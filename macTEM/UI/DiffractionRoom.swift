//
//  DiffractionRoom.swift
//  Role: the Diffraction room's centre: the pattern (log display), the centre, the
//        annulus being dragged, the fitted rings and the clicked spots drawn over it, and the readout table under it. The selected file
//        is the pattern; the state is `DiffractionAnalysis` (TEMSession, `OpenItem.diffraction`), every number DiffractoKit's.
//        Pure SwiftUI. Zoom (control placement §6): the wheel and a pinch zoom about the pattern's centre, a double-click (Ring tool) fits again,
//        and View > Zoom In, Zoom Out and Zoom to Fit (⌘+, ⌘−, ⌘0) do the same from the menu (`DiffractionZoomCommands`);
//        the view stays centred on the pattern, so there is no pan, and the drag belongs to the Ring tool. The R · q · d under the pointer is the
//        status line's (§7); a fit in flight is the infobar's, with Stop (WorkspaceView). Not here yet (open-items): Find Spots, the predicted
//        rings, the centre handle drag.
//
//  The annulus is a drag in the Ring tool: press at the inner radius, release at the outer (or the reverse); the fields in the inspector
//  type it. A click in the Spot tool measures a spot. Gesture-rate values (the drag, the pointer) are `@State` here and never touch the
//  owner until the gesture ends.
//

import ShellControls
import ShellLayout
import ShellMetal
import SwiftUI
import ImagoCore
import TEMCore
import TEMSession
import DiffractoGeometry

struct DiffractionRoom: View {
    let image: CalibratedImage
    let item: OpenItem

    private struct DisplayKey: Equatable { var id: OpenItem.ID; var log: Bool; var width: Int; var height: Int }

    var body: some View {
        // The root reads only what a change of the RESULTS (or the log toggle) must redraw: the pointer, the zoom and the annulus drag live in
        // the leaf views that draw them, so a mouse move re-evaluates one small view and nothing above it.
        let analysis = item.diffraction
        let view = item.diffractionView
        let rows = analysis.readout(image: image)
        VStack(spacing: 0) {
            DiffractionHeader(image: image, analysis: analysis, view: view)
            DiffractionPatternPane(image: image, analysis: analysis, view: view, rows: rows)
                .modifier(DiffractionZoomCommands(image: image, view: view))
            Divider()
            DiffractionReadoutTable(analysis: analysis, view: view, rows: rows)
                .frame(height: LayoutPolicy.diffractionReadoutHeight)
        }
        .task(id: DisplayKey(id: item.id, log: view.useLog, width: image.width, height: image.height)) {
            analysis.bind(image)
            let centre = analysis.centre ?? .imageCentre(width: image.width, height: image.height)
            let radius = await Self.extent(pixels: image.pixels, width: image.width, height: image.height, centre: centre)
            // A quick Log toggle or another file cancels this pass while it computes: it writes nothing, so the newer pass's extent
            // and canvas are the ones left on screen.
            guard !Task.isCancelled else { return }
            view.setAutoExtent(radius)
            let pixels = image.pixels, w = image.width, h = image.height, log = view.useLog
            let canvas = await Self.makeCanvas(pixels: pixels, width: w, height: h, log: log)
            guard !Task.isCancelled else { return }
            // A window in log values means nothing in linear ones: the range starts whole again.
            if view.presentation.canvas.map({ $0.contentVersion != canvas.contentVersion }) ?? false { view.presentation.resetWindow() }
            view.presentation.show(canvas)
        }
        // The ring or spot just added is the selected row.
        .onChange(of: analysis.lastAdded) { if let id = analysis.lastAdded { view.selection = id } }
    }

    @concurrent
    nonisolated static func extent(pixels: [Float], width: Int, height: Int, centre: DiffractionCentre) async -> Double? {
        DiffractionCompute.contentRadius(pixels: pixels, width: width, height: height, centre: centre)
    }

