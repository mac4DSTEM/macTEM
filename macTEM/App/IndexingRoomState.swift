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

/// What the Indexing room's Export section writes (design §4): the map on screen as a PNG (an orientation or phase layer one pixel per
/// point; a scalar layer as the pane draws it, with its colormap, window and scale bar, D-SEM-96), the results as CSV, the orientations as EDAX
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
    /// The export the save panel is writing, as the session record keeps it once the panel says where (`didWrite`).
    @ObservationIgnored private(set) var pendingRecord: SEMExportedFile?
    /// Told of every file the room writes (`AppState` keeps it in the session record for the Results room and the report).
    @ObservationIgnored var onWritten: ((SEMExportedFile) -> Void)?

    /// The save panel wrote the export to `url`.
    func didWrite(to url: URL) {
        if let pendingRecord { onWritten?(pendingRecord.written(to: url, at: Date())) }
        pendingRecord = nil
    }

    /// Makes the bytes of `kind` from the session and opens the save panel, or, with `directory` (the UI journeys' export folder), writes the
    /// file there; says why when there is nothing to write.
    @MainActor func export(_ kind: IndexingExportKind, from session: IndexingSession, directory: URL? = nil, report: (String) -> Void) {
        guard let document = session.patterns.document else { report("Nothing to export yet: no dataset is open."); return }
        guard let result = session.result, result.reachedCount > 0 else { report("Nothing to export yet: Index has not run."); return }
        let data: Data
        do {
            switch kind {
            case .mapPNG:
                if session.showsScalarMap, let canvas = session.mapPresentation.canvas {
                    // A scalar layer as the pane shows it (colormap, window, gamma, scale bar), through the Image room's exporter.
                    data = try PatternsRoomState.mapPNG(canvas: canvas, presentation: session.mapPresentation, dataset: document.dataset,
                                                        fileName: document.fileName, map: "indexed \(session.layer.title)")
                } else {
                    guard let rgba = session.mapRGBA,
                          let png = PatternsRoomState.mixPNG(rgba: rgba, width: result.scanColumns, height: result.scanRows,
                                                             fileName: document.fileName) else {
                        report("Export failed: the map could not be encoded."); return
                    }
                    data = png
                }
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
        let record = Self.record(kind, data: data, layer: exportLayer, method: result.method, refined: session.shownRun?.refinement != nil,
                                 fileName: document.fileName)
        if let directory {
            let name = (document.fileName as NSString).deletingPathExtension + kind.suffix(layer: exportLayer)
            let url = directory.appendingPathComponent(name).appendingPathExtension(kind.fileExtension)
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

    /// The export as the session record keeps it: what it is, the layer a map is of, the methods that made it (a refinement's, its
    /// dictionary indexing then the refinement, D-SEM-109), the PNG's bytes.
    nonisolated static func record(_ kind: IndexingExportKind, data: Data, layer: IndexingLayer, method: IndexingMethod, refined: Bool = false,
                                   fileName: String) -> SEMExportedFile {
        let indexing: [SEMMethod] = method == .hough ? [.houghIndexing] : [.dictionaryIndexing] + (refined ? [.patternRefinement] : [])
        let methods: [SEMMethod]
        var fields: [SEMSessionField] = []
        switch kind {
        case .mapPNG:
            fields.append(SEMSessionField("Layer", layer.title))
            methods = layer.direction != nil ? indexing + [.ipfColours] : indexing
        case .resultsCSV, .methodJSON: methods = indexing
        case .ang: methods = indexing + [.angWriter]
        case .ctf: methods = indexing + [.ctfWriter]
        }
        return SEMExportedFile(room: "Indexing", what: SEMExportedFile.what(kind.title), source: fileName, fields: fields, methods: methods,
                               png: kind == .mapPNG ? data : nil)
    }
}

// MARK: - Words

/// The Indexing room's Info words, one wording for the inspector's Info tab, the Results room's session rows and the session report, and
/// the words of the inspector's Calibration and Dictionary rows and the Results table's header. The numbers are in the reader's decimal
/// mark and a count is never grouped, as `Num` writes every number on screen: "4125 of 4125" on every Mac, where the screen grouped
/// ("4.125 of 4.125" in German) beside a report that does not; the session report passes `ExportSnapshot.labelLocale`.
enum IndexingInfoFormat {
    /// "Hough (pyEBSDindex 0.3.10.1)", "Dictionary (kikuchipy 0.13.1)".
    nonisolated static func method(_ method: IndexingMethod) -> String {
        method == .hough ? "Hough (pyEBSDindex 0.3.10.1)" : "Dictionary (kikuchipy 0.13.1)"
    }

    /// A count as the room writes it: "4125", never grouped, as `Num` writes a whole number (and the SEM-EDS rows their counts).
    nonisolated static func count(_ n: Int, locale: Locale = .autoupdatingCurrent) -> String { Num.fixed(Double(n), 0, locale: locale) }

    /// "4125 of 4125".
    nonisolated static func indexed(_ result: IndexingResult, locale: Locale = .autoupdatingCurrent) -> String {
        "\(count(result.indexedCount, locale: locale)) of \(count(result.pointCount, locale: locale))"
    }

    /// "3812 points", "1 point".
    nonisolated static func points(_ n: Int, locale: Locale = .autoupdatingCurrent) -> String {
        "\(count(n, locale: locale)) \(UnitDisplay.noun(n, "point", "points"))"
    }

    /// "(0.4215, 0.2163, 0.5323) · mean of the file's"; "(0,4215; 0,2163; 0,5323) · …" where the decimal mark is a comma.
    nonisolated static func projectionCentre(_ pc: SIMD3<Double>, locale: Locale = .autoupdatingCurrent) -> String {
        triple(pc, locale: locale) + " · mean of the file's"
    }

    /// The Calibration section's PC help, its count never grouped: "The mean of the file's 4125 projection centres, …" (a Bruker
    /// h5ebsd file holds one per pattern); "The file's projection centre, …" for one. A `String`, so `.help` does not take it as a
    /// localized key, which groups an interpolated count ("4.125" in German).
    nonisolated static func projectionCentreHelp(count n: Int, locale: Locale = .autoupdatingCurrent) -> String {
        n > 1 ? "The mean of the file's \(count(n, locale: locale)) projection centres, Bruker convention (kikuchipy's pc_average)"
              : "The file's projection centre, Bruker convention"
    }

    /// The detected bands' spoken value: "6 of 9 matched", the counts never grouped.
    nonisolated static func matchedBands(_ matched: Int, of total: Int, locale: Locale = .autoupdatingCurrent) -> String {
        "\(count(matched, locale: locale)) of \(count(total, locale: locale)) matched"
    }

    /// The Calibration section's tilts in the Patterns room's words (`EBSDBrowsing.calibrationRows`): "Sample tilt 70°", "Detector
    /// tilt 0°".
    nonisolated static func tiltRows(_ detector: EBSDDetectorGeometry, locale: Locale = .autoupdatingCurrent) -> [EBSDBrowsing.Row] {
        [EBSDBrowsing.Row("Sample tilt", "\(UnitDisplay.number(detector.sampleTilt, locale: locale))°"),
         EBSDBrowsing.Row("Detector tilt", "\(UnitDisplay.number(detector.tilt, locale: locale))°")]
    }

    /// The Results table's header, the run named as the map's title names it, then its PC as the Calibration row writes it: "Results ·
    /// Dictionary · Refined · ni · 4125 of 4125 indexed · PC (0.4215, 0.2163, 0.5323)".
    nonisolated static func resultsHeader(_ result: IndexingResult, run: String, projectionCentre pc: SIMD3<Double>?,
                                          locale: Locale = .autoupdatingCurrent) -> String {
        let phases = result.phases.map(\.name).joined(separator: ", ")
        let words = "Results · \(run) · \(phases) · \(count(result.indexedCount, locale: locale)) of \(count(result.reachedCount, locale: locale)) indexed"
        return pc.map { words + " · PC " + triple($0, locale: locale) } ?? words
    }

    /// The Dictionary section's size row: "11935 patterns at 4°"; with several phases one count each, "11935 + 11935 patterns at 4°".
    /// `sizes` nil while they are counted ("Counting at 4°" when they can be) or when they cannot be (`UnitDisplay.noValue`).
    nonisolated static func dictionarySize(_ sizes: [Int]?, resolution: Double, countable: Bool, locale: Locale = .autoupdatingCurrent) -> String {
        let at = "\(UnitDisplay.number(resolution, locale: locale))°"
        guard let sizes else { return countable ? "Counting at \(at)" : UnitDisplay.noValue }
        return "\(sizes.map { count($0, locale: locale) }.joined(separator: " + ")) patterns at \(at)"
    }

    /// The Dictionary section's Chunk row, as the run would cut the work now: "2000 patterns · 6 chunks", "· over 2 dictionaries" with
    /// several phases on, "per block · 3 blocks" when the scan is read in blocks; `UnitDisplay.noValue` before the dictionaries are counted.
    nonisolated static func chunking(_ cut: (size: Int, chunks: Int, blocks: Int)?, dictionaries: Int,
                                     locale: Locale = .autoupdatingCurrent) -> String {
        guard let cut, cut.size > 0 else { return UnitDisplay.noValue }
        let over = dictionaries > 1 ? " over \(dictionaries) dictionaries" : ""
        let chunks = "\(count(cut.size, locale: locale)) patterns · \(UnitDisplay.count(cut.chunks, "chunk", "chunks"))\(over)"
        return cut.blocks > 1 ? chunks + " per block · \(cut.blocks) blocks" : chunks
    }

    /// "Ni.h5 · Ni · 20 kV · Lambert · 401 × 401".
    nonisolated static func master(_ plan: DictionaryIndexingPlan) -> String { "\(plan.master.fileName) · \(plan.master.summary)" }

    /// "10000 patterns at 4° · NCC · keep 20".
    nonisolated static func dictionary(_ plan: DictionaryIndexingPlan, locale: Locale = .autoupdatingCurrent) -> String {
        "\(count(plan.rotations.count, locale: locale)) patterns at \(UnitDisplay.number(plan.settings.resolution, locale: locale))° · \(plan.settings.metric.title) · keep \(min(plan.settings.keep, plan.rotations.count))"
    }

    /// A run against several phases (D-SEM-98), one phase's master pattern: "Ni.h5 · 20 kV, the master pattern's one energy".
    nonisolated static func phaseMaster(_ plan: DictionaryIndexingPlan) -> String { "\(plan.master.fileName) · \(plan.energyWords)" }

    /// The dictionaries of a run: one plan's as `dictionary(_:)`; several, each phase's size: "10000 + 10000 patterns at 4° · NCC ·
    /// keep 5"; `UnitDisplay.noValue` for none.
    nonisolated static func dictionaries(_ plans: [DictionaryIndexingPlan], locale: Locale = .autoupdatingCurrent) -> String {
        guard let first = plans.first else { return UnitDisplay.noValue }
        guard plans.count > 1 else { return dictionary(first, locale: locale) }
        let sizes = plans.map { count($0.rotations.count, locale: locale) }.joined(separator: " + ")
        let keep = plans.map { min(first.settings.keep, $0.rotations.count) }.min() ?? first.settings.keep
        return "\(sizes) patterns at \(UnitDisplay.number(first.settings.resolution, locale: locale))° · \(first.settings.metric.title) · keep \(keep)"
    }

    /// "1.234 s".
    nonisolated static func time(_ seconds: Double, locale: Locale = .autoupdatingCurrent) -> String {
        "\(UnitDisplay.number(seconds, digits: 3, locale: locale)) s"
    }

    /// A refinement's mean score over the refined points, as indexed and as refined (D-SEM-109): "NCC 0.412 → 0.453"; after an NDP
    /// dictionary, "NDP 0.91 → NCC 0.453".
    /// "NCC 0.200 → 0.361": three places on both sides, so the two scores line up (three significant digits wrote "0,2 → 0,361"), as the
    /// Results table writes a score (`IndexingTableFormat.fraction`).
    nonisolated static func refinementScores(_ s: (before: Double, after: Double, metric: String),
                                             locale: Locale = .autoupdatingCurrent) -> String {
        let n = { (v: Double) in IndexingTableFormat.fraction(v, locale: locale) }
        return s.metric == "NCC" ? "NCC \(n(s.before)) → \(n(s.after))" : "\(s.metric) \(n(s.before)) → NCC \(n(s.after))"
    }

    /// A PC triple (Bruker) at four significant digits, as the Calibration row, the Results header and the Refine section's mean and
    /// standard deviation write it: "(0.4214, 0.2142, 0.5013)"; "(0,4214; 0,2142; 0,5013)" where the decimal mark is a comma, as the
    /// Patterns room writes it (`UnitDisplay.triple`).
    nonisolated static func triple(_ v: SIMD3<Double>, locale: Locale = .autoupdatingCurrent) -> String {
        UnitDisplay.triple(v, digits: 4, locale: locale)
    }

    /// The run's state: running, stopped, stale or current.
    static func state(_ result: IndexingResult, session: IndexingSession) -> String {
        if session.isRefining { return "Refining, row \(result.rowsDone) of \(result.scanRows)" }
        if session.isIndexing, result.method == .dictionary {
            // With several phases, the phase whose dictionary is being matched (D-SEM-98).
            let phase = session.chunkPhase.map { " · \($0)" } ?? ""
            return "Indexing, chunk \(session.chunksDone) of \(session.chunksTotal)\(phase) · row \(result.rowsDone) of \(result.scanRows)"
        }
        if session.isIndexing { return "Indexing, row \(result.rowsDone) of \(result.scanRows)" }
        if session.wasStopped { return "Stopped at row \(result.rowsDone) of \(result.scanRows)" }
        return session.isStale ? "Stale: the patterns, phases or settings changed" : "Current"
    }

    /// `run`'s state in the same words: the run on screen as `state(_:session:)` says it, the other method's run stopped, stale or
    /// current.
    static func state(of run: IndexingRun, session: IndexingSession) -> String {
        if session.shownRun?.id == run.id { return state(run.result, session: session) }
        let result = run.result
        if run.wasStopped { return "Stopped at row \(result.rowsDone) of \(result.scanRows)" }
        return session.isStale(of: run.method) ? "Stale: the patterns, phases or settings changed" : "Current"
    }

    /// Whether an Output line of the room is about a run of `method`: its "Indexed … with <Method>" or its "Stopped …" line, and for
    /// a dictionary run the master pattern it opened; a refinement's (`refined`, D-SEM-109) also its "Refined …" and "Stopped
    /// refinement …", which a Dictionary run as indexed leaves out.
    nonisolated static func isLine(_ text: String, of method: IndexingMethod, refined: Bool = false) -> Bool {
        if text.hasPrefix("Indexed ") { return text.contains(" with \(method.title) ") }
        switch method {
        case .hough: return text.hasPrefix("Stopped indexing ")
        case .dictionary:
            return text.hasPrefix("Stopped dictionary indexing ") || text.hasPrefix("Opened the master pattern ")
                || (refined && (text.hasPrefix("Refined ") || text.hasPrefix("Stopped refinement ")))
        }
    }
}
