//
//  DictionaryMapMerge.swift
//  kikuchipy 0.13.1's `merge_crystal_maps`: single-phase dictionary-indexing results of one scan merged into a multi-phase
//  map by their scores. Per point, the mean of each map's best `meanNBest` scores (float32 `np.nanmean`) decides the phase
//  (`np.nanargmax`, the first map on a tie; the lowest with a negative `meanNBest` or `greaterIsBetter` false); the point
//  takes that map's keep_n rotations, scores and simulation indices. Every map's scores per point are merge-sorted best first
//  over the n-major, map-minor order (`merged_scores`), and the simulation indices with them after each map's indices are
//  shifted past the previous map's (`abs(nanmax(previous) − nanmin(this)) + 1`, so an orientation similarity map can run on
//  them). Phases of the same name are one phase when they are equal and renamed with the map's index otherwise. A result
//  with points left out by its navigation mask enters as kikuchipy's navigation mask: NaN scores and indices there.
//  kikuchipy is GPL-3.0 (NOTICE). Parity: `m4/merge-crystal-maps` (exact).
//  D-SEM-88: phases are equal when name, space group, point group and lattice agree (`np.allclose`); the app's phases carry
//  no atoms, which kikuchipy also compares. kikuchipy's not-indexed step is a no-op with navigation masks (it assigns into a
//  copy) and dictionary results are always indexed, so it is left out. A single map, a single point, or a point out of
//  data in every map is refused (kikuchipy raises or squeezes the arrays to another shape).
//  `chosenMaps` and `picked` are its per-point steps; the Indexing room lands each block of a run against several phases with them
//  (D-SEM-98), on the scores as the run made them (float64 on the CPU, float32 on the GPU), where `merge` takes them as float32.
//

import Foundation

