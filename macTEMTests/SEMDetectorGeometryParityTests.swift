//
//  SEMDetectorGeometryParityTests.swift
//  TEMCore's detector geometry (`EBSDDetectorGeometry` conventions, sizes, gnomonic bounds and coordinates, the sample-to-
//  detector rotation, TKD set-ups) and `PCCalibrationMovingScreen` against kikuchipy 0.13.1's numbers: the bundles
//  `m2/detector-pc-conventions`, `m2/detector-gnomonic`, `m2/detector-sample-to-detector`, `m2/detector-tkd-geometry` and
//  `m2/pc-moving-screen-si` (figure F5) from tools/parity/sem/detector_cases.py, at each bundle's tolerance (docs/parity.md).
//  Red before the port: no `gnomonicBounds`, `sampleToDetector` or `PCCalibrationMovingScreen`. Red after a sign flip in a
//  convention, a swapped bound, a rotation applied about a fixed instead of the turning axis, or the out → in lines drawn
//  the other way round: each moves numbers far beyond rtol 1e-7 (1e-5 for the moving screen).
//

import TEMCore
import XCTest

nonisolated final class SEMDetectorGeometryParityTests: XCTestCase {

    /// detector_cases.py's DETECTORS: (rows, columns), pixel size µm, binning.
    private static let detectors: [(rows: Int, columns: Int, px: Double, binning: Int)] = [
        (60, 60, 1.0, 1), (60, 80, 59.2, 8), (480, 640, 70.0, 2), (1, 1, 1.0, 1), (1024, 1244, 6.5, 1), (240, 200, 30.0, 4),
        (510, 510, 2.5, 1),
    ]
    /// detector_cases.py's CONVENTIONS, kikuchipy's names in order.
    private static let conventionNames = ["bruker", "tsl", "edax", "amatek", "oxford", "aztec", "emsoft", "emsoft4", "emsoft5"]

    private func detector(_ i: Int, centers: [SIMD3<Double>] = [], convention: EBSDDetectorGeometry.Convention = .bruker) -> EBSDDetectorGeometry {
        let d = Self.detectors[i]
        return EBSDDetectorGeometry(rows: d.rows, columns: d.columns, pixelSize: d.px, binning: d.binning, projectionCenters: centers,
                                    convention: convention)
    }

    private func triples(_ values: [Double]) -> [SIMD3<Double>] {
        stride(from: 0, to: values.count, by: 3).map { SIMD3(values[$0], values[$0 + 1], values[$0 + 2]) }
    }

    private func flat(_ v: [SIMD3<Double>]) -> [Double] { v.flatMap { [$0.x, $0.y, $0.z] } }

    // MARK: - Conventions

    func testEveryConventionNameReadsToBrukerAsKikuchipy() throws {
        let ref = try SEMParityReference.load("m2/detector-pc-conventions")
        let fraction = triples(try ref.array("pcs_fraction").values)
        let emsoft = triples(try ref.array("pcs_emsoft").values)
        let expected = try ref.array("to_bruker")
        XCTAssertEqual(expected.shape, [Self.detectors.count, Self.conventionNames.count, 2, 3, 3])
        var ours: [Double] = []
        for i in Self.detectors.indices {
            for name in Self.conventionNames {
                let convention = try XCTUnwrap(EBSDDetectorGeometry.Convention(kikuchipyName: name), name)
                let given = name.hasPrefix("emsoft") ? emsoft : fraction
                ours += flat(detector(i, centers: given, convention: convention).projectionCenters)
            }
        }
        SEMAssertParity(ours, expected, shape: expected.shape)
        XCTAssertNil(EBSDDetectorGeometry.Convention(kikuchipyName: "nordif"), "kikuchipy raises on an unknown name")
        XCTAssertEqual(EBSDDetectorGeometry.Convention(kikuchipyName: "EDAX"), .tsl, "kikuchipy lower-cases the name")
    }

    func testBrukerWrittenInEveryConventionAsKikuchipy() throws {
        let ref = try SEMParityReference.load("m2/detector-pc-conventions")
        let fraction = triples(try ref.array("pcs_fraction").values)
        let expected = try ref.array("from_bruker")
        var ours: [Double] = []
        for i in Self.detectors.indices {
            let d = detector(i, centers: fraction)
            for convention in [EBSDDetectorGeometry.Convention.tsl, .oxford, .emsoft4, .emsoft5] {
                ours += flat(d.centers(in: convention))
            }
        }
        SEMAssertParity(ours, expected, shape: expected.shape)
    }

    func testConventionRoundTripIsExactTo1e12() throws {
        let ref = try SEMParityReference.load("m2/detector-pc-conventions")
        let fraction = triples(try ref.array("pcs_fraction").values)
        for i in Self.detectors.indices {
            let d = detector(i, centers: fraction)
            for convention in [EBSDDetectorGeometry.Convention.bruker, .tsl, .oxford, .emsoft4, .emsoft5] {
                let back = detector(i, centers: d.centers(in: convention), convention: convention).projectionCenters
                for (a, b) in zip(back, fraction) {
                    XCTAssertEqual(a.x, b.x, accuracy: 1e-12, "detector \(i) \(convention)")
                    XCTAssertEqual(a.y, b.y, accuracy: 1e-12, "detector \(i) \(convention)")
                    XCTAssertEqual(a.z, b.z, accuracy: 1e-12 * max(1, abs(b.z)), "detector \(i) \(convention)")
                }
            }
        }
    }

    // MARK: - Sizes and gnomonic projection

    func testSizesGnomonicBoundsScalesAndRMaxAsKikuchipy() throws {
        let ref = try SEMParityReference.load("m2/detector-gnomonic")
        let pcs = triples(try ref.array("pcs_bruker").values)
        var sizes: [Double] = [], bounds: [Double] = [], scales: [Double] = [], rMax: [Double] = [], distance: [Double] = []
        for i in Self.detectors.indices {
            let d = detector(i, centers: pcs)
            sizes += [d.height, d.width, d.binnedPixelSize, Double(d.unbinnedShape.rows), Double(d.unbinnedShape.columns)]
            for pc in d.projectionCenters {
                let b = d.gnomonicBounds(pc)
                bounds += [b.xMin, b.xMax, b.yMin, b.yMax]
                let s = d.gnomonicScale(pc)
                scales += [s.x, s.y]
                rMax.append(d.rMax(pc))
                distance.append(d.specimenScintillatorDistance(pc))
            }
        }
        let sizesRef = try ref.array("sizes"), boundsRef = try ref.array("gnomonic_bounds")
        let scaleRef = try ref.array("gnomonic_scale"), rRef = try ref.array("r_max")
        let distanceRef = try ref.array("specimen_scintillator_distance")
        SEMAssertParity(sizes, sizesRef, shape: sizesRef.shape)
        SEMAssertParity(bounds, boundsRef, shape: boundsRef.shape)
        SEMAssertParity(scales, scaleRef, shape: scaleRef.shape)
        SEMAssertParity(rMax, rRef, shape: rRef.shape)
        SEMAssertParity(distance, distanceRef, shape: distanceRef.shape)
    }

    func testPixelToGnomonicAndBackAsKikuchipy() throws {
        let ref = try SEMParityReference.load("m2/detector-gnomonic")
        let pcs = triples(try ref.array("coords_pc").values)
        let coords = try ref.array("coords_pixel").values
        let points = stride(from: 0, to: coords.count, by: 2).map { SIMD2(coords[$0], coords[$0 + 1]) }
        let d = EBSDDetectorGeometry(rows: 60, columns: 60, projectionCenters: pcs)
        var gnomonic: [Double] = [], back: [Double] = []
        for pc in pcs {
            for p in points {
                let g = d.gnomonic(pixel: p, pc: pc)
                gnomonic += [g.x, g.y]
                let r = d.pixel(gnomonic: g, pc: pc)
                back += [r.x, r.y]
                XCTAssertEqual(r.x, p.x, accuracy: 1e-9)
                XCTAssertEqual(r.y, p.y, accuracy: 1e-9)
            }
        }
        let gRef = try ref.array("coords_gnomonic"), backRef = try ref.array("coords_back_same_pc")
        SEMAssertParity(gnomonic, gRef, shape: gRef.shape)
        SEMAssertParity(back, backRef, shape: backRef.shape)
    }

    // MARK: - Sample to detector, EBSD and TKD

    private func assertRotation(_ r: FrameRotation, file: StaticString = #filePath, line: UInt = #line) {
        for a in 0..<3 {
            for b in 0..<3 {
                let dot = (r.rows[a] * r.rows[b]).sum()
                XCTAssertEqual(dot, a == b ? 1 : 0, accuracy: 1e-12, "rows \(a), \(b) orthonormal", file: file, line: line)
            }
        }
    }

    func testSampleToDetectorMatrixAsKikuchipy() throws {
        let ref = try SEMParityReference.load("m2/detector-sample-to-detector")
        let angles = try ref.array("angles_deg").values
        var ours: [Double] = []
        for k in stride(from: 0, to: angles.count, by: 4) {
            let r = EBSDDetectorGeometry.sampleToDetector(sampleTilt: angles[k + 3], tilt: angles[k], azimuthal: angles[k + 1], twist: angles[k + 2])
            assertRotation(r)
            ours += r.entries
            let v = SIMD3(0.3, -0.5, 0.8)
            let round = r.inverse.apply(r.apply(v))
            XCTAssertEqual(round.x, v.x, accuracy: 1e-12); XCTAssertEqual(round.y, v.y, accuracy: 1e-12); XCTAssertEqual(round.z, v.z, accuracy: 1e-12)
        }
        let expected = try ref.array("matrix")
        SEMAssertParity(ours, expected, shape: expected.shape)
        // The default detector: 70° sample tilt, every detector angle zero (kikuchipy's second test case).
        let d = EBSDDetectorGeometry(rows: 1, columns: 1, projectionCenters: [SIMD3(0.5, 0.5, 0.5)])
        for (a, b) in zip(d.sampleToDetector.entries, expected.values[9..<18]) { XCTAssertEqual(a, b, accuracy: 1e-12) }
        XCTAssertEqual(d.detectorToSample.entries, d.sampleToDetector.inverse.entries)
    }

    func testAzimuthalTurnsAboutDetectorY() {
        // kikuchipy's test_sample_to_detector_azimuthal_about_detector_y: the detector's Y row does not move with ω.
        for sampleTilt in [0.0, 70.0] {
            let y0 = EBSDDetectorGeometry.sampleToDetector(sampleTilt: sampleTilt, tilt: 40, azimuthal: 0, twist: 0).rows[1]
            for azimuthal in [20.0, -40.0] {
                let y = EBSDDetectorGeometry.sampleToDetector(sampleTilt: sampleTilt, tilt: 40, azimuthal: azimuthal, twist: 0).rows[1]
                XCTAssertEqual(y.x, y0.x, accuracy: 1e-8); XCTAssertEqual(y.y, y0.y, accuracy: 1e-8); XCTAssertEqual(y.z, y0.z, accuracy: 1e-8)
            }
        }
    }

    func testTKDGeometryAsKikuchipy() throws {
        let ref = try SEMParityReference.load("m2/detector-tkd-geometry")
        let angles = try ref.array("angles_deg").values
        let pcs = triples(try ref.array("pcs_bruker").values)
        var matrices: [Double] = [], bounds: [Double] = [], rMax: [Double] = [], emsoft: [Double] = []
        for (n, pc) in pcs.enumerated() {
            let k = 4 * n
            let d = EBSDDetectorGeometry(rows: 480, columns: 640, pixelSize: 70, binning: 2, tilt: angles[k], azimuthal: angles[k + 1],
                                         twist: angles[k + 2], sampleTilt: angles[k + 3], projectionCenters: [pc])
            assertRotation(d.sampleToDetector)
            matrices += d.sampleToDetector.entries
            let b = d.gnomonicBounds(pc)
            bounds += [b.xMin, b.xMax, b.yMin, b.yMax]
            rMax.append(d.rMax(pc))
            emsoft += flat(d.centers(in: .emsoft5))
        }
        let mRef = try ref.array("matrix"), bRef = try ref.array("gnomonic_bounds"), rRef = try ref.array("r_max"), eRef = try ref.array("pc_emsoft")
        SEMAssertParity(matrices, mRef, shape: mRef.shape)
        SEMAssertParity(bounds, bRef, shape: bRef.shape)
        SEMAssertParity(rMax, rRef, shape: rRef.shape)
        SEMAssertParity(emsoft, eRef, shape: eRef.shape)
    }

    // MARK: - Moving screen (figure F5)

    /// detector_cases.py's MOVING_SCREEN: label, points used, pixel size (mm), binning, convention.
    private static let movingScreen: [(label: String, n: Int, px: Double?, binning: Int, convention: EBSDDetectorGeometry.Convention)] = [
        ("tutorial-3-tsl", 3, 90e-3, 1, .tsl), ("tutorial-3-mm", 3, nil, 1, .tsl), ("tests-3-tsl", 3, 46.0 / 508.0, 1, .tsl),
        ("tests-4-tsl", 4, 46.0 / 508.0, 1, .tsl), ("tests-5-tsl", 5, 46.0 / 508.0, 1, .tsl), ("tests-5-bruker", 5, 46.0 / 508.0, 1, .bruker),
        ("tests-5-mm", 5, nil, 1, .tsl), ("tests-5-binned", 5, 46.0 / 508.0 / 2.0, 2, .tsl),
    ]

    func testMovingScreenPCOfSiliconAsKikuchipy() throws {
        let ref = try SEMParityReference.load("m2/pc-moving-screen-si")
        let pIn = try ref.array("points_in").values, pOut = try ref.array("points_out").values
        let pointsIn = stride(from: 0, to: pIn.count, by: 2).map { SIMD2(pIn[$0], pIn[$0 + 1]) }
        let pointsOut = stride(from: 0, to: pOut.count, by: 2).map { SIMD2(pOut[$0], pOut[$0 + 1]) }
        for c in Self.movingScreen {
            let cal = PCCalibrationMovingScreen(rows: 480, columns: 480, pointsIn: Array(pointsIn.prefix(c.n)), pointsOut: Array(pointsOut.prefix(c.n)),
                                                deltaZ: 5, pixelSize: c.px, binning: c.binning, convention: c.convention)
            let pc = cal.center, std = cal.standardDeviation, pxy = cal.pixelCenter
            SEMAssertParity([pc.x, pc.y, pc.z], try ref.array("\(c.label)__pc"))
            SEMAssertParity(flat(cal.estimates), try ref.array("\(c.label)__pc_all"))
            SEMAssertParity([std.x, std.y, std.z], try ref.array("\(c.label)__pc_std"))
            SEMAssertParity([pxy.x, pxy.y], try ref.array("\(c.label)__pxy"))
            SEMAssertParity(cal.pixelEstimates.flatMap { [$0.x, $0.y] }, try ref.array("\(c.label)__pxy_all"))
            SEMAssertParity(cal.withinDetector.map { $0 ? 1.0 : 0.0 }, try ref.array("\(c.label)__within"))
            let lengths = cal.lineLengths
            SEMAssertParity(lengths.inner + lengths.outer, try ref.array("\(c.label)__line_lengths"))
            if c.label == "tutorial-3-tsl" || c.label == "tests-5-tsl" {
                // The F5 numbers for the figure script (detector_figure.py --ours): full precision in the CI log.
                print("F5 ours \(c.label): " + String(format: "pc %.10f %.10f %.10f std %.10f %.10f %.10f", pc.x, pc.y, pc.z, std.x, std.y, std.z))
            }
        }
        // kikuchipy's tutorial and tests state (0.5123, 0.8606) with DD 21.7 mm, and (0.5054, 0.8624, 0.5036) for five points.
        let five = PCCalibrationMovingScreen(rows: 480, columns: 480, pointsIn: pointsIn, pointsOut: pointsOut, deltaZ: 5, pixelSize: 46.0 / 508.0)
        XCTAssertEqual(five.center.x, 0.5054, accuracy: 1e-4)
        XCTAssertEqual(five.center.y, 0.8624, accuracy: 1e-4)
        XCTAssertEqual(five.center.z, 0.5036, accuracy: 1e-4)
    }
}
