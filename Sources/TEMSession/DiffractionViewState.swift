//
//  DiffractionViewState.swift
//  Role: what the Diffraction room's views hold and the results owner must not: the tool, the log toggle, the annulus being set, the
//        selected row, the zoom, and the pattern's display (colormap, window, gamma: the Display section, control placement §5). One per open file (`OpenItem.diffractionView`), beside `DiffractionAnalysis`; a change here never
//        invalidates a reader of the results (the readout, the Results room, the exports), as the EDX room keeps `EDXRoomState`
//        apart from `EDXSession`. Display only: no number a scientist reads. Showing a pattern is asked of this owner (`show`: the
//        bind, the pattern's extent and its canvas), as the FFT room asks its own; the view's task makes the one call.
//

import Foundation
import Observation
import ShellMetal
import TEMCore
import ShellEDXModel

@Observable
package final class DiffractionViewState {
    package enum Tool: String, CaseIterable, Sendable { case ring, spot }

    package var tool: Tool = .ring
    package var useLog = true
    package private(set) var annulusInner = 28.0
    package private(set) var annulusOuter = 40.0
    /// The ring or spot the readout highlights (and the ⌫ key removes).
    package var selection: UUID?
    /// The view's half-side in pixels about the centre: the user's zoom, else the pattern's own extent (`DiffractionCompute.contentRadius`),
    /// else the whole image.
    package var zoomHalfSide: Double?
    package private(set) var autoHalfSide: Double?
    /// The pattern as drawn: its canvas (the display values, log or linear) and the Display section's colormap, window and gamma.
    /// Its own, not the Image room's: a pattern reads in viridis where the same file's image reads in gray.
    package let presentation: ImagePresentation = {
        let p = ImagePresentation()
        p.colormap = .viridis
        return p
    }()

    package init() {}

    /// The annulus, ordered and at least 1 px from the centre; a non-finite number is refused.
    package func setAnnulus(inner: Double, outer: Double) {
        guard inner.isFinite, outer.isFinite else { return }
        annulusInner = max(min(inner, outer), 1)
        annulusOuter = max(inner, outer)
    }

    package func setAutoExtent(_ radius: Double?) { if autoHalfSide != radius { autoHalfSide = radius } }

    /// The half-side the pane shows now, never more than the image's own half-side nor less than 8 px.
    package func viewHalfSide(for image: CalibratedImage) -> Double {
        let whole = Double(min(image.width, image.height)) / 2
        return min(max(zoomHalfSide ?? autoHalfSide ?? whole, 8), whole)
    }

    package func zoom(by factor: Double, image: CalibratedImage) {
        guard factor.isFinite, factor > 0 else { return }
        zoomHalfSide = viewHalfSide(for: image) / factor
    }

    /// The half-side a fit shows: the pattern's own extent, else the whole image (the zoom badge's 1×).
    package func fitHalfSide(for image: CalibratedImage) -> Double {
        let whole = Double(min(image.width, image.height)) / 2
        return min(max(autoHalfSide ?? whole, 8), whole)
    }

    package func fitView() { zoomHalfSide = nil }

    // MARK: Showing the pattern

    /// The room shows this pattern: it appeared, another file took the pane, or Log was switched. Binds the results owner to the
    /// image, finds how far the pattern has signal (the view opens on that) and builds the canvas of the display values, both off
    /// the main actor. A pass cancelled while it computes (a quick Log toggle, another file) writes nothing more, so the newer
    /// pass's extent and canvas are the ones left on screen.
    package func show(image: CalibratedImage, analysis: DiffractionAnalysis) async {
        analysis.bind(image)
        let centre = analysis.centre ?? .imageCentre(width: image.width, height: image.height)
        let radius = await Self.extent(pixels: image.pixels, width: image.width, height: image.height, centre: centre)
        guard !Task.isCancelled else { return }
        setAutoExtent(radius)
        let canvas = await Self.canvas(pixels: image.pixels, width: image.width, height: image.height, log: useLog)
        guard !Task.isCancelled else { return }
        // A window in log values means nothing in linear ones: the range starts whole again.
        if presentation.canvas.map({ $0.contentVersion != canvas.contentVersion }) ?? false { presentation.resetWindow() }
        presentation.show(canvas)
    }

    @concurrent
    nonisolated private static func extent(pixels: [Float], width: Int, height: Int, centre: DiffractionCentre) async -> Double? {
        DiffractionCompute.contentRadius(pixels: pixels, width: width, height: height, centre: centre)
    }

    @concurrent
    nonisolated private static func canvas(pixels: [Float], width: Int, height: Int, log: Bool) async -> CanvasPixels {
        CanvasPixels.pattern(pixels: pixels, width: width, height: height, log: log)
    }
}
