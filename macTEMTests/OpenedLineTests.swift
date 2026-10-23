//
//  OpenedLineTests.swift
//  Pins the status line an open writes (`AppState.openedLine`, also the Output log's line): "Opened <file> —
//  <w> × <h> px, <x scale> <unit>/px", or "…, not calibrated" when the x axis is absent or has no unit. The unit is
//  shown with `UnitDisplay.label` (1/nm as nm⁻¹); the x axis decides, whatever y says. And the
//  canvas an open builds (`AppState.canvas(for:)`): its finite value range, or none when no value is finite.
//

import ShellLayout
import XCTest
import ImagoCore
import TEMCore
import TEMSession
@testable import macTEM

nonisolated final class OpenedLineTests: XCTestCase {

    private static func image(_ x: AxisCalibration?, _ y: AxisCalibration?, file: String = "Au_rings.dm4") -> CalibratedImage {
        CalibratedImage(width: 40, height: 24, pixels: [Float](repeating: 0, count: 960), x: x, y: y,
                        fileName: file, source: "ImageList.2 · planted", voltage: 200_000)
    }
    private static func n(_ value: Double) -> String { UnitDisplay.number(value) }

    func testACalibratedImageNamesItsFileSizeAndXSampling() {
        let x = AxisCalibration(scale: Double(Float(0.0123)), unit: "nm", origin: 12)
        let y = AxisCalibration(scale: Double(Float(0.0246)), unit: "nm", origin: -4.5)
        XCTAssertEqual(AppState.openedLine(Self.image(x, y, file: "planted-2d.dm4")),
                       "Opened planted-2d.dm4 — 40 × 24 px, \(Self.n(x.scale)) nm/px")
        XCTAssertEqual(UnitDisplay.number(x.scale, locale: Locale(identifier: "en_US_POSIX")),
                       "0.0123")
    }

    func testAReciprocalUnitIsShownInAngstromInverse() {
        let x = AxisCalibration(scale: 0.05, unit: "1/nm", origin: 0)
        XCTAssertEqual(AppState.openedLine(Self.image(x, x)), "Opened Au_rings.dm4 — 40 × 24 px, \(Self.n(0.005)) Å⁻¹/px")
    }

    func testAnUncalibratedImageSaysSo() {
        XCTAssertEqual(AppState.openedLine(Self.image(nil, nil)), "Opened Au_rings.dm4 — 40 × 24 px, not calibrated")
        let unitless = AxisCalibration(scale: 0.5, unit: "", origin: 0)
        XCTAssertEqual(AppState.openedLine(Self.image(unitless, unitless)),
                       "Opened Au_rings.dm4 — 40 × 24 px, not calibrated", "a scale with no unit is not a calibration")
        // The line reports the x sampling: a calibrated y does not stand in for a missing x.
        let y = AxisCalibration(scale: 0.5, unit: "nm", origin: 0)
        XCTAssertEqual(AppState.openedLine(Self.image(nil, y)), "Opened Au_rings.dm4 — 40 × 24 px, not calibrated")
        let negative = AxisCalibration(scale: -0.5, unit: "nm", origin: 0)
        XCTAssertEqual(AppState.openedLine(Self.image(negative, y)), "Opened Au_rings.dm4 — 40 × 24 px, not calibrated",
                       "a negative scale is not a length per pixel (AxisCalibration.isCalibrated)")
    }

    /// The canvas an open builds: normalised over the finite range, the range reported, and no range at all — not
    /// the 0 … 1 that `finiteMinMax` falls back to — when the image holds no finite value; and the histogram of the raw
    /// pixels. Mutation (red): `IntensityHistogram.compute(normalized)` for `compute(image.pixels)` in `canvas(for:)`.
    func testTheCanvasReportsTheFiniteRangeOrNone() {
        func image(_ pixels: [Float]) -> CalibratedImage {
            CalibratedImage(width: pixels.count, height: 1, pixels: pixels, x: nil, y: nil, fileName: "a.dm4",
                            source: "s", voltage: nil)
        }
        let mixed = AppState.canvas(for: image([-2, .nan, 6, .infinity]))
        XCTAssertEqual(mixed.rawRange, -2...6)
        XCTAssertEqual(mixed.normalized[0], 0)
        XCTAssertEqual(mixed.normalized[2], 1)
        XCTAssertEqual(mixed.normalized[1], FloatImage.invalidDisplayValue, "a non-finite pixel is drawn masked")
        // The histogram is of the RAW pixels (V1-4, Gate B 2026-10-13 F1): histogramming the canvas would give −1…1,
        // four values (the masked sentinel counted) and a mean of −0.25.
        let histogram = try? XCTUnwrap(mixed.histogram)
        XCTAssertEqual(histogram?.minimum, -2)
        XCTAssertEqual(histogram?.maximum, 6)
        XCTAssertEqual(histogram?.finiteCount, 2)
        XCTAssertEqual(histogram?.mean, 2)
        let none = AppState.canvas(for: image([.nan, .nan, -.infinity]))
        XCTAssertNil(none.rawRange, "no finite value, no range")
        XCTAssertNil(none.histogram, "no finite value, no histogram")
        XCTAssertEqual(none.normalized, Array(repeating: FloatImage.invalidDisplayValue, count: 3))
    }

    /// The infobar's glance is the memory figure alone (ADR 011: the chip's name never changes and tells nothing), in
    /// Finder's decimal style. Mutations (each red): the engine's name put back in front; GB read in MB; `>=` made `>` at
    /// the 1 GB boundary.
    @MainActor
    func testTheGlanceIsTheMemoryFigureAlone() {
        XCTAssertEqual(OperationMetricsFormat.glance(residentMB: 512.4), "512 MB")
        XCTAssertEqual(OperationMetricsFormat.glance(residentMB: 1400), "1.4 GB")
        XCTAssertEqual(OperationMetricsFormat.glance(residentMB: 1000), "1.0 GB", "exactly 1 GB reads in the coarser unit")
    }
}
