//
//  TestWaitTests.swift
//  The tests' shared wait (TestWait.swift, #270): a condition that holds ends the wait at the ask that found it, and a wait
//  that runs out has asked through its whole bound before it says no. The failure a run-out wait records cannot be asserted
//  here without failing this test, so `waitUntil` is only run where its condition comes to hold.
//  Red under: the last ask dropped, a wait that goes on asking after its condition held, a bound counted in asks of no fixed
//  length. Not told apart here: a condition asked after each sleep instead of before it, which asks as often and only differs
//  in time (a wait that holds at once would sleep 5 ms first).
//

import XCTest

nonisolated final class TestWaitTests: XCTestCase {

    /// A condition that holds at once is asked once.
    @MainActor func testAConditionThatHoldsAtOnceIsAskedOnce() async throws {
        var asks = 0
        let held = try await conditionHolds(within: 30) {
            asks += 1
            return true
        }
        XCTAssertTrue(held)
        XCTAssertEqual(asks, 1)
        asks = 0
        try await waitUntil("nothing: it holds already", seconds: 30) {
            asks += 1
            return true
        }
        XCTAssertEqual(asks, 1)
    }

    /// A condition that comes to hold on the third ask ends the wait there, long before its bound.
    @MainActor func testAWaitEndsAtTheAskThatFindsItsCondition() async throws {
        var asks = 0
        let held = try await conditionHolds(within: 30) {
            asks += 1
            return asks == 3
        }
        XCTAssertTrue(held)
        XCTAssertEqual(asks, 3)
        asks = 0
        try await waitUntil("the third ask", seconds: 30) {
            asks += 1
            return asks == 3
        }
        XCTAssertEqual(asks, 3)
    }

    /// A condition that never holds is asked before each 5 ms sleep of the bound and once at its end: 0.125 s is 25 sleeps and
    /// 26 asks, and takes 125 ms at least.
    @MainActor func testAWaitThatRunsOutHasAskedThroughItsWholeBound() async throws {
        var asks = 0
        let start = ContinuousClock.now
        let held = try await conditionHolds(within: 0.125) {
            asks += 1
            return false
        }
        let waited = ContinuousClock.now - start
        XCTAssertFalse(held)
        XCTAssertEqual(asks, 26)
        XCTAssertGreaterThanOrEqual(waited, .milliseconds(125), "a wait is never shorter than its bound")
    }

    /// A bound of nothing still asks once.
    @MainActor func testABoundOfZeroAsksOnce() async throws {
        var asks = 0
        let held = try await conditionHolds(within: 0) {
            asks += 1
            return asks == 1
        }
        XCTAssertTrue(held)
        XCTAssertEqual(asks, 1)
    }
}
