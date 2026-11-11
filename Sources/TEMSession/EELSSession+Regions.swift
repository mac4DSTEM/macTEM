//
//  EELSSession+Regions.swift
//  Role: the regions and lines drawn on the EELS room's maps, kept as the EDS room keeps them (`EDXPin`, `EDXLine`): a region drawn
//        is clipped to the scan, kept as the next numbered region and selected, and a kept one is selected (none: the whole map),
//        renamed, hidden, moved or resized, or removed; a line drawn is kept and selected, and a kept one is selected, has its ends
//        moved, or is removed; the selected line's profile is taken on each map tile. With them, what the regions show: each visible
//        region's summed low loss and core loss, every region's row (its t/λ and, once edges are picked, its edge fit), the spectrum
//        plot of the selected region (else of the whole map) with the whole map's drawn in grey under a region's, and the live
//        spectrum of a shape still under the pointer. The state they read and change is `EELSSession`'s (EELSSession.swift).
//
//  The numbers are TEMCore/EELS's and the kits', called with the room's choices: a region's summed low loss and its row
//  `EELSRegionCompute`'s, its summed core loss SpectroKit's `sum(mask:)`, the plots `EELSPlotCompute`'s and a line's profiles
//  MacEMUI's `EDXLineProfiles` (ImagoKit's `LineProfile`). The session's own arithmetic here only clips a drawn shape, or a line's
//  ends, to the scan. The regions' spectra and rows and the plot are made in a detached task and land only if no newer request was
//  made meanwhile (`pinDataRun`, `plotRun`); a drag's live spectrum is summed one shape at a time, and any commit supersedes it.
//

import Foundation
import SpectroEDX
import SpectroEELS
import TEMCore
import ShellEDXModel

extension EELSSession {
    // MARK: Regions and lines

    func resetRegions() {
        pinDataTask?.cancel()
        pins = []; selectedPinID = nil; lines = []; selectedLineID = nil; pinSpectra = [:]; pinCoreSpectra = [:]; pinRows = []; isRefreshingRegions = false
        colorsIssued = 0; regionsIssued = 0; linesIssued = 0
    }

