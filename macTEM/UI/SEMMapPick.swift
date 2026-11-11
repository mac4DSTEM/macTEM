//
//  SEMMapPick.swift
//  Role: how the maps of the three SEM rooms (Patterns, Indexing with its Compare, Maps) pick a scan point, as mac4DSTEM's real-space
//        pane does (its `ImagePanes.swift` selection layer and crosshair, `RealSpacePointerPolicy`, `WorkspaceView`'s arrow keys;
//        D-SEM-110, which reverses design D4): a click or a drag on the map picks the point under the pointer and the pattern pane
//        follows the pick, streaming while the drag goes on; the pointer over the map only writes the status line. Zoomed in, a plain
//        drag pans and only the marker's grab handle moves the pick. The arrows step the pick (⇧ ten), and any press on a map gives the
//        room's root the keyboard, so they work right after a click (after a click in the Indexing room's Results table too).
//
//  THE POLICY (`SEMMapPointer`, pure, pinned by `SEMMapPointerTests`): who owns a plain press at a zoom, and the scan point under a pane
//  point. `MarkGeometry` puts a pixel's centre at an integer, so rounding gives each pixel the area it covers, as mac4DSTEM's floor does
//  with its centres at +0.5. A press beside the picture (zoomed out) picks nothing; a drag past the edge holds the edge's point.
//  THE VIEWS: `SEMMapScrubLayer` (the whole map picks, and in Maps ⌘-clicks; mounted only at 1× and below, so zoomed in the drag falls
//  through to the pan),
//  `SEMScanMarker` (mac4DSTEM's double-stroked circle at mac4DSTEM's sizes, drawn in pane points, so it keeps its size at any zoom; zoomed
//  in, the grab handle; for VoiceOver the pick itself, adjustable and with four named moves), `SEMMapPress` (a press anywhere on a map
//  gives the room the keyboard) and `SEMRoomFocus` (the keyboard half of the room's root, made explicit as `StackArrowKeys` is).
//  mac4DSTEM holds its own copy of the policy and the marker; MacEMUI taking them, so both apps hold one, is a follow-up.
//

import ShellControls
import ShellMetal
import SwiftUI
import TEMCore

// MARK: - The policy

/// Who owns a plain press on an SEM map, and which scan point a pane point picks: mac4DSTEM's `RealSpacePointerPolicy` on macTEM's
/// `MarkGeometry`. Pure, so a test pins it.
nonisolated enum SEMMapPointer {
    enum Mode: Equatable {
        /// At 1× and zoomed out: a click or a drag anywhere on the map picks (zoomed out there is nothing to pan to).
        case scrub
        /// Zoomed in: a plain drag pans, and the marker's grab handle moves the pick.
        case panAndGrab
    }

    /// The name of a map's coordinate space: its box, the pane points `MarkGeometry` maps. The scrub and the handle read their drags in
    /// it, so a click and a handle drag never disagree about the point under the pointer (a `.position`ed handle's `.local` is its own frame).
    static let space = "sem.map"

    /// mac4DSTEM's threshold: its epsilon absorbs the float error a pinch or a wheel notch leaves when it lands back on 1×.
    static func mode(zoom: CGFloat) -> Mode {
        zoom > 1 + 1e-4 ? .panAndGrab : .scrub
    }

    /// The scan point under pane point `p`, held inside the map `geometry` draws: a drag past the edge stays on the edge's point.
    static func position(at p: CGPoint, geometry: MarkGeometry) -> EBSDPosition {
        let q = geometry.imagePoint(atPanePoint: p)
        // Held as a Double first, so a point far off the picture never reaches Int's limits; a degenerate box (NaN) reads the first point.
        func index(_ v: Double, count: Int) -> Int {
            guard v.isFinite else { return 0 }
            return Int(min(max(v.rounded(), 0), Double(max(count - 1, 0))))
        }
        return EBSDPosition(row: index(q.y, count: geometry.imageHeight), column: index(q.x, count: geometry.imageWidth))
    }

    /// Whether pane point `p` lies on the picture, whose pixels span −0.5…W − 0.5 and −0.5…H − 0.5 in image coordinates.
    static func isOnImage(_ p: CGPoint, geometry: MarkGeometry) -> Bool {
        let q = geometry.imagePoint(atPanePoint: p)
        return q.x >= -0.5 && q.x <= Double(geometry.imageWidth) - 0.5 && q.y >= -0.5 && q.y <= Double(geometry.imageHeight) - 0.5
    }
}

