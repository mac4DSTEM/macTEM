//
//  ToolbarDisplay.swift
//  Role: what the toolbar's centre shows, built from the window's state as plain values (ShellLayout's `ToolbarDisplayState`): nothing
//        without a document, "file · room · size" while the shown room is idle, the running work and its clock while it is busy, and
//        another room's run while the shown room is idle. `ContentView` hands it to ShellLayout's `ToolbarRunDisplay`; a test calls it
//        on a window's state, so the line is held by what it shows rather than by the text of the view.
//

import ShellEDXModel
import ShellLayout
import ShellSpectroscopy
import TEMCore
import TEMSession

/// The toolbar's centre line of a window (`state`).
enum ToolbarDisplay {
    /// What the toolbar's centre shows: nothing without a document or while it loads; the running work while busy (`BusyOperation`);
    /// else "file · room · size". While the shown room is idle and another room's run goes on, that run under its room's name, with its
    /// fraction and clock (`BusyOperation.backgroundRoom`), so the window never reads idle while it works.
    @MainActor
    static func state(_ appState: AppState) -> ToolbarDisplayState? {
        let room = appState.navigation.workspaceArea
        if let other = BusyOperation.backgroundRoom(appState), let operation = BusyOperation.backgroundOperation(room: other, appState: appState) {
            return .busy(operation: operation, progress: RoomProgress.fraction(room: other, appState: appState),
                         metrics: { now in RunClock.reading(since: appState.busySince[other], progress: RoomProgress.fraction(room: other, appState: appState), now: now) })
        }
        switch room {
        case .edx, .eels:
            guard !appState.windowTitle.isEmpty, appState.windowTitle != "macTEM" else { return nil }
            let busy = room == .edx ? appState.edx.isBusy : appState.eels.isBusy
            if busy {
                return .busy(operation: BusyOperation.name(room: room, appState: appState) ?? room.title, progress: RoomProgress.fraction(room: room, appState: appState),
                             metrics: { now in RunClock.reading(since: appState.busySince[room], progress: RoomProgress.fraction(room: room, appState: appState), now: now) })
            }
            let detail = room == .edx ? EDXRoomFormat.capsuleDetail(appState.edx) : "spectrum image"
            return .idle(file: appState.windowTitle, room: room.title, detail: detail, help: nil)
        case .patterns:
            let session = appState.ebsd
            guard let dataset = session.dataset else { return nil }
            if let operation = BusyOperation.toolbarOperation(room: room, appState: appState) {
                return .busy(operation: operation, progress: RoomProgress.fraction(room: room, appState: appState),
                             metrics: { now in RunClock.reading(since: appState.busySince[room], progress: RoomProgress.fraction(room: room, appState: appState), now: now) })
            }
            return .idle(file: session.fileName, room: room.title, detail: EBSDBrowsing.capsuleDetail(dataset), help: "Scan rows × columns of pattern rows × columns")
        case .indexing:
            let session = appState.indexing
            guard let dataset = session.patterns.dataset else { return nil }
            if session.isBusy {
                // "Hough · 2340 of 4125", "Dictionary · 1 of 3 chunks · NCC" (`BusyOperation.indexingLine`).
                return .busy(operation: BusyOperation.indexingLine(session, dataset: dataset), progress: RoomProgress.fraction(room: room, appState: appState),
                             metrics: { now in RunClock.reading(since: appState.busySince[room], progress: RoomProgress.fraction(room: room, appState: appState), now: now) })
            }
            // The open of the scan is this room's work too while it is shown (`BusyOperation.isBusy`): the open's own line, as Patterns reads.
            if session.patterns.isOpening, let operation = BusyOperation.toolbarOperation(room: .patterns, appState: appState) {
                return .busy(operation: operation, progress: nil,
                             metrics: { now in RunClock.reading(since: appState.busySince[.patterns], progress: nil, now: now) })
            }
            return .idle(file: session.patterns.fileName, room: room.title, detail: EBSDBrowsing.capsuleDetail(dataset), help: "Scan rows × columns of pattern rows × columns")
        case .maps:
            let session = appState.maps
            // The open, Segment, the texture or a layer's picture; none reports a fraction.
            if let operation = BusyOperation.toolbarOperation(room: room, appState: appState) {
                return .busy(operation: operation, progress: nil,
                             metrics: { now in RunClock.reading(since: appState.busySince[room], progress: nil, now: now) })
            }
            guard let map = session.map else { return nil }
            return .idle(file: session.fileName, room: room.title, detail: MapsRoomFormat.capsuleDetail(map), help: "Map rows × columns and its indexed phases")
        default:
            guard !appState.imageSession.isLoading, let image = appState.imageSession.image else { return nil }
            return .idle(file: image.fileName, room: room.title, detail: "\(image.width) × \(image.height) px", help: nil)
        }
    }
}
