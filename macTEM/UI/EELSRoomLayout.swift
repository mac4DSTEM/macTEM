//
//  EELSRoomLayout.swift
//  Role: the pure parts of the EELS room's views, kept out of the view file (`EELSRoom.swift`): a tile's colours until the person changes
//        them (`EELSTileStyle`, which the colour mix and the maps figure take too), where the spectrum's legend and its "low loss" and "core loss"
//        names sit (`EELSSpectrumLayout`), what a drag on the spectrum does by where it starts (`EELSSpectrumDrag`), the results table's minimum
//        column widths (`EELSResultsColumns`), how the results pane shares its height between the edges table and the Regions section
//        (`EELSResultsSplit`) and the words VoiceOver says for a symbol column header, in the results table and the Regions table
//        (`EELSColumnSpeech`, `EELSRegionsTable.swift`). No state: constants and functions of their arguments, which the room's tests call directly.
//

import ShellMetal
import ShellSpectroscopy
import SwiftUI
import TEMCore

// MARK: - The maps

/// A tile's colours until the person changes them: t/λ, t and I total on viridis, the zero-loss shift diverging (centred on 0), an edge or an at% map black to its
/// element's colour. The scale of each is `EELSMapScale`.
nonisolated enum EELSTileStyle {
    static func hue(forID id: String) -> Double {
        let symbol = id.hasPrefix("edge-") ? String(id.dropFirst(5).prefix { $0 != "-" }) : (id.hasPrefix("at-") || id.hasPrefix("wt-") ? String(id.dropFirst(3)) : "")
        return symbol.isEmpty ? 0.5 : EDXRoomFormat.hue(symbol: symbol)
    }

    static func defaultColoring(_ id: String) -> MapColoring {
        switch EELSMapScale.mode(forTileID: id) {
        case .diverging: return .colormap(.rdbu)
        case .minToMax: return .colormap(.viridis)
        case .zeroToMax:
            let rgb = EDXRoomFormat.rgb(hue: hue(forID: id))
            return .color(RegionColor(red: rgb.0, green: rgb.1, blue: rgb.2))
        }
    }
}

// MARK: - The spectrum and the results

/// Where the spectrum's legend and its "low loss" / "core loss" names sit (pure, so a test checks they never meet).
nonisolated enum EELSSpectrumLayout {
    static let lowLossName = "low loss", coreLossName = "core loss"
    /// The legend's offset from the spectrum's top-left corner: in the band above the plot as in the EDS room, 6 pt further right than the EDS room's 56 so
    /// it clears "log counts" (52 pt wide from x = 4), which is longer than the EDS room's "counts".
    static let legendLeading: CGFloat = 62, legendInset: CGFloat = 2
    /// The bands around the plot: the titles above, the energy ticks and title below, a margin on the right.
    static let top: CGFloat = 20, bottom: CGFloat = 36, right: CGFloat = 8

    /// The plot inside a spectrum of `size` whose counts labels take `left`.
    static func plotArea(in size: CGSize, left: CGFloat) -> CGRect {
        CGRect(x: left, y: top, width: max(size.width - left - right, 1), height: max(size.height - top - bottom, 1))
    }

    /// The legend's frame in the spectrum, for a legend of `legend` size: at a fixed offset from the top-left corner, whatever the spectrum's size.
    static func legendFrame(legend: CGSize) -> CGRect {
        CGRect(x: legendLeading, y: legendInset, width: legend.width, height: legend.height)
    }

    /// Where the two names are drawn at the junction `junction` of a plot `area`: the low loss's right end left of it, the core loss's left end right of it.
    static func sectionLabelCentres(area: CGRect, junction: CGFloat) -> (low: CGPoint, core: CGPoint) {
        (CGPoint(x: junction - 4, y: area.maxY - 8), CGPoint(x: junction + 4, y: area.maxY - 8))
    }

    /// The names' frames for text of `low` and `core` size (trailing and leading anchors, centred vertically).
    static func sectionLabelFrames(area: CGRect, junction: CGFloat, low: CGSize, core: CGSize) -> (low: CGRect, core: CGRect) {
        let c = sectionLabelCentres(area: area, junction: junction)
        return (CGRect(x: c.low.x - low.width, y: c.low.y - low.height / 2, width: low.width, height: low.height),
                CGRect(x: c.core.x, y: c.core.y - core.height / 2, width: core.width, height: core.height))
    }
}

/// What a drag on the EELS spectrum does, by where it starts (pure; the EDS spectrum's `EDXSpectrumDrag` with the EELS view's measured left margin): under the plot
/// the energy axis, left of it the counts axis, inside it a pan (or an edge's window, when the drag starts on one).
nonisolated enum EELSSpectrumDrag {
    typealias Zone = EDXSpectrumDrag.Zone
    static let bottom: CGFloat = 36

    static func zone(start: CGPoint, size: CGSize, left: CGFloat) -> Zone {
        if start.y > size.height - bottom { return .energyAxis }
        if start.x < left { return .countsAxis }
        return .plot
    }
}

