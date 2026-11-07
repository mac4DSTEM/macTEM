//
//  SEMHoughIndexingParityTests.swift
//  TEMCore's Hough indexing (`HoughReflectorLibrary`, `HoughBandDetector`, `HoughIndexer`) against pyEBSDindex 0.3.10.1 as
//  kikuchipy 0.13.1 drives it: the bundles `m4/hough-library` (the reflector libraries of an FCC, a BCC and an HCP phase),
//  `m4/hough-nickel-block` (every stage on a 6 x 6 block of the corrected nickel scan, fed kikuchipy's exact uint8
//  patterns) and `m4/hough-indexing-nickel-large` (north-star figure F8, the whole scan). Tolerances in docs/parity.md,
//  "Hough indexing".
//  Red before the port: no Hough types. Red after a wrong line plan, kernel sign or edge fill (Radon arrays), a wrong peak
//  order or sub-pixel fit (band table), a wrong look-up table or tolerance (votes), or a wrong frame (orientations off by
//  the 20 degree tilt or a 90 degree turn about z).
//

import FormatoCore
import Foundation
import TEMCore
import XCTest

nonisolated final class SEMHoughIndexingParityTests: XCTestCase {

    private static let demoScan = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("DemoData/nickel_ebsd_large/patterns_v2.h5")

    private struct Inputs: Decodable {
        struct Phase: Decodable {
            let name: String
            let spacegroup: Int
            let lattice: [Double]
            let polefamilies: [[Int]]?
            let nband_earlyexit: Int
        }
        struct Indexer: Decodable {
            let nBands: Int
            let tSigma: Double
            let rSigma: Double
            let nRho: Int
            let nTheta: Int
            let rhoMaskFrac: Double
            let angTol: Double
        }
        let phases: [Phase]
        let indexer: Indexer
    }

    private func inputs() throws -> Inputs {
        let url = SEMParityReference.fixturesRoot.appendingPathComponent("hough_inputs.json")
        return try JSONDecoder().decode(Inputs.self, from: Data(contentsOf: url))
    }

    private func library(_ p: Inputs.Phase) throws -> HoughReflectorLibrary {
        try HoughReflectorLibrary(name: p.name, spaceGroup: p.spacegroup, lattice: p.lattice, reflectors: p.polefamilies,
                                  earlyExitBands: p.nband_earlyexit)
    }

    private func settings(_ i: Inputs) -> HoughBandDetector.Settings {
        .init(rhoBins: i.indexer.nRho, thetaBins: i.indexer.nTheta, thetaSigma: i.indexer.tSigma, rhoSigma: i.indexer.rSigma,
              rhoMaskFraction: i.indexer.rhoMaskFrac, bands: i.indexer.nBands)
    }

    private func flat3(_ v: [SIMD3<Double>]) -> [Double] { v.flatMap { [$0.x, $0.y, $0.z] } }
    private func flat3(_ v: [SIMD3<Int>]) -> [Double] { v.flatMap { [Double($0.x), Double($0.y), Double($0.z)] } }

    /// Symmetry-reduced (m-3m) misorientation angles in degrees, orix's `Orientation.angle_with`.
    private func misorientationDegrees(_ a: [SIMD4<Double>], _ b: [SIMD4<Double>]) -> [Double] {
        let oa = Orientations(quaternions: a, symmetry: PointGroup.oh)
        let ob = Orientations(quaternions: b, symmetry: PointGroup.oh)
        return oa.angles(with: ob).map { $0 * 180 / .pi }
    }

    private func quaternions(_ values: [Double]) -> [SIMD4<Double>] {
        stride(from: 0, to: values.count, by: 4).map { SIMD4(values[$0], values[$0 + 1], values[$0 + 2], values[$0 + 3]) }
    }

    // MARK: - The reflector library

    func testReflectorLibrariesMatchPyEBSDindex() throws {
        let ref = try SEMParityReference.load("m4/hough-library")
        for p in try inputs().phases {
            let lib = try library(p)
            let n = p.name
            let laue = try XCTUnwrap(ref.values["\(n)_laue"] as? [String: Any], n)
            XCTAssertEqual(lib.laueCode, laue["lauecode"] as? Int, n)
            XCTAssertEqual(HoughReflectorLibrary.laueRotations(lib.laueCode).count, laue["nsymops"] as? Int, n)
            XCTAssertEqual(lib.familyCount, laue["npolefamilies"] as? Int, n)
            SEMAssertParity(flat3(lib.poles), try ref.array("\(n)_poles"))
            SEMAssertParity(flat3(lib.polesCartesian), try ref.array("\(n)_poles_cart"))
            SEMAssertParity(lib.familyID.map(Double.init), try ref.array("\(n)_family_id"))
            SEMAssertParity(lib.angleTable, try ref.array("\(n)_ang_table"))
            SEMAssertParity(lib.familySize.map(Double.init), try ref.array("\(n)_n_family"))
            SEMAssertParity(lib.familyStart.map(Double.init), try ref.array("\(n)_fam_index"))
            SEMAssertParity(lib.pairAngles, try ref.array("\(n)_pair_angles"))
            SEMAssertParity(lib.pairFamilies.flatMap { [Double($0.0), Double($0.1)] }, try ref.array("\(n)_pair_family_id"))
            SEMAssertParity(flat3(lib.tripletAngles), try ref.array("\(n)_triplet_angles"))
            SEMAssertParity(flat3(lib.tripletFamilies), try ref.array("\(n)_triplet_family_id"))
        }
    }

    func testLaueCodesAndCornerTableAsPyEBSDindex() {
        XCTAssertEqual(HoughReflectorLibrary.laueCode(spaceGroup: 225), 43)
        XCTAssertEqual(HoughReflectorLibrary.laueCode(spaceGroup: 229), 43)
        XCTAssertEqual(HoughReflectorLibrary.laueCode(spaceGroup: 194), 62)
        XCTAssertEqual(HoughReflectorLibrary.laueCode(spaceGroup: 1), 1)
        XCTAssertEqual(HoughReflectorLibrary.laueCode(spaceGroup: 205), 23)
        XCTAssertEqual(HoughReflectorLibrary.laueCode(spaceGroup: 139), 42)
        // The sorted triangle's corner families: angles (ab, ac, bc) = (50, 30, 40) sort to (30, 40, 50): edge order
        // [1, 2, 0], corners [2, 0, 1] (pyEBSDindex's lut).
        let (a, f) = HoughReflectorLibrary.sortTriplet(SIMD3(50, 30, 40), SIMD3(7, 8, 9))
        XCTAssertEqual(a, SIMD3(30, 40, 50))
        XCTAssertEqual(f, SIMD3(9, 7, 8))
        XCTAssertThrowsError(try HoughReflectorLibrary(name: "x", spaceGroup: 231, lattice: [1, 1, 1, 90, 90, 90]))
        XCTAssertThrowsError(try HoughReflectorLibrary(name: "x", spaceGroup: 225, lattice: [1, 1, 1, 90, 90, 90], reflectors: [[0, 0, 0]]))
    }

    // MARK: - Band detection on the block

    func testRadonPlanKernelAndTransformMatchPyEBSDindex() throws {
        let ref = try SEMParityReference.load("m4/hough-nickel-block")
        let det = try HoughBandDetector(rows: 60, columns: 60, settings: settings(inputs()))
        let plan = try XCTUnwrap(ref.values["plan"] as? [String: Any])
        XCTAssertEqual(Double(det.rhoMax), plan["rhoMax"] as? Double)
        XCTAssertEqual([det.padding.rho, det.padding.theta], plan["padding"] as? [Int])
        XCTAssertEqual([det.peakWindow.rho, det.peakWindow.theta], plan["peakPad"] as? [Int])
        SEMAssertParity(det.thetaDegrees.map(Double.init), try ref.array("radon_theta"))
        SEMAssertParity(det.rhoValues.map(Double.init), try ref.array("radon_rho"))
        SEMAssertParity(det.lineCounts.map(Double.init), try ref.array("radon_counts"))
        SEMAssertParity(det.radonMask.map { $0 ? 1.0 : 0.0 }, try ref.array("radon_mask"))
        SEMAssertParity(det.kernel, try ref.array("kernel"))

        let patterns = try ref.array("block_corrected_patterns")
        let first = Array(patterns.values[0..<3600])
        let padded = try det.radon(first)
        let (pR, pT) = det.padding
        let width = 180 + 2 * pT
        var inner: [Double] = []
        for j in 0..<90 { for i in 0..<180 { inner.append(padded[(j + pR) * width + i + pT]) } }
        SEMAssertParity(inner, try ref.array("radon_first"), shape: [90, 180])
        let conv = det.convolve(padded)
        SEMAssertParity(conv.convolved, try ref.array("radon_conv_first"))
        SEMAssertParity([conv.minimum, conv.mean, conv.maximum], try ref.array("radon_conv_stats_first"))
    }

    func testBandsOfTheBlockMatchPyEBSDindex() throws {
        let ref = try SEMParityReference.load("m4/hough-nickel-block")
        let input = try inputs()
        let det = try HoughBandDetector(rows: 60, columns: 60, settings: settings(input))
        let pcValues = try XCTUnwrap(ref.values["pc_bruker"] as? [Double])
        let pc = SIMD3(pcValues[0], pcValues[1], pcValues[2])
        let patterns = try ref.array("block_corrected_patterns").values
        var bands: [HoughBandDetector.Band] = []
        var normals: [SIMD3<Double>] = []
        for q in 0..<36 {
            let b = try det.detect(Array(patterns[(q * 3600)..<((q + 1) * 3600)]))
            bands += b
            normals += det.normals(b, pc: pc)
        }
        SEMAssertParity(bands.map(\.max), try ref.array("band_max"))
        SEMAssertParity(bands.map(\.normalizedMax), try ref.array("band_normmax"))
        SEMAssertParity(bands.map(\.averageMax), try ref.array("band_avemax"))
        SEMAssertParity(bands.map(\.width), try ref.array("band_width"))
        SEMAssertParity(bands.flatMap { [$0.peakRho, $0.peakTheta] }, try ref.array("band_maxloc"))
        SEMAssertParity(bands.flatMap { [$0.rhoIndex, $0.thetaIndex] }, try ref.array("band_aveloc"))
        SEMAssertParity(bands.map(\.theta), try ref.array("band_theta"))
        SEMAssertParity(bands.map(\.rho), try ref.array("band_rho"))
        SEMAssertParity(bands.map { $0.valid ? 1.0 : 0.0 }, try ref.array("band_valid"))
        SEMAssertParity(flat3(normals), try ref.array("band_normals"))
    }

    // MARK: - Vote and indexing on the block

    func testTripletVoteOfTheBlockMatchesPyEBSDindex() throws {
        let ref = try SEMParityReference.load("m4/hough-nickel-block")
        let lib = try library(inputs().phases[0])
        let normals = try ref.array("band_normals").values, intensity = try ref.array("band_intensity").values
        var weighted: [Double] = [], counts: [Double] = [], family: [Double] = [], rank: [Double] = []
        for q in 0..<36 {
            let n = (0..<10).map { b in SIMD3(normals[(q * 10 + b) * 3], normals[(q * 10 + b) * 3 + 1], normals[(q * 10 + b) * 3 + 2]) }
            let v = HoughIndexer.tripletVote(library: lib, normals: n, intensity: Array(intensity[(q * 10)..<((q + 1) * 10)]))
            weighted += v.weighted
            counts += v.counts
            family += v.family.map(Double.init)
            rank += v.rank
        }
        SEMAssertParity(weighted, try ref.array("vote_accumulator_weighted"))
        SEMAssertParity(counts, try ref.array("vote_accumulator"))
        SEMAssertParity(family, try ref.array("vote_band_family"))
        SEMAssertParity(rank, try ref.array("vote_band_rank"))
    }

    func testBlockIsIndexedAsPyEBSDindex() throws {
        let ref = try SEMParityReference.load("m4/hough-nickel-block")
        let input = try inputs()
        let lib = try library(input.phases[0])
        let det = try HoughBandDetector(rows: 60, columns: 60, settings: settings(input))
        let pcValues = try XCTUnwrap(ref.values["pc_bruker"] as? [Double])
        let geometry = try XCTUnwrap(ref.values["geometry"] as? [String: Any])
        let indexer = try HoughIndexer(phases: [lib], detector: det, projectionCenter: SIMD3(pcValues[0], pcValues[1], pcValues[2]),
                                       sampleTilt: try XCTUnwrap(geometry["sample_tilt"] as? Double),
                                       cameraElevation: try XCTUnwrap(geometry["camera_elevation"] as? Double))
        let patterns = try ref.array("block_corrected_patterns").values
        let solutions = try (0..<36).map { q in try indexer.index(Array(patterns[(q * 3600)..<((q + 1) * 3600)])).solution }
        SEMAssertParity(solutions.map { Double($0.matchedBands) }, try ref.array("nmatch"))
        SEMAssertParity(solutions.map { Double($0.phase) }, try ref.array("phase"))
        SEMAssertParity(solutions.map { Double($0.totalVotes) }, try ref.array("totvotes"))
        SEMAssertParity(solutions.map(\.fit), try ref.array("fit"))
        SEMAssertParity(solutions.map(\.confidence), try ref.array("cm"))
        SEMAssertParity(solutions.map(\.patternQuality), try ref.array("pq"))
        SEMAssertParity(solutions.map(\.imageQuality), try ref.array("iq"))
        // The matched variant is one of a family's symmetry-equivalent poles (pyEBSDindex's float32 trial scores break the
        // ties differently): the family is what must agree, and the orientation up to the crystal symmetry.
        let refMatch = try ref.array("band_match_index").values.map { Int($0) }
        let ours = solutions.flatMap { $0.bandMatch }
        XCTAssertEqual(ours.map { $0 < 0 ? -1 : lib.familyID[$0] }, refMatch.map { $0 < 0 ? -1 : lib.familyID[$0] })
        let angles = misorientationDegrees(solutions.map(\.quaternion), quaternions(try ref.array("quaternion").values))
        let worst = angles.max() ?? .nan
        print("Hough block: worst misorientation \(worst) degrees")
        XCTAssertLessThan(worst, 1e-3)
    }

    // MARK: - Figure F8 on the shipped demo scan

    /// F8 end to end: the shipped scan, the app's static then dynamic background (within one grey level of kikuchipy,
    /// D-SEM-18), the file's mean PC, Hough indexing of all 4125 patterns; against kikuchipy + pyEBSDindex: the indexed
    /// count within one point, 99 % of points within 1 degree (symmetry-reduced; north-star figure 4), the number of matched
    /// bands equal on 95 %. The Euler map is printed as float32 base64 for tools/parity/sem/hough_figure.py --ours.
    func testFigureF8HoughIndexedMapOfTheDemoScan() async throws {
        let ref = try SEMParityReference.load("m4/hough-indexing-nickel-large")
        let input = try inputs()
        let dataset = try EBSDH5Reader.read(url: Self.demoScan)
        let background = try XCTUnwrap(dataset.staticBackground).doubles().map { UInt8($0) }
        let raw = try [UInt8](dataset.allPatterns().bytes)
        let rows = dataset.scanRows, columns = dataset.scanColumns, pr = dataset.patternRows, pc = dataset.patternColumns
        let pixels = pr * pc
        var corrected = [Double](repeating: 0, count: rows * columns * pixels)
        for i in 0..<(rows * columns) {
            let p = Array(raw[(i * pixels)..<((i + 1) * pixels)])
            let s = try PatternProcessing.removeStaticBackground(p, background: background, operation: .subtract)
            let d = try PatternProcessing.removeDynamicBackground(s, rows: pr, columns: pc, operation: .subtract, domain: .frequency)
            for j in 0..<pixels { corrected[i * pixels + j] = Double(d[j]) }
        }
        let centres = dataset.detector.projectionCenters
        let mean = centres.reduce(SIMD3<Double>(0, 0, 0), +) / Double(centres.count)
        let refPC = try XCTUnwrap(ref.values["pc_bruker"] as? [Double])
        XCTAssertEqual(mean.x, refPC[0], accuracy: 1e-12)
        XCTAssertEqual(mean.y, refPC[1], accuracy: 1e-12)
        XCTAssertEqual(mean.z, refPC[2], accuracy: 1e-12)
        let indexer = try HoughIndexer(phases: [library(input.phases[0])],
                                       detector: HoughBandDetector(rows: pr, columns: pc, settings: settings(input)),
                                       projectionCenter: mean, sampleTilt: dataset.detector.sampleTilt,
                                       cameraElevation: dataset.detector.tilt)
        let source = corrected
        let started = Date()
        let map = try await indexer.indexMap(scanRows: rows, scanColumns: columns) { r, c in
            let start = (r * columns + c) * pixels
            return Array(source[start..<(start + pixels)])
        }
        let seconds = Date().timeIntervalSince(started)
        let refPhase = try ref.array("phase").values
        let indexed = map.solutions.filter { $0.phase >= 0 }.count
        let refIndexed = refPhase.filter { $0 >= 0 }.count
        let angles = misorientationDegrees(map.rotations.map(\.q), quaternions(try ref.array("quaternion").values))
        let both = (0..<angles.count).filter { map.solutions[$0].phase >= 0 && refPhase[$0] >= 0 }
        let within = both.filter { angles[$0] < 1 }.count
        let refN = try ref.array("nmatch").values
        let sameN = (0..<refN.count).filter { Double(map.solutions[$0].matchedBands) == refN[$0] }.count
        print("F8: \(String(format: "%.1f", seconds)) s; indexed \(indexed) (reference \(refIndexed)); within 1 degree \(within) of \(both.count); same matched-band count \(sameN) of \(refN.count); median misorientation \(both.map { angles[$0] }.sorted()[both.count / 2])")
        XCTAssertLessThanOrEqual(abs(indexed - refIndexed), 1)
        XCTAssertGreaterThanOrEqual(Double(within), 0.99 * Double(both.count))
        XCTAssertGreaterThanOrEqual(Double(sameN), 0.95 * Double(refN.count))
        var bytes = Data(capacity: map.solutions.count * 12)
        for r in map.rotations {
            let e = r.euler
            for v in [e.x, e.y, e.z] { withUnsafeBytes(of: Float(v).bitPattern.littleEndian) { bytes.append(contentsOf: $0) } }
        }
        try bytes.write(to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("macTEM-F8-euler-ours.f32"))
        print("F8 ours euler float32 base64: \(bytes.base64EncodedString())")
    }

    func testMapPlumbingReportsProgressAndStopsOnCancel() async throws {
        let ref = try SEMParityReference.load("m4/hough-nickel-block")
        let input = try inputs()
        let indexer = try HoughIndexer(phases: [library(input.phases[0])],
                                       detector: HoughBandDetector(rows: 60, columns: 60, settings: settings(input)),
                                       projectionCenter: SIMD3(0.42, 0.21, 0.5))
        let patterns = try ref.array("block_corrected_patterns").values
        let seen = HoughSeen()
        let src: @Sendable (Int, Int) throws -> [Double] = { r, c in
            let q = r * 6 + c
            return Array(patterns[(q * 3600)..<((q + 1) * 3600)])
        }
        let map = try await indexer.indexMap(scanRows: 2, scanColumns: 6, progress: { seen.add($0) }, pattern: src)
        XCTAssertEqual(map.solutions.count, 12)
        XCTAssertEqual(seen.values, [0.5, 1])
        let task = Task { () async throws -> HoughIndexer.Map in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await indexer.indexMap(scanRows: 6, scanColumns: 6, pattern: src)
        }
        do {
            _ = try await task.value
            XCTFail("a cancelled map returned")
        } catch is CancellationError {}
        XCTAssertThrowsError(try indexer.index([0, 1, 2]))
    }
}

private nonisolated final class HoughSeen: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Double] = []
    func add(_ v: Double) { lock.withLock { stored.append(v) } }
    var values: [Double] { lock.withLock { stored } }
}
