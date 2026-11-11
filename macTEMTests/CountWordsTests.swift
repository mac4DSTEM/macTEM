//
//  CountWordsTests.swift
//  A count of one reads in the singular (`UnitDisplay.count`): "1 grain", "1 point", "1 band, 1 zone axis", on screen, in the session
//  report and in the exported figures' words. Red before: every producer here wrote the plural whatever the count ("1 grains",
//  "over 1 grains", "1 points", "1 bands, 1 zone axes"), and the helper did not exist.
//

import Foundation
import TEMCore
import XCTest
@testable import macTEM

nonisolated final class CountWordsTests: XCTestCase {

    /// The helper itself: the singular for one, the plural for none and for more.
    func testTheHelperTakesTheSingularForOne() {
        XCTAssertEqual(UnitDisplay.count(0, "grain", "grains"), "0 grains")
        XCTAssertEqual(UnitDisplay.count(1, "grain", "grains"), "1 grain")
        XCTAssertEqual(UnitDisplay.count(2, "grain", "grains"), "2 grains")
        XCTAssertEqual(UnitDisplay.count(11_700, "point", "points"), "11700 points", "no grouping, as the interpolation wrote it")
        XCTAssertEqual(UnitDisplay.noun(1, "zone axis", "zone axes"), "zone axis")
        XCTAssertEqual(UnitDisplay.noun(3, "zone axis", "zone axes"), "zone axes")
    }

    /// The words that count: the overlay's summary and figure Description, the Indexing room's Info row, the Maps room's settings, and a
    /// map that is one grain (its summary, the report's means over it, the Info tab's phase row).
    func testTheProducersWriteOneInTheSingular() throws {
        XCTAssertEqual(KikuchiOverlay.drawnWords(bands: 1, zoneAxes: 1), "1 band, 1 zone axis")
        XCTAssertEqual(KikuchiOverlay.drawnWords(bands: 12, zoneAxes: 0), "12 bands, 0 zone axes")
        let report = ExportSnapshot.labelLocale
        XCTAssertEqual(IndexingInfoFormat.points(1, locale: report), "1 point")
        XCTAssertEqual(IndexingInfoFormat.points(3812, locale: report), "3812 points")

        // A smallest grain of one point is a legal setting.
        let settings = MapAnalysisSettings(boundaryDegrees: 5, minimumSize: 1, kamMaxDegrees: 5)
        XCTAssertEqual(MapsRoomFormat.analysisFields(settings, locale: report).map(\.value), ["5°", "1 point", "5°"])
        XCTAssertEqual(MapsRoomFormat.analysisFields(MapAnalysisSettings(), locale: report)[1].value, "10 points")

        // A 4 × 4 nickel map of one orientation: one grain of 16 points.
        let grid = CrystalMap.coordinates(shape: (rows: 4, columns: 4), steps: (dy: 1.5, dx: 1.5))
        let ni = CrystalPhase(name: "Ni", spaceGroup: 225, pointGroup: "m-3m", lattice: [3.524, 3.524, 3.524, 90, 90, 90])
        let map = try CrystalMap(euler: Array(repeating: SIMD3<Double>(0.1, 0.2, 0.3), count: 16), phaseIDs: Array(repeating: 0, count: 16),
                                 x: grid.x, y: grid.y, phaseList: PhaseList([(0, ni)]), scanUnit: "um")
        let analysis = try MapAnalysis.run(map, settings: settings)
        XCTAssertEqual(analysis.table.count, 1)
        XCTAssertEqual(MapsRoomFormat.grainSummary(analysis, locale: report).components(separatedBy: " · ").first, "1 grain")
        let means = SEMSessionLedger.grainMeans(analysis, locale: report)
        let gos = try XCTUnwrap(means.first { $0.name == "Mean GOS" }, "\(means)")
        XCTAssertTrue(gos.value.hasSuffix("° over 1 grain"), gos.value)
        let kam = try XCTUnwrap(means.first { $0.name == "Mean KAM" }, "\(means)")
        XCTAssertTrue(kam.value.hasSuffix("° over 16 points"), kam.value)
        let made = try XCTUnwrap(MapsRoomFormat.grainRows(analysis, locale: report).first { $0.label == "Made with" })
        XCTAssertTrue(made.value.contains("≥ 1 point ·"), made.value)
    }
}
