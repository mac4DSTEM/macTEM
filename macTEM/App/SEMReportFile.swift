//
//  SEMReportFile.swift
//  Role: the session report as a file (design export-and-reports §4, D-SEM-103): the context it states about itself (the date, the app
//        and its version, the person when they chose to be named, the packages the app is built with), its name, its bytes in the
//        chosen format, and the line the status bar shows when it is written. `ExportPanels.exportSessionReport` asks the place and
//        writes; TEMCore's `SEMSessionReport` decides the content and `SEMReportMarkdown` / `SEMReportPDF` set it.
//

import Foundation
import UniformTypeIdentifiers
import TEMCore

enum SEMReportFile {
    /// What the report says about itself, now.
    static func context(namesAuthor: Bool, date: Date = Date()) -> SEMSessionReport.Context {
        SEMSessionReport.Context(date: date, software: ExportSnapshot.softwareName(), author: namesAuthor ? NSFullUserName() : nil,
                                 packages: SEMReferenceVersions.builtWith)
    }

    /// The file's name without its extension: the title, with the characters a file name cannot hold replaced.
    nonisolated static func stem(_ title: String) -> String {
        let cleaned = title.map { "/:\\".contains($0) ? "-" : String($0) }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "SEM session report" : cleaned
    }

    nonisolated static func contentType(_ format: SEMSessionReport.Format) -> UTType {
        format == .pdf ? .pdf : (UTType(filenameExtension: "md") ?? .plainText)
    }

    /// The bytes of `document` in `format`; a Markdown report links the figures from `directory`, the folder it is written to. nil
    /// only when Core Graphics cannot open a PDF context.
    nonisolated static func data(of document: SEMReportDocument, format: SEMSessionReport.Format, context: SEMSessionReport.Context,
                                 directory: URL?) -> Data? {
        switch format {
        case .markdown: return Data(SEMReportMarkdown.text(of: document, directory: directory).utf8)
        case .pdf: return SEMReportPDF.data(of: document, creator: context.software, author: context.author)
        }
    }

    /// "Exported patterns_v2 session report.pdf — 7 sections, 3 figures".
    nonisolated static func doneLine(name: String, document: SEMReportDocument) -> String {
        let sections = document.sectionTitles.count, figures = document.figures.count
        return "Exported \(name) — \(sections) \(sections == 1 ? "section" : "sections"), \(figures) \(figures == 1 ? "figure" : "figures")"
    }
}
