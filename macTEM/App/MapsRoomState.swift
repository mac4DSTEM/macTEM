//
//  MapsRoomState.swift
//  Role: the Maps room's own view state (the import request, the status line's readout, the export in flight) and its words
//        (`MapsRoomFormat`) and figure (`MapsFigure`: the map with its colour key or phase legend and a scale bar, as one PNG). The room's
//        facts are `OrientationMapSession`'s (TEMSession); the pictures and the hover's words `OrientationMaps`' (TEMCore). Window-wide,
//        not saved; composed by `AppState` as `PatternsRoomState` is. P5-04 adds the bottom pane's tab, the grain table as CSV and the
//        texture figures as one PNG.
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
    /// What the save panel writes: the map figure or the texture figure (PNG) or the grain table (CSV).
    private(set) var exportType = UTType.png
    /// The bottom pane's tab.
    var bottomTab = MapsBottomTab.key

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
                                      presentation: session.propertyPresentation, fileName: document.fileName,
                                      boundaries: session.showsBoundaries ? (session.grainBoundaryEdges, session.phaseBoundaryEdges) : ([], []),
                                      grainCount: session.analysis?.table.count)
        } catch {
            report("Export failed: \(error.localizedDescription)"); return
        }
        write(data, name: name, type: .png, directory: directory, report: report)
    }

    /// The grain table as CSV (`MapsRoomFormat.grainsCSV`), to the save panel or the journeys' folder.
    @MainActor func exportGrains(from session: OrientationMapSession, directory: URL? = nil, report: (String) -> Void) {
        guard let document = session.document, let analysis = session.analysis else {
            report("Nothing to export yet: segment the map first."); return
        }
        let name = (document.fileName as NSString).deletingPathExtension + " grains"
        let csv = MapsRoomFormat.grainsCSV(analysis, slip: session.slip, loadDirection: session.loadDirection)
        write(Data(csv.utf8), name: name, type: .commaSeparatedText, directory: directory, report: report)
    }

    /// The pole figures, the IPF density and the ODF sections of the texture shown, as one PNG.
    @MainActor func exportTexture(from session: OrientationMapSession, directory: URL? = nil, report: (String) -> Void) {
        guard let document = session.document, let texture = session.texture else {
            report("Nothing to export yet: the texture has not landed."); return
        }
        let name = (document.fileName as NSString).deletingPathExtension + " texture " + texture.phaseName.replacingOccurrences(of: "/", with: "-")
        do {
            let data = try MapsFigure.texturePNG(texture, fileName: document.fileName)
            write(data, name: name, type: .png, directory: directory, report: report)
        } catch {
            report("Export failed: \(error.localizedDescription)")
        }
    }

    @MainActor private func write(_ data: Data, name: String, type: UTType, directory: URL?, report: (String) -> Void) {
        if let directory {
            let url = directory.appendingPathComponent(name).appendingPathExtension(type.preferredFilenameExtension ?? "png")
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
        exportName = name
        exportType = type
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

    /// "Map · IPF-Z", "Map · Phase", "Map · iq"; "Map · IPF-Z · stale" for an Indexing run the room has moved on from (D-SEM-99).
    static func mapTitle(_ layer: OrientationMapLayer, stale: Bool = false) -> String { "Map · " + layer.title + (stale ? " · stale" : "") }

    /// A held map's name in the Source pop-up (design §4: the result, then where it is from): "File · sdss.ang",
    /// "Hough · Indexing room".
    static func sourceTitle(_ document: OrientationMapSession.Document) -> String {
        switch document.source {
        case .mapFile, .patterns: "File · " + document.fileName
        case .indexing(_, let method): method.title + " · Indexing room"
        }
    }

    /// Where the map shown came from, in the Source row when it is the only map held.
    static func sourceWords(_ source: OrientationMapSession.Document.Source) -> String {
        switch source {
        case .mapFile: "The map file"
        case .patterns: "The pattern file's map"
        case .indexing(_, let method): "The Indexing room's \(method.title) run"
        }
    }

    /// The Info tab's note on what the map is.
    static func sourceNote(_ source: OrientationMapSession.Document.Source) -> String {
        switch source {
        case .mapFile:
            "The indexing as the file stores it; no patterns came with it, so the pane beside the map draws each point's unit cell."
        case .patterns:
            "The vendor's or kikuchipy's indexing as the file stores it; the patterns are the Patterns room's."
        case .indexing:
            "The Indexing room's run (the rows it reached), handed over without a file: the crystal map its .ang and .ctf exports are written from; the patterns are the Patterns room's."
        }
    }

    /// A phase's name as the room writes it: the file's, or "phase 2" for an unnamed one.
    static func phaseName(_ phase: CrystalPhase, id: Int) -> String { phase.name.isEmpty ? "phase \(id)" : phase.name }

    // MARK: Analysis words (P5-04)

    static let decimal = FloatingPointFormatStyle<Double>.number.precision(.significantDigits(1...4))
    static let whole = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(0))

    static func angle(_ v: Double, digits: Int = 1) -> String {
        v.isFinite ? v.formatted(.number.grouping(.never).precision(.fractionLength(digits))) : "–"
    }

    static func number(_ v: Double) -> String { v.isFinite ? v.formatted(.number.grouping(.never).precision(.significantDigits(1...4))) : "–" }

    static func fraction(_ v: Double) -> String { v.isFinite ? v.formatted(.number.precision(.fractionLength(3))) : "–" }

    /// "102 grains · mean ECD 3.1 µm · ASTM 14.2".
    static func grainSummary(_ analysis: MapAnalysis) -> String {
        var parts = ["\(analysis.table.count) grains"]
        if let mean = analysis.meanDiameter { parts.append("mean ECD \(number(mean.byNumber)) \(EBSDBrowsing.unitLabel(analysis.scanUnit))") }
        if let g = analysis.astmGrainSizeNumber { parts.append("ASTM \(angle(g))") }
        return parts.joined(separator: " · ")
    }

    /// The Grains section's summary rows.
    static func grainRows(_ analysis: MapAnalysis) -> [EBSDBrowsing.Row] {
        let unit = EBSDBrowsing.unitLabel(analysis.scanUnit)
        var out = [EBSDBrowsing.Row("Grains", "\(analysis.table.count)")]
        if let mean = analysis.meanDiameter {
            out.append(EBSDBrowsing.Row("Mean ECD", "\(number(mean.byNumber)) \(unit)"))
            out.append(EBSDBrowsing.Row("Area-weighted", "\(number(mean.byArea)) \(unit)"))
        }
        if let l = analysis.meanLinealIntercept { out.append(EBSDBrowsing.Row("Mean intercept", "\(number(l)) \(unit)")) }
        if let g = analysis.astmGrainSizeNumber { out.append(EBSDBrowsing.Row("ASTM E112", angle(g))) }
        let s = analysis.settings
        out.append(EBSDBrowsing.Row("Made with", "\(number(s.boundaryDegrees))° · ≥ \(s.minimumSize) points · KAM ≤ \(number(s.kamMaxDegrees))°"))
        return out
    }

    /// The slip-system files that fit a phase's crystal structure.
    static func slipChoices(_ phase: CrystalPhase) -> [SlipSystemFile] {
        SlipSystemFile.allCases.filter { MapAnalysis.slipSystems($0, phase: phase) != nil }
    }

    static func slipTitle(_ file: SlipSystemFile) -> String {
        switch file {
        case .cubicFCC: "fcc {111}<110>"
        case .cubicBCC: "bcc {110} {112} {123}<111>"
        case .cubicBCC110Only: "bcc {110}<111>"
        case .cubicFCCDamask: "fcc (DAMASK order)"
        case .hexagonalWithCA: "hcp, with <c+a>"
        case .hexagonalNoCA: "hcp, without <c+a>"
        }
    }

    /// "SF 0.47 · trace 132° · inclined 61°".
    static func planeText(_ plane: GrainSlip.Plane) -> String {
        let trace = plane.traceAngle.isFinite ? "trace \(angle(plane.traceAngle * 180 / .pi, digits: 0))°" : "no trace"
        return "SF \(fraction(plane.schmid)) · \(trace) · inclined \(angle(plane.inclination * 180 / .pi, digits: 0))°"
    }

    /// A trace's direction on the map (x right, y down): `angle` from +y counter-clockwise, as DefDAP's `calc_slip_traces`.
    static func traceDirection(_ angle: Double) -> SIMD2<Double> { SIMD2(-sin(angle), cos(angle)) }

    /// What a derived layer shows, in one sentence.
    static func derivedNote(_ layer: DerivedMapLayer, load: SampleDirection) -> String {
        switch layer {
        case .grains: "Each grain in its own colour, from Segment's boundary angle and smallest grain (DefDAP's find_grains)."
        case .kam: "Kernel average misorientation (°): the mean misorientation to the first neighbours of the same phase, those above the KAM maximum left out."
        case .gos: "Grain orientation spread (°): each grain's mean misorientation to its mean orientation (DefDAP)."
        case .gnd: "Geometrically necessary dislocation density, log₁₀ m⁻²: DefDAP's Nye-tensor estimate from the primary phase's structure."
        case .schmid: "Each grain's largest Schmid factor for a load along sample \(load.rawValue.uppercased()), from its mean orientation and the Slip section's systems."
        }
    }

    /// The texture tab's caption: the points it used and the kernel.
    static func textureCaption(_ texture: MapTexture, odf: Bool) -> String {
        if odf {
            let used = texture.odfPoints == texture.points ? "all \(texture.points) points" : "\(texture.odfPoints) of \(texture.points) points (every \((texture.points + texture.odfPoints - 1) / max(texture.odfPoints, 1))th)"
            return "\(texture.phaseName): ODF φ₂ sections from \(used), de la Vallée Poussin kernel 10°, multiples of random."
        }
        return "\(texture.phaseName): \(texture.points) points, upper hemisphere, 1° bins smoothed 5°, multiples of random. IPF-Z in the colour key's sector."
    }

    /// The grain table as CSV: one header line, one line per grain; lengths in the scan unit, angles in degrees.
    static func grainsCSV(_ analysis: MapAnalysis, slip: [GrainSlip], loadDirection: SampleDirection) -> String {
        let unit = analysis.scanUnit
        var bySlip: [Int: Double] = [:]
        for s in slip { bySlip[s.grain] = s.maximumSchmid }
        var lines = ["grain,phase,points,area_\(unit)2,ecd_\(unit),phi1_deg,Phi_deg,phi2_deg,gos_deg,neighbours,centroid_column,centroid_row,schmid_max_load_\(loadDirection.rawValue)"]
        func f(_ v: Double) -> String { v.isFinite ? String(format: "%.6g", v) : "" }
        for r in analysis.table {
            let name = r.phaseName.contains(",") ? "\"\(r.phaseName)\"" : r.phaseName
            lines.append([String(r.id), name, String(r.points), f(r.area), f(r.diameter), f(r.euler.x), f(r.euler.y), f(r.euler.z),
                          f(r.gosDegrees), String(r.neighbours), f(r.centroid.x), f(r.centroid.y), f(bySlip[r.id] ?? .nan)].joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// The Info tab (design §5): what the map is, where it came from and how its colours are made.
    static func infoRows(_ document: OrientationMapSession.Document) -> [EBSDBrowsing.Row] {
        let map = document.map
        let (rows, columns) = OrientationMaps.gridShape(map)
        let unit = EBSDBrowsing.unitLabel(map.scanUnit)
        var out = [
            EBSDBrowsing.Row("File", document.fileName),
            EBSDBrowsing.Row("Format", document.format),
            EBSDBrowsing.Row("Source", Self.infoSource(document.source)),
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
        out.append(EBSDBrowsing.Row("Euler angles", Self.infoEuler(document.source)))
        out.append(EBSDBrowsing.Row("IPF colours", "TSL key of each phase's Laue group (Nolze and Hielscher 2016), as orix 0.15.0"))
        out.append(EBSDBrowsing.Row("Phase colours", Self.infoPhaseColours(document.source)))
        return out
    }

    private static func infoSource(_ source: OrientationMapSession.Document.Source) -> String {
        switch source {
        case .mapFile: "The map file alone (no patterns)"
        case .patterns: "The pattern file's crystal map"
        case .indexing(_, let method): "The Indexing room's \(method.title) run on the pattern file"
        }
    }

    private static func infoEuler(_ source: OrientationMapSession.Document.Source) -> String {
        switch source {
        case .mapFile, .patterns: "Bunge (φ₁, Φ, φ₂), lab to crystal, as orix reads the file"
        case .indexing: "Bunge (φ₁, Φ, φ₂), lab to crystal, from the run's rotations as orix converts them"
        }
    }

    private static func infoPhaseColours(_ source: OrientationMapSession.Document.Source) -> String {
        switch source {
        case .mapFile, .patterns: "orix's phase list (matplotlib Tableau colours)"
        case .indexing: "The Indexing room's phase colours (orix's names)"
        }
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
                               presentation: ImagePresentation, fileName: String,
                               boundaries: (grain: [(SIMD2<Double>, SIMD2<Double>)], phase: [(SIMD2<Double>, SIMD2<Double>)]) = ([], []),
                               grainCount: Int? = nil) throws -> Data {
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

        // The boundaries the pane shows, at the pixel edges: grain boundaries white, phase boundaries black.
        func stroke(_ edges: [(SIMD2<Double>, SIMD2<Double>)], gray: CGFloat) {
            guard !edges.isEmpty else { return }
            ctx.setStrokeColor(CGColor(gray: gray, alpha: 1))
            ctx.setLineWidth(max(1, CGFloat(s) / 4))
            for (a, b) in edges {
                ctx.move(to: CGPoint(x: mapRect.minX + CGFloat(a.x + 0.5) * CGFloat(s), y: mapRect.minY + CGFloat(a.y + 0.5) * CGFloat(s)))
                ctx.addLine(to: CGPoint(x: mapRect.minX + CGFloat(b.x + 0.5) * CGFloat(s), y: mapRect.minY + CGFloat(b.y + 0.5) * CGFloat(s)))
            }
            ctx.strokePath()
        }
        stroke(boundaries.grain, gray: 1)
        stroke(boundaries.phase, gray: 0)

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
        case .derived(.grains):
            text("Grains", at: CGPoint(x: x, y: y), size: 12, ctx: ctx)
            y += 18
            text("\(grainCount ?? 0) grains, each its own colour", at: CGPoint(x: x, y: y), size: 11, ctx: ctx)
            y += 16
            text("grey: below the smallest grain", at: CGPoint(x: x, y: y), size: 11, ctx: ctx)
        case .derived(let derived):
            text(derived.unit.isEmpty ? derived.title : "\(derived.title) (\(derived.unit))", at: CGPoint(x: x, y: y), size: 12, ctx: ctx)
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
        case .property, .derived: return 56
        }
    }

    // MARK: Texture figures

    /// A texture raster through inferno from 0 to its maximum; NaN (outside the projection or the sector) transparent.
    static func textureImage(_ raster: TextureRaster) -> CGImage? {
        let lut = Colormaps.lutRGBA(.inferno)
        let top = Double(raster.high)
        var rgba = [UInt8](repeating: 0, count: raster.width * raster.height * 4)
        for (i, v) in raster.values.enumerated() where v.isFinite {
            let t = top > 0 ? min(max(Double(v) / top, 0), 1) : 0
            let (r, g, b) = Colormaps.sampleRGB(lut, t)
            rgba[4 * i] = r; rgba[4 * i + 1] = g; rgba[4 * i + 2] = b; rgba[4 * i + 3] = 255
        }
        return cgImage(premultipliedRGBA: rgba, width: raster.width, height: raster.height)
    }

    /// The inferno colour bar, 256 × 1.
    static func colourBarImage() -> CGImage? {
        let lut = Colormaps.lutRGBA(.inferno)
        var rgba = [UInt8](repeating: 255, count: 256 * 4)
        for i in 0..<256 {
            let (r, g, b) = Colormaps.sampleRGB(lut, Double(i) / 255)
            rgba[4 * i] = r; rgba[4 * i + 1] = g; rgba[4 * i + 2] = b
        }
        return cgImage(premultipliedRGBA: rgba, width: 256, height: 1)
    }

    /// The texture of one phase as a figure: the pole figures and the IPF density on the first row, the ODF sections on the second,
    /// each with its title, its colour bar and maximum (multiples of random), and the phase and points as a caption, on white.
    static func texturePNG(_ texture: MapTexture, fileName: String, side: Int = 240) throws -> Data {
        let top = texture.poleFigures + (texture.inversePoleFigure.map { [$0] } ?? [])
        let bottom = texture.odfSections
        let margin = 16, gap = 20, titleH = 18, barH = 10, captionH = 34
        let cellH = titleH + side + 6 + barH + 18
        let columns = max(top.count, bottom.count, 1)
        let width = margin + columns * side + (columns - 1) * gap + margin
        let height = margin + captionH + cellH + (bottom.isEmpty ? 0 : gap + cellH) + margin
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw Failure(text: "The figure could not be drawn.") }
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        text("\(fileName) · \(texture.phaseName) · \(texture.points) points", at: CGPoint(x: margin, y: margin), size: 13, ctx: ctx)
        text("Pole figures: upper hemisphere, 1° bins smoothed 5°. ODF: φ₁ across, Φ down, de la Vallée Poussin 10°. Densities in multiples of random.",
             at: CGPoint(x: margin, y: margin + 17), size: 10, ctx: ctx)
        let bar = colourBarImage()
        func row(_ figures: [MapTexture.Figure], y0: Int, odf: Bool) {
            for (k, figure) in figures.enumerated() {
                let x = CGFloat(margin + k * (side + gap))
                var y = CGFloat(y0)
                text(figure.title, at: CGPoint(x: x, y: y), size: 12, ctx: ctx)
                y += CGFloat(titleH)
                let aspect = CGFloat(figure.raster.height) / CGFloat(max(figure.raster.width, 1))
                if let image = textureImage(figure.raster) {
                    ctx.interpolationQuality = odf ? .none : .high
                    draw(image, in: CGRect(x: x, y: y, width: CGFloat(side), height: CGFloat(side) * aspect), ctx: ctx)
                }
                if !odf {
                    ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.5))
                    if figure.title.hasPrefix("IPF") == false {
                        ctx.strokeEllipse(in: CGRect(x: x, y: y, width: CGFloat(side), height: CGFloat(side)))
                    }
                }
                y += CGFloat(side) + 6
                if let bar {
                    ctx.interpolationQuality = .high
                    draw(bar, in: CGRect(x: x, y: y, width: CGFloat(side), height: CGFloat(barH)), ctx: ctx)
                }
                text("0 to \(UnitDisplay.number(figure.maximum, digits: 3)) MRD", at: CGPoint(x: x, y: y + CGFloat(barH) + 2), size: 10, ctx: ctx)
            }
        }
        row(top, y0: margin + captionH, odf: false)
        if !bottom.isEmpty { row(bottom, y0: margin + captionH + cellH + gap, odf: true) }
        guard let image = ctx.makeImage() else { throw Failure(text: "The figure could not be drawn.") }
        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(encoded as CFMutableData, UTType.png.identifier as CFString, 1, nil) else {
            throw Failure(text: "The figure could not be encoded.")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw Failure(text: "The figure could not be encoded.") }
        return encoded as Data
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
