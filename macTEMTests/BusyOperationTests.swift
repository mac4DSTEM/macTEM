//
//  BusyOperationTests.swift
//  The toolbar's busy line names the work that is running (`BusyOperation`), never the last status sentence: during Quantify it read
//  "Opened … · 4096 channels", because the fit sets no sentence when it starts. The Patterns toolbar read "Reading the scan for the
//  map…" during Process and the quality pass, the Maps toolbar showed the file while Segment and the texture ran, and ⌘. did not
//  reach the texture.
//

import XCTest
import TEMCore
import TEMSession
@testable import macTEM

nonisolated final class BusyOperationTests: XCTestCase {
    private let opened = "Opened map.emd — 1024 × 1024 px, 4096 channels"
    private static let sdss = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures").appendingPathComponent("ebsd-sdss-ferrite-austenite.ang")

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

    /// The toolbar and the Stop button read the running work, not the status sentence. Red under: `appState.statusText` as the operation.
    func testTheToolbarAndStopReadTheRunningWork() throws {
        let view = squeezed(try source("macTEM/UI/ContentView.swift"))
        XCTAssertTrue(view.contains(".busy(operation: BusyOperation.name(room: room, appState: appState) ?? room.title,"))
        let verb = try source("macTEM/UI/RoomPrimaryAction.swift")
        XCTAssertFalse(verb.contains("operationName: appState.statusText"))
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

    /// The Patterns and Maps toolbars take their busy line from `BusyOperation`. Red before: the Patterns case read "Reading the scan for
    /// the map…" whatever ran, and the Maps case was busy only while opening.
    func testThePatternsAndMapsToolbarsReadTheRunningWork() throws {
        let view = squeezed(try source("macTEM/UI/ContentView.swift"))
        XCTAssertFalse(view.contains("Reading the scan for the map…"))
        XCTAssertFalse(view.contains("if session.isOpening {"), "the Maps toolbar is busy for more than its open")
        let busy = "if let operation = BusyOperation.toolbarOperation(room: room, appState: appState) { return .busy(operation: operation, "
        XCTAssertTrue(view.contains(busy + "progress: RoomProgress.fraction(room: room, appState: appState),"), "the Patterns case")
        XCTAssertTrue(view.contains(busy + "progress: nil,"), "the Maps case")
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

    /// The Maps toolbar names Segment and the texture while they run, and ⌘. ends the texture: its result never lands. Red before: the
    /// toolbar showed the file, Stop was off during the texture, and `stop()` left it running.
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

        let texturing = state.maps.showTexture()
        XCTAssertEqual(BusyOperation.toolbarOperation(room: .maps, appState: state), "Computing the texture…")
        XCTAssertTrue(RoomPrimaryAction.canStop(state), "⌘. reaches the texture")
        RoomPrimaryAction.stopActive(state)
        XCTAssertFalse(state.maps.isTexturing)
        XCTAssertFalse(RoomPrimaryAction.canStop(state))
        XCTAssertNil(BusyOperation.toolbarOperation(room: .maps, appState: state))
        XCTAssertEqual(state.statusText, "Stopped the texture")
        await texturing.value
        XCTAssertNil(state.maps.texture, "a stopped texture does not land")
    }
}
