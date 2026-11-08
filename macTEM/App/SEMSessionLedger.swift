//
//  SEMSessionLedger.swift
//  Role: the Results room's SEM rows (design export-and-reports §3, D-SEM-103): what the window's SEM rooms hold now and what the session
//        record kept, as `SEMSessionRow`s in the Results room's order: the pattern dataset and its calibration, the processing run, the
//        scan maps, each indexing run (the one on screen, then the other method's), the orientation map, its grain statistics and
//        texture (macTEM#242), the SEM-EDS line intensities and composition, and every file the rooms exported. The session report
//        sets the same rows (`SEMSessionReport`), so the report says nothing the room does not.
//
//        THE WORDS are the rooms': the Indexing room's Info words (`IndexingInfoFormat`), the Patterns room's Calibration rows
//        (`EBSDBrowsing.calibrationRows`), the Maps room's Info rows (`MapsRoomFormat.infoRows`), the EDS room's SEM rows (`SEMEDSFormat`),
//        the Output lines as logged. A few numbers are aggregates of what a run stored, never a second run: the indexed points' mean
//        confidence index (or dictionary score), which the Results CSV holds point by point, and the grains' mean GOS and the points'
//        mean KAM, which the Grains CSV and the KAM layer hold; nothing else is.
//
//        Read on every body that shows the rows (the record and the sessions are observed), as `ResultsLedger` is.
//

import Foundation
import TEMCore
import TEMSession

enum SEMSessionLedger {
    /// Whether the window has any SEM row, without making them (the File menu's and the room list's question).
    static func hasRows(_ appState: AppState) -> Bool {
        appState.ebsd.hasDataset || appState.maps.hasMap || (appState.semEDS.isSEMSpectrum && !appState.semEDS.rows.isEmpty)
            || !appState.semRecord.exports.isEmpty
    }

    /// The window's SEM rows.
    static func rows(of appState: AppState) -> [SEMSessionRow] {
        rows(patterns: appState.ebsd, indexing: appState.indexing, maps: appState.maps, eds: appState.semEDS, record: appState.semRecord)
    }

    static func rows(patterns: EBSDSession, indexing: IndexingSession, maps: OrientationMapSession, eds: SEMEDSState,
                     record: SEMSessionRecord) -> [SEMSessionRow] {
        var rows: [SEMSessionRow] = []
        var since: Date?
        if let document = patterns.document {
            let dataset = datasetRow(document, record: record)
            since = dataset.time
            rows.append(dataset)
            if let row = processingRow(patterns, record: record) { rows.append(row) }
            if let row = scanMapsRow(patterns) { rows.append(row) }
        }
        rows += indexingRows(indexing, record: record, since: since)
        if let row = mapRow(maps, record: record) { rows.append(row) }
        if let row = grainsRow(maps, record: record) { rows.append(row) }
        if let row = textureRow(maps) { rows.append(row) }
        rows += compositionRows(eds)
        rows += exportRows(record)
        return rows
    }

    // MARK: - Patterns

    /// The dataset: its format and shape, the geometry the file states (the Patterns room's Calibration rows).
    static func datasetRow(_ document: EBSDSession.Document, record: SEMSessionRecord) -> SEMSessionRow {
        let dataset = document.dataset
        let format = dataset.version.isEmpty ? dataset.format.rawValue : "\(dataset.format.rawValue) \(dataset.version)"
        return SEMSessionRow(id: "dataset", kind: .dataset, label: document.fileName,
                             value: "\(format) · \(EBSDBrowsing.capsuleDetail(dataset))", source: "Patterns",
                             time: record.lastLine(of: .patterns, startingWith: "Opened \(document.fileName)")?.time,
                             fields: EBSDBrowsing.calibrationRows(dataset).map { SEMSessionField($0.label, $0.value) },
                             methods: [.patternReading], file: document.url)
    }

    /// The processing run that landed: its stages with their settings, whether it is still current, and the lines it logged.
    static func processingRow(_ session: EBSDSession, record: SEMSessionRecord) -> SEMSessionRow? {
        guard let ran = session.processedWith, session.processed != nil, let document = session.document else { return nil }
        let stages = PatternPipeline.Stage.allCases.filter { ran.isActive($0) }
        var fields = processingFields(ran, dataset: document.dataset, lambda: session.nlparLambda)
        if let stale = session.pipeline.firstDifference(from: ran) {
            fields.append(SEMSessionField("State", "Stale from \(stale.title): the settings changed after the run"))
        } else {
            fields.append(SEMSessionField("State", "Current"))
        }
        let log = record.lines(of: .patterns, sinceLastStartingWith: "Opened \(document.fileName)").filter {
            $0.text.hasPrefix("Processed ") || $0.text.hasPrefix("Process:") || $0.text.hasPrefix("Stopped processing")
        }
        return SEMSessionRow(id: "processing", kind: .processing, label: "Pattern processing",
                             value: stages.isEmpty ? "No stage on" : stages.map(\.title).joined(separator: " · "),
                             source: "Patterns · \(document.fileName)",
                             time: record.lastLine(of: .patterns, startingWith: "Processed ")?.time, fields: fields,
                             methods: processingMethods(ran), log: log)
    }

