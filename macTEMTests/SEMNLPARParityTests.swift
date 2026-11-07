//
//  SEMNLPARParityTests.swift
//  TEMCore's `NLPAR` (non-local pattern averaging, Brewick, Wright and Rowenhorst 2019) against PyEBSDIndex 0.3.10.1:
//  `tools/parity/sem/emit.py` cases `m2/nlpar-kikuchipy-h5ebsd` (the committed 3 x 3 scan: mask, tiles, noise estimate,
//  normalised distances, λ) and `m2/nlpar-nickel-ebsd-large` (all 4125 patterns of nickel_ebsd_large, read from the shipped
//  demo file: the same plus the denoised patterns at the corner and across pyebsdindex's tile seam, and every pattern's mean).
//  Tolerances (docs/parity.md): mask and tiles exact; σ and the denoised patterns 1e-5 relative (float32, the harness rule;
//  the port keeps pyebsdindex's float32 arithmetic, so σ is expected bit-identical); λ 1e-4 relative (the brief).
//  Red before the port: no `NLPAR` type. Red after a change to the tile split, the saturation level, a float32/float64 step
//  of the distance or the Nelder–Mead moves: σ, the distances or λ move beyond those bounds.
//

import CryptoKit
import FormatoCore
import TEMCore
import XCTest

