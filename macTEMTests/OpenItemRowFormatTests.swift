//
//  OpenItemRowFormatTests.swift
//  Pins the text of the open-files list (V1-13): a row's size-and-calibration line, the spoken sentence, the parent
//  folder that tells two same-named files apart, the formats the open prompt names, and the colour a thumbnail pixel gets.
//  The numbers use the conversions `AppState.openedLine` uses (DisplaySampling + CalibrationUnitConversion).
//

import XCTest
import ImagoCore
import TEMCore
import TEMSession
@testable import macTEM

nonisolated final class OpenItemRowFormatTests: XCTestCase {

    private static func n(_ value: Double) -> String { UnitDisplay.number(value) }

    /// Mutation: write `height × width`; drop the unit conversion (a metre axis prints "4.5e-11 m/px"); print the unit
    /// without `displayLabel` (1/nm instead of nm⁻¹).
    func testTheDetailLineGivesTheSizeAndTheXSampling() {
        let metres = AxisCalibration(scale: 4.5e-11, unit: "m", origin: 0)
        XCTAssertEqual(OpenItemRowFormat.detailLine(width: 2048, height: 1024, x: metres),
                       "2048 × 1024 · \(Self.n(0.045)) nm/px")
        let nm = AxisCalibration(scale: 0.25, unit: "nm", origin: 0)
        XCTAssertEqual(OpenItemRowFormat.detailLine(width: 68, height: 68, x: nm), "68 × 68 · \(Self.n(0.25)) nm/px")
        let reciprocal = AxisCalibration(scale: 0.05, unit: "1/nm", origin: 0)
        XCTAssertEqual(OpenItemRowFormat.detailLine(width: 40, height: 24, x: reciprocal),
                       "40 × 24 · \(Self.n(0.005)) Å⁻¹/px", "a pattern's reciprocal axis is shown in Å⁻¹, the Diffraction room's unit")
        XCTAssertEqual(OpenItemRowFormat.size(width: 2048, height: 1024), "2048 × 1024")
    }

    /// Mutation: skip the `isCalibrated` check (a unitless or negative scale reads as a sampling), or fall back to y.
    func testAnUncalibratedImageSaysSo() {
        XCTAssertEqual(OpenItemRowFormat.detailLine(width: 40, height: 24, x: nil), "40 × 24 · not calibrated")
        let unitless = AxisCalibration(scale: 0.5, unit: "", origin: 0)
        XCTAssertEqual(OpenItemRowFormat.detailLine(width: 40, height: 24, x: unitless), "40 × 24 · not calibrated")
        let negative = AxisCalibration(scale: -0.5, unit: "nm", origin: 0)
        XCTAssertEqual(OpenItemRowFormat.detailLine(width: 40, height: 24, x: negative), "40 × 24 · not calibrated")
    }

    /// Mutation: say "×" for "by", say "nm" for "nanometres", or drop the "per pixel".
    func testTheSpokenSentenceNamesTheFileTheSizeAndTheSampling() {
        let nm = AxisCalibration(scale: 0.25, unit: "nm", origin: 0)
        XCTAssertEqual(OpenItemRowFormat.accessibilityLabel(name: "test_STEM_image.dm3", width: 68, height: 68, x: nm),
                       "test_STEM_image.dm3, 68 by 68 pixels, \(Self.n(0.25)) nanometres per pixel")
        let reciprocal = AxisCalibration(scale: 0.05, unit: "1/nm", origin: 0)
        XCTAssertEqual(OpenItemRowFormat.accessibilityLabel(name: "a.dm4", width: 4, height: 2, x: reciprocal),
                       "a.dm4, 4 by 2 pixels, \(Self.n(0.005)) inverse ångströms per pixel")
        XCTAssertEqual(OpenItemRowFormat.accessibilityLabel(name: "a.dm4", width: 4, height: 2, x: nil),
                       "a.dm4, 4 by 2 pixels, not calibrated")
        let micro = AxisCalibration(scale: 2e-6, unit: "m", origin: 0)
        XCTAssertTrue(OpenItemRowFormat.accessibilityLabel(name: "a", width: 1, height: 1, x: micro)
            .hasSuffix("micrometres per pixel"))
    }

    /// Mutation: always prefix the folder; never prefix it; compare folders instead of names; ignore a repeat of three.
    func testTheFolderIsNamedOnlyWhereTwoOpenFilesShareAName() {
        let ambiguous = OpenItemRowFormat.ambiguousNames(["scan.dm4", "other.dm4", "scan.dm4", "scan.dm4"])
        XCTAssertEqual(ambiguous, ["scan.dm4"])
        XCTAssertEqual(OpenItemRowFormat.title(name: "scan.dm4", folder: "A", isAmbiguous: true), "A/scan.dm4")
        XCTAssertEqual(OpenItemRowFormat.title(name: "other.dm4", folder: "A", isAmbiguous: false), "other.dm4")
        XCTAssertEqual(OpenItemRowFormat.title(name: "scan.dm4", folder: "", isAmbiguous: true), "scan.dm4",
                       "a file with no parent folder name has nothing to prefix")
        XCTAssertEqual(OpenItemRowFormat.ambiguousNames(["a.dm4", "A.dm4"]), [], "names are compared as written")
    }

    /// A sidebar row shows the plain name; where two open files share it, the parent folder leads the second line, and
    /// VoiceOver says it. Mutations (each red): `folder` returning the folder for an unambiguous name; for an empty
    /// folder; `withFolder` appending instead of leading, or using "/" for " · "; `spokenName` dropping the folder.
    func testAnAmbiguousNameShowsItsFolderInTheSecondLine() {
        XCTAssertEqual(OpenItemRowFormat.folder("data", isAmbiguous: true), "data")
        XCTAssertNil(OpenItemRowFormat.folder("data", isAmbiguous: false))
        XCTAssertNil(OpenItemRowFormat.folder("", isAmbiguous: true), "a file with no parent folder name has none to show")
        XCTAssertEqual(OpenItemRowFormat.withFolder("68 × 68 · 0.25 nm/px", folder: "data"), "data · 68 × 68 · 0.25 nm/px")
        XCTAssertEqual(OpenItemRowFormat.withFolder("68 × 68", folder: nil), "68 × 68")
        XCTAssertEqual(OpenItemRowFormat.spokenName(name: "scan.dm4", folder: "data"), "scan.dm4, in data")
        XCTAssertEqual(OpenItemRowFormat.spokenName(name: "scan.dm4", folder: nil), "scan.dm4")
    }

    /// Mutation: drop the "or" before the last, add an Oxford comma, forget the dot.
    func testTheFormatsTheOpenPromptNamesAreBuiltFromTheExtensions() {
        XCTAssertEqual(OpenItemRowFormat.extensionList(["dm4", "dm3", "tif", "tiff", "mrc"]),
                       ".dm4, .dm3, .tif, .tiff or .mrc")
        XCTAssertEqual(OpenItemRowFormat.extensionList(["dm4", "dm3"]), ".dm4 or .dm3")
        XCTAssertEqual(OpenItemRowFormat.extensionList(["dm4"]), ".dm4")
        XCTAssertEqual(OpenItemRowFormat.extensionList([]), "")
        for ext in ImageOpening.readableExtensions {
            XCTAssertTrue(OpenItemRowFormat.openPrompt.contains(".\(ext)"), "the prompt names .\(ext)")
        }
    }

    /// A thumbnail pixel takes the colormap's colour; the masked sentinel is transparent. Mutation: treat −1 as data
    /// (it clamps to the first colour, opaque); swap the colour channels.
    func testAThumbnailPixelTakesTheColormapAndAMaskedOneIsTransparent() throws {
        // A ramp LUT: blue at 0 to red at 1, 256 texels, RGBA.
        var lut = [UInt8](repeating: 255, count: 256 * 4)
        for i in 0..<256 {
            lut[i * 4] = UInt8(i); lut[i * 4 + 1] = 0; lut[i * 4 + 2] = UInt8(255 - i)
        }
        let thumbnail = try XCTUnwrap(Thumbnail(width: 4, height: 1,
                                                normalized: [0, 1, FloatImage.invalidDisplayValue, .nan]))
        let bytes = OpenItemThumbnailPixels.rgba(thumbnail, lut: lut)
        XCTAssertEqual(Array(bytes[0..<4]), [0, 0, 255, 255], "0 is the first colour, opaque")
        XCTAssertEqual(Array(bytes[4..<8]), [255, 0, 0, 255], "1 is the last colour, opaque")
        XCTAssertEqual(Array(bytes[8..<12]), [0, 0, 0, 0], "the invalid sentinel is transparent")
        XCTAssertEqual(Array(bytes[12..<16]), [0, 0, 0, 0], "a non-finite value is transparent")
    }
}
