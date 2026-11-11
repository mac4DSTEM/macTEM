//
//  MarkCursor.swift
//  Role: the VoiceOver twin of the pointer on a picture (macTEM#262): a pixel that named accessibility actions move, and the
//        action that does what a click or a drag there does. The Image room's marks and the Diffraction room's spots are
//        otherwise made only with the pointer. The shape is mac4DSTEM's twin of its disk-centre labelling (`DiskLabelCursor` and
//        `LabelCursorAccessibilityActions`, UI/ImagePanes.swift): a pure cursor, and a modifier that adds the actions only while
//        the pointer's own route is on. The actions are named accessibility actions, which VoiceOver lists. There is no key for
//        them yet (DEVIATION from design-dna principle 7: the arrows step a stack's frames, `stackArrowKeys`), so a keyboard user
//        without VoiceOver still makes a mark with the pointer.
//
//  THE CURSOR (`MarkCursor`, pure, pinned by `MarkCursorTests`): a pixel of the picture, column x and row y, that starts at the
//  picture's centre (in the Diffraction room the pattern's centre, `SpotCursorActions`) and steps 1 % of the axis (at least one
//  pixel), held on the picture. Its value is the status line's readout of that pixel, the words the pointer's gives ("x 120,
//  y 88 · 9744"; R, q and d in the Diffraction room). It is drawn nowhere.
//
//  THE IMAGE ROOM (`MarkCursorActions`, `MarkCursorAccessibility`): while Distance, Angle or Profile is chosen, "Place point at
//  centre", the four "Move point …", "Set point", and "Clear points" while a point is set. Set point holds the first point, then
//  makes the mark through the calls the drag's end and the angle's closing click make (`MarkMaking`, UI/ImageRoomMarks.swift): a
//  Distance or a Profile from the two points; an Angle's first two points become the room's `AngleArm` (A, then the vertex), the
//  very arm the pointer's first drag leaves, and the third point closes it as the click does. So a mark set from here is the one
//  a drag between the same points makes, and the pointer and the cursor can finish each other's angle.
//
//  WHAT DROPS A POINT: Clear points, and Escape (the room's key, `ImageKeyedRoom`), drop every point set, as Escape drops the
//  pointer's unfinished angle. A lone held point is the twin's own (a drag is whole, so the pointer has none): it is held only for
//  the picture and the tool it was set with (`MarkCursorState.adopt`), so another frame, a read of other pixels, another size or
//  another tool drops it, and so does an arm the pointer draws (it was the A of another angle). Another file is another pane,
//  which starts with none. Once an Angle's two points are the room's arm, whoever set them, the arm keeps the pointer's rules as
//  before: the closing point, Escape, Clear points or a tool switch drops it; another frame does not.
//
//  WHERE VOICEOVER FINDS THEM: an element of their own, a clear square at the cursor inside the picture, not the pane itself
//  (mac4DSTEM puts its actions on its pane). The pane's value is the pointer's readout through `ReadoutAccessibilityValue`, its one
//  writer, and SwiftUI does not say which of two values on one element wins; this element has one value, the cursor's. The pane's
//  hint names the element while a tool is chosen (`MarkCursor.paneHint`). The marks' overlay stays hidden (the Measure section
//  lists, removes and copies the marks), and the element takes no hits, so every gesture is as it was. Sitting at the cursor, it
//  is where VoiceOver draws its focus ring, and only that small square, not the whole picture, answers VoiceOver's pointer
//  instead of the pane's readout.
//

import ShellMetal
import SwiftUI
import TEMCore
import TEMSession

// MARK: - The cursor

