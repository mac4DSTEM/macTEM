//
//  EBSDDetectorProjection.swift
//  Role: the detector's view of the sample, as kikuchipy's `EBSDDetector` computes it: the projection-centre conventions by
//        every name kikuchipy accepts, the detector's size in µm, the gnomonic bounds, pixel scales and r_max per projection
//        centre, pixel <-> gnomonic coordinates, and the passive sample-to-detector rotation that projection, simulation and
//        indexing use. EBSD and TKD alike: TKD (the detector below a thin sample) is the same four angles with the sample
//        tilt near or below zero, as `EBSDDetector` takes it.
//        Ported from kikuchipy 0.13.1 (`detectors/_ebsd_detector.py`: `_sample_to_detector_matrix`, `x_min` ... `r_max`,
//        `height`, `width`, `specimen_scintillator_distance`, `_get_pc_convention_or_raise`;
//        `detectors/_convert_detector_coordinates.py`; GPL-3.0-or-later). Gnomonic coordinates follow Britton et al. (2016),
//        Ultramicroscopy 165, 1 (supplementary material); the conventions are kikuchipy's class notes. Parity bundles
//        `m2/detector-*` in tools/parity/sem; rows in docs/parity.md.
//

import Foundation

extension EBSDDetectorGeometry.Convention {
    /// A convention by any name kikuchipy accepts (`PC_CONVENTIONS`, case-insensitive): "bruker"; "tsl", "edax", "amatek";
    /// "oxford", "aztec"; "emsoft", "emsoft5" (both version 5) and "emsoft4". Nil for anything else (kikuchipy raises).
    package init?(kikuchipyName name: String) {
        switch name.lowercased() {
        case "bruker": self = .bruker
        case "tsl", "edax", "amatek": self = .tsl
        case "oxford", "aztec": self = .oxford
        case "emsoft", "emsoft5": self = .emsoft5
        case "emsoft4": self = .emsoft4
        default: return nil
        }
    }
}

/// The detector bounds in gnomonic coordinates for one projection centre (kikuchipy's `gnomonic_bounds` row).
package nonisolated struct GnomonicBounds: Sendable, Equatable {
    package var xMin: Double, xMax: Double, yMin: Double, yMax: Double

    package init(xMin: Double, xMax: Double, yMin: Double, yMax: Double) {
        self.xMin = xMin; self.xMax = xMax; self.yMin = yMin; self.yMax = yMax
    }
}

/// A passive rotation as a 3 x 3 matrix by rows: `rows[i]` is the i-th axis of the target frame in source coordinates, so
/// `apply(v)` takes a column vector from the source frame to the target frame.
package nonisolated struct FrameRotation: Sendable, Equatable {
    package var rows: [SIMD3<Double>]

    package init(rows: [SIMD3<Double>]) {
        precondition(rows.count == 3, "a 3 x 3 rotation has three rows")
        self.rows = rows
    }

    /// The matrix times the column vector `v`.
    package func apply(_ v: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3((rows[0] * v).sum(), (rows[1] * v).sum(), (rows[2] * v).sum())
    }

    /// The inverse rotation (the transpose).
    package var inverse: FrameRotation {
        FrameRotation(rows: [SIMD3(rows[0].x, rows[1].x, rows[2].x), SIMD3(rows[0].y, rows[1].y, rows[2].y),
                             SIMD3(rows[0].z, rows[1].z, rows[2].z)])
    }

    /// Row-major entries, the layout of numpy's `(3, 3)` array.
    package var entries: [Double] { rows.flatMap { [$0.x, $0.y, $0.z] } }
}

extension EBSDDetectorGeometry {
    /// A detector whose centres are given in `convention` (kikuchipy's `EBSDDetector(pc=..., convention=...)`): they are
    /// stored converted to Bruker's.
    package init(rows: Int, columns: Int, pixelSize: Double = 1, binning: Int = 1, tilt: Double = 0, azimuthal: Double = 0, twist: Double = 0,
                 sampleTilt: Double = 70, projectionCenters: [SIMD3<Double>], convention: Convention) {
        self.init(rows: rows, columns: columns, pixelSize: pixelSize, binning: binning, tilt: tilt, azimuthal: azimuthal, twist: twist,
                  sampleTilt: sampleTilt, projectionCenters: [])
        let shape = self
        self.projectionCenters = projectionCenters.map { shape.brukerCenter($0, from: convention) }
    }

    /// Every stored centre written in `convention` (`pc_tsl`, `pc_oxford`, `pc_emsoft(version)`, `pc_bruker`).
    package func centers(in convention: Convention) -> [SIMD3<Double>] { projectionCenters.map { center($0, in: convention) } }

    // MARK: Sizes

    /// Detector height in µm, Ny δ b.
    package var height: Double { Double(rows) * pixelSize * Double(binning) }
    /// Detector width in µm, Nx δ b.
    package var width: Double { Double(columns) * pixelSize * Double(binning) }
    /// The binned pixel size in µm, δ b.
    package var binnedPixelSize: Double { pixelSize * Double(binning) }
    /// The unbinned shape (rows, columns), (Ny b, Nx b).
    package var unbinnedShape: (rows: Int, columns: Int) { (rows * binning, columns * binning) }
    /// Specimen-to-scintillator distance (EMsoft's L) in µm for a Bruker centre, PCz times the detector height.
    package func specimenScintillatorDistance(_ pc: SIMD3<Double>) -> Double { pc.z * height }

