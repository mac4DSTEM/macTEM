//
//  SEMRefinementParityTests.swift
//  TEMCore's refinement (`NelderMead`, `EBSDRefinement`) against SciPy 1.18.1 and kikuchipy 0.13.1, bundles in
//  tools/parity/sem/references/m4/:
//  - nelder-mead: SciPy's Nelder-Mead on closed-form functions (unbounded, bounded, a zero start coordinate, a start at an
//    upper bound, stopped by maxfev and by maxiter): x, fun and the final simplex rtol 1e-12, nfev, nit and status exact;
//  - refine-nickel-block (north-star figure F10): a 10 x 10 block of the corrected Ni scan from kikuchipy's Hough
//    orientations against the Ni 20 kV master pattern: orientations (trust region 1 degree, none, a signal mask,
//    pseudo-symmetry operators) within 0.1 degree and scores rtol 1e-4; PCs rtol 1e-4 (95 % of points, all within 1e-3);
//    orientations and PCs together by the per-point spread of D-SEM-87 (docs/parity.md "Refinement").
//  Red before the port: no refinement types. Red after: a simplex coefficient or the bounds' reflection changed (counts and
//  the final simplex move), the NCC not centred (scores), the Euler-to-quaternion sign or a trust region in radians twice
//  (orientations stray), the PC's direction cosines from the start PC only (PCs do not move).
//

import Foundation
import FormatoCore
import TEMCore
import XCTest