    /// Each stage the pipeline runs, in the inspector's words, in the order the stages run.
    nonisolated static func processingFields(_ p: PatternPipeline, dataset: EBSDDataset, lambda: Double?) -> [SEMSessionField] {
        let n = { (v: Double) in UnitDisplay.number(v) }
        var out: [SEMSessionField] = []
        if p.staticStage.isOn {
            out.append(SEMSessionField("Static background", "\(p.staticStage.operation.title) · \(p.staticStage.source.title)"
                                       + (p.staticStage.scaleBackground ? " · scaled" : "")))
        }
        if p.dynamicStage.isOn {
            let d = p.dynamicStage
            let std = d.std.map { "\(n($0)) px" } ?? "\(n(Double(dataset.patternColumns) / 8)) px (default)"
            out.append(SEMSessionField("Dynamic background", "\(d.operation.title) · \(d.domain == .frequency ? "Gaussian" : "Spatial") · std \(std) · truncate \(n(d.truncate)) std"))
        }
        if p.intensity.mode != .none {
            let i = p.intensity
            var words = i.mode.title
            if i.mode == .rescale, i.usesPercentiles { words += " · percentiles \(n(i.lowPercentile))–\(n(i.highPercentile)) %" }
            if i.mode == .normalize { words += " · \(n(i.numStd)) std" + (i.divideBySquareRoot ? " · ÷ √n" : "") }
            out.append(SEMSessionField("Intensity", words))
        }
        if p.intensity.equalize {
            let kernel = p.intensity.equalizeKernel.map { "\($0) px" } ?? "\(dataset.patternColumns / 4) px (default)"
            out.append(SEMSessionField("Equalise", "kernel \(kernel) · clip limit \(n(p.intensity.clipLimit))"))
        }
        if p.fftFilter.isOn {
            let f = p.fftFilter
            var words = f.pass.title
            if f.usesLowpass { words += " · low-pass cutoff \(n(f.lowCutoff)), width \(n(f.lowWidth))" }
            if f.usesHighpass { words += " · high-pass cutoff \(n(f.highCutoff)), width \(n(f.highWidth))" }
            out.append(SEMSessionField("FFT filter", words))
        }
        if p.binning > 1 {
            out.append(SEMSessionField("Size", "binned \(p.binning)× · \(dataset.patternRows / p.binning) × \(dataset.patternColumns / p.binning) px"))
        }
        if p.averaging.isOn { out.append(SEMSessionField("Average neighbours", p.averaging.window.title)) }
        if p.nlpar.isOn {
            out.append(SEMSessionField("NLPAR", "radius \(p.nlpar.searchRadius) px" + (lambda.map { " · λ " + String(format: "%.3f", $0) } ?? "")))
        }
        return out
    }

    /// The methods of the stages the pipeline runs, in order.
    nonisolated static func processingMethods(_ p: PatternPipeline) -> [SEMMethod] {
        var methods: [SEMMethod] = []
        if p.staticStage.isOn { methods.append(.staticBackground) }
        if p.dynamicStage.isOn { methods.append(.dynamicBackground) }
        if p.intensity.mode != .none { methods.append(.intensity) }
        if p.intensity.equalize { methods.append(.equalisation) }
        if p.fftFilter.isOn { methods.append(.fftFilter) }
        if p.binning > 1 { methods.append(.binning) }
        if p.averaging.isOn { methods.append(.neighbourAveraging) }
        if p.nlpar.isOn { methods.append(.nlpar) }
        return methods
    }

