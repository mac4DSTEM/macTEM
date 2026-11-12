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
//        One file per window: a file opened into a window that holds one already gets a tab of its own (`openInTabs`).
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
    /// The batches waiting for a window, oldest first, each taken by one new window (`takeWaitingURLs`): a Finder open that arrived
    /// with no window on screen, and each file that gets a tab of its own (`openInTabs`).
    @ObservationIgnored private var waiting: [[URL]] = []
    /// Opens another window of the scene (SwiftUI's `openWindow`, handed over by a window on screen: only a view has it). Nil until
    /// a window has appeared; files then open in the window they were given to (`canOpenTabs`).
    @ObservationIgnored var openWindow: (() -> Void)?
    var canOpenTabs: Bool { openWindow != nil }
    /// Windows asked for by `openInTabs` that have not come up yet: each one, when it enters its window, is put in the front
    /// window's tab group (`takeTabRequest`, `WindowTabbing`). A window from File > New Window or a restored launch is not.
    @ObservationIgnored private var tabRequests = 0
    /// The app is quitting (`AppDelegate`): the windows closing on the way out leave the last-session record as it is, so it keeps
    /// every window's files, not the last one's (driven 2026-11-10: Reopen Last Session brought back one of two files).
    @ObservationIgnored var isTerminating = false

    /// A window appeared (or came back): it is known, and it is the front one.
    func enroll(_ state: AppState) {
        parked.removeAll { $0 === state }
        if !onScreen.contains(where: { $0 === state }) { onScreen.append(state) }
        state.windows = self
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
        state.windows = nil
        state.showWindow = nil
        if front === state { front = onScreen.last }
        if state.quitQuestion != nil, !parked.contains(where: { $0 === state }) { parked.append(state) }
        // The last-session record follows the windows still on screen; with none left it keeps what the last one held. Not while
        // quitting: every window closes then, and the record must keep them all.
        if !isTerminating { (front ?? onScreen.last)?.recordLastSession() }
    }

    /// The window really closed (AppKit's `willClose`, from `WindowTabbing`; not a tab moving behind another): a state with nothing to
    /// lose lets go of its files now, as the header promises. SwiftUI keeps a closed window's state alive in its scene list (12 Nov
    /// memgraph after closing the 375 MB SEM TIFF's tab: the 1.5 GB pixels <- ImagePresentation <- OpenItem <- OpenItems.selected <-
    /// AppState <- AppWindows.openWindow's context), so a state left holding them keeps them for the app's life. A state parked for
    /// what it would lose keeps everything; nothing is released while the app quits.
    func windowWillClose(_ state: AppState) {
        guard !isTerminating, state.quitQuestion == nil else { return }
        state.releaseFiles()
    }

    /// Each file in a tab of its own (one file per window): a file a window on screen holds already comes forward there, not read
    /// twice; every other waits as a batch of one for the window opened for it (`takeWaitingURLs`). The system makes that window a
    /// tab of the one in front (`WindowTabbing`).
    func openInTabs(_ urls: [URL]) {
        for url in urls {
            if let holder = holder(of: url) {
                holder.open(urls: [url])
                holder.showWindow?()
            } else if let openWindow {
                waiting.append([url])
                tabRequests += 1
                openWindow()
            }
        }
    }

    /// The window on screen that holds `url` already, by its standardised path; nil when none does.
    func holder(of url: URL) -> AppState? {
        let path = url.standardizedFileURL.path
        return onScreen.first { $0.heldFiles.contains(path) }
    }

    /// A Finder open's batch (`OpenURLRelay`): into the window in front, else the newest; with no window on screen it waits for the
    /// one the open brings up (`takeWaitingURLs`).
    func deliver(urls: [URL]) {
        if let target = front ?? onScreen.last { target.open(urls: urls) } else { waiting.append(urls) }
    }

    /// Whether the window coming up was asked for as a tab (`openInTabs`), once per request.
    func takeTabRequest() -> Bool {
        guard tabRequests > 0 else { return false }
        tabRequests -= 1
        return true
    }

    /// The oldest batch waiting for a window, once: a new window takes one.
    func takeWaitingURLs() -> [URL]? {
        waiting.isEmpty ? nil : waiting.removeFirst()
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
    /// Closes every file this window holds (images, the spectrum images, the EBSD dataset), letting go of their pixels: its window closed
    /// with nothing to lose (`AppWindows.windowWillClose`).
    func releaseFiles() {
        for id in openItems.items.map(\.id) { openItems.close(id) }
        eels.close()
        edx.close()
        ebsd.close()
    }

    /// The open files whose marks are not saved to their session file, by the sidebar's titles (the quit question's names).
    var unsavedFileNames: [String] {
        let titles = openItems.displayTitles
        return openItems.items.filter { $0.measurements.isDirty }.map { titles[$0.id] ?? $0.url.lastPathComponent }
    }
}
