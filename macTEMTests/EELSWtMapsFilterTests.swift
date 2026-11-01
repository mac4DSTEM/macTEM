//
//  EELSWtMapsFilterTests.swift
//  The EELS room's wt% maps and its display filter.
//
//  THE TRUTH: the planted spectrum image of `EELSControlsTests` (C K, N K and O K in the amounts 2 : 1 : 1.5 on a power law). The wt% tiles are the
//  kit's `EELSQuantification.composition` on the room's fit, value for value; the planted amounts times the kit's atomic masses are the sanity check.
//  The filter is `EELSMapFilter` (ImagoKit's separable kernels, the EDS room's): the room only chooses which tiles pass through it, and the numbers (the
//  tiles' values, the readout, the CSVs) never do.
//

import XCTest
import AppKit
import SwiftUI
import ShellSpectroscopy
import SpectroCore
import SpectroEELS
import TEMCore
import TEMSession
import ShellEDXModel
@testable import macTEM

nonisolated final class EELSWtMapsFilterTests: XCTestCase {

    @MainActor private func fittedRoom(fitOnly: [Int] = []) async throws -> EELSSession {
        let loaded = LoadedEELS(fileName: "wt.dm4", image: try EELSRoomTests.image(), beamEnergyKeV: 200, convergenceMrad: 0, collectionMrad: 10,
                                origin: "planted", coreLoss: try EELSControlsTests.core(), coreLossOrigin: "planted core")
        let session = EELSSession()
        await session.bind(loaded).value
        session.setThreshold(.fixed(2.5))
        await session.settled()
        session.setConvolveLowLoss(false)
        for (edge, _) in EELSControlsTests.amounts { session.toggleEdge(edge) }
        await session.fit()?.value
        await session.settled()
        XCTAssertNotNil(session.model, session.failure ?? session.fitRefusal ?? "no fit")
        let actions = EELSPeriodicActions.make(session)
        for z in fitOnly { actions.setRole(z, .fitOnly) }
        return session
    }

    // MARK: wt%

    /// One wt% tile per quantified element, its values the kit's composition at every pixel (the same call the at% tiles come from), the planted
    /// composition by mass to within the fit's approximation, and the Maps control's wt% segment on once there is a composition. Red under: no wt% tiles;
    /// the at% values in a wt% tile; the wt% segment off after a fit.
    @MainActor func testTheWtPercentTilesAreTheKitsComposition() async throws {
        let session = try await fittedRoom()
        let model = try XCTUnwrap(session.model)
        let kit = try model.composition(symbols: ["C", "N", "O"])
        for (i, symbol) in ["C", "N", "O"].enumerated() {
            let tile = try XCTUnwrap(session.modelTiles.first { $0.id == "wt-" + symbol }, "no wt% tile for \(symbol)")
            XCTAssertEqual(tile.unit, "wt%")
            XCTAssertEqual(tile.title, symbol)
            XCTAssertEqual(tile.values.count, model.pixelCount)
            XCTAssertEqual(tile.values, kit.map { $0.weightPercent[i] }, "\(symbol): the kit's wt% at every pixel")
            XCTAssertNotEqual(tile.values, session.modelTiles.first { $0.id == "at-" + symbol }?.values, "\(symbol): wt%, not at%")
        }
        // Sanity: the planted amounts by mass (the kit's atomic masses), to a wt% (the two-area background is the method's approximation).
        let masses = EELSQuantification.atomicMasses
        let byMass = EELSControlsTests.amounts.map { $0.amount * masses[$0.edge.element]! }
        let total = byMass.reduce(0, +)
        for (i, symbol) in ["C", "N", "O"].enumerated() {
            let tile = try XCTUnwrap(session.modelTiles.first { $0.id == "wt-" + symbol })
            XCTAssertEqual(tile.values[0], 100 * byMass[i] / total, accuracy: 1, symbol)
        }

        let availability = session.mapsAvailability
        XCTAssertNil(availability.disabledReason(.weightPercent), "wt% is on once the fit has a composition")
        XCTAssertEqual(availability.effective(.weightPercent), .weightPercent)
        let shown = EELSMapsComposition.compose(selection: .weightPercent, onlyCoreLoss: false, tiles: session.tiles, shiftTile: session.alignmentShiftTile,
                                                modelTiles: session.modelTiles)
        XCTAssertEqual(shown.rest.filter { !$0.id.hasPrefix("zlp") }.map(\.id), ["wt-C", "wt-N", "wt-O"])
    }

    /// A fit-only element has no wt% tile, and the others are the kit's composition over the quantified elements only. Red under: a wt% tile for O.
    @MainActor func testAFitOnlyElementHasNoWtPercentTile() async throws {
        let session = try await fittedRoom(fitOnly: [8])
        XCTAssertNil(session.modelTiles.first { $0.id == "wt-O" })
        let kit = try XCTUnwrap(session.model).composition(symbols: ["C", "N"])
        XCTAssertEqual(session.modelTiles.first { $0.id == "wt-C" }?.values, kit.map { $0.weightPercent[0] })
    }

    /// The wt% segment's reasons and caption, from values. Red under: wt% on before a fit; the caption missing its method.
    func testTheWtPercentSegmentIsOffWithItsReasonUntilAComposition() {
        func availability(fit: EELSStageState = .notRun, hasFit: Bool = false, hasComposition: Bool = false) -> EELSMapsAvailability {
            EELSMapsAvailability(alignState: .notRun, thicknessState: .current, fitState: fit, hasMap: true, hasLambda: false, hasFit: hasFit,
                                 hasComposition: hasComposition, onlyCoreLoss: false, fitBlocker: nil)
        }
        XCTAssertEqual(availability().disabledReason(.weightPercent), "Run Fit first: pick edges, then Run.")
        XCTAssertEqual(availability(fit: .current, hasFit: true).disabledReason(.weightPercent), "wt% needs two or more fitted elements.")
        XCTAssertNil(availability(fit: .current, hasFit: true, hasComposition: true).disabledReason(.weightPercent))
        XCTAssertTrue(availability(fit: .current, hasFit: true, hasComposition: true).caption(.weightPercent).contains("atomic masses"))
        XCTAssertTrue(availability(fit: .stale, hasFit: true, hasComposition: true).caption(.weightPercent).hasSuffix("● Showing the last run; Run updates it."))
        XCTAssertTrue(EELSMapsComposition.isStale("wt-C", thickness: .current, fit: .stale, align: .current))
        XCTAssertEqual(EELSMapScale.mode(forTileID: "wt-C"), .zeroToMax)
        XCTAssertEqual(EELSTileStyle.hue(forID: "wt-C"), EELSTileStyle.hue(forID: "at-C"), "a wt% map keeps its element's hue")
    }

    /// The status line names a wt% tile's raw value. Red under: wt% tiles left out of the readout.
    func testTheReadoutNamesTheRawWtPercent() {
        let wt = EELSMapTile(id: "wt-C", title: "C", unit: "wt%", width: 2, height: 1, values: [61.25, 40], version: 1, footer: nil)
        let line = EELSRoomFormat.readout(x: 0, y: 0, tiles: [wt], refusal: nil, locale: Locale(identifier: "en_US"))
        XCTAssertTrue(line.contains("C 61.25 wt%"), line)
    }

    // MARK: The display filter

    private func tile(_ id: String) -> EELSMapTile {
        // A 4 x 3 map with one hot pixel: any smoothing kernel changes it.
        var values = [Double](repeating: 10, count: 12)
        values[5] = 90
        return EELSMapTile(id: id, title: id, unit: "", width: 4, height: 3, values: values, version: 1, footer: nil)
    }

    /// The quantified maps (t/λ, t, at%, wt%) are drawn through the chosen kernel and carry the tag; the intensity, ZLP and I tiles never are; Off draws
    /// every tile raw. The default is the 3 x 3 average. Red under: an edge-intensity tile filtered; at% drawn raw while the filter is on; no default.
    func testTheFilterDrawsOnlyTheQuantifiedMaps() {
        for id in ["tOverLambda", "thickness", "at-C", "wt-C"] {
            XCTAssertTrue(EELSMapDisplay.isFiltered(tileID: id, filter: .mean3x3), id)
            XCTAssertFalse(EELSMapDisplay.isFiltered(tileID: id, filter: .off), id)
            let raw = tile(id)
            let shown = EELSMapDisplay.shownValues(raw, filter: .mean3x3)
            XCTAssertEqual(shown, EELSMapFilter.mean3x3.apply(raw.values, width: 4, height: 3), "\(id): the shared kernel")
            XCTAssertNotEqual(shown, raw.values, "\(id): drawn smoothed")
            XCTAssertEqual(EELSMapDisplay.shownValues(raw, filter: .off), raw.values)
        }
        for id in ["edge-C-K1", "zlpShift", "iTotal", "i0"] {
            XCTAssertFalse(EELSMapDisplay.isFiltered(tileID: id, filter: .mean3x3), id)
            XCTAssertEqual(EELSMapDisplay.shownValues(tile(id), filter: .gaussian1px), tile(id).values, id)
        }
    }

    /// The 3 x 3 average is the default, as the EDS room's. Red under: no default (Off).
    @MainActor func testTheFilterDefaultsToTheThreeByThreeAverage() {
        XCTAssertEqual(EELSRoomState().mapFilter, .mean3x3)
    }

    /// The filter is display only: with it on, the session's tiles, the status-line readout, the results CSV, the per-pixel CSV and the maps figure are the
    /// same bytes as with it off. Red under: the room writing the filtered values into a tile, the readout or an export.
    @MainActor func testTheFilterNeverTouchesTheNumbers() async throws {
        let session = try await fittedRoom()
        let state = EELSRoomState()
        state.maps = .weightPercent
        func snapshot() -> (tiles: [[Double]], readout: String, results: String?, diagnostics: String?, figure: Data?) {
            let maps = EELSMapsBlock.shownMaps(session, state)
            let figure = session.figureContent(maps: maps, mix: [], appearance: state.appearance, scaleBar: false, regions: false).flatMap { EDXMapsFigure.png($0) }
            return (session.modelTiles.map(\.values) + session.tiles.map(\.values),
                    EELSRoomFormat.readout(x: 1, y: 1, tiles: session.tiles + session.modelTiles, refusal: nil),
                    session.resultsCSV, session.diagnosticsCSV, figure)
        }
        state.mapFilter = .off
        let off = snapshot()
        state.mapFilter = .mean3x3
        let on = snapshot()
        XCTAssertEqual(on.tiles, off.tiles)
        XCTAssertEqual(on.readout, off.readout)
        XCTAssertEqual(on.results, off.results)
        XCTAssertEqual(on.diagnostics, off.diagnostics)
        XCTAssertNotNil(on.figure)
        XCTAssertEqual(on.figure, off.figure)
        // The drawn wt% values do change: the filter is not a no-op on this map.
        let wt = try XCTUnwrap(session.modelTiles.first { $0.id == "wt-C" })
        XCTAssertTrue(EELSMapDisplay.isFiltered(tileID: wt.id, filter: state.mapFilter))
    }

    // MARK: The picture

    /// The Maps section with wt% picked and the Filter row, beside the wt% tiles drawn as the room draws them (through the filter, with the tag), rendered
    /// offscreen. Writes `macTEM-98-g2.png` when MACEM_SHOT_DIR is set (TEST_RUNNER_MACEM_SHOT_DIR); otherwise only checks that it renders.
    @MainActor func testTheWtMapsAndTheFilterRowRenderOffscreen() async throws {
        let session = try await fittedRoom()
        let state = EELSRoomState()
        state.maps = .weightPercent
        let maps = EELSMapsBlock.shownMaps(session, state).filter { $0.id.hasPrefix("wt-") }
        XCTAssertEqual(maps.map(\.id), ["wt-C", "wt-N", "wt-O"])
        func picture(_ tile: EELSMapTile) -> CGImage? {
            let values = EELSMapDisplay.shownValues(tile, filter: state.mapFilter)
            let scaled = EELSMapScale.scaled(values, mode: EELSMapScale.mode(forTileID: tile.id))
            return EDXMapRaster.cgImage(rgba: MapRaster.rgba(values: scaled.values, coloring: EELSTileStyle.defaultColoring(tile.id), upper: 1, adjustment: MapAdjustment()),
                                        width: tile.width, height: tile.height)
        }
        let size = CGSize(width: 200, height: 170)
        let view = HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 8) {
                ForEach(maps, id: \.id) { tile in
                    MapTileView(title: tile.title, detail: tile.detailText, image: picture(tile), size: size, scanWidth: tile.width, scanHeight: tile.height,
                                filteredTag: EELSMapDisplay.isFiltered(tileID: tile.id, filter: state.mapFilter), onHover: { _ in }, controls: { EmptyView() })
                        .frame(width: size.width, height: size.height)
                }
            }
            ScrollView { EELSMapsSection(session: session, state: state).padding(.horizontal, 12) }.frame(width: 320)
        }
        .padding(12)
        let canvas = NSSize(width: 580, height: 560)
        let host = NSHostingView(rootView: view.frame(width: canvas.width, height: canvas.height).background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, .light))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: canvas), styleMask: [.borderless], backing: .buffered, defer: true)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: canvas)
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        XCTAssertGreaterThan(rep.pixelsWide, 0)
        guard let dir = ProcessInfo.processInfo.environment["MACEM_SHOT_DIR"] else { return }
        let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("macTEM-98-g2.png"))
    }
}
