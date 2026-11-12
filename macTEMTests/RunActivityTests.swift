//
//  RunActivityTests.swift
//  The activity a long run holds so App Nap and idle sleep never slow it (`RunActivity`, `AppState.holdActivityWhileRoomsWork`):
//  one activity per stretch of work, begun when a room starts working and ended when its run lands or is stopped, counted through
//  injected begin and end closures in place of `ProcessInfo`'s.
//  Red before: no run held any activity (macTEM never called `beginActivity`), and `AppState` took none to count.
//

import Foundation
import Synchronization
import XCTest
import FormatoCore
import TEMCore
import TEMSession
@testable import macTEM

nonisolated final class RunActivityTests: XCTestCase {

    /// Held once however often it is asked while working, and let go once.
    @MainActor func testOneStretchOfWorkHoldsOneActivity() {
        let counts = ActivityCounts()
        let activity = counts.activity()
        activity.hold(false)
        XCTAssertEqual(counts.begun, 0, "nothing to let go")
        activity.hold(true)
        activity.hold(true)
        XCTAssertTrue(activity.isHeld)
        XCTAssertEqual(counts.begun, 1)
        activity.hold(false)
        activity.hold(false)
        XCTAssertFalse(activity.isHeld)
        XCTAssertEqual(counts.ended, 1)
    }

    /// Process on the demo dataset in a window's state: the activity is begun when the run starts and ended when it lands; a second
    /// run, stopped while it reads its first row, ends it too. Each run is held inside its first row until the activity is seen held,
    /// so a fast run cannot land before the watch reads it.
    @MainActor func testAProcessRunHoldsTheActivityUntilItLandsOrStops() async throws {
        let counts = ActivityCounts()
        let state = AppState(launch: LaunchOptions(arguments: []), runActivity: counts.activity())
        let demo = try DemoDocuments.ebsd()
        let gated = GatedRows(base: demo.access)
        defer { gated.release() }
        await state.ebsd.bind(EBSDSession.Document(fileName: demo.fileName, url: nil, dataset: demo.dataset, access: gated)).value
        // The map's pass at open is a run too: it holds the activity and lets it go when it lands.
        try await waitUntil("setup: every room to be idle and the activity let go", seconds: 30) {
            state.busyRooms.isEmpty && !state.runActivity.isHeld
        }
        XCTAssertEqual(counts.ended, counts.begun)
        let before = counts.begun

        // A run that lands.
        gated.hold()
        let landed = state.ebsd.process()
        try await waitUntil("the run to begin an activity", seconds: 10) { counts.begun != before }
        XCTAssertEqual(counts.begun, before + 1, "Process holds one activity")
        XCTAssertTrue(state.runActivity.isHeld)
        gated.release()
        await landed.value
        XCTAssertNotNil(state.ebsd.processed, "the run landed")
        try await waitUntil("a landed run to let the activity go", seconds: 10) { !state.runActivity.isHeld }
        XCTAssertEqual(counts.ended, before + 1)

        // A run that is stopped.
        gated.hold()
        let stopped = state.ebsd.process()
        try await waitUntil("the second run to begin an activity", seconds: 10) { counts.begun != before + 1 }
        XCTAssertEqual(counts.begun, before + 2, "the second run holds its own activity")
        state.ebsd.stop()
        try await waitUntil("a stopped run to let the activity go", seconds: 10) { !state.runActivity.isHeld }
        XCTAssertEqual(counts.ended, before + 2)
        gated.release()
        await stopped.value
    }
}

/// Counts the activities a `RunActivity` begins and ends, in place of `ProcessInfo`'s.
private final class ActivityCounts {
    private(set) var begun = 0
    private(set) var ended = 0

    func activity() -> RunActivity {
        RunActivity(begin: {
            self.begun += 1
            return NSObject()
        }, end: { _ in
            self.ended += 1
        })
    }
}

/// The demo's patterns; the first row read after `hold()` waits until `release()`, so a run stays inside that row. Its state is
/// behind the mutex and the semaphore, hence unchecked.
private nonisolated final class GatedRows: EBSDPatternAccess, @unchecked Sendable {
    private let base: any EBSDPatternAccess
    private let armed: Mutex<Bool>
    private let gate: DispatchSemaphore

    init(base: any EBSDPatternAccess) {
        self.base = base
        armed = Mutex(false)
        gate = DispatchSemaphore(value: 0)
    }

    var dataset: EBSDDataset { base.dataset }

    func pattern(row: Int, column: Int) throws -> FormatoArray { try base.pattern(row: row, column: column) }

    func row(_ row: Int) throws -> FormatoArray {
        let waits = armed.withLock { on -> Bool in
            let was = on
            on = false
            return was
        }
        if waits { gate.wait() }
        return try base.row(row)
    }

    /// Arms the gate for the next row read.
    func hold() {
        armed.withLock { $0 = true }
    }

    /// Lets a held read go on (a spare release is harmless here: nothing reads a row once the test is over).
    func release() {
        _ = gate.signal()
    }
}
