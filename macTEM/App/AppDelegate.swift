//
//  AppDelegate.swift
//  Role: the three things SwiftUI's scene API cannot do for a single-`Window` app (spike 2026-10-12, E1/E4):
//        it quits when the last window closes, `.onOpenURL` gets only the first file of a multi-file open, and a quit
//        cannot be held for a question (SwiftUI has no hook before the app terminates): quitting with marks not saved to
//        their session file, or with a room still working, asks first in an `NSAlert` (`CloseGuard`). This is the AppKit
//        named under the suite's rule ("AppKit only where SwiftUI cannot do the job"), bridged with
//        `@NSApplicationDelegateAdaptor` in `macTEMApp`. Closing the window keeps the app running and its files open.
//

import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {

    /// The window's state, for the question at quit: set when the window first appears (`ImageWindow`), as the URL relay's
    /// handler is, since the adaptor makes the delegate and cannot hand it one. Weak: `macTEMApp` owns the state.
    static weak var appState: AppState?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// The files after the first of a Finder open (and an empty array on a single-file open: tolerated).
    func application(_ application: NSApplication, open urls: [URL]) {
        OpenURLRelay.shared.add(urls)
    }

    /// Quits at once when nothing would be lost; otherwise asks, naming the files with unsaved marks and the rooms still
    /// working: Quit (destructive) or Cancel (Esc). A UI-testing launch quits without asking: a journey's teardown ends the
    /// app, and a modal question would hold it.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let appState = Self.appState, !appState.launch.isUITesting, let question = appState.quitQuestion else {
            return .terminateNow
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = CloseGuard.quitTitle
        alert.informativeText = question
        let quit = alert.addButton(withTitle: "Quit")
        quit.hasDestructiveAction = true
        let cancel = alert.addButton(withTitle: "Cancel")
        cancel.keyEquivalent = "\u{1b}"
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }
}
