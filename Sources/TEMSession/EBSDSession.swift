//
//  EBSDSession.swift
//  Role: the one owner of the Patterns room's state (docs/sem/design/ebsd-patterns-room.md): the open EBSD or TKD dataset and where
//        its patterns are read from, the picked position (`pinned`), the pattern on screen, the navigation map (the mean
//        intensity of every pattern, one pass over the scan) and how the two pictures are drawn (`ImagePresentation` each, so the
//        map and the pattern keep their own contrast). The room's views read it; they hold none of it.
//
//  Nothing here makes a number: the mean map and the virtual images are `VirtualBSEImaging`, the quality maps `PatternQuality` (TEMCore), the patterns the readers'. This
//  owner decides WHEN to read: the map in one detached pass that lands only if no newer dataset was bound and no other grid was picked
//  meanwhile (`mapGeneration`), and that sums the patterns for the scan's mean on the way when the file carries no static background,
//  so such a file is read once at open; the scan's mean asked for later, Process and the quality pass land only for the dataset they
//  started on (`generation`), so a new grid never drops them; the picked pattern in a task that is cancelled by the next pick, so a
//  fast drag over the map reads the pattern the pointer rests on, not every one it passed. Patterns read once stay in a cache by map
//  index that is bounded by their bytes (`cacheBudget`) and lets the least recently shown go first.
//
//  Processing (docs/sem/design/pattern-processing.md): `pipeline` holds the stages' settings (`PatternPipeline`, TEMCore). The pattern pane
//  shows the shown pattern raw or through the current pipeline (`patternDisplay`), computed on the fly from the raw pattern, so a change of
//  a stage's row shows at once; `process()` (the room's verb) runs the pipeline over the whole scan into memory (`processed`), and each
//  stage's state compares the pipeline with the one the scan was processed with (`EELSStageState`: not run, current, stale).
//

import Foundation
import Observation
import FormatoCore
import TEMCore

