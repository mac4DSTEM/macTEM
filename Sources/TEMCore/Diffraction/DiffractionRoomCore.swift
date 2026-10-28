//
//  DiffractionRoomCore.swift
//  Role: the Diffraction room's facts and flow without a view: the centre, the
//        calibration it resolves (a ring fit on a standard, else the file's reciprocal axis, else a typed Δq), a measured ring, a
//        measured spot, the camera pixel pitches, the words of a kit refusal. Every number is DiffractoKit's (`RingFitCalibration`,
//        `RingScale`, `IndexingDisplay`, `RingOverlay`); the app holds the flow. One interim, marked: the spot centroid.
//

import Foundation
import ImagoCore
import DiffractoCore
import DiffractoGeometry
import DiffractoScattering

/// The pattern centre in pixels (row, column; a pixel's centre is at its integer), and where it came from.
package nonisolated struct DiffractionCentre: Sendable, Equatable {
    package enum Source: Sendable, Equatable { case fileCentre, typed, ring }
    package var row: Double
    package var column: Double
    package var source: Source
    package init(row: Double, column: Double, source: Source) { self.row = row; self.column = column; self.source = source }

    /// The image centre: the middle pixel (256 of 512), never a brightest-pixel guess.
    package static func imageCentre(width: Int, height: Int) -> DiffractionCentre {
        DiffractionCentre(row: Double(height / 2), column: Double(width / 2), source: .fileCentre)
    }
}

/// Which scale the room uses, and the numbers it gives q from a radius.
package nonisolated struct DiffractionCalibration: Sendable, Equatable {
    package enum Source: Sendable, Equatable {
        case ringFit(standard: String, family: String)
        case fileAxis
        case typed
    }
    package var source: Source
    /// Å⁻¹ per pixel (the linear scale; for a ring fit with a beam energy the exact form is used for q).
    package var deltaQ: Double
    /// The kit's calibration when the scale comes from a ring fit.
    package var ring: RingCalibration?
    package init(source: Source, deltaQ: Double, ring: RingCalibration?) { self.source = source; self.deltaQ = deltaQ; self.ring = ring }

    /// |q| (Å⁻¹) of a radius (px): the kit's exact form with a camera length and wavelength, else Δq · R.
    package func q(radius: Double) -> Double {
        if let ring { return RingScale.q(radius: radius, calibration: ring) }
        return RingScale.linear(radius: radius, deltaQ: deltaQ)
    }

    /// "fit Au {111}", "the file's axis", "typed".
    package var sourceText: String {
        switch source {
        case .ringFit(let standard, let family): "fit \(standard) \(family)"
        case .fileAxis: "the file's axis"
        case .typed: "typed"
        }
    }

    /// Δq from the file's reciprocal axis in Å⁻¹, when it states 1/nm or 1/Å; nil otherwise.
    package static func fileDeltaQ(_ axis: AxisCalibration?) -> Double? { UnitDisplay.reciprocalAngstromsPerPixel(axis) }
}

/// The camera pixel pitches the room knows until FormatoKit reads them (kit ask 7): nominal values from the vendors' data sheets, typed
/// over when a detector differs. Only L in mm uses them; nothing else does.
package nonisolated enum CameraPitches {
    package struct Camera: Sendable, Equatable { package let name: String; package let pitchMM: Double }
    package static let all: [Camera] = [
        Camera(name: "Thermo Ceta (14 µm)", pitchMM: 0.014),
        Camera(name: "Gatan OneView (15 µm)", pitchMM: 0.015),
        Camera(name: "Dectris ARINA (75 µm)", pitchMM: 0.075),
        Camera(name: "EMPAD (150 µm)", pitchMM: 0.150),
    ]
}

/// A ring the user fitted: the annulus, the kit's radius fit, and the refusal in words when it is not usable.
package nonisolated struct MeasuredRing: Sendable, Equatable, Identifiable {
    package let id: UUID
    package var innerRadius: Double
    package var outerRadius: Double
    package var fit: RingRadiusFit?
    /// "annulus holds no ring", the kit's own sentence; nil for a usable ring.
    package var refusal: String?
    /// This ring set the calibration.
    package var isCalibrating: Bool
    package init(id: UUID = UUID(), innerRadius: Double, outerRadius: Double, fit: RingRadiusFit?, refusal: String?, isCalibrating: Bool) {
        self.id = id; self.innerRadius = innerRadius; self.outerRadius = outerRadius
        self.fit = fit; self.refusal = refusal; self.isCalibrating = isCalibrating
    }
    package var radius: Double? { fit?.isUsable == true ? fit?.radius : nil }
    package var ellipse: RingEllipse? { fit?.fit.map { RingOverlay.ellipse(of: $0) } }
}

