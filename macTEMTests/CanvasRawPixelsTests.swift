//
//  CanvasRawPixelsTests.swift
//  macTEM#562: an image's canvas keeps the raw pixels themselves, shared with the image, and the view normalises them on
//  upload (MacEMUI `MetalImageView.PixelScale.raw`). A 19433 × 19320 SEM TIFF held 4.4 GB with a full-size normalised copy
//  beside its pixels. What the canvas answers for display (each value, the whole array, the thumbnail, the quantile
//  window) is still `DisplayNormalization.normalized` of the pixels, value for value.
//

import XCTest
import ImagoCore
import ShellMetal
import TEMCore
import TEMSession
@testable import macTEM

nonisolated final class CanvasRawPixelsTests: XCTestCase {

    /// 230 × 150 with masked values and a spread of values, so the thumbnail boxes are uneven.
    private static let width = 230, height = 150
    private static let pixels: [Float] = (0..<(width * height)).map { i in
        i % 97 == 0 ? .nan : (i % 211 == 0 ? .infinity : Float((i * 7919) % 1013) * 0.37 - 40)
    }

    /// The canvas holds the image's own pixel storage: no copy, so the bytes kept per pixel are the image's alone.
    /// Mutation: a canvas that stores `DisplayNormalization.normalized(pixels)` (a second full-size array).
    func testTheCanvasSharesTheImagesPixelsAndDrawsThemRaw() throws {
        let pixels = Self.pixels
        let canvas = CanvasPixels.make(width: Self.width, height: Self.height, pixels: pixels)
        let shared = pixels.withUnsafeBufferPointer { a in canvas.values.withUnsafeBufferPointer { b in a.baseAddress == b.baseAddress } }
        XCTAssertTrue(shared, "the canvas must keep the image's pixels, not a copy")
        let finite = pixels.filter(\.isFinite)
        let range = try XCTUnwrap(finite.min())...(try XCTUnwrap(finite.max()))
        XCTAssertEqual(canvas.rawRange, range)
        XCTAssertEqual(canvas.scale, .raw(range: range))
    }

    /// Every display value the canvas answers is the kit's normalisation, bit for bit, one at a time and as the whole array.
    func testTheDisplayValuesAreTheKitNormalisation() {
        let canvas = CanvasPixels.make(width: Self.width, height: Self.height, pixels: Self.pixels)
        let reference = DisplayNormalization.normalized(Self.pixels)
        XCTAssertEqual(canvas.normalized.map(\.bitPattern), reference.map(\.bitPattern))
        for i in stride(from: 0, to: reference.count, by: 101) {
            XCTAssertEqual(canvas.normalizedValue(at: i).bitPattern, reference[i].bitPattern, "pixel \(i)")
        }
        let flat = CanvasPixels.make(width: 3, height: 1, pixels: [4, .nan, 4])
        XCTAssertEqual(flat.normalized, DisplayNormalization.normalized([4, .nan, 4]))
        let none = CanvasPixels.make(width: 2, height: 1, pixels: [.nan, .infinity])
        XCTAssertNil(none.rawRange)
        XCTAssertEqual(none.normalized, [FloatImage.invalidDisplayValue, FloatImage.invalidDisplayValue])
    }

    /// The sidebar thumbnail is `Thumbnail.make` of the display values, without building them all first.
    func testTheThumbnailIsTheKitThumbnailOfTheDisplayValues() {
        let canvas = CanvasPixels.make(width: Self.width, height: Self.height, pixels: Self.pixels)
        let reference = Thumbnail.make(normalized: DisplayNormalization.normalized(Self.pixels), width: Self.width, height: Self.height,
                                       maxSide: Thumbnail.defaultMaxSide)
        XCTAssertEqual(canvas.thumbnail(maxSide: Thumbnail.defaultMaxSide), reference)
        let small = CanvasPixels.make(width: 3, height: 2, pixels: [1, 2, 3, .nan, 5, 6])
        XCTAssertEqual(small.thumbnail(), Thumbnail.make(normalized: DisplayNormalization.normalized([1, 2, 3, .nan, 5, 6]), width: 3, height: 2))
    }

    /// The quantile window reads the same display values as before.
    func testTheQuantileWindowIsTheOneOfTheNormalisedCanvas() {
        let raw = CanvasPixels.make(width: Self.width, height: Self.height, pixels: Self.pixels)
        let normalized = CanvasPixels(width: Self.width, height: Self.height, normalized: DisplayNormalization.normalized(Self.pixels),
                                      contentVersion: 0, rawRange: raw.rawRange)
        XCTAssertEqual(DisplayWindow.quantileWindow(of: raw, 0.01...0.99), DisplayWindow.quantileWindow(of: normalized, 0.01...0.99))
    }
}
