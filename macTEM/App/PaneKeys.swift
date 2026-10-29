//
//  PaneKeys.swift
//  Role: the keys of the FFT room's and the Image room's panes — arrows, Delete, ⌘C and Escape — and Edit > Copy and
//        Delete, all through ONE routing function per room (open-items "Arrows, ⌫ and ⌘C on a pane do nothing"; design:
//        archive: pane-keys-2026-10-15/design.md).
//
//  WHY ONE CONTAINER PER ROOM: the panes' own focusable leaves (`.focusable()` + `@FocusState` + `.onMoveCommand`…) never
//  held focus in this shell — focus was granted and withdrawn within the click — while a room-level focusable ancestor with
//  `.onKeyPress` does receive ←, → and ⌫ (Gate D step 2, experiment E2, 2 of 2; archive: pane-keys-gate-d-2026-10-14/).
//  This is mac4DSTEM's arrangement (`WorkspaceView`: `.focusable().focusEffectDisabled().onKeyPress(phases: .down)` on the
//  pane container). The room's root carries it (`FFTKeyedRoom`, `ImageKeyedRoom` below); the panes hold no focus, no
//  `@FocusState` and no `on…Command`; a pane that has been pressed tells the room which pane the keys are for.
//
//  THE PURE PART (`PaneKey`, `PaneKeyAction`, `PaneKeyRouter`): a key plus the room's selection state gives the action, or
//  nil — not ours, so the press goes on. Nothing in it touches a view, so a test pins every row of the table.
//  THE PERFORMERS (`FFTRoomKeys`, `ImageRoomKeys`): build the state from the owners, route, and do. The key press and the
//  Edit menu go through the SAME `handle`, and the menu items are enabled exactly when the router has an action for them.
//
//  EDIT > COPY AND DELETE are the system's items, validated through the responder chain: the container's `onCopyCommand` /
//  `onDeleteCommand` take an optional action, and nil (no action for the key in this state) disables the item. A custom
//  `CommandGroup(replacing: .pasteboard)` would take Copy from the inspector's text fields (a focused scene value outlives the
//  room's focus), and a focused value may not hold closures (swiftui-specialist, environment.md).
//
//  APPKIT is used here for `NSPasteboard` only (the key path of ⌘C; the menu path hands the system an `NSItemProvider`).
//

import SwiftUI
import AppKit
import TEMCore
import TEMSession

// MARK: - The pure part

/// A key a pane answers. Built from a SwiftUI key press's key and modifiers (`init?(key:modifiers:)`, pure, so a test
/// builds one without a `KeyPress`).
nonisolated enum PaneKey: Equatable {
    case arrow(MoveCommandDirection)
    case delete
    case copy
    case escape

    /// nil for any other key, and for these with a modifier they do not take: an arrow takes ⇧ (ten pixels), ⌘C takes ⌘ alone,
    /// ⌫ and Escape none. Only the four real modifiers count: a real arrow press carries the numeric-pad and function flags
    /// (raw 96, ⇧← 98) and Forward Delete the function flag (64), as the refuter measured on a hosted view; Caps Lock too is
    /// not a modifier of the key.
    init?(key: KeyEquivalent, modifiers: EventModifiers) {
        let held = modifiers.intersection([.shift, .control, .option, .command])
        switch key {
        case .leftArrow where held.isSubset(of: .shift): self = .arrow(.left)
        case .rightArrow where held.isSubset(of: .shift): self = .arrow(.right)
        case .upArrow where held.isSubset(of: .shift): self = .arrow(.up)
        case .downArrow where held.isSubset(of: .shift): self = .arrow(.down)
        case .delete where held.isEmpty, .deleteForward where held.isEmpty: self = .delete
        case .escape where held.isEmpty: self = .escape
        case KeyEquivalent("c") where held == .command: self = .copy
        default: return nil
        }
    }

    /// Only an arrow repeats while held, as `onMoveCommand` did; ⌫ and ⌘C fire once per press.
    var repeats: Bool {
        if case .arrow = self { return true }
        return false
    }

    /// The press's key, modifiers and phase read to the key it is for, or nil when it is not ours (or a repeat of a key that
    /// does not repeat). The one reading both rooms' `handle(_ press:)` use, so a test pins it without a `KeyPress`.
    static func read(key: KeyEquivalent, modifiers: EventModifiers, isRepeat: Bool) -> (key: PaneKey, shift: Bool)? {
        guard let pane = PaneKey(key: key, modifiers: modifiers), !isRepeat || pane.repeats else { return nil }
        return (pane, modifiers.contains(.shift))
    }
}

