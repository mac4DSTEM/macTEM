//
//  NORDIFScan.swift
//  Role: a NORDIF acquisition read as kikuchipy 0.13.1's `nordif` plugin reads it (`kikuchipy/io/plugins/nordif/_api.py`,
//        `file_reader`; GPL-3.0-or-later, kikuchipy developers): `Pattern.dat` is the patterns as one uint8 block in map
//        order (row, column, pattern row, pattern column), with no header; the scan and pattern sizes come from
//        `Setting.txt` beside it (`NORDIFSettings`), and the static background from `Background acquisition pattern.bmp`
//        when the folder has one. Parity: macTEMTests/Fixtures/sem/nordif/reference.json (NORDIFReaderTests).
//
//  A file shorter than the settings say reads with its missing pixels as 0 and says so in `note`, as kikuchipy pads it
//  (with a warning); a longer file reads its first `rows * columns` patterns and says so. The whole block is read into
//  memory: a NORDIF scan is at most a few hundred MB (uint8, 60 to 240 px patterns).
//

import Foundation
import FormatoCore

package nonisolated struct NORDIFScan: Equatable, Sendable {
    package var settings: NORDIFSettings
    /// Navigation shape: scan rows (ny) and columns (nx).
    package var rows: Int
    package var columns: Int
    /// Pattern shape (sy, sx).
    package var patternRows: Int
    package var patternColumns: Int
    /// The scan step, µm, in x and y.
    package var stepUM: Double
    /// `rows * columns * patternRows * patternColumns` bytes in map order.
    package var patterns: [UInt8]
    /// `Background acquisition pattern.bmp`, when the folder carries it.
    package var staticBackground: NORDIFBitmap.Image?
    /// What differed from the settings while reading, in the app's words; nil when nothing did.
    package var note: String?

    package var patternPixels: Int { patternRows * patternColumns }

    /// The pattern at scan position (`row`, `column`), row-major, the top pattern row first.
    package func pattern(row: Int, column: Int) -> ArraySlice<UInt8> {
        let start = (row * columns + column) * patternPixels
        return patterns[start ..< start + patternPixels]
    }

    package var detector: NORDIFSettings.Detector { settings.detector }

    package enum Refusal: Error, Equatable {
        case empty(String)

        package var reason: String {
            switch self {
            case .empty(let name): "\(name) is empty."
            }
        }
    }

    /// Reads `patternFile` with the settings file beside it (`Setting.txt` in the same folder unless `settingsFile` names
    /// another), as `kikuchipy.load("Pattern.dat", setting_file=...)`.
    package static func read(patternFile: String, settingsFile: String? = nil) throws -> NORDIFScan {
        let folder = (patternFile as NSString).deletingLastPathComponent
        let settings = try NORDIFSettings.read(path: settingsFile ?? (folder as NSString).appendingPathComponent("Setting.txt"))
        let data = try Data(contentsOf: URL(fileURLWithPath: patternFile), options: .alwaysMapped)
        guard !data.isEmpty else { throw Refusal.empty(formatoDisplayFileName(patternFile)) }
        let background = try? NORDIFBitmap.read(path: (folder as NSString).appendingPathComponent("Background acquisition pattern.bmp"))
        return read(data: data, settings: settings, staticBackground: background, fileName: formatoDisplayFileName(patternFile))
    }

    package static func read(data: Data, settings: NORDIFSettings, staticBackground: NORDIFBitmap.Image?, fileName: String) -> NORDIFScan {
        let rows = settings.area.rows, columns = settings.area.columns
        let patternRows = settings.acquisition.resolution.height, patternColumns = settings.acquisition.resolution.width
        let size = rows * columns * patternRows * patternColumns
        var patterns = [UInt8](data.prefix(size))
        var note: String?
        if patterns.count < size {
            note = "\(fileName) ends \(size - patterns.count) bytes before its last pattern (\(rows) x \(columns) patterns of "
                + "\(patternColumns) x \(patternRows) px from the settings); the missing pixels read 0."
            patterns.append(contentsOf: [UInt8](repeating: 0, count: size - patterns.count))
        } else if data.count > size {
            note = "\(fileName) is \(data.count - size) bytes longer than its \(rows) x \(columns) patterns of "
                + "\(patternColumns) x \(patternRows) px from the settings; the rest is not read."
        }
        return NORDIFScan(settings: settings, rows: rows, columns: columns, patternRows: patternRows, patternColumns: patternColumns,
                          stepUM: settings.area.stepUM, patterns: patterns, staticBackground: staticBackground, note: note)
    }
}
