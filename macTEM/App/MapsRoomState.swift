//
//  MapsRoomState.swift
//  Role: the Maps room's own view state (the import request, the status line's readout, the export in flight) and its words
//        (`MapsRoomFormat`) and figure (`MapsFigure`: the map with its colour key or phase legend and a scale bar, as one PNG). The room's
//        facts are `OrientationMapSession`'s (TEMSession); the pictures and the hover's words `OrientationMaps`' (TEMCore). Window-wide,
//        not saved; composed by `AppState` as `PatternsRoomState` is.
//

import CoreGraphics
import CoreText
import Foundation
import ImageIO
import ImagoCore
import Observation
import ShellMetal
import UniformTypeIdentifiers
import TEMCore
import TEMSession

@Observable
final class MapsRoomState {
    /// Bumped by every "Open Orientation Map…" gesture; the room presents the open panel when it changes.
    private(set) var importRequest = 0
    /// The status line's cursor readout over the map; nil when the pointer is elsewhere.
    var readout: String?
    /// Whether the save panel is up, and the bytes it writes (made before it opens, as the Patterns room's).
    var isExporting = false
    private(set) var exportData = Data()
    private(set) var exportName = ""
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

    /// Makes the map figure of the shown layer and opens the save panel, or, with `directory` (the UI journeys' export folder), writes it
    /// there; says why when there is nothing to write.
    @MainActor func exportMap(from session: OrientationMapSession, directory: URL? = nil, report: (String) -> Void) {
        guard let document = session.document, let raster = session.raster else {
            report("Nothing to export yet: the map has not landed."); return
        }
        let name = (document.fileName as NSString).deletingPathExtension + " map " + session.layer.title
        let data: Data
        do {
            data = try MapsFigure.png(raster: raster, layer: session.layer, map: document.map, keys: session.keys,
                                      presentation: session.propertyPresentation, fileName: document.fileName)
        } catch {
            report("Export failed: \(error.localizedDescription)"); return
        }
        let layer = session.layer
        let record = SEMExportedFile(room: "Maps", what: "Map PNG", source: document.fileName, fields: [SEMSessionField("Layer", layer.title)],
                                     methods: layer.isColour && layer != .phase ? [.orientationMap, .ipfColours] : [.orientationMap], png: data)
        if let directory {
            let url = directory.appendingPathComponent(name).appendingPathExtension("png")
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
        exportName = name
        isExporting = true
    }
}

// MARK: - Words

nonisolated enum MapsRoomFormat {
    /// The toolbar's detail: "100 × 117 · 2 phases".
    static func capsuleDetail(_ map: CrystalMap) -> String {
        let (rows, columns) = OrientationMaps.gridShape(map)
        let phases = indexedPhases(map).count
        return "\(rows) × \(columns) · \(phases) \(phases == 1 ? "phase" : "phases")"
    }

    /// The indexed phases of the map's points, in id order.
    static func indexedPhases(_ map: CrystalMap) -> [(id: Int, phase: CrystalPhase)] {
        map.phasesInData.entries.filter { $0.id != PhaseList.notIndexedID }
    }

    /// "Map · IPF-Z", "Map · Phase", "Map · iq".
    static func mapTitle(_ layer: OrientationMapLayer) -> String { "Map · " + layer.title }

    /// A phase's name as the room writes it: the file's, or "phase 2" for an unnamed one.
    static func phaseName(_ phase: CrystalPhase, id: Int) -> String { phase.name.isEmpty ? "phase \(id)" : phase.name }

    /// The Info tab (design §5): what the map is, where it came from and how its colours are made.
    static func infoRows(_ document: OrientationMapSession.Document) -> [EBSDBrowsing.Row] {
        let map = document.map
        let (rows, columns) = OrientationMaps.gridShape(map)
        let unit = EBSDBrowsing.unitLabel(map.scanUnit)
        var out = [
            EBSDBrowsing.Row("File", document.fileName),
            EBSDBrowsing.Row("Format", document.format),
            EBSDBrowsing.Row("Source", document.source == .patterns ? "The pattern file's crystal map" : "The map file alone (no patterns)"),
            EBSDBrowsing.Row("Map", "\(rows) × \(columns)"),
            EBSDBrowsing.Row("Step", "\(UnitDisplay.number(map.dx)) \(unit) × \(UnitDisplay.number(map.dy)) \(unit)"),
            EBSDBrowsing.Row("Points", "\(map.size)"),
        ]
        let notIndexed = map.phaseIDs.filter { $0 == PhaseList.notIndexedID }.count
        out.append(EBSDBrowsing.Row("Not indexed", "\(notIndexed)"))
        let ids = map.phaseIDs
        for (id, phase) in indexedPhases(map) {
            let count = ids.filter { $0 == id }.count
            out.append(EBSDBrowsing.Row("Phase", "\(phaseName(phase, id: id)) · \(phase.pointGroupName ?? "no point group") · \(count) points"))
        }
        out.append(EBSDBrowsing.Row("Euler angles", "Bunge (φ₁, Φ, φ₂), lab to crystal, as orix reads the file"))
        out.append(EBSDBrowsing.Row("IPF colours", "TSL key of each phase's Laue group (Nolze and Hielscher 2016), as orix 0.15.0"))
        out.append(EBSDBrowsing.Row("Phase colours", "orix's phase list (matplotlib Tableau colours)"))
        return out
    }
}

// MARK: - The figure

/// The map as a figure: the shown layer at a whole number of pixels per point, a scale bar under it, and on the right the colour key of
/// each phase (an IPF layer), the phase legend (Phase) or the value range (a property), on white. One PNG, drawn with Core Graphics.
nonisolated enum MapsFigure {
    struct Failure: Error, LocalizedError {
        let text: String
        var errorDescription: String? { text }
    }

    /// The pixels per map point: the map at least `minimumWidth` pixels wide, at most `maximumWidth`.
    static func scale(columns: Int, minimumWidth: Int = 600, maximumWidth: Int = 4096) -> Int {
        guard columns > 0 else { return 1 }
        let up = (minimumWidth + columns - 1) / columns
        return max(1, min(up, maximumWidth / columns))
    }

    /// A round scale bar length near a fifth of `span`: 1, 2 or 5 times a power of ten.
    static func niceLength(_ span: Double) -> Double {
        guard span > 0, span.isFinite else { return 0 }
        let target = span / 5
        let power = pow(10, floor(log10(target)))
        for m in [5.0, 2, 1] where m * power <= target { return m * power }
        return power
    }

    /// An image of premultiplied RGBA bytes.
    static func cgImage(premultipliedRGBA rgba: [UInt8], width: Int, height: Int) -> CGImage? {
        guard width > 0, height > 0, rgba.count == width * height * 4,
              let provider = CGDataProvider(data: Data(rgba) as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider, decode: nil,
                       shouldInterpolate: false, intent: .defaultIntent)
    }

    /// The colour layer's map image (its RGBA is straight alpha that is 0 only on black, so it is premultiplied as it stands).
    static func mapImage(_ raster: OrientationMapRaster) -> CGImage? {
        raster.rgba8.flatMap { cgImage(premultipliedRGBA: $0, width: raster.columns, height: raster.rows) }
    }

    @MainActor static func png(raster: OrientationMapRaster, layer: OrientationMapLayer, map: CrystalMap, keys: [OrientationMapSession.PhaseKey],
                               presentation: ImagePresentation, fileName: String) throws -> Data {
        let s = scale(columns: raster.columns)
        let mapW = raster.columns * s, mapH = raster.rows * s
        let margin = 16, legendW = 220, barRoom = 36
        let width = margin + mapW + margin + legendW + margin
        let legendH = legendHeight(layer: layer, map: map, keys: keys, width: legendW)
        let height = margin + max(mapH + barRoom, legendH) + margin
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw Failure(text: "The figure could not be drawn.") }
        // Top-left coordinates throughout: y grows down. Text is drawn through `text`, which flips it back.
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.interpolationQuality = .none

        let mapRect = CGRect(x: margin, y: margin, width: mapW, height: mapH)
        let picture: CGImage?
        if layer.isColour {
            picture = mapImage(raster)
        } else if let canvas = presentation.canvas {
            picture = propertyImage(canvas: canvas, presentation: presentation)
        } else {
            picture = nil
        }
        guard let picture else { throw Failure(text: "The map has no picture to export.") }
        draw(picture, in: mapRect, ctx: ctx)

        // The scale bar under the map, from the step.
        let step = map.dx
        if step > 0 {
            let length = niceLength(Double(raster.columns) * step)
            let barW = CGFloat(length / step) * CGFloat(s)
            let y = mapRect.maxY + 12
            ctx.setFillColor(CGColor(gray: 0, alpha: 1))
            ctx.fill(CGRect(x: mapRect.minX, y: y, width: barW, height: 4))
            text("\(UnitDisplay.number(length)) \(EBSDBrowsing.unitLabel(map.scanUnit))", at: CGPoint(x: mapRect.minX + barW + 8, y: y - 4), size: 12, ctx: ctx)
        }

        // The legend.
        var y = CGFloat(margin)
        let x = CGFloat(margin + mapW + margin)
        switch layer {
        case .ipf(let direction):
            for key in keys {
                text("\(key.name) · IPF-\(direction.rawValue.uppercased())", at: CGPoint(x: x, y: y), size: 12, ctx: ctx)
                y += 18
                let w = CGFloat(legendW - 20), h = w * CGFloat(key.image.height) / CGFloat(max(key.image.width, 1))
                if let image = cgImage(premultipliedRGBA: key.image.premultipliedRGBA8, width: key.image.width, height: key.image.height) {
                    ctx.interpolationQuality = .high
                    draw(image, in: CGRect(x: x, y: y, width: w, height: h), ctx: ctx)
                    ctx.interpolationQuality = .none
                }
                for label in key.labels {
                    let px = x + CGFloat(label.column) * w / CGFloat(key.image.width)
                    let py = y + CGFloat(label.row) * h / CGFloat(key.image.height)
                    text(label.text, at: CGPoint(x: px - 12, y: py + 2), size: 10, ctx: ctx)
                }
                y += h + 22
            }
        case .phase:
            let ids = map.phaseIDs
            for (id, phase) in map.phasesInData.entries {
                let rgb = phase.colorRGB ?? .zero
                ctx.setFillColor(CGColor(srgbRed: rgb.x, green: rgb.y, blue: rgb.z, alpha: 1))
                ctx.fill(CGRect(x: x, y: y, width: 16, height: 16))
                ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.4))
                ctx.stroke(CGRect(x: x, y: y, width: 16, height: 16))
                let count = ids.filter { $0 == id }.count
                text("\(MapsRoomFormat.phaseName(phase, id: id)) · \(count)", at: CGPoint(x: x + 24, y: y + 1), size: 12, ctx: ctx)
                y += 24
            }
        case .property(let name):
            text(name, at: CGPoint(x: x, y: y), size: 12, ctx: ctx)
            y += 18
            if let range = raster.valueRange {
                text("\(UnitDisplay.number(range.lowerBound, digits: 4)) to \(UnitDisplay.number(range.upperBound, digits: 4))", at: CGPoint(x: x, y: y), size: 11, ctx: ctx)
            }
        }
        _ = fileName
        guard let image = ctx.makeImage() else { throw Failure(text: "The figure could not be drawn.") }
        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(encoded as CFMutableData, UTType.png.identifier as CFString, 1, nil) else {
            throw Failure(text: "The figure could not be encoded.")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw Failure(text: "The figure could not be encoded.") }
        return encoded as Data
    }

    /// The legend column's height: a title and a key per phase, a row per phase, or two lines.
    static func legendHeight(layer: OrientationMapLayer, map: CrystalMap, keys: [OrientationMapSession.PhaseKey], width: Int) -> Int {
        switch layer {
        case .ipf:
            return keys.reduce(0) { sum, key in
                sum + 18 + Int((Double(width - 20) * Double(key.image.height) / Double(max(key.image.width, 1))).rounded(.up)) + 22
            }
        case .phase: return map.phasesInData.count * 24
        case .property: return 40
        }
    }

    /// A property layer through the pane's colormap, window and gamma (`ExportSnapshot.display`, the Image room's exporter's mapping).
    @MainActor static func propertyImage(canvas: CanvasPixels, presentation: ImagePresentation) -> CGImage? {
        let display = ExportSnapshot.display(canvas: canvas, presentation: presentation)
        guard let mapping = DisplayMapping(low: display.low, high: display.high, gamma: display.gamma, lut: display.lut) else { return nil }
        var rgba = [UInt8](repeating: 255, count: canvas.width * canvas.height * 4)
        for (i, v) in canvas.normalized.enumerated() {
            let (r, g, b) = mapping.rgb(v)
            rgba[4 * i] = r; rgba[4 * i + 1] = g; rgba[4 * i + 2] = b
        }
        return cgImage(premultipliedRGBA: rgba, width: canvas.width, height: canvas.height)
    }

    /// Draws `image` into `rect` of the flipped context, upright.
    static func draw(_ image: CGImage, in rect: CGRect, ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: rect.width, height: rect.height))
        ctx.restoreGState()
    }

    /// One line of black text with its top-left at `point` of the flipped context.
    static func text(_ string: String, at point: CGPoint, size: CGFloat, ctx: CGContext) {
        let font = CTFontCreateUIFontForLanguage(.system, size, nil) ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes))
        ctx.saveGState()
        ctx.translateBy(x: point.x, y: point.y + size)
        ctx.scaleBy(x: 1, y: -1)
        ctx.textPosition = .zero
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }
}
