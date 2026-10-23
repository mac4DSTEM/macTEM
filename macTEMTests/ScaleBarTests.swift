//
//  ScaleBarTests.swift
//  Pins the scale bar's numbers: `ScaleBarMath.nice125` at every mantissa boundary (and powers of ten, sub-1 values,
//  non-positive and non-finite input), `ScaleBar.format`'s three regimes, `ScaleBar.footerSampling`'s pixel
//  fallback and its use of the COLUMN (x) sampling, and `ImageScaleBar` — the functions `ImagePane` itself calls —
//  against hand-computed numbers on the committed planted fixture: the units per point at zoom 1 and 4, and the
//  label the bar then carries (0.05 nm, then 0.01 nm); an uncalibrated or negatively scaled x axis counts pixels.
//

import ShellControls
import ShellLayout
import ImagoCore
import XCTest
import TEMCore
@testable import macTEM

nonisolated final class ScaleBarTests: XCTestCase {

    @MainActor func testNice125RoundsAtEachMantissaBoundary() {
        // Exponent 0, where the mantissa is the value itself, and exponent 1, where value / 10 is exact.
        let cases: [(Double, Double)] = [
            (1.49, 1), (1.5, 2), (3.49, 2), (3.5, 5), (7.49, 5), (7.5, 10),
            (14.9, 10), (15, 20), (34.9, 20), (35, 50), (74.9, 50), (75, 100),
        ]
        for (value, nice) in cases {
            XCTAssertEqual(ScaleBarMath.nice125(value), nice, "nice125(\(value))")
        }
    }

    @MainActor func testNice125KeepsPowersOfTenAndScalesBelowOne() {
        let cases: [(Double, Double)] = [
            (1, 1), (10, 10), (100, 100), (1000, 1000), (0.1, 0.1), (0.001, 0.001),
            (0.3, 0.2), (0.043, 0.05), (0.0107, 0.01), (0.861, 1), (0.00012, 0.0001), (0.0008, 0.001),
        ]
        for (value, nice) in cases {
            XCTAssertEqual(ScaleBarMath.nice125(value), nice, accuracy: nice * 1e-12, "nice125(\(value))")
        }
        for bad in [0, -3, Double.nan, .infinity, -.infinity] {
            XCTAssertEqual(ScaleBarMath.nice125(bad), 1, "nice125(\(bad))")
        }
    }

    @MainActor func testFormatHasThreeRegimes() {
        // "%.0f" at 10 and above, "%g" from 1 to 10, "%.3g" below 1.
        let cases: [(Double, String)] = [
            (10, "10"), (20, "20"), (100, "100"), (1000, "1000"), (20_000, "20000"),
            (1, "1"), (2, "2"), (5, "5"), (2.5, "2.5"), (9.5, "9.5"),
            (0.5, "0.5"), (0.2, "0.2"), (0.05, "0.05"), (0.002, "0.002"), (0.0001, "0.0001"), (0.123456, "0.123"),
        ]
        let posix = Locale(identifier: "en_US_POSIX")
        for (value, text) in cases {
            XCTAssertEqual(ScaleBar.format(value, locale: posix), text, "format(\(value))")
        }
        // On screen the bar follows the reader's locale: only the decimal separator changes.
        XCTAssertEqual(ScaleBar.format(2.5, locale: Locale(identifier: "de_DE")), "2,5")
        XCTAssertEqual(ScaleBar.format(0.05, locale: Locale(identifier: "de_DE")), "0,05")
        XCTAssertEqual(ScaleBar.format(20, locale: Locale(identifier: "de_DE")), "20")
    }

    @MainActor func testTheBarFallsBackToPixelsWhenXIsNotAPhysicalSampling() {
        func label(_ x: AxisCalibration?, _ y: AxisCalibration? = nil, _ line: UInt = #line) -> (perPixel: Double, label: String) {
            let image = CalibratedImage(width: 8, height: 8, pixels: [Float](repeating: 0, count: 64), x: x, y: y, fileName: "a",
                                        source: "", voltage: nil)
            return ImageScaleBar.sampling(image)
        }
        let nm = AxisCalibration(scale: 0.5, unit: "nm", origin: 0)
        for x in [AxisCalibration(scale: 0.5, unit: "", origin: 0), AxisCalibration(scale: 0, unit: "nm", origin: 0),
                  AxisCalibration(scale: -0.5, unit: "nm", origin: 0), AxisCalibration(scale: .nan, unit: "nm", origin: 0),
                  AxisCalibration(scale: .infinity, unit: "nm", origin: 0)] {
            let s = label(x, nm)
            XCTAssertEqual(s.perPixel, 1, "\(x)")
            XCTAssertEqual(s.label, "px", "\(x)")
        }
        XCTAssertEqual(label(nil, nm).label, "px", "the unit is x's: no x, the bar counts pixels")
    }

    @MainActor func testTheBarMeasuresTheColumnSamplingAndSpellsItsUnit() {
        func sampling(_ x: AxisCalibration?, _ y: AxisCalibration?) -> (perPixel: Double, label: String) {
            ImageScaleBar.sampling(CalibratedImage(width: 8, height: 8, pixels: [Float](repeating: 0, count: 64), x: x, y: y,
                                                   fileName: "a", source: "", voltage: nil))
        }
        let along = sampling(AxisCalibration(scale: 0.0123, unit: "nm", origin: 0), AxisCalibration(scale: 0.0246, unit: "nm", origin: 0))
        XCTAssertEqual(along.perPixel, 0.0123, "the bar is horizontal: it measures x, the column sampling")
        XCTAssertEqual(along.label, "nm")
        let reciprocal = sampling(AxisCalibration(scale: 0.05, unit: "1/nm", origin: 0), nil)
        XCTAssertEqual(reciprocal.label, "nm⁻¹")
        let micro = sampling(AxisCalibration(scale: 0.25, unit: "\u{00B5}m", origin: 0), nil)
        XCTAssertEqual(micro.label, "\u{00B5}m", "an unrecognised unit is shown as written")
    }

    /// The planted fixture is 40 × 24 with x = 0.0123 nm/px (stored as float32: 0.012299999594688416) and
    /// y = 0.0246 nm/px. In an 800 × 600 pane it is drawn in an 800 × 480 box, 40 columns across 800 points.
    /// By hand: units per point = 0.012299999594688416 × 40 / 800 / zoom = 6.149999797344208e-4 / zoom; the bar's
    /// 1-2-5 length nearest 70 points is then 0.05 nm at zoom 1 (70 pt ≈ 0.043 nm) and 0.01 nm at zoom 4
    /// (70 pt ≈ 0.0108 nm). These are the numbers `ImagePane` hands `ScaleBar`, through the same two functions.
    @MainActor func testThePanesScaleBarOnThePlantedFixtureMatchesTheHandComputation() throws {
        let url = try XCTUnwrap(Bundle(for: ScaleBarTests.self).url(forResource: "planted-2d", withExtension: "dm4"))
        let image = try ImageOpening.openNow(path: url.path)
        let box = LayoutPolicy.fitted(in: CGSize(width: 800, height: 600),
                                      aspect: CGFloat(image.width) / CGFloat(image.height))
        XCTAssertEqual(box, CGSize(width: 800, height: 480))
        let sampling = ImageScaleBar.sampling(image)
        XCTAssertEqual(sampling.perPixel, 0.012299999594688416, "x's scale, not y's 0.0246")
        XCTAssertEqual(sampling.label, "nm")

        for (zoom, expected, label) in [(1.0, 6.149999797344208e-4, "0.05 nm"), (4.0, 1.537499949336052e-4, "0.01 nm")] {
            let unitsPerPoint = ImageScaleBar.unitsPerPoint(perPixel: sampling.perPixel, imageWidth: image.width,
                                                            boxWidth: box.width, zoom: CGFloat(zoom))
            XCTAssertEqual(unitsPerPoint, expected, accuracy: expected * 1e-12, "zoom \(zoom)")
            let nice = ScaleBarMath.nice125(unitsPerPoint * 70)
            XCTAssertEqual("\(ScaleBar.format(nice, locale: Locale(identifier: "en_US_POSIX"))) \(sampling.label)", label,
                           "zoom \(zoom)")
            let lengthPt = nice / unitsPerPoint
            XCTAssertGreaterThan(lengthPt, 40, "zoom \(zoom)")
            XCTAssertLessThanOrEqual(lengthPt, 100, "zoom \(zoom)")
        }
    }

    /// The pane's bar counts pixels whenever x is not a physical sampling, whatever y says.
    @MainActor func testThePanesScaleBarCountsPixelsWhenXIsNotCalibrated() {
        func image(_ x: AxisCalibration?) -> CalibratedImage {
            CalibratedImage(width: 4, height: 2, pixels: Array(repeating: 0, count: 8), x: x,
                            y: AxisCalibration(scale: 0.5, unit: "nm", origin: 0), fileName: "a.dm4", source: "s", voltage: nil)
        }
        for x in [nil, AxisCalibration(scale: 1, unit: "", origin: 0), AxisCalibration(scale: -0.0123, unit: "nm", origin: 0)] {
            let sampling = ImageScaleBar.sampling(image(x))
            XCTAssertEqual(sampling.perPixel, 1, "\(String(describing: x))")
            XCTAssertEqual(sampling.label, "px", "\(String(describing: x))")
        }
    }
}
