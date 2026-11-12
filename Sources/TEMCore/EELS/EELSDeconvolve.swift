// The EELS room's Deconvolve stage, on SpectroKit's `EELSDeconvolution`: Fourier-ratio (the core loss by the low loss: the single-scattering core loss
// the edge model then fits, unconvolved), Fourier-log (the low loss by its zero-loss peak: the single-scattering distribution) and Richardson-Lucy (the low
// loss by its zero-loss peak as the point-spread function). The zero-loss peak of a pixel is its own low loss below the threshold the thickness map cut it
// at (`ThicknessPixel.thresholdChannel`, exSpy's `s.isig[:threshold]`), zero above; nothing here is a number of macTEM's own. Reference: `EELSLiterature.deconvolution` (Egerton, ch. 4).
import Foundation
import SpectroCore
import SpectroEELS

/// The Processing section's Deconvolution choice.
package enum EELSDeconvolutionChoice: Equatable, Hashable, Sendable {
    case off
    case fourierLog
    case fourierRatio
    case richardsonLucy(iterations: Int)

    /// exSpy's default number of Richardson-Lucy iterations.
    package static let defaultIterations = 15

    package enum Kind: String, CaseIterable, Hashable, Sendable { case off, fourierLog, fourierRatio, richardsonLucy }

    package var kind: Kind {
        switch self {
        case .off: .off
        case .fourierLog: .fourierLog
        case .fourierRatio: .fourierRatio
        case .richardsonLucy: .richardsonLucy
        }
    }

    package static func make(_ kind: Kind, iterations: Int = defaultIterations) -> EELSDeconvolutionChoice {
        switch kind {
        case .off: .off
        case .fourierLog: .fourierLog
        case .fourierRatio: .fourierRatio
        case .richardsonLucy: .richardsonLucy(iterations: iterations)
        }
    }

    package var title: String { kind.title }

    /// Whether the edge model fits the deconvolved core loss (Fourier-ratio), so the low loss is not convolved in again.
    package var feedsTheFit: Bool { self == .fourierRatio }
}

extension EELSDeconvolutionChoice.Kind {
    package var title: String {
        switch self {
        case .off: "Off"
        case .fourierLog: "Fourier-log"
        case .fourierRatio: "Fourier-ratio"
        case .richardsonLucy: "Richardson-Lucy"
        }
    }

    /// What each does, for the picker's tooltip.
    package var help: String {
        switch self {
        case .off: "No deconvolution: the edge model fits the core loss as stored"
        case .fourierLog: "Fourier-log: the low loss by its zero-loss peak, the single-scattering distribution (drawn dashed; the thickness and the fit do not use it)"
        case .fourierRatio: "Fourier-ratio: the core loss by the low loss; the edge model then fits the single-scattering core loss, not convolved with the low loss"
        case .richardsonLucy: "Richardson-Lucy: the low loss by its zero-loss peak as the point-spread function (drawn dashed; the thickness and the fit do not use it)"
        }
    }

    /// What it needs that a file may not have, or nil.
    package func blocker(hasLowLoss: Bool, hasCoreLoss: Bool) -> String? {
        switch self {
        case .off: nil
        case .fourierRatio:
            !hasLowLoss ? "Fourier-ratio needs the low loss with its zero-loss peak." : !hasCoreLoss ? "Fourier-ratio needs a core loss to deconvolve." : nil
        case .fourierLog, .richardsonLucy: hasLowLoss ? nil : "\(title) needs the low loss with its zero-loss peak."
        }
    }
}

/// What the stage made: the deconvolved low loss (Fourier-log, Richardson-Lucy) or core loss (Fourier-ratio), the kit's per-pixel reasons and its
/// parameters as the export records them.
package nonisolated struct EELSDeconvolutionResult: Sendable {
    package let choice: EELSDeconvolutionChoice
    package let lowLoss: LowLossSpectrumImage?
    package let coreLoss: CoreLossSpectrumImage?
    /// The kit's reason per pixel (`DeconvolvedSpectrumImage.unavailable`), with `.noThreshold` where the map had no zero-loss threshold.
    package let unavailable: [EELSUnavailable?]
    package let fftSize: Int
    package let fwhmEV: Double?
    package let taperedChannels: Int
    package let methodName: String
    /// The threshold rule Fourier-ratio cut I₀ with (the room's), or the one the map's zero-loss peaks were cut at, in the method JSON's words.
    package let thresholdText: String
    /// That rule, for the footer's words in the reader's locale (`EELSDeconvolveCompute.line`).
    package let threshold: EELSThresholdChoice

    package var unavailableCount: Int { unavailable.filter { $0 != nil }.count }
    /// The pixels the kit answered (the rest are zeros in its image and must not be summed or fitted).
    package var answered: PixelMask { unavailable.map { $0 == nil } }
}