    /// The virtual BSE images and the quality maps the room has computed.
    static func scanMapsRow(_ session: EBSDSession) -> SEMSessionRow? {
        guard let document = session.document else { return nil }
        var names: [String] = []
        var fields: [SEMSessionField] = []
        var methods: [SEMMethod] = []
        if session.virtualImages != nil {
            let grid = session.virtualGrid
            names.append("Virtual BSE \(grid.rows) × \(grid.columns)")
            fields.append(SEMSessionField("Virtual BSE", "\(grid.rows) × \(grid.columns) tiles"))
            if session.hasMix {
                let tiles = session.mixTiles.map { $0?.label ?? "none" }
                fields.append(SEMSessionField("Colour mix", "red \(tiles[0]) · green \(tiles[1]) · blue \(tiles[2])"))
            }
            methods.append(.virtualBSE)
        }
        if session.imageQualityMap != nil {
            names.append("Image quality")
            methods.append(.imageQuality)
        }
        if session.dotProductMap != nil {
            names.append("Average dot product")
            methods.append(.averageDotProduct)
        }
        guard !methods.isEmpty else { return nil }
        if session.imageQualityMap != nil || session.dotProductMap != nil {
            fields.append(SEMSessionField("Quality maps", "of the patterns as stored"))
        }
        fields.append(SEMSessionField("On screen", PatternsRoomState.mapName(session.mapChoice)))
        return SEMSessionRow(id: "scanMaps", kind: .scanMaps, label: "Scan maps", value: names.joined(separator: " · "),
                             source: "Patterns · \(document.fileName)", fields: fields, methods: methods)
    }

    // MARK: - Indexing

    /// The Indexing room's runs, the one on screen first, then the other method's when it reached a point (Info's `Also held`).
    static func indexingRows(_ session: IndexingSession, record: SEMSessionRecord, since: Date?) -> [SEMSessionRow] {
        guard let shown = session.shownRun else { return [] }
        var rows: [SEMSessionRow] = []
        if let row = indexingRow(shown, id: "indexing", session: session, record: record, since: since) { rows.append(row) }
        if let other = session.otherRun,
           let row = indexingRow(other, id: "indexing.\(other.method.rawValue)", session: session, record: record, since: since) {
            rows.append(row)
        }
        return rows
    }

    /// One indexing run: the Indexing room's Info words, its settings, the mean score of the indexed points, the lines it logged since
    /// the dataset opened.
    static func indexingRow(_ run: IndexingRun, id: String, session: IndexingSession, record: SEMSessionRecord,
                            since: Date?) -> SEMSessionRow? {
        let result = run.result
        guard result.reachedCount > 0, let document = session.patterns.document else { return nil }
        var fields = [
            SEMSessionField("Method", IndexingInfoFormat.method(result.method)),
            SEMSessionField("Phases", result.phases.map(\.name).joined(separator: ", ")),
            SEMSessionField("Indexed", IndexingInfoFormat.indexed(result)),
        ]
        let counts = result.countsByPhase
        for (i, phase) in result.phases.enumerated() {
            fields.append(SEMSessionField(phase.name, IndexingInfoFormat.points(counts.indices.contains(i) ? counts[i] : 0)))
        }
        let scores = result.solutions.compactMap { $0 }.filter { $0.phase >= 0 }.map(\.confidence).filter(\.isFinite)
        if !scores.isEmpty {
            let mean = scores.reduce(0, +) / Double(scores.count)
            fields.append(SEMSessionField("Mean \(result.scoreTitle)", "\(UnitDisplay.number(mean, digits: 4)) over the indexed points"))
        }
        fields.append(SEMSessionField("Patterns", run.source.title))
        if let pc = run.projectionCenter { fields.append(SEMSessionField("PC", IndexingInfoFormat.projectionCentre(pc))) }
        if result.method == .dictionary, run.dictionaryPlans.count == 1, let plan = run.dictionaryPlans.first {
            fields.append(SEMSessionField("Master", IndexingInfoFormat.master(plan)))
            fields.append(SEMSessionField("Energy", plan.energyWords))
            fields.append(SEMSessionField("Dictionary", IndexingInfoFormat.dictionary(plan)))
        } else if result.method == .dictionary, !run.dictionaryPlans.isEmpty {
            // A run against several phases (D-SEM-98): each phase's master pattern and energy, then the dictionaries.
            for plan in run.dictionaryPlans {
                fields.append(SEMSessionField("\(plan.phase.name) master", IndexingInfoFormat.phaseMaster(plan)))
            }
            fields.append(SEMSessionField("Dictionary", IndexingInfoFormat.dictionaries(run.dictionaryPlans)))
        } else if result.method == .hough {
            fields += houghFields(run.inputs.settings)
        }
        fields.append(SEMSessionField("State", IndexingInfoFormat.state(of: run, session: session)))
        if let seconds = run.seconds { fields.append(SEMSessionField("Time", IndexingInfoFormat.time(seconds))) }
        let methods: [SEMMethod] = result.method == .hough
            ? [.houghIndexing, .orientationMap, .ipfColours]
            : [.dictionaryIndexing, .orientationSimilarity, .orientationMap, .ipfColours]
        let log = record.lines(of: .indexing).filter { line in
            (since.map { line.time >= $0 } ?? true) && IndexingInfoFormat.isLine(line.text, of: result.method)
        }
        let ended = log.last { $0.text.hasPrefix("Indexed ") || $0.text.hasPrefix("Stopped ") }
        return SEMSessionRow(id: id, kind: .indexing, label: "\(result.method.title) indexing",
                             value: "\(IndexingInfoFormat.indexed(result)) indexed · \(result.phases.map(\.name).joined(separator: ", "))",
                             source: "Indexing · \(document.fileName)", time: ended?.time, fields: fields, methods: methods, log: log)
    }

