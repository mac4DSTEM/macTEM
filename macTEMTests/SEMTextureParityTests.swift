//
//  SEMTextureParityTests.swift
//  Pole figures, inverse pole figure densities and ODF sections (Sources/TEMCore/SEM/Texture: `EqualAreaGrid`,
//  `PoleDensityFunction`, `PoleFigures`, `OrientationDensity`) against orix 0.15.0 through the committed bundles
//  `m5/texture-ti` and `m5/texture-cubic`, and figure F13 on orix-data's whole Ti map (`m5/texture-ti-full`, skipped until
//  tools/parity/sem/fetch-data.sh has fetched it). Tolerances are the bundles' (docs/parity.md): counts exact except that
//  each vector the bundle counts as lying on a bin edge (within 1e-12 rad) may sit in the neighbouring bin, densities atol
//  1e-7, ODF values rtol 1e-4, grid nodes and poles atol 1e-10. Red before the port: none of these types exists. Red after
//  a swapped histogram axis, the wrong reflect mode, a sector fold onto the wrong grid, the orientation instead of its
//  inverse in the pole figure, or a missing symmetry element in the ODF: each moves the densities by far more than that.
//

import TEMCore
import XCTest

nonisolated final class SEMTextureParityTests: XCTestCase {

    // MARK: - Helpers

    private func rows3(_ a: SEMParityReference.LoadedArray) -> [SIMD3<Double>] {
        stride(from: 0, to: a.values.count, by: 3).map { SIMD3(a.values[$0], a.values[$0 + 1], a.values[$0 + 2]) }
    }

    private func rows4(_ a: SEMParityReference.LoadedArray) -> [SIMD4<Double>] {
        stride(from: 0, to: a.values.count, by: 4).map { SIMD4(a.values[$0], a.values[$0 + 1], a.values[$0 + 2], a.values[$0 + 3]) }
    }

    private func int(_ ref: SEMParityReference, _ key: String) throws -> Int {
        try XCTUnwrap((ref.values[key] as? NSNumber)?.intValue, "\(ref.manifest.caseName): no value \(key)")
    }

    private func family(_ ref: SEMParityReference, _ tag: String) throws -> [Double] {
        try XCTUnwrap((ref.values["family_\(tag)"] as? [NSNumber])?.map(\.doubleValue), "no family \(tag)")
    }

    /// The same set of poles as orix's symmetrised family (orix sorts them), each within 1e-10.
    private func assertSamePoles(_ ours: [SIMD3<Double>], _ reference: SEMParityReference.LoadedArray, file: StaticString = #filePath, line: UInt = #line) {
        let theirs = rows3(reference)
        XCTAssertEqual(ours.count, theirs.count, "\(reference.name): pole count", file: file, line: line)
        for p in theirs where !ours.contains(where: { max(abs($0.x - p.x), abs($0.y - p.y), abs($0.z - p.z)) <= reference.atol }) {
            XCTFail("\(reference.name): orix's pole \(p) is not among ours", file: file, line: line)
        }
    }

    /// Counts equal orix's, except that each of the `ambiguous` vectors the bundle found on a bin edge may have gone to the
    /// neighbouring bin: the sum is the same and at most 2 x ambiguous counts differ in total. Returns whether they are equal.
    @discardableResult
    private func assertCounts(_ ours: [Double], _ reference: SEMParityReference.LoadedArray, ambiguous: Int,
                              file: StaticString = #filePath, line: UInt = #line) -> Bool {
        XCTAssertEqual(ours.count, reference.values.count, "\(reference.name): bins", file: file, line: line)
        XCTAssertEqual(ours.reduce(0, +), reference.values.reduce(0, +), "\(reference.name): total", file: file, line: line)
        let moved = zip(ours, reference.values).reduce(0.0) { $0 + abs($1.0 - $1.1) }
        XCTAssertLessThanOrEqual(moved, Double(2 * ambiguous), "\(reference.name): \(moved) counts differ, \(ambiguous) vectors on an edge",
                                 file: file, line: line)
        return moved == 0
    }

    /// A pole figure: poles, counts, the smoothing of orix's own counts, and the whole chain when no edge vector moved.
    private func checkPoleFigure(_ ref: SEMParityReference, tag: String, orientations: Orientations, lattice: CrystalLattice,
                                 group: PointGroup) throws {
        let poles = try PoleFigures.poles(family: try family(ref, tag), lattice: lattice, group: group)
        assertSamePoles(poles, try ref.array("poles_\(tag)"))
        let v = PoleFigures.sampleDirections(orientations, poles: poles)
        let (counts, grid) = PoleDensityFunction.counts(v)
        XCTAssertEqual([grid.azimuthBins, grid.polarBins], try ref.array("counts_\(tag)").shape)
        let refCounts = try ref.array("counts_\(tag)")
        let same = assertCounts(counts, refCounts, ambiguous: try int(ref, "ambiguous_\(tag)"))
        let pdf = try ref.array("pdf_\(tag)")
        SEMAssertParity(PoleDensityFunction.density(counts: refCounts.values).values, pdf, shape: [360, 90])
        if same { SEMAssertParity(PoleFigures.poleFigure(orientations, poles: poles).values, pdf) }
    }

    /// The inverse pole figure density of z in `laue`'s sector: counts at half the resolution, the fold and mask, the chain.
    private func checkInversePoleFigure(_ ref: SEMParityReference, orientations: Orientations, laue: PointGroup) throws {
        XCTAssertEqual(ref.values["ipf_symmetry"] as? String, laue.name)
        let v = PoleFigures.crystalDirections(orientations)
        let (counts, grid) = PoleDensityFunction.counts(v, symmetry: laue)
        XCTAssertEqual(grid.resolution, 0.5)
        let refCounts = try ref.array("ipf_z_counts")
        let same = assertCounts(counts, refCounts, ambiguous: try int(ref, "ipf_z_ambiguous"))
        let fromTheirs = PoleDensityFunction.density(counts: refCounts.values, symmetry: laue)
        SEMAssertParity(fromTheirs.mask.map { $0 ? 1.0 : 0.0 }, try ref.array("ipf_z_mask"))
        let filled = zip(fromTheirs.values, fromTheirs.mask).map { $0.1 ? -1 : $0.0 }
        SEMAssertParity(filled, try ref.array("ipf_z_density"), shape: [360, 90])
        if same {
            let map = PoleFigures.inversePoleFigure(orientations, laue: laue)
            SEMAssertParity(zip(map.values, map.mask).map { $0.1 ? -1 : $0.0 }, try ref.array("ipf_z_density"))
        }
    }

    private func checkODF(_ ref: SEMParityReference, orientations: Orientations, phi1: [Double], Phi: [Double]) throws {
        let hw = try XCTUnwrap(ref.values["odf_half_width_degrees"] as? Double)
        let kappa = OrientationDensity.kappa(halfWidthDegrees: hw)
        SEMAssertParity(kappa, ref, scalar: "odf_kappa")
        SEMAssertParity(OrientationDensity.kernelConstant(kappa: kappa), ref, scalar: "odf_kernel_constant")
        let shape = try XCTUnwrap((ref.values["odf_section_shape"] as? [NSNumber])?.map(\.intValue))
        XCTAssertEqual(shape, [phi1.count, Phi.count])
        let sections = try XCTUnwrap((ref.values["odf_sections_phi2_degrees"] as? [NSNumber])?.map(\.doubleValue))
        for phi2 in sections {
            let s = OrientationDensity.section(orientations, phi2Degrees: phi2, phi1Degrees: phi1, PhiDegrees: Phi, halfWidthDegrees: hw)
            SEMAssertParity(s.values, try ref.array("odf_phi2_\(Int(phi2))"), shape: shape)
        }
    }

    private static let tiLattice = CrystalLattice(a: 2.951, b: 2.951, c: 4.684, alpha: 90, beta: 90, gamma: 120)

    // MARK: - Grid

    /// orix's equal-area grid at 1° (upper hemisphere): 361 azimuth and 91 polar edges, their stereographic nodes; at 0.5°
    /// with a sector the same nodes as the 1° grid.
    func testEqualAreaGridMatchesOrix() throws {
        let ref = try SEMParityReference.load("m5/texture-cubic")
        let grid = EqualAreaGrid(resolution: 1)
        XCTAssertEqual(grid.azimuthEdges.count, 361)
        XCTAssertEqual(grid.polarEdges.count, 91)
        XCTAssertEqual(grid.polarEdges.first, 0)
        XCTAssertEqual(try XCTUnwrap(grid.polarEdges.last), Double.pi / 2, accuracy: 1e-15)
        let nodes = grid.stereographicNodes
        SEMAssertParity(nodes.x, try ref.array("grid_x"), shape: [361, 91])
        SEMAssertParity(nodes.y, try ref.array("grid_y"), shape: [361, 91])
        SEMAssertParity(nodes.x, try ref.array("ipf_grid_x"))
        SEMAssertParity(nodes.y, try ref.array("ipf_grid_y"))
        // numpy's histogramdd edge rule: the last edge belongs to the last bin, outside is nothing.
        XCTAssertEqual(EqualAreaGrid.bin(2 * Double.pi, edges: grid.azimuthEdges), 359)
        XCTAssertEqual(EqualAreaGrid.bin(0, edges: grid.azimuthEdges), 0)
        XCTAssertNil(EqualAreaGrid.bin(Double.pi / 2 + 1e-9, edges: grid.polarEdges))
    }

    // MARK: - Ti (622), figure F13 on the committed orientations

    func testTiPoleFiguresMatchOrix() throws {
        let ref = try SEMParityReference.load("m5/texture-ti")
        XCTAssertEqual(ref.values["point_group"] as? String, "622")
        let o = Orientations.fromEuler(rows3(try ref.array("euler_degrees")), symmetry: PointGroup.d6, degrees: true)
        XCTAssertEqual(o.count, 2000)
        for tag in ["0001", "10-10", "11-20"] {
            try checkPoleFigure(ref, tag: tag, orientations: o, lattice: Self.tiLattice, group: PointGroup.d6h)
        }
    }

    func testTiInversePoleFigureDensityMatchesOrix() throws {
        let ref = try SEMParityReference.load("m5/texture-ti")
        let o = Orientations.fromEuler(rows3(try ref.array("euler_degrees")), symmetry: PointGroup.d6, degrees: true)
        try checkInversePoleFigure(ref, orientations: o, laue: PointGroup.d6h)
    }

    func testTiODFSectionsMatchTheKernelDensity() throws {
        let ref = try SEMParityReference.load("m5/texture-ti")
        let o = Orientations.fromEuler(rows3(try ref.array("euler_degrees")), symmetry: PointGroup.d6, degrees: true)
        let phi1 = OrientationDensity.nodes(below: 360, step: 5), Phi = OrientationDensity.nodes(below: 92.5, step: 5)
        try checkODF(ref, orientations: o, phi1: phi1, Phi: Phi)
        // The Maps room's default section grid for 622 is the same one.
        let r = OrientationDensity.bungeRanges(for: PointGroup.d6)
        XCTAssertEqual(r.phi1, 360)
        XCTAssertEqual(r.Phi, 90)
        XCTAssertEqual(r.phi2, 60)
        let s = OrientationDensity.section(o, phi2Degrees: 30)
        XCTAssertEqual(s.phi1Degrees, phi1)
        XCTAssertEqual(s.PhiDegrees, Phi)
        SEMAssertParity(s.values, try ref.array("odf_phi2_30"))
    }

    // MARK: - Cubic (m-3m)

    func testCubicPoleFiguresAndInversePoleFigureMatchOrix() throws {
        let ref = try SEMParityReference.load("m5/texture-cubic")
        XCTAssertEqual(ref.values["point_group"] as? String, "m-3m")
        let o = Orientations(quaternions: rows4(try ref.array("quaternions")), symmetry: PointGroup.oh)
        let cubic = CrystalLattice(a: 1, b: 1, c: 1, alpha: 90, beta: 90, gamma: 90)
        for tag in ["100", "110", "111"] {
            try checkPoleFigure(ref, tag: tag, orientations: o, lattice: cubic, group: PointGroup.oh)
        }
        try checkInversePoleFigure(ref, orientations: o, laue: PointGroup.oh)
    }

    func testCubicODFSectionAndItsNormalisation() throws {
        let ref = try SEMParityReference.load("m5/texture-cubic")
        let o = Orientations(quaternions: rows4(try ref.array("quaternions")), symmetry: PointGroup.oh)
        let nodes = OrientationDensity.nodes(below: 92.5, step: 5)
        try checkODF(ref, orientations: o, phi1: nodes, Phi: nodes)
        let r = OrientationDensity.bungeRanges(for: PointGroup.oh)
        XCTAssertEqual([r.phi1, r.Phi, r.phi2], [360, 90, 90])

        // Independent of the formula's parity: the identity alone peaks at C(κ) / 24 at the identity, and the ODF of the
        // 100 orientations averages 1 mrd over orix's uniform 3° sample of m-3m's fundamental zone.
        let identity = Orientations(quaternions: [SIMD4(1, 0, 0, 0)], symmetry: PointGroup.oh)
        let peak = OrientationDensity.values(identity, at: [SIMD4(1, 0, 0, 0)])[0]
        SEMAssertParity(peak, ref, scalar: "odf_identity_at_identity")
        let uniform = try OrientationSampling.fundamental(resolution: 3, pointGroup: PointGroup.oh).map(\.q)
        let values = OrientationDensity.values(o, at: uniform)
        SEMAssertParity(values.reduce(0, +) / Double(values.count), ref, scalar: "odf_mean_over_uniform_sample")
    }

    // MARK: - Rasters

    /// The Texture tab's canvases: the pole figure drawn over the unit disk (NaN outside), every drawn pixel the value of its
    /// bin; the IPF over its sector's extent with masked bins left out; an ODF section one pixel per node, Φ down.
    func testRastersDrawTheBinsTheyFallIn() throws {
        let ref = try SEMParityReference.load("m5/texture-cubic")
        let o = Orientations(quaternions: rows4(try ref.array("quaternions")), symmetry: PointGroup.oh)
        let pf = PoleFigures.poleFigure(o, poles: try PoleFigures.poles(family: [1, 0, 0], lattice: CrystalLattice(a: 1, b: 1, c: 1, alpha: 90, beta: 90, gamma: 90), group: PointGroup.oh))
        let raster = TextureRaster.stereographic(pf, size: 64)
        XCTAssertEqual(raster.values.count, 64 * 64)
        XCTAssertTrue(raster.values[0].isNaN, "the corner is outside the disk")
        let centre = raster.values[32 * 64 + 32]
        let atCentre = try XCTUnwrap(pf.value(at: StereographicProjection(pole: -1).xyToVector(SIMD2(1.0 / 64, -1.0 / 64))))
        XCTAssertEqual(centre, Float(atCentre))
        XCTAssertLessThanOrEqual(Double(raster.high), pf.maximum * (1 + 1e-6), "a pixel shows a bin, never more")

        let ipf = PoleFigures.inversePoleFigure(o, laue: PointGroup.oh)
        let extent = try XCTUnwrap(PointGroup.oh.fundamentalSector.stereographicExtent)
        let ipfRaster = TextureRaster.stereographic(ipf, size: 48, extent: extent)
        XCTAssertGreaterThan(ipfRaster.values.filter(\.isFinite).count, 48 * 48 / 4)
        XCTAssertTrue(ipfRaster.values.contains { $0.isNaN }, "the sector is a triangle in its bounding box")

        let s = OrientationDensity.section(o, phi2Degrees: 45, phi1Degrees: [0, 5, 10], PhiDegrees: [0, 5])
        let image = TextureRaster.section(s)
        XCTAssertEqual([image.width, image.height], [3, 2])
        XCTAssertEqual(image.values[1 * 3 + 2], Float(s.values[2 * 2 + 1]))
    }

    // MARK: - Figure F13 on the whole Ti map

    /// Figure F13: pole figures {0001}, {10-10}, {11-20} and the IPF-Z density of every point of orix-data's Ti map, the
    /// φ2 = 30° ODF section of every tenth point. The 29 MB file comes through tools/parity/sem/fetch-data.sh; without it
    /// the test skips and the committed 2000 orientations above hold the port.
    func testFigureF13OnTheTiMap() throws {
        let ref = try SEMParityReference.load("m5/texture-ti-full")
        let url = try XCTUnwrap(ref.inputURL())
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path), "fetch-data.sh has not fetched \(url.lastPathComponent)")
        let o = try CrystalMapParityTests.tiMap(url: url).orientations()
        XCTAssertEqual(o.count, try int(ref, "points"))
        for tag in ["0001", "10-10", "11-20"] {
            try checkPoleFigure(ref, tag: tag, orientations: o, lattice: Self.tiLattice, group: PointGroup.d6h)
        }
        try checkInversePoleFigure(ref, orientations: o, laue: PointGroup.d6h)
        let stride = try int(ref, "odf_stride")
        let every = Orientations(quaternions: Swift.stride(from: 0, to: o.count, by: stride).map { o.quaternions[$0] }, symmetry: o.symmetry)
        try checkODF(ref, orientations: every, phi1: OrientationDensity.nodes(below: 360, step: 5), Phi: OrientationDensity.nodes(below: 92.5, step: 5))
    }
}
