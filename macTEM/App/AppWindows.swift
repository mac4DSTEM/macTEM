//
//  AppWindows.swift
//  Role: the app's windows, as their states: one `AppState` per window (one file per window, 2026-11-10, as mac4DSTEM has one
//        dataset per window), and what the app must know across them. Three jobs, all plain bookkeeping with no science:
//          1. the window a Finder open or a File-menu action goes to (`front`: the window last brought forward);
//          2. the question at quit, over every window (`quitQuestion`);
//          3. nothing is lost by closing a window: a window closed with marks not saved to their session file, or with a room
//             still working, is PARKED, not released, and the next window made takes it over (`stateForNewWindow`). The single
//             window made the same promise by keeping its state on the app (ADR 007); with several windows the registry keeps it.
//             A window closed with nothing to lose lets go of its files at once.
//        The launch arguments' documents (`--demo-…`, `--open`) open in the first window only (`launchOptionsForNewWindow`).
//

import Foundation
import Observation

@MainActor
@Observable
final class AppWindows {
    /// The windows on screen, in the order they appeared.
    private(set) var open: [AppState] = []
    /// Windows closed with something to lose, oldest first: kept until a new window takes them over, or the quit question is answered.
    private(set) var parked: [AppState] = []
    /// The window last brought forward; nil when none is open.
    private(set) weak var front: AppState?
    /// The launch arguments' documents have gone to a window.
    @ObservationIgnored private var launchDocumentsTaken = false

    /// A window appeared (or came back): it is known, and it is the front one.
    func enroll(_ state: AppState) {
        parked.removeAll { $0 === state }
        if !open.contains(where: { $0 === state }) { open.append(state) }
        front = state
    }

    /// A window was brought forward.
    func bringForward(_ state: AppState) {
        guard open.contains(where: { $0 === state }) else { return }
        front = state
    }

    /// A window closed: parked when closing it would lose something (`AppState.quitQuestion`), released otherwise.
    func withdraw(_ state: AppState) {
        open.removeAll { $0 === state }
        if front === state { front = open.last }
        if state.quitQuestion != nil, !parked.contains(where: { $0 === state }) { parked.append(state) }
    }

    /// The state a new window shows: the oldest parked one, so what a closed window held comes back with the next window, else a new one.
    func stateForNewWindow(make: () -> AppState) -> AppState {
        parked.isEmpty ? make() : parked.removeFirst()
    }

    /// The launch options a new window's state is made with: the launch's own for the first window, and for every later one the
    /// same without its documents (a second window must not open the demo or the `--open` files again).
    func launchOptionsForNewWindow(_ launch: LaunchOptions = LaunchOptions()) -> LaunchOptions {
        defer { launchDocumentsTaken = true }
        return launchDocumentsTaken ? launch.withoutDocuments : launch
    }

    /// What quitting would lose, over every window open or parked; nil when nothing.
    var quitQuestion: String? {
        let states = open + parked
        return CloseGuard.question(dirtyFiles: states.flatMap(\.unsavedFileNames),
                                   busyRooms: states.flatMap(\.busyRooms).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } })
    }
}

extension AppState {
    /// The open files whose marks are not saved to their session file, by the sidebar's titles (the quit question's names).
    var unsavedFileNames: [String] {
        let titles = openItems.displayTitles
        return openItems.items.filter { $0.measurements.isDirty }.map { titles[$0.id] ?? $0.url.lastPathComponent }
    }
}
