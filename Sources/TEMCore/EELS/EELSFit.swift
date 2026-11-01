// The EELS room's edge model, on SpectroKit: the bundled edges that fit a core-loss window, the fit by the chosen model (`EELSModelFit.fit`, the exact
// per-edge fit: a power-law background and the GOS edge by non-negative least squares with the exponent by Brent's method; or `EELSMLLS.fit`, multiple
// linear least squares with the exponent fixed), the composition (`EELSQuantification.composition`, over the quantified elements only: a fit-only element
// stays in the model and out of the at%) and the tiles and the region table made from them. Nothing here is a number of macTEM's own: every value is a
// field of the kit's fit result (`EELSFitResult`) or of `EELSCompositionPixel`. Validation: none.
import Foundation
import SpectroCore
import SpectroEELS

/// One edge row of the region table: the fitted intensity, and the composition when two or more elements are quantified.
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
    /// The kit's 1 sigma on `intensity` (`EdgeIntensityPixel.intensityStd`, Poisson counts through the background fit; MLLS: the least-squares standard
    /// error); nil where the kit gives none.
    package let intensityStd: Double?
    /// Why `atomicPercent` is nil, when it is: one element quantified, a fit-only element, or the kit's reason for the pixel's composition.
    package let atomicUnavailable: String?
    /// The kit's flag: the fitted power-law exponent ended on a bound of its search range (`EELSModelResult.exponentAtBound`).
    package let exponentAtBound: Bool
    /// The edge's element is fit only: in the model, left out of the composition.
    package let fitOnly: Bool
    /// The 1 sigma on `atomicPercent` and `weightPercent` (`EELSCompositionSigma`: first order from the kit's sigma on each amount); nil where the kit gives
    /// no sigma for an amount, or there is no composition.
    package let atomicSigma: Double?
    package let weightSigma: Double?
    /// I at or under 3 sigma: the edge is not detected in this region, so its at% is not a number to read (Egerton's 3-sigma detection criterion).
    package var belowDetection: Bool {
        guard let i = intensity, let s = intensityStd, s > 0 else { return false }
        return i <= 3 * s
    }

    package init(id: String, title: String, onsetEV: Double, intensity: Double?, arealDensityPerNM2: Double?, atomicPercent: Double?, weightPercent: Double?,
                 exponent: Double? = nil, unavailable: String?, intensityStd: Double? = nil, atomicUnavailable: String? = nil, exponentAtBound: Bool = false,
                 fitOnly: Bool = false, atomicSigma: Double? = nil, weightSigma: Double? = nil) {
        self.id = id; self.title = title; self.onsetEV = onsetEV; self.intensity = intensity; self.arealDensityPerNM2 = arealDensityPerNM2
        self.atomicPercent = atomicPercent; self.weightPercent = weightPercent; self.exponent = exponent; self.unavailable = unavailable
        self.intensityStd = intensityStd; self.atomicUnavailable = atomicUnavailable; self.exponentAtBound = exponentAtBound; self.fitOnly = fitOnly
        self.atomicSigma = atomicSigma; self.weightSigma = weightSigma
    }

    /// The room's words for an at% that needs a second element.
    package static let atomicNeedsTwo = "at% needs two or more fitted elements"
    /// The words when fit-only elements leave fewer than two quantified ones.
    package static let atomicNeedsTwoQuantified = "at% needs two or more quantified elements: fit-only elements are left out of the composition"
    /// The words on a fit-only edge's at%.
    package static let fitOnlyWords = "fit only: in the model, left out of the composition"
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

    /// The kit's reason for a pixel with no answer, as a sentence: the words of SpectroKit's own documentation of each case (the enum has no
    /// description of its own).
    package static func words(_ why: EELSUnavailable) -> String {
        switch why {
        case .masked: "the pixel was masked out"
        case .nonFiniteResult: "the result is not finite"
        case .noPeak: "the spectrum has no peak to measure"
        case .divisionByZero: "a division by zero"
        case .noTwoRoots: "the half-maximum has not exactly two roots, so no width"
        case .noThreshold: "the zero-loss threshold has no value here"
        case .fitFailed: "the edge model could not be fitted (the least-squares solve failed or the spectrum has no support)"
        case .noComposition: "no composition: the fitted amounts sum to zero or an element's amount is missing"
        }
    }

    /// The MLLS options the room hands the kit: the kit's two-area exponent, and the fit window from the start of the first edge's background window (the
    /// window the person sees and drags) to the end of the axis. Without windows, the kit's defaults (the axis start).
    /// `fitToEV` is the Fitting section's Fit to: the last energy of the window, included (nil: the axis end).
    package static func mllsOptions(edgeWindows: [EdgeWindows]?, fitToEV: Double? = nil) -> EELSMLLSOptions {
        EELSMLLSOptions(exponent: .twoArea, startEnergyEV: edgeWindows?.map(\.backgroundEV.lowerBound).min(), endEnergyEV: fitToEV)
    }

    /// The fit by `model`: the exact fit on the per-edge windows, or MLLS over one window from the first background window to `fitToEV` (`mllsOptions`).
    package static func fit(coreLoss: CoreLossSpectrumImage, edges: [CoreLossEdge], microscope: EELSMicroscope, lowLoss: LowLossSpectrumImage?,
                            model: EELSFitModel = .exactNNLS, options: EELSModelOptions = EELSModelOptions(), edgeWindows: [EdgeWindows]? = nil,
                            fitToEV: Double? = nil, mask: PixelMask? = nil,
                            cancelled: @Sendable () -> Bool = SpectroCancellation.task, progress: (@Sendable (Double) -> Void)? = nil) throws -> EELSFitResult {
        switch model {
        case .exactNNLS:
            return .exactNNLS(try EELSModelFit.fit(coreLoss: coreLoss, edges: edges, microscope: microscope, lowLoss: lowLoss, mask: mask, options: options,
                                                   edgeWindows: edgeWindows, cancelled: cancelled, progress: progress))
        case .mlls:
            return .mlls(try EELSMLLS.fit(coreLoss: coreLoss, edges: edges, microscope: microscope, lowLoss: lowLoss, mask: mask,
                                          options: mllsOptions(edgeWindows: edgeWindows, fitToEV: fitToEV), cancelled: cancelled, progress: progress))
        }
    }

    /// The elements fitted, in fit order, one per symbol.
    package static func symbols(_ result: EELSFitResult) -> [String] {
        var seen: [String] = []
        for e in result.edges where !seen.contains(e.element) { seen.append(e.element) }
        return seen
    }

    /// The elements in the composition: the fitted ones less the fit-only ones, in fit order.
    package static func quantifiedSymbols(_ result: EELSFitResult, fitOnly: Set<String>) -> [String] {
        symbols(result).filter { !fitOnly.contains($0) }
    }

    /// The composition at every pixel, or nil when fewer than two elements are quantified (one element is 100 % by construction) or the kit refuses.
    package static func composition(_ result: EELSFitResult, fitOnly: Set<String> = []) -> [EELSCompositionPixel]? {
        try? compositionOrRefusal(result, fitOnly: fitOnly).get()
    }

    /// `composition`, with the kit's refusal kept as words (fewer than two quantified elements is the room's own refusal).
    package static func compositionOrRefusal(_ result: EELSFitResult, fitOnly: Set<String> = []) -> Result<[EELSCompositionPixel], CompositionRefusal> {
        let symbols = quantifiedSymbols(result, fitOnly: fitOnly)
        guard symbols.count >= 2 else {
            let leftOut = self.symbols(result).contains { fitOnly.contains($0) }
            return .failure(CompositionRefusal(text: leftOut ? EELSEdgeRow.atomicNeedsTwoQuantified : EELSEdgeRow.atomicNeedsTwo))
        }
        do { return .success(try result.composition(symbols: symbols)) } catch {
            return .failure(CompositionRefusal(text: "the kit refused the composition: \((error as? LocalizedError)?.errorDescription ?? "\(error)")"))
        }
    }

    package struct CompositionRefusal: Error, Equatable, Sendable { package let text: String }

    /// One tile per fitted edge (its intensity, or the exact fit's areal density when the low loss was convolved) and, with two or more quantified
    /// elements, one at% tile per quantified element. NaN where the kit has no value; the footer counts them.
    package static func tiles(_ result: EELSFitResult, composition: [EELSCompositionPixel]?, fitOnly: Set<String> = [], version: Int) -> [EELSMapTile] {
        var out: [EELSMapTile] = []
        let areal = result.convolved && result.model == .exactNNLS
        for (g, edge) in result.edges.enumerated() {
            let values = (0..<result.pixelCount).map { p -> Double in
                (areal ? result.arealDensity(pixel: p, edge: g) : result.intensity(pixel: p, edge: g)) ?? .nan
            }
            let missing = (0..<result.pixelCount).filter { result.intensity(pixel: $0, edge: g) == nil }.count
            let why = missing == 0 ? nil : "\(missing) px: no fit"
            out.append(EELSMapTile(id: "edge-" + id(edge), title: title(edge) + (fitOnly.contains(edge.element) ? " (fit only)" : ""),
                                   unit: areal ? "nm⁻²" : "intensity", width: result.nx, height: result.ny, values: values, version: version, footer: why))
        }
        if let composition {
            for (i, symbol) in quantifiedSymbols(result, fitOnly: fitOnly).enumerated() {
                let values = composition.map { $0.atomicPercent.indices.contains(i) ? $0.atomicPercent[i] : Double.nan }
                let missing = composition.filter { $0.unavailable != nil }.count
                out.append(EELSMapTile(id: "at-" + symbol, title: symbol, unit: "at%", width: result.nx, height: result.ny, values: values, version: version,
                                       footer: missing == 0 ? nil : "\(missing) px: no composition"))
            }
        }
        return out
    }

    /// The region table: one row per fitted edge for the one pixel of `result` (a summed region fitted as a 1 x 1 image). A fit-only edge keeps its I and
    /// has no at%.
    /// `rawCounts` false (a deconvolved core loss): the exact fit's Poisson σ does not hold, so the composition carries no σ (MLLS's σ is scaled by its own
    /// residual and stays).
    package static func rows(_ result: EELSFitResult, composition: [EELSCompositionPixel]?, fitOnly: Set<String> = [], rawCounts: Bool = true) -> [EELSEdgeRow] {
        guard result.pixelCount > 0 else { return [] }
        let symbols = quantifiedSymbols(result, fitOnly: fitOnly)
        let comp = composition?.first
        // Why a row has no at%: fewer than two quantified elements; else the kit's reason for the pixel, or its refusal of the call.
        let refusal: String? = if case .failure(let r) = compositionOrRefusal(result, fitOnly: fitOnly) { r.text } else { nil }
        let atomicWhy: String? = symbols.count < 2 ? refusal
            : comp.map { $0.unavailable.map(words) } ?? refusal ?? "the kit gave no composition for these elements"
        let atBound = result.exponentAtBound(pixel: 0)
        let sigmaHolds = rawCounts || result.model == .mlls
        let sigma = sigmaHolds && comp?.unavailable == nil && comp?.atomicPercent.count == symbols.count
            ? EELSCompositionSigma.sigmas(result, pixel: 0, symbols: symbols) : nil
        return result.edges.enumerated().map { g, edge in
            let isFitOnly = fitOnly.contains(edge.element)
            let col = isFitOnly ? nil : symbols.firstIndex(of: edge.element)
            let atomic = col.flatMap { c in comp.flatMap { $0.atomicPercent.indices.contains(c) ? $0.atomicPercent[c] : nil } }
            let why = isFitOnly ? EELSEdgeRow.fitOnlyWords : (atomicWhy ?? "the kit gave no at% for this edge")
            return EELSEdgeRow(id: id(edge), title: title(edge), onsetEV: edge.onsetEV, intensity: result.intensity(pixel: 0, edge: g),
                               arealDensityPerNM2: result.arealDensity(pixel: 0, edge: g), atomicPercent: atomic,
                               weightPercent: col.flatMap { c in comp.flatMap { $0.weightPercent.indices.contains(c) ? $0.weightPercent[c] : nil } },
                               exponent: result.exponent(pixel: 0, edge: g),
                               unavailable: result.unavailable(pixel: 0, edge: g).map(words), intensityStd: result.intensityStd(pixel: 0, edge: g),
                               atomicUnavailable: atomic == nil ? why : nil, exponentAtBound: atBound, fitOnly: isFitOnly,
                               atomicSigma: atomic == nil ? nil : col.flatMap { sigma?.atomic[$0] }, weightSigma: atomic == nil ? nil : col.flatMap { sigma?.weight[$0] })
        }
    }
}
