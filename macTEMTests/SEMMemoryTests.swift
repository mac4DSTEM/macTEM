//
//  SEMMemoryTests.swift
//  A pass over an EBSD scan holds a few rows of it, never the scan: the navigation map's pass with the scan's mean riding on it
//  (`VirtualBSEImaging.imagesAndPatternSum`, as the session runs it at the open) and the mean pass (`PatternPipeline.meanBackground`)
//  read a record file through `EBSDPatternReader` (TEMCore) one scan row at a time, whether the file is mapped or read through a file
//  handle. Pattern files run from hundreds of megabytes to tens of gigabytes, and a pass that held the scan would end the app. The
//  measure is the process's physical footprint (`ImageStackTests.footprint()`), taken before the reader opens, after every row and
//  at the end of the pass.
//
//  THE TRUTH: a bare-record file of 100 x 200 patterns of 60 x 60 uint8 pixels (72 MB as stored, 576 MB as float64), written one scan
//  row at a time into a temporary folder; pixel j of pattern k is `(31 k + j) % 251`, so the sums the passes return are checked exactly.
//  A pass holds one row as stored (720 KB) and that row as float64 (5.76 MB) beside its own output, so the bound is its output and four
//  rows as float64 (23 MB), under half the stored scan. A mapped file's pages are clean file pages, which the footprint leaves out.
//  Each pass reports its progress once per scan row, so the footprint is sampled on every row, and the count of samples is checked.
//  Red under: the scan read whole by a pass (`allPatterns()`, 72 MB) or at the open (the record file read into memory instead of mapped
//  or read record by record); every row's stored bytes or float64 values kept until the pass ends, as a read through the handle left to
//  the calling thread's autorelease pool would keep them (the read strategy only, 72 MB).
//

import XCTest
import Foundation
import FormatoCore
import TEMCore

