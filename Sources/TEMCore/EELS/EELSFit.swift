// The EELS room's edge model, on SpectroKit: the bundled edges that fit a core-loss window, the model fit (`EELSModelFit.fit`, exSpy's smart fit:
// a power-law background and the GOS edges by non-negative least squares with the exponent by Brent's method), the composition
// (`EELSQuantification.composition`) and the tiles and the region table made from them. Nothing here is a number of macTEM's own: every value is a
// field of `EdgeIntensityPixel` or `EELSCompositionPixel`. Validation: none.
import Foundation
import SpectroCore
import SpectroEELS

/// One edge row of the region table: the fitted intensity, and the composition when two or more elements are fitted.
package nonisolated struct EELSEdgeRow: Equatable, Sendable, Identifiable {
    package let id: String
    package let title: String
    package let onsetEV: Double
    package let intensity: Double?
    package let arealDensityPerNM2: Double?
    package let atomicPercent: Double?
    package let weightPercent: Double?
    /// The power-law exponent r fitted under this edge (the kit's `exponent(pixel:edge:)`).
    package let exponent: Double?
    package let unavailable: String?
    /// The kit's 1 sigma on `intensity` (`EdgeIntensityPixel.intensityStd`, Poisson counts through the background fit); nil where the kit gives none.
    package let intensityStd: Double?
    /// I at or under 3 sigma: the edge is not detected in this region, so its at% is not a number to read (Egerton's 3-sigma detection criterion).
    package var belowDetection: Bool {
        guard let i = intensity, let s = intensityStd, s > 0 else { return false }
        return i <= 3 * s
    }

    package init(id: String, title: String, onsetEV: Double, intensity: Double?, arealDensityPerNM2: Double?, atomicPercent: Double?, weightPercent: Double?,
                 exponent: Double? = nil, unavailable: String?, intensityStd: Double? = nil) {
        self.id = id; self.title = title; self.onsetEV = onsetEV; self.intensity = intensity; self.arealDensityPerNM2 = arealDensityPerNM2
        self.atomicPercent = atomicPercent; self.weightPercent = weightPercent; self.exponent = exponent; self.unavailable = unavailable
        self.intensityStd = intensityStd
    }
}

package nonisolated enum EELSFitCompute {

    /// The bundled edges a core-loss window can hold, one per shell: K, L1, L3, M3, M5 and the combined L2,3, M2,3, M4,5 (L2, M2 and M4 are the twins of
    /// L3, M3 and M5 in exSpy's model and are not offered alone), by onset. Every K, L and M edge exSpy builds with the dft GOS (SpectroKit 0.12.0). An
    /// edge needs `safeEV` of window before it for the background.
    package static let twins: Set<String> = ["L2", "M2", "M4"]

    package static func offeredEdges(in core: CoreLossSpectrumImage, safeEV: Double = 10) -> [CoreLossEdge] {
        let lo = core.energyOffsetEV + safeEV, hi = core.energyOffsetEV + core.energyScaleEV * Double(core.channels - 1)
        return CoreLossEdge.bundled
            .filter { !twins.contains($0.subshell) && $0.onsetEV >= lo && $0.onsetEV < hi }
            .sorted { ($0.onsetEV, $0.element, $0.subshell) < ($1.onsetEV, $1.element, $1.subshell) }
    }

    /// "Cu L3" / "Al L2,3" / "Mg K": the symbol and the shell as a person reads it (K1 is K).
    package static func title(_ edge: CoreLossEdge) -> String {
        edge.element + " " + (edge.subshell == "K1" ? "K" : edge.subshell)
    }

    /// A stable id for a pick ("Cu-L3").
    package static func id(_ edge: CoreLossEdge) -> String { edge.element + "-" + edge.subshell }

    package static func fit(coreLoss: CoreLossSpectrumImage, edges: [CoreLossEdge], microscope: EELSMicroscope, lowLoss: LowLossSpectrumImage?,
                            options: EELSModelOptions = EELSModelOptions(), edgeWindows: [EdgeWindows]? = nil,
                            cancelled: @Sendable () -> Bool = SpectroCancellation.task, progress: (@Sendable (Double) -> Void)? = nil) throws -> EELSModelResult {
        try EELSModelFit.fit(coreLoss: coreLoss, edges: edges, microscope: microscope, lowLoss: lowLoss, options: options, edgeWindows: edgeWindows, cancelled: cancelled, progress: progress)
    }

    /// The elements fitted, in fit order, one per symbol.
    package static func symbols(_ result: EELSModelResult) -> [String] {
        var seen: [String] = []
        for e in result.edges where !seen.contains(e.element) { seen.append(e.element) }
        return seen
    }

    /// The composition at every pixel, or nil when fewer than two elements are fitted (one element is 100 % by construction) or the kit refuses.
    package static func composition(_ result: EELSModelResult) -> [EELSCompositionPixel]? {
        let symbols = symbols(result)
        guard symbols.count >= 2 else { return nil }
        return try? EELSQuantification.composition(result, symbols: symbols)
    }

    /// One tile per fitted edge (its intensity, or the areal density when the low loss was convolved) and, with two or more elements, one at% tile
    /// per element. NaN where the kit has no value; the footer counts them with the kit's reason.
    package static func tiles(_ result: EELSModelResult, composition: [EELSCompositionPixel]?, version: Int) -> [EELSMapTile] {
        var out: [EELSMapTile] = []
        for (g, edge) in result.edges.enumerated() {
            let values = result.pixels.map { px -> Double in
                let p = px[g]
                return (result.convolved ? p.arealDensityPerNM2 : p.intensity) ?? .nan
            }
            let missing = result.pixels.filter { $0[g].intensity == nil }.count
            let why = missing == 0 ? nil : "\(missing) px: no fit"
            out.append(EELSMapTile(id: "edge-" + id(edge), title: title(edge), unit: result.convolved ? "nm⁻²" : "intensity",
                                   width: result.nx, height: result.ny, values: values, version: version, footer: why))
        }
        if let composition {
            for (i, symbol) in symbols(result).enumerated() {
                let values = composition.map { $0.atomicPercent.indices.contains(i) ? $0.atomicPercent[i] : Double.nan }
                let missing = composition.filter { $0.unavailable != nil }.count
                out.append(EELSMapTile(id: "at-" + symbol, title: symbol, unit: "at%", width: result.nx, height: result.ny, values: values, version: version,
                                       footer: missing == 0 ? nil : "\(missing) px: no composition"))
            }
        }
        return out
    }

    /// The region table: one row per fitted edge for the one pixel of `result` (a summed region fitted as a 1 x 1 image).
    package static func rows(_ result: EELSModelResult, composition: [EELSCompositionPixel]?) -> [EELSEdgeRow] {
        guard let px = result.pixels.first else { return [] }
        let symbols = symbols(result)
        return result.edges.enumerated().map { g, edge in
            let p = px[g]
            let col = symbols.firstIndex(of: edge.element)
            let comp = composition?.first
            return EELSEdgeRow(id: id(edge), title: title(edge), onsetEV: edge.onsetEV, intensity: p.intensity, arealDensityPerNM2: p.arealDensityPerNM2,
                               atomicPercent: col.flatMap { c in comp.flatMap { $0.atomicPercent.indices.contains(c) ? $0.atomicPercent[c] : nil } },
                               weightPercent: col.flatMap { c in comp.flatMap { $0.weightPercent.indices.contains(c) ? $0.weightPercent[c] : nil } },
                               exponent: result.exponent(pixel: 0, edge: g),
                               unavailable: p.unavailable.map { "\($0)" }, intensityStd: p.intensityStd)
        }
    }
}