    /// The Hough settings in the inspector's words.
    nonisolated static func houghFields(_ s: HoughIndexingSettings) -> [SEMSessionField] {
        let n = { (v: Double) in UnitDisplay.number(v, digits: 4) }
        return [
            SEMSessionField("Bands", "\(s.bands)"),
            SEMSessionField("ρ mask", "\(n(s.rhoMaskFraction * 100)) %"),
            SEMSessionField("ρ bins", "\(s.rhoBins)"),
            SEMSessionField("θ bins", "\(s.thetaBins)"),
            SEMSessionField("ρ width", "\(n(s.rhoSigma)) bins"),
            SEMSessionField("θ width", "\(n(s.thetaSigma)) bins"),
            SEMSessionField("Tolerance", "\(n(s.angleTolerance))°"),
            SEMSessionField("Early exit", "\(s.earlyExitBands) bands"),
        ]
    }

    // MARK: - Maps

    /// The orientation map in the Maps room: its Info rows (the method rows are the report's Methods section) and the layer on screen.
    static func mapRow(_ session: OrientationMapSession, record: SEMSessionRecord) -> SEMSessionRow? {
        guard let document = session.document else { return nil }
        let methodRows: Set<String> = ["File", "Euler angles", "IPF colours", "Phase colours"]
        var fields = MapsRoomFormat.infoRows(document).filter { !methodRows.contains($0.label) }.map { SEMSessionField($0.label, $0.value) }
        fields.append(SEMSessionField("Layer on screen", session.layer.title))
        return SEMSessionRow(id: "map", kind: .orientationMap, label: document.fileName, value: MapsRoomFormat.capsuleDetail(document.map),
                             source: "Maps", time: record.lastLine(of: .maps, startingWith: "Opened \(document.fileName)")?.time,
                             fields: fields, methods: [.orientationMap, .ipfColours], file: document.url)
    }

    // MARK: - Grains and texture (macTEM#242)

    /// The Maps room's grain analysis: the Grains section's summary rows, the mean GOS of the grains and the mean KAM of the points that
    /// have one (aggregates of what Segment stored, never a second run), the settings it ran with, and whether they changed since.
    static func grainsRow(_ session: OrientationMapSession, record: SEMSessionRecord) -> SEMSessionRow? {
        guard let document = session.document, let analysis = session.analysis else { return nil }
        let stale = session.analysisIsStale
        var fields = MapsRoomFormat.grainRows(analysis).filter { $0.label != "Made with" }.map { SEMSessionField($0.label, $0.value) }
        fields += grainMeans(analysis)
        fields += MapsRoomFormat.analysisFields(analysis.settings)
        fields.append(SEMSessionField("State", stale ? "Stale: the Grains or Misorientation settings changed after Segment" : "Current"))
        let segmented = record.lastLine(of: .maps, startingWith: "Segmented ")
        return SEMSessionRow(id: "grains", kind: .grains, label: "Grain statistics",
                             value: MapsRoomFormat.grainSummary(analysis) + (stale ? " · stale" : ""),
                             source: "Maps · \(document.fileName)", time: segmented?.time, fields: fields,
                             methods: [.grains, .kam, .gos], log: segmented.map { [$0] } ?? [])
    }

    /// The mean GOS over the grain table and the mean KAM over the points that have one, in degrees.
    nonisolated static func grainMeans(_ analysis: MapAnalysis) -> [SEMSessionField] {
        var out: [SEMSessionField] = []
        let gos = analysis.table.map(\.gosDegrees).filter(\.isFinite)
        if !gos.isEmpty {
            out.append(SEMSessionField("Mean GOS", "\(MapsRoomFormat.angle(gos.reduce(0, +) / Double(gos.count), digits: 2))° over \(gos.count) grains"))
        }
        let kam = analysis.grains.kam.filter(\.isFinite)
        if !kam.isEmpty {
            let mean = kam.reduce(0, +) / Double(kam.count) * 180 / Double.pi
            out.append(SEMSessionField("Mean KAM", "\(MapsRoomFormat.angle(mean, digits: 2))° over \(kam.count) points"))
        }
        return out
    }

