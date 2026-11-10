//
//  EBSDPatternCacheTests.swift
//  The Patterns room's cache of raw patterns is bounded by their bytes and lets the least recently shown go first (#294). On a
//  planted 600 x 1 scan of 512 x 512 uint16 patterns (512 KB each) every position is hovered in turn, and the origin again after
//  every hundred: the cache never holds more than its 64 MB (128 of these patterns), the origin is read once, since a pattern shown
//  again is the last to be let go, and a position hovered long ago is read again.
//
//  Red before the change: the cache held 512 patterns whatever their size (256 MB of these) and let go the one read first, however
//  recently it was shown, so the origin was read a second time once the 513th position had been hovered.
//

import XCTest
import Synchronization
import FormatoCore
import TEMCore
import TEMSession

nonisolated final class EBSDPatternCacheTests: XCTestCase {

    private static let rows = 600
    private static let side = 512
    /// The bytes of one pattern: 512 x 512 uint16.
    private static let patternBytes = 524_288

    private static func scan() -> EBSDDataset {
        EBSDDataset(format: .generated, manufacturer: "test", version: "", scanGroup: "s", scanGroups: ["s"], scanRows: rows,
                    scanColumns: 1, patternRows: side, patternColumns: side, dataType: .uint16, stepY: 1, stepX: 1,
                    detector: EBSDDetectorGeometry(rows: side, columns: side, projectionCenters: []),
                    patterns: EBSDPatternSource(url: URL(fileURLWithPath: "/planted"), datasetPath: "",
                                                fileShape: [rows, 1, side, side], dataType: .uint16))
    }

    /// Hovers `position` and waits until its pattern is the one on screen.
    @MainActor private func hover(_ session: EBSDSession, _ position: EBSDPosition) async throws {
        session.hover(position)
        for _ in 0..<5000 where session.patternPosition != position { try await Task.sleep(for: .milliseconds(1)) }
        XCTAssertEqual(session.patternPosition, position)
    }

    @MainActor func testTheCacheKeepsToItsBytesAndLetsTheLeastRecentlyShownGo() async throws {
        let access = CountedPatterns(dataset: Self.scan())
        let session = EBSDSession()
        await session.bind(EBSDSession.Document(fileName: "planted.h5", url: nil, dataset: access.dataset, access: access)).value
        // The map's pass is not what is tested: it is stopped, and reads rows, which are not counted.
        session.stop()
        XCTAssertEqual(session.cacheBytes, Self.patternBytes, "the first pattern")

        var most = session.cacheBytes
        for row in 1..<Self.rows {
            try await hover(session, EBSDPosition(row: row, column: 0))
            most = max(most, session.cacheBytes)
            if row % 100 == 0 { try await hover(session, .origin) }
        }
        try await hover(session, .origin)
        XCTAssertLessThanOrEqual(most, EBSDSession.cacheBudget)
        XCTAssertEqual(session.cacheBytes, EBSDSession.cacheBudget, "128 patterns of 512 KB are the 64 MB")
        XCTAssertEqual(access.reads(at: 0), 1, "the origin, shown again after every hundred positions, was never let go")
        XCTAssertEqual(access.total, Self.rows, "every position was read once")

        try await hover(session, EBSDPosition(row: 1, column: 0))
        XCTAssertEqual(access.reads(at: 1), 2, "a position shown 599 positions ago was let go, and is read again")
        XCTAssertEqual(session.cacheBytes, EBSDSession.cacheBudget)

        session.close()
        XCTAssertEqual(session.cacheBytes, 0)
    }
}

/// A scan answered from nothing (every pixel 0), with every read of one pattern counted by its map index.
private nonisolated final class CountedPatterns: EBSDPatternAccess {
    let dataset: EBSDDataset
    private let counts: Mutex<[Int: Int]>

    init(dataset: EBSDDataset) {
        self.dataset = dataset
        counts = Mutex([:])
    }

    func pattern(row: Int, column: Int) throws -> FormatoArray {
        let index = row * dataset.scanColumns + column
        counts.withLock { $0[index, default: 0] += 1 }
        return try FormatoArray(dataType: dataset.dataType, shape: [dataset.patternRows, dataset.patternColumns],
                                bytes: Data(count: dataset.patternPixels * dataset.dataType.byteSize))
    }

    func row(_ row: Int) throws -> FormatoArray {
        try FormatoArray(dataType: dataset.dataType, shape: [dataset.scanColumns, dataset.patternRows, dataset.patternColumns],
                         bytes: Data(count: dataset.scanColumns * dataset.patternPixels * dataset.dataType.byteSize))
    }

    func reads(at index: Int) -> Int { counts.withLock { $0[index] ?? 0 } }
    var total: Int { counts.withLock { $0.values.reduce(0, +) } }
}
