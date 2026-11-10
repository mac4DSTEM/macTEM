//
//  SEMStatusLineNumberTests.swift
//  The status lines over the Indexing and Maps maps write a number as the tables under them write the same value (`UnitDisplay.fixed`,
//  which `IndexingTableFormat` and `MapsRoomFormat` go through): printf's digits in the reader's decimal mark, no sign on a value that
//  rounds to zero. Red before: the lines still rounded with FormatStyle, so a dictionary score of -0.0004 read "NCC -0.000" over a
//  cell reading "0.000", the identity orientation's φ₁ (a negative zero out of `qu2eu`) read "-0.0°" over "0.0", and a decimal tie
//  rounded apart (a score of 0.4135 read "0.414" over "0.413", a CI of 0.835 "0.84", an angle of 0.35° "0.4°").
//

import Foundation
import TEMCore
import TEMSession
import XCTest
@testable import macTEM

nonisolated final class SEMStatusLineNumberTests: XCTestCase {
    private let en = Locale(identifier: "en_US")
    private let de = Locale(identifier: "de_DE")
    private let ni = IndexingPhase(name: "ni", spaceGroup: 225, lattice: [3.52, 3.52, 3.52, 90, 90, 90], source: .preset, color: "tab:blue")
    private let identity = SIMD4<Double>(1, 0, 0, 0)

    // MARK: - Indexing

    /// A dictionary point's line is its Results row's cells, in both decimal marks: the Euler angles, the score and the OSM. The scores
    /// are one that rounds to zero from below (-0.0004), a decimal tie whose binary value lies under it (0.4135) and two plain ones.
    func testADictionaryPointsStatusLineIsItsTableRowsCells() throws {
        let block = DictionaryIndexing.Result(navigationShape: [2, 2], keepN: 1, isInData: [true, true, true, true],
                                              scores: [-0.0004, 0.4135, 0.8234, 0.5], simulationIndices: [3, 4, 5, 6],
                                              rotations: [identity, identity, identity, identity])
        var result = IndexingResult(scanRows: 2, scanColumns: 2, phases: [ni], metric: .ncc)
        result.land(block, rows: 0 ..< 2)
        let rows = result.rows
        XCTAssertEqual(rows.map(\.confidence), [-0.0004, 0.4135, 0.8234, 0.5])
        for locale in [en, de] {
            for row in rows {
                let cells = IndexingTableFormat.cells(row, method: .dictionary, locale: locale)
                let line = try XCTUnwrap(result.readout(at: row.position, locale: locale))
                let angles = "φ₁ \(cells[3])° Φ \(cells[4])° φ₂ \(cells[5])°"
                let expected = "row \(cells[0]) · col \(cells[1]) · \(cells[2]) · \(angles) · NCC \(cells[6]) · OSM \(cells[8])"
                XCTAssertEqual(line, expected, "point \(row.id), \(locale.identifier)")
            }
        }
        // The same lines spelled out: no "-0.000", no "-0.0°", the tie as `%.3f` rounds it.
        XCTAssertEqual(result.readout(at: EBSDPosition(row: 0, column: 0), locale: en),
                       "row 0 · col 0 · ni · φ₁ 0.0° Φ 0.0° φ₂ 0.0° · NCC 0.000 · OSM 0.00")
        XCTAssertEqual(result.readout(at: EBSDPosition(row: 0, column: 1), locale: en),
                       "row 0 · col 1 · ni · φ₁ 0.0° Φ 0.0° φ₂ 0.0° · NCC 0.413 · OSM 0.00")
        XCTAssertEqual(result.readout(at: EBSDPosition(row: 1, column: 0), locale: de),
                       "row 1 · col 0 · ni · φ₁ 0,0° Φ 0,0° φ₂ 0,0° · NCC 0,823 · OSM 0,00")
    }

    /// A Hough point's line: the Euler angles and the fit are the row's cells; the CI, which the line writes to two places where the
    /// table writes three, rounds as the table's formatter does at two. CI 0.835 and fit 0.615° are ties whose binary values lie under
    /// them, so `%.2f` writes "0.83" and "0.61".
    func testAHoughPointsStatusLineRoundsAsItsTableRowDoes() throws {
        var solution = HoughIndexer.Solution()
        solution.quaternion = identity
        solution.phase = 0
        solution.confidence = 0.835
        solution.fit = 0.615
        solution.matchedBands = 9
        solution.bandMatch = [Int](repeating: 0, count: 10)
        var result = IndexingResult(scanRows: 1, scanColumns: 1, phases: [ni])
        result.land([solution], at: 0)
        let row = try XCTUnwrap(result.rows.first)
        let cells = IndexingTableFormat.cells(row, method: .hough, locale: en)
        let line = try XCTUnwrap(result.readout(at: row.position, locale: en))
        XCTAssertEqual(line, "row 0 · col 0 · ni · φ₁ 0.0° Φ 0.0° φ₂ 0.0° · CI 0.83 · fit 0.61° · bands 9 of 10")
        XCTAssertTrue(line.contains(" · φ₁ \(cells[3])° Φ \(cells[4])° φ₂ \(cells[5])° · "), line)
        XCTAssertTrue(line.contains(" · fit \(cells[7])° · "), line)
        XCTAssertTrue(line.contains(" · CI " + IndexingTableFormat.angle(row.confidence, digits: 2, locale: en) + " · "), line)
        XCTAssertEqual(result.readout(at: row.position, locale: de),
                       "row 0 · col 0 · ni · φ₁ 0,0° Φ 0,0° φ₂ 0,0° · CI 0,83 · fit 0,61° · bands 9 of 10")
    }

    // MARK: - Maps

    /// The Maps line's Euler angles are written as `MapsRoomFormat.angle` writes the same degrees: φ₁ the decimal tie 0.35° itself
    /// (binary 0.34999…, "0.3"), φ₂ a file's angle of -0.04° ("0.0", never "-0.0"). The KAM the line adds after Segment goes through the
    /// same formatter at two places (a pin: a map of one orientation has no KAM that told the two apart).
    func testTheMapsStatusLineWritesAnglesAsTheRoomsTablesDo() throws {
        let perRadian = 180 / Double.pi
        let tie = 0.35 / perRadian
        XCTAssertEqual(tie * perRadian, 0.35, "the degrees the line shows are the tie itself")
        let xy = CrystalMap.coordinates(shape: (rows: 4, columns: 4), steps: (dy: 1.5, dx: 1.5))
        let nickel = CrystalPhase(name: "Ni", spaceGroup: 225, pointGroup: "m-3m", lattice: [3.524, 3.524, 3.524, 90, 90, 90])
        let map = try CrystalMap(euler: Array(repeating: SIMD3<Double>(tie, 0.2, -0.0007), count: 16), phaseIDs: Array(repeating: 0, count: 16),
                                 x: xy.x, y: xy.y, phaseList: PhaseList([(0, nickel)]), scanUnit: "um")
        let grid = OrientationMaps.pointIndexGrid(map)
        let shown = map.euler[0] * perRadian
        for locale in [en, de] {
            let line = try XCTUnwrap(OrientationMaps.readout(map, grid: grid, row: 0, column: 0, locale: locale))
            let angles = [shown.x, shown.y, shown.z].map { MapsRoomFormat.angle($0, locale: locale) }
            XCTAssertTrue(line.hasSuffix(" · φ₁ \(angles[0])° Φ \(angles[1])° φ₂ \(angles[2])°"), line)
        }
        XCTAssertEqual(OrientationMaps.readout(map, grid: grid, row: 0, column: 0, locale: en), "row 0 · col 0 · Ni · φ₁ 0.3° Φ 11.5° φ₂ 0.0°")
        XCTAssertEqual(OrientationMaps.readout(map, grid: grid, row: 0, column: 0, locale: de), "row 0 · col 0 · Ni · φ₁ 0,3° Φ 11,5° φ₂ 0,0°")

        let analysis = try MapAnalysis.run(map, settings: MapAnalysisSettings(boundaryDegrees: 5, minimumSize: 1, kamMaxDegrees: 5))
        let kam = analysis.grains.kam[analysis.columns + 1] * 180 / Double.pi
        XCTAssertTrue(kam.isFinite, "\(kam)")
        for locale in [en, de] {
            let words = OrientationMapSession.analysisReadout(analysis, row: 1, column: 1, locale: locale)
            XCTAssertTrue(words.hasSuffix(" · KAM " + MapsRoomFormat.angle(kam, digits: 2, locale: locale) + "°"), words)
        }
        XCTAssertTrue(OrientationMapSession.analysisReadout(analysis, row: 1, column: 1, locale: de).hasSuffix(" · KAM 0,00°"))
    }
}
