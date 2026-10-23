//
//  ImagePoint+PixelPoint.swift
//  Role: the seam between the app's `ImagePoint` (Codable session data: marks, the region's press) and ImagoKit's `PixelPoint`
//        (ImagoFFT's `FFTRegion` and `SpectrumBin` take it; ImagoCore's `ImageMeasurement` measures between two). Same convention:
//        x = column, y = row, pixel centres at integers. Distance and angle ARE the kit's `ImageMeasurement` (ImagoKit 0.5.0);
//        the two functions below only take `ImagePoint`s.
//

import ImagoCore

/// A position on an image in pixel coordinates: x = column, y = row; pixel (r, c) has its centre at (c, r).
package nonisolated struct ImagePoint: Sendable, Equatable, Hashable, Codable {
    package var x: Double
    package var y: Double

    package init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    /// The kit's point at the same coordinates.
    package var pixelPoint: PixelPoint { PixelPoint(x: x, y: y) }

    package init(_ p: PixelPoint) { self.init(x: p.x, y: p.y) }
}

extension ImageMeasurement {
    /// What a distance and an angle are checked against, and nothing more (the Results room and its CSV show this sentence
    /// verbatim): the closed forms from the pixel coordinates and the file's scale, to 1e-12 relative, by tools/parity/profile-parity P1.
    package nonisolated static let validation = "closed form from the pixel coordinates and the file's scale, to 1e-12 relative "
        + "(tools/parity/profile-parity, V1-5 P1); the scale as the file states it"

    package nonisolated static func distance(_ a: ImagePoint, _ b: ImagePoint, x: AxisCalibration?, y: AxisCalibration?) -> Distance {
        distance(a.pixelPoint, b.pixelPoint, x: x, y: y)
    }

    package nonisolated static func angle(_ a: ImagePoint, vertex b: ImagePoint, _ c: ImagePoint,
                                          x: AxisCalibration?, y: AxisCalibration?) -> Angle? {
        angle(a.pixelPoint, vertex: b.pixelPoint, c.pixelPoint, x: x, y: y)
    }
}
