//
//  FFTSourceImagePane.swift
//  Role: the FFT room's left pane: the file as the Image room draws it with the region transformed
//        outlined on it, or the transformed pixels alone, or a product of them (the masked inverse, ABSF, Wiener) —
//        one picture at a time, chosen by the header's View menu. The structure is `ImagePane`'s: a single-line header,
//        a `GeometryReader` letterboxing with `LayoutPolicy.fitted`, one zoom (`ZoomPan`) applied by the shader
//        (`MetalDisplayTransform`, a pane-sized untransformed drawable) and, to the overlays, through `MarkGeometry`, and
//        a `PaneFooter` OUTSIDE the zoomed container so the bar keeps its size and corner at any zoom.
//
//  WHICH PIXELS (`FFTSourceLayer`, pure, pinned by FFTRoomPaneTests): Original is the file's canvas with ITS colormap,
//  window and gamma. Every other view is its own pixels LINEAR over their own finite range (gamma 1) in the file's
//  colormap — the one mapping all four share, so flipping between the region and a product is a blink comparison of like
//  with like. A product carries a plate over its top (`.thinMaterial`, never a colour wash) naming it and its inputs and a
//  2-pt border (accent for the inverse, orange for the filters; the plate's words carry the difference, never the colour
//  alone); the filters' plate begins "Unvalidated · not compared with Digital Micrograph", every time.
//
//  THE REGION'S GESTURES (Original only; `FFTRegionGeometry` is the pure part): with no region the overlay takes every
//  press and a drag draws a square from the press (a drag that has not yet left 2 pt of the press makes nothing; once it
//  has drawn, every sample draws); with one, the overlay's hit shape is
//  the square plus four corner discs, so a press inside moves it, a press on a corner resizes it about the opposite
//  corner, and every other press reaches `ZoomPan` (pan, pinch). The region is written to its owner on every sample
//  (`committed: false`: that is what drives the live transform) and committed once on release; a drag the system cancels
//  commits what it had drawn. The press's grab and the crop at the drag's start are this overlay's `@State`, set on the
//  first sample and cleared on the last; the `@GestureState` flag clears it when the system cancels the gesture instead
//  (skill, performance.md "@State for Animated and Gestured Values": nothing of a drag goes through `@Observable` but the
//  region itself). Arrows nudge the region one pixel (⇧ ten) and Delete clears it while this pane was pressed last — the
//  keys are the room's, one keyed container (App/PaneKeys.swift), not this overlay's.
//
//  SKILL NOTES (swiftui-macos): observation.md "Observation Scope Narrowing" — the View menu and its availability read
//  their own slice in `FFTSourceViewControl`, and a product is read only while its view is shown, so the pane is not
//  re-evaluated by a spectrum landing while the file is shown; performance.md "@State for Animated and Gestured Values" —
//  the drag's grab and start crop are `@State`, written twice per drag, and the region itself (what drives the live
//  transform) is the only per-sample write to the owner; accessibility.md — the pane is one container with a label and a
//  value, the canvases are hidden, and every control the pointer reaches has a keyboard or inspector twin (Region
//  section: Left, Top, Size, Clear Region, Use Centred Square; the arrows and Delete here), with the context menu
//  repeating them (platform.md "Interaction Patterns": right-click menus, focus).
//

import ShellControls
import ShellLayout
import ShellMetal
import SwiftUI
#if canImport(TEMCore)
import TEMCore
import TEMSession
import ImagoFFT
import ImagoCore
#endif

// MARK: - The region in pane points (pure)

