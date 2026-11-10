//
//  GrainOrientationStatistics.swift
//  Kernel average misorientation (KAM), the grain average orientation, the grain reference orientation deviation (GROD)
//  and the grain orientation spread (GOS) of an EBSD map, ported from DefDAP 1.3.1 (Apache-2.0, see NOTICE):
//  `ebsd.Map.calc_kam`, `quat.Quat.calc_average_ori`, `quat.Quat.calcMisOri`, `ebsd.Grain.build_mis_ori_list` and
//  `ebsd.Grain.calc_grod`. Wright, Nowell and Field 2011, Microsc. Microanal. 17, 316 (KAM, GROD, GOS).
//
//  KAM. DefDAP's `calc_kam` is kept as `.defdap` (its docstring: "Crystal symmetric equivalences are not considered"): the
//  mean of the |cosines| to the neighbours above and below, the mean to the left and right, the two averaged, 2 arccos.
//  On a map whose software stores symmetrically equivalent quaternions for neighbours of one grain that reads a large
//  angle inside a grain, so the port's default is `.symmetric`: the same four first neighbours, only those of the same
//  indexed phase, each angle the smallest over the phase's symmetry (as `find_boundaries` takes it), neighbours above the
//  threshold dropped (a boundary is not lattice curvature), the mean of the angles; NaN where no neighbour is kept or the
//  point is not indexed (D-SEM-55). Both are against the bundles.
//
//  GOS. DefDAP keeps per grain the mean of the |cosines| to its average orientation (`average_mis_ori`); the GOS of
//  Wright et al. is the mean GROD angle, which `gos` returns; `averageCosine` is DefDAP's number.
//
//  Parity: `tools/parity/sem` bundles `m5/grains-ti`, `m5/grains-ti-full` (figure F12) and `m5/grains-sdss`: KAM, GROD and
//  GOS atol 1e-6 rad, the grain average orientation atol 1e-10 (docs/parity.md).
//

import Foundation

package nonisolated enum KernelAverageMisorientation {
    package enum Method: Sendable, Equatable {
        /// DefDAP 1.3.1's `calc_kam`: no crystal symmetry, no phases, no threshold.
        case defdap
        /// First neighbours of the same phase, symmetric misorientation, those above `thresholdDegrees` dropped (nil: none).
        case symmetric(thresholdDegrees: Double?)
    }

    /// The KAM map in radians, row-major. `isCancelled` is asked before the pass and before each row of the symmetric one; it throws
    /// `CancellationError` once it says so (the Maps room's Stop).
    package static func map(_ map: GrainMap, method: Method = .symmetric(thresholdDegrees: 5), isCancelled: () -> Bool = { false }) throws -> [Double] {
        guard map.rows >= 2, map.columns >= 2 else { throw GrainMap.Refusal.tooSmall }
        if isCancelled() { throw CancellationError() }
        switch method {
        case .defdap: return defdap(map)
        case .symmetric(let t): return try symmetric(map, threshold: t.map { $0 * .pi / 180 }, isCancelled: isCancelled)
        }
    }

    private static func defdap(_ map: GrainMap) -> [Double] {
        let (h, w) = (map.rows, map.columns)
        let q = map.quaternions
        func d(_ i: Int, _ j: Int) -> Double { DefDAPQuat.absDot(q[i], q[j]) }
        var kam = [Double](repeating: 0, count: h * w)
        // Rows: the first and last with their one neighbour row, the others the mean of both; clipped at 1.
        for c in 0..<w {
            kam[c] = d(c, w + c)
            kam[(h - 1) * w + c] = d((h - 1) * w + c, (h - 2) * w + c)
        }
        for r in 1..<(h - 1) {
            for c in 0..<w {
                let i = r * w + c
                kam[i] = (d(i, i + w) + d(i, i - w)) / 2
            }
        }
        for i in kam.indices where kam[i] > 1 { kam[i] = 1 }
        // Columns, added.
        for r in 0..<h {
            kam[r * w] += d(r * w, r * w + 1)
            kam[r * w + w - 1] += d(r * w + w - 1, r * w + w - 2)
        }
        for c in 1..<(w - 1) {
            for r in 0..<h {
                let i = r * w + c
                kam[i] += (d(i, i + 1) + d(i, i - 1)) / 2
            }
        }
        for i in kam.indices {
            var k = kam[i] / 2
            if k > 1 { k = 1 }
            kam[i] = 2 * acos(k)
        }
        return kam
    }

    private static func symmetric(_ map: GrainMap, threshold: Double?, isCancelled: () -> Bool) throws -> [Double] {
        let (h, w) = (map.rows, map.columns)
        let q = map.quaternions, phase = map.phase
        var kam = [Double](repeating: .nan, count: h * w)
        for r in 0..<h {
            if isCancelled() { throw CancellationError() }
            for c in 0..<w {
                let i = r * w + c
                let p = phase[i]
                guard p > 0 else { continue }
                let ops = map.symmetries[p - 1]
                var sum = 0.0, n = 0
                for (rr, cc) in [(r - 1, c), (r + 1, c), (r, c - 1), (r, c + 1)] {
                    guard rr >= 0, rr < h, cc >= 0, cc < w else { continue }
                    let j = rr * w + cc
                    guard phase[j] == p else { continue }
                    var best = DefDAPQuat.absDot(q[j], q[i])
                    for s in ops.dropFirst() { best = max(best, DefDAPQuat.absDot(DefDAPQuat.symmetricEquivalent(q[j], s), q[i])) }
                    let a = 2 * acos(min(best, 1))
                    if let threshold, a > threshold { continue }
                    sum += a
                    n += 1
                }
                if n > 0 { kam[i] = sum / Double(n) }
            }
        }
        return kam
    }
}

