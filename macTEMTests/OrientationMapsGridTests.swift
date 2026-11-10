//
//  OrientationMapsGridTests.swift
//  A map whose points stop short of its grid (an `.ang` or `.ctf` of a scan stopped mid-row): `OrientationMaps.pointIndexGrid`
//  reads the cells past the last point as holding no point, and the map's picture leaves them clear. A full map indexes every cell
//  as before. Red before: `pointIndexGrid` converted the NaN `mapData` leaves in those cells with `Int(_:)` and trapped (and the
//  picture's bytes trapped on the NaN colour), so opening such a map crashed the Maps room. A one-row map whose coordinates leave
//  a gap keeps its grid's length the same way; every grid that fills its axes maps as before, bit for bit.
//

import Foundation
import TEMCore
import XCTest

nonisolated final class OrientationMapsGridTests: XCTestCase {

    private static func identities(_ n: Int) -> [SIMD4<Double>] { Array(repeating: SIMD4<Double>(1, 0, 0, 0), count: n) }

    private static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")

    /// `mapData` as it was before a one-axis map kept its grid's length (#428), the oracle the grids below are held to: one axis
    /// sliced from the per-point array, two axes cell by cell with NaN past the last point.
    private static func mapDataBefore(_ map: CrystalMap, _ values: [Double], fill: Double = .nan) -> [Double] {
        var full = Array(repeating: fill, count: map.isInData.count)
        for (k, i) in map.ids.enumerated() { full[i] = values[k] }
        let original = map.originalShape
        let extents = map.slices(onlyInData: true)
        let base = map.slices(onlyInData: false)
        guard original.count == 2, extents.count == 2, base.count == 2 else {
            guard let e = extents.first, let b = base.first else { return full }
            return Array(full[max(e.start - b.start, 0)..<min(e.stop - b.start, full.count)])
        }
        var out: [Double] = []
        for r in (extents[0].start - base[0].start)..<(extents[0].stop - base[0].start) {
            for c in (extents[1].start - base[1].start)..<(extents[1].stop - base[1].start) {
                let i = r * original[1] + c
                out.append(i < full.count ? full[i] : .nan)
            }
        }
        return out
    }

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

    /// Three points at x = 0, 1, 5 of one row span six cells: the map data, the point index of every cell and the picture are six
    /// long, the cells past the last point empty, as a two-axis scan stopped mid-row has them. The same when only y varies. Red
    /// before: `mapData` returned the three points only, the picture held 12 bytes for 1 x 6 cells and no cell had a hover.
    func testAOneRowMapWithAGapKeepsItsGridLength() throws {
        let map = try CrystalMap(rotations: Self.identities(3), x: [0, 1, 5], y: [0, 0, 0])
        XCTAssertEqual(map.shape, [6])
        XCTAssertEqual(OrientationMaps.gridShape(map).rows, 1)
        XCTAssertEqual(OrientationMaps.gridShape(map).columns, 6)
        let data = map.mapData([1, 2, 3])
        XCTAssertEqual(data.count, 6)
        XCTAssertEqual(Array(data.prefix(3)), [1, 2, 3])
        XCTAssertTrue(data.suffix(3).allSatisfy(\.isNaN), "\(data)")
        XCTAssertEqual(Self.mapDataBefore(map, [1, 2, 3]).count, 3, "the one case that changes")
        let grid = OrientationMaps.pointIndexGrid(map)
        XCTAssertEqual(grid, [0, 1, 2, -1, -1, -1])
        let raster = OrientationMaps.raster(.ipf(.z), of: map)
        XCTAssertEqual(try XCTUnwrap(raster.rgba8).count, 6 * 4)
        XCTAssertEqual(raster.inData, [true, true, true, false, false, false])
        XCTAssertNotNil(OrientationMaps.readout(map, grid: grid, row: 0, column: 2))
        XCTAssertNil(OrientationMaps.readout(map, grid: grid, row: 0, column: 4))
        let column = try CrystalMap(rotations: Self.identities(3), x: [0, 0, 0], y: [0, 1, 5])
        XCTAssertEqual(column.shape, [6])
        XCTAssertEqual(column.mapData([1, 2, 3]).count, 6)
        XCTAssertEqual(OrientationMaps.pointIndexGrid(column), [0, 1, 2, -1, -1, -1])
    }

    /// Every grid that fills its axes, made here or read from the committed fixtures (square, rectangular, stopped mid-row, one row,
    /// one column, no coordinates, sliced), keeps its rows, columns and step, and its map data is the array it was before, bit for
    /// bit: only a one-axis map with a gap changes. Red under: the one-axis branch padding a map that fills its axis.
    func testEveryGridThatFillsItsAxesMapsAsBefore() throws {
        var maps: [(String, CrystalMap)] = try [
            ("square", CrystalMap(rotations: Self.identities(9), x: [0, 1, 2, 0, 1, 2, 0, 1, 2], y: [0, 0, 0, 1, 1, 1, 2, 2, 2])),
            ("rectangle", CrystalMap(rotations: Self.identities(6), x: [0, 1, 2, 0, 1, 2], y: [0, 0, 0, 1, 1, 1])),
            ("stopped mid-row", CrystalMap(rotations: Self.identities(5), x: [0, 1, 2, 0, 1], y: [0, 0, 0, 1, 1])),
            ("one row", CrystalMap(rotations: Self.identities(4), x: [0, 1.5, 3, 4.5], y: [0, 0, 0, 0])),
            ("one column", CrystalMap(rotations: Self.identities(4), x: [0, 0, 0, 0], y: [0, 2, 4, 6])),
            ("no coordinates", CrystalMap(rotations: Self.identities(4))),
        ]
        maps.append(("one row, sliced", maps[3].1.sliced(rows: 1..<3)))
        maps.append(("square, sliced", maps[0].1.sliced(rows: 1..<3, columns: 0..<2)))
        let expected: [String: (rows: Int, columns: Int)] = [
            "square": (3, 3), "rectangle": (2, 3), "stopped mid-row": (2, 3), "one row": (1, 4), "one column": (1, 4),
            "no coordinates": (1, 4), "one row, sliced": (1, 2), "square, sliced": (2, 2),
        ]
        for (name, map) in maps {
            let shape = OrientationMaps.gridShape(map)
            XCTAssertEqual(shape.rows, expected[name]?.rows, name)
            XCTAssertEqual(shape.columns, expected[name]?.columns, name)
        }
        XCTAssertEqual(maps[3].1.dx, 1.5)
        XCTAssertEqual(maps[4].1.dy, 2)

        // The committed fixtures' grids, as their readers' parity truths give them.
        let angs: [(String, [Int], Double)] = [("ebsd-tsl.ang", [3, 4], 2), ("ebsd-tsl-hex.ang", [3, 4], 2),
                                               ("ebsd-sdss-ferrite-austenite.ang", [100, 117], 1.5)]
        for (name, shape, step) in angs {
            let map = try ANGReader.read(url: Self.fixtures.appendingPathComponent(name)).map
            XCTAssertEqual(map.shape, shape, name)
            XCTAssertEqual(map.dx, step, accuracy: 1e-9, name)
            XCTAssertEqual(map.dy, step, accuracy: 1e-9, name)
            maps.append((name, map))
        }
        let ctfs: [(String, [Int])] = [("oxford", [5, 3]), ("bruker", [7, 13]), ("astar", [7, 13]), ("emsoft", [7, 13]), ("mtex", [7, 13]),
                                       ("ti_orientations_head", [4, 507])]
        for (name, shape) in ctfs {
            let map = try CTFReader.read(path: Self.fixtures.appendingPathComponent("sem/oxford/\(name).ctf").path).map
            XCTAssertEqual(map.shape, shape, name)
            maps.append((name, map))
        }

        for (name, map) in maps {
            let values = (0..<map.size).map { Double($0) + 0.5 }
            let data = map.mapData(values)
            XCTAssertEqual(data.map(\.bitPattern), Self.mapDataBefore(map, values).map(\.bitPattern), name)
            let shape = OrientationMaps.gridShape(map)
            XCTAssertEqual(data.count, shape.rows * shape.columns, name)
            XCTAssertEqual(OrientationMaps.pointIndexGrid(map).count, shape.rows * shape.columns, name)
        }
    }
}
