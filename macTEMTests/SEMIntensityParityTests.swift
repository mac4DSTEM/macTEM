//
//  SEMIntensityParityTests.swift
//  TEMCore's intensity and size stages of `PatternProcessing` (`rescaleIntensity` with and without percentiles,
//  `normalizeIntensity`, `downsample`) against kikuchipy 0.13.1's numbers: the bundles `m2/intensity-kikuchipy-h5ebsd` (the
//  nine-pattern fixture) and `m2/intensity-nickel-ebsd-large` (a 3 × 3 corner of the north-star scan) under tools/parity/sem.
//  Every stage starts from the bundle's `corrected` patterns (kikuchipy's static then dynamic subtract), so each is checked
//  alone; `chain` is the Patterns room's default run (rescale 2 to 98 %, bin 2) on top of them.
//  Tolerances are the bundles' own (docs/parity.md): uint8 within one grey level, normalised float32 within 1e-5 relative.
//  The ports reproduce kikuchipy's fastmath arithmetic, so the uint8 arrays are in fact exact; the test also counts that.
//  Red before the port: no `rescaleIntensity`. Red after a change to the percentile interpolation, the reciprocal product or
//  the float32 binning: whole grey levels move on hundreds of pixels.
//

import XCTest
import TEMCore

nonisolated final class SEMIntensityParityTests: XCTestCase {
    private static let cases = ["m2/intensity-kikuchipy-h5ebsd", "m2/intensity-nickel-ebsd-large"]
    private static let side = 60

    /// The nine corrected patterns of a bundle, as uint8 values.
    private func corrected(_ ref: SEMParityReference) throws -> [[UInt8]] {
        let c = try ref.array("corrected")
        XCTAssertEqual(c.shape, [3, 3, Self.side, Self.side])
        let pixels = Self.side * Self.side
        return (0..<9).map { i in c.values[i * pixels..<(i + 1) * pixels].map { UInt8($0) } }
    }

    /// Runs `stage` on every pattern, compares with the bundle's array at its tolerance and returns how many uint8 values differ.
    @discardableResult
    private func check(_ ref: SEMParityReference, _ name: String, shape: [Int],
                       file: StaticString = #filePath, line: UInt = #line, _ stage: ([UInt8]) throws -> [Double]) throws -> Int {
        let expected = try ref.array(name)
        let ours = try corrected(ref).flatMap { try stage($0) }
        SEMAssertParity(ours, expected, shape: shape, file: file, line: line)
        return zip(ours, expected.values).filter { $0 != $1 }.count
    }

    func testRescaleIntensityMatchesKikuchipyExactly() throws {
        for name in Self.cases {
            let ref = try SEMParityReference.load(name)
            let shape = [3, 3, Self.side, Self.side]
            let plain = try check(ref, "rescaled", shape: shape) { try PatternProcessing.rescaleIntensity($0).map(Double.init) }
            let percentiles = (ref.values["rescale_percentiles"] as? [Double]) ?? [2, 98]
            XCTAssertEqual(percentiles, [2, 98], name)
            let clipped = try check(ref, "rescaled_percentiles", shape: shape) {
                try PatternProcessing.rescaleIntensity($0, percentiles: (percentiles[0], percentiles[1])).map(Double.init)
            }
            XCTAssertEqual(plain, 0, "\(name): rescaled differs from kikuchipy's in \(plain) values")
            XCTAssertEqual(clipped, 0, "\(name): rescaled with percentiles differs in \(clipped) values")
        }
    }

    func testNormalizeIntensityMatchesKikuchipy() throws {
        for name in Self.cases {
            let ref = try SEMParityReference.load(name)
            let shape = [3, 3, Self.side, Self.side]
            try check(ref, "normalized", shape: shape) {
                try PatternProcessing.normalizeIntensity($0.map(Double.init)).map(Double.init)
            }
            try check(ref, "normalized_std2_sqrt", shape: shape) {
                try PatternProcessing.normalizeIntensity($0.map(Double.init), numStd: 2, divideBySquareRoot: true).map(Double.init)
            }
        }
    }

    func testDownsampleMatchesKikuchipyExactly() throws {
        for name in Self.cases {
            let ref = try SEMParityReference.load(name)
            for k in [2, 3] {
                let n = Self.side / k
                let off = try check(ref, "downsampled_\(k)", shape: [3, 3, n, n]) {
                    try PatternProcessing.downsample($0, rows: Self.side, columns: Self.side, factor: k).map(Double.init)
                }
                XCTAssertEqual(off, 0, "\(name): downsampled by \(k) differs in \(off) values")
            }
        }
    }

    /// The room's default chain after the backgrounds: rescale 2 to 98 %, then bin 2.
    func testRoomChainMatchesKikuchipy() throws {
        for name in Self.cases {
            let ref = try SEMParityReference.load(name)
            let off = try check(ref, "chain", shape: [3, 3, Self.side / 2, Self.side / 2]) {
                let r = try PatternProcessing.rescaleIntensity($0, percentiles: (2, 98))
                return try PatternProcessing.downsample(r, rows: Self.side, columns: Self.side, factor: 2).map(Double.init)
            }
            XCTAssertEqual(off, 0, "\(name): chain differs in \(off) values")
        }
    }

    /// numpy's linear percentile on small cases worked by hand: [1, 2, 3, 4] at 50 % is 2.5, at 2 % is 1.06, at 100 % is 4.
    func testPercentileIsNumpysLinearRule() throws {
        let v: [Double] = [4, 1, 3, 2]
        XCTAssertEqual(try PatternProcessing.percentile(v, 50), 2.5)
        XCTAssertEqual(try PatternProcessing.percentile(v, 2), 1.06, accuracy: 1e-12)
        XCTAssertEqual(try PatternProcessing.percentile(v, 0), 1)
        XCTAssertEqual(try PatternProcessing.percentile(v, 100), 4)
        XCTAssertThrowsError(try PatternProcessing.percentile(v, 101))
        XCTAssertThrowsError(try PatternProcessing.percentile([], 50))
    }

    func testRefusals() {
        let flat = [UInt8](repeating: 7, count: 16)
        XCTAssertThrowsError(try PatternProcessing.rescaleIntensity(flat)) { XCTAssertEqual($0 as? PatternProcessing.Error, .nonFinite) }
        XCTAssertThrowsError(try PatternProcessing.normalizeIntensity(flat.map(Double.init))) { XCTAssertEqual($0 as? PatternProcessing.Error, .nonFinite) }
        XCTAssertThrowsError(try PatternProcessing.downsample([UInt8](repeating: 1, count: 15), rows: 3, columns: 5, factor: 2)) {
            XCTAssertEqual($0 as? PatternProcessing.Error, .parameter("factor"))
        }
        XCTAssertEqual(try PatternProcessing.downsample(flat, rows: 4, columns: 4, factor: 1), flat)
    }
}
