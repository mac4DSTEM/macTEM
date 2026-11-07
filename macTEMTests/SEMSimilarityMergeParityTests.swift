//
//  SEMSimilarityMergeParityTests.swift
//  TEMCore's orientation similarity map (`OrientationSimilarityMap`) and merge of dictionary-indexed maps
//  (`DictionaryMapMerge`) against kikuchipy 0.13.1's `orientation_similarity_map` and `merge_crystal_maps` in
//  tools/parity/sem/references/m4/:
//  - orientation-similarity-map: a 7 x 9 synthetic map (keep_n 6) with the defaults, n_best 5 to 2 normalised, a full 3 x 3
//    footprint, an even 2 x 2 footprint and a footprint whose centre index is a corner; and figure F9's whole 55 x 75 scan
//    from the committed dictionary-indexing bundle. Exact (float32).
//  - merge-crystal-maps: three synthetic 6 x 7 maps (keep_n 5, tied float32 scores): two phases, an equal repeated phase
//    with the mean of the best 3, a different phase of the same name (renamed), the lowest 2, navigation masks. Exact.
//  Red before the port: no `OrientationSimilarityMap` or `DictionaryMapMerge`. Red after: the origin of an even footprint at
//  0 instead of size // 2, counting shared indices with repeats, an unstable merge sort (ties change order), the increment
//  taken from the unshifted previous map, equal phases kept twice.
//

import Foundation
import TEMCore
import XCTest

