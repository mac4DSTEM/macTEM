//
//  EELSErrorWords.swift
//  Role: every refusal the EELS room can meet, as a sentence. SpectroKit's EELS errors carry fields and no text of their own (they are not
//        LocalizedError), so the room words them here: what went wrong and, where there is one, what the person can do. Never the raw case name.
//        A LocalizedError (the room's own refusals, the readers) keeps its own text; the window refusals keep `EELSWindowPlan.sentence(for:)`.
//

import Foundation
import SpectroCore
import SpectroEELS

package nonisolated enum EELSErrorWords {

    /// The sentence for `error`: the window sentence, then the kit's EELS errors, then a LocalizedError's own text, then a sentence naming the
    /// error type (never only the bare case name).
    package static func sentence(for error: Error) -> String {
        if let s = EELSWindowPlan.sentence(for: error) { return s }
        if let e = error as? EELSDeconvolutionError { return deconvolution(e) }
        if let e = error as? EELSAlignmentError { return alignment(e) }
        if let e = error as? EELSThicknessError { return thickness(e) }
        if let e = error as? EELSModelError { return model(e) }
        if let e = error as? EELSMLLSError { return mlls(e) }
        if let e = error as? EELSUnavailable { return capitalised(EELSFitCompute.words(e)) + "." }
        if let e = error as? EnergyAxisError { return axis(e) }
        if let text = (error as? LocalizedError)?.errorDescription { return text }
        return "The calculation stopped with an error the room has no sentence for (\(type(of: error)): \(error))."
    }

    private static func eV(_ v: Double) -> String { EELSRoomFormat.sig(v, 4) }

    private static func capitalised(_ s: String) -> String { s.prefix(1).uppercased() + s.dropFirst() }

    package static func deconvolution(_ e: EELSDeconvolutionError) -> String {
        switch e {
        case .noPeakWidth:
            "Pixel 0's low-loss tail is unusable: Fourier-ratio cannot estimate the zero-loss FWHM from it. Choose Fourier-log or Richardson-Lucy."
        case .invalidFWHM(let f):
            "The zero-loss FWHM came out as \(eV(f)) eV, which is not a width: choose Fourier-log or Richardson-Lucy."
        case .shapeMismatch(let expected, let got):
            "The low loss and the core loss cover different scans (\(expected) and \(got) pixels): deconvolution needs one pixel of each per scan position."
        case .kernelSizeMismatch(let expected, let got):
            "The zero-loss kernel has \(got) channels where \(expected) are needed."
        case .invalidPeakFactor(let f):
            "The peak-width factor \(EELSRoomFormat.sig(f, 3)) must lie strictly between 0 and 1."
        case .invalidIterations(let n):
            "Richardson-Lucy needs at least one iteration (asked for \(n))."
        case .extrapolationWindowTooWide(let window, let channels):
            "The tail extrapolation window (\(window) channels) is wider than the spectrum (\(channels) channels)."
        case .tooFewChannels(let n):
            "The zero-loss peak spans \(n) channel\(n == 1 ? "" : "s"), too few to deconvolve: check the thickness map's thresholds."
        case .fftSetup(let size):
            "The Fourier transform of length \(size) could not be set up."
        }
    }

    package static func alignment(_ e: EELSAlignmentError) -> String {
        switch e {
        case .maskShapeMismatch(let expected, let got):
            "The mask holds \(got) entries for \(expected) pixels."
        case .alsoAlignShapeMismatch:
            "The core loss covers a different scan than the low loss, so it cannot be aligned with it."
        case .signalRangeOutsideAxis(let a, let b):
            "The zero-loss search window \(eV(a))–\(eV(b)) eV lies outside the low-loss axis: the low loss holds no zero-loss peak to align on."
        case .emptyAfterCrop:
            "The zero-loss shifts are so large that no channel is defined in every pixel: the aligned spectra would be empty."
        case .nonFiniteShift(let pixel):
            "Pixel \(pixel)'s zero-loss shift is not a number."
        case .invalidOption(let why):
            "The alignment cannot start: \(why)."
        case .shiftCountMismatch(let expected, let got):
            "The alignment has \(got) shifts for \(expected) pixels."
        }
    }

    package static func thickness(_ e: EELSThicknessError) -> String {
        switch e {
        case .invalidShape(let nx, let ny, let channels, let counts):
            "The low loss is not a spectrum image of \(nx) × \(ny) pixels and \(channels) channels (\(counts) counts)."
        case .invalidEnergyAxis(let offset, let scale):
            "The low-loss energy axis (offset \(eV(offset)) eV, \(eV(scale)) eV per channel) is not usable: it needs a finite offset and a positive channel width."
        case .nonFiniteCounts(let pixel):
            "Pixel \(pixel) of the low loss holds a count that is not a number."
        case .searchWindowTooShort(let channels):
            "The zero-loss search range holds \(channels) channels; it needs at least 10."
        case .invalidSearchWindow(let start, let window):
            "The zero-loss search window (from \(eV(start)) eV, \(eV(window)) eV wide) is not usable."
        case .invalidSavitzkyGolay(let why):
            "The smoothing for the threshold cannot be applied: \(why)."
        case .invalidTolerance(let t):
            "The threshold tolerance \(EELSRoomFormat.sig(t, 3)) must be zero or more."
        case .perPixelThresholdCount(let expected, let got):
            "The per-pixel thresholds hold \(got) values for \(expected) pixels."
        case .invalidFixedThreshold(let t):
            "The threshold \(eV(t)) eV lies below the first channel of the low loss: set it inside the axis."
        case .zeroLossShapeMismatch(let enx, let eny, let gnx, let gny):
            "The zero-loss image is \(gnx) × \(gny) pixels; the low loss is \(enx) × \(eny)."
        case .invalidMeanFreePath(let why):
            "The mean free path cannot be used: \(why)."
        }
    }

    package static func model(_ e: EELSModelError) -> String {
        switch e {
        case .noEdgeInRange(let a, let b): "No chosen edge lies in \(eV(a))–\(eV(b)) eV."
        case .edgeNotBundled(let edge): "\(edge) has no bundled cross section."
        case .duplicateEdge(let edge): "\(edge) is chosen twice."
        case .lowLossShapeMismatch(let expected, let got):
            "The low loss has \(got) pixels and the core loss \(expected): the convolution needs one low-loss spectrum per core-loss pixel."
        case .backgroundWindowEmpty: "A background window holds no channel of the core loss."
        case .fitDidNotConverge(let pixel): "The edge model did not converge at pixel \(pixel)."
        case .lowLossScaleMismatch(let core, let low):
            "The low loss has \(eV(low)) eV per channel and the core loss \(eV(core)) eV: the convolution would shift the edges. Fit without the low loss."
        case .lowLossAxisHasNoZero: "The low-loss axis does not reach 0 eV, so it holds no zero-loss channel to convolve with: fit without the low loss."
        case .preEdgeWindowTooNarrow(let channels):
            "Only \(channels) channel\(channels == 1 ? "" : "s") lie below the first edge, too few for the background window."
        case .invalidMicroscope: "The beam energy, convergence or collection angle is not usable: check them under Microscope."
        case .crossSectionFailed(let why): "The cross section could not be computed: \(why)."
        case .symbolNotFitted(let s): "\(s) has no fitted edge."
        case .invalidExponentRange: "The power-law exponent range is not usable."
        case .maskShapeMismatch(let expected, let got): "The mask holds \(got) entries for \(expected) pixels."
        case .emptyMask: "No pixel is left to fit: every pixel is masked out."
        case .edgeWindowCountMismatch(let expected, let got): "The fit takes one window pair per edge: \(expected) edges, \(got) windows."
        case .overlappingSignalWindows(let a, let b):
            "The signal windows of \(a) and \(b) share energies; each channel of the signal belongs to one edge. Move or narrow one of them."
        case .edgeWindowInvalid(let edge, let why): "\(edge): \(why)."
        case .backgroundNotEstimable(let why): "The background cannot be estimated: \(why)."
        }
    }

    package static func mlls(_ e: EELSMLLSError) -> String {
        switch e {
        case .exponentCountMismatch(let expected, let got): "MLLS has \(got) exponents for \(expected) pixels."
        case .invalidExponent: "The MLLS power-law exponent is not usable."
        case .invalidReference(let index): "Reference \(index + 1) does not match the core-loss axis or holds a value that is not a number."
        case .windowTooNarrow(let channels, let amplitudes): "The MLLS window holds \(channels) channels for \(amplitudes) amplitudes: set Fit to higher."
        case .invalidWindow(let a, let b): "The MLLS window \(eV(a))–\(eV(b)) eV is not on the core-loss axis: set Fit to inside it."
        }
    }

    package static func axis(_ e: EnergyAxisError) -> String {
        switch e {
        case .outsideAxis(let v): "\(eV(v)) eV is outside the energy axis."
        case .sliceBeyondAxis(let a, let b): "The range \(eV(a))–\(eV(b)) eV lies beyond the energy axis."
        case .notANumber: "An energy is not a number."
        }
    }
}
