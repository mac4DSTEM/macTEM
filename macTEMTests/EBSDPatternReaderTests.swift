//
//  EBSDPatternReaderTests.swift
//  A record file (EDAX .up1/.up2, Oxford .ebsp, NORDIF Pattern.dat) is held by `EBSDPatternReader` as its volume allows: mapped on a
//  local volume, read through a held file handle on a network or unknown one, where a mapped page the network cannot deliver is a
//  SIGBUS. Both give the same bytes for every pattern, row and the whole scan, for bare records and for records with a header and a
//  footer. A file cut short after the open is refused with a sentence on the next read either way, where the mapping alone faulted
//  (a SIGBUS once a whole page is gone; the planted file is smaller than a page, so the old code read stale or zero bytes instead of
//  failing); a file shorter than its patterns at the open is refused there. The files are planted in the temporary folder.
//

import Foundation
import FormatoCore
import TEMCore
import XCTest

nonisolated final class EBSDPatternReaderTests: XCTestCase {

    /// Bytes before the first record, in every planted file.
    private static let offset = 16
    /// A 2 x 3 scan of 2 x 3 uint8 patterns: six patterns of six bytes.
    private static let scanRows = 2, scanColumns = 3, patternBytes = 6

    /// A folder in the temporary directory, removed when the test ends.
    private func scratchFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("EBSDPatternReaderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    /// The bytes of a record file of six records of `recordBytes` each after a 16-byte header, every byte its position mod 251.
    private static func fileBytes(recordBytes: Int) -> Data {
        Data((0..<(offset + 6 * recordBytes)).map { UInt8($0 % 251) })
    }

    /// The dataset whose patterns are the records of `url`, the pixels `patternOffset` bytes into each record.
    private static func dataset(url: URL, recordBytes: Int, patternOffset: Int) -> EBSDDataset {
        let source = EBSDPatternSource(url: url, layout: .records(offset: offset, recordBytes: recordBytes, patternOffset: patternOffset),
                                       fileShape: [6, 2, 3], dataType: .uint8)
        return EBSDDataset(format: .oxfordBinary, manufacturer: "oxford instruments", version: "", scanGroup: "", scanGroups: [],
                           scanRows: scanRows, scanColumns: scanColumns, patternRows: 2, patternColumns: 3, dataType: .uint8, stepY: 1,
                           stepX: 1, detector: EBSDDetectorGeometry(rows: 2, columns: 3, projectionCenters: [SIMD3(0.5, 0.5, 0.5)]),
                           patterns: source)
    }

    /// The stored pixels of pattern `index` in `bytes`.
    private static func pattern(_ index: Int, in bytes: Data, recordBytes: Int, patternOffset: Int) -> Data {
        let first = offset + index * recordBytes + patternOffset
        return bytes.subdata(in: first..<(first + patternBytes))
    }

    /// A local volume is mapped; a network volume, or one that does not say, is read.
    func testTheStrategyMapsOnlyALocalVolume() {
        XCTAssertEqual(EBSDPatternReader.recordStrategy(volumeIsLocal: true), .mapped)
        XCTAssertEqual(EBSDPatternReader.recordStrategy(volumeIsLocal: false), .read)
        XCTAssertEqual(EBSDPatternReader.recordStrategy(volumeIsLocal: nil), .read)
    }

    /// Every pattern, every row and the whole scan read the same bytes mapped and read, for bare records (EDAX, NORDIF) and for
    /// records with a 2-byte header and footer around the pixels (Oxford), and the same bytes as the file holds.
    func testBothStrategiesReadTheSameBytes() throws {
        let folder = try scratchFolder()
        for (recordBytes, patternOffset) in [(6, 0), (10, 2)] {
            let bytes = Self.fileBytes(recordBytes: recordBytes)
            let url = folder.appendingPathComponent("records-\(recordBytes).bin")
            try bytes.write(to: url)
            let dataset = Self.dataset(url: url, recordBytes: recordBytes, patternOffset: patternOffset)
            let expected = (0..<6).map { Self.pattern($0, in: bytes, recordBytes: recordBytes, patternOffset: patternOffset) }
            for strategy in [EBSDPatternReader.RecordStrategy.mapped, .read] {
                let reader = try EBSDPatternReader(dataset, strategy: strategy)
                for row in 0..<Self.scanRows {
                    for column in 0..<Self.scanColumns {
                        XCTAssertEqual(try reader.pattern(row: row, column: column).bytes, expected[row * Self.scanColumns + column],
                                       "\(strategy), \(recordBytes)-byte records, (\(row), \(column))")
                    }
                    XCTAssertEqual(try reader.row(row).bytes, Data(expected[(row * Self.scanColumns)..<((row + 1) * Self.scanColumns)].joined()),
                                   "\(strategy), \(recordBytes)-byte records, row \(row)")
                }
                XCTAssertEqual(try reader.allPatterns().bytes, Data(expected.joined()), "\(strategy), \(recordBytes)-byte records, all")
            }
        }
    }

    /// A file cut short after the open is refused on the next read, mapped (the held descriptor reports the shorter size) and read (the
    /// read comes back short); a file shorter than its patterns at the open is refused there.
    func testAFileCutShortIsRefusedNotRead() throws {
        let folder = try scratchFolder()
        let bytes = Self.fileBytes(recordBytes: 10)
        for strategy in [EBSDPatternReader.RecordStrategy.mapped, .read] {
            let url = folder.appendingPathComponent("records.bin")
            try bytes.write(to: url)
            let reader = try EBSDPatternReader(Self.dataset(url: url, recordBytes: 10, patternOffset: 2), strategy: strategy)
            XCTAssertEqual(try reader.pattern(row: 1, column: 2).bytes, Self.pattern(5, in: bytes, recordBytes: 10, patternOffset: 2), "\(strategy)")
            let writer = try FileHandle(forWritingTo: url)
            try writer.truncate(atOffset: 40)
            try writer.close()
            XCTAssertThrowsError(try reader.pattern(row: 1, column: 2), "\(strategy)") { error in
                XCTAssertEqual((error as? EBSDReadError)?.text, "records.bin is no longer available.", "\(strategy)")
            }
            XCTAssertThrowsError(try EBSDPatternReader(Self.dataset(url: url, recordBytes: 10, patternOffset: 2), strategy: strategy)) { error in
                XCTAssertEqual((error as? EBSDReadError)?.text, "records.bin is shorter than its 6 patterns need (40 bytes).", "\(strategy)")
            }
        }
    }
}
