//
//  UITestingPlacement.swift
//  Role: under `--ui-testing`, every window that becomes key is moved onto the main screen (the one with the menu bar, `NSScreen.screens.first`).
//        XCUITest captures the main screen: a window that opens on a second display (where the last session left it, or where the pointer is)
//        passes every query and then fails its screenshot with "Image creation failed". AppKit because SwiftUI has no way to choose a window's
//        screen; named here, test launches only. The same file is in both apps (a change is copied).
//

import AppKit

enum UITestingPlacement {
    @MainActor private static var observer: (any NSObjectProtocol)?

    /// Moves each window that becomes key onto the main screen when it is not on it, to the top left of the visible frame with a margin.
    @MainActor static func installIfTesting(arguments: [String] = ProcessInfo.processInfo.arguments) {
        guard arguments.contains("--ui-testing"), observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { placeWindowsOnMainScreen() }
        }
    }

    @MainActor private static func placeWindowsOnMainScreen() {
        guard let main = NSScreen.screens.first else { return }
        for window in NSApplication.shared.windows where window.isVisible && window.screen !== main && window.styleMask.contains(.titled) {
            let visible = main.visibleFrame
            window.setFrameTopLeftPoint(NSPoint(x: visible.minX + 60, y: visible.maxY - 60))
        }
    }
}