    /// The pattern's display values: log10(1 + max(I, 0)) by default (a pattern spans decades), normalised; off the main actor. The
    /// Display section's histogram and window are of these values, the ones drawn (0…1), so its handles move what the eye sees.
    @concurrent
    nonisolated static func makeCanvas(pixels: [Float], width: Int, height: Int, log: Bool) async -> CanvasPixels {
        let normalized = TEMCore.DiffractionPattern(qy: height, qx: width, pixels: pixels).normalized(useLog: log)
        return CanvasPixels(width: width, height: height, normalized: normalized,
                            contentVersion: MetalImageView.contentVersion(of: normalized, width: width, height: height), rawRange: 0...1,
                            histogram: IntensityHistogram.compute(normalized))
    }
}

// MARK: - Header

private struct DiffractionHeader: View {
    let image: CalibratedImage
    let analysis: DiffractionAnalysis
    let view: DiffractionViewState

    var body: some View {
        let calibration = analysis.calibration(for: image)
        let volts = analysis.volts(for: image)
        HStack(spacing: 8) {
            Text(image.fileName).font(.callout.weight(.semibold)).lineLimit(1).truncationMode(.middle).layoutPriority(1)
            Text(summary(calibration: calibration, volts: volts))
                .font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                .accessibilityIdentifier("diffraction.scale")
                .accessibilityValue(DiffractionValueFormat.scale(calibration?.deltaQ))
            Spacer(minLength: 8)
            // What the pane shows about the centre, in words (a header holds words only); its value is the half-side to three decimals,
            // which a journey maps its drags by.
            let half = view.viewHalfSide(for: image)
            Text("view ±\(Num.fixed(half, 0)) px")
                .font(.callout.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                .accessibilityIdentifier("diffraction.view")
                .accessibilityValue(DiffractionValueFormat.halfSide(half))
        }
        .padding(.horizontal, LayoutPolicy.infobarHorizontalPadding)
        .frame(height: LayoutPolicy.paneHeaderHeight)
    }

    private func summary(calibration: DiffractionCalibration?, volts: Double?) -> String {
        var parts = ["\(image.width) × \(image.height) px"]
        if let volts { parts.append("\(Num.sig(volts / 1000, 4)) kV\(image.voltage != nil ? " (file)" : "")") }
        if let calibration {
            parts.append("scale: \(calibration.sourceText)")
            parts.append("Δq \(Num.fixed(calibration.deltaQ, 5)) Å⁻¹/px")
            if let l = calibration.ring?.lengthPixels { parts.append("L \(Num.fixed(l, 0)) px") }
            if let mm = calibration.ring?.lengthMillimetres { parts.append("L \(Num.fixed(mm, 0)) mm") }
        } else {
            parts.append("no scale yet")
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - The pattern

/// How the pattern is laid in its box: the image fills the box at `scale` points per pixel, then is magnified `zoom` times about the box
/// centre and moved so the pattern centre sits at the box centre. One map for the picture, the overlays and the gestures.
private nonisolated struct DiffractionLayout {
    let box: CGSize
    let width: Int
    let height: Int
    let centre: DiffractionCentre
    let halfSide: Double

    var scaleX: CGFloat { box.width / CGFloat(width) }
    var scaleY: CGFloat { box.height / CGFloat(height) }
    /// Box points per image point: the image's own half-side over the half-side wanted.
    var zoom: CGFloat { CGFloat(Double(min(width, height)) / 2 / halfSide) }
    private var middle: CGPoint { CGPoint(x: box.width / 2, y: box.height / 2) }
    private var unzoomedCentre: CGPoint { CGPoint(x: (centre.column + 0.5) * scaleX, y: (centre.row + 0.5) * scaleY) }
    var offset: CGSize { CGSize(width: (middle.x - unzoomedCentre.x) * zoom, height: (middle.y - unzoomedCentre.y) * zoom) }

    /// The point of a (column, row) pixel in the box.
    func point(column: Double, row: Double) -> CGPoint {
        let p = CGPoint(x: (column + 0.5) * scaleX, y: (row + 0.5) * scaleY)
        return CGPoint(x: middle.x + (p.x - middle.x) * zoom + offset.width, y: middle.y + (p.y - middle.y) * zoom + offset.height)
    }

    /// The (column, row) under a point of the box.
    func pixel(at p: CGPoint) -> (column: Double, row: Double) {
        let ux = (p.x - offset.width - middle.x) / zoom + middle.x, uy = (p.y - offset.height - middle.y) / zoom + middle.y
        return (Double(ux / scaleX) - 0.5, Double(uy / scaleY) - 0.5)
    }

    /// Box points per pixel after the zoom (x).
    var pointsPerPixel: CGFloat { scaleX * zoom }
}

private struct DiffractionPatternPane: View {
    let image: CalibratedImage
    let analysis: DiffractionAnalysis
    let view: DiffractionViewState
    let rows: [DiffractionReadoutRow]
    @Environment(AppState.self) private var appState
    @State private var drag: (start: CGPoint, end: CGPoint)?
    /// The half-side while a pinch is running; committed to the view state once, when it ends.
    @State private var liveHalf: Double?
    @State private var pinchStart: Double?

    var body: some View {
        GeometryReader { geo in
            let box = LayoutPolicy.fitted(in: geo.size, aspect: CGFloat(image.width) / CGFloat(image.height))
            let centre = analysis.centre ?? .imageCentre(width: image.width, height: image.height)
            let half = liveHalf ?? view.viewHalfSide(for: image)
            let layout = DiffractionLayout(box: box, width: image.width, height: image.height, centre: centre, halfSide: half)
            ZStack {
                Color.black
                if let canvas = view.presentation.canvas {
                    let display = view.presentation
                    MetalImageView(pixels: canvas.normalized, width: canvas.width, height: canvas.height, contentVersion: canvas.contentVersion,
                                   colormap: display.colormap, displayLo: display.displayFractions.low, displayHi: display.displayFractions.high,
                                   gamma: Float(display.gamma))
                        .displayTransform(MetalDisplayTransform(paneSize: box, imageBox: box, zoom: layout.zoom, offset: layout.offset))
                        .allowsHitTesting(false)
                }
                DiffractionOverlay(analysis: analysis, view: view, rows: rows, layout: layout, drag: drag.flatMap { radii(from: $0.start, to: $0.end, layout: layout) })
                    .allowsHitTesting(false)
            }
            .frame(width: box.width, height: box.height)
            .clipped()
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .local)
                .onChanged { if view.tool == .ring { drag = ($0.startLocation, $0.location) } }
                .onEnded { value in
                    defer { drag = nil }
                    guard view.tool == .ring, let radii = radii(from: value.startLocation, to: value.location, layout: layout) else { return }
                    view.setAnnulus(inner: radii.0, outer: radii.1)
                })
            .simultaneousGesture(MagnifyGesture()
                .onChanged { v in
                    let start = pinchStart ?? half
                    if pinchStart == nil { pinchStart = start }
                    liveHalf = min(max(start / v.magnification, 8), Double(min(image.width, image.height)) / 2)
                }
                .onEnded { _ in
                    if let liveHalf { view.zoomHalfSide = liveHalf }
                    liveHalf = nil
                    pinchStart = nil
                })
            // The wheel zooms about the pattern's centre (the view is centred on it); the application-wide monitor stays gone.
            .onScrollWheel { event in
                guard event.delta != 0 else { return }
                view.zoom(by: Double(ScrollZoom.factor(delta: event.delta, isPrecise: event.isPrecise)), image: image)
            }
            .simultaneousGesture(TapGesture(count: 2).onEnded { view.fitView() }, isEnabled: view.tool == .ring)
            .onContinuousHover { phase in
                switch phase {
                case .active(let p):
                    let q = layout.pixel(at: p)
                    appState.diffractionReadout = DiffractionReadoutText.text(column: q.column, row: q.row, centre: analysis.centre,
                                                                               calibration: analysis.calibration(for: image))
                case .ended:
                    appState.diffractionReadout = nil
                }
            }
            .onTapGesture(coordinateSpace: .local) { p in
                guard view.tool == .spot else { return }
                let q = layout.pixel(at: p)
                analysis.addSpot(image: image, row: q.row, column: q.column)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityIdentifier("diffraction.pane")
            .accessibilityLabel("Diffraction pattern")
            .accessibilityValue("\(image.width) by \(image.height) pixels, \(UnitDisplay.count(analysis.rings.count, "ring", "rings")), \(UnitDisplay.count(analysis.spots.count, "spot", "spots"))")
            .accessibilityAction(named: "Zoom in") { view.zoom(by: 2, image: image) }
            .accessibilityAction(named: "Zoom out") { view.zoom(by: 0.5, image: image) }
            .accessibilityAction(named: "Reset zoom") { view.fitView() }
            .overlay(alignment: .bottomTrailing) {
                // The zoom against the pattern's own extent, once it is not 1× (§6).
                let fit = view.fitHalfSide(for: image)
                if let text = ZoomPan.badgeText(zoom: CGFloat(fit / half)), let spoken = ZoomPan.badgeSpoken(zoom: CGFloat(fit / half)) {
                    Text(text)
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.regularMaterial, in: Capsule()).padding(6)
                        .help("\(spoken). Double-click with the Ring tool to see the whole pattern again.")
                        .accessibilityLabel(spoken)
                        .accessibilityIdentifier("diffraction.zoomBadge")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(8)
    }

    /// The annulus the drag would make, in pixels: the distances of its two ends from the centre.
    private func radii(from a: CGPoint, to b: CGPoint, layout: DiffractionLayout) -> (Double, Double)? {
        guard let centre = analysis.centre else { return nil }
        func r(_ p: CGPoint) -> Double {
            let q = layout.pixel(at: p)
            let dy = q.row - centre.row, dx = q.column - centre.column
            return (dx * dx + dy * dy).squareRoot()
        }
        let (ra, rb) = (r(a), r(b))
        guard abs(ra - rb) >= 1 else { return nil }
        return (min(ra, rb), max(ra, rb))
    }
}

// MARK: - View > Zoom

/// What View > Zoom In, Zoom Out or Zoom to Fit asks of the pattern. The commands act on a `PaneZoomModel` (ShellControls) and on
/// nothing else, and the pattern's zoom is a half-side about its centre (`DiffractionViewState`), not a `ZoomPan`. So the room publishes
/// a model of its own that follows the pane's zoom (the badge's number) and reads what the menu did to it, as MacEMUI's maps keep a
/// model beside their shared transform. The rules are pure; the three steps below them are the whole round, on the real owners.
nonisolated enum DiffractionZoomCommand: Equatable {
    /// The half-side divided by this factor (`DiffractionViewState.zoom(by:image:)`).
    case zoom(by: Double)
    /// The pattern's own extent again (`DiffractionViewState.fitView`).
    case fit

    /// The zoom the menu's model holds while the pane shows `halfSide` and a fit shows `fitHalfSide`: the badge's number, held to the
    /// model's own range (`ZoomPan.clampZoom`); 1 when either is not a positive number.
    static func mirrored(fitHalfSide: Double, halfSide: Double) -> CGFloat {
        guard fitHalfSide.isFinite, halfSide.isFinite, fitHalfSide > 0, halfSide > 0 else { return 1 }
        return ZoomPan.clampZoom(CGFloat(fitHalfSide / halfSide))
    }

    /// What the menu asked for, from the model's zoom and the pane's (`mirrored`): nil when they agree (the model only followed the
    /// pane, or the menu's step stopped at the model's limit), the fit at 1×, else the step as a factor on the pane's zoom.
    static func asked(model: CGFloat, mirrored: CGFloat) -> DiffractionZoomCommand? {
        guard model.isFinite, model > 0, mirrored > 0, model != mirrored else { return nil }
        return model == 1 ? .fit : .zoom(by: Double(model / mirrored))
    }

    /// The pane's zoom as the model holds it.
    @MainActor
    static func mirrored(_ view: DiffractionViewState, image: CalibratedImage) -> CGFloat {
        mirrored(fitHalfSide: view.fitHalfSide(for: image), halfSide: view.viewHalfSide(for: image))
    }

    /// The pane zoomed (the wheel, a pinch, a double-click, the pattern's extent found) or a menu step was performed: the model follows
    /// what the pane shows, written only when it differs.
    @MainActor
    static func follow(_ view: DiffractionViewState, image: CalibratedImage, with model: PaneZoomModel) {
        let shown = mirrored(view, image: image)
        if model.state.zoom != shown { model.update { $0.zoom = shown } }
    }

    /// The model changed: when the menu did it, the same step on the pattern (the VoiceOver actions' step, a factor of 2).
    @MainActor
    static func perform(from model: PaneZoomModel, on view: DiffractionViewState, image: CalibratedImage) {
        guard let command = asked(model: model.state.zoom, mirrored: mirrored(view, image: image)) else { return }
        switch command {
        case .zoom(let factor): view.zoom(by: factor, image: image)
        case .fit: view.fitView()
        }
    }
}

/// Publishes the pattern's zoom to View > Zoom In, Zoom Out and Zoom to Fit while the room is shown. Its own modifier with the model as
/// its state, so a zoom step re-evaluates this and not the room around it.
private struct DiffractionZoomCommands: ViewModifier {
    let image: CalibratedImage
    let view: DiffractionViewState
    @State private var model = PaneZoomModel()

    func body(content: Content) -> some View {
        content
            .zoomCommandTarget(model, isTarget: true)
            .onChange(of: DiffractionZoomCommand.mirrored(view, image: image), initial: true) {
                DiffractionZoomCommand.follow(view, image: image, with: model)
            }
            // The step is performed, then the model is put back on what the pane shows: a step the pane takes in part or not at all
            // (its 8 px limit, the whole image, a zoom past the model's range) changes no mirrored value, so the half above would not
            // run and the model would stay off the pane's zoom, where the next step the other way does nothing.
            .onChange(of: model.state.zoom) {
                DiffractionZoomCommand.perform(from: model, on: view, image: image)
                DiffractionZoomCommand.follow(view, image: image, with: model)
            }
    }
}

/// The status line's readout over the pattern (control placement §7): "x 290, y 256 · R 54,8 px · q 0,6848 Å⁻¹ · d 1,460 Å", the pixel
/// alone until there is a centre and a scale. nil off the image is the caller's (the hover ends).
nonisolated enum DiffractionReadoutText {
    static func text(column: Double, row: Double, centre: DiffractionCentre?, calibration: DiffractionCalibration?) -> String {
        let pixel = "x \(Int(column.rounded())), y \(Int(row.rounded()))"
        guard let centre, let calibration else { return pixel }
        let r = ((row - centre.row) * (row - centre.row) + (column - centre.column) * (column - centre.column)).squareRoot()
        let q = calibration.q(radius: r)
        guard q.isFinite, q > 0 else { return "\(pixel) · R \(Num.fixed(r, 1)) px" }
        return "\(pixel) · R \(Num.fixed(r, 1)) px · q \(Num.fixed(q, 4)) Å⁻¹ · d \(Num.fixed(1 / q, 3)) Å"
    }
}

// MARK: - Overlays

private struct DiffractionOverlay: View {
    let analysis: DiffractionAnalysis
    let view: DiffractionViewState
    let rows: [DiffractionReadoutRow]
    let layout: DiffractionLayout
    let drag: (Double, Double)?

    var body: some View {
        let centre = analysis.centre
        let rings = analysis.rings
        let spots = analysis.spots
        let labels = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, label(for: $0)) })
        Canvas { ctx, _ in
            func point(column: Double, row: Double) -> CGPoint { layout.point(column: column, row: row) }
            let ppp = layout.pointsPerPixel
            if let centre {
                let c = point(column: centre.column, row: centre.row)
                var cross = Path()
                cross.move(to: CGPoint(x: c.x - 8, y: c.y)); cross.addLine(to: CGPoint(x: c.x + 8, y: c.y))
                cross.move(to: CGPoint(x: c.x, y: c.y - 8)); cross.addLine(to: CGPoint(x: c.x, y: c.y + 8))
                ctx.stroke(cross, with: .color(.white), lineWidth: 1.5)
                let (inner, outer) = drag ?? (view.annulusInner, view.annulusOuter)
                for r in [inner, outer] {
                    let rect = CGRect(x: c.x - CGFloat(r) * ppp, y: c.y - CGFloat(r) * ppp, width: 2 * CGFloat(r) * ppp, height: 2 * CGFloat(r) * ppp)
                    ctx.stroke(Path(ellipseIn: rect), with: .color(.white.opacity(0.8)), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                }
            }
            for ring in rings {
                guard let ellipse = ring.ellipse else { continue }
                var path = Path()
                let points = RingOverlay.polyline(ellipse)
                for (i, p) in points.enumerated() {
                    let q = point(column: p.x, row: p.y)
                    if i == 0 { path.move(to: q) } else { path.addLine(to: q) }
                }
                path.closeSubpath()
                ctx.stroke(path, with: .color(ring.isCalibrating ? .orange : .yellow), lineWidth: 1.5)
                if let text = labels[ring.id], let first = points.first {
                    let at = point(column: first.x, row: first.y)
                    ctx.draw(Text(text).font(.caption).foregroundStyle(.white), at: CGPoint(x: at.x + 6, y: at.y - 8), anchor: .leading)
                }
            }
            for spot in spots {
                guard let r = spot.row, let c = spot.column else { continue }
                let p = point(column: c, row: r)
                var cross = Path()
                cross.move(to: CGPoint(x: p.x - 6, y: p.y - 6)); cross.addLine(to: CGPoint(x: p.x + 6, y: p.y + 6))
                cross.move(to: CGPoint(x: p.x - 6, y: p.y + 6)); cross.addLine(to: CGPoint(x: p.x + 6, y: p.y - 6))
                ctx.stroke(cross, with: .color(.red), lineWidth: 1.5)
                if let text = labels[spot.id] { ctx.draw(Text(text).font(.caption).foregroundStyle(.white), at: CGPoint(x: p.x + 8, y: p.y - 6), anchor: .leading) }
            }
        }
        .accessibilityHidden(true)
    }

    private func label(for row: DiffractionReadoutRow) -> String {
        guard let d = row.d else { return "" }
        return "d \(Num.fixed(d, 3)) Å" + (row.family.map { " · \($0)" } ?? "")
    }
}

// MARK: - The readout

/// The rings and spots as a system `Table` with a selection: arrow keys, ⌫ (removes the selected row), ⌘C (copies it, tab-separated under
/// the column titles), column resizing and VoiceOver rows come with it. The titles and the cells are `DiffractionReadoutFormat`'s, so the
/// copied text is what the table shows. A value a journey reads is a cell's accessibility value (`diffraction.row.<kind><n>.<column>`);
/// the d there has one decimal more than the cell (`DiffractionValueFormat.spacing`). A header is drawn as its title and spoken as
/// words (`Column.spoken`: the titles are symbols and units, and the first is empty), and the ring that sets the scale says so, not
/// "●" (whether the system's table header speaks a `Text`'s accessibility label is unverified on screen).
private struct DiffractionReadoutTable: View {
    let analysis: DiffractionAnalysis
    let view: DiffractionViewState
    let rows: [DiffractionReadoutRow]

    private typealias Column = DiffractionReadoutFormat.Column

    var body: some View {
        // The selection is read here, in the leaf: handed to the table as a binding to the view state, and to Edit > Copy as a value.
        let selection = Binding<UUID?>(get: { view.selection }, set: { view.selection = $0 })
        let selected = view.selection
        Table(rows, selection: selection) {
            TableColumn(header(.name)) { row in
                Text(DiffractionReadoutFormat.cell(.name, row)).help(row.isCalibrating ? "Set the scale" : "")
                    .accessibilityLabel(DiffractionReadoutFormat.spokenName(row))
                    .accessibilityValue(DiffractionReadoutFormat.spokenMark(row))
            }.width(min: 52, ideal: 58)
            TableColumn(header(.radius)) { row in Text(DiffractionReadoutFormat.cell(.radius, row)).monospacedDigit() }.width(min: 44, ideal: 50)
            TableColumn(header(.q)) { row in Text(DiffractionReadoutFormat.cell(.q, row)).monospacedDigit() }.width(min: 56, ideal: 62)
            TableColumn(header(.d)) { row in
                Text(DiffractionReadoutFormat.cell(.d, row)).monospacedDigit()
                    .accessibilityIdentifier("diffraction.row.\(row.kind.rawValue)\(row.number).d")
                    .accessibilityValue(DiffractionValueFormat.spacing(row.d))
            }.width(min: 52, ideal: 56)
            TableColumn(header(.family)) { row in
                Text(DiffractionReadoutFormat.cell(.family, row))
                    .accessibilityIdentifier("diffraction.row.\(row.kind.rawValue)\(row.number).family")
                    .accessibilityValue(row.family ?? "")
            }.width(min: 46, ideal: 52)
            TableColumn(header(.dListed)) { row in Text(DiffractionReadoutFormat.cell(.dListed, row)).monospacedDigit() }.width(min: 52, ideal: 58)
            TableColumn(header(.delta)) { row in Text(DiffractionReadoutFormat.cell(.delta, row)).monospacedDigit() }.width(min: 48, ideal: 54)
            TableColumn(header(.odds)) { row in Text(DiffractionReadoutFormat.cell(.odds, row)).monospacedDigit() }.width(min: 60, ideal: 68)
            TableColumn(header(.verdict)) { row in
                Text(DiffractionReadoutFormat.cell(.verdict, row)).lineLimit(1)
                    .accessibilityIdentifier("diffraction.row.\(row.kind.rawValue)\(row.number).verdict")
                    .accessibilityValue(row.verdict)
            }.width(min: 70, ideal: 90)
        }
        .onDeleteCommand { if let id = view.selection { analysis.remove(id); view.selection = nil } }
        // ⌘C and Edit > Copy: the selected ring or spot; dimmed with no row selected.
        .onCopyCommand(perform: rows.contains(where: { $0.id == selected }) ? { copied(selected) } : nil)
        .overlay {
            if rows.isEmpty {
                Text("Drag an annulus over a ring (Ring tool) or click a spot (Spot tool). A scale comes first: Calibrate on a standard's ring, or use the file's.")
                    .font(.callout).foregroundStyle(.secondary).padding(10).allowsHitTesting(false)
            }
        }
        .accessibilityIdentifier("diffraction.readout")
    }

    /// A column's header: the title as drawn, with the column's words as what VoiceOver calls it.
    private func header(_ column: Column) -> Text {
        Text(column.title).accessibilityLabel(column.spoken)
    }

    /// What ⌘C hands the system: the selected row as the table shows it (`DiffractionReadoutFormat.copyText`), nothing when none is.
    private func copied(_ selected: UUID?) -> [NSItemProvider] {
        let picked = rows.filter { $0.id == selected }
        guard !picked.isEmpty else { return [] }
        return [NSItemProvider(object: DiffractionReadoutFormat.copyText(picked) as NSString)]
    }
}

// MARK: - The values beside the words

/// The numbers the room hands accessibility beside the text it draws: the scale (Δq, Å⁻¹ per pixel), the half-side the pane shows (px)
/// and a row's d (Å). Each is one number with more decimals than the text, written in the reader's locale as the text is (#329:
/// VoiceOver spoke "0.01250" under a header that read "0,01250"), never grouped. A UI journey reads them and parses the reader's
/// decimal mark. Pure.
nonisolated enum DiffractionValueFormat {
    /// Δq to five decimals, "0,01250" in a comma locale; "" while there is no scale.
    static func scale(_ deltaQ: Double?, locale: Locale = .autoupdatingCurrent) -> String {
        deltaQ.map { Num.fixed($0, 5, locale: locale) } ?? ""
    }

    /// The half-side to three decimals, "79,412".
    static func halfSide(_ half: Double, locale: Locale = .autoupdatingCurrent) -> String {
        Num.fixed(half, 3, locale: locale)
    }

    /// A row's d to five decimals, "2,03910"; "" for a row that has none.
    static func spacing(_ d: Double?, locale: Locale = .autoupdatingCurrent) -> String {
        d.map { Num.fixed($0, 5, locale: locale) } ?? ""
    }
}
