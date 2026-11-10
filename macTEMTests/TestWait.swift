//
//  TestWait.swift
//  The one wait of the tests that poll an owner's state (#270). A loop written in place,
//  `for _ in 0..<N where busy { try await Task.sleep(for: .milliseconds(5)) }`, falls through when its time runs out: the test
//  then fails at some later assertion, or passes on a state that is not the one it waited for. `waitUntil` asks its condition
//  the same way, every 5 ms; a wait that runs out fails the test at the line that waited, with what it waited for, and throws,
//  so the test ends there.
//  No test is declared here (the unit gate reads test names by file and type): TestWaitTests.swift holds the helper's own.
//

import XCTest

/// A `waitUntil` whose condition never came to hold; it says what was waited for, as the failure recorded with it does.
nonisolated struct WaitTimedOut: Error, LocalizedError {
    let what: String
    var errorDescription: String? { "timed out waiting for: \(what)" }
}

/// Whether `condition` came to hold: asked before each 5 ms sleep, `seconds` × 200 sleeps at most, and once more after the
/// last. The bound counts sleeps, as the loops written in place did, so a loaded machine waits longer than `seconds`,
/// never shorter.
@MainActor func conditionHolds(within seconds: Double, _ condition: () -> Bool) async throws -> Bool {
    let sleeps = max(0, Int((seconds * 200).rounded(.up)))
    for _ in 0..<sleeps {
        if condition() { return true }
        try await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}

/// Waits until `condition` holds, for `seconds` at least (`conditionHolds`). When it never does, the test fails at the caller's
/// line with `what` ("timed out after 30 s waiting for: the scan's passes to end") and `WaitTimedOut` is thrown.
@MainActor func waitUntil(_ what: String, seconds: Double = 10, file: StaticString = #filePath, line: UInt = #line,
                          _ condition: () -> Bool) async throws {
    if try await conditionHolds(within: seconds, condition) { return }
    XCTFail("timed out after \(String(format: "%g", seconds)) s waiting for: \(what)", file: file, line: line)
    throw WaitTimedOut(what: what)
}
