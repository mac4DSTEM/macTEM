//
//  HoughIndexer.swift
//  Hough (Radon) indexing of EBSD patterns: the detected bands of a pattern vote, three at a time, for the reflector
//  families whose interplanar angles their triangle matches (triplet voting, Wright & Adams 1992, Metall. Trans. A 23,
//  759; Lassen 1994); the best-ranked band pairs fix trial orientations, the one matching most bands closest wins, and the
//  orientation is refined over the matched bands with Shuster's QUEST (Shuster & Oh 1981, J. Guid. Control 4, 70). The
//  orientation is then turned from the detector frame into the sample frame through the sample tilt and the camera
//  elevation. Confidence metrics as pyEBSDindex reports them: the fit (mean angle between the measured and the matched
//  band normals), the confidence metric (the votes of the matched families over all votes), the pattern quality (mean
//  band peak) and the number of matched bands.
//
//  Ported from pyEBSDindex 0.3.10.1 (D. Rowenhorst, US Naval Research Laboratory; public domain in the US, NOTICE carries
//  the acknowledgement and modification notice): `tripletvote.BandIndexer.bandindex`, `_tripvote_numba`,
//  `_assign_bands_nb2`, `_calc_quest_weights`, `_refine_orientation_quest`, `_orientation_quest_nb`, `_calc_cm`;
//  `_ebsd_index_single.EBSDIndexer.index_pats`, `_indexbandsphase`, `_detector2refframe`; `rotlib.quat_multiply`,
//  `quatnorm`, `quat_vector`. Rowenhorst et al. 2024 (pyEBSDindex docs) describe the method. Modified for macTEM in
//  November 2026: Swift, float64 (pyEBSDindex: float32 votes and trial rotations under numba fastmath); the vendor fixed
//  to "KIKUCHIPY" (Bruker PCs in, orix's quaternion convention out), the frame kikuchipy's `hough_indexing` uses.
//  Parity bundles `m4/hough-nickel-block` and `m4/hough-indexing-nickel-large` (north-star figure F8).
//

import Foundation

