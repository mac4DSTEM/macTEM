//
//  MenuActionRelay.swift
//  Role: the actions a File-menu command can hand to a window that does not exist yet. The relay itself (the one
//        app-scoped hand-off, with the request counter a minimised window watches) is ShellLayout's `MenuActionRelay`
//        (suite task 8, MacEMUI), generic over this enum; where an action meets a window's state (`run`) is this app's.
//

import ShellLayout

nonisolated enum MenuAction: Equatable {
    case openImage
}

typealias MenuActionRelay = ShellLayout.MenuActionRelay<MenuAction>

extension ShellLayout.MenuActionRelay where Action == MenuAction {
    /// The one place an action meets a window's state, for the focused-window route and the new-window route alike.
    static func run(_ action: MenuAction, in appState: AppState) {
        switch action {
        case .openImage: appState.requestOpenImage()
        }
    }
}
