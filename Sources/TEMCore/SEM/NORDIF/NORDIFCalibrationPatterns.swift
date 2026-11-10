//
//  NORDIFCalibrationPatterns.swift
//  Role: the calibration patterns of a NORDIF acquisition, read as kikuchipy 0.13.1's `nordif_calibration_patterns`
//        plugin reads them (`kikuchipy/io/plugins/nordif_calibration_patterns/_api.py` and
//        `nordif/_api.py: _get_calibration_pattern_settings`; GPL-3.0-or-later, kikuchipy developers): from
//        `Setting.txt`, every `Calibration (x,y)` line names a `Calibration (x,y).bmp` in the same folder; their
//        positions in the electron image, the area and the region of interest, each also scaled to scan steps; and
//        `Background calibration pattern.bmp` as the static background. Parity: reference.json (NORDIFReaderTests).
//
//  The scaling is kikuchipy's: `factor = step * width_px / width_um` from the `[Area] Width` line, and every scaled
//  value is `round(value / factor)` with NumPy's round-half-to-even. Without a readable `Width` there is no scaling,
//  nor with a factor of 0 or NaN (a `Step size` of 0 or NaN, a `Width` of 0 px), nor when a scaled value is beyond an
//  Int: the scaled values stay nil where kikuchipy casts the NaN, infinite or out-of-range quotient to an undefined
//  integer. An infinite factor scales every value to 0, as kikuchipy's division does.
//  An `[Area]` corner the file does not carry counts as 0 in `roiOrigin`, as kikuchipy's default; `settings.area`
//  keeps it nil.
//

import Foundation
import FormatoCore

package nonisolated struct NORDIFCalibrationPatterns: Equatable, Sendable {
    package struct Point: Equatable, Sendable {
        package var row: Int
        package var column: Int

        package init(row: Int, column: Int) {
            self.row = row
            self.column = column
        }
    }

    package var settings: NORDIFSettings
    /// The positions in pixels of the electron image, in the file's order (`x`, `y` as written).
    package var positions: [NORDIFSettings.Position]
    /// One pattern per position, `Calibration (x,y).bmp`.
    package var patterns: [NORDIFBitmap.Image]
    /// `Background calibration pattern.bmp`, when the folder carries it.
    package var staticBackground: NORDIFBitmap.Image?
    /// The electron image's size, when `[Electron image] Resolution` is readable.
    package var areaShape: Point?
    /// `[Area]` Top, Left (the origin) and Height, Width (the shape) in pixels of the electron image.
    package var roiOrigin: Point
    package var roiShape: Point
    /// The same in scan steps (kikuchipy's `indices_scaled`, `shape_scaled`, `origin_scaled`); nil without a readable width or a usable
    /// factor.
    package var positionsScaled: [Point]?
    package var areaShapeScaled: Point?
    package var roiOriginScaled: Point?
    package var roiShapeScaled: Point?

    package var detector: NORDIFSettings.Detector { settings.detector }

    package enum Refusal: Error, Equatable {
        case missingPattern(String)

        package var reason: String {
            switch self {
            case .missingPattern(let name): "its calibration pattern \(name) is not beside it."
            }
        }
    }

    /// Reads the settings file and the bitmaps beside it, as `kikuchipy.load("Setting.txt")`.
    package static func read(settingsFile: String) throws -> NORDIFCalibrationPatterns {
        let settings = try NORDIFSettings.read(path: settingsFile)
        let folder = (settingsFile as NSString).deletingLastPathComponent
        guard !settings.calibrationPositions.isEmpty else { throw NORDIFSettings.Refusal.noCalibrationPatterns }
        let patterns = try settings.calibrationPositions.map { position in
            let name = "Calibration (\(position.x),\(position.y)).bmp"
            let path = (folder as NSString).appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: path) else { throw Refusal.missingPattern(name) }
            return try NORDIFBitmap.read(path: path)
        }
        let background = try? NORDIFBitmap.read(path: (folder as NSString).appendingPathComponent("Background calibration pattern.bmp"))
        return geometry(settings: settings, patterns: patterns, staticBackground: background)
    }

    package static func geometry(settings: NORDIFSettings, patterns: [NORDIFBitmap.Image],
                                 staticBackground: NORDIFBitmap.Image?) -> NORDIFCalibrationPatterns {
        let area = settings.area
        let positions = settings.calibrationPositions
        let areaShape = settings.electronImageResolution.map { Point(row: $0.height, column: $0.width) }
        let roiOrigin = Point(row: area.top?.pixels ?? 0, column: area.left?.pixels ?? 0)
        let roiShape = Point(row: area.height?.pixels ?? 0, column: area.width?.pixels ?? 0)
        var result = NORDIFCalibrationPatterns(settings: settings, positions: positions, patterns: patterns,
                                               staticBackground: staticBackground, areaShape: areaShape,
                                               roiOrigin: roiOrigin, roiShape: roiShape)
        guard let width = area.width, width.micrometres != 0 else { return result }
        let factor = area.stepUM * Double(width.pixels) / width.micrometres
        // An infinite factor scales every value to 0, as kikuchipy's division does; NaN scales nothing.
        guard factor != 0, !factor.isNaN else { return result }
        // `Int(exactly:)`, as `ReaderNumber.int`: a quotient no Int holds means no scaling, where `Int(_:)` would trap.
        func steps(_ value: Int) -> Int? { Int(exactly: (Double(value) / factor).rounded(.toNearestOrEven)) }
        func steps(of point: Point) -> Point? {
            guard let row = steps(point.row), let column = steps(point.column) else { return nil }
            return Point(row: row, column: column)
        }
        var positionsScaled: [Point] = []
        for position in positions {
            guard let scaled = steps(of: Point(row: position.y, column: position.x)) else { return result }
            positionsScaled.append(scaled)
        }
        var areaShapeScaled: Point?
        if let areaShape {
            guard let scaled = steps(of: areaShape) else { return result }
            areaShapeScaled = scaled
        }
        guard let roiOriginScaled = steps(of: roiOrigin), let roiShapeScaled = steps(of: roiShape) else { return result }
        result.positionsScaled = positionsScaled
        result.areaShapeScaled = areaShapeScaled
        result.roiOriginScaled = roiOriginScaled
        result.roiShapeScaled = roiShapeScaled
        return result
    }
}
