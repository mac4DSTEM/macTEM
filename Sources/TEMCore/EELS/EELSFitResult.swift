// The EELS room's two fit models behind one value: the exact fit (`EELSModelFit.fit`, non-negative least squares with the exponent by Brent's method) and the
// multiple linear least squares fit (`EELSMLLS.fit`, one QR solve per pixel with the exponent fixed by the two-area estimate). The room reads every number through
// this value; each accessor is a field of the kit's result, nothing is computed here. Reference: `EELSLiterature.edges`.
import Foundation
import SpectroCore
import SpectroEELS

/// The Fitting section's model.
package enum EELSFitModel: String, CaseIterable, Sendable {
    case exactNNLS, mlls

    package var title: String {
        switch self {
        case .exactNNLS: "Exact NNLS"
        case .mlls: "MLLS"
        }
    }

    /// The control's tooltip: what the kit does for each.
    package var help: String {
        switch self {
        case .exactNNLS: "Each edge on its own windows: a power law on the background window, the edge's intensity non-negative on the signal window (SpectroKit EELSModelFit)"
        case .mlls: "One linear least-squares solve per pixel from the first background window to the end of the axis: the power law with its exponent fixed by the two-area estimate and every edge at once, unconstrained (SpectroKit EELSMLLS)"
        }
    }
}

/// One fit of the room, by either model.
package nonisolated enum EELSFitResult: Sendable {
    case exactNNLS(EELSModelResult)
    case mlls(EELSMLLSResult)

    package var model: EELSFitModel {
        switch self {
        case .exactNNLS: .exactNNLS
        case .mlls: .mlls
        }
    }
    package var nx: Int { switch self { case .exactNNLS(let r): r.nx; case .mlls(let r): r.nx } }
    package var ny: Int { switch self { case .exactNNLS(let r): r.ny; case .mlls(let r): r.ny } }
    package var pixelCount: Int { nx * ny }
    /// The masters, in onset order.
    package var edges: [CoreLossEdge] { switch self { case .exactNNLS(let r): r.edges; case .mlls(let r): r.edges } }
    package var convolved: Bool { switch self { case .exactNNLS(let r): r.convolved; case .mlls(let r): r.convolved } }
    package var methodName: String { switch self { case .exactNNLS(let r): r.methodName; case .mlls(let r): r.methodName } }
    /// The kit's own trust word. Not shown in the room or its exports; the Results ledger reads it until its rows name the method instead.
    package var validation: String { switch self { case .exactNNLS(let r): r.validation; case .mlls(let r): r.validation } }
    /// The windows the exact fit was handed (nil for MLLS, which fits one window).
    package var edgeWindows: [EdgeWindows]? { if case .exactNNLS(let r) = self { r.edgeWindows } else { nil } }
    /// Where the model holds values: the exact fit's signal windows (none without per-edge windows), or the MLLS window.
    package var fitRangesEV: [ClosedRange<Double>] {
        switch self {
        case .exactNNLS(let r): r.fitRangeEV ?? []
        case .mlls(let r): [r.windowEV]
        }
    }

    /// The kit's intensity of edge `g` at `pixel`, or nil where it has none.
    package func intensity(pixel: Int, edge g: Int) -> Double? {
        switch self {
        case .exactNNLS(let r): r.pixels[pixel][g].intensity
        case .mlls(let r): r.pixels[pixel].intensities.indices.contains(g) ? r.pixels[pixel].intensities[g].value : nil
        }
    }

    /// The kit's 1 sigma on that intensity (the exact fit's Poisson sigma, MLLS's ordinary least-squares standard error).
    package func intensityStd(pixel: Int, edge g: Int) -> Double? {
        switch self {
        case .exactNNLS(let r): r.pixels[pixel][g].intensityStd
        case .mlls(let r): r.pixels[pixel].intensities.indices.contains(g) ? r.pixels[pixel].intensities[g].standardError : nil
        }
    }

    /// The exact fit's areal density (convolved only); the MLLS result carries none.
    package func arealDensity(pixel: Int, edge g: Int) -> Double? {
        if case .exactNNLS(let r) = self { r.pixels[pixel][g].arealDensityPerNM2 } else { nil }
    }

    package func unavailable(pixel: Int, edge g: Int) -> EELSUnavailable? {
        switch self {
        case .exactNNLS(let r): r.pixels[pixel][g].unavailable
        case .mlls(let r): r.pixels[pixel].unavailable
        }
    }

    /// The power-law exponent under edge `g` (the exact fit's per edge; MLLS's one fixed exponent of the pixel).
    package func exponent(pixel: Int, edge g: Int) -> Double? {
        switch self {
        case .exactNNLS(let r): r.exponent(pixel: pixel, edge: g)
        case .mlls(let r): r.pixels[pixel].exponent
        }
    }

    /// The exact fit's flag: the exponent ended on a bound of its search range. MLLS does not search (false).
    package func exponentAtBound(pixel: Int) -> Bool {
        if case .exactNNLS(let r) = self, r.exponentAtBound.indices.contains(pixel) { r.exponentAtBound[pixel] } else { false }
    }

    /// The kit's model curve over the whole core-loss axis at `pixel`.
    package func modelCurve(pixel: Int) -> [Double]? {
        switch self {
        case .exactNNLS(let r): r.modelCurve(pixel: pixel)
        case .mlls(let r): r.modelCurve(pixel: pixel)
        }
    }

    /// The exact fit's per-edge power laws at the first pixel (nil for MLLS: its one background is in the model curve).
    package var edgeBackgroundsOfFirstPixel: [PowerLawParameters?]? {
        if case .exactNNLS(let r) = self { r.edgeBackgrounds?.first } else { nil }
    }

    /// The kit's composition of `symbols` (each fitted), one per pixel.
    package func composition(symbols: [String]) throws -> [EELSCompositionPixel] {
        switch self {
        case .exactNNLS(let r): try EELSQuantification.composition(r, symbols: symbols)
        case .mlls(let r): try EELSQuantification.composition(r, symbols: symbols)
        }
    }
}
