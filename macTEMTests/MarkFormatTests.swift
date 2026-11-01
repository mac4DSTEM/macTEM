//
//  MarkFormatTests.swift
//  Pins what a mark's value READS as in the Measure section (`MarkFormat`): a distance in the shown
//  unit with its pixel length beside it, an angle with its plane named when it is the pixel grid, a profile with its
//  length, "—" for an angle that has no arm, the reader's decimal mark, the profile chart's positions in the same unit,
//  and what VoiceOver is told. The numbers themselves are TEMCore's (gated against the closed form and scikit-image);
//  this is only their spelling, so every expected string is a literal worked out from the closed form (the comment on
//  each test gives the arithmetic), never read back from the formatter.
//
//  Registered mutations, each named by the test meant to turn it red (applied to a scratch copy of the formatter,
//  compiled bare with `swift test`, 2026-10-13; the lane's log is in the report, not the repo):
//   - the metre axis not converted (shown() returns the file's axes): testAVeloxMetreAxisReadsInNanometres,
//     testAMetrePixelPairAcrossAUnitBoundaryShareOneUnit, testProfilePositionsAreChartedInTheShownUnit
//   - pixels and physical swapped: testACalibratedDistanceNamesBothLengths
//   - the plane label dropped: testAnAngleOnThePixelGridSaysSo
//   - the wrong digit count (4 for 3, 3 for 4): testLengthsKeepFourSignificantDigitsAndAProfileThree
//   - the degenerate angle as 0: testAnAngleWithoutAnArmReadsAsADash
//   - the locale ignored: testTheReadersDecimalMarkIsUsed
//   - a unit per axis (DisplaySampling.perPixel), or the smaller pixel as the pair's reference:
//     testAMetrePixelPairAcrossAUnitBoundaryShareOneUnit
//   - a metre axis dropped to pixels (no physical plane): testAnAngleInMetresIsPhysicalToo
//   - the kind not spoken: testVoiceOverIsToldPixelsAndTheKind
//   - the chart's positions unscaled: testProfilePositionsAreChartedInTheShownUnit
//   - "px" spoken as letters: testVoiceOverIsToldPixelsAndTheKind
//

import ImagoCore
import XCTest
import TEMCore
import TEMSession
@testable import macTEM

