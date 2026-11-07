//
//  SEMIndexingCompareParityTests.swift
//  The Indexing room's Compare (`IndexingComparison`, #230, D-SEM-97) against orix 0.15.0's `Orientation.angle_with` and numpy's
//  `rad2deg`, `histogram`, `median` and `mean` in tools/parity/sem/references/m4/:
//  - indexing-compare-planted: a 20 x 25 grid in two pairs. `multi`: A ni m-3m and ti 6/mmm against B ni 432, ti 622, fe m-3m and x
//    without a point group (pairing by name within a Laue class), with small rotations either side of 2° times an element of B's
//    group, near-Σ3, points not indexed on either side, zero quaternions under a phase, unpaired phases and B's groupless phase.
//    `single`: A ni m-3m against B Nickel 432 (one phase a side pairs by Laue class, as kikuchipy compares two maps). Outcomes,
//    edges, counts and the fraction over 2° exact; angles atol 1e-7 rad; the median 5.8e-6° (1e-7 rad). The bins top of every
//    proper point group as orix's fundamental region gives it.
//  - indexing-compare-nickel-large: the demo scan's Hough run (F8's bundle), its 4° dictionary run (F9's) and the file's own
//    indexing, compared in the three pairs; the file's rotations as orix reads them.
//  The bundles store an angle not compared as -1 (a reference holds no NaN). Red before: no `IndexingComparison`. Red after: a
//  point masked by its quaternion rather than its phase, pairing by name only (single), bins on the data's largest angle, an even
//  median taken as one of the middle two.
//

import Foundation
import TEMCore
import XCTest