    // MARK: Gnomonic projection (Britton et al. 2016)

    /// The detector bounds in gnomonic coordinates seen from the Bruker centre `pc` (`x_min`, `x_max`, `y_min`, `y_max`).
    package func gnomonicBounds(_ pc: SIMD3<Double>) -> GnomonicBounds {
        GnomonicBounds(xMin: -aspectRatio * (pc.x / pc.z), xMax: aspectRatio * (1 - pc.x) / pc.z,
                       yMin: -(1 - pc.y) / pc.z, yMax: pc.y / pc.z)
    }

    /// The width and height of one pixel in gnomonic coordinates (`x_scale`, `y_scale`): the range over Nx − 1 and Ny − 1
    /// steps, or the whole range for a one-pixel side.
    package func gnomonicScale(_ pc: SIMD3<Double>) -> (x: Double, y: Double) {
        let b = gnomonicBounds(pc)
        let x = (b.xMax - b.xMin) / (columns == 1 ? 1 : Double(columns - 1))
        let y = (b.yMax - b.yMin) / (rows == 1 ? 1 : Double(rows - 1))
        return (x, y)
    }

    /// The largest distance from the centre to a detector corner in gnomonic coordinates, kikuchipy's `r_max`. Its corner
    /// list repeats the upper left (x_min, y_min) where the lower left would be (x_min, y_max); the port keeps that list so the
    /// number is kikuchipy's (decision in docs/decisions.md, row in docs/parity.md).
    package func rMax(_ pc: SIMD3<Double>) -> Double {
        let b = gnomonicBounds(pc)
        let corners = [b.xMin * b.xMin + b.yMin * b.yMin, b.xMax * b.xMax + b.yMin * b.yMin,
                       b.xMax * b.xMax + b.yMax * b.yMax, b.xMin * b.xMin + b.yMin * b.yMin]
        return corners.max()!.squareRoot()
    }

    /// Pixel coordinates (y, x) to gnomonic (gy, gx) for the Bruker centre `pc` (`to_gnomonic_coords`): linear over the
    /// detector's Nx and Ny pixel edges, gy pointing up.
    package func gnomonic(pixel: SIMD2<Double>, pc: SIMD3<Double>) -> SIMD2<Double> {
        let b = gnomonicBounds(pc)
        let mx = (b.xMax - b.xMin) / Double(columns), my = (b.yMin - b.yMax) / Double(rows)
        return SIMD2(my * pixel.x + b.yMax, mx * pixel.y + b.xMin)
    }

    /// Gnomonic coordinates (gy, gx) to pixel (y, x) for the Bruker centre `pc` (`to_pixel_coords`), the inverse map.
    package func pixel(gnomonic: SIMD2<Double>, pc: SIMD3<Double>) -> SIMD2<Double> {
        let b = gnomonicBounds(pc)
        let mx = Double(columns) / (b.xMax - b.xMin), my = Double(rows) / (b.yMin - b.yMax)
        return SIMD2(my * gnomonic.x - b.yMax * my, mx * gnomonic.y - b.xMin * mx)
    }

    // MARK: Sample to detector

    /// The passive sample-to-detector rotation (`sample_to_detector`, `_sample_to_detector_matrix`): rows are the detector
    /// axes X_d, Y_d, Z_d in sample coordinates. Starting from X_d = y_s, Y_d = z_s, Z_d = x_s, the basis is turned by
    /// Rodrigues' formula about its own current axes: −σ (sample tilt) about X_d, then θ (detector tilt) about X_d, −ω
    /// (azimuthal) about Y_d, −γ (twist) about Z_d.
    package var sampleToDetector: FrameRotation {
        Self.sampleToDetector(sampleTilt: sampleTilt, tilt: tilt, azimuthal: azimuthal, twist: twist)
    }

    /// The same rotation for explicit angles in degrees.
    package static func sampleToDetector(sampleTilt: Double, tilt: Double, azimuthal: Double, twist: Double) -> FrameRotation {
        let radians = Double.pi / 180
        var basis: [SIMD3<Double>] = [SIMD3(0, 1, 0), SIMD3(0, 0, 1), SIMD3(1, 0, 0)]
        let steps: [(axis: Int, angle: Double)] = [(0, -sampleTilt * radians), (0, tilt * radians), (1, -azimuthal * radians),
                                                    (2, -twist * radians)]
        for (axis, angle) in steps {
            let u = basis[axis] / (basis[axis] * basis[axis]).sum().squareRoot()
            let c = cos(angle), s = sin(angle), oneMinusC = 1 - c
            for j in 0..<3 {
                let v = basis[j]
                let dot = (u * v).sum()
                let cross = SIMD3(u.y * v.z - u.z * v.y, u.z * v.x - u.x * v.z, u.x * v.y - u.y * v.x)
                basis[j] = v * c + cross * s + u * (dot * oneMinusC)
            }
        }
        return FrameRotation(rows: basis)
    }

    /// The detector-to-sample rotation, the inverse of `sampleToDetector`.
    package var detectorToSample: FrameRotation { sampleToDetector.inverse }
}
