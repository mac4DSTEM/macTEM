//
//  PatternsRoomState.swift
//  Role: the Patterns room's own view state (the import request, the status line's readout, the export in flight). The room's facts are
//        `EBSDSession`'s (TEMSession); this holds only what the views share between the centre and the inspector. Window-wide, not saved;
//        composed by `AppState` as `EELSRoomState` is.
//

import Foundation
import Observation
import UniformTypeIdentifiers
import TEMCore
import TEMSession

/// What the Patterns room's Export section writes (design §4): the pattern on screen as a PNG, the header as JSON.
nonisolated enum PatternsExportKind: String, CaseIterable, Identifiable {
    case patternPNG, metadataJSON
    var id: String { rawValue }
    var title: String {
        switch self {
        case .patternPNG: "Pattern PNG…"
        case .metadataJSON: "Metadata JSON…"
        }
    }
    var contentType: UTType {
        switch self {
        case .patternPNG: .png
        case .metadataJSON: .json
        }
    }
    /// The file name's tail after the file's own name: "patterns_v2 pattern r12 c40".
    func suffix(position: EBSDPosition) -> String {
        switch self {
        case .patternPNG: " pattern r\(position.row) c\(position.column)"
        case .metadataJSON: " metadata"
        }
    }
}

@Observable
final class PatternsRoomState {
    /// Bumped by every "Open EBSD Dataset…" gesture; the room presents the open panel when it changes.
    private(set) var importRequest = 0
    /// The status line's cursor readout: the position and its mean over the map, the detector pixel over the pattern; nil when the pointer is elsewhere.
    var readout: String?
    /// The export whose save panel is up, and the position it is of.
    var exporting: PatternsExportKind?
    private(set) var exportPosition = EBSDPosition.origin
    /// The bytes of the export in flight (made before the panel opens, as the EELS room's).
    private(set) var exportData = Data()

    func requestImport() { importRequest &+= 1 }

    /// Makes the bytes of `kind` from the session and opens the save panel, or, with `directory` (the UI journeys' export folder), writes the
    /// file there; says why when there is nothing to write.
    @MainActor func export(_ kind: PatternsExportKind, from session: EBSDSession, directory: URL? = nil, report: (String) -> Void) {
        guard let document = session.document else { report("Nothing to export yet: no dataset is open."); return }
        let data: Data
        do {
            switch kind {
            case .metadataJSON:
                data = try EBSDBrowsing.metadataJSON(document.dataset, fileName: document.fileName)
            case .patternPNG:
                guard let canvas = session.patternPresentation.canvas, let position = session.patternPosition else {
                    report("Nothing to export yet: no pattern is on screen."); return
                }
                exportPosition = position
                data = try Self.patternPNG(canvas: canvas, presentation: session.patternPresentation, dataset: document.dataset,
                                           fileName: document.fileName, position: position)
            }
        } catch {
            report("Export failed: \(error.localizedDescription)"); return
        }
        if let directory {
            let name = (document.fileName as NSString).deletingPathExtension + kind.suffix(position: exportPosition)
            let url = directory.appendingPathComponent(name).appendingPathExtension(kind.contentType.preferredFilenameExtension ?? "txt")
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try data.write(to: url)
                report("Exported \(url.lastPathComponent)")
            } catch {
                report("Export failed: \(error.localizedDescription)")
            }
            return
        }
        exportData = data
        exporting = kind
    }

    /// The pattern as the pane shows it (its colormap, window and gamma), one PNG pixel per detector pixel, through the Image room's exporter.
    @MainActor static func patternPNG(canvas: CanvasPixels, presentation: ImagePresentation, dataset: EBSDDataset, fileName: String,
                                      position: EBSDPosition) throws -> Data {
        let pixels = canvas.normalized   // the display copy is what the exporter maps; the raw range is in the metadata
        let image = CalibratedImage(width: canvas.width, height: canvas.height, pixels: pixels, x: nil, y: nil,
                                    fileName: fileName, source: "pattern row \(position.row) col \(position.column)", voltage: dataset.sem.beamEnergyKeV.map { $0 * 1000 },
                                    notes: ["\(dataset.format.rawValue)"])
        let display = ExportSnapshot.display(canvas: canvas, presentation: presentation)
        return try ImageExport.render(source: ExportSource(image: image, software: "macTEM"), display: display, marks: [],
                                      options: ImageExport.Options(scaleBar: false, marks: false)).png
    }
}
