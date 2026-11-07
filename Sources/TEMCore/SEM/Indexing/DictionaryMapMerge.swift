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

        let sign: Float
        var meanN = meanNBest
        if let greaterIsBetter {
            sign = greaterIsBetter ? 1 : -1
        } else {
            sign = meanNBest < 0 ? -1 : 1
            meanN = abs(meanNBest)
        }
        // `[:, :mean_n_best]`: a negative stop counts from the end.
        let taken = meanN >= 0 ? min(meanN, keepN) : max(keepN + meanN, 0)
        guard taken > 0 else { throw Error.meanNBest(meanNBest) }

        // Scores as float32 (kikuchipy's dtype), NaN out of data.
        func score(_ map: Int, _ point: Int, _ n: Int) -> Float {
            let r = maps[map].result
            return r.isInData[point] ? Float(r.scores[point * keepN + n]) : .nan
        }

        var phaseIDs = [Int](repeating: 0, count: m)
        for p in 0 ..< m {
            var best: Float = .nan, bestMap = -1
            for i in 0 ..< k {
                var v: Float
                if taken == 1 {
                    v = score(i, p, 0)
                } else {
                    var sum: Float = 0, count = 0
                    for n in 0 ..< taken { let s = score(i, p, n); if !s.isNaN { sum += s; count += 1 } }
                    v = count > 0 ? sum / Float(count) : .nan
                }
                v *= sign
                if !v.isNaN, bestMap < 0 || v > best { best = v; bestMap = i }
            }
            guard bestMap >= 0 else { throw Error.noScoreAt(point: p) }
            phaseIDs[p] = bestMap
        }

        var phaseList = PhaseList()
        var rotations = [SIMD4<Double>](repeating: SIMD4(0, 0, 0, 0), count: m * keepN)
        var scores = [Double](repeating: 0, count: m * keepN)
        var indices = [Int](repeating: 0, count: m * keepN)
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
            let r = maps[i].result
            for p in points {
                for n in 0 ..< keepN {
                    rotations[p * keepN + n] = r.rotations[p * keepN + n]
                    scores[p * keepN + n] = Double(Float(r.scores[p * keepN + n]))
                    indices[p * keepN + n] = r.simulationIndices[p * keepN + n]
                }
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
                    let s = score(i, p, n)
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
                      rotations: rotations, scores: scores, simulationIndices: indices, mergedScores: mergedScores,
                      mergedSimulationIndices: mergedIndices)
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
