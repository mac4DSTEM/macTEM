//
//  EELSRoomLayout.swift
//  Role: the pure parts of the EELS room's views, kept out of the view file (`EELSRoom.swift`): a tile's colours until the person changes
//        them (`EELSTileStyle`, which the colour mix and the maps figure take too), where the spectrum's legend and its "low loss" and "core loss"
//        names sit (`EELSSpectrumLayout`), what a drag on the spectrum does by where it starts (`EELSSpectrumDrag`), the results table's minimum
//        column widths (`EELSResultsColumns`) and the words VoiceOver says for a symbol column header, in the results table and the Regions table
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