nonisolated enum FFTRegionGeometry {
    /// A drag shorter than this, in points, draws no region and moves or resizes nothing (a click is not a gesture).
    static let minimumDrag: CGFloat = 2
    /// The corner discs take a press this close to a corner (and are drawn 8 pt across).
    static let maximumHandleRadius: CGFloat = 8

    /// What a press took.
    enum Grab: Equatable {
        case draw
        case move
        case resize(FFTRegion.Corner)
    }

    /// Where `corner` of `crop` is drawn: the pixel EDGE (`FFTRegion.point(of:in:)`), so the outline is exactly the
    /// pixels transformed.
    static func corner(_ corner: FFTRegion.Corner, of crop: PixelCrop, in geometry: MarkGeometry) -> CGPoint {
        geometry.panePoint(of: ImagePoint(FFTRegion.point(of: corner, in: crop)))
    }

    /// The outline, top-left to bottom-right.
    static func rect(of crop: PixelCrop, in geometry: MarkGeometry) -> CGRect {
        let a = corner(.topLeft, of: crop, in: geometry), b = corner(.bottomRight, of: crop, in: geometry)
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }

    /// The discs' radius for a region `side` points across: 8, but never more than a third of the side, so the middle of
    /// a small region (32 px on a 3000-px image is 6 pt) still moves it.
    static func handleRadius(forSide side: CGFloat) -> CGFloat {
        max(0, min(maximumHandleRadius, side / 3))
    }

    /// What a press at `press` takes: with no region, a draw; with one, the nearest corner within the discs' radius (even
    /// outside the square), else a move inside the square, else nothing — the press is the pane's (nil).
    static func grab(at press: CGPoint, region: PixelCrop?, in geometry: MarkGeometry) -> Grab? {
        guard let region else { return .draw }
        let square = rect(of: region, in: geometry)
        let radius = handleRadius(forSide: min(square.width, square.height))
        var best: (corner: FFTRegion.Corner, distance: CGFloat)?
        for c in FFTRegion.Corner.allCases {
            let p = corner(c, of: region, in: geometry)
            let d = hypot(p.x - press.x, p.y - press.y)
            if d <= radius, d < (best?.distance ?? .infinity) { best = (c, d) }
        }
        if let best { return .resize(best.corner) }
        return square.contains(press) ? .move : nil
    }

    /// The overlay's hit area: the whole pane with no region, else the square and its four discs — exactly where `grab`
    /// acts, so no part of the pane is a dead zone.
    static func hitShape(region: PixelCrop?, in geometry: MarkGeometry) -> FFTRegionHitShape {
        guard let region else { return FFTRegionHitShape(rect: nil, corners: [], radius: 0) }
        let square = rect(of: region, in: geometry)
        return FFTRegionHitShape(rect: square, corners: FFTRegion.Corner.allCases.map { corner($0, of: region, in: geometry) },
                                 radius: handleRadius(forSide: min(square.width, square.height)))
    }

    /// A pane translation in image pixels: each axis by its own points per pixel at the current zoom.
    static func pixels(ofPaneTranslation t: CGSize, in geometry: MarkGeometry) -> (dx: Double, dy: Double) {
        (Double(t.width / geometry.pointsPerPixel), Double(t.height / geometry.pointsPerPixelY))
    }

    /// The region a drag proposes. `start` is the crop at the PRESS (never the live one: a move is the drag from where it
    /// was, not a sum of samples). A draw is nil until the pointer is 2 pt from the press — a click is not a gesture — and
    /// only until the drag has proposed once (`hasProposed`): after that every sample proposes, a pointer back near the press
    /// giving R1's 32-px square; a move or resize under the threshold proposes `start` itself. R1 takes the press and the
    /// pointer in image coordinates as they are, off the image too (`FFTRegion.drawn` holds the corner to the image and
    /// shifts the square in), so a drag that leaves the image, or a press in the zoomed-out letterbox, is not held to its
    /// edge first. A resize moves the corner by the DRAG (the Image room's rule for a grabbed end), not to the pointer — the
    /// grab is up to a disc's radius off the corner — about the opposite corner.
    static func proposed(_ grab: Grab, from start: PixelCrop?, press: CGPoint, location: CGPoint, hasProposed: Bool = false,
                         in geometry: MarkGeometry) -> PixelCrop? {
        let width = geometry.imageWidth, height = geometry.imageHeight
        let travelled = hypot(location.x - press.x, location.y - press.y)
        let drag = CGSize(width: location.x - press.x, height: location.y - press.y)
        switch grab {
        case .draw:
            guard hasProposed || travelled >= minimumDrag else { return nil }
            return FFTRegion.drawn(from: geometry.imagePoint(atPanePoint: press).pixelPoint, to: geometry.imagePoint(atPanePoint: location).pixelPoint,
                                   width: width, height: height)
        case .move:
            guard let start else { return nil }
            guard travelled >= minimumDrag else { return start }
            let d = pixels(ofPaneTranslation: drag, in: geometry)
            return FFTRegion.moved(start, dx: d.dx, dy: d.dy, width: width, height: height)
        case .resize(let corner):
            guard let start else { return nil }
            guard travelled >= minimumDrag else { return start }
            let d = pixels(ofPaneTranslation: drag, in: geometry)
            let at = FFTRegion.point(of: corner, in: start)
            return FFTRegion.resized(start, corner: corner, to: PixelPoint(x: at.x + d.dx, y: at.y + d.dy),
                                     width: width, height: height)
        }
    }

    /// An arrow key: the crop moved `step` pixels toward the arrow, held inside the image.
    static func nudged(_ crop: PixelCrop, _ direction: MoveCommandDirection, step: Int, width: Int, height: Int) -> PixelCrop {
        let s = Double(step)
        switch direction {
        case .left: return FFTRegion.moved(crop, dx: -s, dy: 0, width: width, height: height)
        case .right: return FFTRegion.moved(crop, dx: s, dy: 0, width: width, height: height)
        case .up: return FFTRegion.moved(crop, dx: 0, dy: -s, width: width, height: height)
        case .down: return FFTRegion.moved(crop, dx: 0, dy: s, width: width, height: height)
        @unknown default: return crop
        }
    }
}

