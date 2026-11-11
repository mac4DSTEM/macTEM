//  Navigation and nothing else: the workspaces, then the parts of the one in front. The workspaces list is ShellLayout's
//  `WorkspaceSidebarFrame` and `WorkspaceRoomsSection` (suite task 8, MacEMUI), in mac4DSTEM's shape: the workspaces, then a section
//  titled by the workspace in front with its parts (mac4DSTEM: Crystal Maps over Strain, Orientation, Phase mapping). The open files
//  are the window's tabs (one file per window, 2026-11-10), not a list here.
import ShellLayout
import SwiftUI

/// Navigation and nothing else: the five workspaces and the parts of the one in front, filling the column. A workspace or a part
/// the window's file has nothing for is listed, dimmed, with its reason on hover, and cannot be selected.
struct WorkspaceSidebar: View {
    @Environment(AppState.self) private var appState
    /// The system's sidebar size (System Settings > Appearance), which sets the rows' pitch.
    @Environment(\.sidebarRowSize) private var sidebarRowSize

    var body: some View {
        roomsList
            .environment(\.defaultMinListRowHeight, LayoutPolicy.sidebarRoomRowHeight(sidebarRowSize))
            .frame(maxHeight: .infinity)
    }

    private var roomsList: some View {
        let group = appState.navigation.workspaceArea.group
        return WorkspaceSidebarFrame(selection: appState.sidebarRoute) {
            WorkspaceRoomsSection(
                rooms: WorkspaceGroup.allCases, tag: { SidebarRoute.workspace($0) },
                isAvailable: { appState.workspaceUnavailableReason($0) == nil },
                unavailableHelp: { appState.workspaceUnavailableReason($0) ?? "" })
            if group.hasParts {
                Section(group.title) {
                    ForEach(group.parts) { room in
                        let available = appState.roomUnavailableReason(room) == nil
                        partRow(room, available: available)
                            .tag(SidebarRoute.room(room))
                            .disabled(!available)
                            .selectionDisabled(!available)
                    }
                }
            }
        }
        // Rebuilt when a room becomes available or unavailable, or the parts section changes (another workspace in front): a row whose
        // selection is disabled kept its highlight when the selection moved off it (the Image row stayed lit beside EDS after a lone .msa
        // opened), and mac4DSTEM's list kept the old section's row lit when its task section changed (its R5). A fresh list takes its
        // selection from the binding alone. Interim: delete at the MacEMUI release that deselects such a row itself.
        .id(appState.sidebarListIdentity)
    }

    /// A part's row, drawn as the shell draws a workspace row (`WorkspaceRoomsSection`): an unavailable one in the tertiary style, its
    /// reason on hover. The identifier stays the room's, `workspace.<room>`, so the UI journeys find a room as before.
    @ViewBuilder
    private func partRow(_ room: WorkspaceArea, available: Bool) -> some View {
        let label = Label(room.title, systemImage: room.symbolName)
        Group {
            if available {
                label
            } else {
                label.foregroundStyle(.tertiary)
            }
        }
        .help(available ? room.subtitle : (appState.roomUnavailableReason(room) ?? ""))
        .accessibilityLabel(room.title)
        .accessibilityIdentifier("workspace.\(room.id)")
        .accessibilityHint(available ? room.subtitle : "Not available")
    }
}

/// What the sidebar selects. A workspace with parts is represented by its selected part (selecting a file, not its folder, is what
/// highlights in Xcode's navigator, mac4DSTEM's `WorkspaceRoute`); a workspace of one room (Diffraction, Results) is selected in its
/// own right. Derived from the navigation seam, never stored beside it.
nonisolated enum SidebarRoute: Hashable, Sendable {
    case workspace(WorkspaceGroup)
    case room(WorkspaceArea)

    /// The row that reads as selected while `area` is in front.
    static func current(_ area: WorkspaceArea) -> SidebarRoute {
        area.group.hasParts ? .room(area) : .workspace(area.group)
    }
}

extension AppState {
    /// The sidebar's selection, as a binding onto the navigation seam: derived, never stored beside it
    /// (mac4DSTEM UI/WorkspaceRoute.swift). It lives in UI/ because `Binding` is SwiftUI's.
    var sidebarRoute: Binding<SidebarRoute?> {
        Binding(
            get: { SidebarRoute.current(self.navigation.workspaceArea) },
            set: { route in
                switch route {
                case .workspace(let group): self.selectWorkspaceGroup(group)
                case .room(let room): self.selectWorkspace(room)
                case nil: break
                }
            }
        )
    }

    /// What the sidebar's list is rebuilt on: the workspace in front (its parts section) and which rooms can be entered.
    var sidebarListIdentity: String {
        navigation.workspaceArea.group.rawValue + ":"
            + WorkspaceArea.allCases.map { roomUnavailableReason($0) == nil ? "1" : "0" }.joined()
    }
}
