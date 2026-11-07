//
//  IndexingDictionaryPhasesTests.swift
//  Dictionary indexing against several phases in the Indexing room (#231, D-SEM-98): `IndexingResult.land(_:rows:)` with one result
//  per phase lands each block as kikuchipy 0.13.1's `merge_crystal_maps` merges the phases' maps, held to the bundle
//  `m4/merge-crystal-maps` (synthetic 6 × 7 maps, keep_n 5): two phases, three phases with one renamed (ni2), the best match alone
//  (keep_n 1). Each point's phase, the chosen phase's matches, the crystal map and the orientation similarity map (kikuchipy's on the
//  merged map's simulation indices) exact, on the rows landed after each block as on the whole map. Then the room's own cases: a point
//  no phase scores, phases tied at every point (F9's matches twice: the first phase everywhere, the OSM twice F9's), the choice on
//  the scores as the run made them (float64) where `merge` compares them as float32.
//  Red before: a block of several phases was dropped. Red when a tie takes the last phase, when the OSM's indices of two phases
//  collide, when a phase that wins no point stays in the crystal map's list, when the choice rounds the scores to float32.
//

import Foundation
import TEMCore
import XCTest

nonisolated final class IndexingDictionaryPhasesTests: XCTestCase {

    private let rows = 6, columns = 7

    /// The room's phases of the bundle's maps: ni, al and the other ni, which the room's list holds as ni2 (kikuchipy renames it so),
    /// in orix's colours.
    private let ni = IndexingPhase(name: "ni", spaceGroup: 225, lattice: [3.52, 3.52, 3.52, 90, 90, 90], source: .preset, color: "tab:blue")
    private let al = IndexingPhase(name: "al", spaceGroup: 225, lattice: [4.05, 4.05, 4.05, 90, 90, 90], source: .preset, color: "tab:orange")
    private let ni2 = IndexingPhase(name: "ni2", spaceGroup: 225, lattice: [3.6, 3.6, 3.6, 90, 90, 90], source: .preset, color: "tab:green")

    private func ints(_ a: SEMParityReference.LoadedArray) -> [Int] { a.values.map { Int($0) } }

    /// The bundle's map `i` (6 × 7, keep_n 5) as kikuchipy's result; with `keep` 1 each point's best match alone.
    private func kikuchipyMap(_ ref: SEMParityReference, _ i: Int, keep: Int) throws -> DictionaryIndexing.Result {
        let scores = try ref.array("map\(i)_scores").values
        let indices = ints(try ref.array("map\(i)_simulation_indices"))
        let q = try ref.array("map\(i)_rotations").values
        let rotations = stride(from: 0, to: q.count, by: 4).map { SIMD4(q[$0], q[$0 + 1], q[$0 + 2], q[$0 + 3]) }
        let kept = (0 ..< (rows * columns)).flatMap { p in (0 ..< keep).map { p * 5 + $0 } }
        return DictionaryIndexing.Result(navigationShape: [rows, columns], keepN: keep, isInData: Array(repeating: true, count: rows * columns),
                                         scores: kept.map { scores[$0] }, simulationIndices: kept.map { indices[$0] },
                                         rotations: kept.map { rotations[$0] })
    }

    /// Rows `range` of a map of `width` columns, as a block of a run lands.
    private func block(_ r: DictionaryIndexing.Result, _ range: Range<Int>, width: Int) -> DictionaryIndexing.Result {
        let keep = r.keepN, a = range.lowerBound * width, b = range.upperBound * width
        return DictionaryIndexing.Result(navigationShape: [range.count, width], keepN: keep, isInData: Array(r.isInData[a ..< b]),
                                         scores: Array(r.scores[(a * keep) ..< (b * keep)]),
                                         simulationIndices: Array(r.simulationIndices[(a * keep) ..< (b * keep)]),
                                         rotations: Array(r.rotations[(a * keep) ..< (b * keep)]))
    }

    /// Lands the bundle's maps as a run against `phases` landing blocks `blocks`, and holds it to kikuchipy's merge of run `name`.
    private func check(_ name: String, phases: [IndexingPhase], keep: Int, blocks: [Range<Int>]) throws {
        let ref = try SEMParityReference.load("m4/merge-crystal-maps")
        let maps = try phases.indices.map { try kikuchipyMap(ref, $0, keep: keep) }
        var result = IndexingResult(scanRows: rows, scanColumns: columns, phases: phases, metric: .ncc)
        for range in blocks {
            result.land(maps.map { block($0, range, width: columns) }, rows: range)
            XCTAssertEqual(result.rowsDone, range.upperBound, name)
            // The rows landed: kikuchipy's OSM of the merge of those rows (every merged match, the four nearest neighbours).
            let landed = try DictionaryMapMerge.merge(zip(maps, phases).map {
                DictionaryMapMerge.Input(result: block($0, 0 ..< range.upperBound, width: columns), phase: $1.crystalPhase)
            })
            let osm = try OrientationSimilarityMap.compute(simulationIndices: landed.mergedSimulationIndices.map { Int($0) },
                                                           keepN: keep * phases.count, rows: range.upperBound, columns: columns)
            XCTAssertEqual(Array(result.similarity[0 ..< (range.upperBound * columns)]), osm.maps[0], "\(name), \(range.upperBound) rows")
            XCTAssertTrue(result.similarity[(range.upperBound * columns)...].allSatisfy(\.isNaN), "\(name): rows not landed have no OSM")
        }
        XCTAssertTrue(result.isComplete, name)

        // Each point: the phase kikuchipy picks, that phase's best rotation and score.
        let phaseIDs = ints(try ref.array("\(name)_phase_id"))
        let solutions = result.solutions.compactMap { $0 }
        XCTAssertEqual(solutions.count, rows * columns)
        XCTAssertEqual(solutions.map(\.phase), phaseIDs, name)
        let merged = try XCTUnwrap(result.dictionary, name)
        XCTAssertEqual(merged.keepN, keep)
        XCTAssertEqual(merged.navigationShape, [rows, columns])
        SEMAssertParity(merged.scores, try ref.array("\(name)_scores"))
        SEMAssertParity(merged.simulationIndices.map(Double.init), try ref.array("\(name)_simulation_indices"))
        SEMAssertParity(merged.rotations.flatMap { [$0.x, $0.y, $0.z, $0.w] }, try ref.array("\(name)_rotations"))
        XCTAssertEqual(solutions.map(\.confidence), merged.bestScores, name)
        XCTAssertEqual(solutions.map(\.quaternion), merged.bestRotations, name)
        XCTAssertEqual(result.phaseSimulationIndices, maps.map(\.simulationIndices), "each phase's own matches, for the OSM")
        SEMAssertParity(result.similarity.map(Double.init), try ref.array("\(name)_osm"))
        XCTAssertEqual(result.countsByPhase, phases.indices.map { p in phaseIDs.filter { $0 == p }.count })

        // The crystal map is kikuchipy's merged map: ids, rotations, best scores and indices, the phase list's names and colours.
        let xmap = try XCTUnwrap(try result.crystalMap(steps: (1, 1), scanUnit: "px"))
        let kikuchipy = try DictionaryMapMerge.merge(zip(maps, phases).map { DictionaryMapMerge.Input(result: $0, phase: $1.crystalPhase) })
            .crystalMap(stepSizes: [1, 1])
        XCTAssertEqual(xmap.allPhaseIDs, kikuchipy.allPhaseIDs, name)
        XCTAssertEqual(xmap.rotations, kikuchipy.rotations, name)
        XCTAssertEqual(xmap.property("scores"), kikuchipy.property("scores"), name)
        XCTAssertEqual(xmap.property("simulation_indices"), kikuchipy.property("simulation_indices"), name)
        XCTAssertEqual(xmap.allX, kikuchipy.allX)
        XCTAssertEqual(xmap.allY, kikuchipy.allY)
        let listed = try XCTUnwrap(ref.values["\(name)_phases"] as? [String: [String: String]])
        XCTAssertEqual(xmap.phases.ids, listed.keys.compactMap(Int.init).sorted(), name)
        for (id, p) in listed {
            XCTAssertEqual(xmap.phases[id: Int(id)!]?.name, p["name"], "\(name) phase \(id)")
            XCTAssertEqual(xmap.phases[id: Int(id)!]?.color, p["color"], "\(name) phase \(id)")
        }

        // The status line, the Results rows and the CSV name each point's phase.
        let english = Locale(identifier: "en_US_POSIX")
        let csv = result.csv(stepX: 1, stepY: 1).split(separator: "\n")
        for p in [0, 9, 41] {
            let position = EBSDPosition(row: p / columns, column: p % columns)
            let words = phases[phaseIDs[p]].name
            XCTAssertTrue(try XCTUnwrap(result.readout(at: position, locale: english)).contains(" · \(words) · φ₁"), "\(name) point \(p)")
            XCTAssertEqual(result.rows[p].phase, words)
            XCTAssertEqual(result.rows[p].simulationIndex, merged.simulationIndices[p * keep])
            XCTAssertEqual(csv[p + 1].split(separator: ",", omittingEmptySubsequences: false)[4], Substring(words))
        }
    }

    // MARK: - Against kikuchipy's merge

    func testTwoPhasesLandAsKikuchipysMergeCrystalMaps() throws {
        try check("two", phases: [ni, al], keep: 5, blocks: [0 ..< 1, 1 ..< 4, 4 ..< 6])
    }

    func testThreePhasesLandAsKikuchipysMergeCrystalMaps() throws {
        try check("renamed", phases: [ni, al, ni2], keep: 5, blocks: [0 ..< 3, 3 ..< 6])
    }

    /// Keep 1: each phase's best match alone (kikuchipy's `merge_crystal_maps` raises on (M, 1) properties; the bundle's run hands it
    /// 1-D ones, the room keeps 1 as one column).
    func testTheBestMatchAloneLandsAsKikuchipysMerge() throws {
        try check("best", phases: [ni, al, ni2], keep: 1, blocks: [0 ..< 6])
    }

    /// A block that is not one result per phase, or that does not follow, is dropped; so is a block of one phase's result.
    func testABlockThatDoesNotFitIsDropped() throws {
        let ref = try SEMParityReference.load("m4/merge-crystal-maps")
        let maps = try (0 ..< 2).map { try kikuchipyMap(ref, $0, keep: 5) }
        var result = IndexingResult(scanRows: rows, scanColumns: columns, phases: [ni, al], metric: .ncc)
        result.land([block(maps[0], 0 ..< 2, width: columns)], rows: 0 ..< 2)
        result.land(block(maps[0], 0 ..< 2, width: columns), rows: 0 ..< 2)
        result.land(maps.map { block($0, 2 ..< 4, width: columns) }, rows: 2 ..< 4)
        result.land([block(maps[0], 0 ..< 2, width: columns), block(maps[1], 0 ..< 3, width: columns)], rows: 0 ..< 2)
        XCTAssertEqual(result.rowsDone, 0)
        XCTAssertNil(result.dictionary)
        result.land(maps.map { block($0, 0 ..< 2, width: columns) }, rows: 0 ..< 2)
        XCTAssertEqual(result.rowsDone, 2)
        let single = try (0 ..< 2).map { try kikuchipyMap(ref, $0, keep: 1) }
        result.land(single.map { block($0, 2 ..< 4, width: columns) }, rows: 2 ..< 4)
        XCTAssertEqual(result.rowsDone, 2, "a block of another keep_n")
    }

    // MARK: - The room's own cases

    /// A point no phase scores (no contrast: NaN in every dictionary, where kikuchipy's `nanargmax` raises) is not indexed; a phase
    /// that does not score a point, or has it out of its data, leaves it to the others.
    func testAPointNoPhaseScoresIsNotIndexed() throws {
        let one = SIMD4<Double>(1, 0, 0, 0), half = SIMD4<Double>(0, 1, 0, 0)
        let a = DictionaryIndexing.Result(navigationShape: [2, 2], keepN: 1, isInData: [true, true, true, true],
                                          scores: [.nan, .nan, 0.5, 0.2], simulationIndices: [3, 4, 5, 6], rotations: [one, one, one, one])
        let b = DictionaryIndexing.Result(navigationShape: [2, 2], keepN: 1, isInData: [true, true, true, false],
                                          scores: [.nan, 0.3, .nan, 0.9], simulationIndices: [7, 8, 9, 10], rotations: [half, half, half, half])
        XCTAssertThrowsError(try DictionaryMapMerge.merge([.init(result: a, phase: ni.crystalPhase), .init(result: b, phase: al.crystalPhase)])) {
            XCTAssertEqual($0 as? DictionaryMapMerge.Error, .noScoreAt(point: 0), "kikuchipy raises")
        }
        var result = IndexingResult(scanRows: 2, scanColumns: 2, phases: [ni, al], metric: .ncc)
        result.land([a, b], rows: 0 ..< 2)
        let solutions = result.solutions.compactMap { $0 }
        XCTAssertEqual(solutions.map(\.phase), [-1, 1, 0, 0])
        XCTAssertEqual(solutions.map(\.confidence), [0, 0.3, 0.5, 0.2])
        XCTAssertEqual(solutions.map(\.quaternion), [one, half, one, one])
        XCTAssertEqual(result.countsByPhase, [2, 1])
        XCTAssertEqual(result.indexedCount, 3)
        XCTAssertEqual(result.readout(at: EBSDPosition(row: 0, column: 0)), "row 0 · col 0 · not indexed: the pattern has no contrast to score")
        XCTAssertNil(result.value(.osm, at: 0), "a point not indexed shows no OSM")
        XCTAssertNil(result.value(.score, at: 0))
        XCTAssertEqual(result.rows[0].phase, "not indexed")
        XCTAssertEqual(result.simulationIndex(at: EBSDPosition(row: 0, column: 1)), 8, "into the dictionary of the point's phase")
        let xmap = try XCTUnwrap(try result.crystalMap(steps: (1, 1), scanUnit: "px"))
        XCTAssertEqual(xmap.allPhaseIDs, [PhaseList.notIndexedID, 1, 0, 0])
        XCTAssertEqual(xmap.properties["scores"], [0, 0.3, 0.5, 0.2], "files hold numbers: 0 where not indexed")
        XCTAssertEqual(xmap.phases[id: 0]?.name, "ni")
        XCTAssertEqual(xmap.phases[id: 1]?.name, "al")
        XCTAssertEqual(xmap.phases[id: PhaseList.notIndexedID]?.name, "not_indexed")
    }

    /// Phases tied at every point (F9's matches as two phases' maps): the first phase takes every point, as `np.nanargmax` does; the
    /// OSM counts each shared match twice, twice F9's; the phase that wins no point is not in the crystal map's list.
    func testTiedPhasesTakeTheFirstAndDoubleTheSimilarityMap() throws {
        let f9 = try SEMParityReference.load("m4/dictionary-indexing-nickel-ebsd-large")
        let indices = ints(try f9.array("ncc_simulation_indices")), scores = try f9.array("ncc_scores").values
        let whole = DictionaryIndexing.Result(navigationShape: [55, 75], keepN: 5, isInData: Array(repeating: true, count: 4125),
                                              scores: scores, simulationIndices: indices,
                                              rotations: Array(repeating: SIMD4(1, 0, 0, 0), count: indices.count))
        var copy = ni
        copy.name = "ni copy"
        var result = IndexingResult(scanRows: 55, scanColumns: 75, phases: [ni, copy], metric: .ncc)
        for rows in [0 ..< 30, 30 ..< 55] {
            let b = block(whole, rows, width: 75)
            result.land([b, b], rows: rows)
        }
        XCTAssertTrue(result.isComplete)
        XCTAssertEqual(result.countsByPhase, [4125, 0])
        XCTAssertEqual(result.dictionary?.simulationIndices, indices)
        let ref = try SEMParityReference.load("m4/orientation-similarity-map")
        XCTAssertEqual(result.similarity.map(Double.init), try ref.array("f9_osm").values.map { 2 * $0 })
        let xmap = try XCTUnwrap(try result.crystalMap(steps: (1, 1), scanUnit: "px"))
        XCTAssertEqual(xmap.phases.names, ["ni"])
    }

    /// The choice compares the scores as the run made them (float64 on the CPU): a score 1e-12 higher wins, where `merge`, on
    /// kikuchipy's float32 bundles, rounds both to one float32 and takes the first.
    func testTheChoiceComparesTheScoresAsTheRunMadeThem() throws {
        let one = SIMD4<Double>(1, 0, 0, 0), half = SIMD4<Double>(0, 1, 0, 0)
        let a = DictionaryIndexing.Result(navigationShape: [2, 2], keepN: 1, isInData: [true, true, true, true],
                                          scores: [0.5, 0.5, 0.5, 0.5], simulationIndices: [0, 1, 2, 3], rotations: [one, one, one, one])
        let b = DictionaryIndexing.Result(navigationShape: [2, 2], keepN: 1, isInData: [true, true, true, true],
                                          scores: [0.5 + 1e-12, 0.4, 0.6, 0.5], simulationIndices: [0, 1, 2, 3], rotations: [half, half, half, half])
        var result = IndexingResult(scanRows: 2, scanColumns: 2, phases: [ni, al], metric: .ncc)
        result.land([a, b], rows: 0 ..< 2)
        XCTAssertEqual(result.solutions.compactMap { $0?.phase }, [1, 0, 1, 0])
        XCTAssertEqual(result.solutions[0]?.confidence, 0.5 + 1e-12, "the score as the run made it")
        let merged = try DictionaryMapMerge.merge([.init(result: a, phase: ni.crystalPhase), .init(result: b, phase: al.crystalPhase)])
        XCTAssertEqual(merged.phaseIDs, [0, 0, 1, 0], "float32: the 1e-12 is lost and the first map wins the tie")
    }
}
