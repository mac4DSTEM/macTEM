//
//  BusyOperationTests.swift
//  The toolbar's busy line names the work that is running (`BusyOperation`), never the last status sentence: during Quantify it read
//  "Opened … · 4096 channels", because the fit sets no sentence when it starts. The Patterns toolbar read "Reading the scan for the
//  map…" during Process and the quality pass, the Maps toolbar showed the file while Segment and the texture ran, and ⌘. did not
//  reach the texture.
//

import XCTest
import ShellEDXModel
import ShellLayout
import TEMCore
import TEMSession
@testable import macTEM

nonisolated final class BusyOperationTests: XCTestCase {
    private let opened = "Opened map.emd — 1024 × 1024 px, 4096 channels"
    private static let sdss = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures").appendingPathComponent("ebsd-sdss-ferrite-austenite.ang")
    private static let scan = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures").appendingPathComponent("ebsd-kikuchipy-h5ebsd.h5")

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    private func squeezed(_ text: String) -> String { text.split(whereSeparator: \.isWhitespace).joined(separator: " ") }

    /// With the EDS room busy fitting (a Quantify: the fit runs inside a refresh), the operation is the fit, not the open line. Red under:
    /// the busy line taking the status sentence.
    func testAQuantifyIsNamedNotTheOpenLine() {
        let name = BusyOperation.edx(opening: false, openSentence: opened, fitting: true, checking: false, identifying: false, mapping: false, refreshing: true)
        XCTAssertEqual(name, "Quantifying…")
    }

    /// Each EDS busy flag has its own name; idle has none.
    func testEachEDSWorkHasItsName() {
        func edx(fit: Bool = false, check: Bool = false, id: Bool = false, maps: Bool = false, refresh: Bool = false) -> String? {
            BusyOperation.edx(opening: false, openSentence: opened, fitting: fit, checking: check, identifying: id, mapping: maps, refreshing: refresh)
        }
        XCTAssertEqual(edx(check: true), "Checking for unlisted lines…")
        XCTAssertEqual(edx(id: true), "Identifying elements…")
        XCTAssertEqual(edx(maps: true), "Computing the composition maps…")
        XCTAssertEqual(edx(refresh: true), "Updating the spectrum and maps…")
        XCTAssertNil(edx())
    }

    /// An open keeps the sentence it sets as it starts ("Opening <file>…"); a stale one is not taken for it.
    func testAnOpenKeepsItsOwnSentence() {
        XCTAssertEqual(BusyOperation.edx(opening: true, openSentence: "Opening map.emd…", fitting: false, checking: false, identifying: false,
                                         mapping: false, refreshing: false), "Opening map.emd…")
        XCTAssertEqual(BusyOperation.edx(opening: true, openSentence: opened, fitting: false, checking: false, identifying: false,
                                         mapping: false, refreshing: false), "Opening the spectrum image…")
        XCTAssertEqual(BusyOperation.eels(opening: true, openSentence: opened, computing: false, stage: nil), "Opening the spectrum image…")
    }

    /// The EELS room names the stage its pass computes.
    func testTheEELSStageIsNamed() {
        XCTAssertEqual(BusyOperation.eels(opening: false, openSentence: opened, computing: true, stage: .align), "Aligning the zero-loss peak…")
        XCTAssertEqual(BusyOperation.eels(opening: false, openSentence: opened, computing: true, stage: .thickness), "Mapping the thickness…")
        XCTAssertEqual(BusyOperation.eels(opening: false, openSentence: opened, computing: true, stage: .fit), "Fitting the edges…")
        XCTAssertNil(BusyOperation.eels(opening: false, openSentence: opened, computing: false, stage: .fit))
    }

    /// An idle room in a fresh window names nothing.
    @MainActor func testAnIdleRoomNamesNothing() {
        let state = AppState()
        XCTAssertNil(BusyOperation.name(room: .edx, appState: state))
        XCTAssertNil(BusyOperation.name(room: .eels, appState: state))
    }

    /// Each room's verb names the work its room runs, never the status sentence, so its Stop's help and VoiceOver label say what Stop
    /// ends: idle, the verb names nothing while the status line still holds the last event; while the Index runs, the verb names the
    /// run and its Stop ends it. Red under: `operationName: appState.statusText` in the idle verb of the EDS, EELS, Patterns, Indexing
    /// or Maps room (the verb then names the status sentence), or the Index verb's `stop` dropped (the run goes on). The EDS room's
    /// opening verb is held by `testTheEDSOpeningVerbNamesTheOpenNotTheStatusLine`, and the Cancel of a room without a verb by
    /// `testARoomWithoutAVerbOffersCancelForARunInAnotherRoom`.
    @MainActor func testEachVerbNamesTheRunningWorkNotTheStatusLine() async throws {
        let state = AppState()
        state.edx.bind(DemoDocuments.edx())
        state.edx.stop()
        let spectra = try DemoDocuments.eels()
        state.eels.bind(spectra)
        await state.eels.settled()
        await state.ebsd.bind(try DemoDocuments.ebsd()).value
        try await waitUntil("the demo documents' passes in the EDS, EELS, Patterns and Maps rooms to end", seconds: 30) {
            !state.edx.isBusy && !state.eels.isBusy && !state.ebsd.isBusy && !state.ebsd.isComputingMean && !state.maps.isBusy
        }
        state.statusText = opened
        for room in [WorkspaceArea.edx, .eels, .patterns, .indexing, .maps] {
            state.navigation.workspaceArea = room
            let action = try XCTUnwrap(RoomPrimaryAction.current(state), "the \(room.title) room has its verb")
            XCTAssertFalse(action.isRunning, room.title)
            XCTAssertNil(action.operationName, "\(room.title): an idle verb names no work, and never the status sentence")
        }

        state.navigation.workspaceArea = .indexing
        XCTAssertTrue(state.indexing.canIndex, state.indexing.refusal ?? "")
        let run = state.indexing.index()
        state.statusText = opened
        let running = try XCTUnwrap(RoomPrimaryAction.current(state), "the Index runs: the verb is its Stop")
        XCTAssertTrue(running.isRunning)
        XCTAssertEqual(running.operationName, "Indexing with Hough…", "the Stop names the run, not the status sentence")
        running.stop?()
        XCTAssertFalse(state.indexing.isIndexing, "the verb's Stop ends the run")
        await run.value
        XCTAssertTrue(state.indexing.wasStopped)
    }

    /// While the EDS room opens a spectrum image, its verb is the open's Stop, and the Stop names the open even when the status line
    /// holds an older event. Red under: `operationName: appState.statusText` in the EDS room's opening verb (the Stop then names the
    /// status sentence).
    @MainActor func testTheEDSOpeningVerbNamesTheOpenNotTheStatusLine() async throws {
        let state = AppState()
        state.navigation.workspaceArea = .edx
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("not-yet-\(UUID().uuidString).emd")
        try Data(count: 64).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let open = state.edx.open(url: url)
        state.statusText = opened
        let action = try XCTUnwrap(RoomPrimaryAction.current(state), "opening: the verb is its Stop")
        XCTAssertTrue(action.isRunning)
        XCTAssertEqual(action.operationName, "Opening the spectrum image…", "the open's Stop names the open, not the status sentence")
        action.stop?()
        XCTAssertFalse(state.edx.isOpening, "the Stop ends the open")
        await open.value
    }

    /// The Patterns room names its open, its run, the map's pass and the quality pass, in the order the map pane's header shows them.
    /// Red before: the quality pass had no name (the verb's Cancel said nothing) and the open was the toolbar's own literal.
    func testEachPatternsWorkHasItsName() {
        func patterns(open: Bool = false, process: Bool = false, map: Bool = false, quality: Bool = false) -> String? {
            BusyOperation.patterns(opening: open, processing: process, mapping: map, qualityMapping: quality, stage: .dynamicBackground)
        }
        XCTAssertEqual(patterns(open: true, map: true), "Opening the dataset…")
        XCTAssertEqual(patterns(process: true, map: true, quality: true), "Processing: Dynamic background…")
        XCTAssertEqual(BusyOperation.patterns(opening: false, processing: true, mapping: false, qualityMapping: false, stage: nil),
                       "Processing the patterns…")
        XCTAssertEqual(patterns(map: true, quality: true), "Reading the scan…")
        XCTAssertEqual(patterns(quality: true), "Computing the quality maps…")
        XCTAssertEqual(BusyOperation.patterns(opening: false, processing: false, mapping: false, qualityMapping: false, computingMean: true, stage: nil),
                       "Computing the scan's mean pattern…")
        XCTAssertNil(patterns())
    }

    /// The Maps room names its open, Segment, the texture and a layer's picture. Red before: only Segment had a name.
    func testEachMapsWorkHasItsName() {
        func maps(open: Bool = false, segment: Bool = false, texture: Bool = false, draw: Bool = false) -> String? {
            BusyOperation.maps(opening: open, segmenting: segment, texturing: texture, drawing: draw)
        }
        XCTAssertEqual(maps(open: true, segment: true), "Opening the orientation map…")
        XCTAssertEqual(maps(segment: true, texture: true, draw: true), "Segmenting grains…")
        XCTAssertEqual(maps(texture: true, draw: true), "Computing the texture…")
        XCTAssertEqual(maps(draw: true), "Drawing the map…")
        XCTAssertNil(maps())
    }

    /// The Patterns toolbar names the pass that runs, and the quality pass reports its own fraction. The demo's map pass starts as it is
    /// bound; stopped, the quality pass runs alone. Red before: the line read "Reading the scan for the map…" and the fraction was nil.
    @MainActor func testThePatternsToolbarNamesTheQualityPass() throws {
        let state = AppState()
        XCTAssertNil(BusyOperation.toolbarOperation(room: .patterns, appState: state), "idle without a dataset")
        state.ebsd.bind(try DemoDocuments.ebsd())
        XCTAssertEqual(BusyOperation.toolbarOperation(room: .patterns, appState: state), "Reading the scan…")
        state.ebsd.stop()
        XCTAssertNil(BusyOperation.toolbarOperation(room: .patterns, appState: state))
        state.ebsd.showMap(.imageQuality)
        XCTAssertTrue(state.ebsd.isQualityMapping)
        XCTAssertEqual(BusyOperation.toolbarOperation(room: .patterns, appState: state), "Computing the quality maps…")
        XCTAssertEqual(RoomProgress.fraction(room: .patterns, appState: state), 0)
        state.ebsd.stop()
        XCTAssertNil(BusyOperation.toolbarOperation(room: .patterns, appState: state))
        XCTAssertNil(RoomProgress.fraction(room: .patterns, appState: state))
    }

    /// The Maps toolbar names Segment and the texture while they run, and ⌘. ends the texture: its result never lands, the session
    /// remembers it was stopped, and Compute Texture (`canComputeTexture`) makes it again (macTEM#410). Red before: the toolbar showed the
    /// file, Stop was off during the texture, and `stop()` left it running; then nothing remembered the stop or offered to compute again.
    @MainActor func testTheMapsToolbarNamesSegmentAndTheTextureAndStopEndsIt() async {
        let state = AppState()
        state.navigation.workspaceArea = .maps
        await state.maps.open(url: Self.sdss).value
        XCTAssertNil(BusyOperation.toolbarOperation(room: .maps, appState: state), "idle once the map is drawn")

        let segmenting = state.maps.segment()
        XCTAssertEqual(BusyOperation.toolbarOperation(room: .maps, appState: state), "Segmenting grains…")
        RoomPrimaryAction.stopActive(state)
        await segmenting.value
        XCTAssertNil(BusyOperation.toolbarOperation(room: .maps, appState: state))

        XCTAssertTrue(state.maps.canComputeTexture, "a map with a textured phase and no texture yet")
        XCTAssertFalse(state.maps.textureStopped)
        let texturing = state.maps.showTexture()
        XCTAssertEqual(BusyOperation.toolbarOperation(room: .maps, appState: state), "Computing the texture…")
        XCTAssertFalse(state.maps.canComputeTexture, "Compute Texture is off while the texture is made")
        XCTAssertTrue(RoomPrimaryAction.canStop(state), "⌘. reaches the texture")
        RoomPrimaryAction.stopActive(state)
        XCTAssertFalse(state.maps.isTexturing)
        XCTAssertFalse(RoomPrimaryAction.canStop(state))
        XCTAssertNil(BusyOperation.toolbarOperation(room: .maps, appState: state))
        XCTAssertEqual(state.statusText, "Stopped the texture")
        await texturing.value
        XCTAssertNil(state.maps.texture, "a stopped texture does not land")
        XCTAssertTrue(state.maps.textureStopped, "the session remembers the stop")
        XCTAssertTrue(state.maps.canComputeTexture, "Compute Texture makes it again")

        await state.maps.showTexture().value
        XCTAssertNotNil(state.maps.texture, "computed again after the stop")
        XCTAssertFalse(state.maps.textureStopped)
        XCTAssertFalse(state.maps.canComputeTexture, "Compute Texture is off while a texture is shown")
    }

    // MARK: A run in another room

    /// The room whose run the toolbar shows and ⌘. stops in place of an idle shown room: the first busy room in the Workspace menu's
    /// order; none while the shown room is busy itself or nothing else runs. Red before: no such room, so a run elsewhere showed nowhere.
    func testTheBackgroundRoomIsTheFirstBusyOtherRoom() {
        XCTAssertEqual(BusyOperation.backgroundRoom(shown: .maps, busy: [.indexing]), .indexing)
        XCTAssertEqual(BusyOperation.backgroundRoom(shown: .image, busy: [.maps, .indexing, .eels]), .eels)
        XCTAssertNil(BusyOperation.backgroundRoom(shown: .maps, busy: [.maps, .indexing]), "a busy shown room keeps its own")
        XCTAssertNil(BusyOperation.backgroundRoom(shown: .maps, busy: []))
        XCTAssertNil(BusyOperation.backgroundRoom(shown: .image, busy: [.diffraction]), "the ring fit is stopped in its own room")
    }

    /// An Index left running while the Maps room is shown: the toolbar names it under its room, ⌘. is on, says which room it stops and
    /// stops it; with the Indexing room shown the run is its own again. Red before: `canStop` was false outside the Indexing room and
    /// ⌘. reached only the shown room.
    @MainActor func testAnIndexRunningBehindTheMapsRoomShowsAndStops() async throws {
        let state = AppState()
        await state.ebsd.bind(try DemoDocuments.ebsd()).value
        try await waitUntil("the demo scan's passes in the Patterns and Maps rooms to end", seconds: 30) {
            !state.ebsd.isBusy && !state.ebsd.isComputingMean && !state.maps.isBusy
        }
        state.navigation.workspaceArea = .maps
        XCTAssertNil(BusyOperation.backgroundRoom(state), "nothing runs")
        XCTAssertFalse(RoomPrimaryAction.canStop(state))
        XCTAssertEqual(RoomPrimaryAction.stopTitle(state), "Stop")
        XCTAssertTrue(state.indexing.canIndex, state.indexing.refusal ?? "")

        let run = state.indexing.index()
        XCTAssertTrue(state.indexing.isIndexing)
        XCTAssertEqual(BusyOperation.backgroundRoom(state), .indexing)
        let line = try XCTUnwrap(BusyOperation.backgroundOperation(room: .indexing, appState: state))
        XCTAssertTrue(line.hasPrefix("Indexing · Hough · "), line)
        // The counts as the map's count line writes them, never grouped: "Hough · 0 of 1200" in German too, where it read "1.200".
        let german = BusyOperation.indexingLine(state.indexing, dataset: try XCTUnwrap(state.indexing.patterns.dataset), locale: Locale(identifier: "de_DE"))
        XCTAssertTrue(german.hasPrefix("Hough · ") && german.hasSuffix(" of 1200"), german)
        XCTAssertTrue(RoomPrimaryAction.canStop(state), "⌘. reaches the run")
        XCTAssertEqual(RoomPrimaryAction.stopTitle(state), "Stop Indexing")

        state.navigation.workspaceArea = .indexing
        XCTAssertNil(BusyOperation.backgroundRoom(state), "the shown room's run is its own")
        XCTAssertEqual(RoomPrimaryAction.stopTitle(state), "Stop")

        state.navigation.workspaceArea = .maps
        RoomPrimaryAction.stopActive(state)
        XCTAssertFalse(state.indexing.isIndexing)
        await run.value
        XCTAssertTrue(state.indexing.wasStopped)
        XCTAssertNil(BusyOperation.backgroundRoom(state))
        XCTAssertFalse(RoomPrimaryAction.canStop(state))
    }

    /// A room without a verb (the Image room) offers Cancel in the verb's place for a run left going in another room, as ShellLayout's
    /// `PrimaryAction` documents (no title, a run in flight keeps its Cancel), and the Cancel stops that run; Workspace > Run (⌘R) stays
    /// off and reads "Run". Red before: `current` was nil there, so the toolbar showed the run and nothing on screen stopped it.
    @MainActor func testARoomWithoutAVerbOffersCancelForARunInAnotherRoom() async throws {
        let state = AppState()
        await state.ebsd.bind(try DemoDocuments.ebsd()).value
        try await waitUntil("the demo scan's passes in the Patterns and Maps rooms to end", seconds: 30) {
            !state.ebsd.isBusy && !state.ebsd.isComputingMean && !state.maps.isBusy
        }
        state.navigation.workspaceArea = .image
        XCTAssertNil(RoomPrimaryAction.current(state), "nothing runs: no verb, no Cancel")
        XCTAssertEqual(PrimaryActionPresentation.of(RoomPrimaryAction.current(state)), .hidden)
        XCTAssertTrue(state.indexing.canIndex, state.indexing.refusal ?? "")

        let run = state.indexing.index()
        XCTAssertTrue(state.indexing.isIndexing)
        let action = try XCTUnwrap(RoomPrimaryAction.current(state), "the Index runs behind the Image room: its Cancel is offered")
        XCTAssertNil(action.title, "the Image room has no verb")
        XCTAssertEqual(PrimaryActionPresentation.of(action), .cancel)
        XCTAssertEqual(action.operationName, "Indexing · Indexing with Hough…", "the Cancel says which room and what it runs")
        XCTAssertFalse(RoomPrimaryAction.canRun(action), "⌘R stays off")
        XCTAssertEqual(RoomPrimaryAction.runTitle(state), "Run")

        action.stop?()
        XCTAssertFalse(state.indexing.isIndexing, "the Cancel stops the run it names")
        XCTAssertNil(RoomPrimaryAction.current(state), "the Cancel goes with the run")
        await run.value
        XCTAssertTrue(state.indexing.wasStopped)
    }

    /// A dataset opened while the Indexing room is shown is that room's own work (it shows the scan too and draws the open with a Stop
    /// of its own): no other room's run takes the toolbar, and ⌘. reads "Stop" and ends the open. From a room that does not show the
    /// scan the open stays the Patterns room's. Red before: the Indexing room was busy only while it indexed, so the toolbar read
    /// "Patterns · Opening the dataset…" and the item "Stop Patterns" for the open the shown room was drawing.
    @MainActor func testADatasetOpeningInTheIndexingRoomIsItsOwnWork() async {
        let state = AppState()
        state.navigation.workspaceArea = .indexing
        let open = state.ebsd.open(url: Self.scan)
        XCTAssertTrue(state.ebsd.isOpening)
        XCTAssertTrue(BusyOperation.isBusy(.indexing, appState: state), "the room that shows the scan is busy with its open")
        XCTAssertNil(BusyOperation.backgroundRoom(state), "the shown room's own open, not another room's run")
        XCTAssertEqual(RoomPrimaryAction.stopTarget(state), .indexing)
        XCTAssertTrue(RoomPrimaryAction.canStop(state))
        XCTAssertEqual(RoomPrimaryAction.stopTitle(state), "Stop")

        state.navigation.workspaceArea = .maps
        XCTAssertEqual(BusyOperation.backgroundRoom(state), .patterns, "from a room that does not show the scan it is the Patterns room's")
        XCTAssertEqual(RoomPrimaryAction.stopTitle(state), "Stop Patterns")

        state.navigation.workspaceArea = .indexing
        RoomPrimaryAction.stopActive(state)
        XCTAssertFalse(state.ebsd.isOpening, "⌘. ends the open")
        XCTAssertFalse(RoomPrimaryAction.canStop(state))
        await open.value
        XCTAssertFalse(state.ebsd.hasDataset, "a stopped open binds nothing")
    }

    /// A layer picked in the Maps room while an Index runs in another room: a layer's picture is not work Stop ends, so the Index
    /// keeps the toolbar's line and ⌘.; with nothing else running the room still names its draw. Red before: the draw made the shown
    /// room busy, so for its length `backgroundRoom` was nil, the line read "Drawing the map…" and ⌘. was off.
    @MainActor func testALayersPictureDoesNotHideARunInAnotherRoom() async throws {
        let state = AppState()
        await state.ebsd.bind(try DemoDocuments.ebsd()).value
        try await waitUntil("the demo scan's passes in the Patterns and Maps rooms to end", seconds: 30) {
            !state.ebsd.isBusy && !state.ebsd.isComputingMean && !state.maps.isBusy
        }
        state.navigation.workspaceArea = .maps
        XCTAssertTrue(state.maps.hasMap, "the demo carries its own crystal map")
        XCTAssertTrue(state.indexing.canIndex, state.indexing.refusal ?? "")

        let run = state.indexing.index()
        let drawing = state.maps.setLayer(.phase)
        XCTAssertTrue(state.indexing.isIndexing)
        XCTAssertTrue(state.maps.isDrawing)
        XCTAssertFalse(BusyOperation.isBusy(.maps, appState: state), "a layer's picture is not work Stop ends")
        XCTAssertEqual(BusyOperation.backgroundRoom(state), .indexing, "the Index keeps the toolbar's line")
        XCTAssertTrue(RoomPrimaryAction.canStop(state), "⌘. stays on")
        XCTAssertEqual(RoomPrimaryAction.stopTitle(state), "Stop Indexing")

        RoomPrimaryAction.stopActive(state)
        XCTAssertFalse(state.indexing.isIndexing)
        XCTAssertNil(BusyOperation.backgroundRoom(state))
        XCTAssertEqual(BusyOperation.toolbarOperation(room: .maps, appState: state), "Drawing the map…",
                       "with nothing else running the room names its draw")
        await run.value
        await drawing.value
    }

    /// Workspace > Stop takes its title from the run it stops (`RoomPrimaryAction.stopTitle`, held by
    /// `testAnIndexRunningBehindTheMapsRoomShowsAndStops`). This stays a pin: the item is built in the app's menu commands, a view no
    /// test calls. The toolbar's line for that run is held by `ToolbarDisplayTests.testARunInAnotherRoomShowsUnderItsRoomsName`. Red
    /// under: the item titled "Stop" whatever it stops.
    func testTheStopItemTakesTheTitleOfTheRunItStops() throws {
        let menu = squeezed(try source("macTEM/App/macTEMApp.swift"))
        XCTAssertTrue(menu.contains("Button(appState.map { RoomPrimaryAction.stopTitle($0) } ?? \"Stop\") { if let appState { RoomPrimaryAction.stopActive(appState) } }"))
    }
}
