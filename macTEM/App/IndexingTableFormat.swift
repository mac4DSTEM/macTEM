//
//  IndexingTableFormat.swift
//  Role: the words of the Indexing room's Results table (design §3): each cell as the table shows it, and ⌘C's text, the selected rows
//        as TSV (D-SEM-96): one header line with the table's column titles, then one line per row in the table's order, the cells as
//        shown, tab-separated. Numbers in the reader's locale without grouping, as the status line and `UnitDisplay` write them (a
//        spreadsheet in that locale reads them as numbers); the CSV export is the locale-free channel. Pure: no view, no session.
//

import Foundation
import TEMCore

nonisolated enum IndexingTableFormat {
    /// An angle (or any value shown to a fixed number of decimals): "12,3"; `UnitDisplay.noValue` where there is none (NaN).
    static func angle(_ v: Double, digits: Int = 1, locale: Locale = .autoupdatingCurrent) -> String {
        UnitDisplay.fixed(v, places: digits, locale: locale)
    }

    /// A fraction (CI, a score): three decimals.
    static func fraction(_ v: Double, locale: Locale = .autoupdatingCurrent) -> String { angle(v, digits: 3, locale: locale) }

    /// A value of any size (pattern quality, a Radon peak): up to four significant digits.
    static func number(_ v: Double, locale: Locale = .autoupdatingCurrent) -> String { UnitDisplay.number(v, digits: 4, locale: locale) }

    /// The table's column titles: Row, Col, Phase, the Euler angles, then Hough's CI, Fit, Bands, PQ or a dictionary's score (named by
    /// its metric, `scoreTitle`), Simulation, OSM.
    static func titles(method: IndexingMethod, scoreTitle: String) -> [String] {
        let head = ["Row", "Col", "Phase", "φ₁ °", "Φ °", "φ₂ °"]
        switch method {
        case .hough: return head + ["CI", "Fit °", "Bands", "PQ"]
        case .dictionary: return head + [scoreTitle, "Simulation", "OSM"]
        }
    }

    /// A row's cells, as the table shows them, in `titles` order.
    static func cells(_ row: IndexingResult.Row, method: IndexingMethod, locale: Locale = .autoupdatingCurrent) -> [String] {
        let head = [String(row.row), String(row.column), row.phase, angle(row.phi1, locale: locale), angle(row.capitalPhi, locale: locale),
                    angle(row.phi2, locale: locale)]
        switch method {
        case .hough:
            return head + [fraction(row.confidence, locale: locale), angle(row.fit, digits: 2, locale: locale), String(row.bands),
                           number(row.patternQuality, locale: locale)]
        case .dictionary:
            return head + [fraction(row.confidence, locale: locale), row.simulationIndex >= 0 ? String(row.simulationIndex) : UnitDisplay.noValue,
                           angle(row.similarity, digits: 2, locale: locale)]
        }
    }

    /// ⌘C's text: the header line, then `rows` (in the order given: the table's), each its cells joined by tabs; a tab or line break in
    /// a cell (a phase's name) becomes a space (`TSV.line`). "" for no rows.
    static func copyText(_ rows: [IndexingResult.Row], method: IndexingMethod, scoreTitle: String, locale: Locale = .autoupdatingCurrent) -> String {
        guard !rows.isEmpty else { return "" }
        return ([TSV.line(titles(method: method, scoreTitle: scoreTitle))] + rows.map { TSV.line(cells($0, method: method, locale: locale)) })
            .joined(separator: "\n")
    }

    /// The row a change of the table's selection from `old` to `new` pins: the one row just added (a click, a ⌘-click, ⇧ by one row),
    /// else the only row left selected; nil when the change selects several at once (⌘A, a ⇧-range) or removes rows from several, so
    /// a wide selection for ⌘C leaves the pattern where it is.
    static func pinTarget(old: Set<Int>, new: Set<Int>) -> Int? {
        let added = new.subtracting(old)
        if added.count == 1 { return added.first }
        return added.isEmpty && new.count == 1 ? new.first : nil
    }
}