/// A region drag in progress: what its press grabbed, the crop at that press and whether it has changed the region yet. Pure
/// (the overlay holds one in `@State`), so a test drives a whole drag sample by sample.
nonisolated struct FFTRegionDrag {
    let grab: FFTRegionGeometry.Grab
    let start: PixelCrop?
    /// True once a sample has proposed a crop other than `start`: from then on the drag is a region change to commit, and a
    /// draw proposes on every sample (`FFTRegionGeometry.proposed`'s `hasProposed`).
    private(set) var wrote = false

    init(grab: FFTRegionGeometry.Grab, start: PixelCrop?) {
        self.grab = grab
        self.start = start
    }

    /// The crop this sample proposes, or nil for none (a draw not yet past the threshold, or a move or resize with no crop).
    mutating func propose(press: CGPoint, location: CGPoint, in geometry: MarkGeometry) -> PixelCrop? {
        guard let crop = FFTRegionGeometry.proposed(grab, from: start, press: press, location: location, hasProposed: wrote,
                                                    in: geometry) else { return nil }
        // Only a drag that changed the crop is committed: a click on the region proposes the crop it already is.
        if !wrote, crop != start { wrote = true }
        return crop
    }
}

/// Where the region overlay takes a press: the whole pane, or (with a region) only the square and its corner discs.
nonisolated struct FFTRegionHitShape: Shape {
    /// nil: the whole rectangle.
    let rect: CGRect?
    let corners: [CGPoint]
    let radius: CGFloat

    func path(in bounds: CGRect) -> Path {
        guard let rect else { return Path(bounds) }
        var path = Path(rect)
        for c in corners { path.addEllipse(in: CGRect(x: c.x - radius, y: c.y - radius, width: 2 * radius, height: 2 * radius)) }
        return path
    }
}

// MARK: - Which pixels, and how (pure)