// MARK: - The scrub

/// The whole map picks: a press on the picture picks the point under it, and the drag that follows streams the pick (the pattern pane
/// follows every point it crosses). Mounted only in the scrub mode, so zoomed in the plain drag falls through to the pane's pan. It takes
/// the clicks ZoomPan's double-click would see, so it fits on a double-click itself, as ZoomPan does.
///
/// The Maps room's ⌘-click (`commandClick`, macTEM#239) is the layer's own, simultaneous with the pick, not a gesture over it: an
/// ancestor's high-priority ⌘-tap would hold the pick back until the tap failed, and a ⌘-drag that failed it would pick and collapse
/// the grain selection. While ⌘ is down the drag picks nothing, and a ⌘-click on the picture calls `commandClick` with its point.
struct SEMMapScrubLayer: View {
    let geometry: MarkGeometry
    let zoomModel: PaneZoomModel
    let pick: (EBSDPosition) -> Void
    var commandClick: ((EBSDPosition) -> Void)? = nil
    @Environment(\.semRoomKeys) private var roomKeys
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Rectangle()
            .fill(Color.clear)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named(SEMMapPointer.space)).onChanged { value in
                roomKeys.take()
                // A press beside the picture (zoomed out) picks nothing, nor does the drag it starts; with ⌘ down it is a ⌘-click (below).
                guard SEMMapPointer.isOnImage(value.startLocation, geometry: geometry), !(commandClick != nil && Self.commandIsDown) else { return }
                pick(SEMMapPointer.position(at: value.location, geometry: geometry))
            })
            .simultaneousGesture(TapGesture(count: 2).onEnded { fit() })
            .simultaneousGesture(SpatialTapGesture(coordinateSpace: .named(SEMMapPointer.space)).modifiers(.command).onEnded { value in
                guard let commandClick, SEMMapPointer.isOnImage(value.location, geometry: geometry) else { return }
                commandClick(SEMMapPointer.position(at: value.location, geometry: geometry))
            }, including: commandClick == nil ? .none : .all)
            .accessibilityHidden(true)
    }

    /// Whether ⌘ is down at this event (`ModifierKeys`, the app layer's AppKit query): a drag's value carries no modifier keys.
    private static var commandIsDown: Bool { ModifierKeys.commandIsDown }

    /// Back to 1×, animated unless the reader asked for Reduce Motion, as ZoomPan's own double-click.
    private func fit() {
        if reduceMotion {
            zoomModel.fit()
        } else {
            withAnimation(.snappy) { zoomModel.fit() }
        }
    }
}

// MARK: - The marker

/// The picked point: mac4DSTEM's marker, a white circle over a dark halo that reads on any map, drawn in pane points so it keeps its size
/// at any zoom. Zoomed in it is the grab handle, larger and with a white centre, the one way a drag moves the pick there; otherwise it
/// takes no hits and the scrub layer under it picks. For VoiceOver it is the pick: adjustable (increment right, decrement left) and with
/// the four moves by name, the twin of a click and of the arrows.
struct SEMScanMarker: View {
    let position: EBSDPosition
    let geometry: MarkGeometry
    /// Zoomed in (`SEMMapPointer.Mode.panAndGrab`): the grab handle.
    let isHandle: Bool
    let identifier: String
    let pick: (EBSDPosition) -> Void
    let step: (EBSDPosition.Direction) -> Void
    @Environment(\.semRoomKeys) private var roomKeys

    /// mac4DSTEM's values (ImagePanes.swift, the crosshair): white 1.5 pt over black 0.75 at 3.5 pt, 11 pt across; the handle 20 pt across
    /// with a 12 pt white centre edged in black 0.6 at 1 pt. No division by the zoom: macTEM draws the marker outside the zoomed layer.
    static let diameter: CGFloat = 11
    static let handleDiameter: CGFloat = 20
    static let handleCentre: CGFloat = 12
    static let lineWidth: CGFloat = 1.5
    static let haloWidth: CGFloat = 3.5
    static let haloOpacity = 0.75
    static let handleEdgeOpacity = 0.6
    static let handleEdgeWidth: CGFloat = 1

