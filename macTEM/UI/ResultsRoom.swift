//
//  ResultsRoom.swift
//  Role: the Results room (archive: roadmap-registrations-2026-10-15.md V1-10 slice 3; archive: results-room-design-2026-10-15.md, Part 1): every finished
//        measurement of the selected file in one native `Table` with a `Section` per group — marks and FFT spots — mounted by
//        `WorkspaceView`'s room switch. It makes no number and keeps none: the rows are `ResultsLedger`'s, read once per body
//        from the file's owners and handed down as values (skill, observation.md "State Capture at Body Level": a row that read
//        the owner itself would register one dependency per row); what it remembers is `ResultsRoomState`'s (the selection
//        and the shown groups).
//
//        LAYOUT: a 26-pt header (the file · "12 results, 3 hidden" · the session sentence of the Image room's tail) over the
//        Table. Columns Result · Value · Source · Record · Validation; the badge is the producer's label and its tooltip the
//        producer's sentence (`ResultsFormat`). No selection: nothing is shown but the table. No result: a
//        `ContentUnavailableView`. No chart, no statistics, no editing: a result is removed in the room that made it.
//
//        KEYS: ↑ ↓ select (the Table's own selection) and ⌘C copies the selected rows' lines (`onCopyCommand`, tab-separated).
//        There is no ⌫. Whether a Table holds the keys without a keyed container is for the drive.
//
//        The inspector's Settings and Info are in ResultsRoomInspector.swift.
//

import ShellLayout
import SwiftUI
import TEMCore
import TEMSession

struct ResultsRoom: View {
    let image: CalibratedImage
    let item: OpenItem
    @Environment(AppState.self) private var appState

    var body: some View {
        // One read of the ledger and of the state, here.
        let state = appState.resultsRoom
        let rows = ResultsLedger.rows(of: item)
        let sections = state.sections(rows)
        let shown = sections.reduce(0) { $0 + $1.rows.count }
        VStack(spacing: 0) {
            ResultsHeader(fileName: image.fileName, shown: shown, hidden: rows.count - shown,
                          session: ExportSnapshot.sessionSentence(of: item))
            Divider()
            if rows.isEmpty {
                ContentUnavailableView(ResultsFormat.emptyTitle, systemImage: "square.grid.2x2",
                                       description: Text(ResultsFormat.emptyDetail))
            } else if sections.isEmpty {
                ContentUnavailableView(ResultsFormat.allHiddenTitle, systemImage: "eye.slash",
                                       description: Text(ResultsFormat.allHiddenDetail))
            } else {
                ResultsTable(image: image, sections: sections, state: state)
            }
        }
        .onChange(of: item.id, initial: true) { state.attach(to: item.id) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("results.room")
    }
}

/// The header: what the table holds, and where the marks are kept.
private struct ResultsHeader: View {
    let fileName: String
    let shown: Int
    let hidden: Int
    let session: String

    var body: some View {
        HStack(spacing: LayoutPolicy.inspectorRowSpacing) {
            Text(ResultsFormat.summary(fileName: fileName, shown: shown, hidden: hidden))
                .font(.callout.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)
            Spacer(minLength: LayoutPolicy.inspectorRowSpacing)
            Text(session)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(session)
        }
        .padding(.horizontal, LayoutPolicy.infobarHorizontalPadding)
        .frame(height: LayoutPolicy.paneHeaderHeight)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("results.header")
    }
}

/// The native table: a `Section` per group, one row per result, the selection the state's.
private struct ResultsTable: View {
    let image: CalibratedImage
    let sections: [ResultsSection]
    @Bindable var state: ResultsRoomState

    var body: some View {
        Table(of: ResultRow.self, selection: $state.selection) {
            TableColumn("Result") { row in
                Text(row.label)
                    .lineLimit(1)
                    .accessibilityLabel(spoken(row))
                    .accessibilityIdentifier("results.row.\(row.id)")
            }
            .width(min: 110, ideal: 130)
            TableColumn("Value") { row in
                Text(value(row))
                    .monospacedDigit()
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(value(row))
            }
            .width(min: 120, ideal: 250)
            TableColumn("Source") { row in
                Text(ResultsFormat.source(row, imageWidth: image.width, imageHeight: image.height))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .width(min: 90, ideal: 190)
            TableColumn("Record") { row in
                Text(ResultsFormat.record(row))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .width(min: 60, ideal: 90)
            TableColumn("Validation") { row in
                Text(ResultsFormat.badge(row, notes: image.notes))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(ResultsFormat.validation(row))
            }
            .width(min: 130, ideal: 200)
        } rows: {
            ForEach(sections) { section in
                Section(ResultsFormat.title(section.group)) {
                    ForEach(section.rows) { row in TableRow(row) }
                }
            }
        }
        .onCopyCommand { copied() }
        .accessibilityIdentifier("results.table")
    }

    private func value(_ row: ResultRow) -> String { ResultsFormat.value(row, x: image.x, y: image.y) }

    private func spoken(_ row: ResultRow) -> String {
        ResultsFormat.spoken(row, value: value(row), badge: ResultsFormat.badge(row, notes: image.notes))
    }

    /// ⌘C: the selected rows' lines, in table order, one per line; nothing when nothing is selected.
    private func copied() -> [NSItemProvider] {
        let rows = state.selectedRows(in: sections.flatMap(\.rows))
        guard !rows.isEmpty else { return [] }
        let text = ResultsFormat.copyText(rows, image: image)
        return [NSItemProvider(object: text as NSString)]
    }
}
