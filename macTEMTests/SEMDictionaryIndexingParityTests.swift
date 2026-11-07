//
//  SEMDictionaryIndexingParityTests.swift
//  TEMCore's dictionary indexing (`DictionaryIndexing`, figure F9) against kikuchipy 0.13.1's `EBSD.dictionary_indexing` in
//  tools/parity/sem/references/m4/:
//  - dictionary-indexing-kikuchipy-h5ebsd: the committed 3 x 3 nickel cut after kikuchipy's background chain (its corrected
//    patterns are in the bundle, so the input is kikuchipy's), indexed against the Ni 20 kV master pattern projected for the
//    m-3m cubochoric sample at 4° (11 935 patterns): NCC in float32 (the default) and float64, NDP, NCC with a circular signal
//    mask and a navigation mask, NCC in chunks of 1000;
//  - dictionary-indexing-nickel-ebsd-large: figure F9, the shipped 55 x 75 scan through the app's own background chain, and a
//    6 x 6 block of kikuchipy's corrected patterns (exact input on real data).
//  The dictionary is built here from the app's own sampling (`OrientationSampling`, parity m3/orientation-sampling) and projection
//  (`MasterPatternProjection`, parity m6/project-master-pattern-*), so the whole chain is the app's. Scores at the bundles'
//  tolerances (float32 runs rtol 1e-4, float64 runs 1e-5, F9's whole scan 2e-3 for D-SEM-18's one-grey-level background
//  differences); simulation indices exact except where two ranks' reference scores tie within twice the score tolerance.
//  Red before the port: no `DictionaryIndexing`. Red after: NCC without centring (scores move by 10 %), the norm left out, the
//  signal mask negated, the merge keeping the worst instead of the best, the chunk offset dropped (indices of later chunks wrong).
//

import Foundation
import FormatoCore
import TEMCore
import XCTest

