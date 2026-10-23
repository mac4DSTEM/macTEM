//
//  OpenURLRelayTests.swift
//  Pins `OpenURLRelay`, which rebuilds a Finder open's ordered batch from `.onOpenURL` (first file) and the
//  delegate (the rest). Mutations each test must go red under, in order:
//   - OneOrderedBatch: `add` flushes at once instead of restarting a timer (two batches), or prepends/sorts.
//   - EmptyArray: the guard on an empty array removed (an empty batch reaches the handler, or the timer restarts).
//   - TwoBursts: `pending` not cleared after a flush (the second batch repeats the first).
//   - BeforeHandler: the handler's `didSet` flush removed, or a flush with no handler drops the batch.
//

import XCTest
@testable import macTEM

nonisolated final class OpenURLRelayTests: XCTestCase {

    private func url(_ name: String) -> URL { URL(fileURLWithPath: "/tmp/\(name)") }

    @MainActor func testOnOpenURLAndDelegateArriveAsOneOrderedBatch() async {
        let relay = OpenURLRelay(delay: .milliseconds(30))
        var batches: [[URL]] = []
        relay.handler = { batches.append($0) }
        relay.add([url("a")])               // .onOpenURL: the first
        relay.add([url("b"), url("c")])     // the delegate: the rest
        await relay.pendingFlush?.value
        XCTAssertEqual(batches, [[url("a"), url("b"), url("c")]])
    }

    @MainActor func testAnEmptyDelegateArrayChangesNothing() async {
        let relay = OpenURLRelay(delay: .milliseconds(30))
        var batches: [[URL]] = []
        relay.handler = { batches.append($0) }
        relay.add([])
        XCTAssertNil(relay.pendingFlush, "an empty array starts no timer")
        relay.add([url("a")])
        relay.add([])                       // the single-file open's empty delegate call
        await relay.pendingFlush?.value
        XCTAssertEqual(batches, [[url("a")]])
    }

    @MainActor func testTwoSeparatedBurstsGiveTwoBatches() async {
        let relay = OpenURLRelay(delay: .milliseconds(30))
        var batches: [[URL]] = []
        relay.handler = { batches.append($0) }
        relay.add([url("a"), url("b")])
        await relay.pendingFlush?.value
        relay.add([url("c")])
        await relay.pendingFlush?.value
        XCTAssertEqual(batches, [[url("a"), url("b")], [url("c")]])
    }

    @MainActor func testABatchBeforeTheHandlerIsDeliveredWhenItIsSet() async {
        let relay = OpenURLRelay(delay: .milliseconds(30))
        relay.add([url("a"), url("b")])
        await relay.pendingFlush?.value     // the timer fired with nobody to hand the batch to
        var batches: [[URL]] = []
        relay.handler = { batches.append($0) }
        XCTAssertEqual(batches, [[url("a"), url("b")]], "setting the handler delivers the kept batch")
        relay.add([url("c")])
        await relay.pendingFlush?.value
        XCTAssertEqual(batches.count, 2, "and the kept batch is not delivered again")
    }
}