package nonisolated enum DictionaryMapMerge {
    package enum Error: Swift.Error, Equatable, Sendable, LocalizedError {
        case tooFewMaps
        case shapes
        case meanNBest(Int)
        case noScoreAt(point: Int)

        package var errorDescription: String? {
            switch self {
            case .tooFewMaps: "Merging needs at least two dictionary-indexed maps of more than one point."
            case .shapes: "The maps must have the same shape and the same number of matches per point."
            case .meanNBest(let n): "The mean of the best \(n) scores takes no score."
            case .noScoreAt(let p): "Point \(p) is out of the data in every map."
            }
        }
    }

    package struct Input: Sendable, Equatable {
        package var result: DictionaryIndexing.Result
        package var phase: CrystalPhase
        package init(result: DictionaryIndexing.Result, phase: CrystalPhase) { self.result = result; self.phase = phase }
    }

    package struct Merged: Sendable, Equatable {
        package var navigationShape: [Int]
        package var keepN: Int
        package var mapCount: Int
        /// The phase of each point as kikuchipy hands it to `CrystalMap` (the map's index, or the id of an equal phase).
        package var phaseIDs: [Int]
        /// The phase list kikuchipy builds (`PhaseList.add` in map order); `crystalMap` keys it to the data's ids as orix does.
        package var phaseList: PhaseList
        /// The chosen map's rotations, scores and simulation indices, point × keepN.
        package var rotations: [SIMD4<Double>]
        package var scores: [Double]
        package var simulationIndices: [Int]
        /// Every map's scores per point, best first, point × (keepN · maps); NaN where a map has the point out of data.
        package var mergedScores: [Double]
        /// The shifted simulation indices in the order of `mergedScores`.
        package var mergedSimulationIndices: [Double]

        /// The merged map as the app's `CrystalMap`: the best rotation, score and simulation index per point.
        package func crystalMap(stepSizes: [Double], scanUnit: String = "px") throws -> CrystalMap {
            let rows = navigationShape.count == 2 ? navigationShape[0] : 1
            let columns = navigationShape.last ?? 0
            let dy = stepSizes.count == 2 ? stepSizes[0] : 1, dx = stepSizes.last ?? 1
            let (x, y) = CrystalMap.coordinates(shape: (rows, columns), steps: (dy, dx))
            let best = { (a: [Double]) in stride(from: 0, to: a.count, by: keepN).map { a[$0] } }
            return try CrystalMap(rotations: stride(from: 0, to: rotations.count, by: keepN).map { rotations[$0] }, phaseIDs: phaseIDs,
                                  x: x, y: navigationShape.count == 2 ? y : nil, phaseList: phaseList,
                                  properties: ["scores": best(scores), "simulation_indices": best(simulationIndices.map(Double.init))],
                                  scanUnit: scanUnit)
        }
    }

    /// `merge_crystal_maps(maps, mean_n_best, greater_is_better, simulation_indices_prop="simulation_indices")`.
    package static func merge(_ maps: [Input], meanNBest: Int = 1, greaterIsBetter: Bool? = nil) throws -> Merged {
        guard maps.count >= 2 else { throw Error.tooFewMaps }
        let shape = maps[0].result.navigationShape, keepN = maps[0].result.keepN
        guard maps.allSatisfy({ $0.result.navigationShape == shape && $0.result.keepN == keepN }) else { throw Error.shapes }
        let m = maps[0].result.pointCount, k = maps.count
        guard m >= 2 else { throw Error.tooFewMaps }
        let (sign, _) = try ordering(meanNBest: meanNBest, greaterIsBetter: greaterIsBetter, keepN: keepN)

        let choice = try chosenMaps(maps, meanNBest: meanNBest, greaterIsBetter: greaterIsBetter, float32: true)
        var phaseIDs = [Int](repeating: 0, count: m)
        for p in 0 ..< m {
            guard let i = choice[p] else { throw Error.noScoreAt(point: p) }
            phaseIDs[p] = i
        }
        let best = picked(maps, choice: choice, float32: true)

        var phaseList = PhaseList()
        let chosen = phaseIDs
        for i in 0 ..< k {
            let points = (0 ..< m).filter { chosen[$0] == i }
            guard !points.isEmpty else { continue }
            var phase = maps[i].phase
            if let existingID = phaseList.id(named: phase.name), let existing = phaseList[id: existingID] {
                if equal(phase, existing) {
                    for p in points { phaseIDs[p] = existingID }
                } else {
                    phase.name += String(i)
                    phaseList.set(phase, id: (phaseList.ids.max() ?? -1) + 1)
                }
            } else {
                phaseList.set(phase, id: (phaseList.ids.max() ?? -1) + 1)
            }
        }

        // Shifted indices, map by map (`comb_sim_idx[..., i] += increment` on the already shifted previous map).
        var shifted: [[Double]] = maps.map { input in
            let r = input.result
            return (0 ..< m * keepN).map { r.isInData[$0 / keepN] ? Double(r.simulationIndices[$0]) : .nan }
        }
        for i in 1 ..< k {
            let previousMax = shifted[i - 1].filter { !$0.isNaN }.max() ?? .nan
            let thisMin = shifted[i].filter { !$0.isNaN }.min() ?? .nan
            let increment = abs(previousMax - thisMin) + 1
            shifted[i] = shifted[i].map { $0 + increment }
        }

        // Stable sort of sign · −score over n-major, map-minor order, NaN last.
        let width = keepN * k
        var mergedScores = [Double](repeating: .nan, count: m * width)
        var mergedIndices = [Double](repeating: .nan, count: m * width)
        for p in 0 ..< m {
            var entries: [(key: Float, score: Float, index: Double)] = []
            entries.reserveCapacity(width)
            for n in 0 ..< keepN {
                for i in 0 ..< k {
                    let s: Float = score(maps, i, p, n, keepN: keepN)
                    entries.append((sign * -s, s, shifted[i][p * keepN + n]))
                }
            }
            let order = entries.indices.sorted { a, b in
                let x = entries[a].key, y = entries[b].key
                if x.isNaN != y.isNaN { return !x.isNaN }
                if !x.isNaN, x != y { return x < y }
                return a < b
            }
            for (j, e) in order.enumerated() {
                mergedScores[p * width + j] = Double(entries[e].score)
                mergedIndices[p * width + j] = entries[e].index
            }
        }

        return Merged(navigationShape: shape, keepN: keepN, mapCount: k, phaseIDs: phaseIDs, phaseList: phaseList,
                      rotations: best.rotations, scores: best.scores, simulationIndices: best.simulationIndices,
                      mergedScores: mergedScores, mergedSimulationIndices: mergedIndices)
    }

    /// Each point's map: `np.nanargmax` of sign × the mean of each map's best `meanNBest` scores (`np.nanmean`), the first map on a
    /// tie; nil where no map scores the point (out of every map's data, or NaN in each), where kikuchipy raises. `float32` takes the
    /// scores and their mean as float32 (`merge`, kikuchipy's dtype for the bundles' maps); else as they are, float64, which is
    /// kikuchipy's comparison for float64 maps (the Indexing room's CPU runs; a GPU run's scores are float32 values already). A
    /// point's choice reads only its own scores, so a block of rows gets the choice the whole scan gives it (D-SEM-98).
    package static func chosenMaps(_ maps: [Input], meanNBest: Int = 1, greaterIsBetter: Bool? = nil, float32: Bool) throws -> [Int?] {
        guard let first = maps.first else { throw Error.tooFewMaps }
        let shape = first.result.navigationShape, keepN = first.result.keepN
        guard maps.allSatisfy({ $0.result.navigationShape == shape && $0.result.keepN == keepN && $0.result.scores.count == $0.result.pointCount * keepN })
        else { throw Error.shapes }
        let (sign, taken) = try ordering(meanNBest: meanNBest, greaterIsBetter: greaterIsBetter, keepN: keepN)
        return float32 ? choose(maps, sign: sign, taken: taken, keepN: keepN)
            : choose(maps, sign: Double(sign), taken: taken, keepN: keepN)
    }

    /// The chosen map's keep_n rotations, scores and simulation indices at each point, as `merge` hands them to the merged map (scores
    /// as float32 with `float32`, else as they are); a point without a choice keeps the first map's. `isInData` is the chosen map's.
    package static func picked(_ maps: [Input], choice: [Int?], float32: Bool) -> DictionaryIndexing.Result {
        guard let first = maps.first?.result else {
            return DictionaryIndexing.Result(navigationShape: [0], keepN: 1, isInData: [], scores: [], simulationIndices: [], rotations: [])
        }
        let keepN = first.keepN
        var best = first
        for p in 0 ..< min(first.pointCount, choice.count) {
            let i = choice[p] ?? 0
            guard maps.indices.contains(i) else { continue }
            let r = maps[i].result
            best.isInData[p] = r.isInData[p]
            for n in 0 ..< keepN {
                let j = p * keepN + n
                best.rotations[j] = r.rotations[j]
                best.scores[j] = r.scores[j]
                best.simulationIndices[j] = r.simulationIndices[j]
            }
        }
        if float32 { best.scores = best.scores.map { Double(Float($0)) } }
        return best
    }

    /// kikuchipy's sign and the count of best scores the choice averages (`greater_is_better`, `mean_n_best`; a negative stop counts
    /// from the end, as `[:, :mean_n_best]` does).
    private static func ordering(meanNBest: Int, greaterIsBetter: Bool?, keepN: Int) throws -> (sign: Float, taken: Int) {
        let sign: Float
        var meanN = meanNBest
        if let greaterIsBetter {
            sign = greaterIsBetter ? 1 : -1
        } else {
            sign = meanNBest < 0 ? -1 : 1
            meanN = abs(meanNBest)
        }
        let taken = meanN >= 0 ? min(meanN, keepN) : max(keepN + meanN, 0)
        guard taken > 0 else { throw Error.meanNBest(meanNBest) }
        return (sign, taken)
    }

    /// A map's score at a point in `T` (Float: kikuchipy's float32 dtype); NaN out of the data.
    private static func score<T: BinaryFloatingPoint>(_ maps: [Input], _ map: Int, _ point: Int, _ n: Int, keepN: Int) -> T {
        let r = maps[map].result
        return r.isInData[point] ? T(r.scores[point * keepN + n]) : .nan
    }

    private static func choose<T: BinaryFloatingPoint>(_ maps: [Input], sign: T, taken: Int, keepN: Int) -> [Int?] {
        let m = maps[0].result.pointCount
        var out = [Int?](repeating: nil, count: m)
        for p in 0 ..< m {
            var best: T = .nan, bestMap = -1
            for i in maps.indices {
                var v: T
                if taken == 1 {
                    v = score(maps, i, p, 0, keepN: keepN)
                } else {
                    var sum: T = 0, count = 0
                    for n in 0 ..< taken {
                        let s: T = score(maps, i, p, n, keepN: keepN)
                        if !s.isNaN { sum += s; count += 1 }
                    }
                    v = count > 0 ? sum / T(count) : .nan
                }
                v *= sign
                if !v.isNaN, bestMap < 0 || v > best { best = v; bestMap = i }
            }
            out[p] = bestMap >= 0 ? bestMap : nil
        }
        return out
    }

    /// kikuchipy's `_equal_phase` on what the app's phases carry: name, space group, point group, lattice (`np.allclose`).
    static func equal(_ a: CrystalPhase, _ b: CrystalPhase) -> Bool {
        guard a.name == b.name, a.spaceGroup == b.spaceGroup, a.pointGroupName == b.pointGroupName else { return false }
        switch (a.lattice, b.lattice) {
        case (nil, nil): return true
        case let (x?, y?):
            return x.count == y.count && zip(x, y).allSatisfy { abs($0 - $1) <= 1e-8 + 1e-5 * abs($1) }
        default: return false
        }
    }
}