package nonisolated enum EELSDeconvolveCompute {

    /// Each pixel's zero-loss peak: its low loss on channels `[0, thresholdChannel)` of the map, zero above, over `channels` channels (nil: the largest
    /// threshold channel). A pixel with no threshold is all zeros; `noThreshold` lists them.
    package static func zeroLoss(_ low: LowLossSpectrumImage, map: ThicknessMap, channels: Int? = nil) throws -> (image: LowLossSpectrumImage, noThreshold: [Bool]) {
        guard map.nx == low.nx, map.ny == low.ny else { throw EELSDeconvolutionError.shapeMismatch(expected: low.pixelCount, got: map.nx * map.ny) }
        let stops = map.pixels.map { $0.thresholdChannel.map { min(max($0, 0), low.channels) } }
        let width = channels ?? (stops.compactMap { $0 }.max() ?? 0)
        guard width >= 2 else { throw EELSDeconvolutionError.tooFewChannels(width) }
        var out = [Double](repeating: 0, count: low.pixelCount * width)
        let stored = low.storedCounts
        for p in 0..<low.pixelCount {
            guard let stop = stops[p] else { continue }
            for c in 0..<min(stop, width) { out[p * width + c] = stored[p * low.channels + c] }
        }
        let image = try LowLossSpectrumImage(nx: low.nx, ny: low.ny, channels: width, counts: out, energyOffsetEV: low.energyOffsetEV, energyScaleEV: low.energyScaleEV)
        return (image, stops.map { $0 == nil })
    }

    /// The stage: the kit's method for `choice` on the working cubes. `map` is the thickness map of `low` (its thresholds cut the zero-loss peaks);
    /// `threshold` is the room's rule for Fourier-ratio's I₀. nil for `.off`.
    package static func run(_ choice: EELSDeconvolutionChoice, low: LowLossSpectrumImage?, core: CoreLossSpectrumImage?, map: ThicknessMap?,
                            threshold: EELSThresholdChoice, cancelled: @Sendable () -> Bool = SpectroCancellation.task,
                            progress: (@Sendable (Double) -> Void)? = nil) throws -> EELSDeconvolutionResult? {
        func merge(_ kit: [EELSUnavailable?], _ noThreshold: [Bool]) -> [EELSUnavailable?] {
            zip(kit, noThreshold).map { k, none in none ? .noThreshold : k }
        }
        switch choice {
        case .off:
            return nil
        case .fourierRatio:
            guard let low, let core else { throw EELSDeconvolveRefusal.needs(choice.kind.blocker(hasLowLoss: low != nil, hasCoreLoss: core != nil) ?? "") }
            let d = try EELSDeconvolution.fourierRatio(coreLoss: core, lowLoss: low, options: FourierRatioOptions(threshold: threshold.rule),
                                                       cancelled: cancelled, progress: progress)
            return EELSDeconvolutionResult(choice: choice, lowLoss: nil, coreLoss: d.image, unavailable: d.unavailable, fftSize: d.fftSize, fwhmEV: d.fwhmEV,
                                           taperedChannels: d.taperedChannels, methodName: d.methodName, thresholdText: thresholdWords(threshold),
                                           threshold: threshold)
        case .fourierLog:
            guard let low, let map else { throw EELSDeconvolveRefusal.needs("Fourier-log needs the low loss and its thickness map (Run the Thickness stage first).") }
            let zlp = try zeroLoss(low, map: map)
            let d = try EELSDeconvolution.fourierLog(low, zeroLoss: zlp.image, cancelled: cancelled, progress: progress)
            return EELSDeconvolutionResult(choice: choice, lowLoss: d.image, coreLoss: nil, unavailable: merge(d.unavailable, zlp.noThreshold), fftSize: d.fftSize,
                                           fwhmEV: nil, taperedChannels: d.taperedChannels, methodName: d.methodName, thresholdText: thresholdWords(threshold),
                                           threshold: threshold)
        case .richardsonLucy(let iterations):
            guard let low, let map else { throw EELSDeconvolveRefusal.needs("Richardson-Lucy needs the low loss and its thickness map (Run the Thickness stage first).") }
            let zlp = try zeroLoss(low, map: map, channels: low.channels)
            let d = try EELSDeconvolution.richardsonLucy(low, psf: zlp.image, options: RichardsonLucyOptions(iterations: iterations), cancelled: cancelled, progress: progress)
            return EELSDeconvolutionResult(choice: choice, lowLoss: d.image, coreLoss: nil, unavailable: merge(d.unavailable, zlp.noThreshold), fftSize: d.fftSize,
                                           fwhmEV: nil, taperedChannels: d.taperedChannels, methodName: d.methodName, thresholdText: thresholdWords(threshold),
                                           threshold: threshold)
        }
    }

    /// The threshold rule in the words the method JSON and the results CSV record (`thresholdText`): the eV as Swift writes a Double, a point.
    package static func thresholdWords(_ t: EELSThresholdChoice) -> String {
        switch t {
        case .estimated: "estimated threshold"
        case .fixed(let eV): "fixed threshold \(eV) eV"
        }
    }

    /// The threshold rule as the room's footer reads it, the eV in `locale` beside the FWHM ("fixed threshold 12,5 eV" in de_DE).
    package static func thresholdWords(_ t: EELSThresholdChoice, locale: Locale) -> String {
        switch t {
        case .estimated: "estimated threshold"
        case .fixed(let eV): "fixed threshold \(UnitDisplay.number(eV, locale: locale)) eV"
        }
    }

    /// The method and its parameters, for the method JSON (`deconvolution`) and the results CSV.
    package static func parameters(_ r: EELSDeconvolutionResult) -> [String: Any] {
        var d: [String: Any] = ["method": r.choice.title, "kit_method": r.methodName, "reference": EELSLiterature.deconvolution,
                                "pixels_unavailable": r.unavailableCount]
        switch r.choice {
        case .off: break
        case .fourierLog:
            d["zero_loss"] = "each pixel's low loss below its thickness-map threshold (\(r.thresholdText))"
            d["zero_loss_width"] = "one width for every pixel, the largest threshold channel, each pixel zero above its own threshold: exSpy's per-pixel call exactly for a fixed threshold"
            d["add_zero_loss"] = false; d["crop"] = false
            d["fft_size"] = r.fftSize; d["tapered_channels"] = r.taperedChannels
            d["output"] = "single-scattering low loss"
        case .fourierRatio:
            d["low_loss_threshold"] = r.thresholdText
            if let f = r.fwhmEV { d["fwhm_eV"] = f }
            d["fwhm_source"] = "estimated (estimate_peak_width of the first low-loss pixel)"
            d["extrapolate_low_loss"] = true; d["extrapolate_core_loss"] = true
            d["fft_size"] = r.fftSize; d["tapered_channels"] = r.taperedChannels
            d["output"] = "single-scattering core loss, fitted by the edge model without the low-loss convolution"
        case .richardsonLucy(let iterations):
            d["iterations"] = iterations
            d["psf"] = "each pixel's zero-loss peak: its low loss below its thickness-map threshold (\(r.thresholdText))"
            d["output"] = "deconvolved low loss"
        }
        return d
    }

    /// One line: "Fourier-ratio deconvolution (FWHM 1.23 eV, estimated threshold)" / "Richardson-Lucy deconvolution, 15 iterations", its
    /// numbers in `locale` (the room's footer and its log).
    package static func line(_ r: EELSDeconvolutionResult?, locale: Locale = .autoupdatingCurrent) -> String {
        guard let r else { return "no deconvolution" }
        return line(r, fwhmLocale: locale, threshold: thresholdWords(r.threshold, locale: locale))
    }

    /// The line as the results CSV records it: the FWHM with a point and the threshold in the method JSON's words (`thresholdText`).
    package static func recordLine(_ r: EELSDeconvolutionResult) -> String {
        line(r, fwhmLocale: Locale(identifier: "en_US_POSIX"), threshold: r.thresholdText)
    }

    private static func line(_ r: EELSDeconvolutionResult, fwhmLocale: Locale, threshold: String) -> String {
        switch r.choice {
        case .off: return "no deconvolution"
        case .fourierRatio: return r.methodName + " (" + (r.fwhmEV.map { "FWHM \(EELSRoomFormat.sig($0, 3, locale: fwhmLocale)) eV, " } ?? "") + threshold + ")"
        case .fourierLog: return r.methodName + " (zero-loss peak below the " + threshold + ")"
        case .richardsonLucy: return r.methodName + " (zero-loss peak below the " + threshold + ")"
        }
    }

    /// Why the deconvolution left a pixel unanswered, as words: a non-finite result is the low-loss tail's power-law continuation, the rest are the
    /// kit's own reasons (`EELSFitCompute.words`).
    package static func words(_ why: EELSUnavailable) -> String {
        why == .nonFiniteResult ? "the low-loss tail's power-law continuation is not finite" : EELSFitCompute.words(why)
    }

    /// The reason for pixel `p` of a result's `unavailable`, or nil when the kit answered it (or `p` is outside the result).
    package static func reason(_ unavailable: [EELSUnavailable?]?, pixel p: Int) -> String? {
        guard let unavailable, unavailable.indices.contains(p), let why = unavailable[p] else { return nil }
        return words(why)
    }

    /// The Deconvolve readout's part for the unanswered pixels of a result's `unavailable`: "3 px unanswered (2: the low-loss tail's …; 1: the zero-loss
    /// threshold has no value here)", by count then by first occurrence; nil when every pixel was answered. Those pixels are left out of the fit.
    package static func unansweredLine(_ unavailable: [EELSUnavailable?]) -> String? {
        var counts: [EELSUnavailable: Int] = [:], order: [EELSUnavailable] = []
        for case let why? in unavailable {
            if counts[why] == nil { order.append(why) }
            counts[why, default: 0] += 1
        }
        guard !order.isEmpty else { return nil }
        let total = counts.values.reduce(0, +)
        let parts = order.enumerated().sorted { (counts[$0.element]!, -$0.offset) > (counts[$1.element]!, -$1.offset) }
            .map { "\(counts[$0.element]!): \(words($0.element))" }
        return "\(total) px unanswered (" + parts.joined(separator: "; ") + ")"
    }
}

package enum EELSDeconvolveRefusal: Error, Equatable, LocalizedError {
    case needs(String)
    package var errorDescription: String? { if case .needs(let s) = self { s } else { nil } }
}