nonisolated final class SEMNLPARParityTests: XCTestCase {

    private static let repoRoot = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath()
        .deletingLastPathComponent().deletingLastPathComponent()

    /// The scan of an h5ebsd file as NLPAR's float32 input (pyebsdindex's `read_data(convertToFloat=True)`).
    private func scan(of url: URL) throws -> NLPAR.Scan {
        let dataset = try EBSDH5Reader.read(url: url)
        let values = try dataset.allPatterns().doubles().map { Float($0) }
        return try NLPAR.Scan(rows: dataset.scanRows, columns: dataset.scanColumns, patternRows: dataset.patternRows,
                              patternColumns: dataset.patternColumns, values: values)
    }

    private func worstRelative(_ a: [Double], _ b: [Double]) -> Double {
        zip(a, b).map { abs($0 - $1) / max(abs($1), 1e-30) }.max() ?? 0
    }

    private func assertTiles(_ ref: SEMParityReference, _ key: String, _ tiles: (columns: [Range<Int>], rows: [Range<Int>])) throws {
        let t = try XCTUnwrap(ref.values[key] as? [String: Any], key)
        let columns = try XCTUnwrap(t["columns"] as? [[Int]], key).map { $0[0]..<$0[1] }
        let rows = try XCTUnwrap(t["rows"] as? [[Int]], key).map { $0[0]..<$0[1] }
        XCTAssertEqual(tiles.columns, columns, "\(key) columns")
        XCTAssertEqual(tiles.rows, rows, "\(key) rows")
    }

    /// Mask, tiles, the noise estimate and λ against one bundle; returns the estimate.
    private func checkEstimate(_ ref: SEMParityReference, _ s: NLPAR.Scan, searchRadius: Int) throws -> (NLPAR.NoiseEstimate, [Double]) {
        let mask = NLPAR.autoMask(patternRows: s.patternRows, patternColumns: s.patternColumns)
        SEMAssertParity(mask.map { Double($0) }, try ref.array("automask"))
        try assertTiles(ref, "sigma_tiles", NLPAR.tiles(rows: s.rows, columns: s.columns, patternRows: s.patternRows,
                                                         patternColumns: s.patternColumns, overlap: 1))
        try assertTiles(ref, "nlpar_tiles", NLPAR.tiles(rows: s.rows, columns: s.columns, patternRows: s.patternRows,
                                                         patternColumns: s.patternColumns, overlap: searchRadius))
        let estimate = try NLPAR.estimateNoise(s)
        let sigmaRef = try ref.array("sigma")
        let sigma = estimate.sigma.map { Double($0) }
        SEMAssertParity(sigma, sigmaRef, shape: [s.rows, s.columns])
        let distRef = try ref.array("distances")
        SEMAssertParity(estimate.distances.map { Double($0) }, distRef, shape: [s.rows, s.columns, 9])
        let lambdas = NLPAR.optimiseLambda(estimate)
        let lambdaRef = try ref.array("lambdas")
        SEMAssertParity(lambdas, lambdaRef)
        print("NLPAR \(ref.manifest.caseName): sigma worst rel \(worstRelative(sigma, sigmaRef.values)), "
              + "lambdas \(lambdas) vs \(lambdaRef.values)")
        return (estimate, lambdas)
    }

    func testSmallScanNoiseEstimateAndLambdaMatchPyebsdindex() throws {
        let ref = try SEMParityReference.load("m2/nlpar-kikuchipy-h5ebsd")
        let s = try scan(of: try XCTUnwrap(ref.inputURL()))
        XCTAssertEqual([s.rows, s.columns], [3, 3])
        _ = try checkEstimate(ref, s, searchRadius: 1)
    }

    func testNickelNLPARMatchesPyebsdindex() throws {
        let ref = try SEMParityReference.load("m2/nlpar-nickel-ebsd-large")
        let url = Self.repoRoot.appendingPathComponent("DemoData/nickel_ebsd_large/patterns_v2.h5")
        let digest = SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(digest, ref.manifest.inputs[0].sha256, "the shipped demo file is the reference's input")
        let s = try scan(of: url)
        let start = Date()
        let result = try NLPAR.run(s, searchRadius: 3)
        let seconds = Date().timeIntervalSince(start)
        let (estimate, lambdas) = try checkEstimate(ref, s, searchRadius: 3)
        XCTAssertEqual(result.estimate, estimate)
        XCTAssertEqual(result.lambdas, lambdas)
        SEMAssertParity(result.lambda, ref, scalar: "lambda")

        let out = result.denoised
        XCTAssertEqual([out.rows, out.columns, out.patternRows, out.patternColumns], [55, 75, 60, 60])
        let px = out.pixels
        let means = (0..<(out.rows * out.columns)).map { p in
            out.values[(p * px)..<((p + 1) * px)].reduce(0.0) { $0 + Double($1) } / Double(px)
        }
        let meanRef = try ref.array("denoised_mean")
        SEMAssertParity(means, meanRef, shape: [55, 75])
        var worst = 0.0
        for (name, r0, r1, c0, c1) in [("denoised_corner", 0, 3, 0, 3), ("denoised_seam", 26, 29, 33, 40)] {
            var block: [Double] = []
            for r in r0..<r1 {
                for c in c0..<c1 {
                    let p = (r * out.columns + c) * px
                    block.append(contentsOf: out.values[p..<(p + px)].map { Double($0) })
                }
            }
            let blockRef = try ref.array(name)
            SEMAssertParity(block, blockRef, shape: [r1 - r0, c1 - c0, 60, 60])
            worst = max(worst, worstRelative(block, blockRef.values))
        }
        print("NLPAR nickel: lambda \(result.lambda), denoised blocks worst rel \(worst), "
              + "means worst rel \(worstRelative(means, meanRef.values)), run \(String(format: "%.2f", seconds)) s")
    }

    /// With λ → ∞ every weight is one, so each pattern becomes the plain mean of its (shifted) search window: the averaging
    /// and the window shift checked without a reference: on 3 x 4 (two column tiles, the window shifted at the edges) and on
    /// 3 x 3, whose column tiles are narrower than the window (run as one tile).
    func testHugeLambdaAveragesTheWindow() throws {
        for (rows, columns) in [(3, 4), (3, 3)] { try checkWindowMean(rows: rows, columns: columns) }
    }

    private func checkWindowMean(rows: Int, columns: Int) throws {
        let h = 4, w = 4, px = h * w
        let values = (0..<(rows * columns * px)).map { Float(($0 * 37) % 101) }
        let s = try NLPAR.Scan(rows: rows, columns: columns, patternRows: h, patternColumns: w, values: values)
        let sigma = [Float](repeating: 1, count: rows * columns)
        let out = try NLPAR.denoise(s, lambda: 1e6, sigma: sigma, searchRadius: 1)
        for r in 0..<rows {
            for c in 0..<columns {
                let r0 = min(max(r - 1, 0), rows - 3), c0 = min(max(c - 1, 0), columns - 3)
                for q in 0..<px {
                    var sum = 0.0
                    for rr in r0..<(r0 + 3) { for cc in c0..<(c0 + 3) { sum += Double(values[(rr * columns + cc) * px + q]) } }
                    XCTAssertEqual(Double(out.values[(r * columns + c) * px + q]), sum / 9, accuracy: 1e-3, "\(rows) x \(columns): (\(r), \(c)) pixel \(q)")
                }
            }
        }
    }

    func testRefusesAWindowLargerThanTheScanAndBadShapes() throws {
        let s = try NLPAR.Scan(rows: 3, columns: 3, patternRows: 2, patternColumns: 2, values: [Float](repeating: 1, count: 36))
        XCTAssertThrowsError(try NLPAR.denoise(s, lambda: 1, sigma: [Float](repeating: 1, count: 9), searchRadius: 2)) {
            XCTAssertEqual($0 as? NLPAR.Error, .parameter("search radius"))
        }
        XCTAssertThrowsError(try NLPAR.denoise(s, lambda: 0, sigma: [Float](repeating: 1, count: 9), searchRadius: 1)) {
            XCTAssertEqual($0 as? NLPAR.Error, .parameter("lambda"))
        }
        XCTAssertThrowsError(try NLPAR.denoise(s, lambda: 1, sigma: [1], searchRadius: 1)) { XCTAssertEqual($0 as? NLPAR.Error, .shape) }
        XCTAssertThrowsError(try NLPAR.Scan(rows: 2, columns: 2, patternRows: 2, patternColumns: 2, values: [1])) {
            XCTAssertEqual($0 as? NLPAR.Error, .shape)
        }
    }
}
