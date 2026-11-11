//
//  IndexingComparisonTests.swift
//  The Indexing room's Compare on small synthetic results (#230, D-SEM-97), beside the orix bundles of SEMIndexingCompareParityTests:
//  a point not indexed never reads as agreement (orix's `angle_with` gives 0° for a zero quaternion, so the phase index masks it);
//  a run's and a crystal map's sides on the scan's grid; the pairing rule (one phase a side by Laue class, else by name within one);
//  numpy's median, share and histogram edges; the words of the footer, the status lines and the empty histogram in two locales, a side
//  without an orientation as `UnitDisplay.noValue` and the counts never grouped (#272).
//  Red before: no `IndexingComparison`, no `IndexingCompareFormat`.
//

import XCTest
import TEMCore
import TEMSession
@testable import macTEM

nonisolated final class IndexingComparisonTests: XCTestCase {
    private typealias Phase = IndexingComparison.Side.Phase

    private static let ni = IndexingPhase(name: "ni", spaceGroup: 225, lattice: [3.52, 3.52, 3.52, 90, 90, 90], source: .preset)
    private static let q1 = SIMD4<Double>(1, 0, 0, 0)
    /// 10.5° about z (off a bin edge).
    private static let q10 = SIMD4<Double>(cos(5.25 * Double.pi / 180), 0, 0, sin(5.25 * Double.pi / 180))

    private static func solution(phase: Int, quaternion: SIMD4<Double>) -> HoughIndexer.Solution {
        var s = HoughIndexer.Solution()
        s.phase = phase
        s.quaternion = quaternion
        return s
    }

    // MARK: - The mask

    func testANotIndexedPointIsNeverAgreement() throws {
        // The trap: orix's angle_with (and its port) turns the zero quaternion of a point not indexed into 0°, perfect agreement.
        let zero = Orientations(quaternions: [SIMD4(0, 0, 0, 0)], symmetry: PointGroup.oh)
            .angles(with: Orientations(quaternions: [Self.q10], symmetry: PointGroup.oh))
        XCTAssertEqual(zero, [0])

        var result = IndexingResult(scanRows: 1, scanColumns: 3, phases: [Self.ni])
        result.land([HoughIndexer.Solution(), Self.solution(phase: 0, quaternion: Self.q1), Self.solution(phase: 0, quaternion: Self.q1)], at: 0)
        let a = IndexingComparison.Side(result)
        XCTAssertEqual(a.phaseIndices, [-1, 0, 0])
        let b = IndexingComparison.Side(phases: [Phase(name: "ni", pointGroupName: "m-3m")], phaseIndices: [0, 0, -1],
                                        rotations: [Self.q10, Self.q10, Self.q1])
        let c = try IndexingComparison(a, b)
        XCTAssertEqual(c.outcomes, [.noneInA, .compared, .noneInB])
        XCTAssertTrue(c.angles[0].isNaN)
        XCTAssertTrue(c.angles[2].isNaN)
        XCTAssertEqual(try XCTUnwrap(c.degrees(at: 1)), 10.5, accuracy: 1e-9)
        XCTAssertEqual(c.comparedCount, 1)
        XCTAssertEqual(c.histogram?.counts.reduce(0, +), 1, "a point left out is in no bin")
        XCTAssertEqual(c.histogram?.counts[10], 1)
        XCTAssertEqual(c.count(.noneInA), 1)
        XCTAssertEqual(c.count(.noneInB), 1)
    }

    // MARK: - The sides

    func testSidesOfARunAndOfACrystalMap() throws {
        // A run: points not reached and not indexed are -1; an indexed point with a quaternion that is no rotation too.
        var result = IndexingResult(scanRows: 2, scanColumns: 3, phases: [Self.ni])
        result.land([Self.solution(phase: 0, quaternion: Self.q10), HoughIndexer.Solution(),
                     Self.solution(phase: 0, quaternion: SIMD4(0, 0, 0, 0))], at: 0)
        let run = IndexingComparison.Side(result)
        XCTAssertEqual(run.phases, [Phase(name: "ni", pointGroupName: "m-3m")])
        XCTAssertEqual(run.phaseIndices, [0, -1, -1, -1, -1, -1], "row 1 is not reached")
        XCTAssertEqual(run.rotations[0], Self.q10)
        XCTAssertEqual(run.rotations[2], Self.q1, "the identity where there is no orientation")
        XCTAssertEqual(run.phaseName(at: 0), "ni")
        XCTAssertNil(run.phaseName(at: 1))
        XCTAssertNil(run.eulerDegrees(at: 1))
        XCTAssertEqual(try XCTUnwrap(run.eulerDegrees(at: 0)).y, 0, accuracy: 1e-9, "a rotation about z: Φ is 0")

        // A crystal map on a 2 × 3 grid: its point at (row 0, col 1) not indexed; laid row-major on the scan.
        let grid = CrystalMap.coordinates(shape: (2, 3), steps: (1, 1))
        let ni = CrystalPhase(name: "Ni", spaceGroup: 225, pointGroup: "m-3m", lattice: [3.524, 3.524, 3.524, 90, 90, 90])
        let map = try CrystalMap(euler: (0..<6).map { SIMD3(Double($0) * 0.1, 0.2, 0.3) }, phaseIDs: [0, -1, 0, 0, 0, 0],
                                 x: grid.x, y: grid.y, phaseList: PhaseList([(0, ni)]), scanUnit: "um")
        let file = try XCTUnwrap(IndexingComparison.Side(map, scanRows: 2, scanColumns: 3))
        XCTAssertEqual(file.phases, [Phase(name: "Ni", pointGroupName: "m-3m")], "not_indexed is no phase")
        XCTAssertEqual(file.phaseIndices, [0, -1, 0, 0, 0, 0])
        let cells = OrientationMaps.pointIndexGrid(map)
        for k in [0, 2, 3, 4, 5] { XCTAssertEqual(file.rotations[k], map.rotations[cells[k]], "cell \(k)") }
        XCTAssertNil(IndexingComparison.Side(map, scanRows: 3, scanColumns: 2), "a map off the scan's grid")
    }

    // MARK: - Pairing

    func testPhasePairing() throws {
        let ni = Phase(name: "ni", pointGroupName: "m-3m"), nickel = Phase(name: "Nickel", pointGroupName: "432")
        let ti = Phase(name: "ti", pointGroupName: "6/mmm"), ti622 = Phase(name: "ti", pointGroupName: "622")
        let ni432 = Phase(name: "ni", pointGroupName: "432"), x = Phase(name: "x", pointGroupName: nil)

        // One phase a side: the Laue classes decide, the names do not (kikuchipy compares two single-phase maps).
        XCTAssertEqual(IndexingComparison.pairing([ni], [nickel]), [0: 0])
        XCTAssertEqual(IndexingComparison.pairing([ni], [ti]), [:])
        XCTAssertEqual(IndexingComparison.pairing([ni], [x]), [:])
        // Several: by name within one Laue class.
        XCTAssertEqual(IndexingComparison.pairing([ni, ti], [ti622, ni432]), [0: 1, 1: 0])
        XCTAssertEqual(IndexingComparison.pairing([ni, ti], [nickel, ti622]), [1: 1], "Nickel is not ni")

        // m-3m against 432 is 432 against 432: the same proper elements.
        let rotations = [Self.q10, SIMD4(0.5, 0.5, 0.5, 0.5), SIMD4(0.9, 0.1, 0.3, 0.3) / (0.81 + 0.01 + 0.09 + 0.09).squareRoot()]
        let reference = [Self.q1, Self.q1, Self.q10]
        let c = try IndexingComparison(IndexingComparison.Side(phases: [ni], phaseIndices: [0, 0, 0], rotations: rotations),
                                       IndexingComparison.Side(phases: [nickel], phaseIndices: [0, 0, 0], rotations: reference))
        let o = PointGroup.named("432")!
        let direct = Orientations(quaternions: rotations, symmetry: o).angles(with: Orientations(quaternions: reference, symmetry: o))
        for i in 0..<3 { XCTAssertEqual(c.angles[i], direct[i], accuracy: 1e-12) }
        XCTAssertEqual(c.histogram?.edges.last, 63, "432's largest disorientation is 62.8°")

        // A Laue mismatch leaves every point unpaired; B's phase without a point group is no B.
        let mismatch = try IndexingComparison(IndexingComparison.Side(phases: [ni], phaseIndices: [0], rotations: [Self.q1]),
                                              IndexingComparison.Side(phases: [ti], phaseIndices: [0], rotations: [Self.q1]))
        XCTAssertEqual(mismatch.outcomes, [.unpairedPhases])
        XCTAssertNil(mismatch.histogram)
        XCTAssertNil(mismatch.medianDegrees)
        XCTAssertNil(mismatch.fractionOverThreshold)
        let groupless = try IndexingComparison(IndexingComparison.Side(phases: [ni], phaseIndices: [0], rotations: [Self.q1]),
                                               IndexingComparison.Side(phases: [x], phaseIndices: [0], rotations: [Self.q1]))
        XCTAssertEqual(groupless.outcomes, [.noneInB])
    }

    // MARK: - numpy's statistics

    func testStatisticsAreNumpys() throws {
        XCTAssertEqual(IndexingComparison.median([0.436470372, 0.436490468]), (0.436470372 + 0.436490468) / 2, "an even count: the mean of the two")
        XCTAssertEqual(IndexingComparison.median([3, 1, 2]), 2)
        XCTAssertNil(IndexingComparison.median([]))
        XCTAssertEqual(IndexingComparison.fraction(over: 2, of: [0.5, 2, 2.0000001, 3]), 0.5, "strictly over")
        XCTAssertNil(IndexingComparison.fraction(over: 2, of: []))
        XCTAssertEqual(IndexingComparison.degrees(1), 1 * (180 / Double.pi))
        let edges = IndexingComparison.edges(top: 63)
        XCTAssertEqual(edges.count, 64)
        XCTAssertEqual(edges.first, 0)
        XCTAssertEqual(edges.last, 63)
        XCTAssertEqual(AngleHistogram(values: [63, 0, 62.5], edges: edges).counts.last, 2, "the last bin is closed: 63° is in it")
        XCTAssertEqual(PointGroup.oh.disorientationBinsTop, 63)
        XCTAssertEqual(try XCTUnwrap(PointGroup.named("2")).disorientationBinsTop, 181)

        let one = IndexingComparison.Side(phases: [Phase(name: "ni", pointGroupName: "m-3m")], phaseIndices: [0], rotations: [Self.q1])
        let two = IndexingComparison.Side(phases: one.phases, phaseIndices: [0, 0], rotations: [Self.q1, Self.q1])
        XCTAssertThrowsError(try IndexingComparison(one, two)) { XCTAssertEqual($0 as? IndexingComparison.Refusal, .differentScans) }
    }

    // MARK: - The words

    func testCompareWords() throws {
        let ni = Phase(name: "ni", pointGroupName: "m-3m"), nickel = Phase(name: "Nickel", pointGroupName: "m-3m")
        // Four points of one row: 10.5° apart, the same, not indexed by A, not indexed by B.
        let a = IndexingComparison.Side(phases: [ni], phaseIndices: [0, 0, -1, 0], rotations: [Self.q10, Self.q1, Self.q1, Self.q1])
        let b = IndexingComparison.Side(phases: [nickel], phaseIndices: [0, 0, 0, -1], rotations: [Self.q1, Self.q1, Self.q1, Self.q1])
        let c = try IndexingComparison(a, b)
        let us = Locale(identifier: "en_US_POSIX"), de = Locale(identifier: "de_DE")
        XCTAssertEqual(IndexingCompareFormat.footer(c, a: .hough, b: .file, locale: us),
                       "2 of 4 points · median 5.25° · 50.0 % over 2° · 1 without a Hough orientation · 1 without a File orientation")
        XCTAssertEqual(IndexingCompareFormat.footer(c, a: .hough, b: .file, locale: de),
                       "2 of 4 points · median 5,25° · 50,0 % over 2° · 1 without a Hough orientation · 1 without a File orientation")
        XCTAssertEqual(IndexingCompareFormat.mapsTitle(a: .hough, b: .file, layer: .ipfZ), "Compare · Hough against File · IPF-Z")
        XCTAssertEqual(IndexingCompareFormat.tileTitle("B", .dictionary, layer: .ipfX, stale: true), "B · Dictionary · IPF-X · stale")
        XCTAssertEqual(IndexingCompareFormat.histogramTitle(a: .dictionary, b: .file), "Disorientation · Dictionary against File")

        let compared = try XCTUnwrap(IndexingCompareFormat.readout(c, a: .hough, b: .file, at: EBSDPosition(row: 0, column: 0), columns: 4, locale: us))
        XCTAssertTrue(compared.hasPrefix("row 0 · col 0 · Hough ni φ₁ "), compared)
        XCTAssertTrue(compared.contains(" · File Nickel φ₁ "), compared)
        XCTAssertTrue(compared.hasSuffix(" · disorientation 10.50°"), compared)
        let left = try XCTUnwrap(IndexingCompareFormat.readout(c, a: .hough, b: .file, at: EBSDPosition(row: 0, column: 2), columns: 4, locale: us))
        // A side without an orientation is the one dash (`UnitDisplay.noValue`). Red before: an en dash, "Hough –".
        XCTAssertTrue(left.hasPrefix("row 0 · col 2 · Hough \(UnitDisplay.noValue) · File Nickel φ₁ "), left)
        XCTAssertTrue(left.hasSuffix(" · not compared: no Hough orientation"), left)
        let right = try XCTUnwrap(IndexingCompareFormat.readout(c, a: .hough, b: .file, at: EBSDPosition(row: 0, column: 3), columns: 4, locale: us))
        XCTAssertTrue(right.hasSuffix(" · File \(UnitDisplay.noValue) · not compared: no File orientation"), right)
        let leftInGerman = try XCTUnwrap(IndexingCompareFormat.readout(c, a: .hough, b: .file, at: EBSDPosition(row: 0, column: 2), columns: 4,
                                                                       locale: de))
        XCTAssertTrue(leftInGerman.hasPrefix("row 0 · col 2 · Hough \u{2014} · File Nickel φ₁ "), leftInGerman)
        XCTAssertNil(IndexingCompareFormat.readout(c, a: .hough, b: .file, at: EBSDPosition(row: 1, column: 0), columns: 4, locale: us))

        XCTAssertEqual(IndexingCompareFormat.binReadout(c, atDegrees: 10.4, locale: us), "10–11° · 1 point · 50.0 % of those compared")
        XCTAssertEqual(IndexingCompareFormat.binReadout(c, atDegrees: 0.2, locale: de), "0–1° · 1 point · 50,0 % of those compared")
        XCTAssertEqual(IndexingCompareFormat.binReadout(c, atDegrees: 5, locale: us), "5–6° · 0 points · 0.0 % of those compared")
        XCTAssertNil(IndexingCompareFormat.binReadout(c, atDegrees: 64, locale: us))
        XCTAssertEqual(IndexingCompareFormat.bins(try XCTUnwrap(c.histogram)).count, 63)
        // Only the two occupied bins are drawn (0–1° and 10–11°): an empty bin drew as a dot on the axis.
        XCTAssertEqual(IndexingCompareFormat.drawnBins(try XCTUnwrap(c.histogram)).map(\.low), [0, 10])

        let none = try IndexingComparison(IndexingComparison.Side(phases: [ni], phaseIndices: [-1], rotations: [Self.q1]),
                                          IndexingComparison.Side(phases: [nickel], phaseIndices: [0], rotations: [Self.q1]))
        XCTAssertEqual(IndexingCompareFormat.nothingCompared(none, a: .hough, b: .file),
                       "No point is indexed in both as phases that pair (Hough: ni; File: Nickel)")
    }

    /// The footer and the bar's status line write their counts as the Info words do, never grouped, in every locale. Red before:
    /// "1,234 of 1,234 points" in en_US and "1.234 of 1.234 points" in German.
    func testCompareCountsAreNeverGrouped() throws {
        let ni = Phase(name: "ni", pointGroupName: "m-3m"), nickel = Phase(name: "Nickel", pointGroupName: "m-3m")
        let n = 1234
        let a = IndexingComparison.Side(phases: [ni], phaseIndices: Array(repeating: 0, count: n), rotations: Array(repeating: Self.q1, count: n))
        let b = IndexingComparison.Side(phases: [nickel], phaseIndices: Array(repeating: 0, count: n), rotations: Array(repeating: Self.q1, count: n))
        let c = try IndexingComparison(a, b)
        for locale in [Locale(identifier: "en_US"), Locale(identifier: "de_DE"), Locale(identifier: "en_US_POSIX")] {
            let footer = IndexingCompareFormat.footer(c, a: .hough, b: .file, locale: locale)
            XCTAssertTrue(footer.hasPrefix("1234 of 1234 points · median "), "\(locale.identifier): \(footer)")
            let bar = try XCTUnwrap(IndexingCompareFormat.binReadout(c, atDegrees: 0.2, locale: locale))
            XCTAssertTrue(bar.hasPrefix("0–1° · 1234 points · 100"), "\(locale.identifier): \(bar)")
        }
    }
}
