//
//  IndexingSession.swift
//  Role: the one owner of the Indexing room's state (docs/sem/design/indexing-room.md): the phases indexed against, the method (Hough
//        or Dictionary, D-SEM-91) and its settings, the master patterns opened for a dictionary, the run (its result, filled row by
//        row or block by block, and what it was made of, so a later change to Processing, the phases or the method's settings stales
//        it), the map on screen as RGBA, the pattern pane's pattern with its detected bands, and a dictionary run's best match at that
//        point. The dataset, its processing and the pinned position are the Patterns room's (`EBSDSession`): the two rooms share one
//        scan and one marker.
//
//  Nothing here makes a number: the indexing is `HoughIndexer`'s (pyEBSDindex's port) or `DictionaryIndexing`'s (kikuchipy's), the
//  colours `IndexingRaster`'s (orix's keys), the patterns `IndexingSource`'s. This owner decides WHEN: a run in one detached task that
//  indexes the scan row by row (Hough) or block of rows by block (dictionary, its chunks counted for the toolbar) and lands each only if
//  no newer run or dataset started meanwhile (`generation`), so the map grows in place and Stop keeps the indexed rows; the pattern
//  under the pointer in a task the next hover cancels; the band detector (the Radon line plan) built once per settings off the main
//  actor and kept (`probe`); the dictionary's orientations sampled once per resolution and point group and kept (`sampled`).
//

import Foundation
import Observation
import TEMCore