    /// The texture the Maps room's Pole figures and ODF tabs show: its phase and points, each figure's largest density in multiples of
    /// random, and the tabs' captions (the smoothing, the ODF kernel and the points it used).
    static func textureRow(_ session: OrientationMapSession) -> SEMSessionRow? {
        guard let document = session.document, let texture = session.texture else { return nil }
        let figures = texture.poleFigures + (texture.inversePoleFigure.map { [$0] } ?? []) + texture.odfSections
        var fields = [SEMSessionField("Phase", texture.phaseName), SEMSessionField("Points", "\(texture.points)")]
        fields += figures.map { SEMSessionField($0.title, "maximum \(MapsRoomFormat.number($0.maximum)) MRD") }
        fields.append(SEMSessionField("Pole figures", MapsRoomFormat.textureCaption(texture, odf: false)))
        if !texture.odfSections.isEmpty { fields.append(SEMSessionField("ODF", MapsRoomFormat.textureCaption(texture, odf: true))) }
        let largest = texture.poleFigures.map(\.maximum).filter(\.isFinite).max()
        var value = "\(texture.points) points · " + texture.poleFigures.map(\.title).joined(separator: " ")
        if let largest { value += " · up to \(MapsRoomFormat.number(largest)) MRD" }
        return SEMSessionRow(id: "texture", kind: .texture, label: "\(texture.phaseName) texture", value: value,
                             source: "Maps · \(document.fileName)", fields: fields, methods: [.orientationMap, .texture])
    }

    // MARK: - SEM-EDS

    /// One row per X-ray line of the SEM spectrum the EDS room shows: its window and intensity, and its composition once quantified.
    static func compositionRows(_ eds: SEMEDSState) -> [SEMSessionRow] {
        guard eds.isSEMSpectrum, let path = eds.path, !eds.rows.isEmpty else { return [] }
        let url = URL(fileURLWithPath: path)
        let composition = Dictionary((eds.composition ?? []).map { ($0.line, $0) }, uniquingKeysWith: { a, _ in a })
        let quantified = eds.composition != nil
        return eds.rows.map { row in
            var fields = [
                SEMSessionField("Energy", "\(SEMEDSFormat.keV(row.energyKeV)) keV"),
                SEMSessionField("Window", SEMEDSFormat.windows(row)),
                SEMSessionField("Intensity", "\(SEMEDSFormat.counts(row.intensity)) counts"),
            ]
            var value = "\(SEMEDSFormat.counts(row.intensity)) counts"
            if quantified {
                let k = eds.kFactors[row.line].map { UnitDisplay.number($0, digits: 4) } ?? "none"
                fields.append(SEMSessionField("k-factor", k))
                if let c = composition[row.line] {
                    let wt = "\(SEMEDSFormat.percent(c.weightPercent)) wt%", at = "\(SEMEDSFormat.percent(c.atomicPercent)) at%"
                    fields.append(SEMSessionField("Weight", wt))
                    fields.append(SEMSessionField("Atomic", at))
                    value = "\(wt) · \(at)" + (eds.compositionIsStale ? " · stale" : "")
                } else {
                    fields.append(SEMSessionField("Weight", ""))
                    fields.append(SEMSessionField("Atomic", ""))
                }
            }
            return SEMSessionRow(id: "eds:\(row.line)", kind: .composition, label: SEMEDSFormat.lineTitle(row.line), value: value,
                                 source: "EDS · \(url.lastPathComponent)", fields: fields,
                                 methods: quantified ? [.edsLines, .cliffLorimer] : [.edsLines], file: url)
        }
    }

    // MARK: - Exports

    /// Every file a SEM room wrote, in order, with its picture when it is one.
    static func exportRows(_ record: SEMSessionRecord) -> [SEMSessionRow] {
        record.exports.enumerated().map { index, export in
            let figure = export.png.flatMap { SEMReportFigure(png: $0, caption: "", file: export.file) }
            var value = export.what
            if let figure { value += ", \(figure.pixelWidth) × \(figure.pixelHeight) px" }
            return SEMSessionRow(id: "export:\(index)", kind: .export, label: export.file?.lastPathComponent ?? export.what, value: value,
                                 source: "\(export.room) · \(export.source)", time: export.time, fields: export.fields, methods: export.methods,
                                 file: export.file, figure: figure)
        }
    }
}