nonisolated final class SEMIndexingCompareParityTests: XCTestCase {
    private static let demoScan = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("DemoData/nickel_ebsd_large/patterns_v2.h5")

    private func ints(_ a: SEMParityReference.LoadedArray) -> [Int] { a.values.map { Int($0) } }

    private func quaternions(_ a: SEMParityReference.LoadedArray) -> [SIMD4<Double>] {
        stride(from: 0, to: a.values.count, by: 4).map { SIMD4(a.values[$0], a.values[$0 + 1], a.values[$0 + 2], a.values[$0 + 3]) }
    }

    private func flat(_ q: [SIMD4<Double>]) -> [Double] { q.flatMap { [$0[0], $0[1], $0[2], $0[3]] } }

    /// A point not compared as the bundle stores it.
    private func noNaN(_ a: [Double]) -> [Double] { a.map { $0.isNaN ? -1 : $0 } }

    /// A side's phases from the bundle's values: `[{"name", "point_group"}]`, a null group none.
    private func phases(_ ref: SEMParityReference, _ key: String) throws -> [IndexingComparison.Side.Phase] {
        let list = try XCTUnwrap(ref.values[key] as? [[String: Any]], key)
        return try list.map { IndexingComparison.Side.Phase(name: try XCTUnwrap($0["name"] as? String), pointGroupName: $0["point_group"] as? String) }
    }

    /// Every array, scalar and count of pair `p`.
    private func assertPair(_ p: String, _ comparison: IndexingComparison, _ ref: SEMParityReference,
                            file: StaticString = #filePath, line: UInt = #line) throws {
        SEMAssertParity(comparison.outcomes.map { Double($0.rawValue) }, try ref.array("\(p)_outcomes"), file: file, line: line)
        SEMAssertParity(noNaN(comparison.angles), try ref.array("\(p)_angles_radians"), file: file, line: line)
        let histogram = try XCTUnwrap(comparison.histogram, p, file: file, line: line)
        SEMAssertParity(histogram.edges, try ref.array("\(p)_edges_degrees"), file: file, line: line)
        SEMAssertParity(histogram.counts.map(Double.init), try ref.array("\(p)_counts"), file: file, line: line)
        SEMAssertParity(try XCTUnwrap(comparison.medianDegrees), ref, scalar: "\(p)_median_degrees", file: file, line: line)
        SEMAssertParity(try XCTUnwrap(comparison.fractionOverThreshold), ref, scalar: "\(p)_fraction_over_2_degrees", file: file, line: line)
        XCTAssertEqual(comparison.comparedCount, ref.values["\(p)_compared_count"] as? Int, p, file: file, line: line)
        let pairs = try XCTUnwrap(ref.values["\(p)_pairs"] as? [String: Int], p, file: file, line: line)
        XCTAssertEqual(comparison.pairs, Dictionary(uniqueKeysWithValues: pairs.compactMap { k, v in Int(k).map { ($0, v) } }), p,
                       file: file, line: line)
    }

    // MARK: - Planted

    func testPlantedComparisonMatchesOrix() throws {
        let ref = try SEMParityReference.load("m4/indexing-compare-planted")
        XCTAssertEqual(ref.values["grid_rc"] as? [Int], [20, 25])
        for p in ["multi", "single"] {
            let a = IndexingComparison.Side(phases: try phases(ref, "\(p)_a_phases"), phaseIndices: ints(try ref.array("\(p)_a_phase")),
                                            rotations: quaternions(try ref.array("\(p)_a_quaternions")))
            let b = IndexingComparison.Side(phases: try phases(ref, "\(p)_b_phases"), phaseIndices: ints(try ref.array("\(p)_b_phase")),
                                            rotations: quaternions(try ref.array("\(p)_b_quaternions")))
            XCTAssertEqual(a.pointCount, 500)
            try assertPair(p, try IndexingComparison(a, b), ref)
        }
        // The top of the bins: the first whole degree above the largest disorientation of each proper point group.
        let tops = try XCTUnwrap(ref.values["bins_top_degrees"] as? [String: Int])
        XCTAssertEqual(tops.count, 11)
        for (name, top) in tops {
            let group = try XCTUnwrap(PointGroup.named(name), name)
            XCTAssertEqual(group.properSubgroup.disorientationBinsTop, top, name)
        }
        XCTAssertEqual(try XCTUnwrap(PointGroup.named("m-3m")).disorientationBinsTop, 63, "m-3m's proper subgroup is 432")
        XCTAssertEqual(try XCTUnwrap(PointGroup.named("6/mmm")).disorientationBinsTop, 94, "6/mmm's proper subgroup is 622")
    }

    // MARK: - The demo scan

    /// The three results of the shipped nickel scan, pairwise: Hough against the file's indexing (a median of 0.44°), the 4° dictionary
    /// against the file (2.44°, the dictionary's grid), Hough against the dictionary (2.37°).
    func testTheDemoScanComparesAsOrixDoes() throws {
        let ref = try SEMParityReference.load("m4/indexing-compare-nickel-large")
        XCTAssertEqual(ref.values["navigation_shape_rc"] as? [Int], [55, 75])
        let hough = try SEMParityReference.load("m4/hough-indexing-nickel-large")
        let dictionary = try SEMParityReference.load("m4/dictionary-indexing-nickel-ebsd-large")
        let ni = [IndexingComparison.Side.Phase(name: "ni", pointGroupName: "m-3m")]
        let houghSide = IndexingComparison.Side(phases: ni, phaseIndices: ints(try hough.array("phase")),
                                                rotations: quaternions(try hough.array("quaternion")))
        let dictionarySide = IndexingComparison.Side(phases: ni, phaseIndices: Array(repeating: 0, count: 4125),
                                                     rotations: quaternions(try dictionary.array("ncc_best_quaternions")))

        // The file's side as the room reads it: the dataset's crystal map laid on the scan.
        let dataset = try EBSDH5Reader.read(url: Self.demoScan)
        let map = try XCTUnwrap(dataset.crystalMap)
        let fileSide = try XCTUnwrap(IndexingComparison.Side(map, scanRows: 55, scanColumns: 75))
        XCTAssertEqual(fileSide.phases.map(\.name), ["ni"])
        XCTAssertEqual(fileSide.phases.map(\.pointGroupName), ["m-3m"])
        XCTAssertEqual(fileSide.phaseIndices.map(Double.init), try ref.array("file_phase").values)
        // q and -q are one rotation: each of ours on the reference's sign before the values are compared.
        let fileReference = try ref.array("file_quaternions")
        let theirs = quaternions(fileReference)
        let ours = zip(fileSide.rotations, theirs).map { q, r in (q * r).sum() < 0 ? -q : q }
        SEMAssertParity(flat(ours), fileReference)
        XCTAssertNil(IndexingComparison.Side(map, scanRows: 75, scanColumns: 55), "a map off the scan's grid is no side")

        try assertPair("hough_file", try IndexingComparison(houghSide, fileSide), ref)
        try assertPair("dictionary_file", try IndexingComparison(dictionarySide, fileSide), ref)
        try assertPair("hough_dictionary", try IndexingComparison(houghSide, dictionarySide), ref)
    }
}
