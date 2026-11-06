//
//  PatternsRoomInspector.swift
//  Role: the Patterns room's inspector content, mounted by `WorkspaceInspector`'s Settings and Info switches, in the Image room's order
//        (control placement §2; design §4): Calibration (the geometry the file states, as value rows), Display (the map's colormap, window,
//        gamma and scale bar), Pattern Display (the pattern pane's own, so the two pictures keep their own contrast) and Export (the
//        pattern on screen as PNG, the header as JSON). Info: what the file is (design §5). Presentation only: the rows are
//        `EBSDBrowsing`'s (TEMCore), the state `EBSDSession`'s (TEMSession).
//

import ShellInspector
import ShellLayout
import SwiftUI
import TEMCore
import TEMSession

struct PatternsRoomSettings: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let session = appState.ebsd
        if let dataset = session.dataset {
            InspectorSection("Calibration") {
                ForEach(EBSDBrowsing.calibrationRows(dataset)) { row in
                    InspectorValueRow(row.label, row.value)
                        .accessibilityIdentifier("patterns.calibration.\(row.key)")
                }
                InspectorNote("The file's own values. The projection centre is shown in the Bruker convention, as kikuchipy stores it.")
            }
            ImageRoomDisplaySection(presentation: session.mapPresentation, colormapID: "patterns.colormap")
            ImageRoomDisplaySection(presentation: session.patternPresentation, title: "Pattern Display", colormapID: "patterns.pattern.colormap")
            PatternsExportSection(session: session, state: appState.patternsRoom)
        } else {
            ContentUnavailableView("No EBSD dataset open", systemImage: "square.grid.3x3.square",
                                   description: Text("Open an h5ebsd pattern file to browse its patterns. Its controls appear here."))
        }
    }
}

/// Export (closed until opened, as the image rooms'): the pattern on screen and the header.
struct PatternsExportSection: View {
    @Environment(AppState.self) private var appState
    let session: EBSDSession
    let state: PatternsRoomState

    var body: some View {
        InspectorSection("Export", startsExpanded: false) {
            InspectorActionRow {
                Button(PatternsExportKind.patternPNG.title) { export(.patternPNG) }
                    .disabled(session.patternPresentation.canvas == nil)
                    .help("The pattern on screen as a PNG, one pixel per detector pixel, with its colormap and contrast")
                    .accessibilityIdentifier("patterns.export.pattern")
                Button(PatternsExportKind.metadataJSON.title) { export(.metadataJSON) }
                    .help("The scan, pattern and detector header as the reader holds it, as JSON")
                    .accessibilityIdentifier("patterns.export.metadata")
            }
        }
    }

    private func export(_ kind: PatternsExportKind) {
        state.export(kind, from: session, directory: appState.exportDirectory, report: { appState.statusText = $0 })
    }
}

struct PatternsRoomInfo: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let session = appState.ebsd
        if let document = session.document {
            InspectorSection("Dataset") {
                ForEach(EBSDBrowsing.infoRows(document.dataset, fileName: document.fileName)) { row in
                    InspectorValueRow(row.label, row.value)
                }
                if document.dataset.format == .generated {
                    InspectorNote("A generated demo dataset, not data: six grains of cosine bands with fixed-seed noise.")
                } else {
                    InspectorNote("Patterns are as the file stores them (no background correction yet).")
                }
            }
        } else {
            ContentUnavailableView("No EBSD dataset open", systemImage: "square.grid.3x3.square",
                                   description: Text("The file, its scan and its detector appear here."))
        }
    }
}