/// What the source pane draws for one View: the pixels, the colormap, window and gamma the shader takes, the plate and
/// border of a product, and whether the region's outline is drawn on it.
nonisolated struct FFTSourceLayer {
    enum Border: Equatable {
        case plain
        /// The masked inverse's.
        case accent
        /// The unvalidated filters'.
        case orange
    }

    let canvas: CanvasPixels
    let colormap: ColormapKind
    let window: (low: Float, high: Float)
    let gamma: Float
    let plate: String?
    let border: Border
    let drawsRegion: Bool

    /// The layer for `view`; nil when its product does not exist yet. `original`, `colormap`, `window` and `gamma` are the
    /// file's own presentation, used by Original alone; the products are drawn linear over their own range at gamma 1.
    @MainActor
    static func make(_ view: FFTAnalysis.SourceView, original: CanvasPixels, colormap: ColormapKind,
                     window: (low: Float, high: Float), gamma: Float, spectrum: FFTSpectrumProduct?,
                     inverse: FFTMaskedInverseProduct?, filtered: FFTFilterProduct?) -> FFTSourceLayer? {
        func product(_ canvas: CanvasPixels, border: Border, plate: String) -> FFTSourceLayer {
            FFTSourceLayer(canvas: canvas, colormap: colormap, window: (0, 1), gamma: 1, plate: plate, border: border,
                           drawsRegion: false)
        }
        switch view {
        case .original:
            return FFTSourceLayer(canvas: original, colormap: colormap, window: window, gamma: gamma, plate: nil,
                                  border: .plain, drawsRegion: true)
        case .region:
            guard let spectrum else { return nil }
            return product(spectrum.region, border: .plain,
                           plate: FFTPaneFormat.regionPlate(crop: spectrum.key.crop, width: spectrum.region.width,
                                                            height: spectrum.region.height))
        case .maskedInverse:
            guard let inverse else { return nil }
            let first = inverse.key.spots.first
            return product(inverse.canvas, border: .accent,
                           plate: FFTPaneFormat.maskedInversePlate(spots: inverse.key.spots.count, radius: first?.radius ?? 0,
                                                                   edge: first?.edge ?? 0, width: inverse.canvas.width,
                                                                   height: inverse.canvas.height))
        case .absf:
            guard let filtered else { return nil }
            return product(filtered.absf, border: .orange, plate: FFTPaneFormat.filterPlate("ABSF", size: filtered.n))
        case .wiener:
            guard let filtered else { return nil }
            return product(filtered.wiener, border: .orange, plate: FFTPaneFormat.filterPlate("Wiener", size: filtered.n))
        }
    }
}

// MARK: - The View menu

/// The header's borderless menu and its filtering indicator. Reads its own slice of the owner (the views' availability
/// and whether a filter runs), so the pane around it is not re-evaluated by them.
struct FFTSourceViewControl: View {
    let analysis: FFTAnalysis

    /// The menu's items for the owner as it stands, its state read once for all of them.
    static func entries(for analysis: FFTAnalysis) -> [FFTPaneFormat.MenuEntry] {
        FFTPaneFormat.menuEntries(selected: analysis.sourceView, hasSpectrum: analysis.spectrum != nil,
                                  hasMeasuredSpot: analysis.hasMeasuredSpot, hasMaskSpot: analysis.hasMaskSpot,
                                  hasFilterResult: analysis.filtered != nil)
    }

    var body: some View {
        HStack(spacing: 4) {
            if analysis.isFiltering {
                ProgressView().controlSize(.small).help("Filtering…")
            }
            Picker("View", selection: Binding(get: { analysis.sourceView }, set: { analysis.setSourceView($0) })) {
                ForEach(Self.entries(for: analysis), id: \.view) { entry in
                    Text(entry.title).tag(entry.view).disabled(!entry.isEnabled)
                }
            }
            .pickerStyle(.menu)
            .buttonStyle(.borderless)
            .labelsHidden()
            .fixedSize()
            .accessibilityLabel("View")
            .accessibilityIdentifier("fft.view")
        }
    }
}

