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
                          let png = PatternsRoomState.mixPNG(rgba: rgba, width: result.scanColumns, height: result.scanRows) else {
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

/// The Indexing room's Info words, one wording for the inspector's Info tab, the Results room's session rows and the session report.
enum IndexingInfoFormat {
    /// "Hough (pyEBSDindex 0.3.10.1)", "Dictionary (kikuchipy 0.13.1)".
    nonisolated static func method(_ method: IndexingMethod) -> String {
        method == .hough ? "Hough (pyEBSDindex 0.3.10.1)" : "Dictionary (kikuchipy 0.13.1)"
    }

    /// "4,125 of 4,125".
    nonisolated static func indexed(_ result: IndexingResult) -> String {
        "\(result.indexedCount.formatted()) of \(result.pointCount.formatted())"
    }

    /// "3,812 points".
    nonisolated static func points(_ count: Int) -> String { "\(count.formatted()) points" }

    /// "(0.4215, 0.2163, 0.5323) · mean of the file's".
    nonisolated static func projectionCentre(_ pc: SIMD3<Double>) -> String {
        "(\(UnitDisplay.number(pc.x, digits: 4)), \(UnitDisplay.number(pc.y, digits: 4)), \(UnitDisplay.number(pc.z, digits: 4))) · mean of the file's"
    }

    /// "Ni.h5 · Ni · 20 kV · Lambert · 401 × 401".
    nonisolated static func master(_ plan: DictionaryIndexingPlan) -> String { "\(plan.master.fileName) · \(plan.master.summary)" }

    /// "10,000 patterns at 4° · NCC · keep 20".
    nonisolated static func dictionary(_ plan: DictionaryIndexingPlan) -> String {
        "\(plan.rotations.count.formatted()) patterns at \(UnitDisplay.number(plan.settings.resolution))° · \(plan.settings.metric.title) · keep \(min(plan.settings.keep, plan.rotations.count))"
    }

    /// A run against several phases (D-SEM-98), one phase's master pattern: "Ni.h5 · 20 kV, the master pattern's one energy".
    nonisolated static func phaseMaster(_ plan: DictionaryIndexingPlan) -> String { "\(plan.master.fileName) · \(plan.energyWords)" }

    /// The dictionaries of a run: one plan's as `dictionary(_:)`; several, each phase's size: "10,000 + 10,000 patterns at 4° · NCC ·
    /// keep 5".
    nonisolated static func dictionaries(_ plans: [DictionaryIndexingPlan]) -> String {
        guard let first = plans.first else { return "–" }
        guard plans.count > 1 else { return dictionary(first) }
        let sizes = plans.map { $0.rotations.count.formatted() }.joined(separator: " + ")
        let keep = plans.map { min(first.settings.keep, $0.rotations.count) }.min() ?? first.settings.keep
        return "\(sizes) patterns at \(UnitDisplay.number(first.settings.resolution))° · \(first.settings.metric.title) · keep \(keep)"
    }

    /// "1.234 s".
    nonisolated static func time(_ seconds: Double) -> String { "\(UnitDisplay.number(seconds, digits: 3)) s" }

    /// A refinement's mean score over the refined points, as indexed and as refined (D-SEM-109): "NCC 0.412 → 0.453"; after an NDP
    /// dictionary, "NDP 0.91 → NCC 0.453".
    /// "NCC 0.200 → 0.361": three places on both sides, so the two scores line up (three significant digits wrote "0,2 → 0,361").
    nonisolated static func refinementScores(_ s: (before: Double, after: Double, metric: String),
                                             locale: Locale = .autoupdatingCurrent) -> String {
        let n = { (v: Double) in
            v.isFinite ? v.formatted(.number.locale(locale).grouping(.never).precision(.fractionLength(3))) : UnitDisplay.number(v)
        }
        return s.metric == "NCC" ? "NCC \(n(s.before)) → \(n(s.after))" : "\(s.metric) \(n(s.before)) → NCC \(n(s.after))"
    }

    /// A PC triple (Bruker), the refined PCs' mean or standard deviation as the Refine section shows each on its row:
    /// "(0.4214, 0.2142, 0.5013)".
    nonisolated static func triple(_ v: SIMD3<Double>) -> String {
        "(\(UnitDisplay.number(v.x, digits: 4)), \(UnitDisplay.number(v.y, digits: 4)), \(UnitDisplay.number(v.z, digits: 4)))"
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