/// A spot the user clicked: the click, the refined centre, and its radius from the pattern centre (ellipse-corrected when a
/// calibrating ring gave an ellipse).
package nonisolated struct MeasuredSpot: Sendable, Equatable, Identifiable {
    package let id: UUID
    package var clickRow: Double
    package var clickColumn: Double
    package var row: Double?
    package var column: Double?
    package var radius: Double?
    package var refusal: String?
    package init(id: UUID = UUID(), clickRow: Double, clickColumn: Double, row: Double?, column: Double?, radius: Double?, refusal: String?) {
        self.id = id; self.clickRow = clickRow; self.clickColumn = clickColumn
        self.row = row; self.column = column; self.radius = radius; self.refusal = refusal
    }
}

package nonisolated enum DiffractionCompute {

    /// The kit's input pattern from the image's pixels.
    package static func pattern(of image: CalibratedImage) -> DiffractoGeometry.DiffractionPattern {
        DiffractoGeometry.DiffractionPattern(width: image.width, height: image.height, pixels: image.pixels)
    }

    /// A ring in the annulus about the centre, by the kit (`RingFitCalibration.fitRing`), with its refusal in the kit's words.
    package static func fitRing(pattern: DiffractoGeometry.DiffractionPattern, centre: DiffractionCentre, inner: Double, outer: Double,
                                isCancelled: @escaping @Sendable () -> Bool) -> (fit: RingRadiusFit?, refusal: String?) {
        do {
            let fit = try RingCalibration.fitRing(pattern: pattern, centerQX: centre.row, centerQY: centre.column,
                                                  innerRadius: inner, outerRadius: outer, isCancelled: isCancelled)
            if fit.isUsable { return (fit, nil) }
            return (fit, fit.refusals.first?.reason ?? "the ring was not usable")
        } catch {
            return (nil, error.localizedDescription)
        }
    }

    /// The calibration of a fitted ring against the spacing d (Å) of a standard's family, by the kit.
    package static func calibrate(_ ring: RingRadiusFit, d: Double, volts: Double?, pitchMM: Double?) throws -> RingFitCalibration {
        try RingCalibration.calibrating(ring, d: d, highTensionVolts: volts, pixelPitchMM: pitchMM)
    }

    /// INTERIM, `delete at DiffractoKit <the version with a pattern extent>` (kit ask 10): a median/MAD estimate in the app. DISPLAY ONLY (no measurement): how far from the centre the pattern has signal, so the view can open on it instead of on a sixth of the
    /// pane. The farthest pixel above the median by eight median absolute deviations (a floor of one grey level), scaled by 1.15, at least
    /// 48 px; nil when nothing rises above that or it reaches the image's own edge (noise or a full-frame pattern: show everything). Subsampled for large images.
    package static func contentRadius(pixels: [Float], width: Int, height: Int, centre: DiffractionCentre) -> Double? {
        guard width > 8, height > 8, pixels.count == width * height else { return nil }
        let step = max(1, Int((Double(width * height) / 1_000_000).squareRoot().rounded(.up)))
        var sample: [Float] = []
        for y in stride(from: 0, to: height, by: step) { for x in stride(from: 0, to: width, by: step) where pixels[y * width + x].isFinite { sample.append(pixels[y * width + x]) } }
        guard sample.count > 16 else { return nil }
        sample.sort()
        let median = sample[sample.count / 2]
        var deviations = sample.map { abs($0 - median) }
        deviations.sort()
        let mad = deviations[deviations.count / 2]
        let threshold = median + 8 * max(mad, 1)
        var farthest = 0.0
        for y in stride(from: 0, to: height, by: step) {
            for x in stride(from: 0, to: width, by: step) where pixels[y * width + x] > threshold {
                let dy = Double(y) - centre.row, dx = Double(x) - centre.column
                farthest = max(farthest, (dx * dx + dy * dy).squareRoot())
            }
        }
        guard farthest > 0 else { return nil }
        let extent = max(farthest * 1.15, 48)
        return extent < 0.9 * Double(min(width, height)) / 2 ? extent : nil
    }

    /// The radius (px) of a point about the centre, corrected by the calibrating ring's ellipse when there is one (the kit's
    /// `EllipseTransform`): the radius a circle of the same scale would have.
    package static func radius(row: Double, column: Double, centre: DiffractionCentre, ellipse: RingEllipse?) -> Double {
        let dRow = row - centre.row, dColumn = column - centre.column
        guard let ellipse, ellipse.a > 0, ellipse.b > 0,
              let transform = EllipseTransform(a: ellipse.a, b: ellipse.b, theta: ellipse.theta) else { return (dRow * dRow + dColumn * dColumn).squareRoot() }
        let corrected = transform.correctedOffset(dx: Float(dColumn), dy: Float(dRow))
        return (Double(corrected.x * corrected.x + corrected.y * corrected.y)).squareRoot()
    }

    /// The kinematic list of a structure to k_max (Å⁻¹), by the kit.
    package static func list(of structure: CrystalStructure, kMax: Double) throws -> KinematicReflectionList {
        try structure.kinematicReflections(kMax: kMax)
    }

    /// "{111}": the kit's family name without its spaces.
    package static func familyName(_ family: ReflectionFamily) -> String { family.name.replacingOccurrences(of: " ", with: "") }
}
