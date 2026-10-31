//  Navigation and nothing else: the rooms, then the open files. The rooms list is ShellLayout's `WorkspaceSidebarFrame` and
//  `WorkspaceRoomsSection` (suite task 8, MacEMUI): a room that is not built is listed, dimmed, and cannot be selected.
//  What stays here: the open files below the rooms (two Lists, each with its own selection) and the rooms list's height.
import ShellLayout
import SwiftUI
import TEMCore
import TEMSession

/// Navigation and nothing else: the five rooms, then the open files. A room that is not built is listed, dimmed — the
/// window shows where the app is going — and cannot be selected.
struct WorkspaceSidebar: View {
    @Environment(AppState.self) private var appState
    /// The system's sidebar size (System Settings > Appearance), which sets the rooms' row pitch: the rooms list's height
    /// is a constant per size, never measured (`LayoutPolicy.sidebarRoomsListHeight`).
    @Environment(\.sidebarRowSize) private var sidebarRowSize

    var body: some View {
        // Two Lists, not one: a shared selection would drop the active room's highlight when a file is chosen. With
        // files open the rooms list is as tall as its rows and the files take the rest; with none it fills the column.
        // The height is a constant per system sidebar size: measuring it from the rows' positions either left a gap on
        // a first layout or, written to state during layout, crashed AppKit's layout loop guard (2026-10-13).
        let hasItems = !appState.openItems.items.isEmpty
        VStack(spacing: 0) {
            roomsList
                .environment(\.defaultMinListRowHeight, LayoutPolicy.sidebarRoomRowHeight(sidebarRowSize))
                // The rooms are always all in view; only the files below scroll (the owner, 2026-10-13).
                .scrollDisabled(hasItems)
                .frame(height: hasItems ? LayoutPolicy.sidebarRoomsListHeight(sidebarRowSize) : nil)
                .frame(maxHeight: hasItems ? nil : .infinity)
            if hasItems {
                OpenItemsList()
            }
        }
    }

    private var roomsList: some View {
        WorkspaceSidebarFrame(selection: appState.workspaceSelection) {
            WorkspaceRoomsSection(
                rooms: WorkspaceArea.allCases, tag: { $0 },
                isAvailable: { appState.roomUnavailableReason($0) == nil },
                unavailableHelp: { appState.roomUnavailableReason($0) ?? "" })
        }
        // Rebuilt when a room becomes available or unavailable: a row whose selection is disabled kept its highlight when the selection
        // moved off it (the Image row stayed lit beside EDS after a lone .msa opened, which leaves Image unavailable). Interim: delete at
        // the MacEMUI release that deselects such a row itself.
        .id(WorkspaceArea.allCases.map { appState.roomUnavailableReason($0) == nil })
    }
}

extension AppState {
    /// The sidebar's selection, as a binding onto the navigation seam: derived, never stored beside it
    /// (mac4DSTEM UI/WorkspaceRoute.swift). It lives in UI/ because `Binding` is SwiftUI's.
    var workspaceSelection: Binding<WorkspaceArea?> {
        Binding(
            get: { self.navigation.workspaceArea },
            set: { if let area = $0 { self.selectWorkspace(area) } }
        )
    }
}