nonisolated final class SEMMemoryTests: XCTestCase {

    /// The planted scan: `scanRows` x `scanColumns` patterns of `side` x `side` uint8 pixels, stored as bare records in map order.
    private static let scanRows = 100, scanColumns = 200, side = 60
    private static let pixels = side * side
    private static let patternCount = scanRows * scanColumns
    /// The scan as stored, 72 MB.
    private static let storedBytes = patternCount * pixels
    /// What a pass may grow the footprint by beyond its own output: four scan rows as float64 (23 MB), where it holds one row as stored
    /// and that row as float64 (6.5 MB together); the rest is margin for the allocator and the worker threads.
    private static let rowAllowance = 4 * scanColumns * pixels * MemoryLayout<Double>.size

    /// Pixel `pixel` of the pattern at file index (and map position) `index`.
    private static func planted(_ index: Int, _ pixel: Int) -> UInt8 { UInt8((index * 31 + pixel) % 251) }

    /// The planted pixels of pattern `index` inside `rect`, summed as integers.
    private static func sum(_ rect: DetectorRect, index: Int) -> Int {
        var total = 0
        for y in rect.top..<rect.bottom {
            for x in rect.left..<rect.right { total += Int(planted(index, y * side + x)) }
        }
        return total
    }

    /// Pixel `pixel` summed over every pattern of the scan, as integers.
    private static func scanSum(pixel: Int) -> Int {
        (0..<patternCount).reduce(0) { total, index in total + Int(planted(index, pixel)) }
    }

    /// The planted scan as a record file in a temporary folder that goes when the test ends, written one scan row at a time, so the
    /// writer never holds the scan.
    private func plantedRecordFile() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SEMMemoryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("patterns.up1")
        try Data().write(to: url)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        let columns = Self.scanColumns, pixels = Self.pixels
        var row = [UInt8](repeating: 0, count: columns * pixels)
        for scanRow in 0..<Self.scanRows {
            for column in 0..<columns {
                let index = scanRow * columns + column
                for pixel in 0..<pixels { row[column * pixels + pixel] = Self.planted(index, pixel) }
            }
            try handle.write(contentsOf: row)
        }
        return url
    }

    /// The dataset whose patterns are the bare records of `url` (EDAX's layout), the file order the map order.
    private static func dataset(_ url: URL) -> EBSDDataset {
        let source = EBSDPatternSource(url: url, layout: .records(offset: 0, recordBytes: pixels, patternOffset: 0),
                                       fileShape: [patternCount, side, side], dataType: .uint8)
        return EBSDDataset(format: .edaxBinary, manufacturer: "planted", version: "", scanGroup: "", scanGroups: [], scanRows: scanRows,
                           scanColumns: scanColumns, patternRows: side, patternColumns: side, dataType: .uint8, stepY: 1, stepX: 1,
                           detector: EBSDDetectorGeometry(rows: side, columns: side, projectionCenters: []), patterns: source)
    }

    /// The map's pass with the mean riding on it, as the session runs it at the open (the whole detector and the 5 x 5 grid), over the
    /// file read and mapped: the footprint, sampled on every row, grows by the pass's images and pattern sum and a few rows, not by the
    /// scan, and the whole detector, one tile and the pattern sum are the planted sums exactly.
    func testTheMapPassGrowsTheFootprintByAFewRowsNotTheScan() throws {
        let url = try plantedRecordFile()
        let dataset = Self.dataset(url)
        let rects = [DetectorRect(top: 0, bottom: Self.side, left: 0, right: Self.side)]
            + VirtualBSEGrid(5).rects(patternRows: Self.side, patternColumns: Self.side)
        // The pass's own output: one float64 image of the scan per rectangle, and the float64 sum of every detector pixel.
        let output = (rects.count * Self.patternCount + Self.pixels) * MemoryLayout<Double>.size
        let bound = output + Self.rowAllowance
        XCTAssertLessThanOrEqual(bound, Self.storedBytes / 2, "the bound is at most half the stored scan")
        let positions = [0, 7_777, Self.patternCount - 1]
        // Rectangle 8 is the tile in row 1, column 2 of the grid.
        let expectedImages = [0, 8].map { k in positions.map { Double(Self.sum(rects[k], index: $0)) } }
        let sumPixels = [0, 1_234, Self.pixels - 1]
        let expectedSum = sumPixels.map { Double(Self.scanSum(pixel: $0)) }

        for strategy in [EBSDPatternReader.RecordStrategy.read, .mapped] {
            let before = ImageStackTests.footprint()
            XCTAssertGreaterThan(before, 0, "the footprint can be read")
            let reader = try EBSDPatternReader(dataset, strategy: strategy)
            var peak = ImageStackTests.footprint()
            var rowsSeen = 0
            let pass = try VirtualBSEImaging.imagesAndPatternSum(reader, rects: rects, sumsPatterns: true, progress: { _ in
                peak = max(peak, ImageStackTests.footprint())
                rowsSeen += 1
            })
            peak = max(peak, ImageStackTests.footprint())
            XCTAssertEqual(rowsSeen, Self.scanRows, "\(strategy): one footprint sample per scan row")
            XCTAssertLessThan(peak - before, bound,
                              "\(strategy): the map's pass grew the footprint by \(peak - before) bytes; the scan is \(Self.storedBytes) as stored")

            let result = try XCTUnwrap(pass)
            for (n, k) in [0, 8].enumerated() {
                XCTAssertEqual(positions.map { result.images[k][$0] }, expectedImages[n], "\(strategy): the image of rectangle \(k)")
            }
            let patternSum = try XCTUnwrap(result.patternSum)
            XCTAssertEqual(sumPixels.map { patternSum[$0] }, expectedSum, "\(strategy): the pattern sum")
        }
    }

    /// The mean pass over the file read and mapped: the footprint, sampled on every row, grows by a few rows, not by the scan, and the
    /// mean is the planted mean exactly (the integer sum over the patterns divided by their count, truncated).
    func testTheMeanPassGrowsTheFootprintByAFewRowsNotTheScan() throws {
        let url = try plantedRecordFile()
        let dataset = Self.dataset(url)
        // The pass's own output: the float64 sum of every detector pixel and the uint8 mean.
        let bound = Self.pixels * (MemoryLayout<Double>.size + 1) + Self.rowAllowance
        XCTAssertLessThanOrEqual(bound, Self.storedBytes / 2, "the bound is at most half the stored scan")
        let meanPixels = [0, 1_234, Self.pixels - 1]
        let expectedMean = meanPixels.map { UInt8(Self.scanSum(pixel: $0) / Self.patternCount) }

        for strategy in [EBSDPatternReader.RecordStrategy.read, .mapped] {
            let before = ImageStackTests.footprint()
            XCTAssertGreaterThan(before, 0, "the footprint can be read")
            let reader = try EBSDPatternReader(dataset, strategy: strategy)
            var peak = ImageStackTests.footprint()
            var rowsSeen = 0
            let mean = try PatternPipeline.meanBackground(reader, progress: { _ in
                peak = max(peak, ImageStackTests.footprint())
                rowsSeen += 1
            })
            peak = max(peak, ImageStackTests.footprint())
            XCTAssertEqual(rowsSeen, Self.scanRows, "\(strategy): one footprint sample per scan row")
            XCTAssertLessThan(peak - before, bound,
                              "\(strategy): the mean pass grew the footprint by \(peak - before) bytes; the scan is \(Self.storedBytes) as stored")

            let background = try XCTUnwrap(mean)
            XCTAssertEqual(background.dataType, .uint8)
            XCTAssertEqual(background.shape, [Self.side, Self.side])
            let values = [UInt8](background.bytes)
            XCTAssertEqual(meanPixels.map { values[$0] }, expectedMean, "\(strategy): the mean")
        }
    }
}
