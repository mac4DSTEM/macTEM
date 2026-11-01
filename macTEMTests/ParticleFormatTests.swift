//
//  ParticleFormatTests.swift
//  The Particles view writes the numbers a person reads in the locale's decimal mark, never grouped (`UnitDisplay.number`), as the
//  rest of the Image room does; the CSV keeps a point whatever the locale.
//

import XCTest
import TEMCore

nonisolated final class ParticleFormatTests: XCTestCase {
    private let de = Locale(identifier: "de_DE")
    private let us = Locale(identifier: "en_US")

    /// A shown number carries the locale decimal mark: "0,873" in de_DE beside a pixel value of "3657,6". Red under: `%.3g`, always a point.
    func testAShownNumberUsesTheLocaleDecimalMark() {
        XCTAssertEqual(ParticleFormat.number(0.873, locale: de), "0,873")
        XCTAssertEqual(ParticleFormat.number(0.873, locale: us), "0.873")
        XCTAssertEqual(ParticleFormat.number(15.94, locale: de), "15,9", "three significant digits")
    }

    /// Never grouped, and no exponent for a large area: "12300", not "12.300" or "1.23e+04".
    func testAShownNumberIsNeverGrouped() {
        XCTAssertEqual(ParticleFormat.number(12_345, locale: de), "12300")
        XCTAssertEqual(ParticleFormat.number(12_345, locale: us), "12300")
    }

    /// The inspector size line follows the locale. Red under: the line written with a point.
    func testTheSizeLineUsesTheLocaleDecimalMark() {
        var s = ParticleSummary()
        s.total = 3; s.counted = 3; s.medianLengthPx = 3.5; s.meanWidthPx = 1.25
        XCTAssertEqual(ParticleFormat.sizes(s, scale: ParticleScale(perPixel: 0.5, unit: "nm"), locale: de), "median length 1,75 nm · mean width 0,625 nm")
        XCTAssertEqual(ParticleFormat.sizes(s, scale: ParticleScale(perPixel: 0.5, unit: "nm"), locale: us), "median length 1.75 nm · mean width 0.625 nm")
    }

    /// The CSV a script reads keeps a point: its digits are printf's, and it takes no locale.
    func testTheCSVKeepsAPoint() throws {
        let report = try ParticleCompute.analyse(pixels: ParticleTests.planted(), width: ParticleTests.width, height: ParticleTests.height,
                                                 settings: ParticleSettings())
        let csv = ParticleFormat.csv(report, scale: ParticleScale(perPixel: 0.5, unit: "nm"), fileName: "p.dm4")
        XCTAssertTrue(csv.contains("fraction 0.5 of the raw range"), csv)
        XCTAssertTrue(csv.contains("pixel size 0.5 nm/px"), csv)
        XCTAssertEqual(ParticleFormat.csvNumber(0.873), "0.873")
    }
}
