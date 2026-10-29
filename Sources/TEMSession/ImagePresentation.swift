//
//  ImagePresentation.swift
//  Role: the one owner of how one open file is drawn — the display-normalised pixels the canvas uploads, the
//        colormap, the contrast window, the gamma and whether the scale bar shows (V1-4). Never a scientific number:
//        nothing here is measured, exported or saved, and no measurement reads the canvas (V1-5 reads the image's own
//        pixels). The intensity histogram the Display section draws is computed once with the canvas, off the main
//        actor, from the RAW pixels (`IntensityHistogram`, ImagoKit ImagoCore with an app default-bins extension; archive: roadmap-registrations-2026-10-15.md V1-4, gated against numpy).
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
    /// Whether the pane draws its scale bar (ADR 017: the toggle joins V1-4). The calibration is never hidden.
    package var showsScaleBar = true

    /// The window as the shader takes it (`DisplayWindow.fractions`).
    package var displayFractions: (low: Float, high: Float) {
        DisplayWindow.fractions(low: windowLow, high: windowHigh, rawRange: canvas?.rawRange)
    }

    /// Takes `other`'s settings — colormap, window, gamma, scale bar — and none of its pixels: an item that goes cold
    /// is drawn as it was when it is read again (V1-13).
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

    /// Back to the full range (the histogram's "Reset range").
    package func resetWindow() {
        windowLow = nil
        windowHigh = nil
    }

    package init() {}

    package func show(_ canvas: CanvasPixels) {
        self.canvas = canvas
    }
}
