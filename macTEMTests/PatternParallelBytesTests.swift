//
//  PatternParallelBytesTests.swift
//  Process, the indexer's streamed patterns, the image-quality map and the virtual BSE pass work a scan row's patterns on every core
//  (`ScanRowWork`, TEMCore) and give the serial loop's bytes: on the generated demo and on a planted 8 × 9 scan of 60 × 60 uint8
//  patterns, each result equals the same per-pattern function called pattern by pattern here, bit for bit; and a pattern's bytes,
//  now written in one copy, are each value's little-endian bytes appended in turn. Those are guards, green before and after the change
//  (a speed-up has no reliable red test in CI). Red before: `ScanRowWork`, whose column order and lowest-column error the first test
//  holds, does not exist.
//

import XCTest
import Foundation
import FormatoCore
import TEMCore
import TEMSession

nonisolated final class PatternParallelBytesTests: XCTestCase {

    /// A planted 8 × 9 scan of 60 × 60 uint8 patterns: a band that turns from point to point, on a slope, with hashed noise.
    private func plantedScan() throws -> EBSDMemoryPatterns {
        let rows = 8, columns = 9, side = 60
        var raw = [UInt8](repeating: 0, count: rows * columns * side * side)
        for p in 0..<(rows * columns) {
            let angle = Double(p) * 0.37
            for y in 0..<side {
                for x in 0..<side {
                    let i = (p * side + y) * side + x
                    let band = 40 * cos((Double(x) * cos(angle) + Double(y) * sin(angle)) / 4)
                    let noise = Double((i * 7919 + p * 104_729) % 23)
                    raw[i] = UInt8(min(max(100 + band + Double(y) + noise, 0), 255))
                }
            }
        }
        let dataset = EBSDDataset(format: .generated, manufacturer: "test", version: "", scanGroup: "s", scanGroups: ["s"], scanRows: rows,
                                  scanColumns: columns, patternRows: side, patternColumns: side, dataType: .uint8, stepY: 1, stepX: 1,
                                  detector: EBSDDetectorGeometry(rows: side, columns: side, projectionCenters: []),
                                  patterns: EBSDPatternSource(url: URL(fileURLWithPath: "/planted"), datasetPath: "",
                                                              fileShape: [rows, columns, side, side], dataType: .uint8))
        return try EBSDMemoryPatterns(dataset: dataset, bytes: Data(raw))
    }

    /// The demo and the planted scan.
    private func scans() throws -> [any EBSDPatternAccess] {
        let demo = try DemoDocuments.ebsd()
        let planted = try plantedScan()
        return [demo.access, planted]
    }

    /// The room's default and two that run every other per-pattern branch: a spatial dynamic background, rescale by percentiles,
    /// equalise, the band FFT filter and bin 2 on uint8; a divided static background, normalise to float32 and bin 2.
    private var pipelines: [PatternPipeline] {
        var filtered = PatternPipeline.roomDefault
        filtered.dynamicStage.domain = .spatial
        filtered.intensity.mode = .rescale
        filtered.intensity.usesPercentiles = true
        filtered.intensity.equalize = true
        filtered.fftFilter.isOn = true
        filtered.binning = 2
        var normalised = PatternPipeline.roomDefault
        normalised.staticStage.operation = .divide
        normalised.intensity.mode = .normalize
        normalised.binning = 2
        return [.roomDefault, filtered, normalised]
    }

    func testScanRowWorkKeepsColumnOrderAndThrowsTheLowestColumnsError() throws {
        let squares = try ScanRowWork.map(columns: 1000) { (column: Int) -> Int in column * column }
        XCTAssertEqual(squares, (0..<1000).map { $0 * $0 })
        let none = try ScanRowWork.map(columns: 0) { (column: Int) -> Int in column }
        XCTAssertTrue(none.isEmpty)
        // Columns 3, 10, 17, … fail: the error is column 3's, the one a serial loop stops at.
        XCTAssertThrowsError(try ScanRowWork.map(columns: 64) { (column: Int) throws -> Int in
            if column % 7 == 3 { throw PatternProcessing.Error.parameter(String(column)) }
            return column
        }) { error in
            XCTAssertEqual(error as? PatternProcessing.Error, .parameter("3"))
        }
    }

    func testApplyWritesEachValuesLittleEndianBytes() throws {
        let side = 6
        let pattern = (0..<(side * side)).map { UInt16(truncatingIfNeeded: ($0 * 7919) % 65536) }
        var stored = Data()
        for v in pattern { withUnsafeBytes(of: v.littleEndian) { stored.append(contentsOf: $0) } }
        let one = try FormatoArray(dataType: .uint16, shape: [side, side], bytes: stored)
        var rescale = PatternPipeline()
        rescale.staticStage.isOn = false
        rescale.dynamicStage.isOn = false
        rescale.intensity.mode = .rescale
        var expected = Data()
        for v in try PatternProcessing.rescaleIntensity(pattern) { withUnsafeBytes(of: v.littleEndian) { expected.append(contentsOf: $0) } }
        XCTAssertEqual(try rescale.apply(one, rows: side, columns: side, background: nil).bytes, expected)

        var normalise = rescale
        normalise.intensity.mode = .normalize
        var floats = Data()
        for v in try PatternProcessing.normalizeIntensity(pattern.map { Double($0) }) {
            withUnsafeBytes(of: v.bitPattern.littleEndian) { floats.append(contentsOf: $0) }
        }
        XCTAssertEqual(try normalise.apply(one, rows: side, columns: side, background: nil).bytes, floats)
    }

    func testProcessGivesTheSerialLoopsBytes() throws {
        for access in try scans() {
            let d = access.dataset
            let background = try XCTUnwrap(PatternPipeline.meanBackground(access))
            for pipeline in pipelines {
                let processed = try XCTUnwrap(pipeline.process(access, background: background))
                var serial = Data()
                for row in 0..<d.scanRows {
                    for column in 0..<d.scanColumns {
                        serial.append(try pipeline.apply(access.pattern(row: row, column: column), rows: d.patternRows, columns: d.patternColumns,
                                                         background: background).bytes)
                    }
                }
                XCTAssertEqual(processed.bytes, serial, "\(d.scanRows) × \(d.scanColumns), \(pipeline.intensity.mode.rawValue)")
            }
        }
    }

    func testTheIndexersStreamedRowsAreTheSerialLoops() throws {
        for access in try scans() {
            let d = access.dataset
            let background = try XCTUnwrap(PatternPipeline.meanBackground(access))
            let source = IndexingSource(stored: access, pipeline: .roomDefault, background: background)
            for row in 0..<d.scanRows {
                let streamed = try source.patterns(row: row)
                let serial = try (0..<d.scanColumns).map { try source.pattern(row: row, column: $0) }
                XCTAssertEqual(streamed, serial, "row \(row)")
            }
        }
    }

    func testTheImageQualityMapIsTheSerialLoops() async throws {
        for access in try scans() {
            let d = access.dataset
            let maps = try await PatternQuality.maps(of: access)
            let iq = try PatternQuality.ImageQuality(rows: d.patternRows, columns: d.patternColumns)
            var serial: [Double] = []
            for row in 0..<d.scanRows {
                for column in 0..<d.scanColumns { serial.append(try iq(access.pattern(row: row, column: column).doubles())) }
            }
            XCTAssertEqual(maps.imageQuality.map(\.bitPattern), serial.map(\.bitPattern))
        }
    }

    func testTheVirtualBSEPassIsTheSerialLoops() throws {
        for access in try scans() {
            let d = access.dataset
            let rects = [DetectorRect(top: 0, bottom: d.patternRows, left: 0, right: d.patternColumns)]
                + VirtualBSEGrid(5).rects(patternRows: d.patternRows, patternColumns: d.patternColumns)
                + [DetectorRect(top: 7, bottom: 7, left: 0, right: 10)]
            let pass = try XCTUnwrap(VirtualBSEImaging.imagesAndPatternSum(access, rects: rects, sumsPatterns: true))
            var images = [[Double]](repeating: [], count: rects.count)
            var patternSum = [Double](repeating: 0, count: d.patternPixels)
            for row in 0..<d.scanRows {
                for column in 0..<d.scanColumns {
                    let values = try access.pattern(row: row, column: column).doubles()
                    for (k, rect) in rects.enumerated() {
                        var sum = 0.0
                        for y in rect.top..<rect.bottom {
                            for x in rect.left..<rect.right { sum += values[y * d.patternColumns + x] }
                        }
                        images[k].append(sum)
                    }
                    for j in 0..<d.patternPixels { patternSum[j] += values[j] }
                }
            }
            XCTAssertEqual(pass.images.map { $0.map(\.bitPattern) }, images.map { $0.map(\.bitPattern) })
            XCTAssertEqual(pass.patternSum?.map(\.bitPattern), patternSum.map(\.bitPattern))
        }
    }
}
