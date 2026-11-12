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
///
/// A canvas of raw pixels (`make`) keeps the raw values themselves, shared with the image (no copy), and the view normalises
/// them on upload (`MetalImageView.PixelScale.raw`): a full-size normalised copy beside them cost 1.5 GB for a 19433 × 19320
/// SEM TIFF (macTEM#562). Draw it with `values` and `scale`; read one display value with `normalizedValue(at:)`. `normalized`
/// builds the whole normalised array, a full-size copy for a raw canvas: only for a one-off (an export), never in a view's body.
package nonisolated struct CanvasPixels: Sendable, Equatable {
    package let width: Int
    package let height: Int
    /// The pixels the view draws, as `scale` says: display values in [0, 1] (masked < 0), or the raw values over `rawRange`.
    package let values: [Float]
    package let scale: MetalImageView.PixelScale
    /// Changes exactly when the drawn pixels do (`MetalImageView.contentVersion`); the view re-uploads on it.
    package let contentVersion: Int
    /// The finite raw range the display values span (0 maps to its lower bound, 1 to its upper); nil when the image
    /// holds no finite value, and every pixel is drawn masked.
    package let rawRange: ClosedRange<Float>?
    /// The histogram of the image's finite RAW pixels (`IntensityHistogram`: 96 bins over `rawRange`, widened for a
    /// constant image, no bins where numpy refuses the range); nil when none is finite.
    package let histogram: IntensityHistogram?

    /// A canvas of display values already normalised.
    package init(width: Int, height: Int, normalized: [Float], contentVersion: Int, rawRange: ClosedRange<Float>?,
                 histogram: IntensityHistogram? = nil) {
        self.init(width: width, height: height, values: normalized, scale: .normalized, contentVersion: contentVersion,
                  rawRange: rawRange, histogram: histogram)
    }

    private init(width: Int, height: Int, values: [Float], scale: MetalImageView.PixelScale, contentVersion: Int,
                 rawRange: ClosedRange<Float>?, histogram: IntensityHistogram?) {
        self.width = width
        self.height = height
        self.values = values
        self.scale = scale
        self.contentVersion = contentVersion
        self.rawRange = rawRange
        self.histogram = histogram
    }

    /// The canvas of raw `pixels`: the pixels themselves (shared, not copied), their finite range, the version and the
    /// histogram. Built off the main actor at open (`AppState.canvas(for:)`, the Patterns room's map and pattern).
    package static func make(width: Int, height: Int, pixels: [Float]) -> CanvasPixels {
        // `minMax` answers 0…1 for an image with no finite value; that is not a range the data holds.
        let minMax = FloatImage(width: width, height: height, pixels: pixels).minMax
        let range: ClosedRange<Float>? = pixels.contains(where: \.isFinite) ? minMax.0...minMax.1 : nil
        // The range is a function of the pixels, so the raw pixels' hash versions what is drawn.
        return CanvasPixels(width: width, height: height, values: pixels, scale: .raw(range: range),
                            contentVersion: MetalImageView.contentVersion(of: pixels, width: width, height: height),
                            rawRange: range, histogram: IntensityHistogram.compute(pixels))
    }

    /// The display value of pixel `index` (row-major): what the view draws there, [0, 1] or the masked sentinel. Value for
    /// value `DisplayNormalization.normalized` for a raw canvas.
    package func normalizedValue(at index: Int) -> Float {
        let v = values[index]
        guard case .raw(let range) = scale else { return v }
        guard let range, v.isFinite else { return FloatImage.invalidDisplayValue }
        let span = range.upperBound - range.lowerBound
        return span > 0 ? (v - range.lowerBound) / span : 0
    }

    /// Every display value, row-major. A raw canvas builds them, a full-size copy: for a one-off only (an export).
    package var normalized: [Float] {
        guard case .raw = scale else { return values }
        return (0..<values.count).map(normalizedValue(at:))
    }

    /// The sidebar thumbnail: `Thumbnail.make` of the display values, without the full-size copy for a raw canvas (each
    /// box sums the same display values in the same order, so it is the same thumbnail, value for value).
    package func thumbnail(maxSide: Int = Thumbnail.defaultMaxSide) -> Thumbnail? {
        guard case .raw = scale else { return Thumbnail.make(normalized: values, width: width, height: height, maxSide: maxSide) }
        guard width >= 1, height >= 1, maxSide >= 1, values.count == width * height else { return nil }
        let long = max(width, height)
        if long <= maxSide { return Thumbnail(width: width, height: height, normalized: normalized) }
        func scaled(_ side: Int) -> Int {
            side == long ? maxSide : max(1, Int((Double(side) * Double(maxSide) / Double(long)).rounded()))
        }
        let w = scaled(width), h = scaled(height)
        let invalid = DisplayNormalization.invalidValue
        var colBox = [Int](repeating: 0, count: width)
        var i = 0
        for x in 0..<width {
            while (i + 1) * width / w <= x { i += 1 }
            colBox[x] = i
        }
        var rowBox = [Int](repeating: 0, count: height)
        var j = 0
        for y in 0..<height {
            while (j + 1) * height / h <= y { j += 1 }
            rowBox[y] = j
        }
        var sums = [Double](repeating: 0, count: w * h)
        var counts = [Int32](repeating: 0, count: w * h)
        for y in 0..<height {
            let rowBase = rowBox[y] * w, srcBase = y * width
            for x in 0..<width {
                let v = normalizedValue(at: srcBase + x)
                if v.isFinite && v != invalid {
                    let k = rowBase + colBox[x]
                    sums[k] += Double(v)
                    counts[k] += 1
                }
            }
        }
        var out = [Float](repeating: invalid, count: w * h)
        for k in 0..<(w * h) where counts[k] > 0 { out[k] = Float(sums[k] / Double(counts[k])) }
        return Thumbnail(width: w, height: h, normalized: out)
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
        let count = canvas.values.count
        guard let raw = canvas.rawRange, raw.upperBound > raw.lowerBound, count > 0 else { return nil }
        let stride = max(1, count / max(sampleCap, 2))
        var sample: [Float] = []
        sample.reserveCapacity(count / stride + 1)
        var i = 0
        while i < count {
            let v = canvas.normalizedValue(at: i)
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

    /// Lets go of the canvas; the settings stay. The object may outlive its file (a SwiftUI binding held by a control, as the gamma
    /// slider's, can keep it: measured on the closed 375 MB SEM TIFF, #562), so the pixels must not live as long as it does.
    package func releaseCanvas() {
        canvas = nil
    }

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
