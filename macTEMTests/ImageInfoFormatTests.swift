//
//  ImageInfoFormatTests.swift
//  Pins the Info and Settings rows' wording (`ImageInfoFormat`): sampling "<scale> <unit>/px" or "Not calibrated",
//  axis "<scale> <unit>/px · origin <origin> px" or "No calibration" / "(no unit)", and the value range "lo … hi",
//  for the planted fixture's axes, an uncalibrated axis, µm (U+00B5) passing through as written, and 1/nm shown
//  as nm⁻¹. Numbers go through `UnitDisplay.number` in the reader's locale, so each expected
//  string spells its numbers the same way; the en_US_POSIX spelling of those numbers is pinned once, separately.
//

import ImagoCore
import XCTest
import TEMCore
@testable import macTEM

nonisolated final class ImageInfoFormatTests: XCTestCase {

    /// The planted fixture's axes as the reader returns them (float32 scales widened to Double).
    private static let plantedX = AxisCalibration(scale: Double(Float(bitPattern: 0x3c49_85f0)), unit: "nm", origin: 12)
    private static let plantedY = AxisCalibration(scale: Double(Float(bitPattern: 0x3cc9_85f0)), unit: "nm", origin: -4.5)

    private static func n(_ value: Double) -> String { UnitDisplay.number(value) }

    func testThePlantedScalesDisplayAsTheirDecimalsAtSixSignificantDigits() {
        let posix = Locale(identifier: "en_US_POSIX")
        XCTAssertEqual(UnitDisplay.number(Self.plantedX.scale, locale: posix), "0.0123")
        XCTAssertEqual(UnitDisplay.number(Self.plantedY.scale, locale: posix), "0.0246")
        XCTAssertEqual(UnitDisplay.number(-4.5, locale: posix), "-4.5")
        XCTAssertEqual(UnitDisplay.number(-12000, locale: posix), "-12000", "no grouping")
    }

    @MainActor func testThePlantedAxesRead() {
        XCTAssertEqual(ImageInfoFormat.sampling(Self.plantedX), "\(Self.n(Self.plantedX.scale)) nm/px")
        XCTAssertEqual(ImageInfoFormat.sampling(Self.plantedY), "\(Self.n(Self.plantedY.scale)) nm/px")
        XCTAssertEqual(ImageInfoFormat.axis(Self.plantedX),
                       "\(Self.n(Self.plantedX.scale)) nm/px · origin \(Self.n(12)) px")
        XCTAssertEqual(ImageInfoFormat.axis(Self.plantedY),
                       "\(Self.n(Self.plantedY.scale)) nm/px · origin \(Self.n(-4.5)) px")
        // The planted pixels run from -12000 to 23 * 1000 + 39 - 12000.
        XCTAssertEqual(ImageInfoFormat.range(-12000, 11039), "\(Self.n(-12000)) … \(Self.n(11039))")
    }

    /// The range is printed at 9 significant digits: an integer image's extremes (exact in Float32 up to 2^24)
    /// print exactly, where 6 digits showed 1234567 as 1234570 — a value not in the file.
    @MainActor func testTheValueRangeOfAnIntegerImageIsExact() {
        let posix = Locale(identifier: "en_US_POSIX")
        XCTAssertEqual(UnitDisplay.number(1_234_567, digits: 9, locale: posix), "1234567")
        XCTAssertEqual(ImageInfoFormat.range(0, 1_234_567),
                       "\(UnitDisplay.number(0, digits: 9)) … \(UnitDisplay.number(1_234_567, digits: 9))")
        XCTAssertTrue(ImageInfoFormat.range(0, 16_777_216).hasSuffix("16777216"), "2^24")
    }

    /// A negative scale is not a length per pixel: the sampling row agrees with the scale bar, which counts pixels.
    @MainActor func testANegativeScaleIsNotACalibration() {
        let negative = AxisCalibration(scale: -0.0123, unit: "nm", origin: 0)
        XCTAssertEqual(ImageInfoFormat.sampling(negative), "Not calibrated")
        XCTAssertEqual(ImageInfoFormat.axis(negative), "\(Self.n(-0.0123)) nm/px · origin \(Self.n(0)) px",
                       "the axis row still shows what the file stores")
    }

    @MainActor func testAnUncalibratedAxisSaysSo() {
        XCTAssertEqual(ImageInfoFormat.sampling(nil), "Not calibrated")
        XCTAssertEqual(ImageInfoFormat.axis(nil), "No calibration")
        // A scale with no unit is not a calibration for the sampling row, but the axis row still shows what is stored.
        let unitless = AxisCalibration(scale: 1, unit: "", origin: 0)
        XCTAssertEqual(ImageInfoFormat.sampling(unitless), "Not calibrated")
        XCTAssertEqual(ImageInfoFormat.axis(unitless), "\(Self.n(1)) (no unit)/px · origin \(Self.n(0)) px")
    }

    @MainActor func testMicrometresPassThroughAsWritten() {
        let micro = AxisCalibration(scale: 0.75, unit: "\u{00B5}m", origin: 2)
        XCTAssertEqual(ImageInfoFormat.sampling(micro), "\(Self.n(0.75)) \u{00B5}m/px")
        XCTAssertEqual(ImageInfoFormat.axis(micro), "\(Self.n(0.75)) \u{00B5}m/px · origin \(Self.n(2)) px")
        XCTAssertFalse(ImageInfoFormat.sampling(micro).unicodeScalars.contains("\u{03BC}"),
                       "MICRO SIGN is not rewritten as GREEK SMALL LETTER MU")
    }

    @MainActor func testReciprocalNanometresShowAsNmInverse() {
        let reciprocal = AxisCalibration(scale: 0.05, unit: "1/nm", origin: 128)
        XCTAssertEqual(ImageInfoFormat.sampling(reciprocal), "\(Self.n(0.005)) Å⁻¹/px")
        XCTAssertEqual(ImageInfoFormat.axis(reciprocal), "\(Self.n(0.005)) Å⁻¹/px · origin \(Self.n(128)) px")
    }
}
