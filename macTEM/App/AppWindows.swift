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
import TEMSession

@MainActor
@Observable
final class AppWindows {
    /// The windows on screen, in the order they appeared.
    private(set) var onScreen: [AppState] = []
    /// Windows closed with something to lose, oldest first: kept until a new window takes them over, or the quit question is answered.
    private(set) var parked: [AppState] = []
    /// The window last brought forward; nil when none is open.
    private(set) weak var front: AppState?
    /// The launch arguments' documents have gone to a window.
    @ObservationIgnored private var launchDocumentsTaken = false
    /// A Finder open that arrived with no window on screen.
    @ObservationIgnored private var waitingURLs: [URL] = []

    /// A window appeared (or came back): it is known, and it is the front one.
    func enroll(_ state: AppState) {
        parked.removeAll { $0 === state }
        if !onScreen.contains(where: { $0 === state }) { onScreen.append(state) }
        front = state
    }

    /// A window was brought forward.
    func bringForward(_ state: AppState) {
        guard onScreen.contains(where: { $0 === state }) else { return }
        front = state
    }

    /// A window closed: parked when closing it would lose something (`AppState.quitQuestion`), released otherwise.
    func withdraw(_ state: AppState) {
        onScreen.removeAll { $0 === state }
        if front === state { front = onScreen.last }
        if state.quitQuestion != nil, !parked.contains(where: { $0 === state }) { parked.append(state) }
    }

    /// A Finder open's batch (`OpenURLRelay`): into the window in front, else the newest; with no window on screen it waits for the
    /// one the open brings up (`takeWaitingURLs`).
    func deliver(urls: [URL]) {
        if let target = front ?? onScreen.last { target.open(urls: urls) } else { waitingURLs.append(contentsOf: urls) }
    }

    /// The files that arrived while no window was on screen, once.
    func takeWaitingURLs() -> [URL]? {
        guard !waitingURLs.isEmpty else { return nil }
        defer { waitingURLs = [] }
        return waitingURLs
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
        let states = onScreen + parked
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