/// What a key does in a room.
nonisolated enum PaneKeyAction: Equatable {
    case nudgeRegion(MoveCommandDirection, step: Int)
    case clearRegion
    case deleteSpot
    case copySpot
    case deleteMark
    case copyMark
    case cancelAngle
}

/// The FFT room's two panes: the keys are for the one pressed last.
nonisolated enum FFTKeyPane: Equatable {
    case source
    case spectrum
}

/// What the FFT room's keys depend on.
nonisolated struct FFTKeyState: Equatable {
    /// The pane pressed last; nil until a pane has been pressed (the keys are then for neither).
    var active: FFTKeyPane?
    /// The source pane shows the file (the Original view) and a region exists: the outline is there to move or clear.
    var regionShown: Bool
    /// The spectrum is shown and a spot on it is selected.
    var spotSelected: Bool
}

/// What the Image room's keys depend on.
nonisolated struct ImageKeyState: Equatable {
    var markSelected: Bool
    /// An angle whose first arm is drawn, waiting for its third point.
    var angleInProgress: Bool
}

nonisolated enum PaneKeyRouter {
    /// Source pane: the arrows nudge the region (⇧ ten pixels), ⌫ clears it. Spectrum pane: ⌫ deletes the selected spot, ⌘C
    /// copies its line. Anything else, or the other pane, is nil.
    static func fft(_ key: PaneKey, shift: Bool, state: FFTKeyState) -> PaneKeyAction? {
        switch (key, state.active) {
        case (.arrow(let direction), .source?):
            return state.regionShown ? .nudgeRegion(direction, step: shift ? 10 : 1) : nil
        case (.delete, .source?):
            return state.regionShown ? .clearRegion : nil
        case (.delete, .spectrum?):
            return state.spotSelected ? .deleteSpot : nil
        case (.copy, .spectrum?):
            return state.spotSelected ? .copySpot : nil
        default:
            return nil
        }
    }

    /// ⌫ and ⌘C act on the selected mark; Escape drops an angle that is in progress. The arrows are not the Image room's.
    static func image(_ key: PaneKey, state: ImageKeyState) -> PaneKeyAction? {
        switch key {
        case .delete: state.markSelected ? .deleteMark : nil
        case .copy: state.markSelected ? .copyMark : nil
        case .escape: state.angleInProgress ? .cancelAngle : nil
        case .arrow: nil
        }
    }
}

// MARK: - The pasteboard

/// Where a ⌘C that arrives as a key writes its text. The system's general pasteboard in the app; a test passes its own, so
/// no test touches the owner's clipboard.
@MainActor
protocol PaneTextWriter {
    func write(_ text: String)
}

struct SystemPaneTextWriter: PaneTextWriter {
    func write(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}

// MARK: - The FFT room

/// The FFT room's keys, built from the owner at the moment of use.
@MainActor
struct FFTRoomKeys {
    let analysis: FFTAnalysis
    var active: FFTKeyPane?
    /// The file's size, which the region is held inside (the Original view draws the region, and shows the file).
    var sourceSize: (width: Int, height: Int)
    var writer: any PaneTextWriter = SystemPaneTextWriter()

