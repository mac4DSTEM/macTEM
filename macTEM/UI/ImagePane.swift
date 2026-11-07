//
//  ImagePane.swift
//  Role: the Image room's canvas — one calibrated image, letterboxed at its pixel aspect, zoomable, with the
//        scale bar. The structure is mac4DSTEM's `DiffractionPane` (UI/ImagePanes.swift): a single-line header,
//        a `GeometryReader` letterboxing with `LayoutPolicy.fitted(in:aspect:)`, one zoom (`ZoomPan`) applied
//        twice by the same numbers — SwiftUI's `scaleEffect`/`offset` for what overlays the image, the vertex
//        shader (`MetalDisplayTransform`) for the image itself, so the Metal drawable stays pane-sized — and a
//        `PaneFooter` OUTSIDE that container so the bar keeps its size and corner at any zoom.
//
//  THE SCALE BAR (scientific): it measures along the SCREEN HORIZONTAL, so it takes the x axis's sampling —
//  correct for horizontal distances whatever y says — through `ImageScaleBar`, the pure function a test pins.
//  `ScaleBarMath.sampling` falls back to "px" when x is not calibrated (`AxisCalibration.isCalibrated`). A metre axis is
//  first brought to nm, µm or mm (`DisplaySampling`); the bar itself then reads in the unit its length suits
//  (`ScaleBarMath.ladder`: "20 nm" where "0.02 µm" would be printed) — each step converts once, and
//  `ScaleBarReadingTests` pins that the label names the length the bar draws. The image is drawn at its pixel
//  aspect; when the axes differ the Info tab says the pixels are not square.
//

import ShellControls
import ShellLayout
import ShellMetal
import ImagoCore
import SwiftUI
import TEMCore
import TEMSession

struct ImagePane: View {
    let image: CalibratedImage
    let canvas: CanvasPixels
    /// The item this pane shows: its committed zoom and pan are where `zp` starts and where a finished gesture writes
    /// back, so switching items and back restores them exactly. The pane is keyed by the item's id.
    let item: OpenItem
    @State private var zoomModel: PaneZoomModel
    private var zp: ZoomPan { zoomModel.state }
    @Environment(AppState.self) private var appState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// An angle whose first arm is drawn: the marks overlay's gesture state, held here so Escape (the room's key) can drop it.
    @State private var angleArm: AngleArm?

    init(image: CalibratedImage, canvas: CanvasPixels, item: OpenItem) {
        self.image = image
        self.canvas = canvas
        self.item = item
        var start = ZoomPan()
        start.zoom = item.viewport.zoom
        start.offset = item.viewport.offset
        let model = PaneZoomModel()
        model.state = start
        _zoomModel = State(initialValue: model)
    }

