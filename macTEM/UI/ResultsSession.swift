//
//  ResultsSession.swift
//  Role: the Results room's SEM session (design export-and-reports §3 and §4, D-SEM-103): a second native `Table` with a `Section` per
//        kind of SEM result (the dataset, the processing run, the scan maps, the indexing run, the orientation map, the SEM-EDS lines,
//        every file the SEM rooms exported), under the image's results when an image is open and alone when none is
//        (`ResultsSessionRoom`); and the inspector's Report section, which sets those rows as one PDF or Markdown report, with the
//        selected row's Info. The rows are `SEMSessionLedger`'s, read once per body; what the room remembers is `ResultsRoomState`'s.
//
//        The Report section follows mac4DSTEM's Figure section in its Results inspector: a checkbox per part of the output with what it
//        holds beside it, the format, one full-width Export button at the end. It departs from the design's Embed/Link picker: the
//        PDF embeds every figure and the Markdown links the exported files (D-SEM-103), so the format says it.
//
//        KEYS: ↑ ↓ select (the Table's own selection) and ⌘C copies the selected rows' lines, tab-separated, as the image table does.
//

import ShellControls
import ShellInspector
import ShellLayout
import SwiftUI
import TEMCore

/// One kind of SEM result in the table, its rows in the ledger's order.
struct SEMSessionSection: Identifiable {
    let kind: SEMSessionRow.Kind
    let rows: [SEMSessionRow]

    var id: SEMSessionRow.Kind { kind }

    /// The rows by kind, in `SEMSessionRow.Kind.allCases` order, empty kinds left out.
    static func sections(_ rows: [SEMSessionRow]) -> [SEMSessionSection] {
        SEMSessionRow.Kind.allCases.compactMap { kind in
            let inKind = rows.filter { $0.kind == kind }
            return inKind.isEmpty ? nil : SEMSessionSection(kind: kind, rows: inKind)
        }
    }
}

/// The Results room with no image open: the SEM session alone.
struct ResultsSessionRoom: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let rows = SEMSessionLedger.rows(of: appState)
        Group {
            if rows.isEmpty {
                ContentUnavailableView(ResultsSessionFormat.emptyTitle, systemImage: "square.grid.2x2",
                                       description: Text(ResultsSessionFormat.emptyDetail))
            } else {
                ResultsSessionPane(rows: rows, state: appState.resultsRoom)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("results.room")
    }
}

/// The SEM session's header over its table.
struct ResultsSessionPane: View {
    let rows: [SEMSessionRow]
    let state: ResultsRoomState

    var body: some View {
        VStack(spacing: 0) {
            ResultsSessionHeader(rows: rows)
            Divider()
            ResultsSessionTable(sections: SEMSessionSection.sections(rows), state: state)
        }
    }
}

/// "SEM session · 9 results · 3 files exported", then the files the session read.
private struct ResultsSessionHeader: View {
    let rows: [SEMSessionRow]

    var body: some View {
        HStack(spacing: LayoutPolicy.inspectorRowSpacing) {
            Text(ResultsSessionFormat.summary(rows))
                .font(.callout.weight(.semibold))
                .lineLimit(1)
                .layoutPriority(1)
            Spacer(minLength: LayoutPolicy.inspectorRowSpacing)
            Text(ResultsSessionFormat.files(rows))
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(ResultsSessionFormat.files(rows))
        }
        .padding(.horizontal, LayoutPolicy.infobarHorizontalPadding)
        .frame(height: LayoutPolicy.paneHeaderHeight)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("results.session.header")
    }
}

/// The native table of the SEM rows: a `Section` per kind, the selection the state's.
private struct ResultsSessionTable: View {
    let sections: [SEMSessionSection]
    @Bindable var state: ResultsRoomState

