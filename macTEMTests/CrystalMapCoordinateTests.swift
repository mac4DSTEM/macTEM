//
//  CrystalMapCoordinateTests.swift
//  x and y that make no grid are refused when a crystal map is built (`CrystalMap.Refusal.coordinates`): a value that is not
//  finite, a step far finer than the spread (one jittered coordinate), a grid of more than `CrystalMap.maximumCells` cells; an
//  ASTAR `.ctf` with a NaN coordinate reaches the same refusal. A grid of exactly the bound builds, and the committed .ang and .ctf
//  maps build the shapes and steps orix gives them. Red before: a trap in `dataSlices` (`Int(.nan)`, `Int(1e300)`), or a map of
//  a quarter of a billion cells built without a word for the Maps room to allocate.
//

import Foundation
import TEMCore
import XCTest

nonisolated final class CrystalMapCoordinateTests: XCTestCase {

    private static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")

    private static func identities(_ n: Int) -> [SIMD4<Double>] { Array(repeating: SIMD4<Double>(1, 0, 0, 0), count: n) }

    /// The refusal building a map of three identity points at `x` and `y` throws; nil when it builds.
    private func refusal(x: [Double]?, y: [Double]?) -> CrystalMap.Refusal? {
        do {
            _ = try CrystalMap(rotations: Self.identities(3), x: x, y: y)
            return nil
        } catch {
            return error as? CrystalMap.Refusal
        }
    }

    /// A coordinate that is not finite, and a step so fine its slice bound passes 2^53, are refused by name.
    func testCoordinatesThatAreNotFiniteOrTooFineAreRefused() {
        XCTAssertEqual(refusal(x: [0, Double.nan, 1], y: [0, 0, 1]), .coordinates("x holds a value that is not a finite number"))
        XCTAssertEqual(refusal(x: [0, 1, 2], y: [0, Double.infinity, 1]), .coordinates("y holds a value that is not a finite number"))
        XCTAssertEqual(refusal(x: [0, 1e-300, 1], y: nil), .coordinates("x spans more than 2^53 times its smallest step"))
        let reason = CrystalMap.Refusal.coordinates("x holds a value that is not a finite number").errorDescription ?? ""
        XCTAssertTrue(reason.hasPrefix("The crystal map's coordinates") && reason.hasSuffix("."), reason)
    }

    /// Three points whose coordinates span 2^14 × 2^14 cells build (the bound itself); one cell more across is refused.
    func testAGridPastTheBoundIsRefused() throws {
        XCTAssertEqual(CrystalMap.maximumCells, 1 << 28)
        let corner = try CrystalMap(rotations: Self.identities(3), x: [0, 1, 16_383], y: [0, 1, 16_383])
        XCTAssertEqual(corner.shape, [16_384, 16_384])
        XCTAssertEqual(refusal(x: [0, 1, 16_384], y: [0, 1, 16_383]), .coordinates("they span more than 268435456 grid cells"))
        XCTAssertEqual(refusal(x: [0, 1e-6, 1000], y: [0, 0, 1]), .coordinates("they span more than 268435456 grid cells"))
    }

    /// An ASTAR `.ctf` with a NaN x: the coordinates are left as read and the map refuses them.
    func testAnASTARFileWithANaNCoordinateIsRefused() {
        let text = "Channel Text File\nAuthor\tFile created from ACOM RES results\nXCells\t2\nYCells\t2\nXStep\t1\nYStep\t1\n" +
            "Phases\t1\n3.6;3.6;3.6\t90;90;90\tNi\t11\t225\nPhase\tX\tY\tBands\tError\tEuler1\tEuler2\tEuler3\tMAD\tBC\tBS\n" +
            "1 0 0 1 0 1 2 3 0 0 0\n1 nan 0 1 0 1 2 3 0 0 0\n1 0 1 1 0 1 2 3 0 0 0\n1 1 1 1 0 1 2 3 0 0 0\n"
        XCTAssertThrowsError(try CTFReader.read(text: text)) { error in
            XCTAssertEqual(error as? CrystalMap.Refusal, .coordinates("x holds a value that is not a finite number"))
        }
    }

    /// The committed maps build the shapes and steps orix gives them (Fixtures/ebsd-edax.truth.json, Fixtures/sem/oxford/*.json).
    func testTheCommittedMapsKeepTheirShapesAndSteps() throws {
        let sdss = try ANGReader.read(url: Self.fixtures.appendingPathComponent("ebsd-sdss-ferrite-austenite.ang")).map
        XCTAssertEqual(sdss.shape, [100, 117])
        XCTAssertEqual([sdss.dy, sdss.dx], [1.5, 1.5])
        let oxford = try CTFReader.read(path: Self.fixtures.appendingPathComponent("sem/oxford/oxford.ctf").path).map
        XCTAssertEqual(oxford.shape, [5, 3])
        XCTAssertEqual([oxford.dy, oxford.dx], [0.1, 0.1])
        let astar = try CTFReader.read(path: Self.fixtures.appendingPathComponent("sem/oxford/astar.ctf").path).map
        XCTAssertEqual(astar.shape, [7, 13])
        XCTAssertEqual([astar.dy, astar.dx], [0.00191999995708466, 0.00191999995708466])
    }
}
