//
//  EELSSession.swift
//  Role: the one owner of the EELS room's state: the opened low-loss spectrum image, the zero-loss choice, the mean free path
//        choice, and what the last pass put on screen (the t/λ map and its tiles). The room's views read it; they hold none of it.
//
//  Nothing here makes a number. `TEMCore/EELS/EELSCompute` is SpectroKit's `EELSThickness.logRatio` called with the room's
//  choices; this owner decides WHEN to ask: every pass runs in a detached task and lands only if no newer request was made
//  meanwhile (`generation`), as `EDXSession` does. The map is badged `validation: none`.
//

import Foundation
import Observation
import SpectroCore
import SpectroEDX
import SpectroEELS
import TEMCore
import ShellEDXModel

@Observable
package final class EELSSession {

    // MARK: The spectrum image

    package private(set) var source: LoadedEELS?
    package private(set) var isOpening = false

    // MARK: The choices

    package private(set) var threshold: EELSThresholdChoice = .estimated
    package private(set) var meanFreePath: EELSMeanFreePathChoice = .none
    /// Typed for a file that does not state E0 (the Iakoubovskii route needs it).
    package private(set) var typedBeamEnergyKeV: Double?

    // MARK: What the last pass put on screen

    package private(set) var map: ThicknessMap?
    /// The zero-loss alignment (`EELSAlignment.alignZeroLossPeak`): the aligned low loss (and core loss), and the shifts. Nil until Align has run;
    /// from then the thickness map and the edge model work on the aligned cubes.
    package private(set) var alignment: ZeroLossAlignment?
    /// Bumped whenever the cube the stages work on changes (a new file, an alignment): a map made from an older one is stale.
    @ObservationIgnored private var inputVersion = 0
    package private(set) var mapInputVersion = 0
    /// What the map on screen was made from (the cube, the threshold, the λ choice and the beam energy it used); a different one is stale.
    package private(set) var mapSignature = ""
    // The edge model (Edges and Fit stages)
    package private(set) var pickedEdges: [CoreLossEdge] = []
    package private(set) var convolveLowLoss = true
    /// The Fitting section's model: the exact per-edge fit, or MLLS.
    package private(set) var fitModel: EELSFitModel = .exactNNLS
    /// The elements picked "Fit only": their edges stay in the fit model, their amounts stay out of the composition.
    package private(set) var fitOnlyElements: Set<String> = []
    package private(set) var model: EELSFitResult?
    package private(set) var modelComposition: [EELSCompositionPixel]?
    /// The deconvolution the fit on screen was made on (Fourier-ratio only; nil when the fit took the stored core loss).
    package private(set) var modelDeconvolution: EELSDeconvolutionResult?
    /// The whole map's summed spectra fitted as one pixel: the region table's numbers (the stable ones; the maps' per-pixel numbers are the second estimator).
    package private(set) var regionModel: EELSFitResult?
    /// How well `regionModel` fits the whole map's summed core loss (the kit's RSS, Pearson's χ²/dof).
    package private(set) var regionQuality: EELSFitQuality?
    /// The Fitting section's Fit to: the last energy of the MLLS window, included; nil is the axis end. The exact fit uses its signal windows instead.
    package private(set) var fitToEV: Double?
    /// The sentence for a Fit to the room refused (the axis end is used).
    package private(set) var fitToNotice: String?
    // The Deconvolve stage
    package private(set) var deconvolutionChoice: EELSDeconvolutionChoice = .off
    /// What the stage made last (kept, dimmed as stale, when its inputs change); nil until it ran.
    package private(set) var deconvolution: EELSDeconvolutionResult?
    @ObservationIgnored private var deconvolutionSignature = ""
    /// The sentence for a method this file cannot take (the control stays where it was).
    package private(set) var deconvolutionNotice: String?
    package private(set) var regionComposition: [EELSCompositionPixel]?
    package private(set) var modelTiles: [EELSMapTile] = []
    /// What the fit on screen was made from; a different one is stale.
    @ObservationIgnored private var modelSignature = ""
    @ObservationIgnored private var modelVersion = 0
    package private(set) var typedConvergenceMrad: Double?
    package private(set) var typedCollectionMrad: Double?
    // Slice 2: the windows per edge, the background choice and the reference spectra.
    /// The background and signal windows the person moved, by the id of the group's master edge (`EELSWindowPlan.Entry.key`); a group not in it has the kit's defaults
    /// (`EdgeWindows.defaults`, squeezed by its neighbours).
    package private(set) var editedWindows: [String: EELSEdgeWindows] = [:]
    /// The Fitting section's background; only the power law is live in the kit, a request for another is refused with its reason (`backgroundNotice`).
    package private(set) var backgroundChoice: EELSBackgroundChoice = .powerLaw
    package private(set) var backgroundNotice: String?
    /// The sentence for a fit the kit refused because of a window (overlap, a window that is not on the axis or too narrow); the fit did not run. Cleared by the next
    /// window change, pick or fit.
    package private(set) var fitRefusal: String?
    package private(set) var references: [EELSReference] = []
    package private(set) var referenceNotice: String?
    /// Where the working core loss's summed spectrum holds no counts (a detector range that ends); a signal window on one is refused by name.
    package private(set) var coreDeadStretches: [ClosedRange<Double>] = []
    @ObservationIgnored private var deadTask: Task<Void, Never>?
    /// Where the zero-loss peak sat before Align moved it (a diagnostic tile beside the map's own ZLP centre, which is after): nil until Align has run.
    package private(set) var alignmentTile: EELSMapTile?
    /// The shift Align applied at each pixel, as a tile (the room's ZLP segment and the tile beside the anchor): nil until Align has run.
    package private(set) var alignmentShiftTile: EELSMapTile?
    /// The spectrum plot of the selected region, or of the whole map: the summed low loss and core loss and, after Fit, the kit's model (made off the main actor).
    package private(set) var plot: EELSPlotData?
    /// The whole map's spectrum (no fit), drawn in grey under a selected region's so the region reads against the whole (Paul's drive, 2026-10-23).
    package private(set) var wholeMapPlot: EELSPlotData?
    @ObservationIgnored private var fitUsed: EELSPlotFit?
    @ObservationIgnored private var plotTask: Task<Void, Never>?
    @ObservationIgnored private var plotRun = 0
    /// The live spectrum of a drag (`previewRegion`): the running sum, the shape waiting for it, and whether the plot shows a preview.
    @ObservationIgnored private var previewTask: Task<Void, Never>?
    @ObservationIgnored private var pendingPreview: EDXRegion?
    @ObservationIgnored private var previewDone = true
    @ObservationIgnored private var isPreviewing = false
    package private(set) var tiles: [EELSMapTile] = []
    // Regions and lines drawn on the maps (design 2026-10-22 §2.1): kept as the EDX room keeps them (EDXPin, EDXLine), with the summed low-loss spectrum of
    // each visible region for the plot's layers and each region's row for the Table tab.
    package private(set) var pins: [EDXPin] = []
    package private(set) var selectedPinID: EDXPin.ID?
    package private(set) var lines: [EDXLine] = []
    package private(set) var selectedLineID: EDXLine.ID?
    package private(set) var pinSpectra: [EDXPin.ID: [Double]] = [:]
    /// The summed core loss of each visible region, on the working core loss's axis (the plot's `core`), drawn over the selected region's spectrum.
    package private(set) var pinCoreSpectra: [EDXPin.ID: [Double]] = [:]
    package private(set) var pinRows: [EELSRegionRow] = []
    /// True while the regions' rows are being summed and fitted again: `pinRows` still holds the previous ones (the Results room lists none meanwhile).
    package private(set) var isRefreshingRegions = false
    /// What the regions' rows were made from: the thickness inputs and the fit inputs at the time (`thicknessSignature`, `fitSignature`).
    package private(set) var pinRowsThicknessSignature = ""
    package private(set) var pinRowsFitSignature = ""
    @ObservationIgnored private var colorsIssued = 0
    @ObservationIgnored private var regionsIssued = 0
    @ObservationIgnored private var linesIssued = 0
    @ObservationIgnored private var pinDataTask: Task<Void, Never>?
    @ObservationIgnored private var pinDataRun = 0
    package private(set) var isComputing = false
    package private(set) var progress = 0.0
    package private(set) var failure: String?
    /// Why pixels have no t/λ and how many, from the map on screen (made once when a map lands).
    package private(set) var unavailableReasons: [EELSCompute.UnavailableReason] = []

    /// The infobar's events and the errors the person must see; set by the window.
    @ObservationIgnored package var onEvent: ((String) -> Void)?
    @ObservationIgnored package var onFailure: ((any Error) -> Void)?

    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var passTask: Task<Void, Never>?
    @ObservationIgnored private var openTask: Task<Void, Never>?
    @ObservationIgnored private var version = 0

    package init() {}

    // MARK: Derived

    package var hasImage: Bool { source != nil }
    /// The low loss the thickness map is made from: the aligned one once Align has run.
    package var workingLowLoss: LowLossSpectrumImage? { alignment?.aligned ?? source?.image }
    /// The core loss the edge model fits: the aligned one once Align has run.
    package var workingCoreLoss: CoreLossSpectrumImage? { alignment?.alsoAligned.first ?? source?.coreLoss }

    /// Whether the low loss holds the zero-loss peak (its energy window contains 0 eV).
    package var hasLowLoss: Bool {
        guard let image = source?.image else { return false }
        return image.energyOffsetEV <= 0 && image.energy(ofChannel: image.channels - 1) >= 0
    }
    /// A file whose only cube is a core loss: no t/λ, no t, no zero-loss peak to align (the room's "only core loss" state).
    package var onlyCoreLoss: Bool { hasImage && !hasLowLoss && source?.coreLoss == nil }
    package var selectedPin: EDXPin? { selectedPinID.flatMap { id in pins.first { $0.id == id } } }

    package var fileName: String { source?.fileName ?? "" }
    /// The open file's path as it was read ("" for a document made in memory).
    package var filePath: String { source?.filePath ?? "" }
    /// The file's scan pixel size and its unit, when it states one (the EDS room's `scanPixel`): the maps' scale bars and the maps export draw from it.
    package var scanPixel: (size: Double, unit: String)? {
        guard let size = source?.scanPixelSize, size > 0, let unit = source?.scanPixelUnit, !unit.isEmpty else { return nil }
        return (size, unit)
    }
    package var beamEnergyKeV: Double? { typedBeamEnergyKeV ?? source?.beamEnergyKeV }
    package var isBusy: Bool { isOpening || isComputing }
    package var exportStem: String { (fileName as NSString).deletingPathExtension + " thickness" }

    // MARK: Stages (design 2026-10-22: state on sections and the header readout, never blanking a result)

    package var alignState: EELSStageState { alignment == nil ? .notRun : .current }
    package var thicknessState: EELSStageState {
        map == nil ? .notRun : (mapInputVersion == inputVersion && mapSignature == thicknessSignature ? .current : .stale)
    }
    /// The thickness inputs now: the cube, the threshold, the λ choice and, for Iakoubovskii's λ, the beam energy. A map made from other ones is
    /// stale (a pass that was stopped, or refused, leaves the previous map on screen).
    package var thicknessSignature: String {
        let beam: String = if case .iakoubovskii = meanFreePath { "\(beamEnergyKeV.map { "\($0)" } ?? "-")" } else { "-" }
        return "\(inputVersion)|\(threshold)|\(meanFreePath)|\(beam)"
    }
    /// The fit inputs now (`currentSignature`): a fit or a region row made from other ones is stale.
    package var fitSignature: String { currentSignature }
    /// Whether the regions' rows were made from the inputs now: their t/λ from the thickness inputs, their edges from the fit on screen.
    package var pinRowsThicknessCurrent: Bool { !isRefreshingRegions && pinRowsThicknessSignature == thicknessSignature }
    package var pinRowsFitCurrent: Bool { !isRefreshingRegions && fitState == .current && pinRowsFitSignature == modelSignature }
    package var edgesState: EELSStageState { pickedEdges.isEmpty ? .notRun : .current }
    package var fitState: EELSStageState { model == nil ? .notRun : (modelSignature == currentSignature ? .current : .stale) }
    /// The Deconvolve stage: current when its result was made from the inputs now (the cubes, the thresholds, the method); always current when Off.
    package var deconvolveState: EELSStageState {
        if deconvolutionChoice == .off { return .current }
        guard deconvolution != nil else { return .notRun }
        return deconvolutionSignature == currentDeconvolutionSignature ? .current : .stale
    }
    /// What a deconvolution made now would be made from: the cubes, the threshold (it cuts the zero-loss peaks and Fourier-ratio's I₀) and the method.
    /// λ and the beam energy enter no deconvolution.
    private var currentDeconvolutionSignature: String { "\(inputVersion)|\(threshold)|\(deconvolutionChoice)" }
    /// The stages in order; Deconvolve is listed only when a method is chosen.
    package var stages: [(stage: EELSStage, state: EELSStageState)] {
        var out: [(stage: EELSStage, state: EELSStageState)] = [(.align, alignState), (.thickness, thicknessState)]
        if deconvolutionChoice != .off { out.append((.deconvolve, deconvolveState)) }
        return out + [(.edges, edgesState), (.fit, fitState)]
    }

    /// The core loss the spectrum shows: the Fourier-ratio deconvolved one once the stage made it, else the working core loss.
    package var shownCoreLoss: CoreLossSpectrumImage? {
        if deconvolutionChoice.feedsTheFit, let core = deconvolution?.coreLoss { return core }
        return workingCoreLoss
    }
    /// The pixels of `shownCoreLoss` the kit answered, when it is a deconvolved one (nil: every pixel).
    package var shownAnswered: PixelMask? {
        guard deconvolutionChoice.feedsTheFit, let d = deconvolution, d.coreLoss != nil else { return nil }
        return d.answered
    }
    /// The core loss the fit takes: the current Fourier-ratio result when that is the method (nil until it is current), else the working core loss.
    package var fitCoreLoss: CoreLossSpectrumImage? {
        guard deconvolutionChoice.feedsTheFit else { return workingCoreLoss }
        return deconvolveState == .current ? deconvolution?.coreLoss : nil
    }
    /// Convolve with the low loss as the fit does it: never on a Fourier-ratio deconvolved core loss (the low loss is divided out already).
    package var effectiveConvolve: Bool { convolveLowLoss && !deconvolutionChoice.feedsTheFit && workingLowLoss != nil }

    /// Run does every stage that is not current, in order; nothing to do when all are. Fit joins them only when it can run.
    package var canRun: Bool {
        guard hasImage, !isBusy else { return false }
        return stages.contains { $0.stage.isRun && $0.state != .current && ($0.stage != .fit || fitBlockerBeforeDeconvolution == nil) }
    }

    /// The microscope the model needs: the beam energy (the file's or typed) and the two angles (the file's or typed); nil until all are known.
    package var microscope: EELSMicroscope? {
        guard let e0 = beamEnergyKeV, e0 > 0,
              let alpha = typedConvergenceMrad ?? source?.convergenceMrad, let beta = typedCollectionMrad ?? source?.collectionMrad, beta > 0 else { return nil }
        return EELSMicroscope(beamEnergyKeV: e0, convergenceMrad: alpha, collectionMrad: beta)
    }

    /// Why Fit cannot run, in a sentence, or nil.
    package var fitBlocker: String? {
        guard hasImage else { return nil }
        if workingCoreLoss == nil { return "This file holds no core-loss spectrum image to fit." }
        if pickedEdges.isEmpty { return "Pick at least one edge to fit." }
        if microscope == nil { return "Type the beam energy and the convergence and collection angles under Fitting." }
        if fittableEdges.isEmpty { return refusals.map(\.reason).joined(separator: "\n") }
        if deconvolutionChoice.feedsTheFit && fitCoreLoss == nil { return "Fourier-ratio is chosen: the fit takes the deconvolved core loss. Run deconvolves first." }
        return nil
    }

    /// Why Fit cannot run now, leaving out a deconvolution Run makes before it (Run does Deconvolve, then Fit).
    private var fitBlockerBeforeDeconvolution: String? {
        guard deconvolutionChoice.feedsTheFit, deconvolveState != .current else { return fitBlocker }
        guard hasImage else { return nil }
        if workingCoreLoss == nil { return "This file holds no core-loss spectrum image to fit." }
        if pickedEdges.isEmpty { return "Pick at least one edge to fit." }
        if microscope == nil { return "Type the beam energy and the convergence and collection angles under Fitting." }
        if fittableEdges.isEmpty { return refusals.map(\.reason).joined(separator: "\n") }
        return nil
    }

    /// The axis the windows are made for: the working core loss's (a large one before a file is open; no edge can be picked then).
    private var windowAxis: EnergyAxis {
        workingCoreLoss.map { EnergyAxis(offset: $0.energyOffsetEV, scale: $0.energyScaleEV, size: $0.channels) } ?? EnergyAxis(offset: 0, scale: 1, size: 100_000)
    }

    /// The windows of the picked edges as the kit takes them, one entry per group in onset order (an unpicked `edge` is planned as if it were picked).
    private func plan(including edge: CoreLossEdge? = nil) -> [EELSWindowPlan.Entry] {
        let edges = edge.map { pickedEdges.contains($0) ? pickedEdges : pickedEdges + [$0] } ?? pickedEdges
        return EELSWindowPlan.plan(for: edges, edited: editedWindows, axis: windowAxis)
    }

    /// The windows of an edge: the person's, else the kit's defaults.
    package func windows(for edge: CoreLossEdge) -> EELSEdgeWindows {
        plan(including: edge).first { $0.edges.contains(edge) }?.windows ?? EELSEdgeWindows(EdgeWindows.defaults(onsetEV: edge.onsetEV, family: edge.family, precedingSignalEndEV: nil, nextOnsetEV: nil, axis: windowAxis))
    }

    /// The windows handed to the kit's fit: one per fitted edge (the fittable picks, twins of one element and family are one), in onset order.
    package var fitWindows: [EdgeWindows] {
        let fittable = Set(fittableEdges.map { EELSFitCompute.id($0) })
        return plan().filter { entry in entry.edges.contains { fittable.contains(EELSFitCompute.id($0)) } }.map(\.windows.kit)
    }

    /// The picked edges whose signal window sits on a stretch with no counts, each with the sentence that names why it is not fitted.
    package var refusals: [(edge: CoreLossEdge, reason: String)] {
        pickedEdges.compactMap { edge in
            EELSDeadStretch.refusal(title: EELSFitCompute.title(edge), windows: windows(for: edge), stretches: coreDeadStretches).map { (edge, $0) }
        }
    }

    /// The picked edges the fit takes: all but the refused.
    package var fittableEdges: [CoreLossEdge] {
        let refused = Set(refusals.map { EELSFitCompute.id($0.edge) })
        return pickedEdges.filter { !refused.contains(EELSFitCompute.id($0)) }
    }

    /// The reason the λ estimate (Iakoubovskii) cannot be made now; nil when it can.
    package var lambdaEstimateBlocker: String? {
        guard let e0 = beamEnergyKeV, e0 > 0 else { return "The estimate needs the beam energy: the file does not state it. Type it under Fitting." }
        return nil
    }

    /// The edges the core loss can hold, to pick from.
    package var offeredEdges: [CoreLossEdge] { workingCoreLoss.map { EELSFitCompute.offeredEdges(in: $0) } ?? [] }

    private var currentSignature: String {
        let edges = fittableEdges.map { EELSFitCompute.id($0) }.joined(separator: ",")
        let m = microscope.map { "\($0.beamEnergyKeV)/\($0.convergenceMrad)/\($0.collectionMrad)" } ?? "-"
        // A Fourier-ratio fit is made from the stage's result: current only while that result is.
        let deconvolved = !deconvolutionChoice.feedsTheFit ? "-" : deconvolveState == .current ? deconvolutionSignature : "pending"
        let fitTo = fitModel == .mlls ? fitToEV.map { "\($0)" } ?? "end" : "-"
        return "\(inputVersion)|\(edges)|\(m)|\(effectiveConvolve)|\(fitModel)|\(fitTo)|\(deconvolved)|\(fitWindows.map { "\($0.backgroundEV.lowerBound)-\($0.backgroundEV.upperBound)/\($0.signalEV.lowerBound)-\($0.signalEV.upperBound)" }.joined(separator: ","))"
    }

    /// The Align section's readout: "offset −21.503 → 0.000 eV, 2041 of 2048 channels kept".
    package var alignmentReadout: String? {
        guard let alignment, let before = source?.image else { return nil }
        return EELSRoomFormat.alignmentReadout(offsetBefore: before.energyOffsetEV, offsetAfter: alignment.aligned.energyOffsetEV,
                                               kept: alignment.aligned.channels, of: before.channels)
            + " · " + EELSRoomFormat.shiftSummary(alignment.shiftEV, channelEV: before.energyScaleEV)
    }

    /// The tiles on screen: the map's, with the "before" zero-loss centre next to its own once Align has run.
    package var displayedTiles: [EELSMapTile] {
        var out = tiles
        if let before = alignmentTile {
            if let i = out.firstIndex(where: { $0.id == "zlpCentre" }) { out.insert(before, at: i) } else { out.append(before) }
        }
        return out + modelTiles
    }

    /// What the Maps control needs: the stages' states and what the session holds.
    package var mapsAvailability: EELSMapsAvailability {
        EELSMapsAvailability(alignState: alignState, thicknessState: thicknessState, fitState: fitState, hasMap: map != nil, hasLambda: map?.meanFreePathNM != nil,
                             hasFit: model != nil, hasComposition: modelComposition != nil, onlyCoreLoss: onlyCoreLoss, fitBlocker: model == nil ? fitBlocker : nil)
    }

    /// The edge rows of the results panel: the selected region's, else the whole map's summed fit.
    package var resultRows: [EELSEdgeRow] {
        if let pin = selectedPin { return pinRows.first { $0.id == pin.id }?.edges ?? [] }
        return regionRows
    }

    /// The fit quality of the results panel's rows: the selected region's, else the whole map's.
    package var resultQuality: EELSFitQuality? {
        if let pin = selectedPin { return pinRows.first { $0.id == pin.id }?.quality }
        return regionQuality
    }

    // MARK: Opening

    @discardableResult
    package func open(url: URL) -> Task<Void, Never> {
        openTask?.cancel()
        isOpening = true
        onEvent?("Opening \(url.lastPathComponent)…")
        let task = Task { [weak self] in
            do {
                let loaded = try await Self.read(url)
                guard let self, !Task.isCancelled else { return }
                self.isOpening = false
                await self.bind(loaded).value
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.isOpening = false
                if !(error is CancellationError) && !(error is SpectroCancelled) { self.onFailure?(error) }
            }
        }
        openTask = task
        return task
    }

    @concurrent
    nonisolated private static func read(_ url: URL) async throws -> LoadedEELS {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return try EELSOpening.open(url: url)
    }

    /// Starts the room over on `loaded` with the defaults (estimated threshold, no λ); the returned task ends when the first map has landed.
    @discardableResult
    package func bind(_ loaded: LoadedEELS) -> Task<Void, Never> {
        cancelPass()
        source = loaded
        threshold = .estimated; meanFreePath = .none; typedBeamEnergyKeV = nil
        alignment = nil; alignmentTile = nil; alignmentShiftTile = nil; inputVersion += 1; fitUsed = nil
        pickedEdges = []; model = nil; modelComposition = nil; regionModel = nil; regionComposition = nil; modelTiles = []; modelSignature = ""
        fitModel = .exactNNLS; fitOnlyElements = []; modelDeconvolution = nil; fitToEV = nil; fitToNotice = nil; regionQuality = nil
        deconvolutionChoice = .off; deconvolution = nil; deconvolutionSignature = ""; deconvolutionNotice = nil
        typedConvergenceMrad = nil; typedCollectionMrad = nil
        map = nil; tiles = []; unavailableReasons = []; failure = nil
        resetRegions()
        editedWindows = [:]; references = []; referenceNotice = nil; backgroundChoice = .powerLaw; backgroundNotice = nil; coreDeadStretches = []
        refreshDeadStretches()
        refreshPlot()
        onEvent?("Opened \(loaded.fileName) — \(loaded.image.nx) × \(loaded.image.ny) px, \(loaded.image.channels) channels")
        return refresh() ?? Task {}
    }

    package func close() {
        cancelPass()
        openTask?.cancel(); openTask = nil; isOpening = false
        plotTask?.cancel(); plot = nil; wholeMapPlot = nil; fitUsed = nil; alignmentShiftTile = nil
        deadTask?.cancel(); coreDeadStretches = []; editedWindows = [:]; references = []
        fitModel = .exactNNLS; fitOnlyElements = []; modelDeconvolution = nil; fitToEV = nil; fitToNotice = nil; regionQuality = nil
        deconvolutionChoice = .off; deconvolution = nil; deconvolutionSignature = ""; deconvolutionNotice = nil
        source = nil; alignment = nil; alignmentTile = nil; pickedEdges = []; model = nil; modelComposition = nil; regionModel = nil; regionComposition = nil; modelTiles = []; modelSignature = ""; map = nil; tiles = []; unavailableReasons = []; failure = nil
        resetRegions()
    }

    // MARK: Choices

    package func setThreshold(_ new: EELSThresholdChoice) {
        guard new != threshold else { return }
        threshold = new
        refresh()
    }

    package func setMeanFreePath(_ new: EELSMeanFreePathChoice) {
        guard new != meanFreePath else { return }
        meanFreePath = new
        refresh()
    }

    package func setBeamEnergy(_ keV: Double?) {
        guard keV != typedBeamEnergyKeV else { return }
        typedBeamEnergyKeV = keV
        if case .iakoubovskii = meanFreePath { refresh() }
    }

    // MARK: Pass

    private func cancelPass() {
        generation += 1
        passTask?.cancel(); passTask = nil
        isComputing = false
    }

    /// Stop: ends the pass; the kit stops at its next block and the previous map stays.
    package func stop() {
        guard isBusy else { return }
        openTask?.cancel(); openTask = nil; isOpening = false
        cancelPass()
        onEvent?("Stopped.")
    }

    @discardableResult
    private func refresh() -> Task<Void, Never>? {
        guard source != nil, let image = workingLowLoss else { return nil }
        passTask?.cancel()
        generation += 1
        let gen = generation
        let threshold = threshold, inputAtStart = inputVersion, signature = thicknessSignature
        let lambda: MeanFreePathSource?
        do { lambda = try EELSCompute.source(meanFreePath, beamEnergyKeV: beamEnergyKeV) } catch {
            failure = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            isComputing = false
            if let failure { onEvent?("Refused: \(failure)") }
            return nil
        }
        failure = nil
        isComputing = true
        progress = 0
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let interval = Signposts.begin("eels.map"); defer { Signposts.end(interval) }
                // One hop to the main actor per percent, not per callback (the kit reports at its own rate).
                let gate = ProgressGate()
                let map = try EELSCompute.map(image: image, threshold: threshold, meanFreePath: lambda, progress: { f in
                    guard gate.shouldReport(f) else { return }
                    Task { @MainActor in self?.landProgress(f, generation: gen) }
                })
                if Task.isCancelled { return }
                await self?.land(map, failure: nil, generation: gen, input: inputAtStart, signature: signature)
            } catch is SpectroCancelled {
                return
            } catch {
                if Task.isCancelled { return }
                await self?.land(nil, failure: (error as? LocalizedError)?.errorDescription ?? "\(error)", generation: gen, input: inputAtStart,
                                 signature: signature)
            }
        }
        passTask = task
        return task
    }

    private func landProgress(_ f: Double, generation gen: Int) {
        guard gen == generation, isComputing else { return }
        progress = f
    }

    private func land(_ new: ThicknessMap?, failure why: String?, generation gen: Int, input: Int, signature: String) {
        guard gen == generation else { return }
        isComputing = false
        progress = 1
        if let new {
            version += 1
            mapInputVersion = input
            mapSignature = signature
            map = new
            tiles = EELSCompute.tiles(new, version: version)
            unavailableReasons = EELSCompute.unavailableReasons(new)
            failure = nil
            refreshPinData()
        } else {
            failure = why   // the previous map stays
            if let why { onEvent?("Refused: \(why)") }
        }
    }

    /// Returns when no pass is in flight.
    package func settled() async {
        for _ in 0..<20 {
            let seen = generation
            await passTask?.value
            await pinDataTask?.value
            await plotTask?.value
            await previewTask?.value
            await deadTask?.value
            if generation == seen && !isComputing { return }
        }
    }

    // MARK: Edges and Model

    package func toggleEdge(_ edge: CoreLossEdge) {
        if let i = pickedEdges.firstIndex(of: edge) { pickedEdges.remove(at: i) } else { pickedEdges.append(edge) }
        pickedEdges.sort { $0.onsetEV < $1.onsetEV }
        fitRefusal = nil
        // An element with no edge left has no role.
        if fitOnlyElements.contains(edge.element), !pickedEdges.contains(where: { $0.element == edge.element }) { setFitOnly(edge.element, false) }
    }

    /// The periodic table's role: Fit only keeps the element's edges in the fit and its amount out of the composition. The fit is not run again: the
    /// composition, the at% tiles and the rows are made again from the fit on screen (and the regions' rows from theirs).
    package func setFitOnly(_ symbol: String, _ on: Bool) {
        guard fitOnlyElements.contains(symbol) != on else { return }
        if on { fitOnlyElements.insert(symbol) } else { fitOnlyElements.remove(symbol) }
        guard let model else { return }
        modelComposition = EELSFitCompute.composition(model, fitOnly: fitOnlyElements)
        regionComposition = regionModel.flatMap { EELSFitCompute.composition($0, fitOnly: fitOnlyElements) }
        modelVersion += 1
        modelTiles = EELSFitCompute.tiles(model, composition: modelComposition, fitOnly: fitOnlyElements, version: modelVersion)
        if !pins.isEmpty { refreshPinData() }
    }

    /// The Fitting section's model; Fit is stale until it runs again.
    package func setFitModel(_ new: EELSFitModel) { fitModel = new }

    /// The Fitting section's Fit to (MLLS): nil or zero is the axis end; a value at or under the last picked edge's onset, or past the axis end, is
    /// refused with its sentence and the axis end kept, as the EDS room's Fit to. Stales an MLLS fit.
    package func setFitTo(_ eV: Double?) {
        fitToNotice = nil
        guard let eV, eV.isFinite, eV != 0 else { fitToEV = nil; return }
        // The kit ends the window on the nearest channel: compare that channel's energy with the onsets.
        let channelEV = workingCoreLoss.map { $0.energyOffsetEV + $0.energyScaleEV * ((eV - $0.energyOffsetEV) / $0.energyScaleEV).rounded() } ?? eV
        if let last = fittableEdges.map(\.onsetEV).max(), channelEV <= last {
            fitToEV = nil
            fitToNotice = "Fit to must be above the last edge onset (\(EELSRoomFormat.sig(last, 5)) eV): the axis end is used."
            return
        }
        if let core = workingCoreLoss {
            let end = core.energyOffsetEV + core.energyScaleEV * Double(core.channels - 1)
            if eV > end {
                fitToEV = nil
                fitToNotice = "Fit to is past the end of the core-loss axis (\(EELSRoomFormat.sig(end, 5)) eV): the axis end is used."
                return
            }
        }
        fitToEV = eV
    }

    /// The Processing section's Deconvolution: a method the file cannot take is refused with its sentence and the control stays where it was.
    package func setDeconvolution(_ new: EELSDeconvolutionChoice) {
        guard new != deconvolutionChoice else { return }
        if let why = new.kind.blocker(hasLowLoss: hasLowLoss, hasCoreLoss: workingCoreLoss != nil) { deconvolutionNotice = why; return }
        deconvolutionNotice = nil
        deconvolutionChoice = new
        refreshPlot()
    }

    package func setConvolveLowLoss(_ on: Bool) { convolveLowLoss = on }
    package func setConvergence(_ mrad: Double?) { typedConvergenceMrad = mrad }
    package func setCollection(_ mrad: Double?) { typedCollectionMrad = mrad }

    // MARK: Windows, background and references

    /// A window of `edge` moved or resized (dragging on the spectrum). A window equal to the defaults is not kept as an edit.
    package func setWindows(_ new: EELSEdgeWindows, for edge: CoreLossEdge) {
        let edges = pickedEdges.contains(edge) ? pickedEdges : pickedEdges + [edge]
        guard let master = EELSWindowPlan.groups(of: edges).first(where: { $0.contains(edge) })?.last else { return }
        let key = EELSFitCompute.id(master)
        let defaults = EELSWindowPlan.defaultWindows(of: edge, among: edges, edited: editedWindows, axis: windowAxis)
        if new == defaults { editedWindows[key] = nil } else { editedWindows[key] = new }
        fitRefusal = nil
    }

    /// Every edge's windows back to the kit's defaults (the Edges section's Reset Windows and the spectrum's menu).
    package func resetAllWindows() {
        editedWindows = [:]
        fitRefusal = nil
    }

    package var hasEditedWindows: Bool { !editedWindows.isEmpty }

    /// One edge's windows back to the kit's defaults (a double click on its window, or the spectrum's menu).
    package func resetWindows(for edge: CoreLossEdge) {
        let edges = pickedEdges.contains(edge) ? pickedEdges : pickedEdges + [edge]
        if let master = EELSWindowPlan.groups(of: edges).first(where: { $0.contains(edge) })?.last { editedWindows[EELSFitCompute.id(master)] = nil }
        fitRefusal = nil
    }

    /// The background control: the power law is the kit's; another is refused with its reason and the control stays where it was.
    package func setBackground(_ choice: EELSBackgroundChoice) {
        if let why = choice.disabledReason { backgroundNotice = why; return }
        backgroundChoice = choice; backgroundNotice = nil
    }

    /// "From region": the selected region's (else the whole map's) core loss less the kit's power-law background, over the signal window of `edge`.
    @discardableResult
    package func addReferenceFromRegion(edge: CoreLossEdge) -> EELSReference? {
        referenceNotice = nil
        guard let core = plot?.core else { referenceNotice = "This file holds no core loss to take a reference from."; return nil }
        guard let reference = EELSReferenceCompute.fromRegion(name: plot?.regionName ?? "Whole map", edge: edge, core: core, windows: windows(for: edge)) else {
            referenceNotice = "\(EELSFitCompute.title(edge)): the kit has no background fit over this window, so there is no reference to take."
            return nil
        }
        references.append(reference)
        return reference
    }

    /// "Import…": an MSA file through FormatoKit's reader.
    @discardableResult
    package func importReference(url: URL) -> EELSReference? {
        referenceNotice = nil
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let reference = try EELSReferenceCompute.importMSA(url: url)
            references.append(reference)
            return reference
        } catch {
            referenceNotice = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            return nil
        }
    }

    package func removeReference(_ id: EELSReference.ID) { references.removeAll { $0.id == id }; referenceNotice = nil }

    /// The summed core loss's empty stretches, found off the main actor and landed once; a newer request drops an older one.
    private func refreshDeadStretches() {
        deadTask?.cancel()
        guard let core = workingCoreLoss else { coreDeadStretches = []; return }
        deadTask = Task.detached(priority: .utility) { [weak self] in
            let sums = EELSDeadStretch.channelSums(of: core)
            let stretches = EELSDeadStretch.stretches(counts: sums, origin: core.energyOffsetEV, step: core.energyScaleEV)
            if Task.isCancelled { return }
            await self?.landDeadStretches(stretches, for: core.energyOffsetEV)
        }
    }

    private func landDeadStretches(_ stretches: [ClosedRange<Double>], for offset: Double) {
        guard workingCoreLoss?.energyOffsetEV == offset else { return }
        coreDeadStretches = stretches
    }

    /// The edge model on the aligned core loss (and the low loss, to convolve): the maps' per-pixel fit, and the whole map's summed spectra as one
    /// region fit (the stable numbers). Lands only if no newer request was made.
    @discardableResult
    package func fit() -> Task<Void, Never>? {
        guard source != nil, let core = fitCoreLoss, let microscope, fitBlocker == nil else { return nil }
        passTask?.cancel()
        generation += 1
        let gen = generation
        let edges = fittableEdges, windows = fitWindows, kind = fitModel, fitTo = fitModel == .mlls ? fitToEV : nil
        let low = effectiveConvolve ? workingLowLoss : nil
        let signature = currentSignature
        let deconvolved = deconvolutionChoice.feedsTheFit ? deconvolution : nil
        // The pixels the deconvolution answered: the others are the kit's zeros, never summed or fitted.
        let answered = deconvolved?.answered
        let used = EELSPlotFit(edges: edges, microscope: microscope, convolve: low != nil, windows: windows, model: kind, deconvolved: deconvolved != nil)
        failure = nil
        fitRefusal = nil
        isComputing = true
        progress = 0
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let interval = Signposts.begin("eels.fit"); defer { Signposts.end(interval) }
                let gate = ProgressGate()
                // The whole map's summed spectra first: one pixel, so the kit checks the windows (and refuses a bad one by name) before the per-pixel map starts.
                let all = answered ?? [Bool](repeating: true, count: core.pixelCount)
                let regionCore = try core.sum(mask: all)
                let regionLow = try low.map { try $0.sum(mask: all) }
                let region = try EELSFitCompute.fit(coreLoss: regionCore, edges: edges, microscope: microscope, lowLoss: regionLow, model: kind, edgeWindows: windows,
                                                    fitToEV: fitTo)
                let quality = EELSFitQuality.of(region, core: regionCore, rawCounts: deconvolved == nil)
                if Task.isCancelled { return }
                let result = try EELSFitCompute.fit(coreLoss: core, edges: edges, microscope: microscope, lowLoss: low, model: kind, edgeWindows: windows,
                                                    fitToEV: fitTo, mask: answered, progress: { f in
                    guard gate.shouldReport(f * 0.9) else { return }
                    Task { @MainActor in self?.landProgress(f * 0.9, generation: gen) }
                })
                if Task.isCancelled { return }
                await self?.landModel(result, region: region, quality: quality, signature: signature, used: used, deconvolved: deconvolved, generation: gen)
            } catch is SpectroCancelled {
                return
            } catch {
                if Task.isCancelled { return }
                if let sentence = EELSWindowPlan.sentence(for: error) { await self?.landFitRefusal(sentence, generation: gen); return }
                await self?.landAlignmentFailure((error as? LocalizedError)?.errorDescription ?? "\(error)", generation: gen)
            }
        }
        passTask = task
        return task
    }

    /// The kit refused a window: its sentence goes under Fitting, the previous fit stays, nothing was run.
    private func landFitRefusal(_ sentence: String, generation gen: Int) {
        guard gen == generation else { return }
        isComputing = false
        fitRefusal = sentence
        onEvent?("Refused: \(sentence)")
    }

    private func landModel(_ result: EELSFitResult, region: EELSFitResult, quality: EELSFitQuality?, signature: String, used: EELSPlotFit,
                           deconvolved: EELSDeconvolutionResult?, generation gen: Int) {
        guard gen == generation else { return }
        modelVersion += 1
        model = result
        modelDeconvolution = deconvolved
        modelComposition = EELSFitCompute.composition(result, fitOnly: fitOnlyElements)
        regionModel = region
        regionQuality = quality
        regionComposition = EELSFitCompute.composition(region, fitOnly: fitOnlyElements)
        modelTiles = EELSFitCompute.tiles(result, composition: modelComposition, fitOnly: fitOnlyElements, version: modelVersion)
        modelSignature = signature
        fitUsed = used
        isComputing = false
        progress = 1
        refreshPinData()
        onEvent?("Fitted \(result.edges.count) edge\(result.edges.count == 1 ? "" : "s") over \(result.nx * result.ny) px")
    }

    /// The region table's rows: the whole map's summed spectra fitted as one pixel.
    package var regionRows: [EELSEdgeRow] {
        regionModel.map { EELSFitCompute.rows($0, composition: regionComposition, fitOnly: fitOnlyElements, rawCounts: modelDeconvolution == nil) } ?? []
    }

    // MARK: Deconvolve

    /// The Deconvolve stage: the kit's method on the working cubes (the thickness map's thresholds cut the zero-loss peaks). Lands only if no newer request
    /// was made; a refusal keeps the previous result on screen.
    @discardableResult
    package func deconvolve() -> Task<Void, Never>? {
        guard source != nil, deconvolutionChoice != .off else { return nil }
        passTask?.cancel()
        generation += 1
        let gen = generation
        let choice = deconvolutionChoice, low = hasLowLoss ? workingLowLoss : nil, core = workingCoreLoss, map = thicknessState == .current ? map : nil, threshold = threshold
        let signature = currentDeconvolutionSignature
        failure = nil
        isComputing = true
        progress = 0
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let interval = Signposts.begin("eels.deconvolve"); defer { Signposts.end(interval) }
                let gate = ProgressGate()
                let result = try EELSDeconvolveCompute.run(choice, low: low, core: core, map: map, threshold: threshold, progress: { f in
                    guard gate.shouldReport(f) else { return }
                    Task { @MainActor in self?.landProgress(f, generation: gen) }
                })
                if Task.isCancelled { return }
                await self?.landDeconvolution(result, signature: signature, generation: gen)
            } catch is SpectroCancelled {
                return
            } catch {
                if Task.isCancelled { return }
                await self?.landAlignmentFailure((error as? LocalizedError)?.errorDescription ?? "\(error)", generation: gen)
            }
        }
        passTask = task
        return task
    }

    private func landDeconvolution(_ result: EELSDeconvolutionResult?, signature: String, generation gen: Int) {
        guard gen == generation else { return }
        isComputing = false
        progress = 1
        deconvolution = result
        deconvolutionSignature = signature
        refreshPinData()
        if let result {
            onEvent?("Deconvolved: \(EELSDeconvolveCompute.line(result))" + (result.unavailableCount > 0 ? ", \(result.unavailableCount) px with no answer" : ""))
        }
    }

    /// The deconvolved low loss the spectrum draws: the stage's, while its method is the one chosen.
    package var shownDeconvolvedLow: LowLossSpectrumImage? {
        guard let d = deconvolution, d.choice == deconvolutionChoice else { return nil }
        return d.lowLoss
    }

    /// The results footer of the fit on screen (the results panel draws the same call).
    package var fitFooter: String {
        EELSRoomFormat.fitFooter(hasFit: model != nil, convolved: model?.convolved ?? false, model: model?.model ?? .exactNNLS,
                                 deconvolution: modelDeconvolution.map { EELSDeconvolveCompute.line($0) } ?? "no deconvolution")
    }

    /// The edge fit as the method JSON records it: the model, the kit's method and its reference, the fit-only elements and the deconvolution it fitted.
    package var fitParameters: [String: Any]? {
        guard let model else { return nil }
        var d: [String: Any] = ["model": model.model.title, "kit_method": model.methodName, "reference": EELSLiterature.edges,
                                "edges": model.edges.map(EELSFitCompute.title), "convolved_with_low_loss": model.convolved,
                                "fit_only": fitOnlyElements.sorted(), "quantified": EELSFitCompute.quantifiedSymbols(model, fitOnly: fitOnlyElements)]
        if model.model == .mlls {
            d["exponent"] = "two-area estimate per pixel"
            if case .mlls(let r) = model { d["window_eV"] = [r.windowEV.lowerBound, r.windowEV.upperBound] }
            d["fit_to_eV"] = fitToEV.map { $0 as Any } ?? "axis end"
        }
        d["deconvolution"] = modelDeconvolution.map { $0.choice.title } ?? "none"
        d["composition_sigma"] = EELSCompositionSigma.formula
        if let q = regionQuality {
            var quality: [String: Any] = ["rss": q.rss, "channels": q.channels, "parameters": q.parameters, "degrees_of_freedom": q.degreesOfFreedom,
                                          "chi2_reduced_pearson": q.reducedChiSquared.map { $0 as Any } ?? (q.chiSquaredUnavailable ?? "none")]
            quality["of"] = "whole map, summed spectra"
            d["fit_quality"] = quality
        }
        return d
    }

    // MARK: Regions and lines

    private func resetRegions() {
        pinDataTask?.cancel()
        pins = []; selectedPinID = nil; lines = []; selectedLineID = nil; pinSpectra = [:]; pinCoreSpectra = [:]; pinRows = []; isRefreshingRegions = false
        colorsIssued = 0; regionsIssued = 0; linesIssued = 0
    }

    /// A region drawn on a map: kept as the next numbered region and selected. A shape that holds no pixel, or one already kept, changes nothing.
    @discardableResult
    package func drawRegion(_ region: EDXRegion) -> EDXPin? {
        guard let image = source?.image else { return nil }
        let clipped = Self.clipped(region, nx: image.nx, ny: image.ny)
        guard let clipped, clipped.pixelCount(nx: image.nx, ny: image.ny) > 0 else { return nil }
        if let existing = pins.first(where: { $0.region == clipped }) { selectedPinID = existing.id; return existing }
        regionsIssued += 1; colorsIssued += 1
        let pin = EDXPin(name: "Region \(regionsIssued)", region: clipped, number: colorsIssued)
        pins.append(pin)
        selectedPinID = pin.id
        refreshPinData()
        return pin
    }

    private static func clipped(_ region: EDXRegion, nx: Int, ny: Int) -> EDXRegion? {
        func box(_ r: PixelRect) -> PixelRect? {
            let c = PixelRect(x0: max(r.x0, 0), y0: max(r.y0, 0), x1: min(r.x1, nx), y1: min(r.y1, ny))
            return c.width > 0 && c.height > 0 ? c : nil
        }
        switch region {
        case .wholeMap, .pool: return nil   // the EELS room keeps drawn shapes only; a pool is the EDS room's
        case .rectangle(let r): return box(r).map { .rectangle($0) }
        case .ellipse(let r): return box(r).map { .ellipse($0) }
        case .polygon(let v): return v.count >= 3 ? .polygon(v) : nil
        }
    }

    package func selectPin(_ id: EDXPin.ID?) {
        guard let id else { selectedPinID = nil; return }
        if pins.contains(where: { $0.id == id }) { selectedPinID = id; refreshPlot() }
    }

    /// No region selected: the spectrum, the results and the thickness line are the whole map's.
    package func selectWholeMap() {
        guard selectedPinID != nil else { return }
        selectedPinID = nil
        refreshPlot()
    }

    package func renamePin(_ id: EDXPin.ID, to name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, let i = pins.firstIndex(where: { $0.id == id }) else { return }
        pins[i].name = clean
        if let j = pinRows.firstIndex(where: { $0.pin.id == id }) { pinRows[j] = pinRows[j].renamed(pins[i]) }
    }

    package func removePin(_ id: EDXPin.ID) {
        pins.removeAll { $0.id == id }
        if selectedPinID == id { selectedPinID = pins.last?.id }
        refreshPinData()
    }

    package func setPinVisible(_ id: EDXPin.ID, _ visible: Bool) {
        guard let i = pins.firstIndex(where: { $0.id == id }), pins[i].isVisible != visible else { return }
        pins[i].isVisible = visible
        refreshPinData()
    }

    /// A kept region edited on the map (moved, or resized by a handle); one that holds no pixel, or is another region's, changes nothing.
    package func setPinRegion(_ id: EDXPin.ID, _ new: EDXRegion) {
        guard let image = source?.image, let i = pins.firstIndex(where: { $0.id == id }),
              let c = Self.clipped(new, nx: image.nx, ny: image.ny), c.pixelCount(nx: image.nx, ny: image.ny) > 0,
              c != pins[i].region, !pins.contains(where: { $0.id != id && $0.region == c }) else { return }
        pins[i].region = c
        refreshPinData()
    }

    /// A kept line edited on the map: its ends move; one shorter than a pixel changes nothing.
    package func setLineEnds(_ id: EDXLine.ID, from a: PixelPoint, to b: PixelPoint) {
        guard let image = source?.image, let i = lines.firstIndex(where: { $0.id == id }) else { return }
        func clamp(_ p: PixelPoint) -> PixelPoint { PixelPoint(x: min(max(p.x, 0), Double(image.nx)), y: min(max(p.y, 0), Double(image.ny))) }
        var edited = lines[i]
        edited.from = clamp(a); edited.to = clamp(b)
        if edited.length >= 1 { lines[i] = edited }
    }

    package func setPinColor(_ id: EDXPin.ID, _ color: EDXPinColor) { if let i = pins.firstIndex(where: { $0.id == id }) { pins[i].color = color } }

    /// A line drawn on a map, in scan pixels (continuous; pixel i covers [i, i+1)); one shorter than a pixel is not kept.
    @discardableResult
    package func drawLine(from a: PixelPoint, to b: PixelPoint) -> EDXLine? {
        guard let image = source?.image else { return nil }
        func clamp(_ p: PixelPoint) -> PixelPoint { PixelPoint(x: min(max(p.x, 0), Double(image.nx)), y: min(max(p.y, 0), Double(image.ny))) }
        linesIssued += 1; colorsIssued += 1
        let line = EDXLine(name: "Line \(linesIssued)", number: colorsIssued, from: clamp(a), to: clamp(b))
        guard line.length >= 1 else { linesIssued -= 1; colorsIssued -= 1; return nil }
        lines.append(line)
        selectedLineID = line.id
        return line
    }

    package func selectLine(_ id: EDXLine.ID?) {
        guard let id else { selectedLineID = nil; return }
        if lines.contains(where: { $0.id == id }) { selectedLineID = id }
    }

    package func removeLine(_ id: EDXLine.ID) {
        lines.removeAll { $0.id == id }
        if selectedLineID == id { selectedLineID = lines.last?.id }
    }

    package func renameLine(_ id: EDXLine.ID, to name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, let i = lines.firstIndex(where: { $0.id == id }) else { return }
        lines[i].name = clean
    }

    package func setLineVisible(_ id: EDXLine.ID, _ visible: Bool) { if let i = lines.firstIndex(where: { $0.id == id }) { lines[i].isVisible = visible } }
    package func setLineColor(_ id: EDXLine.ID, _ color: EDXPinColor) { if let i = lines.firstIndex(where: { $0.id == id }) { lines[i].color = color } }

    /// The selected line's profile on each map the grid shows: (tile id, title, positions in scan pixels, samples).
    package func profiles(width: Int = 1) -> [(id: String, title: String, positions: [Double], samples: [Double])] {
        guard let id = selectedLineID, let line = lines.first(where: { $0.id == id }) else { return [] }
        return displayedTiles.map { tile in
            let p = EDXLineProfiles.profile(values: tile.values, width: tile.width, height: tile.height, along: line, linewidth: width)
            return (tile.id, tile.title, p.positions, p.samples)
        }
    }

    /// The summed low-loss spectra of the visible regions (the plot's layers) and every region's row (the Table tab), summed and fitted off the main actor and
    /// landed once; a newer request drops an older one. The rows follow the thickness choices and, once edges are picked, the edge model.
    package func refreshPinData() {
        refreshPlot()
        pinDataTask?.cancel()
        pinDataRun += 1
        guard let low = workingLowLoss, !pins.isEmpty else { pinSpectra = [:]; pinCoreSpectra = [:]; pinRows = []; isRefreshingRegions = false; return }
        isRefreshingRegions = true
        let thicknessMade = thicknessSignature, fitMade = fitSignature
        let run = pinDataRun, pins = pins, core = shownCoreLoss, fitCore = fitCoreLoss
        let edges = fittableEdges, microscope = microscope, convolve = effectiveConvolve, edgeWindows = fitWindows
        let kind = fitModel, fitOnly = fitOnlyElements, answered = shownAnswered, fitTo = fitModel == .mlls ? fitToEV : nil
        let rawCounts = !deconvolutionChoice.feedsTheFit
        let threshold = threshold, lambda = try? EELSCompute.source(meanFreePath, beamEnergyKeV: beamEnergyKeV)
        pinDataTask = Task.detached(priority: .userInitiated) { [weak self] in
            var spectra: [EDXPin.ID: [Double]] = [:], coreSpectra: [EDXPin.ID: [Double]] = [:]
            var rows: [EELSRegionRow] = []
            for pin in pins {
                if Task.isCancelled { return }
                if pin.isVisible, let sum = EELSRegionCompute.summedLowLoss(low, region: pin.region) { spectra[pin.id] = sum.counts }
                if pin.isVisible, let core, pin.region.mask(nx: core.nx, ny: core.ny) != nil,
                   let sum = try? core.sum(mask: EELSRegionCompute.mask(pin.region, nx: core.nx, ny: core.ny, answered: answered)) { coreSpectra[pin.id] = sum.counts }
                if let row = EELSRegionCompute.row(pin: pin, low: low, core: fitCore, edges: edges, microscope: microscope, convolve: convolve,
                                                   threshold: threshold, meanFreePath: lambda ?? nil, edgeWindows: edgeWindows, model: kind, fitOnly: fitOnly,
                                                   answered: fitCore == nil ? nil : answered, fitToEV: fitTo, rawCounts: rawCounts) { rows.append(row) }
            }
            if Task.isCancelled { return }
            await self?.landPinData(spectra: spectra, coreSpectra: coreSpectra, rows: rows, run: run, thickness: thicknessMade, fit: fitMade)
        }
    }

    /// The plot of the selected region (the whole map when none is) off the main actor; a newer request drops an older one.
    package func refreshPlot() {
        plotTask?.cancel()
        plotRun += 1
        guard let low = workingLowLoss else { plot = nil; wholeMapPlot = nil; return }
        let run = plotRun, core = shownCoreLoss, map = map, threshold = threshold, deconvolvedLow = shownDeconvolvedLow, answered = shownAnswered
        let lambda = (try? EELSCompute.source(meanFreePath, beamEnergyKeV: beamEnergyKeV)) ?? nil
        let pin = selectedPin
        let region = pin?.region ?? .wholeMap, name = pin?.name ?? "Whole map"
        // The model is drawn only over the core loss it was fitted to (stored or Fourier-ratio deconvolved).
        let fit = model != nil && fitUsed?.deconvolved == (answered != nil) ? fitUsed : nil
        plotTask = Task.detached(priority: .userInitiated) { [weak self] in
            let data = EELSPlotCompute.make(name: name, region: region, low: low, core: core, map: map, threshold: threshold, meanFreePath: lambda, fit: fit,
                                            deconvolvedLow: deconvolvedLow, answered: answered)
            let whole = pin == nil ? data : EELSPlotCompute.make(name: "Whole map", region: .wholeMap, low: low, core: core, map: map, threshold: threshold,
                                                                  meanFreePath: lambda, fit: nil, deconvolvedLow: deconvolvedLow, answered: answered)
            if Task.isCancelled { return }
            await self?.landPlot(data, whole: whole, run: run)
        }
    }

    private func landPlot(_ data: EELSPlotData?, whole: EELSPlotData?, run: Int) {
        guard run == plotRun else { return }
        isPreviewing = false
        plot = data
        wholeMapPlot = whole
    }

    /// A region shape still under the pointer (MacEMUI's drawing layer reports it while a region is drawn, moved or resized): the spectrum follows it while the drag
    /// runs; the selected region, the results and the fit wait for the release. nil: the drag ended; if no region was committed with it, the selected region's spectrum
    /// is put back. Coalesced as the EDS room's (`EDXSession.previewRegion`): one sum at a time, a shape that arrives meanwhile replaces the waiting one, and a commit
    /// (any `refreshPlot`) supersedes every preview still in flight. The preview carries no model: the fit is the committed region's.
    @discardableResult
    package func previewRegion(_ preview: EDXRegion?) -> Task<Void, Never>? {
        guard let low = workingLowLoss else { return nil }
        let committed = plotRun
        guard let preview else {
            pendingPreview = nil
            // The release commits right after this call (same event): look once the event is over, then restore only if nothing was committed.
            let task = Task { @MainActor [weak self] in
                await self?.previewTask?.value
                guard let self, self.plotRun == committed, self.isPreviewing else { return }
                self.isPreviewing = false
                self.refreshPlot()
            }
            return task
        }
        guard let shape = Self.clipped(preview, nx: low.nx, ny: low.ny), shape.pixelCount(nx: low.nx, ny: low.ny) > 0 else { return previewTask }
        if let running = previewTask, !previewDone {
            pendingPreview = shape
            return running
        }
        previewDone = false
        let core = shownCoreLoss, map = map, threshold = threshold, answered = shownAnswered
        let lambda = (try? EELSCompute.source(meanFreePath, beamEnergyKeV: beamEnergyKeV)) ?? nil
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            var next: EDXRegion? = shape
            while let region = next {
                let data = EELSPlotCompute.make(name: "Selection", region: region, low: low, core: core, map: map, threshold: threshold, meanFreePath: lambda, fit: nil,
                                                answered: answered)
                next = await self?.landPreview(data, run: committed)
            }
        }
        previewTask = task
        return task
    }

    /// Shows a preview's plot unless a commit came since; returns the shape that arrived meanwhile (nil ends the run).
    private func landPreview(_ data: EELSPlotData?, run: Int) -> EDXRegion? {
        if run == plotRun, let data {
            isPreviewing = true
            plot = data
        }
        let next = run == plotRun ? pendingPreview : nil
        pendingPreview = nil
        if next == nil { previewDone = true }
        return next
    }

    private func landPinData(spectra: [EDXPin.ID: [Double]], coreSpectra: [EDXPin.ID: [Double]], rows: [EELSRegionRow], run: Int,
                             thickness: String, fit: String) {
        guard run == pinDataRun else { return }
        pinSpectra = spectra
        pinCoreSpectra = coreSpectra
        // Each row under its pin as it is now: a rename or a colour made while the rows were computed is kept.
        pinRows = rows.compactMap { row in pins.first { $0.id == row.pin.id }.map(row.renamed) }
        pinRowsThicknessSignature = thickness
        pinRowsFitSignature = fit
        isRefreshingRegions = false
    }

    // MARK: Align and Run

    /// The zero-loss alignment on the low loss (and the core loss with it): the kit's `EELSAlignment.alignZeroLossPeak` with its defaults
    /// (recalibrate the offset, subpixel pass, crop). Lands only if no newer request was made; the thickness map is then stale until it runs.
    @discardableResult
    package func align() -> Task<Void, Never>? {
        guard let loaded = source else { return nil }
        passTask?.cancel()
        generation += 1
        let gen = generation
        let low = loaded.image
        let core = loaded.coreLoss
        failure = nil
        isComputing = true
        progress = 0
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let interval = Signposts.begin("eels.align"); defer { Signposts.end(interval) }
                let gate = ProgressGate()
                // The search window for the peak: ±5 eV about 0 (the design's default Signal range), cut to the axis. Over the whole axis a noisy pixel's
                // maximum is anywhere, and its shift empties the cropped axis.
                let axisHigh = low.energyOffsetEV + low.energyScaleEV * Double(low.channels - 1)
                let window = max(low.energyOffsetEV, -5)...min(axisHigh, 5)
                var options = ZeroLossAlignmentOptions()
                if window.lowerBound < window.upperBound { options.signalRangeEV = window }
                let result = try EELSAlignment.alignZeroLossPeak(low, alsoAlign: core.map { [$0] } ?? [], options: options, progress: { f in
                    guard gate.shouldReport(f) else { return }
                    Task { @MainActor in self?.landProgress(f, generation: gen) }
                })
                if Task.isCancelled { return }
                await self?.landAlignment(result, generation: gen)
            } catch is SpectroCancelled {
                return
            } catch {
                if Task.isCancelled { return }
                await self?.landAlignmentFailure((error as? LocalizedError)?.errorDescription ?? "\(error)", generation: gen)
            }
        }
        passTask = task
        return task
    }

    private func landAlignment(_ result: ZeroLossAlignment, generation gen: Int) {
        guard gen == generation else { return }
        alignment = result
        alignmentTile = EELSCompute.beforeTile(result, nx: source?.image.nx ?? 0, ny: source?.image.ny ?? 0, version: inputVersion + 1)
        alignmentShiftTile = EELSCompute.shiftTile(result, nx: source?.image.nx ?? 0, ny: source?.image.ny ?? 0, version: inputVersion + 1)
        inputVersion += 1
        isComputing = false
        refreshDeadStretches()
        refreshPinData()
        onEvent?(alignmentReadout.map { "Aligned: \($0)" } ?? "Aligned.")
    }

    private func landAlignmentFailure(_ why: String, generation gen: Int) {
        guard gen == generation else { return }
        isComputing = false
        failure = why
        onEvent?("Refused: \(why)")
    }

    /// The toolbar's verb: every stage that is not current, in order (Align, then Thickness). The returned task ends when the last has landed.
    @discardableResult
    package func run() -> Task<Void, Never> {
        Task { [weak self] in
            guard let self, self.canRun else { return }
            if self.alignState != .current { await self.align()?.value }
            guard self.failure == nil else { return }
            if self.thicknessState != .current { await self.refresh()?.value }
            guard self.failure == nil else { return }
            if self.deconvolveState != .current { await self.deconvolve()?.value }
            guard self.failure == nil else { return }
            if self.fitState != .current, self.fitBlocker == nil { await self.fit()?.value }
        }
    }

    // MARK: Export

    package var diagnosticsCSV: String? { map.map { EELSCompute.diagnosticsCSV($0, fileName: fileName) } }
    /// The results table as the room shows it (the plot's region): nil before a fit.
    package var resultsCSV: String? {
        let rows = resultRows
        guard !rows.isEmpty, let plot else { return nil }
        let thickness = EELSRoomFormat.thicknessLine(plot.thickness, lambdaNM: map?.meanFreePathNM, lambdaSource: EELSRoomFormat.lambdaSource(meanFreePath),
                                                     locale: Locale(identifier: "en_US_POSIX"))
        return EELSExports.resultsCSV(rows, fileName: fileName, regionName: plot.regionName, thickness: thickness, method: fitFooter,
                                      deconvolution: modelDeconvolution.map(Self.deconvolutionRecord),
                                      quality: resultQuality.map { EELSRoomFormat.fitQuality($0, locale: Locale(identifier: "en_US_POSIX")) })
    }

    /// The deconvolution as the results CSV records it: the line, then its parameters as key=value.
    private static func deconvolutionRecord(_ d: EELSDeconvolutionResult) -> String {
        EELSDeconvolveCompute.line(d) + "; " + EELSDeconvolveCompute.parameters(d).sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
    }
    /// The shown spectrum (the selected region's, else the whole map's), with the model where the fit holds one.
    package var spectrumCSV: String? { plot.map { EELSExports.spectrumCSV($0, fileName: fileName) } }
    /// The kept regions' rows; nil without a region.
    package var regionsCSV: String? { pinRows.isEmpty ? nil : EELSExports.regionsCSV(pinRows, fileName: fileName) }
    package var methodJSON: String? {
        map.map { EELSCompute.methodJSON($0, fileName: fileName, origin: source?.origin ?? "", deconvolution: stageRecord, fit: fitParameters) }
    }

    /// The Deconvolve stage as the method JSON records it: the chosen method's result with its parameters and whether it is current; nil when Off or not run.
    private var stageRecord: [String: Any]? {
        guard deconvolutionChoice != .off, let d = deconvolution, d.choice.kind == deconvolutionChoice.kind else { return nil }
        var record = EELSDeconvolveCompute.parameters(d)
        record["state"] = deconvolveState.word
        return record
    }
}

/// Lets a progress fraction through when it has moved by a percent since the last one that went (and at the end). Called from the compute
/// thread; the lock makes it safe to share.
private nonisolated final class ProgressGate: @unchecked Sendable {
    private let lock = NSLock()
    private var last = -1.0

    func shouldReport(_ fraction: Double) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard fraction >= 1 || fraction - last >= 0.01 else { return false }
        last = fraction
        return true
    }
}
