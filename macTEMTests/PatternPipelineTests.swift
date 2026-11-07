//
//  PatternPipelineTests.swift
//  The Patterns room's pipeline (`PatternPipeline`, TEMCore) chains `PatternProcessing`'s stages in kikuchipy's order. On the
//  nine-pattern h5ebsd fixture: the room default (static then dynamic subtract) over the whole scan equals kikuchipy's corrected
//  patterns (`m2/intensity-kikuchipy-h5ebsd/corrected`) within one grey level, the background rows' bound; the intensity and size
//  stages from those corrected patterns equal kikuchipy's `chain` exactly. Also: the processed dataset's shape and detector after
//  binning, the scan's mean background against `PatternProcessing.meanBackground`, staling by stage, the refusals' sentences and
//  the method JSON's kikuchipy names.
//  Red before the pipeline: no `PatternPipeline`. Red after a stage is skipped or reordered: the corrected or chain arrays move.
//

import XCTest
import FormatoCore
import TEMCore

nonisolated final class PatternPipelineTests: XCTestCase {
    private static let caseName = "m2/intensity-kikuchipy-h5ebsd"

    private func opened() throws -> (SEMParityReference, EBSDDataset, EBSDPatternReader) {
        let ref = try SEMParityReference.load(Self.caseName)
        let url = try XCTUnwrap(ref.inputURL(0))
        let (dataset, reader) = try EBSDOpening.open(url: url)
        return (ref, dataset, reader)
    }

    func testTheRoomDefaultOverTheScanIsKikuchipysCorrectedPatterns() throws {
        let (ref, dataset, reader) = try opened()
        XCTAssertEqual(dataset.scanRows * dataset.scanColumns, 9)
        let background = try XCTUnwrap(dataset.staticBackground, "the fixture carries its static background")
        var fractions: [Double] = []
        let processed = try XCTUnwrap(PatternPipeline.roomDefault.process(reader, background: background, progress: { fractions.append($0) }))
        XCTAssertEqual(fractions.last, 1)
        XCTAssertEqual(processed.dataset.patternRows, dataset.patternRows)
        let ours = PatternPipeline.unsigned(try FormatoArray(dataType: .uint8, shape: [processed.bytes.count], bytes: processed.bytes), as: UInt8.self)
        let corrected = try ref.array("corrected").values
        XCTAssertEqual(ours.count, corrected.count)
        var off = 0, worst = 0
        for (a, b) in zip(ours, corrected) {
            let d = abs(Int(a) - Int(b))
            if d > 0 { off += 1 }
            worst = max(worst, d)
        }
        XCTAssertLessThanOrEqual(worst, 1)
        XCTAssertLessThanOrEqual(Double(off), 0.01 * Double(corrected.count), "\(off) of \(corrected.count) pixels one grey level off")
    }

    func testIntensityAndSizeStagesFromTheCorrectedPatternsAreKikuchipysChain() throws {
        let ref = try SEMParityReference.load(Self.caseName)
        let corrected = try ref.array("corrected")
        var pipeline = PatternPipeline()
        pipeline.staticStage.isOn = false
        pipeline.dynamicStage.isOn = false
        pipeline.intensity.mode = .rescale
        pipeline.intensity.usesPercentiles = true
        pipeline.binning = 2
        let pixels = 3600
        var ours: [Double] = []
        for i in 0..<9 {
            let one = try FormatoArray(dataType: .uint8, shape: [60, 60], bytes: Data(corrected.values[i * pixels..<(i + 1) * pixels].map { UInt8($0) }))
            let out = try pipeline.apply(one, rows: 60, columns: 60, background: nil)
            XCTAssertEqual(out.shape, [30, 30]); XCTAssertEqual(out.dataType, .uint8)
            ours += out.doubles()
        }
        let chain = try ref.array("chain")
        SEMAssertParity(ours, chain, shape: [3, 3, 30, 30])
        XCTAssertEqual(zip(ours, chain.values).filter { $0 != $1 }.count, 0)
    }

    func testNormaliseMakesFloat32AndTheProcessedDatasetIsBinned() throws {
        let (_, dataset, reader) = try opened()
        var pipeline = PatternPipeline.roomDefault
        pipeline.intensity.mode = .normalize
        pipeline.binning = 2
        let processed = try XCTUnwrap(pipeline.process(reader, background: dataset.staticBackground))
        let out = processed.dataset
        XCTAssertEqual(out.dataType, .float32)
        XCTAssertEqual([out.patternRows, out.patternColumns], [dataset.patternRows / 2, dataset.patternColumns / 2])
        XCTAssertEqual(out.detector.binning, dataset.detector.binning * 2)
        XCTAssertEqual(out.staticBackground?.shape, [dataset.patternRows / 2, dataset.patternColumns / 2])
        let first = try processed.pattern(row: 0, column: 0).doubles()
        XCTAssertEqual(first.min()!, -1, accuracy: 1e-6); XCTAssertEqual(first.max()!, 1, accuracy: 1e-6)
    }

    func testTheScansMeanBackgroundIsPatternProcessingsMean() throws {
        let (_, dataset, reader) = try opened()
        let mean = try XCTUnwrap(PatternPipeline.meanBackground(reader))
        var all: [UInt8] = []
        for r in 0..<dataset.scanRows { all += PatternPipeline.unsigned(try reader.row(r), as: UInt8.self) }
        let expected = try PatternProcessing.meanBackground(of: all, count: dataset.patternCount, pixels: dataset.patternPixels)
        XCTAssertEqual(PatternPipeline.unsigned(mean, as: UInt8.self), expected)
        XCTAssertEqual(mean.shape, [dataset.patternRows, dataset.patternColumns])
    }

    func testAChangeStalesItsStageAndTheRefusalsSaySo() throws {
        let (_, dataset, _) = try opened()
        var p = PatternPipeline.roomDefault
        XCTAssertNil(p.firstDifference(from: .roomDefault))
        p.dynamicStage.std = 12
        XCTAssertEqual(p.firstDifference(from: .roomDefault), .dynamicBackground)
        p.staticStage.operation = .divide
        XCTAssertEqual(p.firstDifference(from: .roomDefault), .staticBackground)

        XCTAssertNil(PatternPipeline.roomDefault.refusal(for: dataset, background: dataset.staticBackground))
        XCTAssertEqual(PatternPipeline.roomDefault.refusal(for: dataset, background: nil)?.stage, .staticBackground)
        let wrong = try FormatoArray(dataType: .uint8, shape: [2, 2], bytes: Data([1, 2, 3, 4]))
        XCTAssertEqual(PatternPipeline.roomDefault.refusal(for: dataset, background: wrong)?.sentence,
                       "Static background is 2 × 2 uint8, the patterns are 60 × 60 uint8.")
        var bin = PatternPipeline.roomDefault
        bin.binning = 8
        XCTAssertEqual(bin.refusal(for: dataset, background: dataset.staticBackground)?.stage, .size)
        var pct = PatternPipeline.roomDefault
        pct.intensity.mode = .rescale; pct.intensity.usesPercentiles = true; pct.intensity.lowPercentile = 90; pct.intensity.highPercentile = 10
        XCTAssertEqual(pct.refusal(for: dataset, background: dataset.staticBackground)?.stage, .intensity)
    }

    func testTheMethodJSONNamesEveryStageAsKikuchipyDoes() throws {
        let (_, dataset, _) = try opened()
        var p = PatternPipeline.roomDefault
        p.intensity.mode = .rescale; p.intensity.usesPercentiles = true
        p.binning = 2
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: p.methodJSON(fileName: "x.h5", dataset: dataset)) as? [String: Any])
        let steps = try XCTUnwrap(json["steps"] as? [[String: Any]])
        XCTAssertEqual(steps.compactMap { $0["method"] as? String },
                       ["EBSD.remove_static_background", "EBSD.remove_dynamic_background", "EBSD.rescale_intensity", "EBSD.downsample"])
        XCTAssertEqual(steps[1]["filter_domain"] as? String, "frequency")
        XCTAssertEqual(steps[2]["percentiles"] as? [Double], [2, 98])
        XCTAssertEqual(steps[3]["factor"] as? Int, 2)
    }

    func testFloatDownsampleSpansMinusOneToOne() throws {
        let f: [Float] = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15]
        // 2 x 2 blocks of a 4 x 4 ramp: sums 10, 18, 42, 50 -> (s - 10) / 40 * 2 - 1.
        let out = try PatternProcessing.downsampleFloat(f, rows: 4, columns: 4, factor: 2)
        XCTAssertEqual(out.count, 4)
        for (a, b) in zip(out, [Float(-1), -0.6, 0.6, 1]) { XCTAssertEqual(a, b, accuracy: 1e-6) }
    }
}
