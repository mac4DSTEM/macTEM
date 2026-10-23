//
//  OpenURLRelay.swift
//  Role: rebuilds one ordered batch from a Finder open that SwiftUI and AppKit deliver in pieces. SwiftUI's
//        `.onOpenURL` gets only the FIRST url of a multi-file open; the rest reach `AppDelegate`'s
//        `application(_:open:)` (spike 2026-10-12, E4/E5: 0–62 ms apart, and an EMPTY array on a single-file
//        open). Both feed `add`; a trailing coalescing timer hands the whole batch once to the handler
//        (`AppState.open(urls:)`). Nothing is persisted and nothing renders from it: a plain object.
//

import Foundation

@MainActor
final class OpenURLRelay {

    /// The app's one relay: `AppDelegate` (created by the adaptor, so it cannot be handed one) and the window's
    /// `.onOpenURL` meet here.
    static let shared = OpenURLRelay()

    /// Where a batch goes. Setting it delivers a batch that arrived before there was one.
    var handler: (@MainActor ([URL]) -> Void)? {
        didSet { if handler != nil, timer == nil { flush() } }
    }

    private let delay: Duration
    private var pending: [URL] = []
    private var timer: Task<Void, Never>?

    /// 150 ms worked in four of four spike runs (the pieces arrive within 62 ms of each other).
    init(delay: Duration = .milliseconds(150)) {
        self.delay = delay
    }

    /// The running timer, for a test to await; nil when none is running.
    var pendingFlush: Task<Void, Never>? { timer }

    /// Appends `urls` (an empty array changes nothing) and restarts the timer.
    func add(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        pending.append(contentsOf: urls)
        timer?.cancel()
        timer = Task { [delay] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self.timer = nil
            self.flush()
        }
    }

    /// Hands the batch over once; with no handler yet it is kept for the one that is set.
    private func flush() {
        guard let handler, !pending.isEmpty else { return }
        let batch = pending
        pending = []
        handler(batch)
    }
}
