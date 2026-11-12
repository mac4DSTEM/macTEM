// Two readouts of an EELS fit that SpectroKit 0.12.0 does not give as one number: the 1 sigma on the composition, and how well the model fits.
//
// SIGMA ON at% AND wt% (interim, delete at the SpectroKit version whose `EELSCompositionPixel` carries its sigma). The kit's composition is
// f_i = w_i a_i / S, S = sum_j w_j a_j, over the quantified elements' amounts a (each element's first edge in fit order, the kit's intensity) with
// w = 1 for at% and w = the kit's atomic mass for wt% (`EELSQuantification.composition`). First-order propagation with independent amounts, each with
// the kit's own 1 sigma (`intensityStd` of the exact fit, `standardError` of MLLS):
//
//     var(f_i) = sum_j (w_j sigma_j / S)^2 (delta_ij - f_i)^2          (x 100 for percent)
//
// the same first-order rule as the kit's EDX composition sigma (`EDXQuantification.quantifyWithSigma`, a diagonal covariance), which the tests compare
// it with. Not in it: the covariance between the amounts (MLLS fits every edge in one solve, and exact-fit edges whose background window lies in an
// earlier edge's signal window share counts; the kit gives only the diagonal, so the sigma of a ratio can read low there), the cross sections and the
// atomic masses (taken as exact). A first-order sigma is a poor guide near 0 or 100 % on a few counts. The exact fit's sigma assumes raw counts: on a
// deconvolved core loss the rows carry none (`EELSFitCompute.rows(rawCounts:)`).
//
// FIT QUALITY. The residual sum of squares is the kit's (`EELSModelResult.residualSumOfSquares`, `EELSMLLSPixel.residualSumOfSquares`). The degrees of
// freedom are the kit's for MLLS (`degreesOfFreedom`: window channels less the amplitudes); for the exact fit they are the channels of the edges' signal
// windows (`fitRangeEV`, where the kit sums its residual) less one intensity per edge (each background is fitted on its own window, not on these
// channels; its extrapolation error enters every signal channel, so the exact fit's chi-squared reads above 1 by construction and is not comparable
// with MLLS's). Pearson's statistic takes the counts as detected electrons: on gain-unit counts it scales with the gain. The reduced chi-squared is Pearson's, as the EDS room's: sum over those channels of (counts - model)^2 / model, divided by the degrees of
// freedom; refused where the model is not positive on every one of them (an unconstrained MLLS can go negative). It assumes raw detected counts
// (Poisson variance = mean): a deconvolved core loss is not, and gets none.
import Foundation
import SpectroCore
import SpectroEELS

/// The composition's first-order 1 sigma (see the file header).
package nonisolated enum EELSCompositionSigma {
    /// The formula in words, for the method JSON and the tooltip.
    package static let formula = "first-order propagation of each element's 1σ amount (the kit's) to at% and wt%; amounts taken as independent (MLLS amounts, "
        + "and exact-fit edges sharing counts with an earlier signal window, covary: the σ can read low there); cross sections and atomic masses exact"

    /// 100 x sigma of f_i = w_i a_i / sum_j w_j a_j for every i; nil when a sigma is missing or not finite, or the sum is not positive.
    package static func percentSigmas(amounts a: [Double], sigmas s: [Double?], weights w: [Double]) -> [Double]? {
        guard a.count == s.count, a.count == w.count, !a.isEmpty else { return nil }
        let sigmas = s.compactMap { $0 }
        guard sigmas.count == a.count, sigmas.allSatisfy({ $0.isFinite && $0 >= 0 }), a.allSatisfy(\.isFinite), w.allSatisfy({ $0.isFinite && $0 > 0 }) else {
            return nil
        }
        let total = zip(w, a).map { $0 * $1 }.reduce(0, +)
        guard total > 0 else { return nil }
        let f = zip(w, a).map { $0 * $1 / total }
        return (0..<a.count).map { i in
            var v = 0.0
            for j in 0..<a.count {
                let d = (i == j ? 1 : 0) - f[i]
                let t = w[j] * sigmas[j] / total
                v += t * t * d * d
            }
            return 100 * v.squareRoot()
        }
    }

    /// The at% and wt% sigmas of `symbols` at `pixel` of `result`, in the order of `symbols`; nil where the kit gives no sigma for an amount.
    package static func sigmas(_ result: EELSFitResult, pixel: Int, symbols: [String]) -> (atomic: [Double], weight: [Double])? {
        var amounts: [Double] = [], stds: [Double?] = [], masses: [Double] = []
        for s in symbols {
            guard let g = result.edges.firstIndex(where: { $0.element == s }), let i = result.intensity(pixel: pixel, edge: g),
                  let m = EELSQuantification.atomicMasses[s] else { return nil }
            amounts.append(i); stds.append(result.intensityStd(pixel: pixel, edge: g)); masses.append(m)
        }
        guard let at = percentSigmas(amounts: amounts, sigmas: stds, weights: amounts.map { _ in 1 }),
              let wt = percentSigmas(amounts: amounts, sigmas: stds, weights: masses) else { return nil }
        return (at, wt)
    }
}