@Observable
package final class IndexingSession {
    /// The Patterns room's owner: the dataset, its processing and the pinned position the two rooms share.
    package let patterns: EBSDSession

    // MARK: The settings

    /// The phases to index against, in the indexer's order once on: the file's crystal map's, then those added here.
    package private(set) var phases: [IndexingPhase] = []
    /// The file's phases left out for want of a space group or a lattice (Info names them).
    package private(set) var skippedPhases: [String] = []
    package private(set) var settings = HoughIndexingSettings.roomDefault
    /// How Index indexes (D-SEM-91).
    package private(set) var method = IndexingMethod.hough
    package private(set) var dictionarySettings = DictionaryIndexingSettings.roomDefault
    /// The master patterns opened, in the order opened (the shipped Ni 20 kV one first); kept across datasets.
    package private(set) var masterPatterns: [IndexingMasterPattern] = []
    /// The one a dictionary is projected from (`IndexingMasterPattern.id`).
    package private(set) var masterID: String?
    package private(set) var isLoadingMaster = false
    /// The dictionary's orientations at the current resolution for the phase on; nil while they are counted or when there is no one
    /// phase on.
    package private(set) var dictionarySize: Int?
    /// What the map shows.
    package private(set) var layer = IndexingLayer.ipfZ
    /// Whether the pattern pane draws the detected bands.
    package var showsDetectedBands = true

    // MARK: The run

    /// The last run, filled row by row while it runs; nil before the first.
    package private(set) var result: IndexingResult?
    /// What the last run was made of (stales it when the current inputs differ) and where it read its patterns.
    package private(set) var resultInputs: IndexingInputs?
    package private(set) var resultSource: IndexingSource.Kind?
    package private(set) var resultProjectionCenter: SIMD3<Double>?
    package private(set) var isIndexing = false
    /// The run's fraction of rows done (0...1).
    package private(set) var progress = 0.0
    /// The last complete run's time; nil while running or after a stop.
    package private(set) var lastRunSeconds: Double?
    /// The last run was stopped: its indexed rows stay, the rest of the map shows the navigator.
    package private(set) var wasStopped = false
    /// A dictionary run's chunks done and in all (every block runs the whole dictionary in chunks).
    package private(set) var chunksDone = 0
    package private(set) var chunksTotal = 0
    /// The last dictionary run's plan: its master pattern, orientations, detector and energy (Info, the method record, Best match).
    package private(set) var dictionaryPlan: DictionaryIndexingPlan?

    // MARK: The pictures

    /// The map as RGBA, one pixel per scan point, and its version for the Metal view.
    package private(set) var mapRGBA: [UInt8]?
    package private(set) var mapVersion = 0
    /// The pattern as it is indexed (through the pipeline), drawn with its own contrast.
    package let patternPresentation = ImagePresentation()
    /// The position under the pointer while it hovers the map, else nil (the pinned position is the Patterns room's).
    package private(set) var hovered: EBSDPosition?
    /// The position of the pattern on screen.
    package private(set) var patternPosition: EBSDPosition?
    /// The detected bands of the pattern on screen, with what the run matched them to.
    package private(set) var detectedBands: [IndexedBand] = []
    /// The shape of the pattern on screen (binned when the pipeline bins).
    package private(set) var patternShape = (rows: 0, columns: 0)
    /// Why the pattern could not be shown as it is indexed; nil when it could.
    package private(set) var patternFailure: String?
    /// The IPF colour key of each point group in the phases, by orix name, once made.
    package private(set) var keyImages: [String: IPFKeyImage] = [:]
    /// A dictionary run's best match at the pattern pane's point: the simulated pattern of its orientation on the run's detector.
    package let bestMatchPresentation = ImagePresentation()
    /// The point the best match on screen is of; nil when there is none (no dictionary result there).
    package private(set) var bestMatchPosition: EBSDPosition?
    package private(set) var bestMatchFailure: String?

    /// The infobar's line for an event and the alert for a failure (the window's `AppState` wires them).
    package var onEvent: ((String) -> Void)?
    package var onFailure: ((any Error) -> Void)?

    nonisolated private struct ProbeKey: Equatable, Sendable {
        var pipeline: PatternPipeline
        var settings: HoughIndexingSettings
        var kind: IndexingSource.Kind
        var generation: Int
    }

    nonisolated private struct ShownKey: Equatable, Sendable {
        var position: EBSDPosition
        var probe: ProbeKey
    }

    nonisolated private struct Inspected: Sendable {
        var probe: IndexingProbe
        var canvas: CanvasPixels
        var bands: [HoughBandDetector.Band]
    }

    /// The dictionary's orientations are those of a resolution in a point group's fundamental zone.
    nonisolated private struct SamplingKey: Equatable, Sendable {
        var resolution: Double
        var pointGroup: String
    }

    nonisolated private struct BestMatchKey: Equatable, Sendable {
        var position: EBSDPosition
        var run: Int
        var simulation: Int
    }

    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var patternTask: Task<Void, Never>?
    /// Bumped by every dataset bound or closed (a pattern or a key that lands for another dataset is dropped) and by every run (a row
    /// that lands for an earlier run is dropped).
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var runGeneration = 0
    @ObservationIgnored private var palette: IndexingPalette?
    /// The band detector of the current settings, kept between hovers and handed to the run.
    @ObservationIgnored private var probe: (key: ProbeKey, probe: IndexingProbe)?
    /// The libraries of the last run, for the Bands table's families.
    @ObservationIgnored private var runPlan: IndexingPlan?
    @ObservationIgnored private var shownKey: ShownKey?
    @ObservationIgnored private var shownRaw: [HoughBandDetector.Band] = []
    /// The dictionary's orientations last sampled, kept for the next run at the same resolution and point group.
    @ObservationIgnored private var sampled: (key: SamplingKey, rotations: [SIMD4<Double>])?
    @ObservationIgnored private var samplingTask: Task<Void, Never>?
    @ObservationIgnored private var masterTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var bestMatchTask: Task<Void, Never>?
    @ObservationIgnored private var bestMatchKey: BestMatchKey?

    package init(patterns: EBSDSession) {
        self.patterns = patterns
    }

    package var hasDataset: Bool { patterns.hasDataset }
    package var isBusy: Bool { isIndexing }
    /// What the pattern pane shows: the hovered position while there is one, else the pinned.
    package var shown: EBSDPosition { hovered ?? patterns.pinned }
    package var phasesOn: [IndexingPhase] { phases.filter(\.isOn) }
    /// The inputs a run of `method` would take now.
    package func inputs(for method: IndexingMethod) -> IndexingInputs {
        IndexingInputs(pipeline: patterns.pipeline, phases: phases, settings: settings, method: method, dictionary: dictionarySettings,
                       masterID: masterID)
    }
    /// The inputs a run would take now.
    package var currentInputs: IndexingInputs { inputs(for: method) }
    /// The result was made of other inputs than its method's current ones (design §6: a Processing, Phases or method settings change
    /// stales it; picking the other method does not, the result on screen is still its method's).
    package var isStale: Bool {
        guard let result else { return false }
        return resultInputs != inputs(for: result.method)
    }
    /// The master pattern a dictionary is projected from.
    package var currentMaster: IndexingMasterPattern? { masterPatterns.first { $0.id == masterID } }
    /// The map layers on offer: the result's method's, or the method picked before a run.
    package var availableLayers: [IndexingLayer] { result?.layers ?? IndexingLayer.layers(for: method) }

    // MARK: - The dataset

    /// A dataset was bound in Patterns: the room starts over on it, with the phases of its crystal map.
    package func bind(_ document: EBSDSession.Document) {
        reset()
        let fromFile = document.dataset.crystalMap.map { IndexingPhase.fromCrystalMap($0.phases) } ?? (phases: [], skipped: [])
        phases = fromFile.phases
        skippedPhases = fromFile.skipped
        refreshMap()
        loadKeys()
        openShippedMasterPattern()
    }

    /// The dataset was closed: the room goes back to its door.
    package func close() {
        reset()
    }

    /// Everything of the dataset goes; the master patterns opened and the orientations sampled stay (they are not the dataset's).
    private func reset() {
        generation += 1
        runGeneration += 1
        runTask?.cancel(); patternTask?.cancel(); samplingTask?.cancel(); bestMatchTask?.cancel()
        result = nil; resultInputs = nil; resultSource = nil; resultProjectionCenter = nil
        isIndexing = false; progress = 0; lastRunSeconds = nil; wasStopped = false; chunksDone = 0; chunksTotal = 0
        mapRGBA = nil; palette = nil; probe = nil; runPlan = nil; dictionaryPlan = nil; shownKey = nil; shownRaw = []
        hovered = nil; patternPosition = nil; detectedBands = []; patternFailure = nil; patternShape = (rows: 0, columns: 0)
        bestMatchPosition = nil; bestMatchFailure = nil; bestMatchKey = nil
        phases = []; skippedPhases = []; settings = .roomDefault; layer = .ipfZ
        method = .hough; dictionarySettings = .roomDefault; dictionarySize = nil
    }

    // MARK: - Phases and settings

    /// Adds `phase` under a name the list does not hold yet, in the next colour orix would hand out.
    package func addPhase(_ phase: IndexingPhase) {
        var added = phase
        added.name = IndexingPhase.uniqueName(phase.name, among: phases.map(\.name))
        let used = Set(phases.map(\.color))
        added.color = PhaseList.tableau.first { !used.contains($0) } ?? PhaseList.tableau[phases.count % PhaseList.tableau.count]
        phases.append(added)
        phasesChanged()
    }

    package func removePhase(named name: String) {
        guard let i = phases.firstIndex(where: { $0.name == name }) else { return }
        phases.remove(at: i)
        phasesChanged()
    }

    package func setPhase(named name: String, isOn: Bool) {
        guard let i = phases.firstIndex(where: { $0.name == name }), phases[i].isOn != isOn else { return }
        phases[i].isOn = isOn
        phasesChanged()
    }

    package func setReflectors(_ reflectors: IndexingPhase.Reflectors, named name: String) {
        guard let i = phases.firstIndex(where: { $0.name == name }), phases[i].reflectors != reflectors else { return }
        phases[i].reflectors = reflectors
        phasesChanged()
    }

    private func phasesChanged() {
        loadKeys()
        refreshBandRows()
        refreshDictionarySize()
    }

    /// Edits the Hough settings in place (one field); the pattern pane re-detects its bands with them.
    package func editSettings(_ change: (inout HoughIndexingSettings) -> Void) {
        var edited = settings
        change(&edited)
        guard edited != settings else { return }
        settings = edited
        showPattern()
    }

    package func resetSettings() {
        guard settings != .roomDefault else { return }
        settings = .roomDefault
        showPattern()
    }

    // MARK: - The method and the dictionary

    /// Picks how Index indexes; the result on screen stays (it is its method's), the map's layer follows the method before a run.
    package func setMethod(_ new: IndexingMethod) {
        guard new != method else { return }
        method = new
        if result == nil, !IndexingLayer.layers(for: new).contains(layer) { setLayer(.ipfZ) }
        refreshDictionarySize()
    }

    /// Edits the dictionary settings in place (one field).
    package func editDictionarySettings(_ change: (inout DictionaryIndexingSettings) -> Void) {
        var edited = dictionarySettings
        change(&edited)
        guard edited != dictionarySettings else { return }
        dictionarySettings = edited
        refreshDictionarySize()
    }

    package func resetDictionarySettings() {
        guard dictionarySettings != .roomDefault else { return }
        dictionarySettings = .roomDefault
        refreshDictionarySize()
    }

    /// Picks the master pattern a dictionary is projected from, by its id.
    package func selectMasterPattern(_ id: String) {
        guard id != masterID, masterPatterns.contains(where: { $0.id == id }) else { return }
        masterID = id
    }

    /// Opens the master pattern at `url` off the main actor and picks it (an open one is picked again). A file that is not an EMsoft
    /// EBSD or TKD master pattern is refused with the reason. The returned task ends when it is open (or refused).
    @discardableResult
    package func openMasterPattern(url: URL) -> Task<Void, Never> {
        openMasterPattern(url: url, quietly: false)
    }

    /// The shipped Ni 20 kV master pattern (kikuchipy's), opened once when the first dataset binds, so Dictionary runs on the demo
    /// scan without a file to find (D-SEM-91). Outside the app bundle there is none.
    private func openShippedMasterPattern() {
        guard masterPatterns.isEmpty, let url = DemoDocuments.Shipped.nickelMasterPattern.url else { return }
        openMasterPattern(url: url, quietly: true)
    }

    @discardableResult
    private func openMasterPattern(url: URL, quietly: Bool) -> Task<Void, Never> {
        let id = url.standardizedFileURL.path
        if masterPatterns.contains(where: { $0.id == id }) {
            masterID = id
            return Task {}
        }
        if let loading = masterTasks[id] { return loading }
        isLoadingMaster = true
        let task = Task { [weak self] in
            do {
                let opened = try await Self.loadMaster(url)
                guard let self else { return }
                self.masterTasks[id] = nil
                self.isLoadingMaster = !self.masterTasks.isEmpty
                if !self.masterPatterns.contains(where: { $0.id == opened.id }) { self.masterPatterns.append(opened) }
                if !quietly || self.masterID == nil { self.masterID = opened.id }
                if !quietly { self.onEvent?("Opened the master pattern \(opened.fileName): \(opened.summary)") }
            } catch {
                guard let self else { return }
                self.masterTasks[id] = nil
                self.isLoadingMaster = !self.masterTasks.isEmpty
                guard !quietly else { return }
                self.onEvent?("Master pattern: " + ((error as? LocalizedError)?.errorDescription ?? error.localizedDescription))
                self.onFailure?(error)
            }
        }
        masterTasks[id] = task
        return task
    }

    @concurrent
    nonisolated private static func loadMaster(_ url: URL) async throws -> IndexingMasterPattern {
        try IndexingMasterPattern.load(url)
    }

    /// Counts the dictionary's orientations for the current resolution and the one phase on, off the main actor, and keeps them for
    /// the run (only while Dictionary is picked: sampling 1° takes seconds).
    private func refreshDictionarySize() {
        guard method == .dictionary, phasesOn.count == 1, let phase = phasesOn.first, let name = phase.pointGroupName,
              dictionarySettings.refusal == nil else {
            samplingTask?.cancel()
            dictionarySize = nil
            return
        }
        let key = SamplingKey(resolution: dictionarySettings.resolution, pointGroup: name)
        if let sampled, sampled.key == key {
            dictionarySize = sampled.rotations.count
            return
        }
        dictionarySize = nil
        samplingTask?.cancel()
        samplingTask = Task { [weak self] in
            guard let group = PointGroup.named(name),
                  let rotations = try? await DictionaryIndexingPlan.sample(resolution: key.resolution, pointGroup: group),
                  !Task.isCancelled, let self else { return }
            self.sampled = (key: key, rotations: rotations)
            if self.samplingKey == key { self.dictionarySize = rotations.count }
        }
    }

    /// The sampling the current settings ask for; nil without one phase on.
    private var samplingKey: SamplingKey? {
        guard phasesOn.count == 1, let name = phasesOn.first?.pointGroupName else { return nil }
        return SamplingKey(resolution: dictionarySettings.resolution, pointGroup: name)
    }

    /// The Dictionary section's Chunk row: patterns per chunk, chunks per block and blocks, as the run would cut them now; nil before
    /// the dictionary is counted.
    package var dictionaryChunking: (size: Int, chunks: Int, blocks: Int)? {
        guard let size = dictionarySize, case .success(let source) = self.source() else { return nil }
        let pixels = source.patternRows * source.patternColumns
        let mask = (try? dictionarySettings.signalMask(rows: source.patternRows, columns: source.patternColumns)) ?? nil
        let kept = mask.map { $0.filter { !$0 }.count } ?? pixels
        let perBlock = DictionaryIndexingPlan.rowsPerBlock(scanRows: source.scanRows, scanColumns: source.scanColumns, pixels: pixels)
        let options = DictionaryIndexing.Options(metric: dictionarySettings.metric, keepN: dictionarySettings.keep, signalMask: mask)
        let cut = DictionaryIndexingPlan.chunking(points: perBlock * source.scanColumns, keptPixels: kept, dictionary: size, options: options)
        return (cut.size, cut.chunks, (source.scanRows + perBlock - 1) / max(perBlock, 1))
    }

    /// Why a dictionary cannot run now (the Dictionary section's warning); nil when it can.
    package var dictionaryRefusal: String? {
        guard let document = patterns.document else { return "No EBSD dataset is open." }
        if currentMaster == nil, isLoadingMaster { return "The master pattern is being read." }
        return DictionaryIndexingPlan.refusal(phases: phases, master: currentMaster, settings: dictionarySettings,
                                              detector: document.dataset.detector, beamEnergy: document.dataset.sem.beamEnergyKeV)
    }

    package func setLayer(_ new: IndexingLayer) {
        guard new != layer, availableLayers.contains(new) else { return }
        layer = new
        palette = result.map { IndexingPalette(layer: new, phases: $0.phases) }
        refreshMap()
    }

    // MARK: - Whether Index can run

    /// The patterns a run would read now (D-SEM-83): the processed scan when it is current, else the stored patterns through the
    /// pipeline's per-pattern stages; refused while NLPAR is on and the scan is not processed (NLPAR needs the neighbours), and with the
    /// pipeline's own refusal.
    package func source() -> Result<IndexingSource, IndexingRefusal> {
        guard let document = patterns.document else { return .failure(IndexingRefusal("No EBSD dataset is open.")) }
        let pipeline = patterns.pipeline
        if let processed = patterns.processed, patterns.processedWith == pipeline {
            return .success(IndexingSource(processed: processed))
        }
        let active = PatternPipeline.Stage.allCases.contains { pipeline.isActive($0) }
        if active {
            if pipeline.nlpar.isOn {
                return .failure(IndexingRefusal("NLPAR averages each pattern with its neighbours: Process the scan in Patterns, then Index."))
            }
            if let refusal = patterns.processingRefusal { return .failure(IndexingRefusal("Patterns: " + refusal.sentence)) }
        }
        return .success(IndexingSource(stored: document.access, pipeline: pipeline, background: patterns.staticBackground))
    }

    /// Why Index cannot run now with the method picked; nil when it can.
    package var refusal: String? {
        guard let document = patterns.document else { return "No EBSD dataset is open." }
        switch method {
        case .hough:
            if let why = IndexingPlan.refusal(phases: phases, settings: settings, detector: document.dataset.detector) { return why }
        case .dictionary:
            if let why = dictionaryRefusal { return why }
        }
        if case .failure(let refusal) = self.source() { return refusal.sentence }
        return nil
    }

    package var canIndex: Bool { patterns.document != nil && !isIndexing && !patterns.isOpening && !patterns.isProcessing && refusal == nil }

    /// The verb's help: "Index 4,125 patterns with Hough (ni)", "Index 4,125 patterns with Dictionary (ni)", or why it cannot run.
    package var verbHelp: String {
        if let refusal { return refusal }
        guard let dataset = patterns.dataset else { return "" }
        let what = "Index \(dataset.patternCount.formatted()) patterns with \(method.title) (\(phasesOn.map(\.name).joined(separator: ", ")))"
        if let result, result.method == method, isStale { return what + "; the inputs changed since the last run" }
        return what
    }

    // MARK: - The run

    /// The room's verb: the scan indexed off the main actor with the method picked, row by row (Hough) or block of rows by block
    /// (dictionary); each lands on the map as it is done. Stop (⌘.) ends it and keeps the rows indexed. The returned task ends when the
    /// run has landed (or was refused, stopped or failed).
    @discardableResult
    package func index() -> Task<Void, Never> {
        guard let document = patterns.document, !isIndexing else { return Task {} }
        if let why = refusal {
            onEvent?("Index: \(why)")
            return Task {}
        }
        guard case .success(let source) = self.source() else { return Task {} }
        switch method {
        case .hough: return indexWithHough(document, source: source)
        case .dictionary: return indexWithDictionary(document, source: source)
        }
    }

    private func indexWithHough(_ document: EBSDSession.Document, source: IndexingSource) -> Task<Void, Never> {
        let inputs = currentInputs
        let key = ProbeKey(pipeline: inputs.pipeline, settings: inputs.settings, kind: source.kind, generation: generation)
        let cached = probe?.key == key ? probe?.probe : nil
        let phases = self.phases, settings = self.settings, detector = document.dataset.detector
        let rows = document.dataset.scanRows, columns = document.dataset.scanColumns
        runTask?.cancel()
        runGeneration += 1
        let run = runGeneration
        result = IndexingResult(scanRows: rows, scanColumns: columns, phases: inputs.phases)
        resultInputs = inputs
        resultSource = source.kind
        resultProjectionCenter = IndexingPlan.meanProjectionCenter(detector)
        if !IndexingLayer.layers(for: .hough).contains(layer) { layer = .ipfZ }
        palette = IndexingPalette(layer: layer, phases: inputs.phases)
        runPlan = nil; dictionaryPlan = nil
        isIndexing = true; progress = 0; wasStopped = false; lastRunSeconds = nil; chunksDone = 0; chunksTotal = 0
        clearBestMatch()
        refreshMap()
        onEvent?("Indexing \(rows * columns) patterns with Hough (\(inputs.phases.map(\.name).joined(separator: ", ")))…")
        let started = Date()
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let built = try cached ?? IndexingProbe(source: source, settings: settings)
                let plan = try IndexingPlan(probe: built, phases: phases, settings: settings, detector: detector)
                await self?.landPlan(plan, probe: built, key: key, run: run)
                for row in 0..<rows {
                    try Task.checkCancellation()
                    let solutions = try await plan.indexRow(row)
                    await self?.landRow(solutions, row: row, run: run)
                }
                await self?.finish(seconds: Date().timeIntervalSince(started), failure: nil, run: run)
            } catch is CancellationError {
                return
            } catch {
                let words = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                await self?.finish(seconds: 0, failure: words, run: run)
            }
        }
        runTask = task
        return Task { await task.value }
    }

    /// A dictionary run (D-SEM-92): the orientations sampled (or the ones kept for this resolution and point group), the plan built, then
    /// each block of rows read and matched against the whole dictionary, chunk by chunk, its rows landing when it is done.
    private func indexWithDictionary(_ document: EBSDSession.Document, source: IndexingSource) -> Task<Void, Never> {
        let inputs = currentInputs
        guard let master = currentMaster, let phase = inputs.phases.first, let key = samplingKey else { return Task {} }
        let cached = sampled?.key == key ? sampled?.rotations : nil
        let phases = self.phases, settings = dictionarySettings, detector = document.dataset.detector
        let beam = document.dataset.sem.beamEnergyKeV
        let rows = document.dataset.scanRows, columns = document.dataset.scanColumns
        runTask?.cancel()
        runGeneration += 1
        let run = runGeneration
        result = IndexingResult(scanRows: rows, scanColumns: columns, phases: inputs.phases, metric: settings.metric)
        resultInputs = inputs
        resultSource = source.kind
        resultProjectionCenter = IndexingPlan.meanProjectionCenter(detector)
        if !IndexingLayer.layers(for: .dictionary).contains(layer) { layer = .ipfZ }
        palette = IndexingPalette(layer: layer, phases: inputs.phases)
        runPlan = nil; dictionaryPlan = nil
        isIndexing = true; progress = 0; wasStopped = false; lastRunSeconds = nil; chunksDone = 0; chunksTotal = 0
        clearBestMatch()
        refreshMap()
        refreshBandRows()
        let resolution = settings.resolution.formatted(.number.precision(.significantDigits(1...3)))
        onEvent?("Indexing \(rows * columns) patterns against the \(phase.name) dictionary at \(resolution)° (\(settings.metric.title))…")
        // The chunks merged, in order, to the main actor (the newest only: the count only grows).
        let (chunks, chunkSink) = AsyncStream.makeStream(of: Int.self, bufferingPolicy: .bufferingNewest(1))
        Task { [weak self] in
            for await done in chunks { self?.chunkMerged(done, run: run) }
        }
        let started = Date()
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            defer { chunkSink.finish() }
            do {
                let rotations: [SIMD4<Double>]
                if let cached {
                    rotations = cached
                } else {
                    guard let group = phase.pointGroup else { throw IndexingRefusal("\(phase.name): no point group is known for space group \(phase.spaceGroup).") }
                    rotations = try await DictionaryIndexingPlan.sample(resolution: settings.resolution, pointGroup: group)
                }
                try Task.checkCancellation()
                let plan = try DictionaryIndexingPlan(source: source, phases: phases, master: master, settings: settings,
                                                      fileDetector: detector, beamEnergy: beam, rotations: rotations)
                let perBlock = plan.chunksPerBlock
                await self?.landDictionaryPlan(plan, key: key, chunks: perBlock.reduce(0, +), run: run)
                var before = 0
                for (k, block) in plan.blocks.enumerated() {
                    try Task.checkCancellation()
                    let offset = before
                    let matched = try await plan.indexBlock(block) { done, _ in _ = chunkSink.yield(offset + done) }
                    before += perBlock[k]
                    await self?.landBlock(matched, rows: block, run: run)
                }
                await self?.finish(seconds: Date().timeIntervalSince(started), failure: nil, run: run)
            } catch is CancellationError {
                return
            } catch {
                let words = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                await self?.finish(seconds: 0, failure: words, run: run)
            }
        }
        runTask = task
        return Task { await task.value }
    }

    /// Ends the run in flight; the rows indexed stay on the map and in the results (a dictionary block stopped between its chunks
    /// keeps nothing of it: its points have not met the whole dictionary).
    package func stop() {
        guard isIndexing else { return }
        runTask?.cancel()
        isIndexing = false
        wasStopped = true
        if let result {
            if result.method == .dictionary {
                onEvent?("Stopped dictionary indexing after \(chunksDone) of \(chunksTotal) chunks; \(result.rowsDone) of \(result.scanRows) rows were indexed and stay")
            } else {
                onEvent?("Stopped indexing after \(result.rowsDone) of \(result.scanRows) rows; the indexed rows stay")
            }
        }
        refreshBandRows()
    }

    private func landPlan(_ plan: IndexingPlan, probe built: IndexingProbe, key: ProbeKey, run: Int) {
        guard run == runGeneration else { return }
        runPlan = plan
        probe = (key: key, probe: built)
    }

    private func landRow(_ solutions: [HoughIndexer.Solution], row: Int, run: Int) {
        guard run == runGeneration, isIndexing else { return }
        result?.land(solutions, at: row)
        progress = Double(row + 1) / Double(max(result?.scanRows ?? 1, 1))
        repaint(rows: row..<(row + 1))
        if patternPosition?.row == row { refreshBandRows() }
    }

    private func landDictionaryPlan(_ plan: DictionaryIndexingPlan, key: SamplingKey, chunks: Int, run: Int) {
        guard run == runGeneration else { return }
        dictionaryPlan = plan
        sampled = (key: key, rotations: plan.rotations)
        if samplingKey == key { dictionarySize = plan.rotations.count }
        chunksTotal = chunks
    }

    private func chunkMerged(_ done: Int, run: Int) {
        guard run == runGeneration, isIndexing, chunksTotal > 0 else { return }
        chunksDone = min(max(chunksDone, done), chunksTotal)
        progress = Double(chunksDone) / Double(chunksTotal)
    }

    private func landBlock(_ matched: DictionaryIndexing.Result, rows: Range<Int>, run: Int) {
        guard run == runGeneration, isIndexing else { return }
        result?.land(matched, rows: rows)
        repaint(rows: rows)
        if let row = patternPosition?.row, rows.contains(row) { showBestMatch() }
    }

    private func finish(seconds: Double, failure: String?, run: Int) {
        guard run == runGeneration, isIndexing else { return }
        isIndexing = false
        if let failure {
            onEvent?("Error: \(failure)")
            return
        }
        progress = 1
        if chunksTotal > 0 { chunksDone = chunksTotal }
        lastRunSeconds = seconds
        if let result {
            onEvent?("Indexed \(result.indexedCount) of \(result.pointCount) patterns with \(result.method.title) in \(String(format: "%.1f", seconds)) s")
        }
        refreshBandRows()
        showBestMatch()
    }

    // MARK: - The map

    /// Repaints the whole map: the result on its layer over the dimmed navigator, or the navigator alone before a run.
    package func refreshMap() {
        guard let dataset = patterns.dataset else {
            mapRGBA = nil
            return
        }
        if let result {
            let palette = self.palette.flatMap { $0.layer == layer ? $0 : nil } ?? IndexingPalette(layer: layer, phases: result.phases)
            self.palette = palette
            mapRGBA = IndexingRaster.rgba(result, palette: palette, backdrop: patterns.meanIntensities)
        } else {
            mapRGBA = IndexingRaster.backdrop(scanRows: dataset.scanRows, scanColumns: dataset.scanColumns, means: patterns.meanIntensities)
        }
        mapVersion &+= 1
    }

    /// Landed rows: a pointwise layer repaints those rows, a scalar layer (its grey range moves) the whole map.
    private func repaint(rows: Range<Int>) {
        guard let result, let palette, palette.layer == layer, layer.isPointwise, var rgba = mapRGBA, rgba.count == result.pointCount * 4 else {
            refreshMap()
            return
        }
        mapRGBA = nil
        IndexingRaster.paint(&rgba, result: result, palette: palette, backdrop: patterns.meanIntensities, rows: rows)
        mapRGBA = rgba
        mapVersion &+= 1
    }

    /// The status line over the map at `position`; nil outside the scan.
    package func readout(at position: EBSDPosition) -> String? {
        guard let dataset = patterns.dataset, position.isInside(rows: dataset.scanRows, columns: dataset.scanColumns) else { return nil }
        if let line = result?.readout(at: position) { return line }
        return "row \(position.row) · col \(position.column) · not indexed yet"
    }

    // MARK: - The position

    /// The pointer is over map position `position` (nil: it left the map); the pattern pane follows it.
    package func hover(_ position: EBSDPosition?) {
        guard let dataset = patterns.dataset else { return }
        let inside = position.flatMap { $0.isInside(rows: dataset.scanRows, columns: dataset.scanColumns) ? $0 : nil }
        guard inside != hovered else { return }
        hovered = inside
        showPattern()
    }

    /// Pins `position` (a click on the map, a Results row, Space, an arrow key): the shared marker moves.
    package func pin(_ position: EBSDPosition) {
        patterns.pin(position)
        showPattern()
    }

    package func pinHovered() {
        if let hovered { pin(hovered) }
    }

    package func step(_ direction: EBSDPosition.Direction, by count: Int = 1) {
        patterns.step(direction, by: count)
        showPattern()
    }

    // MARK: - The pattern

    /// Shows the pattern at `shown` as it is indexed, with its detected bands: read, processed and detected off the main actor in a task
    /// the next request cancels. The returned task ends when the pattern is on screen.
    @discardableResult
    package func showPattern() -> Task<Void, Never> {
        guard patterns.document != nil else { return Task {} }
        let position = shown
        let source: IndexingSource
        switch self.source() {
        case .success(let s):
            source = s
        case .failure(let refusal):
            patternTask?.cancel()   // a request still loading would land over the refusal
            shownKey = nil
            patternFailure = refusal.sentence
            return Task {}
        }
        let key = ProbeKey(pipeline: patterns.pipeline, settings: settings, kind: source.kind, generation: generation)
        let request = ShownKey(position: position, probe: key)
        guard request != shownKey else { return Task {} }
        shownKey = request
        patternTask?.cancel()
        let cached = probe?.key == key ? probe?.probe : nil
        let settings = self.settings
        let gen = generation
        let task = Task { [weak self] in
            do {
                let inspected = try await Self.inspect(cached: cached, source: source, settings: settings, position: position)
                guard let self, !Task.isCancelled, gen == self.generation else { return }
                self.probe = (key: key, probe: inspected.probe)
                self.patternPresentation.show(inspected.canvas)
                self.patternPosition = position
                self.patternShape = (rows: inspected.probe.source.patternRows, columns: inspected.probe.source.patternColumns)
                self.shownRaw = inspected.bands
                self.patternFailure = nil
                self.refreshBandRows()
                self.showBestMatch()
            } catch {
                guard let self, !Task.isCancelled, gen == self.generation, !(error is CancellationError) else { return }
                self.shownKey = nil
                self.patternFailure = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
        patternTask = task
        return task
    }

    @concurrent
    nonisolated private static func inspect(cached: IndexingProbe?, source: IndexingSource, settings: HoughIndexingSettings,
                                            position: EBSDPosition) async throws -> Inspected {
        let probe = try cached ?? IndexingProbe(source: source, settings: settings)
        try Task.checkCancellation()
        let shown = try probe.inspect(row: position.row, column: position.column)
        let canvas = CanvasPixels.make(width: probe.source.patternColumns, height: probe.source.patternRows, pixels: shown.pattern.map { Float($0) })
        return Inspected(probe: probe, canvas: canvas, bands: shown.bands)
    }

    /// The Bands table of the pattern on screen: the detected bands, with a Hough run's families and fits while the result is current
    /// (a dictionary run matches no band).
    private func refreshBandRows() {
        guard let position = patternPosition, patternShape.rows > 0 else {
            detectedBands = []
            return
        }
        let solution = isStale || result?.method != .hough ? nil : result?.solution(at: position)
        detectedBands = IndexedBand.bands(shownRaw, solution: solution, libraries: runPlan?.indexer.phases ?? [],
                                          rows: patternShape.rows, columns: patternShape.columns)
    }

    // MARK: - The colour keys

    /// Makes the IPF colour key of every point group in the phases that has none yet, off the main actor.
    private func loadKeys() {
        let wanted = Set(phases.compactMap(\.pointGroupName)).subtracting(keyImages.keys)
        guard !wanted.isEmpty else { return }
        let names = Array(wanted).sorted()
        Task { [weak self] in
            let made = await Self.makeKeys(names)
            self?.keyImages.merge(made) { kept, _ in kept }
        }
    }

    @concurrent
    nonisolated private static func makeKeys(_ names: [String]) async -> [String: IPFKeyImage] {
        var out: [String: IPFKeyImage] = [:]
        for name in names {
            if let group = PointGroup.named(name) { out[name] = IndexingColorKey.image(group) }
        }
        return out
    }

    // MARK: - The best match

    /// The Best match pane: a dictionary run's best orientation at the pattern pane's point, simulated on the run's detector from its
    /// master pattern (`MasterPatternProjection`, kikuchipy's `get_patterns`), off the main actor; nothing where the point has none.
    private func showBestMatch() {
        guard let result, result.method == .dictionary, let plan = dictionaryPlan, let position = patternPosition,
              let solution = result.solution(at: position), solution.phase >= 0, let simulation = result.simulationIndex(at: position) else {
            clearBestMatch()
            return
        }
        let key = BestMatchKey(position: position, run: runGeneration, simulation: simulation)
        guard key != bestMatchKey else { return }
        bestMatchKey = key
        bestMatchTask?.cancel()
        let rotation = solution.quaternion
        bestMatchTask = Task { [weak self] in
            do {
                let pixels = try await plan.simulated(rotation)
                guard let self, !Task.isCancelled, self.bestMatchKey == key else { return }
                self.bestMatchPresentation.show(CanvasPixels.make(width: plan.detector.columns, height: plan.detector.rows, pixels: pixels))
                self.bestMatchPosition = position
                self.bestMatchFailure = nil
            } catch {
                guard let self, !Task.isCancelled, self.bestMatchKey == key else { return }
                self.bestMatchPosition = nil
                self.bestMatchFailure = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    private func clearBestMatch() {
        bestMatchTask?.cancel()
        bestMatchKey = nil
        bestMatchPosition = nil
        bestMatchFailure = nil
    }

    // MARK: - Export

    /// The last run as orix's crystal map (`IndexingResult.crystalMap`, the rows it reached on the scan's steps): what the .ang and
    /// .ctf exports write. nil before a row has landed.
    package func crystalMap() throws -> CrystalMap? {
        guard let result, let dataset = patterns.document?.dataset else { return nil }
        let steps = (dy: dataset.stepY, dx: dataset.stepX)
        switch result.method {
        case .hough:
            guard let runPlan else { return nil }
            return try result.crystalMap(indexer: runPlan.indexer, steps: steps, scanUnit: dataset.scanUnit)
        case .dictionary:
            return try result.crystalMap(steps: steps, scanUnit: dataset.scanUnit)
        }
    }

    /// The method record of the last run (every input, in pyEBSDindex's, kikuchipy's and orix's names); nil before a run has its plan.
    package func methodJSON() throws -> Data? {
        guard let result, let document = patterns.document else { return nil }
        switch result.method {
        case .hough:
            guard let runPlan else { return nil }
            return try runPlan.methodJSON(fileName: document.fileName, points: result.pointCount, indexed: result.indexedCount)
        case .dictionary:
            guard let dictionaryPlan else { return nil }
            return try dictionaryPlan.methodJSON(fileName: document.fileName, points: result.pointCount, indexed: result.indexedCount)
        }
    }
}
