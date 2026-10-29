//
//  EELSRegionSpectraTests.swift
//  The EELS room's regions as the EDS room has them (Paul's first look at 143, 2026-10-23): each visible region's core loss is summed for the spectrum's overlay,
//  and the spectrum follows a region while it is drawn, moved or resized, the selected region and the results waiting for the release.
//
//  WHAT IS PINNED: the sums are the kit's (`CoreLossSpectrumImage.sum(mask:)`) over the region's mask, on a 2 x 2 core loss whose pixel k holds 100 (k + 1) counts in
//  every channel, so a one-pixel region reads its own level and the whole map 1000. Red under: no core-loss layer; the preview shown on release only; a stale preview
//  landing over a committed region.
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

    static func loaded() throws -> LoadedEELS {
        var counts = [Double](repeating: 0, count: nx * ny * coreChannels)
        for k in 0..<(nx * ny) { for c in 0..<coreChannels { counts[k * coreChannels + c] = 100 * Double(k + 1) } }
        let core = try CoreLossSpectrumImage(nx: nx, ny: ny, channels: coreChannels, counts: counts, energyOffsetEV: 300, energyScaleEV: 1)
        // The low loss is the room tests' planted one, cut to the same 2 x 2 scan.
        let low = try EELSRoomTests.image()
        var lowCounts = [Double]()
        for k in 0..<(nx * ny) { lowCounts += Array(low.counts[(k * low.channels)..<((k + 1) * low.channels)]) }
        let lowCut = try LowLossSpectrumImage(nx: nx, ny: ny, channels: low.channels, counts: lowCounts, energyOffsetEV: low.energyOffsetEV, energyScaleEV: low.energyScaleEV)
        return LoadedEELS(fileName: "regions.dm4", image: lowCut, beamEnergyKeV: 200, convergenceMrad: 0, collectionMrad: 10, origin: "planted",
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
    /// by edge or all at once (Paul's drive, 2026-10-23). Red under: no whole-map plot with a region selected; no way back to the defaults.
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
}

/// Zero-loss alignment as a feature of the room (Paul, 2026-10-23: "the 0 loss alignment has to be a feature for sure"): on a cube whose zero-loss peak is planted
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

/// The EELS exports beside the per-pixel CSV and the method JSON, as the EDS room has them (Paul's drive, 2026-10-23). Red under: no such writer.
nonisolated final class EELSExportsTests: XCTestCase {
    func testResultsSpectrumAndRegionsAreCSVWithTheirProvenance() throws {
        let c = EELSEdgeRow(id: "C-K", title: "C K", onsetEV: 284, intensity: 1.925e-4, arealDensityPerNM2: 1.925e6, atomicPercent: 95.8, weightPercent: 94.5,
                            exponent: 3.95, unavailable: nil, intensityStd: 8.1e-10)
        let n = EELSEdgeRow(id: "N-K", title: "N K", onsetEV: 401, intensity: 0, arealDensityPerNM2: 0, atomicPercent: 0, weightPercent: 0,
                            unavailable: nil, intensityStd: 1.4e-9)
        let results = EELSExports.resultsCSV([c, n], fileName: "143.dm4", regionName: "Whole map", thickness: "t/λ 0.52", method: "Exact NNLS")
        let lines = results.split(separator: "\n")
        XCTAssertTrue(lines[0].contains("validation: none") && lines[0].contains("143.dm4"))
        XCTAssertEqual(lines[3], "edge,onset_eV,intensity,intensity_sigma,areal_density_per_nm2,atomic_percent,weight_percent,exponent_r,below_detection,unavailable")
        XCTAssertEqual(lines[4], "\"C K\",284,0.0001925,8.1e-10,1925000,95.8,94.5,3.95,false,")
        XCTAssertTrue(lines[5].hasSuffix(",true,"), "N K is below detection: \(lines[5])")

        let plot = EELSPlotData(regionName: "Region 1", pixels: 4, low: EELSPlotCurve(origin: -1, step: 0.5, counts: [1, 2]),
                                core: EELSPlotCurve(origin: 300, step: 1, counts: [10, 11]), zlpMaskEV: nil, model: [.nan, 10.5], edges: [], thickness: nil)
        let spectrum = EELSExports.spectrumCSV(plot, fileName: "143.dm4").split(separator: "\n")
        XCTAssertEqual(Array(spectrum.dropFirst()), ["segment,energy_eV,counts,model", "low_loss,-1,1,", "low_loss,-0.5,2,", "core_loss,300,10,", "core_loss,301,11,10.5"])

        let pin = EDXPin(name: "Region 1", region: .rectangle(PixelRect(x0: 0, y0: 0, x1: 2, y1: 2)), number: 1)
        let regions = EELSExports.regionsCSV([EELSRegionRow(pin: pin, pixels: 4, totalCounts: 1e6, tOverLambda: 0.5, edges: [c])], fileName: "143.dm4").split(separator: "\n")
        XCTAssertEqual(regions[1], "region,pixels,i_total,t_over_lambda,\"C K intensity\",\"C K intensity_sigma\",\"C K atomic_percent\"")
        XCTAssertEqual(regions[2], "\"Region 1\",4,1000000,0.5,0.0001925,8.1e-10,95.8")
    }
}
