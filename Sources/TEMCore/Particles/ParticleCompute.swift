// The Particles view's compute, on ImagoKit: Gaussian smoothing (`SeparableFilters.gaussianFilter`), a threshold on the raw range,
// connected-component labelling (`Segmentation.label`) and the objects' moments (`Segmentation.objectMoments`). Nothing here is a
// number of macTEM's own: the threshold is `Thresholding.level` (a fraction of the raw range) or `Thresholding.otsu`, the compare is
// `.mask`, objects below the minimum area are removed from the mask by `BinaryMorphology.removeSmallObjects`, the summary (counts, a median
// and a mean of the kit's lengths and widths, the Miles–Lantuéjoul areal density) is `ObjectStatistics.arealDensity`, and the labels and
// every length, width, angle and centroid are ImagoKit's. Validation: none.
import Foundation
import ImagoCore
import ImagoFilters

package nonisolated struct ParticleSettings: Equatable, Sendable {
    package enum Polarity: String, Sendable, CaseIterable, Identifiable {
        case bright, dark
        package var id: String { rawValue }
        package var title: String { self == .bright ? "Bright" : "Dark" }
    }

    /// How the threshold is chosen: the slider's fraction of the range, or Otsu's level of the pixels the objects are cut from.
    package enum Method: String, Sendable, CaseIterable, Identifiable {
        case manual, otsu
        package var id: String { rawValue }
        package var title: String { self == .manual ? "Manual" : "Otsu" }
    }

    package var polarity: Polarity = .bright
    package var method: Method = .manual
    /// The threshold as a fraction of the raw finite range: 0 is the minimum, 1 the maximum (`.manual` only).
    package var thresholdFraction = 0.5
    /// Gaussian smoothing before the threshold, in pixels; 0 is none.
    package var sigma = 0.0
    package var connectivity: Segmentation.Connectivity = .eight
    /// An object of fewer pixels is removed from the mask before the objects are labelled.
    package var minimumArea = 4
    package init() {}
}

package nonisolated struct ParticleObject: Equatable, Sendable, Identifiable {
    package let moments: Segmentation.ObjectMoments
    package var id: Int32 { moments.label }
    package var touchesEdge: Bool { moments.touchesEdge }
    /// Counted in the statistics: not on the image edge (cut by it). Objects below the minimum area are not objects.
    package var isCounted: Bool { !touchesEdge }
}

