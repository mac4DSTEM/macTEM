//
//  OrientationMapsGridTests.swift
//  A map whose points stop short of its grid (an `.ang` or `.ctf` of a scan stopped mid-row): `OrientationMaps.pointIndexGrid`
//  reads the cells past the last point as holding no point, and the map's picture leaves them clear. A full map indexes every cell
//  as before. Red before: `pointIndexGrid` converted the NaN `mapData` leaves in those cells with `Int(_:)` and trapped (and the
//  picture's bytes trapped on the NaN colour), so opening such a map crashed the Maps room.
//

import Foundation
import TEMCore
import XCTest

nonisolated final class OrientationMapsGridTests: XCTestCase {

    private static func identities(_ n: Int) -> [SIMD4<Double>] { Array(repeating: SIMD4<Double>(1, 0, 0, 0), count: n) }

    /// Five points of a 2 × 3 scan stopped one point short: cells 0 to 4 hold points 0 to 4, the last cell none; the IPF picture is
    /// clear there and the hover has no words for it.
    func testCellsPastTheLastPointHoldNoPoint() throws {
        let map = try CrystalMap(rotations: Self.identities(5), x: [0, 1, 2, 0, 1], y: [0, 0, 0, 1, 1])
        XCTAssertEqual(OrientationMaps.gridShape(map).rows, 2)
        XCTAssertEqual(OrientationMaps.gridShape(map).columns, 3)
        let grid = OrientationMaps.pointIndexGrid(map)
        XCTAssertEqual(grid, [0, 1, 2, 3, 4, -1])
        let raster = OrientationMaps.raster(.ipf(.z), of: map)
        XCTAssertEqual(raster.inData, [true, true, true, true, true, false])
        let bytes = try XCTUnwrap(raster.rgba8)
        XCTAssertEqual(bytes.count, 6 * 4)
        XCTAssertEqual(bytes[4 * 4 + 3], 255, "the last point is opaque")
        XCTAssertEqual(bytes[4 * 5 + 3], 0, "the cell without a point is clear")
        XCTAssertNil(OrientationMaps.readout(map, grid: grid, row: 1, column: 2))
        XCTAssertNotNil(OrientationMaps.readout(map, grid: grid, row: 1, column: 1))
    }

    /// The whole 2 × 3 scan: every cell holds its point, in order.
    func testAFullMapIndexesEveryCell() throws {
        let map = try CrystalMap(rotations: Self.identities(6), x: [0, 1, 2, 0, 1, 2], y: [0, 0, 0, 1, 1, 1])
        XCTAssertEqual(OrientationMaps.pointIndexGrid(map), Array(0..<6))
        XCTAssertEqual(OrientationMaps.raster(.ipf(.z), of: map).inData, Array(repeating: true, count: 6))
    }
}
