//
//  RunClockTests.swift
//  The toolbar's busy line carries a clock for the spectrum rooms' long work: elapsed since the room became busy and, once the work
//  reports a fraction done, an ETA extrapolated from it (`RunClock`); the start is kept per room by `AppState.markBusy`.
//

import XCTest
@testable import macTEM

nonisolated final class RunClockTests: XCTestCase {

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    private func squeezed(_ text: String) -> String { text.split(whereSeparator: \.isWhitespace).joined(separator: " ") }

    /// Elapsed is the time since the start; no start, no reading. Red under: the reading nil (the busy line without a clock).
    func testElapsedIsTheTimeSinceTheStart() throws {
        let start = Date(timeIntervalSinceReferenceDate: 1000)
        XCTAssertNil(RunClock.reading(since: nil, progress: nil, now: start))
        let r = try XCTUnwrap(RunClock.reading(since: start, progress: nil, now: start.addingTimeInterval(42)))
        XCTAssertEqual(r.elapsed, 42)
        XCTAssertNil(r.eta, "no fraction done: no ETA")
        XCTAssertEqual(try XCTUnwrap(RunClock.reading(since: start, progress: nil, now: start.addingTimeInterval(-1))).elapsed, 0, "never negative")
    }

    /// The ETA is the elapsed time scaled by what is left: a quarter done in 30 s leaves 90 s. It is absent, never invented, before the work
    /// has done enough to estimate from (under 2 % or under 2 s) and at the end. Red under: an ETA from 1 % done.
    func testTheETAIsExtrapolatedFromTheFractionDone() throws {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        XCTAssertEqual(try XCTUnwrap(RunClock.reading(since: start, progress: 0.25, now: start.addingTimeInterval(30))?.eta), 90, accuracy: 1e-9)
        XCTAssertNil(RunClock.reading(since: start, progress: 0.01, now: start.addingTimeInterval(30))?.eta)
        XCTAssertNil(RunClock.reading(since: start, progress: 0.5, now: start.addingTimeInterval(1))?.eta)
        XCTAssertNil(RunClock.reading(since: start, progress: 1, now: start.addingTimeInterval(30))?.eta)
    }

    /// A room's start is set when it becomes busy, kept while it stays busy, and cleared when it is idle. Red under: the start reset on every call.
    @MainActor func testTheStartIsKeptWhileTheRoomIsBusy() {
        let state = AppState()
        let t0 = Date(timeIntervalSinceReferenceDate: 100)
        state.markBusy(.eels, true, now: t0)
        state.markBusy(.eels, true, now: t0.addingTimeInterval(5))
        XCTAssertEqual(state.busySince[.eels], t0)
        XCTAssertNil(state.busySince[.edx])
        state.markBusy(.eels, false, now: t0.addingTimeInterval(9))
        XCTAssertNil(state.busySince[.eels])
    }

    /// The toolbar passes the clock, and the window marks each spectrum room's busy edges. Red under: `metrics: { _ in nil }`.
    func testTheToolbarPassesTheClock() throws {
        let view = squeezed(try source("macTEM/UI/ContentView.swift"))
        XCTAssertFalse(view.contains("metrics: { _ in nil }"))
        XCTAssertTrue(view.contains("metrics: { now in RunClock.reading(since: appState.busySince[room], progress: RoomProgress.fraction(room: room, appState: appState), now: now) }"))
        XCTAssertTrue(view.contains(".onChange(of: appState.edx.isBusy, initial: true) { appState.markBusy(.edx, appState.edx.isBusy) }"))
        XCTAssertTrue(view.contains(".onChange(of: appState.eels.isBusy, initial: true) { appState.markBusy(.eels, appState.eels.isBusy) }"))
    }
}
