//
//  EDAXOpening.swift
//  Role: an EDAX scan at the app's door: the `.up1`/`.up2` pattern file and the `.ang` orientation map EDAX writes next to it with the
//        same name, paired by name whichever of the two is opened. A hexagonal grid in either file is refused with a sentence (decision
//        D-SEM-9: square grids only in phase 1; kikuchipy reads the patterns of a hexagonal `.up` file as one row, which `EDAXBinaryReader`
//        keeps for parity, and the app does not lay them out). A version 1 `.up1` carries no grid, so its scan shape and step come from the
//        `.ang` when the point counts agree; a map whose point count differs from the pattern count is not the scan's and is left out
//        with a note.
//

import Foundation

/// An EDAX scan: its patterns, its map, or both.
package nonisolated struct EDAXScan: Sendable, Equatable {
    package var patterns: EDAXBinaryFile?
    package var map: ANGMap?
    /// The scan grid (rows, columns) the app lays out: the `.up` file's own, or the `.ang`'s shape for a version 1 file.
    package var scanRows: Int
    package var scanColumns: Int
    package var stepX: Double
    package var stepY: Double
    package var scanUnit: String
    /// What was left out and why, one sentence each, for the Open Files row.
    package var notes: [String]
}

package nonisolated enum EDAXOpening {
    package static let readableExtensions = EDAXBinaryReader.readableExtensions + ANGReader.readableExtensions

    /// The file next to `url` with the same name and one of `extensions` (lowercased, then uppercased), or nil.
    package static func companion(of url: URL, extensions: [String]) -> URL? {
        let folder = url.deletingLastPathComponent()
        let stem = url.deletingPathExtension().lastPathComponent
        for ext in extensions {
            for variant in [ext, ext.uppercased()] {
                let candidate = folder.appendingPathComponent(stem).appendingPathExtension(variant)
                if candidate.path != url.path, FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            }
        }
        return nil
    }

    /// Opens the `.up1`, `.up2` or `.ang` at `url` and the companion next to it. Reads the whole `.ang` (text); run it off the main actor.
    package static func open(url: URL) throws -> EDAXScan {
        let ext = url.pathExtension.lowercased()
        var patternsURL: URL?, mapURL: URL?
        if EDAXBinaryReader.readableExtensions.contains(ext) {
            patternsURL = url
            mapURL = companion(of: url, extensions: ANGReader.readableExtensions)
        } else if ANGReader.readableExtensions.contains(ext) {
            mapURL = url
            patternsURL = companion(of: url, extensions: EDAXBinaryReader.readableExtensions)
        } else {
            throw EDAXReadError(text: "\(url.lastPathComponent) is not an EDAX pattern file (.up1, .up2) or orientation map (.ang).")
        }
        var notes: [String] = []
        let patterns = try patternsURL.map { try EDAXBinaryReader.read(url: $0) }
        if let patterns, patterns.isHexagonal {
            throw EDAXReadError(text: "\(patterns.url.lastPathComponent) was acquired on a hexagonal grid; only square-grid EBSD maps are read.")
        }
        var map: ANGMap?
        if let mapURL {
            do { map = try ANGReader.read(url: mapURL) } catch let error as ANGReadError where mapURL != url {
                // The companion is not the map it should be: the patterns open on their own, with the reason.
                notes.append("\(mapURL.lastPathComponent) next to it was not read: \(error.text)")
            }
        }
        if let map, map.header.isHexagonal {
            throw EDAXReadError(text: "\(map.url.lastPathComponent) is a hexagonal grid (\(map.header.grid ?? "HexGrid")); only square-grid EBSD maps are read.")
        }
        if let patterns, let found = map, found.pointCount != patterns.patternCount {
            notes.append("\(found.url.lastPathComponent) next to it has \(found.pointCount) points for \(patterns.patternCount) patterns and was left out.")
            map = nil
        }
        var rows: Int, columns: Int, stepX: Double, stepY: Double, unit: String
        if let patterns {
            rows = patterns.scanRows; columns = patterns.scanColumns; stepX = patterns.stepX; stepY = patterns.stepY; unit = patterns.scanUnit
            if patterns.version == 1, let map, map.shape.count == 2, map.shape[0] * map.shape[1] == patterns.patternCount {
                rows = map.shape[0]; columns = map.shape[1]; stepX = map.dx; stepY = map.dy; unit = map.scanUnit
            }
        } else if let map {
            rows = map.shape.count == 2 ? map.shape[0] : 1
            columns = map.shape.count == 2 ? map.shape[1] : (map.shape.first ?? map.pointCount)
            stepX = map.dx; stepY = map.dy; unit = map.scanUnit
        } else {
            throw EDAXReadError(text: "\(url.lastPathComponent) holds neither patterns nor a map.")
        }
        return EDAXScan(patterns: patterns, map: map, scanRows: rows, scanColumns: columns, stepX: stepX, stepY: stepY, scanUnit: unit, notes: notes)
    }
}
