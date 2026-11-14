//
//  PatternErrorTextTests.swift
//  A processing or Hough failure reads as a sentence and names the pattern (`PatternPipeline`, the SEM error types, TEMCore): Process
//  over a scan whose second pattern is flat finishes and names that pattern as not usable (#607, as kikuchipy carries on past a
//  NaN); the indexer's streamed patterns stop with "Pattern (row 0, column 1): …", where it read "The operation couldn't be completed (TEMCore.PatternProcessing.Error error 2.)"; and every case
//  of the error types a session can show has its own sentence. Red before the change: Process throws the bare
//  `PatternProcessing.Error.nonFinite`, which is no `Refusal` and names no pattern, and the error types are not `LocalizedError`.
//

import XCTest
import FormatoCore
import TEMCore

nonisolated final class PatternErrorTextTests: XCTestCase {

    /// A 1 × 2 uint8 scan of 4 × 4 px patterns: the first ramps from 0 to 225, the second is all zeros.
    private func flatSecondPattern() throws -> EBSDMemoryPatterns {
        let side = 4
        let ramp = (0..<(side * side)).map { UInt8($0 * 15) }
        let flat = [UInt8](repeating: 0, count: side * side)
        let dataset = EBSDDataset(format: .generated, manufacturer: "test", version: "", scanGroup: "s", scanGroups: ["s"], scanRows: 1,
                                  scanColumns: 2, patternRows: side, patternColumns: side, dataType: .uint8, stepY: 1, stepX: 1,
                                  detector: EBSDDetectorGeometry(rows: side, columns: side, projectionCenters: []),
                                  patterns: EBSDPatternSource(url: URL(fileURLWithPath: "/planted"), datasetPath: "",
                                                              fileShape: [1, 2, side, side], dataType: .uint8))
        return try EBSDMemoryPatterns(dataset: dataset, bytes: Data(ramp + flat))
    }

    /// Rescale alone: the flat pattern cannot be stretched, so the run stops there.
    private var rescaleOnly: PatternPipeline {
        var pipeline = PatternPipeline()
        pipeline.staticStage.isOn = false
        pipeline.dynamicStage.isOn = false
        pipeline.intensity.mode = .rescale
        return pipeline
    }

    /// Red before #607: the flat pattern threw and the whole run landed nothing.
    func testAFlatPatternIsNotUsableAndProcessFinishes() throws {
        let access = try flatSecondPattern()
        var unusable: [EBSDPosition] = []
        let processed = try XCTUnwrap(try rescaleOnly.process(access, background: nil, unusable: { unusable = $0 }))
        XCTAssertEqual(unusable, [EBSDPosition(row: 0, column: 1)])
        XCTAssertEqual(processed.bytes.count, 2 * 16)
        XCTAssertEqual(Array(processed.bytes.suffix(16)), [UInt8](repeating: 0, count: 16), "uint8: numpy's cast of NaN, 0")
        XCTAssertEqual(Array(processed.bytes.prefix(16)).last, 255, "the ramp is rescaled")

        // Normalise makes float32: the flat pattern's place holds NaN.
        var normalize = rescaleOnly
        normalize.intensity.mode = .normalize
        let floats = try XCTUnwrap(try normalize.process(access, background: nil))
        let values = floats.bytes.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        XCTAssertTrue(values.suffix(16).allSatisfy(\.isNaN))
        XCTAssertTrue(values.prefix(16).allSatisfy(\.isFinite))

        // The one-pattern preview says the stage's sentence, with no position: the person is looking at the pattern.
        let flat = try access.pattern(row: 0, column: 1)
        XCTAssertThrowsError(try rescaleOnly.apply(flat, rows: 4, columns: 4, background: nil)) { error in
            XCTAssertEqual((error as? PatternPipeline.Refusal)?.stage, .intensity, "\(error)")
            XCTAssertFalse(error.localizedDescription.contains("Pattern (row"), error.localizedDescription)
        }
    }

    func testTheIndexersStreamedPatternsNameTheFlatOne() throws {
        let access = try flatSecondPattern()
        let source = IndexingSource(stored: access, pipeline: rescaleOnly, background: nil)
        XCTAssertEqual(source.kind, .perPattern)
        XCTAssertThrowsError(try source.patterns(row: 0)) { error in
            XCTAssertTrue(error.localizedDescription.hasPrefix("Pattern (row 0, column 1): "), error.localizedDescription)
        }
    }

    func testEveryCaseOfTheSEMErrorsHasASentence() {
        let errors: [any LocalizedError] = [
            PatternProcessing.Error.shape, PatternProcessing.Error.parameter("std"), PatternProcessing.Error.nonFinite,
            PatternFilters.Error.shape, PatternFilters.Error.fft, PatternFilters.Error.nonFinite,
            PatternWindow.Error.shape, PatternWindow.Error.parameter("cutoff"),
            NLPAR.Error.shape, NLPAR.Error.parameter("search radius"),
            NeighbourAveraging.Error.shape, NeighbourAveraging.Error.nonFinite,
            PatternQuality.Error.shape, PatternQuality.Error.plan,
            HoughIndexer.Error.noPhases, HoughIndexer.Error.shape,
            HoughBandDetector.Error.settings, HoughBandDetector.Error.shape,
            HoughReflectorLibrary.Error.spaceGroup(231), HoughReflectorLibrary.Error.reflectors, HoughReflectorLibrary.Error.lattice,
        ]
        for error in errors {
            let sentence = error.errorDescription ?? ""
            XCTAssertTrue(sentence.hasSuffix("."), "\(error): \(sentence)")
            XCTAssertEqual(error.localizedDescription, sentence, "\(error)")
        }
    }
}
