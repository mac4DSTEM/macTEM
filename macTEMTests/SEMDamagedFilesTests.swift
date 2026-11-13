//
//  SEMDamagedFilesTests.swift
//  A damaged EDS or EBSD file is refused in words, never a crash (macEM 2.1.0 bundle B: #606 damaged EDS files, #607 truncated
//  EBSD files). One test per site the audit named; the flat-pattern runs are in PatternErrorTextTests and IndexingRefineTests.
//  Red before: a spectrum image's channel past its last indexed out of range when summed; a pixel table that ran backwards, or
//  more pixels than the header, trapped in `precondition`; an SFS stream offset behind what was read gave a negative index; a
//  JEOL magnification of 0 gave an infinite scale; a Bruker region of interest with gaps sized its index map by ny · nx; a
//  saved binning of 0 divided by zero.
//

import Foundation
import FormatoCore
import TEMCore
import XCTest

nonisolated final class SEMDamagedFilesTests: XCTestCase {

    // MARK: - #606

    func testASpectrumImageWithACountPastItsLastChannelIsRefused() {
        XCTAssertThrowsError(try CSRSpectrumImage(ny: 1, nx: 2, channels: 4, rowOffsets: [0, 1, 2], channelIndex: [0, 4], counts: [1, 1])) {
            XCTAssertTrue(($0 as? SEMEDSReadError)?.text.contains("channel 4") ?? false, "\($0)")
        }
        var builder = try? CSRSpectrumImageBuilder(ny: 1, nx: 1, channels: 4)
        builder?.append(channels: [UInt16(9)], counts: [UInt32(2)])
        XCTAssertThrowsError(try builder?.finish())
    }

    func testASpectrumImageWhosePixelTableDoesNotDescribeItsCountsIsRefused() {
        // Backwards offsets.
        XCTAssertThrowsError(try CSRSpectrumImage(ny: 1, nx: 2, channels: 4, rowOffsets: [0, 2, 1], channelIndex: [0], counts: [1]))
        // Too few offsets for the pixels.
        XCTAssertThrowsError(try CSRSpectrumImage(ny: 2, nx: 2, channels: 4, rowOffsets: [0, 1], channelIndex: [0], counts: [1]))
        // The last offset is not the number of counts.
        XCTAssertThrowsError(try CSRSpectrumImage(ny: 1, nx: 1, channels: 4, rowOffsets: [0, 3], channelIndex: [0], counts: [1]))
        // An overflowing pixel count.
        XCTAssertThrowsError(try CSRSpectrumImage(ny: Int.max, nx: 2, channels: 4, rowOffsets: [0], channelIndex: [], counts: []))
        // More pixels appended than the image holds.
        var builder = try? CSRSpectrumImageBuilder(ny: 1, nx: 1, channels: 4)
        builder?.append(channels: [UInt16(1)], counts: [UInt32(2)])
        builder?.append(channels: [UInt16(1)], counts: [UInt32(2)])
        XCTAssertThrowsError(try builder?.finish()) {
            XCTAssertTrue(($0 as? SEMEDSReadError)?.text.contains("more than its 1 x 1") ?? false, "\($0)")
        }
    }

    func testAnSFSStreamOffsetBehindWhatWasReadIsRefused() throws {
        var blocks = [[UInt8](repeating: 1, count: 16)]
        var stream = SEMEDSByteStream(name: "damaged.bcf") { blocks.isEmpty ? nil : blocks.removeFirst() }
        try stream.skip(8)
        XCTAssertThrowsError(try stream.seek(2)) { XCTAssertTrue("\($0)".contains("damaged.bcf"), "\($0)") }
        XCTAssertThrowsError(try stream.skip(-1))
        XCTAssertThrowsError(try stream.seek(Int.min))
        try stream.seek(12)
        XCTAssertEqual(try stream.take(4).count, 4)
    }

    func testAJEOLMagnificationOfZeroNegativeOrNaNIsRefusedNamingTheFile() throws {
        for mag in [0, -100, Double.nan] {
            XCTAssertThrowsError(try JEOLEDSReader.fieldWidth(scanSize: 125, magnification: mag, file: "map.pts")) {
                XCTAssertTrue(($0 as? SEMEDSReadError)?.text.hasPrefix("map.pts") ?? false, "\($0)")
            }
        }
        XCTAssertEqual(try JEOLEDSReader.fieldWidth(scanSize: 125, magnification: 1000, file: "map.pts"), 125, accuracy: 1e-12)
    }

    // MARK: - #607

    func testABrukerRegionOfInterestWithGapsIsNotRectangular() {
        // Two positions on the diagonal of a 2 x 2 rectangle: each row and column once, but half the rectangle missing.
        XCTAssertNil(EBSDH5Reader.rectangularROI(rows: [0, 1], columns: [0, 1]))
        let full = EBSDH5Reader.rectangularROI(rows: [5, 5, 6, 6], columns: [2, 3, 2, 3])
        XCTAssertEqual(full?.rows, 2)
        XCTAssertEqual(full?.fileIndexByPosition.count, 4)
    }

    func testASavedBinningOutsideTheOfferedSetIsRefusedNotDividedBy() throws {
        let side = 4
        let dataset = EBSDDataset(format: .generated, manufacturer: "test", version: "", scanGroup: "s", scanGroups: ["s"], scanRows: 1,
                                  scanColumns: 1, patternRows: side, patternColumns: side, dataType: .uint8, stepY: 1, stepX: 1,
                                  detector: EBSDDetectorGeometry(rows: side, columns: side, projectionCenters: []),
                                  patterns: EBSDPatternSource(url: URL(fileURLWithPath: "/planted"), datasetPath: "",
                                                              fileShape: [1, 1, side, side], dataType: .uint8))
        let access = try EBSDMemoryPatterns(dataset: dataset, bytes: Data((0..<(side * side)).map { UInt8($0) }))
        for factor in [0, -2, 3] {
            var pipeline = PatternPipeline()
            pipeline.staticStage.isOn = false
            pipeline.dynamicStage.isOn = false
            pipeline.binning = factor
            XCTAssertEqual(pipeline.refusal(for: dataset, background: nil)?.stage, .size, "bin \(factor)")
            XCTAssertThrowsError(try pipeline.process(access, background: nil), "bin \(factor)")
            XCTAssertThrowsError(try pipeline.apply(access.pattern(row: 0, column: 0), rows: side, columns: side, background: nil))
            XCTAssertEqual(pipeline.processedDataset(dataset).patternRows, side, "bin \(factor)")
        }
    }
}
