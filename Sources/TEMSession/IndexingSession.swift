//
//  IndexingSession.swift
//  Role: the one owner of the Indexing room's state (docs/sem/design/indexing-room.md): the phases indexed against, the method (Hough
//        or Dictionary, D-SEM-91) and its settings, the master patterns opened and the one each phase on takes (D-SEM-98), the last
//        run of each method
//        (`IndexingRun`, D-SEM-97: its result, filled row by row or block by block, and what it was made of, so a later change to
//        Processing, the phases or the method's settings stales it) and which one is on screen (the run in flight, else the picked
//        method's), the map on screen as RGBA, the pattern pane's pattern with its detected bands, a dictionary run's best match at
//        that point, Compare's two results (IndexingSession+Compare.swift) and the Dictionary run's refinement
//        (IndexingSession+Refine.swift, D-SEM-109). The dataset, its processing and the pinned position are
//        the Patterns room's (`EBSDSession`): the two rooms share one scan and one marker.
//
//  Nothing here makes a number: the indexing is `HoughIndexer`'s (pyEBSDindex's port) or `DictionaryIndexing`'s (kikuchipy's), the
//  colours `IndexingRaster`'s (orix's keys), the patterns `IndexingSource`'s. This owner decides WHEN: a run in one detached task that
//  indexes the scan row by row (Hough) or block of rows by block (dictionary, its chunks counted for the toolbar) and lands each only if
//  no newer run or dataset started meanwhile (`generation`), so the map grows in place and Stop keeps the indexed rows; the pattern
//  at the picked position in a task the next pick cancels; the band detector (the Radon line plan) built once per settings off the main
//  actor and kept (`probe`); the dictionary's orientations sampled once per resolution and point group and kept (`sampled`), one
//  sampling for every phase of a point group.
//

