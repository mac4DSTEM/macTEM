//
//  SEMNumberFormatTests.swift
//  The SEM rooms' number words go through `UnitDisplay`, as every other room's: the Maps room's angles, numbers, fractions and grain
//  lengths, the orientation pane's Euler angles and the Indexing table's cells take printf's digits in the reader's decimal mark, never a
//  negative zero, and one dash where there is no value; the Patterns room's readouts and Info rows take the locale they are given; the
//  typed fields of both rooms share `Num`'s styles, never grouped; a count of one reads in the singular. The EDS room's SEM rows follow
//  with that room's rework.
//

import XCTest
import TEMCore
@testable import macTEM

nonisolated final class SEMNumberFormatTests: XCTestCase {
    private let en = Locale(identifier: "en_US")
    private let de = Locale(identifier: "de_DE")

    /// A value that is not there reads as UnitDisplay's one dash in the Maps and Indexing tables and lines. Red before: both wrote an
    /// en dash ("–").
    func testNoValueIsUnitDisplaysDash() {
        XCTAssertEqual(UnitDisplay.noValue, "\u{2014}")
        for v in [Double.nan, Double.infinity, -Double.infinity] {
            XCTAssertEqual(MapsRoomFormat.number(v), UnitDisplay.number(v), "\(v)")
            XCTAssertEqual(MapsRoomFormat.angle(v), UnitDisplay.noValue, "\(v)")
            XCTAssertEqual(MapsRoomFormat.fraction(v), UnitDisplay.noValue, "\(v)")
            XCTAssertEqual(MapsRoomFormat.length(v), UnitDisplay.noValue, "\(v)")
            XCTAssertEqual(IndexingTableFormat.number(v), UnitDisplay.number(v), "\(v)")
            XCTAssertEqual(IndexingTableFormat.angle(v), UnitDisplay.noValue, "\(v)")
        }
    }

    /// The routed formatters keep their digits and the reader's mark, and a value that rounds to zero has no sign. Red before: the Maps
    /// angle of -0.04° read "-0.0".
    func testTheRoutedFormattersKeepTheirDigits() {
        XCTAssertEqual(MapsRoomFormat.angle(12.34, locale: de), "12,3")
        XCTAssertEqual(MapsRoomFormat.angle(132.4, digits: 0, locale: en), "132")
        XCTAssertEqual(MapsRoomFormat.angle(-0.04, locale: en), "0.0")
        XCTAssertEqual(MapsRoomFormat.number(0.0123456, locale: de), "0,01235")
        XCTAssertEqual(MapsRoomFormat.number(12_345.6, locale: en), "12350", "four significant digits, never grouped")
        XCTAssertEqual(MapsRoomFormat.fraction(0.4712, locale: de), "0,471")
        XCTAssertEqual(IndexingTableFormat.fraction(0.8234, locale: de), "0,823")
    }

    /// A 4 × 4 map of Ni at `step` in `unit`, of one orientation, or with `odd` its first point turned away from the rest into a grain of
    /// its own; segmented with no smallest size, so that point stays a grain.
    private func niAnalysis(step: Double, unit: String, odd: Bool = false) throws -> MapAnalysis {
        let grid = CrystalMap.coordinates(shape: (rows: 4, columns: 4), steps: (dy: step, dx: step))
        let ni = CrystalPhase(name: "Ni", spaceGroup: 225, pointGroup: "m-3m", lattice: [3.524, 3.524, 3.524, 90, 90, 90])
        var euler = Array(repeating: SIMD3<Double>(0.1, 0.2, 0.3), count: 16)
        if odd { euler[0] = SIMD3<Double>(1.2, 0.7, 0.4) }
        let map = try CrystalMap(euler: euler, phaseIDs: Array(repeating: 0, count: 16), x: grid.x, y: grid.y, phaseList: PhaseList([(0, ni)]),
                                 scanUnit: unit)
        return try MapAnalysis.run(map, settings: MapAnalysisSettings(boundaryDegrees: 5, minimumSize: 1, kamMaxDegrees: 5))
    }

    /// The grain table's ECD column, the summary and the Grains rows write a length at two decimals in the scan unit, so a column reads
    /// "10,70 · 10,16 · 21,00 · 6,56" and the inspector's Mean ECD the same way. Red before: four significant digits ("10,7 · 10,16 · 21 ·
    /// 6,555" in the drive; the one grain below read "4.514 µm" in the summary and the rows).
    func testGrainLengthsReadTwoDecimals() throws {
        XCTAssertEqual([10.7, 10.16, 21, 6.5551].map { MapsRoomFormat.length($0, locale: de) }, ["10,70", "10,16", "21,00", "6,56"])
        XCTAssertEqual(MapsRoomFormat.length(12_345.678, locale: en), "12345.68", "never grouped")
        XCTAssertEqual(MapsRoomFormat.length(-0.001, locale: en), "0.00")

        // A 1 µm step: one grain of 16 µm², ECD 2√(16/π) = 4.5135 µm.
        let analysis = try niAnalysis(step: 1, unit: "um")
        let grain = try XCTUnwrap(analysis.table.first)
        XCTAssertEqual(grain.diameter, 2 * (16 / Double.pi).squareRoot(), accuracy: 1e-9)
        XCTAssertEqual(MapsRoomFormat.lengthPlaces(analysis), 2)
        XCTAssertEqual(MapsRoomFormat.length(grain.diameter, locale: en), "4.51")
        XCTAssertTrue(MapsRoomFormat.grainSummary(analysis, locale: en).hasPrefix("1 grain · mean ECD 4.51 µm"),
                      MapsRoomFormat.grainSummary(analysis, locale: en))
        XCTAssertTrue(MapsRoomFormat.grainSummary(analysis, locale: de).hasPrefix("1 grain · mean ECD 4,51 µm"),
                      MapsRoomFormat.grainSummary(analysis, locale: de))
        let rows = Dictionary(MapsRoomFormat.grainRows(analysis, locale: de).map { ($0.label, $0.value) }, uniquingKeysWith: { first, _ in first })
        XCTAssertEqual(rows["Mean ECD"], "4,51 µm")
        XCTAssertEqual(rows["Area-weighted"], "4,51 µm")
        if let intercept = analysis.meanLinealIntercept {
            XCTAssertEqual(rows["Mean intercept"], "\(UnitDisplay.fixed(intercept, places: 2, locale: de)) µm")
        }
    }

    /// The scan unit is the file's, so a fine step keeps three significant digits of its smallest length, with one count of decimals for
    /// the whole table: a TKD map in µm at a 10 nm step reads "0.0113 · 0.0437", a 1 nm step's grain "0.00451", an mm map at 5 µm
    /// "0.0226 mm". Red before: two decimals at any size read "0.01 · 0.04", "0.00" (a grain written as nothing) and "0.02 mm".
    func testAFineStepKeepsThreeFiguresOfItsSmallestLength() throws {
        XCTAssertEqual([10.7, 1.128, 0.999, 0.5, 0.0113, 0.00451].map { MapsRoomFormat.lengthPlaces(smallest: $0) }, [2, 2, 3, 3, 4, 5])
        XCTAssertEqual([0, -1, Double.nan, Double.infinity].map { MapsRoomFormat.lengthPlaces(smallest: $0) }, [2, 2, 2, 2])

        // A 10 nm step in µm: a one-point grain (ECD 2√(10⁻⁴/π) = 0.01128 µm) beside the other fifteen points (0.04370 µm).
        let tkd = try niAnalysis(step: 0.01, unit: "um", odd: true)
        XCTAssertEqual(tkd.table.count, 2)
        let places = MapsRoomFormat.lengthPlaces(tkd)
        XCTAssertEqual(places, 4)
        XCTAssertEqual(tkd.table.map { MapsRoomFormat.length($0.diameter, places: places, locale: en) }.sorted(), ["0.0113", "0.0437"])
        XCTAssertTrue(MapsRoomFormat.grainSummary(tkd, locale: en).hasPrefix("2 grains · mean ECD 0.0275 µm"), MapsRoomFormat.grainSummary(tkd, locale: en))
        let rows = Dictionary(MapsRoomFormat.grainRows(tkd, locale: de).map { ($0.label, $0.value) }, uniquingKeysWith: { first, _ in first })
        XCTAssertEqual(rows["Mean ECD"], "0,0275 µm")
        if let mean = tkd.meanDiameter { XCTAssertEqual(rows["Area-weighted"], "\(UnitDisplay.fixed(mean.byArea, places: 4, locale: de)) µm") }
        if let intercept = tkd.meanLinealIntercept {
            XCTAssertEqual(rows["Mean intercept"], "\(UnitDisplay.fixed(intercept, places: 4, locale: de)) µm")
        }

        // A 1 nm step: one grain of ECD 0.004514 µm, where two decimals wrote "0.00".
        let fine = try niAnalysis(step: 0.001, unit: "um")
        XCTAssertEqual(MapsRoomFormat.lengthPlaces(fine), 5)
        XCTAssertTrue(MapsRoomFormat.grainSummary(fine, locale: en).hasPrefix("1 grain · mean ECD 0.00451 µm"), MapsRoomFormat.grainSummary(fine, locale: en))

        // An mm map at a 5 µm step: ECD 0.02257 mm.
        let mm = try niAnalysis(step: 0.005, unit: "mm")
        XCTAssertTrue(MapsRoomFormat.grainSummary(mm, locale: en).hasPrefix("1 grain · mean ECD 0.0226 \(EBSDBrowsing.unitLabel("mm"))"),
                      MapsRoomFormat.grainSummary(mm, locale: en))
    }

    /// The orientation pane's angles are the status line's: one decimal through `UnitDisplay.fixed`, so the decimal tie 0.35° reads "0.3"
    /// as printf rounds it and a file's -0.04° reads "0.0". Red before: FormatStyle wrote them "0.4" and "-0.0" beside the line's "0.3"
    /// and "0.0".
    func testTheOrientationPaneWritesTheStatusLinesAngles() {
        let perRadian = 180 / Double.pi
        let radians = SIMD3<Double>(0.35 / perRadian, 0.2, -0.0007)
        XCTAssertEqual(MapsRoomFormat.eulerText(radians, locale: en), "φ₁ 0.3°  Φ 11.5°  φ₂ 0.0°")
        XCTAssertEqual(MapsRoomFormat.eulerText(radians, locale: de), "φ₁ 0,3°  Φ 11,5°  φ₂ 0,0°")
    }

    /// The phase rows, the phase legend and the histogram's spoken label count one in the singular. Red before: "1 points" and "1 values
    /// in 1 bins".
    func testTheMapsCountsReadOneInTheSingular() {
        let ni = CrystalPhase(name: "Ni", spaceGroup: 225, pointGroup: "m-3m")
        XCTAssertEqual(MapsRoomFormat.phasePoints(ni, count: 1), "m-3m · 1 point")
        XCTAssertEqual(MapsRoomFormat.phasePoints(ni, count: 3812), "m-3m · 3812 points", "never grouped")
        XCTAssertEqual(MapsRoomFormat.phasePoints(CrystalPhase(name: "x"), count: 2), "no point group · 2 points")
        XCTAssertEqual(MapsRoomFormat.phasePoints(CrystalPhase(name: "x"), count: 2, missing: UnitDisplay.noValue), "— · 2 points")
        XCTAssertEqual(MapsRoomFormat.histogramSpoken(.kam, histogram: AngleHistogram(values: [0.5], edges: [0, 1])),
                       "Histogram of KAM, 1 value in 1 bin")
        XCTAssertEqual(MapsRoomFormat.histogramSpoken(.kam, histogram: AngleHistogram(values: [0.5, 1.5, 1.6], edges: [0, 1, 2])),
                       "Histogram of KAM, 3 values in 2 bins")
    }

    /// The Maps and Patterns rooms' typed fields share `Num`'s styles and never group: "12345" where a German field read "12.345", a
    /// whole number that reads as twelve. The Patterns stages keep six significant digits, Simulation's Min d and the Maps angles four.
    /// Red before: every style grouped, and the Patterns room kept its own.
    func testTheTypedFieldsShareOneStyleAndNeverGroup() {
        XCTAssertEqual(12_345.0.formatted(Num.wholeField.locale(de)), "12345")
        XCTAssertEqual(12_345.0.formatted(Num.wholeField.locale(en)), "12345")
        XCTAssertEqual(1234.56.formatted(Num.decimalField.locale(de)), "1235")
        XCTAssertEqual(0.123456.formatted(Num.decimalField.locale(de)), "0,1235")
        XCTAssertEqual(1234.5678.formatted(PatternsProcessingSections.number.locale(de)), "1234,57")
        XCTAssertEqual(1234.5678.formatted(PatternsProcessingSections.number.locale(en)), "1234.57")
        XCTAssertEqual(PatternsProcessingSections.number, Num.significantField(6))
        XCTAssertEqual(MapsRoomFormat.decimal, Num.decimalField)
        XCTAssertEqual(MapsRoomFormat.whole, Num.wholeField)
    }

    /// The Patterns room's status line and Info rows take the locale they are given, never grouped. Red before: no locale to pass.
    func testThePatternsReadoutsTakeTheLocale() {
        XCTAssertEqual(EBSDBrowsing.mapReadout(EBSDPosition(row: 1, column: 2), mean: 118.3, map: (label: "r2 c1", value: 12_034.5), locale: de),
                       "row 1 · col 2 · mean 118,3 · r2 c1 12034,5")
        XCTAssertEqual(EBSDBrowsing.mapReadout(EBSDPosition(row: 1, column: 2), mean: 118.3, map: (label: "r2 c1", value: 12_034.5), locale: en),
                       "row 1 · col 2 · mean 118.3 · r2 c1 12034.5")
        XCTAssertEqual(EBSDBrowsing.patternReadout(x: 10, y: 20, value: 1234.5, locale: de), "x 10, y 20 · 1234,5")
        XCTAssertEqual(EBSDBrowsing.patternReadout(x: 10, y: 20, value: 1234.5, locale: en), "x 10, y 20 · 1234.5")
    }
}
