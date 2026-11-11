//
//  AppDelegate.swift
//  Role: the three things SwiftUI's scene API cannot do for this app (spike 2026-10-12, E1/E4):
//        it quits when the last window closes, `.onOpenURL` gets only the first file of a multi-file open, and a quit
//        cannot be held for a question (SwiftUI has no hook before the app terminates): quitting with marks not saved to
//        their session file, or with a room still working, asks first in an `NSAlert` (`CloseGuard`). This is the AppKit
//        named under the suite's rule ("AppKit only where SwiftUI cannot do the job"), bridged with
//        `@NSApplicationDelegateAdaptor` in `macTEMApp`. Closing the window keeps the app running and its files open.
//

import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {

    /// The app's windows, for the question at quit: set when a window first appears (`ImageWindow`), as the URL relay's
    /// handler is, since the adaptor makes the delegate and cannot hand it one. Weak: `macTEMApp` owns them.
    static weak var windows: AppWindows?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// The files after the first of a Finder open (and an empty array on a single-file open: tolerated).
    func application(_ application: NSApplication, open urls: [URL]) {
        OpenURLRelay.shared.add(urls)
    }

    /// Quits at once when nothing would be lost; otherwise asks, naming the files with unsaved marks and the rooms still
    /// working, over every window (`AppWindows.quitQuestion`): Quit (destructive) or Cancel (Esc). A UI-testing launch quits without asking: a journey's teardown ends the
    /// app, and a modal question would hold it.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let windows = Self.windows, !LaunchOptions().isUITesting, let question = windows.quitQuestion else {
            Self.windows?.isTerminating = true
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
        // A quit asked from the Dock or a script while another app is in front: the question sits behind that app, unseen, and the
        // quit waits on it (driven 2026-11-11, macTEM#487). Since macOS 14 an app in the background may not take the front itself
        // (`activate()` is a request the system declines from the Dock's Quit, driven the same day), so it asks for attention as a
        // document app does with unsaved work: the Dock icon bounces until the person comes, and the question is in front then.
        NSApp.activate()
        let attention = NSApp.isActive ? nil : NSApp.requestUserAttention(.criticalRequest)
        defer { if let attention { NSApp.cancelUserAttentionRequest(attention) } }
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        windows.isTerminating = true
        return .terminateNow
    }
}
