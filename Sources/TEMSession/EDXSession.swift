//
//  EDXSession.swift
//  Role: the one owner of the EDX room's state: the opened spectrum image, the picked elements, the region, the
//        quantification method, and what the last compute put on screen (the region's spectrum, the net-count maps, the
//        pooled fit). The room's views read it; they hold none of it.
//
//  Nothing here makes a number. `TEMCore/EDX/EDXCompute` is SpectroKit called with the room's choices; this owner decides
//  WHEN to ask: every pass runs in a detached task and lands only if no newer request was made meanwhile (`generation`).
//  The blueprint is mac4DSTEM's SpectroscopyRoomController, cut to one window, whole map and one rectangle, no pins, no
//  4D pools. Once the Quantify verb has run, the fit is live: every pick, region or setting re-fits (no Apply).
//

import Foundation
import Observation
import SpectroCore
import SpectroEDX
import TEMCore

/// One element's net-count map, as the tile shows it.
package nonisolated struct EDXMapTile: Identifiable, Equatable {
    package let symbol: String
    package let width: Int
    package let height: Int
    package let values: [Double]
    /// What the tile's picture was made from; two tiles with the same version are the same picture.
    package let version: Int
    /// "Al Kα" and, when the line is not a measurement, why.
    package let line: String
    package let note: String?
    /// What the values are: net counts, or a composition from the quantification maps.
    package var mode: EDXMapMode = .net
    /// Under the picture, for a composition tile: the k source, what was not applied, the failed pixels and the badge. nil for net counts.
    package var footer: String?
    /// The largest finite value, found once when the tile is made (the colorbar's upper end), not per render.
    package let maxValue: Double
    package var id: String { symbol }

    package init(symbol: String, width: Int, height: Int, values: [Double], version: Int, line: String, note: String?,
                 mode: EDXMapMode = .net, footer: String? = nil) {
        self.symbol = symbol; self.width = width; self.height = height; self.values = values; self.version = version
        self.line = line; self.note = note; self.mode = mode; self.footer = footer
        self.maxValue = values.reduce(0.0) { max($0, $1.isFinite ? $1 : 0) }
    }

    package static func == (a: EDXMapTile, b: EDXMapTile) -> Bool {
        a.symbol == b.symbol && a.version == b.version && a.note == b.note && a.mode == b.mode && a.footer == b.footer
    }
}

/// The composition maps' pass: nothing asked, waiting for something only the person can give, running, landed, or the kit's refusal.
package nonisolated enum EDXMapsState: Equatable {
    case idle
    case blocked(String)
    case running
    case done
    case failed(String)
}

/// One line window's counts in the region's spectrum, before any fit (the rows of the table until Quantify has run).
package nonisolated struct EDXWindowRow: Identifiable, Equatable {
    package let symbol: String
    package let line: String
    package let net: Double
    package let sigma: Double
    package let note: String?
    package let failure: String?
    package var id: String { symbol + "|" + line }
}

/// A marker on the spectrum: where a picked element's alpha line sits.
package nonisolated struct EDXMarker: Identifiable, Equatable {
    package let symbol: String
    package let label: String
    package let energy: Double
    package let quantified: Bool
    package var id: String { symbol + "|" + label }
    package init(symbol: String, label: String, energy: Double, quantified: Bool) {
        self.symbol = symbol; self.label = label; self.energy = energy; self.quantified = quantified
    }
}

/// What the spectrum plot draws. With a fit: the fitted channels' model and continuum on the fit's own (refined) axis.
package nonisolated struct EDXPlot: Equatable {
    package var energyStart: Double
    package var energyStep: Double
    package var data: [Double]
    package var background: [Double] = []
    package var model: [Double] = []
    package var fitChannels: Range<Int> = 0..<0

    /// The fitted channels of a curve the kit returns over the whole axis (zero outside the fit range), with the energy of the first.
    package func fitted(_ values: [Double]) -> (start: Double, values: [Double]) {
        let lo = max(fitChannels.lowerBound, 0), hi = min(fitChannels.upperBound, values.count)
        guard lo < hi else { return (energyStart, []) }
        return (energyStart + energyStep * Double(lo), Array(values[lo..<hi]))
    }

    package init(energyStart: Double, energyStep: Double, data: [Double], background: [Double] = [], model: [Double] = [],
                 fitChannels: Range<Int> = 0..<0) {
        self.energyStart = energyStart; self.energyStep = energyStep; self.data = data
        self.background = background; self.model = model; self.fitChannels = fitChannels
    }
}

package nonisolated enum EDXAutoIDState: Equatable {
    case idle
    case running
    case done(EDXCompute.AutoIDOutcome)
    case failed(String)

    /// What the last finished run found; nil while idle, running or failed.
    package var outcome: EDXCompute.AutoIDOutcome? { if case .done(let o) = self { o } else { nil } }
}

/// A weak reference a progress callback can hold from another thread.
private final class WeakSession: @unchecked Sendable {
    weak var session: EDXSession?
    init(_ session: EDXSession) { self.session = session }
}

