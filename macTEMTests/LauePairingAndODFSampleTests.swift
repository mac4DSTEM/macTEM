//
//  LauePairingAndODFSampleTests.swift
//  macEM#615 (bundle C of #603), two checks against orix 0.15.0:
//  - orix's `_get_laue_group_name` lists no "m" although `Cs` (named "m") has 2/m elements, so a monoclinic m phase never paired in
//    Compare. Red before: `pairing` of two "m" phases was empty.
//  - The ODF took every k-th point of a row-major map, which aliased with the columns. Red before: a map whose texture alternates by
//    column, with a column count k divides, gave the ODF only one of its two components.
//

import Foundation
import TEMCore
import XCTest

nonisolated final class LauePairingAndODFSampleTests: XCTestCase {

    func testAMonoclinicMirrorPhasePairsAsTwoOverM() throws {
        XCTAssertEqual(PointGroup.laueClassName("m"), "2/m")
        XCTAssertEqual(PointGroup.laueClassName("11m"), "2/m")
        XCTAssertEqual(PointGroup.laueClassName("m-3m"), "m-3m")
        // The orix port itself stays orix's.
        XCTAssertNil(PointGroup.laueName("m"))
        // By elements the mirror's Laue group is 2/m's (as a set: the two groups list their elements in different orders).
        let cs = try XCTUnwrap(PointGroup.named("m")), c2h = try XCTUnwrap(PointGroup.named("2/m"))
        XCTAssertEqual(cs.laue.order, c2h.laue.order)
        for x in cs.laue.elements {
            XCTAssertTrue(c2h.laue.elements.contains { y in
                x.improper == y.improper && ((0..<4).allSatisfy { abs(x.q[$0] - y.q[$0]) <= 1e-8 }
                    || (0..<4).allSatisfy { abs(x.q[$0] + y.q[$0]) <= 1e-8 })
            }, "\(x.q) improper \(x.improper) is not in 2/m's Laue group")
        }

        let mirror = IndexingComparison.Side.Phase(name: "monoclinic", pointGroupName: "m")
        let twoOverM = IndexingComparison.Side.Phase(name: "monoclinic", pointGroupName: "2/m")
        XCTAssertEqual(IndexingComparison.pairing([mirror], [mirror]), [0: 0])
        XCTAssertEqual(IndexingComparison.pairing([mirror], [twoOverM]), [0: 0])
        let cubic = IndexingComparison.Side.Phase(name: "monoclinic", pointGroupName: "m-3m")
        XCTAssertEqual(IndexingComparison.pairing([mirror], [cubic]), [:])
    }

    func testTheODFSampleDoesNotAliasWithTheColumns() {
        // 200 columns x 100 rows; even columns hold one texture component, odd columns the other. Every 4th point would take
        // only even columns.
        let columns = 200, count = 200 * 100
        let picked = MapTexture.odfSampleIndices(count: count, limit: 5000)
        XCTAssertEqual(picked.count, 5000)
        XCTAssertEqual(Set(picked).count, 5000)
        XCTAssertEqual(picked, picked.sorted())
        XCTAssertTrue(picked.allSatisfy { (0..<count).contains($0) })
        let odd = Double(picked.filter { ($0 % columns) % 2 == 1 }.count) / Double(picked.count)
        XCTAssertEqual(odd, 0.5, accuracy: 0.03, "odd-column share \(odd)")
        // The old rule, for the record of what aliased.
        let strided = Array(stride(from: 0, to: count, by: (count + 4999) / 5000))
        XCTAssertEqual(strided.filter { ($0 % columns) % 2 == 1 }.count, 0)
        // Seeded: the same map gives the same sample; a small map is taken whole.
        XCTAssertEqual(MapTexture.odfSampleIndices(count: count, limit: 5000), picked)
        XCTAssertEqual(MapTexture.odfSampleIndices(count: 30, limit: 5000), Array(0..<30))
    }
}