nonisolated final class SEMRefinementParityTests: XCTestCase {

    // MARK: - Nelder-Mead

    private static func rosen(_ x: [Double]) -> Double {
        var s = 0.0
        for i in 0..<(x.count - 1) {
            let a = x[i + 1] - x[i] * x[i]
            let b = 1 - x[i]
            s += 100.0 * (a * a) + b * b
        }
        return s
    }

    private static func sphereShift(_ x: [Double]) -> Double {
        let c = [0.3, -0.2, 0.1, 0.4]
        var s = 0.0
        for i in x.indices { let d = x[i] - c[i]; s += d * d }
        return s
    }

    private static func absSum(_ x: [Double]) -> Double {
        var s = 0.0
        for v in x { s += abs(v - 0.25) }
        return s
    }

    func testNelderMeadFollowsSciPyStepForStep() throws {
        let ref = try SEMParityReference.load("m4/nelder-mead")
        let names = try XCTUnwrap(ref.values["cases"] as? [String])
        XCTAssertEqual(names.count, 6)
        let functions: [String: ([Double]) -> Double] = [
            "rosen2": Self.rosen, "rosen3_bounded": Self.rosen, "sphere_zero_start": Self.sphereShift,
            "near_upper_bound": Self.sphereShift, "rosen3_maxfev": Self.rosen, "abs_sum4_maxiter": Self.absSum,
        ]
        for name in names {
            let c = try XCTUnwrap(ref.values["\(name)_case"] as? [String: Any], name)
            let x0 = try XCTUnwrap(c["x0"] as? [Double], name)
            let bounds = (c["bounds"] as? [[Double]])?.map { NelderMead.Bound($0[0], $0[1]) }
            let opts = c["options"] as? [String: Any] ?? [:]
            let options = NelderMead.Options(maxiter: opts["maxiter"] as? Int, maxfev: opts["maxfev"] as? Int)
            let f = try XCTUnwrap(functions[name], name)
            let r = try NelderMead.minimize(f, x0: x0, bounds: bounds, options: options)
            XCTAssertEqual(r.nfev, c["nfev"] as? Int, "\(name) nfev")
            XCTAssertEqual(r.nit, c["nit"] as? Int, "\(name) nit")
            XCTAssertEqual(r.status, c["status"] as? Int, "\(name) status")
            SEMAssertParity(r.x, try ref.array("\(name)_x"))
            SEMAssertParity([r.fun], try ref.array("\(name)_fun"))
            SEMAssertParity(r.finalSimplex.flatMap { $0 }, try ref.array("\(name)_final_simplex"))
        }
    }

    func testNelderMeadRefusesCrossedBounds() {
        XCTAssertThrowsError(try NelderMead.minimize(Self.rosen, x0: [0, 0], bounds: [.init(1, 0), .init(0, 1)])) { error in
            XCTAssertEqual(error as? NelderMead.Error, .lowerAboveUpper(0))
        }
    }

    // MARK: - The block (figure F10)

    private struct Block {
        let ref: SEMParityReference
        let patterns: EBSDRefinement.Patterns
        let detector: EBSDDetectorGeometry
        let master: EBSDRefinement.Master
        let starts: [SIMD3<Double>]
        let count: Int
    }

    private static func triples(_ v: [Double]) -> [SIMD3<Double>] {
        stride(from: 0, to: v.count, by: 3).map { SIMD3(v[$0], v[$0 + 1], v[$0 + 2]) }
    }

    private static func quads(_ v: [Double]) -> [SIMD4<Double>] {
        stride(from: 0, to: v.count, by: 4).map { SIMD4(v[$0], v[$0 + 1], v[$0 + 2], v[$0 + 3]) }
    }

    private func block() throws -> Block {
        let ref = try SEMParityReference.load("m4/refine-nickel-block")
        let mpURL = try XCTUnwrap(ref.inputURL(1))
        let mp = try EMsoftMasterPatternReader.read(url: mpURL, type: .ebsd, projection: .lambert, hemisphere: .both)
        let energy = try XCTUnwrap(ref.values["energy"] as? Double)
        let master = try EBSDRefinement.Master(mp, energy: energy)
        let d = try XCTUnwrap(ref.values["detector"] as? [String: Any])
        let shape = try XCTUnwrap(d["shape"] as? [Int])
        let pc = try XCTUnwrap(d["pc"] as? [Double])
        let detector = EBSDDetectorGeometry(rows: shape[0], columns: shape[1], pixelSize: try XCTUnwrap(d["px_size"] as? Double),
                                            binning: try XCTUnwrap(d["binning"] as? Int), tilt: try XCTUnwrap(d["tilt"] as? Double),
                                            azimuthal: try XCTUnwrap(d["azimuthal"] as? Double),
                                            twist: try XCTUnwrap(d["twist"] as? Double),
                                            sampleTilt: try XCTUnwrap(d["sample_tilt"] as? Double),
                                            projectionCenters: [SIMD3(pc[0], pc[1], pc[2])])
        let p = try ref.array("patterns")
        let pixels = shape[0] * shape[1]
        let count = p.values.count / pixels
        let patterns = EBSDRefinement.Patterns(count: count, pixels: pixels, values: p.values.map { Float($0) }, isFloat32: false)
        let starts = Self.triples(try ref.array("start_euler").values)
        return Block(ref: ref, patterns: patterns, detector: detector, master: master, starts: starts, count: count)
    }

    /// Symmetry-reduced (m-3m) angles in degrees between two sets of Bunge Euler angles (orix's `angle_with`).
    private func misorientationDegrees(_ a: [SIMD3<Double>], _ b: [SIMD3<Double>]) -> [Double] {
        let oa = Orientations(quaternions: a.map(RotationConversions.eu2qu), symmetry: PointGroup.oh)
        let ob = Orientations(quaternions: b.map(RotationConversions.eu2qu), symmetry: PointGroup.oh)
        return oa.angles(with: ob).map { $0 * 180 / .pi }
    }

    private func relative(_ a: [Double], _ b: [Double]) -> [Double] {
        zip(a, b).map { abs($0 - $1) / abs($1) }
    }

    /// The fraction of `values` at or under `bound`.
    private func fraction(_ values: [Double], within bound: Double) -> Double {
        Double(values.filter { $0 <= bound }.count) / Double(values.count)
    }

    private func assertOrientations(_ results: [EBSDRefinement.OrientationResult], _ b: Block, prefix: String,
                                    file: StaticString = #filePath, line: UInt = #line) throws {
        let euler = Self.triples(try b.ref.array("\(prefix)_euler").values)
        let angles = misorientationDegrees(results.map(\.euler), euler)
        XCTAssertLessThan(angles.max()!, 0.1, "\(prefix): largest misorientation \(angles.max()!) degrees", file: file, line: line)
        let scores = try b.ref.array("\(prefix)_scores")
        SEMAssertParity(results.map(\.score), scores, file: file, line: line)
    }

    func testOrientationRefinementMatchesKikuchipyWithATrustRegion() throws {
        let b = try block()
        let starts = b.starts.map { [$0] }
        let results = try EBSDRefinement.refineOrientations(b.patterns, starts: starts, detector: b.detector, master: b.master,
                                                            settings: .init(trustRegion: [1, 1, 1]))
        XCTAssertEqual(results.count, b.count)
        XCTAssertTrue(results.allSatisfy { $0.pseudoSymmetryIndex == nil })
        try assertOrientations(results, b, prefix: "ori")
    }

    func testOrientationRefinementMatchesKikuchipyUnbounded() throws {
        let b = try block()
        let results = try EBSDRefinement.refineOrientations(b.patterns, starts: b.starts.map { [$0] }, detector: b.detector,
                                                            master: b.master)
        try assertOrientations(results, b, prefix: "ori_free")
    }

    func testOrientationRefinementMatchesKikuchipyWithASignalMask() throws {
        let b = try block()
        let border = try XCTUnwrap(b.ref.values["mask_border"] as? Int)
        let rows = b.detector.rows, cols = b.detector.columns
        var mask = [Bool](repeating: true, count: rows * cols)
        for r in border..<(rows - border) { for c in border..<(cols - border) { mask[r * cols + c] = false } }
        let results = try EBSDRefinement.refineOrientations(b.patterns, starts: b.starts.map { [$0] }, detector: b.detector,
                                                            master: b.master,
                                                            settings: .init(trustRegion: [1, 1, 1], signalMask: mask))
        try assertOrientations(results, b, prefix: "ori_masked")
        XCTAssertThrowsError(try EBSDRefinement.refineOrientations(b.patterns, starts: b.starts.map { [$0] }, detector: b.detector,
                                                                   master: b.master,
                                                                   settings: .init(signalMask: Array(repeating: true, count: rows * cols)))) {
            XCTAssertEqual($0 as? EBSDRefinement.Error, .emptyMask)
        }
    }

    func testPseudoSymmetryStartsAndTheBestOfThem() throws {
        let b = try block()
        let ops = Self.quads(try b.ref.array("pseudo_symmetry_quaternions").values)
        XCTAssertEqual(ops.count, 2)
        let starts = EBSDRefinement.startingEuler(rotations: b.starts.map(RotationConversions.eu2qu), pseudoSymmetry: ops)
        // The operator starts (index 1 and 2 of each point) against orix's outer product.
        SEMAssertParity(starts.flatMap { $0.dropFirst().flatMap { [$0.x, $0.y, $0.z] } }, try b.ref.array("ori_ps_start_euler"))
        let results = try EBSDRefinement.refineOrientations(b.patterns, starts: starts, detector: b.detector, master: b.master,
                                                            settings: .init(trustRegion: [1, 1, 1]))
        try assertOrientations(results, b, prefix: "ori_ps")
        let index = try b.ref.array("ori_ps_pseudo_symmetry_index")
        SEMAssertParity(results.map { Double($0.pseudoSymmetryIndex ?? -1) }, index)
    }

    func testProjectionCentreRefinementMatchesKikuchipy() throws {
        let b = try block()
        let rotations = Self.quads(try b.ref.array("pc_start_quaternion").values)
        let results = try EBSDRefinement.refineProjectionCenters(b.patterns, rotations: rotations, detector: b.detector,
                                                                 master: b.master, settings: .init(trustRegion: [0.05, 0.05, 0.05]))
        SEMAssertParity(results.map(\.score), try b.ref.array("pc_scores"))
        let pc = try b.ref.array("pc_pc").values
        let rel = relative(results.flatMap { [$0.pc.x, $0.pc.y, $0.pc.z] }, pc)
        XCTAssertGreaterThanOrEqual(fraction(rel, within: 1e-4), 0.95, "PC: \(fraction(rel, within: 1e-4)) within rtol 1e-4")
        XCTAssertLessThanOrEqual(rel.max()!, 1e-3, "PC: largest relative difference \(rel.max()!)")
        XCTAssertThrowsError(try EBSDRefinement.refineProjectionCenters(b.patterns, rotations: rotations, detector: b.detector,
                                                                        master: b.master, settings: .init(trustRegion: [0.05]))) {
            XCTAssertEqual($0 as? EBSDRefinement.Error, .trustRegion(expected: 3, got: 1))
        }
    }

    /// Orientation and PC together (D-SEM-87): the six-variable simplex is ill-conditioned (a PC shift mimics a small
    /// rotation), so a float32 sum in another order sends a few points to a neighbouring optimum. Held: 90 % of points within
    /// 0.1 degree and all within 1 degree (the north star's bound); 90 % of scores within rtol 1e-4, all within 1e-2, the mean
    /// within 1e-4; 90 % of PC values within 2e-3, all within 5e-2.
    func testOrientationAndProjectionCentreRefinementMatchesKikuchipy() throws {
        let b = try block()
        let results = try EBSDRefinement.refineOrientationsAndProjectionCenters(
            b.patterns, starts: b.starts.map { [$0] }, detector: b.detector, master: b.master,
            settings: .init(trustRegion: [1, 1, 1, 0.05, 0.05, 0.05]))
        let angles = misorientationDegrees(results.map(\.euler), Self.triples(try b.ref.array("ori_pc_euler").values))
        XCTAssertGreaterThanOrEqual(fraction(angles, within: 0.1), 0.9, "orientations within 0.1 degree: \(fraction(angles, within: 0.1))")
        XCTAssertLessThan(angles.max()!, 1, "largest misorientation \(angles.max()!) degrees")
        let refScores = try b.ref.array("ori_pc_scores").values
        let scores = results.map(\.score)
        let rs = relative(scores, refScores)
        XCTAssertGreaterThanOrEqual(fraction(rs, within: 1e-4), 0.9, "scores within rtol 1e-4: \(fraction(rs, within: 1e-4))")
        XCTAssertLessThanOrEqual(rs.max()!, 1e-2)
        let mean = scores.reduce(0, +) / Double(scores.count), refMean = refScores.reduce(0, +) / Double(refScores.count)
        XCTAssertEqual(mean, refMean, accuracy: 1e-4 * refMean)
        let rp = relative(results.flatMap { [$0.pc.x, $0.pc.y, $0.pc.z] }, try b.ref.array("ori_pc_pc").values)
        XCTAssertGreaterThanOrEqual(fraction(rp, within: 2e-3), 0.9, "PC values within rtol 2e-3: \(fraction(rp, within: 2e-3))")
        XCTAssertLessThanOrEqual(rp.max()!, 5e-2)
    }

    // MARK: - Crystal maps

    /// `refine_orientation(xmap, ...)`: the refined map keeps the grid, gives the master pattern's phase to the refined points,
    /// −1 and the identity to points that were not indexed, and carries scores and num_evals; the PC run hands back one PC per
    /// refined point.
    func testCrystalMapInAndOut() throws {
        let b = try block()
        var ids = [Int](repeating: 0, count: b.count)
        ids[3] = PhaseList.notIndexedID
        ids[57] = PhaseList.notIndexedID
        let (x, y) = CrystalMap.coordinates(shape: (10, 10), steps: (1.5, 1.5))
        let phase = CrystalPhase(name: "ni", spaceGroup: b.master.phase.spaceGroup, pointGroup: b.master.phase.pointGroup)
        let map = try CrystalMap(rotations: b.starts.map(RotationConversions.eu2qu), phaseIDs: ids, x: x, y: y,
                                 phaseList: PhaseList([(id: 0, phase: phase)]), scanUnit: "um")
        let refined = try EBSDRefinement.refineOrientations(map: map, patterns: b.patterns, detector: b.detector, master: b.master,
                                                           settings: .init(trustRegion: [1, 1, 1]))
        XCTAssertEqual(refined.pointCount, b.count)
        XCTAssertEqual(refined.scanUnit, "um")
        XCTAssertEqual(refined.dx, 1.5)
        XCTAssertEqual(refined.phases.names, [PhaseList.notIndexedName, b.master.phase.name])
        XCTAssertEqual(refined.allPhaseIDs[3], PhaseList.notIndexedID)
        XCTAssertEqual(refined.rotations[57], SIMD4(1, 0, 0, 0))
        let scores = try XCTUnwrap(refined.properties["scores"])
        XCTAssertEqual(scores[3], 0)
        let evals = try XCTUnwrap(refined.properties["num_evals"])
        XCTAssertTrue(evals.enumerated().allSatisfy { $0.offset == 3 || $0.offset == 57 ? $0.element == 0 : $0.element > 0 })
        XCTAssertNil(refined.properties["pseudo_symmetry_index"])
        let refScores = try b.ref.array("ori_scores").values
        let kept = (0..<b.count).filter { $0 != 3 && $0 != 57 }
        let rel = relative(kept.map { scores[$0] }, kept.map { refScores[$0] })
        XCTAssertLessThanOrEqual(rel.max()!, 1e-4)

        let wrong = try CrystalMap(rotations: map.rotations, phaseIDs: ids, x: x, y: y,
                                   phaseList: PhaseList([(id: 0, phase: CrystalPhase(name: "fe", spaceGroup: 229, pointGroup: "m-3m"))]))
        XCTAssertThrowsError(try EBSDRefinement.refineOrientations(map: wrong, patterns: b.patterns, detector: b.detector,
                                                                   master: b.master)) {
            XCTAssertEqual($0 as? EBSDRefinement.Error, .phaseMismatch(map: "fe", master: b.master.phase.name))
        }
    }
}
