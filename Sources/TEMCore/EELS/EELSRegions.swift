// Regions of the EELS room (design 2026-10-22 §2.1): a shape drawn on a map is a region whose spectra are summed over its pixels (SpectroKit's
// `EELSSpectrumImage.sum(mask:)`, the mask the EDX room's shapes make) and read as one pixel: the low loss through the thickness method of the maps
// (`EELSThickness.logRatio` on the 1 x 1 sum) and the core loss through the edge model (`EELSModelFit.fit` on the 1 x 1 sum), the same calls the whole-map
// region table makes. Nothing here is a number of macTEM's own; this file chooses the inputs.
import Foundation
import SpectroCore
import SpectroEDX
import SpectroEELS

/// One region's row: its pixels, the summed low loss's total and t/λ, and, with the edge model's inputs, one row per fitted edge.
package nonisolated struct EELSRegionRow: Equatable, Sendable, Identifiable {
    package let pin: EDXPin
    package let pixels: Int
    package let totalCounts: Double
    package let tOverLambda: Double?
    package let edges: [EELSEdgeRow]
    package var id: EDXPin.ID { pin.id }
    package init(pin: EDXPin, pixels: Int, totalCounts: Double, tOverLambda: Double?, edges: [EELSEdgeRow]) {
        self.pin = pin; self.pixels = pixels; self.totalCounts = totalCounts; self.tOverLambda = tOverLambda; self.edges = edges
    }
}

package nonisolated enum EELSRegionCompute {
    /// The summed low-loss spectrum of `region` as stored counts (nil when the region holds no pixel of the image).
    package static func summedLowLoss(_ low: LowLossSpectrumImage, region: EDXRegion) -> LowLossSpectrumImage? {
        guard let mask = region.mask(nx: low.nx, ny: low.ny) else { return try? low.sum(mask: [Bool](repeating: true, count: (low.nx * low.ny))) }
        return try? low.sum(mask: mask)
    }

    /// The row of one pin. `core`, `edges` and `microscope` (all three) switch the edge fit on; `convolve` hands the summed low loss to it.
    package static func row(pin: EDXPin, low: LowLossSpectrumImage, core: CoreLossSpectrumImage?, edges: [CoreLossEdge], microscope: EELSMicroscope?,
                            convolve: Bool, threshold: EELSThresholdChoice, meanFreePath: MeanFreePathSource?, edgeWindows: [EdgeWindows]? = nil) -> EELSRegionRow? {
        guard let lowSum = summedLowLoss(low, region: pin.region) else { return nil }
        let pixels = pin.region.pixelCount(nx: low.nx, ny: low.ny)
        let t = (try? EELSCompute.map(image: lowSum, threshold: threshold, meanFreePath: meanFreePath))?.pixels.first?.tOverLambda
        var edgeRows: [EELSEdgeRow] = []
        if let core, !edges.isEmpty, let microscope, core.nx == low.nx, core.ny == low.ny {
            let coreSum: CoreLossSpectrumImage?
            if let mask = pin.region.mask(nx: core.nx, ny: core.ny) { coreSum = try? core.sum(mask: mask) } else { coreSum = try? core.sum(mask: [Bool](repeating: true, count: (core.nx * core.ny))) }
            if let coreSum, let fit = try? EELSFitCompute.fit(coreLoss: coreSum, edges: edges, microscope: microscope, lowLoss: convolve ? lowSum : nil,
                                                           edgeWindows: edgeWindows) {
                edgeRows = EELSFitCompute.rows(fit, composition: EELSFitCompute.composition(fit))
            }
        }
        return EELSRegionRow(pin: pin, pixels: pixels, totalCounts: lowSum.counts.reduce(0, +), tOverLambda: t, edges: edgeRows)
    }
}
