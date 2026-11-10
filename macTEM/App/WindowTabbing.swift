//
//  WindowTabbing.swift
//  Role: a window prefers tabs, so a file opened while another is open comes up as a tab of the window in front, as Finder and
//        Safari do (Paul, 2026-11-10). AppKit, named: SwiftUI has no modifier for a window's tabbing mode (`NSWindow.tabbingMode`);
//        without it a new window is a tab only for someone whose System Settings say "Prefer tabs: Always". The same place hands
//        the window's state a way to bring its window forward (`AppState.showWindow`), for a file opened again that another
//        window holds. An empty view that draws nothing; the window stays SwiftUI's.
//

import AppKit
import SwiftUI

struct WindowTabbing: NSViewRepresentable {
    let state: AppState

    func makeNSView(context: Context) -> NSView { Probe(state: state) }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class Probe: NSView {
        private weak var state: AppState?

        init(state: AppState) {
            self.state = state
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("not decoded") }

        /// Runs when the view enters its window, before the window is shown: the mode is set by the time the system decides
        /// whether the window is a tab.
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.tabbingMode = .preferred
            state?.showWindow = { [weak window] in window?.makeKeyAndOrderFront(nil) }
        }
    }
}
