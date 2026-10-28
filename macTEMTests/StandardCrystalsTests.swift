import XCTest
import DiffractoCore
import DiffractoScattering
import TEMCore

/// The standards a ring pattern is calibrated against (R7): named, at the lattice constants the room states, with the
/// kinematic ring lists the numpy reference gives (tools/parity/diffraction-room-parity R7: Au 8 families at k_max 1.2 and 22 at 2.0,
/// Al the same, Si 10 and 28; Au {111} d = a / sqrt 3). Red under: Au at 4.0872, the diamond basis dropped (Si becomes 14 families at 1.2).
nonisolated final class StandardCrystalsTests: XCTestCase {

    private func list(_ name: String, _ kMax: Double) throws -> KinematicReflectionList {
        try StandardCrystals.list(of: try XCTUnwrap(StandardCrystals.named(name)), kMax: kMax)
    }

    func testTheStandardsAreAuAlSiAtTheirNamedLatticeConstants() {
        XCTAssertEqual(StandardCrystals.all.map(\.name), ["Au", "Al", "Si"])
        XCTAssertEqual(StandardCrystals.named("Au")?.latticeConstant, 4.0782)
        XCTAssertEqual(StandardCrystals.named("Al")?.latticeConstant, 4.0495)
        XCTAssertEqual(StandardCrystals.named("Si")?.latticeConstant, 5.4309)
        XCTAssertNil(StandardCrystals.named("Cu"))
    }

    func testGoldFirstRingIsAOverRootThree() throws {
        let first = try XCTUnwrap(try list("Au", 1.2).families.first).family
        XCTAssertEqual(first.name, "{1 1 1}")
        XCTAssertEqual(first.multiplicity, 8)
        XCTAssertEqual(first.d, 4.0782 / 3.0.squareRoot(), accuracy: 1e-12)
        XCTAssertEqual(first.d, 2.3545498678091317, accuracy: 1e-12)
    }

    func testGoldRingCounts() throws {
        XCTAssertEqual(try list("Au", 1.2).families.count, 8)
        XCTAssertEqual(try list("Au", 2.0).families.count, 22)
        XCTAssertEqual(try list("Au", 1.2).families.map(\.family.name),
                       ["{1 1 1}", "{2 0 0}", "{2 2 0}", "{3 1 1}", "{2 2 2}", "{4 0 0}", "{3 3 1}", "{4 2 0}"])
    }

    func testAluminiumHasGoldsFamiliesAtItsOwnSpacings() throws {
        XCTAssertEqual(try list("Al", 1.2).families.count, 8)
        XCTAssertEqual(try list("Al", 2.0).families.count, 22)
        XCTAssertEqual(try XCTUnwrap(try list("Al", 1.2).families.first).family.d, 4.0495 / 3.0.squareRoot(), accuracy: 1e-12)
    }

    func testSiliconDiamondBasisForbidsTheSecondRingAndCountsTen() throws {
        let si = try list("Si", 1.2)
        XCTAssertEqual(si.families.count, 10)
        XCTAssertEqual(try list("Si", 2.0).families.count, 28)
        XCTAssertEqual(si.families.map(\.family.name).prefix(4), ["{1 1 1}", "{2 2 0}", "{3 1 1}", "{4 0 0}"])      // no {2 0 0}, no {2 2 2}
        XCTAssertEqual(try XCTUnwrap(si.families.first).family.d, 5.4309 / 3.0.squareRoot(), accuracy: 1e-12)
    }

    func testAnInvalidKMaxIsTheKitsRefusal() {
        XCTAssertThrowsError(try StandardCrystals.list(of: StandardCrystals.all[0], kMax: -1)) { error in
            XCTAssertEqual(error as? KinematicError, .reflectionList(.invalidKMax(-1)))
        }
    }
}
