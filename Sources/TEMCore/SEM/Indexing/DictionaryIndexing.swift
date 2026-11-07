//
//  DictionaryIndexing.swift
//  Role: EBSD dictionary indexing (Chen et al. 2015, Jackson et al. 2019): every experimental pattern compared with every
//        pattern of a dictionary of known orientations by a similarity metric, the `keepN` best matches kept per pattern. A port
//        of kikuchipy 0.13.1's `EBSD.dictionary_indexing` and `indexing/_dictionary_indexing.py` (`_dictionary_indexing`,
//        `_match_chunk`) with its two metrics, `NormalizedCrossCorrelationMetric` ("ncc": each pattern centred to zero mean
//        and scaled to unit norm, the Pearson coefficient) and `NormalizedDotProductMetric` ("ndp": unit norm only), the
//        signal and navigation masks and the dictionary taken in chunks; GPL-3.0-or-later, notice in NOTICE.
//        The dictionary either comes in full or is projected chunk by chunk from a master pattern (`MasterPatternProjection`,
//        figure F15) for a sample of orientations (`OrientationSampling.fundamental`), so a large dictionary never sits in
//        memory whole. The float64 CPU path is the reference (decision D16); `DictionaryIndexingMetal` is the float32 GPU path
//        for the matrix product of patterns x dictionary, checked against this one.
//        Parity: macTEMTests/SEMDictionaryIndexingParityTests.swift against tools/parity/sem/references/m4/dictionary-indexing-*
//        (figure F9): scores within rtol 1e-4 of kikuchipy's float32 run and 1e-5 of its float64 run, simulation indices exact
//        where the scores do not tie.
//

import Foundation

