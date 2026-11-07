//
//  SEMReportMarkdown.swift
//  Role: the session report as one Markdown file (CommonMark with GitHub's tables). The figures are not copied: each was written by
//        its room's export, so the report links the file the export wrote, by its name when it sits in the report's folder (the default:
//        every export and the report go next to the data) and by its file URL otherwise. The PDF (`SEMReportPDF`) is the one-file form
//        with the figures drawn in (decision D-SEM-103).
//

import Foundation

package nonisolated enum SEMReportMarkdown {
    /// The report's text. `directory` is the folder the report is written into (nil: unknown, every figure is linked by its file URL).
    package static func text(of document: SEMReportDocument, directory: URL?) -> String {
        var parts = ["# " + oneLine(document.title)]
        if !document.subtitle.isEmpty { parts.append(oneLine(document.subtitle)) }
        var figureNumber = 0
        for block in document.blocks {
            switch block {
            case .heading(let level, let text):
                parts.append(String(repeating: "#", count: min(max(level, 1), 6)) + " " + oneLine(text))
            case .paragraph(let text):
                parts.append(text)
            case .bullets(let items):
                guard !items.isEmpty else { continue }
                parts.append(items.map { "- " + oneLine($0) }.joined(separator: "\n"))
            case .table(let table):
                parts.append(self.table(table))
            case .figure(let figure):
                figureNumber += 1
                parts.append(self.figure(figure, number: figureNumber, directory: directory))
            }
        }
        return parts.joined(separator: "\n\n") + "\n"
    }

    /// A GitHub table: the header, the rule, one line per row; a short row is padded with empty cells.
    static func table(_ table: SEMReportTable) -> String {
        let columns = max(table.header.count, table.rows.map(\.count).max() ?? 0)
        guard columns > 0 else { return "" }
        func line(_ cells: [String]) -> String {
            let padded = cells + Array(repeating: "", count: max(0, columns - cells.count))
            return "| " + padded.map { Self.cell($0) }.joined(separator: " | ") + " |"
        }
        let rule = "|" + Array(repeating: "---|", count: columns).joined()
        return ([line(table.header), rule] + table.rows.map(line)).joined(separator: "\n")
    }

    /// The image line and the caption under it.
    static func figure(_ figure: SEMReportFigure, number: Int, directory: URL?) -> String {
        let caption = "Figure \(number). " + oneLine(figure.caption)
        guard let file = figure.file else { return caption }
        return "![Figure \(number)](\(link(to: file, from: directory)))\n\n" + caption
    }

    /// The figure's name when it is in `directory`, its file URL otherwise; spaces and other characters a link cannot hold are
    /// percent-encoded.
    static func link(to file: URL, from directory: URL?) -> String {
        if let directory, file.deletingLastPathComponent().standardizedFileURL.path == directory.standardizedFileURL.path {
            return file.lastPathComponent.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? file.lastPathComponent
        }
        return file.absoluteString
    }

    /// A cell: one line, its pipes escaped.
    static func cell(_ text: String) -> String {
        oneLine(text).replacingOccurrences(of: "|", with: "\\|")
    }

    /// Line breaks become spaces (a heading, a list item and a cell are one line each).
    static func oneLine(_ text: String) -> String {
        text.components(separatedBy: .newlines).filter { !$0.isEmpty }.joined(separator: " ")
    }
}