nonisolated final class SEMDictionaryIndexingParityTests: XCTestCase {

    /// The shipped demo scan (DemoData/), the same file the large bundle was emitted from (sha256 in its manifest).
    private static let demoScan = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("DemoData/nickel_ebsd_large/patterns_v2.h5")

    /// The dictionary both bundles use: the master pattern, the sampled rotations, the detector and the patterns (float32 values).
    private struct NickelDictionary: Sendable {
        let master: EBSDMasterPattern
        let rotations: [SIMD4<Double>]
        let detector: EBSDDetectorGeometry
        let patterns: [Double]
        var pixels: Int { detector.rows * detector.columns }
    }

    private static let dictionary: Result<NickelDictionary, Swift.Error> = Result {
        let ref = try SEMParityReference.load("m4/dictionary-indexing-kikuchipy-h5ebsd")
        let master = try EMsoftMasterPatternReader.read(url: try XCTUnwrap(ref.inputURL(1)), projection: .lambert, hemisphere: .both)
        let group = try XCTUnwrap(PointGroup.named(try XCTUnwrap(ref.values["point_group"] as? String)))
        let resolution = try XCTUnwrap(ref.values["resolution"] as? Double)
        let rotations = try OrientationSampling.fundamental(resolution: resolution, pointGroup: group).map(\.q)
        let d = try XCTUnwrap(ref.values["detector"] as? [String: Any])
        let shape = try XCTUnwrap(d["shape"] as? [Int])
        let pc = try XCTUnwrap(d["pc"] as? [Double])
        let detector = EBSDDetectorGeometry(rows: shape[0], columns: shape[1], pixelSize: 1, binning: d["binning"] as? Int ?? 1,
                                            sampleTilt: try XCTUnwrap(d["sample_tilt"] as? Double),
                                            projectionCenters: [SIMD3(pc[0], pc[1], pc[2])])
        let patterns = try MasterPatternProjection.project(master: master, rotations: rotations, detector: detector, output: .float32).values
        return NickelDictionary(master: master, rotations: rotations, detector: detector, patterns: patterns)
    }

    private func dictionary() throws -> NickelDictionary { try Self.dictionary.get() }

    /// The ranks' simulation indices against the reference's: a difference only where the reference scores of that rank and a
    /// neighbouring one tie within `2 rtol`, or at the last rank where the score itself agrees (the next match is not in the
    /// bundle). Returns the number of tied swaps it let through.
    @discardableResult
    private func assertIndices(_ ours: [Int], _ ourScores: [Double], _ ref: SEMParityReference, _ run: String, keepN: Int,
                               rtol override: Double? = nil, file: StaticString = #filePath, line: UInt = #line) throws -> Int {
        let indices = try ref.array("\(run)_simulation_indices"), scores = try ref.array("\(run)_scores")
        XCTAssertEqual(ours.count, indices.values.count, "\(run): index count", file: file, line: line)
        let rtol = override ?? scores.rtol
        func tied(_ a: Double, _ b: Double) -> Bool { abs(a - b) <= 2 * rtol * max(abs(a), abs(b)) }
        var swaps = 0
        for row in 0 ..< (indices.values.count / keepN) {
            for r in 0 ..< keepN {
                let k = row * keepN + r
                guard ours[k] != Int(indices.values[k]) else { continue }
                let s = scores.values
                let ok = (r > 0 && tied(s[k], s[k - 1])) || (r < keepN - 1 && tied(s[k], s[k + 1])) || (r == keepN - 1 && tied(ourScores[k], s[k]))
                if ok { swaps += 1 } else {
                    XCTFail("\(run): point \(row) rank \(r): simulation index \(ours[k]), kikuchipy \(Int(indices.values[k])) (score \(s[k]))", file: file, line: line)
                }
            }
        }
        return swaps
    }

    /// The scores and indices of the points in the data, as the bundle keeps them.
    private func inData(_ r: DictionaryIndexing.Result) -> (scores: [Double], indices: [Int]) {
        var s = [Double](), i = [Int]()
        for p in 0 ..< r.pointCount where r.isInData[p] {
            s.append(contentsOf: r.scores[(p * r.keepN) ..< ((p + 1) * r.keepN)])
            i.append(contentsOf: r.simulationIndices[(p * r.keepN) ..< ((p + 1) * r.keepN)])
        }
        return (s, i)
    }

    /// A run's scores at the bundle's tolerance (or `rtol`) and its indices.
    private func checkRun(_ r: DictionaryIndexing.Result, _ ref: SEMParityReference, _ run: String, rtol: Double? = nil,
                          file: StaticString = #filePath, line: UInt = #line) throws {
        let (s, i) = inData(r)
        let scores = try ref.array("\(run)_scores")
        if let m = SEMParityCompare.mismatch(name: scores.name, actual: s, expected: scores.values, rtol: rtol ?? scores.rtol, atol: scores.atol) {
            XCTFail(m.description, file: file, line: line)
        }
        try assertIndices(i, s, ref, run, keepN: r.keepN, rtol: rtol, file: file, line: line)
    }

    private func small() throws -> (SEMParityReference, [Double], NickelDictionary) {
        let ref = try SEMParityReference.load("m4/dictionary-indexing-kikuchipy-h5ebsd")
        let d = try dictionary()
        XCTAssertEqual(d.rotations.count, ref.values["dictionary_size"] as? Int, "orix's sample size")
        return (ref, try ref.array("experimental").values, d)
    }

    // MARK: - Small cut, kikuchipy's input

    /// The default run (NCC, keep_n 20) on the CPU in float64 against kikuchipy's float32 run, and its float64 run.
    /// Mutation: NCC without the centring, the dictionary's norm left out, the merge's comparison reversed.
    func testNCCMatchesKikuchipyInFloat32AndFloat64() throws {
        let (ref, exp, d) = try small()
        let r = try DictionaryIndexing.index(experimental: exp, navigationShape: [3, 3], dictionary: d.patterns, rotations: d.rotations,
                                             pixels: d.pixels, options: .init(metric: .ncc, keepN: 20, backend: .cpu))
        XCTAssertEqual(r.keepN, 20)
        XCTAssertEqual(r.isInData, Array(repeating: true, count: 9))
        try checkRun(r, ref, "ncc")
        try checkRun(r, ref, "ncc_float64")
    }

    /// NDP: unit norm without centring. Mutation: NDP centred like NCC.
    func testNDPMatchesKikuchipy() throws {
        let (ref, exp, d) = try small()
        let r = try DictionaryIndexing.index(experimental: exp, navigationShape: [3, 3], dictionary: d.patterns, rotations: d.rotations,
                                             pixels: d.pixels, options: .init(metric: .ndp, keepN: 20, backend: .cpu))
        try checkRun(r, ref, "ndp")
    }

    /// A circular signal mask and two points left out by the navigation mask. Mutation: the masks negated, a masked point indexed.
    func testSignalAndNavigationMasksMatchKikuchipy() throws {
        let (ref, exp, d) = try small()
        let signal = try ref.array("signal_mask").values.map { $0 != 0 }
        let navigation = try ref.array("navigation_mask").values.map { $0 != 0 }
        let r = try DictionaryIndexing.index(experimental: exp, navigationShape: [3, 3], dictionary: d.patterns, rotations: d.rotations,
                                             pixels: d.pixels, options: .init(keepN: 20, signalMask: signal, navigationMask: navigation, backend: .cpu))
        XCTAssertEqual(r.isInData.map { $0 ? 1.0 : 0.0 }, try ref.array("ncc_masked_is_in_data").values)
        try checkRun(r, ref, "ncc_masked")
        for p in 0 ..< 9 where !r.isInData[p] {
            XCTAssertTrue(r.scores[p * 20].isNaN)
            XCTAssertEqual(r.simulationIndices[p * 20], -1)
            XCTAssertEqual(r.rotations[p * 20], SIMD4(1, 0, 0, 0))
        }
    }

    /// kikuchipy's chunked path (n_per_iteration 1000), and the result the same for any chunk size, the memory budget's included.
    /// Mutation: the chunk offset dropped, keep_n per chunk not clamped to the chunk.
    func testChunksGiveTheSameResult() throws {
        let (ref, exp, d) = try small()
        func run(_ per: Int?, budget: Int = 512 << 20) throws -> DictionaryIndexing.Result {
            try DictionaryIndexing.index(experimental: exp, navigationShape: [3, 3], dictionary: d.patterns, rotations: d.rotations, pixels: d.pixels,
                                         options: .init(keepN: 20, patternsPerIteration: per, memoryBudget: budget, backend: .cpu))
        }
        let whole = try run(nil)
        let chunked = try run(1000)
        try checkRun(chunked, ref, "ncc_chunked")
        XCTAssertEqual(chunked, whole)
        XCTAssertEqual(try run(7), whole)
        // A budget of a few patterns: chunks of (3600 + 9) doubles each.
        XCTAssertEqual(try run(nil, budget: 5 * 3609 * 8), whole)
        XCTAssertEqual(try DictionaryIndexing.chunkSize(.init(memoryBudget: 5 * 3609 * 8), experimental: 9, length: 3600, dictionary: 11935), 5)
    }

    /// The crystal map kikuchipy returns: the best match's rotation and Bunge angles, the coordinates, the score properties.
    /// Mutation: the rotation taken at rank 1, x and y swapped.
    func testCrystalMapOfTheResult() throws {
        let (ref, exp, d) = try small()
        let r = try DictionaryIndexing.index(experimental: exp, navigationShape: [3, 3], dictionary: d.patterns, rotations: d.rotations,
                                             pixels: d.pixels, options: .init(backend: .cpu))
        let quaternions = r.bestRotations.flatMap { [$0.x, $0.y, $0.z, $0.w] }
        // orix's sample against the port's: atol 1e-7 (m3/orientation-sampling), so the angles within 1e-6.
        if let m = SEMParityCompare.mismatch(name: "best_quaternions", actual: quaternions, expected: try ref.array("ncc_best_quaternions").values,
                                             rtol: 0, atol: 1e-7) { XCTFail(m.description) }
        let steps = try XCTUnwrap(ref.values["step_sizes"] as? [Double])
        let map = r.crystalMap(phase: EBSDPhase(id: 0, name: "ni", spaceGroup: 225, pointGroup: "m-3m"), stepSizes: steps)
        if let m = SEMParityCompare.mismatch(name: "best_euler", actual: map.euler.flatMap { [$0.x, $0.y, $0.z] },
                                             expected: try ref.array("ncc_best_euler").values, rtol: 0, atol: 1e-6) { XCTFail(m.description) }
        SEMAssertParity(try XCTUnwrap(map.x), try ref.array("ncc_x"))
        SEMAssertParity(try XCTUnwrap(map.y), try ref.array("ncc_y"))
        XCTAssertEqual(map.phaseIDs, Array(repeating: 0, count: 9))
        XCTAssertEqual(map.properties["scores"], r.bestScores)
        XCTAssertEqual(map.properties["simulation_indices"], r.bestSimulationIndices.map(Double.init))
        XCTAssertEqual(map.coordinateShape, [3, 3])
    }

    /// The dictionary projected chunk by chunk from the master pattern gives what the dictionary in memory gives.
    func testProjectingTheDictionaryInChunksMatchesTheDictionaryInMemory() throws {
        let (_, exp, d) = try small()
        let inMemory = try DictionaryIndexing.index(experimental: exp, navigationShape: [3, 3], dictionary: d.patterns, rotations: d.rotations,
                                                    pixels: d.pixels, options: .init(backend: .cpu))
        let projected = try DictionaryIndexing.index(experimental: exp, navigationShape: [3, 3], master: d.master, rotations: d.rotations,
                                                     detector: d.detector, options: .init(patternsPerIteration: 2500, backend: .cpu))
        XCTAssertEqual(projected, inMemory)
    }

    /// The float32 GPU product against the float64 CPU reference: scores within `DictionaryIndexingMetal.tolerance`, and against
    /// kikuchipy's float32 run. The dictionary projected on the GPU too (each pixel within `MasterPatternProjectionMetal.tolerance`,
    /// 1e-3, of the CPU's) against kikuchipy at rtol 1e-3. Skipped where the Mac has no Metal device.
    func testTheMetalPathMatchesTheCPUReference() throws {
        guard DictionaryIndexingMetal.isAvailable else { throw XCTSkip("no Metal device on this machine") }
        let (ref, exp, d) = try small()
        let cpu = try DictionaryIndexing.index(experimental: exp, navigationShape: [3, 3], dictionary: d.patterns, rotations: d.rotations,
                                               pixels: d.pixels, options: .init(backend: .cpu))
        let gpu = try DictionaryIndexing.index(experimental: exp, navigationShape: [3, 3], dictionary: d.patterns, rotations: d.rotations,
                                               pixels: d.pixels, options: .init(patternsPerIteration: 4000, backend: .metal))
        var worst = 0.0
        for (a, b) in zip(gpu.scores, cpu.scores) { worst = max(worst, abs(a - b)) }
        print("Metal vs CPU dictionary indexing scores: largest difference \(worst)")
        XCTAssertLessThanOrEqual(worst, DictionaryIndexingMetal.tolerance)
        try checkRun(gpu, ref, "ncc")
        let projected = try DictionaryIndexing.index(experimental: exp, navigationShape: [3, 3], master: d.master, rotations: d.rotations,
                                                     detector: d.detector, options: .init(backend: .metal))
        try checkRun(projected, ref, "ncc", rtol: 1e-3)
    }

    /// What kikuchipy refuses, refused.
    func testInvalidInputsThrow() throws {
        let (_, exp, d) = try small()
        func index(_ options: DictionaryIndexing.Options, shape: [Int] = [3, 3], rotations: [SIMD4<Double>]? = nil) throws -> DictionaryIndexing.Result {
            try DictionaryIndexing.index(experimental: exp, navigationShape: shape, dictionary: Array(d.patterns.prefix(10 * d.pixels)),
                                         rotations: rotations ?? Array(d.rotations.prefix(10)), pixels: d.pixels, options: options)
        }
        XCTAssertThrowsError(try index(.init(keepN: 0))) { XCTAssertEqual($0 as? DictionaryIndexing.Error, .keepN(0)) }
        XCTAssertThrowsError(try index(.init(), shape: [2, 3])) { XCTAssertEqual($0 as? DictionaryIndexing.Error, .navigationShape([2, 3], patterns: 9)) }
        XCTAssertThrowsError(try index(.init(navigationMask: Array(repeating: true, count: 9)))) {
            XCTAssertEqual($0 as? DictionaryIndexing.Error, .navigationMaskAll)
        }
        XCTAssertThrowsError(try index(.init(signalMask: Array(repeating: true, count: d.pixels)))) {
            XCTAssertEqual($0 as? DictionaryIndexing.Error, .signalMaskAll)
        }
        XCTAssertThrowsError(try index(.init(signalMask: [false]))) { XCTAssertEqual($0 as? DictionaryIndexing.Error, .signalMaskShape(mask: 1, pixels: 3600)) }
        XCTAssertThrowsError(try index(.init(), rotations: Array(d.rotations.prefix(9)))) {
            XCTAssertEqual($0 as? DictionaryIndexing.Error, .rotationCount(rotations: 9, patterns: 10))
        }
        XCTAssertThrowsError(try index(.init(patternsPerIteration: 0))) { XCTAssertEqual($0 as? DictionaryIndexing.Error, .patternsPerIteration(0)) }
        // keep_n above the dictionary's size is clamped, as kikuchipy's `min(keep_n, dictionary_size)`.
        XCTAssertEqual(try index(.init(keepN: 50, backend: .cpu)).keepN, 10)
    }

    // MARK: - Figure F9: the north-star scan

    /// The 6 x 6 block of kikuchipy's corrected patterns: exact input on real data, float32 tolerances.
    func testTheCorrectedBlockMatchesKikuchipy() throws {
        let ref = try SEMParityReference.load("m4/dictionary-indexing-nickel-ebsd-large")
        let d = try dictionary()
        let r = try DictionaryIndexing.index(experimental: try ref.array("block_experimental").values, navigationShape: [6, 6],
                                             dictionary: d.patterns, rotations: d.rotations, pixels: d.pixels, options: .init(keepN: 5))
        try checkRun(r, ref, "block_ncc")
    }

    /// F9 end to end: the shipped scan, the app's static then dynamic background (kikuchipy's docs chain), dictionary indexing
    /// with keep_n 5 on the automatic backend. The best match equals kikuchipy's at 99.5 % of the points or more (a one-grey-level
    /// perturbation of 0.2 % of kikuchipy's corrected pixels moved 2 of 4125), the scores within rtol 2e-3 (it moved them 1.04e-3).
    /// The best simulation indices are printed as base64 int32 and written to $TMPDIR for tools/parity/sem/dictionary_figure.py --ours.
    func testFigureF9WholeScanIndexedAgainstTheNickelDictionary() async throws {
        let ref = try SEMParityReference.load("m4/dictionary-indexing-nickel-ebsd-large")
        let d = try dictionary()
        let dataset = try EBSDH5Reader.read(url: Self.demoScan)
        let background = try XCTUnwrap(dataset.staticBackground).doubles().map { UInt8($0) }
        let raw = try [UInt8](dataset.allPatterns().bytes)
        let rows = dataset.scanRows, columns = dataset.scanColumns, pixels = dataset.patternRows * dataset.patternColumns
        XCTAssertEqual([rows, columns, dataset.patternRows, dataset.patternColumns], [55, 75, 60, 60])
        var corrected = [Double](repeating: 0, count: rows * columns * pixels)
        for i in 0 ..< (rows * columns) {
            let p = Array(raw[(i * pixels) ..< ((i + 1) * pixels)])
            let s = try PatternProcessing.removeStaticBackground(p, background: background, operation: .subtract)
            let c = try PatternProcessing.removeDynamicBackground(s, rows: dataset.patternRows, columns: dataset.patternColumns,
                                                                  operation: .subtract, domain: .frequency)
            for j in 0 ..< pixels { corrected[i * pixels + j] = Double(c[j]) }
        }
        let start = Date()
        let r = try await DictionaryIndexing.indexAsync(experimental: corrected, navigationShape: [rows, columns], master: d.master,
                                                        rotations: d.rotations, detector: d.detector, options: .init(keepN: 5))
        print("F9: \(rows * columns) patterns against \(d.rotations.count) in \(Date().timeIntervalSince(start)) s")
        let refIndices = try ref.array("ncc_simulation_indices").values, refScores = try ref.array("ncc_scores")
        let best = r.bestSimulationIndices
        let same = (0 ..< best.count).filter { best[$0] == Int(refIndices[$0 * 5]) }.count
        print("F9: best match equal to kikuchipy's at \(same) of \(best.count) points")
        XCTAssertGreaterThanOrEqual(Double(same) / Double(best.count), 0.995)
        let refBest = stride(from: 0, to: refScores.values.count, by: 5).map { refScores.values[$0] }
        if let m = SEMParityCompare.mismatch(name: "F9 best scores", actual: r.bestScores, expected: refBest, rtol: refScores.rtol, atol: 0) {
            XCTFail(m.description)
        }
        var bytes = Data()
        for i in best { withUnsafeBytes(of: Int32(i).littleEndian) { bytes.append(contentsOf: $0) } }
        print("F9 ours best simulation indices int32 base64: \(bytes.base64EncodedString())")
        try? bytes.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("macTEM-F9-ours.i32"))
    }
}
