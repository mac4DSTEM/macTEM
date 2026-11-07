//
//  SEMOrientationParityTests.swift
//  TEMCore's orientation core (Sources/TEMCore/SEM/Orientation: `RotationConversions`, `Rotation`, `PointGroup`,
//  `OrientationRegion`, `Orientations`, `Misorientations`) against orix 0.15.0 through the committed bundles
//  `m3/rotation-conversions`, `m3/point-groups`, `m3/orientation-regions` and `m3/ti-disorientations` (tools/parity/sem/emit.py).
//  Tolerances are the bundles' (docs/parity.md): components and angles within atol 1e-7, symmetry elements and region normals
//  within 1e-10, names, orders, flags and indices exact. Red before the port: none of these types exists. Red after a sign in a
//  conversion, a product order, an element order in `fromGenerators`, a boundary in a fundamental zone or a pair order in
//  `reduce`: the arrays move by far more than the tolerance.
//

import TEMCore
import XCTest

nonisolated final class SEMOrientationParityTests: XCTestCase {

    // MARK: - Helpers

    private func flat(_ a: [SIMD4<Double>]) -> [Double] { a.flatMap { [$0[0], $0[1], $0[2], $0[3]] } }
    private func flat(_ a: [SIMD3<Double>]) -> [Double] { a.flatMap { [$0.x, $0.y, $0.z] } }

    private func rows4(_ a: SEMParityReference.LoadedArray) -> [SIMD4<Double>] {
        stride(from: 0, to: a.values.count, by: 4).map { SIMD4(a.values[$0], a.values[$0 + 1], a.values[$0 + 2], a.values[$0 + 3]) }
    }

    private func rows3(_ a: SEMParityReference.LoadedArray) -> [SIMD3<Double>] {
        stride(from: 0, to: a.values.count, by: 3).map { SIMD3(a.values[$0], a.values[$0 + 1], a.values[$0 + 2]) }
    }

    /// The bundle's comparison where the reference holds +∞ (a two-fold Rodrigues-Frank length): those must be +∞ here, the
    /// rest within the array's tolerance.
    private func assertParityWithInfinities(_ actual: [Double], _ reference: SEMParityReference.LoadedArray,
                                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.count, reference.values.count, reference.name, file: file, line: line)
        var finiteActual: [Double] = [], finiteExpected: [Double] = []
        for (a, b) in zip(actual, reference.values) {
            if b.isInfinite {
                XCTAssertEqual(a, b, "\(reference.name): an infinite reference element", file: file, line: line)
            } else {
                finiteActual.append(a)
                finiteExpected.append(b)
            }
        }
        if let m = SEMParityCompare.mismatch(name: reference.name, actual: finiteActual, expected: finiteExpected,
                                             rtol: reference.rtol, atol: reference.atol) {
            XCTFail(m.description, file: file, line: line)
        }
    }

    // MARK: - Conversions

    func testConversionsFromQuaternionsMatchOrix() throws {
        let ref = try SEMParityReference.load("m3/rotation-conversions")
        let rotations = rows4(try ref.array("qu")).map { Rotation($0) }
        XCTAssertEqual(rotations.count, 64)
        SEMAssertParity(flat(rotations.map(\.euler)), try ref.array("qu2eu"))
        SEMAssertParity(rotations.flatMap(\.matrix.flat), try ref.array("qu2om"))
        SEMAssertParity(flat(rotations.map(\.axisAngleFour)), try ref.array("qu2ax"))
        SEMAssertParity(flat(rotations.map(\.axisAngleVector)), try ref.array("axangle"))
        SEMAssertParity(flat(rotations.map(\.homochoric)), try ref.array("qu2ho"))
        SEMAssertParity(rotations.map(\.angle), try ref.array("angle"))
        SEMAssertParity(flat(rotations.map(\.axis)), try ref.array("axis"))
        let rows = try XCTUnwrap(ref.values["rodrigues_rows"] as? [Int])
        SEMAssertParity(flat(rows.map { rotations[$0].rodrigues }), try ref.array("ro"))
        assertParityWithInfinities(flat(rotations.map(\.rodriguesFrank)), try ref.array("ro_frank"))
        // And back.
        SEMAssertParity(flat(rotations.map { Rotation.fromMatrix($0.matrix).q }), try ref.array("om2qu"))
        SEMAssertParity(flat(rotations.map { RotationConversions.ho2ax($0.homochoric) }), try ref.array("ho2ax"))
        SEMAssertParity(flat(rotations.map { Rotation.fromHomochoric($0.homochoric).q }), try ref.array("ho2qu"))
        SEMAssertParity(flat(rows.map { Rotation.fromRodrigues(rotations[$0].rodrigues).q }), try ref.array("ro2qu"))
        SEMAssertParity(flat(rotations.map { r -> SIMD4<Double> in
            let ax = r.axisAngleFour
            return Rotation.fromAxisAngle(SIMD3(ax[0], ax[1], ax[2]), ax[3]).q
        }), try ref.array("ax2qu"))
    }

    func testEulerAndCubochoricConversionsMatchOrix() throws {
        let ref = try SEMParityReference.load("m3/rotation-conversions")
        let eu = rows3(try ref.array("eu"))
        SEMAssertParity(flat(eu.map { Rotation.fromEuler($0).q }), try ref.array("eu2qu"))
        SEMAssertParity(flat(eu.map { Rotation.fromEuler($0, direction: .crystalToLab).q }), try ref.array("eu2qu_crystal2lab"))
        SEMAssertParity(flat(eu.map { Rotation.fromEuler($0).euler }), try ref.array("eu_roundtrip"))
        // ANGReader's conversion is the core's.
        for e in eu { XCTAssertEqual(ANGReader.quaternion(fromBungeEuler: e), RotationConversions.eu2qu(e)) }
        let cu = rows3(try ref.array("cu"))
        SEMAssertParity(cu.map { Double(RotationConversions.pyramid($0)) }, try ref.array("cu_pyramid"))
        SEMAssertParity(flat(cu.map(RotationConversions.cu2ho)), try ref.array("cu2ho"))
        assertParityWithInfinities(flat(cu.map(RotationConversions.cu2ro)), try ref.array("cu2ro"))
    }

    func testCompositionVectorsOuterProductsAndUniqueMatchOrix() throws {
        let ref = try SEMParityReference.load("m3/rotation-conversions")
        let r = rows4(try ref.array("qu")).map { Rotation($0) }
        let r1 = Array(r[0..<32]), r2 = Array(r[32..<64])
        SEMAssertParity(flat(zip(r1, r2).map { ($0.0 * $0.1).q }), try ref.array("product"))
        SEMAssertParity(flat(r.map(\.inverse.q)), try ref.array("inverse"))
        SEMAssertParity(zip(r1, r2).map { $0.0.angle(with: $0.1) }, try ref.array("angle_with"))
        let v = rows3(try ref.array("vectors"))
        SEMAssertParity(flat(zip(r, v).map { $0.0 * $0.1 }), try ref.array("rotated"))
        let improper = try ref.array("improper_mask").values.map { $0 != 0 }
        let ri = zip(r, improper).map { Rotation(unit: $0.0.q, improper: $0.1) }
        SEMAssertParity(flat(zip(ri, v).map { $0.0 * $0.1 }), try ref.array("rotated_improper"))
        SEMAssertParity(zip(ri[0..<32], ri[32..<64]).map { ($0.0 * $0.1).improper ? 1.0 : 0.0 }, try ref.array("product_improper"))
        SEMAssertParity(flat(Rotation.outer(Array(r[0..<4]), Array(r[4..<7])).map(\.q)), try ref.array("outer"), shape: [4, 3, 4])
        SEMAssertParity(flat(Rotation.outer(Array(r[0..<4]), Array(v[0..<5]))), try ref.array("outer_vectors"), shape: [4, 5, 3])
        let a = Array(r[0..<8]), b = Array(r[8..<16])
        SEMAssertParity(a.flatMap { x in b.map { x.absDot($0) } }, try ref.array("dot_outer"))
        SEMAssertParity(a.flatMap { x in b.map { x.angleOuter(with: $0) } }, try ref.array("angle_with_outer"))
        let dup = rows4(try ref.array("unique_input")).map { Rotation($0) }
        let u = Rotation.unique(dup)
        SEMAssertParity(u.index.map { Double($0) }, try ref.array("unique_index"))
        SEMAssertParity(u.inverse.map { Double($0) }, try ref.array("unique_inverse"))
    }

    // MARK: - Point groups

    /// orix's `_groups` and the aliases 2, m, 32, in the bundle's order.
    private static let groups = PointGroup.groups + [PointGroup.c2, PointGroup.cs, PointGroup.d3]

    func testPointGroupsMatchOrixElementForElement() throws {
        let ref = try SEMParityReference.load("m3/point-groups")
        let names = try XCTUnwrap(ref.values["names"] as? [String])
        XCTAssertEqual(Self.groups.map { $0.name ?? "" }, names)
        let rows = try XCTUnwrap(ref.values["groups"] as? [[String: Any]])
        XCTAssertEqual(rows.count, Self.groups.count)
        for (i, (g, row)) in zip(Self.groups, rows).enumerated() {
            let tag = String(format: "%02d", i)
            let label = g.name ?? "?"
            SEMAssertParity(flat(g.elements.map(\.q)), try ref.array("elements_\(tag)"))
            SEMAssertParity(g.elements.map { $0.improper ? 1.0 : 0.0 }, try ref.array("improper_\(tag)"))
            XCTAssertEqual(g.order, row["order"] as? Int, label)
            XCTAssertEqual(g.isProper, row["is_proper"] as? Bool, label)
            XCTAssertEqual(g.containsInversion, row["contains_inversion"] as? Bool, label)
            XCTAssertEqual(g.properSubgroup.name, row["proper_subgroup"] as? String, label)
            let laue = g.laue
            XCTAssertEqual(laue.name, row["laue"] as? String, label)
            XCTAssertEqual(laue.order, row["laue_order"] as? Int, label)
            XCTAssertEqual(g.laueProperSubgroup.name, row["laue_proper_subgroup"] as? String, label)
            XCTAssertEqual(g.system, row["system"] as? String, label)
            XCTAssertEqual(g.eulerFundamentalRegion, row["euler_fundamental_region"] as? [Int], label)
            XCTAssertEqual(g.subgroups.compactMap(\.name), row["subgroups"] as? [String], label)
            let center = row["sector_center"] as? [Double]
            XCTAssertEqual(g.fundamentalSectorCenter.map { [$0.x, $0.y, $0.z] }, center, label)
            SEMAssertParity(flat(g.fundamentalSectorNormals), try ref.array("sector_\(tag)"))
            SEMAssertParity(flat(g.fundamentalZoneNormals()), try ref.array("zone_\(tag)"))
        }
    }

    func testOrientationRegionsMatchOrix() throws {
        let ref = try SEMParityReference.load("m3/orientation-regions")
        let defined = try XCTUnwrap(ref.values["misorientation_defined"] as? [Bool])
        for (i, g) in Self.groups.enumerated() {
            let tag = String(format: "%02d", i)
            SEMAssertParity(flat(try OrientationRegion.fromSymmetry(g).normals), try ref.array("orientation_\(tag)"))
            if defined[i] {
                SEMAssertParity(flat(try OrientationRegion.fromSymmetry(g, g).normals), try ref.array("misorientation_\(tag)"))
            } else {
                XCTAssertThrowsError(try OrientationRegion.fromSymmetry(g, g), g.name ?? "?") { error in
                    XCTAssertEqual(error as? OrientationRegion.Error, .bothImproperWithoutInversion)
                }
            }
        }
    }

    // MARK: - Orientations and misorientations (figure 3, first half)

    func testTiOrientationsReduceAndDisorientationsMatchOrix() throws {
        let ref = try SEMParityReference.load("m3/ti-disorientations")
        XCTAssertEqual(ref.values["point_group"] as? String, "622")
        let eu = rows3(try ref.array("euler_degrees"))
        XCTAssertEqual(eu.count, 2000)
        let o = Orientations.fromEuler(eu, symmetry: PointGroup.d6, degrees: true)
        SEMAssertParity(flat(o.quaternions), try ref.array("quaternions"))
        SEMAssertParity(flat(o.reduced().quaternions), try ref.array("reduced"))
        let later = Orientations(quaternions: Array(o.quaternions.dropFirst()), symmetry: o.symmetry)
        let earlier = Orientations(quaternions: Array(o.quaternions.dropLast()), symmetry: o.symmetry)
        SEMAssertParity(later.angles(with: earlier), try ref.array("angle_with_next"))
        let m = try later.misorientations(from: earlier)
        SEMAssertParity(m.angles, try ref.array("disorientation_next"))
        SEMAssertParity(flat(m.quaternions), try ref.array("misorientation_next"))
        let first150 = Orientations(quaternions: Array(o.quaternions.prefix(150)), symmetry: o.symmetry)
        SEMAssertParity(first150.distanceMatrix(), try ref.array("distance_matrix_150"), shape: [150, 150])
        let m40 = Misorientations(quaternions: Array(m.quaternions.prefix(40)), start: m.start, end: m.end)
        SEMAssertParity(m40.distanceMatrix(), try ref.array("misorientation_distance_matrix_40"), shape: [40, 40])
    }

    func testCubicOrientationsReduceAndDisorientationsMatchOrix() throws {
        let ref = try SEMParityReference.load("m3/ti-disorientations")
        XCTAssertEqual(ref.values["cubic_point_group"] as? String, "m-3m")
        let c = Orientations(quaternions: rows4(try ref.array("cubic_quaternions")), symmetry: PointGroup.oh)
        SEMAssertParity(flat(c.reduced().quaternions), try ref.array("cubic_reduced"))
        let later = Orientations(quaternions: Array(c.quaternions.dropFirst()), symmetry: c.symmetry)
        let earlier = Orientations(quaternions: Array(c.quaternions.dropLast()), symmetry: c.symmetry)
        let m = try later.misorientations(from: earlier)
        SEMAssertParity(m.angles, try ref.array("cubic_disorientation_next"))
        // `angle_with` (the Indexing room's Compare, D-SEM-97) is the same number for one point group, m-3m's improper elements
        // included.
        SEMAssertParity(later.angles(with: earlier), try ref.array("cubic_disorientation_next"))
        SEMAssertParity(flat(m.quaternions), try ref.array("cubic_misorientation_next"))
        SEMAssertParity(c.distanceMatrix(), try ref.array("cubic_distance_matrix"), shape: [100, 100])
        let m30 = Misorientations(quaternions: Array(m.quaternions.prefix(30)), start: m.start, end: m.end)
        SEMAssertParity(m30.distanceMatrix(), try ref.array("cubic_misorientation_distance_matrix_30"), shape: [30, 30])
        // The cubic disorientation never exceeds 62.8° (Mackenzie 1958), a check independent of orix.
        XCTAssertLessThanOrEqual(m.angles.max() ?? 0, 62.81 * Double.pi / 180)
    }
}
