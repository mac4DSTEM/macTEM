//
//  ImagePresentation.swift
//  Role: the one owner of how one open file is drawn — the display-normalised pixels the canvas uploads, the
//        colormap, the contrast window, the gamma and whether the scale bar shows. Never a scientific number:
//        nothing here is measured, exported or saved, and no measurement reads the canvas (the measuring tools read the image's own
//        pixels). The intensity histogram the Display section draws is computed once with the canvas, off the main
//        actor, from the RAW pixels (`IntensityHistogram`; ImagoKit ImagoCore with an app default-bins extension; gated against numpy).
//        A diffraction pattern's canvas is of its display values, log or linear (`CanvasPixels.pattern`): its range and its
//        histogram are of what is drawn.
//

import ShellMetal
import Foundation
import Observation
import ImagoCore
import TEMCore

/// What the canvas uploads: the image normalised to [0, 1] over its finite range, with non-finite pixels at
/// `FloatImage.invalidDisplayValue` (drawn as the masked colour). Built off the main actor at open.
package nonisolated struct CanvasPixels: Sendable, Equatable {
    package let width: Int
    package let height: Int
    package let normalized: [Float]
    /// Changes exactly when `normalized` does (`MetalImageView.contentVersion`); the view re-uploads on it.
    package let contentVersion: Int
    /// The finite raw range `normalized` spans (0 maps to its lower bound, 1 to its upper); nil when the image
    /// holds no finite value, and every pixel is drawn masked.
    package let rawRange: ClosedRange<Float>?
    /// The histogram of the image's finite RAW pixels (`IntensityHistogram`: 96 bins over `rawRange`, widened for a
    /// constant image, no bins where numpy refuses the range); nil when none is finite.
    package let histogram: IntensityHistogram?

    package init(width: Int, height: Int, normalized: [Float], contentVersion: Int, rawRange: ClosedRange<Float>?,
                 histogram: IntensityHistogram? = nil) {
        self.width = width
        self.height = height
        self.normalized = normalized
        self.contentVersion = contentVersion
        self.rawRange = rawRange
        self.histogram = histogram
    }

    /// The canvas of raw `pixels`: normalised over their finite range, the version, the raw range and the histogram. Built off the
    /// main actor at open (`AppState.canvas(for:)`, the Patterns room's map and pattern).
    package static func make(width: Int, height: Int, pixels: [Float]) -> CanvasPixels {
        let floatImage = FloatImage(width: width, height: height, pixels: pixels)
        let normalized = floatImage.normalized()
        // `minMax` answers 0…1 for an image with no finite value; that is not a range the data holds.
        let range: ClosedRange<Float>? = pixels.contains(where: \.isFinite) ? floatImage.minMax.0...floatImage.minMax.1 : nil
        return CanvasPixels(width: width, height: height, normalized: normalized,
                            contentVersion: MetalImageView.contentVersion(of: normalized, width: width, height: height),
                            rawRange: range, histogram: IntensityHistogram.compute(pixels))
    }

    /// The canvas of a diffraction pattern: its display values, log10(1 + max(I, 0)) when `log` (a pattern spans decades), else
    /// linear, normalised (`DiffractionPattern.normalized`). The range is 0…1 and the histogram is of these values, the ones drawn,
    /// so the Display section's handles move what the eye sees. Built off the main actor (`DiffractionViewState.show`).
    package static func pattern(pixels: [Float], width: Int, height: Int, log: Bool) -> CanvasPixels {
        let normalized = TEMCore.DiffractionPattern(qy: height, qx: width, pixels: pixels).normalized(useLog: log)
        return CanvasPixels(width: width, height: height, normalized: normalized,
                            contentVersion: MetalImageView.contentVersion(of: normalized, width: width, height: height), rawRange: 0...1,
                            histogram: IntensityHistogram.compute(normalized))
    }
}

/// The contrast window the shader takes: fractions of the canvas's raw range, since the canvas is normalised over it.
package nonisolated enum DisplayWindow {
    /// `low…high` (raw values; nil is the full range) as fractions of `rawRange`, clamped to 0…1 with low < high. A
    /// window that is empty or outside the range falls back to the full range: the image is never drawn blank by a
    /// stale window. With no finite range (every pixel masked) the full range.
    package static func fractions(low: Float?, high: Float?, rawRange: ClosedRange<Float>?) -> (low: Float, high: Float) {
        guard let rawRange, rawRange.upperBound > rawRange.lowerBound else { return (0, 1) }
        let span = rawRange.upperBound - rawRange.lowerBound
        let lo = min(max(((low ?? rawRange.lowerBound) - rawRange.lowerBound) / span, 0), 1)
        let hi = min(max(((high ?? rawRange.upperBound) - rawRange.lowerBound) / span, 0), 1)
        return lo < hi ? (lo, hi) : (0, 1)
    }

    /// The `quantiles` (fractions, linear between ranks as numpy's `percentile` does) of the canvas's finite pixels, in raw values: the
    /// default window of a map that opens on its 1st to 99th percentile (control placement §11). Read from the normalised pixels on at
    /// most `sampleCap` of them, evenly strided (a display default, never a number). Nil with fewer than two finite pixels or no span.
    package static func quantileWindow(of canvas: CanvasPixels, _ quantiles: ClosedRange<Double>, sampleCap: Int = 1 << 16) -> ClosedRange<Float>? {
        guard let raw = canvas.rawRange, raw.upperBound > raw.lowerBound, !canvas.normalized.isEmpty else { return nil }
        let stride = max(1, canvas.normalized.count / max(sampleCap, 2))
        var sample: [Float] = []
        sample.reserveCapacity(canvas.normalized.count / stride + 1)
        var i = 0
        while i < canvas.normalized.count {
            let v = canvas.normalized[i]
            if v.isFinite, v >= 0, v <= 1 { sample.append(v) }
            i += stride
        }
        guard sample.count >= 2 else { return nil }
        sample.sort()
        func at(_ q: Double) -> Float {
            let position = min(max(q, 0), 1) * Double(sample.count - 1)
            let below = Int(position.rounded(.down)), above = min(below + 1, sample.count - 1)
            let t = Float(position - Double(below))
            return sample[below] + (sample[above] - sample[below]) * t
        }
        let span = raw.upperBound - raw.lowerBound
        let low = raw.lowerBound + at(quantiles.lowerBound) * span, high = raw.lowerBound + at(quantiles.upperBound) * span
        return low < high ? low...high : nil
    }
}