    var body: some View {
        Table(of: SEMSessionRow.self, selection: $state.sessionSelection) {
            TableColumn("Result") { row in
                Text(row.label)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityLabel("\(row.label), \(row.value)")
                    .accessibilityIdentifier("results.session.row.\(row.id)")
            }
            .width(min: 110, ideal: 170)
            TableColumn("Value") { row in
                Text(row.value)
                    .monospacedDigit()
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(row.value)
            }
            .width(min: 120, ideal: 250)
            TableColumn("Source") { row in
                Text(row.source)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .width(min: 90, ideal: 170)
            TableColumn("Time") { row in
                Text(ResultsSessionFormat.time(row.time))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            .width(min: 60, ideal: 70)
            TableColumn("Method") { row in
                Text(row.methodTitle)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(ResultsSessionFormat.methodHelp(row))
            }
            .width(min: 110, ideal: 170)
        } rows: {
            ForEach(sections) { section in
                Section(section.kind.title) {
                    ForEach(section.rows) { row in TableRow(row) }
                }
            }
        }
        .onCopyCommand { copied() }
        .accessibilityIdentifier("results.session.table")
    }

    /// ⌘C: the selected rows' lines, in table order; nothing when nothing is selected.
    private func copied() -> [NSItemProvider] {
        let rows = sections.flatMap(\.rows).filter { state.sessionSelection.contains($0.id) }
        guard !rows.isEmpty else { return [] }
        return [NSItemProvider(object: ResultsSessionFormat.copyText(rows) as NSString)]
    }
}

// MARK: - Inspector

/// The Settings tab's Report section: what goes in the report, its format and title, and the one Export button.
struct ResultsSessionSettings: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let rows = SEMSessionLedger.rows(of: appState)
        if !rows.isEmpty {
            ResultsReportSection(rows: rows, state: appState.resultsRoom)
        }
    }
}

private struct ResultsReportSection: View {
    @Environment(AppState.self) private var appState
    let rows: [SEMSessionRow]
    @Bindable var state: ResultsRoomState

    var body: some View {
        let outline = SEMSessionReport.outline(rows)
        InspectorSection("Report") {
            InspectorRow("Title") {
                TextField("Title", text: $state.reportTitle, prompt: Text(SEMSessionReport.defaultTitle(rows)))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .help("The report's title and file name; empty is the first file's name")
                    .accessibilityIdentifier("results.report.title")
            }
            SegmentedPicker(label: "Format", items: SEMSessionReport.Format.allCases.map { format in
                (format, .title(format.title, help: format == .pdf ? "One PDF with every exported figure drawn in it"
                                                                  : "One Markdown file that links the exported figures"))
            }, selection: $state.reportFormat)
                .accessibilityIdentifier("results.report.format")
            ForEach(SEMSessionReport.Section.allCases) { section in
                InspectorRow("\(section.title) · \(outline[section] ?? 0)") {
                    Toggle(section.title, isOn: Binding(get: { state.includes(section) }, set: { state.setIncludes(section, $0) }))
                        .labelsHidden()
                        .toggleStyle(.checkbox)
                        .accessibilityIdentifier("results.report.include.\(section.rawValue)")
                }
            }
            InspectorRow("Name me") {
                Toggle("Name me in the report", isOn: $state.reportNamesAuthor)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .help("Write this Mac account's full name under the title")
                    .accessibilityIdentifier("results.report.author")
            }
            InspectorActionRow {
                Button(ResultsSessionFormat.exportTitle) { ExportPanels.exportSessionReport(appState: appState) }
                    .disabled(state.reportSections.isEmpty)
                    .help(state.reportSections.isEmpty ? "Tick a part to put in the report" : ResultsSessionFormat.exportHelp)
                    .accessibilityIdentifier("results.report.export")
            }
            InspectorNote(ResultsSessionFormat.reportNote)
        }
    }
}