package nonisolated enum DictionaryIndexing {
    /// kikuchipy's `metric`: "ncc" (the default) or "ndp". Greater is better for both.
    package enum Metric: String, Sendable, CaseIterable {
        case ncc, ndp

        /// NCC centres each pattern before it scales it to unit norm; NDP only scales (its code, whatever its docstring says).
        var centres: Bool { self == .ncc }
    }

    /// Where the matrix product runs: the float64 CPU reference, the float32 GPU path, or the GPU when the work pays and a device
    /// is there.
    package enum Backend: Sendable, Equatable { case automatic, cpu, metal }

    package struct Options: Sendable, Equatable {
        package var metric: Metric
        /// `keep_n`: best matches kept per pattern, at most the dictionary's size.
        package var keepN: Int
        /// `signal_mask`, detector row-major: `true` leaves the pixel out of the comparison.
        package var signalMask: [Bool]?
        /// `navigation_mask`, scan row-major: `true` leaves the pattern out (it is not indexed).
        package var navigationMask: [Bool]?
        /// `n_per_iteration`: dictionary patterns compared per chunk; nil sizes the chunk from `memoryBudget`.
        package var patternsPerIteration: Int?
        /// Bytes the chunk's dictionary patterns and score matrix may take when `patternsPerIteration` is nil.
        package var memoryBudget: Int
        package var backend: Backend

        package init(metric: Metric = .ncc, keepN: Int = 20, signalMask: [Bool]? = nil, navigationMask: [Bool]? = nil,
                     patternsPerIteration: Int? = nil, memoryBudget: Int = 256 << 20, backend: Backend = .automatic) {
            self.metric = metric; self.keepN = keepN; self.signalMask = signalMask; self.navigationMask = navigationMask
            self.patternsPerIteration = patternsPerIteration; self.memoryBudget = memoryBudget; self.backend = backend
        }
    }

    package enum Error: Swift.Error, LocalizedError, Equatable {
        case emptyDictionary
        case keepN(Int)
        case patternCount(values: Int, patterns: Int, pixels: Int)
        case navigationShape([Int], patterns: Int)
        case rotationCount(rotations: Int, patterns: Int)
        case signalMaskShape(mask: Int, pixels: Int)
        case navigationMaskShape(mask: Int, patterns: Int)
        case signalMaskAll
        case navigationMaskAll
        case patternsPerIteration(Int)

        package var errorDescription: String? {
            switch self {
            case .emptyDictionary: return "The dictionary holds no patterns."
            case .keepN(let n): return "keep_n must be at least 1, not \(n)."
            case .patternCount(let v, let p, let px): return "\(v) values are not \(p) patterns of \(px) pixels."
            case .navigationShape(let s, let p): return "The navigation shape \(s) does not hold \(p) patterns."
            case .rotationCount(let r, let p): return "The dictionary has \(p) patterns but \(r) rotations."
            case .signalMaskShape(let m, let px): return "The signal mask has \(m) pixels, the patterns \(px)."
            case .navigationMaskShape(let m, let p): return "The navigation mask has \(m) points, the scan \(p)."
            case .signalMaskAll: return "The signal mask leaves no pixel to compare."
            case .navigationMaskAll: return "The navigation mask must allow for indexing of at least one pattern."
            case .patternsPerIteration(let n): return "n_per_iteration must be at least 1, not \(n)."
            }
        }
    }

    /// The crystal map kikuchipy returns: per scan point (row-major) `keepN` matches, best first.
    package struct Result: Sendable, Equatable {
        /// Scan rows, columns (one entry for a line scan).
        package var navigationShape: [Int]
        package var keepN: Int
        /// orix's `is_in_data`: false where the navigation mask left the point out.
        package var isInData: [Bool]
        /// `prop["scores"]`, point × keepN; NaN for a point not in the data (kikuchipy leaves `np.empty`'s garbage there).
        package var scores: [Double]
        /// `prop["simulation_indices"]` into the dictionary, point × keepN; -1 for a point not in the data.
        package var simulationIndices: [Int]
        /// The dictionary's rotation (a, b, c, d) at each simulation index, point × keepN; the identity for a point not in the data.
        package var rotations: [SIMD4<Double>]

        package var pointCount: Int { isInData.count }

        /// The best match of each point.
        package var bestScores: [Double] { stride(from: 0, to: scores.count, by: keepN).map { scores[$0] } }
        package var bestSimulationIndices: [Int] { stride(from: 0, to: simulationIndices.count, by: keepN).map { simulationIndices[$0] } }
        package var bestRotations: [SIMD4<Double>] { stride(from: 0, to: rotations.count, by: keepN).map { rotations[$0] } }

        /// The result as the app's crystal map: the best match's Bunge Euler angles (orix's `to_euler`), the phase's id where the
        /// point is in the data and -1 (orix's `not_indexed`) where it is not, the best score and simulation index as properties,
        /// and orix's `create_coordinate_arrays` from the step sizes (dy, dx).
        package func crystalMap(phase: EBSDPhase, stepSizes: [Double]) -> EBSDCrystalMapData {
            let rows = navigationShape.count == 2 ? navigationShape[0] : 1
            let columns = navigationShape.last ?? 0
            let dy = stepSizes.count == 2 ? stepSizes[0] : 1, dx = stepSizes.last ?? 1
            var x = [Double](), y = [Double]()
            x.reserveCapacity(pointCount); y.reserveCapacity(pointCount)
            for r in 0 ..< rows { for c in 0 ..< columns { x.append(Double(c) * dx); y.append(Double(r) * dy) } }
            let id = phase.id ?? 0
            return EBSDCrystalMapData(euler: bestRotations.map(RotationConversions.qu2eu),
                                      phaseIDs: isInData.map { $0 ? id : -1 }, phases: [phase],
                                      properties: ["scores": bestScores, "simulation_indices": bestSimulationIndices.map(Double.init)],
                                      x: x, y: navigationShape.count == 2 ? y : nil)
        }
    }

    // MARK: - Preparation

    /// The pixels the comparison uses: those the signal mask leaves in, all without a mask.
    static func keptPixels(_ mask: [Bool]?, pixels: Int) throws -> [Int] {
        guard let mask else { return Array(0 ..< pixels) }
        guard mask.count == pixels else { throw Error.signalMaskShape(mask: mask.count, pixels: pixels) }
        let kept = (0 ..< pixels).filter { !mask[$0] }
        guard !kept.isEmpty else { throw Error.signalMaskAll }
        return kept
    }

    /// `prepare_experimental` / `prepare_dictionary` in float64: the kept pixels of `count` patterns (row-major in `values`, a
    /// pattern of `pixels` values every `pixels`), centred for NCC, divided by their Euclidean norm. A flat pattern divides zero by
    /// zero, so its values are NaN, as kikuchipy's are.
    package static func prepare(_ values: UnsafeBufferPointer<Double>, count: Int, pixels: Int, kept: [Int], metric: Metric) -> [Double] {
        let n = kept.count
        var out = [Double](repeating: 0, count: count * n)
        let all = kept.count == pixels
        out.withUnsafeMutableBufferPointer { o in
            for p in 0 ..< count {
                let src = values.baseAddress! + p * pixels
                let dst = o.baseAddress! + p * n
                if all { for k in 0 ..< n { dst[k] = src[k] } } else { for k in 0 ..< n { dst[k] = src[kept[k]] } }
                if metric.centres {
                    var sum = 0.0
                    for k in 0 ..< n { sum += dst[k] }
                    let mean = sum / Double(n)
                    for k in 0 ..< n { dst[k] -= mean }
                }
                var squares = 0.0
                for k in 0 ..< n { squares += dst[k] * dst[k] }
                let norm = squares.squareRoot()
                for k in 0 ..< n { dst[k] /= norm }
            }
        }
        return out
    }

    // MARK: - Matching

    /// `metric.match` on the CPU in float64: the scores of every experimental pattern (rows) against every dictionary pattern
    /// (columns), `experimental · dictionaryᵀ`, both already prepared with `length` values per pattern.
    static func matchCPU(experimental e: [Double], count nExp: Int, dictionary d: [Double], count nDict: Int, length: Int) -> [Double] {
        var scores = [Double](repeating: 0, count: nExp * nDict)
        // Blocks of experimental patterns that stay in cache while a block of dictionary patterns streams past.
        let expBlock = 32, dictBlock = 64
        let expBlocks = (nExp + expBlock - 1) / expBlock, dictBlocks = (nDict + dictBlock - 1) / dictBlock
        e.withUnsafeBufferPointer { ep in
            d.withUnsafeBufferPointer { dp in
                scores.withUnsafeMutableBufferPointer { sp in
                    let shared = MatchBuffers(e: ep.baseAddress!, d: dp.baseAddress!, s: sp.baseAddress!)
                    DispatchQueue.concurrentPerform(iterations: expBlocks * dictBlocks) { job in
                        let eb = job / dictBlocks, db = job % dictBlocks
                        let i0 = eb * expBlock, i1 = min(nExp, i0 + expBlock)
                        let m0 = db * dictBlock, m1 = min(nDict, m0 + dictBlock)
                        for m in m0 ..< m1 {
                            let dm = shared.d + m * length
                            for i in i0 ..< i1 { shared.s[i * nDict + m] = dot(shared.e + i * length, dm, length) }
                        }
                    }
                }
            }
        }
        return scores
    }

    /// The dot product of two float64 vectors, four lanes at a time.
    @inline(__always)
    static func dot(_ a: UnsafePointer<Double>, _ b: UnsafePointer<Double>, _ n: Int) -> Double {
        var acc0 = SIMD4<Double>(repeating: 0), acc1 = SIMD4<Double>(repeating: 0)
        let ra = UnsafeRawPointer(a), rb = UnsafeRawPointer(b)
        var k = 0
        let stride = MemoryLayout<Double>.stride
        while k + 8 <= n {
            acc0 += ra.loadUnaligned(fromByteOffset: k * stride, as: SIMD4<Double>.self) * rb.loadUnaligned(fromByteOffset: k * stride, as: SIMD4<Double>.self)
            acc1 += ra.loadUnaligned(fromByteOffset: (k + 4) * stride, as: SIMD4<Double>.self) * rb.loadUnaligned(fromByteOffset: (k + 4) * stride, as: SIMD4<Double>.self)
            k += 8
        }
        var sum = (acc0 + acc1).sum()
        while k < n { sum += a[k] * b[k]; k += 1 }
        return sum
    }

    private struct MatchBuffers: @unchecked Sendable {
        let e: UnsafePointer<Double>
        let d: UnsafePointer<Double>
        let s: UnsafeMutablePointer<Double>
    }

    /// Whether score `a` (at dictionary index `ia`) ranks before `b` (at `ib`): greater first, a NaN last, a tie by the lower index.
    /// kikuchipy breaks ties by `argsort`'s order, which is not stable; the lower index makes the result the same for any chunking.
    @inline(__always)
    static func ranksBefore(_ a: Double, _ ia: Int, _ b: Double, _ ib: Int) -> Bool {
        if a.isNaN { return b.isNaN && ia < ib }
        if b.isNaN { return true }
        return a > b || (a == b && ia < ib)
    }

    /// The best `keepN` matches of each experimental pattern so far, merged chunk by chunk (`_dictionary_indexing`'s hstack, sort
    /// and `take_along_axis`).
    struct Best {
        let keepN: Int
        var scores: [[Double]]
        var indices: [[Int]]

        init(patterns: Int, keepN: Int) {
            self.keepN = keepN
            scores = Array(repeating: [], count: patterns)
            indices = Array(repeating: [], count: patterns)
        }

        /// Merges a chunk's score matrix (patterns × `count`), whose column 0 is dictionary index `offset`.
        mutating func merge(_ chunk: [Double], count: Int, offset: Int) {
            let k = keepN
            for i in 0 ..< scores.count {
                var s = scores[i], idx = indices[i]
                for m in 0 ..< count {
                    let x = chunk[i * count + m], j = offset + m
                    if s.count == k, !ranksBefore(x, j, s[k - 1], idx[k - 1]) { continue }
                    // Insert in rank order, dropping the last when full.
                    var pos = s.count
                    while pos > 0, ranksBefore(x, j, s[pos - 1], idx[pos - 1]) { pos -= 1 }
                    s.insert(x, at: pos); idx.insert(j, at: pos)
                    if s.count > k { s.removeLast(); idx.removeLast() }
                }
                scores[i] = s; indices[i] = idx
            }
        }
    }

    /// The patterns per chunk: `patternsPerIteration`, or as many as the memory budget holds for the chunk's prepared dictionary
    /// and its score matrix (at least one).
    static func chunkSize(_ options: Options, experimental: Int, length: Int, dictionary: Int) throws -> Int {
        if let n = options.patternsPerIteration {
            guard n >= 1 else { throw Error.patternsPerIteration(n) }
            return min(n, dictionary)
        }
        let perPattern = (length + experimental) * MemoryLayout<Double>.stride
        return max(1, min(dictionary, options.memoryBudget / max(perPattern, 1)))
    }

    /// Whether the GPU computes the products: asked for, or automatic and the work (patterns × dictionary × pixels) pays.
    static func usesMetal(_ backend: Backend, work: Int) -> Bool {
        switch backend {
        case .cpu: return false
        case .metal: return true
        case .automatic: return work >= DictionaryIndexingMetal.workThreshold && DictionaryIndexingMetal.isAvailable
        }
    }

    // MARK: - Indexing

    /// The checked experimental side: navigation shape, masks, the prepared patterns of the points in the data.
    private struct Experimental {
        let count: Int
        let inData: [Bool]
        let indexed: [Int]
        let kept: [Int]
        let prepared: [Double]
    }

    private static func experimentalSide(_ experimental: [Double], navigationShape: [Int], pixels: Int, options: Options) throws -> Experimental {
        guard options.keepN >= 1 else { throw Error.keepN(options.keepN) }
        guard pixels > 0, experimental.count % pixels == 0 else {
            throw Error.patternCount(values: experimental.count, patterns: pixels > 0 ? experimental.count / pixels : 0, pixels: pixels)
        }
        let count = experimental.count / pixels
        guard !navigationShape.isEmpty, navigationShape.reduce(1, *) == count else { throw Error.navigationShape(navigationShape, patterns: count) }
        var inData = [Bool](repeating: true, count: count)
        if let mask = options.navigationMask {
            guard mask.count == count else { throw Error.navigationMaskShape(mask: mask.count, patterns: count) }
            inData = mask.map { !$0 }
            guard inData.contains(true) else { throw Error.navigationMaskAll }
        }
        let kept = try keptPixels(options.signalMask, pixels: pixels)
        let indexed = (0 ..< count).filter { inData[$0] }
        var selected = [Double]()
        selected.reserveCapacity(indexed.count * pixels)
        for p in indexed { selected.append(contentsOf: experimental[(p * pixels) ..< ((p + 1) * pixels)]) }
        let prepared = selected.withUnsafeBufferPointer { prepare($0, count: indexed.count, pixels: pixels, kept: kept, metric: options.metric) }
        return Experimental(count: count, inData: inData, indexed: indexed, kept: kept, prepared: prepared)
    }

    /// Runs the chunks: `chunk(start, end)` hands the dictionary patterns `start ..< end` (float32-valued doubles, row-major), each
    /// prepared, matched on the chosen backend and merged.
    private static func run(_ exp: Experimental, pixels: Int, dictionarySize: Int, rotations: [SIMD4<Double>], navigationShape: [Int],
                            options: Options, chunk: (Int, Int) throws -> [Double]) throws -> Result {
        guard dictionarySize > 0 else { throw Error.emptyDictionary }
        let keepN = min(options.keepN, dictionarySize)
        let length = exp.kept.count, nExp = exp.indexed.count
        let per = try chunkSize(options, experimental: nExp, length: length, dictionary: dictionarySize)
        let metal = usesMetal(options.backend, work: nExp * dictionarySize * length)
        var gpu: DictionaryIndexingMetal.Matcher?
        if metal { gpu = try DictionaryIndexingMetal.Matcher(experimental: exp.prepared, count: nExp, length: length) }
        var best = Best(patterns: nExp, keepN: keepN)
        var start = 0
        while start < dictionarySize {
            let end = min(dictionarySize, start + per)
            let raw = try chunk(start, end)
            let prepared = raw.withUnsafeBufferPointer { prepare($0, count: end - start, pixels: pixels, kept: exp.kept, metric: options.metric) }
            let scores: [Double]
            if let gpu {
                scores = try gpu.match(dictionary: prepared, count: end - start)
            } else {
                scores = matchCPU(experimental: exp.prepared, count: nExp, dictionary: prepared, count: end - start, length: length)
            }
            best.merge(scores, count: end - start, offset: start)
            start = end
        }
        var result = Result(navigationShape: navigationShape, keepN: keepN, isInData: exp.inData,
                            scores: [Double](repeating: .nan, count: exp.count * keepN),
                            simulationIndices: [Int](repeating: -1, count: exp.count * keepN),
                            rotations: [SIMD4<Double>](repeating: SIMD4(1, 0, 0, 0), count: exp.count * keepN))
        for (row, point) in exp.indexed.enumerated() {
            for r in 0 ..< keepN {
                let j = best.indices[row][r]
                result.scores[point * keepN + r] = best.scores[row][r]
                result.simulationIndices[point * keepN + r] = j
                result.rotations[point * keepN + r] = rotations[j]
            }
        }
        return result
    }

    /// `EBSD.dictionary_indexing` against a dictionary in memory: `experimental` holds the scan's patterns (scan row-major, then
    /// detector row-major, any data type as doubles), `dictionary` the simulated patterns of the same detector, one per rotation
    /// (a, b, c, d) in `rotations`. kikuchipy casts both to the metric's float type first; pass the dictionary as float32 values
    /// (`get_patterns`' default) to compare with it.
    package static func index(experimental: [Double], navigationShape: [Int], dictionary: [Double], rotations: [SIMD4<Double>],
                              pixels: Int, options: Options = Options()) throws -> Result {
        let exp = try experimentalSide(experimental, navigationShape: navigationShape, pixels: pixels, options: options)
        guard !dictionary.isEmpty else { throw Error.emptyDictionary }
        guard dictionary.count % pixels == 0 else {
            throw Error.patternCount(values: dictionary.count, patterns: dictionary.count / pixels, pixels: pixels)
        }
        let size = dictionary.count / pixels
        guard rotations.count == size else { throw Error.rotationCount(rotations: rotations.count, patterns: size) }
        return try run(exp, pixels: pixels, dictionarySize: size, rotations: rotations, navigationShape: navigationShape, options: options) { s, e in
            Array(dictionary[(s * pixels) ..< (e * pixels)])
        }
    }

    /// Dictionary indexing against the master pattern projected onto `detector` for each rotation, chunk by chunk
    /// (`EBSDMasterPattern.get_patterns(rotations, detector, energy, dtype_out=float32)` then `dictionary_indexing`): the dictionary
    /// is never held whole. The projection runs on the GPU when the matching does (`MasterPatternProjection.patternsFloat32`).
    package static func index(experimental: [Double], navigationShape: [Int], master: EBSDMasterPattern, rotations: [SIMD4<Double>],
                              detector: EBSDDetectorGeometry, energy: Double? = nil, options: Options = Options()) throws -> Result {
        let pixels = detector.rows * detector.columns
        let exp = try experimentalSide(experimental, navigationShape: navigationShape, pixels: pixels, options: options)
        guard !rotations.isEmpty else { throw Error.emptyDictionary }
        let metal = usesMetal(options.backend, work: exp.indexed.count * rotations.count * exp.kept.count)
        return try run(exp, pixels: pixels, dictionarySize: rotations.count, rotations: rotations, navigationShape: navigationShape,
                       options: options) { s, e in
            let chunk = Array(rotations[s ..< e])
            if metal {
                return try MasterPatternProjection.patternsFloat32(master: master, rotations: chunk, detector: detector, energy: energy,
                                                                   backend: .metal).map(Double.init)
            }
            return try MasterPatternProjection.project(master: master, rotations: chunk, detector: detector, energy: energy, output: .float32).values
        }
    }

    /// `index(experimental:navigationShape:master:rotations:detector:energy:options:)` off the caller's actor (seconds to minutes).
    @concurrent package static func indexAsync(experimental: [Double], navigationShape: [Int], master: EBSDMasterPattern,
                                               rotations: [SIMD4<Double>], detector: EBSDDetectorGeometry, energy: Double? = nil,
                                               options: Options = Options()) async throws -> Result {
        try index(experimental: experimental, navigationShape: navigationShape, master: master, rotations: rotations,
                  detector: detector, energy: energy, options: options)
    }
}