@Observable
package final class ImagePresentation {
    package private(set) var canvas: CanvasPixels?
    /// Gray is the TEM convention; mac4DSTEM's diffraction panes default to viridis.
    package var colormap: ColormapKind = .gray
    /// The contrast window's edges in the image's raw values; nil is the edge of the finite range (the default: every
    /// value the file holds is shown).
    package var windowLow: Float?
    package var windowHigh: Float?
    /// The display gamma, 0.2–5; 1 is linear.
    package var gamma: Double = 1
    /// Whether the pane draws its scale bar, and where Export Image's scale-bar choice starts. The calibration is never hidden. An open
    /// image's first read (`OpenItem.publish`) sets it by `startsWithScaleBar(notes:)`; after that it is the person's, kept while
    /// the file is cold.
    package var showsScaleBar = true

    /// Whether a file whose reader wrote `notes` opens with the scale bar shown: every file but a render (`TIFFImageReader.Note.render`,
    /// a TIFF of equal red, green and blue read as 8-bit grey). A render is a picture its acquisition software exported, not the
    /// counts: Velox and GMS burn their scale bar into it when the user asks for one at export, and nothing in the file says
    /// whether they did. On the renders of #110 Velox put it bottom left, where macTEM draws its own on screen and in Export Image,
    /// so the two overlapped. On a render the bar therefore starts hidden, and Show Scale Bar brings it back (docs/decisions.md,
    /// 2026-11-11). Display only: no number changes.
    package nonisolated static func startsWithScaleBar(notes: [String]) -> Bool {
        !notes.contains(TIFFImageReader.Note.render)
    }

    /// What the Display section says under Show Scale Bar on a render (`startsWithScaleBar(notes:)`): why the bar starts hidden.
    package nonisolated static let renderScaleBarNote =
        "A render: any scale bar it shows was drawn into its pixels at export, so macEM's starts hidden."

    /// The window as the shader takes it (`DisplayWindow.fractions`).
    package var displayFractions: (low: Float, high: Float) {
        DisplayWindow.fractions(low: windowLow, high: windowHigh, rawRange: canvas?.rawRange)
    }

    /// Takes `other`'s settings — colormap, window, gamma, scale bar — and none of its pixels: an item that goes cold
    /// is drawn as it was when it is read again.
    package func keepSettings(of other: ImagePresentation) {
        colormap = other.colormap
        windowLow = other.windowLow
        windowHigh = other.windowHigh
        gamma = other.gamma
        showsScaleBar = other.showsScaleBar
    }

    /// Pins the window at the range of the canvas shown (edges already set stay): the window is in raw values, so the next frame of a
    /// stack is drawn on the same scale instead of on its own range. Nothing without a finite range.
    package func holdCurrentRange() {
        guard let range = canvas?.rawRange else { return }
        if windowLow == nil { windowLow = range.lowerBound }
        if windowHigh == nil { windowHigh = range.upperBound }
    }

    /// The quantiles a picture opens on, as fractions; nil (the image rooms) opens on the full range. The SEM scan and property maps
    /// pass 0.01…0.99: a few outliers (a dark speck, a dust spot, one high KAM) otherwise drew the rest of a mean, IQ, ADP or KAM map
    /// white or black (drive 2026-11-08). Display only: no number, export or readout reads the window.
    package var defaultQuantiles: ClosedRange<Double>?
    /// The default window of the canvas shown, and whether the window on screen is still it (a person's edit keeps theirs).
    @ObservationIgnored private var defaultWindow: ClosedRange<Float>?

    /// Back to the default: the full range, or the quantile window of a picture that opens on one (the histogram's "Reset range").
    package func resetWindow() {
        windowLow = defaultWindow?.lowerBound
        windowHigh = defaultWindow?.upperBound
    }

    package init() {}

    /// Shows `canvas`. A picture with `defaultQuantiles` gets the new canvas's quantile window while its window is still the default one
    /// (a new map, a new tile); a window the person set stays.
    package func show(_ canvas: CanvasPixels) {
        let untouched = windowLow == defaultWindow?.lowerBound && windowHigh == defaultWindow?.upperBound
        self.canvas = canvas
        guard let defaultQuantiles else { return }
        defaultWindow = DisplayWindow.quantileWindow(of: canvas, defaultQuantiles)
        if untouched { resetWindow() }
    }
}
