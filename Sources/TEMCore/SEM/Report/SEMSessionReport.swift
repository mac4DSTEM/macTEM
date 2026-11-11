//
//  SEMSessionReport.swift
//  Role: the session report's content (design export-and-reports §4, D-SEM-103): the SEM session's rows (`SEMSessionRow`, the Results
//        room's) set as one document of sections, in the order a methods section is written: the files opened, their calibration,
//        each stage with its parameters and the Output lines it logged, the results, the figures the session exported with their
//        captions, the methods with their literature and the reference package each was held to, and the versions. The writers
//        (`SEMReportMarkdown`, `SEMReportPDF`) set the document; this file decides what is in it.
//
//        ASSEMBLED, NOT RECOMPUTED: every string is a row's (the rooms' own words and numbers) or the context's (the date, the app). A
//        section the person switched off, or one with nothing in it, is left out; the methods are those of the sections kept.
//

import Foundation

package nonisolated enum SEMSessionReport {
    /// The report's sections, in order; the Report section's `Include` checkboxes.
    package enum Section: String, Sendable, Equatable, Hashable, CaseIterable, Identifiable {
        case openedFiles, calibration, processing, indexing, maps, texture, spectra, figures, methods, versions

        package var id: String { rawValue }

        package var title: String {
            switch self {
            case .openedFiles: "Opened files"
            case .calibration: "Calibration"
            case .processing: "Processing"
            case .indexing: "Indexing"
            case .maps: "Maps and grains"
            case .texture: "Texture"
            case .spectra: "Spectra"
            case .figures: "Figures"
            case .methods: "Methods and references"
            case .versions: "Versions"
            }
        }

        /// The row kinds a section sets (the opened files, the methods and the versions are drawn from every kept row).
        var kinds: [SEMSessionRow.Kind] {
            switch self {
            case .openedFiles: [.dataset, .orientationMap, .composition]
            case .calibration: [.dataset]
            case .processing: [.processing, .scanMaps]
            case .indexing: [.indexing]
            case .maps: [.orientationMap, .grains]
            case .texture: [.texture]
            case .spectra: [.composition]
            case .figures: [.export]
            case .methods, .versions: []
            }
        }
    }

    /// The file the report is written as.
    package enum Format: String, Sendable, Equatable, CaseIterable, Identifiable {
        case pdf, markdown

        package var id: String { rawValue }
        package var title: String { self == .pdf ? "PDF" : "Markdown" }
        package var fileExtension: String { self == .pdf ? "pdf" : "md" }
    }

    /// What the person chose in the Report section.
    package struct Options: Sendable, Equatable {
        package var title: String
        package var sections: Set<Section>
        package var format: Format

        package init(title: String, sections: Set<Section> = Set(Section.allCases), format: Format = .pdf) {
            self.title = title
            self.sections = sections
            self.format = format
        }
    }

    /// What the report says about itself: when it was made, by which app, for whom, and what the app was built with.
    package struct Context: Sendable, Equatable {
        package var date: Date
        /// "macEM 1.12.0 (45)".
        package var software: String
        /// The person's name when they chose to be named; nil otherwise.
        package var author: String?
        /// The kits and the shell the app was built with, name and version ("FormatoKit", "0.12.1").
        package var packages: [SEMSessionField]
        /// The zone the times are written in.
        package var timeZone: TimeZone

        package init(date: Date, software: String, author: String? = nil, packages: [SEMSessionField] = [], timeZone: TimeZone = .current) {
            self.date = date
            self.software = software
            self.author = author
            self.packages = packages
            self.timeZone = timeZone
        }
    }

    /// The default title: "patterns_v2 session report", from the first file the session read; "SEM session report" without one.
    package static func defaultTitle(_ rows: [SEMSessionRow]) -> String {
        guard let file = rows.first(where: { $0.kind != .export && $0.file != nil })?.file else { return "SEM session report" }
        return file.deletingPathExtension().lastPathComponent + " session report"
    }

    /// How many items each section would hold: what the Report section's outline shows beside each checkbox.
    package static func outline(_ rows: [SEMSessionRow]) -> [Section: Int] {
        var counts: [Section: Int] = [:]
        for section in Section.allCases {
            switch section {
            case .openedFiles: counts[section] = openedFiles(rows).count
            case .methods: counts[section] = methods(of: rows).count
            case .versions: counts[section] = 1
            default: counts[section] = rows.filter { section.kinds.contains($0.kind) }.count
            }
        }
        return counts
    }

    /// The document of `rows` under `options`.
    package static func document(_ rows: [SEMSessionRow], options: Options, context: Context) -> SEMReportDocument {
        let clock = Clock(timeZone: context.timeZone)
        var subtitle = [clock.dateTime(context.date), context.software]
        if let author = context.author, !author.isEmpty { subtitle.append(author) }
        var blocks: [SEMReportDocument.Block] = []
        // The methods cited are those of the sections the report keeps.
        var cited: [SEMSessionRow] = []
        for section in Section.allCases where options.sections.contains(section) {
            let kept = rows.filter { section.kinds.contains($0.kind) }
            switch section {
            case .openedFiles:
                let files = openedFiles(rows)
                guard !files.isEmpty else { continue }
                blocks.append(.heading(level: 2, text: section.title))
                blocks.append(.table(SEMReportTable(header: ["File", "Room", "Contents", "Folder"], rows: files.map { row in
                    [row.file?.lastPathComponent ?? row.label, row.kind.room, row.kind == .composition ? "SEM-EDS spectrum" : row.value,
                     row.file?.deletingLastPathComponent().path ?? "in memory"]
                })))
            case .calibration, .processing, .indexing, .maps, .texture:
                guard !kept.isEmpty else { continue }
                cited += kept
                blocks.append(.heading(level: 2, text: section.title))
                for row in kept { blocks += stage(row, clock: clock) }
            case .spectra:
                guard !kept.isEmpty else { continue }
                cited += kept
                blocks.append(.heading(level: 2, text: section.title))
                blocks += spectra(kept, clock: clock)
            case .figures:
                guard !kept.isEmpty else { continue }
                cited += kept
                blocks.append(.heading(level: 2, text: section.title))
                blocks += figures(kept, clock: clock)
            case .methods:
                let used = methods(of: cited)
                guard !used.isEmpty else { continue }
                blocks.append(.heading(level: 2, text: section.title))
                for method in used {
                    blocks.append(.heading(level: 3, text: method.title))
                    blocks.append(.paragraph(method.sentence + " Parity reference: " + method.parityReference + "."))
                    blocks.append(.bullets(method.references))
                }
            case .versions:
                blocks.append(.heading(level: 2, text: section.title))
                var table = [[context.software, "the app that made this report"]]
                table += context.packages.map { [$0.name + " " + $0.value, "a Swift package the app is built with"] }
                table += SEMReferenceVersions.pinned.map { [$0.name + " " + $0.version, "parity reference (tools/parity/sem)"] }
                blocks.append(.table(SEMReportTable(header: ["Package", "Role"], rows: table)))
            }
        }
        return SEMReportDocument(title: options.title, subtitle: subtitle.joined(separator: " \u{00B7} "), blocks: blocks)
    }

    // MARK: - Sections

    /// The rows read from a file, one per file, in order (a spectrum's lines are one file).
    static func openedFiles(_ rows: [SEMSessionRow]) -> [SEMSessionRow] {
        var seen = Set<String>()
        return rows.filter { row in
            guard Section.openedFiles.kinds.contains(row.kind) else { return false }
            let key = row.file?.standardizedFileURL.path ?? "memory:" + row.label
            if row.kind == .composition, row.file == nil { return false }
            return seen.insert(key).inserted
        }
    }

    /// A stage or a result: its title, its one line, its table, when it ran and what it logged.
    static func stage(_ row: SEMSessionRow, clock: Clock) -> [SEMReportDocument.Block] {
        var blocks: [SEMReportDocument.Block] = [.heading(level: 3, text: row.label)]
        var line = row.value
        if let time = row.time { line += " (" + clock.time(time) + ")" }
        if !line.isEmpty { blocks.append(.paragraph(line)) }
        if !row.fields.isEmpty { blocks.append(.table(SEMReportTable(fields: row.fields))) }
        if !row.log.isEmpty { blocks.append(.bullets(row.log.map { clock.time($0.time) + "  " + $0.text })) }
        return blocks
    }

    /// The composition: one table per spectrum, a line per row, the columns the rows' fields.
    static func spectra(_ rows: [SEMSessionRow], clock: Clock) -> [SEMReportDocument.Block] {
        var blocks: [SEMReportDocument.Block] = []
        var bySource: [(source: String, rows: [SEMSessionRow])] = []
        for row in rows {
            if let index = bySource.firstIndex(where: { $0.source == row.source }) { bySource[index].rows.append(row) }
            else { bySource.append((row.source, [row])) }
        }
        for group in bySource {
            blocks.append(.heading(level: 3, text: group.source))
            let names = group.rows.first?.fields.map(\.name) ?? []
            let table = SEMReportTable(header: ["Line"] + names, rows: group.rows.map { row in
                [row.label] + names.map { name in row.fields.first { $0.name == name }?.value ?? "" }
            })
            blocks.append(.table(table))
            if let time = group.rows.compactMap(\.time).max() { blocks.append(.paragraph("Quantified at " + clock.time(time) + ".")) }
        }
        return blocks
    }

    /// Each exported picture with its caption, then the files without a picture as one table.
    static func figures(_ rows: [SEMSessionRow], clock: Clock) -> [SEMReportDocument.Block] {
        var blocks: [SEMReportDocument.Block] = []
        for row in rows {
            guard var figure = row.figure else { continue }
            figure.caption = caption(row, clock: clock)
            blocks.append(.figure(figure))
        }
        let files = rows.filter { $0.figure == nil }
        if !files.isEmpty {
            blocks.append(.heading(level: 3, text: "Files written"))
            blocks.append(.table(SEMReportTable(header: ["File", "What", "From", "Time"], rows: files.map { row in
                [row.file?.lastPathComponent ?? row.label, row.value, row.source, row.time.map(clock.time) ?? ""]
            })))
        }
        return blocks
    }

    /// "patterns_v2 indexed IPF-Z.png: Map PNG of the IPF-Z layer, 75 × 55 px. Indexing · patterns_v2.h5 · Layer IPF-Z · written 16:42:10."
    static func caption(_ row: SEMSessionRow, clock: Clock) -> String {
        var parts = [row.source] + row.fields.map { "\($0.name) \($0.value)" }
        if let time = row.time { parts.append("written " + clock.time(time)) }
        let name = row.file?.lastPathComponent ?? row.label
        return name + ": " + row.value + ". " + parts.joined(separator: " \u{00B7} ") + "."
    }

    /// The methods of `rows`, each once, in the order they are first used.
    static func methods(of rows: [SEMSessionRow]) -> [SEMMethod] {
        var seen = Set<SEMMethod>()
        return rows.flatMap(\.methods).filter { seen.insert($0).inserted }
    }

    // MARK: - Times

    /// Dates and times as the report writes them: "2026-11-07 16:42", "16:42:10", in the context's zone, the same on every Mac.
    struct Clock {
        let timeZone: TimeZone

        func dateTime(_ date: Date) -> String { format(date, "yyyy-MM-dd HH:mm") }
        func time(_ date: Date) -> String { format(date, "HH:mm:ss") }

        private func format(_ date: Date, _ pattern: String) -> String {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = timeZone
            formatter.dateFormat = pattern
            return formatter.string(from: date)
        }
    }
}
