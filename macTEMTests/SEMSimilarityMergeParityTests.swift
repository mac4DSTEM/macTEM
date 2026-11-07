//
//  SEMSimilarityMergeParityTests.swift
//  TEMCore's orientation similarity map (`OrientationSimilarityMap`) and merge of dictionary-indexed maps
//  (`DictionaryMapMerge`) against kikuchipy 0.13.1's `orientation_similarity_map` and `merge_crystal_maps` in
//  tools/parity/sem/references/m4/:
//  - orientation-similarity-map: a 7 x 9 synthetic map (keep_n 6) with the defaults, n_best 5 to 2 normalised, a full 3 x 3
//    footprint, an even 2 x 2 footprint and a footprint whose centre index is a corner; and figure F9's whole 55 x 75 scan
//    from the committed dictionary-indexing bundle. Exact (float32).
//  - merge-crystal-maps: three synthetic 6 x 7 maps (keep_n 5, tied float32 scores): two phases, an equal repeated phase
//    with the mean of the best 3, a different phase of the same name (renamed), the lowest 2, navigation masks, the best match
//    alone (keep_n 1); and kikuchipy's OSM of each merge without masks on its merged simulation indices (the Indexing room's OSM
//    of several phases, D-SEM-98). Exact.
//  Red before the port: no `OrientationSimilarityMap` or `DictionaryMapMerge`. Red after: the origin of an even footprint at
//  0 instead of size // 2, counting shared indices with repeats, an unstable merge sort (ties change order), the increment
//  taken from the unshifted previous map, equal phases kept twice.
//

import Foundation
import TEMCore
import XCTest