@Observable
package final class EDXSession {

    // MARK: The spectrum image

    package private(set) var source: (any SpectrumImageSource)?
    /// The scan image's finite range (the HAADF colorbar's ends), found when the source is bound.
    package private(set) var scanRange: ClosedRange<Double>?
    package private(set) var isOpening = false
    package private(set) var openProgress = 0.0

    // MARK: The choices

    package private(set) var picks: [EDXPick] = []
    /// Elements the person took out by hand: Auto ID does not add them again.
    package private(set) var dismissed: Set<String> = []
    package private(set) var region: EDXRegion = .wholeMap
    /// Regions kept under a name; the spectrum and the fit follow the one selected.
    package private(set) var pins: [EDXPin] = []
    /// Lines drawn on the maps; the selected one's profile is the Profile tab's.
    package private(set) var lines: [EDXLine] = []
    package private(set) var selectedLineID: EDXLine.ID?
    /// The Quantification section's choices. Its `elements` are filled from `picks` when a fit runs.
    package private(set) var method = QuantificationMethod()

    // MARK: What the last compute put on screen

    package private(set) var plot = EDXPlot(energyStart: 0, energyStep: 0.01, data: [])
    /// The region's summed spectrum as the file stores it (the plot holds the same numbers as Doubles).
    package private(set) var spectrumCounts: [UInt64] = []
    package private(set) var totalCounts: UInt64 = 0
    package private(set) var regionPixels = 0
    package private(set) var tiles: [EDXMapTile] = []
    package private(set) var windowRows: [EDXWindowRow] = []
    /// The visible pins' summed spectra (one layer each on the plot) and every pin's row of the Table tab, for the picks and region set of the last pass.
    package private(set) var pinSpectra: [EDXPin.ID: [Double]] = [:]
    package private(set) var pinRows: [EDXPins.Row] = []
    package private(set) var markers: [EDXMarker] = []
    /// The Quantify verb has run: the pooled fit is live from here on.
    package private(set) var quantifyActive = false
    package private(set) var fit: PooledQuantification?
    package private(set) var fitFailure: String?
    package private(set) var isFitting = false
    /// The unlisted-line check is still running for the fit shown.
    package private(set) var isChecking = false
    package private(set) var autoID: EDXAutoIDState = .idle
    /// A refresh (the region's sum, the windows, the maps, the fit) is in flight.
    package private(set) var isRefreshing = false

    /// What the maps grid draws; wt% and at% come from `EDXQuantMaps` when the typed k allows.
    package private(set) var mapMode: EDXMapMode = .net
    package private(set) var mapsState: EDXMapsState = .idle
    /// How the maps are quantified; the pooled fit (results table) is always Cliff-Lorimer.
    package private(set) var mapMethod: EDXMapMethod = .cliffLorimer
    /// The zeta / cross-section factors, dose and source the person typed.
    package private(set) var dose = EDXDoseInputs()
    /// The composition tiles of the last landed pass, by mode.
    package private(set) var quantTiles: [EDXMapMode: [EDXMapTile]] = [:]
    /// The kit's maps behind `quantTiles` (a test compares them with the kit's per-pixel call).
    package private(set) var quantMaps: EDXQuantificationMaps?

    /// The infobar's events (an open, an error); set by the window, which owns the status line.
    @ObservationIgnored package var onEvent: ((String) -> Void)?
    /// Errors the person must see (a file that is not a spectrum image).
    @ObservationIgnored package var onFailure: ((any Error) -> Void)?

    @ObservationIgnored private var cache = EDXComputeCache()
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    /// The live spectrum of a drag (`previewRegion`): the running sum, the shape waiting for it, and whether the plot shows a preview.
    @ObservationIgnored private var previewTask: Task<Void, Never>?
    @ObservationIgnored private var pendingPreview: EDXRegion?
    @ObservationIgnored private var previewDone = true
    @ObservationIgnored private var isPreviewing = false
    @ObservationIgnored private var checkTask: Task<Void, Never>?
    @ObservationIgnored private var autoIDTask: Task<Void, Never>?
    @ObservationIgnored private var openTask: Task<Void, Never>?
    @ObservationIgnored private var mapsTask: Task<Void, Never>?
    /// The chain after an open: the first spectrum, then Auto ID. Stop ends it with the rest.
    @ObservationIgnored private var bindTask: Task<Void, Never>?
    @ObservationIgnored private var mapsRun = 0
    /// The windows of the last landed refresh: the net maps the composition pass reads.
    @ObservationIgnored private var lastWindows: EDXCompute.Windows?
    @ObservationIgnored private var tileVersion = 0
    /// The newest Auto ID run; an older one that lands later is dropped.
    @ObservationIgnored private var autoIDRun = 0
    /// How many pins and lines were ever made in this image: numbers, default names and palette colours follow them, so a deleted one is not reused.
    @ObservationIgnored private var colorsIssued = 0   // regions and lines share it: the palette colour follows the count
    @ObservationIgnored private var linesIssued = 0
    @ObservationIgnored private var pinDataTask: Task<Void, Never>?
    @ObservationIgnored private var pinDataRun = 0

    package init() {}

    // MARK: Derived

    /// The tiles the grid draws: the net maps, or the composition of the chosen mode once it has landed.
    package var shownTiles: [EDXMapTile] { mapMode == .net ? tiles : (quantTiles[mapMode] ?? tiles) }
    /// Something Stop can end: an open, a refresh, a fit and its check, Auto ID, a composition pass.
    package var isBusy: Bool { isOpening || isRefreshing || isFitting || isChecking || autoID == .running || mapsState == .running }
    package var hasImage: Bool { source != nil }
    /// The file's real-space pixel size and its unit ("nm"), when it states one: a line profile is then in that unit; else in scan pixels.
    package var scanPixel: (size: Double, unit: String)? {
        guard let m = source?.metadata, let size = m.scanPixelSize, size > 0, let unit = m.scanPixelUnit, !unit.isEmpty else { return nil }
        return (size, unit)
    }
    package var fileName: String { source?.metadata.fileName ?? "" }
    package var fileBeamEnergy: Double? { source?.metadata.beamEnergyKeV }
    /// The beam energy a run uses: the typed one, else the file's.
    package var beamEnergy: Double? { method.beamEnergyKeV ?? fileBeamEnergy }
    /// A one-pixel file (an .msa, a single Velox spectrum): there are no maps, no region to draw, and the words say "Spectrum", not "Whole map".
    package var isSingleSpectrum: Bool { (source?.nx ?? 0) * (source?.ny ?? 0) == 1 }
    package var regionName: String { isSingleSpectrum ? "Spectrum" : region.name }
    package var canQuantify: Bool { hasImage && picks.contains { $0.role == .quantify } }
    package var quantifyBlocker: String? {
        hasImage && !canQuantify ? "Pick at least one element to quantify." : nil
    }
    /// The default stem of an export file: the image, the region.
    package var exportStem: String { SpectroscopyExport.fileStem(imageName: fileName, regionName: region.name) }

    // MARK: Opening

    /// Reads a spectrum image off the main actor and starts the room over on it. A newer open replaces one in flight. The
    /// returned task ends when the room has its first spectrum and Auto ID has run (a test awaits it).
    @discardableResult
    package func open(url: URL) -> Task<Void, Never> {
        openTask?.cancel()
        isOpening = true
        openProgress = 0
        onEvent?("Opening \(url.lastPathComponent)…")
        let box = WeakSession(self)
        let task = Task { [weak self] in
            do {
                let loaded = try await Self.read(url) { fraction in
                    Task { @MainActor in box.session?.openProgress = fraction }
                }
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

    /// The read, holding the sandbox scope while it lasts (as `AppState.read` does for an image).
    @concurrent
    nonisolated private static func read(_ url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> LoadedSpectrumImage {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return try EDXOpening.open(url: url, progress: progress)
    }

    /// Starts the room over on `source`: no elements, the whole map, the method kept (it is the person's choice, not a
    /// property of the file). Auto ID runs on open and its picks are applied (mac4DSTEM ADR 057 item 4); nothing is
    /// quantified until the Quantify verb.
    @discardableResult
    package func bind(_ source: any SpectrumImageSource) -> Task<Void, Never> {
        cancelWork()
        self.source = source
        scanRange = source.scanImage.flatMap { values in
            let finite = values.filter(\.isFinite)
            guard let lo = finite.min(), let hi = finite.max() else { return nil }
            return Double(lo)...Double(hi)
        }
        cache = EDXComputeCache()
        picks = []; dismissed = []; region = .wholeMap; pins = []; lines = []; selectedLineID = nil; pinSpectra = [:]; pinRows = []; colorsIssued = 0; linesIssued = 0; pinDataTask?.cancel()
        quantifyActive = false; fit = nil; fitFailure = nil; isFitting = false; isChecking = false
        tiles = []; windowRows = []; markers = []; autoID = .idle
        clearQuantMaps(); lastWindows = nil
        method.beamEnergyKeV = nil
        method.elements = []
        let meta = source.metadata
        onEvent?("Opened — \(meta.scanWidth) × \(meta.scanHeight) px, \(meta.channelCount) channels")
        let first = refresh()
        let chain = Task { [weak self] in
            await first?.value
            guard let self, !Task.isCancelled, self.source === source else { return }
            await self.runAutoID()?.value
        }
        bindTask = chain
        return chain
    }

    package func close() {
        cancelWork()
        source = nil
        scanRange = nil
        picks = []; dismissed = []; region = .wholeMap; pins = []; lines = []; selectedLineID = nil; pinSpectra = [:]; pinRows = []; colorsIssued = 0; linesIssued = 0; pinDataTask?.cancel()
        quantifyActive = false; fit = nil; fitFailure = nil; isFitting = false; isChecking = false
        tiles = []; windowRows = []; markers = []; autoID = .idle
        clearQuantMaps(); lastWindows = nil
        plot = EDXPlot(energyStart: 0, energyStep: 0.01, data: [])
        totalCounts = 0; regionPixels = 0; spectrumCounts = []
        openTask?.cancel(); openTask = nil; isOpening = false
    }

    private func cancelWork() {
        generation += 1; autoIDRun += 1; mapsRun += 1
        refreshTask?.cancel(); checkTask?.cancel(); autoIDTask?.cancel(); mapsTask?.cancel(); bindTask?.cancel()
        refreshTask = nil; checkTask = nil; autoIDTask = nil; mapsTask = nil; bindTask = nil
        isRefreshing = false
    }

    /// Stop: ends whatever is running and leaves the room usable. The kit stops a fit or the proposer at its next check; a composition
    /// pass (`concurrentPerform`) runs to its end but its result is dropped. What was being computed is not shown half done: a fit
    /// that was running or checking is cleared with the reason, and the next change or the Quantify verb runs it again.
    package func stop() {
        guard isBusy else { return }
        let wasOpening = isOpening
        openTask?.cancel(); openTask = nil; isOpening = false
        let fitWasRunning = isFitting || isChecking
        cancelWork()
        isFitting = false; isChecking = false
        if autoID == .running { autoID = .idle }
        if mapsState == .running { mapsState = .idle }
        if fitWasRunning { fit = nil; fitFailure = "Stopped." }
        onEvent?(wasOpening ? "Stopped opening." : "Stopped.")
    }

    // MARK: Elements

    /// The periodic table's click: an unlisted element is picked (Quantify), a listed one is taken out by hand.
    package func toggle(_ symbol: String) {
        guard hasImage else { return }
        if picks.contains(where: { $0.symbol == symbol }) { remove(symbol) } else { add(symbol, role: .quantify, manual: true) }
    }

    package func setRole(_ role: EDXRole, of symbol: String) {
        guard let i = picks.firstIndex(where: { $0.symbol == symbol }), picks[i].role != role else { return }
        picks[i].role = role
        picks[i].manual = true
        refresh()
    }

    /// The line family the maps and the fit's windows use for a picked element (the right-click menu's "K lines"); the lines checked before are cleared, they belonged to another family.
    package func setFamily(_ family: XRayFamily, of symbol: String) {
        guard let i = picks.firstIndex(where: { $0.symbol == symbol }), picks[i].family != family else { return }
        picks[i].family = family
        picks[i].lines = []
        picks[i].manual = true
        refresh()
    }

    /// Checks or unchecks one line of a picked element (what the maps sum and the spectrum marks).
    package func toggleLine(_ id: String, of symbol: String) {
        guard let i = picks.firstIndex(where: { $0.symbol == symbol }) else { return }
        if let at = picks[i].lines.firstIndex(of: id) { picks[i].lines.remove(at: at) } else { picks[i].lines.append(id) }
        picks[i].manual = true
        refresh()
    }

    /// Back to the element's default lines.
    package func resetLines(of symbol: String) {
        guard let i = picks.firstIndex(where: { $0.symbol == symbol }), picks[i].family != nil || !picks[i].lines.isEmpty else { return }
        picks[i].family = nil
        picks[i].lines = []
        refresh()
    }

    private func add(_ symbol: String, role: EDXRole, manual: Bool) {
        guard EDXElements.unavailableReason(symbol: symbol) == nil, !picks.contains(where: { $0.symbol == symbol }) else { return }
        picks.append(EDXPick(symbol: symbol, role: role, manual: manual))
        picks.sort { (EDXElements.z(of: $0.symbol) ?? 0) < (EDXElements.z(of: $1.symbol) ?? 0) }
        if manual { dismissed.remove(symbol) }
        refresh()
    }

    private func remove(_ symbol: String) {
        picks.removeAll { $0.symbol == symbol }
        dismissed.insert(symbol)
        refresh()
    }

    // MARK: Region

    package func selectWholeMap() {
        guard region != .wholeMap else { return }
        region = .wholeMap
        regionChanged()
    }

    /// A rectangle drawn on a map, in pixels of the spectrum image's grid; one that holds no pixel changes nothing.
    package func selectRectangle(_ rect: PixelRect) {
        if let clipped = clipped(rect) { select(.rectangle(clipped)) }
    }

    /// The ellipse inscribed in a rectangle drawn on a map.
    package func selectEllipse(_ rect: PixelRect) {
        if let clipped = clipped(rect) { select(.ellipse(clipped)) }
    }

    /// A closed polygon of at least three vertices (pixel coordinates); one that holds no pixel centre changes nothing.
    package func selectPolygon(_ vertices: [PixelPoint]) {
        guard let source, vertices.count >= 3 else { return }
        let r = EDXRegion.polygon(vertices)
        guard r.pixelCount(nx: source.nx, ny: source.ny) > 0 else { return }
        select(r)
    }

    /// A region shape still under the pointer: the spectrum follows it while the drag runs; the selected region, the windows, the results, the
    /// fit and Auto ID wait for the release (the drawing layer's commit). nil: the drag ended; if no region was committed with it, the selected
    /// region's spectrum is put back. Coalesced: one sum at a time, and a shape that arrives meanwhile replaces the waiting one (the latest wins),
    /// so a fast drag costs one sum per finished sum, never a queue. A commit (any refresh) supersedes every preview still in flight.
    @discardableResult
    package func previewRegion(_ preview: EDXRegion?) -> Task<Void, Never>? {
        guard let source else { return nil }
        let committed = generation
        guard let preview else {
            pendingPreview = nil
            // The release commits right after this call (same event): look once the event is over, then restore only if nothing was committed.
            let task = Task { @MainActor [weak self] in
                await self?.previewTask?.value
                guard let self, self.generation == committed, self.isPreviewing, let axis = self.source?.energyAxis else { return }
                self.isPreviewing = false
                self.plot = EDXPlot(energyStart: axis.offset, energyStep: axis.scale, data: self.spectrumCounts.map { Double($0) })
            }
            return task
        }
        guard preview.pixelCount(nx: source.nx, ny: source.ny) > 0 else { return previewTask }
        if let running = previewTask, !previewDone {
            pendingPreview = preview
            return running
        }
        previewDone = false
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            var next: EDXRegion? = preview
            while let shape = next {
                // Not through the compute cache: a drag passes through hundreds of shapes, and the cache keeps every region it is given.
                let spectrum = source.sum(mask: shape.mask(nx: source.nx, ny: source.ny))
                next = await self?.landPreview(spectrum, generation: committed)
            }
        }
        previewTask = task
        return task
    }

    /// Shows a preview's sum unless a commit came since; returns the shape that arrived meanwhile (nil ends the run).
    private func landPreview(_ spectrum: [UInt64], generation committed: Int) -> EDXRegion? {
        guard let source else { previewDone = true; return nil }
        if generation == committed {
            isPreviewing = true
            plot = EDXPlot(energyStart: source.energyAxis.offset, energyStep: source.energyAxis.scale, data: spectrum.map { Double($0) })
        }
        let next = generation == committed ? pendingPreview : nil
        pendingPreview = nil
        if next == nil { previewDone = true }
        return next
    }

    /// A region drawn on a map: it is selected and kept as the next numbered region, so drawing a second shape adds a region to compare with the first.
    package func drawRectangle(_ rect: PixelRect) { selectRectangle(rect); keepSelectedRegion() }
    package func drawEllipse(_ rect: PixelRect) { selectEllipse(rect); keepSelectedRegion() }
    package func drawPolygon(_ vertices: [PixelPoint]) { selectPolygon(vertices); keepSelectedRegion() }

    private func keepSelectedRegion() {
        guard region != .wholeMap else { return }
        let before = pins.count
        pinRegion()
        if pins.count != before { refreshPinData() }
    }

    private func clipped(_ rect: PixelRect) -> PixelRect? {
        guard let source, rect.width > 0, rect.height > 0 else { return nil }
        let c = PixelRect(x0: max(rect.x0, 0), y0: max(rect.y0, 0), x1: min(rect.x1, source.nx), y1: min(rect.y1, source.ny))
        return c.width > 0 && c.height > 0 ? c : nil
    }

    private func select(_ new: EDXRegion) {
        guard region != new else { return }
        region = new
        regionChanged()
    }

    // MARK: Pins

    /// The pin whose region is the one selected, if any.
    package var selectedPin: EDXPin? { pins.first { $0.region == region } }

    /// Keeps the selected region under a name ("Region 1", "Region 2", …); a region already pinned is not pinned twice.
    @discardableResult
    package func pinRegion(named name: String? = nil) -> EDXPin? {
        guard hasImage, selectedPin == nil else { return selectedPin }
        var n = pins.count + 1
        while pins.contains(where: { $0.name == "Region \(n)" }) { n += 1 }
        let clean = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        colorsIssued += 1
        let pin = EDXPin(name: (clean?.isEmpty == false ? clean : nil) ?? (region == .wholeMap ? "Whole map" : "Region \(n)"), region: region, number: colorsIssued)
        pins.append(pin)
        return pin
    }

    package func selectPin(_ id: EDXPin.ID) {
        guard let pin = pins.first(where: { $0.id == id }) else { return }
        select(pin.region)
    }

    package func renamePin(_ id: EDXPin.ID, to name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, let i = pins.firstIndex(where: { $0.id == id }) else { return }
        pins[i].name = clean
    }

    package func removePin(_ id: EDXPin.ID) { pins.removeAll { $0.id == id }; refreshPinData() }

    package func setPinVisible(_ id: EDXPin.ID, _ visible: Bool) {
        guard let i = pins.firstIndex(where: { $0.id == id }), pins[i].isVisible != visible else { return }
        pins[i].isVisible = visible
        refreshPinData()
    }

    /// A kept region edited on the map (moved, or resized by a handle): it takes the new shape, clipped to the scan. A shape that holds no pixel, or one that
    /// is another region's, changes nothing. The selected region's spectrum and fit follow it.
    package func setPinRegion(_ id: EDXPin.ID, _ new: EDXRegion) {
        guard let source, let i = pins.firstIndex(where: { $0.id == id }) else { return }
        let clippedNew: EDXRegion
        switch new {
        case .wholeMap: return
        case .rectangle(let r): guard let c = clipped(r) else { return }; clippedNew = .rectangle(c)
        case .ellipse(let r): guard let c = clipped(r) else { return }; clippedNew = .ellipse(c)
        case .polygon(let v): guard v.count >= 3, new.pixelCount(nx: source.nx, ny: source.ny) > 0 else { return }; clippedNew = new
        }
        guard clippedNew != pins[i].region, !pins.contains(where: { $0.id != id && $0.region == clippedNew }) else { return }
        let wasSelected = pins[i].region == region
        pins[i].region = clippedNew
        if wasSelected { select(clippedNew) }
        refreshPinData()
    }

    /// A kept line edited on the map: its ends move; one shorter than a pixel changes nothing.
    package func setLineEnds(_ id: EDXLine.ID, from a: PixelPoint, to b: PixelPoint) {
        guard let source, let i = lines.firstIndex(where: { $0.id == id }) else { return }
        func clamp(_ p: PixelPoint) -> PixelPoint { PixelPoint(x: min(max(p.x, 0), Double(source.nx)), y: min(max(p.y, 0), Double(source.ny))) }
        var edited = lines[i]
        edited.from = clamp(a); edited.to = clamp(b)
        if edited.length >= 1 { lines[i] = edited }
    }

    package func setPinColor(_ id: EDXPin.ID, _ color: EDXPinColor) {
        guard let i = pins.firstIndex(where: { $0.id == id }) else { return }
        pins[i].color = color
    }

    // MARK: Lines

    /// A line drawn on a map, in pixels of the scan grid (as `PixelPoint`: continuous, pixel i covering [i, i+1)); one shorter than a pixel is not kept.
    @discardableResult
    package func drawLine(from a: PixelPoint, to b: PixelPoint) -> EDXLine? {
        guard let source else { return nil }
        func clamp(_ p: PixelPoint) -> PixelPoint { PixelPoint(x: min(max(p.x, 0), Double(source.nx)), y: min(max(p.y, 0), Double(source.ny))) }
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

    /// The selected line's profile on each shown map: (element, positions in scan pixels, samples).
    package func profiles(width: Int = 1) -> [(symbol: String, positions: [Double], samples: [Double])] {
        guard let id = selectedLineID, let line = lines.first(where: { $0.id == id }) else { return [] }
        return shownTiles.map { tile in
            let p = EDXLineProfiles.profile(values: tile.values, width: tile.width, height: tile.height, along: line, linewidth: width)
            return (tile.symbol, p.positions, p.samples)
        }
    }

    // MARK: Pin data

    /// The spectrum of one scan pixel, for the pointer's temporary layer; nil off the grid or with no image. One pixel is cheap: it does not touch the cache.
    package func pixelSpectrum(x: Int, y: Int) -> [Double]? {
        guard let source, x >= 0, y >= 0, x < source.nx, y < source.ny else { return nil }
        return EDXCompute.spectrum(source: source, region: .rectangle(PixelRect(x0: x, y0: y, x1: x + 1, y1: y + 1)), cache: EDXComputeCache()).map { Double($0) }
    }

    /// The visible pins' spectra and every pin's table row, summed off the main actor and landed once; a newer request drops an older one.
    package func refreshPinData() {
        pinDataTask?.cancel()
        pinDataRun += 1
        guard let source, !pins.isEmpty else { pinSpectra = [:]; pinRows = []; return }
        let run = pinDataRun, pins = pins, cache = cache, symbols = quantifiedSymbols
        let setup = try? EDXQuantMaps.setup(method: method, mapMethod: mapMethod, dose: dose, symbols: symbols)
        pinDataTask = Task.detached(priority: .userInitiated) { [weak self] in
            var spectra: [EDXPin.ID: [Double]] = [:]
            for pin in pins where pin.isVisible {
                spectra[pin.id] = EDXCompute.spectrum(source: source, region: pin.region, cache: cache).map { Double($0) }
            }
            let rows = EDXPins.rows(pins: pins, source: source, symbols: symbols, setup: setup, cache: cache)
            if Task.isCancelled { return }
            await self?.landPinData(spectra: spectra, rows: rows, run: run)
        }
    }

    private func landPinData(spectra: [EDXPin.ID: [Double]], rows: [EDXPins.Row], run: Int) {
        guard run == pinDataRun else { return }
        pinSpectra = spectra
        pinRows = rows
    }

    /// Replaces the pins with a set read from a pins CSV, regions clipped away when they hold no pixel of this image.
    @discardableResult
    package func loadPins(_ loaded: [EDXPin]) -> Int {
        guard let source else { return 0 }
        let usable = loaded.filter { $0.region.pixelCount(nx: source.nx, ny: source.ny) > 0 }
        pins = usable
        colorsIssued = usable.count
        refreshPinData()
        return usable.count
    }

    /// The pins CSV: each pin's pixels, counts, net counts and (with complete factors) composition, summed off the main actor.
    package func pinsCSV() async -> String? {
        guard let source, !pins.isEmpty else { return nil }
        let pins = pins, cache = cache, name = fileName
        let symbols = quantifiedSymbols
        let setup = try? EDXQuantMaps.setup(method: method, mapMethod: mapMethod, dose: dose, symbols: symbols)
        return await Task.detached(priority: .userInitiated) {
            EDXPins.csv(rows: EDXPins.rows(pins: pins, source: source, symbols: symbols, setup: setup, cache: cache), fileName: name)
        }.value
    }

    private func regionChanged() {
        var restart = false
        if case .running = autoID { restart = true }
        autoIDTask?.cancel(); autoIDRun += 1; autoID = .idle
        let run = autoIDRun
        let pass = refresh()
        if restart { Task { [weak self] in await pass?.value; if self?.autoIDRun == run { self?.runAutoID() } } }
    }

    // MARK: Method

    /// Writes a Quantification control into the method; after the verb has run the fit follows.
    package func changeMethod(_ edit: (inout QuantificationMethod) -> Void) {
        let before = method
        var m = method
        edit(&m)
        guard m != before else { return }
        method = m
        if case .failed(EDXCompute.autoIDNeedsBeamNote) = autoID, beamEnergy != nil { autoID = .idle }
        if quantifyActive { refresh() } else if mapMode != .net { startMaps() }
    }

    /// Which composition the maps draw. wt% and at% need the typed k; until they have it the status strip says what to type.
    package func setMapMode(_ mode: EDXMapMode) {
        guard mode != mapMode else { return }
        mapMode = mode
        if mode == .net {
            mapsTask?.cancel(); mapsRun += 1
            if mapsState == .running { mapsState = .idle }
        } else if quantTiles[mode] == nil || mapsState != .done {
            startMaps()
        }
    }

    // MARK: Auto ID

    /// Auto ID: the element proposer on the region's spectrum (0.4 to 20 s by channel count), detached, its picks applied.
    /// It needs the beam energy, so a file without one says so.
    @discardableResult
    /// `explicit`: the Auto ID button. An explicit run is a request for the whole proposal, so it forgets the elements the person took out
    /// (a deselect-all then Auto ID must find everything again; drive 6, 2026-10-22); the automatic runs (open, a region change) keep them.
    package func runAutoID(explicit: Bool = false) -> Task<Void, Never>? {
        guard let source else { return nil }
        if case .running = autoID { return nil }
        if explicit { dismissed = [] }
        guard let beam = beamEnergy, beam > 0 else {
            autoID = .failed(EDXCompute.autoIDNeedsBeamNote)
            return nil
        }
        autoID = .running
        let region = region, cache = cache, listed = picks.map(\.symbol), computedK = method.kFactorSource == .computed
        let regionName = region.name
        autoIDRun += 1
        let run = autoIDRun
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            let spectrum = EDXCompute.spectrum(source: source, region: region, cache: cache)
            var outcome: EDXCompute.AutoIDOutcome?
            var failure: String?
            do {
                outcome = try EDXCompute.autoID(spectrum: spectrum, axis: source.energyAxis, beam: beam, listed: listed,
                                                computedK: computedK, regionName: regionName, metadata: source.metadata)
            } catch ProposerError.cancelled {
                return
            } catch {
                failure = "Auto ID could not fit this spectrum: \((error as? LocalizedError)?.errorDescription ?? "\(error)")"
            }
            if Task.isCancelled { return }
            let finalOutcome = outcome, finalFailure = failure
            await self?.landAutoID(finalOutcome, failure: finalFailure, run: run)
        }
        autoIDTask = task
        return task
    }

    private func landAutoID(_ outcome: EDXCompute.AutoIDOutcome?, failure: String?, run: Int) {
        guard run == autoIDRun, case .running = autoID else { return }
        guard let outcome else { autoID = .failed(failure ?? "Auto ID failed."); return }
        var decided = outcome
        decided.suggestions = outcome.suggestions.filter { s in !dismissed.contains(s.symbol) && !picks.contains(where: { $0.symbol == s.symbol }) }
        autoID = .done(decided)
        var applied = false
        for s in outcome.suggestions where !dismissed.contains(s.symbol) && !picks.contains(where: { $0.symbol == s.symbol }) {
            picks.append(EDXPick(symbol: s.symbol, role: s.role, manual: false))
            applied = true
        }
        if applied {
            picks.sort { (EDXElements.z(of: $0.symbol) ?? 0) < (EDXElements.z(of: $1.symbol) ?? 0) }
            refresh()
        }
    }

    // MARK: Quantify

    /// The Quantify verb: fits the region's pooled spectrum with the method and, from now on, keeps it live. The method takes
    /// the run's own (a computed k's source string filled in), so an export names it.
    @discardableResult
    package func quantify() -> Task<Void, Never>? {
        guard canQuantify else { return nil }
        quantifyActive = true
        return refresh()
    }

    // MARK: Compute

    /// Recomputes everything the current choices show. Cheap when nothing it needs is new: the region's spectrum, each
    /// window's map and the axis refinement are cached by their content.
    @discardableResult
    private func refresh() -> Task<Void, Never>? {
        guard let source else { return nil }
        refreshTask?.cancel(); checkTask?.cancel()
        generation += 1
        isRefreshing = true
        let gen = generation
        let region = region, picks = picks, cache = cache
        var request: QuantificationMethod?
        if quantifyActive && canQuantify {
            var m = method
            m.elements = picks.map { QuantificationMethod.ElementState(symbol: $0.symbol, role: $0.role == .quantify ? .quantify : .fitOnly, isManual: $0.manual) }
                + dismissed.sorted().map { QuantificationMethod.ElementState(symbol: $0, role: .off, isManual: true) }
            request = m
            isFitting = true
            isChecking = false
        } else if quantifyActive {
            fit = nil; fitFailure = nil; isFitting = false; isChecking = false
        }
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            let interval = Signposts.begin("edx.refresh")
            let spectrum = EDXCompute.spectrum(source: source, region: region, cache: cache)
            if Task.isCancelled { return }
            let windows = EDXCompute.windows(source: source, spectrum: spectrum, picks: picks, cache: cache)
            if Task.isCancelled { return }
            var quantified: EDXCompute.Quantified?
            var failure: String?
            if let method = request {
                do { quantified = try EDXCompute.quantify(spectrum: spectrum, region: region, source: source, method: method, cache: cache) }
                catch is SpectroCancelled { return }
                catch { failure = (error as? LocalizedError)?.errorDescription ?? "\(error)" }
            }
            Signposts.end(interval)
            if Task.isCancelled { return }
            await self?.land(spectrum: spectrum, windows: windows, quantified: quantified, failure: failure, picks: picks,
                             region: region, generation: gen)
        }
        refreshTask = task
        return task
    }

    private func land(spectrum: [UInt64], windows: EDXCompute.Windows, quantified: EDXCompute.Quantified?, failure: String?,
                      picks usedPicks: [EDXPick], region usedRegion: EDXRegion, generation gen: Int) {
        guard gen == generation, let source else { return }
        isRefreshing = false
        isPreviewing = false
        let axis = source.energyAxis
        spectrumCounts = spectrum
        totalCounts = spectrum.reduce(UInt64(0), &+)
        regionPixels = usedRegion.pixelCount(nx: source.nx, ny: source.ny)
        plot = EDXPlot(energyStart: axis.offset, energyStep: axis.scale, data: spectrum.map { Double($0) })

        // The rows and tiles of the quantified elements; a fit-only element shapes the windows, not the table.
        var rows: [EDXWindowRow] = []
        var newTiles: [EDXMapTile] = []
        var done = Set<String>()
        for w in windows.windows where done.insert(w.element).inserted {
            let group = windows.windows.indices.filter { windows.windows[$0].element == w.element }
            let i = group.first { windows.counts[$0] != nil } ?? group[0]
            if let c = windows.counts[i] {
                rows.append(EDXWindowRow(symbol: w.element, line: ElementWindows.label(ofLineID: c.id), net: c.net, sigma: c.sigma,
                                         note: ElementWindows.conflictNote(w.conflicts), failure: c.notAMeasurementText))
            } else {
                rows.append(EDXWindowRow(symbol: w.element, line: w.element, net: 0, sigma: 0, note: nil, failure: w.failure))
            }
            if usedPicks.first(where: { $0.symbol == w.element })?.role == .quantify, let map = EDXCompute.elementMap(w.element, in: windows) {
                tileVersion += 1
                newTiles.append(EDXMapTile(symbol: w.element, width: source.nx, height: source.ny, values: map, version: tileVersion,
                                           line: ElementWindows.label(ofLineID: windows.windows[i].id),
                                           note: group.compactMap { windows.counts[$0]?.notAMeasurementText }.first))
            }
        }
        windowRows = rows
        tiles = newTiles
        markers = Self.markers(windows.windows, picks: usedPicks)
        lastWindows = windows

        if quantifyActive {
            isFitting = false
            fitFailure = failure
            if let q = quantified {
                fit = UnlistedLineChecker.holding(q.fit)
                method = q.fit.method   // the run's own: a computed k's source string and date filled in
                method.elements = []    // the picks are the elements; the method carries them only while a fit runs
                plot = Self.plot(spectrum: spectrum, fit: fit!)
                startCheck(q, region: usedRegion, generation: gen)
            } else {
                fit = nil
            }
        }
        // The composition maps read the windows and, for a computed k, the fit: asked once both have landed.
        if mapMode != .net { startMaps() } else { clearQuantMaps() }
        if !pins.isEmpty { refreshPinData() }
    }

    private func startCheck(_ q: EDXCompute.Quantified, region used: EDXRegion, generation gen: Int) {
        isChecking = true
        let cache = cache
        checkTask?.cancel()
        checkTask = Task.detached(priority: .utility) { [weak self] in
            let shown: PooledQuantification
            do { shown = try EDXCompute.checked(q, region: used, cache: cache) }
            catch ProposerError.cancelled { return }   // superseded by a newer fit: a silent discard
            catch is SpectroCancelled { return }
            catch {
                let why = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                let failed = UnlistedLineChecker.withholding(q.fit, .failed(why))
                await self?.landCheck(failed, generation: gen)
                return
            }
            if Task.isCancelled { return }
            await self?.landCheck(shown, generation: gen)
        }
    }

    /// A finished check lands only on the fit it was run for: any newer refresh has bumped `generation`.
    private func landCheck(_ shown: PooledQuantification?, generation gen: Int) {
        guard gen == generation else { return }
        isChecking = false
        guard let shown else { return }
        fit = shown
        plot = Self.plot(spectrum: spectrumCounts, fit: shown)
    }

    private static func plot(spectrum: [UInt64], fit: PooledQuantification) -> EDXPlot {
        EDXPlot(energyStart: fit.usedAxis.offset, energyStep: fit.usedAxis.scale, data: spectrum.map { Double($0) },
                background: fit.plotBackground, model: fit.plotModel, fitChannels: fit.fit.channels)
    }

    /// The alpha line of the default family of every picked element, where it lies on the axis.
    private static func markers(_ windows: [LineWindow], picks: [EDXPick]) -> [EDXMarker] {
        var seen = Set<String>()
        return windows.compactMap { w in
            guard w.window != nil, let line = XRayLines.line(w.id), seen.insert(w.id).inserted else { return nil }
            let role = picks.first { $0.symbol == w.element }?.role
            return EDXMarker(symbol: w.element, label: ElementWindows.label(ofLineID: w.id), energy: line.energy, quantified: role == .quantify)
        }
    }

    /// Returns when the room is at rest: no pass in flight, the last fit checked, Auto ID answered. A pass that lands can start
    /// the next (Auto ID's picks refresh the maps; a fit starts its check), so this loops until the generation stops moving.
    package func settled() async {
        for _ in 0..<20 {
            let seen = (generation, autoIDRun, mapsRun)
            await refreshTask?.value
            await checkTask?.value
            await autoIDTask?.value
            await mapsTask?.value
            await pinDataTask?.value
            if (generation, autoIDRun, mapsRun) == seen && !isFitting && !isChecking && autoID != .running && mapsState != .running { return }
        }
    }

    // MARK: Composition maps

    private func clearQuantMaps() {
        mapsTask?.cancel(); mapsTask = nil; mapsRun += 1
        quantTiles = [:]; quantMaps = nil; mapsState = .idle
    }

    /// The composition pass: `EDXQuantification.quantifyMaps` on the quantified elements' net maps with the typed k, over the whole scan
    /// whatever region is selected (the region only defines the results table and the fit). Detached; it lands only if no newer pass was asked meanwhile.
    @discardableResult
    private func startMaps() -> Task<Void, Never>? {
        mapsTask?.cancel(); mapsRun += 1
        guard mapMode != .net, let source, let windows = lastWindows else { return nil }
        let inputs = EDXQuantMaps.inputs(quantified: picks.filter { $0.role == .quantify }.map(\.symbol), windows: windows)
        let prepared: EDXQuantMaps.Prepared
        do {
            prepared = try EDXQuantMaps.prepare(method: method, mapMethod: mapMethod, dose: dose, symbols: inputs.symbols,
                                                lineEnergies: EDXQuantMaps.lineEnergies(windows), fit: fit, metadata: source.metadata)
            // Cliff-Lorimer gives a mass thickness only with the absorption correction (and a typed thickness).
            if mapMode == .massThickness, mapMethod == .cliffLorimer, prepared.setup.absorption == nil { throw EDXQuantMaps.Refusal.noMassThickness }
        } catch {
            quantTiles = [:]; quantMaps = nil
            mapsState = .blocked((error as? LocalizedError)?.errorDescription ?? "\(error)")
            return nil
        }
        mapsState = .running
        let setup = prepared.setup
        let run = mapsRun, dose = dose, nx = source.nx, ny = source.ny
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            var result: EDXQuantificationMaps?
            var failure: String?
            do { result = try EDXQuantMaps.run(maps: inputs.maps, nx: nx, ny: ny, setup: setup, region: .wholeMap) }
            catch { failure = (error as? LocalizedError)?.errorDescription ?? "\(error)" }
            if Task.isCancelled { return }
            let done = result, why = failure
            await self?.landMaps(done, failure: why, prepared: prepared, dose: dose, run: run)
        }
        mapsTask = task
        return task
    }

    private func landMaps(_ result: EDXQuantificationMaps?, failure: String?, prepared: EDXQuantMaps.Prepared,
                          dose usedDose: EDXDoseInputs, run: Int) {
        guard run == mapsRun, let source else { return }
        guard let result else {
            quantTiles = [:]; quantMaps = nil
            mapsState = .failed(failure ?? "The composition maps failed.")
            return
        }
        var byMode: [EDXMapMode: [EDXMapTile]] = [:]
        for mode in [EDXMapMode.weight, .atomic] {
            let footer = EDXQuantMaps.footer(mode: mode, factorText: prepared.factorText, absorptionText: prepared.absorptionText,
                                             dose: prepared.setup.beamCurrentNA == nil ? nil : usedDose, result: result, masked: 0)
            byMode[mode] = result.elements.indices.compactMap { i in
                guard let values = EDXQuantMaps.values(result, element: i, mode: mode) else { return nil }
                tileVersion += 1
                let symbol = result.elements[i]
                let net = tiles.first { $0.symbol == symbol }
                return EDXMapTile(symbol: symbol, width: source.nx, height: source.ny, values: values, version: tileVersion,
                                  line: (net?.line ?? symbol) + " \u{00B7} " + mode.title, note: nil, mode: mode, footer: footer)
            }
        }
        if let mass = result.massThickness {
            tileVersion += 1
            byMode[.massThickness] = [EDXMapTile(symbol: EDXMapMode.massThickness.title, width: source.nx, height: source.ny, values: mass, version: tileVersion,
                                                 line: "mass thickness", note: nil, mode: .massThickness,
                                                 footer: EDXQuantMaps.footer(mode: .massThickness, factorText: prepared.factorText, absorptionText: prepared.absorptionText,
                                                                             dose: prepared.setup.beamCurrentNA == nil ? nil : usedDose, result: result, masked: 0))]
        }
        quantTiles = byMode
        quantMaps = result
        mapsState = .done
    }

    // MARK: Typed k and the dose methods

    /// Chooses how the maps are quantified. Zeta and cross section need their factors and the dose (the sheet); the pooled fit stays Cliff-Lorimer.
    package func setMapMethod(_ new: EDXMapMethod) {
        guard new != mapMethod else { return }
        mapMethod = new
        if mapMode != .net { startMaps() }
    }

    /// Commits the factors sheet for `draft.method` (zeta or cross section); an incomplete draft writes nothing.
    package func commitFactors(_ draft: EDXFactorsDraft, date: String) {
        guard draft.isComplete, draft.method != .cliffLorimer else { return }
        dose = draft.applying(to: dose, date: date)
        if mapMode != .net { startMaps() }
    }

    /// Chooses computed or typed k-factors; the fit and the maps follow. Typed keeps what was typed.
    package func setKFactorSource(_ source: QuantificationMethod.KFactorSource) {
        changeMethod { m in
            guard m.kFactorSource != source else { return }
            m.kFactorSource = source
            if source == .computed { m.typedK = []; m.kSource = ""; m.kDate = ""; m.kReference = nil }
        }
    }

    /// Commits the typed-k sheet: k with its σ per element, the source line and the date it was typed.
    package func commitTypedK(_ draft: EDXTypedKDraft, date: String) {
        guard draft.isComplete else { return }
        changeMethod { m in
            m.kFactorSource = .typed
            m.typedK = draft.entries
            m.kSource = draft.source.trimmingCharacters(in: .whitespacesAndNewlines)
            m.kDate = date
        }
    }

    /// The quantified elements the typed-k sheet lists.
    package var quantifiedSymbols: [String] { picks.filter { $0.role == .quantify }.map(\.symbol) }

    // MARK: Export

    package var resultsCSV: String? { fit.map { EDXCompute.resultsCSV($0, regionName: region.name) } }
    package var methodJSON: String? { fit.map { SpectroscopyExport.methodJSON($0.method) } }
    /// The region's spectrum as an `.msa` file (FormatoKit's writer); nil before there is a spectrum.
    package func spectrumMSA() throws -> Data? {
        guard let source, !spectrumCounts.isEmpty else { return nil }
        return try EDXExports.msa(counts: spectrumCounts, axis: source.energyAxis, title: "\(fileName) \(region.name)", beamEnergyKeV: beamEnergy)
    }
    package var spectrumCSV: String? {
        guard let source, !spectrumCounts.isEmpty else { return nil }
        return EDXCompute.spectrumCSV(counts: spectrumCounts, axis: source.energyAxis, fileName: fileName, regionName: region.name)
    }
}
