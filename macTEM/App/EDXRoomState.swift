//
//  EDXRoomState.swift
//  Role: the EDX room's own view state (its spectrum window and the export in flight). The room's facts are
//        `EDXSession`'s (TEMSession); this holds only what the views share between the centre and the inspector.
//        Window-wide and not saved; composed by `AppState` as `ResultsRoomState` is.
//

import Foundation
import Observation
import ShellSpectroscopy
import SpectroCore
import UniformTypeIdentifiers
import TEMCore
import TEMSession

/// What the Export section writes: text (the results, the method, the spectrum as CSV or `.msa`, the pins) or the maps as a PNG.
nonisolated enum EDXExportKind: String, Identifiable, CaseIterable {
    case results, method, spectrum, spectrumMSA, pins, mapsPNG

    var id: String { rawValue }

    var title: String {
        switch self {
        case .results: "Results as CSV…"
        case .method: "Method as JSON…"
        case .spectrum: "Spectrum as CSV…"
        case .spectrumMSA: "Spectrum as MSA…"
        case .pins: "Pinned regions as CSV…"
        case .mapsPNG: "Maps as PNG…"
        }
    }

    var contentType: UTType {
        switch self {
        case .method: .json
        case .mapsPNG: .png
        case .spectrumMSA: UTType(filenameExtension: "msa") ?? .plainText
        default: .commaSeparatedText
        }
    }

    /// The file name's tail: "Sample Whole_map quantification".
    var suffix: String {
        switch self {
        case .results: " quantification"
        case .method: " method"
        case .spectrum, .spectrumMSA: " spectrum"
        case .pins: " pins"
        case .mapsPNG: " maps"
        }
    }
}

struct EDXHoverPixel: Equatable { var x: Int; var y: Int }

@Observable
final class EDXRoomState {
    /// The drawing tool of the header's picker.
    var tool: RegionTool = .pointer
    /// The tile shown alone after a double click (nil: the grid).
    var soloTile: String?
    /// The zoom and position every map shares (pinch, scroll, drag; a double click resets).
    var mapView = MapViewTransform()
    /// How the maps are coloured and the colour mix (the inspector's Maps section); window-wide, reset with a new file.
    var appearance = MapAppearance()
    /// The display filter of the wt%, at% and Thickness tiles (never of the net maps or the HAADF, never of a number).
    var mapFilter: EDXMapFilter = .mean3x3
    /// The pixel under the pointer on any map (its spectrum is the temporary layer); nil off the maps.
    var hoverPixel: EDXHoverPixel?
    /// The status line's cursor readout: the pixel and its value over a map, the energy and counts over the spectrum; nil when the pointer is elsewhere.
    var readout: String?
    /// Whether the Regions list's selection (and the heavier outline) belongs to a line, the last thing the person drew or picked, or to a region.
    var linesFocused = false
    /// Bumped by every "Open Spectrum Image…" gesture; the room presents the open panel when it changes.
    private(set) var importRequest = 0
    /// The export whose save panel is up, and its bytes (made before the panel opens: the pins and the figure are made off the click).
    var exporting: EDXExportKind?
    private(set) var exportData = Data()
    /// The energy window the spectrum shows, keV; nil = the automatic one (the picked elements' lines, or where the counts are).
    var window: ClosedRange<Double>?
    /// How far the counts axis is zoomed in (1: the automatic top).
    var yZoom = 1.0
    /// What the maps export draws besides the pictures.
    var exportScaleBar = true
    var exportRegions = true

    func requestImport() { importRequest &+= 1 }

    /// Makes the bytes of `kind` from the session and opens the save panel (or, with `directory`, the UI journeys' export folder, writes the file there
    /// as the other rooms' exports do); says why when there is nothing to write.
    @MainActor func export(_ kind: EDXExportKind, from session: EDXSession, directory: URL? = nil, report: (String) -> Void) async {
        let data: Data?
        switch kind {
        case .results: data = session.resultsCSV.map { Data($0.utf8) }
        case .method: data = session.methodJSON.map { Data($0.utf8) }
        case .spectrum: data = session.spectrumCSV.map { Data($0.utf8) }
        case .spectrumMSA:
            do { data = try session.spectrumMSA() } catch { report("MSA export failed: \(error.localizedDescription)"); return }
        case .pins: data = await session.pinsCSV().map { Data($0.utf8) }
        case .mapsPNG:
            let mixIDs = Set(EDXMapsComposition.selection(appearance.mix, scan: session.source?.scanImage, tiles: session.shownTiles))
            let mix = session.shownTiles.filter { mixIDs.contains($0.symbol) }
            data = session.figureContent(scaleBar: exportScaleBar, regions: exportRegions, mix: mix).flatMap { EDXMapsFigure.png($0) }
        }
        guard let data else { report("Nothing to export yet for \(kind.title.dropLast())."); return }
        if let directory {
            let url = directory.appendingPathComponent(session.exportStem + kind.suffix).appendingPathExtension(kind.contentType.preferredFilenameExtension ?? "txt")
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try data.write(to: url)
                report("Exported \(url.lastPathComponent)")
            } catch { report("Export failed: \(error.localizedDescription)") }
            return
        }
        exportData = data
        exporting = kind
    }
}
