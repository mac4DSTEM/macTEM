//
//  IndexingSession.swift
//  Role: the one owner of the Indexing room's state (docs/sem/design/indexing-room.md): the phases indexed against, the Hough settings,
//        the run (its result, filled row by row, and what it was made of, so a later change to Processing, the phases or the settings
//        stales it), the map on screen as RGBA and the pattern pane's pattern with its detected bands. The dataset, its processing and
//        the pinned position are the Patterns room's (`EBSDSession`): the two rooms share one scan and one marker.
//
//  Nothing here makes a number: the indexing is `HoughIndexer`'s (TEMCore, pyEBSDindex's port), the colours `IndexingRaster`'s (orix's
//  keys), the patterns `IndexingSource`'s. This owner decides WHEN: a run in one detached task that indexes the scan row by row and
//  lands each row only if no newer run or dataset started meanwhile (`generation`), so the map grows in place and Stop keeps the
//  indexed rows; the pattern under the pointer in a task the next hover cancels; the band detector (the Radon line plan) built once
//  per settings off the main actor and kept (`probe`).
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

    package init(patterns: EBSDSession) {
        self.patterns = patterns
    }

    package var hasDataset: Bool { patterns.hasDataset }
    package var isBusy: Bool { isIndexing }
    /// What the pattern pane shows: the hovered position while there is one, else the pinned.
    package var shown: EBSDPosition { hovered ?? patterns.pinned }
    package var phasesOn: [IndexingPhase] { phases.filter(\.isOn) }
    /// The inputs a run would take now.
    package var currentInputs: IndexingInputs { IndexingInputs(pipeline: patterns.pipeline, phases: phases, settings: settings) }
    /// The result was made of other inputs than the current ones (design §6: a Processing, Phases or Hough change stales it).
    package var isStale: Bool { result != nil && resultInputs != currentInputs }

    // MARK: - The dataset

    /// A dataset was bound in Patterns: the room starts over on it, with the phases of its crystal map.
    package func bind(_ document: EBSDSession.Document) {
        reset()
        let fromFile = document.dataset.crystalMap.map { IndexingPhase.fromCrystalMap($0.phases) } ?? (phases: [], skipped: [])
        phases = fromFile.phases
        skippedPhases = fromFile.skipped
        refreshMap()
        loadKeys()
    }

    /// The dataset was closed: the room goes back to its door.
    package func close() {
        reset()
    }

    private func reset() {
        generation += 1
        runGeneration += 1
        runTask?.cancel(); patternTask?.cancel()
        result = nil; resultInputs = nil; resultSource = nil; resultProjectionCenter = nil
        isIndexing = false; progress = 0; lastRunSeconds = nil; wasStopped = false
        mapRGBA = nil; palette = nil; probe = nil; runPlan = nil; shownKey = nil; shownRaw = []
        hovered = nil; patternPosition = nil; detectedBands = []; patternFailure = nil; patternShape = (rows: 0, columns: 0)
        phases = []; skippedPhases = []; settings = .roomDefault; layer = .ipfZ
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

    package func setLayer(_ new: IndexingLayer) {
        guard new != layer else { return }
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

    /// Why Index cannot run now; nil when it can.
    package var refusal: String? {
        guard let document = patterns.document else { return "No EBSD dataset is open." }
        if let why = IndexingPlan.refusal(phases: phases, settings: settings, detector: document.dataset.detector) { return why }
        if case .failure(let refusal) = self.source() { return refusal.sentence }
        return nil
    }

    package var canIndex: Bool { patterns.document != nil && !isIndexing && !patterns.isOpening && !patterns.isProcessing && refusal == nil }

    /// The verb's help: "Index 4,125 patterns with Hough (ni)", or why it cannot run.
    package var verbHelp: String {
        if let refusal { return refusal }
        guard let dataset = patterns.dataset else { return "" }
        let what = "Index \(dataset.patternCount.formatted()) patterns with Hough (\(phasesOn.map(\.name).joined(separator: ", ")))"
        return isStale ? what + "; the inputs changed since the last run" : what
    }

    // MARK: - The run

    /// The room's verb: the scan indexed row by row off the main actor; each row lands on the map as it is done. Stop (⌘.) ends it and
    /// keeps the rows indexed. The returned task ends when the run has landed (or was refused, stopped or failed).
    @discardableResult
    package func index() -> Task<Void, Never> {
        guard let document = patterns.document, !isIndexing else { return Task {} }
        if let why = refusal {
            onEvent?("Index: \(why)")
            return Task {}
        }
        guard case .success(let source) = self.source() else { return Task {} }
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
        palette = IndexingPalette(layer: layer, phases: inputs.phases)
        runPlan = nil
        isIndexing = true; progress = 0; wasStopped = false; lastRunSeconds = nil
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

    /// Ends the run in flight; the rows indexed stay on the map and in the results.
    package func stop() {
        guard isIndexing else { return }
        runTask?.cancel()
        isIndexing = false
        wasStopped = true
        if let result { onEvent?("Stopped indexing after \(result.rowsDone) of \(result.scanRows) rows; the indexed rows stay") }
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
        repaint(row: row)
        if patternPosition?.row == row { refreshBandRows() }
    }

    private func finish(seconds: Double, failure: String?, run: Int) {
        guard run == runGeneration, isIndexing else { return }
        isIndexing = false
        if let failure {
            onEvent?("Error: \(failure)")
            return
        }
        progress = 1
        lastRunSeconds = seconds
        if let result {
            onEvent?("Indexed \(result.indexedCount) of \(result.pointCount) patterns with Hough in \(String(format: "%.1f", seconds)) s")
        }
        refreshBandRows()
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

    /// One landed row: a pointwise layer repaints that row, a scalar layer (its grey range moves) the whole map.
    private func repaint(row: Int) {
        guard let result, let palette, palette.layer == layer, layer.isPointwise, var rgba = mapRGBA, rgba.count == result.pointCount * 4 else {
            refreshMap()
            return
        }
        mapRGBA = nil
        IndexingRaster.paint(&rgba, result: result, palette: palette, backdrop: patterns.meanIntensities, rows: row..<(row + 1))
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

    /// The Bands table of the pattern on screen: the detected bands, with the run's families and fits while the result is current.
    private func refreshBandRows() {
        guard let position = patternPosition, patternShape.rows > 0 else {
            detectedBands = []
            return
        }
        let solution = isStale ? nil : result?.solution(at: position)
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

    // MARK: - Export

    /// The last run as orix's crystal map (`IndexingResult.crystalMap`, the rows it reached on the scan's steps): what the .ang and
    /// .ctf exports write. nil before a row has landed.
    package func crystalMap() throws -> CrystalMap? {
        guard let runPlan, let result, let dataset = patterns.document?.dataset else { return nil }
        return try result.crystalMap(indexer: runPlan.indexer, steps: (dy: dataset.stepY, dx: dataset.stepX), scanUnit: dataset.scanUnit)
    }

    /// The method record of the last run (every input, in pyEBSDindex's and kikuchipy's names); nil before a run has its plan.
    package func methodJSON() throws -> Data? {
        guard let runPlan, let result, let document = patterns.document else { return nil }
        return try runPlan.methodJSON(fileName: document.fileName, points: result.pointCount, indexed: result.indexedCount)
    }
}