// MARK: - The region's outline and gestures

/// Draws the region transformed (the pixel edges, four corner discs) over the file and takes the gestures that make, move
/// and resize it. The region is the owner's; this view maps and writes.
struct FFTRegionOverlay: View {
    let analysis: FFTAnalysis
    let geometry: MarkGeometry

    /// True while the gesture lives and false the moment it ends or is cancelled: the cancel hook for `drag`.
    @GestureState private var isDragging = false
    @State private var drag: FFTRegionDrag?

    var body: some View {
        // Read here, not only inside the Canvas closure, so the overlay is told when the region changes.
        let region = analysis.region
        ZStack {
            Canvas { context, _ in draw(region, in: &context) }
                .allowsHitTesting(false)
            Color.clear
                .contentShape(FFTRegionGeometry.hitShape(region: region, in: geometry))
                .gesture(regionDrag)
                .pointerStyle(region == nil ? .rectSelection : .grabIdle)
        }
        .onChange(of: isDragging) { _, now in if !now { finishDrag() } }
        .accessibilityHidden(true)   // the Region section lists Left, Top and Size, and clears and centres the region
    }

    // MARK: Gestures

    private var regionDrag: some Gesture {
        DragGesture(minimumDistance: 0)
            .updating($isDragging) { _, flag, _ in flag = true }
            .onChanged { value in
                if drag == nil {
                    guard let grab = FFTRegionGeometry.grab(at: value.startLocation, region: analysis.region, in: geometry) else { return }
                    drag = FFTRegionDrag(grab: grab, start: analysis.region)
                }
                propose(value)
            }
            .onEnded { value in
                propose(value)
                finishDrag()
            }
    }

    /// The sample's region, written to the owner uncommitted; nothing when the drag has not left its threshold.
    private func propose(_ value: DragGesture.Value) {
        guard var current = drag else { return }
        let wrote = current.wrote
        guard let crop = current.propose(press: value.startLocation, location: value.location, in: geometry) else { return }
        if crop != analysis.region { analysis.setRegion(crop, committed: false) }
        if current.wrote != wrote { drag = current }       // written once per drag, not per sample
    }

    /// The drag ended (or was cancelled): what it proposed is committed once.
    private func finishDrag() {
        guard let finished = drag else { return }
        drag = nil
        if finished.wrote { analysis.setRegion(analysis.region, committed: true) }
    }

    // MARK: Drawing

    private func draw(_ region: PixelCrop?, in context: inout GraphicsContext) {
        guard let region else { return }
        let outline = Path(FFTRegionGeometry.rect(of: region, in: geometry))
        // A dark halo under the accent line, so it reads on any pixels.
        context.stroke(outline, with: .color(.black.opacity(0.6)), lineWidth: 4)
        context.stroke(outline, with: .color(.accentColor), lineWidth: 2)
        for corner in FFTRegion.Corner.allCases {
            let p = FFTRegionGeometry.corner(corner, of: region, in: geometry)
            let disc = Path(ellipseIn: CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8))
            context.fill(disc, with: .color(.white))
            context.stroke(disc, with: .color(.black.opacity(0.6)), lineWidth: 1.5)
        }
    }
}

// MARK: - The pane

struct FFTSourceImagePane: View {
    let image: CalibratedImage
    let canvas: CanvasPixels
    let item: OpenItem
    /// The room's keys are for the pane pressed last; any press in this pane says it is this one (`FFTPanePress`).
    @Binding var keyPane: FFTKeyPane?
    @State private var zoomModel = PaneZoomModel()
    private var zp: ZoomPan { zoomModel.state }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var analysis: FFTAnalysis { item.fft }