/// A pixel of a picture that the named actions move: the VoiceOver twin of the pointer's place. Pure.
nonisolated enum MarkCursor {
    /// A pixel by its column `x` and row `y`, from 0, as `ImagePoint` names a pixel's centre.
    nonisolated struct Pixel: Equatable, Sendable {
        var x: Int
        var y: Int
    }

    /// The four steps, named as their actions are.
    nonisolated enum Move: CaseIterable, Sendable {
        case left, right, up, down

        /// The action's name ("Move point left").
        var actionName: String {
            switch self {
            case .left: "Move point left"
            case .right: "Move point right"
            case .up: "Move point up"
            case .down: "Move point down"
            }
        }
    }

    /// The action that brings the cursor back to the picture's centre.
    static let placeActionName = "Place point at centre"

    /// The side of the cursor's accessibility element, in points: what VoiceOver outlines at the cursor.
    static let elementSide: CGFloat = 12

    /// One step along an axis of `extent` pixels: 1 % of it, at least one pixel.
    static func step(extent: Int) -> Int { max(1, extent / 100) }

    /// `p` held on the picture's pixels, 0…width − 1 and 0…height − 1 (a picture of no pixels holds it at 0).
    static func clamped(_ p: Pixel, width: Int, height: Int) -> Pixel {
        Pixel(x: min(max(p.x, 0), max(width - 1, 0)), y: min(max(p.y, 0), max(height - 1, 0)))
    }

    /// The picture's centre pixel (the lower one of the two middle pixels of an even side).
    static func centre(width: Int, height: Int) -> Pixel {
        Pixel(x: max(width - 1, 0) / 2, y: max(height - 1, 0) / 2)
    }

    /// The pixel nearest the image point (`column`, `row`), held on the picture; nil when either is not a number. Where the
    /// Diffraction room's pattern centre puts the cursor.
    static func nearest(column: Double, row: Double, width: Int, height: Int) -> Pixel? {
        guard column.isFinite, row.isFinite else { return nil }
        // Held on the picture before the conversion, so a typed centre far off it cannot overflow `Int`.
        let x = min(max(column.rounded(), 0), Double(max(width - 1, 0)))
        let y = min(max(row.rounded(), 0), Double(max(height - 1, 0)))
        return Pixel(x: Int(x), y: Int(y))
    }

    /// The cursor where it was moved, or the picture's centre before it has been; always on the picture (a smaller picture than
    /// the one it was moved on holds it at its edge).
    static func resolved(_ stored: Pixel?, width: Int, height: Int) -> Pixel {
        clamped(stored ?? centre(width: width, height: height), width: width, height: height)
    }

    /// One named step from `p`, held on the picture. Up is a smaller row, as the picture is drawn.
    static func moved(_ p: Pixel, by move: Move, width: Int, height: Int) -> Pixel {
        // Brought onto the picture first, so the step cannot overflow and lands one step from a place on it.
        var next = clamped(p, width: width, height: height)
        switch move {
        case .left: next.x -= step(extent: width)
        case .right: next.x += step(extent: width)
        case .up: next.y -= step(extent: height)
        case .down: next.y += step(extent: height)
        }
        return clamped(next, width: width, height: height)
    }

    /// The pixel's centre in image coordinates: where a click on it lands.
    static func imagePoint(_ p: Pixel) -> ImagePoint {
        ImagePoint(x: Double(p.x), y: Double(p.y))
    }

    /// The pixel in the status line's words: "x 120, y 88". A String, never a localized key, so no number is grouped.
    static func spokenValue(_ p: Pixel) -> String {
        "x \(p.x), y \(p.y)"
    }

    /// The Image room's value: "Point 2 of 2, x 120, y 88 · 9744", the point Set point places next of the mark's count, then the
    /// status line's `readout` of the pixel (`ImageReadout`), or the bare place when there is none.
    static func spokenValue(_ p: Pixel, point: Int, of count: Int, readout: String? = nil) -> String {
        "Point \(point) of \(count), " + ReadoutSpeech.value(readout: readout, fallback: spokenValue(p))
    }

    /// What the Image room's element is called: the tool's mark, "Distance point".
    static func elementLabel(_ kind: ImageMark.Kind) -> String {
        MarkFormat.kindName(kind) + " point"
    }

    /// The Image pane's hint: the zoom's (`zoom`), then, while a tool is chosen, where its points are set (the Measure section's
    /// note names only the pointer's gestures).
    static func paneHint(_ zoom: String, kind: ImageMark.Kind?) -> String {
        guard let kind else { return zoom }
        return zoom + " Set the points of a mark with the actions of the " + elementLabel(kind) + "."
    }

    /// Where the cursor's element is placed in a box of `size`: on the pixel's point `p`, held inside the box so the element stays
    /// on screen (and so reachable) when the pixel is zoomed out of view; the box's centre when `p` is not a number.
    static func elementCentre(_ p: CGPoint, in size: CGSize) -> CGPoint {
        let half = elementSide / 2
        guard p.x.isFinite, p.y.isFinite else { return CGPoint(x: size.width / 2, y: size.height / 2) }
        return CGPoint(x: min(max(p.x, half), max(size.width - half, half)),
                       y: min(max(p.y, half), max(size.height - half, half)))
    }
}

