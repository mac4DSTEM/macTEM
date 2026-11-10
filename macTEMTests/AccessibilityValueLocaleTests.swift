//
//  AccessibilityValueLocaleTests.swift
//  The numbers the Diffraction and FFT rooms hand accessibility (#329): the scale, the half-side shown and a row's d in the Diffraction
//  room, a measured spot's d in the FFT room. VoiceOver speaks them and the UI journeys read them, so they carry the reader's decimal
//  mark like the text beside them, with the digits they had before.
//  Red before the change: no `DiffractionValueFormat`, no `FFTRoomFormat.spacingValue`; the four sites wrote `String(format:)`, which
//  writes a point in every locale, and the three journeys parsed the values with `Double(_:)`, which reads only a point.
//

import XCTest
@testable import macTEM

nonisolated final class AccessibilityValueLocaleTests: XCTestCase {

    private static let en = Locale(identifier: "en_US")
    private static let de = Locale(identifier: "de_DE")

    private func ui(_ name: String) throws -> String { try FFTRoomWiringTests.squeezedUI(name) }

    /// A journey's source (macTEMUITests is not compiled by CI's unit run, so its lines are read as text).
    private func journey(_ name: String) throws -> String {
        let folder = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("macTEMUITests")
        return try String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)
    }

    /// The Diffraction room's three values take the reader's decimal mark and keep their decimals: five for Δq and for d, three for
    /// the half-side. Red under: a point in a comma locale (what VoiceOver spoke under "0,01250"), a grouped half-side, a decimal dropped.
    func testTheDiffractionValuesTakeTheReadersDecimalMark() {
        XCTAssertEqual(DiffractionValueFormat.scale(0.0125, locale: Self.de), "0,01250")
        XCTAssertEqual(DiffractionValueFormat.scale(0.0125, locale: Self.en), "0.01250")
        XCTAssertEqual(DiffractionValueFormat.scale(nil, locale: Self.de), "", "no scale yet, no value")
        XCTAssertEqual(DiffractionValueFormat.halfSide(79.412, locale: Self.de), "79,412")
        XCTAssertEqual(DiffractionValueFormat.halfSide(1024, locale: Self.de), "1024,000", "never grouped")
        XCTAssertEqual(DiffractionValueFormat.halfSide(1024, locale: Self.en), "1024.000")
        XCTAssertEqual(DiffractionValueFormat.spacing(0.2351, locale: Self.de), "0,23510")
        XCTAssertEqual(DiffractionValueFormat.spacing(2.0391, locale: Self.en), "2.03910")
        XCTAssertEqual(DiffractionValueFormat.spacing(nil, locale: Self.en), "", "a row without a d has no value")
    }

    /// A measured spot's d: five significant digits and its unit, the reader's decimal mark.
    /// Red under: a point in a comma locale, the unit dropped (the journey reads it), the row's own four digits.
    func testASpotsSpacingTakesTheReadersDecimalMark() {
        XCTAssertEqual(FFTRoomFormat.spacingValue(d: 0.235142, unit: "nm", locale: Self.de), "0,23514 nm")
        XCTAssertEqual(FFTRoomFormat.spacingValue(d: 0.235142, unit: "nm", locale: Self.en), "0.23514 nm")
        XCTAssertEqual(FFTRoomFormat.spacingValue(d: 19.1, unit: "px", locale: Self.de), "19,1 px")
    }

    /// In a point locale the values are the ones written before (`%.5f`, `%.3f`, `%.5g`): nothing a script read has changed there.
    /// Red under: another precision than before, another rounding.
    func testInAPointLocaleTheValuesAreTheOnesWrittenBefore() {
        let values: [Double] = [0.0125, 0.012625, 0.2351, 1.4419, 2.0391, 79.4125, 256]
        for value in values {
            XCTAssertEqual(DiffractionValueFormat.scale(value, locale: Self.en), String(format: "%.5f", value))
            XCTAssertEqual(DiffractionValueFormat.spacing(value, locale: Self.en), String(format: "%.5f", value))
            XCTAssertEqual(DiffractionValueFormat.halfSide(value, locale: Self.en), String(format: "%.3f", value))
        }
        let spacings: [Double] = [0.2351, 0.235142, 2.03914, 19.1, 120]
        for d in spacings {
            XCTAssertEqual(FFTRoomFormat.spacingValue(d: d, unit: "nm", locale: Self.en), String(format: "%.5g", d) + " nm")
        }
    }

    /// The four sites hand accessibility the formatted value, and neither file writes a number with `String(format:)`, which knows
    /// no locale. Red under: a site back on `String(format:)`, a value moved off the element that carries its identifier.
    func testTheRoomsHandAccessibilityTheLocalisedValues() throws {
        let diffraction = try ui("DiffractionRoom.swift")
        XCTAssertTrue(diffraction.contains(
            ".accessibilityIdentifier(\"diffraction.scale\") .accessibilityValue(DiffractionValueFormat.scale(calibration?.deltaQ))"))
        XCTAssertTrue(diffraction.contains(
            ".accessibilityIdentifier(\"diffraction.view\") .accessibilityValue(DiffractionValueFormat.halfSide(half))"))
        XCTAssertTrue(diffraction.contains(
            ".accessibilityIdentifier(\"diffraction.row.\\(row.kind.rawValue)\\(row.number).d\") .accessibilityValue(DiffractionValueFormat.spacing(row.d))"))
        XCTAssertFalse(diffraction.contains("String(format:"), "a number the Diffraction room writes goes through Num")
        let inspector = try ui("FFTRoomInspector.swift")
        XCTAssertTrue(inspector.contains(
            ".accessibilityIdentifier(spot.measured == nil ? \"\" : \"fft.spotSpacing\") "
                + ".accessibilityValue(spot.measured.map { FFTRoomFormat.spacingValue(d: $0.d, unit: $0.units) } ?? \"\")"))
        XCTAssertFalse(inspector.contains("String(format:"), "a number the FFT inspector writes goes through its format")
    }

    /// The journeys that read these values parse the reader's decimal mark (`Journey.number`), so they pass on a Mac whose region
    /// writes a comma. Red under: a value parsed with `Double(_:)` again, which reads "0,01250" as no number.
    func testTheJourneysParseTheReadersDecimalMark() throws {
        let helper = try journey("Support/JourneyHelpers.swift")
        XCTAssertTrue(helper.contains("nonisolated static func number(_ value: String) -> Double? {"))
        XCTAssertTrue(helper.contains("let mark = Locale.current.decimalSeparator ?? \".\""))
        for name in ["DiffractionJourney.swift", "DemoDataJourney.swift", "FFTJourney.swift"] {
            let text = try journey(name)
            XCTAssertFalse(text.contains("Double("), "\(name) parses a value with Double(_:)")
            XCTAssertTrue(text.contains("Journey.number("), "\(name) reads its values through Journey.number")
        }
    }
}
