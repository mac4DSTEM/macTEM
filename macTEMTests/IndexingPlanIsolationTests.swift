//
//  IndexingPlanIsolationTests.swift
//  A Hough run reads and indexes each scan row off the caller's actor (`IndexingPlan.indexRow`, TEMCore). TEMCore's async functions
//  run on their caller's actor unless they are marked `@concurrent`, and `indexRow` reads a whole scan row (a blocking file read)
//  and puts its patterns through the processing stages before its first suspension. A planted scan notes the thread of each row
//  read and then stops the row there, so no pattern reaches the indexer; the row is indexed from the main actor.
//  Red under: `@concurrent` dropped from `indexRow` (the row is then read on the main thread).
//

import Foundation
import FormatoCore
import Synchronization
import TEMCore
import XCTest

nonisolated final class IndexingPlanIsolationTests: XCTestCase {

    /// A 1 × 2 uint8 scan of 60 × 60 px patterns with one projection centre, indexed against nickel with the room's defaults; the
    /// probe and the plan read no pattern, so the only read is the one `indexRow` makes.
    @MainActor func testIndexRowReadsItsRowOffTheCallersActor() async throws {
        let side = 60
        let dataset = EBSDDataset(format: .generated, manufacturer: "test", version: "", scanGroup: "s", scanGroups: ["s"], scanRows: 1,
                                  scanColumns: 2, patternRows: side, patternColumns: side, dataType: .uint8, stepY: 1, stepX: 1,
                                  detector: EBSDDetectorGeometry(rows: side, columns: side, projectionCenters: [SIMD3(0.5, 0.5, 0.5)]),
                                  patterns: EBSDPatternSource(url: URL(fileURLWithPath: "/planted"), datasetPath: "",
                                                              fileShape: [1, 2, side, side], dataType: .uint8))
        let patterns = ThreadNotingPatterns(dataset: dataset)
        let source = IndexingSource(stored: patterns, pipeline: .roomDefault, background: nil)
        let probe = try IndexingProbe(source: source, settings: .roomDefault)
        let nickel = IndexingPhase(name: "Ni", spaceGroup: 225, lattice: [3.52, 3.52, 3.52, 90, 90, 90], source: .preset)
        let plan = try IndexingPlan(probe: probe, phases: [nickel], settings: .roomDefault, detector: dataset.detector)
        XCTAssertEqual(patterns.readsOnMainThread, [], "building the plan reads no pattern")

        do {
            _ = try await plan.indexRow(0)
            XCTFail("the planted row read stops the row")
        } catch is RowReadStopped {}
        XCTAssertEqual(patterns.readsOnMainThread, [false], "the row is read once, off the main thread")
    }
}

/// The planted row read's error: the row stops at its read.
private nonisolated struct RowReadStopped: Error {}

/// A planted scan whose row read notes whether it runs on the main thread and then throws `RowReadStopped`; a single pattern read
/// throws it too. Its notes are behind a mutex, as `CountedPatterns`' counts are (EBSDPatternCacheTests).
private nonisolated final class ThreadNotingPatterns: EBSDPatternAccess {
    let dataset: EBSDDataset
    private let notes = Mutex<[Bool]>([])

    init(dataset: EBSDDataset) {
        self.dataset = dataset
    }

    func pattern(row: Int, column: Int) throws -> FormatoArray {
        throw RowReadStopped()
    }

    func row(_ row: Int) throws -> FormatoArray {
        let onMainThread = Thread.isMainThread
        notes.withLock { $0.append(onMainThread) }
        throw RowReadStopped()
    }

    /// One note per row read: true where the read ran on the main thread.
    var readsOnMainThread: [Bool] { notes.withLock { $0 } }
}
