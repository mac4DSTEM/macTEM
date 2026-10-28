//
//  AppDelegate.swift
//  Role: the two things SwiftUI's scene API cannot do for a single-`Window` app (spike 2026-10-12, E1/E4):
//        it quits when the last window closes, and `.onOpenURL` gets only the first file of a multi-file open.
//        This is the AppKit named under the suite's rule ("AppKit only where SwiftUI cannot do the job"),
//        bridged with `@NSApplicationDelegateAdaptor` in `macTEMApp`. ADR 007: closing the window keeps the app
//        running and its files open.
//

import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// The files after the first of a Finder open (and an empty array on a single-file open: tolerated).
    func application(_ application: NSApplication, open urls: [URL]) {
        OpenURLRelay.shared.add(urls)
    }
}