/// Per grain: DefDAP's average orientation, each point's GROD angle and axis, GOS.
package nonisolated struct GrainOrientationStatistics: Sendable, Equatable {
    /// `Grain.ref_ori` per grain (northern hemisphere, unit).
    package let averageOrientations: [SIMD4<Double>]
    /// Per grain, per point in the grain's order: the GROD angle in radians.
    package let grod: [[Double]]
    /// Per grain, per point: DefDAP's GROD axis (`calc_grod`: 2 · arccos(dq₀) · (dq₁, dq₂, dq₃) / √(1 − dq₀²)).
    package let grodAxis: [[SIMD3<Double>]]
    /// DefDAP's `average_mis_ori`: the mean |cosine| of the points to the average.
    package let averageCosine: [Double]

    /// GOS per grain: the mean GROD angle, radians.
    package var gos: [Double] { grod.map { $0.isEmpty ? .nan : $0.reduce(0, +) / Double($0.count) } }

    /// The GOS of every point's grain as a map (radians), NaN outside the grains.
    package func gosMap(_ segmentation: GrainSegmentation) -> [Double] {
        let values = gos
        var out = [Double](repeating: .nan, count: segmentation.rows * segmentation.columns)
        for (g, grain) in segmentation.grains.enumerated() {
            for i in grain.points { out[i] = values[g] }
        }
        return out
    }

    package static func compute(_ map: GrainMap, segmentation: GrainSegmentation) -> GrainOrientationStatistics {
        // Never nil: nothing cancels it.
        compute(map, segmentation: segmentation, isCancelled: { false })!
    }

    /// The same, asking `isCancelled` before each grain: nil once it says so (the Maps room's Stop, `GrainAnalysis.run`).
    package static func compute(_ map: GrainMap, segmentation: GrainSegmentation, isCancelled: () -> Bool) -> GrainOrientationStatistics? {
        var averages: [SIMD4<Double>] = [], grods: [[Double]] = [], axes: [[SIMD3<Double>]] = [], cosines: [Double] = []
        for grain in segmentation.grains {
            if isCancelled() { return nil }
            let ops = grain.phaseIndex.map { map.symmetries[$0] } ?? [SIMD4(1, 0, 0, 0)]
            let eq = grain.points.map { DefDAPQuat.symmetricEquivalents(map.quaternions[$0], ops) }
            let ref = averageOrientation(eq)
            var angles: [Double] = [], axis: [SIMD3<Double>] = []
            angles.reserveCapacity(eq.count); axis.reserveCapacity(eq.count)
            var cosSum = 0.0
            let inv = SIMD4(ref[0], -ref[1], -ref[2], -ref[3])
            for e in eq {
                var best = 0, bestDot = -1.0
                for (s, qs) in e.enumerated() {
                    let d = DefDAPQuat.absDot(qs, ref)
                    if d > bestDot { bestDot = d; best = s }
                }
                let m = e[best]
                let c = min(bestDot, 1)
                cosSum += c
                angles.append(2 * acos(c))
                var dq = SIMD4(inv[0] * m[0] - inv[1] * m[1] - inv[2] * m[2] - inv[3] * m[3],
                               inv[1] * m[0] + inv[0] * m[1] + inv[3] * m[2] - inv[2] * m[3],
                               inv[2] * m[0] + inv[0] * m[2] + inv[1] * m[3] - inv[3] * m[1],
                               inv[3] * m[0] + inv[0] * m[3] + inv[2] * m[1] - inv[1] * m[2])
                if dq[0] < 0 { dq = -dq }
                let f = 2 * acos(dq[0]) / (1 - dq[0] * dq[0]).squareRoot()
                axis.append(SIMD3(dq[1], dq[2], dq[3]) * f)
            }
            averages.append(ref)
            grods.append(angles)
            axes.append(axis)
            cosines.append(eq.isEmpty ? .nan : cosSum / Double(eq.count))
        }
        return GrainOrientationStatistics(averageOrientations: averages, grod: grods, grodAxis: axes, averageCosine: cosines)
    }

    /// DefDAP's `Quat.calc_average_ori`: start from the first point's quaternion; for each next point add the symmetric
    /// equivalent closest to the running sum (the first largest |dot|); northern hemisphere, then normalised.
    package static func averageOrientation(_ equivalents: [[SIMD4<Double>]]) -> SIMD4<Double> {
        guard var sum = equivalents.first?.first else { return SIMD4(1, 0, 0, 0) }
        for e in equivalents.dropFirst() {
            var best = 0, bestDot = -1.0
            for (s, qs) in e.enumerated() {
                let d = DefDAPQuat.absDot(qs, sum)
                if d > bestDot { bestDot = d; best = s }
            }
            sum += e[best]
        }
        if sum[0] < 0 { sum = -sum }
        let norm = (sum[0] * sum[0] + sum[1] * sum[1] + sum[2] * sum[2] + sum[3] * sum[3]).squareRoot()
        return sum / norm
    }
}

