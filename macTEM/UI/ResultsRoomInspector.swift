//
//  ResultsRoomInspector.swift
//  Role: the Results room's inspector content (V1-10 slice 3; archive: results-room-design-2026-10-15.md, section 3),
//        mounted by `WorkspaceInspector`'s Settings and Info switches.
//        Settings: Show (one switch per group), Session (the Image room's tail: where the marks are kept, Save to Session) and
//        Export (one full-width button: All results as CSV…, the twin of File > Export Results…, ⇧⌥⌘E).
//        Info: Result (the selected row: its name, value, source, record, how far it is trusted — the producer's sentence —
//        and every number with its unit as the CSV names it) and Source Image (the file, its size and calibration).
//
//  COST (design estimates, unverified on screen): Show 44 + 2 × 34 = 112 + 12; Session ~90 + 12; Export 44 + 12 — about 280 pt,
//  inside the 570 pt of a 915 × 640 window.
//
//  SKILL NOTES (swiftui-macos): observation.md "State Capture at Body Level" — the ledger and the availability are read once per
//  body; accessibility.md — every switch and the menu carry their titles.
//

import ShellInspector
import SwiftUI
#if canImport(TEMCore)
import TEMCore
import TEMSession
#endif

/// The room's Settings tab content.
struct ResultsRoomSettings: View {
    let image: CalibratedImage
    let item: OpenItem
    @Environment(AppState.self) private var appState

    var body: some View {
        let state = appState.resultsRoom
        let rows = ResultsLedger.rows(of: item)
        let availability = ExportSnapshot.availability(hasImage: appState.hasImage, area: appState.navigation.workspaceArea,
                                                       isLoading: appState.imageSession.isLoading,
                                                       profileHasSamples: false, resultRows: rows.count)
        InspectorSection("Show") {
            ForEach(ResultRow.Group.allCases, id: \.self) { group in
                InspectorRow("\(ResultsFormat.title(group)) · \(rows.filter { $0.group == group }.count)") {
                    Toggle(ResultsFormat.title(group), isOn: Binding(get: { state.isShown(group) },
                                                                     set: { state.setShown(group, $0) }))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .accessibilityIdentifier("results.show.\(group.rawValue)")
                }
            }
        }
        InspectorSection("Session") {
            ImageRoomSessionTail(item: item)
        }
        InspectorSection("Export") {
            InspectorActionRow {
                Button(ResultsExportButton.title) { ExportPanels.exportResults(appState: appState) }
                    .disabled(!availability.results)
                    .help(ResultsExportButton.help(enabled: availability.results, hasRows: !rows.isEmpty))
                    .accessibilityIdentifier("results.export")
            }
        }
    }
}

/// The Results room's one Export button, as data: a plain full-width button at the end of the inspector (control placement
/// standard), disabled with its reason as help.
nonisolated enum ResultsExportButton {
    static let title = "All results as CSV…"

    /// What the button does when it is on; why it is off otherwise.
    static func help(enabled: Bool, hasRows: Bool) -> String {
        guard !enabled else { return "Export every finished measurement of this file" }
        return hasRows ? "a read is running" : "nothing measured yet"
    }
}

/// The room's Info tab content: the selected result, then the image it was measured on.
struct ResultsRoomInfo: View {
    let image: CalibratedImage
    let item: OpenItem
    @Environment(AppState.self) private var appState

    var body: some View {
        let state = appState.resultsRoom
        let rows = ResultsLedger.rows(of: item)
        InspectorSection("Result") {
            if let row = state.selected(in: rows) {
                let value = ResultsFormat.value(row, x: image.x, y: image.y)
                InspectorValueRow("Result", row.label)
                InspectorValueRow("Value", value)
                InspectorValueRow("Source", ResultsFormat.source(row, imageWidth: image.width, imageHeight: image.height))
                InspectorValueRow("Record", ResultsFormat.record(row))
                InspectorValueRow("Trust", ResultsFormat.badge(row, notes: image.notes))
                InspectorNote(ResultsFormat.validation(row))
                ForEach(Array(row.entries.enumerated()), id: \.offset) { _, entry in
                    let field = ResultsFormat.field(entry)
                    InspectorValueRow(field.name, field.text, mono: true)
                }
                InspectorNote("Remove it in \(ResultsFormat.owner(row.group)).")
            } else {
                InspectorNote(state.selection.count > 1 ? ResultsFormat.severalSelected : ResultsFormat.noSelection)
            }
        }
        InspectorSection("Source Image") {
            InspectorValueRow("File", image.fileName)
            InspectorValueRow("Object", image.source)
            InspectorValueRow("Size", "\(image.width) × \(image.height) px")
            InspectorValueRow("x axis", ImageInfoFormat.axis(image.x))
            InspectorValueRow("y axis", ImageInfoFormat.axis(image.y))
            if !image.notes.isEmpty { InspectorValueRow("Notes", image.notes.joined(separator: "; ")) }
        }
    }
}
