//
//  WindowTabbing.swift
//  Role: a file opened while another is open comes up as a tab of the window in front, as Finder and Safari do (Paul,
//        2026-11-10). AppKit, named: SwiftUI has no way to put a window in another's tab group, nor a modifier for the tabbing mode
//        (`NSWindow.addTabbedWindow`, `tabbingMode`); without them a new window is a tab only for someone whose System Settings
//        say "Prefer tabs: Always". File > New Window stays a window of its own, as Safari's. The same place hands
//        the window's state a way to bring its window forward (`AppState.showWindow`), for a file opened again that another
//        window holds. An empty view that draws nothing; the window stays SwiftUI's.
//

import AppKit
import SwiftUI

struct WindowTabbing: NSViewRepresentable {
    let state: AppState
    let windows: AppWindows

    func makeNSView(context: Context) -> NSView { Probe(state: state, windows: windows) }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class Probe: NSView {
        private weak var state: AppState?
        private weak var windows: AppWindows?
        /// The window's tab request has been answered (`AppWindows.takeTabRequest`): once per window.
        private var placed = false

        init(state: AppState, windows: AppWindows) {
            self.state = state
            self.windows = windows
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("not decoded") }

        /// Runs when the view enters its window. The mode alone came too late: AppKit had already decided the window was not a tab
        /// (driven 2026-11-10, System Settings' "Prefer tabs" at its default). So a window asked for as a tab (`AppWindows.openInTabs`)
        /// is added to the tab group of the window in front once it is on screen, AppKit's own `addTabbedWindow(_:ordered:)`.
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.tabbingMode = .preferred
            state?.showWindow = { [weak window] in window?.makeKeyAndOrderFront(nil) }
            guard !placed else { return }
            placed = true
            guard windows?.takeTabRequest() == true else { return }
            Task { @MainActor [weak window] in
                guard let window, (window.tabbedWindows?.count ?? 1) <= 1 else { return }
                let host = NSApp.orderedWindows.first {
                    $0 !== window && $0.isVisible && !($0 is NSPanel) && $0.tabbingIdentifier == window.tabbingIdentifier
                }
                guard let host else { return }
                host.addTabbedWindow(window, ordered: .above)
                window.makeKeyAndOrderFront(nil)
            }
        }
    }
}
