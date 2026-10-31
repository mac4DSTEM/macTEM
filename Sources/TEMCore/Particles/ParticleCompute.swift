// The Particles view's compute, on ImagoKit: Gaussian smoothing (`SeparableFilters.gaussianFilter`), a threshold on the raw range,
// connected-component labelling (`Segmentation.label`) and the objects' moments (`Segmentation.objectMoments`). Nothing here is a
// number of macTEM's own: the threshold level and compare are `Thresholding.level` and `.mask`, the summary (counts, a median and a mean of
// the kit's lengths and widths) is `ObjectStatistics.sizeSummary`, and the labels and every length, width, angle and centroid are ImagoKit's.
// Validation: none.
import Foundation
import ImagoCore
import ImagoFilters

package nonisolated struct ParticleSettings: Equatable, Sendable {
    package enum Polarity: String, Sendable, CaseIterable, Identifiable {
        case bright, dark
        package var id: String { rawValue }
        package var title: String { self == .bright ? "Bright" : "Dark" }
    }

    package var polarity: Polarity = .bright
    /// The threshold as a fraction of the raw finite range: 0 is the minimum, 1 the maximum.
    package var thresholdFraction = 0.5
    /// Gaussian smoothing before the threshold, in pixels; 0 is none.
    package var sigma = 0.0
    package var connectivity: Segmentation.Connectivity = .eight
    /// An object of fewer pixels is listed and not counted.
    package var minimumArea = 4
    package init() {}
}

package nonisolated struct ParticleObject: Equatable, Sendable, Identifiable {
    package let moments: Segmentation.ObjectMoments
    package let isSmall: Bool
    package var id: Int32 { moments.label }
    package var touchesEdge: Bool { moments.touchesEdge }
    /// Counted in the statistics: not on the image edge (cut by it) and not below the minimum area.
    package var isCounted: Bool { !isSmall && !touchesEdge }
}

package nonisolated struct ParticleSummary: Equatable, Sendable {
    package var total = 0
    package var counted = 0
    /// Touching the image edge (whatever their size).
    package var edge = 0
    /// Below the minimum area and not on the edge.
    package var small = 0
    /// Over the counted objects, in pixels; nil with none.
    package var medianLengthPx: Double?
    package var meanWidthPx: Double?
    package init() {}
}

package nonisolated struct ParticleReport: Equatable, Sendable {
    package let settings: ParticleSettings
    package let width: Int
    package let height: Int
    /// The raw value the threshold fraction stood for.
    package let thresholdValue: Float
    package let objects: [ParticleObject]
    package let summary: ParticleSummary
    package let labels: Segmentation.LabelImage
}

/// A pixel size for lengths: units per pixel, and the unit ("px" when the image is not calibrated or its pixels are not square).
package nonisolated struct ParticleScale: Equatable, Sendable {
    package let perPixel: Double
    package let unit: String
    package init(perPixel: Double, unit: String) { self.perPixel = perPixel; self.unit = unit }
    package var isCalibrated: Bool { unit != "px" }
}

package nonisolated enum ParticleError: Error, Equatable, LocalizedError {
    case noFiniteValues
    package var errorDescription: String? { "The image holds no finite value to threshold." }
}

package nonisolated enum ParticleCompute {
    /// The raw finite range of `pixels`; nil when none is finite.
    package static func range(_ pixels: [Float]) -> ClosedRange<Float>? {
        var lo = Float.infinity, hi = -Float.infinity
        for v in pixels where v.isFinite { lo = min(lo, v); hi = max(hi, v) }
        return lo <= hi ? lo...hi : nil
    }

    /// The pixels the objects are cut from: smoothed when sigma > 0 (a non-finite pixel is read as the range's low end first).
    package static func smoothed(_ pixels: [Float], width: Int, height: Int, sigma: Double, low: Float) throws -> [Float] {
        guard sigma > 0 else { return pixels }
        let clean = pixels.map { $0.isFinite ? $0 : low }
        return try SeparableFilters.gaussianFilter(clean, rows: height, columns: width, sigma: (row: sigma, column: sigma))
    }

    /// `true` where the (smoothed) pixel is on the object side of the threshold.
    package static func mask(pixels: [Float], width: Int, height: Int, range: ClosedRange<Float>, settings: ParticleSettings) throws -> (mask: [Bool], threshold: Float) {
        let data = try smoothed(pixels, width: width, height: height, sigma: settings.sigma, low: range.lowerBound)
        guard let t = Thresholding.level(pixels, atFraction: settings.thresholdFraction) else { throw ParticleError.noFiniteValues }
        return (Thresholding.mask(data, threshold: t, polarity: settings.polarity == .bright ? .bright : .dark), t)
    }

    package static func analyse(pixels: [Float], width: Int, height: Int, settings: ParticleSettings) throws -> ParticleReport {
        guard let range = range(pixels) else { throw ParticleError.noFiniteValues }
        let cut = try mask(pixels: pixels, width: width, height: height, range: range, settings: settings)
        let labels = try Segmentation.label(cut.mask, width: width, height: height, connectivity: settings.connectivity)
        let objects = try Segmentation.objectMoments(labels).map { ParticleObject(moments: $0, isSmall: $0.area < settings.minimumArea) }
        return ParticleReport(settings: settings, width: width, height: height, thresholdValue: cut.threshold, objects: objects,
                              summary: summary(objects, minimumArea: settings.minimumArea), labels: labels)
    }

    package static func summary(_ objects: [ParticleObject], minimumArea: Int) -> ParticleSummary {
        let kit = ObjectStatistics.sizeSummary(objects.map(\.moments), minimumArea: minimumArea)
        var s = ParticleSummary()
        s.total = kit.total
        s.counted = kit.counted
        s.edge = kit.edge
        s.small = kit.small
        s.medianLengthPx = kit.medianLength
        s.meanWidthPx = kit.meanWidth
        return s
    }

    /// The scale lengths are shown in: the x axis (ImagoKit's `ScaleBarMath.sampling`), or pixels when the image is not calibrated
    /// or its two axes differ.
    package static func scale(of image: CalibratedImage) -> ParticleScale {
        guard image.hasSquarePixels == true else { return ParticleScale(perPixel: 1, unit: "px") }
        let s = ScaleBarMath.sampling(x: image.x, y: image.y, width: image.width, height: image.height, unitLabel: UnitDisplay.label)
        return ParticleScale(perPixel: s.perPixel, unit: s.unit)
    }
}

