//
//  IndexingRoomState.swift
//  Role: the Indexing room's own view state (the status line's readout, the export in flight). The room's facts
//        are `IndexingSession`'s (TEMSession); this holds only what the views share between the centre and the inspector. Window-wide,
//        not saved; composed by `AppState` as `PatternsRoomState` is.
//

import Foundation
import Observation
import UniformTypeIdentifiers
import TEMCore
import TEMSession

/// What the Indexing room's Export section writes (design §4): the map on screen as a PNG, the results as CSV, the orientations as EDAX
/// .ang and Oxford .ctf (the run's crystal map: Hough's, D-SEM-81, or the dictionary's, D-SEM-92), the run's method as JSON.
nonisolated enum IndexingExportKind: String, CaseIterable, Identifiable {
    case mapPNG, resultsCSV, ang, ctf, methodJSON
    var id: String { rawValue }
    var title: String {
        switch self {
        case .mapPNG: "Map PNG…"
        case .resultsCSV: "Results CSV…"
        case .ang: "EDAX ANG…"
        case .ctf: "Oxford CTF…"
        case .methodJSON: "Method JSON…"
        }
    }
    var fileExtension: String {
        switch self {
        case .mapPNG: "png"
        case .resultsCSV: "csv"
        case .ang: ANGWriter.fileExtension
        case .ctf: CTFWriter.fileExtension
        case .methodJSON: "json"
        }
    }
    var contentType: UTType {
        switch self {
        case .mapPNG: .png
        case .resultsCSV: .commaSeparatedText
        case .ang, .ctf: UTType(filenameExtension: fileExtension) ?? .plainText
        case .methodJSON: .json
        }
    }
    /// The file name's tail after the file's own name: "patterns_v2 indexed IPF-Z", "patterns_v2 indexing results".
    func suffix(layer: IndexingLayer) -> String {
        switch self {
        case .mapPNG: " indexed \(layer.title)"
        case .resultsCSV: " indexing results"
        case .ang, .ctf: " indexed"
        case .methodJSON: " indexing method"
        }
    }
}

@Observable
final class IndexingRoomState {
    /// The status line's cursor readout over the map; nil when the pointer is elsewhere.
    var readout: String?
    /// The export whose save panel is up, the layer its map is of, and its bytes (made before the panel opens, as the Patterns room's).
    var exporting: IndexingExportKind?
    private(set) var exportLayer = IndexingLayer.ipfZ
    private(set) var exportData = Data()

    /// Makes the bytes of `kind` from the session and opens the save panel, or, with `directory` (the UI journeys' export folder), writes the
    /// file there; says why when there is nothing to write.
    @MainActor func export(_ kind: IndexingExportKind, from session: IndexingSession, directory: URL? = nil, report: (String) -> Void) {
        guard let document = session.patterns.document else { report("Nothing to export yet: no dataset is open."); return }
        guard let result = session.result, result.reachedCount > 0 else { report("Nothing to export yet: Index has not run."); return }
        let data: Data
        do {
            switch kind {
            case .mapPNG:
                guard let rgba = session.mapRGBA,
                      let png = PatternsRoomState.mixPNG(rgba: rgba, width: result.scanColumns, height: result.scanRows) else {
                    report("Export failed: the map could not be encoded."); return
                }
                data = png
            case .resultsCSV:
                data = Data(result.csv(stepX: document.dataset.stepX, stepY: document.dataset.stepY).utf8)
            case .ang:
                guard let map = try session.crystalMap() else { report("Nothing to export yet: the run has not started."); return }
                let options = result.method == .dictionary ? IndexingResult.dictionaryAngOptions : IndexingResult.angOptions
                data = Data(try ANGWriter.text(of: map, options: options).utf8)
            case .ctf:
                guard let map = try session.crystalMap() else { report("Nothing to export yet: the run has not started."); return }
                let project = (document.fileName as NSString).deletingPathExtension
                data = Data(try CTFWriter.text(of: IndexingResult.ctfColumns(map), project: project).utf8)
            case .methodJSON:
                guard let json = try session.methodJSON() else { report("Nothing to export yet: the run has not started."); return }
                data = json
            }
        } catch {
            report("Export failed: \(error.localizedDescription)"); return
        }
        exportLayer = session.layer
        if let directory {
            let name = (document.fileName as NSString).deletingPathExtension + kind.suffix(layer: exportLayer)
            let url = directory.appendingPathComponent(name).appendingPathExtension(kind.fileExtension)
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
}