/// The minimum widths of the results table's columns, as the EDS room's `EDXResultsColumns`: the longest cell `EELSRoomFormat` writes inside the bounds
/// `EELSResultsColumnsTests` states, measured in the cell font, plus the cell's own inset. Narrower columns cut at% and wt% off ("95,88…", "not de…").
nonisolated enum EELSResultsColumns {
    /// The cell's inset around its text, both sides together (the EDS room's allowance).
    static let cellAllowance: CGFloat = 12
    /// Edge: "Ba M45" semibold, 48 pt, and the 16-pt mark of a refused edge after a 4-pt gap.
    static let edgeMinimum: CGFloat = 82
    /// I: "-8.888e-6 ± 8.8e-5", 121 pt (the EDS room's net counts column).
    static let intensityMinimum: CGFloat = 134
    /// at% and wt%: "100.000 ± 0.010", 104 pt (the EDS room's at% and wt% columns); "below detection" is 97 pt.
    static let percentMinimum: CGFloat = 116
}

/// How the results pane shares the height its header, thickness line, notes and footer leave between the edges table and the Regions section, as a
/// standard macOS results pane does: the results come first, and a table that is cut scrolls, both ways. The edges table takes its column headers
/// and every edge's row up to `edgesKeptInView`, whole and clear of the horizontal scroll bar (the columns' minimum widths, `EELSResultsColumns`, are
/// wider than a narrow pane, so it scrolls sideways). The Regions section takes what is left, up to its caption, header and every region's row (five;
/// more scroll), so in a short pane it gives way first: down to its caption, header and one row, and below that it scrolls in what is left. A taller
/// pane gives the rest to the edges table. Before a fit the Regions section takes its full height and the pane's "No edges fitted yet" the rest.
nonisolated enum EELSResultsSplit {
    /// A row of the system table at its regular size on macOS 26, its text and its inset (measured offscreen for #97).
    static let tableRowHeight: CGFloat = 24
    /// The table's column headers (measured with the row).
    static let tableHeaderHeight: CGFloat = 28
    /// The inset table style's margin above the first row (measured with the row), allowed again below the last.
    static let tableInset: CGFloat = 5
    /// The horizontal scroll bar: a legacy one takes 15 pt under the rows, an overlay one draws over the last row unless the table leaves it room.
    static let scrollBarAllowance: CGFloat = 16
    /// The edges table keeps this many rows in view at least, or every row when there are fewer; more scroll inside it (a quantification typically
    /// has three to six edges).
    static let edgesKeptInView = 6
    /// The Regions section's divider and its "Regions" caption (the caption font and its 4-pt top padding).
    static let regionsCaptionHeight: CGFloat = 18
    /// The Regions grid at its full height, as the pane has always sized it: 22 pt a row and 60 pt for its header, padding and scroll bar, at most
    /// 190 pt (five rows; more scroll).
    static let regionsRowHeight: CGFloat = 22, regionsGridChrome: CGFloat = 60, regionsGridMaximum: CGFloat = 190

    /// The edges table's floor for `rows` fitted edges: its column headers, the rows up to `edgesKeptInView`, its insets and the scroll bar's room.
    /// Nothing with no edge: the pane then says what to do, not a table.
    static func edgesFloor(rows: Int) -> CGFloat {
        guard rows > 0 else { return 0 }
        return tableHeaderHeight + 2 * tableInset + CGFloat(min(rows, edgesKeptInView)) * tableRowHeight + scrollBarAllowance
    }

    /// The Regions section at its full height for `rows` regions: the caption over the grid.
    static func regionsHeight(rows: Int) -> CGFloat {
        guard rows > 0 else { return 0 }
        return regionsCaptionHeight + min(CGFloat(rows) * regionsRowHeight + regionsGridChrome, regionsGridMaximum)
    }

    /// The edges table's height and the Regions section's in the `available` points between the thickness line and the lines under the tables (the
    /// refusal, the exponents line and the footer), for `edgeRows` fitted edges and `regionRows` regions: the edges table's floor first (all of
    /// `available` when it is less), then the Regions section up to its full height, then the edges table again. The two add up to `available` and
    /// neither is below 0, so nothing is pushed out of the pane.
    static func heights(available: CGFloat, edgeRows: Int, regionRows: Int) -> (edges: CGFloat, regions: CGFloat) {
        let pane = max(available, 0)
        guard regionRows > 0 else { return (pane, 0) }
        let edges = max(min(pane, edgesFloor(rows: edgeRows)), pane - regionsHeight(rows: regionRows))
        return (edges, pane - edges)
    }
}

/// A column header that is a symbol on screen, with the words VoiceOver says for it (pure, so a test reads the words): the results table's I, at% and
/// wt%, the Regions table's I total and t/λ. What is drawn stays as it was.
nonisolated enum EELSColumnSpeech {
    static let words: [String: String] = ["I": "intensity", "at%": "atomic percent", "wt%": "weight percent", "I total": "total counts", "t/λ": "t over lambda"]

    /// The words for the header drawn as `drawn`; a header that is a word already ("Edge", "Pixels") is said as it is drawn.
    static func spoken(_ drawn: String) -> String { words[drawn] ?? drawn }

    /// An edge's column in the Regions table: "Fe L2,3 intensity", "Fe L2,3 atomic percent".
    static func spoken(edge: String, column: String) -> String { "\(edge) \(spoken(column))" }

    /// The header as the table draws it, said in words.
    @MainActor static func header(_ drawn: String) -> Text { Text(drawn).accessibilityLabel(spoken(drawn)) }
}