package nonisolated enum ParticleFormat {
    /// A number a person reads (the object table, the inspector, the pointer readout): three significant digits in the locale's decimal
    /// mark, never grouped, as `UnitDisplay.number` writes every other number in the Image room ("0,873" in de_DE).
    package static func number(_ v: Double, locale: Locale = .autoupdatingCurrent) -> String { UnitDisplay.number(v, digits: 3, locale: locale) }

    /// The same number for the CSV a script reads: printf's `%.3g`, always a point.
    package static func csvNumber(_ v: Double) -> String { String(format: "%.3g", v) }

    /// "128 objects · 97 counted · 19 edge · 12 small".
    package static func counts(_ s: ParticleSummary) -> String {
        "\(s.total) object\(s.total == 1 ? "" : "s") · \(s.counted) counted · \(s.edge) edge · \(s.small) small"
    }

    /// "median length 18.2 nm · mean width 5.9 nm", or why there is none.
    package static func sizes(_ s: ParticleSummary, scale: ParticleScale, locale: Locale = .autoupdatingCurrent) -> String {
        guard let l = s.medianLengthPx, let w = s.meanWidthPx else { return s.total == 0 ? "No objects above the threshold." : "No object is counted." }
        return "median length \(number(l * scale.perPixel, locale: locale)) \(scale.unit) · mean width \(number(w * scale.perPixel, locale: locale)) \(scale.unit)"
    }

    /// The objects as CSV with provenance comment lines; lengths in the scale's unit beside the pixels.
    package static func csv(_ r: ParticleReport, scale: ParticleScale, fileName: String) -> String {
        let u = scale.isCalibrated ? scale.unit : "px"
        var out = ["# macTEM particles, file: \(fileName), validation: none",
                   "# threshold: \(r.settings.polarity.rawValue) objects, fraction \(csvNumber(r.settings.thresholdFraction)) of the raw range = \(csvNumber(Double(r.thresholdValue))), smoothing sigma \(csvNumber(r.settings.sigma)) px, connectivity \(r.settings.connectivity.rawValue), minimum area \(r.settings.minimumArea) px",
                   "# \(ParticleFormat.counts(r.summary)); labels, centroids, lengths, widths and angles: ImagoKit Segmentation.objectMoments; counted = not touching the image edge and not below the minimum area",
                   "# length_ and width_ in \(u) (pixel size \(csvNumber(scale.perPixel)) \(scale.unit)/px); angle: long axis from +x toward +y, degrees",
                   "label,counted,touches_edge,small,area_px,centroid_x_px,centroid_y_px,length_px,width_px,angle_deg,length_\(u),width_\(u),area_\(u)2"]
        for o in r.objects {
            let m = o.moments
            let cells: [String] = ["\(m.label)", o.isCounted ? "1" : "0", m.touchesEdge ? "1" : "0", o.isSmall ? "1" : "0", "\(m.area)",
                                   String(format: "%.4f", m.centroidCol), String(format: "%.4f", m.centroidRow),
                                   String(format: "%.4f", m.lengthPx), String(format: "%.4f", m.widthPx), String(format: "%.3f", m.orientationDegrees),
                                   String(format: "%.5g", m.lengthPx * scale.perPixel), String(format: "%.5g", m.widthPx * scale.perPixel),
                                   String(format: "%.5g", Double(m.area) * scale.perPixel * scale.perPixel)]
            out.append(cells.joined(separator: ","))
        }
        return out.joined(separator: "\n") + "\n"
    }
}