    var body: some View {
        let side = isHandle ? Self.handleDiameter : Self.diameter
        ZStack {
            if isHandle {
                Circle().fill(Color.white)
                    .overlay(Circle().stroke(Color.black.opacity(Self.handleEdgeOpacity), lineWidth: Self.handleEdgeWidth))
                    .frame(width: Self.handleCentre, height: Self.handleCentre)
            }
            Circle().stroke(Color.black.opacity(Self.haloOpacity), lineWidth: Self.haloWidth)
            Circle().stroke(Color.white, lineWidth: Self.lineWidth)
        }
        .frame(width: side, height: side)
        .contentShape(Circle())
        // In the map's own space, as the scrub: `.local` here would be the handle's own frame.
        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named(SEMMapPointer.space)).onChanged { value in
            roomKeys.take()
            pick(SEMMapPointer.position(at: value.location, geometry: geometry))
        }, including: isHandle ? .all : .none)
        .allowsHitTesting(isHandle)
        .accessibilityElement()
        .accessibilityLabel("Picked point")
        .accessibilityValue("row \(position.row), column \(position.column)")
        .accessibilityHint("Adjust to move left or right, or use the named actions to move in any direction")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: step(.right)
            case .decrement: step(.left)
            @unknown default: break
            }
        }
        .accessibilityAction(named: "Move left") { step(.left) }
        .accessibilityAction(named: "Move right") { step(.right) }
        .accessibilityAction(named: "Move up") { step(.up) }
        .accessibilityAction(named: "Move down") { step(.down) }
        .accessibilityIdentifier(identifier)
        .position(geometry.panePoint(of: ImagePoint(x: Double(position.column), y: Double(position.row))))
    }
}

// MARK: - The keyboard

/// Gives an SEM room's root the keyboard. `SEMRoomFocus` puts it in the environment; outside an SEM room it does nothing.
struct SEMRoomKeys {
    let take: () -> Void
}

extension EnvironmentValues {
    @Entry var semRoomKeys = SEMRoomKeys(take: {})
}

/// A press anywhere on a map's pane (a click, the start of a pan, the handle, ⌘-click) gives the room's root the keyboard. SIMULTANEOUS
/// and on the pane, an ancestor of the map's own gestures, as `FFTPanePress`: inside the map it would be a child gesture of ZoomPan's
/// and could take the pan; here the pick, the pan and the double-click are not disturbed.
struct SEMMapPress: ViewModifier {
    @Environment(\.semRoomKeys) private var roomKeys

    func body(content: Content) -> some View {
        content.simultaneousGesture(DragGesture(minimumDistance: 0).onChanged { _ in roomKeys.take() })
    }
}

/// The keyboard half of an SEM room's root (`PatternsKeyedRoom`, `IndexingKeyedRoom`, `MapsKeyedRoom` add the arrows): the one focusable
/// container (the arrangement of `PaneKeys.swift`), the window's default focus while nothing else claims it, and given the keyboard
/// explicitly by a press on the room's map (`SEMRoomKeys`) rather than left to SwiftUI's defaults, as `StackArrowKeys` does.
///
/// Bound to a value, not a Bool: a Bool bound with `focused(_:)` reads true while a focusable descendant has the keyboard (the Indexing
/// room's Results or Bands table, the Maps room's Grains table or bottom-pane picker; Apple's `FocusState`, "Nest focusable views"), so
/// a click on the map would leave the arrows with the table. `focused(_:equals:)` reads `.room` only while the root itself has it.
struct SEMRoomFocus: ViewModifier {
    enum Target: Hashable { case room }
    @FocusState private var focus: Target?
    /// ⌘C while the container has the keys (the Indexing room: the picked point's Results row); nil leaves Edit › Copy off. On the
    /// focusable view itself, as `ImageKeyedRoom` places its copy: applied around the focus modifiers it was never asked (drive,
    /// 2026-11-11: the arrows reached the container, ⌘C did nothing).
    var copy: (() -> [NSItemProvider])? = nil

    func body(content: Content) -> some View {
        content
            .focusable()
            .focusEffectDisabled()   // DEVIATION as `FFTKeyedRoom`'s, named there
            .onCopyCommand(perform: copy)
            .focused($focus, equals: .room)
            // The DEFAULT focus: the room has the keyboard when nothing else claims it, and never takes it from a field the person is in.
            .defaultFocus($focus, .room)
            .environment(\.semRoomKeys, SEMRoomKeys { if focus != .room { focus = .room } })
    }
}