nonisolated final class MarkFormatTests: XCTestCase {
    private static let posix = Locale(identifier: "en_US_POSIX")
    private static let german = Locale(identifier: "de_DE")
    private static let micro = "\u{00B5}"   // U+00B5, the micro sign DisplaySampling writes in "µm"

    private static func axis(_ scale: Double, _ units: String) -> AxisCalibration { AxisCalibration(scale: scale, unit: units, origin: 0) }

    private static func mark(_ kind: ImageMark.Kind, _ points: [(Double, Double)]) -> ImageMark {
        ImageMark(kind: kind, points: points.map { ImagePoint(x: $0.0, y: $0.1) })
    }

    private func value(_ mark: ImageMark, _ x: AxisCalibration?, _ y: AxisCalibration?, locale: Locale = posix) -> String {
        MarkFormat.value(mark, x: x, y: y, locale: locale)
    }

    // MARK: Distance

    /// Pixels 0.5 × 0.8 nm, a segment of 6 columns by 5 rows: (3, 4) nm, so exactly 5 nm, and √61 = 7.8102 px.
    func testACalibratedDistanceNamesBothLengths() {
        let distance = Self.mark(.distance, [(0, 0), (6, 5)])
        XCTAssertEqual(value(distance, Self.axis(0.5, "nm"), Self.axis(0.8, "nm")), "5 nm · 7.81 px")
    }

    /// The Ceta TIFF's pixel (4.46179e-11 m, the shell drive): 1000 columns are 44.6179 nm, shown at 4 digits. A file's "m"
    /// is never printed; an SEM-sized pixel (2e-6 m) reads in µm: 500 px of 2 µm is 1000 µm.
    func testAVeloxMetreAxisReadsInNanometres() {
        let ceta = Self.axis(4.46179e-11, "m")
        XCTAssertEqual(value(Self.mark(.distance, [(0, 0), (1000, 0)]), ceta, ceta), "44.62 nm · 1000 px")
        let sem = Self.axis(2e-6, "m")
        XCTAssertEqual(value(Self.mark(.distance, [(0, 0), (300, 400)]), sem, sem),
                       "1000 \(Self.micro)m · 500 px")
    }

    /// A pair whose pixels sit either side of a unit boundary (0.9 and 1.1 µm: nm for one, µm for the other if each axis
    /// chose for itself) shares one unit — the larger pixel's — and keeps its physical length; per-axis units would make
    /// `ImageMeasurement` answer in pixels alone.
    func testAMetrePixelPairAcrossAUnitBoundaryShareOneUnit() {
        let distance = Self.mark(.distance, [(0, 0), (1, 1)])
        XCTAssertEqual(value(distance, Self.axis(9e-7, "m"), Self.axis(1.1e-6, "m")),
                       "1.421 \(Self.micro)m · 1.414 px")
    }

    func testAnUncalibratedDistanceIsPixelsOnly() {
        let distance = Self.mark(.distance, [(0, 0), (12.3, 45.6)])
        XCTAssertEqual(value(distance, nil, nil), "47.23 px")
        XCTAssertEqual(value(distance, Self.axis(0.5, "nm"), nil), "47.23 px", "one axis calibrated is not a length")
    }

    /// 123.456 px at 1 nm per pixel: 4 significant digits for a distance in both lengths, 3 for a profile.
    func testLengthsKeepFourSignificantDigitsAndAProfileThree() {
        let nm = Self.axis(1, "nm")
        XCTAssertEqual(value(Self.mark(.distance, [(0, 0), (123.456, 0)]), nm, nm), "123.5 nm · 123.5 px")
        XCTAssertEqual(value(Self.mark(.profile, [(0, 0), (123.456, 0)]), nm, nm), "Profile · 123 nm")
        XCTAssertEqual(value(Self.mark(.profile, [(0, 0), (123.456, 0)]), nil, nil), "Profile · 123 px")
    }

    // MARK: Angle

    /// A = (10, 0), vertex (0, 0), C = (10, 10) on pixels 1 × 2 nm: arms (10, 0) and (10, 20) nm, atan2(200, 100) =
    /// 63.43°; on the pixel grid the same marks are 45°, and say so.
    func testAnAngleOnThePixelGridSaysSo() {
        let angle = Self.mark(.angle, [(10, 0), (0, 0), (10, 10)])
        XCTAssertEqual(value(angle, Self.axis(1, "nm"), Self.axis(2, "nm")), "63.4°")
        XCTAssertEqual(value(angle, nil, nil), "45.0° (pixel grid)")
        // Two units: no physical plane to take it in.
        XCTAssertEqual(value(angle, Self.axis(1, "nm"), Self.axis(1, "\(Self.micro)m")), "45.0° (pixel grid)")
    }

    func testAnAngleInMetresIsPhysicalToo() {
        let angle = Self.mark(.angle, [(10, 0), (0, 0), (10, 10)])
        XCTAssertEqual(value(angle, Self.axis(1e-10, "m"), Self.axis(2e-10, "m")), "63.4°")
    }

    /// An arm of zero length (the vertex dropped on an end) has no angle: "—", never 0°.
    func testAnAngleWithoutAnArmReadsAsADash() {
        let nm = Self.axis(1, "nm")
        XCTAssertEqual(value(Self.mark(.angle, [(5, 5), (5, 5), (9, 9)]), nm, nm), "—")
        XCTAssertEqual(value(Self.mark(.angle, [(9, 9), (5, 5), (5, 5)]), nil, nil), "—")
    }

    // MARK: The reader

    /// de_DE writes a decimal comma, in every kind; the unit and the pixel grid note stay words.
    func testTheReadersDecimalMarkIsUsed() {
        let nm = Self.axis(0.5, "nm"), nmY = Self.axis(0.8, "nm")
        // Δ = (6.2, 5) px: (3.1, 4.0) nm = 5.0606 nm, 7.9649 px.
        XCTAssertEqual(value(Self.mark(.distance, [(0, 0), (6.2, 5)]), nm, nmY, locale: Self.german),
                       "5,061 nm · 7,965 px")
        XCTAssertEqual(value(Self.mark(.profile, [(0, 0), (6.2, 5)]), nm, nmY, locale: Self.german),
                       "Profile · 5,06 nm")
        let angle = Self.mark(.angle, [(10, 0), (0, 0), (10, 10)])
        XCTAssertEqual(value(angle, Self.axis(1, "nm"), Self.axis(2, "nm"), locale: Self.german), "63,4°")
        XCTAssertEqual(value(angle, nil, nil, locale: Self.german), "45,0° (pixel grid)")
    }

    // MARK: The chart and VoiceOver

    private static func ramp(width: Int = 11, height: Int = 3, x: AxisCalibration?, y: AxisCalibration?) -> CalibratedImage {
        CalibratedImage(width: width, height: height,
                        pixels: (0..<(width * height)).map { Float($0 % width) },
                        x: x, y: y, fileName: "ramp.tif", source: "TIFF", voltage: nil)
    }

    /// A profile of 10 columns on a 4.46179e-11 m pixel is 0.446179 nm long; it is charted in nm, as the list reads it.
    func testProfilePositionsAreChartedInTheShownUnit() throws {
        let from = ImagePoint(x: 0, y: 1), to = ImagePoint(x: 10, y: 1)
        let ceta = Self.axis(4.46179e-11, "m")
        let metres = Self.ramp(x: ceta, y: ceta)
        let profile = LineProfile.sample(metres, from: from, to: to, width: 1)
        let shown = MarkFormat.chartPositions(profile, x: metres.x, y: metres.y)
        XCTAssertEqual(shown.unit, "nm")
        XCTAssertEqual(shown.positions.count, 11)
        XCTAssertEqual(try XCTUnwrap(shown.positions.last), 0.446179, accuracy: 0.446179 * 1e-12)
        XCTAssertEqual(shown.positions.first, 0)

        // A unit the file writes in nm, or as "A", is only spelled: no factor.
        let angstrom = Self.ramp(x: Self.axis(0.2, "A"), y: Self.axis(0.2, "A"))
        let inAngstrom = MarkFormat.chartPositions(LineProfile.sample(angstrom, from: from, to: to, width: 1),
                                                   x: angstrom.x, y: angstrom.y)
        XCTAssertEqual(inAngstrom.unit, "Å")
        XCTAssertEqual(try XCTUnwrap(inAngstrom.positions.last), 2, accuracy: 1e-12)

        let plain = Self.ramp(x: nil, y: nil)
        let inPixels = MarkFormat.chartPositions(LineProfile.sample(plain, from: from, to: to, width: 1),
                                                 x: plain.x, y: plain.y)
        XCTAssertEqual(inPixels.unit, "px")
        XCTAssertEqual(try XCTUnwrap(inPixels.positions.last), 10, accuracy: 1e-12)
    }

    func testTheProfileSummaryCountsLengthAndExtremes() {
        let plain = Self.ramp(x: nil, y: nil)
        let profile = LineProfile.sample(plain, from: ImagePoint(x: 0, y: 1), to: ImagePoint(x: 4, y: 1), width: 1)
        let summary = MarkFormat.profileSummary(profile, positions: profile.positions, unit: "px", locale: Self.posix)
        XCTAssertEqual(summary, "5 samples over 4 pixels; lowest 0, highest 4")
        // A line with a non-finite end has no samples (TEMCore's answer): "No samples", never a crash on min/max.
        let empty = LineProfile.sample(plain, from: ImagePoint(x: .nan, y: 0), to: ImagePoint(x: 4, y: 0), width: 1)
        XCTAssertTrue(empty.samples.isEmpty)
        XCTAssertEqual(MarkFormat.profileSummary(empty, positions: [], unit: "px", locale: Self.posix), "No samples")
    }

    /// The row's spoken form names the kind (a profile's own text already does), reads "px" as "pixels" and the separator
    /// as a pause.
    func testVoiceOverIsToldPixelsAndTheKind() {
        let nm = Self.axis(0.5, "nm"), nmY = Self.axis(0.8, "nm")
        func spoken(_ mark: ImageMark, _ x: AxisCalibration?, _ y: AxisCalibration?) -> String {
            MarkFormat.spoken(mark, x: x, y: y, locale: Self.posix)
        }
        XCTAssertEqual(spoken(Self.mark(.distance, [(0, 0), (6, 5)]), nm, nmY), "Distance, 5 nm, 7.81 pixels")
        XCTAssertEqual(spoken(Self.mark(.distance, [(0, 0), (12.3, 45.6)]), nil, nil), "Distance, 47.23 pixels")
        XCTAssertEqual(spoken(Self.mark(.angle, [(10, 0), (0, 0), (10, 10)]), nil, nil), "Angle, 45.0° (pixel grid)")
        XCTAssertEqual(spoken(Self.mark(.profile, [(0, 0), (12.3, 45.6)]), nil, nil), "Profile, 47.2 pixels")
    }
}
