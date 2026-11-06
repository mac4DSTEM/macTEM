//
//  EDAXBinaryReader.swift
//  Role: EDAX TSL's binary pattern files (`.up1`: uint8 patterns, `.up2`: uint16), read as kikuchipy 0.13.1 reads them
//        (`kikuchipy/io/plugins/edax_binary/_api.py`, GPL-3.0-or-later, itself adapted from PyEBSDIndex's reader): the header (version,
//        pattern width and height, pattern offset; from version 3 the map width and height, the hexagonal-grid flag and the step in
//        µm), the pattern count from the file size for a version 1 file or a hexagonal grid (one row of patterns, kikuchipy's one
//        navigation dimension, with its warning as `note`), and the patterns by index or map position, as stored. Version 2 is refused
//        as upstream refuses it. The pairing with the `.ang` map next to the file is `EDAXOpening`.
//        Parity: macTEMTests/EDAXBinaryReaderTests.swift against ebsd-edax.truth.json (tools/parity/sem-readers/make_edax_fixtures.py).
//

import Foundation
import FormatoCore

/// The header of an EDAX `.up1`/`.up2` file, and where its patterns are.
package nonisolated struct EDAXBinaryFile: Sendable, Equatable {
    package var url: URL
    /// The file's version word (1, or 3 and above; 2 is refused).
    package var version: Int
    /// Pattern height (`sy`) and width (`sx`) in pixels.
    package var patternRows: Int
    package var patternColumns: Int
    /// Byte offset of the first pattern.
    package var patternOffset: Int
    /// Map rows (`ny`) and columns (`nx`): the file's own for a square grid of version 3 and above; one row of every pattern for a
    /// version 1 file (no grid in the header) and for a hexagonal grid, as kikuchipy returns them.
    package var scanRows: Int
    package var scanColumns: Int
    /// Patterns in the file (`n_patterns`): `scanRows * scanColumns`.
    package var patternCount: Int
    /// Step along x (`dx`) and y (`dy`) in µm; 1 for a version 1 file, which states none.
    package var stepX: Double
    package var stepY: Double
    package var scanUnit: String = "um"
    /// The hexagonal-grid flag of a version 3 file (false for version 1).
    package var isHexagonal: Bool
    /// `.uint8` for `.up1`, `.uint16` for `.up2`.
    package var dataType: FormatoDataType
    /// kikuchipy's warning for a hexagonal grid, in its words; nil otherwise.
    package var note: String?

    package var patternPixels: Int { patternRows * patternColumns }
    package var bytesPerPattern: Int { patternPixels * dataType.byteSize }
}