/// How well one pixel's model fits (see the file header).
package nonisolated struct EELSFitQuality: Equatable, Sendable {
    /// The kit's residual sum of squares, counts².
    package let rss: Double
    /// The channels the residual is summed over, and the amplitudes fitted on them.
    package let channels: Int
    package let parameters: Int
    /// Pearson's chi-squared over the degrees of freedom; nil for data that are not raw counts, or with no degree of freedom left.
    package let reducedChiSquared: Double?
    /// Why `reducedChiSquared` is nil.
    package let chiSquaredUnavailable: String?
    package var degreesOfFreedom: Int { channels - parameters }

    package init(rss: Double, channels: Int, parameters: Int, reducedChiSquared: Double?, chiSquaredUnavailable: String? = nil) {
        self.rss = rss; self.channels = channels; self.parameters = parameters; self.reducedChiSquared = reducedChiSquared
        self.chiSquaredUnavailable = chiSquaredUnavailable
    }

    package static let notCounts = "the core loss is deconvolved, not raw counts: no Pearson χ²"
    package static let noFreedom = "no degree of freedom left"

    package static let modelNotPositive = "the model is not positive on every fitted channel: no Pearson χ²"

    /// Pearson's chi-squared over `channels` of `counts` against `model`, divided by the number of channels less `parameters`. Refused (with the
    /// sentence) when the model is not positive and finite on every one of those channels, or no degree of freedom is left.
    package static func pearsonReduced(counts: [Double], model: [Double], channels: [Int], parameters: Int) -> Result<Double, Refusal> {
        var chi = 0.0
        for k in channels {
            guard k >= 0, k < counts.count, k < model.count, model[k] > 0, model[k].isFinite, counts[k].isFinite else {
                return .failure(Refusal(text: modelNotPositive))
            }
            let d = counts[k] - model[k]
            chi += d * d / model[k]
        }
        let dof = channels.count - parameters
        return dof > 0 ? .success(chi / Double(dof)) : .failure(Refusal(text: noFreedom))
    }

    package struct Refusal: Error, Equatable, Sendable {
        package let text: String
        package init(text: String) { self.text = text }
    }

    /// The channels of `core` the fit's residual is summed over: the MLLS window, or the exact fit's signal windows (each channel once).
    package static func fittedChannels(_ result: EELSFitResult, core: CoreLossSpectrumImage) -> [Int] {
        switch result {
        case .mlls(let r): return Array(r.windowChannels)
        case .exactNNLS(let r):
            var out: [Int] = []
            for range in r.fitRangeEV ?? [] {
                let lo = Int(((range.lowerBound - core.energyOffsetEV) / core.energyScaleEV).rounded())
                let hi = Int(((range.upperBound - core.energyOffsetEV) / core.energyScaleEV).rounded())
                guard lo <= hi else { continue }
                for k in max(lo, 0)...min(hi, core.channels - 1) where !out.contains(k) { out.append(k) }
            }
            return out
        }
    }

    /// The quality of pixel 0 of `result`, fitted on `core` (a region's summed spectrum fitted as one pixel); nil where the kit gives no residual.
    /// `rawCounts` false (a deconvolved core loss) leaves the chi-squared out.
    package static func of(_ result: EELSFitResult, core: CoreLossSpectrumImage, pixel: Int = 0, rawCounts: Bool = true) -> EELSFitQuality? {
        guard pixel >= 0, pixel < result.pixelCount, pixel < core.pixelCount else { return nil }
        let rss: Double, channels: [Int], parameters: Int
        switch result {
        case .mlls(let r):
            guard let v = r.pixels[pixel].residualSumOfSquares else { return nil }
            rss = v
            channels = fittedChannels(result, core: core)
            parameters = channels.count - r.pixels[pixel].degreesOfFreedom
        case .exactNNLS(let r):
            guard pixel < r.residualSumOfSquares.count, let v = r.residualSumOfSquares[pixel] else { return nil }
            rss = v
            channels = fittedChannels(result, core: core)
            parameters = r.edges.count
        }
        guard !channels.isEmpty else { return nil }
        guard rawCounts else {
            return EELSFitQuality(rss: rss, channels: channels.count, parameters: parameters, reducedChiSquared: nil, chiSquaredUnavailable: notCounts)
        }
        let n = core.channels
        let counts = core.storedCounts.withRow(start: pixel * n, count: n) { Array($0) }
        guard let curve = result.modelCurve(pixel: pixel) else {
            return EELSFitQuality(rss: rss, channels: channels.count, parameters: parameters, reducedChiSquared: nil, chiSquaredUnavailable: modelNotPositive)
        }
        switch pearsonReduced(counts: counts, model: curve, channels: channels, parameters: parameters) {
        case .success(let chi): return EELSFitQuality(rss: rss, channels: channels.count, parameters: parameters, reducedChiSquared: chi)
        case .failure(let why): return EELSFitQuality(rss: rss, channels: channels.count, parameters: parameters, reducedChiSquared: nil, chiSquaredUnavailable: why.text)
        }
    }
}