    /// A region drawn on a map: kept as the next numbered region and selected. A shape that holds no pixel changes nothing; one already kept is
    /// selected and its spectrum shown.
    @discardableResult
    package func drawRegion(_ region: EDXRegion) -> EDXPin? {
        guard let image = source?.image else { return nil }
        let clipped = Self.clipped(region, nx: image.nx, ny: image.ny)
        guard let clipped, clipped.pixelCount(nx: image.nx, ny: image.ny) > 0 else { return nil }
        // Already kept: selected, and the spectrum follows the selection (Return on the colour mix draws the middle box again). A key held on a
        // region that is already shown asks for nothing.
        if let existing = pins.first(where: { $0.region == clipped }) {
            let changed = selectedPinID != existing.id
            selectedPinID = existing.id
            if changed || isPreviewing { refreshPlot() }
            return existing
        }
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

    /// The selected line's profile on each of `tiles` (every map the room holds when nil): (tile id, title, positions in scan pixels, samples).
    package func profiles(of tiles: [EELSMapTile]? = nil, width: Int = 1) -> [(id: String, title: String, positions: [Double], samples: [Double])] {
        guard let id = selectedLineID, let line = lines.first(where: { $0.id == id }) else { return [] }
        return (tiles ?? displayedTiles).map { tile in
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
        let kind = fitModel, fitOnly = fitOnlyElements, answered = shownAnswered, fitTo = fitModel == .mlls ? fitToEV : nil, refs = fitReferences
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
                                                   answered: fitCore == nil ? nil : answered, fitToEV: fitTo, references: refs,
                                                   rawCounts: rawCounts) { rows.append(row) }
            }
            if Task.isCancelled { return }
            await self?.landPinData(spectra: spectra, coreSpectra: coreSpectra, rows: rows, run: run, thickness: thicknessMade, fit: fitMade)
        }
    }

    /// The plot of the selected region (the whole map when none is) off the main actor; a newer request drops an older one. Right after a drag the plot on
    /// screen is the live spectrum of a shape that is not the selected one, and the fitted plot can take a while: the selected shape's own spectrum, summed
    /// as a preview is and without the model, lands first (the 2026-11-11 drive read "Selection · 552 px" beside a 1722 px region while the fit ran).
    package func refreshPlot() {
        plotTask?.cancel()
        plotInterimTask?.cancel()
        plotRun += 1
        // A drag's live spectrum is on screen until a plot of the selected shape lands (`isPreviewing` is cleared there, not here), so a second
        // request before that also starts its own quick spectrum.
        let afterPreview = isPreviewing
        plotInterimTask = nil
        guard let low = workingLowLoss else { plot = nil; wholeMapPlot = nil; isPreviewing = false; return }
        let run = plotRun, core = shownCoreLoss, map = map, threshold = threshold, deconvolvedLow = shownDeconvolvedLow, answered = shownAnswered
        let lambda = (try? EELSCompute.source(meanFreePath, beamEnergyKeV: beamEnergyKeV)) ?? nil
        let pin = selectedPin
        let region = pin?.region ?? .wholeMap, name = selectedRegionName
        // The model is drawn only over the core loss it was fitted to (stored or Fourier-ratio deconvolved).
        let fit = model != nil && fitUsed?.deconvolved == (answered != nil) ? fitUsed : nil
        let interim: Task<Void, Never>? = if afterPreview {
            Task.detached(priority: .userInitiated) { [weak self] in
                let quick = EELSPlotCompute.make(name: name, region: region, low: low, core: core, map: map, threshold: threshold, meanFreePath: lambda, fit: nil,
                                                 deconvolvedLow: deconvolvedLow, answered: answered)
                if Task.isCancelled { return }
                await self?.landInterimPlot(quick, run: run)
            }
        } else {
            nil
        }
        plotInterimTask = interim
        plotTask = Task.detached(priority: .userInitiated) { [weak self] in
            let data = EELSPlotCompute.make(name: name, region: region, low: low, core: core, map: map, threshold: threshold, meanFreePath: lambda, fit: fit,
                                            deconvolvedLow: deconvolvedLow, answered: answered)
            let whole = pin == nil ? data : EELSPlotCompute.make(name: "Whole map", region: .wholeMap, low: low, core: core, map: map, threshold: threshold,
                                                                  meanFreePath: lambda, fit: nil, deconvolvedLow: deconvolvedLow, answered: answered)
            // The quick spectrum, when there is one, goes up first: it never covers the fitted plot.
            await interim?.value
            if Task.isCancelled { return }
            await self?.landPlot(data, whole: whole, run: run)
        }
    }

    /// The selected shape's spectrum without the model, shown until the fitted plot lands; nothing when a newer request came meanwhile. It never
    /// lands over the fitted plot of the same request: that plot's task waits for this one to end.
    private func landInterimPlot(_ data: EELSPlotData?, run: Int) {
        guard run == plotRun, let data else { return }
        isPreviewing = false
        plot = data
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
    /// The live spectrum carries the name the shape has (`editing`: the kept region a handle or a move drags) or will have once it is kept (the next new region's), as
    /// Velox names an area's spectrum while it is drawn; "Selection" stayed on the header for a third of a second after a release (the 2026-11-11 drive).
    @discardableResult
    package func previewRegion(_ preview: EDXRegion?, editing: EDXPin.ID? = nil) -> Task<Void, Never>? {
        guard let low = workingLowLoss else { return nil }
        let committed = plotRun
        guard let preview else {
            pendingPreview = nil
            // The release commits right after this call (same event): look once the event is over, then restore only if nothing was committed.
            let task = Task { @MainActor [weak self] in
                await self?.previewTask?.value
                guard let self, self.plotRun == committed, self.isPreviewing else { return }
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
        let name = editing.flatMap { id in pins.first { $0.id == id }?.name } ?? "Region \(regionsIssued + 1)"
        let core = shownCoreLoss, map = map, threshold = threshold, answered = shownAnswered
        let lambda = (try? EELSCompute.source(meanFreePath, beamEnergyKeV: beamEnergyKeV)) ?? nil
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            var next: EDXRegion? = shape
            while let region = next {
                let data = EELSPlotCompute.make(name: name, region: region, low: low, core: core, map: map, threshold: threshold, meanFreePath: lambda, fit: nil,
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
}
