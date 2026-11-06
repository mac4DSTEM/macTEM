//
//  SEMParityHarnessTests.swift
//  The parity harness of the SEM program checked on its own, before any port uses it: every committed bundle under
//  tools/parity/sem/references loads with its arrays intact (sha256, byte count, shape), every fixture is the file its
//  checksum names, the comparison accepts within tolerance and refuses beyond it, and every case is named in
//  docs/sem/north-star.md so a reference without a stated figure cannot slip in.
//
//  THE TRUTH: the manifests and SHA256SUMS the Python side wrote (tools/parity/sem/emit.py, make_fixtures.py). Nothing here
//  makes a number; the comparison is numpy's assert_allclose rule restated.
//

import CryptoKit
import Foundation
import XCTest

nonisolated final class SEMParityHarnessTests: XCTestCase {

    /// Mutation: edit any .bin by one byte, or a manifest's shape - red, naming the case and array.
    func testEveryCommittedBundleLoadsIntact() throws {
        let cases = try SEMParityReference.allCases()
        XCTAssertGreaterThanOrEqual(cases.count, 20, "tools/parity/sem/references holds the milestone-1 bundles")
        for name in cases {
            let ref = try SEMParityReference.load(name)
            XCTAssertEqual(ref.manifest.milestone, Int(name.dropFirst().prefix(1)), "\(name): milestone folder and manifest agree")
            XCTAssertFalse(ref.manifest.inputs.isEmpty, "\(name): names its input")
            XCTAssertNotNil(ref.manifest.stack["python"] ?? nil, "\(name): records the Python it was emitted with")
            for arrayName in ref.manifest.arrays.keys.sorted() {
                let a = try ref.array(arrayName)
                XCTAssertEqual(a.values.count, a.shape.reduce(1, *), "\(name)/\(arrayName): element count is the shape's product")
                XCTAssertFalse(a.values.contains { $0.isNaN }, "\(name)/\(arrayName): no NaN in a reference")
            }
        }
    }

    /// Every fixture is the file tools/parity/sem/fixtures/SHA256SUMS names (a reader reference is only as good as its input).
    func testEveryFixtureMatchesItsChecksum() throws {
        let root = SEMParityReference.fixturesRoot
        let sums = try String(contentsOf: root.appendingPathComponent("SHA256SUMS"), encoding: .utf8)
        var checked = 0
        for line in sums.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            let data = try Data(contentsOf: root.appendingPathComponent(parts[1]))
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(digest, parts[0], "fixtures/\(parts[1])")
            checked += 1
        }
        XCTAssertGreaterThanOrEqual(checked, 16)
    }

    /// The inputs every committed bundle names are the fixtures (sha256 in the manifest), where they are present.
    func testBundleInputsAreTheFixtures() throws {
        for name in try SEMParityReference.allCases() {
            let ref = try SEMParityReference.load(name)
            for (i, input) in ref.manifest.inputs.enumerated() {
                guard let url = ref.inputURL(i) else {
                    XCTFail("\(name): input \(input.path) is neither fixtures/ nor sem-data/")
                    continue
                }
                guard input.path.hasPrefix("fixtures/") || FileManager.default.fileExists(atPath: url.path) else { continue }
                let digest = SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
                XCTAssertEqual(digest, input.sha256, "\(name): \(input.path)")
            }
        }
    }

    func testCompareAcceptsWithinToleranceAndRefusesBeyond() {
        let ref = [1.0, 2.0, 3.0, -4.0]
        XCTAssertNil(SEMParityCompare.mismatch(name: "x", actual: ref, expected: ref, rtol: 0, atol: 0))
        XCTAssertNil(SEMParityCompare.mismatch(name: "x", actual: [1.0, 2.0, 3.0, -4.0 * (1 + 1e-8)], expected: ref, rtol: 1e-7, atol: 0))
        XCTAssertNil(SEMParityCompare.mismatch(name: "x", actual: [1.9, 2.0, 3.0, -4.0], expected: ref, rtol: 0, atol: 1))
        let exact = SEMParityCompare.mismatch(name: "x", actual: [1.0, 2.0, 3.0000001, -4.0], expected: ref, rtol: 0, atol: 0)
        XCTAssertEqual(exact?.count, 1)
        XCTAssertEqual(exact?.worstIndex, 2)
        let rel = SEMParityCompare.mismatch(name: "x", actual: [1.0, 2.0, 3.0, -4.0 * (1 + 1e-6)], expected: ref, rtol: 1e-7, atol: 0)
        XCTAssertEqual(rel?.worstIndex, 3)
        XCTAssertNotNil(SEMParityCompare.mismatch(name: "x", actual: [1.0, 2.0, 3.0], expected: ref, rtol: 1, atol: 1), "a short result is a mismatch")
        XCTAssertNotNil(SEMParityCompare.mismatch(name: "x", actual: [1.0, .nan, 3.0, -4.0], expected: ref, rtol: 1, atol: 1), "NaN against a number is a mismatch")
        XCTAssertNil(SEMParityCompare.mismatch(name: "x", actual: [.nan], expected: [.nan], rtol: 0, atol: 0), "NaN matches NaN")
    }

    /// The loader decodes each dtype the writer allows, little-endian, in C order.
    func testDecodeEveryDtype() throws {
        let f32 = Data([0x00, 0x00, 0x80, 0x3f, 0x00, 0x00, 0x00, 0xc0])           // 1.0, -2.0
        XCTAssertEqual(try SEMParityReference.decode(f32, dtype: "float32", count: 2, label: "t"), [1.0, -2.0])
        let f64 = Data([0, 0, 0, 0, 0, 0, 0xf0, 0x3f])                               // 1.0
        XCTAssertEqual(try SEMParityReference.decode(f64, dtype: "float64", count: 1, label: "t"), [1.0])
        XCTAssertEqual(try SEMParityReference.decode(Data([7, 255]), dtype: "uint8", count: 2, label: "t"), [7, 255])
        XCTAssertEqual(try SEMParityReference.decode(Data([0x01, 0x02]), dtype: "uint16", count: 1, label: "t"), [513])
        XCTAssertEqual(try SEMParityReference.decode(Data([0xff, 0xff, 0xff, 0xff]), dtype: "int32", count: 1, label: "t"), [-1])
        XCTAssertEqual(try SEMParityReference.decode(Data([2, 0, 0, 0, 0, 0, 0, 0]), dtype: "int64", count: 1, label: "t"), [2])
        XCTAssertThrowsError(try SEMParityReference.decode(Data([1, 2, 3]), dtype: "uint16", count: 2, label: "t"), "a short file")
        XCTAssertThrowsError(try SEMParityReference.decode(Data([1]), dtype: "float16", count: 1, label: "t"), "an unknown dtype")
    }

    /// A bundle's values are what a port reads for its claims: the small Ni scan's shapes and detector as kikuchipy states them.
    func testTheSmallNickelReferenceStatesItsGeometry() throws {
        let ref = try SEMParityReference.load("m1/read-kikuchipy-h5ebsd")
        XCTAssertEqual(ref.values["navigation_shape_rc"] as? [Int], [3, 3])
        XCTAssertEqual(ref.values["signal_shape_rc"] as? [Int], [60, 60])
        XCTAssertEqual(ref.values["dtype"] as? String, "uint8")
        let detector = ref.values["detector"] as? [String: Any]
        XCTAssertEqual(detector?["sample_tilt"] as? Double, 70)
        XCTAssertEqual(ref.manifest.reference.package, "kikuchipy")
        let first = try ref.array("first_pattern")
        XCTAssertEqual(first.shape, [60, 60])
        XCTAssertTrue(first.rtol == 0 && first.atol == 0, "a reader's pattern is exact")
        let mean = try ref.array("pattern_mean")
        XCTAssertEqual(mean.shape, [3, 3])
        XCTAssertEqual(mean.rtol, 1e-7)
    }

    /// Every committed case is named in docs/sem/north-star.md: a reference without a stated figure and tolerance is not a reference.
    func testEveryCaseIsNamedInTheNorthStar() throws {
        let doc = SEMParityReference.harnessRoot.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/sem/north-star.md")
        let text = try String(contentsOf: doc, encoding: .utf8)
        for name in try SEMParityReference.allCases() {
            XCTAssertTrue(text.contains("`\(name)`"), "docs/sem/north-star.md names \(name)")
        }
    }
}
