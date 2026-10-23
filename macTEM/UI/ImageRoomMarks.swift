//
//  ImageRoomMarks.swift
//  Role: the Image room's marks on the image (archive: roadmap-registrations-2026-10-15.md V1-5; the design in archive: image-room-design-2026-10-13.md):
//        the drawing of every distance, angle and profile of the selected file, and the gestures that make and move
//        them. The marks are the file's (`ImageMeasurements`); the numbers are TEMCore's; this file maps and draws.
//
//  THE MAP (`MarkGeometry`): image coordinates — column x, row y, a pixel's centre at integers, so the image spans
//  −0.5…W − 0.5 — to the pane's points, through the SAME `MetalDisplayTransform` the vertex shader draws the image with
//  (its `uv(atPanePoint:)` is the inverse; `panePoint(of:)` is its forward chain, pinned against it by
//  `MarkGeometryTests`). The marks are drawn in one pane-sized `Canvas` OUTSIDE the zoomed layer, so a stroke keeps its
//  width at any zoom and a mark moves exactly as the image does — both are drawn from the one zoom and offset, so an
//  animated zoom reset cannot slip one from the other (V1-5's check on the first overlay).
//
//  THE GESTURES, only with a tool chosen (Pan keeps the pane's drag-to-pan; a pinch zooms in every tool):
//  Distance and Profile — press, drag, release; Angle — drag the first arm from A to the vertex B, then click C, the
//  second arm following the pointer until then. In every tool a press within `handleRadius` of a mark's end drags that
//  end by the drag (never to the pointer); a drag under `minimumDrag` makes and moves nothing. A gesture's live points
//  are this view's `@GestureState` (a gesture value never goes through `@Observable`, and a cancelled drag leaves
//  nothing); a mark is written to the owner once, on release. Escape or a tool switch drops an unfinished angle; Escape,
//  Delete and ⌘C are the room's keys (`ImageKeyedRoom`, App/PaneKeys.swift), not this overlay's: it holds no focus.
//

import ShellMetal
import SwiftUI
#if canImport(TEMCore)
import TEMCore
import TEMSession
#endif

/// Image coordinates ↔ pane points, through the shader's own transform.
nonisolated struct MarkGeometry: Equatable {
    let transform: MetalDisplayTransform
    let imageWidth: Int
    let imageHeight: Int

    /// The image point under pane point `p` (not clamped).
    func imagePoint(atPanePoint p: CGPoint) -> ImagePoint {
        let uv = transform.uv(atPanePoint: p)
        return ImagePoint(x: Double(uv.x) * Double(imageWidth) - 0.5, y: Double(uv.y) * Double(imageHeight) - 0.5)
    }

    /// Where image point `q` is drawn: `MetalDisplayTransform`'s forward chain (no rotation or mirror in this room).
    func panePoint(of q: ImagePoint) -> CGPoint {
        let w = Double(transform.imageBox.width), h = Double(transform.imageBox.height)
        let pcx = (q.x + 0.5) / Double(imageWidth) * w - w / 2
        let pcy = (q.y + 0.5) / Double(imageHeight) * h - h / 2
        let z = Double(transform.zoom)
        return CGPoint(x: pcx * z + Double(transform.offset.width) + Double(transform.paneSize.width) / 2,
                       y: pcy * z + Double(transform.offset.height) + Double(transform.paneSize.height) / 2)
    }

    /// `q` held inside the image (−0.5…W − 0.5 on each axis): a mark never ends off the pixels.
    func clamped(_ q: ImagePoint) -> ImagePoint {
        ImagePoint(x: min(max(q.x, -0.5), Double(imageWidth) - 0.5), y: min(max(q.y, -0.5), Double(imageHeight) - 0.5))
    }

    /// Screen points per image pixel along x (the profile band's width).
    var pointsPerPixel: CGFloat { transform.imageBox.width / CGFloat(imageWidth) * transform.zoom }
}

