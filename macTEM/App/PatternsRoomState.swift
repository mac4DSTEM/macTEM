//
//  PatternsRoomState.swift
//  Role: the Patterns room's own view state (the import request, the status line's readout, the export in flight). The room's facts are
//        `EBSDSession`'s (TEMSession); this holds only what the views share between the centre and the inspector. Window-wide, not saved;
//        composed by `AppState` as `EELSRoomState` is.
//

import Foundation
import ImagoCore
import Observation
import ShellSpectroscopy
import UniformTypeIdentifiers
import TEMCore
import TEMSession

/// What the Patterns room's Export section writes (design §4): the pattern on screen as a PNG (alone or with the Kikuchi overlay), the
/// overlay as CSV, the header as JSON.
nonisolated enum PatternsExportKind: String, CaseIterable, Identifiable {
    case mapPNG, patternPNG, overlayPNG, overlayCSV, metadataJSON, methodJSON
    var id: String { rawValue }
    var title: String {
        switch self {
        case .mapPNG: "Map PNG…"
        case .patternPNG: "Pattern PNG…"
        case .overlayPNG: "Pattern with Overlay…"
        case .overlayCSV: "Overlay CSV…"
        case .metadataJSON: "Metadata JSON…"
        case .methodJSON: "Method JSON…"
        }
    }
    var contentType: UTType {
        switch self {
        case .mapPNG, .patternPNG, .overlayPNG: .png
        case .overlayCSV: .commaSeparatedText
        case .metadataJSON, .methodJSON: .json
        }
    }
    /// The file name's tail after the file's own name: "patterns_v2 pattern r12 c40", "patterns_v2 map mean".
    func suffix(position: EBSDPosition, map: String = "") -> String {
        switch self {
        case .mapPNG: " map \(map)"
        case .patternPNG: " pattern r\(position.row) c\(position.column)"
        case .overlayPNG: " pattern r\(position.row) c\(position.column) overlay"
        case .overlayCSV: " overlay r\(position.row) c\(position.column)"
        case .metadataJSON: " metadata"
        case .methodJSON: " processing method"
        }
    }
}

@Observable
final class PatternsRoomState {
    /// Bumped by every "Open EBSD Dataset…" gesture; the room presents the open panel when it changes.
    private(set) var importRequest = 0
    /// The status line's cursor readout: the position and its mean over the map, the detector pixel over the pattern; nil when the pointer is elsewhere.
    var readout: String?
    /// What the pattern pane last wrote to `readout` (`setPatternReadout`).
    private var patternText: String?
    /// `readout` while it is the pattern pane's own (the detector pixel and its value under the pointer); nil while it is the scan map's position,
    /// or nothing. The pattern pane's accessibility value says this, so it never speaks the map's position as its own (#345).
    var patternReadout: String? { readout != nil && readout == patternText ? readout : nil }
    /// The export whose save panel is up, and the position it is of.
    var exporting: PatternsExportKind?
    private(set) var exportPosition = EBSDPosition.origin
    /// The map's name in the export's file name ("mean", "bse", "r2 c1", "mix").
    private(set) var exportMap = ""
    /// The bytes of the export in flight (made before the panel opens, as the EELS room's).
    private(set) var exportData = Data()
    /// The export the save panel is writing, as the session record keeps it once the panel says where (`didWrite`).
    @ObservationIgnored private(set) var pendingRecord: SEMExportedFile?
    /// Told of every file the room writes (`AppState` keeps it in the session record for the Results room and the report).
    @ObservationIgnored var onWritten: ((SEMExportedFile) -> Void)?

    /// The save panel wrote the export to `url`.
    func didWrite(to url: URL) {
        if let pendingRecord { onWritten?(pendingRecord.written(to: url, at: Date())) }
        pendingRecord = nil
    }

    func requestImport() { importRequest &+= 1 }

    /// The pattern pane's hover: the status line's readout, marked as the pattern pane's (`patternReadout`); nil when the pointer leaves the pattern.
    func setPatternReadout(_ text: String?) {
        patternText = text
        readout = text
    }