package nonisolated struct ParticleSummary: Equatable, Sendable {
    /// The objects found, and the small ones removed: `counted + edge + small`.
    package var total = 0
    package var counted = 0
    /// Touching the image edge (whatever their size).
    package var edge = 0
    /// Below the minimum area, removed from the mask (not listed).
    package var small = 0
    /// Over the counted objects, in pixels; nil with none.
    package var medianLengthPx: Double?
    package var meanWidthPx: Double?
    /// Counted objects per unit area of the scale's unit, edge-corrected (Miles–Lantuéjoul); nil when the image is not calibrated.
    package var arealDensity: Double?
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

    /// `true` where the (smoothed) pixel is on the object side of the threshold. The manual level is a fraction of the raw range;
    /// Otsu's is ImagoKit's `threshold_otsu` of the finite pixels the mask is cut from (the smoothed ones when sigma > 0).
    package static func mask(pixels: [Float], width: Int, height: Int, range: ClosedRange<Float>, settings: ParticleSettings) throws -> (mask: [Bool], threshold: Float) {
        let data = try smoothed(pixels, width: width, height: height, sigma: settings.sigma, low: range.lowerBound)
        let t: Float
        switch settings.method {
        case .manual:
            guard let level = Thresholding.level(pixels, atFraction: settings.thresholdFraction) else { throw ParticleError.noFiniteValues }
            t = level
        case .otsu:
            let finite = data.filter(\.isFinite)
            guard !finite.isEmpty else { throw ParticleError.noFiniteValues }
            t = Float(try Thresholding.otsu(.float32(finite)))
        }
        return (Thresholding.mask(data, threshold: t, polarity: settings.polarity == .bright ? .bright : .dark), t)
    }

    /// The objects of `pixels` under `settings`. `pixelSize` (units per pixel, nil when not calibrated) gives the areal density.
    package static func analyse(pixels: [Float], width: Int, height: Int, settings: ParticleSettings,
                                pixelSize: Double? = nil) throws -> ParticleReport {
        guard let range = range(pixels) else { throw ParticleError.noFiniteValues }
        let cut = try mask(pixels: pixels, width: width, height: height, range: range, settings: settings)
        let found = try Segmentation.label(cut.mask, width: width, height: height, connectivity: settings.connectivity)
        // scikit-image's `remove_small_objects(max_size=)` clears objects of at most max_size pixels: below the minimum is minimum − 1.
        let kept = try BinaryMorphology.removeSmallObjects(cut.mask, width: width, height: height, maxSize: settings.minimumArea - 1,
                                                           connectivity: settings.connectivity)
        let labels = try Segmentation.label(kept, width: width, height: height, connectivity: settings.connectivity)
        let objects = try Segmentation.objectMoments(labels).map { ParticleObject(moments: $0) }
        let density = try ObjectStatistics.arealDensity(labels: labels, pixelSize: pixelSize)
        var s = ParticleSummary()
        s.counted = density.counted
        s.edge = density.edgeExcluded
        s.small = found.count - labels.count
        s.total = s.counted + s.edge + s.small
        s.medianLengthPx = density.medianLength
        s.meanWidthPx = density.meanWidth
        s.arealDensity = density.arealDensity
        return ParticleReport(settings: settings, width: width, height: height, thresholdValue: cut.threshold, objects: objects,
                              summary: s, labels: labels)
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
    package static func number(_ v: Double) -> String { String(format: "%.3g", v) }

    /// The same number for the CSV a script reads: printf's `%.3g`, always a point, whatever the shown numbers do.
    package static func csvNumber(_ v: Double) -> String { String(format: "%.3g", v) }

    /// "128 objects · 97 counted · 19 edge · 12 small".
    package static func counts(_ s: ParticleSummary) -> String {
        "\(s.total) object\(s.total == 1 ? "" : "s") · \(s.counted) counted · \(s.edge) edge · \(s.small) small"
    }

    /// "median length 18.2 nm · mean width 5.9 nm", or why there is none.
    package static func sizes(_ s: ParticleSummary, scale: ParticleScale) -> String {
        guard let l = s.medianLengthPx, let w = s.meanWidthPx else { return s.total == 0 ? "No objects above the threshold." : "No object is counted." }
        return "median length \(number(l * scale.perPixel)) \(scale.unit) · mean width \(number(w * scale.perPixel)) \(scale.unit)"
    }

    /// "areal density 0.00123 /nm² (edge-corrected)", or why there is none.
    package static func density(_ s: ParticleSummary, scale: ParticleScale) -> String {
        guard scale.isCalibrated, let d = s.arealDensity else { return "No areal density: the image is not calibrated." }
        return "areal density \(number(d)) /\(scale.unit)² (edge-corrected)"
    }

    /// How the threshold was chosen, for the CSV's provenance line (point decimals: `csvNumber`).
    package static func threshold(_ r: ParticleReport) -> String {
        switch r.settings.method {
        case .manual: "fraction \(csvNumber(r.settings.thresholdFraction)) of the raw range = \(csvNumber(Double(r.thresholdValue)))"
        case .otsu: "Otsu (ImagoKit Thresholding.otsu, 256 bins) = \(csvNumber(Double(r.thresholdValue)))"
        }
    }

    /// The objects as CSV with provenance comment lines; lengths in the scale's unit beside the pixels.
    package static func csv(_ r: ParticleReport, scale: ParticleScale, fileName: String) -> String {
        let u = scale.isCalibrated ? scale.unit : "px"
        let densityLine = scale.isCalibrated && r.summary.arealDensity != nil
            ? "# areal density: \(String(format: "%.6g", r.summary.arealDensity!)) per \(scale.unit)^2, counted objects weighted by Miles-Lantuejoul's edge correction (ImagoKit ObjectStatistics.arealDensity), validation: none"
            : "# areal density: none (the image is not calibrated)"
        var out = ["# macTEM particles, file: \(fileName), validation: none",
                   "# threshold: \(r.settings.polarity.rawValue) objects, \(threshold(r)), smoothing sigma \(csvNumber(r.settings.sigma)) px, connectivity \(r.settings.connectivity.rawValue), minimum area \(r.settings.minimumArea) px (smaller objects removed: ImagoKit BinaryMorphology.removeSmallObjects)",
                   "# \(ParticleFormat.counts(r.summary)); labels, centroids, lengths, widths and angles: ImagoKit Segmentation.objectMoments; counted = not touching the image edge",
                   densityLine,
                   "# length_ and width_ in \(u) (pixel size \(csvNumber(scale.perPixel)) \(scale.unit)/px); angle: long axis from +x toward +y, degrees",
                   // `small` stays so a script reading the columns by position keeps working: objects below the minimum area are now removed before
                   // labelling, so a listed object is never small (always 0); the count removed is in the summary line above.
                   "label,counted,touches_edge,small,area_px,centroid_x_px,centroid_y_px,length_px,width_px,angle_deg,length_\(u),width_\(u),area_\(u)2"]
        for o in r.objects {
            let m = o.moments
            let cells: [String] = ["\(m.label)", o.isCounted ? "1" : "0", m.touchesEdge ? "1" : "0", "0", "\(m.area)",
                                   String(format: "%.4f", m.centroidCol), String(format: "%.4f", m.centroidRow),
                                   String(format: "%.4f", m.lengthPx), String(format: "%.4f", m.widthPx), String(format: "%.3f", m.orientationDegrees),
                                   String(format: "%.5g", m.lengthPx * scale.perPixel), String(format: "%.5g", m.widthPx * scale.perPixel),
                                   String(format: "%.5g", Double(m.area) * scale.perPixel * scale.perPixel)]
            out.append(cells.joined(separator: ","))
        }
        return out.joined(separator: "\n") + "\n"
    }
}