/// Draws the selected file's marks and takes the gestures that make and move them.
struct ImageMarksOverlay: View {
    let image: CalibratedImage
    let geometry: MarkGeometry
    let measurements: ImageMeasurements
    /// An angle whose first arm is drawn, waiting for the click on its third point; outlives the drag on purpose. The room
    /// owns it (`ImagePane`), so Escape, which is the room's key (`ImageKeyedRoom`), can drop it.
    @Binding var angleArm: AngleArm?
    let tool: ImageRoomTools.Tool
    /// The text drawn beside a mark ("12.43 nm"); the Measure section's formatter, also what ⌘C copies.
    let label: (ImageMark) -> String
    /// Where a refused mark, move or width is said (`MarkRefusalText`): never a silent no-op.
    @Environment(AppState.self) private var appState

    /// A press this close to a mark's end, in points, drags that end.
    static let handleRadius: CGFloat = 6
    /// A drag shorter than this, in points, makes no mark and moves no end (a click is not a measurement).
    static let minimumDrag: CGFloat = 2

    /// What the drag in progress shows. A `@GestureState`, so a drag the system cancels leaves nothing behind (an
    /// `onEnded` that never comes cannot strand a half-drawn mark); `onEnded` decides from the gesture's own values.
    private enum Live: Equatable {
        case none
        /// A segment (or an angle's first arm) being drawn.
        case drawing(ImageMark.Kind, start: ImagePoint, current: ImagePoint)
        /// A mark's end being dragged: where it would land.
        case moving(ImageMark.ID, index: Int, to: ImagePoint)
    }

    @GestureState private var live = Live.none
    /// The pointer, tracked only while an angle waits for its third point.
    @State private var hover: CGPoint?

    var body: some View {
        // Read here, not only inside the Canvas closure, so the overlay is told when the marks or the selection change.
        let marks = measurements.marks
        let selection = measurements.selection
        ZStack {
            Canvas { context, size in draw(in: &context, size: size, marks: marks, selection: selection) }
                .allowsHitTesting(false)
            Color.clear
                .contentShape(hitShape(marks))
                .gesture(drag(marks))
                .onContinuousHover { phase in
                    guard angleArm != nil else { return }
                    if case .active(let p) = phase { hover = p } else { hover = nil }
                }
                .pointerStyle(tool == .pan ? .grabIdle : .rectSelection)
        }
        .accessibilityHidden(true)   // the Measure section lists every mark and its value, and removes and copies them
        .onChange(of: tool) { angleArm = nil }
    }

    // MARK: Hit testing

    /// Where a press is ours: anywhere with a tool chosen; only on a mark's ends with Pan (elsewhere the pane pans).
    private func hitShape(_ marks: [ImageMark]) -> MarkHitShape {
        MarkHitShape(points: tool == .pan ? marks.flatMap { $0.points.map(geometry.panePoint(of:)) } : nil,
                     radius: Self.handleRadius)
    }

    /// The mark end nearest `p` within `handleRadius`, and where it is drawn.
    private func handle(near p: CGPoint, in marks: [ImageMark]) -> (id: ImageMark.ID, index: Int, at: CGPoint)? {
        var best: (ImageMark.ID, Int, CGPoint, CGFloat)?
        for mark in marks {
            for (i, q) in mark.points.enumerated() {
                let s = geometry.panePoint(of: q)
                let d = hypot(s.x - p.x, s.y - p.y)
                if d <= Self.handleRadius, d < (best?.3 ?? .infinity) { best = (mark.id, i, s, d) }
            }
        }
        return best.map { ($0.0, $0.1, $0.2) }
    }

    // MARK: Gestures

    /// Where a grabbed end lands: its own place moved by the drag, never jumped to the pointer (the grab is up to
    /// `handleRadius` off the end, which at a fitted 2k image is about 13 px).
    private func landing(of end: CGPoint, _ value: DragGesture.Value) -> ImagePoint {
        geometry.clamped(geometry.imagePoint(atPanePoint: CGPoint(x: end.x + value.translation.width,
                                                                  y: end.y + value.translation.height)))
    }

