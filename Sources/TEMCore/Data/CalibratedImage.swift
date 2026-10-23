//
//  CalibratedImage.swift
//  Role: macTEM's image — one 2D Float32 image and the calibration of each axis (ImagoKit's `AxisCalibration`: the physical value at pixel i is (i - origin) * scale) exactly as the file
//        states it. Reader-independent: DM3/DM4, TIFF and MRC produce it today; Velox EMD will produce the
//        same value. Nothing here converts, guesses or rounds a calibration: a unit is the file's own
//        string ("nm", "µm" with U+00B5, "1/nm"). An axis is nil when the file writes no calibration for it;
//        GMS writes scale 1 and no unit for an uncalibrated image, which `isCalibrated` reads as uncalibrated.
//

import Foundation
import ImagoCore

package nonisolated struct CalibratedImage: Sendable, Equatable {
    package let width: Int
    package let height: Int
    /// Row-major, `width` fastest; row 0 is the file's first row and is drawn at the top.
    package let pixels: [Float]
    /// Calibration along columns (x, the file's fastest axis) and rows (y); nil when the file has none.
    package let x: AxisCalibration?
    package let y: AxisCalibration?
    /// The file's name, never its folders (`formatoDisplayFileName`).
    package let fileName: String
    /// Which object of a multi-object file this is, as the reader names it ("ImageList.2 · HAADF").
    package let source: String
    /// Accelerating voltage in volts as the file stores it; nil when absent.
    package let voltage: Double?
    /// What a reader must say about this image beyond its numbers, in its own words ("8-bit render, not
    /// counts", "scale unvalidated (one acquisition)"). Empty for a file read by a validated convention.
    package let notes: [String]

    package init(width: Int, height: Int, pixels: [Float], x: AxisCalibration?, y: AxisCalibration?,
                 fileName: String, source: String, voltage: Double?, notes: [String] = []) {
        precondition(width > 0 && height > 0 && pixels.count == width * height,
                     "CalibratedImage: \(pixels.count) pixels for \(width) × \(height)")
        self.width = width
        self.height = height
        self.pixels = pixels
        self.x = x
        self.y = y
        self.fileName = fileName
        self.source = source
        self.voltage = voltage
        self.notes = notes
    }

    /// Whether the two axes state the same sampling. Exact comparison of what the file wrote: macTEM reports
    /// the file, it does not decide how close is close enough. nil when either axis is uncalibrated.
    package var hasSquarePixels: Bool? {
        guard let x, let y, x.isCalibrated, y.isCalibrated else { return nil }
        return x.scale == y.scale && x.unit == y.unit
    }
}