    var state: FFTKeyState {
        let selected = analysis.selection.flatMap { id in analysis.spots.first { $0.id == id } }
        return FFTKeyState(active: active,
                           regionShown: analysis.sourceView == .original && analysis.region != nil,
                           spotSelected: selected != nil && analysis.spectrum != nil && analysis.spectrumFailure == nil)
    }

    func route(_ key: PaneKey, shift: Bool = false) -> PaneKeyAction? {
        PaneKeyRouter.fft(key, shift: shift, state: state)
    }

    /// Edit > Copy and Delete are enabled exactly when the keys would act.
    var canCopy: Bool { route(.copy) != nil }
    var canDelete: Bool { route(.delete) != nil }

    /// A key press, or an Edit menu item: true when it was ours and was done.
    @discardableResult
    func handle(_ key: PaneKey, shift: Bool = false) -> Bool {
        guard let action = route(key, shift: shift) else { return false }
        perform(action)
        return true
    }

    /// A key press, as its parts (a test has no `KeyPress`): ours and done is `.handled`.
    func handle(key: KeyEquivalent, modifiers: EventModifiers, isRepeat: Bool = false) -> KeyPress.Result {
        guard let read = PaneKey.read(key: key, modifiers: modifiers, isRepeat: isRepeat) else { return .ignored }
        return handle(read.key, shift: read.shift) ? .handled : .ignored
    }

    /// A SwiftUI key press.
    func handle(_ press: KeyPress) -> KeyPress.Result {
        handle(key: press.key, modifiers: press.modifiers, isRepeat: press.phase == .repeat)
    }

    private func perform(_ action: PaneKeyAction) {
        switch action {
        case .nudgeRegion(let direction, let step):
            guard let region = analysis.region else { return }
            analysis.setRegion(FFTRegionGeometry.nudged(region, direction, step: step, width: sourceSize.width, height: sourceSize.height),
                               committed: true)
        case .clearRegion:
            analysis.setRegion(nil, committed: true)
        case .deleteSpot:
            if let id = analysis.selection { analysis.removeSpot(id) }
        case .copySpot:
            if let text = copyText() { writer.write(text) }
        case .deleteMark, .copyMark, .cancelAngle:
            break
        }
    }

    /// The selected spot's line, with what was transformed (`FFTPaneFormat.copyLine`).
    func copyText() -> String? {
        guard let id = analysis.selection, let spot = analysis.spots.first(where: { $0.id == id }),
              let spectrum = analysis.spectrum else { return nil }
        let subject = FFTPaneFormat.subject(crop: spectrum.key.crop, width: spectrum.width, height: spectrum.height)
        return FFTPaneFormat.copyLine(spot, subject: subject)
    }

    /// What Edit > Copy hands the system: the same line, or nothing when the keys would not copy.
    func copyProviders() -> [NSItemProvider] {
        guard canCopy, let text = copyText() else { return [] }
        return [NSItemProvider(object: text as NSString)]
    }
}

/// The FFT room's root: focusable, key-pressed, and the owner of Edit > Copy and Delete for the room.
struct FFTKeyedRoom: ViewModifier {
    let analysis: FFTAnalysis
    let imageWidth: Int
    let imageHeight: Int
    @Binding var active: FFTKeyPane?

    func body(content: Content) -> some View {
        let keys = FFTRoomKeys(analysis: analysis, active: active, sourceSize: (imageWidth, imageHeight))
        return content
            .focusable()
            // DEVIATION (deliberate, mac4DSTEM's arrangement): no focus ring. The container is the whole room, and a room-sized
            // ring on every click would be wrong; the cost is that Full Keyboard Access shows no ring on this stop. The
            // inspector's controls stay reachable by Tab, and the keys here are the pointer's companions (design.md).
            .focusEffectDisabled()
            // A held arrow repeats, as `onMoveCommand` did; ⌫ and ⌘C do not (`PaneKey.repeats`).
            .onKeyPress(phases: [.down, .repeat]) { keys.handle($0) }
            .onCopyCommand(perform: keys.canCopy ? { keys.copyProviders() } : nil)
            .onDeleteCommand(perform: keys.canDelete ? { _ = keys.handle(.delete) } : nil)
    }
}

/// A pane that says, on any press inside it (picture, header or footer, a click or the start of a pan), that the room's keys are
/// now for it. SIMULTANEOUS, so the region's and ZoomPan's own gestures are not disturbed; written only when it changes.
struct FFTPanePress: ViewModifier {
    let pane: FFTKeyPane
    @Binding var keyPane: FFTKeyPane?