    private func isClick(_ value: DragGesture.Value) -> Bool {
        hypot(value.translation.width, value.translation.height) < Self.minimumDrag
    }

    private func drag(_ marks: [ImageMark]) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .updating($live) { value, live, _ in
                if let grab = handle(near: value.startLocation, in: marks) {
                    live = isClick(value) ? .none : .moving(grab.id, index: grab.index, to: landing(of: grab.at, value))
                } else if angleArm == nil, let kind = tool.markKind, !isClick(value) {
                    let start = geometry.clamped(geometry.imagePoint(atPanePoint: value.startLocation))
                    live = .drawing(kind, start: start,
                                    current: geometry.clamped(geometry.imagePoint(atPanePoint: value.location)))
                }
            }
            .onEnded { value in
                let here = geometry.clamped(geometry.imagePoint(atPanePoint: value.location))
                if let grab = handle(near: value.startLocation, in: marks) {
                    measurements.selection = grab.id
                    if !isClick(value),
                       MarkEdits.move(grab.id, point: grab.index, to: landing(of: grab.at, value), on: image, in: measurements) {
                        SessionPanels.markRefused(nil, .moved, appState: appState)
                    }
                } else if let arm = angleArm {
                    SessionPanels.markRefused(
                        measurements.add(ImageMark(kind: .angle, points: [arm.a, arm.vertex, here]), on: image),
                        .added, appState: appState)
                    angleArm = nil
                    hover = nil
                } else if let kind = tool.markKind, !isClick(value) {
                    let start = geometry.clamped(geometry.imagePoint(atPanePoint: value.startLocation))
                    if kind == .angle {
                        angleArm = AngleArm(a: start, vertex: here)
                        hover = value.location
                    } else {
                        SessionPanels.markRefused(measurements.add(ImageMark(kind: kind, points: [start, here]), on: image),
                                                  .added, appState: appState)
                    }
                }
            }
    }

    // MARK: Drawing

    private struct Shown {
        let kind: ImageMark.Kind
        let points: [ImagePoint]
        let width: Int
        let isSelected: Bool
        /// The value beside it, live while it is drawn or moved; nil while only a first arm exists.
        let text: String?
    }

    /// The marks as they are, with the one being drawn or moved in its live place and its value live too.
    private func shownMarks(_ marks: [ImageMark], selection: ImageMark.ID?) -> [Shown] {
        var out = marks.map { mark -> Shown in
            var shown = mark
            if case .moving(let id, let index, let to) = live, id == mark.id { shown.points[index] = to }
            return Shown(kind: mark.kind, points: shown.points, width: mark.width, isSelected: mark.id == selection,
                         text: label(shown))
        }
        switch live {
        case .drawing(let kind, let start, let current):
            let segment = kind == .angle ? ImageMark.Kind.distance : kind
            out.append(Shown(kind: segment, points: [start, current], width: 1, isSelected: true,
                             text: kind == .angle ? nil : label(ImageMark(kind: kind, points: [start, current]))))
        default:
            break
        }
        if let arm = angleArm {
            let c = hover.map { geometry.clamped(geometry.imagePoint(atPanePoint: $0)) } ?? arm.vertex
            let mark = ImageMark(kind: .angle, points: [arm.a, arm.vertex, c])
            out.append(Shown(kind: .angle, points: mark.points, width: 1, isSelected: true,
                             text: c == arm.vertex ? nil : label(mark)))
        }
        return out
    }

    private func draw(in context: inout GraphicsContext, size: CGSize, marks: [ImageMark], selection: ImageMark.ID?) {
        for shown in shownMarks(marks, selection: selection) {
            // Selected: the accent colour AND a heavier stroke, so colour is never the only difference (an accent
            // colour can be yellow).
            let colour: Color = shown.isSelected ? .accentColor : .yellow
            let line: CGFloat = shown.isSelected ? 2.25 : 1.5
            let screen = shown.points.map(geometry.panePoint(of:))
            if shown.kind == .profile, shown.width > 1, screen.count == 2 {
                band(context: &context, screen[0], screen[1], width: CGFloat(shown.width) * geometry.pointsPerPixel,
                     colour: colour)
            }
            var path = Path()
            path.addLines(screen)
            context.stroke(path, with: .color(.black.opacity(0.6)),
                           style: StrokeStyle(lineWidth: line + 2, lineCap: .round, lineJoin: .round))
            context.stroke(path, with: .color(colour), style: StrokeStyle(lineWidth: line, lineCap: .round, lineJoin: .round))
            for p in screen {
                let ring = Path(ellipseIn: CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6))
                context.stroke(ring, with: .color(.black.opacity(0.6)), lineWidth: 3)
                context.stroke(ring, with: .color(colour), lineWidth: 1.5)
            }
            // A label only where its anchor is on the pane: one pinned to the edge for a mark out of view would name
            // a line the reader cannot see (the 2026-10-13 drive, at ×4).
            if let words = shown.text, !words.isEmpty, let anchor = labelAnchor(screen, kind: shown.kind),
               CGRect(origin: .zero, size: size).contains(anchor) {
                let resolved = context.resolve(Text(words).font(.caption.monospacedDigit()).foregroundStyle(.white))
                let textSize = resolved.measure(in: CGSize(width: 400, height: 40))
                let w = textSize.width + 8, h = textSize.height + 2
                // Beside the anchor, kept inside the pane so a mark near an edge still shows its value.
                let x = min(max(anchor.x + 6, 2), max(size.width - w - 2, 2))
                let y = min(max(anchor.y - h - 6, 2), max(size.height - h - 2, 2))
                let box = CGRect(x: x, y: y, width: w, height: h)
                context.fill(Path(roundedRect: box, cornerRadius: 4), with: .color(.black.opacity(0.65)))
                context.draw(resolved, at: CGPoint(x: box.midX, y: box.midY))
            }
        }
    }

    /// The midpoint of a segment, the vertex of an angle.
    private func labelAnchor(_ screen: [CGPoint], kind: ImageMark.Kind) -> CGPoint? {
        switch kind {
        case .angle: return screen.count == 3 ? screen[1] : nil
        case .distance, .profile:
            guard screen.count == 2 else { return nil }
            return CGPoint(x: (screen[0].x + screen[1].x) / 2, y: (screen[0].y + screen[1].y) / 2)
        }
    }

    /// The strip a profile averages over, `width` points across, as a translucent band.
    private func band(context: inout GraphicsContext, _ a: CGPoint, _ b: CGPoint, width: CGFloat, colour: Color) {
        let dx = b.x - a.x, dy = b.y - a.y
        let length = hypot(dx, dy)
        guard length > 0 else { return }
        let nx = -dy / length * width / 2, ny = dx / length * width / 2
        var strip = Path()
        strip.addLines([CGPoint(x: a.x + nx, y: a.y + ny), CGPoint(x: b.x + nx, y: b.y + ny),
                        CGPoint(x: b.x - nx, y: b.y - ny), CGPoint(x: a.x - nx, y: a.y - ny)])
        strip.closeSubpath()
        context.fill(strip, with: .color(colour.opacity(0.18)))
    }
}

/// The overlay's hit area: the whole pane, or (with Pan) only discs around the marks' ends.
nonisolated struct MarkHitShape: Shape {
    /// nil: the whole rectangle.
    let points: [CGPoint]?
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        guard let points else { return Path(rect) }
        var path = Path()
        for p in points { path.addEllipse(in: CGRect(x: p.x - radius, y: p.y - radius, width: 2 * radius, height: 2 * radius)) }
        return path
    }
}
