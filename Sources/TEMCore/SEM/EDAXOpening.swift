//
//  EDAXOpening.swift
//  Role: an EDAX scan at the app's door, as one `EBSDDataset`: the `.up1`/`.up2` pattern file and the `.ang` orientation map EDAX
//        writes next to it with the same name, paired by name whichever of the two is opened. A hexagonal grid in either file is
//        refused with a sentence (decision D-SEM-9: square grids only in phase 1; kikuchipy reads the patterns of a hexagonal `.up`
//        file as one row, which `EDAXBinaryReader` keeps for parity, and the app does not lay them out). A version 1 `.up1` carries no
//        grid, so its scan shape and step come from the `.ang` when the point counts agree; a map whose point count differs from the
//        pattern count is not the scan's and is left out with a note. A map alone, without its patterns, opens in the Maps room instead
//        (D-SEM-70; D-SEM-25 refused it). The detector is kikuchipy's default for the binary file (projection centre 0.5, 0.5, 0.5, sample
//        tilt 70°); with an `.ang`, its `x-star`, `y-star`, `z-star` are a TSL-convention centre, converted to Bruker's.
//

import Foundation

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

    /// The pattern file an open of `url` reads: `url` itself, or the `.up1`/`.up2` next to a `.ang`; the refusal sentence when there is none.
    package static func patternFile(for url: URL) throws -> URL {
        let ext = url.pathExtension.lowercased()
        if EDAXBinaryReader.readableExtensions.contains(ext) { return url }
        guard ANGReader.readableExtensions.contains(ext) else {
            throw EDAXReadError(text: "\(url.lastPathComponent) is not an EDAX pattern file (.up1, .up2) or orientation map (.ang).")
        }
        guard let patterns = companion(of: url, extensions: EDAXBinaryReader.readableExtensions) else {
            // A hexagonal map is refused for its grid first, the sentence it gets with its patterns too (D-SEM-9).
            if let map = try? ANGReader.read(url: url), map.header.isHexagonal {
                throw EDAXReadError(text: "\(url.lastPathComponent) is a hexagonal grid (\(map.header.grid ?? "HexGrid")); only square-grid EBSD maps are read.")
            }
            throw EDAXReadError(text: "\(url.lastPathComponent) is an orientation map without its patterns: open the .up1 or .up2 of the same name next to it, which reads the map with it.")
        }
        return patterns
    }

    /// Opens the `.up1`, `.up2` or `.ang` at `url` and the companion next to it. Reads the whole `.ang` (text); run it off the main actor.
    package static func open(url: URL) throws -> EBSDDataset {
        let patternsURL = try patternFile(for: url)
        let mapURL = patternsURL == url ? companion(of: url, extensions: ANGReader.readableExtensions) : url
        var notes: [String] = []
        let patterns = try EDAXBinaryReader.read(url: patternsURL)
        if patterns.isHexagonal {
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
        if let found = map, found.pointCount != patterns.patternCount {
            notes.append("\(found.url.lastPathComponent) next to it has \(found.pointCount) points for \(patterns.patternCount) patterns and was left out.")
            map = nil
        }
        var rows = patterns.scanRows, columns = patterns.scanColumns
        var stepX = patterns.stepX, stepY = patterns.stepY, unit = patterns.scanUnit
        if patterns.version == 1, let map, map.map.shape.count == 2, map.map.shape[0] * map.map.shape[1] == patterns.patternCount {
            rows = map.map.shape[0]; columns = map.map.shape[1]; stepX = map.map.dx; stepY = map.map.dy; unit = map.map.scanUnit
        }

        var detector = EBSDDetectorGeometry(rows: patterns.patternRows, columns: patterns.patternColumns, projectionCenters: [SIMD3(0.5, 0.5, 0.5)])
        var sem = EBSDSEMHeader()
        if let map {
            if let pc = map.header.projectionCenter { detector.projectionCenters = [detector.brukerCenter(pc, from: .tsl)] }
            sem.workingDistanceMM = map.header.workingDistance
        }
        let source = EBSDPatternSource(url: patterns.url, layout: .records(offset: patterns.patternOffset, recordBytes: patterns.bytesPerPattern, patternOffset: 0),
                                       fileShape: [patterns.patternCount, patterns.patternRows, patterns.patternColumns], dataType: patterns.dataType)
        return EBSDDataset(format: .edaxBinary, manufacturer: "edax", version: String(patterns.version), scanGroup: "", scanGroups: [],
                           scanRows: rows, scanColumns: columns, patternRows: patterns.patternRows, patternColumns: patterns.patternColumns,
                           dataType: patterns.dataType, stepY: stepY, stepX: stepX, scanUnit: unit, detector: detector, sem: sem,
                           crystalMap: map?.map, patterns: source, notes: notes)
    }
}