// MARK: - The Image room's state

/// The picture a point is set on: its size and its pixels' version (`CanvasPixels.contentVersion`, which another frame of a stack
/// or a read of other pixels changes).
nonisolated struct MarkCursorBasis: Equatable, Sendable {
    var width: Int
    var height: Int
    var version: Int
}

/// The picture and the tool's kind of mark (nil: Pan) that a held point belongs to.
nonisolated struct MarkCursorScope: Equatable, Sendable {
    var basis: MarkCursorBasis
    var kind: ImageMark.Kind?
}

/// The Image room's cursor and the point Set point holds. The room keeps it beside its `AngleArm` (`ImagePane`); drawn nowhere.
nonisolated struct MarkCursorState: Equatable, Sendable {
    /// Where the cursor is; nil until it is moved (it starts at the picture's centre, `MarkCursor.resolved`).
    var position: MarkCursor.Pixel?
    /// The first point set, waiting for the second: a Distance's or a Profile's other end, an Angle's vertex. An Angle's first
    /// two points are then the room's `AngleArm`.
    var first: ImagePoint?
    /// The picture and the tool the held point was set with; nil until the state is first used.
    var scope: MarkCursorScope?

    init() {}

    /// The picture or the tool is `scope` now. Another than the point was set with drops the held point, so a lone point set on
    /// one picture or for one tool never lands on another. An Angle's arm is the room's and keeps its own rules (the header). The
    /// pane calls this whenever either changes; every Set point calls it first.
    mutating func adopt(_ scope: MarkCursorScope) {
        if let held = self.scope, held != scope { first = nil }
        self.scope = scope
    }

    /// An Angle's arm was drawn or went: a lone point still held belongs to no angle now (only the pointer's drag makes an arm
    /// while one is held, and that starts another angle), so it goes, and the next Set point starts afresh. The pane calls this.
    mutating func armChanged() { first = nil }
}

/// What a Set point did.
nonisolated enum MarkCursorOutcome: Equatable, Sendable {
    /// Point `point` of the mark's `of` is held; the mark waits for the next.
    case held(point: Int, of: Int)
    /// The mark was added (and selected, as a drawn one is).
    case added
    /// The session record refused the mark (`SessionPanels.markRefused` says why).
    case refused(SessionLineage.Refusal)
    /// Nothing: the cursor is on the point set last, and a mark of no length is no measurement (as a click is not a drag).
    case samePlace
}

// MARK: - The Image room's actions

/// The Image room's named actions' work, on the owners at the moment of use (as `ImageRoomKeys`): the modifier below only forwards
/// to it, so a test drives these same calls.
@MainActor
struct MarkCursorActions {
    let image: CalibratedImage
    let measurements: ImageMeasurements
    /// The chosen tool's kind of mark.
    let kind: ImageMark.Kind
    let basis: MarkCursorBasis

