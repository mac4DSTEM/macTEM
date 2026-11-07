//
//  PatternsRoomState.swift
//  Role: the Patterns room's own view state (the import request, the status line's readout, the export in flight). The room's facts are
//        `EBSDSession`'s (TEMSession); this holds only what the views share between the centre and the inspector. Window-wide, not saved;
//        composed by `AppState` as `EELSRoomState` is.
//

import Foundation
import ImageIO
import ImagoCore
import Observation
import ShellSpectroscopy
import UniformTypeIdentifiers
import TEMCore
import TEMSession

/// What the Patterns room's Export section writes (design §4): the pattern on screen as a PNG, the header as JSON.
nonisolated enum PatternsExportKind: String, CaseIterable, Identifiable {
    case mapPNG, patternPNG, metadataJSON, methodJSON
    var id: String { rawValue }
    var title: String {
        switch self {
        case .mapPNG: "Map PNG…"
        case .patternPNG: "Pattern PNG…"
        case .metadataJSON: "Metadata JSON…"
        case .methodJSON: "Method JSON…"
        }
    }
    var contentType: UTType {
        switch self {
        case .mapPNG, .patternPNG: .png
        case .metadataJSON, .methodJSON: .json
        }
    }
    /// The file name's tail after the file's own name: "patterns_v2 pattern r12 c40", "patterns_v2 map mean".
    func suffix(position: EBSDPosition, map: String = "") -> String {
        switch self {
        case .mapPNG: " map \(map)"
        case .patternPNG: " pattern r\(position.row) c\(position.column)"
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
    /// The export whose save panel is up, and the position it is of.
    var exporting: PatternsExportKind?
    private(set) var exportPosition = EBSDPosition.origin
    /// The map's name in the export's file name ("mean", "bse", "r2 c1", "mix").
    private(set) var exportMap = ""
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
            case .methodJSON:
                data = try session.pipeline.methodJSON(fileName: document.fileName, dataset: document.dataset)
            case .patternPNG:
                guard let canvas = session.patternPresentation.canvas, let position = session.patternPosition else {
                    report("Nothing to export yet: no pattern is on screen."); return
                }
                exportPosition = position
                data = try Self.patternPNG(canvas: canvas, presentation: session.patternPresentation, dataset: document.dataset,
                                           fileName: document.fileName, position: position)
            case .mapPNG:
                guard let canvas = session.mapPresentation.canvas else { report("Nothing to export yet: the map has not landed."); return }
                if session.mapChoice == .imageQuality || session.mapChoice == .dotProduct, session.chosenImage == nil {
                    report("Nothing to export yet: the quality maps have not landed."); return
                }
                exportMap = Self.mapName(session.mapChoice)
                if session.mapChoice == .mix, let rgba = session.mixRGBA {
                    guard let png = Self.mixPNG(rgba: rgba, width: canvas.width, height: canvas.height) else {
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
        if let directory {
            let name = (document.fileName as NSString).deletingPathExtension + kind.suffix(position: exportPosition, map: exportMap)
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

    /// The colour mix's RGBA bytes as a PNG (ImageIO), one pixel per scan point.
    nonisolated static func mixPNG(rgba: [UInt8], width: Int, height: Int) -> Data? {
        guard let image = EDXMapRaster.cgImage(rgba: rgba, width: width, height: height) else { return nil }
        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(encoded as CFMutableData, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? encoded as Data : nil
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
