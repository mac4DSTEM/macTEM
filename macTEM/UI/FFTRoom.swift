//
//  FFTRoom.swift
//  Role: the FFT room: the image
//        beside its transform, mounted by `WorkspaceView`'s room switch; its inspector content mounted by
//        `WorkspaceInspector`'s Settings and Info switches.
//
//  THE ROOM is two panes of equal width, each at least `LayoutPolicy.imagePaneMinimum` (the window budgets
//  `scienceMinimum` for "the image beside its transform"): the source pane (FFTSourceImagePane.swift: the file with the
//  region, or a product of the transformed pixels) and the transform pane (FFTSpectrumImagePane.swift: the spectrum, its
//  spots and the mask). Both are built as `ImagePane` is. The room appearing asks the owner for the spectrum
//  (`.task(id: contentVersion)` asks again when the file is read again; skill, views.md ".task(id:) for Reactive Async
//  Work"); leaving the room releases the products (`onDisappear`), so the selected file's megabytes go with the room.
//  `WorkspaceView` keys the room by the item's id, so a file switch is a new room. The room's accessibility identifier is
//  `fft.room`; `fft.view` is the View menu's (the design note's list), `fft.sourcePane` and `fft.spectrumPane` the panes'.
//
//  The inspector's two sections are lane C2's (FFTRoomInspector.swift); the two forwarders below are the mount points
//  the shell's switches call.
//

import ShellLayout
import ShellMetal
import SwiftUI
import TEMCore
import TEMSession

/// The room's canvas: the source pane beside the transform pane.
struct FFTRoom: View {
    let image: CalibratedImage
    let canvas: CanvasPixels
    let item: OpenItem
    /// The pane the keys are for: the one pressed last, nil until one is (`PaneKeys.swift`). Owned here, written by the panes on a press.
    @State private var keyPane: FFTKeyPane?

    var body: some View {
        HStack(spacing: 0) {
            FFTSourceImagePane(image: image, canvas: canvas, item: item, keyPane: $keyPane)
                .frame(minWidth: LayoutPolicy.imagePaneMinimum, maxWidth: .infinity)
            Divider()
            FFTSpectrumImagePane(analysis: item.fft, keyPane: $keyPane)
                .frame(minWidth: LayoutPolicy.imagePaneMinimum, maxWidth: .infinity)
        }
        // The one keyed container of the room: arrows, ⌫, ⌘C and Edit > Copy / Delete (`PaneKeys.swift`).
        .modifier(FFTKeyedRoom(analysis: item.fft, imageWidth: image.width, imageHeight: image.height, active: $keyPane))
        .task(id: canvas.contentVersion) { item.fft.show(image, contentVersion: canvas.contentVersion) }
        .onDisappear { item.fft.release() }
        .accessibilityIdentifier("fft.room")
    }
}

/// The room's Settings tab content.
struct FFTRoomSettings: View {
    let image: CalibratedImage
    let item: OpenItem

    var body: some View {
        FFTRoomInspectorSettings(image: image, analysis: item.fft)
    }
}

/// The room's section of the Info tab, above the Image section: what is transformed.
struct FFTRoomInfoSection: View {
    let image: CalibratedImage
    let item: OpenItem

    var body: some View {
        FFTRoomInspectorInfo(image: image, analysis: item.fft)
    }
}

/// How both panes map image coordinates (a pixel's centre at integers) to their own points: the shader's transform with
/// a pane-sized, untransformed drawable (`MetalDisplayTransform(paneSize: box, imageBox: box, …)`), the same map the
/// marks use, so an overlay cannot slip from the picture at any zoom or pan.
nonisolated enum FFTPaneGeometry {
    static func make(box: CGSize, width: Int, height: Int, zoom: CGFloat, offset: CGSize) -> MarkGeometry {
        MarkGeometry(transform: MetalDisplayTransform(paneSize: box, imageBox: box, zoom: zoom, offset: offset),
                     imageWidth: width, imageHeight: height)
    }
}

/// A pane as one accessibility container: a label, a value, an identifier (skill, accessibility.md "Accessibility
/// Grouping"). The canvases inside are hidden or drawn by the shader; every number is in the inspector.
struct FFTPaneAccessibility: ViewModifier {
    let label: String
    let value: String
    let identifier: String

    func body(content: Content) -> some View {
        content
            .accessibilityElement(children: .contain)
            .accessibilityLabel(label)
            .accessibilityValue(value)
            .accessibilityIdentifier(identifier)
    }
}

extension View {
    func fftPaneAccessibility(label: String, value: String, identifier: String) -> some View {
        modifier(FFTPaneAccessibility(label: label, value: value, identifier: identifier))
    }
}

extension MarkGeometry {
    /// Screen points per image pixel along y. `pointsPerPixel` is x's; the two differ on the transform's box, which is
    /// drawn at its physical aspect (a ring is a circle), and on any image whose box is not its pixel aspect.
    nonisolated var pointsPerPixelY: CGFloat { transform.imageBox.height / CGFloat(imageHeight) * transform.zoom }
}
