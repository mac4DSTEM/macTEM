//
//  SEMGrainParityTests.swift
//  TEMCore's grain analysis (Sources/TEMCore/SEM/Grains: `GrainMap`, `DefDAPQuat`, `DefDAPCrystalStructure`, `GrainBoundaries`,
//  `GrainSegmentation`, `KernelAverageMisorientation`, `GrainOrientationStatistics`) against DefDAP 1.3.1 through the
//  bundles `m5/grains-ti` (a committed 90 x 120 corner of orix-data's Ti map), `m5/grains-sdss` (the two-phase steel,
//  committed as Fixtures/ebsd-sdss-ferrite-austenite.ang) and `m5/grains-ti-full` (figures F11 and F12: the whole
//  381 x 507 Ti map, a downloaded dataset). Tolerances are the bundles' (docs/parity.md): boundary images, grain maps,
//  grain points, sizes, phases and the neighbour network exact; neighbour angles atol 1e-7; KAM, GROD and GOS atol 1e-6;
//  the grain average orientation atol 1e-10. Red before the port: none of these types exists. Red after a flood fill that
//  visits its moves in another order (the points' order moves the grain average), a boundary taken on the wrong side of
//  a point, a KAM that averages angles where DefDAP averages cosines, or a GROD axis from the inverse product.
//

import CryptoKit
import Foundation
import TEMCore
import XCTest

