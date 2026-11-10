//
//  LayoutPolicy+macTEM.swift
//  Role: what is macTEM's of the layout vocabulary: the sidebar's rooms list and the open files' rows.
//        `LayoutPolicy` (the window's numbers), `ProcessAreaLayout`, `OperationMetricsFormat` and `displayByteString` are
//        ShellLayout's (suite task 8, MacEMUI).
//

import ShellLayout
import SwiftUI

extension LayoutPolicy {
    /// The rooms list's height once files are open, per system sidebar size: its top inset under the toolbar, the
    /// "Workspace" header and the five rooms, and 6 pt before "Open Files" (no gap). Measured on scratch builds
    /// on 2026-10-13 (the last room's bottom in the list + 6: 145, 178, 216 pt), and a constant, not measured at run
    /// time: a measured height left a gap on some first layouts or, set during layout, tripped AppKit's layout-loop
    /// guard (8 crashes in 15 resize cycles). A sixth room changes it: the EDS and EELS rooms (2026-10-22) add two rows to the 2026-10-13 measurements (145, 178, 216 for five rooms), at each size's row pitch (23, 30, 38 pt): 192, 238, 291. A list too short hides the last rooms behind a scroll that `scrollDisabled` turns off — the rooms were cut off once files were open.
    static func sidebarRoomsListHeight(_ size: SidebarRowSize) -> CGFloat {
        sidebarRoomRowHeight(size) * CGFloat(WorkspaceArea.allCases.count) + 32
    }

    /// The rooms' row height per system sidebar size, a little more than the system's own (23, 30, 38 pt) so the list breathes (Paul, 2026-10-22: the sidebar was cramped). The rooms list's height
    /// is one per room and the header with its insets (about 32 pt, measured as the earlier constants were), a constant like the earlier ones.
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

    /// The Patterns room's map progress bar in the pane header: short, beside the title (rule 4).
    static let paneHeaderProgressWidth: CGFloat = 80
    /// The Diffraction room's readout table under the pattern: room content, named once (rule 4).
    static let diffractionReadoutHeight: CGFloat = 170
    /// The colour dot before a region's name in the Table tab.
    static let regionSwatchSize: CGFloat = 9
    /// The Indexing room's IPF colour key in the map pane's footer: legible beside the scale bar, small enough not to hide the map.
    static let indexingKeyHeight: CGFloat = 56
    /// The Maps room's colour key in the bottom pane: one phase's key image this wide (its own aspect sets the height).
    static let mapsKeyWidth: CGFloat = 150
    /// The margin either side of a colour key for its corner labels ("[001]" sits centred on the left corner and was cut off).
    static let mapsKeyLabelInset: CGFloat = 18
    /// The Maps room's bottom pane under the map: the keys' height plus their titles (rule 4).
    static let mapsKeyPaneMinimum: CGFloat = 140
    /// A phase's colour square in the Maps room's legend and inspector, and the IPF colour swatch under the unit cell.
    static let mapsPhaseSwatchSize: CGFloat = 12
    static let mapsColourSwatchSize: CGFloat = 22
    /// The kinematical master pattern's picture in the Simulation section: wide enough to read its zone axes (rule 4).
    static let overlayMasterPictureWidth: CGFloat = 180
    /// One stereogram or ODF section in the Maps room's Pole figures and ODF tabs (its title and colour bar under it).
    static let mapsTextureFigureSide: CGFloat = 150
    /// An ODF φ₂ section's width: three times wider than tall (φ₁ over 0–360°, Φ over 0–90° for cubic), it read as a strip at 150 pt.
    static let mapsODFSectionWidth: CGFloat = 240
    /// The colour bar under a texture figure, and the boundary and trace line widths on the map (points).
    static let mapsColourBarHeight: CGFloat = 8
    static let mapsBoundaryLineWidth: CGFloat = 1
    static let mapsOutlineLineWidth: CGFloat = 2
    static let mapsTraceLineWidth: CGFloat = 1.5
    /// A selected grain's pole on a pole figure: a ring this radius (points), and the room under the histogram's bars for the ticks.
    static let mapsPoleMarkerRadius: CGFloat = 3.5
    static let mapsHistogramTickHeight: CGFloat = 8
}
