//
//  EELSRoomTests.swift
//  The EELS room's first slice: opening a low-loss spectrum image, the t/λ map through `EELSSession` and `EELSCompute`
//  (TEMSession, TEMCore) on a planted image, the tiles, the badge, Stop, the exports and the shell's slots.
//
//  THE TRUTH: a 4 x 3 spectrum image of 256 channels (0.5 eV from -5 eV) whose pixels hold a zero-loss core of I_0 = 2000 counts
//  around channel 10 (0 eV) and a plasmon-like tail over 100 channels (never above the core's peak) of I_0 (e^p - 1) counts, so ln(I_t/I_0) = p exactly: p = 0.5 + 0.25 k for pixel k.
//  A fixed threshold of 2.5 eV cuts exactly at the end of the core, so the kit's log-ratio is the planted p to rounding.
//  The room has no arithmetic of its own (D12, D17): every tile value is the kit's `ThicknessPixel` field.
//

import XCTest
import UniformTypeIdentifiers
import ShellSpectroscopy
import SpectroCore
import SpectroEDX
import SpectroEELS
import TEMCore
import TEMSession
@testable import macTEM

nonisolated final class EELSRoomTests: XCTestCase {

    static let nx = 4, ny = 3, channels = 256, offset = -5.0, scale = 0.5
    static func planted(_ k: Int) -> Double { 0.5 + 0.25 * Double(k) }

    static func image(unavailablePixel: Int? = nil) throws -> LowLossSpectrumImage {
        var counts = [Double](repeating: 0, count: nx * ny * channels)
        for k in 0..<(nx * ny) where k != unavailablePixel {
            let base = k * channels
            counts[base + 9] = 300; counts[base + 10] = 1400; counts[base + 11] = 300      // I_0 = 2000, centre at channel 10 = 0 eV
            let tail = 2000 * (exp(planted(k)) - 1) / 100
            for c in 30..<130 { counts[base + c] = tail }
        }
        return try LowLossSpectrumImage(nx: nx, ny: ny, channels: channels, counts: counts, energyOffsetEV: offset, energyScaleEV: scale)
    }

    static func loaded(beam: Double? = nil, unavailablePixel: Int? = nil) throws -> LoadedEELS {
        LoadedEELS(fileName: "planted.dm4", image: try image(unavailablePixel: unavailablePixel), beamEnergyKeV: beam,
                   convergenceMrad: 0, collectionMrad: 10, origin: "planted")
    }

    @MainActor private func openRoom(beam: Double? = nil, unavailablePixel: Int? = nil) async throws -> EELSSession {
        let session = EELSSession()
        await session.bind(try Self.loaded(beam: beam, unavailablePixel: unavailablePixel)).value
        session.setThreshold(.fixed(2.5))
        await session.settled()
        return session
    }

    // MARK: The planted map

    /// The planted t/λ is recovered pixel by pixel through the room, the tiles are the kit's fields, the zero-loss centre is 0 eV and
    /// I_0 is the core's 2000, the counting σ is the kit's, and the map carries the unvalidated badge. Red under: a transposed grid;
    /// a tile from the wrong field; the badge missing.
    @MainActor func testThePlantedThicknessIsRecoveredThroughTheRoom() async throws {
        let session = try await openRoom()
        let map = try XCTUnwrap(session.map, session.failure ?? "no map")
        XCTAssertEqual(map.validation, "none")
        XCTAssertEqual(map.method, EELSThickness.methodName)
        for k in 0..<(Self.nx * Self.ny) {
            let p = map.pixels[k]
            XCTAssertEqual(try XCTUnwrap(p.tOverLambda), Self.planted(k), accuracy: 1e-12, "pixel \(k)")
            XCTAssertEqual(try XCTUnwrap(p.i0), 2000, accuracy: 1e-9)
            XCTAssertEqual(p.zlpCentreEV, 0, accuracy: 1e-12)
            XCTAssertEqual(try XCTUnwrap(p.sigmaCounting), (1 / 2000 - 1 / p.iTotal).squareRoot(), accuracy: 1e-15)
        }
        XCTAssertEqual(map[2, 1].tOverLambda, map.pixels[1 * Self.nx + 2].tOverLambda, "row-major y * nx + x")
        let tiles = session.tiles
        XCTAssertEqual(tiles.map(\.id), ["tOverLambda", "zlpCentre", "i0", "iTotal"], "no t tile without a λ")
        let t = try XCTUnwrap(tiles.first)
        XCTAssertEqual(t.width, Self.nx); XCTAssertEqual(t.height, Self.ny)
        XCTAssertEqual(t.values, map.pixels.map { $0.tOverLambda ?? .nan })
        XCTAssertNil(t.footer, "every pixel has a value")
        XCTAssertEqual(session.tiles.first { $0.id == "iTotal" }?.values, map.pixels.map(\.iTotal))
        XCTAssertTrue(try XCTUnwrap(session.methodJSON).contains("\"validation\" : \"none\""))
    }

    /// The default (estimated) rule runs on the planted image and lands near the planted values; the exact claim is the fixed one above.
    /// Red under: the default rule not run on open.
    @MainActor func testTheEstimatedThresholdRunsOnOpen() async throws {
        let session = EELSSession()
        await session.bind(try Self.loaded()).value
        await session.settled()
        let map = try XCTUnwrap(session.map, session.failure ?? "no map")
        XCTAssertEqual(session.threshold, .estimated)
        XCTAssertNotNil(map.estimatedTolerance)
        XCTAssertEqual(map.pixels.filter { $0.tOverLambda != nil }.count + map.pixels.filter { $0.unavailable != nil }.count, Self.nx * Self.ny)
    }

    /// A given λ adds the t tile (t/λ × λ); Iakoubovskii without a beam energy says what to type and keeps the map; typing it equals the
    /// kit's call. Red under: λ applied twice; the refusal swallowed.
    @MainActor func testMeanFreePathAddsThicknessAndNeedsTheBeam() async throws {
        let session = try await openRoom()
        let plain = try XCTUnwrap(session.map)
        session.setMeanFreePath(.given(nanometres: 100))
        await session.settled()
        XCTAssertEqual(session.tiles.map(\.id), ["tOverLambda", "thickness", "zlpCentre", "i0", "iTotal"])
        let thickness = try XCTUnwrap(session.tiles.first { $0.id == "thickness" })
        for k in 0..<(Self.nx * Self.ny) { XCTAssertEqual(thickness.values[k], try XCTUnwrap(plain.pixels[k].tOverLambda) * 100, accuracy: 1e-9) }

        session.setMeanFreePath(.iakoubovskii(density: 2.7, convergenceMrad: 0, collectionMrad: 10))
        XCTAssertEqual(session.failure, EELSRoomRefusal.needsBeamEnergy.errorDescription)
        XCTAssertNotNil(session.map, "the previous map stays")
        session.setBeamEnergy(200)
        await session.settled()
        XCTAssertNil(session.failure)
        let direct = try EELSThickness.logRatio(Self.image(), threshold: .fixed(2.5),
                                                meanFreePath: .iakoubovskii(density: 2.7, beamEnergyKeV: 200, convergenceMrad: 0, collectionMrad: 10))
        XCTAssertEqual(session.map?.pixels, direct.pixels, "the room's map is the kit's, to the bit")
        XCTAssertNotNil(session.map?.angularCorrection)
    }

    /// A pixel the kit cannot answer is hatched (NaN), counted by reason in the tile footer and the diagnostics, and the others stand.
    /// Red under: the empty pixel drawn as zero; the reason dropped.
    @MainActor func testAnUnavailablePixelIsNaNWithItsReason() async throws {
        let session = try await openRoom(unavailablePixel: 5)
        let map = try XCTUnwrap(session.map)
        XCTAssertEqual(map.pixels[5].unavailable, .zeroLossIntensityNotPositive)
        let t = try XCTUnwrap(session.tiles.first)
        XCTAssertTrue(t.values[5].isNaN)
        XCTAssertEqual(t.values[4], Self.planted(4), accuracy: 1e-12)
        XCTAssertEqual(t.footer, "1 px: \(ThicknessUnavailable.zeroLossIntensityNotPositive.description)")
        let reasons = EELSCompute.unavailable(map)
        XCTAssertEqual(reasons.count, 1); XCTAssertEqual(reasons[0].count, 1)
    }

    // MARK: Pointer, Stop

    /// The pixel under the pointer is the kit's pixel and its stored spectrum; off the grid there is none.
    @MainActor func testThePointerReadsTheKitsPixelAndTheStoredSpectrum() async throws {
        let session = try await openRoom()
        session.movePointer(to: EELSCompute.Pixel(x: 2, y: 1))
        XCTAssertEqual(session.pointerPixel, session.map?[2, 1])
        let spectrum = try XCTUnwrap(session.pointerSpectrum)
        XCTAssertEqual(spectrum.count, Self.channels)
        XCTAssertEqual(spectrum[10], 1400)
        session.movePointer(to: EELSCompute.Pixel(x: 9, y: 9))
        XCTAssertNil(session.pointerPixel); XCTAssertNil(session.pointerSpectrum)
        session.movePointer(to: nil)
        XCTAssertNil(session.pointerPixel)
    }

    /// Stop ends the pass and leaves the room usable. Red under: the busy flag stuck; a stopped pass landing.
    @MainActor func testStopEndsThePassAndTheRoomStillWorks() async throws {
        let session = EELSSession()
        let first = session.bind(try Self.loaded())
        XCTAssertTrue(session.isBusy)
        session.stop()
        XCTAssertFalse(session.isBusy)
        await first.value
        await session.settled()
        XCTAssertNil(session.map, "the stopped pass did not land")
        session.setThreshold(.fixed(2.5))
        await session.settled()
        XCTAssertNotNil(session.map)
        var events: [String] = []
        session.onEvent = { events.append($0) }
        session.stop()
        XCTAssertTrue(events.isEmpty, "nothing running: nothing to stop")
    }

    // MARK: Exports

    /// The diagnostics CSV has the badge in its first line, a row per pixel and the kit's reason where there is none; the method JSON names the rule.
    @MainActor func testTheExportsCarryTheBadgeAndEveryPixel() async throws {
        let session = try await openRoom(unavailablePixel: 5)
        let csv = try XCTUnwrap(session.diagnosticsCSV)
        let lines = csv.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 2 + Self.nx * Self.ny)
        XCTAssertTrue(lines[0].hasSuffix("validation: none"), lines[0])
        XCTAssertEqual(lines[1], "x,y,t_over_lambda,sigma_counting,i0,i_total,zlp_centre_eV,threshold_eV,thickness_nm,unavailable")
        XCTAssertTrue(lines[2 + 5].hasPrefix("1,1,,"), lines[7])
        XCTAssertTrue(lines[2 + 5].contains("I_0 <= 0"), lines[7])
        let json = try XCTUnwrap(session.methodJSON)
        XCTAssertTrue(json.contains("fixed threshold 2.5 eV"), json)
        XCTAssertTrue(json.contains("\"pixels_unavailable\" : 1"), json)
        XCTAssertEqual(session.exportStem, "planted thickness")
    }

    // MARK: Opening

    /// FormatoKit's planted GMS file: the first EELS object opens with its grid, its energy axis and the angles the file states; a file
    /// with no EELS object is refused in words. Red under: the reader not reached; the axis offset sign; the angles dropped.
    func testAGMSEELSSpectrumImageOpens() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/eels-planted.dm4")
        let loaded = try EELSOpening.open(url: url)
        XCTAssertEqual(loaded.image.nx, 3); XCTAssertEqual(loaded.image.ny, 2); XCTAssertEqual(loaded.image.channels, 5)
        XCTAssertEqual(loaded.image.energyOffsetEV, 10, accuracy: 1e-12)
        XCTAssertEqual(loaded.image.energyScaleEV, 0.25, accuracy: 1e-12)
        XCTAssertEqual(loaded.beamEnergyKeV, 80); XCTAssertEqual(loaded.convergenceMrad, 17.5); XCTAssertEqual(loaded.collectionMrad, 33.25)
        XCTAssertEqual(loaded.origin, "GMS DM4 object 2 (EELS)")
        let two = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/planted-2d.dm4")
        XCTAssertThrowsError(try EELSOpening.open(url: two)) {
            XCTAssertEqual(($0 as? LocalizedError)?.errorDescription, "planted-2d.dm4 holds no EELS spectrum image.")
        }
        XCTAssertThrowsError(try EELSOpening.open(url: URL(fileURLWithPath: "/tmp/x.tif"))) { XCTAssertEqual($0 as? EELSOpeningError, .notEELS("x.tif")) }
    }

    // MARK: The shell's slots

    /// The EELS room is built, is the fifth (⌘5) right after the EDS room (⌘4), and is entered with no image open.
    @MainActor func testTheEELSRoomIsBuiltAndFifth() {
        XCTAssertTrue(WorkspaceArea.eels.isBuilt)
        XCTAssertEqual(WorkspaceArea.allCases[3], .eels)
        XCTAssertEqual(WorkspaceArea.eels.shortcutDigit, "4")
        XCTAssertEqual(WorkspaceArea.edx.shortcutDigit, "3")
        XCTAssertEqual(WorkspaceArea.eels.title, "EELS")
        let state = AppState()
        state.selectWorkspace(.eels)
        XCTAssertEqual(state.navigation.workspaceArea, .eels)
        XCTAssertFalse(state.eels.hasImage)
        let image = ExportSnapshot.availability(hasImage: true, area: .eels, isLoading: false, profileHasSamples: true, resultRows: 3)
        XCTAssertEqual(image, ExportAvailability(image: false, profile: false, results: false))
    }

    @MainActor func testTheExportKindsNameTheirFiles() {
        // The EDS room's exports (Paul's drive, 2026-10-23), the per-pixel thickness and the method keeping their old names.
        XCTAssertEqual(EELSExportKind.allCases.map(\.suffix), [" results", " spectrum", " regions", " maps", " thickness", " thickness method"])
        XCTAssertEqual(EELSExportKind.mapsPNG.contentType, .png)
        XCTAssertEqual(EELSExportKind.method.contentType, .json)
        XCTAssertEqual(EELSExportKind.diagnostics.contentType, .commaSeparatedText)
    }

    // A tile whose pixels all hold one value says so in words; a tile with a range does not.
    func testAFlatTileNamesItsValue() {
        let flat = EELSMapTile(id: "zlpCentre", title: "ZLP centre", unit: "eV", width: 2, height: 1, values: [0, 0], version: 1, footer: nil)
        XCTAssertEqual(flat.flatValueText, "0 eV")
        let ranged = EELSMapTile(id: "i0", title: "I0", unit: "counts", width: 2, height: 1, values: [1, 2], version: 1, footer: nil)
        XCTAssertNil(ranged.flatValueText)
        let withHole = EELSMapTile(id: "i0", title: "I0", unit: "", width: 3, height: 1, values: [4, .nan, 4], version: 1, footer: nil)
        XCTAssertEqual(withHole.flatValueText, "4")
    }

    // The window's title follows the room: the spectrum image's file in the EELS room, the image's elsewhere.
    @MainActor func testTheWindowTitleFollowsTheRoom() async throws {
        let state = AppState()
        XCTAssertEqual(state.windowTitle, "macTEM")
        state.navigation.workspaceArea = .eels
        XCTAssertEqual(state.windowTitle, "macTEM", "no spectrum image open: the app's name")
    }

    /// The reasons a pixel has no t/λ are held by the session once per map, and a hover that stays on its pixel changes nothing.
    @MainActor func testTheUnavailableReasonsLandWithTheMapAndASamePixelHoverIsQuiet() async throws {
        let session = try await openRoom(unavailablePixel: 5)
        XCTAssertEqual(session.unavailableReasons.count, 1)
        XCTAssertEqual(session.unavailableReasons.first?.count, 1)
        session.movePointer(to: EELSCompute.Pixel(x: 1, y: 1))
        let seen = session.pointer
        session.movePointer(to: EELSCompute.Pixel(x: 1, y: 1))
        XCTAssertEqual(session.pointer, seen)
    }

    /// The toolbar's busy display gets the EELS pass's fraction while it computes and nothing while idle; the EDS room reports its open. Red under: progress left nil (a
    /// run showed a spinner with no fraction).
    @MainActor func testTheToolbarShowsTheEELSPassProgress() async throws {
        let appState = AppState(launch: LaunchOptions(arguments: []))
        XCTAssertNil(RoomProgress.fraction(room: .eels, appState: appState), "idle: no fraction")
        XCTAssertNil(RoomProgress.fraction(room: .edx, appState: appState))
        XCTAssertNil(RoomProgress.fraction(room: .image, appState: appState))
        let task = appState.eels.bind(try DemoDocuments.eels())
        let busy = RoomProgress.fraction(room: .eels, appState: appState)
        XCTAssertTrue(busy.map { (0...1).contains($0) } ?? false, "a pass is running: a fraction in 0...1, got \(String(describing: busy))")
        await task.value
        await appState.eels.settled()
        XCTAssertNil(RoomProgress.fraction(room: .eels, appState: appState), "finished: no fraction")
    }

    // MARK: The chassis (slice 1, docs/design/eels-room.md)

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    private func squeezed(_ text: String) -> String { text.split(whereSeparator: \.isWhitespace).joined(separator: " ") }

    private func availability(align: EELSStageState = .notRun, thickness: EELSStageState = .current, fit: EELSStageState = .notRun, hasMap: Bool = true, hasLambda: Bool = false,
                              hasFit: Bool = false, hasComposition: Bool = false, onlyCoreLoss: Bool = false, blocker: String? = nil) -> EELSMapsAvailability {
        EELSMapsAvailability(alignState: align, thicknessState: thickness, fitState: fit, hasMap: hasMap, hasLambda: hasLambda, hasFit: hasFit,
                             hasComposition: hasComposition, onlyCoreLoss: onlyCoreLoss, fitBlocker: blocker)
    }

    /// The Maps control's segments: each is off with its reason until its stage ran, and a pick that is off falls back to t/λ. Red under: a segment on before its
    /// stage; the reason dropped; wt% on.
    func testTheMapsSegmentsAreOffWithTheirReasonUntilTheirStageRan() {
        XCTAssertEqual(EELSMapsSegment.allCases.map(\.title), ["ZLP", "t/λ", "t", "at%", "wt%"])
        let opened = availability()
        XCTAssertEqual(opened.disabledReason(.zlp), "Run Align first: it measures the zero-loss shift.")
        XCTAssertNil(opened.disabledReason(.tOverLambda))
        XCTAssertEqual(opened.disabledReason(.thickness), "Give a mean free path λ under Processing to get t in nm.")
        XCTAssertEqual(opened.disabledReason(.atomicPercent), "Run Fit first: pick edges, then Run.")
        XCTAssertNotNil(opened.disabledReason(.weightPercent))
        XCTAssertEqual(opened.effective(.zlp), .tOverLambda)
        XCTAssertEqual(opened.effective(.tOverLambda), .tOverLambda)

        XCTAssertEqual(availability(hasMap: false).disabledReason(.tOverLambda), "Run the thickness first: t/λ comes from it.")
        XCTAssertEqual(availability(hasMap: false).disabledReason(.thickness), "Run the thickness first: t comes from t/λ.")
        let blocked = availability(blocker: "Pick at least one edge to fit.")
        XCTAssertEqual(blocked.disabledReason(.atomicPercent), "Pick at least one edge to fit.", "the kit's sentence about why Fit cannot run")

        let ran = availability(align: .current, thickness: .current, fit: .current, hasLambda: true, hasFit: true, hasComposition: true)
        for s in [EELSMapsSegment.zlp, .tOverLambda, .thickness, .atomicPercent] { XCTAssertNil(ran.disabledReason(s), s.title) }
        XCTAssertEqual(ran.effective(.atomicPercent), .atomicPercent)
        XCTAssertEqual(availability(align: .current, hasFit: true, hasComposition: false).disabledReason(.atomicPercent), "at% needs two or more fitted elements.")

        let core = availability(hasMap: false, onlyCoreLoss: true)
        XCTAssertNotNil(core.disabledReason(.tOverLambda)); XCTAssertNotNil(core.disabledReason(.thickness)); XCTAssertNotNil(core.disabledReason(.zlp))
        XCTAssertEqual(core.caption(.tOverLambda), "Composition without plural-scattering correction: this file holds only a core loss.")
        XCTAssertTrue(availability(thickness: .stale).caption(.tOverLambda).hasSuffix("● Showing the last run; Run updates it."))
        XCTAssertFalse(opened.caption(.tOverLambda).contains("●"))
    }

    /// The same, from a real session: a planted image before Align, with a λ, after Align (the thickness is then stale and says so).
    @MainActor func testTheSessionsStagesDriveTheMapsSegments() async throws {
        let session = EELSSession()
        await session.bind(LoadedEELS(fileName: "shifted.dm4", image: try EELSOpeningTests.shiftedImage(), beamEnergyKeV: nil, convergenceMrad: 0, collectionMrad: 10, origin: "planted")).value
        await session.settled()
        var a = session.mapsAvailability
        XCTAssertNotNil(a.disabledReason(.zlp)); XCTAssertNil(a.disabledReason(.tOverLambda)); XCTAssertNotNil(a.disabledReason(.thickness))
        XCTAssertEqual(a.disabledReason(.atomicPercent), "This file holds no core-loss spectrum image to fit.")
        session.setMeanFreePath(.given(nanometres: 100))
        await session.settled()
        a = session.mapsAvailability
        XCTAssertNil(a.disabledReason(.thickness))
        await session.align()?.value
        await session.settled()
        a = session.mapsAvailability
        XCTAssertNil(a.disabledReason(.zlp))
        XCTAssertEqual(a.thicknessState, .stale, "Align changed the cube the map was made from")
        XCTAssertNotNil(session.alignmentShiftTile)
        XCTAssertEqual(session.alignmentShiftTile?.id, "zlpShift")
        XCTAssertEqual(session.alignmentShiftTile?.values.count, 12)
        XCTAssertTrue(a.caption(.tOverLambda).contains("●"))
    }

    /// The anchor and the tiles beside it for each pick, and what is dimmed. Red under: the ZLP shift tile on the left for t/λ; at% tiles and edge tiles together;
    /// the anchor missing in a core-loss-only file.
    func testTheAnchorAndTheTilesBesideItFollowTheMapsControl() {
        func tile(_ id: String, _ title: String = "") -> EELSMapTile { EELSMapTile(id: id, title: title.isEmpty ? id : title, unit: "", width: 1, height: 1, values: [1], version: 1, footer: nil) }
        let tiles = [tile("tOverLambda"), tile("thickness"), tile("zlpCentre"), tile("i0"), tile("iTotal")]
        // A shift that moved pixels (a flat one is not a tile beside the anchor: testAFileThatCameAlignedSaysSoAndDrawsNoFlatTile).
        let shift = EELSMapTile(id: "zlpShift", title: "zlpShift", unit: "eV", width: 2, height: 1, values: [0.5, -0.5], version: 1, footer: nil)
        let model = [tile("edge-Mg-K1"), tile("edge-Si-K1"), tile("at-Mg"), tile("at-Si")]
        func compose(_ s: EELSMapsSegment, onlyCore: Bool = false, shift: EELSMapTile? = shift, model: [EELSMapTile] = model) -> (anchor: EELSMapTile?, rest: [EELSMapTile]) {
            EELSMapsComposition.compose(selection: s, onlyCoreLoss: onlyCore, tiles: tiles, shiftTile: shift, modelTiles: model)
        }
        XCTAssertEqual(compose(.tOverLambda).anchor?.id, "tOverLambda")
        XCTAssertEqual(compose(.tOverLambda).rest.map(\.id), ["zlpShift", "edge-Mg-K1", "edge-Si-K1"])
        XCTAssertEqual(compose(.atomicPercent).anchor?.id, "tOverLambda")
        XCTAssertEqual(compose(.atomicPercent).rest.map(\.id), ["zlpShift", "at-Mg", "at-Si"])
        XCTAssertEqual(compose(.atomicPercent, model: [tile("edge-Mg-K1")]).rest.map(\.id), ["zlpShift", "edge-Mg-K1"], "one element: no at% tiles, the edge's own")
        XCTAssertEqual(compose(.zlp).anchor?.id, "zlpShift")
        XCTAssertEqual(compose(.zlp).rest.map(\.id), ["edge-Mg-K1", "edge-Si-K1"])
        XCTAssertEqual(compose(.thickness).anchor?.id, "thickness")
        XCTAssertEqual(compose(.tOverLambda, shift: nil, model: []).rest.map(\.id), [], "before Align and Fit: the anchor alone")
        XCTAssertEqual(compose(.tOverLambda, onlyCore: true).anchor?.id, "iTotal")
        XCTAssertNil(EELSMapsComposition.compose(selection: .tOverLambda, onlyCoreLoss: false, tiles: [], shiftTile: nil, modelTiles: []).anchor)

        XCTAssertTrue(EELSMapsComposition.isStale("tOverLambda", thickness: .stale, fit: .current, align: .current))
        XCTAssertFalse(EELSMapsComposition.isStale("edge-Mg-K1", thickness: .stale, fit: .current, align: .current))
        XCTAssertTrue(EELSMapsComposition.isStale("at-Mg", thickness: .current, fit: .stale, align: .current))
    }

    /// The colour scales: the zero-loss shift is centred on 0 (diverging), t/λ runs from its smallest to its largest, an edge from 0; NaN stays NaN (drawn at
    /// the bottom of the scale, never as a value).
    func testTheTileScalesAreCentredOrMinToMaxOrFromZero() {
        let d = EELSMapScale.scaled([-2, 0, 1, .nan], mode: EELSMapScale.mode(forTileID: "zlpShift"))
        XCTAssertEqual(d.low, -2); XCTAssertEqual(d.high, 2)
        XCTAssertEqual(d.values[0], 0); XCTAssertEqual(d.values[1], 0.5); XCTAssertEqual(d.values[2], 0.75); XCTAssertTrue(d.values[3].isNaN)
        XCTAssertEqual(EELSMapScale.scaled([1, 3, 2], mode: EELSMapScale.mode(forTileID: "tOverLambda")).values, [0, 1, 0.5])
        let z = EELSMapScale.scaled([0, 5, 10], mode: EELSMapScale.mode(forTileID: "edge-Mg-K1"))
        XCTAssertEqual(z.values, [0, 0.5, 1]); XCTAssertEqual(z.high, 10)
        XCTAssertEqual(EELSMapScale.scaled([4, 4], mode: .minToMax).values, [0, 0], "a flat map has no range")
        XCTAssertEqual(EELSMapScale.scaled([0, 0], mode: .diverging).values, [0.5, 0.5])
        XCTAssertEqual(EELSMapScale.mode(forTileID: "at-Si"), .zeroToMax)
        XCTAssertEqual(EELSMapScale.mode(forTileID: "thickness"), .minToMax)
    }

    /// The one energy axis: the two windows share the width by the energy they span (each at least a fifth), a fixed gap between, nothing at an energy in it.
    /// Red under: the gap taken from one segment only; the clamp missing; an energy in the gap given an x.
    func testTheOneAxisSharesTheWidthAndMarksTheGap() throws {
        let axis = EELSOneAxis(low: -5...300, core: 800...1100, width: 616, gapWidth: 16)
        let gap = try XCTUnwrap(axis.gap)
        XCTAssertEqual(gap.upperBound - gap.lowerBound, 16, accuracy: 1e-12)
        XCTAssertEqual(axis.segments.count, 2)
        let (low, core) = (axis.segments[0], axis.segments[1])
        XCTAssertEqual(low.x.lowerBound, 0); XCTAssertEqual(core.x.upperBound, 616, accuracy: 1e-12)
        XCTAssertEqual(low.x.upperBound, gap.lowerBound, accuracy: 1e-12); XCTAssertEqual(core.x.lowerBound, gap.upperBound, accuracy: 1e-12)
        XCTAssertEqual((low.x.upperBound - low.x.lowerBound) + (core.x.upperBound - core.x.lowerBound), 600, accuracy: 1e-9, "the width less the gap")
        XCTAssertEqual((low.x.upperBound - low.x.lowerBound) / 600, 305.0 / 605.0, accuracy: 1e-12, "by the energy each spans")
        XCTAssertEqual(axis.gapEnergy, 300...800)
        XCTAssertNil(axis.x(forEnergy: 550), "inside the gap")
        XCTAssertNil(axis.energy(atX: (gap.lowerBound + gap.upperBound) / 2))
        XCTAssertEqual(try XCTUnwrap(axis.x(forEnergy: -5)), 0, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(axis.x(forEnergy: 1100)), 616, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(axis.x(forEnergy: -500)), 0, "beyond the start: clamped")
        let x900 = try XCTUnwrap(axis.x(forEnergy: 900))
        XCTAssertEqual(try XCTUnwrap(axis.energy(atX: x900)), 900, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(axis.energy(atX: try XCTUnwrap(axis.x(forEnergy: 100)))), 100, accuracy: 1e-9)

        let narrow = EELSOneAxis(low: 0...10, core: 1000...3000, width: 516, gapWidth: 16)
        XCTAssertEqual(narrow.segments[0].x.upperBound - narrow.segments[0].x.lowerBound, 100, accuracy: 1e-9, "a fifth of 500 at least")

        let touching = EELSOneAxis(low: -5...900, core: 800...1100, width: 600)
        XCTAssertNil(touching.gap, "overlapping windows leave nothing out"); XCTAssertEqual(touching.segments.map(\.energy), [-5...800, 800...1100], "the low loss ends where the core loss starts")
        let lowOnly = EELSOneAxis(low: -5...300, core: nil, width: 600)
        XCTAssertNil(lowOnly.gap); XCTAssertEqual(lowOnly.segments[0].x, 0...600)

        XCTAssertEqual(EELSOneAxis.ticks(in: 0...100), [0, 20, 40, 60, 80, 100])
        XCTAssertEqual(EELSOneAxis.snappedOnset(530, among: [532, 1305]), 532)
        XCTAssertNil(EELSOneAxis.snappedOnset(540, among: [532, 1305]))
        XCTAssertEqual(EELSOneAxis.snappedOnset(1300, among: [532, 1305]), 1305)
    }

    /// The thickness line's words: median, IQR, λ with its source, t; a missing part says what it needs.
    func testTheThicknessLineNamesEachPart() {
        let en = Locale(identifier: "en_US")
        let stats = EELSThicknessStats(pixels: 90, total: 100, median: 0.523, q1: 0.481, q3: 0.571, medianThicknessNM: 62.8)
        XCTAssertEqual(EELSRoomFormat.thicknessLine(stats, lambdaNM: 120, lambdaSource: "given", locale: en), "t/λ 0.523 (IQR 0.481–0.571) · λ 120 nm, given · t 62.8 nm")
        let noLambda = EELSThicknessStats(pixels: 90, total: 100, median: 0.523, q1: 0.481, q3: 0.571, medianThicknessNM: nil)
        XCTAssertEqual(EELSRoomFormat.thicknessLine(noLambda, lambdaNM: nil, lambdaSource: nil, locale: en), "t/λ 0.523 (IQR 0.481–0.571) · λ not set · t needs λ")
        XCTAssertEqual(EELSRoomFormat.thicknessLine(nil, lambdaNM: nil, lambdaSource: nil, locale: en), "t/λ not available · λ not set · t needs λ")
        XCTAssertEqual(EELSRoomFormat.lambdaSource(.none), nil)
        XCTAssertEqual(EELSRoomFormat.lambdaSource(.given(nanometres: 100)), "given")
        XCTAssertEqual(EELSRoomFormat.lambdaSource(.iakoubovskii(density: 2.7, convergenceMrad: 0, collectionMrad: 10)), "Iakoubovskii, 2.7 g/cm³")
        XCTAssertEqual(EELSRoomFormat.valueSource(typed: 300, file: 200), "typed")
        XCTAssertEqual(EELSRoomFormat.valueSource(typed: nil, file: 200), "from the file")
        XCTAssertEqual(EELSRoomFormat.valueSource(typed: nil, file: nil), "not set")
        XCTAssertEqual(EELSRoomFormat.fitFooter(hasFit: false, convolved: false), "No fit yet")
        XCTAssertEqual(EELSRoomFormat.fitFooter(hasFit: true, convolved: true), "Exact NNLS · power-law background · convolved with the low loss · no deconvolution")
    }

    /// The median and the quartiles are over the region's pixels (numpy's linear rule), through the room: the planted t/λ of pixel k is 0.5 + 0.25 k.
    @MainActor func testTheThicknessStatsAreOverTheSelectedRegionAndTheWholeMapOtherwise() async throws {
        let session = try await openRoom()
        var plot = try XCTUnwrap(session.plot)
        XCTAssertEqual(plot.regionName, "Whole map"); XCTAssertEqual(plot.pixels, Self.nx * Self.ny)
        var stats = try XCTUnwrap(plot.thickness)
        XCTAssertEqual(stats.median, 1.875, accuracy: 1e-12); XCTAssertEqual(stats.q1, 1.1875, accuracy: 1e-12); XCTAssertEqual(stats.q3, 2.5625, accuracy: 1e-12)
        XCTAssertEqual(stats.pixels, 12); XCTAssertNil(stats.medianThicknessNM, "no λ")
        XCTAssertEqual(plot.low.counts.count, Self.channels)
        XCTAssertEqual(plot.low.counts[10], 12 * 1400, "the whole map's summed spectrum")
        XCTAssertNil(plot.core); XCTAssertNil(plot.model, "no fit yet")
        let cut = try XCTUnwrap(plot.zlpMaskEV)
        XCTAssertEqual(cut.lowerBound, Self.offset); XCTAssertEqual(cut.upperBound, 2.5, accuracy: 1e-12, "the fixed threshold")

        // The rectangle over pixels 0, 1, 4, 5 (planted 0.5, 0.75, 1.5, 1.75): the plot, the results and the stats follow it; the whole map again on request.
        let pin = try XCTUnwrap(session.drawRegion(.rectangle(PixelRect(x0: 0, y0: 0, x1: 2, y1: 2))))
        await session.settled()
        plot = try XCTUnwrap(session.plot)
        XCTAssertEqual(plot.regionName, pin.name); XCTAssertEqual(plot.pixels, 4)
        XCTAssertEqual(plot.low.counts[10], 4 * 1400)
        stats = try XCTUnwrap(plot.thickness)
        XCTAssertEqual(stats.median, 1.125, accuracy: 1e-12)
        session.selectWholeMap()
        await session.settled()
        XCTAssertEqual(session.plot?.regionName, "Whole map")
        XCTAssertEqual(session.plot?.low.counts[10], 12 * 1400)
        session.setMeanFreePath(.given(nanometres: 100))
        await session.settled()
        XCTAssertEqual(try XCTUnwrap(session.plot?.thickness?.medianThicknessNM), 187.5, accuracy: 1e-9, "t = t/λ × λ at the median pixel")
    }

    /// The readout over a map: row, col, then the tiles' values that exist there, and the kit's reason first where the pixel has no t/λ.
    func testTheReadoutNamesThePixelAndItsValues() {
        func tile(_ id: String, _ title: String, _ unit: String, _ values: [Double]) -> EELSMapTile { EELSMapTile(id: id, title: title, unit: unit, width: 2, height: 1, values: values, version: 1, footer: nil) }
        let tiles = [tile("tOverLambda", "t/λ", "", [0.5, .nan]), tile("i0", "I₀", "counts", [9, 9]), tile("zlpShift", "ZLP shift", "eV", [0.01, 0.02]), tile("at-Mg", "Mg", "at%", [60, 40])]
        let en = Locale(identifier: "en_US")
        XCTAssertEqual(EELSRoomFormat.readout(x: 0, y: 0, tiles: tiles, refusal: nil, locale: en), "row 0 · col 0 · t/λ 0.5 · ZLP shift 0.01 eV · Mg 60 at%")
        XCTAssertEqual(EELSRoomFormat.readout(x: 1, y: 0, tiles: tiles, refusal: "I_0 <= 0", locale: en), "row 0 · col 1 · t/λ: I_0 <= 0 · ZLP shift 0.02 eV · Mg 40 at%")
        XCTAssertEqual(EELSRoomFormat.readout(x: 5, y: 5, tiles: tiles, refusal: nil, locale: en), "row 5 · col 5", "off the grid: no values")
    }

    /// The Processing section's state is Align and Thickness as one; its line says what Align did or that it has not run.
    func testTheProcessingStateIsAlignAndThicknessAsOne() {
        XCTAssertEqual(EELSRoomFormat.processingState(align: .notRun, thickness: .current), .notRun, "opened: Align —")
        XCTAssertEqual(EELSRoomFormat.processingState(align: .current, thickness: .current), .current)
        XCTAssertEqual(EELSRoomFormat.processingState(align: .current, thickness: .stale), .stale)
        XCTAssertEqual(EELSRoomFormat.processingState(align: .notRun, thickness: .stale), .stale)
        XCTAssertEqual(EELSRoomFormat.processingState(align: .current, thickness: .notRun), .notRun)
        XCTAssertEqual(EELSRoomFormat.processingLine(align: .notRun, thickness: .current, alignmentReadout: nil), "Align —: Run aligns the zero-loss peak.")
        XCTAssertEqual(EELSRoomFormat.processingLine(align: .current, thickness: .current, alignmentReadout: "offset -1.000 → 0.000 eV, 9 of 10 channels kept"),
                       "Aligned: offset -1.000 → 0.000 eV, 9 of 10 channels kept")
    }

    /// The periodic table's answers: every element with a K, L or M edge exSpy builds is live (SpectroKit 0.12.0, Paul 2026-10-23: "we need to put everything
    /// in"), and only those the core loss reaches; a click picks K where offered, else L₂,₃, else M₄,₅. Red under: the 8 elements of before.
    func testThePeriodicTableAnswersFromTheBundledEdges() throws {
        XCTAssertEqual(EELSEdgeChoices.live.count, 95)
        for s in ["Ti", "Ba", "Ce", "Au", "Zr", "Ni", "Ga"] { XCTAssertTrue(EELSEdgeChoices.live.contains(s), s) }
        let offered: [CoreLossEdge] = [.siliconK, .siliconL3, .copperL1, .copperL3, .ironL3]
        XCTAssertEqual(EELSEdgeChoices.unavailableReason(symbol: "Og", offered: offered, hasCoreLoss: true), "no bundled edge")
        XCTAssertEqual(EELSEdgeChoices.unavailableReason(symbol: "Au", offered: offered, hasCoreLoss: true), "no edge of it in this core loss's energy window")
        // M edges: Ba's M5 is the default and both M families are listed; twins (L2, M2, M4) are never offered alone.
        let ba = CoreLossEdge.bundled.filter { $0.element == "Ba" && !EELSFitCompute.twins.contains($0.subshell) }
        XCTAssertEqual(EELSEdgeChoices.defaultEdge(symbol: "Ba", offered: ba)?.subshell, "M5")
        XCTAssertEqual(EELSEdgeChoices.families(symbol: "Ba", offered: ba).map(\.name), ["M₂,₃", "M₄,₅"])
        let counts = [Double](repeating: 1, count: 2 * 2 * 1000)
        let core = try CoreLossSpectrumImage(nx: 2, ny: 2, channels: 1000, counts: counts, energyOffsetEV: 400, energyScaleEV: 1)
        let inRange = EELSFitCompute.offeredEdges(in: core)
        XCTAssertTrue(inRange.allSatisfy { $0.onsetEV >= 410 && $0.onsetEV < 1399 && !EELSFitCompute.twins.contains($0.subshell) })
        for e in ["Ti L3", "Ba M5", "Ce M5", "O K", "Fe L3"] { XCTAssertTrue(inRange.map(EELSFitCompute.title).contains(e), e) }
        XCTAssertEqual(EELSEdgeChoices.unavailableReason(symbol: "Mg", offered: offered, hasCoreLoss: true), "no edge of it in this core loss's energy window")
        XCTAssertEqual(EELSEdgeChoices.unavailableReason(symbol: "Si", offered: offered, hasCoreLoss: false), "this file holds no core loss")
        XCTAssertNil(EELSEdgeChoices.unavailableReason(symbol: "Si", offered: offered, hasCoreLoss: true))
        // A dimmed cell names the file's range (Paul, 2026-10-23: "some elements are grayed out, why??").
        XCTAssertEqual(EELSEdgeChoices.unavailableReason(symbol: "Mg", offered: offered, hasCoreLoss: true, windowEV: 149.6...1665.2), "no edge in 150\u{2013}1665 eV")
        XCTAssertNil(EELSEdgeChoices.unavailableReason(symbol: "Si", offered: offered, hasCoreLoss: true, windowEV: 149.6...1665.2))
        let three = try CoreLossSpectrumImage(nx: 1, ny: 1, channels: 3, counts: [1, 2, 3] as [Double], energyOffsetEV: 150, energyScaleEV: 0.5)
        XCTAssertEqual(EELSEdgeChoices.window(of: three), 150...151)
        XCTAssertEqual(EELSEdgeChoices.defaultEdge(symbol: "Si", offered: offered), .siliconK, "K where bundled")
        XCTAssertEqual(EELSEdgeChoices.defaultEdge(symbol: "Cu", offered: offered), .copperL3, "else L₂,₃")
        XCTAssertNil(EELSEdgeChoices.defaultEdge(symbol: "Mg", offered: offered))
        XCTAssertEqual(EELSEdgeChoices.families(symbol: "Si", offered: offered).map(\.name), ["K", "L₂,₃"])
        XCTAssertEqual(EELSEdgeChoices.families(symbol: "Cu", offered: offered).map(\.name), ["L₁", "L₂,₃"])
        XCTAssertEqual(EELSEdgeChoices.defaultEdge(symbol: "Al", offered: [.aluminiumL23]), .aluminiumL23)
    }

    /// The chassis is the EDS room's, in the order the design names: sections, the verb, the states, the anchor-only regions. Red under: a section moved or
    /// missing; the header strip back; the verb changed; regions drawn on every tile.
    func testTheRoomIsTheChassisInTheDesignsOrder() throws {
        let inspector = squeezed(try source("macTEM/UI/EELSRoomInspector.swift"))
        let order = ["EELSMapsSection(session: session, state: appState.eelsRoom)", "EELSToolsSection(state: appState.eelsRoom)", "EELSEdgesSection(session: session)",
                     "EELSProcessingSection(session: session)", "EELSFittingSection(session: session)", "EELSExportSection(session: session, state: appState.eelsRoom)"]
        let at = try order.map { try XCTUnwrap(inspector.range(of: $0), $0).lowerBound }
        XCTAssertEqual(at, at.sorted(), "Maps, Tools, Edges, Processing, Fitting, Export")
        XCTAssertTrue(inspector.contains("InspectorSection(\"Maps\")")); XCTAssertTrue(inspector.contains("InspectorSection(\"Tools\")"))
        XCTAssertTrue(inspector.contains("InspectorSection(\"Processing\")")); XCTAssertTrue(inspector.contains("InspectorSection(\"Fitting\")"))
        XCTAssertTrue(inspector.contains("SegmentedPicker(label: \"Maps\""), "full-width segmented controls (MacEMUI's)")
        XCTAssertTrue(inspector.contains("SegmentedPicker(label: \"Region tool\""))
        XCTAssertTrue(inspector.contains("PeriodicTable(actions: EELSPeriodicActions.make(session))"))

        let room = squeezed(try source("macTEM/UI/EELSRoom.swift"))
        XCTAssertTrue(room.contains("VerticalPaneSplit(storageKey: \"eels.lowerSplit\""))
        XCTAssertTrue(room.contains("AnchoredMapsBlock(anchor: mix, items: maps.map"))
        XCTAssertTrue(room.contains("HorizontalPaneSplit(storageKey: \"eels.resultsSplit\""))
        XCTAssertTrue(room.contains("transform: $state.mapView"), "one zoom for every tile")
        XCTAssertTrue(room.contains("regions: isAnchor ? regions : nil"), "regions drawn and edited on the anchor only")
        XCTAssertTrue(room.contains("state.readout = pixel.map"), "the one cursor goes to the status line")
        XCTAssertFalse(room.contains("EELSHeader"), "no strip over the maps")
        XCTAssertFalse(room.contains("hoverChip"))
        XCTAssertTrue(room.contains("Text(\"Opening spectrum image\")")); XCTAssertTrue(room.contains("Label(\"No EELS spectrum image open\""))
        XCTAssertTrue(room.contains("EELSOneAxis("), "one axis with a gap")
        XCTAssertTrue(room.contains("\"validation: none\""), "the badge, once, in the results header")
        XCTAssertTrue(room.contains("EELSRoomFormat.thicknessLine(")); XCTAssertTrue(room.contains("EELSRoomFormat.fitFooter("))
        let verb = squeezed(try source("macTEM/UI/RoomPrimaryAction.swift"))
        XCTAssertTrue(verb.contains("title: \"Run\""))
        XCTAssertTrue(squeezed(try source("macTEM/UI/ContentView.swift")).contains("PrimaryActionButton(RoomPrimaryAction.current(appState))"))
        let state = squeezed(try source("macTEM/App/EELSRoomState.swift"))
        XCTAssertTrue(state.contains("var readout: String?"))
    }

    /// A file with only a core loss (its window starts above 0 eV): no t/λ, the anchor is I total, Convolve is off, and Align has nothing to move.
    @MainActor func testAFileWithOnlyACoreLossIsItsOwnState() async throws {
        let counts = [Double](repeating: 100, count: 2 * 2 * 64)
        let image = try LowLossSpectrumImage(nx: 2, ny: 2, channels: 64, counts: counts, energyOffsetEV: 800, energyScaleEV: 1)
        let session = EELSSession()
        await session.bind(LoadedEELS(fileName: "core.dm4", image: image, beamEnergyKeV: nil, convergenceMrad: nil, collectionMrad: nil, origin: "planted")).value
        await session.settled()
        XCTAssertFalse(session.hasLowLoss); XCTAssertTrue(session.onlyCoreLoss)
        let a = session.mapsAvailability
        XCTAssertTrue(a.onlyCoreLoss)
        XCTAssertNotNil(a.disabledReason(.tOverLambda)); XCTAssertNotNil(a.disabledReason(.zlp))
        let composition = EELSMapsComposition.compose(selection: a.effective(.tOverLambda), onlyCoreLoss: true, tiles: session.tiles, shiftTile: nil, modelTiles: [])
        XCTAssertEqual(composition.anchor?.id, "iTotal", "the anchor is the total intensity")
        XCTAssertNotNil(session.plot, "its spectrum is still drawn")
    }

    // MARK: Round 2 (143_STEM SI.dm4, 2026-10-22 evening)

    /// THE COLLAPSE (143_STEM SI.dm4, read through the app's reader): the core loss is clean from 150 to 1664 eV; the LOW LOSS cube runs -150 to 1364 eV on the same
    /// 0.75 eV grid, overlaps the core loss from 150 eV, and its summed counts fall below zero above about 1080 eV (a dark-subtracted detector tail), which a log axis
    /// drew as spikes to zero over the core loss. Red under: the low loss drawn over the core loss; a non-positive value drawn at the log floor.
    func testTheLowLossEndsWhereTheCoreLossStartsAndAnEmptyTailBreaksTheLogLine() throws {
        let axis = EELSOneAxis(low: -150...1363.5, core: 150...1663.5, width: 600)
        XCTAssertNil(axis.gap)
        XCTAssertEqual(axis.lowShown, -150...150); XCTAssertEqual(axis.coreShown, 150...1663.5)
        XCTAssertEqual(axis.segments.count, 2)
        XCTAssertEqual(axis.segments[0].x.upperBound, axis.segments[1].x.lowerBound, accuracy: 1e-9, "contiguous: no gap band")
        XCTAssertEqual(try XCTUnwrap(axis.x(forEnergy: 1000)), try XCTUnwrap(axis.x(forEnergy: 1000)))
        XCTAssertGreaterThan(try XCTUnwrap(axis.x(forEnergy: 1000)), try XCTUnwrap(axis.x(forEnergy: 150)), "the core loss carries the axis past 150 eV")
        let separate = EELSOneAxis(low: 0...300, core: 800...1100, width: 616, gapWidth: 30)
        XCTAssertEqual(separate.lowShown, 0...300); XCTAssertEqual(separate.coreShown, 800...1100)
        XCTAssertNil(EELSOneAxis(low: 0...300, core: nil, width: 100).lowShown)
        // The sum of a dark-subtracted tail: positive, then below zero for the rest.
        let sums = (0..<200).map { $0 < 120 ? 1000.0 / Double($0 + 1) : -50.0 }
        let stretches = EELSDeadStretch.stretches(counts: sums, origin: 100, step: 0.75)
        XCTAssertEqual(stretches.count, 1)
        XCTAssertEqual(try XCTUnwrap(stretches.first).lowerBound, 100 + 0.75 * 120, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(stretches.first).upperBound, 100 + 0.75 * 199, accuracy: 1e-9)
        XCTAssertTrue(EELSDeadStretch.stretches(counts: [5, 0, 0, 5, 0, 5], origin: 0, step: 1).isEmpty, "a few empty channels in a sparse spectrum are not a stretch")
        let room = squeezed(try source("macTEM/UI/EELSRoom.swift"))
        XCTAssertTrue(room.contains("if !v.isFinite || (isLog && v <= 0) { started = false; return }"), "a value with no counts breaks the log line")
        XCTAssertTrue(room.contains("within: axis.lowShown"), "the low loss is drawn only where the axis shows it")
    }

    /// A signal window on a stretch with no counts is refused by name, and the edge is not fitted; the other edge is. Red under: the dead stretch fitted through.
    @MainActor func testASignalWindowOnAnEmptyStretchIsRefusedByNameAndNotFitted() async throws {
        let nx = 2, ny = 2, channels = 400
        var counts = [Double](repeating: 0, count: nx * ny * channels)
        for p in 0..<(nx * ny) { for c in 0..<250 { counts[p * channels + c] = 500 * pow((600 + Double(c)) / 600, -3) } }   // 600...849 eV have counts, 850...999 do not
        let core = try CoreLossSpectrumImage(nx: nx, ny: ny, channels: channels, counts: counts, energyOffsetEV: 600, energyScaleEV: 1)
        let loaded = LoadedEELS(fileName: "dead.dm4", image: try Self.image(), beamEnergyKeV: 200, convergenceMrad: 0, collectionMrad: 10, origin: "planted", coreLoss: core, coreLossOrigin: "planted core")
        let session = EELSSession()
        await session.bind(loaded).value
        await session.settled()
        let stretch = try XCTUnwrap(session.coreDeadStretches.first)
        XCTAssertEqual(stretch.lowerBound, 850, accuracy: 1e-9)
        session.toggleEdge(.copperL3); session.toggleEdge(.ironL3)
        XCTAssertEqual(session.refusals.map { EELSFitCompute.title($0.edge) }, ["Cu L3"])
        XCTAssertTrue(try XCTUnwrap(session.refusals.first).reason.hasPrefix("Cu L3: the core loss holds no counts from 850"), session.refusals.first?.reason ?? "")
        XCTAssertEqual(session.fittableEdges.map(EELSFitCompute.title), ["Fe L3"])
        XCTAssertNil(session.fitBlocker, "the other edge can still be fitted")
        session.toggleEdge(.ironL3)
        XCTAssertTrue(try XCTUnwrap(session.fitBlocker).contains("Cu L3: the core loss holds no counts"), "all refused: Fit says why, by name")
        // Moving the window off the empty stretch lifts the refusal.
        session.setWindows(EELSEdgeWindows(background: 650...700, signal: 710...800), for: .copperL3)
        XCTAssertTrue(session.refusals.isEmpty)
    }

    /// The windows: the kit's defaults, drag by body or end, the background kept below the signal, and one window pair per fitted edge handed to the kit in onset order.
    @MainActor func testTheWindowsAreTheKitsDefaultsDraggableAndHandedToTheKitOnePerEdgeInOnsetOrder() async throws {
        let axis = EnergyAxis(offset: 0, scale: 1, size: 5000)
        let d = EELSEdgeWindows(EdgeWindows.defaults(onsetEV: 1000, family: "K", precedingSignalEndEV: nil, nextOnsetEV: nil, axis: axis))
        XCTAssertEqual(d.background.upperBound, 995, accuracy: 1e-9, "the kit's rule: 5 eV below the onset"); XCTAssertEqual(d.background.lowerBound, 895, accuracy: 1e-9)
        XCTAssertEqual(d.signal.lowerBound, 1000, accuracy: 1e-9); XCTAssertEqual(d.signal.upperBound, 1100, accuracy: 1e-9)
        XCTAssertEqual(d.kit, EdgeWindows(backgroundEV: d.background, signalEV: d.signal), "what the kit's fit takes")
        let limit = 500.0...1500.0
        func near(_ a: ClosedRange<Double>, _ b: ClosedRange<Double>, _ note: String = "") {
            XCTAssertEqual(a.lowerBound, b.lowerBound, accuracy: 1e-9, note); XCTAssertEqual(a.upperBound, b.upperBound, accuracy: 1e-9, note)
        }
        near(d.moved(.signalBody, by: 20, within: limit).signal, 1020...1120)
        near(d.moved(.signalUpper, by: 50, within: limit).signal, 1000...1150)
        near(d.moved(.signalLower, by: 500, within: limit).signal, 1099...1100, "a window keeps at least 1 eV")
        XCTAssertEqual(d.moved(.backgroundBody, by: 300, within: limit).background.upperBound, 1000, accuracy: 1e-9, "the background stops at the signal")
        XCTAssertEqual(d.moved(.backgroundLower, by: -900, within: limit).background.lowerBound, 500, "not past the spectrum")
        XCTAssertEqual(d.handle(at: 996, tolerance: 3), .backgroundUpper)
        XCTAssertEqual(d.handle(at: 900, tolerance: 3), .backgroundBody)
        XCTAssertEqual(d.handle(at: 1050, tolerance: 3), .signalBody)
        XCTAssertNil(d.handle(at: 1300, tolerance: 3))

        // One window pair per fitted edge, in onset order, whatever order the edges were picked in; the twins of one element and family are one.
        let picked: [CoreLossEdge] = [.copperL3, .siliconK, .ironL3, .copperL1]
        let plan = EELSWindowPlan.plan(for: picked, edited: [:], axis: axis)
        XCTAssertEqual(plan.map { EELSFitCompute.title($0.master) }, ["Fe L3", "Cu L3", "Si K"], "onset order, Cu L1 and Cu L3 are one group")
        XCTAssertEqual(plan.map(\.master.onsetEV), plan.map(\.master.onsetEV).sorted())
        let fe = EdgeWindows.defaults(onsetEV: CoreLossEdge.ironL3.onsetEV, family: "L", precedingSignalEndEV: nil, nextOnsetEV: CoreLossEdge.copperL3.onsetEV, axis: axis)
        let cu = EdgeWindows.defaults(onsetEV: CoreLossEdge.copperL3.onsetEV, family: "L", precedingSignalEndEV: fe.signalEV.upperBound, nextOnsetEV: CoreLossEdge.siliconK.onsetEV, axis: axis)
        XCTAssertEqual(plan[0].windows.kit, fe, "the neighbours' ends are the kit's inputs"); XCTAssertEqual(plan[1].windows.kit, cu)
        // A person's window replaces the group's; the neighbours' defaults follow it.
        let mine = EELSEdgeWindows(background: 650...700, signal: 710...800)
        let edited = EELSWindowPlan.plan(for: picked, edited: [EELSFitCompute.id(.ironL3): mine], axis: axis)
        XCTAssertEqual(edited[0].windows, mine); XCTAssertTrue(edited[0].isEdited); XCTAssertFalse(edited[1].isEdited)

        let session = EELSSession()
        await session.bind(try Self.loaded(beam: 200)).value
        XCTAssertTrue(session.fitWindows.isEmpty, "nothing picked: nothing to hand over")
        for e in picked { session.toggleEdge(e) }
        XCTAssertEqual(session.fitWindows.count, 3, "one per fitted edge")
        XCTAssertEqual(session.windows(for: .copperL1), session.windows(for: .copperL3), "twins share the group's windows")
        session.setWindows(d.moved(.backgroundLower, by: 30, within: limit), for: .siliconK)
        XCTAssertEqual(session.windows(for: .siliconK).background.lowerBound, session.fitWindows[2].backgroundEV.lowerBound, "an edited window is what the spectrum draws and what the kit gets")
        XCTAssertEqual(session.editedWindows.count, 1)
        session.resetWindows(for: .siliconK)
        XCTAssertTrue(session.editedWindows.isEmpty)
        let before = session.windows(for: .copperL3)
        session.setWindows(before.moved(.signalUpper, by: 10, within: 0...5000), for: .copperL3)
        XCTAssertEqual(session.editedWindows.count, 1)
        session.setWindows(before, for: .copperL3)
        XCTAssertTrue(session.editedWindows.isEmpty, "back at the defaults: not an edit")
    }

    /// A window the kit refuses becomes a sentence under Fitting and the fit is not run; a valid pair of windows reaches the kit and comes back in its result.
    @MainActor func testAWindowTheKitRefusesIsItsSentenceAndTheFitDoesNotRun() async throws {
        let nx = 2, ny = 2, channels = 400
        var counts = [Double](repeating: 0, count: nx * ny * channels)
        for p in 0..<(nx * ny) { for c in 0..<channels { counts[p * channels + c] = 5e5 * pow((600 + Double(c)) / 600, -3) } }
        let core = try CoreLossSpectrumImage(nx: nx, ny: ny, channels: channels, counts: counts, energyOffsetEV: 600, energyScaleEV: 1)
        let loaded = LoadedEELS(fileName: "windows.dm4", image: try Self.image(), beamEnergyKeV: 200, convergenceMrad: 0, collectionMrad: 10, origin: "planted", coreLoss: core, coreLossOrigin: "planted core")
        let session = EELSSession()
        await session.bind(loaded).value
        await session.settled()
        session.setConvolveLowLoss(false)
        session.toggleEdge(.copperL3); session.toggleEdge(.ironL3)
        let hand = session.fitWindows
        XCTAssertEqual(hand.count, 2); XCTAssertLessThan(hand[0].signalEV.lowerBound, hand[1].signalEV.lowerBound, "Fe L before Cu L")
        // Overlapping signal windows: the kit refuses, its sentence is under Fitting, nothing landed.
        session.setWindows(EELSEdgeWindows(background: 603...703, signal: 720...945), for: .ironL3)
        session.setWindows(EELSEdgeWindows(background: 826...926, signal: 940...999), for: .copperL3)
        await session.fit()?.value
        await session.settled()
        XCTAssertEqual(session.fitRefusal, "The signal windows of Fe L and Cu L share energies; each channel of the signal belongs to one edge. Move or narrow one of them.")
        XCTAssertNil(session.model, "the fit did not run"); XCTAssertNil(session.failure)
        XCTAssertEqual(EELSWindowPlan.sentence(for: EELSModelError.edgeWindowInvalid(edge: "Cu L", why: "signal window holds 1 channels, needs 2")), "Cu L: signal window holds 1 channels, needs 2.")
        XCTAssertNil(EELSWindowPlan.sentence(for: EELSModelError.emptyMask), "an error that is not about a window is not this sentence")
        // Moving the window clears the sentence; the fit then runs on the windows it was given and the kit's result carries them.
        session.resetWindows(for: .ironL3)
        XCTAssertNil(session.fitRefusal)
        await session.fit()?.value
        await session.settled()
        let model = try XCTUnwrap(session.model, "failure: \(session.failure ?? session.fitRefusal ?? "none")")
        XCTAssertEqual(model.edgeWindows, session.fitWindows, "the windows handed over are the windows the kit fitted")
        XCTAssertEqual(model.edges.map(EELSFitCompute.title), ["Fe L3", "Cu L3"], "one per fitted edge, in onset order")
        let row = try XCTUnwrap(session.regionRows.first)
        XCTAssertNotNil(row.exponent, "the kit's exponent under each edge")
        XCTAssertNotNil(EELSRoomFormat.exponentsLine(session.regionRows))
        for r in session.regionRows { XCTAssertGreaterThan(r.intensityStd ?? 0, 0, "\(r.title): the kit's 1 sigma on I reaches the row") }
        XCTAssertEqual(session.fitState, .current)
        session.setWindows(session.windows(for: .copperL3).moved(.signalUpper, by: -5, within: 600...999), for: .copperL3)
        XCTAssertEqual(session.fitState, .stale, "moving a window stales Fit")
    }

    /// The background control: only the power law is live; the others are refused with their reason.
    @MainActor func testOnlyThePowerLawBackgroundIsLive() async throws {
        XCTAssertNil(EELSBackgroundChoice.powerLaw.disabledReason)
        XCTAssertEqual(EELSBackgroundChoice.allCases.map(\.title), ["Power law", "LCPL", "Polynomial", "Linear"])
        XCTAssertEqual(EELSBackgroundChoice.lcpl.disabledReason, "LCPL is not in SpectroKit yet: only the power law fits today.")
        let session = EELSSession()
        session.setBackground(.linear)
        XCTAssertEqual(session.backgroundChoice, .powerLaw); XCTAssertNotNil(session.backgroundNotice)
        session.setBackground(.powerLaw)
        XCTAssertNil(session.backgroundNotice)
    }

    /// A reference from a region is the counts over the signal window less the kit's power-law background; an MSA file is read through FormatoKit.
    func testAReferenceIsTheRegionLessItsBackgroundOrAnMSAFile() throws {
        let edge = CoreLossEdge.copperL3
        let windows = EELSEdgeWindows(EdgeWindows.defaults(onsetEV: edge.onsetEV, family: edge.family, precedingSignalEndEV: nil, nextOnsetEV: nil,
                                                           axis: EnergyAxis(offset: 600, scale: 1, size: 400)))
        let counts = (0..<400).map { k -> Double in
            let e = 600 + Double(k)
            return 1000 * pow(e / 600, -3) + (e >= edge.onsetEV ? 50 : 0)
        }
        let core = EELSPlotCurve(origin: 600, step: 1, counts: counts)
        let reference = try XCTUnwrap(EELSReferenceCompute.fromRegion(name: "Region 1", edge: edge, core: core, windows: windows))
        XCTAssertEqual(reference.name, "Region 1 · Cu L3"); XCTAssertEqual(reference.originText, "Region 1 · Cu L3")
        XCTAssertEqual(reference.curve.range.lowerBound, ceil(windows.signal.lowerBound), accuracy: 1)
        XCTAssertEqual(reference.curve.counts.reduce(0, +) / Double(reference.curve.counts.count), 50, accuracy: 5, "the planted step, the background gone")
        let ext = try XCTUnwrap(EELSBackgroundFit.extrapolation(of: core, windows: windows, over: windows.background.lowerBound...windows.signal.upperBound))
        XCTAssertEqual(ext.count, counts.count)
        XCTAssertTrue(ext[0].isNaN, "outside the shown range: no value")
        XCTAssertNil(EELSReferenceCompute.fromRegion(name: "x", edge: edge, core: EELSPlotCurve(origin: 0, step: 1, counts: [1, 2, 3]), windows: windows))

        let msa = """
        #FORMAT      : EMSA/MAS Spectral Data File
        #VERSION     : 1.0
        #TITLE       : silicon reference
        #DATE        :
        #TIME        :
        #OWNER       :
        #NPOINTS     : 4
        #NCOLUMNS    : 1
        #XUNITS      : eV
        #YUNITS      : counts
        #DATATYPE    : Y
        #XPERCHAN    : 0.5
        #OFFSET      : 100
        #SPECTRUM    : Spectral Data Starts Here
        1.0
        2.0
        4.0
        8.0
        #ENDOFDATA   :
        """
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("eels-reference-\(UUID().uuidString).msa")
        try msa.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let imported = try EELSReferenceCompute.importMSA(url: url)
        XCTAssertEqual(imported.curve.counts, [1, 2, 4, 8]); XCTAssertEqual(imported.curve.origin, 100); XCTAssertEqual(imported.curve.step, 0.5)
        XCTAssertTrue(imported.originText.hasPrefix("from eels-reference-"))
        XCTAssertTrue(EELSReference.note.contains("MLLS fit with references is not in SpectroKit yet"))
    }

    /// The session keeps the references and says why one could not be made.
    @MainActor func testTheSessionKeepsAndRemovesReferencesAndSaysWhyNot() async throws {
        let session = try await openRoom(beam: 200)
        XCTAssertNil(session.addReferenceFromRegion(edge: .copperL3))
        XCTAssertEqual(session.referenceNotice, "This file holds no core loss to take a reference from.")
        XCTAssertNil(session.importReference(url: URL(fileURLWithPath: "/nonexistent/none.msa")))
        XCTAssertNotNil(session.referenceNotice)
        XCTAssertTrue(session.references.isEmpty)
    }

    /// The tile of a map whose pixels are all one value (the ZLP shift of 0): drawn at the middle of a grey ramp, never white, and the tile says so. The anchor and the tiles
    /// fit the scan's aspect as the EDS block does.
    func testAFlatTileIsDrawnAtTheMiddleAndNamesItsValueAndTheTilesFitTheScan() throws {
        let flat = EELSMapTile(id: "zlpShift", title: "ZLP shift", unit: "eV", width: 3, height: 2, values: [0, 0, 0, 0, .nan, 0], version: 1, footer: nil)
        XCTAssertTrue(EELSMapScale.isFlat(flat.values))
        XCTAssertEqual(EELSMapScale.flatValues(flat.values).filter { $0 == EELSMapScale.flatLevel }.count, 5)
        XCTAssertTrue(EELSMapScale.flatValues(flat.values)[4].isNaN)
        XCTAssertEqual(flat.detailText, "every pixel 0 eV")
        XCTAssertFalse(EELSMapScale.isFlat([0, 1])); XCTAssertFalse(EELSMapScale.isFlat([.nan]))
        XCTAssertEqual(EELSMapTile(id: "x", title: "t/λ", unit: "", width: 1, height: 1, values: [0.5], version: 1, footer: nil).detailText, "every pixel 0.5")
        XCTAssertEqual(EELSMapTile(id: "x", title: "t/λ", unit: "", width: 2, height: 1, values: [0.5, 0.6], version: 1, footer: nil).detailText, nil)
        XCTAssertEqual(EELSMapTile(id: "x", title: "I", unit: "counts", width: 2, height: 1, values: [1, 2], version: 1, footer: nil).detailText, "counts")
        XCTAssertEqual(EELSMapsComposition.aspect(nx: 432, ny: 172), 432.0 / 172.0, accuracy: 1e-12)
        XCTAssertEqual(EELSMapsComposition.aspect(nx: nil, ny: nil), 1)
        let room = squeezed(try source("macTEM/UI/EELSRoom.swift"))
        XCTAssertTrue(room.contains("aspect: CGFloat(aspect)"), "AnchoredMapsBlock fits the tiles to the scan")
        XCTAssertTrue(room.contains("EELSMapsComposition.aspect(nx: image?.nx, ny: image?.ny)"))
        XCTAssertTrue(room.contains("coloring: .colormap(.gray)"), "a flat map is grey, not the diverging scale's white")
        XCTAssertTrue(room.contains("detail: tile.detailText"))
    }

    /// The inspector: Maps, Tools, the λ choice and the Fitting model and background are MacEMUI's full-width SegmentedPicker; Tools has no paragraph; Processing
    /// has one note (its tooltip holds the refused pixels).
    func testTheInspectorUsesTheSharedControlsAndOneNotePerSection() throws {
        let inspector = squeezed(try source("macTEM/UI/EELSRoomInspector.swift"))
        for label in ["Maps", "Region tool", "Mean free path λ", "Model", "Background"] {
            XCTAssertTrue(inspector.contains("SegmentedPicker(label: \"\(label)\""), label)
        }
        XCTAssertFalse(inspector.contains("InspectorNote(state.tool.hint)"), "the tool's hint is its tooltip")
        XCTAssertTrue(inspector.contains("help: $0.hint"))
        XCTAssertFalse(inspector.contains("InspectorNote(\"The core loss is aligned with it.\")"))
        XCTAssertTrue(inspector.contains("EELSRoomFormat.processingNote("))
        XCTAssertFalse(inspector.contains(".pickerStyle(.segmented)"), "no centred pill")
        XCTAssertTrue(inspector.contains("EELSReferencesBlock(session: session)"))
        for label in ["From region", "Import…", "Remove"] { XCTAssertTrue(inspector.contains("\"\(label)\""), label) }
        XCTAssertEqual(EELSRoomFormat.processingNote(align: .current, thickness: .current, alignmentReadout: "offset -1 → 0 eV, 9 of 10 channels kept", coreAligned: true),
                       "Aligned: offset -1 → 0 eV, 9 of 10 channels kept The core loss is aligned with it.")
        XCTAssertEqual(EELSRoomFormat.processingNote(align: .notRun, thickness: .current, alignmentReadout: nil, coreAligned: false),
                       "Align —: Run aligns the zero-loss peak.")
    }

    /// The numbers in words: an energy as the app writes a number (three significant digits), never "-150,000 → -150,000".
    func testEnergiesPrintWithThreeSignificantDigits() {
        let en = Locale(identifier: "en_US")
        XCTAssertEqual(EELSRoomFormat.alignmentReadout(offsetBefore: -150, offsetAfter: -150, kept: 2020, of: 2020, locale: en), "offset -150 → -150 eV, 2020 of 2020 channels kept")
        XCTAssertEqual(EELSRoomFormat.eV(-0.0001, locale: en), "0"); XCTAssertEqual(EELSRoomFormat.eV(0.0123, locale: en), "0.0123")
        XCTAssertEqual(EELSRoomFormat.eV(-21.5026, locale: en), "-21.5")
        XCTAssertEqual(EELSRoomFormat.alignmentReadout(offsetBefore: -150, offsetAfter: -149.75, kept: 1, of: 2, locale: Locale(identifier: "de_DE")), "offset -150 → -150 eV, 1 of 2 channels kept")
    }

    /// The log axis's labels fit and read: plain digits to 1000, then 1e4, 1e11 (Paul, 2026-10-23: superscript decades were too small to read and were cut), and a left
    /// margin as wide as the widest, so no label is clipped; the axis title is drawn from the view's left edge, never cut ("ounts"). The gap says what it skips, once.
    func testTheLogAxisLabelsAreShortAndTheMarginHoldsTheWidest() throws {
        XCTAssertEqual((0...7).map { EELSRoomFormat.logTickLabel(decade: $0) }, ["1", "10", "100", "1000", "1e4", "1e5", "1e6", "1e7"])
        XCTAssertEqual(EELSRoomFormat.logTickLabel(decade: 11), "1e11")
        let labels = (0...7).map { EELSRoomFormat.logTickLabel(decade: $0) }
        XCTAssertGreaterThanOrEqual(EELSRoomFormat.leftMargin(labels: labels), 3 * 5.8 + 12)
        XCTAssertGreaterThan(EELSRoomFormat.leftMargin(labels: ["10000000"]), 52, "the old fixed 52 points clipped a seven-digit label")
        XCTAssertEqual(EELSRoomFormat.leftMargin(labels: []), 36)
        XCTAssertGreaterThanOrEqual(EELSRoomFormat.leftMargin(labels: ["69 528 956"]), 10 * 6.3 + 12, "a linear axis's widest label keeps its first digit")
        let axis = EELSOneAxis(low: -5...300, core: 800...1100, width: 616, gapWidth: 30)
        XCTAssertEqual(axis.gapLabel, "skips 300–800 eV")
        XCTAssertNil(EELSOneAxis(low: -5...300, core: nil, width: 600).gapLabel)
        let room = squeezed(try source("macTEM/UI/EELSRoom.swift"))
        XCTAssertTrue(room.contains("EELSRoomFormat.leftMargin(labels:"), "the margin is measured from the labels")
        XCTAssertTrue(room.contains("hatch(band"), "the gap is a hatched band"); XCTAssertTrue(room.contains("axis.gapLabel"))
        XCTAssertTrue(room.contains("dash: [3, 3]"))
        XCTAssertTrue(room.contains("at: CGPoint(x: 4, y: area.minY - 8), anchor: .leading"), "the counts axis's title starts at the view's left edge")
    }

    /// The spectrum zooms and pans as the EDS one does (Paul, 2026-10-23): the window cuts the low loss and the core loss, the gap stays between them, a window on the
    /// core loss alone draws one segment, and the drags are assigned by where they start. Red under: no window (the whole axis whatever the zoom).
    func testTheSpectrumWindowCutsBothSegmentsAndTheDragsAreTheEDSOnes() throws {
        let low = -5.0...300.0, core = 800.0...1100.0
        XCTAssertEqual(EELSOneAxis.domain(low: low, core: core), -5...1100)
        let whole = try XCTUnwrap(EELSOneAxis.windowed(low: low, core: core, window: nil))
        XCTAssertEqual(whole.low, low); XCTAssertEqual(whole.core, core)
        let both = try XCTUnwrap(EELSOneAxis.windowed(low: low, core: core, window: 100...900))
        XCTAssertEqual(both.low, 100...300); XCTAssertEqual(both.core, 800...900)
        XCTAssertEqual(EELSOneAxis(low: both.low, core: both.core, width: 600, gapWidth: 30).gapLabel, "skips 300–800 eV")
        let coreOnly = try XCTUnwrap(EELSOneAxis.windowed(low: low, core: core, window: 850...950))
        XCTAssertEqual(coreOnly.low, 850...950); XCTAssertNil(coreOnly.core)
        XCTAssertNil(EELSOneAxis.windowed(low: low, core: core, window: 400...500), "a window in the gap shows nothing")
        // The zoom is the EDS spectrum's arithmetic over the EELS domain.
        let zoomed = EDXSpectrumWindow.zoomed(-5...1100, factor: 2, anchor: 0.5, domain: -5...1100, minimumSpan: 2)
        XCTAssertEqual(zoomed.upperBound - zoomed.lowerBound, 552.5, accuracy: 1e-9)
        XCTAssertEqual(EELSSpectrumDrag.zone(start: CGPoint(x: 100, y: 195), size: CGSize(width: 600, height: 200), left: 40), .energyAxis)
        XCTAssertEqual(EELSSpectrumDrag.zone(start: CGPoint(x: 20, y: 50), size: CGSize(width: 600, height: 200), left: 40), .countsAxis)
        XCTAssertEqual(EELSSpectrumDrag.zone(start: CGPoint(x: 300, y: 50), size: CGSize(width: 600, height: 200), left: 40), .plot)
        let room = squeezed(try source("macTEM/UI/EELSRoom.swift"))
        XCTAssertTrue(room.contains(".onScrollWheel"), "the wheel zooms"); XCTAssertTrue(room.contains("MagnifyGesture"), "a pinch zooms")
        XCTAssertTrue(room.contains(".onTapGesture(count: 2)"), "a double click returns to the whole axis")
    }

    /// The regions' spectra are drawn over the selected one, as in the EDS room, in their colours with a legend; the drag preview is wired to the drawing layer;
    /// the inspector has no Regions list and no status icons on its section titles; the run's bar is the infobar's, not one over the maps (Paul, 2026-10-23).
    func testTheEELSRoomLaysOutItsRegionsSpectrumAndRunAsTheEDSRoom() throws {
        let room = squeezed(try source("macTEM/UI/EELSRoom.swift"))
        XCTAssertTrue(room.contains("SpectrumLayerLegend("), "a legend names the overlaid regions")
        XCTAssertTrue(room.contains("session.pinCoreSpectra"), "each region's core loss is overlaid")
        XCTAssertTrue(room.contains("onDrag: { session.previewRegion("), "the spectrum follows a region while it is dragged")
        XCTAssertFalse(room.contains("eels.progress"), "no progress bar over the maps")
        let inspector = squeezed(try source("macTEM/UI/EELSRoomInspector.swift"))
        XCTAssertFalse(inspector.contains("RegionsList("), "no region rows in the inspector")
        XCTAssertFalse(inspector.contains("InspectorSection(\"Edges\", icon:"), "plain section titles")
        XCTAssertFalse(inspector.contains("InspectorSection(\"Processing\", icon:")); XCTAssertFalse(inspector.contains("InspectorSection(\"Fitting\", icon:"))
        XCTAssertTrue(InfobarRunPolicy.shows(area: .eels, eelsComputing: true))
        XCTAssertFalse(InfobarRunPolicy.shows(area: .eels, eelsComputing: false)); XCTAssertFalse(InfobarRunPolicy.shows(area: .image, eelsComputing: true))
        XCTAssertEqual(InfobarRunPolicy.percent(0.426), "43 %")
    }

    /// The anchor is a colour mix, as in the EDS room (Paul, 2026-10-23): t/λ alone until edges are fitted, then the fitted edges; a click on a map puts it in or
    /// takes it out and the choice is the person's; a map that is no longer shown leaves the mix. Red under: a fixed t/λ anchor (no mix).
    func testTheAnchorIsAColourMixOfTheMapsTheClicksChoose() throws {
        func tile(_ id: String) -> EELSMapTile { EELSMapTile(id: id, title: id, unit: "", width: 2, height: 1, values: [0, 1], version: 1, footer: nil) }
        let t = tile("tOverLambda"), c = tile("edge-C-K"), n = tile("edge-N-K")
        var mix = ColorMix()
        XCTAssertEqual(EELSMixComposition.selection(mix, maps: [t]), ["tOverLambda"], "before a fit: t/λ")
        XCTAssertEqual(EELSMixComposition.selection(mix, maps: [t, c, n]), ["edge-C-K", "edge-N-K"], "after a fit: the edges")
        EELSMixComposition.toggle("tOverLambda", in: &mix, maps: [t, c, n])
        XCTAssertEqual(EELSMixComposition.selection(mix, maps: [t, c, n]), ["tOverLambda", "edge-C-K", "edge-N-K"])
        EELSMixComposition.toggle("edge-C-K", in: &mix, maps: [t, c, n])
        XCTAssertEqual(EELSMixComposition.selection(mix, maps: [t, c, n]), ["tOverLambda", "edge-N-K"])
        XCTAssertEqual(EELSMixComposition.selection(mix, maps: [t]), ["tOverLambda"], "a map not shown is not in the mix")
        XCTAssertEqual(EELSMixComposition.layers([c, n], appearance: MapAppearance()).count, 2)
        let room = squeezed(try source("macTEM/UI/EELSRoom.swift"))
        XCTAssertTrue(room.contains("AnchoredMapsBlock(anchor: mix,"), "the anchor is the mix")
        XCTAssertTrue(room.contains("onToggleMix: { EELSMixComposition.toggle("), "a click on a map toggles it in the mix")
    }

    /// λ: the estimate is offered (Iakoubovskii from E₀, α, β and a density) next to a typed value, t gets its value, and the results header says which.
    @MainActor func testLambdaIsEstimatedOrTypedAndTheHeaderSaysWhich() async throws {
        XCTAssertEqual(EELSRoomFormat.resultsHeader(region: "Region 1", lambdaNM: nil, lambdaSource: nil), "Results · Region 1 · λ not set")
        XCTAssertEqual(EELSRoomFormat.resultsHeader(region: "Whole map", lambdaNM: 112, lambdaSource: "given"), "Results · Whole map · λ given")
        let none = try await openRoom()
        XCTAssertEqual(none.lambdaEstimateBlocker, "The estimate needs the beam energy: the file does not state it. Type it under Fitting.")
        let session = try await openRoom(beam: 200)
        XCTAssertNil(session.lambdaEstimateBlocker)
        XCTAssertFalse(session.mapsAvailability.hasLambda, "no λ yet: t is off")
        session.setMeanFreePath(.iakoubovskii(density: 2.7, convergenceMrad: 0, collectionMrad: 10))
        await session.settled()
        let nm = try XCTUnwrap(session.map?.meanFreePathNM, "the estimate gives t a value")
        XCTAssertTrue(session.mapsAvailability.hasLambda); XCTAssertNil(session.mapsAvailability.disabledReason(.thickness))
        XCTAssertEqual(EELSRoomFormat.resultsHeader(region: "Whole map", lambdaNM: nm, lambdaSource: EELSRoomFormat.lambdaSource(session.meanFreePath)), "Results · Whole map · λ Iakoubovskii, 2.7 g/cm³")
        session.setMeanFreePath(.given(nanometres: 120))
        await session.settled()
        XCTAssertEqual(try XCTUnwrap(session.map?.meanFreePathNM), 120, accuracy: 1e-9)
        let inspector = squeezed(try source("macTEM/UI/EELSRoomInspector.swift"))
        XCTAssertTrue(inspector.contains("\"Typed λ\"")); XCTAssertTrue(inspector.contains("\"Estimate λ\""))
        let room = squeezed(try source("macTEM/UI/EELSRoom.swift"))
        XCTAssertTrue(room.contains("EELSRoomFormat.resultsHeader("))
    }

    /// The spectrum draws the windows, drags them, draws the extrapolated background and the references dashed.
    func testTheSpectrumDrawsAndDragsTheWindowsAndDrawsTheReferences() throws {
        let room = squeezed(try source("macTEM/UI/EELSRoom.swift"))
        XCTAssertTrue(room.contains("DragGesture(minimumDistance: 2)"))
        XCTAssertTrue(room.contains("EELSBackgroundFit.extrapolation(of:"), "the extrapolation is recomputed with the windows, so it follows a drag")
        XCTAssertTrue(room.contains("onWindows: { session.setWindows($1, for: $0) }"))
        XCTAssertTrue(room.contains("plot.backgrounds.first("), "the kit's fitted per-edge power law is drawn when the windows are the fit's")
        XCTAssertFalse(room.contains("MapColorControls")); XCTAssertFalse(room.contains("startExpanded")); XCTAssertTrue(room.contains("MapDisplayPopover(kind:")); XCTAssertTrue(room.contains("MapHistogram.bins("))
        XCTAssertTrue(room.contains("for (i, reference) in references.enumerated()")); XCTAssertTrue(room.contains("style: StrokeStyle(lineWidth: 1, dash: [6, 3])"))
    }

    /// Results line 7: I is written with its 1 sigma; an edge with I at or under 3 sigma is "below detection" in the at% column, never a bare 0.
    func testIntensityCarriesItsSigmaAndAWeakEdgeIsBelowDetection() {
        let en = Locale(identifier: "en_US")
        let c = EELSEdgeRow(id: "C-K", title: "C K", onsetEV: 284, intensity: 4.318e7, arealDensityPerNM2: nil, atomicPercent: 95.8, weightPercent: 94.5,
                            unavailable: nil, intensityStd: 2.1e5)
        let n = EELSEdgeRow(id: "N-K", title: "N K", onsetEV: 401, intensity: 0, arealDensityPerNM2: nil, atomicPercent: 0, weightPercent: 0,
                            unavailable: nil, intensityStd: 1.4e5)
        let weak = EELSEdgeRow(id: "O-K", title: "O K", onsetEV: 532, intensity: 3e5, arealDensityPerNM2: nil, atomicPercent: 0.7, weightPercent: 0.9,
                               unavailable: nil, intensityStd: 1.1e5)
        let bare = EELSEdgeRow(id: "O-K", title: "O K", onsetEV: 532, intensity: 3e5, arealDensityPerNM2: nil, atomicPercent: 0.7, weightPercent: 0.9, unavailable: nil)
        // Very large and very small intensities in e-notation (Paul's 143, 2026-10-23: "0.0001871 ± 0.0000000037" could not be read).
        XCTAssertEqual(EELSRoomFormat.intensityText(c, locale: en), "4.318e7 ± 2.1e5")
        XCTAssertEqual(EELSRoomFormat.intensityText(bare, locale: en), "3e5")
        let small = EELSEdgeRow(id: "C-K", title: "C K", onsetEV: 284, intensity: 1.871e-4, arealDensityPerNM2: nil, atomicPercent: nil, weightPercent: nil,
                                unavailable: nil, intensityStd: 3.7e-9)
        XCTAssertEqual(EELSRoomFormat.intensityText(small, locale: en), "1.871e-4 ± 3.7e-9")
        let mid = EELSEdgeRow(id: "C-K", title: "C K", onsetEV: 284, intensity: 1234, arealDensityPerNM2: nil, atomicPercent: nil, weightPercent: nil,
                              unavailable: nil, intensityStd: 56)
        XCTAssertEqual(EELSRoomFormat.intensityText(mid, locale: en), "1234 ± 56")
        XCTAssertFalse(c.belowDetection)
        XCTAssertTrue(n.belowDetection, "I = 0 with a sigma is below detection")
        XCTAssertTrue(weak.belowDetection, "I under 3 sigma")
        XCTAssertFalse(bare.belowDetection, "no sigma, no claim")
        XCTAssertEqual(EELSRoomFormat.atomicText(c, locale: en), "95.8")
        XCTAssertEqual(EELSRoomFormat.atomicText(n, locale: en), "below detection")
    }
}