    static let setActionName = "Set point"
    /// Drops every point set for the mark, as Escape does.
    static let clearActionName = "Clear points"
    /// What VoiceOver hears after Clear points (the value then says "Point 1").
    static let clearedAnnouncement = "Points cleared"

    var scope: MarkCursorScope { MarkCursorScope(basis: basis, kind: kind) }

    /// Where the cursor is, on this picture.
    func pixel(_ state: MarkCursorState) -> MarkCursor.Pixel {
        MarkCursor.resolved(state.position, width: image.width, height: image.height)
    }

    /// How many of the mark's points are set: an Angle's arm holds two, whoever drew it; a held point one, none for a point of
    /// another picture or tool, which the next Set point drops.
    func pointsSet(_ state: MarkCursorState, arm: AngleArm?) -> Int {
        if kind == .angle, arm != nil { return 2 }
        guard state.first != nil, state.scope == nil || state.scope == scope else { return 0 }
        return 1
    }

    /// The element's value: "Point 2 of 2, x 120, y 88 · 9744", with the status line's readout of the cursor's pixel.
    func spokenValue(_ state: MarkCursorState, arm: AngleArm?) -> String {
        let p = pixel(state)
        return MarkCursor.spokenValue(p, point: min(pointsSet(state, arm: arm) + 1, kind.pointCount), of: kind.pointCount,
                                      readout: ImageReadout.text(image, at: MarkCursor.imagePoint(p)))
    }

    /// The element's hint: which points Set point takes, in the order the drag takes them, in the Measure section's words.
    var hint: String {
        kind == .angle ? "Set point at the first arm's end, then at the vertex, then at the third point."
                       : "Set point at one end of the line, then at the other."
    }

    func placeAtCentre(_ state: inout MarkCursorState) {
        state.position = MarkCursor.centre(width: image.width, height: image.height)
    }

    func move(_ step: MarkCursor.Move, _ state: inout MarkCursorState) {
        state.position = MarkCursor.moved(pixel(state), by: step, width: image.width, height: image.height)
    }

    /// Set point: the first point is held; the next makes the mark through the drag's own calls (`MarkMaking`). A Distance or a
    /// Profile is added from the two points; an Angle's two become `arm` (A, the vertex), as the pointer's first drag leaves it, and
    /// the third, C, closes it as the click does, whoever drew the arm. A point held for another picture or tool is dropped first.
    func setPoint(_ state: inout MarkCursorState, arm: inout AngleArm?) -> MarkCursorOutcome {
        state.adopt(scope)
        let here = MarkCursor.imagePoint(pixel(state))
        if kind == .angle, let held = arm {
            guard here != held.vertex else { return .samePlace }
            // Every finished angle starts the next afresh, also when the arm was the pointer's and a point was held before it.
            state.first = nil
            arm = nil
            return Self.outcome(MarkMaking.angle(held, third: here, on: image, in: measurements))
        }
        guard let start = state.first else {
            state.first = here
            return .held(point: 1, of: kind.pointCount)
        }
        guard here != start else { return .samePlace }
        state.first = nil
        let refusal = MarkMaking.stroke(kind, from: start, to: here, arm: &arm, on: image, in: measurements)
        return kind == .angle ? .held(point: 2, of: kind.pointCount) : Self.outcome(refusal)
    }

    /// Clear points: the held point and an Angle's arm, whoever drew it, go, as Escape drops them. Nothing is added.
    func clearPoints(_ state: inout MarkCursorState, arm: inout AngleArm?) {
        state.first = nil
        arm = nil
    }

    private static func outcome(_ refusal: SessionLineage.Refusal?) -> MarkCursorOutcome {
        if let refusal { return .refused(refusal) }
        return .added
    }

    /// What VoiceOver hears after a Set point the value does not say: the mark added ("Added Distance, 12.43 nm, 50.02 pixels", the
    /// Measure section's words), or why nothing was set. nil when the value says it (a point held) or an alert does (a refusal).
    func announcement(_ outcome: MarkCursorOutcome) -> String? {
        switch outcome {
        case .added:
            guard let mark = measurements.mark(measurements.selection) else { return nil }
            return "Added " + MarkFormat.spoken(mark, x: image.x, y: image.y)
        case .samePlace:
            return "No point set: the point is where the last one is. Move it first."
        case .held, .refused:
            return nil
        }
    }
}

