//
//  DisplaySamplingTests.swift
//  Pins how a calibration in metres is SHOWN (`DisplaySampling`): the Ceta TIFF of the shell drive (4.46179e-11 m
//  per pixel, 2048 wide) reads 0.0446179 nm/px in the Info and Settings rows and the status line, and its scale bar
//  measures in nm — the same physical length, never "1e-08 m"; an SEM-sized field (1e-8 m per pixel, 1536 wide)
//  reads 10 nm/px but its bar in µm; a 2 mm pixel reads 2 mm/px; every other unit passes through unchanged.
//  Mutations each test must go red under: the rescale dropped (×1 for ×1e9), the bar's reference taken per pixel
//  instead of the image's width, the metre spelling not recognised, the calibration guard dropped, the mm factor ×1.
//

import ImagoCore
import XCTest
import TEMCore
@testable import macTEM

nonisolated final class DisplaySamplingTests: XCTestCase {

    private static let ceta = AxisCalibration(scale: 4.46179e-11, unit: "m", origin: 0)
    private static let sem = AxisCalibration(scale: 1e-8, unit: "m", origin: 0)

    private static func image(_ x: AxisCalibration?, width: Int, height: Int) -> CalibratedImage {
        CalibratedImage(width: width, height: height, pixels: [Float](repeating: 0, count: width * height),
                        x: x, y: x, fileName: "Camera Ceta.tif", source: "TIFF", voltage: nil)
    }
    private static func n(_ value: Double) -> String { UnitDisplay.number(value) }

    func testAMetrePixelReadsInNanometresAndKeepsItsLength() throws {
        let shown = try XCTUnwrap(DisplaySampling.perPixel(Self.ceta))
        XCTAssertEqual(shown.unit, "nm")
        XCTAssertEqual(shown.scale, 0.0446179, accuracy: 0.0446179 * 1e-12)
        XCTAssertEqual(shown.origin, 0)
        XCTAssertEqual(UnitDisplay.number(shown.scale, locale: Locale(identifier: "en_US_POSIX")),
                       "0.0446179")
    }

    @MainActor func testTheInfoAndSettingsRowsOfAMetreAxisReadInNanometres() {
        XCTAssertEqual(ImageInfoFormat.sampling(Self.ceta), "\(Self.n(0.0446179)) nm/px")
        XCTAssertEqual(ImageInfoFormat.axis(Self.ceta), "\(Self.n(0.0446179)) nm/px · origin \(Self.n(0)) px")
        XCTAssertEqual(ImageInfoFormat.sampling(Self.sem), "\(Self.n(10)) nm/px", "an SEM pixel still reads in nm")
    }

    func testTheStatusLineOfAMetreImageReadsInNanometres() {
        XCTAssertEqual(AppState.openedLine(Self.image(Self.ceta, width: 4, height: 2)),
                       "Opened Camera Ceta.tif — 4 × 2 px, \(Self.n(0.0446179)) nm/px")
    }

    /// The bar takes the unit the image's width reads in: 2048 × 4.46179e-11 m = 91 nm → nm, and the length it
    /// draws is the same physical length (per pixel × 1e-9 m = the file's metres).
    @MainActor func testTheScaleBarOfACetaImageMeasuresInNanometres() {
        let sampling = ImageScaleBar.sampling(Self.image(Self.ceta, width: 2048, height: 2))
        XCTAssertEqual(sampling.label, "nm")
        XCTAssertEqual(sampling.perPixel * 1e-9, Self.ceta.scale, accuracy: Self.ceta.scale * 1e-12)
    }

    /// 1536 × 1e-8 m = 15.4 µm: the bar measures in µm while the per-pixel row stays in nm.
    @MainActor func testTheScaleBarOfAnSEMFieldMeasuresInMicrometres() {
        let sampling = ImageScaleBar.sampling(Self.image(Self.sem, width: 1536, height: 2))
        XCTAssertEqual(sampling.label, "µm")
        XCTAssertEqual(sampling.perPixel, 0.01, accuracy: 0.01 * 1e-12)
    }

    func testTheLadderOfUnits() {
        XCTAssertEqual(DisplaySampling.unit(forMetres: 9.9e-7).label, "nm")
        XCTAssertEqual(DisplaySampling.unit(forMetres: 1e-6).label, "µm")
        XCTAssertEqual(DisplaySampling.unit(forMetres: 9.9e-4).label, "µm")
        XCTAssertEqual(DisplaySampling.unit(forMetres: 1e-3).label, "mm")
        for spelling in ["m", "M", " metre ", "meters"] {
            XCTAssertTrue(DisplaySampling.isMetres(spelling), spelling)
        }
        XCTAssertFalse(DisplaySampling.isMetres("mm"))
        XCTAssertFalse(DisplaySampling.isMetres("mrad"))
    }

    /// A pixel of 1 mm or more reads in mm, rescaled ×1e3 (the review's gap: the factor was unpinned).
    func testAMillimetrePixelReadsInMillimetres() throws {
        let shown = try XCTUnwrap(DisplaySampling.perPixel(AxisCalibration(scale: 0.002, unit: "m", origin: 3)))
        XCTAssertEqual(shown.unit, "mm")
        XCTAssertEqual(shown.scale, 2, accuracy: 2e-12)
        XCTAssertEqual(shown.origin, 3, "the origin is in pixels")
        XCTAssertEqual(DisplaySampling.unit(forMetres: 0.002).perMetre, 1e3)
    }

    func testEveryOtherUnitPassesThroughUnchanged() {
        for axis in [AxisCalibration(scale: 0.0123, unit: "nm", origin: 12), AxisCalibration(scale: 0.5, unit: "µm", origin: 0),
                     AxisCalibration(scale: 0.05, unit: "1/nm", origin: -4.5), AxisCalibration(scale: 56.79, unit: "Å", origin: 0),
                     AxisCalibration(scale: 1, unit: "", origin: 0), AxisCalibration(scale: -1e-9, unit: "m", origin: 0)] {
            XCTAssertEqual(DisplaySampling.perPixel(axis), axis, "\(axis)")
            XCTAssertEqual(ScaleBarMath.shown(axis, reference: 1e-7), axis, "\(axis)")
        }
        XCTAssertNil(DisplaySampling.perPixel(nil))
    }
}
