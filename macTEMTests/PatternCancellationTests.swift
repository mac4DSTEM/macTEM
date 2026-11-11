//
//  PatternCancellationTests.swift
//  Stop reaches NLPAR and neighbour averaging (`NLPAR`, `NeighbourAveraging`, `PatternPipeline.process`, TEMCore; `EBSDSession`):
//  both ask the cancellation check between their rows and tiles, NLPAR's worker threads included, the session's Stop raises the flag
//  the check reads, and a Process started after Stop waits for the stopped run to end before it reads the scan. Nothing moves when
//  nothing is cancelled.
//  Red before the change: NLPAR takes no check, so Process returns patterns after the check said stop once NLPAR or averaging had
//  begun, and a Process started after Stop read the scan beside the stopped run still inside its row.
//

import XCTest
import Synchronization
import FormatoCore
import TEMCore
import TEMSession

nonisolated final class PatternCancellationTests: XCTestCase {

    /// The generated demo as NLPAR's float32 scan (two column tiles).
    private func demoScan() throws -> NLPAR.Scan {
        let demo = try DemoDocuments.ebsd()
        let d = demo.dataset
        var values: [Float] = []
        for row in 0..<d.scanRows { values += try demo.access.row(row).doubles().map { Float($0) } }
        return try NLPAR.Scan(rows: d.scanRows, columns: d.scanColumns, patternRows: d.patternRows, patternColumns: d.patternColumns,
                              values: values)
    }

    /// NLPAR asks between its tiles and rows: a check that turns half way stops it with `CancellationError` before the rows it had
    /// left, one that says yes at once stops it at the start, and asking changes no value.
    func testNLPARStopsBetweenItsRowsAndTiles() throws {
        let scan = try demoScan()
        let all = CountingCheck(after: .max)
        let whole = try NLPAR.run(scan, isCancelled: { all.check() })
        XCTAssertEqual(whole.denoised.values, try NLPAR.run(scan).denoised.values, "asking changes no value")
        XCTAssertGreaterThan(all.count, scan.rows * scan.columns, "asked on every row of every column")

        let halfWay = CountingCheck(after: all.count / 2)
        XCTAssertThrowsError(try NLPAR.run(scan, isCancelled: { halfWay.check() })) { XCTAssertTrue($0 is CancellationError, "\($0)") }
        XCTAssertLessThan(halfWay.count, all.count, "stopped before the rows it had left")
        XCTAssertThrowsError(try NLPAR.run(scan, isCancelled: { true })) { XCTAssertTrue($0 is CancellationError, "\($0)") }
    }

    /// Process asks once per row and once before the whole-scan stage; the next question is NLPAR's or averaging's own, so a check that
    /// says yes from then on ends Process with nil instead of letting the stage run to its end.
    func testProcessReturnsNilWhenStopReachesNLPAROrAveraging() throws {
        let demo = try DemoDocuments.ebsd()
        let rows = demo.dataset.scanRows
        let background = try XCTUnwrap(PatternPipeline.meanBackground(demo.access))
        var nlpar = PatternPipeline.roomDefault
        nlpar.nlpar.isOn = true
        let inNLPAR = CountingCheck(after: rows + 1)
        XCTAssertNil(try nlpar.process(demo.access, background: background, isCancelled: { inNLPAR.check() }))
        XCTAssertEqual(inNLPAR.count, rows + 2, "stopped at NLPAR's first question")

        var averaging = PatternPipeline.roomDefault
        averaging.averaging.isOn = true
        let inAveraging = CountingCheck(after: rows + 1)
        XCTAssertNil(try averaging.process(demo.access, background: background, isCancelled: { inAveraging.check() }))
        XCTAssertEqual(inAveraging.count, rows + 2, "stopped at averaging's first row")
        let never = CountingCheck(after: .max)
        XCTAssertNotNil(try averaging.process(demo.access, background: background, isCancelled: { never.check() }))
    }

    /// Stop reaches the run through the flag (the stopped run reads no row after it), and Process after Stop waits: while the stopped
    /// run is held inside its row, the new run reads nothing; released, the stopped run ends at its next row and only the new run lands.
    @MainActor func testStopEndsTheRunAndProcessAfterStopWaitsForIt() async throws {
        let demo = try DemoDocuments.ebsd()
        let gated = GatedPatterns(base: try XCTUnwrap(demo.access as? EBSDMemoryPatterns))
        defer { gated.release() }
        let session = EBSDSession()
        await session.bind(EBSDSession.Document(fileName: demo.fileName, url: nil, dataset: demo.dataset, access: gated)).value
        try await waitUntil("the demo scan's map and mean passes to end", seconds: 30) { !session.isMapping && !session.isComputingMean }
        XCTAssertTrue(session.canProcess)
        var events: [String] = []
        session.onEvent = { events.append($0) }

        // Stop while the run is inside its first row: released, it reads no further row.
        var reads = gated.hold()
        let stopped = session.process()
        for _ in 0..<2000 where gated.rowReads == reads { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(gated.rowReads, reads + 1, "the run is inside its first row")
        session.stop()
        XCTAssertFalse(session.isProcessing)
        gated.release()
        await stopped.value
        XCTAssertEqual(gated.rowReads, reads + 1, "the stopped run read no row after Stop")
        XCTAssertNil(session.processed)

        // Stop then Process while the stopped run is held: the new run waits for it, then runs and lands alone.
        reads = gated.hold()
        let first = session.process()
        try await waitUntil("the first run to enter its first row", seconds: 10) { gated.rowReads != reads }
        session.stop()
        let second = session.process()
        XCTAssertTrue(session.isProcessing)
        for _ in 0..<60 where gated.rowReads == reads + 1 { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(gated.rowReads, reads + 1, "the new run reads nothing while the stopped run is inside its row")
        gated.release()
        await first.value
        await second.value
        XCTAssertFalse(session.isProcessing)
        XCTAssertNotNil(session.processed)
        XCTAssertEqual(session.processedWith, session.pipeline)
        XCTAssertEqual(gated.rowReads, reads + 1 + demo.dataset.scanRows, "the new run read the scan once, after the stopped run")
        XCTAssertEqual(events.filter { $0.hasPrefix("Processed ") }.count, 1, "\(events)")
    }
}

/// A cancellation check that counts the times it is asked and says yes from the `after + 1`th time on.
private nonisolated final class CountingCheck: Sendable {
    private let asked: Mutex<Int>
    private let after: Int

    init(after: Int) {
        asked = Mutex(0)
        self.after = after
    }

    func check() -> Bool {
        let limit = after
        return asked.withLock { n -> Bool in
            n += 1
            return n > limit
        }
    }

    var count: Int { asked.withLock { $0 } }
}

/// The demo's patterns, where the first row read after `hold()` waits until `release()`: a Process run stays inside that row. Its state is
/// behind the mutex and the semaphore, hence unchecked.
private nonisolated final class GatedPatterns: EBSDPatternAccess, @unchecked Sendable {
    private let base: EBSDMemoryPatterns
    private let state: Mutex<(armed: Bool, reads: Int)>
    private let gate: DispatchSemaphore

    init(base: EBSDMemoryPatterns) {
        self.base = base
        state = Mutex((armed: false, reads: 0))
        gate = DispatchSemaphore(value: 0)
    }

    var dataset: EBSDDataset { base.dataset }

    func pattern(row: Int, column: Int) throws -> FormatoArray { try base.pattern(row: row, column: column) }

    func row(_ row: Int) throws -> FormatoArray {
        let waits = state.withLock { s -> Bool in
            s.reads += 1
            let armed = s.armed
            s.armed = false
            return armed
        }
        if waits { gate.wait() }
        return try base.row(row)
    }

    /// Arms the gate for the next row read; returns the row reads so far.
    func hold() -> Int {
        state.withLock { s -> Int in
            s.armed = true
            return s.reads
        }
    }

    /// Lets a held read go on (a spare release is harmless: nothing waits once the gate is disarmed).
    func release() {
        _ = gate.signal()
    }

    var rowReads: Int { state.withLock { $0.reads } }
}