nonisolated final class SEMGrainParityTests: XCTestCase {

    private static let ti = CrystalPhase(name: "Ti", spaceGroup: 194, pointGroup: "622", lattice: [2.951, 2.951, 4.684, 90, 90, 120])
    private static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")

    private func flat(_ a: [SIMD4<Double>]) -> [Double] { a.flatMap { [$0[0], $0[1], $0[2], $0[3]] } }
    private func flat(_ a: [SIMD3<Double>]) -> [Double] { a.flatMap { [$0[0], $0[1], $0[2]] } }
    private func minusOneForNaN(_ a: [Double]) -> [Double] { a.map { $0.isNaN ? -1 : $0 } }
    private func bytes(_ a: [Bool]) -> [Double] { a.map { $0 ? 1 : 0 } }

    // MARK: - Maps

    /// The committed Ti corner: Bunge angles in degrees from fixtures/grain_inputs.json, through a `CrystalMap` (622) as the
    /// app hands it over.
    private func tiCorner(_ ref: SEMParityReference) throws -> GrainMap {
        let url = try XCTUnwrap(ref.inputURL())
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let ti = try XCTUnwrap(json["ti"] as? [String: Any])
        let shape = try XCTUnwrap(ti["shape"] as? [Int])
        let degrees = try XCTUnwrap(ti["euler_degrees"] as? [[Double]])
        let step = try XCTUnwrap(ti["step_um"] as? Double)
        let grid = CrystalMap.coordinates(shape: (shape[0], shape[1]), steps: (step, step))
        let map = try CrystalMap(euler: degrees.map { SIMD3($0[0], $0[1], $0[2]) * (.pi / 180) }, phaseIDs: Array(repeating: 1, count: degrees.count),
                                 x: grid.x, y: grid.y, phaseList: PhaseList([(1, Self.ti)]), scanUnit: "um")
        return try GrainMap(map: map)
    }

    private func sdss() throws -> GrainMap {
        let map = try ANGReader.read(url: Self.fixtures.appendingPathComponent("ebsd-sdss-ferrite-austenite.ang")).map
        return try GrainMap(map: map)
    }

    // MARK: - Every array on the committed maps

    private func assertEveryArray(_ map: GrainMap, _ ref: SEMParityReference) throws {
        XCTAssertEqual([map.rows, map.columns], ref.values["shape"] as? [Int])
        XCTAssertEqual(map.step, ref.values["step_um"] as? Double)
        SEMAssertParity(flat(map.quaternions), try ref.array("quaternions"))
        SEMAssertParity(map.phase.map(Double.init), try ref.array("phase"))

        let boundaries = GrainBoundaries.find(in: map, thresholdDegrees: try XCTUnwrap(ref.values["boundary_degrees"] as? Double))
        SEMAssertParity(minusOneForNaN(boundaries.angleX), try ref.array("neighbour_angle_x"))
        SEMAssertParity(minusOneForNaN(boundaries.angleY), try ref.array("neighbour_angle_y"))
        SEMAssertParity(bytes(boundaries.grainX), try ref.array("grain_boundary_x"))
        SEMAssertParity(bytes(boundaries.grainY), try ref.array("grain_boundary_y"))
        SEMAssertParity(bytes(boundaries.phaseX), try ref.array("phase_boundary_x"))
        SEMAssertParity(bytes(boundaries.phaseY), try ref.array("phase_boundary_y"))

        let minimum = try XCTUnwrap(ref.values["min_grain_size"] as? Int)
        let seg = GrainSegmentation.find(in: map, boundaries: boundaries, minimumSize: minimum)
        XCTAssertEqual(seg.grains.count, ref.values["grain_count"] as? Int)
        XCTAssertEqual(seg.grainMap.filter { $0 == -2 }.count, ref.values["small_grain_points"] as? Int)
        XCTAssertEqual(seg.grainMap.filter { $0 == 0 }.count, ref.values["unassigned_points"] as? Int)
        SEMAssertParity(seg.grainMap.map(Double.init), try ref.array("grains"))
        SEMAssertParity(seg.grains.flatMap(\.points).map(Double.init), try ref.array("grain_points"))
        SEMAssertParity(seg.sizes.map(Double.init), try ref.array("grain_sizes"))
        SEMAssertParity(seg.grains.map { Double($0.phaseIndex ?? -1) }, try ref.array("grain_phase"))
        let network = seg.neighbourNetwork(boundaries: boundaries)
        SEMAssertParity(network.flatMap { [Double($0.a), Double($0.b), Double($0.pointsX), Double($0.pointsY)] }, try ref.array("neighbour_network"))

        let threshold = try XCTUnwrap(ref.values["kam_threshold_degrees"] as? Double)
        SEMAssertParity(try KernelAverageMisorientation.map(map, method: .defdap), try ref.array("kam_defdap"))
        SEMAssertParity(minusOneForNaN(try KernelAverageMisorientation.map(map, method: .symmetric(thresholdDegrees: nil))), try ref.array("kam"))
        SEMAssertParity(minusOneForNaN(try KernelAverageMisorientation.map(map, method: .symmetric(thresholdDegrees: threshold))),
                        try ref.array("kam_threshold"))

        let stats = GrainOrientationStatistics.compute(map, segmentation: seg)
        SEMAssertParity(flat(stats.averageOrientations), try ref.array("grain_average_orientation"))
        SEMAssertParity(stats.grod.flatMap { $0 }, try ref.array("grod"))
        SEMAssertParity(flat(stats.grodAxis.flatMap { $0 }), try ref.array("grod_axis"))
        SEMAssertParity(stats.gos, try ref.array("gos"))
        SEMAssertParity(stats.averageCosine, try ref.array("grain_average_cosine"))

        // The one-call analysis is the same pieces.
        let all = try GrainAnalysis.run(map, boundaryDegrees: 10, minimumSize: minimum, kam: .symmetric(thresholdDegrees: threshold))
        XCTAssertEqual(all.segmentation, seg)
        XCTAssertEqual(all.neighbours, network)
        XCTAssertEqual(all.statistics.averageOrientations, stats.averageOrientations)
        XCTAssertEqual(all.statistics.grod, stats.grod)
    }

    func testGrainsOfTheTiCornerMatchDefDAP() throws {
        let ref = try SEMParityReference.load("m5/grains-ti")
        let map = try tiCorner(ref)
        XCTAssertEqual(map.symmetries, [DefDAPCrystalStructure.hexagonal.symmetries])
        try assertEveryArray(map, ref)
    }

    func testGrainsOfTheTwoPhaseSteelMatchDefDAP() throws {
        let ref = try SEMParityReference.load("m5/grains-sdss")
        let map = try sdss()
        XCTAssertEqual(map.symmetries, [DefDAPCrystalStructure.cubic.symmetries, DefDAPCrystalStructure.cubic.symmetries])
        XCTAssertEqual(map.phase.filter { $0 == 0 }.count, 0)
        try assertEveryArray(map, ref)
    }

    // MARK: - Figures F11 and F12 on the whole Ti map

    /// F11 (grain map and sizes) and F12 (KAM, GOS) on orix-data's 381 x 507 Ti map. The 29 MB file comes through
    /// tools/parity/sem/fetch-data.sh; without it the test skips and the committed corner above holds the port.
    func testFiguresF11AndF12GrainsKAMAndGOSOfTheTiMap() throws {
        let ref = try SEMParityReference.load("m5/grains-ti-full")
        let url = try XCTUnwrap(ref.inputURL())
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path), "fetch-data.sh has not fetched \(url.lastPathComponent)")
        let map = try GrainMap(map: CrystalMapParityTests.tiMap(url: url))
        XCTAssertEqual([map.rows, map.columns], [381, 507])
        let analysis = try GrainAnalysis.run(map, kam: .symmetric(thresholdDegrees: nil))
        let seg = analysis.segmentation
        XCTAssertEqual(seg.grains.count, ref.values["grain_count"] as? Int)
        XCTAssertEqual(seg.grainMap.filter { $0 == -2 }.count, ref.values["small_grain_points"] as? Int)

        var le = Data()
        for v in seg.grainMap { withUnsafeBytes(of: Int32(v).littleEndian) { le.append(contentsOf: $0) } }
        let digest = SHA256.hash(data: le).map { String(format: "%02x", $0) }.joined()
        let fingerprint = try XCTUnwrap(ref.values["grains"] as? [String: Any])
        XCTAssertEqual(digest, fingerprint["sha256"] as? String, "F11 grain map")

        SEMAssertParity(seg.sizes.map(Double.init), try ref.array("grain_sizes"))
        SEMAssertParity(seg.grains.map { Double($0.phaseIndex ?? -1) }, try ref.array("grain_phase"))
        SEMAssertParity(analysis.neighbours.flatMap { [Double($0.a), Double($0.b), Double($0.pointsX), Double($0.pointsY)] },
                        try ref.array("neighbour_network"))
        let index = try ref.array("sample_index").values.map { Int($0) }
        SEMAssertParity(index.map { Double(seg.grainMap[$0]) }, try ref.array("sample_grains"))

        let kamDefDAP = try KernelAverageMisorientation.map(map, method: .defdap)
        let kamThreshold = try KernelAverageMisorientation.map(map, method: .symmetric(thresholdDegrees: 5))
        SEMAssertParity(index.map { kamDefDAP[$0] }, try ref.array("sample_kam_defdap"))
        SEMAssertParity(minusOneForNaN(index.map { analysis.kam[$0] }), try ref.array("sample_kam"))
        SEMAssertParity(minusOneForNaN(index.map { kamThreshold[$0] }), try ref.array("sample_kam_threshold"))

        let stats = analysis.statistics
        SEMAssertParity(flat(stats.averageOrientations), try ref.array("grain_average_orientation"))
        SEMAssertParity(stats.gos, try ref.array("gos"))
        SEMAssertParity(stats.averageCosine, try ref.array("grain_average_cosine"))
        let grod = stats.grod.flatMap { $0 }
        let points = seg.grains.flatMap(\.points)
        let g = try ref.array("sample_grod_index").values.map { Int($0) }
        SEMAssertParity(g.map { Double(points[$0]) }, try ref.array("sample_grod_point"))
        SEMAssertParity(g.map { grod[$0] }, try ref.array("sample_grod"))
        Self.writeFigures(seg, gos: stats.gos, kam: kamThreshold)
    }

    /// The figures' numbers as text beside the reference figures (`$TMPDIR/macTEM-F11-ours.txt`: grain, size, ECD in µm;
    /// `macTEM-F12-ours.txt`: grain, GOS in degrees, then the mean KAM).
    static func writeFigures(_ seg: GrainSegmentation, gos: [Double], kam: [Double]) {
        let f11 = zip(seg.sizes, seg.equivalentCircleDiameters).enumerated().map { "\($0.offset + 1)\t\($0.element.0)\t\($0.element.1)" }
        try? (f11.joined(separator: "\n") + "\n").write(toFile: NSTemporaryDirectory() + "macTEM-F11-ours.txt", atomically: true, encoding: .utf8)
        let finite = kam.filter { !$0.isNaN }
        let f12 = gos.enumerated().map { "\($0.offset + 1)\t\($0.element * 180 / .pi)" }
            + ["mean KAM (5 degree threshold)\t\(finite.reduce(0, +) / Double(max(finite.count, 1)) * 180 / .pi)"]
        try? (f12.joined(separator: "\n") + "\n").write(toFile: NSTemporaryDirectory() + "macTEM-F12-ours.txt", atomically: true, encoding: .utf8)
    }

    // MARK: - Hand numbers

    /// Two rows of four points, one grain boundary between columns 1 and 2: two crossings on rows, none on columns; the
    /// test lines are 2 x 3 + 4 x 1 steps long, so the mean intercept is 5 steps.
    func testMeanLinealInterceptAndASTMGrainSizeNumber() throws {
        let a = SIMD3<Double>(0, 0, 0), b = SIMD3<Double>(0.5, 0, 0)  // 0.5 rad = 28.6 degrees about z
        let map = try GrainMap(rows: 2, columns: 4, euler: [a, a, b, b, a, a, b, b], phase: Array(repeating: 1, count: 8),
                               symmetries: [DefDAPCrystalStructure.cubic.symmetries], step: 2)
        let boundaries = GrainBoundaries.find(in: map)
        XCTAssertEqual(boundaries.grainX, [false, true, false, false, false, true, false, false])
        XCTAssertEqual(boundaries.grainY, Array(repeating: false, count: 8))
        XCTAssertEqual(try XCTUnwrap(GrainSegmentation.meanLinealIntercept(boundaries: boundaries, step: 2)), 10, accuracy: 1e-12)
        // ASTM E112: ℓ = 1 mm is G = −3.288; ℓ = 0.032 mm is G = 6.6436 by hand (log10 0.032 = −1.494850).
        XCTAssertEqual(GrainSegmentation.astmGrainSizeNumber(meanLinealInterceptMillimetres: 1), -3.288, accuracy: 1e-12)
        XCTAssertEqual(GrainSegmentation.astmGrainSizeNumber(meanLinealInterceptMillimetres: 0.032), -6.643856 * log10(0.032) - 3.288, accuracy: 1e-12)
        XCTAssertEqual(GrainSegmentation.astmGrainSizeNumber(meanLinealInterceptMillimetres: 0.032), 6.6436, accuracy: 1e-4)

        let seg = GrainSegmentation.find(in: map, boundaries: boundaries, minimumSize: 1)
        XCTAssertEqual(seg.grainMap, [1, 1, 2, 2, 1, 1, 2, 2])
        XCTAssertEqual(seg.sizes, [4, 4])
        XCTAssertEqual(seg.areas, [16, 16])
        XCTAssertEqual(seg.equivalentCircleDiameters[0], 2 * (16 / Double.pi).squareRoot(), accuracy: 1e-12)
        // Every boundary point lies on the map's outer pixels, which DefDAP's network leaves out.
        XCTAssertEqual(seg.neighbourNetwork(boundaries: boundaries), [])
        XCTAssertNil(GrainSegmentation.meanLinealIntercept(boundaries: GrainBoundaries.find(in: map, thresholdDegrees: 45), step: 2))
    }

    /// Two cube orientations that are one 90° rotation apart are the same crystal: the symmetric KAM reads 0 where DefDAP's
    /// reads the 90° between the stored quaternions, and no grain boundary separates them.
    func testSymmetricKAMSeesThroughEquivalentQuaternions() throws {
        let a = SIMD3<Double>(0, 0, 0), b = SIMD3<Double>(.pi / 2, 0, 0)
        let map = try GrainMap(rows: 2, columns: 2, euler: [a, b, a, b], phase: [1, 1, 1, 1], symmetries: [DefDAPCrystalStructure.cubic.symmetries], step: 1)
        let symmetric = try KernelAverageMisorientation.map(map, method: .symmetric(thresholdDegrees: nil))
        for v in symmetric { XCTAssertEqual(v, 0, accuracy: 1e-7) }
        let defdap = try KernelAverageMisorientation.map(map, method: .defdap)
        // DefDAP: cos 0 from the row neighbour, cos 45° from the column neighbour, averaged, 2 arccos.
        for v in defdap { XCTAssertEqual(v, 2 * acos((1 + cos(Double.pi / 4)) / 2), accuracy: 1e-12) }
        XCTAssertFalse(GrainBoundaries.find(in: map).grainX.contains(true))

        // A point of another phase is no neighbour; a point that is not indexed has no KAM.
        let mixed = try GrainMap(rows: 2, columns: 2, euler: [a, b, a, b], phase: [1, 2, 0, 1],
                                 symmetries: [DefDAPCrystalStructure.cubic.symmetries, DefDAPCrystalStructure.cubic.symmetries], step: 1)
        let k = try KernelAverageMisorientation.map(mixed, method: .symmetric(thresholdDegrees: 5))
        XCTAssertTrue(k[0].isNaN)   // its neighbours are phase 2 and not indexed
        XCTAssertTrue(k[1].isNaN)   // the only phase-2 point
        XCTAssertTrue(k[2].isNaN)   // not indexed
        XCTAssertTrue(k[3].isNaN)   // neighbours of phase 2 and not indexed
        XCTAssertThrowsError(try KernelAverageMisorientation.map(try GrainMap(rows: 1, columns: 3, euler: [a, a, a], phase: [1, 1, 1],
                                                                                symmetries: [DefDAPCrystalStructure.cubic.symmetries], step: 1)))
    }

    /// DefDAP's two tables for m-3m and 6/mmm; any other Laue group its proper rotations (northern, identity first).
    func testSymmetryOperatorsByPointGroup() throws {
        XCTAssertEqual(DefDAPCrystalStructure.operators(for: PointGroup.named("m-3m")), DefDAPCrystalStructure.cubic.symmetries)
        XCTAssertEqual(DefDAPCrystalStructure.operators(for: PointGroup.named("432")), DefDAPCrystalStructure.cubic.symmetries)
        XCTAssertEqual(DefDAPCrystalStructure.operators(for: PointGroup.named("6/mmm")), DefDAPCrystalStructure.hexagonal.symmetries)
        XCTAssertEqual(DefDAPCrystalStructure.operators(for: nil), [SIMD4(1, 0, 0, 0)])
        let mmm = DefDAPCrystalStructure.operators(for: PointGroup.named("mmm"))
        XCTAssertEqual(mmm.count, 4)
        XCTAssertEqual(mmm.first, SIMD4(1, 0, 0, 0))
        XCTAssertTrue(mmm.allSatisfy { $0[0] >= 0 })
        XCTAssertEqual(DefDAPCrystalStructure.operators(for: PointGroup.named("-3m")).count, 6)
        XCTAssertEqual(DefDAPCrystalStructure.operators(for: PointGroup.named("m-3")).count, 12)
        // One structure for the grain and slip code: a phase's Laue group names the same DefDAP structure both use.
        XCTAssertEqual(PointGroup.named("m-3m").flatMap(DefDAPCrystalStructure.init(pointGroup:)), .cubic)
        XCTAssertEqual(PointGroup.named("432").flatMap(DefDAPCrystalStructure.init(pointGroup:)), .cubic)
        XCTAssertEqual(PointGroup.named("6/mmm").flatMap(DefDAPCrystalStructure.init(pointGroup:)), .hexagonal)
        XCTAssertNil(PointGroup.named("mmm").flatMap(DefDAPCrystalStructure.init(pointGroup:)))
        XCTAssertEqual(DefDAPCrystalStructure.cubic.symmetries.count, 24)
        XCTAssertEqual(DefDAPCrystalStructure.hexagonal.symmetries.count, 12)
        XCTAssertThrowsError(try GrainMap(rows: 2, columns: 2, quaternions: [SIMD4(1, 0, 0, 0)], phase: [1], symmetries: [DefDAPCrystalStructure.cubic.symmetries], step: 1))
        XCTAssertThrowsError(try GrainMap(rows: 1, columns: 1, quaternions: [SIMD4(1, 0, 0, 0)], phase: [2], symmetries: [DefDAPCrystalStructure.cubic.symmetries], step: 1))
    }
}