/// The Info tab's SEM result: the selected row, its parameters, its methods with their literature, the file it came from.
struct ResultsSessionInfo: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let rows = SEMSessionLedger.rows(of: appState)
        let state = appState.resultsRoom
        if !rows.isEmpty {
            InspectorSection("SEM Result") {
                if let row = state.selectedSessionRow(in: rows) {
                    InspectorValueRow("Result", row.label)
                    InspectorValueRow("Value", row.value)
                    InspectorValueRow("Source", row.source)
                    if row.time != nil { InspectorValueRow("Time", ResultsSessionFormat.time(row.time)) }
                    ForEach(Array(row.fields.enumerated()), id: \.offset) { _, field in
                        InspectorValueRow(field.name, field.value)
                    }
                    ForEach(row.methods) { method in
                        InspectorValueRow("Method", method.title)
                        InspectorNote(ResultsSessionFormat.methodNote(method))
                    }
                    if let file = row.file {
                        InspectorValueRow("File", file.lastPathComponent)
                        InspectorActionRow {
                            Button("Show in Finder") { DatasetLocationActions.reveal(url: file) }
                                .accessibilityIdentifier("results.session.reveal")
                        }
                    }
                    InspectorNote(ResultsSessionFormat.owner(row))
                } else {
                    InspectorNote(state.sessionSelection.count > 1 ? ResultsSessionFormat.severalSelected : ResultsSessionFormat.noSelection)
                }
            }
        }
    }
}

// MARK: - Words

nonisolated enum ResultsSessionFormat {
    static let emptyTitle = "No SEM results"
    static let emptyDetail = "Open an EBSD dataset, an orientation map or an SEM spectrum: what the SEM rooms make and export is listed here, and set as one report."
    static let noSelection = "Select an SEM result to see what made it."
    static let severalSelected = "Several SEM results are selected."
    static let exportTitle = "Export Report…"
    static let exportHelp = "Every SEM result and exported figure of this session, with its parameters and methods, as one file"
    static let reportNote = "Every figure the SEM rooms exported this session with its parameters, the methods with their literature and the reference package each port is held to, and the versions. The PDF draws the figures; the Markdown links the exported files."

    /// "SEM session · 9 results · 3 files exported".
    static func summary(_ rows: [SEMSessionRow]) -> String {
        let exports = rows.filter { $0.kind == .export }.count
        let results = rows.count - exports
        var text = "SEM session · \(results) \(results == 1 ? "result" : "results")"
        if exports > 0 { text += " · \(exports) \(exports == 1 ? "file" : "files") exported" }
        return text
    }

    /// The files the session read, by name: "patterns_v2.h5 · TM002.hspy".
    static func files(_ rows: [SEMSessionRow]) -> String {
        var seen = Set<String>()
        return rows.filter { $0.kind != .export }.compactMap { $0.file?.lastPathComponent }.filter { seen.insert($0).inserted }
            .joined(separator: " · ")
    }

    /// The time column: "16:42:10"; empty when the session logged none.
    static func time(_ date: Date?) -> String { date?.formatted(date: .omitted, time: .standard) ?? "" }

    /// The Method column's help: every method with the reference its port is held to.
    static func methodHelp(_ row: SEMSessionRow) -> String {
        guard !row.methods.isEmpty else { return row.kind == .export ? "A file the room wrote" : "Read from the file" }
        return row.methods.map { "\($0.title) (\($0.parityReference))" }.joined(separator: "; ")
    }

    /// A method's sentence, its literature and its reference package.
    static func methodNote(_ method: SEMMethod) -> String {
        method.sentence + " " + method.references.joined(separator: "; ") + ". Parity reference: " + method.parityReference + "."
    }

    /// Where a row is changed.
    static func owner(_ row: SEMSessionRow) -> String {
        row.kind == .export ? "Written by the room named in Source; export again there." : "Change it in the \(row.kind.room) room."
    }

    /// ⌘C: one line per row, tab-separated: result, value, source, time, method; a tab or line break in a column (a file's name)
    /// becomes a space (`TSV.line`), so every pasted row keeps its five columns.
    static func copyText(_ rows: [SEMSessionRow]) -> String {
        rows.map { TSV.line([$0.label, $0.value, $0.source, time($0.time), $0.methodTitle]) }.joined(separator: "\n")
    }
}