nonisolated final class SEMSimilarityMergeParityTests: XCTestCase {

    private func ints(_ a: SEMParityReference.LoadedArray) -> [Int] { a.values.map { Int($0) } }

    /// The bundles store kikuchipy's NaN as -1 (a reference holds no NaN).
    private func noNaN(_ a: [Double]) -> [Double] { a.map { $0.isNaN ? -1 : $0 } }

    /// `fixtures/similarity_inputs.json`, the section of `key`.
    private func inputs(_ ref: SEMParityReference, _ key: String) throws -> [String: Any] {
        let data = try Data(contentsOf: try XCTUnwrap(ref.inputURL(0)))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(json[key] as? [String: Any])
    }

    // MARK: Orientation similarity map

    func testOrientationSimilarityMapMatchesKikuchipy() throws {
        let ref = try SEMParityReference.load("m4/orientation-similarity-map")
        let indices = ints(try ref.array("simulation_indices"))
        let runs = try XCTUnwrap(try inputs(ref, "orientation_similarity_map")["runs"] as? [String: [String: Any]])
        XCTAssertEqual(runs.count, 5)
        for (name, o) in runs {
            let footprint = (o["footprint"] as? [[Int]])?.map { $0.map { $0 != 0 } } ?? OrientationSimilarityMap.crossFootprint
            let result = try OrientationSimilarityMap.compute(
                simulationIndices: indices, keepN: 6, rows: 7, columns: 9, nBest: o["n_best"] as? Int,
                normalize: o["normalize"] as? Bool ?? false, fromNBest: o["from_n_best"] as? Int, footprint: footprint,
                centerIndex: o["center_index"] as? Int ?? 2)
            // kikuchipy's osm[:, :, i]: n interleaved per point.
            var flat: [Double] = []
            for p in 0 ..< 63 { for m in result.maps { flat.append(Double(m[p])) } }
            SEMAssertParity(noNaN(flat), try ref.array("\(name)_osm"))
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
        SEMAssertParity(noNaN(osm.maps[0].map(Double.init)), try ref.array("f9_osm"))
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
        let runs: [String: [String: Any]]
    }

    private func mergeInputs(_ ref: SEMParityReference) throws -> MergeInputs {
        var scores: [[Double]] = [], indices: [[Int]] = [], rotations: [[SIMD4<Double>]] = []
        for i in 0 ..< 3 {
            scores.append(try ref.array("map\(i)_scores").values)
            indices.append(ints(try ref.array("map\(i)_simulation_indices")))
            let q = try ref.array("map\(i)_rotations").values
            rotations.append(stride(from: 0, to: q.count, by: 4).map { SIMD4(q[$0], q[$0 + 1], q[$0 + 2], q[$0 + 3]) })
        }
        let cfg = try inputs(ref, "merge_crystal_maps")
        let table = try XCTUnwrap(cfg["phases"] as? [String: [String: Any]])
        var phases: [String: CrystalPhase] = [:]
        for (key, p) in table {
            phases[key] = CrystalPhase(name: try XCTUnwrap(p["name"] as? String), spaceGroup: p["space_group"] as? Int,
                                       pointGroup: "m-3m", lattice: try XCTUnwrap(p["lattice"] as? [Double]))
        }
        return MergeInputs(scores: scores, indices: indices, rotations: rotations, phases: phases,
                           runs: try XCTUnwrap(cfg["runs"] as? [String: [String: Any]]))
    }

    private func check(_ name: String, _ ref: SEMParityReference, _ inputs: MergeInputs) throws {
        let run = try XCTUnwrap(inputs.runs[name])
        let keys = try XCTUnwrap(run["maps"] as? [String])
        // keep_n 1: each map's best match alone (column 0 of its five).
        let keep = run["keep_n"] as? Int ?? 5
        let first = { (a: [Double]) in keep == 5 ? a : stride(from: 0, to: a.count, by: 5).map { a[$0] } }
        let options = run["options"] as? [String: Any] ?? [:]
        // masked_points: per map, the (row, column) of each point out of its data, or null.
        let masked = run["masked_points"] as? [Any] ?? []
        let maps = try keys.enumerated().map { i, key in
            var inData = Array(repeating: true, count: 42)
            if i < masked.count, let points = masked[i] as? [[Int]] {
                for p in points { inData[p[0] * 7 + p[1]] = false }
            }
            let columns = { (n: Int) in keep == 5 ? Array(0 ..< n) : Array(stride(from: 0, to: n, by: 5)) }(inputs.scores[i].count)
            return DictionaryMapMerge.Input(
                result: DictionaryIndexing.Result(navigationShape: [6, 7], keepN: keep, isInData: inData, scores: first(inputs.scores[i]),
                                                  simulationIndices: columns.map { inputs.indices[i][$0] },
                                                  rotations: columns.map { inputs.rotations[i][$0] }),
                phase: try XCTUnwrap(inputs.phases[key]))
        }
        let merged = try DictionaryMapMerge.merge(maps, meanNBest: options["mean_n_best"] as? Int ?? 1,
                                                  greaterIsBetter: options["greater_is_better"] as? Bool)
        SEMAssertParity(merged.phaseIDs.map(Double.init), try ref.array("\(name)_phase_id"))
        SEMAssertParity(merged.rotations.flatMap { [$0.x, $0.y, $0.z, $0.w] }, try ref.array("\(name)_rotations"))
        SEMAssertParity(merged.scores, try ref.array("\(name)_scores"))
        SEMAssertParity(merged.simulationIndices.map(Double.init), try ref.array("\(name)_simulation_indices"))
        SEMAssertParity(noNaN(merged.mergedScores), try ref.array("\(name)_merged_scores"))
        SEMAssertParity(noNaN(merged.mergedSimulationIndices), try ref.array("\(name)_merged_simulation_indices"))

        let map = try merged.crystalMap(stepSizes: [1, 1])
        let phases = try XCTUnwrap(ref.values["\(name)_phases"] as? [String: [String: String]])
        XCTAssertEqual(map.phases.ids, phases.keys.compactMap(Int.init).sorted(), name)
        for (id, p) in phases {
            XCTAssertEqual(map.phases[id: Int(id)!]?.name, p["name"], "\(name) phase \(id)")
            XCTAssertEqual(map.phases[id: Int(id)!]?.color, p["color"], "\(name) phase \(id)")
        }
        XCTAssertEqual(map.property("scores"), stride(from: 0, to: merged.scores.count, by: keep).map { merged.scores[$0] })

        // kikuchipy's OSM of the merged map on its merged simulation indices, every merged match (D-SEM-98).
        if run["masked_points"] == nil {
            let osm = try OrientationSimilarityMap.compute(simulationIndices: merged.mergedSimulationIndices.map { Int($0) },
                                                           keepN: keep * keys.count, rows: 6, columns: 7)
            SEMAssertParity(osm.maps[0].map(Double.init), try ref.array("\(name)_osm"))
        } else {
            XCTAssertNil(ref.manifest.arrays["\(name)_osm"], name)
        }
    }

    func testMergeMatchesKikuchipy() throws {
        let ref = try SEMParityReference.load("m4/merge-crystal-maps")
        let inputs = try mergeInputs(ref)
        XCTAssertEqual(inputs.runs.count, 6)
        for name in inputs.runs.keys.sorted() { try check(name, ref, inputs) }
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
