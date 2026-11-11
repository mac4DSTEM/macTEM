//
//  EBSDH5OxfordMapTests.swift
//  An Oxford .h5oina that holds an orientation map but no patterns (AZtec's map export, #513) opens in the Maps room, by double-click
//  and through any Open panel (both go through `FileRouting.inventory`), as a `.ctf` alone does. The planted fixtures
//  (tools/parity/sem-readers/make_h5oina_map_fixtures.py; every value exact in float32) read exactly as the H5OINA specification lays
//  the map out: Euler angles in radians as stored, phase 0 not indexed, the phases of `Header/Phases` with Oxford's Laue group ids,
//  lattice angles in degrees (90° and 120° exact), the `.ctf`'s column names with MAD in degrees, the header's cells and steps in µm.
//  The same points stored in another order with their X and Y, or without X and Y, read the same map (DREAM3D's EbsdLib, MTEX). A
//  file with no Euler angles is refused in words; the pattern files keep opening in the Patterns room.
//  Red before: the map-only file was routed to the Patterns room and refused with "the header has no 'Pattern Height' dataset.", and
//  the Maps room read only .ang and .ctf.
//

import Foundation
import TEMCore
import TEMSession
import XCTest
@testable import macTEM

nonisolated final class EBSDH5OxfordMapTests: XCTestCase {

    private static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
    private static func fixture(_ name: String) -> URL { fixtures.appendingPathComponent(name + ".h5oina") }
    private static let map = fixture("ebsd-oxford-map")

    /// The planted map, row by row (4 columns, 3 rows): its phases with 0 not indexed, Euler angles, and columns.
    private static let phases = [1, 1, 2, 2, 1, 0, 2, 2, 1, 1, 1, 2]
    private static func euler(_ i: Int) -> SIMD3<Double> {
        phases[i] == 0 ? .zero : SIMD3(0.5 + 0.125 * Double(i), 0.25 + 0.0625 * Double(i), 1.0 + 0.03125 * Double(i))
    }

    // MARK: - The map

    /// Every number of the planted map, exact: points, phases, orientations, coordinates on the header's grid, the five columns, the
    /// phase list. Red under: degrees taken for radians, phase 0 kept as a phase, MAD left in radians, the columns misnamed, the grid
    /// transposed, a lattice angle of 90.0000025°.
    func testAMapOnlyH5OINAReadsAsTheSpecificationLaysItOut() throws {
        let map = try EBSDH5Reader.readOxfordMap(url: Self.map)
        XCTAssertEqual(map.pointCount, 12)
        XCTAssertEqual(map.phaseIDs, Self.phases.map { $0 == 0 ? PhaseList.notIndexedID : $0 })
        XCTAssertEqual(map.eulerInData, (0..<12).map(Self.euler))
        XCTAssertEqual(map.x, (0..<12).map { Double($0 % 4) * 0.5 })
        XCTAssertEqual(map.y, (0..<12).map { Double($0 / 4) * 0.25 })
        XCTAssertEqual([map.dx, map.dy], [0.5, 0.25])
        XCTAssertEqual(map.scanUnit, "um")
        XCTAssertEqual(map.propertyNames, ["BC", "BS", "MAD", "bands", "error"])
        XCTAssertEqual(map.property("MAD"), (0..<12).map { 0.0078125 * Double($0 + 1) * 180 / Double.pi })
        XCTAssertEqual(map.property("BC"), (0..<12).map { Double(100 + $0) })
        XCTAssertEqual(map.property("BS"), (0..<12).map { Double(50 + $0) })
        XCTAssertEqual(map.property("bands"), (0..<12).map { Double(8 + $0 % 4) })
        XCTAssertEqual(map.property("error"), Self.phases.map { $0 == 0 ? 2.0 : 1.0 })

        XCTAssertEqual(map.phases.ids, [PhaseList.notIndexedID, 1, 2])
        let aluminium = try XCTUnwrap(map.phases[id: 1])
        XCTAssertEqual(aluminium, CrystalPhase(name: "Aluminium", spaceGroup: 225, pointGroup: "m-3m",
                                               lattice: [Double(Float(4.05)), Double(Float(4.05)), Double(Float(4.05)), 90, 90, 90],
                                               color: "tab:blue"))
        let magnesium = try XCTUnwrap(map.phases[id: 2])
        XCTAssertEqual(magnesium, CrystalPhase(name: "Magnesium", spaceGroup: 194, pointGroup: "6/mmm",
                                               lattice: [Double(Float(3.21)), Double(Float(3.21)), Double(Float(5.21)), 90, 90, 120],
                                               color: "tab:orange"))
        XCTAssertNotNil(aluminium.pointGroup)
        XCTAssertNotNil(magnesium.pointGroup)
    }

    /// The same points stored in another order, each with its X and Y, read the same map, as EbsdLib places them; without X and Y the
    /// header's grid places them row by row, as MTEX does. Red under: X and Y ignored, or a map that needs them.
    func testTheSameMapStoredInAnotherOrderOrWithoutPositionsReadsTheSame() throws {
        let map = try EBSDH5Reader.readOxfordMap(url: Self.map)
        XCTAssertEqual(try EBSDH5Reader.readOxfordMap(url: Self.fixture("ebsd-oxford-map-shuffled")), map)
        XCTAssertEqual(try EBSDH5Reader.readOxfordMap(url: Self.fixture("ebsd-oxford-map-grid")), map)
    }

    /// Positions that fill the grid once give each point its cell; the stored order already, two points on one cell, a point off the
    /// grid or one not finite give none (the stored order stands). A line scan needs no y step.
    func testThePositionsPlaceEachPointOnceOrNotAtAll() {
        let x = [0.5, 0.0, 0.5, 0.0], y = [0.0, 0.0, 0.25, 0.25]
        XCTAssertEqual(EBSDH5Reader.oxfordGridOrder(x: x, y: y, columns: 2, rows: 2, dx: 0.5, dy: 0.25), [1, 0, 3, 2])
        XCTAssertEqual(EBSDH5Reader.oxfordGridOrder(x: x.map { $0 + 10.000_01 }, y: y.map { $0 - 3 }, columns: 2, rows: 2, dx: 0.5, dy: 0.25),
                       [1, 0, 3, 2], "counted from the smallest x and y, to the nearest cell")
        XCTAssertNil(EBSDH5Reader.oxfordGridOrder(x: [0, 0.5, 0, 0.5], y: [0, 0, 0.25, 0.25], columns: 2, rows: 2, dx: 0.5, dy: 0.25))
        XCTAssertNil(EBSDH5Reader.oxfordGridOrder(x: [0, 0.5, 0.5, 0.5], y: [0, 0, 0.25, 0.25], columns: 2, rows: 2, dx: 0.5, dy: 0.25))
        XCTAssertNil(EBSDH5Reader.oxfordGridOrder(x: [0, 1.5, 0, 0.5], y: [0, 0, 0.25, 0.25], columns: 2, rows: 2, dx: 0.5, dy: 0.25))
        XCTAssertNil(EBSDH5Reader.oxfordGridOrder(x: [0, .nan, 0, 0.5], y: [0, 0, 0.25, 0.25], columns: 2, rows: 2, dx: 0.5, dy: 0.25))
        XCTAssertNil(EBSDH5Reader.oxfordGridOrder(x: x, y: y, columns: 2, rows: 2, dx: 0, dy: 0.25))
        XCTAssertNil(EBSDH5Reader.oxfordGridOrder(x: x, y: y, columns: 3, rows: 2, dx: 0.5, dy: 0.25))
        XCTAssertEqual(EBSDH5Reader.oxfordGridOrder(x: [1, 0, 0.5], y: [0, 0, 0], columns: 3, rows: 1, dx: 0.5, dy: 0), [2, 0, 1])
    }

    // MARK: - Routing and the Maps room

    /// A map-only H5OINA is the Maps room's, the pattern files stay the Patterns room's, and the Patterns reader names the room
    /// instead of the 'Pattern Height' the map lacks.
    func testAMapOnlyH5OINARoutesToTheMapsRoomAndThePatternFilesDoNot() throws {
        for name in ["ebsd-oxford-map", "ebsd-oxford-map-shuffled", "ebsd-oxford-map-grid", "ebsd-oxford-map-no-euler"] {
            let url = Self.fixture(name)
            XCTAssertEqual(EBSDH5Reader.sniff(url: url), .oxfordH5OINA, name)
            XCTAssertEqual(EBSDH5Reader.probe(url: url)?.mapOnly, true, name)
            XCTAssertEqual(FileRouting.inventory(path: url.path), FileInventory(orientationMap: true), name)
        }
        for name in ["ebsd-oxford", "ebsd-oxford-6"] {
            let url = Self.fixture(name)
            XCTAssertEqual(EBSDH5Reader.probe(url: url)?.mapOnly, false, name)
            XCTAssertEqual(FileRouting.inventory(path: url.path), FileInventory(ebsdPatterns: true), name)
        }
        XCTAssertThrowsError(try EBSDH5Reader.read(url: Self.map)) { error in
            XCTAssertEqual((error as? EBSDReadError)?.text,
                           "ebsd-oxford-map.h5oina holds an orientation map but no EBSD patterns: it opens in the Maps room.")
        }
    }

    /// The Maps room's reader makes the document of the map, named for Info; a file with neither patterns nor Euler angles is refused
    /// in words that name it.
    func testTheMapsRoomReadsTheMapAndRefusesAFileWithoutOrientations() async throws {
        let document = try await OrientationMapSession.read(Self.map)
        XCTAssertEqual(document.fileName, "ebsd-oxford-map.h5oina")
        XCTAssertEqual(document.source, .mapFile)
        XCTAssertEqual(document.format, ".h5oina (Oxford Instruments)")
        XCTAssertEqual(document.map, try EBSDH5Reader.readOxfordMap(url: Self.map))
        XCTAssertEqual([document.rows, document.columns, document.size, document.notIndexedCount], [3, 4, 12, 1])
        XCTAssertEqual(document.phaseCounts, [1: 6, 2: 5, PhaseList.notIndexedID: 1])

        do {
            let refused = try await OrientationMapSession.read(Self.fixture("ebsd-oxford-map-no-euler"))
            XCTFail("read as \(refused.format)")
        } catch let error as MapReadError {
            XCTAssertEqual(error.text,
                           "ebsd-oxford-map-no-euler.h5oina holds neither EBSD patterns nor orientations: its EBSD data has no Euler angles.")
        }
    }

    /// The app's Open: the map-only file lands in the Maps room with its map shown at IPF-Z.
    @MainActor func testOpeningAMapOnlyH5OINALandsInTheMapsRoom() async throws {
        let state = AppState(launch: LaunchOptions(arguments: []))
        await state.open(urls: [Self.map])?.value
        XCTAssertEqual(state.navigation.workspaceArea, .maps)
        for _ in 0..<4000 where state.maps.raster == nil { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(state.maps.fileName, "ebsd-oxford-map.h5oina")
        XCTAssertEqual(state.maps.document?.source, .mapFile)
        XCTAssertEqual(state.maps.document?.format, ".h5oina (Oxford Instruments)")
        XCTAssertEqual(state.maps.layer, .ipf(.z))
        XCTAssertNil(state.ebsd.dataset, "nothing opened in the Patterns room")
        XCTAssertNil(state.roomUnavailableReason(.maps))
    }
}
