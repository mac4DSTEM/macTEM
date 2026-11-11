//
//  PatternsRoomInspector.swift
//  Role: the Patterns room's inspector content, mounted by `WorkspaceInspector`'s Settings and Info switches, in the Image room's order
//        (control placement §2; design §4; processing: pattern-processing.md §3): Calibration (the geometry the file states, as value rows), Display (`PaneDisplaySection`: a Map · Pattern
//        switch over the picked picture's colormap, window, gamma and scale bar, so the two keep their own contrast), Virtual images (the detector grid, the map's image, the colour mix, the tiles pane), the processing stages (`PatternsProcessingSections`),
//        Simulation (the Kikuchi overlay, `PatternsSimulationOverlay.swift`) and Export (the map and the pattern on screen as PNG, the header as JSON). Info: what the file is (design §5). Presentation only: the rows are
//        `EBSDBrowsing`'s (TEMCore), the state `EBSDSession`'s (TEMSession).
//

import ShellControls
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
            PaneDisplaySection(map: session.mapPresentation, pattern: session.patternPresentation, room: "patterns",
                               mapColormapID: "patterns.colormap", patternColormapID: "patterns.pattern.colormap")
            PatternsVirtualImagesSection(session: session, dataset: dataset)
            PatternsProcessingSections(session: session, dataset: dataset)
            PatternsSimulationSection(session: session)
            PatternsExportSection(session: session, state: appState.patternsRoom)
        } else {
            ContentUnavailableView("No EBSD dataset open", systemImage: "square.grid.3x3.square",
                                   description: Text("Open an h5ebsd pattern file to browse its patterns. Its controls appear here."))
        }
    }
}

/// Virtual images (design §4, north star F1): the detector grid, which image the map shows, the three tiles of the colour mix, the tiles pane.
struct PatternsVirtualImagesSection: View {
    let session: EBSDSession
    let dataset: EBSDDataset

    /// The grids offered: the whole detector, 3 x 3, 5 x 5 (kikuchipy's default), 7 x 7; one the pattern is too small for is left out.
    private var grids: [Int] { [1, 3, 5, 7].filter { $0 <= min(dataset.patternRows, dataset.patternColumns) } }

    var body: some View {
        let landed = session.virtualImages != nil
        InspectorSection("Virtual images") {
            SegmentedPicker(label: "Grid", items: grids.map { n in (n, .title(n == 1 ? "1" : "\(n) × \(n)", help: n == 1 ? "The whole detector: the virtual BSE" : "The detector cut into \(n) by \(n) tiles")) },
                            selection: Binding(get: { session.virtualGrid.rows }, set: { session.setVirtualGrid(VirtualBSEGrid($0)) }))
                .accessibilityIdentifier("patterns.grid")
            InspectorRow("Map") {
                Picker("Map", selection: Binding(get: { session.mapChoice }, set: { session.showMap($0) })) {
                    ForEach(PatternsRoomState.mapMenu(session.virtualGrid, hasMix: session.hasMix), id: \.self) { entry in
                        switch entry {
                        case .map(let choice, let title): Text(title).tag(choice)
                        case .divider: Divider()
                        }
                    }
                }
                .labelsHidden()
                .disabled(!landed)
                .help(landed ? "The image the scan map draws" : "Waiting for the pass over the scan")
                .accessibilityIdentifier("patterns.map.choice")
            }
            if session.mapChoice == .imageQuality || session.mapChoice == .dotProduct {
                InspectorNote("Of the patterns as stored, before any background is removed. Image quality: the FFT spectrum's inertia (Krieger Lassen); average dot product: with the four nearest neighbours (kikuchipy's defaults).")
            }
            if session.virtualGrid.tileCount > 1 {
                ForEach(Array(["Red", "Green", "Blue"].enumerated()), id: \.offset) { channel, name in
                    InspectorRow(name) {
                        Picker(name, selection: Binding(get: { session.mixTiles[channel] }, set: { session.setMixTile($0, channel: channel) })) {
                            Text("None").tag(VirtualBSETile?.none)
                            ForEach(session.virtualGrid.tiles) { tile in Text(tile.label).tag(VirtualBSETile?.some(tile)) }
                        }
                        .labelsHidden()
                        .disabled(!landed)
                        .help("The tile summed into the \(name.lowercased()) channel of the colour mix")
                        .accessibilityIdentifier("patterns.mix.\(name.lowercased())")
                    }
                }
                InspectorNote(session.hasMix ? "The colour mix: each channel normalised to its median and spread, then the three rescaled together (kikuchipy)."
                              : "Pick a tile for each of red, green and blue to see the colour mix on the map.")
            }
            InspectorRow("Tiles") {
                Toggle("Show the tiles", isOn: Binding(get: { session.showsTiles }, set: { session.showsTiles = $0 }))
                    .toggleStyle(.switch).labelsHidden()
                    .help("Every tile's image in a pane under the map; a click makes it the map")
                    .accessibilityIdentifier("patterns.tiles")
            }
        }
    }
}

/// Export (closed until opened, as the image rooms'): the pattern on screen, the Kikuchi overlay over it, and the header.
struct PatternsExportSection: View {
    @Environment(AppState.self) private var appState
    let session: EBSDSession
    let state: PatternsRoomState

    var body: some View {
        InspectorSection("Export", startsExpanded: false) {
            InspectorActionRow {
                Button(PatternsExportKind.mapPNG.title) { export(.mapPNG) }
                    .disabled(session.mapPresentation.canvas == nil)
                    .help("The scan map on screen (the mean, a tile or the colour mix) as a PNG, one pixel per scan point")
                    .accessibilityIdentifier("patterns.export.map")
                Button(PatternsExportKind.patternPNG.title) { export(.patternPNG) }
                    .disabled(session.patternPresentation.canvas == nil)
                    .help("The pattern on screen as a PNG, one pixel per detector pixel, with its colormap and contrast")
                    .accessibilityIdentifier("patterns.export.pattern")
                Button(PatternsExportKind.overlayPNG.title) { export(.overlayPNG) }
                    .disabled(!session.overlayOn || session.overlayCSV == nil || session.patternPresentation.canvas == nil)
                    .help("The pattern with the Kikuchi overlay as drawn (bands, edges, zone axes and labels), enlarged so the labels read")
                    .accessibilityIdentifier("patterns.export.overlayPNG")
                Button(PatternsExportKind.overlayCSV.title) { export(.overlayCSV) }
                    .disabled(!session.overlayOn || session.overlayCSV == nil)
                    .help("The overlay's band lines (hkl, ends in detector pixels, θ) and zone axes (uvw, position) as CSV, for a figure made elsewhere")
                    .accessibilityIdentifier("patterns.export.overlayCSV")
                Button(PatternsExportKind.metadataJSON.title) { export(.metadataJSON) }
                    .help("The scan, pattern and detector header as the reader holds it, as JSON")
                    .accessibilityIdentifier("patterns.export.metadata")
                Button(PatternsExportKind.methodJSON.title) { export(.methodJSON) }
                    .help("Every processing stage with its parameters in kikuchipy's names, to redo the run in Python")
                    .accessibilityIdentifier("patterns.export.method")
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
                    InspectorNote(session.processed == nil ? "Patterns are as the file stores them; Process runs the Processing stages over the scan."
                                  : "The scan is processed in memory; the file is unchanged.")
                }
            }
        } else {
            ContentUnavailableView("No EBSD dataset open", systemImage: "square.grid.3x3.square",
                                   description: Text("The file, its scan and its detector appear here."))
        }
    }
}