    var body: some View {
        let view = analysis.sourceView
        // A product is read only while its view is shown: a spectrum landing does not re-evaluate this pane over the file.
        let layer = FFTSourceLayer.make(view, original: canvas, colormap: item.presentation.colormap,
                                        window: item.presentation.displayFractions, gamma: Float(item.presentation.gamma),
                                        spectrum: view == .region ? analysis.spectrum : nil,
                                        inverse: view == .maskedInverse ? analysis.maskedInverse : nil,
                                        filtered: view == .absf || view == .wiener ? analysis.filtered : nil)
        VStack(spacing: 6) {
            header(layer)
            GeometryReader { geometry in
                Group {
                    if let layer {
                        content(layer, view: view, in: geometry.size)
                    } else {
                        missing(view)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(8)
        .clipped()
        .modifier(FFTPanePress(pane: .source, keyPane: $keyPane))
        // Region, masked inverse, ABSF and Wiener are one size: their zoom survives the flip (the blink comparison); to or
        // from the file it is a different picture, and starts at fit.
        .onChange(of: view) { old, new in
            if (old == .original) != (new == .original) { zoomModel.fit() }
        }
    }

    private func resetZoom() {
        if reduceMotion { zoomModel.fit() } else { withAnimation(.snappy) { zoomModel.fit() } }
    }

    // MARK: Header

    /// Single-line on purpose (the constraint-loop rule: nothing inside a split may change its own minimum). Two
    /// layouts, the first that fits wins: the title, the View menu and the size, or the title (which truncates) and the
    /// menu — the menu is the one control here and never goes.
    private func header(_ layer: FFTSourceLayer?) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                title
                Spacer(minLength: 8)
                FFTSourceViewControl(analysis: analysis)
                size(layer)
            }
            HStack(spacing: 8) {
                title
                Spacer(minLength: 8)
                FFTSourceViewControl(analysis: analysis)
            }
        }
        .frame(height: LayoutPolicy.paneHeaderHeight)
    }

    private var title: some View {
        Text(image.fileName)
            .font(.headline)
            .lineLimit(1)
            .truncationMode(.middle)
            .layoutPriority(-1)
    }

    private func size(_ layer: FFTSourceLayer?) -> some View {
        let shown = layer?.canvas
        return Text(verbatim: "\(shown?.width ?? image.width) × \(shown?.height ?? image.height)")
            .help("Columns × rows, in pixels")
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .fixedSize()
    }

    // MARK: Body

    /// What the view's product is failing with, in the core's words (nil while it is merely not there yet).
    static func missingFailure(for analysis: FFTAnalysis, view: FFTAnalysis.SourceView) -> String? {
        view == .maskedInverse ? analysis.maskFailure : view == .absf || view == .wiener ? analysis.filterFailure : nil
    }

    /// The words under a view whose product is not there yet — what it waits for, or why it failed — read from the owner
    /// once, so the pane and its tests share one call (the Masked Inverse waits by the menu's two causes).
    static func missingWords(for analysis: FFTAnalysis, view: FFTAnalysis.SourceView) -> (title: String, detail: String) {
        let working = view == .maskedInverse ? analysis.hasMaskSpot
            : view == .absf || view == .wiener ? analysis.isFiltering : analysis.spectrum == nil
        return FFTPaneFormat.missing(view, isWorking: working, failure: missingFailure(for: analysis, view: view),
                                     hasMeasuredSpot: analysis.hasMeasuredSpot, hasMaskSpot: analysis.hasMaskSpot)
    }

    /// The view's product is not there yet: what it waits for, or why it failed, in the core's words.
    private func missing(_ view: FFTAnalysis.SourceView) -> some View {
        let failure = Self.missingFailure(for: analysis, view: view)
        let words = Self.missingWords(for: analysis, view: view)
        return ContentUnavailableView {
            Label(words.title, systemImage: failure == nil ? "photo" : "exclamationmark.triangle")
        } description: {
            Text(words.detail)
        }
        .fftPaneAccessibility(label: FFTPaneFormat.title(of: view),
                              value: FFTPaneFormat.spokenSubject(crop: analysis.region, width: image.width, height: image.height),
                              identifier: "fft.sourcePane")
    }

    private func content(_ layer: FFTSourceLayer, view: FFTAnalysis.SourceView, in size: CGSize) -> some View {
        let shown = layer.canvas
        let box = LayoutPolicy.fitted(in: size, aspect: CGFloat(shown.width) / CGFloat(shown.height))
        let sampling = ImageScaleBar.sampling(image)
        let geometry = FFTPaneGeometry.make(box: box, width: shown.width, height: shown.height, zoom: zp.drawZoom,
                                            offset: zp.effectiveOffset)
        return ZStack {
            // The picture is drawn BEHIND this layer by the shader (the `.background`: pane-sized and untransformed, the
            // vertex shader applies the zoom and offset, so the drawable stays pane-sized at any zoom — `ImagePane`'s
            // measured reason); everything over it is mapped through `MarkGeometry`.
            Color.clear
                .frame(width: box.width, height: box.height)
                .background {
                    MetalImageView(
                        pixels: shown.normalized, width: shown.width, height: shown.height,
                        contentVersion: shown.contentVersion, colormap: layer.colormap,
                        displayLo: layer.window.low, displayHi: layer.window.high, gamma: layer.gamma
                    )
                    .displayTransform(geometry.transform)
                    .frame(width: box.width, height: box.height)
                    .allowsHitTesting(false)
                }
                .overlay {
                    if layer.drawsRegion {
                        // The overlay takes the presses of the region, so ZoomPan's double-click never sees them: the
                        // same reset here (`ImagePane`, the Image room's drive).
                        FFTRegionOverlay(analysis: analysis, geometry: geometry)
                            .simultaneousGesture(TapGesture(count: 2).onEnded { resetZoom() })
                    }
                }
                .overlay(alignment: .top) {
                    if let plate = layer.plate {
                        Text(plate)
                            .font(.caption)
                            .lineLimit(3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.thinMaterial)
                            .allowsHitTesting(false)
                    }
                }
                .overlay {
                    if layer.border != .plain {
                        Rectangle()
                            .strokeBorder(layer.border == .accent ? Color.accentColor : Color.orange, lineWidth: 2)
                            .allowsHitTesting(false)
                    }
                }
                .clipped()
                .contentShape(Rectangle())
                .border(Color.white.opacity(0.08))
                .zoomPan(zoomModel, box: box)
                .zoomPanWheel(zoomModel, box: box)
                .contextMenu { contextMenu }

            PaneFooter {
                // Hidden, never re-measured, as `ImagePane`: opacity keeps the footer's identity and place.
                ScaleBar(unitsPerPoint: ImageScaleBar.unitsPerPoint(perPixel: sampling.perPixel, imageWidth: shown.width,
                                                                    boxWidth: box.width, zoom: zp.drawZoom),
                         unitLabel: sampling.label)
                    .opacity(item.presentation.showsScaleBar ? 1 : 0)
                    .accessibilityHidden(!item.presentation.showsScaleBar)
            } trailing: {
                EmptyView()
            }
        }
        .frame(width: box.width, height: box.height)
        // Centred, as Preview centres a photo.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .fftPaneAccessibility(label: view == .original ? "Image" : FFTPaneFormat.title(of: view),
                              value: FFTPaneFormat.spokenSubject(crop: analysis.region, width: image.width, height: image.height),
                              identifier: "fft.sourcePane")
        .accessibilityHint(ZoomPan.accessibilityHint)
        .zoomPanAccessibilityActions(zoomModel, box: box)
    }

    @ViewBuilder
    private var contextMenu: some View {
        let centred = FFTRegion.centredSquare(width: image.width, height: image.height)
        Button("Clear Region") { analysis.setRegion(nil, committed: true) }
            .disabled(analysis.region == nil)
        Button("Use Centred Square") {
            if let centred { analysis.setRegion(centred, committed: true) }
        }
        .disabled(centred == nil)
        Divider()
        Button("Reset Zoom") { resetZoom() }
    }
}
