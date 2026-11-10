//
//  MenuActionRelay.swift
//  Role: the actions a menu command can hand to a window that does not exist yet (Open Image…, an Open Recent
//        entry, Reopen Last Session, a Help > Open Demo Data entry). The relay itself (the one app-scoped hand-off,
//        with the request counter a minimised window watches) is ShellLayout's `MenuActionRelay` (suite task 8,
//        MacEMUI), generic over this enum; where an action meets a window's state (`run`) is this app's.
//

import ShellLayout
import TEMSession

nonisolated enum MenuAction: Equatable {
    case openImage
    /// File > Open Recent > (a file), chosen with or without a window focused.
    case openRecent(RecentFile)
    /// File > Reopen Last Session: the files and the room of the last launch.
    case reopenLastSession
    /// Help > Open Demo Data > (a document): opened in its room, in the window that takes the action.
    case openDemo(DemoDocument)
}

typealias MenuActionRelay = ShellLayout.MenuActionRelay<MenuAction>

extension ShellLayout.MenuActionRelay where Action == MenuAction {
    /// The one place an action meets a window's state, for the focused-window route and the new-window route alike.
    static func run(_ action: MenuAction, in appState: AppState) {
        switch action {
        case .openImage: appState.requestOpenImage()
        case .openRecent(let entry): appState.openRecent(entry)
        case .reopenLastSession: appState.reopenLastSession()
        case .openDemo(let demo): appState.openDemo(demo)
        }
    }
}