nonisolated final class SEMSimilarityMergeParityTests: XCTestCase {

    private func ints(_ a: SEMParityReference.LoadedArray) -> [Int] { a.values.map { Int($0) } }

    // MARK: Orientation similarity map

    func testOrientationSimilarityMapMatchesKikuchipy() throws {
        let ref = try SEMParityReference.load("m4/orientation-similarity-map")
        let indices = ints(try ref.array("simulation_indices"))
        for name in ["default", "range", "square", "even", "corner"] {
            let o = try XCTUnwrap(ref.values["\(name)_options"] as? [String: Any])
            let footprint = (o["footprint"] as? [[Int]])?.map { $0.map { $0 != 0 } } ?? OrientationSimilarityMap.crossFootprint
            let result = try OrientationSimilarityMap.compute(
                simulationIndices: indices, keepN: 6, rows: 7, columns: 9, nBest: o["n_best"] as? Int,
                normalize: o["normalize"] as? Bool ?? false, fromNBest: o["from_n_best"] as? Int, footprint: footprint,
                centerIndex: o["center_index"] as? Int ?? 2)
            // kikuchipy's osm[:, :, i]: n interleaved per point.
            var flat: [Double] = []
            for p in 0 ..< 63 { for m in result.maps { flat.append(Double(m[p])) } }
            SEMAssertParity(flat, try ref.array("\(name)_osm"))
        }
    }

    func testOrientationSimilarityMapOfFigureF9() throws {
        let ref = try SEMParityReference.load("m4/orientation-similarity-map")
        let f9 = try SEMParityReference.load("m4/dictionary-indexing-nickel-ebsd-large")
        let indices = ints(try f9.array("ncc_simulation_indices"))
        let result = DictionaryIndexing.Result(navigationShape: [55, 75], keepN: 5, isInData: Array(repeating: true, count: 4125),
                                               scores: Array(repeating: 0, count: indices.count), simulationIndices: indices,
                                               rotations: Array(repeating: SIMD4(1, 0, 0, 0), count: indices.count))
        let osm = try result.orientationSimilarityMap()
        XCTAssertEqual(osm.n, [5])
        SEMAssertParity(osm.maps[0].map(Double.init), try ref.array("f9_osm"))
    }

    func testOrientationSimilarityMapRefusals() throws {
        let line = DictionaryIndexing.Result(navigationShape: [4], keepN: 1, isInData: [true, true, true, true], scores: [0, 0, 0, 0],
                                             simulationIndices: [0, 1, 2, 3], rotations: Array(repeating: SIMD4(1, 0, 0, 0), count: 4))
        XCTAssertThrowsError(try line.orientationSimilarityMap()) {
            XCTAssertEqual($0 as? OrientationSimilarityMap.Error, .notAMap(shape: [4]))
        }
        var masked = line
        masked.navigationShape = [2, 2]
        masked.isInData[1] = false
        XCTAssertThrowsError(try masked.orientationSimilarityMap()) {
            XCTAssertEqual($0 as? OrientationSimilarityMap.Error, .pointsNotInData)
        }
        XCTAssertThrowsError(try OrientationSimilarityMap.compute(simulationIndices: [0, 1, 2, 3], keepN: 1, rows: 2, columns: 2, nBest: 2))
    }

    // MARK: Merge

    private struct MergeInputs {
        let scores: [[Double]]
        let indices: [[Int]]
        let rotations: [[SIMD4<Double>]]
        let phases: [String: CrystalPhase]
    }

    private func mergeInputs(_ ref: SEMParityReference) throws -> MergeInputs {
        var scores: [[Double]] = [], indices: [[Int]] = [], rotations: [[SIMD4<Double>]] = []
        for i in 0 ..< 3 {
            scores.append(try ref.array("map\(i)_scores").values)
            indices.append(ints(try ref.array("map\(i)_simulation_indices")))
            let q = try ref.array("map\(i)_rotations").values
            rotations.append(stride(from: 0, to: q.count, by: 4).map { SIMD4(q[$0], q[$0 + 1], q[$0 + 2], q[$0 + 3]) })
        }
        let table = try XCTUnwrap(ref.values["phases"] as? [String: [String: Any]])
        var phases: [String: CrystalPhase] = [:]
        for (key, p) in table {
            phases[key] = CrystalPhase(name: try XCTUnwrap(p["name"] as? String), spaceGroup: p["space_group"] as? Int,
                                       pointGroup: "m-3m", lattice: try XCTUnwrap(p["lattice"] as? [Double]))
        }
        return MergeInputs(scores: scores, indices: indices, rotations: rotations, phases: phases)
    }

    private func check(_ name: String, _ ref: SEMParityReference, _ inputs: MergeInputs, masks: [[Bool]?] = [nil, nil, nil],
                       meanNBest: Int = 1, greaterIsBetter: Bool? = nil) throws {
        let keys = try XCTUnwrap(ref.values["\(name)_maps"] as? [String])
        let maps = try keys.enumerated().map { i, key in
            let inData = masks[i].map { $0.map { !$0 } } ?? Array(repeating: true, count: 42)
            return DictionaryMapMerge.Input(
                result: DictionaryIndexing.Result(navigationShape: [6, 7], keepN: 5, isInData: inData, scores: inputs.scores[i],
                                                  simulationIndices: inputs.indices[i], rotations: inputs.rotations[i]),
                phase: try XCTUnwrap(inputs.phases[key]))
        }
        let merged = try DictionaryMapMerge.merge(maps, meanNBest: meanNBest, greaterIsBetter: greaterIsBetter)
        SEMAssertParity(merged.phaseIDs.map(Double.init), try ref.array("\(name)_phase_id"))
        SEMAssertParity(merged.rotations.flatMap { [$0.x, $0.y, $0.z, $0.w] }, try ref.array("\(name)_rotations"))
        SEMAssertParity(merged.scores, try ref.array("\(name)_scores"))
        SEMAssertParity(merged.simulationIndices.map(Double.init), try ref.array("\(name)_simulation_indices"))
        SEMAssertParity(merged.mergedScores, try ref.array("\(name)_merged_scores"))
        SEMAssertParity(merged.mergedSimulationIndices, try ref.array("\(name)_merged_simulation_indices"))

        let map = try merged.crystalMap(stepSizes: [1, 1])
        let phases = try XCTUnwrap(ref.values["\(name)_phases"] as? [String: [String: String]])
        XCTAssertEqual(map.phases.ids, phases.keys.compactMap(Int.init).sorted(), name)
        for (id, p) in phases {
            XCTAssertEqual(map.phases[id: Int(id)!]?.name, p["name"], "\(name) phase \(id)")
            XCTAssertEqual(map.phases[id: Int(id)!]?.color, p["color"], "\(name) phase \(id)")
        }
        XCTAssertEqual(map.property("scores"), stride(from: 0, to: merged.scores.count, by: 5).map { merged.scores[$0] })
    }

    func testMergeMatchesKikuchipy() throws {
        let ref = try SEMParityReference.load("m4/merge-crystal-maps")
        let inputs = try mergeInputs(ref)
        try check("two", ref, inputs)
        try check("equal", ref, inputs, meanNBest: 3)
        try check("renamed", ref, inputs)
        try check("lowest", ref, inputs, meanNBest: -2)
        let masks: [[Bool]?] = [try ref.array("masked_mask0").values.map { $0 != 0 }, nil,
                                try ref.array("masked_mask2").values.map { $0 != 0 }]
        try check("masked", ref, inputs, masks: masks, greaterIsBetter: true)
    }

    func testMergeRefusals() throws {
        let r = DictionaryIndexing.Result(navigationShape: [2], keepN: 1, isInData: [true, false], scores: [0.5, .nan],
                                          simulationIndices: [0, -1], rotations: [SIMD4(1, 0, 0, 0), SIMD4(1, 0, 0, 0)])
        let phase = CrystalPhase(name: "ni", spaceGroup: 225, pointGroup: "m-3m")
        XCTAssertThrowsError(try DictionaryMapMerge.merge([.init(result: r, phase: phase)])) {
            XCTAssertEqual($0 as? DictionaryMapMerge.Error, .tooFewMaps)
        }
        XCTAssertThrowsError(try DictionaryMapMerge.merge([.init(result: r, phase: phase), .init(result: r, phase: phase)])) {
            XCTAssertEqual($0 as? DictionaryMapMerge.Error, .noScoreAt(point: 1))
        }
        XCTAssertThrowsError(try DictionaryMapMerge.merge([.init(result: r, phase: phase), .init(result: r, phase: phase)], meanNBest: 0)) {
            XCTAssertEqual($0 as? DictionaryMapMerge.Error, .meanNBest(0))
        }
    }
}