// MARK: - The Image room's element

/// The named actions on an element of their own at the cursor, while a measuring tool is chosen (the header says why not on the
/// pane). Forwards to `MarkCursorActions`; nothing here is drawn, and it takes no hits.
struct MarkCursorAccessibility: ViewModifier {
    let image: CalibratedImage
    let measurements: ImageMeasurements
    /// The chosen tool's kind of mark; nil with Pan, and there is no element.
    let kind: ImageMark.Kind?
    let basis: MarkCursorBasis
    /// The marks' map, which places the element on the cursor's pixel at the pane's zoom.
    let geometry: MarkGeometry
    @Binding var state: MarkCursorState
    @Binding var angleArm: AngleArm?
    /// Where a refused mark is said (`SessionPanels.markRefused`), as for a drawn one.
    @Environment(AppState.self) private var appState

    func body(content: Content) -> some View {
        content.overlay {
            if let kind {
                element(MarkCursorActions(image: image, measurements: measurements, kind: kind, basis: basis))
            }
        }
    }

    private func element(_ actions: MarkCursorActions) -> some View {
        let at = geometry.panePoint(of: MarkCursor.imagePoint(actions.pixel(state)))
        let pointsSet = actions.pointsSet(state, arm: angleArm)
        return Color.clear
            .frame(width: MarkCursor.elementSide, height: MarkCursor.elementSide)
            .accessibilityElement()
            .accessibilityLabel(MarkCursor.elementLabel(actions.kind))
            .accessibilityValue(actions.spokenValue(state, arm: angleArm))
            .accessibilityHint(actions.hint)
            .accessibilityAction(named: MarkCursor.placeActionName) { actions.placeAtCentre(&state) }
            .accessibilityAction(named: MarkCursor.Move.left.actionName) { actions.move(.left, &state) }
            .accessibilityAction(named: MarkCursor.Move.right.actionName) { actions.move(.right, &state) }
            .accessibilityAction(named: MarkCursor.Move.up.actionName) { actions.move(.up, &state) }
            .accessibilityAction(named: MarkCursor.Move.down.actionName) { actions.move(.down, &state) }
            .accessibilityAction(named: MarkCursorActions.setActionName) { setPoint(actions) }
            // Only while there is a point to drop, as Escape routes only then.
            .accessibilityActions {
                if pointsSet > 0 {
                    Button(MarkCursorActions.clearActionName) { clearPoints(actions) }
                }
            }
            .accessibilityIdentifier("image.markCursor")
            .position(MarkCursor.elementCentre(at, in: geometry.transform.paneSize))
            .allowsHitTesting(false)
    }

    /// Set point, then what the drag's end does with its answer: a refusal is said as for a drawn mark; a mark added is spoken.
    private func setPoint(_ actions: MarkCursorActions) {
        var cursor = state
        var arm = angleArm
        let outcome = actions.setPoint(&cursor, arm: &arm)
        if cursor != state { state = cursor }
        if arm != angleArm { angleArm = arm }
        if case .refused(let refusal) = outcome {
            SessionPanels.markRefused(refusal, .added, appState: appState)
        } else if let words = actions.announcement(outcome) {
            AccessibilityNotification.Announcement(words).post()
        }
    }

    /// Clear points, written only where something changed, and said.
    private func clearPoints(_ actions: MarkCursorActions) {
        var cursor = state
        var arm = angleArm
        actions.clearPoints(&cursor, arm: &arm)
        if cursor != state { state = cursor }
        if arm != angleArm { angleArm = arm }
        AccessibilityNotification.Announcement(MarkCursorActions.clearedAnnouncement).post()
    }
}