/// The whole grain analysis of a map: boundaries, grains, the network, KAM and the grain orientation statistics.
package nonisolated struct GrainAnalysis: Sendable, Equatable {
    package let boundaries: GrainBoundaries
    package let segmentation: GrainSegmentation
    package let neighbours: [GrainNeighbour]
    package let kam: [Double]
    package let statistics: GrainOrientationStatistics

    /// The analysis; `isCancelled` is asked before each row of the boundaries and of KAM and before each grain of the flood fill and of
    /// the statistics, and it throws `CancellationError` once it says so (the Maps room's Stop). Not cancelled, every stage runs as it
    /// did, in the same order.
    package static func run(_ map: GrainMap, boundaryDegrees: Double = 10, minimumSize: Int = 10,
                            kam method: KernelAverageMisorientation.Method = .symmetric(thresholdDegrees: 5),
                            isCancelled: () -> Bool = { false }) throws -> GrainAnalysis {
        guard let boundaries = GrainBoundaries.find(in: map, thresholdDegrees: boundaryDegrees, isCancelled: isCancelled) else {
            throw CancellationError()
        }
        guard let segmentation = GrainSegmentation.find(in: map, boundaries: boundaries, minimumSize: minimumSize, isCancelled: isCancelled) else {
            throw CancellationError()
        }
        let neighbours = segmentation.neighbourNetwork(boundaries: boundaries)
        let kam = try KernelAverageMisorientation.map(map, method: method, isCancelled: isCancelled)
        guard let statistics = GrainOrientationStatistics.compute(map, segmentation: segmentation, isCancelled: isCancelled) else {
            throw CancellationError()
        }
        return GrainAnalysis(boundaries: boundaries, segmentation: segmentation, neighbours: neighbours, kam: kam, statistics: statistics)
    }
}
