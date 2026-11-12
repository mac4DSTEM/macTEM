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
    /// What the Histogram tab counts.
    var histogramKind = MapAnalysis.HistogramKind.kam
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
                                      presentation: session.propertyPresentation, fileName: document.fileName,
                                      boundaries: session.showsBoundaries ? (session.grainBoundaryEdges, session.phaseBoundaryEdges) : ([], []),
                                      grainCount: session.analysis?.table.count)
        } catch {
            report("Export failed: \(error.localizedDescription)"); return
        }
        let record = SEMExportedFile(room: "Maps", what: "Map PNG", source: document.fileName,
                                     fields: MapsRoomFormat.recordFields(of: session.layer, session: session),
                                     methods: MapsRoomFormat.methods(of: session.layer), png: data)
        write(data, name: name, type: .png, record: record, directory: directory, report: report)
    }

    /// The grain table as CSV (`MapsRoomFormat.grainsCSV`), to the save panel or the journeys' folder.
    @MainActor func exportGrains(from session: OrientationMapSession, directory: URL? = nil, report: (String) -> Void) {
        guard let document = session.document, let analysis = session.analysis else {
            report("Nothing to export yet: segment the map first."); return
        }
        let name = (document.fileName as NSString).deletingPathExtension + " grains"
        let csv = MapsRoomFormat.grainsCSV(analysis, slip: session.slip, loadDirection: session.loadDirection)
        var fields = MapsRoomFormat.analysisFields(analysis.settings) + [SEMSessionField("Grains", "\(analysis.table.count)")]
        if !session.slip.isEmpty { fields.append(SEMSessionField("Load", "Sample \(session.loadDirection.rawValue.uppercased())")) }
        let record = SEMExportedFile(room: "Maps", what: "Grains CSV", source: document.fileName, fields: fields,
                                     methods: [.orientationMap, .grains, .gos] + (session.slip.isEmpty ? [] : [.schmid]))
        write(Data(csv.utf8), name: name, type: .commaSeparatedText, record: record, directory: directory, report: report)
    }

    /// The Histogram tab's distribution as CSV.
    @MainActor func exportHistogram(from session: OrientationMapSession, directory: URL? = nil, report: (String) -> Void) {
        guard let document = session.document, let analysis = session.analysis else {
            report("Nothing to export yet: segment the map first."); return
        }
        let kind = histogramKind
        let unit = kind == .grainSize ? analysis.scanUnit : "deg"
        let name = (document.fileName as NSString).deletingPathExtension + " histogram " + kind.rawValue
        let csv = MapsRoomFormat.histogramCSV(kind, histogram: analysis.histogram(kind), unit: unit)
        let methods: [SEMMethod] = switch kind {
        case .kam: [.orientationMap, .kam]
        case .gos: [.orientationMap, .grains, .gos]
        case .grainSize: [.orientationMap, .grains]
        }
        let record = SEMExportedFile(room: "Maps", what: "Histogram CSV", source: document.fileName,
                                     fields: [SEMSessionField("Histogram", kind.rawValue)] + MapsRoomFormat.analysisFields(analysis.settings),
                                     methods: methods)
        write(Data(csv.utf8), name: name, type: .commaSeparatedText, record: record, directory: directory, report: report)
    }

    /// The pole figures, the IPF density and the ODF sections of the texture shown, as one PNG.
    @MainActor func exportTexture(from session: OrientationMapSession, directory: URL? = nil, report: (String) -> Void) {
        guard let document = session.document, let texture = session.texture else {
            report("Nothing to export yet: the texture has not landed."); return
        }
        let name = (document.fileName as NSString).deletingPathExtension + " texture " + texture.phaseName.replacingOccurrences(of: "/", with: "-")
        do {
            let data = try MapsFigure.texturePNG(texture, fileName: document.fileName)
            let figures = texture.poleFigures.map(\.title) + (texture.inversePoleFigure.map { [$0.title] } ?? []) + texture.odfSections.map(\.title)
            let record = SEMExportedFile(room: "Maps", what: "Texture PNG", source: document.fileName,
                                         fields: [SEMSessionField("Phase", texture.phaseName), SEMSessionField("Points", "\(texture.points)"),
                                                  SEMSessionField("ODF points", "\(texture.odfPoints)"),
                                                  SEMSessionField("Figures", figures.joined(separator: ", "))],
                                         methods: [.orientationMap, .texture], png: data)
            write(data, name: name, type: .png, record: record, directory: directory, report: report)
        } catch {
            report("Export failed: \(error.localizedDescription)")
        }
    }

    /// Writes to the journeys' folder (the record kept at once) or opens the save panel (the record kept once it has written).
    @MainActor private func write(_ data: Data, name: String, type: UTType, record: SEMExportedFile, directory: URL?, report: (String) -> Void) {
        if let directory {
            let url = directory.appendingPathComponent(name).appendingPathExtension(type.preferredFilenameExtension ?? "png")
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
        exportType = type
        isExporting = true
    }
}

