//
//  SEMQualityParityTests.swift
//  TEMCore's `PatternQuality` (image quality and average neighbour dot product maps of an EBSD scan) against kikuchipy 0.13.1:
//  the bundles `m2/quality-kikuchipy-h5ebsd` (every option on the 3 x 3 nickel fixture) and `m2/quality-nickel-ebsd-large`
//  (north-star figure F3 on the shipped demo scan). The port is fed exactly kikuchipy's input (the committed corrected
//  patterns, or the raw patterns through the h5ebsd reader) and must match within the bundle's rtol 1e-5. The F3 chain test
//  runs the app's own background removal first (PatternProcessing, within one grey level of kikuchipy, D-SEM-18) and holds
//  the maps to the bound that difference allows (docs/parity.md, "Pattern quality").
//  Red before the port: no `PatternQuality` type. Red after a change to the frequency weights, the normalisation, the window
//  mask or the edge rule: the maps move by far more than 1e-5.
//

import CryptoKit
import FormatoCore
import Foundation
import TEMCore
import XCTest

nonisolated final class SEMQualityParityTests: XCTestCase {

    /// The shipped demo scan (DemoData/), the same file the large bundle was emitted from (sha256 in its manifest).
    private static let demoScan = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("DemoData/nickel_ebsd_large/patterns_v2.h5")

    /// A flat pattern stack (scan row-major, then detector row-major) as the map functions' pattern source.
    private func source(_ values: [Double], scanColumns: Int, pixels: Int) -> @Sendable (Int, Int) throws -> [Double] {
        { r, c in
            let start = (r * scanColumns + c) * pixels
            return Array(values[start..<(start + pixels)])
        }
    }

    private func iqMap(_ values: [Double], shape: [Int], normalize: Bool = true) async throws -> [Double] {
        try await PatternQuality.imageQualityMap(scanRows: shape[0], scanColumns: shape[1], patternRows: shape[2], patternColumns: shape[3],
                                                 normalize: normalize, pattern: source(values, scanColumns: shape[1], pixels: shape[2] * shape[3]))
    }

    private func adpMap(_ values: [Double], shape: [Int], window: PatternQuality.NeighbourWindow = .nearest,
                        zeroMean: Bool = true, normalize: Bool = true) async throws -> [Double] {
        try await PatternQuality.averageNeighbourDotProductMap(scanRows: shape[0], scanColumns: shape[1], patternPixels: shape[2] * shape[3],
                                                               window: window, zeroMean: zeroMean, normalize: normalize,
                                                               pattern: source(values, scanColumns: shape[1], pixels: shape[2] * shape[3]))
    }

    // MARK: - Pieces

    func testFrequencyVectorsAreKikuchipysExactly() throws {
        let ref = try SEMParityReference.load("m2/quality-kikuchipy-h5ebsd")
        SEMAssertParity(PatternQuality.frequencyVectors(rows: 60, columns: 60), try ref.array("frequency_vectors"), shape: [60, 60])
        // A small non-square shape by hand: kikuchipy's lines are [1, -1] (2 rows) and [1, -2, -1] (3 columns).
        XCTAssertEqual(PatternQuality.frequencyVectors(rows: 2, columns: 3), [1 + 1 - 1, 1 + 4 - 1, 1 + 1 - 1, 1 + 1 - 1, 1 + 4 - 1, 1 + 1 - 1])
    }

    func testCircularWindowsAreKikuchipysMasks() throws {
        let ref = try SEMParityReference.load("m2/quality-kikuchipy-h5ebsd")
        let windows = try XCTUnwrap(ref.values["windows"] as? [String: [[Int]]])
        let cases: [String: PatternQuality.NeighbourWindow] = [
            "rect3": .init(rows: 3, columns: 3, circular: false), "circ5": .init(rows: 5, columns: 5, circular: true),
            "rect1x3": .init(rows: 1, columns: 3, circular: false),
        ]
        for (name, window) in cases {
            let expected = try XCTUnwrap(windows[name], name).flatMap { $0 }.map { $0 != 0 }
            XCTAssertEqual(window.mask, expected, name)
        }
        XCTAssertEqual(PatternQuality.NeighbourWindow.nearest.mask, [false, true, false, true, true, true, false, true, false])
        XCTAssertEqual(PatternQuality.NeighbourWindow.nearest.offsets.map { [$0.row, $0.column] }, [[-1, 0], [0, -1], [0, 1], [1, 0]])
    }

    // MARK: - Every option on the 3 x 3 fixture (kikuchipy's corrected patterns as input)

    func testImageQualityMatchesKikuchipyOnTheFixture() async throws {
        let ref = try SEMParityReference.load("m2/quality-kikuchipy-h5ebsd")
        let patterns = try ref.array("corrected_patterns")
        try await SEMAssertParity(iqMap(patterns.values, shape: patterns.shape), ref.array("iq"), shape: [3, 3])
        try await SEMAssertParity(iqMap(patterns.values, shape: patterns.shape, normalize: false), ref.array("iq_unnormalized"), shape: [3, 3])
    }

    func testAverageDotProductMatchesKikuchipyForEveryOption() async throws {
        let ref = try SEMParityReference.load("m2/quality-kikuchipy-h5ebsd")
        let patterns = try ref.array("corrected_patterns")
        let p = patterns.values, shape = patterns.shape
        try await SEMAssertParity(adpMap(p, shape: shape), ref.array("adp"), shape: [3, 3])
        try await SEMAssertParity(adpMap(p, shape: shape, window: .init(rows: 3, columns: 3, circular: false)), ref.array("adp_rect3"))
        try await SEMAssertParity(adpMap(p, shape: shape, window: .init(rows: 5, columns: 5, circular: true)), ref.array("adp_circ5"))
        try await SEMAssertParity(adpMap(p, shape: shape, window: .init(rows: 1, columns: 3, circular: false)), ref.array("adp_rect1x3"))
        try await SEMAssertParity(adpMap(p, shape: shape, zeroMean: false), ref.array("adp_no_zero_mean"))
        try await SEMAssertParity(adpMap(p, shape: shape, normalize: false), ref.array("adp_no_normalize"))
    }

    func testRawFixtureMapsMatchKikuchipyThroughTheReader() async throws {
        let ref = try SEMParityReference.load("m2/quality-kikuchipy-h5ebsd")
        let url = try XCTUnwrap(ref.inputURL())
        let all = try EBSDH5Reader.read(url: url).allPatterns()
        try await SEMAssertParity(iqMap(all.doubles(), shape: all.shape), ref.array("raw_iq"))
        try await SEMAssertParity(adpMap(all.doubles(), shape: all.shape), ref.array("raw_adp"))
    }

    // MARK: - Figure F3 on the shipped demo scan

    func testDemoScanIsTheBundlesInput() throws {
        let ref = try SEMParityReference.load("m2/quality-nickel-ebsd-large")
        let data = try Data(contentsOf: Self.demoScan)
        let digest = SHA256Hex.of(data)
        XCTAssertEqual(digest, ref.manifest.inputs.first?.sha256)
    }

    func testBlockOfCorrectedPatternsMatchesKikuchipy() async throws {
        let ref = try SEMParityReference.load("m2/quality-nickel-ebsd-large")
        let block = try ref.array("block_corrected_patterns")
        try await SEMAssertParity(iqMap(block.values, shape: block.shape), ref.array("block_iq"), shape: [6, 6])
        try await SEMAssertParity(adpMap(block.values, shape: block.shape), ref.array("block_adp"), shape: [6, 6])
    }

    func testWholeRawScanMapsMatchKikuchipy() async throws {
        let ref = try SEMParityReference.load("m2/quality-nickel-ebsd-large")
        let all = try EBSDH5Reader.read(url: Self.demoScan).allPatterns()
        XCTAssertEqual(all.shape, [55, 75, 60, 60])
        let values = all.doubles()
        try await SEMAssertParity(iqMap(values, shape: all.shape), ref.array("raw_iq"), shape: [55, 75])
        try await SEMAssertParity(adpMap(values, shape: all.shape), ref.array("raw_adp"), shape: [55, 75])
    }

    /// F3 end to end: the shipped scan, the app's static then dynamic background (kikuchipy's docs chain), then both maps,
    /// against kikuchipy's F3 maps. Bound: rtol 1e-2 for IQ and 5e-3 for ADP (docs/parity.md: the one-grey-level background
    /// differences of D-SEM-18 move the maps; a float64 replica of this chain measured 5.3e-3 and 1.1e-3). The maps are
    /// written to $TMPDIR as float32 and printed as base64 for tools/parity/sem/quality_figure.py --ours-iq / --ours-adp.
    func testFigureF3QualityMapsAfterBackgroundRemoval() async throws {
        let ref = try SEMParityReference.load("m2/quality-nickel-ebsd-large")
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
        let shape = [rows, columns, pr, pc]
        let iq = try await iqMap(corrected, shape: shape)
        let adp = try await adpMap(corrected, shape: shape)
        let iqRef = try ref.array("iq"), adpRef = try ref.array("adp")
        let iqWorst = zip(iq, iqRef.values).map { abs($0 - $1) / abs($1) }.max() ?? .nan
        let adpWorst = zip(adp, adpRef.values).map { abs($0 - $1) / abs($1) }.max() ?? .nan
        print("F3 chain: IQ max rel \(iqWorst), ADP max rel \(adpWorst)")
        if let m = SEMParityCompare.mismatch(name: "F3 iq", actual: iq, expected: iqRef.values, rtol: 1e-2, atol: 0) { XCTFail(m.description) }
        if let m = SEMParityCompare.mismatch(name: "F3 adp", actual: adp, expected: adpRef.values, rtol: 5e-3, atol: 0) { XCTFail(m.description) }
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        for (name, map) in [("iq", iq), ("adp", adp)] {
            var bytes = Data(capacity: map.count * 4)
            for v in map { withUnsafeBytes(of: Float(v).bitPattern.littleEndian) { bytes.append(contentsOf: $0) } }
            try bytes.write(to: tmp.appendingPathComponent("macTEM-F3-\(name)-ours.f32"))
            print("F3 ours \(name) float32 base64: \(bytes.base64EncodedString())")
        }
    }

    // MARK: - Map plumbing

    func testProgressReachesOneAndCancellationStops() async throws {
        let ref = try SEMParityReference.load("m2/quality-kikuchipy-h5ebsd")
        let patterns = try ref.array("corrected_patterns")
        let seen = Seen()
        _ = try await PatternQuality.imageQualityMap(scanRows: 3, scanColumns: 3, patternRows: 60, patternColumns: 60,
                                                     progress: { seen.add($0) },
                                                     pattern: source(patterns.values, scanColumns: 3, pixels: 3600))
        XCTAssertEqual(seen.values, [1.0 / 3, 2.0 / 3, 1])
        let src = source(patterns.values, scanColumns: 3, pixels: 3600)
        let task = Task { () async throws -> [Double] in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await PatternQuality.averageNeighbourDotProductMap(scanRows: 3, scanColumns: 3, patternPixels: 3600, pattern: src)
        }
        do {
            _ = try await task.value
            XCTFail("a cancelled map returned")
        } catch is CancellationError {}
    }

    func testFlatPatternGivesNaNAndIsSkippedByItsNeighbours() async throws {
        // Two 1 x 4 patterns side by side and a flat one: the flat one has no direction (NaN), the others average only
        // over finite dot products, as np.nanmean does.
        let a: [Double] = [0, 1, 2, 3], b: [Double] = [3, 2, 1, 0], flat: [Double] = [5, 5, 5, 5]
        let map = try await adpMap(a + flat + b, shape: [1, 3, 1, 4])
        XCTAssertTrue(map[1].isNaN)
        XCTAssertTrue(map[0].isNaN)   // its only neighbour is the flat one
        XCTAssertTrue(map[2].isNaN)
        let pair = try await adpMap(a + b, shape: [1, 2, 1, 4])
        XCTAssertEqual(pair[0], -1, accuracy: 1e-15)
        XCTAssertEqual(pair[1], -1, accuracy: 1e-15)
    }
}

private nonisolated final class Seen: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Double] = []
    func add(_ v: Double) { lock.withLock { stored.append(v) } }
    var values: [Double] { lock.withLock { stored } }
}

private nonisolated enum SHA256Hex {
    static func of(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
