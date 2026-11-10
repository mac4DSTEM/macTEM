//
//  TSV.swift
//  Role: one line of the text ⌘C writes for a table's rows: the cells joined by tabs, a tab or a line break inside a cell made a
//        space first, so a pasted row keeps its columns whatever a file's or a phase's name holds. The app's three table copies
//        write their lines through it: the Results room's image table (`ResultsFormat.copyLine`), its SEM session table
//        (`ResultsSessionFormat.copyText`) and the Indexing room's Results table (`IndexingTableFormat.copyText`). Pure.
//

import Foundation

nonisolated enum TSV {
    /// `cells` as one line: each with its tabs and line breaks made spaces (a CRLF one space), joined by tabs.
    static func line(_ cells: [String]) -> String {
        cells.map { $0.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ") }
            .joined(separator: "\t")
    }
}