// MARK: - Words

nonisolated enum MapsRoomFormat {
    /// The methods a map figure of `layer` rests on, for the session report (D-SEM-104).
    static func methods(of layer: OrientationMapLayer) -> [SEMMethod] {
        switch layer {
        case .ipf: [.orientationMap, .ipfColours]
        case .phase, .property: [.orientationMap]
        case .derived(.kam): [.orientationMap, .kam]
        case .derived(.gos): [.orientationMap, .grains, .gos]
        case .derived(.gnd): [.orientationMap, .gnd]
        case .derived(.grains): [.orientationMap, .grains]
        case .derived(.schmid): [.orientationMap, .grains, .schmid]
        }
    }

    /// The Grains and Misorientation sections' settings an analysis ran with, in their words, the numbers in `locale`.
    static func analysisFields(_ settings: MapAnalysisSettings, locale: Locale = .autoupdatingCurrent) -> [SEMSessionField] {
        [SEMSessionField("Boundary", "\(UnitDisplay.number(settings.boundaryDegrees, locale: locale))°"),
         SEMSessionField("Smallest", UnitDisplay.count(settings.minimumSize, "point", "points")),
         SEMSessionField("KAM maximum", "\(UnitDisplay.number(settings.kamMaxDegrees, locale: locale))°")]
    }

    /// A map figure's settings for the session report: the layer, and for a layer the analysis makes, the settings it ran with (and the
    /// load axis of the Schmid factors).
    @MainActor static func recordFields(of layer: OrientationMapLayer, session: OrientationMapSession) -> [SEMSessionField] {
        var fields = [SEMSessionField("Layer", layer.title)]
        guard case .derived(let derived) = layer, let analysis = session.analysis else { return fields }
        fields += analysisFields(analysis.settings)
        if derived == .schmid { fields.append(SEMSessionField("Load", "Sample \(session.loadDirection.rawValue.uppercased())")) }
        return fields
    }

    /// The toolbar's detail: "117 × 100 · 2 phases", the map's width × height in points (X before Y, as AZtec's X and Y Cells).
    static func capsuleDetail(_ map: CrystalMap) -> String {
        let (rows, columns) = OrientationMaps.gridShape(map)
        let phases = indexedPhases(map).count
        return "\(columns) × \(rows) · \(phases) \(phases == 1 ? "phase" : "phases")"
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

    // The numbers are in the reader's locale unless the caller passes one (the session report passes `ExportSnapshot.labelLocale`), written
    // as `UnitDisplay` writes every number: printf's digits, no grouping, `UnitDisplay.noValue` where there is none.

    static let decimal = Num.decimalField
    static let whole = Num.wholeField

    static func angle(_ v: Double, digits: Int = 1, locale: Locale = .autoupdatingCurrent) -> String {
        UnitDisplay.fixed(v, places: digits, locale: locale)
    }

    static func number(_ v: Double, locale: Locale = .autoupdatingCurrent) -> String { UnitDisplay.number(v, digits: 4, locale: locale) }

    static func fraction(_ v: Double, locale: Locale = .autoupdatingCurrent) -> String { UnitDisplay.fixed(v, places: 3, locale: locale) }

    /// The orientation pane's Bunge angles (`radians`) in degrees, one decimal each, as the Grains table writes them: ["203.3", "38.8", "171.2"].
    static func eulerValues(_ radians: SIMD3<Double>, locale: Locale = .autoupdatingCurrent) -> [String] {
        let d = radians * (180 / Double.pi)
        return [d.x, d.y, d.z].map { angle($0, locale: locale) }
    }

    /// The orientation pane's Euler line from `eulerValues`: "φ₁ 203.3°  Φ 38.8°  φ₂ 171.2°" (`SEMColumnSpeech.spokenEuler` says it).
    static func eulerLine(_ values: [String]) -> String {
        zip(["φ₁", "Φ", "φ₂"], values).map { "\($0) \($1)°" }.joined(separator: "  ")
    }

    /// A grain length in the scan unit (an ECD, a mean intercept) at `places` decimals, one count wherever the room writes one: the
    /// table's column, the summary and the Grains rows read alike ("10,70 · 10,16 · 21,00", where significant digits read "10,7 · 10,16 ·
    /// 21"). The room passes `lengthPlaces(analysis)`.
    static func length(_ v: Double, places: Int = 2, locale: Locale = .autoupdatingCurrent) -> String {
        UnitDisplay.fixed(v, places: places, locale: locale)
    }

    /// The decimals of `analysis`'s grain lengths: two, or more where the smallest length the room writes (a grain's ECD, the mean
    /// intercept) would show fewer than three significant digits, as the scan unit is the file's: a 10 nm step in µm reads "0.0113", where
    /// two decimals read "0.01" and a 4 nm step's one-point grain "0.00". One count for the whole table, so the column keeps one width.
    static func lengthPlaces(_ analysis: MapAnalysis) -> Int {
        var smallest = Double.infinity
        for row in analysis.table where row.diameter.isFinite && row.diameter > 0 { smallest = min(smallest, row.diameter) }
        if let intercept = analysis.meanLinealIntercept, intercept.isFinite, intercept > 0 { smallest = min(smallest, intercept) }
        return lengthPlaces(smallest: smallest)
    }

    /// Two decimals, or the decimals three significant digits of `smallest` need (0.5 → 3, 0.0113 → 4); two when it is not a finite
    /// positive length.
    static func lengthPlaces(smallest: Double) -> Int {
        guard smallest.isFinite, smallest > 0 else { return 2 }
        return max(2, 2 - Int(log10(smallest).rounded(.down)))
    }

    /// The orientation pane's Bunge angles from radians, one decimal each as the status line beside it writes them
    /// (`OrientationMaps.degrees`): "φ₁ 12.3°  Φ 44.0°  φ₂ 271.5°", never "-0.0°".
    static func eulerText(_ radians: SIMD3<Double>, locale: Locale = .autoupdatingCurrent) -> String {
        eulerLine(eulerValues(radians, locale: locale))
    }

    /// A phase's point group and its points, as the Phases rows, the phase legend and the Info tab write them: "m-3m · 1 point";
    /// `missing` stands for a phase without a point group.
    static func phasePoints(_ phase: CrystalPhase, count: Int, missing: String = "no point group") -> String {
        "\(phase.pointGroupName ?? missing) · \(UnitDisplay.count(count, "point", "points"))"
    }

    /// The histogram's spoken label: "Histogram of KAM, 1 value in 40 bins".
    static func histogramSpoken(_ kind: MapAnalysis.HistogramKind, histogram: AngleHistogram) -> String {
        let n = histogram.counts.reduce(0, +)
        return "Histogram of \(kind.rawValue), \(UnitDisplay.count(n, "value", "values")) in \(UnitDisplay.count(histogram.counts.count, "bin", "bins"))"
    }

    /// "102 grains · mean ECD 3.14 µm · ASTM 14.2", the length as the grain table writes it.
    static func grainSummary(_ analysis: MapAnalysis, locale: Locale = .autoupdatingCurrent) -> String {
        var parts = [UnitDisplay.count(analysis.table.count, "grain", "grains")]
        if let mean = analysis.meanDiameter {
            let places = lengthPlaces(analysis)
            parts.append("mean ECD \(length(mean.byNumber, places: places, locale: locale)) \(EBSDBrowsing.unitLabel(analysis.scanUnit))")
        }
        if let g = analysis.astmGrainSizeNumber { parts.append("ASTM \(angle(g, locale: locale))") }
        return parts.joined(separator: " · ")
    }

    /// The Grains section's summary rows; the lengths at the grain table's decimals (`lengthPlaces`).
    static func grainRows(_ analysis: MapAnalysis, locale: Locale = .autoupdatingCurrent) -> [EBSDBrowsing.Row] {
        let unit = EBSDBrowsing.unitLabel(analysis.scanUnit)
        let places = lengthPlaces(analysis)
        let n = { (v: Double) in Self.number(v, locale: locale) }
        let l = { (v: Double) in Self.length(v, places: places, locale: locale) }
        var out = [EBSDBrowsing.Row("Grains", "\(analysis.table.count)")]
        if let mean = analysis.meanDiameter {
            out.append(EBSDBrowsing.Row("Mean ECD", "\(l(mean.byNumber)) \(unit)"))
            out.append(EBSDBrowsing.Row("Area-weighted", "\(l(mean.byArea)) \(unit)"))
        }
        if let intercept = analysis.meanLinealIntercept { out.append(EBSDBrowsing.Row("Mean intercept", "\(l(intercept)) \(unit)")) }
        if let g = analysis.astmGrainSizeNumber { out.append(EBSDBrowsing.Row("ASTM E112", angle(g, locale: locale))) }
        let s = analysis.settings
        out.append(EBSDBrowsing.Row("Made with", "\(n(s.boundaryDegrees))° · ≥ \(UnitDisplay.count(s.minimumSize, "point", "points")) · KAM ≤ \(n(s.kamMaxDegrees))°"))
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

    /// "KAM · 11700 points · mean ≈ 0.62 ° · 40 bins": what the histogram counts and its centre.
    static func histogramCaption(_ kind: MapAnalysis.HistogramKind, histogram: AngleHistogram, unit: String) -> String {
        let n = histogram.counts.reduce(0, +)
        guard n > 0 else { return "\(kind.rawValue) · no values" }
        let what = kind == .kam ? UnitDisplay.count(n, "point", "points") : UnitDisplay.count(n, "grain", "grains")
        // The centre from the bins (each value at its bin's middle), the precision the bars show.
        var sum = 0.0
        for (k, c) in histogram.counts.enumerated() { sum += Double(c) * (histogram.edges[k] + histogram.edges[k + 1]) / 2 }
        return "\(kind.rawValue) · \(what) · mean ≈ \(number(sum / Double(n))) \(unit) · \(UnitDisplay.count(histogram.counts.count, "bin", "bins"))"
    }

    /// The histogram as CSV: one line per bin, its edges and its count.
    static func histogramCSV(_ kind: MapAnalysis.HistogramKind, histogram: AngleHistogram, unit: String) -> String {
        let name = kind.rawValue.lowercased().replacingOccurrences(of: " ", with: "_")
        var lines = ["\(name)_low_\(unit),\(name)_high_\(unit),count"]
        for (k, c) in histogram.counts.enumerated() {
            lines.append(String(format: "%.6g,%.6g,%d", histogram.edges[k], histogram.edges[k + 1], c))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// The texture tab's caption: the points it used and the kernel.
    static func textureCaption(_ texture: MapTexture, odf: Bool) -> String {
        let points = UnitDisplay.count(texture.points, "point", "points")
        if odf {
            let used = texture.odfPoints == texture.points ? "all \(points)" : "\(texture.odfPoints) of \(points) (every \((texture.points + texture.odfPoints - 1) / max(texture.odfPoints, 1))th)"
            return "\(texture.phaseName): ODF φ₂ sections from \(used), de la Vallée Poussin kernel 10°, multiples of random."
        }
        return "\(texture.phaseName): \(points), upper hemisphere, 1° bins smoothed 5°, multiples of random. IPF-Z in the colour key's sector."
    }

    /// What the Pole figures and ODF panes say while no texture is shown or being made: no phase to make it for, refused for the phase
    /// picked (`failure`, the status line's reason), stopped by ⌘., or not yet asked for; the last two name the inspector's Compute
    /// Texture (macTEM#410), which a refusal leaves off.
    static func textureUnavailable(stopped: Bool, failure: String?, hasPhases: Bool) -> (title: String, detail: String, systemImage: String) {
        guard hasPhases else { return ("No texture", "No indexed phase with a point group.", "circle.grid.cross") }
        if let failure { return ("No texture", failure, "circle.grid.cross") }
        if stopped { return ("Texture stopped", "Compute Texture in the inspector's Texture section makes it again.", "stop.circle") }
        return ("No texture", "Compute Texture in the inspector's Texture section makes it.", "circle.grid.cross")
    }

    /// The help of the Texture section's Compute Texture: what it makes, or why it is off.
    static func computeTextureHelp(isTexturing: Bool, failure: String?, canCompute: Bool) -> String {
        if isTexturing { return "The texture is being computed" }
        if let failure { return failure }
        return canCompute ? "The phase's pole figures, IPF-Z density and ODF sections, in the Pole figures and ODF tabs"
            : "The Pole figures and ODF tabs show this phase's texture"
    }

    /// The grain table as CSV: one header line, one line per grain; lengths in the scan unit, angles in degrees. The phase name is an
    /// RFC 4180 cell (`CSVText.quoted`, #338), as in the indexing results CSV.
    static func grainsCSV(_ analysis: MapAnalysis, slip: [GrainSlip], loadDirection: SampleDirection) -> String {
        let unit = analysis.scanUnit
        var bySlip: [Int: Double] = [:]
        for s in slip { bySlip[s.grain] = s.maximumSchmid }
        var lines = ["grain,phase,points,area_\(unit)2,ecd_\(unit),phi1_deg,Phi_deg,phi2_deg,gos_deg,neighbours,centroid_column,centroid_row,schmid_max_load_\(loadDirection.rawValue)"]
        func f(_ v: Double) -> String { v.isFinite ? String(format: "%.6g", v) : "" }
        for r in analysis.table {
            lines.append([String(r.id), CSVText.quoted(r.phaseName), String(r.points), f(r.area), f(r.diameter), f(r.euler.x), f(r.euler.y), f(r.euler.z),
                          f(r.gosDegrees), String(r.neighbours), f(r.centroid.x), f(r.centroid.y), f(bySlip[r.id] ?? .nan)].joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// The Info tab (design §5): what the map is, where it came from and how its colours are made; the step in `locale`.
    static func infoRows(_ document: OrientationMapSession.Document, locale: Locale = .autoupdatingCurrent) -> [EBSDBrowsing.Row] {
        let map = document.map
        let (rows, columns) = OrientationMaps.gridShape(map)
        let unit = EBSDBrowsing.unitLabel(map.scanUnit)
        var out = [
            EBSDBrowsing.Row("File", document.fileName),
            EBSDBrowsing.Row("Format", document.format),
            EBSDBrowsing.Row("Source", Self.infoSource(document.source)),
            EBSDBrowsing.Row("Map", "\(columns) × \(rows)"),
            EBSDBrowsing.Row("Step", "\(UnitDisplay.number(map.dx, locale: locale)) \(unit) × \(UnitDisplay.number(map.dy, locale: locale)) \(unit)"),
            EBSDBrowsing.Row("Points", "\(map.size)"),
        ]
        let notIndexed = map.phaseIDs.filter { $0 == PhaseList.notIndexedID }.count
        out.append(EBSDBrowsing.Row("Not indexed", "\(notIndexed)"))
        let ids = map.phaseIDs
        for (id, phase) in indexedPhases(map) {
            let count = ids.filter { $0 == id }.count
            out.append(EBSDBrowsing.Row("Phase", "\(phaseName(phase, id: id)) · \(phasePoints(phase, count: count))"))
        }
        out.append(EBSDBrowsing.Row("Euler angles", Self.infoEuler(document)))
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

    /// The Euler row names the reader that read the angles: an H5OINA, with or without patterns, is read as its .ctf is (orix has
    /// no H5OINA reader, #539); the other map files and pattern files' maps through orix's readers or their ports.
    private static func infoEuler(_ document: OrientationMapSession.Document) -> String {
        let h5oina = [OrientationMapSession.h5oinaFormat, EBSDFileFormat.oxfordH5OINA.rawValue].contains(document.format)
        return switch document.source {
        case .mapFile where h5oina, .patterns where h5oina:
            "Bunge (φ₁, Φ, φ₂), lab to crystal, as the H5OINA file stores them (read as its .ctf is)"
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

    // MARK: Labels

    // The words burned into the PNGs are in `ExportSnapshot.labelLocale`, not the reader's: a de_DE reader still gets "0.5 µm" in a
    // figure, as from the Image room. A test passes another locale; the figures take the default.

    /// The scale bar's label: "0.5 µm" (the files write "um").
    static func scaleBarLabel(length: Double, unit: String, locale: Locale = ExportSnapshot.labelLocale) -> String {
        "\(UnitDisplay.number(length, locale: locale)) \(EBSDBrowsing.unitLabel(unit))"
    }

    /// A property or derived layer's value range in the legend: "0.5 to 2.25".
    static func rangeLabel(_ range: ClosedRange<Double>, locale: Locale = ExportSnapshot.labelLocale) -> String {
        "\(UnitDisplay.number(range.lowerBound, digits: 4, locale: locale)) to \(UnitDisplay.number(range.upperBound, digits: 4, locale: locale))"
    }

    /// A texture figure's colour bar: "0 to 3.21 MRD" (multiples of random).
    static func mrdLabel(_ maximum: Double, locale: Locale = ExportSnapshot.labelLocale) -> String {
        "0 to \(UnitDisplay.number(maximum, digits: 3, locale: locale)) MRD"
    }

    /// An image of premultiplied RGBA bytes (#331: the IPF colour key has no other builder): each pixel a block where it is drawn larger
    /// (a map, a figure, the Maps room's key), or smoothed with `interpolate` (the Indexing room's key, `IndexingIPFKey.picture`).
    static func cgImage(premultipliedRGBA rgba: [UInt8], width: Int, height: Int, interpolate: Bool = false) -> CGImage? {
        guard width > 0, height > 0, rgba.count == width * height * 4,
              let provider = CGDataProvider(data: Data(rgba) as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider, decode: nil,
                       shouldInterpolate: interpolate, intent: .defaultIntent)
    }

    /// An IPF colour key as an image: its premultiplied RGBA, transparent outside the sector.
    static func cgImage(_ key: IPFKeyImage, interpolate: Bool = false) -> CGImage? {
        cgImage(premultipliedRGBA: key.premultipliedRGBA8, width: key.width, height: key.height, interpolate: interpolate)
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
            text(scaleBarLabel(length: length, unit: map.scanUnit), at: CGPoint(x: mapRect.minX + barW + 8, y: y - 4), size: 12, ctx: ctx)
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
                if let image = cgImage(key.image) {
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
                text(rangeLabel(range), at: CGPoint(x: x, y: y), size: 11, ctx: ctx)
            }
        case .derived(.grains):
            text("Grains", at: CGPoint(x: x, y: y), size: 12, ctx: ctx)
            y += 18
            text("\(UnitDisplay.count(grainCount ?? 0, "grain", "grains")), each its own colour", at: CGPoint(x: x, y: y), size: 11, ctx: ctx)
            y += 16
            text("grey: below the smallest grain", at: CGPoint(x: x, y: y), size: 11, ctx: ctx)
        case .derived(let derived):
            text(derived.unit.isEmpty ? derived.title : "\(derived.title) (\(derived.unit))", at: CGPoint(x: x, y: y), size: 12, ctx: ctx)
            y += 18
            if let range = raster.valueRange {
                text(rangeLabel(range), at: CGPoint(x: x, y: y), size: 11, ctx: ctx)
            }
        }
        guard let image = ctx.makeImage() else { throw Failure(text: "The figure could not be drawn.") }
        return try encoded(image, fileName: fileName)
    }

    /// A figure as PNG bytes through the app's one encoder (`ImageExport.encodePNG`), the file's name as its Title and macEM as
    /// its Software, as the Patterns room's map PNG carries them.
    private static func encoded(_ image: CGImage, fileName: String) throws -> Data {
        guard let png = try? ImageExport.encodePNG(image, title: fileName, software: "macEM") else {
            throw Failure(text: "The figure could not be encoded.")
        }
        return png
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
        text("\(fileName) · \(texture.phaseName) · \(UnitDisplay.count(texture.points, "point", "points"))", at: CGPoint(x: margin, y: margin), size: 13, ctx: ctx)
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
                text(mrdLabel(figure.maximum), at: CGPoint(x: x, y: y + CGFloat(barH) + 2), size: 10, ctx: ctx)
            }
        }
        row(top, y0: margin + captionH, odf: false)
        if !bottom.isEmpty { row(bottom, y0: margin + captionH + cellH + gap, odf: true) }
        guard let image = ctx.makeImage() else { throw Failure(text: "The figure could not be drawn.") }
        return try encoded(image, fileName: fileName)
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
