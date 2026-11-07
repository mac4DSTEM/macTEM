//
//  EBSDPatternAccess.swift
//  Role: the one way the Patterns room reaches a dataset's patterns, whatever holds them: the file (`EBSDPatternReader`, one HDF5
//        slab per request) or memory (`EBSDMemoryPatterns`, the generated demo dataset and the tests' planted scans). Both answer
//        one pattern by map position and one scan row at a time, so a pass over the scan (the navigation map) reads the file in
//        row-sized slabs, never the whole dataset at once.
//

import Foundation
import FormatoCore

/// Patterns by map position. Every method is synchronous and may block on I/O: call it off the main actor.
package nonisolated protocol EBSDPatternAccess: Sendable {
    var dataset: EBSDDataset { get }
    /// The pattern at (row, column), shape (patternRows, patternColumns), as stored; zero where the file has none.
    func pattern(row: Int, column: Int) throws -> FormatoArray
    /// One scan row of patterns, shape (scanColumns, patternRows, patternColumns), in map order.
    func row(_ row: Int) throws -> FormatoArray
}

extension EBSDPatternReader: EBSDPatternAccess {
    /// One slab when the file order is the map order and the row is inside the file; else pattern by pattern (a Bruker region of
    /// interest, a file shorter than its scan).
    package func row(_ row: Int) throws -> FormatoArray {
        guard row >= 0, row < dataset.scanRows else {
            throw EBSDReadError(text: "Row \(row) is outside the \(dataset.scanRows) x \(dataset.scanColumns) scan.")
        }
        let columns = dataset.scanColumns
        let shape = [columns, dataset.patternRows, dataset.patternColumns]
        let source = dataset.patterns
        let first = row * columns
        if source.fileIndexByPosition == nil, first + columns <= source.fileCount {
            let slab = try rowSlab(row: row)
            return try FormatoArray(dataType: slab.dataType, shape: shape, bytes: slab.bytes)
        }
        var bytes = Data()
        bytes.reserveCapacity(columns * dataset.patternPixels * dataset.dataType.byteSize)
        for column in 0..<columns {
            let one = try pattern(row: row, column: column)
            bytes.append(one.bytes)
        }
        return try FormatoArray(dataType: dataset.dataType, shape: shape, bytes: bytes)
    }
}

/// A dataset whose patterns are in memory, in map order (row-major scan, then row-major pattern pixels).
package nonisolated final class EBSDMemoryPatterns: EBSDPatternAccess {
    package let dataset: EBSDDataset
    /// `patternCount * patternPixels * byteSize` bytes, little-endian as `FormatoArray` holds them.
    package let bytes: Data

    package init(dataset: EBSDDataset, bytes: Data) throws {
        let expected = dataset.patternCount * dataset.patternPixels * dataset.dataType.byteSize
        guard bytes.count == expected else {
            throw EBSDReadError(text: "EBSDMemoryPatterns: \(bytes.count) bytes for \(dataset.patternCount) patterns of \(dataset.patternPixels) \(dataset.dataType.rawValue) pixels (\(expected) expected).")
        }
        self.dataset = dataset
        self.bytes = bytes
    }

    package func pattern(row: Int, column: Int) throws -> FormatoArray {
        guard row >= 0, row < dataset.scanRows, column >= 0, column < dataset.scanColumns else {
            throw EBSDReadError(text: "Position (\(row), \(column)) is outside the \(dataset.scanRows) x \(dataset.scanColumns) scan.")
        }
        let size = dataset.patternPixels * dataset.dataType.byteSize
        let start = (row * dataset.scanColumns + column) * size
        return try FormatoArray(dataType: dataset.dataType, shape: [dataset.patternRows, dataset.patternColumns], bytes: bytes.subdata(in: start..<(start + size)))
    }

    package func row(_ row: Int) throws -> FormatoArray {
        guard row >= 0, row < dataset.scanRows else {
            throw EBSDReadError(text: "Row \(row) is outside the \(dataset.scanRows) x \(dataset.scanColumns) scan.")
        }
        let size = dataset.scanColumns * dataset.patternPixels * dataset.dataType.byteSize
        let start = row * size
        return try FormatoArray(dataType: dataset.dataType, shape: [dataset.scanColumns, dataset.patternRows, dataset.patternColumns],
                                bytes: bytes.subdata(in: start..<(start + size)))
    }
}
