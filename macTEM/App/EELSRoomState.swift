//
//  EELSRoomState.swift
//  Role: the EELS room's own view state (the import request, the Maps control, the zoom the maps share, the tool, the export in flight, the status line's
//        readout). The room's facts are `EELSSession`'s (TEMSession); this holds only what the views share between the centre and the inspector.
//        Window-wide, not saved; composed by `AppState` as `EDXRoomState` is.
//

import Foundation
import Observation
import UniformTypeIdentifiers
import ShellSpectroscopy
import TEMCore
import TEMSession
import ShellEDXModel

@Observable
final class EELSRoomState {
    /// Bumped by every "Open EELS Spectrum Image…" gesture; the room presents the open panel when it changes.
    private(set) var importRequest = 0
    /// The tile shown alone (nil: the block). Kept with `tileSize` for the old room's tests; delete `tileSize` with them.
    var tileSize: MapTileSize = .medium
    var soloTile: String?
    /// The zoom and position every map shares (pinch, scroll, drag; a double click resets).
    var mapView = MapViewTransform()
    /// How the maps are coloured (the scale bar's popover); window-wide, reset with a new file.
    var appearance = MapAppearance()
    /// The drawing tool (the inspector's Tools section) and whether the Regions list's selection belongs to a line (the last thing touched).
    var tool: RegionTool = .pointer
    var linesFocused = false
    /// The Maps control's pick, and the sentence for a segment the person tried while it was off (cleared by the next pick).
    var maps: EELSMapsSegment = .tOverLambda
    var mapsNotice: String?
    /// The status line's cursor readout: the pixel and its values over a map, the energy and counts over the spectrum; nil when the pointer is elsewhere.
    var readout: String?
    /// The spectrum's counts axis: log (the room's default) or linear.
    var spectrumIsLog = true
    /// The spectrum's energy window (nil: the whole axis) and its counts zoom (1: the automatic top), as the EDS spectrum's `window` and `yZoom`.
    var spectrumWindow: ClosedRange<Double>?
    var spectrumYZoom = 1.0
    /// The export whose save panel is up.
    var exporting: EELSExportKind?
    /// The bytes of the export in flight (made before the panel opens, as the EDS room's).
    private(set) var exportData = Data()
    /// What the maps export draws besides the pictures: the scale bar (when the file states a pixel size) and the selected region.
    var exportScaleBar = true
    var exportRegions = true

    /// Makes the bytes of `kind` and opens the save panel, or, with `directory` (the UI journeys' export folder), writes the file there; says why when there
    /// is nothing to write. The EDS room's `EDXRoomState.export`.
    @MainActor func export(_ kind: EELSExportKind, from session: EELSSession, maps: [EELSMapTile], directory: URL? = nil, report: (String) -> Void) {
        let data: Data?
        switch kind {
        case .results: data = session.resultsCSV.map { Data($0.utf8) }
        case .spectrum: data = session.spectrumCSV.map { Data($0.utf8) }
        case .regions: data = session.regionsCSV.map { Data($0.utf8) }
        case .diagnostics: data = session.diagnosticsCSV.map { Data($0.utf8) }
        case .method: data = session.methodJSON.map { Data($0.utf8) }
        case .mapsPNG:
            let chosen = Set(EELSMixComposition.selection(appearance.mix, maps: maps))
            data = session.figureContent(maps: maps, mix: maps.filter { chosen.contains($0.id) }, appearance: appearance, scaleBar: exportScaleBar, regions: exportRegions)
                .flatMap { EDXMapsFigure.png($0) }
        }
        guard let data else { report("Nothing to export yet for \(kind.title.dropLast())."); return }
        if let directory {
            let url = directory.appendingPathComponent((session.fileName as NSString).deletingPathExtension + kind.suffix)
                .appendingPathExtension(kind.contentType.preferredFilenameExtension ?? "txt")
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

    func requestImport() { importRequest &+= 1 }

    /// A new file starts the view over.
    func reset() {
        soloTile = nil; mapView.reset(); appearance = MapAppearance(); maps = .tOverLambda; mapsNotice = nil; readout = nil; spectrumWindow = nil; spectrumYZoom = 1
    }
}