import Foundation
import Observation
import ShellMetal
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
    /// The master pattern picked for a phase in the Dictionary section, phase name (`IndexingPhase.id`) to `IndexingMasterPattern.id`
    /// (D-SEM-98); a phase without a pick takes `IndexingMasterPattern.preferred(for:among:)`. The dataset's, as its phases are.
    package private(set) var masterPicks: [String: String] = [:]
    package private(set) var isLoadingMaster = false
    /// The dictionary's orientations counted at the current resolution, by point group (orix's name); a group is missing while it is
    /// counted, and all are while Dictionary is not picked.
    package private(set) var dictionarySizes: [String: Int] = [:]
    /// What the map shows.
    package private(set) var layer = IndexingLayer.ipfZ
    /// Whether the pattern pane draws the detected bands.
    package var showsDetectedBands = true
    /// Whether the pattern pane draws the Kikuchi simulation of the point's solution (`simulationOverlay`, #201).
    package var showsSimulation = false

    // MARK: The runs

    /// The last run of each method (D-SEM-97): a run replaces only its own method's, so a Dictionary run leaves the Hough one as it was.
    package private(set) var runs: [IndexingMethod: IndexingRun] = [:]
    package internal(set) var isIndexing = false
    /// The method of the run in flight; nil when none runs.
    package internal(set) var runningMethod: IndexingMethod?
    /// The run's fraction of rows done (0...1).
    package internal(set) var progress = 0.0
    /// A dictionary run's chunks done and in all (every block runs every phase's whole dictionary in chunks).
    package internal(set) var chunksDone = 0
    package internal(set) var chunksTotal = 0
    /// The phase whose dictionary a run against several phases is matching now (the toolbar, the map's count and Info name it); nil
    /// otherwise.
    package internal(set) var chunkPhase: String?
    /// The dataset's own crystal map when it lies on the scan's grid (the Maps room's guard): Compare's `File`.
    package private(set) var fileIndexing: CrystalMap?

    // MARK: Compare (IndexingSession+Compare.swift)

    /// Whether the bottom pane shows Compare in place of the Results and Bands tables (`Display › Compare`).
    package internal(set) var showsCompare = false
    package internal(set) var compareA = IndexingCompareSource.hough
    package internal(set) var compareB = IndexingCompareSource.file
    /// The comparison of A and B and their pictures on the compare layer, once made; nil while it is made or cannot be.
    package internal(set) var comparison: IndexingComparison?
    package internal(set) var comparePictures: IndexingComparePictures?
    package internal(set) var compareVersion = 0
    @ObservationIgnored var compareTask: Task<Void, Never>?
    @ObservationIgnored var compareKey: IndexingCompareKey?

    // MARK: Refine (IndexingSession+Refine.swift)

    /// `Refine › After indexing` (design §3, D-SEM-109): Index refines the Dictionary run after it; the room shows the refinement.
    package internal(set) var refinesAfterIndexing = false
    /// What Refine moves and its trust region. Not a run's input: an edit stales the refinement, never the Dictionary run.
    package internal(set) var refineSettings = IndexingRefineSettings.roomDefault
    /// The last refinement of the Dictionary run, a copy of it with the refined rows, kept beside it.
    package internal(set) var refinedRun: IndexingRun?
    /// The run in flight is the Refine stage (`isIndexing`, `runningMethod` .dictionary).
    package internal(set) var isRefining = false

    /// The run on screen: the run in flight, else the picked method's last run, else the latest run held; nil before a run. The
    /// Dictionary run's refinement stands in its place while Refine is on and it reached a point (D-SEM-109).
    package var shownRun: IndexingRun? {
        if isIndexing, let runningMethod { return isRefining ? refinedRun : runs[runningMethod] }
        let run = runs[method] ?? runs.values.max { $0.id < $1.id }
        if let run, run.id == runs[.dictionary]?.id, let refined = shownRefinedRun { return refined }
        return run
    }
    /// The other method's run, when it reached a point (Info's `Also held`).
    package var otherRun: IndexingRun? {
        guard let shown = shownRun else { return nil }
        return runs.values.first { $0.method != shown.method && $0.result.reachedCount > 0 }
    }
    /// The run on screen's result, filled row by row while it runs; nil before the first run.
    package var result: IndexingResult? { shownRun?.result }
    /// What the run on screen was made of (it is stale when the current inputs of its method differ) and where it read its patterns.
    package var resultInputs: IndexingInputs? { shownRun?.inputs }
    package var resultSource: IndexingSource.Kind? { shownRun?.source }
    package var resultProjectionCenter: SIMD3<Double>? { shownRun?.projectionCenter }
    /// The run on screen's time once complete; nil while it runs or after a stop.
    package var lastRunSeconds: Double? { shownRun?.seconds }
    /// The run on screen was stopped: its indexed rows stay, the rest of the map shows the navigator.
    package var wasStopped: Bool { shownRun?.wasStopped ?? false }
    /// The run on screen's dictionary plans, one per phase in its result's order: each master pattern, orientations, detector and
    /// energy (Info, the method record, Best match). Empty without one.
    package var dictionaryPlans: [DictionaryIndexingPlan] { shownRun?.dictionaryPlans ?? [] }
    /// The run on screen's Hough libraries, for the Bands table's families, the .ang and the method record.
    private var runPlan: IndexingPlan? { shownRun?.houghPlan }

    // MARK: The pictures

    /// The map as RGBA, one pixel per scan point, and its version for the Metal view: a pointwise layer (IPF, Euler, Phase) or the
    /// navigator before a run; nil while the map shows a scalar layer.
    package private(set) var mapRGBA: [UInt8]?
    package private(set) var mapVersion = 0
    /// A scalar layer's values (CI, Fit, Bands, PQ, Score, OSM) as the image rooms draw a picture (D-SEM-96): its colormap, window,
    /// gamma and scale bar are the inspector's Map Display; a point without a value is masked. Viridis first (matplotlib's default,
    /// which orix's `CrystalMap.plot` draws a property with): its masked grey is no value's colour, where on Gray it reads as a value
    /// a third of the way up.
    package let mapPresentation: ImagePresentation = {
        let presentation = ImagePresentation()
        presentation.colormap = .viridis
        presentation.defaultQuantiles = 0.01...0.99
        return presentation
    }()
    /// The pattern as it is indexed (through the pipeline), drawn with its own contrast.
    package let patternPresentation = ImagePresentation()
    /// The position of the pattern on screen (the picked position is the Patterns room's, `patterns.pinned`).
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
    nonisolated private struct SamplingKey: Hashable, Sendable {
        var resolution: Double
        var pointGroup: String
    }

    nonisolated private struct BestMatchKey: Equatable, Sendable {
        var position: EBSDPosition
        var run: Int
        var phase: Int
        var simulation: Int
    }

    @ObservationIgnored var runTask: Task<Void, Never>?
    @ObservationIgnored private var patternTask: Task<Void, Never>?
    /// Bumped by every dataset bound or closed (a pattern or a key that lands for another dataset is dropped) and by every run (a row
    /// that lands for an earlier run is dropped).
    @ObservationIgnored private var generation = 0
    /// The number of the last run started: bumped by every run and every dataset (a row that lands for an earlier run is dropped). A
    /// run keeps it as its id (`IndexingRun.id`): the Maps room names a run it shows by it (D-SEM-99), Compare the runs it compares.
    package internal(set) var runGeneration = 0
    @ObservationIgnored private var palette: IndexingPalette?
    /// The band detector of the current settings, kept between hovers and handed to the run; kept without the patterns (#427), and
    /// given the patterns current when it is used.
    @ObservationIgnored private var probe: (key: ProbeKey, probe: IndexingProbe)?
    @ObservationIgnored private var shownKey: ShownKey?
    @ObservationIgnored private var shownRaw: [HoughBandDetector.Band] = []
    /// The dictionary's orientations sampled, by resolution and point group, kept for the next run: those the settings want, and the
    /// last landed.
    @ObservationIgnored private var sampled: [SamplingKey: [SIMD4<Double>]] = [:]
    @ObservationIgnored private var samplingTasks: [SamplingKey: Task<Void, Never>] = [:]
    @ObservationIgnored private var masterTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var bestMatchTask: Task<Void, Never>?
    @ObservationIgnored private var bestMatchKey: BestMatchKey?
    /// The simulation overlay's bands and kinematical master patterns per phase and spacing, and the last overlay made
    /// (IndexingSession+Overlay.swift).
    @ObservationIgnored var overlayBands: [IndexingOverlayKey: KikuchiOverlay.Bands?] = [:]
    @ObservationIgnored var overlayMasters: [IndexingOverlayKey: EBSDMasterPattern] = [:]
    @ObservationIgnored var overlayMemo: (key: IndexingOverlayMemo, value: Result<KikuchiOverlay.Pattern, KikuchiOverlay.Absence>)?
    /// The master patterns being made off the main actor, by phase and spacing, and how many have landed: the overlay reads the
    /// count, so a master that lands draws the simulation.
    @ObservationIgnored var overlayMasterTasks: [IndexingOverlayKey: Task<Void, Never>] = [:]
    var overlayMastersLanded = 0

    package init(patterns: EBSDSession) {
        self.patterns = patterns
    }

    package var hasDataset: Bool { patterns.hasDataset }
    package var isBusy: Bool { isIndexing }
    package var phasesOn: [IndexingPhase] { phases.filter(\.isOn) }
    /// The inputs a run of `method` would take now.
    package func inputs(for method: IndexingMethod) -> IndexingInputs {
        IndexingInputs(pipeline: patterns.pipeline, phases: phases, settings: settings, method: method, dictionary: dictionarySettings,
                       masterIDs: method == .dictionary ? mastersOn.mapValues(\.id) : [:])
    }
    /// The inputs a run would take now.
    package var currentInputs: IndexingInputs { inputs(for: method) }
    /// `method`'s last run was made of other inputs than that method's current ones (design §6: a Processing, Phases or method
    /// settings change stales it; picking the other method does not, each run is its method's); false without one.
    package func isStale(of method: IndexingMethod) -> Bool {
        guard let run = runs[method] else { return false }
        return run.inputs != inputs(for: method)
    }
    /// The run on screen is stale (`isStale(of:)` of its method; a refinement's `isRefinementStale`).
    package var isStale: Bool { shownRun.map { $0.refinement != nil ? isRefinementStale : isStale(of: $0.method) } ?? false }
    /// The master pattern `phase`'s dictionary is projected from (D-SEM-98): the one picked for it, else the one it prefers
    /// (`IndexingMasterPattern.preferred(for:among:)`); nil when none is open.
    package func master(for phase: IndexingPhase) -> IndexingMasterPattern? {
        if let id = masterPicks[phase.id], let picked = masterPatterns.first(where: { $0.id == id }) { return picked }
        return IndexingMasterPattern.preferred(for: phase, among: masterPatterns)
    }
    /// Each phase on with its master pattern, by phase name.
    private var mastersOn: [String: IndexingMasterPattern] {
        Dictionary(phasesOn.compactMap { p in master(for: p).map { (p.id, $0) } }, uniquingKeysWith: { first, _ in first })
    }
    /// The map layers on offer: the result's method's, or the method picked before a run.
    package var availableLayers: [IndexingLayer] { result?.layers ?? IndexingLayer.layers(for: method) }

    // MARK: - The dataset

    /// A dataset was bound in Patterns: the room starts over on it, with the phases of its crystal map.
    package func bind(_ document: EBSDSession.Document) {
        reset()
        let fromFile = document.dataset.crystalMap.map { IndexingPhase.fromCrystalMap($0.phases) } ?? (phases: [], skipped: [])
        phases = fromFile.phases
        skippedPhases = fromFile.skipped
        fileIndexing = OrientationMapSession.patternsDocument(fileName: document.fileName, url: document.url, dataset: document.dataset)?.map
        compareA = .hough
        compareB = fileIndexing == nil ? .dictionary : .file
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
        runTask?.cancel(); patternTask?.cancel(); bestMatchTask?.cancel(); compareTask?.cancel()
        for task in samplingTasks.values { task.cancel() }
        samplingTasks = [:]
        runs = [:]; runningMethod = nil; fileIndexing = nil
        isIndexing = false; progress = 0; chunksDone = 0; chunksTotal = 0; chunkPhase = nil
        showsCompare = false; comparison = nil; comparePictures = nil; compareTask = nil; compareKey = nil
        mapRGBA = nil; palette = nil; probe = nil; shownKey = nil; shownRaw = []
        mapPresentation.resetWindow()
        patternPosition = nil; detectedBands = []; patternFailure = nil; patternShape = (rows: 0, columns: 0)
        bestMatchPosition = nil; bestMatchFailure = nil; bestMatchKey = nil
        overlayBands = [:]; overlayMasters = [:]; overlayMemo = nil
        for task in overlayMasterTasks.values { task.cancel() }
        overlayMasterTasks = [:]
        phases = []; skippedPhases = []; settings = .roomDefault; layer = .ipfZ
        method = .hough; dictionarySettings = .roomDefault; dictionarySizes = [:]; masterPicks = [:]
        refinedRun = nil; isRefining = false; refinesAfterIndexing = false; refineSettings = .roomDefault
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
        masterPicks[name] = nil
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
        refreshDictionarySizes()
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

    /// Picks how Index indexes, and so which run the room shows (D-SEM-97): that method's last run when the room holds one, else the
    /// run on screen stays; the map's layer follows the method before a run.
    package func setMethod(_ new: IndexingMethod) {
        guard new != method else { return }
        let before = shownRun?.id
        method = new
        if shownRun?.id != before {
            shownResultChanged()
        } else if result == nil, !IndexingLayer.layers(for: new).contains(layer) {
            setLayer(.ipfZ)
        }
        refreshDictionarySizes()
    }

    /// Edits the dictionary settings in place (one field).
    package func editDictionarySettings(_ change: (inout DictionaryIndexingSettings) -> Void) {
        var edited = dictionarySettings
        change(&edited)
        guard edited != dictionarySettings else { return }
        dictionarySettings = edited
        refreshDictionarySizes()
    }

    package func resetDictionarySettings() {
        guard dictionarySettings != .roomDefault else { return }
        dictionarySettings = .roomDefault
        refreshDictionarySizes()
    }

    /// Picks the master pattern phase `name`'s dictionary is projected from, by its id (D-SEM-98). The run's inputs name it, so a pick
    /// stales a dictionary run.
    package func selectMasterPattern(_ id: String, forPhase name: String) {
        guard masterPatterns.contains(where: { $0.id == id }), phases.contains(where: { $0.name == name }), masterPicks[name] != id else { return }
        masterPicks[name] = id
    }

    /// Opens the master pattern at `url` off the main actor (D-SEM-98: each phase without a pick then takes it when it prefers it, of
    /// its name and space group, `IndexingMasterPattern.preferred(for:among:)`; the event says which phases on do). A file that is
    /// not an EMsoft EBSD or TKD master pattern is refused with the reason. The returned task ends when it is open (or refused).
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
        if let open = masterPatterns.first(where: { $0.id == id }) {
            if !quietly { onEvent?("\(open.fileName) is already open; " + users(of: open)) }
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
                if !quietly { self.onEvent?("Opened the master pattern \(opened.fileName): \(opened.summary); " + self.users(of: opened)) }
            } catch {
                guard let self else { return }
                self.masterTasks[id] = nil
                self.isLoadingMaster = !self.masterTasks.isEmpty
                guard !quietly else { return }
                // The line is for the Output pane and the session record; the alert that follows is what VoiceOver reads, so the window
                // does not speak this line as well (the app's `SessionEventSpeech.alertedPrefix` is how it starts).
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

    /// Which phases on take master pattern `master`, for the open event: "ni, Al take it", or how to give it one.
    private func users(of master: IndexingMasterPattern) -> String {
        let names = phasesOn.filter { self.master(for: $0)?.id == master.id }.map(\.name)
        if names.isEmpty { return "no phase on takes it: pick it for a phase under Dictionary" }
        return names.joined(separator: ", ") + (names.count == 1 ? " takes it" : " take it")
    }

    /// The sampling `phase`'s dictionary takes at the current resolution; nil without a point group.
    private func samplingKey(for phase: IndexingPhase) -> SamplingKey? {
        phase.pointGroupName.map { SamplingKey(resolution: dictionarySettings.resolution, pointGroup: $0) }
    }

    /// The samplings the phases on take now.
    private var wantedSamplingKeys: Set<SamplingKey> { Set(phasesOn.compactMap(samplingKey(for:))) }

    /// `phase`'s dictionary size at the current resolution; nil while it is counted, when it cannot be, or while Dictionary is not
    /// picked.
    package func dictionarySize(for phase: IndexingPhase) -> Int? { phase.pointGroupName.flatMap { dictionarySizes[$0] } }

    /// The dictionaries of the phases on, summed (one per phase on: two phases of one point group are sampled once and run twice); nil
    /// while one is counted, without a phase on, or when Dictionary is not picked or its settings are refused.
    package var dictionarySize: Int? {
        guard method == .dictionary, !phasesOn.isEmpty, dictionarySettings.refusal == nil else { return nil }
        var total = 0
        for phase in phasesOn {
            guard let n = dictionarySize(for: phase) else { return nil }
            total += n
        }
        return total
    }

    /// Counts the dictionary's orientations for the current resolution and each point group of the phases on, off the main actor, one
    /// task per point group, and keeps them for the run (only while Dictionary is picked: sampling 1° takes seconds).
    private func refreshDictionarySizes() {
        guard method == .dictionary, dictionarySettings.refusal == nil else {
            for task in samplingTasks.values { task.cancel() }
            samplingTasks = [:]
            dictionarySizes = [:]
            return
        }
        let wanted = wantedSamplingKeys
        for (key, task) in samplingTasks where !wanted.contains(key) {
            task.cancel()
            samplingTasks[key] = nil
        }
        var sizes: [String: Int] = [:]
        for key in wanted {
            if let rotations = sampled[key] {
                sizes[key.pointGroup] = rotations.count
                continue
            }
            guard samplingTasks[key] == nil else { continue }
            samplingTasks[key] = Task { [weak self] in
                var rotations: [SIMD4<Double>]?
                var failure: String?
                if let group = PointGroup.named(key.pointGroup) {
                    do {
                        rotations = try await DictionaryIndexingPlan.sample(resolution: key.resolution, pointGroup: group)
                    } catch {
                        failure = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    }
                }
                // A cancelled task was taken out of `samplingTasks` by whoever cancelled it; any other ends its own entry, landed or
                // not, so a later refresh samples the group again.
                guard let self, !Task.isCancelled else { return }
                self.samplingTasks[key] = nil
                if let rotations {
                    self.keepSampled([key: rotations])
                } else if let failure {
                    // The group's dictionary size stays blank; the status line says why.
                    self.onEvent?("Dictionary (\(key.pointGroup)): \(failure)")
                }
            }
        }
        dictionarySizes = sizes
    }

    /// Keeps freshly sampled orientations and drops the samples no setting wants any more (the wanted keys and those just landed
    /// stay); the dictionary sizes of the wanted ones follow.
    private func keepSampled(_ landed: [SamplingKey: [SIMD4<Double>]]) {
        sampled.merge(landed) { _, new in new }
        let wanted = wantedSamplingKeys
        sampled = sampled.filter { wanted.contains($0.key) || landed[$0.key] != nil }
        guard method == .dictionary, dictionarySettings.refusal == nil else { return }
        for (key, rotations) in landed where wanted.contains(key) { dictionarySizes[key.pointGroup] = rotations.count }
    }

    /// The Dictionary section's Chunk row: patterns per chunk (the largest over the phases), the chunks of every phase's dictionary per
    /// block summed, and the blocks, as the run would cut them now; nil before every dictionary is counted.
    package var dictionaryChunking: (size: Int, chunks: Int, blocks: Int)? {
        guard dictionarySize != nil, case .success(let source) = self.source() else { return nil }
        let pixels = source.patternRows * source.patternColumns
        let mask = (try? dictionarySettings.signalMask(rows: source.patternRows, columns: source.patternColumns)) ?? nil
        let kept = mask.map { $0.filter { !$0 }.count } ?? pixels
        let perBlock = DictionaryIndexingPlan.rowsPerBlock(scanRows: source.scanRows, scanColumns: source.scanColumns, pixels: pixels)
        let options = DictionaryIndexing.Options(metric: dictionarySettings.metric, keepN: dictionarySettings.keep, signalMask: mask)
        let cuts = phasesOn.compactMap { dictionarySize(for: $0) }.map {
            DictionaryIndexingPlan.chunking(points: perBlock * source.scanColumns, keptPixels: kept, dictionary: $0, options: options)
        }
        return (cuts.map(\.size).max() ?? 0, cuts.reduce(0) { $0 + $1.chunks }, (source.scanRows + perBlock - 1) / max(perBlock, 1))
    }

    /// Why a dictionary cannot run now (the Dictionary section's warning); nil when it can. Every phase on needs a master pattern of
    /// its space group (D-SEM-98).
    package var dictionaryRefusal: String? {
        guard let document = patterns.document else { return "No EBSD dataset is open." }
        if isLoadingMaster, phasesOn.contains(where: { master(for: $0)?.master.phase.spaceGroup != $0.spaceGroup }) {
            return "The master pattern is being read."
        }
        return DictionaryIndexingPlan.refusal(phases: phases, masters: mastersOn, settings: dictionarySettings,
                                              detector: document.dataset.detector, beamEnergy: document.dataset.sem.beamEnergyKeV)
    }

    /// Shows layer `new` of the result. A scalar layer's window goes back to its full range (each layer has its own units); the
    /// colormap and the gamma stay, as the Patterns room's map keeps them from map to map.
    package func setLayer(_ new: IndexingLayer) {
        guard new != layer, availableLayers.contains(new) else { return }
        layer = new
        palette = result.map { IndexingPalette(layer: new, phases: $0.phases) }
        if !new.isPointwise { mapPresentation.resetWindow() }
        refreshMap()
        refreshComparison()
    }

    /// Another run came on screen (a Method pick, or the run in flight ended under another method): its layers, map, Bands families,
    /// best match and Compare.
    func shownResultChanged() {
        if !availableLayers.contains(layer) { layer = .ipfZ }
        if !layer.isPointwise { mapPresentation.resetWindow() }
        palette = nil
        clearBestMatch()
        refreshMap()
        refreshBandRows()
        showBestMatch()
        refreshComparison()
    }

    /// Whether the map shows a scalar layer through `mapPresentation` (a result is on screen and its layer is not pointwise).
    package var showsScalarMap: Bool { result != nil && !layer.isPointwise }

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

    /// The patterns `run` read, to read them again once the ended run has let them go (#427; Refine on a Dictionary run, D-SEM-109):
    /// the same kind through the same stages as `source()` gave the run, while the Patterns room's processing is still the run's. nil
    /// when they cannot be read so now: the processed scan the run read was replaced by one processed with other stages.
    func patternsRead(by run: IndexingRun) -> IndexingSource? {
        guard let document = patterns.document, run.inputs.pipeline == patterns.pipeline else { return nil }
        switch run.source {
        case .processedScan:
            guard let processed = patterns.processed, patterns.processedWith == patterns.pipeline else { return nil }
            return IndexingSource(processed: processed)
        case .perPattern, .asStored:
            let source = IndexingSource(stored: document.access, pipeline: patterns.pipeline, background: patterns.staticBackground)
            return source.kind == run.source ? source : nil
        }
    }

    /// Why Index cannot run now with the method picked; nil when it can.
    package var refusal: String? {
        guard let document = patterns.document else { return "No EBSD dataset is open." }
        switch method {
        case .hough:
            if let why = IndexingPlan.refusal(phases: phases, settings: settings, detector: document.dataset.detector) { return why }
        case .dictionary:
            if let why = dictionaryRefusal ?? (refinesAfterIndexing ? refineRefusal : nil) { return why }
        }
        if case .failure(let refusal) = self.source() { return refusal.sentence }
        return nil
    }

    package var canIndex: Bool { patterns.document != nil && !isIndexing && !patterns.isOpening && !patterns.isProcessing && refusal == nil }

    /// The verb's help: "Index 4125 patterns with Hough (ni)", "Index 4125 patterns with Dictionary (ni)", or why it cannot run;
    /// with Refine on, the stale stages it runs (design §3): "…, then refine the orientations", or "Refine the orientations of the
    /// 4125 patterns indexed with Dictionary (ni)". The counts never grouped, as `UnitDisplay.count` writes a count.
    package var verbHelp: String {
        if let refusal { return refusal }
        guard let dataset = patterns.dataset else { return "" }
        if method == .dictionary, refinesAfterIndexing {
            let noun = refineSettings.target.noun, names = phasesOn.map(\.name).joined(separator: ", ")
            if refinesAlone, let base = runs[.dictionary] {
                return "Refine the \(noun) of the \(base.result.indexedCount) patterns indexed with Dictionary (\(names))"
            }
            return "Index \(dataset.patternCount) patterns with Dictionary (\(names)), then refine the \(noun)"
                + (isStale(of: .dictionary) ? "; the inputs changed since the last run" : "")
        }
        let what = "Index \(dataset.patternCount) patterns with \(method.title) (\(phasesOn.map(\.name).joined(separator: ", ")))"
        if let result, result.method == method, isStale { return what + "; the inputs changed since the last run" }
        return what
    }

    // MARK: - The run

    /// The room's verb: the scan indexed off the main actor with the method picked, row by row (Hough) or block of rows by block
    /// (dictionary); each lands on the map as it is done. Stop (⌘.) ends it and keeps the rows indexed. With `Refine › After indexing`
    /// on (D-SEM-109) it runs the stale stages in order: Dictionary then Refine, or Refine alone on a current, complete Dictionary run
    /// whose refinement is missing, stale, stopped or incomplete. The returned task ends when the run has landed (or was refused,
    /// stopped or failed), the Refine stage included.
    @discardableResult
    package func index() -> Task<Void, Never> {
        guard let document = patterns.document, !isIndexing else { return Task {} }
        if let why = refusal {
            onEvent?("Index: \(why)")
            return Task {}
        }
        guard case .success(let source) = self.source() else { return Task {} }
        switch method {
        case .hough:
            return indexWithHough(document, source: source)
        case .dictionary:
            if refinesAfterIndexing, refinesAlone, let refining = refineDictionaryRun() { return refining }
            let indexed = indexWithDictionary(document, source: source)
            guard refinesAfterIndexing else { return indexed }
            // Index → Refine: `finish` starts the Refine stage in the same turn, so the run's task is then the refinement's.
            return Task { [weak self] in
                await indexed.value
                await self?.runTask?.value
            }
        }
    }

    private func indexWithHough(_ document: EBSDSession.Document, source: IndexingSource) -> Task<Void, Never> {
        let inputs = currentInputs
        let key = ProbeKey(pipeline: inputs.pipeline, settings: inputs.settings, kind: source.kind, generation: generation)
        let cached = probe?.key == key ? probe?.probe.reading(source) : nil
        let phases = self.phases, settings = self.settings, detector = document.dataset.detector
        let rows = document.dataset.scanRows, columns = document.dataset.scanColumns
        runTask?.cancel()
        runGeneration += 1
        let run = runGeneration
        runs[.hough] = IndexingRun(id: run, result: IndexingResult(scanRows: rows, scanColumns: columns, phases: inputs.phases), inputs: inputs,
                                   source: source.kind, projectionCenter: IndexingPlan.meanProjectionCenter(detector))
        isIndexing = true; runningMethod = .hough; progress = 0; chunksDone = 0; chunksTotal = 0
        if !IndexingLayer.layers(for: .hough).contains(layer) { layer = .ipfZ }
        palette = IndexingPalette(layer: layer, phases: inputs.phases)
        clearBestMatch()
        refreshMap()
        refreshBandRows()
        refreshComparison()
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

    /// The Output line a dictionary run starts with: "Indexing 4125 patterns against the Ni dictionary at 4° (NCC)…"; against several
    /// phases, "… against 2 dictionaries (Ni, Al) at 4° (NCC); each point takes the phase of its best score…". The resolution in
    /// `locale` as the Dictionary section's size row writes it (`UnitDisplay.number`): "2,675°" in German, where three significant
    /// digits by FormatStyle read "2,68°".
    nonisolated package static func dictionaryStartLine(points: Int, phases: [String], resolution: Double, metric: String,
                                                        locale: Locale = .autoupdatingCurrent) -> String {
        let at = "\(UnitDisplay.number(resolution, locale: locale))° (\(metric))"
        guard phases.count != 1 else { return "Indexing \(points) patterns against the \(phases[0]) dictionary at \(at)…" }
        return "Indexing \(points) patterns against \(phases.count) dictionaries (\(phases.joined(separator: ", "))) at \(at); "
            + "each point takes the phase of its best score…"
    }

    /// A dictionary run (D-SEM-92, D-SEM-98): each phase's orientations sampled (or the ones kept for its resolution and point group,
    /// one sampling for every phase of a group), the plans built (one per phase on), then each block of rows read once and matched
    /// against every phase's dictionary in turn, chunk by chunk, its rows landing when every phase has matched them (merged as
    /// kikuchipy's `merge_crystal_maps` merges the phases' maps, `IndexingResult.land(_:rows:)`). One phase makes today's calls.
    private func indexWithDictionary(_ document: EBSDSession.Document, source: IndexingSource) -> Task<Void, Never> {
        let inputs = currentInputs
        let on = phasesOn, masters = mastersOn
        let keys = on.compactMap { samplingKey(for: $0) }
        guard !on.isEmpty, keys.count == on.count, on.allSatisfy({ masters[$0.id] != nil }) else { return Task {} }
        let cached = sampled.filter { keys.contains($0.key) }
        let phases = self.phases, settings = dictionarySettings, detector = document.dataset.detector
        let beam = document.dataset.sem.beamEnergyKeV
        let rows = document.dataset.scanRows, columns = document.dataset.scanColumns
        runTask?.cancel()
        runGeneration += 1
        let run = runGeneration
        runs[.dictionary] = IndexingRun(id: run, result: IndexingResult(scanRows: rows, scanColumns: columns, phases: inputs.phases,
                                                                        metric: settings.metric),
                                        inputs: inputs, source: source.kind, projectionCenter: IndexingPlan.meanProjectionCenter(detector))
        refinedRun = nil   // a refinement of the run replaced goes with it
        isIndexing = true; runningMethod = .dictionary; progress = 0; chunksDone = 0; chunksTotal = 0; chunkPhase = nil
        if !IndexingLayer.layers(for: .dictionary).contains(layer) { layer = .ipfZ }
        palette = IndexingPalette(layer: layer, phases: inputs.phases)
        clearBestMatch()
        refreshMap()
        refreshBandRows()
        refreshComparison()
        onEvent?(Self.dictionaryStartLine(points: rows * columns, phases: on.map(\.name), resolution: settings.resolution,
                                          metric: settings.metric.title))
        // The chunks merged, in order, and the phase matching, to the main actor (the newest only: the count only grows).
        let (chunks, chunkSink) = AsyncStream.makeStream(of: (done: Int, phase: Int).self, bufferingPolicy: .bufferingNewest(1))
        Task { [weak self] in
            for await chunk in chunks { self?.chunkMerged(chunk.done, phase: chunk.phase, run: run) }
        }
        let started = Date()
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            defer { chunkSink.finish() }
            do {
                var byKey = cached
                for (phase, key) in zip(on, keys) where byKey[key] == nil {
                    guard let group = phase.pointGroup else { throw IndexingRefusal("\(phase.name): no point group is known for space group \(phase.spaceGroup).") }
                    byKey[key] = try await DictionaryIndexingPlan.sample(resolution: settings.resolution, pointGroup: group)
                    try Task.checkCancellation()
                }
                try Task.checkCancellation()
                let plans = try DictionaryIndexingPlan.plans(source: source, phases: phases, masters: masters, settings: settings,
                                                             fileDetector: detector, beamEnergy: beam, rotations: keys.map { byKey[$0] ?? [] })
                guard let first = plans.first else { throw IndexingRefusal("Turn a phase on to index against it.") }
                let perBlock = plans.map(\.chunksPerBlock)
                await self?.landDictionaryPlans(plans, sampled: byKey, chunks: perBlock.joined().reduce(0, +), run: run)
                var before = 0
                for (k, block) in first.blocks.enumerated() {
                    try Task.checkCancellation()
                    // Read once, matched against every phase's dictionary.
                    let experimental = try await first.readBlock(block)
                    var matched: [DictionaryIndexing.Result] = []
                    for (i, plan) in plans.enumerated() {
                        let offset = before
                        _ = chunkSink.yield((done: offset, phase: i))
                        matched.append(try await plan.indexBlock(block, experimental: experimental) { done, _ in
                            _ = chunkSink.yield((done: offset + done, phase: i))
                        })
                        before += perBlock[i][k]
                    }
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
    /// keeps nothing of it: its points have not met the whole dictionary). Stopping the Refine stage keeps the rows refined and
    /// leaves the Dictionary run as it was.
    package func stop() {
        guard isIndexing else { return }
        runTask?.cancel()
        let before = shownRun?.id
        let stopped = runningMethod
        let refining = isRefining
        isIndexing = false
        isRefining = false
        runningMethod = nil
        chunkPhase = nil
        if refining {
            refinedRun?.wasStopped = true
            if let r = refinedRun?.result { onEvent?("Stopped refinement at row \(r.rowsDone) of \(r.scanRows); the refined rows stay") }
        } else if let stopped {
            runs[stopped]?.wasStopped = true
            if let result = runs[stopped]?.result {
                if result.method == .dictionary {
                    onEvent?("Stopped dictionary indexing after \(chunksDone) of \(chunksTotal) chunks; \(result.rowsDone) of \(result.scanRows) rows were indexed and stay")
                } else {
                    onEvent?("Stopped indexing after \(result.rowsDone) of \(result.scanRows) rows; the indexed rows stay")
                }
            }
        }
        releasePatterns(ofRefinement: refining, method: stopped)
        if shownRun?.id != before {
            shownResultChanged()
        } else {
            refreshBandRows()
            refreshComparison()
        }
    }

    /// The run that ended lets go of the patterns it read (#427): the refinement, or the run of `method`.
    private func releasePatterns(ofRefinement refined: Bool, method: IndexingMethod?) {
        if refined {
            refinedRun?.releasePatterns()
        } else if let method {
            runs[method]?.releasePatterns()
        }
    }

    /// The run's plan lands. One built while Stop was pressed lands after it (the task asks for cancellation only between rows): the
    /// run has ended, so the plan lands without its patterns (#427).
    private func landPlan(_ plan: IndexingPlan, probe built: IndexingProbe, key: ProbeKey, run: Int) {
        guard run == runGeneration else { return }
        runs[.hough]?.houghPlan = plan
        if !isIndexing { runs[.hough]?.releasePatterns() }
        probe = (key: key, probe: built.released)
    }

    private func landRow(_ solutions: [HoughIndexer.Solution], row: Int, run: Int) {
        guard run == runGeneration, isIndexing else { return }
        runs[.hough]?.result.land(solutions, at: row)
        progress = Double(row + 1) / Double(max(runs[.hough]?.result.scanRows ?? 1, 1))
        repaint(rows: row..<(row + 1))
        if patternPosition?.row == row { refreshBandRows() }
    }

    private func landDictionaryPlans(_ plans: [DictionaryIndexingPlan], sampled landed: [SamplingKey: [SIMD4<Double>]], chunks: Int,
                                     run: Int) {
        guard run == runGeneration else { return }
        runs[.dictionary]?.dictionaryPlans = plans
        // Plans built while Stop was pressed land after it: the run has ended (#427).
        if !isIndexing { runs[.dictionary]?.releasePatterns() }
        keepSampled(landed)
        chunksTotal = chunks
    }

    /// `done` chunks of the run merged, phase `phase`'s dictionary matching now.
    private func chunkMerged(_ done: Int, phase: Int, run: Int) {
        guard run == runGeneration, isIndexing, chunksTotal > 0 else { return }
        chunksDone = min(max(chunksDone, done), chunksTotal)
        progress = Double(chunksDone) / Double(chunksTotal)
        if let phases = runs[.dictionary]?.result.phases, phases.count > 1, phases.indices.contains(phase) { chunkPhase = phases[phase].name }
    }

    private func landBlock(_ matched: [DictionaryIndexing.Result], rows: Range<Int>, run: Int) {
        guard run == runGeneration, isIndexing else { return }
        runs[.dictionary]?.result.land(matched, rows: rows)
        repaint(rows: rows)
        if let row = patternPosition?.row, rows.contains(row) { showBestMatch() }
    }

    func finish(seconds: Double, failure: String?, run: Int) {
        guard run == runGeneration, isIndexing else { return }
        let before = shownRun?.id
        let finished = runningMethod
        let refined = isRefining
        isIndexing = false
        isRefining = false
        runningMethod = nil
        chunkPhase = nil
        // The ended run lets go of the patterns it read (#427), on every way out of here, the failure's included. A Refine stage
        // started below as the Dictionary stage ends reads them through its own copy of the plan, taken as it starts, and lets go
        // of them when it ends.
        defer { releasePatterns(ofRefinement: refined, method: finished) }
        let shownChanged = shownRun?.id != before
        if let failure {
            onEvent?("Error: \(failure)")
            if shownChanged { shownResultChanged() } else { refreshComparison() }
            return
        }
        progress = 1
        if chunksTotal > 0 { chunksDone = chunksTotal }
        if refined, let r = refinedRun {
            refinedRun?.seconds = seconds
            let base = runs[.dictionary]?.result
            let change = base.flatMap { IndexingRefinement.meanScores(base: $0, refined: r.result) }.map {
                " · mean \(base?.scoreTitle ?? "NCC") \(SessionEventFormat.fixed($0.before, 3)) → NCC \(SessionEventFormat.fixed($0.after, 3))"
            } ?? ""
            onEvent?("Refined \(r.result.indexedCount) of \(r.result.pointCount) patterns (\(r.refinement?.settings.target.noun ?? "")) in "
                + "\(SessionEventFormat.fixed(seconds, 1)) s" + change)
        } else if let finished {
            runs[finished]?.seconds = seconds
            if let result = runs[finished]?.result {
                // A run against several phases says how many points each took.
                let byPhase = result.method == .dictionary && result.phases.count > 1
                    ? " (" + zip(result.phases, result.countsByPhase).map { "\($0.name) \($1)" }.joined(separator: " · ") + ")" : ""
                onEvent?("Indexed \(result.indexedCount) of \(result.pointCount) patterns with \(result.method.title) in \(SessionEventFormat.fixed(seconds, 1)) s"
                    + byPhase)
            }
        }
        // Index → Refine (design §3): the stage starts in this turn, so the verb never goes idle between them (and Stop reaches it);
        // a stage that cannot run says why (the phases or the trust region changed while the dictionary ran).
        if !refined, finished == .dictionary, refinesAfterIndexing {
            if refineDictionaryRun() != nil { return }
            onEvent?("Refine: \(refineStageRefusal ?? "the Dictionary run cannot be refined.")")
        }
        if shownChanged {
            shownResultChanged()
        } else {
            refreshBandRows()
            showBestMatch()
            refreshComparison()
        }
    }

    // MARK: - The map

    /// Repaints the whole map: the result on its layer (a pointwise one over the dimmed navigator, a scalar one as its values through
    /// `mapPresentation`), or the navigator alone before a run.
    package func refreshMap() {
        guard let dataset = patterns.dataset else {
            mapRGBA = nil
            return
        }
        if let result, !layer.isPointwise {
            mapRGBA = nil
            mapPresentation.show(CanvasPixels.make(width: result.scanColumns, height: result.scanRows,
                                                   pixels: IndexingRaster.scalarPixels(result, layer: layer)))
        } else if let result {
            let palette = self.palette.flatMap { $0.layer == layer ? $0 : nil } ?? IndexingPalette(layer: layer, phases: result.phases)
            self.palette = palette
            mapRGBA = IndexingRaster.rgba(result, palette: palette, backdrop: patterns.meanIntensities)
        } else {
            mapRGBA = IndexingRaster.backdrop(scanRows: dataset.scanRows, scanColumns: dataset.scanColumns, means: patterns.meanIntensities)
        }
        mapVersion &+= 1
    }

    /// Landed rows: a pointwise layer repaints those rows, a scalar layer (its range moves) the whole map.
    func repaint(rows: Range<Int>) {
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

    /// Picks `position` (a click or a drag on the map or a compared map, a Results row, an arrow key): the shared marker moves and the
    /// pattern pane follows it. The pointer over the map picks nothing (D-SEM-110).
    package func pin(_ position: EBSDPosition) {
        patterns.pin(position)
        showPattern()
    }

    package func step(_ direction: EBSDPosition.Direction, by count: Int = 1) {
        patterns.step(direction, by: count)
        showPattern()
    }

    // MARK: - The pattern

    /// Shows the pattern at the picked position (`patterns.pinned`) as it is indexed, with its detected bands: read, processed and detected
    /// off the main actor in a task the next request cancels. The returned task ends when the pattern is on screen.
    @discardableResult
    package func showPattern() -> Task<Void, Never> {
        guard patterns.document != nil else { return Task {} }
        let position = patterns.pinned
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
        let cached = probe?.key == key ? probe?.probe.reading(source) : nil
        let settings = self.settings
        let gen = generation
        let task = Task { [weak self] in
            do {
                let inspected = try await Self.inspect(cached: cached, source: source, settings: settings, position: position)
                guard let self, !Task.isCancelled, gen == self.generation else { return }
                self.probe = (key: key, probe: inspected.probe.released)
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

    /// Makes the IPF colour key of every point group in the phases and in the file's indexing (Compare's `File`) that has none yet, off
    /// the main actor.
    private func loadKeys() {
        let fileGroups = fileIndexing?.phases.entries.compactMap(\.phase.pointGroupName) ?? []
        let wanted = Set(phases.compactMap(\.pointGroupName) + fileGroups).subtracting(keyImages.keys)
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

    /// The Best match pane: a dictionary run's best orientation at the pattern pane's point, simulated on the run's detector from the
    /// master pattern of the point's phase (`MasterPatternProjection`, kikuchipy's `get_patterns`, D-SEM-98), off the main actor;
    /// nothing where the point has none. A refinement's point simulates its refined orientation at the PC it was refined at (its
    /// refined PC under PC or Both, else the run's detector's, the file's mean), the pattern its NCC scores.
    func showBestMatch() {
        guard let run = shownRun, run.method == .dictionary, let position = patternPosition,
              let solution = run.result.solution(at: position), solution.phase >= 0, run.dictionaryPlans.indices.contains(solution.phase),
              let simulation = run.result.simulationIndex(at: position) else {
            clearBestMatch()
            return
        }
        let plan = run.dictionaryPlans[solution.phase]
        let key = BestMatchKey(position: position, run: run.id, phase: solution.phase, simulation: simulation)
        guard key != bestMatchKey else { return }
        bestMatchKey = key
        bestMatchTask?.cancel()
        let rotation = solution.quaternion, pc = run.result.refinedProjectionCenter(at: position)
        bestMatchTask = Task { [weak self] in
            do {
                let pixels = try await plan.simulated(rotation, projectionCenter: pc)
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

    // MARK: - The Maps room

    /// Why `Open in Maps` cannot hand the result over now (D-SEM-99): nothing indexed yet, or a run still going (Maps shows a result
    /// as it stands, and a run's map grows row by row). nil when it can.
    package var openInMapsRefusal: String? {
        if isIndexing { return "Stop the run or let it finish first" }
        guard let result, result.reachedCount > 0 else { return "Index first" }
        return nil
    }

    /// The run on screen as the Maps room shows it (D-SEM-99): its crystal map (`crystalMap()`, the one the .ang and .ctf exports are
    /// written from: the rows reached, the room's phase colours, the scan's steps and unit, the run's values) under the pattern file's
    /// name, its source this run of its method. nil while `openInMapsRefusal` holds.
    package func mapsDocument() throws -> OrientationMapSession.Document? {
        guard openInMapsRefusal == nil, let run = shownRun, let document = patterns.document, let map = try crystalMap() else { return nil }
        return OrientationMapSession.Document(fileName: document.fileName, url: document.url, map: map,
                                              source: .indexing(run: run.id, method: run.method),
                                              format: "Indexing room · \(run.title)")
    }

    /// What the Maps room says of run `run` of `method` it shows: nil while it is that method's last run and its inputs stand; else that
    /// a later run of the method replaced it (started, or ended having reached a point; and to Open in Maps again when that newer run
    /// is the one on screen and can be handed), or which inputs changed since (`isStale(of:)`): the Patterns room's processing, or this
    /// room's phases or method settings. A run of the other method leaves it current (D-SEM-97). A refinement (D-SEM-109) is stale
    /// once its Dictionary run was replaced, is stale, or Refine moves something else now; a refinement that a later refinement of
    /// the same Dictionary run replaced says so (its id is above the Dictionary run's: only a refinement of it starts after it under
    /// Dictionary), with Open in Maps again while that later refinement is on screen.
    package func staleness(ofRun run: Int, method: IndexingMethod) -> String? {
        if let refined = refinedRun, refined.id == run {
            guard heldRefinement != nil else { return "Stale: the Indexing room has run Dictionary again since this refinement." }
            return isRefinementStale ? "Stale: the Indexing room's phases, settings or Refine changed since this refinement." : nil
        }
        if method == .dictionary, let base = runs[.dictionary], run > base.id {
            guard let newer = heldRefinement, newer.id > run, newer.result.rowsDone > 0, !isRefining else {
                return "Stale: the Indexing room has started another refinement since."
            }
            let handable = shownRun?.id == newer.id && openInMapsRefusal == nil
            return "Stale: the Indexing room has refined the Dictionary run again since."
                + (handable ? " Open in Maps again to show the new refinement." : "")
        }
        guard let held = runs[method], held.id == run else {
            guard let newer = runs[method], newer.result.reachedCount > 0, runningMethod != method else {
                return "Stale: the Indexing room has started another \(method.title) run since."
            }
            // Open in Maps hands the run on screen: the note offers it only while that is the newer run (or its refinement, shown in
            // its place) and it can be handed.
            let shown = shownRun.map { $0.id == newer.id || $0.refinement?.base == newer.id } ?? false
            let handable = shown && openInMapsRefusal == nil
            return "Stale: the Indexing room has run \(method.title) again since." + (handable ? " Open in Maps again to show the new run." : "")
        }
        guard isStale(of: method) else { return nil }
        if held.inputs.pipeline != patterns.pipeline { return "Stale: the Patterns room's processing changed since this run." }
        return "Stale: the Indexing room's phases or settings changed since this run."
    }

    // MARK: - Export

    /// The run on screen as orix's crystal map (`IndexingResult.crystalMap`, the rows it reached on the scan's steps): what the .ang
    /// and .ctf exports write. nil before a row has landed.
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

    /// The method record of the run on screen (every input, in pyEBSDindex's, kikuchipy's and orix's names); nil before a run has its plan.
    /// A refinement's is its Dictionary run's with the refinement under "refinement" (D-SEM-109).
    package func methodJSON() throws -> Data? {
        guard let result, let document = patterns.document else { return nil }
        switch result.method {
        case .hough:
            guard let runPlan else { return nil }
            return try runPlan.methodJSON(fileName: document.fileName, points: result.pointCount, indexed: result.indexedCount)
        case .dictionary:
            let plans = dictionaryPlans
            guard !plans.isEmpty else { return nil }
            let counted = shownRun?.refinement != nil ? (runs[.dictionary]?.result ?? result) : result
            let data = try DictionaryIndexingPlan.methodJSON(plans, fileName: document.fileName, points: counted.pointCount,
                                                             indexed: counted.indexedCount, indexedByPhase: counted.countsByPhase)
            guard let run = shownRun, let record = run.refinement, let plan = plans.first else { return data }
            return try IndexingRefinement.methodJSON(data, settings: record.settings, plan: plan, base: counted, refined: run.result)
        }
    }
}
