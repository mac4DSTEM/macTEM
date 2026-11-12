//
//  EELSRegionSpectraTests.swift
//  The EELS room's regions as the EDS room has them (the owner's first look at 143, 2026-10-23): each visible region's core loss is summed for the spectrum's overlay,
//  and the spectrum follows a region while it is drawn, moved or resized, the selected region and the results waiting for the release.
//
//  WHAT IS PINNED: the sums are the kit's (`CoreLossSpectrumImage.sum(mask:)`) over the region's mask, on a 2 x 2 core loss whose pixel k holds 100 (k + 1) counts in
//  every channel, so a one-pixel region reads its own level and the whole map 1000. Red under: no core-loss layer; the preview shown on release only; a stale preview
//  landing over a committed region; the drag's spectrum left up until the fitted plot lands; a kept region drawn again without its spectrum; a selection
//  changed with no drag whose spectrum waits for the fitted plot.
//

import XCTest
import ShellSpectroscopy
import SpectroEDX
import SpectroEELS
import TEMCore
import TEMSession
@testable import macTEM
import ShellEDXModel

nonisolated final class EELSRegionSpectraTests: XCTestCase {
    static let nx = 2, ny = 2, coreChannels = 300   // 300 to 599 eV: N K and O K are offered

    static func loaded(collectionMrad: Double? = 10) throws -> LoadedEELS {
        var counts = [Double](repeating: 0, count: nx * ny * coreChannels)
        for k in 0..<(nx * ny) { for c in 0..<coreChannels { counts[k * coreChannels + c] = 100 * Double(k + 1) } }
        let core = try CoreLossSpectrumImage(nx: nx, ny: ny, channels: coreChannels, counts: counts, energyOffsetEV: 300, energyScaleEV: 1)
        // The low loss is the room tests' planted one, cut to the same 2 x 2 scan.
        let low = try EELSRoomTests.image()
        var lowCounts = [Double]()
        for k in 0..<(nx * ny) { lowCounts += Array(low.counts[(k * low.channels)..<((k + 1) * low.channels)]) }
        let lowCut = try LowLossSpectrumImage(nx: nx, ny: ny, channels: low.channels, counts: lowCounts, energyOffsetEV: low.energyOffsetEV, energyScaleEV: low.energyScaleEV)
        return LoadedEELS(fileName: "regions.dm4", image: lowCut, beamEnergyKeV: 200, convergenceMrad: 0, collectionMrad: collectionMrad, origin: "planted",
                          coreLoss: core, coreLossOrigin: "planted core")
    }

    @MainActor private func openRoom() async throws -> EELSSession {
        let session = EELSSession()
        await session.bind(try Self.loaded()).value
        await session.settled()
        return session
    }

    /// Each visible region carries its summed core loss for the overlay; a hidden one does not.
    @MainActor func testEachVisibleRegionCarriesItsCoreLossForTheOverlay() async throws {
        let session = try await openRoom()
        let first = try XCTUnwrap(session.drawRegion(.rectangle(PixelRect(x0: 0, y0: 0, x1: 1, y1: 1))))
        let last = try XCTUnwrap(session.drawRegion(.rectangle(PixelRect(x0: 1, y0: 1, x1: 2, y1: 2))))
        await session.settled()
        XCTAssertEqual(session.pinCoreSpectra[first.id], [Double](repeating: 100, count: Self.coreChannels))
        XCTAssertEqual(session.pinCoreSpectra[last.id], [Double](repeating: 400, count: Self.coreChannels))
        session.setPinVisible(first.id, false)
        await session.settled()
        XCTAssertNil(session.pinCoreSpectra[first.id], "a hidden region has no layer")
    }

    /// A selected region is drawn against the whole map (its spectrum kept beside the region's, grey under it); a dragged window goes back to the kit's default
    /// by edge or all at once (the owner's drive, 2026-10-23). Red under: no whole-map plot with a region selected; no way back to the defaults.
    @MainActor func testARegionReadsAgainstTheWholeMapAndWindowsReset() async throws {
        let session = try await openRoom()
        session.drawRegion(.rectangle(PixelRect(x0: 0, y0: 0, x1: 1, y1: 1)))
        await session.settled()
        XCTAssertEqual(session.plot?.core?.counts.first, 100, "the plot is the region's")
        XCTAssertEqual(session.wholeMapPlot?.core?.counts.first, 1000, "the whole map is kept beside it")
        let layers = EELSLowerPane.layers(session)
        XCTAssertEqual(layers.first?.name, "Whole map", "the whole map is the first layer, under the regions")

        let edge = try XCTUnwrap(session.offeredEdges.first)
        session.toggleEdge(edge)
        let defaults = session.windows(for: edge)
        var moved = defaults
        moved.signal = (defaults.signal.lowerBound + 2)...(defaults.signal.upperBound + 2)
        session.setWindows(moved, for: edge)
        XCTAssertTrue(session.hasEditedWindows)
        session.resetWindows(for: edge)
        XCTAssertEqual(session.windows(for: edge), defaults); XCTAssertFalse(session.hasEditedWindows)
        session.setWindows(moved, for: edge)
        session.resetAllWindows()
        XCTAssertEqual(session.windows(for: edge), defaults); XCTAssertFalse(session.hasEditedWindows)
        let room = try String(contentsOfFile: #filePath.replacingOccurrences(of: "macTEMTests/EELSRegionSpectraTests.swift", with: "macTEM/UI/EELSRoom.swift"), encoding: .utf8)
        XCTAssertTrue(room.contains("onResetWindows(item.edge)"), "a double click or the menu resets an edge's windows")
        XCTAssertTrue(room.contains(".alternatingRowBackgrounds(.disabled)"), "the results table shows its rows only")
    }

    /// A region still under the pointer: the plot follows it while the drag runs; the selected region and the results wait for the release. Ending the preview
    /// without a commit puts the selected region's spectrum back; a region committed on release wins over a preview still in flight.
    @MainActor func testADragPreviewsTheSpectrumAndTheReleaseCommits() async throws {
        let session = try await openRoom()
        let whole = try XCTUnwrap(session.plot?.core?.counts)
        XCTAssertEqual(whole.first, 1000)
        await session.previewRegion(.rectangle(PixelRect(x0: 1, y0: 0, x1: 2, y1: 1)))?.value
        XCTAssertEqual(session.plot?.core?.counts.first, 200, "the plot is the dragged pixel's spectrum while dragging")
        XCTAssertNil(session.selectedPinID, "the selection waits for the release")
        XCTAssertTrue(session.pins.isEmpty)
        await session.previewRegion(nil)?.value
        await session.settled()
        XCTAssertEqual(session.plot?.core?.counts, whole, "no region was committed: the whole map's spectrum is back")

        let late = session.previewRegion(.rectangle(PixelRect(x0: 1, y0: 0, x1: 2, y1: 1)))
        session.previewRegion(nil)
        session.drawRegion(.rectangle(PixelRect(x0: 0, y0: 1, x1: 1, y1: 2)))
        await late?.value
        await session.settled()
        XCTAssertEqual(session.plot?.core?.counts.first, 300, "the committed region's spectrum, not the late preview's")
        XCTAssertNotNil(session.selectedPinID)
    }

    /// Right after a drag the plot on screen is the live spectrum of a shape that is not the selected one. On the commit the committed region's own spectrum goes
    /// up at once, summed without the model, ahead of the fitted plot (the 2026-11-11 drive read "Selection · 552 px" beside a 1722 px region while the fit ran).
    /// The live spectrum is named as the shape is or will be kept, never "Selection", and the results header names the selected region. A refresh with no drag
    /// before it lands in one step. Red under: a commit that leaves the drag's spectrum up until the fitted plot lands; a live spectrum called "Selection".
    @MainActor func testAfterADragTheCommittedRegionsSpectrumGoesUpBeforeTheFittedPlot() async throws {
        let session = try await openRoom()
        await session.previewRegion(.rectangle(PixelRect(x0: 1, y0: 0, x1: 2, y1: 1)))?.value
        XCTAssertEqual(session.plot?.regionName, "Region 1", "a new shape's live spectrum carries the name it will be kept under")
        XCTAssertEqual(session.plot?.pixels, 1)
        XCTAssertEqual(session.selectedRegionName, "Whole map", "the results are still the whole map's while the drag runs")
        session.previewRegion(nil)
        // Pixels 0 and 2 of the planted core loss: 100 + 300 counts in every channel.
        let pin = try XCTUnwrap(session.drawRegion(.rectangle(PixelRect(x0: 0, y0: 0, x1: 1, y1: 2))))
        XCTAssertEqual(pin.name, "Region 1")
        XCTAssertEqual(session.selectedRegionName, pin.name, "the results header names the kept region at the release")
        await session.plotInterimTask?.value
        XCTAssertEqual(session.plot?.regionName, pin.name, "the committed region's spectrum, not the drag's")
        XCTAssertEqual(session.plot?.pixels, 2)
        XCTAssertEqual(session.plot?.core?.counts.first, 400)
        await session.settled()
        XCTAssertEqual(session.plot?.regionName, pin.name)
        XCTAssertEqual(session.plot?.core?.counts.first, 400)

        // A handle dragged on the kept region: its live spectrum keeps the region's name, and a new shape's takes the next one.
        await session.previewRegion(.rectangle(PixelRect(x0: 0, y0: 0, x1: 1, y1: 1)), editing: pin.id)?.value
        XCTAssertEqual(session.plot?.regionName, pin.name)
        XCTAssertEqual(session.plot?.pixels, 1)
        await session.previewRegion(nil)?.value
        await session.settled()
        await session.previewRegion(.rectangle(PixelRect(x0: 1, y0: 1, x1: 2, y1: 2)))?.value
        XCTAssertEqual(session.plot?.regionName, "Region 2")
        await session.previewRegion(nil)?.value
        await session.settled()
        XCTAssertEqual(session.plot?.regionName, pin.name, "no shape was kept: the selected region's spectrum is back")

        session.selectWholeMap()
        await session.settled()
        XCTAssertEqual(session.plot?.regionName, "Whole map")
        session.refreshPlot()
        XCTAssertNil(session.plotInterimTask, "the shape on screen refreshed: one landing, the model stays up until the new one")
        await session.settled()
        XCTAssertEqual(session.plot?.regionName, "Whole map")
    }

    /// With no drag before it the spectrum still follows the selection at once: a region drawn by Return, a click back to the whole map and a pick in the
    /// Regions table each put the selected shape's own spectrum up ahead of the fitted plot. On the 2026-11-11 re-drive the header kept Region 1 under a
    /// new Region 2 and under Whole map while the fitted plots ran. While a new region's fit runs, the results say it is fitting, not "Run fits them".
    /// Red under: a quick spectrum only after a drag; a region with edges picked and no rows yet read as "not fitted".
    @MainActor func testTheSpectrumFollowsEveryChangeOfSelectionAtOnce() async throws {
        let session = try await openRoom()
        session.toggleEdge(.nitrogenK)
        session.toggleEdge(.oxygenK)
        let first = try XCTUnwrap(session.drawRegion(.rectangle(PixelRect(x0: 0, y0: 0, x1: 1, y1: 2))))
        XCTAssertTrue(session.isFittingSelectedRegion, "the new region's rows are on their way")
        XCTAssertEqual(EELSRoomFormat.fittingLine(region: session.selectedRegionName), "Fitting Region 1…")
        XCTAssertNotNil(session.plotInterimTask, "a region drawn without a drag: its spectrum goes up first")
        await session.plotInterimTask?.value
        XCTAssertEqual(session.plot?.regionName, first.name)
        XCTAssertEqual(session.plot?.core?.counts.first, 400)
        await session.settled()
        XCTAssertFalse(session.isFittingSelectedRegion, "the rows landed")

        let second = try XCTUnwrap(session.drawRegion(.rectangle(PixelRect(x0: 1, y0: 0, x1: 2, y1: 1))))
        XCTAssertNotNil(session.plotInterimTask)
        await session.plotInterimTask?.value
        XCTAssertEqual(session.plot?.regionName, second.name, "the new region's spectrum, not the one before it")
        XCTAssertEqual(session.plot?.core?.counts.first, 200)

        session.selectWholeMap()
        XCTAssertNotNil(session.plotInterimTask, "back to the whole map: its spectrum goes up first")
        await session.plotInterimTask?.value
        XCTAssertEqual(session.plot?.regionName, "Whole map")
        XCTAssertEqual(session.plot?.core?.counts.first, 1000)
        XCTAssertFalse(session.isFittingSelectedRegion, "the whole map is not a region being fitted")

        session.selectPin(first.id)
        XCTAssertNotNil(session.plotInterimTask, "a pick in the Regions table: its spectrum goes up first")
        await session.plotInterimTask?.value
        XCTAssertEqual(session.plot?.regionName, first.name)
        await session.settled()
        XCTAssertEqual(session.plot?.regionName, first.name)
        XCTAssertEqual(session.plot?.core?.counts.first, 400)

        // No edges picked: a new region has nothing to fit, and the body keeps "No edges fitted yet"; nor does an edge picked once the rows are on
        // their way, which that refresh does not fit.
        session.toggleEdge(.nitrogenK)
        session.toggleEdge(.oxygenK)
        session.drawRegion(.rectangle(PixelRect(x0: 1, y0: 1, x1: 2, y1: 2)))
        XCTAssertFalse(session.isFittingSelectedRegion)
        session.toggleEdge(.nitrogenK)
        XCTAssertTrue(session.isRefreshingRegions)
        XCTAssertFalse(session.isFittingSelectedRegion, "the running refresh started with no edge")
        await session.settled()

        // No collection angle: the microscope is unknown, a region's rows are summed without a fit, and the body never says "Fitting".
        let unknown = EELSSession()
        await unknown.bind(try Self.loaded(collectionMrad: nil)).value
        await unknown.settled()
        unknown.toggleEdge(.nitrogenK)
        unknown.drawRegion(.rectangle(PixelRect(x0: 0, y0: 0, x1: 1, y1: 2)))
        XCTAssertTrue(unknown.isRefreshingRegions)
        XCTAssertFalse(unknown.isFittingSelectedRegion, "no fit can run without the collection angle")
        await unknown.settled()
    }

    /// A region removed and its box drawn again before the whole map's spectrum landed is a new region under a new name: its spectrum goes up at
    /// once, not after the fitted plot with the removed region's name on it. Red under: a plot keyed by its shape alone.
    @MainActor func testTheSameBoxKeptAgainUnderANewNameGoesUpAtOnce() async throws {
        let session = try await openRoom()
        let box = PixelRect(x0: 0, y0: 0, x1: 1, y1: 2)
        let first = try XCTUnwrap(session.drawRegion(.rectangle(box)))
        await session.settled()
        XCTAssertEqual(session.plot?.regionName, first.name)
        session.removePin(first.id)
        let second = try XCTUnwrap(session.drawRegion(.rectangle(box)))
        XCTAssertNotEqual(second.id, first.id)
        XCTAssertEqual(second.name, "Region 2")
        XCTAssertNotNil(session.plotInterimTask, "the same box, another region: its spectrum goes up first")
        await session.plotInterimTask?.value
        XCTAssertEqual(session.plot?.regionName, second.name)
        await session.settled()
        XCTAssertEqual(session.plot?.regionName, second.name)
    }

    /// Drawing a region that is already kept selects it, and the spectrum follows the selection: Return on the colour mix draws the middle box, and a second
    /// Return after Whole map left the header on the whole map with the region selected. Red under: a draw of a kept region that selects it without a new plot.
    @MainActor func testDrawingAKeptRegionAgainSelectsItAndShowsItsSpectrum() async throws {
        let session = try await openRoom()
        let box = PixelRect(x0: 0, y0: 0, x1: 1, y1: 2)
        let first = try XCTUnwrap(session.drawRegion(.rectangle(box)))
        await session.settled()
        session.selectWholeMap()
        await session.settled()
        XCTAssertEqual(session.plot?.regionName, "Whole map")
        let again = try XCTUnwrap(session.drawRegion(.rectangle(box)))
        XCTAssertEqual(again.id, first.id, "the kept region, not a new one")
        XCTAssertEqual(session.pins.count, 1)
        await session.settled()
        XCTAssertEqual(session.selectedPinID, first.id)
        XCTAssertEqual(session.plot?.regionName, first.name)
        XCTAssertEqual(session.plot?.core?.counts.first, 400)
    }
}

/// Zero-loss alignment as a feature of the room (the owner, 2026-10-23: "the 0 loss alignment has to be a feature for sure"): on a cube whose zero-loss peak is planted
/// at a different energy in each pixel, Align moves each pixel by the planted difference and the ZLP shift tile carries those shifts (the kit's own parity with exSpy's
/// `align_zero_loss_peak` is SpectroKit's AlignPinsTests; this pins that the room hands them on). Red under: a tile of zeros, or shifts lost on the way to the tile.
nonisolated final class EELSAlignmentInRoomTests: XCTestCase {
    static let centres = [0.0, 1.0, -1.5, 0.5]   // eV, one per pixel of a 2 x 2 scan
    static let channels = 256, offset = -10.0, scale = 0.25

    static func planted() throws -> LoadedEELS {
        var counts = [Double]()
        for c0 in centres {
            for i in 0..<channels {
                let e = offset + scale * Double(i)
                counts.append(1e4 * exp(-0.5 * pow((e - c0) / 0.8, 2)) + 500 * exp(-0.5 * pow((e - c0 - 15) / 3, 2)))
            }
        }
        let low = try LowLossSpectrumImage(nx: 2, ny: 2, channels: channels, counts: counts, energyOffsetEV: offset, energyScaleEV: scale)
        return LoadedEELS(fileName: "shifted.dm4", image: low, beamEnergyKeV: 200, convergenceMrad: 0, collectionMrad: 10, origin: "planted")
    }

    @MainActor func testAlignRecoversPlantedShiftsAndTheShiftTileCarriesThem() async throws {
        let session = EELSSession()
        await session.bind(try Self.planted()).value
        await session.settled()
        await session.align()?.value
        await session.settled()
        let tile = try XCTUnwrap(session.alignmentShiftTile, "Align makes the ZLP shift tile")
        let mean = Self.centres.reduce(0, +) / Double(Self.centres.count)
        for (k, c0) in Self.centres.enumerated() {
            // The kit moves each pixel's peak to the mean centre (then recalibrates the axis); planted shifts come back to a quarter channel (the kit's own test).
            XCTAssertEqual(tile.values[k], mean - c0, accuracy: Self.scale / 4, "pixel \(k)")
        }
        XCTAssertNil(tile.flatValueText, "a cube with planted shifts is not flat")
        XCTAssertTrue(session.alignmentReadout?.contains("shifts up to") == true, session.alignmentReadout ?? "no readout")
    }

    /// A file that came aligned (143: every zero-loss centre at 0 eV before Align) says so instead of drawing a flat tile; the tile is there on the ZLP segment.
    func testAFileThatCameAlignedSaysSoAndDrawsNoFlatTile() {
        let en = Locale(identifier: "en_US")
        XCTAssertEqual(EELSRoomFormat.shiftSummary([0, 0, nil, 0], channelEV: 0.75, locale: en), "already aligned in the file, max |shift| 0 eV")
        XCTAssertEqual(EELSRoomFormat.shiftSummary([0.25, -0.125], channelEV: 0.75, locale: en), "already aligned in the file, max |shift| 0.25 eV")
        XCTAssertEqual(EELSRoomFormat.shiftSummary([0.5, -1.25], channelEV: 0.75, locale: en), "shifts up to 1.25 eV")
        func tile(_ id: String, _ v: [Double]) -> EELSMapTile { EELSMapTile(id: id, title: id, unit: "eV", width: 2, height: 1, values: v, version: 1, footer: nil) }
        let t = tile("tOverLambda", [0.3, 0.4]), flat = tile("zlpShift", [0, 0]), moved = tile("zlpShift", [0.5, -0.5])
        XCTAssertFalse(EELSMapsComposition.compose(selection: .tOverLambda, onlyCoreLoss: false, tiles: [t], shiftTile: flat, modelTiles: []).rest.contains { $0.id == "zlpShift" })
        XCTAssertTrue(EELSMapsComposition.compose(selection: .tOverLambda, onlyCoreLoss: false, tiles: [t], shiftTile: moved, modelTiles: []).rest.contains { $0.id == "zlpShift" })
        XCTAssertEqual(EELSMapsComposition.compose(selection: .zlp, onlyCoreLoss: false, tiles: [t], shiftTile: flat, modelTiles: []).anchor?.id, "zlpShift")
    }
}

/// The EELS exports beside the per-pixel CSV and the method JSON, as the EDS room has them (the owner's drive, 2026-10-23). Red under: no such writer.
nonisolated final class EELSExportsTests: XCTestCase {
    func testResultsSpectrumAndRegionsAreCSVWithTheirProvenance() throws {
        let c = EELSEdgeRow(id: "C-K", title: "C K", onsetEV: 284, intensity: 1.925e-4, arealDensityPerNM2: 1.925e6, atomicPercent: 95.8, weightPercent: 94.5,
                            exponent: 3.95, unavailable: nil, intensityStd: 8.1e-10, atomicSigma: 0.4, weightSigma: 0.5)
        let n = EELSEdgeRow(id: "N-K", title: "N K", onsetEV: 401, intensity: 0, arealDensityPerNM2: 0, atomicPercent: 0, weightPercent: 0,
                            unavailable: nil, intensityStd: 1.4e-9)
        let results = EELSExports.resultsCSV([c, n], fileName: "143.dm4", regionName: "Whole map", thickness: "t/λ 0.52", method: "Exact NNLS")
        let lines = results.split(separator: "\n")
        XCTAssertTrue(lines[0].contains("143.dm4"), String(lines[0]))
        XCTAssertFalse(lines[0].lowercased().contains("validat"), "no trust word: \(lines[0])")
        XCTAssertTrue(lines[0].contains("thickness: Malis, Cheng and Egerton, J. Electron Microsc. Tech. 8 (1988) 193"), String(lines[0]))
        XCTAssertTrue(lines[0].contains("edges: exSpy 7185a4d1 with the dft GOS tables (Segger, Guzzinati and Kohl, v1.5.0)"), String(lines[0]))
        XCTAssertEqual(lines[3], "edge,onset_eV,intensity,intensity_sigma,areal_density_per_nm2,atomic_percent,atomic_percent_sigma,weight_percent,"
                       + "weight_percent_sigma,exponent_r,below_detection,unavailable")
        XCTAssertEqual(lines[4], "\"C K\",284,0.0001925,8.1e-10,1925000,95.8,0.4,94.5,0.5,3.95,false,")
        XCTAssertTrue(lines[5].hasSuffix(",true,"), "N K is below detection: \(lines[5])")

        let plot = EELSPlotData(regionName: "Region 1", pixels: 4, low: EELSPlotCurve(origin: -1, step: 0.5, counts: [1, 2]),
                                core: EELSPlotCurve(origin: 300, step: 1, counts: [10, 11]), zlpMaskEV: nil, model: [.nan, 10.5], edges: [], thickness: nil)
        let spectrum = EELSExports.spectrumCSV(plot, fileName: "143.dm4").split(separator: "\n")
        XCTAssertEqual(Array(spectrum.dropFirst()), ["segment,energy_eV,counts,model", "low_loss,-1,1,", "low_loss,-0.5,2,", "core_loss,300,10,", "core_loss,301,11,10.5"])

        let pin = EDXPin(name: "Region 1", region: .rectangle(PixelRect(x0: 0, y0: 0, x1: 2, y1: 2)), number: 1)
        let regions = EELSExports.regionsCSV([EELSRegionRow(pin: pin, pixels: 4, totalCounts: 1e6, tOverLambda: 0.5, edges: [c])], fileName: "143.dm4").split(separator: "\n")
        XCTAssertEqual(regions[1], "region,pixels,i_total,t_over_lambda,\"C K intensity\",\"C K intensity_sigma\",\"C K atomic_percent\",\"C K atomic_percent_sigma\"")
        XCTAssertEqual(regions[2], "\"Region 1\",4,1000000,0.5,0.0001925,8.1e-10,95.8,0.4")
        XCTAssertFalse(regions[0].lowercased().contains("validat"), "no trust word: \(regions[0])")
        XCTAssertTrue(regions[0].hasSuffix(", " + EELSLiterature.headerLine), String(regions[0]))
    }

    /// The deconvolution and the edge fit name their reference in the method JSON, not a trust word; the maps captions name the method's
    /// reference. Red under: a "validation" key; a caption that says "validation: none".
    func testTheMethodsNameTheirReferenceNotATrustWord() {
        XCTAssertEqual(EELSLiterature.deconvolution, "Egerton, EELS in the Electron Microscope, 3rd ed. (2011), ch. 4")
        let available = EELSMapsAvailability(alignState: .current, thicknessState: .current, fitState: .current, hasMap: true, hasLambda: true,
                                             hasFit: true, hasComposition: true, onlyCoreLoss: false, fitBlocker: nil)
        let chassis = [EELSMapsSegment.tOverLambda, .thickness, .atomicPercent].map(available.caption)
        for caption in chassis { XCTAssertFalse(caption.lowercased().contains("validat"), caption) }
        XCTAssertTrue(chassis[0].contains("Malis, Cheng and Egerton, J. Electron Microsc. Tech. 8 (1988) 193"), chassis[0])
        XCTAssertTrue(chassis[2].contains("exSpy 7185a4d1"), chassis[2])
    }
}