package nonisolated enum EDAXBinaryReader {
    /// The two extensions, lowercased, each with its element type.
    package static let readableExtensions = ["up1", "up2"]

    package static func dataType(forExtension ext: String) -> FormatoDataType? {
        switch ext.lowercased() {
        case "up1": return .uint8
        case "up2": return .uint16
        default: return nil
        }
    }

    /// kikuchipy's warning for a hexagonal grid, verbatim.
    package static let hexagonalNote = "Returned signal has one navigation dimension since an hexagonal grid is not supported"

    /// The header of the file at `url`; the patterns stay in the file (`pattern(_:index:)`, `allPatterns(_:)`).
    package static func read(url: URL) throws -> EDAXBinaryFile {
        let name = url.lastPathComponent
        guard let dataType = dataType(forExtension: url.pathExtension) else {
            throw EDAXReadError(text: "\(name) is not an EDAX pattern file (.up1 or .up2).")
        }
        let data: Data
        do { data = try Data(contentsOf: url, options: .alwaysMapped) } catch {
            throw EDAXReadError(text: "\(name) could not be read: \((error as NSError).localizedDescription)")
        }
        return try read(data: data, url: url, dataType: dataType)
    }

    /// The header from the file's bytes (`url` names it and sizes it: `data.count` is the file size kikuchipy divides).
    package static func read(data: Data, url: URL, dataType: FormatoDataType) throws -> EDAXBinaryFile {
        let name = url.lastPathComponent
        func word(_ offset: Int) throws -> Int {
            guard offset + 4 <= data.count else { throw EDAXReadError(text: "\(name) ends before its header does (\(data.count) bytes).") }
            return Int(UInt32(littleEndian: data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }))
        }
        func double(_ offset: Int) throws -> Double {
            guard offset + 8 <= data.count else { throw EDAXReadError(text: "\(name) ends before its header does (\(data.count) bytes).") }
            return Double(bitPattern: UInt64(littleEndian: data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self) }))
        }
        let version = try word(0)
        guard version != 2 else { throw EDAXReadError(text: "\(name) is a version 2 file; only files with version 1 or 3 and above are read, as kikuchipy reads them.") }
        guard version >= 1 else { throw EDAXReadError(text: "\(name) has version \(version), which is not an EDAX pattern file (1, or 3 and above).") }
        let sx = try word(4), sy = try word(8), offset = try word(12)
        guard sx > 0, sy > 0 else { throw EDAXReadError(text: "\(name) states a \(sx) x \(sy) pattern.") }
        guard offset <= data.count else { throw EDAXReadError(text: "\(name) puts its patterns at byte \(offset), past the end of the file (\(data.count) bytes).") }
        let bytesPerPattern = sx * sy * dataType.byteSize
        let count: Int
        var nx: Int, ny: Int, dx = 1.0, dy = 1.0, isHex = false
        if version == 1 {
            count = (data.count - offset) / bytesPerPattern
            nx = count; ny = 1
        } else {
            // Upstream reads nx, ny one byte after the first four words (`np.fromfile(..., offset=1)`), the hex flag as one byte, then dx, dy.
            nx = try word(17); ny = try word(21)
            guard 25 < data.count else { throw EDAXReadError(text: "\(name) ends before its header does (\(data.count) bytes).") }
            isHex = data[data.startIndex + 25] != 0
            dx = try double(26); dy = try double(34)
            if isHex {
                count = (data.count - offset) / bytesPerPattern
                nx = count; ny = 1
            } else {
                count = nx * ny
                guard offset + count * bytesPerPattern <= data.count else {
                    throw EDAXReadError(text: "\(name) states \(ny) x \(nx) patterns of \(sy) x \(sx) but holds \((data.count - offset) / bytesPerPattern).")
                }
            }
        }
        return EDAXBinaryFile(url: url, version: version, patternRows: sy, patternColumns: sx, patternOffset: offset, scanRows: ny, scanColumns: nx,
                              patternCount: count, stepX: dx, stepY: dy, isHexagonal: isHex, dataType: dataType, note: isHex ? hexagonalNote : nil)
    }

    /// Pattern `index` (file order, row-major in the map), shape (patternRows, patternColumns), as stored.
    package static func pattern(_ file: EDAXBinaryFile, index: Int) throws -> FormatoArray {
        guard index >= 0, index < file.patternCount else {
            throw EDAXReadError(text: "Pattern \(index) is outside the \(file.patternCount) patterns of \(file.url.lastPathComponent).")
        }
        let data = try mapped(file)
        let start = file.patternOffset + index * file.bytesPerPattern
        return try FormatoArray(dataType: file.dataType, shape: [file.patternRows, file.patternColumns],
                                bytes: data.subdata(in: (data.startIndex + start)..<(data.startIndex + start + file.bytesPerPattern)))
    }

    /// The pattern at map position (row, column).
    package static func pattern(_ file: EDAXBinaryFile, row: Int, column: Int) throws -> FormatoArray {
        guard row >= 0, row < file.scanRows, column >= 0, column < file.scanColumns else {
            throw EDAXReadError(text: "Position (\(row), \(column)) is outside the \(file.scanRows) x \(file.scanColumns) scan of \(file.url.lastPathComponent).")
        }
        return try pattern(file, index: row * file.scanColumns + column)
    }

    /// Every pattern, shape (scanRows, scanColumns, patternRows, patternColumns), as stored: one slice of the mapped file.
    package static func allPatterns(_ file: EDAXBinaryFile) throws -> FormatoArray {
        let data = try mapped(file)
        let start = data.startIndex + file.patternOffset
        return try FormatoArray(dataType: file.dataType, shape: [file.scanRows, file.scanColumns, file.patternRows, file.patternColumns],
                                bytes: data.subdata(in: start..<(start + file.patternCount * file.bytesPerPattern)))
    }

    private static func mapped(_ file: EDAXBinaryFile) throws -> Data {
        let data: Data
        do { data = try Data(contentsOf: file.url, options: .alwaysMapped) } catch {
            throw EDAXReadError(text: "\(file.url.lastPathComponent) could not be read: \((error as NSError).localizedDescription)")
        }
        guard data.count >= file.patternOffset + file.patternCount * file.bytesPerPattern else {
            throw EDAXReadError(text: "\(file.url.lastPathComponent) is shorter than when it was opened (\(data.count) bytes).")
        }
        return data
    }
}

/// What the EDAX readers say when a file is not what it claims, in one sentence for the Open Files row.
package nonisolated struct EDAXReadError: Error, LocalizedError, Equatable {
    package var text: String
    package var errorDescription: String? { text }
    package init(text: String) { self.text = text }
}
