// The EELS room's spectrum, as values: the low loss and the core loss of one region (or the whole map) summed, the zero-loss mask the thickness rule cut,
// and, once Fit has run, the kit's model curve and the power-law background it fitted with the windows it used. Everything is a field of SpectroKit's
// thickness map or edge fit, read for the summed region as one pixel (the calls `EELSRegionCompute.row` makes); nothing here is a number of macTEM's own,
// but the background curve, which is the kit's `A * E^-r * channel width` (the part of `EELSModelResult.modelCurve` the kit does not hand out alone).
import Foundation
import SpectroCore
import SpectroEELS

/// One spectrum on its own energy axis.
package nonisolated struct EELSPlotCurve: Equatable, Sendable {
    package let origin: Double
    package let step: Double
    package let counts: [Double]

    package init(origin: Double, step: Double, counts: [Double]) { self.origin = origin; self.step = step; self.counts = counts }

    package func energy(_ i: Int) -> Double { origin + step * Double(i) }
    package var range: ClosedRange<Double> { origin...max(energy(max(counts.count - 1, 0)), origin) }
}

package nonisolated struct EELSPlotEdge: Equatable, Sendable {
    package let title: String
    package let onsetEV: Double
}

/// What the fit of the plot's region was made from (the picks, microscope and convolution of the last Fit).
package nonisolated struct EELSPlotFit: Equatable, Sendable {
    package let edges: [CoreLossEdge]
    package let microscope: EELSMicroscope
    package let convolve: Bool
    /// The windows the last Fit passed the kit: one per fitted edge, in onset order.
    package let windows: [EdgeWindows]

    package init(edges: [CoreLossEdge], microscope: EELSMicroscope, convolve: Bool, windows: [EdgeWindows]) {
        self.edges = edges; self.microscope = microscope; self.convolve = convolve; self.windows = windows
    }

    package static func == (a: EELSPlotFit, b: EELSPlotFit) -> Bool {
        a.edges == b.edges && a.convolve == b.convolve && a.windows == b.windows && a.microscope.beamEnergyKeV == b.microscope.beamEnergyKeV
            && a.microscope.convergenceMrad == b.microscope.convergenceMrad && a.microscope.collectionMrad == b.microscope.collectionMrad
    }
}

/// One fitted edge's background: the kit's power law A E^-r (counts per channel) from its background window's start to its signal window's end, NaN elsewhere.
package nonisolated struct EELSPlotBackground: Equatable, Sendable {
    package let edgeID: String
    package let windows: EELSEdgeWindows
    package let exponent: Double
    package let curve: [Double]
}

package nonisolated struct EELSPlotData: Equatable, Sendable {
    package var regionName: String
    package var pixels: Int
    package var low: EELSPlotCurve
    package var core: EELSPlotCurve?
    /// From the low loss's start to the threshold the thickness rule cut I₀ at.
    package var zlpMaskEV: ClosedRange<Double>?
    /// The kit's model on the core-loss axis, NaN outside the signal windows (the model holds nothing there); nil before Fit.
    package var model: [Double]?
    /// The kit's power law of each fitted edge (`edgeBackgrounds`) with the windows it was fitted on; empty before Fit.
    package var backgrounds: [EELSPlotBackground] = []
    package var edges: [EELSPlotEdge]
    package var thickness: EELSThicknessStats?

    package init(regionName: String, pixels: Int, low: EELSPlotCurve, core: EELSPlotCurve?, zlpMaskEV: ClosedRange<Double>?, model: [Double]?,
                 backgrounds: [EELSPlotBackground] = [], edges: [EELSPlotEdge], thickness: EELSThicknessStats?) {
        self.regionName = regionName; self.pixels = pixels; self.low = low; self.core = core; self.zlpMaskEV = zlpMaskEV; self.model = model
        self.backgrounds = backgrounds; self.edges = edges; self.thickness = thickness
    }
}

package nonisolated enum EELSPlotCompute {
    /// The plot of `region` (`.wholeMap` for every pixel). Nil when the region holds no pixel.
    package static func make(name: String, region: EDXRegion, low: LowLossSpectrumImage, core: CoreLossSpectrumImage?, map: ThicknessMap?,
                             threshold: EELSThresholdChoice, meanFreePath: MeanFreePathSource?, fit: EELSPlotFit?) -> EELSPlotData? {
        guard let lowSum = EELSRegionCompute.summedLowLoss(low, region: region) else { return nil }
        let pixels = region.pixelCount(nx: low.nx, ny: low.ny)
        let lowCurve = EELSPlotCurve(origin: low.energyOffsetEV, step: low.energyScaleEV, counts: lowSum.counts)
        var data = EELSPlotData(regionName: name, pixels: pixels, low: lowCurve, core: nil, zlpMaskEV: nil, model: nil, edges: [], thickness: map.flatMap { EELSThicknessStats.of($0, region: region) })
        if let cut = (try? EELSCompute.map(image: lowSum, threshold: threshold, meanFreePath: meanFreePath))?.pixels.first?.thresholdEV, cut > lowCurve.origin {
            data.zlpMaskEV = lowCurve.origin...cut
        }
        guard let core else { return data }
        let coreSum: CoreLossSpectrumImage?
        if let mask = region.mask(nx: core.nx, ny: core.ny) { coreSum = try? core.sum(mask: mask) }
        else { coreSum = try? core.sum(mask: [Bool](repeating: true, count: core.nx * core.ny)) }
        guard let coreSum else { return data }
        data.core = EELSPlotCurve(origin: coreSum.energyOffsetEV, step: coreSum.energyScaleEV, counts: coreSum.counts)
        if let fit, !fit.edges.isEmpty,
           let result = try? EELSFitCompute.fit(coreLoss: coreSum, edges: fit.edges, microscope: fit.microscope, lowLoss: fit.convolve ? lowSum : nil,
                                                edgeWindows: fit.windows) {
            let step = coreSum.energyScaleEV, origin = coreSum.energyOffsetEV
            let ranges = result.fitRangeEV ?? []
            data.model = result.modelCurve(pixel: 0).map { curve in
                curve.enumerated().map { k, v in ranges.contains { $0.contains(origin + step * Double(k)) } ? v : .nan }
            }
            if let all = result.edgeBackgrounds?.first {
                for (g, edge) in result.edges.enumerated() where g < all.count && g < fit.windows.count {
                    guard let p = all[g] else { continue }
                    let w = EELSEdgeWindows(fit.windows[g])
                    let span = w.background.lowerBound...w.signal.upperBound
                    // The kit's term: A * E^-r * channel width, zero at E <= 0.
                    let curve = (0..<coreSum.channels).map { k -> Double in
                        let e = origin + step * Double(k)
                        return span.contains(e) && e > 0 ? p.a * pow(e, -p.r) * step : .nan
                    }
                    data.backgrounds.append(EELSPlotBackground(edgeID: EELSFitCompute.id(edge), windows: w, exponent: p.r, curve: curve))
                }
            }
            data.edges = result.edges.map { EELSPlotEdge(title: EELSFitCompute.title($0), onsetEV: $0.onsetEV) }
        }
        return data
    }
}
