//
//  ToolbarDisplayTests.swift
//  The toolbar's centre line (`ToolbarDisplay.state`) on a window's state, room by room: nothing without a document; the file, the
//  room and one more fact while the shown room is at rest; the running work, its fraction and its clock while the room is busy; and
//  another room's run while the shown room is at rest. These were held by the text of `ContentView` before, which a reflow could break
//  and which passed whatever the window showed (#266). The clock is read 42 s after the room's busy edge (`elapsed`).
//

import Foundation
import XCTest
import ShellEDXModel
import ShellLayout
import ShellSpectroscopy
import TEMCore
import TEMSession
@testable import macTEM

nonisolated final class ToolbarDisplayTests: XCTestCase {
    private let opened = "Opened map.emd — 1024 × 1024 px, 4096 channels"
    private static let sdss = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures").appendingPathComponent("ebsd-sdss-ferrite-austenite.ang")
    private static let scan = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures").appendingPathComponent("ebsd-kikuchipy-h5ebsd.h5")
    private static let scanHelp = "Scan width × height in points, of patterns of width × height in pixels"
    private static let mapHelp = "Map width × height in points, and its indexed phases"

    /// What the busy line's clock reads 42 s after `room` became busy (`AppState.markBusy`, which the window calls at each room's busy
    /// edge): the elapsed time, or nil when it reads nothing. The start is cleared after, so the next reading starts from none.
    @MainActor private func elapsed(_ metrics: (Date) -> (elapsed: TimeInterval, eta: TimeInterval?)?, since room: WorkspaceArea,
                                    in state: AppState) -> TimeInterval? {
        let start = Date(timeIntervalSinceReferenceDate: 1000)
        state.markBusy(room, true, now: start)
        defer { state.markBusy(room, false) }
        return metrics(start.addingTimeInterval(42))?.elapsed
    }

    /// A window with nothing open shows nothing, whichever room is shown. Red under: the spectrum rooms' guard on the window's title
    /// dropped (the line then reads "macEM · EDS · spectrum image").
    @MainActor func testNothingShowsWithoutADocument() {
        let state = AppState(launch: LaunchOptions(arguments: []))
        for room in WorkspaceArea.allCases {
            state.navigation.workspaceArea = room
            XCTAssertNil(ToolbarDisplay.state(state), room.title)
        }
    }

    /// An image open: each room that shows it reads the file, the room and the image's size in pixels, with no help. Red under: the size
    /// worded otherwise ("512 x 512", or without "px"), another room's title in its place, or a help on the image's line.
    @MainActor func testAnImageShowsItsFileTheRoomAndItsSize() async {
        let state = AppState(launch: LaunchOptions(arguments: []))
        await state.openDemo(.lattice)?.value
        for room in [WorkspaceArea.image, .fft, .diffraction, .results] {
            state.navigation.workspaceArea = room
            guard case let .idle(file, title, detail, help)? = ToolbarDisplay.state(state) else {
                return XCTFail("\(room.title): the image's line")
            }
            XCTAssertEqual(file, "Demo lattice", room.title)
            XCTAssertEqual(title, room.title)
            XCTAssertEqual(detail, "512 × 512 px", room.title)
            XCTAssertNil(help, room.title)
        }
    }

    /// The EDS room while its first pass runs, then at rest: the busy line names the work that runs, never the status sentence, with no
    /// fraction and the clock from the room's own start; at rest, the file, the room and the room's own detail. Red under:
    /// `appState.statusText` or `room.title` as the operation, `metrics: { _ in nil }`, the clock read from another room's start, or
    /// the EELS room's detail ("spectrum image") in the EDS room.
    @MainActor func testTheEDSRoomShowsItsRunningWorkAndClockThenItsFile() {
        let state = AppState(launch: LaunchOptions(arguments: []))
        state.navigation.workspaceArea = .edx
        state.edx.bind(DemoDocuments.edx())
        state.statusText = opened
        XCTAssertTrue(state.edx.isBusy, "setup: the demo's first pass runs")
        guard case let .busy(operation, progress, metrics)? = ToolbarDisplay.state(state) else {
            return XCTFail("the EDS room's pass is the toolbar's line")
        }
        XCTAssertEqual(operation, "Updating the spectrum and maps…", "the running work, not the status sentence")
        XCTAssertNil(progress, "the pass reports no fraction")
        XCTAssertEqual(elapsed(metrics, since: .edx, in: state), 42, "the clock runs from the EDS room's start")

        state.edx.stop()
        XCTAssertFalse(state.edx.isBusy)
        guard case let .idle(file, room, detail, help)? = ToolbarDisplay.state(state) else {
            return XCTFail("the EDS room at rest shows its file")
        }
        XCTAssertEqual(file, "Demo EDX")
        XCTAssertEqual(room, "EDS")
        XCTAssertEqual(detail, EDXRoomFormat.capsuleDetail(state.edx))
        XCTAssertTrue(detail.hasPrefix("16 × 16 px · "), detail)
        XCTAssertNil(help)
    }

    /// The EELS room while its first pass runs, then at rest: the busy line names what `BusyOperation` names, never the status sentence,
    /// with the pass's fraction and the clock from the room's own start; at rest, the file, the room and "spectrum image". Red under:
    /// `appState.statusText` as the operation, `progress: nil` in the spectrum rooms' busy line, or `metrics: { _ in nil }`.
    @MainActor func testTheEELSRoomShowsItsRunningWorkAndClockThenItsFile() async throws {
        let state = AppState(launch: LaunchOptions(arguments: []))
        state.navigation.workspaceArea = .eels
        state.eels.bind(try DemoDocuments.eels())
        state.statusText = opened
        XCTAssertTrue(state.eels.isComputing, "setup: the demo's first pass runs")
        guard case let .busy(operation, progress, metrics)? = ToolbarDisplay.state(state) else {
            return XCTFail("the EELS room's pass is the toolbar's line")
        }
        XCTAssertEqual(operation, BusyOperation.name(room: .eels, appState: state), "the running work")
        XCTAssertNotEqual(operation, opened, "never the status sentence")
        XCTAssertNotNil(progress, "the pass's fraction")
        XCTAssertEqual(progress, RoomProgress.fraction(room: .eels, appState: state))
        XCTAssertEqual(elapsed(metrics, since: .eels, in: state), 42, "the clock runs from the EELS room's start")

        await state.eels.settled()
        guard case let .idle(file, room, detail, help)? = ToolbarDisplay.state(state) else {
            return XCTFail("the EELS room at rest shows its file")
        }
        XCTAssertEqual(file, "Demo EELS")
        XCTAssertEqual(room, "EELS")
        XCTAssertEqual(detail, "spectrum image")
        XCTAssertNil(help)
    }

    /// The Patterns room names the pass that runs, with its fraction and the clock from the room's own start, and at rest shows the scan:
    /// the map's pass as the demo is bound, the scan once the pass is stopped, the quality pass once it is asked for. Red under: one line
    /// for whatever runs (the old "Reading the scan for the map…"), `progress: nil` in the Patterns case, the clock read from another
    /// room's start, or the scan's line without its help.
    @MainActor func testThePatternsRoomNamesThePassThatRunsThenShowsTheScan() throws {
        let state = AppState(launch: LaunchOptions(arguments: []))
        state.navigation.workspaceArea = .patterns
        state.ebsd.bind(try DemoDocuments.ebsd())
        guard case let .busy(mapping, mapFraction, metrics)? = ToolbarDisplay.state(state) else {
            return XCTFail("the map's pass is the toolbar's line")
        }
        XCTAssertEqual(mapping, "Reading the scan…")
        XCTAssertNotNil(mapFraction, "the pass's fraction")
        XCTAssertEqual(mapFraction, RoomProgress.fraction(room: .patterns, appState: state))
        XCTAssertEqual(elapsed(metrics, since: .patterns, in: state), 42, "the clock runs from the Patterns room's start")

        state.ebsd.stop()
        guard case let .idle(file, room, detail, help)? = ToolbarDisplay.state(state) else {
            return XCTFail("the scan at rest")
        }
        XCTAssertEqual(file, "Demo EBSD")
        XCTAssertEqual(room, "Patterns")
        XCTAssertEqual(detail, "40 × 30 of 60 × 60", "the scan's 40 columns before its 30 rows, X before Y")
        XCTAssertEqual(help, Self.scanHelp)

        state.ebsd.showMap(.imageQuality)
        guard case let .busy(quality, qualityFraction, _)? = ToolbarDisplay.state(state) else {
            return XCTFail("the quality pass is the toolbar's line")
        }
        XCTAssertEqual(quality, "Computing the quality maps…")
        XCTAssertNotNil(qualityFraction, "the pass's fraction")
        XCTAssertEqual(qualityFraction, RoomProgress.fraction(room: .patterns, appState: state))
        state.ebsd.stop()
    }

    /// The Indexing room at rest shows the scan; while it indexes, the run's count line with its fraction and the clock from the room's
    /// own start; while the scan it shows opens anew, the open's own line with the Patterns room's clock. Red under: the run named by
    /// `BusyOperation.name` ("Indexing with Hough…") in place of its count line, `progress: nil` for the run, the open's branch dropped
    /// (the room then reads at rest while its scan opens), or the open's clock read from the Indexing room's start.
    @MainActor func testTheIndexingRoomShowsItsRunAndTheOpenOfItsScan() async throws {
        let state = AppState(launch: LaunchOptions(arguments: []))
        await state.ebsd.bind(try DemoDocuments.ebsd()).value
        try await waitUntil("the demo scan's passes in the Patterns and Maps rooms to end", seconds: 30) {
            !state.ebsd.isBusy && !state.ebsd.isComputingMean && !state.maps.isBusy
        }
        state.navigation.workspaceArea = .indexing
        guard case let .idle(file, room, detail, help)? = ToolbarDisplay.state(state) else {
            return XCTFail("the scan at rest")
        }
        XCTAssertEqual(file, "Demo EBSD")
        XCTAssertEqual(room, "Indexing")
        XCTAssertEqual(detail, "40 × 30 of 60 × 60", "the scan's 40 columns before its 30 rows, X before Y")
        XCTAssertEqual(help, Self.scanHelp)

        XCTAssertTrue(state.indexing.canIndex, state.indexing.refusal ?? "")
        let dataset = try XCTUnwrap(state.indexing.patterns.dataset)
        let run = state.indexing.index()
        guard case let .busy(line, fraction, metrics)? = ToolbarDisplay.state(state) else {
            RoomPrimaryAction.stopActive(state)
            return XCTFail("the Index is the toolbar's line")
        }
        XCTAssertEqual(line, BusyOperation.indexingLine(state.indexing, dataset: dataset))
        XCTAssertTrue(line.hasPrefix("Hough · "), line)
        XCTAssertNotNil(fraction, "the run's fraction")
        XCTAssertEqual(fraction, RoomProgress.fraction(room: .indexing, appState: state))
        XCTAssertEqual(elapsed(metrics, since: .indexing, in: state), 42, "the clock runs from the Indexing room's start")
        RoomPrimaryAction.stopActive(state)
        await run.value

        let open = state.ebsd.open(url: Self.scan)
        guard case let .busy(opening, openFraction, openMetrics)? = ToolbarDisplay.state(state) else {
            state.ebsd.stop()
            return XCTFail("the open of the scan the room shows is its own line")
        }
        XCTAssertEqual(opening, "Opening the dataset…")
        XCTAssertNil(openFraction, "an open reports no fraction")
        XCTAssertEqual(elapsed(openMetrics, since: .patterns, in: state), 42, "the open's clock is the Patterns room's")
        state.ebsd.stop()
        await open.value
    }

    /// The Maps room while it opens a map and while Segment runs, then at rest: the open's line before the map is there, Segment's
    /// line once it is, neither with a fraction, and the clock from the room's own start; at rest, the map's file, its size and its
    /// phases. Red under: the Maps case busy only while it opens (Segment then shows the file), the map's guard ahead of the busy line
    /// (the open then shows nothing), or the clock read from another room's start.
    @MainActor func testTheMapsRoomShowsItsOpenAndSegmentThenItsMap() async {
        let state = AppState(launch: LaunchOptions(arguments: []))
        state.navigation.workspaceArea = .maps
        let open = state.maps.open(url: Self.sdss)
        guard case let .busy(opening, openFraction, metrics)? = ToolbarDisplay.state(state) else {
            return XCTFail("the open is the toolbar's line before the map is there")
        }
        XCTAssertEqual(opening, "Opening the orientation map…")
        XCTAssertNil(openFraction, "an open reports no fraction")
        XCTAssertEqual(elapsed(metrics, since: .maps, in: state), 42, "the clock runs from the Maps room's start")
        await open.value

        guard case let .idle(file, room, detail, help)? = ToolbarDisplay.state(state) else {
            return XCTFail("the map at rest")
        }
        XCTAssertEqual(file, "ebsd-sdss-ferrite-austenite.ang")
        XCTAssertEqual(room, "Maps")
        XCTAssertEqual(detail, "117 × 100 · 2 phases", "117 columns before 100 rows, X before Y")
        XCTAssertEqual(help, Self.mapHelp)

        let segmenting = state.maps.segment()
        guard case let .busy(segment, segmentFraction, _)? = ToolbarDisplay.state(state) else {
            RoomPrimaryAction.stopActive(state)
            return XCTFail("Segment is the toolbar's line")
        }
        XCTAssertEqual(segment, "Segmenting grains…")
        XCTAssertNil(segmentFraction, "Segment reports no fraction")
        RoomPrimaryAction.stopActive(state)
        await segmenting.value
    }

    /// An Index left running while the Maps room is shown: the toolbar shows that run under its room's name, with its fraction and the
    /// clock from its room's start; before it, the demo's own map. Red under: the toolbar built from the shown room alone (the map's line
    /// while the Index runs), or the shown room's fraction or clock in place of the running room's (`RoomProgress.fraction(room: room, …)`
    /// and `busySince[room]`, both nil for the Maps room).
    @MainActor func testARunInAnotherRoomShowsUnderItsRoomsName() async throws {
        let state = AppState(launch: LaunchOptions(arguments: []))
        await state.ebsd.bind(try DemoDocuments.ebsd()).value
        try await waitUntil("the demo scan's passes in the Patterns and Maps rooms to end", seconds: 30) {
            !state.ebsd.isBusy && !state.ebsd.isComputingMean && !state.maps.isBusy
        }
        state.navigation.workspaceArea = .maps
        let map = try XCTUnwrap(state.maps.map, "the demo carries its own crystal map")
        guard case let .idle(file, room, detail, help)? = ToolbarDisplay.state(state) else {
            return XCTFail("the demo's map at rest")
        }
        XCTAssertEqual(file, "Demo EBSD")
        XCTAssertEqual(room, "Maps")
        XCTAssertEqual(detail, MapsRoomFormat.capsuleDetail(map))
        XCTAssertEqual(help, Self.mapHelp)

        XCTAssertTrue(state.indexing.canIndex, state.indexing.refusal ?? "")
        let run = state.indexing.index()
        guard case let .busy(line, fraction, metrics)? = ToolbarDisplay.state(state) else {
            RoomPrimaryAction.stopActive(state)
            return XCTFail("the Index running behind the Maps room is the toolbar's line")
        }
        XCTAssertEqual(line, BusyOperation.backgroundOperation(room: .indexing, appState: state))
        XCTAssertTrue(line.hasPrefix("Indexing · Hough · "), line)
        XCTAssertNotNil(fraction, "the Index's fraction")
        XCTAssertEqual(fraction, RoomProgress.fraction(room: .indexing, appState: state))
        XCTAssertEqual(elapsed(metrics, since: .indexing, in: state), 42, "the clock runs from the Indexing room's start")
        RoomPrimaryAction.stopActive(state)
        await run.value
    }
}
