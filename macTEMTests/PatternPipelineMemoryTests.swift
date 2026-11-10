//
//  PatternPipelineMemoryTests.swift
//  Process holds less of the scan while neighbour averaging and NLPAR run (`PatternPipeline`, TEMCore): NLPAR takes the per-pattern
//  output decoded straight to float32 (`floats(_:type:)`, no float64 array of the whole scan), averaging writes each pattern into the
//  caller's buffer (`NeighbourAveraging.average(into:)`), and both results are written out in one copy. The numbers do not move: on
//  the generated demo and on a planted uint16 scan, Process gives the bytes of the former whole-scan path, rebuilt here.
//  Red before the change: `floats(_:type:)` and `average(into:)` do not exist.
//

import XCTest
import FormatoCore
import TEMCore
import TEMSession

nonisolated final class PatternPipelineMemoryTests: XCTestCase {

    /// The values as the former path made them: every value as float64, then cast to float32.
    private func doublesAsFloats(_ bytes: Data, _ type: FormatoDataType) throws -> [Float] {
        try FormatoArray(dataType: type, shape: [bytes.count / type.byteSize], bytes: bytes).doubles().map { Float($0) }
    }

    /// The former serialisation: each value's little-endian bytes appended in turn.
    private func appended(_ values: [Float]) -> Data {
        var data = Data()
        for v in values { withUnsafeBytes(of: v.bitPattern.littleEndian) { data.append(contentsOf: $0) } }
        return data
    }

    private func appended(_ values: [UInt16]) -> Data {
        var data = Data()
        for v in values { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        return data
    }

    /// The decode NLPAR now reads is the float64 values cast to float32, exactly, for every per-pattern type; any other type is refused.
    func testFloatsAreTheDoublesCastToFloat() throws {
        let u8 = Data((0..<256).map { UInt8($0) })
        let u16 = appended([UInt16(0), 1, 255, 256, 4095, 32768, 65534, 65535])
        let f32 = appended([Float(0), -1.5, 0.1, 3.25e-3, 1e30, -7, 1, Float.leastNormalMagnitude])
        let cases: [(FormatoDataType, Data)] = [(.uint8, u8), (.uint16, u16), (.float32, f32)]
        for (type, bytes) in cases {
            XCTAssertEqual(try PatternPipeline.floats(bytes, type: type), try doublesAsFloats(bytes, type), type.rawValue)
        }
        XCTAssertThrowsError(try PatternPipeline.floats(Data(count: 8), type: .float64))
    }

    /// NLPAR through Process on the demo: the bytes of the former path (the per-pattern output as float64 cast to float32, NLPAR, each
    /// value appended), across the demo's two column tiles.
    func testNLPARThroughProcessGivesTheFormerPathsBytes() throws {
        let demo = try DemoDocuments.ebsd()
        let dataset = demo.dataset
        let background = try XCTUnwrap(PatternPipeline.meanBackground(demo.access))
        var withNLPAR = PatternPipeline.roomDefault
        withNLPAR.nlpar.isOn = true
        let processed = try XCTUnwrap(withNLPAR.process(demo.access, background: background))
        XCTAssertEqual(processed.dataset.dataType, .float32)

        let corrected = try XCTUnwrap(PatternPipeline.roomDefault.process(demo.access, background: background))
        let scan = try NLPAR.Scan(rows: dataset.scanRows, columns: dataset.scanColumns, patternRows: dataset.patternRows,
                                  patternColumns: dataset.patternColumns, values: doublesAsFloats(corrected.bytes, .uint8))
        XCTAssertEqual(processed.bytes, appended(try NLPAR.run(scan).denoised.values))
    }

    /// Averaging through Process on the demo, for every window: the former path's bytes (the whole scan averaged in float64, then
    /// cast), and the streaming `average(into:)` is that cast value for value.
    func testAveragingThroughProcessGivesTheFormerPathsBytes() throws {
        let demo = try DemoDocuments.ebsd()
        let dataset = demo.dataset
        let background = try XCTUnwrap(PatternPipeline.meanBackground(demo.access))
        let corrected = try XCTUnwrap(PatternPipeline.roomDefault.process(demo.access, background: background))
        let correctedValues = PatternPipeline.unsigned(try FormatoArray(dataType: .uint8, shape: [corrected.bytes.count], bytes: corrected.bytes),
                                                       as: UInt8.self)
        for window in PatternPipeline.AveragingWindow.allCases {
            var pipeline = PatternPipeline.roomDefault
            pipeline.averaging.isOn = true
            pipeline.averaging.window = window
            let processed = try XCTUnwrap(pipeline.process(demo.access, background: background))
            let values = try NeighbourAveraging.averageValues(correctedValues, scanRows: dataset.scanRows, scanColumns: dataset.scanColumns,
                                                              pixels: dataset.patternPixels, window: window.window())
            let cast = try PatternProcessing.cast(values, to: UInt8.self)
            XCTAssertEqual(processed.bytes, Data(cast), window.title)

            var streamed = [UInt8](repeating: 0, count: correctedValues.count)
            try NeighbourAveraging.average(correctedValues, scanRows: dataset.scanRows, scanColumns: dataset.scanColumns,
                                           pixels: dataset.patternPixels, window: window.window(), into: &streamed)
            XCTAssertEqual(streamed, cast, window.title)
        }
    }

    /// A uint16 scan through averaging alone: the averaged patterns written out in one copy are the little-endian bytes the former path
    /// appended value by value; a buffer of the wrong length is refused.
    func testUInt16AveragingIsWrittenOutAsLittleEndianBytes() throws {
        let rows = 4, columns = 5, side = 6
        let raw = (0..<(rows * columns * side * side)).map { UInt16(truncatingIfNeeded: ($0 * 7919 + ($0 / 36) * 977) % 65536) }
        let dataset = EBSDDataset(format: .generated, manufacturer: "test", version: "", scanGroup: "s", scanGroups: ["s"], scanRows: rows,
                                  scanColumns: columns, patternRows: side, patternColumns: side, dataType: .uint16, stepY: 1, stepX: 1,
                                  detector: EBSDDetectorGeometry(rows: side, columns: side, projectionCenters: []),
                                  patterns: EBSDPatternSource(url: URL(fileURLWithPath: "/planted"), datasetPath: "",
                                                              fileShape: [rows, columns, side, side], dataType: .uint16))
        let access = try EBSDMemoryPatterns(dataset: dataset, bytes: appended(raw))
        var pipeline = PatternPipeline()
        pipeline.staticStage.isOn = false
        pipeline.dynamicStage.isOn = false
        pipeline.averaging.isOn = true
        let processed = try XCTUnwrap(pipeline.process(access, background: nil))
        XCTAssertEqual(processed.dataset.dataType, .uint16)
        let window = try PatternPipeline.AveragingWindow.circular3.window()
        let values = try NeighbourAveraging.averageValues(raw, scanRows: rows, scanColumns: columns, pixels: side * side, window: window)
        XCTAssertEqual(processed.bytes, appended(try PatternProcessing.cast(values, to: UInt16.self)))

        var short = [UInt16](repeating: 0, count: raw.count - 1)
        do {
            try NeighbourAveraging.average(raw, scanRows: rows, scanColumns: columns, pixels: side * side, window: window, into: &short)
            XCTFail("a buffer one value short is refused")
        } catch {
            XCTAssertEqual(error as? NeighbourAveraging.Error, .shape)
        }
    }
}