@Observable
package final class EBSDSession {

    /// The open dataset and the way to its patterns (`EBSDPatternAccess`: the file, or memory for the demo).
    package nonisolated struct Document: Sendable {
        package var fileName: String
        /// The file, nil for a dataset answered from memory.
        package var url: URL?
        package var dataset: EBSDDataset
        package var access: any EBSDPatternAccess

        package init(fileName: String, url: URL?, dataset: EBSDDataset, access: any EBSDPatternAccess) {
            self.fileName = fileName; self.url = url; self.dataset = dataset; self.access = access
        }
    }

    // MARK: The dataset

    package private(set) var document: Document?
    package private(set) var isOpening = false
    /// The navigation map's pass: running, and how far (0...1).
    package private(set) var isMapping = false
    package private(set) var mapProgress = 0.0
    /// The mean intensity of every pattern in map order (`EBSDBrowsing.meanIntensityMap`), once the pass has landed.
    package private(set) var meanIntensities: [Float]?
    /// Why the map could not be made (the reader's sentence); nil while it is being made or once it has landed.
    package private(set) var mapFailure: String?

    // MARK: The virtual images (north star F1)

    /// The detector grid the pass cuts the patterns into (`VirtualBSEGrid`); changing it runs the pass again.
    package private(set) var virtualGrid = VirtualBSEGrid(5)
    /// The sum images the pass landed: index 0 the whole detector (the virtual BSE), then `virtualGrid.tiles` in order; each
    /// `scanRows * scanColumns` long. nil until the pass lands.
    package private(set) var virtualImages: [[Float]]?
    /// What the scan map draws.
    package enum MapChoice: Sendable, Hashable {
        /// The mean intensity of every pattern (the navigator).
        case mean
        /// The sum over the whole detector (grid tile 1).
        case bse
        /// One tile of `virtualGrid`.
        case tile(VirtualBSETile)
        /// The colour mix of `mixTiles` (kikuchipy's `get_rgb_image`).
        case mix
        /// The image quality of every pattern (Krieger Lassen; `PatternQuality`), of the patterns as stored.
        case imageQuality
        /// The average dot product of every pattern with its four nearest neighbours (`PatternQuality`), of the patterns as stored.
        case dotProduct
    }
    package private(set) var mapChoice = MapChoice.mean
    /// The tiles of the colour mix: red, green, blue; nil until picked.
    package private(set) var mixTiles: [VirtualBSETile?] = [nil, nil, nil]
    /// The colour mix as RGBA bytes for the Metal view, once the three tiles are picked and the pass has landed; its version for the view.
    package private(set) var mixRGBA: [UInt8]?
    package private(set) var mixVersion = 0
    /// The quality maps (north star F3), made by their own pass the first time one is picked: image quality and average dot product in
    /// map order, nil until that pass lands.
    package private(set) var imageQualityMap: [Float]?
    package private(set) var dotProductMap: [Float]?
    /// The quality pass: running, and how far (0...1).
    package private(set) var isQualityMapping = false
    package private(set) var qualityProgress = 0.0
    /// The lower pane with every tile (the inspector's "Show the tiles").
    package var showsTiles = false

    // MARK: The simulation overlay (docs/sem/design/simulation-overlay.md)

    /// Whether the pattern pane draws the geometrical Kikuchi simulation of the shown position's orientation (`overlay`).
    package internal(set) var overlayOn = false
    /// Which bands, and whether the zone axes and the labels are drawn.
    package internal(set) var overlaySettings = KikuchiOverlay.Settings()
    /// The bands per phase id for the current minimum spacing, and the scan's largest r_max (both per dataset).
    @ObservationIgnored var overlayBands: [Int: KikuchiOverlay.Bands?] = [:]
    @ObservationIgnored var overlayMaxR: Double?
    /// The last overlay made, by position and spacing (the pane asks on every draw).
    @ObservationIgnored var overlayMemo: (position: EBSDPosition, minD: Double, bandWidth: Bool, kinematical: Bool,
                                          value: Result<KikuchiOverlay.Pattern, KikuchiOverlay.Absence>)?
    /// The kinematical master pattern (Lambert, for the simulation) and its stereographic picture per phase id, for the current bands.
    @ObservationIgnored var overlayMasters: [Int: EBSDMasterPattern] = [:]
    @ObservationIgnored var overlayPictures: [Int: [Double]] = [:]
    /// The master patterns being made off the main actor, by phase id, and how many have landed: the overlay reads the count, so a
    /// master that lands draws the simulation (EBSDSession+Overlay.swift).
    @ObservationIgnored var overlayMasterTasks: [Int: Task<Void, Never>] = [:]
    var overlayMastersLanded = 0

    // MARK: Processing

    /// What the pattern pane shows: the pattern as stored, or through the current pipeline.
    package enum PatternDisplay: String, Sendable, CaseIterable, Identifiable {
        case raw, processed
        package var id: String { rawValue }
        package var title: String { rawValue.capitalized }
    }

    /// The stages' settings; a change re-draws the shown pattern when it is processed and stales the scan's run from that stage on.
    package private(set) var pipeline = PatternPipeline.roomDefault
    package private(set) var patternDisplay = PatternDisplay.raw
    /// The whole scan through `processedWith`, in memory, once `process()` has landed.
    package private(set) var processed: EBSDMemoryPatterns?
    package private(set) var processedWith: PatternPipeline?
    package private(set) var isProcessing = false
    package private(set) var processProgress = 0.0
    /// The mean of every pattern (the static background "The scan's mean"), once its pass has landed.
    package private(set) var scanMeanBackground: FormatoArray?
    /// The scan's mean is being summed: in the map's pass at open (a file without a static background), or in its own pass when the
    /// source is switched to it later. Busy either way, and Stop ends it.
    package private(set) var isComputingMean = false
    /// Whether the pattern on screen went through the pipeline (the pane's title says so).
    package private(set) var patternIsProcessed = false
    /// Why the shown pattern could not be processed (a stage's sentence), shown under the Processing rows; nil when it could.
    package private(set) var previewFailure: String?
    /// The λ NLPAR chose in the run that landed (`opt_lambda`'s median), nil when that run had no NLPAR; it lands with the run's result.
    package private(set) var nlparLambda: Double?

    /// The static background the pipeline uses: the file's or the scan's mean.
    package var staticBackground: FormatoArray? {
        pipeline.staticStage.source == .file ? document?.dataset.staticBackground : scanMeanBackground
    }

    /// The first reason the pipeline cannot run on this dataset, nil when it can.
    package var processingRefusal: PatternPipeline.Refusal? {
        guard let dataset = document?.dataset else { return nil }
        if pipeline.staticStage.isOn, pipeline.staticStage.source == .mean, scanMeanBackground == nil {
            return isComputingMean ? PatternPipeline.Refusal(.staticBackground, "Computing the scan's mean pattern…") : pipeline.refusal(for: dataset, background: nil)
        }
        return pipeline.refusal(for: dataset, background: staticBackground)
    }

    /// The stage's state for its section's title glyph: not run until the scan was processed; stale from the first stage whose settings
    /// changed since; current for an active stage of the run; not run for one the pipeline leaves out.
    package func stageState(_ stage: PatternPipeline.Stage) -> EELSStageState {
        guard let processedWith, processed != nil else { return .notRun }
        if let changed = pipeline.firstDifference(from: processedWith), stage >= changed { return .stale }
        return pipeline.isActive(stage) ? .current : .notRun
    }

    /// The first stage that is not current, for the verb's help ("starting with Dynamic background"); nil when the run is current.
    package var firstStaleStage: PatternPipeline.Stage? {
        guard let processedWith, processed != nil else { return PatternPipeline.Stage.allCases.first { pipeline.isActive($0) } }
        return pipeline.firstDifference(from: processedWith)
    }

    package var canProcess: Bool { document != nil && !isBusy && processingRefusal == nil }

    /// The Mac's memory, which Process's admission measures the run against; a test sets a smaller one.
    @ObservationIgnored package var physicalMemory = ProcessInfo.processInfo.physicalMemory

    /// Why Process would not fit in memory beside the processed scan already held (`PatternPipeline.processAdmission`), nil when it
    /// fits. Kept out of `processingRefusal`, which the one-pattern preview and Indexing also read: they stream the patterns, so a scan
    /// too large to process into memory still previews and indexes. Process says it in the status line when the verb is clicked.
    package var processAdmission: PatternPipeline.Refusal? {
        guard let dataset = document?.dataset else { return nil }
        return pipeline.processAdmission(for: dataset, heldBytes: processed?.bytes.count ?? 0, physicalMemory: physicalMemory)
    }

    /// Takes new stage settings: the shown pattern is re-drawn when processed; "The scan's mean" starts its pass when it has not run.
    package func setPipeline(_ new: PatternPipeline) {
        guard new != pipeline else { return }
        pipeline = new
        if new.staticStage.isOn, new.staticStage.source == .mean, scanMeanBackground == nil, !isComputingMean, let document { startMean(document) }
        if patternDisplay == .processed { showPattern(at: pinned) }
    }

    /// Edits the pipeline in place (one stage's row).
    package func editPipeline(_ change: (inout PatternPipeline) -> Void) {
        var p = pipeline
        change(&p)
        setPipeline(p)
    }

    package func setPatternDisplay(_ display: PatternDisplay) {
        guard display != patternDisplay else { return }
        patternDisplay = display
        if document != nil { showPattern(at: pinned) }
    }

    /// The room's verb: the whole scan through the pipeline, off the main actor, with progress; Stop (⌘.) ends it and keeps the last run.
    /// The returned task ends when the run has landed (or was refused or stopped). Each run lands only while it is the latest
    /// (`processRun`), so a stopped run never lands over the one started after it; and a run starts computing only once the run before
    /// it has ended, so a stopped run still finishing its row or tile never shares the cores and the memory with the new one.
    @discardableResult
    package func process() -> Task<Void, Never> {
        guard let document, !isBusy else { return Task {} }
        if let refusal = processingRefusal ?? processAdmission {
            onEvent?("Process: \(refusal.sentence)")
            return Task {}
        }
        let gen = generation
        processRun += 1
        let runID = processRun
        let pipeline = self.pipeline
        let background = staticBackground
        let access = document.access
        isProcessing = true
        processProgress = 0
        onEvent?("Processing \(document.dataset.patternCount) patterns…")
        let previous = processTask
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            if let previous { await previous.value }
            let started = Date()
            // Stop cancels this task, and the handler raises the flag the pipeline asks: NLPAR asks it on worker threads that run no
            // task, where `Task.isCancelled` is always false.
            let stopped = CancellationFlag()
            do {
                // NLPAR's λ travels with this run's result, so a stopped run never hands its λ to the run that stays.
                var chosenLambda: Double?
                let result = try await withTaskCancellationHandler {
                    try pipeline.process(access, background: background, progress: { f in
                        Task { @MainActor in self?.landProcessProgress(f, generation: gen, processRun: runID) }
                    }, isCancelled: { stopped.isRaised }, lambda: { chosenLambda = $0 })
                } onCancel: {
                    stopped.raise()
                }
                await self?.landProcessed(result, with: pipeline, lambda: chosenLambda, failure: nil, seconds: Date().timeIntervalSince(started),
                                          generation: gen, processRun: runID)
            } catch {
                let words = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                await self?.landProcessed(nil, with: pipeline, lambda: nil, failure: words, seconds: 0, generation: gen, processRun: runID)
            }
        }
        processTask = task
        return Task { await task.value }
    }

    private func landProcessProgress(_ f: Double, generation gen: Int, processRun runID: Int) {
        guard gen == generation, runID == processRun, isProcessing else { return }
        processProgress = f
    }

    private func landProcessed(_ result: EBSDMemoryPatterns?, with run: PatternPipeline, lambda: Double?, failure: String?, seconds: Double,
                               generation gen: Int, processRun runID: Int) {
        guard gen == generation, runID == processRun, isProcessing else { return }
        isProcessing = false
        if let result {
            processed = result
            processedWith = run
            nlparLambda = lambda
            processProgress = 1
            let mb = Double(result.bytes.count) / 1_000_000
            let nlpar = run.nlpar.isOn ? lambda.map { " · NLPAR λ \(SessionEventFormat.fixed($0, 3))" } ?? "" : ""
            onEvent?("Processed \(result.dataset.patternCount) patterns in \(SessionEventFormat.fixed(seconds, 1)) s · \(SessionEventFormat.fixed(mb, 1)) MB in memory"
                + nlpar)
            // Already showing Processed: re-draw, so the pane trades the one-pattern preview for the run (the whole-scan stages show).
            if patternDisplay == .processed { showPattern(at: pinned) } else { setPatternDisplay(.processed) }
        } else if let failure {
            onEvent?("Error: \(failure)")
        }
    }

    /// The scan's mean in its own pass, when the source is switched to it after the map's pass (or the patterns cannot be summed, which
    /// it says at once, with the reason). A stopped pass lands nothing.
    private func startMean(_ document: Document) {
        let gen = generation
        isComputingMean = true
        let access = document.access
        meanTask = Task.detached(priority: .userInitiated) { [weak self] in
            let mean: FormatoArray?
            let failure: String?
            do {
                guard let summed = try PatternPipeline.meanBackground(access, isCancelled: { Task.isCancelled }) else { return }
                mean = summed
                failure = nil
            } catch {
                mean = nil
                failure = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            await self?.landMean(mean, failure: failure, generation: gen)
        }
    }

    /// The scan's mean landed, or could not be made: then the status line says so with the reader's or the stage's sentence (`failure`).
    private func landMean(_ mean: FormatoArray?, failure: String?, generation gen: Int) {
        guard gen == generation else { return }
        isComputingMean = false
        scanMeanBackground = mean
        if mean == nil { onEvent?("The scan's mean pattern could not be computed" + (failure.map { ": " + $0 } ?? ".")) }
        if patternDisplay == .processed { showPattern(at: pinned) }
    }

    // MARK: The position

    /// The picked position: where the marker stands and what the pattern pane shows. The pointer over the map picks nothing (D-SEM-110).
    package private(set) var pinned = EBSDPosition.origin

    // MARK: The pictures

    /// The pattern on screen and the position it is of (the pane keeps the last pattern until the next one arrives: never a blank).
    package private(set) var patternPosition: EBSDPosition?
    package let patternPresentation = ImagePresentation()
    /// How the map is drawn; its canvas is the mean map once it has landed. It opens on its 1st to 99th percentile, as a map does.
    package let mapPresentation: ImagePresentation = {
        let presentation = ImagePresentation()
        presentation.defaultQuantiles = 0.01...0.99
        return presentation
    }()

    /// The infobar's line for an event ("Opening…", "Opened…") and the alert for a failure (the window's `AppState` wires them).
    package var onEvent: ((String) -> Void)?
    package var onFailure: ((any Error) -> Void)?
    /// A dataset was bound, and one was closed: the Indexing room starts over on the dataset (`IndexingSession`), and the Maps room
    /// shows the dataset's crystal map beside its patterns (`OrientationMapSession`).
    package var onBind: ((Document) -> Void)?
    package var onClose: (() -> Void)?

    @ObservationIgnored private var openTask: Task<Void, Never>?
    @ObservationIgnored private var mapTask: Task<Void, Never>?
    @ObservationIgnored private var qualityTask: Task<Void, Never>?
    @ObservationIgnored private var patternTask: Task<Void, Never>?
    @ObservationIgnored private var processTask: Task<Void, Never>?
    @ObservationIgnored private var meanTask: Task<Void, Never>?
    /// The map's pass in flight also sums the patterns for the scan's mean (set at open for a file without a static background): the
    /// mean lands with the map, and a new grid's pass carries it on.
    @ObservationIgnored private var meanRidesMap = false
    /// The dataset's count: bind and close move it on, and the scan's mean, Process, the quality pass and the pattern reads land only
    /// for the dataset they started on.
    @ObservationIgnored private var generation = 0
    /// The virtual-image pass's own count: a new dataset or a new grid moves it on, and only the latest pass lands. Kept apart from
    /// `generation`, so a new grid never drops the scan's mean, Process or the quality pass.
    @ObservationIgnored private var mapGeneration = 0
    /// The processing run's own count: Process and Stop move it on, and a run's progress and result land only while it is the latest,
    /// so Stop then Process never lands the stopped run as the new one.
    @ObservationIgnored private var processRun = 0
    /// Raw patterns read so far, by map index, and their indices from the least recently shown to the most (`cacheOrder`): a cached
    /// pattern shown again moves to the end, and the front is let go while the patterns hold more than `cacheBudget` bytes. Emptied
    /// with every new dataset.
    @ObservationIgnored private var cache: [Int: FormatoArray] = [:]
    @ObservationIgnored private var cacheOrder: [Int] = []
    /// The bytes the cached patterns hold.
    @ObservationIgnored package private(set) var cacheBytes = 0
    /// The most the cached patterns may hold: 64 MB, which is 128 patterns of 512 x 512 uint16 or 26 of 1244 x 1024.
    package static let cacheBudget = 64 << 20

    package init() {}

    package var fileName: String { document?.fileName ?? "" }
    package var hasDataset: Bool { document != nil }
    package var isBusy: Bool { isOpening || isMapping || isQualityMapping || isProcessing || isComputingMean }
    package var dataset: EBSDDataset? { document?.dataset }

    /// The mean intensity at `position`, once the map has landed.
    package func meanIntensity(at position: EBSDPosition) -> Float? {
        guard let dataset = document?.dataset, let meanIntensities, position.isInside(rows: dataset.scanRows, columns: dataset.scanColumns) else { return nil }
        return meanIntensities[position.index(columns: dataset.scanColumns)]
    }

    /// The value of the map on screen at `position` with its name ("BSE", "r2 c1"), once the pass has landed; nil for the mean map (the
    /// readout carries the mean on its own) and for the colour mix.
    package func mapValue(at position: EBSDPosition) -> (label: String, value: Float)? {
        guard let dataset = document?.dataset, let image = chosenImage, position.isInside(rows: dataset.scanRows, columns: dataset.scanColumns) else { return nil }
        let label: String
        switch mapChoice {
        case .bse: label = "BSE"
        case .tile(let tile): label = tile.label
        case .imageQuality: label = "IQ"
        case .dotProduct: label = "ADP"
        case .mean, .mix: return nil
        }
        return (label, image[position.index(columns: dataset.scanColumns)])
    }

    /// The sum image `mapChoice` names, once landed.
    package var chosenImage: [Float]? {
        if mapChoice == .imageQuality || mapChoice == .dotProduct { return qualityImage }
        guard let virtualImages else { return nil }
        switch mapChoice {
        case .bse: return virtualImages.first
        case .tile(let tile):
            let k = virtualGrid.index(of: tile) + 1
            return k < virtualImages.count ? virtualImages[k] : nil
        case .imageQuality, .dotProduct: return qualityImage
        case .mean, .mix: return nil
        }
    }

    /// The quality map `mapChoice` names, once its pass has landed.
    private var qualityImage: [Float]? {
        switch mapChoice {
        case .imageQuality: imageQualityMap
        case .dotProduct: dotProductMap
        default: nil
        }
    }

    /// The tile image of `tile`, once landed.
    package func tileImage(_ tile: VirtualBSETile) -> [Float]? {
        guard let virtualImages else { return nil }
        let k = virtualGrid.index(of: tile) + 1
        return k < virtualImages.count ? virtualImages[k] : nil
    }

    /// Cuts the detector into `grid` and runs the pass again (the tiles and the colour mix are the new grid's).
    package func setVirtualGrid(_ grid: VirtualBSEGrid) {
        guard grid != virtualGrid, let document else { virtualGrid = grid; return }
        virtualGrid = grid
        virtualImages = nil
        mixTiles = [nil, nil, nil]
        mixRGBA = nil
        if case .tile = mapChoice { mapChoice = .mean }
        if mapChoice == .mix { mapChoice = .mean }
        mapGeneration += 1
        mapTask?.cancel()
        startMap(document)
    }

    /// Shows `choice` on the scan map (nothing changes until its image has landed; the mix needs its three tiles).
    package func showMap(_ choice: MapChoice) {
        mapChoice = choice
        if choice == .imageQuality || choice == .dotProduct, imageQualityMap == nil, !isQualityMapping, let document { startQuality(document) }
        remakeMap()
    }

    /// Picks `tile` (nil: none) for `channel` of the colour mix (0 red, 1 green, 2 blue); the map shows the mix once all three are picked.
    package func setMixTile(_ tile: VirtualBSETile?, channel: Int) {
        guard (0..<3).contains(channel) else { return }
        mixTiles[channel] = tile
        remakeMix()
        if mixRGBA != nil { mapChoice = .mix }
        remakeMap()
    }

    /// Whether the colour mix can be drawn: three tiles picked and the pass landed.
    package var hasMix: Bool { mixRGBA != nil }

    private func remakeMix() {
        guard let r = mixTiles[0], let g = mixTiles[1], let b = mixTiles[2],
              let red = tileImage(r), let green = tileImage(g), let blue = tileImage(b) else { mixRGBA = nil; return }
        let rgb = VirtualBSEImaging.rgb(red: red, green: green, blue: blue)
        guard !rgb.isEmpty else { mixRGBA = nil; return }
        var rgba = [UInt8](repeating: 255, count: red.count * 4)
        for i in 0..<red.count {
            rgba[4 * i] = rgb[3 * i]; rgba[4 * i + 1] = rgb[3 * i + 1]; rgba[4 * i + 2] = rgb[3 * i + 2]
        }
        mixRGBA = rgba
        mixVersion &+= 1
    }

    /// The map's canvas for `mapChoice`: the mean map, a sum image, or (for the mix, drawn from `mixRGBA`) the mean map's canvas underneath.
    private func remakeMap() {
        guard let dataset = document?.dataset else { return }
        let pixels: [Float]?
        switch mapChoice {
        case .mean, .mix: pixels = meanIntensities
        case .bse, .tile, .imageQuality, .dotProduct: pixels = chosenImage
        }
        if let pixels { mapPresentation.show(CanvasPixels.make(width: dataset.scanColumns, height: dataset.scanRows, pixels: pixels)) }
    }

    // MARK: Opening

    /// Opens the h5ebsd file at `url` (its first scan) off the main actor, then binds it. The returned task ends when the dataset is bound
    /// and the first pattern is on screen (the map's pass goes on).
    @discardableResult
    package func open(url: URL) -> Task<Void, Never> {
        openTask?.cancel()
        isOpening = true
        onEvent?("Opening \(url.lastPathComponent)…")
        let task = Task { [weak self] in
            do {
                let document = try await Self.read(url)
                guard let self, !Task.isCancelled else { return }
                self.isOpening = false
                await self.bind(document).value
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.isOpening = false
                if !(error is CancellationError) { self.onFailure?(error) }
            }
        }
        openTask = task
        return task
    }

    @concurrent
    nonisolated private static func read(_ url: URL) async throws -> Document {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let opened = try EBSDOpening.open(url: url)
        return Document(fileName: url.lastPathComponent, url: url, dataset: opened.dataset, access: opened.reader)
    }

    /// Starts the room over on `document`: the pinned position at the origin, the first pattern read, the map's pass started. The returned
    /// task ends when pattern (0, 0) is on screen.
    @discardableResult
    package func bind(_ document: Document) -> Task<Void, Never> {
        generation += 1
        mapGeneration += 1
        mapTask?.cancel(); patternTask?.cancel()
        self.document = document
        cache = [:]; cacheOrder = []; cacheBytes = 0
        pinned = .origin
        patternPosition = nil; meanIntensities = nil; mapFailure = nil; mapProgress = 0
        virtualImages = nil; mixTiles = [nil, nil, nil]; mixRGBA = nil; mapChoice = .mean
        qualityTask?.cancel(); imageQualityMap = nil; dotProductMap = nil; isQualityMapping = false; qualityProgress = 0
        resetOverlay()
        resetProcessing()
        onEvent?("Opened \(document.fileName) — \(EBSDBrowsing.capsuleDetail(document.dataset)), step \(UnitDisplay.number(document.dataset.stepX)) \(EBSDBrowsing.unitLabel(document.dataset.scanUnit))")
        startMap(document)
        onBind?(document)
        return showPattern(at: .origin)
    }

    /// Ends the open, the map's pass, the scan's mean or the processing run in flight; what has landed stays (a stopped run keeps the last
    /// complete one, and never lands itself, even after a new run has started). A stopped run's work ends at its next row or tile, NLPAR's
    /// and neighbour averaging's included. A stopped mean is summed again when a stage is edited.
    package func stop() {
        if isOpening { openTask?.cancel(); isOpening = false; onEvent?("Stopped opening") }
        if isMapping { mapTask?.cancel(); isMapping = false; mapFailure = "The map's pass was stopped." }
        if isComputingMean {
            meanTask?.cancel()
            meanRidesMap = false
            isComputingMean = false
            onEvent?("Stopped the scan's mean pattern")
        }
        if isQualityMapping { qualityTask?.cancel(); isQualityMapping = false; onEvent?("Stopped the quality maps") }
        if isProcessing {
            processRun += 1
            processTask?.cancel()
            isProcessing = false
            onEvent?("Stopped processing; the last complete run stays")
        }
    }

    /// Starts processing over for a new dataset (bind, before the map's pass starts): a file without a static background has its mean
    /// summed in the map's pass, so it is read once; patterns that cannot be summed go to the mean's own pass, which says so at once.
    private func resetProcessing() {
        processTask?.cancel(); meanTask?.cancel()
        processed = nil; processedWith = nil; isProcessing = false; processProgress = 0; nlparLambda = nil
        scanMeanBackground = nil; isComputingMean = false; meanRidesMap = false; patternIsProcessed = false; previewFailure = nil
        patternDisplay = .raw
        pipeline = .roomDefault
        if document?.dataset.staticBackground == nil { pipeline.staticStage.source = .mean }
        guard pipeline.staticStage.source == .mean, let document else { return }
        do {
            try PatternPipeline.checkMeanBackground(document.dataset)
            meanRidesMap = true
            isComputingMean = true
        } catch {
            startMean(document)
        }
    }

    /// Closes the dataset: the room goes back to its door.
    package func close() {
        generation += 1
        mapGeneration += 1
        openTask?.cancel(); mapTask?.cancel(); patternTask?.cancel()
        isOpening = false; isMapping = false
        document = nil; cache = [:]; cacheOrder = []; cacheBytes = 0
        meanIntensities = nil; mapFailure = nil; patternPosition = nil; pinned = .origin
        virtualImages = nil; mixTiles = [nil, nil, nil]; mixRGBA = nil; mapChoice = .mean
        qualityTask?.cancel(); imageQualityMap = nil; dotProductMap = nil; isQualityMapping = false; qualityProgress = 0; showsTiles = false
        processTask?.cancel(); meanTask?.cancel()
        processed = nil; processedWith = nil; isProcessing = false; processProgress = 0; nlparLambda = nil
        scanMeanBackground = nil; isComputingMean = false; meanRidesMap = false; patternIsProcessed = false; previewFailure = nil
        patternDisplay = .raw; pipeline = .roomDefault
        resetOverlay()
        onClose?()
    }

    // MARK: The map

    /// One pass over the scan in rows (`VirtualBSEImaging.imagesAndPatternSum`): the whole detector's sum and every tile of `virtualGrid`;
    /// the mean map is the whole sum over the pattern's pixels (`EBSDBrowsing.meanIntensityMap`'s number, tested against it). While the
    /// scan's mean rides on the pass (`meanRidesMap`), it sums the patterns too and the mean lands with the map.
    private func startMap(_ document: Document) {
        let gen = mapGeneration
        isMapping = true
        mapProgress = 0
        mapFailure = nil
        let access = document.access
        let dataset = document.dataset
        let sumsPatterns = meanRidesMap
        let rects = [DetectorRect(top: 0, bottom: dataset.patternRows, left: 0, right: dataset.patternColumns)]
            + virtualGrid.rects(patternRows: dataset.patternRows, patternColumns: dataset.patternColumns)
        mapTask = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let pass = try VirtualBSEImaging.imagesAndPatternSum(access, rects: rects, sumsPatterns: sumsPatterns, progress: { f in
                    Task { @MainActor in self?.landMapProgress(f, mapGeneration: gen) }
                }, isCancelled: { Task.isCancelled })
                guard let pass else { return }
                let sums = pass.images
                let pixels = Double(max(dataset.patternPixels, 1))
                let mean = sums[0].map { Float($0 / pixels) }
                let images = sums.map { $0.map(Float.init) }
                var scanMean: FormatoArray?
                var meanFailure: String?
                if let patternSum = pass.patternSum {
                    do {
                        scanMean = try PatternPipeline.meanBackground(sum: patternSum, of: dataset)
                    } catch {
                        meanFailure = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    }
                }
                await self?.landMap(mean, images: images, scanMean: scanMean, meanFailure: meanFailure, failure: nil, mapGeneration: gen)
            } catch {
                let words = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                await self?.landMap(nil, images: nil, scanMean: nil, meanFailure: nil, failure: words, mapGeneration: gen)
            }
        }
    }

    /// The quality pass (`PatternQuality.maps`): both maps in one detached task that lands only for the dataset it started on.
    private func startQuality(_ document: Document) {
        let gen = generation
        isQualityMapping = true
        qualityProgress = 0
        let access = document.access
        qualityTask = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let maps = try await PatternQuality.maps(of: access, progress: { f in
                    Task { @MainActor in self?.landQualityProgress(f, generation: gen) }
                })
                await self?.landQuality(maps.imageQuality.map(Float.init), maps.dotProduct.map(Float.init), failure: nil, generation: gen)
            } catch is CancellationError {
                return
            } catch {
                let words = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                await self?.landQuality(nil, nil, failure: words, generation: gen)
            }
        }
    }

    private func landQualityProgress(_ f: Double, generation gen: Int) {
        guard gen == generation, isQualityMapping else { return }
        qualityProgress = f
    }

    private func landQuality(_ iq: [Float]?, _ adp: [Float]?, failure: String?, generation gen: Int) {
        guard gen == generation else { return }
        isQualityMapping = false
        if let iq, let adp {
            imageQualityMap = iq
            dotProductMap = adp
            qualityProgress = 1
            remakeMap()
        } else if let failure {
            onEvent?("Error: \(failure)")
        }
    }

    private func landMapProgress(_ f: Double, mapGeneration gen: Int) {
        guard gen == mapGeneration, isMapping else { return }
        mapProgress = f
    }

    /// The map's pass landed (or failed); the scan's mean that rode on it lands with it (or `meanFailure` says why it could not be made),
    /// or stops computing when the pass failed (the map's error says why). A stopped mean (`stop()` lowered `meanRidesMap`) does not land.
    private func landMap(_ map: [Float]?, images: [[Float]]?, scanMean: FormatoArray?, meanFailure: String?, failure: String?,
                         mapGeneration gen: Int) {
        guard gen == mapGeneration else { return }
        isMapping = false
        mapProgress = map == nil ? mapProgress : 1
        if let map, let images {
            meanIntensities = map
            virtualImages = images
            remakeMix()
            remakeMap()
        } else if let failure {
            mapFailure = failure
            onEvent?("Error: \(failure)")
        }
        guard meanRidesMap else { return }
        meanRidesMap = false
        if map != nil {
            landMean(scanMean, failure: meanFailure, generation: generation)
        } else {
            isComputingMean = false
        }
    }

    // MARK: The position

    /// Picks `position` (a click or a drag on the map, an arrow key, a Results row), held inside the scan: the marker moves and the
    /// pattern pane shows it. The returned task ends when that pattern is on screen (the read in flight when the pick is the same one).
    @discardableResult
    package func pin(_ position: EBSDPosition) -> Task<Void, Never> {
        guard let dataset = document?.dataset else { return Task {} }
        let clamped = position.clamped(rows: dataset.scanRows, columns: dataset.scanColumns)
        guard clamped != pinned else { return patternTask ?? Task {} }
        pinned = clamped
        return showPattern(at: clamped)
    }

    /// An arrow key: the pinned position moves `by` positions, held inside the scan.
    package func step(_ direction: EBSDPosition.Direction, by count: Int = 1) {
        guard let dataset = document?.dataset else { return }
        pin(pinned.stepped(direction, by: count, rows: dataset.scanRows, columns: dataset.scanColumns))
    }

    // MARK: The pattern

    /// Shows the pattern at `position`, raw or through the pipeline (`patternDisplay`): a cached raw pattern shown raw lands at once, else
    /// the read and the processing run in a task that the next request cancels. The returned task ends when the pattern is on screen.
    @discardableResult
    private func showPattern(at position: EBSDPosition) -> Task<Void, Never> {
        patternTask?.cancel()
        guard let document else { return Task {} }
        let index = position.index(columns: document.dataset.scanColumns)
        let pipeline: PatternPipeline? = patternDisplay == .processed && processingRefusal == nil ? self.pipeline : nil
        let background = staticBackground
        if patternDisplay == .processed, let refusal = processingRefusal { previewFailure = refusal.sentence } else { previewFailure = nil }
        // The scan's own run when it is current: the only way to see NLPAR, which needs the neighbours.
        if patternDisplay == .processed, let processed, processedWith == self.pipeline,
           let one = try? processed.pattern(row: position.row, column: position.column) {
            patternPresentation.show(Self.canvas(one))
            patternPosition = position
            patternIsProcessed = true
            previewFailure = nil
            return Task {}
        }
        let cached = cache[index]
        if cached != nil { touch(index) }
        if let cached, pipeline == nil {
            patternPresentation.show(Self.canvas(cached))
            patternPosition = position
            patternIsProcessed = false
            return Task {}
        }
        let gen = generation
        let access = document.access
        let task = Task { [weak self] in
            do {
                let (raw, shown) = try await Self.readPattern(access, position: position, cached: cached, pipeline: pipeline, background: background)
                guard let self, !Task.isCancelled, gen == self.generation else { return }
                if cached == nil { self.remember(raw, at: index) }
                self.patternPresentation.show(Self.canvas(shown))
                self.patternPosition = position
                self.patternIsProcessed = pipeline != nil
            } catch {
                guard let self, !Task.isCancelled, gen == self.generation, !(error is CancellationError) else { return }
                if pipeline != nil {
                    // The stage's sentence under the rows; the pane keeps the raw pattern.
                    self.previewFailure = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    if let cached = self.cache[index] ?? cached {
                        self.patternPresentation.show(Self.canvas(cached)); self.patternPosition = position; self.patternIsProcessed = false
                    }
                } else {
                    self.onFailure?(error)
                }
            }
        }
        patternTask = task
        return task
    }

    @concurrent
    nonisolated private static func readPattern(_ access: any EBSDPatternAccess, position: EBSDPosition, cached: FormatoArray?,
                                                pipeline: PatternPipeline?, background: FormatoArray?) async throws -> (raw: FormatoArray, shown: FormatoArray) {
        let raw = try cached ?? access.pattern(row: position.row, column: position.column)
        try Task.checkCancellation()
        guard let pipeline else { return (raw, raw) }
        let dataset = access.dataset
        return (raw, try pipeline.apply(raw, rows: dataset.patternRows, columns: dataset.patternColumns, background: background))
    }

    nonisolated private static func canvas(_ pattern: FormatoArray) -> CanvasPixels {
        let rows = pattern.shape.count == 2 ? pattern.shape[0] : 1
        let columns = pattern.shape.last ?? pattern.count
        return CanvasPixels.make(width: columns, height: rows, pixels: EBSDBrowsing.pixels(pattern))
    }

    /// Keeps `pattern` as the most recently shown, then lets the least recently shown go while the cache holds more than `cacheBudget`
    /// bytes. The pattern just read always stays, so one larger than the budget is the cache's only entry.
    private func remember(_ pattern: FormatoArray, at index: Int) {
        if let replaced = cache[index] {
            cacheBytes -= replaced.bytes.count
            cacheOrder.removeAll { $0 == index }
        }
        cache[index] = pattern
        cacheOrder.append(index)
        cacheBytes += pattern.bytes.count
        var dropped = 0
        while cacheBytes > Self.cacheBudget, dropped < cacheOrder.count - 1 {
            let oldest = cacheOrder[dropped]
            cacheBytes -= cache[oldest]?.bytes.count ?? 0
            cache[oldest] = nil
            dropped += 1
        }
        cacheOrder.removeFirst(dropped)
    }

    /// The cached pattern at `index` is shown again: it becomes the most recently shown, the last to be let go.
    private func touch(_ index: Int) {
        guard cacheOrder.last != index, let place = cacheOrder.firstIndex(of: index) else { return }
        cacheOrder.remove(at: place)
        cacheOrder.append(index)
    }
}
