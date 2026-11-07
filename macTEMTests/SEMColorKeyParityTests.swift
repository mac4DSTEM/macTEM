//
//  SEMColorKeyParityTests.swift
//  TEMCore's vectors, Miller indices, stereographic projection, fundamental sectors and colour keys
//  (Sources/TEMCore/SEM/Orientation: `StereographicProjection`, `CrystalLattice`, `Miller`, `FundamentalSector`,
//  `DirectionColorKeyTSL`, `IPFColorKeyTSL`, `EulerColorKey`) against orix 0.15.0 through the committed bundles
//  `m3/ipf-color-keys`, `m3/ipf-sdss-ferrite-austenite` and `m3/ipf-nickel-ebsd-large` (tools/parity/sem/emit.py, figure F6).
//  Tolerances are the bundles' (docs/parity.md): colours within 1e-6, coordinates within 1e-7, sector geometry within 1e-10,
//  edges within 1e-9, rounded indices exact. Red before the port: none of these types exists. Red after a wrong sign in the
//  projection, a swapped cross product in the vertices, a missed special case of the sector projection or a wrong azimuth
//  correction: the colours move by far more than 1e-6.
//

import Foundation
import TEMCore
import XCTest

nonisolated final class SEMColorKeyParityTests: XCTestCase {

    // MARK: - Helpers

    private func flat(_ a: [SIMD3<Double>]) -> [Double] { a.flatMap { [$0.x, $0.y, $0.z] } }
    private func flat(_ a: [SIMD2<Double>]) -> [Double] { a.flatMap { [$0.x, $0.y] } }
    private func flat(_ a: [SIMD4<Double>]) -> [Double] { a.flatMap { [$0[0], $0[1], $0[2], $0[3]] } }

    private func rows3(_ a: SEMParityReference.LoadedArray) -> [SIMD3<Double>] {
        stride(from: 0, to: a.values.count, by: 3).map { SIMD3(a.values[$0], a.values[$0 + 1], a.values[$0 + 2]) }
    }

    private func rows2(_ a: SEMParityReference.LoadedArray) -> [SIMD2<Double>] {
        stride(from: 0, to: a.values.count, by: 2).map { SIMD2(a.values[$0], a.values[$0 + 1]) }
    }

    private func doubles(_ any: Any?) -> [Double]? { (any as? [NSNumber])?.map(\.doubleValue) }

    /// orix's `_groups` and the aliases 2, m, 32, in the bundles' order (fixtures/orientation_inputs.json).
    private static let groups = PointGroup.groups + [PointGroup.c2, PointGroup.cs, PointGroup.d3]

    private func ipfInputs() throws -> [String: Any] {
        let url = SEMParityReference.fixturesRoot.appendingPathComponent("ipf_inputs.json")
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private func vectors(_ any: Any?, width: Int) throws -> [[Double]] {
        let rows = try XCTUnwrap(any as? [[NSNumber]])
        return rows.map { r in
            XCTAssertEqual(r.count, width)
            return r.map(\.doubleValue)
        }
    }

    // MARK: - Spherical coordinates and the stereographic projection

    func testSphericalCoordinatesAndStereographicProjectionMatchOrix() throws {
        let ref = try SEMParityReference.load("m3/ipf-color-keys")
        let d = rows3(try ref.array("directions"))
        XCTAssertEqual(d.count, 400)
        SEMAssertParity(d.map(Vector3.azimuth), try ref.array("azimuth"))
        SEMAssertParity(d.map(Vector3.polar), try ref.array("polar"))
        SEMAssertParity(flat(StereographicProjection(pole: -1).vectorToXY(d)), try ref.array("upper_xy"))
        SEMAssertParity(flat(StereographicProjection(pole: 1).vectorToXY(d)), try ref.array("lower_xy"))
        let split = StereographicProjection.vectorToXYSplit(d)
        XCTAssertEqual([split.upper.count, split.lower.count], ref.values["split_counts"] as? [Int])
        SEMAssertParity(flat(split.upper), try ref.array("split_upper_xy"))
        SEMAssertParity(flat(split.lower), try ref.array("split_lower_xy"))
        let xy = rows2(try ref.array("stereographic_xy"))
        SEMAssertParity(flat(xy.map(StereographicProjection(pole: -1).xyToVector)), try ref.array("inverse_upper"))
        SEMAssertParity(flat(xy.map(StereographicProjection(pole: 1).xyToVector)), try ref.array("inverse_lower"))
        // Inside the unit circle the inverse of the upper projection projects back to the same point (independent of orix).
        for p in xy where p.x * p.x + p.y * p.y < 1 {
            let back = StereographicProjection.project(StereographicProjection(pole: -1).xyToVector(p), pole: -1)
            XCTAssertEqual(back.x, p.x, accuracy: 1e-12)
            XCTAssertEqual(back.y, p.y, accuracy: 1e-12)
        }
    }

    // MARK: - Lattices and Miller indices

    func testLatticesAndMillerIndicesMatchOrix() throws {
        let ref = try SEMParityReference.load("m3/ipf-color-keys")
        let inputs = try ipfInputs()
        let lattices = try XCTUnwrap(ref.values["lattices"] as? [[String: Any]])
        XCTAssertEqual(lattices.count, 4)
        let hkl = try vectors(inputs["hkl"], width: 3).map { SIMD3($0[0], $0[1], $0[2]) }
        let uvw = try vectors(inputs["uvw"], width: 3).map { SIMD3($0[0], $0[1], $0[2]) }
        let hkil = try vectors(inputs["hkil"], width: 4).map { SIMD4($0[0], $0[1], $0[2], $0[3]) }
        let uvtw = try vectors(inputs["UVTW"], width: 4).map { SIMD4($0[0], $0[1], $0[2], $0[3]) }
        let roundXYZ = try vectors(inputs["round_xyz"], width: 3).map { SIMD3($0[0], $0[1], $0[2]) }
        for (i, row) in lattices.enumerated() {
            let tag = String(format: "%02d", i)
            let abc = try XCTUnwrap(doubles(row["abc"])), angles = try XCTUnwrap(doubles(row["angles"]))
            let lattice = CrystalLattice(a: abc[0], b: abc[1], c: abc[2], alpha: angles[0], beta: angles[1], gamma: angles[2])
            SEMAssertParity(flat(lattice.base), try ref.array("lattice_base_\(tag)"))
            SEMAssertParity(flat(lattice.recbase), try ref.array("lattice_recbase_\(tag)"))
            let planes = Miller(hkl: hkl, lattice: lattice)
            SEMAssertParity(flat(planes.xyz), try ref.array("hkl_xyz_\(tag)"))
            SEMAssertParity(flat(planes.uvw), try ref.array("hkl_uvw_\(tag)"))
            SEMAssertParity(planes.length, try ref.array("hkl_length_\(tag)"))
            SEMAssertParity(flat(planes.hkil), try ref.array("hkl_hkil_\(tag)"))
            let directions = Miller(uvw: uvw, lattice: lattice)
            SEMAssertParity(flat(directions.xyz), try ref.array("uvw_xyz_\(tag)"))
            SEMAssertParity(flat(directions.hkl), try ref.array("uvw_hkl_\(tag)"))
            SEMAssertParity(directions.length, try ref.array("uvw_length_\(tag)"))
            SEMAssertParity(flat(directions.UVTW), try ref.array("uvw_UVTW_\(tag)"))
            let asPlanes = Miller(xyz: roundXYZ, lattice: lattice, format: .hkl)
            let roundedHKL = asPlanes.coordinates.map { Miller.roundIndices($0, maxIndex: 20) }
            SEMAssertParity(roundedHKL.flatMap { $0 }, try ref.array("round_hkl_\(tag)"))
            let asDirections = Miller(xyz: roundXYZ, lattice: lattice, format: .uvw)
            SEMAssertParity(asDirections.coordinates.map { Miller.roundIndices($0, maxIndex: 20) }.flatMap { $0 },
                            try ref.array("round_uvw_\(tag)"))
            // `rounded()` rebuilds the vectors from those indices: their (hkl) are the integers again.
            for (h, expected) in zip(asPlanes.rounded().hkl, roundedHKL) {
                for k in 0..<3 { XCTAssertEqual(h[k], expected[k], accuracy: 1e-9) }
            }
            if row["point_group"] as? String == "6/mmm" {
                SEMAssertParity(flat(try Miller(hkil: hkil, lattice: lattice).xyz), try ref.array("hkil_xyz_\(tag)"))
                SEMAssertParity(flat(try Miller(UVTW: uvtw, lattice: lattice).xyz), try ref.array("UVTW_xyz_\(tag)"))
                XCTAssertThrowsError(try Miller(hkil: [SIMD4(1, 0, 0, 1)], lattice: lattice)) { error in
                    XCTAssertEqual(error as? Miller.IndexError, .hkilSum)
                }
            }
        }
    }

    // MARK: - Fundamental sectors

    func testFundamentalSectorsAndProjectionIntoThemMatchOrix() throws {
        let ref = try SEMParityReference.load("m3/ipf-color-keys")
        let d = Array(rows3(try ref.array("directions")).prefix(100))
        for (i, g) in Self.groups.enumerated() {
            let tag = String(format: "%02d", i)
            let sector = g.fundamentalSector
            SEMAssertParity(flat(sector.vertices), try ref.array("vertices_\(tag)"))
            SEMAssertParity(flat(sector.center.map { [$0] } ?? []), try ref.array("center_\(tag)"))
            let projected = g.projectToFundamentalSector(d)
            SEMAssertParity(flat(projected), try ref.array("in_sector_\(tag)"))
            // orix leaves some vectors outside the sector of a few non-Laue groups (-4, 1m1, -6m2), and the port keeps
            // that; the Laue groups the colour keys use always land inside (independent of orix's numbers).
            if sector.center != nil, PointGroup.laueName(g.name) == g.name {
                for v in projected { XCTAssertTrue(sector.contains(v), "\(g.name ?? "?"): \(v) is outside its sector") }
            }
        }
    }

    func testSectorEdgesMatchOrix() throws {
        let ref = try SEMParityReference.load("m3/ipf-color-keys")
        let laue = try XCTUnwrap(ref.values["laue_groups"] as? [String])
        XCTAssertEqual(laue.count, 11)
        for name in laue {
            let tag = name.replacingOccurrences(of: "/", with: "_")
            let edges = try XCTUnwrap(PointGroup.named(name)).laue.fundamentalSector.edges
            XCTAssertEqual(edges.count, ref.values["edges_count_\(tag)"] as? Int, name)
            if name == "m-3m" || name == "6/mmm" {
                SEMAssertParity(flat(edges), try ref.array("edges_\(tag)"))
            }
        }
    }

    // MARK: - The TSL colour key

    func testTSLDirectionColoursMatchOrixForEveryLaueGroup() throws {
        let ref = try SEMParityReference.load("m3/ipf-color-keys")
        let d = rows3(try ref.array("directions"))
        for name in try XCTUnwrap(ref.values["laue_groups"] as? [String]) {
            let key = DirectionColorKeyTSL(try XCTUnwrap(PointGroup.named(name)))
            XCTAssertEqual(key.symmetry.name, name)
            SEMAssertParity(flat(key.color(of: d)), try ref.array("tsl_rgb_\(name.replacingOccurrences(of: "/", with: "_"))"))
        }
        // The m-3m corners as every IPF key draws them (independent of orix): [001] red, [101] green, [111] blue, within the
        // hue shift of MTEX's azimuth correction (under 0.01).
        let cubic = DirectionColorKeyTSL(PointGroup.oh).color(of: [SIMD3(0, 0, 1), SIMD3(1, 0, 1), SIMD3(1, 1, 1)])
        for (c, expected) in zip(cubic, [SIMD3<Double>(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1)]) {
            for k in 0..<3 { XCTAssertEqual(c[k], expected[k], accuracy: 0.01) }
        }
    }

    func testKeyImagesAreTheExactColoursOnOrixsGrid() throws {
        let ref = try SEMParityReference.load("m3/ipf-color-keys")
        let stride = try XCTUnwrap(ref.values["key_stride"] as? Int)
        for name in ["m-3m", "6/mmm"] {
            let tag = name.replacingOccurrences(of: "/", with: "_")
            let key = DirectionColorKeyTSL(try XCTUnwrap(PointGroup.named(name)))
            let e = try XCTUnwrap(doubles(ref.values["key_extent_\(tag)"]))
            let shape = try XCTUnwrap(ref.values["key_shape_\(tag)"] as? [Int])
            // The sector's own extent is orix's within its 11-decimal rounding, so the default image has orix's shape.
            let own = try XCTUnwrap(key.sector.stereographicExtent)
            for (a, b) in zip([own.x.lowerBound, own.x.upperBound, own.y.lowerBound, own.y.upperBound], e) {
                XCTAssertEqual(a, b, accuracy: 1e-6, name)
            }
            let image = key.keyImage(step: 0.001, extent: (x: e[0]...e[1], y: e[2]...e[3]))
            XCTAssertEqual([image.height, image.width], shape, name)
            var rgb: [Double] = [], alpha: [Double] = []
            for row in Swift.stride(from: 0, to: image.height, by: stride) {
                for col in Swift.stride(from: 0, to: image.width, by: stride) {
                    let p = image.pixel(row: row, column: col)
                    alpha.append(Double(p[3]))
                    rgb.append(contentsOf: p[3] > 0 ? [Double(p[0]), Double(p[1]), Double(p[2])] : [0, 0, 0])
                }
            }
            SEMAssertParity(alpha, try ref.array("key_alpha_\(tag)"))
            SEMAssertParity(rgb, try ref.array("key_rgb_\(tag)"))
            // orix's own image interpolates a 2-degree sampling (scipy cubic griddata): within 0.05 of the exact colours on
            // all but its boundary pixels (decision D-SEM in docs/decisions.md).
            let interpolated = try ref.array("key_orix_interpolated_\(tag)")
            var compared = 0, within = 0, k = 0
            for row in Swift.stride(from: 0, to: image.height, by: 2 * stride) {
                for col in Swift.stride(from: 0, to: image.width, by: 2 * stride) {
                    let p = image.pixel(row: row, column: col)
                    let o = [interpolated.values[k], interpolated.values[k + 1], interpolated.values[k + 2]]
                    k += 3
                    guard p[3] > 0 else { continue }
                    compared += 1
                    if zip([p[0], p[1], p[2]].map { Double($0) }, o).allSatisfy({ abs($0 - $1) <= interpolated.atol }) { within += 1 }
                }
            }
            XCTAssertEqual(k, interpolated.values.count, name)
            XCTAssertGreaterThan(compared, 100, name)
            XCTAssertGreaterThanOrEqual(Double(within) / Double(compared), 0.99, name)
        }
    }

    // MARK: - The Euler colour key

    func testEulerColourKeyMatchesOrixForEveryGroup() throws {
        let ref = try SEMParityReference.load("m3/ipf-color-keys")
        let qa = try ref.array("euler_key_quaternions")
        let q = Swift.stride(from: 0, to: qa.values.count, by: 4).map { SIMD4(qa.values[$0], qa.values[$0 + 1], qa.values[$0 + 2], qa.values[$0 + 3]) }
        XCTAssertEqual(q.count, 100)
        for (i, g) in Self.groups.enumerated() {
            let tag = String(format: "%02d", i)
            let key = EulerColorKey(g)
            SEMAssertParity(flat(q.map(key.eulerInFundamentalRegion)), try ref.array("euler_region_\(tag)"))
            SEMAssertParity(flat(key.color(of: q)), try ref.array("euler_rgb_\(tag)"))
        }
    }

    // MARK: - Figure F6: IPF-Z maps

    private func assertIPFZMap(_ caseName: String, points: Int) throws {
        let ref = try SEMParityReference.load(caseName)
        let euler = rows3(try ref.array("euler"))
        XCTAssertEqual(euler.count, points)
        let phaseID = try ref.array("phase_id").values.map { Int($0) }
        let phases = try XCTUnwrap(ref.values["phases"] as? [String: [String: Any]])
        var keys: [Int: IPFColorKeyTSL] = [:]
        for (id, phase) in phases {
            let group = try XCTUnwrap(PointGroup.named(try XCTUnwrap(phase["point_group"] as? String)))
            keys[try XCTUnwrap(Int(id))] = IPFColorKeyTSL(group, direction: Vector3.z)
        }
        var rgb = [SIMD3<Double>](repeating: SIMD3(0, 0, 0), count: euler.count)
        for (id, key) in keys {
            let rows = phaseID.indices.filter { phaseID[$0] == id }
            let colours = key.color(of: rows.map { Rotation.fromEuler(euler[$0]).q })
            for (r, c) in zip(rows, colours) { rgb[r] = c }
        }
        SEMAssertParity(flat(rgb), try ref.array("ipf_z_rgb"))
    }

    func testIPFZColoursOfTheFerriteAusteniteMapMatchOrix() throws {
        try assertIPFZMap("m3/ipf-sdss-ferrite-austenite", points: 11_700)
    }

    func testIPFZColoursOfTheNickelMapMatchOrix() throws {
        try assertIPFZMap("m3/ipf-nickel-ebsd-large", points: 4125)
    }
}
