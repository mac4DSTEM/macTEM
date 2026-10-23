//
//  LayoutPolicy+macTEM.swift
//  Role: what is macTEM's of the layout vocabulary: the sidebar's rooms list and the open files' rows (V1-13, ADR 011).
//        `LayoutPolicy` (the window's numbers), `ProcessAreaLayout`, `OperationMetricsFormat` and `displayByteString` are
//        ShellLayout's (suite task 8, MacEMUI).
//

import ShellLayout
import SwiftUI

extension LayoutPolicy {
    /// The rooms list's height once files are open, per system sidebar size: its top inset under the toolbar, the
    /// "Workspace" header and the five rooms, and 6 pt before "Open Files" (ADR 011, no gap). Measured on scratch builds
    /// on 2026-10-13 (the last room's bottom in the list + 6: 145, 178, 216 pt), and a constant, not measured at run
    /// time: a measured height left a gap on some first layouts or, set during layout, tripped AppKit's layout-loop
    /// guard (8 crashes in 15 resize cycles; archive: sidebar-gap-gate-d-2026-10-13.md). A sixth room changes it: the EDS and EELS rooms (2026-10-22) add two rows to the 2026-10-13 measurements (145, 178, 216 for five rooms), at each size's row pitch (23, 30, 38 pt): 192, 238, 291. A list too short hides the last rooms behind a scroll that `scrollDisabled` turns off — the rooms were cut off once files were open.
    static func sidebarRoomsListHeight(_ size: SidebarRowSize) -> CGFloat {
        sidebarRoomRowHeight(size) * 7 + 32
    }

    /// The rooms' row height per system sidebar size, a little more than the system's own (23, 30, 38 pt) so the list breathes (Paul, 2026-10-22: the sidebar was cramped). The rooms list's height
    /// is seven of these and the header with its insets (about 32 pt, measured as the earlier constants were), a constant like the earlier ones.
    static func sidebarRoomRowHeight(_ size: SidebarRowSize) -> CGFloat {
        switch size {
        case .small: 30
        case .large: 42
        default: 34
        }
    }
    /// "Open Files" is a header of the column's own, above its list so it stays while the rows scroll: it is set in from the
    /// column's edge by what a sidebar section header's text is, and a little air above and below.
    static let sidebarSectionHeaderInset: CGFloat = 18
    static let sidebarSectionHeaderVerticalPadding: CGFloat = 10
    /// An open file's picture in the sidebar list, a square; the row is this tall (the owner's answer, 2026-10-12).
    static let openItemThumbnailSide: CGFloat = 40
    static let openItemRowSpacing: CGFloat = 8

    /// The Diffraction room's readout table under the pattern, and an EDS tile's colour bar gradient: room content, named once (rule 4).
    static let diffractionReadoutHeight: CGFloat = 170
    static let colorbarGradientHeight: CGFloat = 6
    /// The colour dot before a region's name in the Table tab.
    static let regionSwatchSize: CGFloat = 9
}