package nonisolated struct HoughIndexer: Sendable {
    package enum Error: Swift.Error, Equatable, Sendable, LocalizedError {
        case noPhases
        case shape

        package var errorDescription: String? {
            switch self {
            case .noPhases: "Hough indexing needs at least one phase."
            case .shape: "Hough indexing needs a scan of at least one row and one column."
            }
        }
    }

    /// One pattern's solution for one phase (pyEBSDindex's index record).
    package struct Solution: Sendable, Equatable {
        /// Unit quaternion (a >= 0) in the sample frame (vendor "KIKUCHIPY"); all zero when not indexed.
        package var quaternion = SIMD4<Double>(0, 0, 0, 0)
        /// Mean angle (degrees) between the measured and the matched band normals of the fit's bands; 180 when not indexed.
        package var fit = 180.0
        /// Votes of the matched families over all votes; 0 when not indexed.
        package var confidence = 0.0
        /// Mean convolved Radon peak of the valid bands (pattern quality) and mean normalised peak (pyEBSDindex's "iq").
        package var patternQuality = 0.0
        package var imageQuality = 0.0
        /// The phase's index in the indexer's list, -1 when not indexed.
        package var phase = -1
        /// Bands matched to the library.
        package var matchedBands = 0
        /// The winning band pair: its rank positions and band indices (-1 when no pair matched).
        package var matchAttempts = SIMD4<Int>(-1, -1, -1, -1)
        /// Matched bands whose library family agrees with the band's voted family.
        package var totalVotes = 0
        /// Per band: the nearest library variant under the winning trial rotation (-1 none) and the angle (degrees) to it after
        /// the fit, for the bands the QUEST fit weighed (180 elsewhere).
        package var bandMatch: [Int] = []
        package var bandFit: [Double] = []
        /// Per band: whether the assignment matched it (within the angle tolerance of its variant); `matchedBands` counts them.
        package var bandMatched: [Bool] = []

        /// The not-indexed solution.
        package init() {}
    }

    /// The vote of one pattern for one phase (`_tripvote_numba`), kept for the parity tests.
    package struct Vote: Sendable, Equatable {
        /// family-major (families x bands): weighted and plain votes.
        package var weighted: [Double]
        package var counts: [Double]
        package var family: [Int]
        package var rank: [Double]
    }

    package let phases: [HoughReflectorLibrary]
    package let detector: HoughBandDetector
    /// The projection centre (Bruker convention), the sample tilt and the camera (detector) elevation, degrees.
    package let projectionCenter: SIMD3<Double>
    package let sampleTilt: Double
    package let cameraElevation: Double
    /// Matched bands after which later phases are not tried (the largest of the phases' early exits).
    package let earlyExitBands: Int

    package init(phases: [HoughReflectorLibrary], detector: HoughBandDetector, projectionCenter: SIMD3<Double>,
                 sampleTilt: Double = 70, cameraElevation: Double = 0) throws {
        guard !phases.isEmpty else { throw Error.noPhases }
        self.phases = phases
        self.detector = detector
        self.projectionCenter = projectionCenter
        self.sampleTilt = sampleTilt
        self.cameraElevation = cameraElevation
        earlyExitBands = phases.map(\.earlyExitBands).max() ?? 0   // no phase, no band to wait for
    }

    // MARK: - One pattern

    /// The bands' vote weights (`_indexbandsphase`): the peak value, lowered towards large |rho|, halved for bands within
    /// 2 degrees of theta 0 or 180, zero for invalid bands.
    package func bandIntensity(_ bands: [HoughBandDetector.Band]) -> [Double] {
        let rhoMax = Double(detector.rhoMax)
        return bands.map { b in
            var v = (-1 * abs(b.rho) * 0.5 / rhoMax + 1) * b.max
            v *= ((b.theta > 2 * Double.pi / 180 ? 1 : 0) + 0.5) / 2
            v *= ((b.theta < 178 * Double.pi / 180 ? 1 : 0) + 0.5) / 2
            return b.valid ? v : 0
        }
    }

    /// Index one pattern: detect its bands, then every phase until one matches `earlyExitBands`, the best by
    /// (3 - fit) · matched bands.
    package func index(_ pattern: [Double]) throws -> (solution: Solution, bands: [HoughBandDetector.Band]) {
        let bands = try detector.detect(pattern)
        let normals = detector.normals(bands, pc: projectionCenter)
        return (index(bands: bands, normals: normals), bands)
    }

    package func index(bands: [HoughBandDetector.Band], normals: [SIMD3<Double>]) -> Solution {
        let intensity = bandIntensity(bands)
        let valid = bands.map { $0.valid ? 1.0 : 0.0 }
        let n = Double(bands.count)
        let pq = zip(bands, valid).reduce(0.0) { $0 + $1.0.max * $1.1 } / n
        let iq = zip(bands, valid).reduce(0.0) { $0 + $1.0.normalizedMax * $1.1 } / n
        let reference = detectorToSample()
        var perPhase: [Solution] = []
        var bestMatched = 0
        for (j, library) in phases.enumerated() {
            var s = Solution()
            s.patternQuality = pq
            s.imageQuality = iq
            s.bandMatch = [Int](repeating: -100, count: bands.count)
            s.bandFit = [Double](repeating: 180, count: bands.count)
            s.bandMatched = [Bool](repeating: false, count: bands.count)
            if bestMatched < earlyExitBands {
                let r = Self.indexBands(library: library, normals: normals, intensity: intensity)
                if r.matched >= 3 {
                    s.quaternion = r.quaternion
                    s.fit = r.fit
                    s.confidence = r.confidence
                    s.phase = j
                    s.matchedBands = r.matched
                    s.matchAttempts = r.attempts
                    s.totalVotes = r.totalVotes
                    s.bandMatch = r.match
                    s.bandFit = r.bandFit
                    s.bandMatched = r.bandMatched
                }
                bestMatched = max(bestMatched, s.matchedBands)
            }
            s.quaternion = Self.normalized(Self.multiply(s.quaternion, reference))
            perPhase.append(s)
        }
        var best = perPhase[0]
        for s in perPhase.dropFirst() where (3 - s.fit) * Double(s.matchedBands) > (3 - best.fit) * Double(best.matchedBands) {
            best = s
        }
        return best
    }

    /// `_detector2refframe` for "KIKUCHIPY": a -90 degree turn about z, then the tilt -(90 - sample tilt + camera
    /// elevation) about x.
    package func detectorToSample() -> SIMD4<Double> {
        let h = 2.0.squareRoot() * 0.5
        let q0 = SIMD4<Double>(h, 0, 0, -h)
        let t = -1 * (90 - sampleTilt + cameraElevation) / HoughReflectorLibrary.degrees
        let q1 = SIMD4<Double>(cos(t * 0.5), sin(t * 0.5), 0, 0)
        return Self.multiply(q1, q0)
    }

    /// `rotlib.quat_multiply` (P = 1): the Hamilton product q1 q2.
    package static func multiply(_ q1: SIMD4<Double>, _ q2: SIMD4<Double>) -> SIMD4<Double> {
        SIMD4(q1[0] * q2[0] - (q1[1] * q2[1] + q1[2] * q2[2] + q1[3] * q2[3]),
              q1[0] * q2[1] + q2[0] * q1[1] + (q1[2] * q2[3] - q1[3] * q2[2]),
              q1[0] * q2[2] + q2[0] * q1[2] + (q1[3] * q2[1] - q1[1] * q2[3]),
              q1[0] * q2[3] + q2[0] * q1[3] + (q1[1] * q2[2] - q1[2] * q2[1]))
    }

    /// `rotlib.quatnorm`: a >= 0 and unit length (a zero quaternion stays zero).
    package static func normalized(_ q: SIMD4<Double>) -> SIMD4<Double> {
        let s = q[0] >= 0 ? q : -q
        return s * (1 / ((s * s).sum().squareRoot() + 1e-35))
    }

    // MARK: - bandindex

    package struct BandIndexResult: Sendable, Equatable {
        package var quaternion = SIMD4<Double>(0, 0, 0, 0)
        package var fit = 180.0
        package var confidence = -1.0
        package var matched = 0
        package var attempts = SIMD4<Int>(-1, -1, -1, -1)
        package var totalVotes = 0
        package var match: [Int] = []
        package var bandFit: [Double] = []
        /// The assignment's matched bands (`_assign_bands_nb2`'s valid flags).
        package var bandMatched: [Bool] = []
        package var vote: Vote
    }

    /// `BandIndexer.bandindex` for one pattern: vote, assign, QUEST fit, confidence; the orientation in the detector frame.
    package static func indexBands(library: HoughReflectorLibrary, normals: [SIMD3<Double>], intensity: [Double]) -> BandIndexResult {
        let vote = tripletVote(library: library, normals: normals, intensity: intensity)
        let nb = normals.count
        // argsort of the rank (ascending, stable for ties as numpy's insertion sort on so few values).
        let rankOrder = (0..<nb).sorted { vote.rank[$0] < vote.rank[$1] || (vote.rank[$0] == vote.rank[$1] && $0 < $1) }
        let a = assignBands(library: library, normals: normals, rankOrder: rankOrder, family: vote.family)
        var result = BandIndexResult(vote: vote)
        result.matched = a.matched
        result.attempts = a.attempts
        result.match = a.match
        result.bandMatched = a.valid
        let fams = library.familyID
        result.totalVotes = (0..<nb).filter { a.valid[$0] && fams[max(a.match[$0], 0)] == vote.family[$0] }.count
        // _calc_quest_weights (simpleqweights False): the six best-supported matched bands, weighted by intensity.
        let good = (0..<nb).filter { a.valid[$0] }
        var weights = [Double](repeating: 0, count: nb)
        if good.count >= 3 {
            var score = [Double](repeating: -1, count: nb)
            for g in good {
                let f = fams[a.match[g]]
                score[g] = vote.weighted[f * nb + g] / max(vote.counts[f * nb + g], 1e-12)
            }
            let ascending = (0..<nb).sorted { score[$0] < score[$1] || (score[$0] == score[$1] && $0 < $1) }
            for s in ascending.reversed().prefix(min(6, good.count)) { weights[s] = intensity[s] }
            let total = weights.reduce(0, +)
            weights = weights.map { $0 / total }
        }
        let poles = a.match.map { library.polesCartesian[max($0, 0)] }
        let q = quest(poles: poles, normals: normals, weights: weights)
        result.quaternion = q.quaternion
        result.fit = acos(min(max(q.meanDot, -1), 1)) * HoughReflectorLibrary.degrees
        result.bandFit = q.dots.map { acos(min(max($0, -1), 1)) * HoughReflectorLibrary.degrees }
        // _calc_cm: the matched bands' votes for their families over every vote cell (each counted at least 1).
        if good.count >= 3 {
            var matchedVotes = 0.0
            for g in good { matchedVotes += vote.weighted[fams[a.match[g]] * nb + g] }
            result.confidence = matchedVotes / vote.weighted.reduce(0) { $0 + max($1, 1) }
        }
        return result
    }

    /// `_tripvote_numba` for one pattern: every band triangle against every library triplet within the tolerance; each
    /// match votes for the corner families (weighted by the closeness), with the extra assignments when two or three of the
    /// triangle's angles are within the tolerance of each other. Then each band's family (the largest weighted vote, first
    /// on ties), its confidence ((first - second) / total) and its rank ((n - i) / n · confidence · int(largest vote)).
    package static func tripletVote(library: HoughReflectorLibrary, normals: [SIMD3<Double>], intensity: [Double]) -> Vote {
        let nb = normals.count, nf = library.familyCount, tol = library.angleTolerance
        var angles = [Double](repeating: 0, count: nb * nb)
        for i in 0..<nb {
            for j in 0..<nb {
                angles[i * nb + j] = acos(min(max(abs(Vector3.dot(normals[i], normals[j])), -1), 1)) * HoughReflectorLibrary.degrees
            }
        }
        for q in 0..<nb where intensity[q] < 1e-6 {
            for k in 0..<nb { angles[q * nb + k] = 10000; angles[k * nb + q] = 10000 }
        }
        var acc = [Double](repeating: 0, count: nf * nb), accW = [Double](repeating: 0, count: nf * nb)
        func add(_ f: Int, _ b: Int, _ w: Double) {
            accW[f * nb + b] += w
            acc[f * nb + b] += 1
        }
        let table = library.tripletAngles, ids = library.tripletFamilies
        for i in 0..<nb {
            for j in (i + 1)..<max(nb, i + 1) {
                for k in (j + 1)..<max(nb, j + 1) {
                    let tri = [angles[i * nb + j], angles[i * nb + k], angles[j * nb + k]]
                    var s = [0, 1, 2]
                    if tri[s[0]] > tri[s[2]] { s.swapAt(0, 2) }
                    if tri[s[0]] > tri[s[1]] { s.swapAt(0, 1) }
                    if tri[s[1]] > tri[s[2]] { s.swapAt(1, 2) }
                    let s2 = HoughReflectorLibrary.cornerPermutation(s)
                    var u = [0, 1, 2]
                    if s2[u[0]] > s2[u[2]] { u.swapAt(0, 2) }
                    if s2[u[0]] > s2[u[1]] { u.swapAt(0, 1) }
                    if s2[u[1]] > s2[u[2]] { u.swapAt(1, 2) }
                    let a0 = tri[s[0]], a1 = tri[s[1]], a2 = tri[s[2]]
                    let c1 = abs(a0 - a1) < tol, c2 = abs(a1 - a2) < tol, c3 = abs(a2 - a0) < tol
                    for qq in 0..<table.count {
                        let t1 = abs(table[qq][0] - a0)
                        if t1 > tol { continue }
                        let t2 = abs(table[qq][1] - a1)
                        if t2 > tol { continue }
                        let t3 = abs(table[qq][2] - a2)
                        if t3 > tol { continue }
                        let f = SIMD3(ids[qq][u[0]], ids[qq][u[1]], ids[qq][u[2]])
                        let w1 = tol - 0.5 * (t1 + t2), w2 = tol - 0.5 * (t1 + t3), w3 = tol - 0.5 * (t2 + t3)
                        add(f[0], i, w1); add(f[1], j, w2); add(f[2], k, w3)
                        if c1 { add(f[0], j, w1); add(f[1], i, w2); add(f[2], k, w3) }
                        if c2 { add(f[0], i, w1); add(f[1], k, w2); add(f[2], j, w3) }
                        if c3 { add(f[0], k, w1); add(f[1], j, w2); add(f[2], i, w3) }
                        if c1 && c2 && c3 {
                            add(f[0], k, w1); add(f[1], i, w2); add(f[2], j, w3)
                            add(f[0], j, w1); add(f[1], k, w2); add(f[2], i, w3)
                        }
                    }
                }
            }
        }
        var family = [Int](repeating: 0, count: nb), rank = [Double](repeating: 0, count: nb)
        for b in 0..<nb {
            let column = (0..<nf).map { accW[$0 * nb + b] }
            let largest = column.max() ?? 0
            let total = column.reduce(0, +)
            // int32 truncation of the float sums, as pyEBSDindex stores mxvote and tvotes.
            // A sum that is not a number (NaN weights) votes nothing rather than trapping in the cast.
            let mxvote = Double(CheckedConversion.int(largest) ?? 0), tvotes = Double(CheckedConversion.int(total) ?? 0)
            var cm = 0.0
            if tvotes >= 1 {
                let sorted = column.sorted()
                cm = (sorted[sorted.count - 1] - (sorted.count > 1 ? sorted[sorted.count - 2] : 0)) / tvotes
            }
            var mx = -1.0e12
            for q in 0..<nf where column[q] > mx {
                mx = column[q]
                family[b] = q
            }
            rank[b] = Double(nb - b) / Double(nb) * cm * mxvote
        }
        return Vote(weighted: accW, counts: acc, family: family, rank: rank)
    }

    package struct Assignment: Sendable, Equatable {
        var matched = 0
        var fit = 360.0
        var match: [Int]
        var valid: [Bool]
        var attempts = SIMD4<Int>(-1, -1, -1, -1)
    }

    /// `_assign_bands_nb2`: band pairs in rank order (best first); each pair whose angle the library allows between the
    /// two voted families gives trial rotations (one per allowed variant of the second family, the first band on the
    /// family's first variant); the trial matching most bands (score: matches / mean angle) sets the pair's solution; the
    /// pair with most matched bands, then the smallest mean angle, wins; the search stops once `earlyExitBands` match.
    package static func assignBands(library: HoughReflectorLibrary, normals: [SIMD3<Double>], rankOrder: [Int], family: [Int]) -> Assignment {
        let nb = normals.count, tol = library.angleTolerance
        let poles = library.polesCartesian, nPoles = poles.count
        var best = Assignment(match: [Int](repeating: -1000, count: nb), valid: [Bool](repeating: false, count: nb))
        outer: for ii in 0..<max(nb - 1, 0) {
            for jj in (ii + 1)..<nb {
                let b1 = rankOrder[nb - 1 - ii], b2 = rankOrder[nb - 1 - jj]
                let v1 = normals[b1], v2 = normals[b2], f1 = family[b1], f2 = family[b2]
                var c01 = Vector3.dot(v1, v2)
                if c01 > 1 { c01 = 1 - 1e-12 }
                if c01 < -1 { c01 = -1 + 1e-12 }
                // Not (anti)parallel: the pair can fix an orientation.
                if acos(abs(c01)) * HoughReflectorLibrary.degrees > tol {
                    let a01 = acos(c01) * HoughReflectorLibrary.degrees
                    let s1 = library.familyStart[f1], s2 = library.familyStart[f2]
                    let candidates = (s2..<(s2 + library.familySize[f2])).filter { abs(library.angleTable[s1 * nPoles + $0] - a01) < tol }
                    var angFit = [Double](repeating: 0, count: nb)
                    var match = [Int](repeating: -1, count: nb), valid = [Bool](repeating: false, count: nb)
                    var nGood = 0
                    if !candidates.isEmpty {
                        let p1 = poles[s1]
                        var c = Vector3.cross(v1, v2)
                        c /= (c * c).sum().squareRoot()
                        let bRows = [v1, c, Vector3.cross(v1, c)]
                        var score = -1.0
                        for w in candidates {
                            var p2 = poles[w]
                            p2 /= ((p2 * p2).sum().squareRoot() + 1e-35)
                            var pp = Vector3.cross(p1, p2)
                            pp /= ((pp * pp).sum().squareRoot() + 1e-35)
                            let aCols = [p1, pp, Vector3.cross(p1, pp)]
                            // AB = A · B with A's columns aCols and B's rows bRows: AB · v = Σ_k aCols[k] (bRows[k] · v).
                            var fitTry = [Double](repeating: 0, count: nb), argmaxTry = [Int](repeating: 0, count: nb)
                            for b in 0..<nb {
                                let n = normals[b]
                                let d0 = Vector3.dot(bRows[0], n), d1 = Vector3.dot(bRows[1], n), d2 = Vector3.dot(bRows[2], n)
                                let rotated = aCols[0] * d0 + aCols[1] * d1 + aCols[2] * d2
                                var mx = -Double.infinity, arg = 0
                                for p in 0..<nPoles {
                                    let t = Vector3.dot(poles[p], rotated)
                                    if t > mx { mx = t; arg = p }
                                }
                                fitTry[b] = acos(min(max(mx, -1), 1)) * HoughReflectorLibrary.degrees
                                argmaxTry[b] = arg
                            }
                            let matchedTry = fitTry.filter { $0 < tol }
                            let scoreTry = Double(matchedTry.count) / (matchedTry.reduce(0, +) / Double(matchedTry.count) + 1e-6)
                            if scoreTry > score {
                                score = scoreTry
                                angFit = fitTry
                                match = argmaxTry
                                valid = fitTry.map { $0 < tol }
                            }
                        }
                        nGood = angFit.filter { $0 < tol }.count
                    }
                    if nGood >= 3 {
                        let fit = (0..<nb).filter { angFit[$0] < tol }.reduce(0.0) { $0 + angFit[$1] } / Double(nGood)
                        if best.matched < nGood || (best.matched == nGood && best.fit > fit) {
                            best = Assignment(matched: nGood, fit: fit, match: match, valid: valid, attempts: SIMD4(ii, jj, b1, b2))
                        }
                    }
                }
                if best.matched >= library.earlyExitBands { break outer }
            }
        }
        return best
    }

    /// `_orientation_quest_nb`: the weighted best rotation taking the band normals onto the matched library normals
    /// (Shuster's quaternion estimator, Newton iterations on the characteristic polynomial), a >= 0; the cosines between
    /// the rotated normals and their poles for the weighted bands (-1 elsewhere) and their mean.
    package static func quest(poles: [SIMD3<Double>], normals: [SIMD3<Double>], weights: [Double])
        -> (quaternion: SIMD4<Double>, meanDot: Double, dots: [Double]) {
        let good = weights.indices.filter { weights[$0] > 1e-7 }
        var dots = [Double](repeating: -1, count: normals.count)
        guard good.count >= 3 else { return (SIMD4(1, 0, 0, 0), -1, dots) }
        let total = good.reduce(0.0) { $0 + weights[$1] }
        var B = [Double](repeating: 0, count: 9)
        var z = SIMD3<Double>(0, 0, 0)
        for g in good {
            let w = weights[g] / total, b = normals[g], p = poles[g]
            for r in 0..<3 { for c in 0..<3 { B[r * 3 + c] += w * b[r] * p[c] } }
            z += w * Vector3.cross(b, p)
        }
        var S = [Double](repeating: 0, count: 9)
        for r in 0..<3 { for c in 0..<3 { S[r * 3 + c] = B[r * 3 + c] + B[c * 3 + r] } }
        func mul(_ x: [Double], _ y: [Double]) -> [Double] {
            var o = [Double](repeating: 0, count: 9)
            for r in 0..<3 { for c in 0..<3 { for k in 0..<3 { o[r * 3 + c] += x[r * 3 + k] * y[k * 3 + c] } } }
            return o
        }
        func apply(_ m: [Double], _ v: SIMD3<Double>) -> SIMD3<Double> {
            SIMD3(m[0] * v[0] + m[1] * v[1] + m[2] * v[2], m[3] * v[0] + m[4] * v[1] + m[5] * v[2], m[6] * v[0] + m[7] * v[1] + m[8] * v[2])
        }
        let S2 = mul(S, S)
        let det = S[0] * (S[4] * S[8] - S[5] * S[7]) - S[1] * (S[3] * S[8] - S[5] * S[6]) + S[2] * (S[3] * S[7] - S[4] * S[6])
        let k = (S[4] * S[8] - S[5] * S[7]) + (S[0] * S[8] - S[2] * S[6]) + (S[0] * S[4] - S[3] * S[1])
        let sig = 0.5 * (S[0] + S[4] + S[8]), sig2 = sig * sig
        let d = Vector3.dot(z, apply(S2, z))
        let c = det + Vector3.dot(z, apply(S, z))
        let b = sig2 + Vector3.dot(z, z)
        let a = sig2 - k
        var lam = 1.0, iter = 0, dlam = 1e6
        while dlam > 1e-12 && iter < 10 {
            let lam0 = lam
            lam -= (lam * lam * lam * lam - (a + b) * lam * lam - c * lam + (a * b + c * sig - d))
                / (4 * lam * lam * lam - 2 * (a + b) * lam - c)
            dlam = abs(lam0 - lam)
            iter += 1
        }
        let beta = lam - sig, alpha = lam * lam - sig2 + k, gamma = (lam + sig) * alpha - det
        var M = S2
        for r in 0..<3 { for col in 0..<3 { M[r * 3 + col] += beta * S[r * 3 + col] + (r == col ? alpha : 0) } }
        let X = apply(M, z)
        var q = SIMD4(gamma, X[0], X[1], X[2])
        let norm = (q * q).sum().squareRoot()
        // A zero or non-finite quaternion (degenerate or NaN band normals) has no rotation: the point is not indexed, as with
        // fewer than three weighted bands.
        guard norm > 0, norm.isFinite else { return (SIMD4(1, 0, 0, 0), -1, dots) }
        q /= norm
        if gamma < 0 { q = -q }
        var sum = 0.0
        for g in good {
            let rotated = HoughReflectorLibrary.rotate(q, normals[g])
            dots[g] = Vector3.dot(rotated, poles[g])
            sum += dots[g]
        }
        return (q, sum / Double(good.count), dots)
    }

    // MARK: - A scan

    /// A Hough-indexed scan, scan row-major.
    package struct Map: Sendable {
        package var scanRows: Int
        package var scanColumns: Int
        package var solutions: [Solution]

        package init(scanRows: Int, scanColumns: Int, solutions: [Solution]) {
            self.scanRows = scanRows; self.scanColumns = scanColumns; self.solutions = solutions
        }

        /// The orientations as orix's `Rotation` takes them (kikuchipy's `xmap_from_hough_indexing_data`): identity where
        /// not indexed.
        package var rotations: [Rotation] {
            solutions.map { $0.phase < 0 ? Rotation(SIMD4(1, 0, 0, 0)) : Rotation($0.quaternion) }
        }
    }

    /// Index every pattern of a scan. Patterns are read in scan order on the calling task (`pattern` need not be thread
    /// safe) and indexed in parallel; `progress` reports after each scan row; cancellation stops between batches.
    @concurrent package func indexMap(
        scanRows: Int, scanColumns: Int, progress: (@Sendable (Double) -> Void)? = nil,
        pattern: @Sendable (_ row: Int, _ column: Int) throws -> [Double]
    ) async throws -> Map {
        guard scanRows >= 1, scanColumns >= 1 else { throw Error.shape }
        var solutions = [Solution](repeating: Solution(), count: scanRows * scanColumns)
        let workers = max(ProcessInfo.processInfo.activeProcessorCount, 1)
        for r in 0..<scanRows {
            try Task.checkCancellation()
            var row: [[Double]] = []
            row.reserveCapacity(scanColumns)
            for c in 0..<scanColumns { row.append(try pattern(r, c)) }
            let patterns = row
            let results = try await withThrowingTaskGroup(of: (Int, Solution).self) { group in
                var next = 0
                var out = [Solution](repeating: Solution(), count: scanColumns)
                func launch() {
                    let c = next
                    next += 1
                    group.addTask { [self] in (c, try self.index(patterns[c]).solution) }
                }
                while next < min(workers, scanColumns) { launch() }
                while let (c, s) = try await group.next() {
                    out[c] = s
                    if next < scanColumns { launch() }
                }
                return out
            }
            for c in 0..<scanColumns { solutions[r * scanColumns + c] = results[c] }
            progress?(Double(r + 1) / Double(scanRows))
        }
        return Map(scanRows: scanRows, scanColumns: scanColumns, solutions: solutions)
    }
}