    var body: some View {
        VStack(spacing: 6) {
            header
            GeometryReader { geometry in
                if let strip = appState.cropsDatabar ? nil : item.databar {
                    // The databar shown (design §3): a strip under the picture, outside the zoom container, as wide as the
                    // picture; the picture keeps the scan's rows, so every measurement and export stays on the scan.
                    let split = DatabarLayout.split(geometry.size, width: canvas.width, height: canvas.height,
                                                    stripWidth: strip.width, stripRows: strip.height)
                    VStack(spacing: 0) {
                        content(in: split.picture)
                            .frame(width: split.picture.width, height: split.picture.height)
                        DatabarStrip(strip: strip)
                            .frame(width: split.strip.width, height: split.strip.height)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    content(in: geometry.size)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .padding(8)
        .clipped()
        // The one keyed container of the room: Delete, ⌘C, Escape and Edit > Copy / Delete (`PaneKeys.swift`).
        .modifier(ImageKeyedRoom(image: image, measurements: item.measurements, angleArm: $angleArm))
        // The COMMITTED values only (`zoom`, `offset`); the live gesture fields change on every sample and stay here.
        .onChange(of: zp.zoom) { item.viewport = ImageViewport(zoom: zp.zoom, offset: zp.offset) }
        .onChange(of: zp.offset) { item.viewport = ImageViewport(zoom: zp.zoom, offset: zp.offset) }
    }

    /// The status line's cursor readout (control placement §7): the pixel under the pointer and its raw value. No crosshair over the
    /// picture (the owner, 2026-10-23: the system pointer is enough, as in Velox, GMS and Preview).
    private func hovered(_ phase: HoverPhase, box: CGSize) {
        switch phase {
        case .active(let p):
            let geometry = MarkGeometry(transform: MetalDisplayTransform(paneSize: box, imageBox: box, zoom: zp.drawZoom, offset: zp.effectiveOffset),
                                        imageWidth: canvas.width, imageHeight: canvas.height)
            // While the Particles view shows its objects, the object under the pointer is named after the pixel.
            appState.imageRoomTools.readout = ImageReadout.text(image, at: geometry.imagePoint(atPanePoint: p),
                                                                particles: item.particles.showsObjects ? item.particles.report : nil,
                                                                scale: ParticleCompute.scale(of: image))
        case .ended:
            appState.imageRoomTools.readout = nil
        }
    }

    /// The zoom, once it is not 1× (control placement §6, mac4DSTEM's `zoomBadge`).
    @ViewBuilder
    private var zoomBadge: some View {
        if let text = ZoomPan.badgeText(zoom: zp.drawZoom), let spoken = ZoomPan.badgeSpoken(zoom: zp.drawZoom) {
            Text(text)
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(Color.accentColor)
                .fixedSize()
                .help("\(spoken). Double-click, or View \u{203A} Zoom to Fit, to see the whole image.")
                .accessibilityLabel(spoken)
                .accessibilityIdentifier("image.zoomBadge")
        }
    }

    /// ZoomPan's own reset (its double-click), animated unless Reduce Motion is on.
    private func resetZoom() {
        if reduceMotion { zoomModel.fit() } else { withAnimation(.snappy) { zoomModel.fit() } }
    }

    /// Single-line on purpose: a wrapping title changes the header's height, which moves the image below it.
    /// Two layouts, the first that fits wins (mac4DSTEM's pane headers): the title with the size, or the title
    /// alone — so the size, which differs per image, never announces a minimum width upward (the constraint-loop
    /// rule: nothing inside a split may change its own minimum).
    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                title
                Spacer(minLength: 8)
                notes
                size
            }
            HStack(spacing: 8) {
                title
                Spacer(minLength: 8)
                size
            }
            title
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: LayoutPolicy.paneHeaderHeight)
    }

    private var size: some View {
        Text(verbatim: "\(image.width) × \(image.height)")
            .help("Columns × rows, in pixels")
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .fixedSize()
    }

    /// What the reader says beyond the numbers ("frame 1 of 212", "8-bit render, not counts"), first to go when the
    /// header is narrow (the Info tab lists them too).
    @ViewBuilder
    private var notes: some View {
        if !image.notes.isEmpty {
            Text(image.notes.joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
        }
    }

    private var title: some View {
        Text(image.fileName)
            .font(.headline)
            .lineLimit(1)
            .truncationMode(.middle)
            .layoutPriority(-1)
    }

    private func content(in size: CGSize) -> some View {
        let box = LayoutPolicy.fitted(in: size, aspect: CGFloat(canvas.width) / CGFloat(canvas.height))
        let sampling = ImageScaleBar.sampling(image)
        return ZStack {
            ZStack {
                // The image itself is drawn BEHIND this layer, by the shader (the `.background` below); the marks
                // are drawn OVER it, untransformed (the `.overlay` below), so nothing here scales.
                Color.clear.frame(width: box.width, height: box.height)
            }
            .frame(width: box.width, height: box.height)
            .scaleEffect(zp.drawZoom)
            .offset(zp.effectiveOffset)
            .frame(width: box.width, height: box.height)
            .background {
                // Pane-sized and untransformed: the vertex shader applies the zoom and offset
                // (`MetalDisplayTransform`, the same map the layer above applies), so the drawable stays
                // pane-sized at any zoom — a scaled MTKView grows its drawable with the zoom (mac4DSTEM
                // `46e1237e` measured 14656² px, ~1.3 GB at 16×). Inside the clip, behind the layer.
                MetalImageView(
                    pixels: canvas.normalized,
                    width: canvas.width, height: canvas.height,
                    contentVersion: canvas.contentVersion,
                    colormap: item.presentation.colormap,
                    displayLo: item.presentation.displayFractions.low,
                    displayHi: item.presentation.displayFractions.high,
                    gamma: Float(item.presentation.gamma)
                )
                .displayTransform(MetalDisplayTransform(
                    paneSize: box, imageBox: box,
                    zoom: zp.drawZoom, offset: zp.effectiveOffset))
                .frame(width: box.width, height: box.height)
                .allowsHitTesting(false)
            }
            .overlay {
                // The Particles view's objects and mask tint, under the marks (same transform, no hit testing).
                ParticleOverlay(analysis: item.particles,
                                geometry: MarkGeometry(transform: MetalDisplayTransform(paneSize: box, imageBox: box,
                                                                                        zoom: zp.drawZoom, offset: zp.effectiveOffset),
                                                       imageWidth: canvas.width, imageHeight: canvas.height))
            }
            .overlay {
                // Pane-sized and untransformed, like the Metal view: the marks are mapped through the shader's own
                // transform (`MarkGeometry`), so they keep their stroke at any zoom and cannot slip from the image.
                ImageMarksOverlay(
                    image: image,
                    geometry: MarkGeometry(transform: MetalDisplayTransform(paneSize: box, imageBox: box,
                                                                            zoom: zp.drawZoom, offset: zp.effectiveOffset),
                                           imageWidth: canvas.width, imageHeight: canvas.height),
                    measurements: item.measurements,
                    angleArm: $angleArm,
                    tool: appState.imageRoomTools.tool,
                    label: { [x = image.x, y = image.y] in MarkFormat.value($0, x: x, y: y) })
                // With a measuring tool the overlay takes every press, so the pane's double-click reset (ZoomPan, a
                // verbatim copy) never sees one: the same reset here (the 2026-10-13 drive).
                .simultaneousGesture(TapGesture(count: 2).onEnded { resetZoom() },
                                     isEnabled: appState.imageRoomTools.tool != .pan)
            }
            .clipped()
            .contentShape(Rectangle())
            .border(Color.white.opacity(0.08))
            .zoomPan(zoomModel, box: box, onHover: { phase in hovered(phase, box: box) })
            .zoomPanWheel(zoomModel, box: box)
            .zoomCommandTarget(zoomModel, isTarget: true)

            PaneFooter {
                // Hidden, never re-measured: the toggle removes the bar only (the calibration stays in the
                // inspector). Opacity, not `if`, so the footer keeps its identity and its place.
                ScaleBar(unitsPerPoint: ImageScaleBar.unitsPerPoint(perPixel: sampling.perPixel,
                                                                    imageWidth: canvas.width,
                                                                    boxWidth: box.width, zoom: zp.drawZoom),
                         unitLabel: sampling.label)
                    .opacity(item.presentation.showsScaleBar ? 1 : 0)
                    .accessibilityHidden(!item.presentation.showsScaleBar)
            } trailing: {
                zoomBadge
            }
        }
        .frame(width: box.width, height: box.height)
        // Centred, as Preview centres a photo (mac4DSTEM measured top-pinning to leave dead space below).
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("image.view")
        .accessibilityLabel("Image")
        .accessibilityValue("\(image.width) by \(image.height) pixels")
        .accessibilityHint(ZoomPan.accessibilityHint)
        .zoomPanAccessibilityActions(zoomModel, box: box)
    }
}

/// The status line's readout over a picture: the pixel under the pointer and its raw value (the file's numbers, not the display
/// range), in the EDS maps' words ("x 96, y 412 · 9744"). nil off the pixels.
nonisolated enum ImageReadout {
    static func text(_ image: CalibratedImage, at q: ImagePoint) -> String? {
        let c = Int(q.x.rounded()), r = Int(q.y.rounded())
        guard c >= 0, c < image.width, r >= 0, r < image.height else { return nil }
        return "x \(c), y \(r) · \(Num.sig(Double(image.pixels[r * image.width + c]), 5))"
    }

    /// The pixel readout, then the found object under the pointer when there is one: "x 30, y 30 · 100 · object 2: 15.9 × 6.1 nm", its
    /// length and width (ImagoKit's moments) in the scale's unit, "(edge)" when it is cut by the image edge. `particles` nil: the pixel alone.
    static func text(_ image: CalibratedImage, at q: ImagePoint, particles: ParticleReport?, scale: ParticleScale) -> String? {
        guard let pixel = text(image, at: q) else { return nil }
        guard let report = particles, report.width == image.width, report.height == image.height else { return pixel }
        let c = Int(q.x.rounded()), r = Int(q.y.rounded())
        let label = report.labels.labels[r * report.width + c]
        guard label > 0, let object = report.objects.first(where: { $0.id == label }) else { return pixel }
        let m = object.moments
        let size = "\(ParticleFormat.number(m.lengthPx * scale.perPixel)) × \(ParticleFormat.number(m.widthPx * scale.perPixel)) \(scale.unit)"
        return pixel + " · object \(label): " + size + (object.touchesEdge ? " (edge)" : "")
    }
}

/// What the image pane's scale bar measures, pure so a test pins the pane's own numbers.
enum ImageScaleBar {
    /// The sampling along the screen horizontal: x's, or pixels when x is not calibrated. A metre axis is measured in
    /// the unit the image's width reads in (`DisplaySampling`), so the bar says "10 nm", not "1e-08 m"; `ScaleBar`
    /// then re-reads its length in the unit that suits it (nm, µm or mm), so this unit is where the bar STARTS.
    static func sampling(_ image: CalibratedImage) -> (perPixel: Double, label: String) {
        let s = ScaleBarMath.sampling(x: image.x, y: image.y, width: image.width, height: image.height, unitLabel: UnitDisplay.label)
        return (s.perPixel, s.unit)
    }

    /// Physical units per screen point: at zoom 1 the box's width spans the image's `imageWidth` pixels.
    static func unitsPerPoint(perPixel: Double, imageWidth: Int, boxWidth: CGFloat, zoom: CGFloat) -> Double {
        perPixel * Double(imageWidth) / Double(boxWidth) / Double(zoom)
    }
}

/// Where the picture and the databar strip under it sit in the pane: fitted together at their pixel aspect (the strip has the
/// picture's width in pixels), the picture above, the strip below at the same on-screen width. Pure, so a test pins it.
nonisolated enum DatabarLayout {
    static func split(_ size: CGSize, width: Int, height: Int, stripWidth: Int, stripRows: Int) -> (picture: CGSize, strip: CGSize) {
        guard width > 0, height > 0, stripWidth > 0, stripRows > 0 else {
            return (LayoutPolicy.fitted(in: size, aspect: CGFloat(max(width, 1)) / CGFloat(max(height, 1))), .zero)
        }
        // The strip's rows in the picture's pixel units (equal widths, so equal per-pixel scale on screen).
        let rows = CGFloat(stripRows) * CGFloat(width) / CGFloat(stripWidth)
        let whole = LayoutPolicy.fitted(in: size, aspect: CGFloat(width) / (CGFloat(height) + rows))
        let stripHeight = whole.height * rows / (CGFloat(height) + rows)
        return (CGSize(width: whole.width, height: whole.height - stripHeight), CGSize(width: whole.width, height: stripHeight))
    }
}

/// The vendor's databar rows as they are stored, in grey over their own range (the vendor draws them in black and white; the
/// image's colormap and display range are for the scan). Drawn by SwiftUI from a small grey `CGImage`, not through Metal: it
/// never zooms, and it is never measured on.
struct DatabarStrip: View, Equatable {
    let strip: CanvasPixels

    var body: some View {
        Group {
            if let picture = Self.picture(strip) {
                Image(decorative: picture, scale: 1).resizable().interpolation(.medium)
            } else {
                Color.black
            }
        }
        .accessibilityElement()
        .accessibilityIdentifier("image.sem.databarStrip")
        .accessibilityLabel("Databar")
        .accessibilityValue("\(strip.height) rows under the scan")
    }

    /// 8-bit grey of `normalized` (0...1; a non-finite pixel is black).
    nonisolated static func picture(_ strip: CanvasPixels) -> CGImage? {
        guard strip.width > 0, strip.height > 0, strip.normalized.count == strip.width * strip.height else { return nil }
        let bytes = strip.normalized.map { v -> UInt8 in v.isFinite ? UInt8((min(max(v, 0), 1) * 255).rounded()) : 0 }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: strip.width, height: strip.height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: strip.width,
                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