    func body(content: Content) -> some View {
        content.simultaneousGesture(DragGesture(minimumDistance: 0).onChanged { _ in
            if keyPane != pane { keyPane = pane }
        })
    }
}

// MARK: - The Image room

/// An angle whose first arm is drawn, waiting for its third point.
nonisolated struct AngleArm: Equatable {
    var a: ImagePoint
    var vertex: ImagePoint
}

/// The Image room's keys, built from the owner at the moment of use.
@MainActor
struct ImageRoomKeys {
    let measurements: ImageMeasurements
    /// The text a mark is copied as (the Measure section's value).
    let label: (ImageMark) -> String
    var angleInProgress: Bool
    let cancelAngle: () -> Void
    var writer: any PaneTextWriter = SystemPaneTextWriter()

    var state: ImageKeyState {
        ImageKeyState(markSelected: measurements.mark(measurements.selection) != nil, angleInProgress: angleInProgress)
    }

    func route(_ key: PaneKey) -> PaneKeyAction? {
        PaneKeyRouter.image(key, state: state)
    }

    var canCopy: Bool { route(.copy) != nil }
    var canDelete: Bool { route(.delete) != nil }

    @discardableResult
    func handle(_ key: PaneKey) -> Bool {
        guard let action = route(key) else { return false }
        perform(action)
        return true
    }

    func handle(key: KeyEquivalent, modifiers: EventModifiers) -> KeyPress.Result {
        guard let read = PaneKey.read(key: key, modifiers: modifiers, isRepeat: false) else { return .ignored }
        return handle(read.key) ? .handled : .ignored
    }

    func handle(_ press: KeyPress) -> KeyPress.Result {
        handle(key: press.key, modifiers: press.modifiers)
    }

    private func perform(_ action: PaneKeyAction) {
        switch action {
        case .deleteMark:
            if let id = measurements.selection { measurements.remove(id) }
        case .copyMark:
            if let text = copyText() { writer.write(text) }
        case .cancelAngle:
            cancelAngle()
        case .nudgeRegion, .clearRegion, .deleteSpot, .copySpot:
            break
        }
    }

    func copyText() -> String? {
        measurements.mark(measurements.selection).map(label)
    }

    func copyProviders() -> [NSItemProvider] {
        guard canCopy, let text = copyText() else { return [] }
        return [NSItemProvider(object: text as NSString)]
    }
}

/// The Image room's root: focusable, key-pressed, and the owner of Edit > Copy and Delete for the room.
struct ImageKeyedRoom: ViewModifier {
    let image: CalibratedImage
    let measurements: ImageMeasurements
    @Binding var angleArm: AngleArm?

    func body(content: Content) -> some View {
        let x = image.x, y = image.y
        let arm = $angleArm
        let keys = ImageRoomKeys(measurements: measurements, label: { MarkFormat.value($0, x: x, y: y) },
                                 angleInProgress: arm.wrappedValue != nil, cancelAngle: { arm.wrappedValue = nil })
        return content
            .focusable()
            .focusEffectDisabled()   // DEVIATION as `FFTKeyedRoom`'s, named there
            .onKeyPress(phases: .down) { keys.handle($0) }
            .onCopyCommand(perform: keys.canCopy ? { keys.copyProviders() } : nil)
            .onDeleteCommand(perform: keys.canDelete ? { _ = keys.handle(.delete) } : nil)
    }
}
