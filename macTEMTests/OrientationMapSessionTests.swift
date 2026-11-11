//
//  OrientationMapSessionTests.swift
//  The Maps room's owner keeps the map's grid, steps and counts from when the map's document is made (`OrientationMapSession.Document`):
//  the hover, the status line's words, the toolbar and Segment's switch read those stored numbers instead of reducing the map's
//  coordinates again on every mouse move. The stored numbers are the map's own reductions. Red before: on a 1000 × 1000 map each hover
//  and each readout rebuilt four sets of a million coordinates, so 200 moves took tens of seconds on the main actor.
//

import Foundation
import TEMCore
import TEMSession
import XCTest

nonisolated final class OrientationMapSessionTests: XCTestCase {

    /// A 1000 × 1000 map of identity points on a unit grid: every seventh point not indexed, the others phase 1 or phase 0.
    private static func largeMap() throws -> CrystalMap {
        let side = 1000, n = side * side
        let grid = CrystalMap.coordinates(shape: (rows: side, columns: side))
        let ids = (0..<n).map { $0 % 7 == 0 ? PhaseList.notIndexedID : ($0 % 3 == 0 ? 1 : 0) }
        return try CrystalMap(rotations: Array(repeating: SIMD4<Double>(1, 0, 0, 0), count: n),
                              euler: Array(repeating: SIMD3<Double>(0, 0, 0), count: n), phaseIDs: ids, x: grid.x, y: grid.y)
    }

    @MainActor func testHoveringALargeMapReadsTheNumbersStoredWithItsDocument() async throws {
        let map = try Self.largeMap()
        let document = OrientationMapSession.Document(fileName: "large.ang", url: nil, map: map, source: .mapFile, format: ".ang")
        let shape = OrientationMaps.gridShape(map)
        XCTAssertEqual([document.rows, document.columns], [shape.rows, shape.columns])
        XCTAssertEqual([document.rows, document.columns], [1000, 1000])
        XCTAssertEqual([document.dy, document.dx], [map.dy, map.dx])
        XCTAssertEqual(document.size, map.size)
        let ids = map.phaseIDs
        XCTAssertEqual(document.notIndexedCount, ids.filter { $0 == PhaseList.notIndexedID }.count)
        XCTAssertEqual(Set(document.phaseCounts.keys), [PhaseList.notIndexedID, 0, 1])
        for id in [PhaseList.notIndexedID, 0, 1] {
            XCTAssertEqual(document.phaseCounts[id], ids.filter { $0 == id }.count, "phase \(id)")
        }

        let session = OrientationMapSession()
        await session.bind(document).value
        XCTAssertEqual(session.gridShape.rows, 1000)
        XCTAssertEqual(session.gridShape.columns, 1000)
        XCTAssertEqual(session.notIndexedCount, document.notIndexedCount)
        XCTAssertTrue(session.canSegment)
        XCTAssertNil(session.segmentBlocker)

        // 200 moves of the pointer, each the status line's words (the pointer picks nothing, D-SEM-110): under 2 s with the stored grid
        // (well under 0.1 s on the dev Mac; generous for a shared runner).
        let start = Date()
        var words = 0
        for k in 0..<200 {
            let point = EBSDPosition(row: (k * 37) % 1000, column: (k * 91) % 1000)
            if session.readout(at: point) != nil { words += 1 }
        }
        let seconds = Date().timeIntervalSince(start)
        XCTAssertEqual(words, 200)
        XCTAssertLessThan(seconds, 2, "200 readouts took \(seconds) s")
        // The status line's words are the ones `OrientationMaps.readout` makes from the map's own shape.
        let en = Locale(identifier: "en_US")
        XCTAssertEqual(OrientationMaps.readout(map, grid: session.grid, row: 3, column: 5, shape: session.gridShape, locale: en),
                       OrientationMaps.readout(map, grid: session.grid, row: 3, column: 5, locale: en))
    }
}