    /// Makes the bytes of `kind` from the session and opens the save panel, or, with `directory` (the UI journeys' export folder), writes the
    /// file there; says why when there is nothing to write.
    @MainActor func export(_ kind: PatternsExportKind, from session: EBSDSession, directory: URL? = nil, report: (String) -> Void) {
        guard let document = session.document else { report("Nothing to export yet: no dataset is open."); return }
        let data: Data
        do {
            switch kind {
            case .metadataJSON:
                data = try EBSDBrowsing.metadataJSON(document.dataset, fileName: document.fileName)
            case .methodJSON:
                data = try session.pipeline.methodJSON(fileName: document.fileName, dataset: document.dataset)
            case .patternPNG:
                guard let canvas = session.patternPresentation.canvas, let position = session.patternPosition else {
                    report("Nothing to export yet: no pattern is on screen."); return
                }
                exportPosition = position
                data = try Self.patternPNG(canvas: canvas, presentation: session.patternPresentation, dataset: document.dataset,
                                           fileName: document.fileName, position: position)
            case .overlayPNG:
                guard let canvas = session.patternPresentation.canvas, let position = session.patternPosition,
                      session.overlayOn, case .success(let overlay)? = session.overlay else {
                    report("Nothing to export yet: no Kikuchi overlay is on the pattern."); return
                }
                // The kinematical master pattern is made off the main actor: until it lands, the picture would leave the simulation out.
                if session.overlaySettings.kinematical, overlay.simulated == nil, session.isMakingOverlayMaster {
                    report("Nothing to export yet: the kinematical simulation is still being made.")
                    return
                }
                exportPosition = position
                let plain = try Self.patternPNG(canvas: canvas, presentation: session.patternPresentation, dataset: document.dataset,
                                                fileName: document.fileName, position: position)
                guard let png = KikuchiOverlayExport.png(patternPNG: plain, fileName: document.fileName, overlay: overlay,
                                                         settings: session.overlaySettings) else {
                    report("Export failed: the pattern with its overlay could not be encoded."); return
                }
                data = png
            case .overlayCSV:
                guard let position = session.patternPosition, session.overlayOn, let csv = session.overlayCSV else {
                    report("Nothing to export yet: no Kikuchi overlay is on the pattern."); return
                }
                exportPosition = position
                data = Data(csv.utf8)
            case .mapPNG:
                guard let canvas = session.mapPresentation.canvas else { report("Nothing to export yet: the map has not landed."); return }
                if session.mapChoice == .imageQuality || session.mapChoice == .dotProduct, session.chosenImage == nil {
                    report("Nothing to export yet: the quality maps have not landed."); return
                }
                exportMap = Self.mapName(session.mapChoice)
                if session.mapChoice == .mix, let rgba = session.mixRGBA {
                    guard let png = Self.mixPNG(rgba: rgba, width: canvas.width, height: canvas.height, fileName: document.fileName) else {
                        report("Export failed: the colour mix could not be encoded."); return
                    }
                    data = png
                } else {
                    data = try Self.mapPNG(canvas: canvas, presentation: session.mapPresentation, dataset: document.dataset, fileName: document.fileName,
                                           map: exportMap)
                }
            }
        } catch {
            report("Export failed: \(error.localizedDescription)"); return
        }
        let record = exportRecord(kind, data: data, session: session, fileName: document.fileName)
        if let directory {
            let name = (document.fileName as NSString).deletingPathExtension + kind.suffix(position: exportPosition, map: exportMap)
            let url = directory.appendingPathComponent(name).appendingPathExtension(kind.contentType.preferredFilenameExtension ?? "txt")
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try data.write(to: url)
                onWritten?(record.written(to: url, at: Date()))
                report("Exported \(url.lastPathComponent)")
            } catch {
                report("Export failed: \(error.localizedDescription)")
            }
            return
        }
        pendingRecord = record
        exportData = data
        exporting = kind
    }

    /// The export as the session record keeps it: what it is, the map or the position it is of, the methods that made it, the PNG's
    /// bytes.
    @MainActor private func exportRecord(_ kind: PatternsExportKind, data: Data, session: EBSDSession, fileName: String) -> SEMExportedFile {
        let position = SEMSessionField("Position", "row \(exportPosition.row) · col \(exportPosition.column)")
        let processing = SEMSessionLedger.processingMethods(session.pipeline)
        var fields: [SEMSessionField] = []
        var methods: [SEMMethod] = []
        switch kind {
        case .mapPNG:
            fields = [SEMSessionField("Map", exportMap)]
            switch session.mapChoice {
            case .mean: methods = [.patternReading]
            case .bse, .tile, .mix: methods = [.virtualBSE]
            case .imageQuality: methods = [.imageQuality]
            case .dotProduct: methods = [.averageDotProduct]
            }
        case .patternPNG:
            fields = [position, SEMSessionField("Pattern", session.patternDisplay.title)]
            methods = [.patternReading] + (session.patternDisplay == .raw ? [] : processing)
        case .overlayPNG, .overlayCSV:
            let overlay = session.overlaySettings
            let drawsSimulation = kind == .overlayPNG && overlay.kinematical && session.canDrawBandWidth
            // The Simulation section's words: Overlay, Blend (two decimals, as its slider), Min d, Band width, in one locale.
            fields = [position, SEMSessionField("Overlay", drawsSimulation ? "Kinematical" : "Geometrical")]
            if drawsSimulation { fields.append(SEMSessionField("Blend", Num.fixed(overlay.blend, 2))) }
            fields.append(SEMSessionField("Min d", "\(UnitDisplay.number(overlay.minDSpacing)) Å"))
            fields.append(SEMSessionField("Band width", overlay.bandWidth && session.canDrawBandWidth ? "On" : "Off"))
            methods = [.kikuchiOverlay] + (drawsSimulation ? [.kinematicalSimulation] : [])
        case .metadataJSON:
            methods = [.patternReading]
        case .methodJSON:
            methods = processing
        }
        let isPicture = kind == .mapPNG || kind == .patternPNG || kind == .overlayPNG
        return SEMExportedFile(room: "Patterns", what: SEMExportedFile.what(kind.title), source: fileName, fields: fields, methods: methods,
                               png: isPicture ? data : nil)
    }

    /// The colour mix's RGBA bytes as a PNG, one pixel per scan point, through the app's one encoder (`ImageExport.encodePNG`) with
    /// `fileName` as Title and macTEM as Software, as the map PNG carries them.
    nonisolated static func mixPNG(rgba: [UInt8], width: Int, height: Int, fileName: String) -> Data? {
        guard let image = EDXMapRaster.cgImage(rgba: rgba, width: width, height: height) else { return nil }
        return try? ImageExport.encodePNG(image, title: fileName, software: "macTEM")
    }

    static func mapName(_ choice: EBSDSession.MapChoice) -> String {
        switch choice {
        case .mean: "mean"
        case .bse: "bse"
        case .tile(let tile): tile.label
        case .mix: "mix"
        case .imageQuality: "image quality"
        case .dotProduct: "average dot product"
        }
    }

    /// The scan map as the pane shows it, one PNG pixel per scan point, through the Image room's exporter; the step is the pixel calibration.
    @MainActor static func mapPNG(canvas: CanvasPixels, presentation: ImagePresentation, dataset: EBSDDataset, fileName: String, map: String) throws -> Data {
        let unit = dataset.scanUnit
        let image = CalibratedImage(width: canvas.width, height: canvas.height, pixels: canvas.normalized,
                                    x: AxisCalibration(scale: dataset.stepX, unit: unit), y: AxisCalibration(scale: dataset.stepY, unit: unit),
                                    fileName: fileName, source: "scan map \(map)", voltage: dataset.sem.beamEnergyKeV.map { $0 * 1000 },
                                    notes: ["\(dataset.format.rawValue)"])
        let display = ExportSnapshot.display(canvas: canvas, presentation: presentation)
        return try ImageExport.render(source: ExportSource(image: image, software: "macTEM"), display: display, marks: [],
                                      options: ImageExport.Options(scaleBar: presentation.showsScaleBar, marks: false)).png
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
