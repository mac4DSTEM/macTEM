//
//  ANGWriter.swift
//  Role: write a `CrystalMap` as an EDAX TSL `.ang` file, as orix 0.15.0's `orix/io/plugins/ang.py` `file_writer` writes it
//        (GPL-3.0-or-later, see NOTICE): the header with the phases in reversed order (EDAX TSL OIM Analysis 7.2 reads them
//        so), each phase's proper point group under EDAX's alias, the lattice at three decimals, the grid and steps; then one
//        row per point of the data extent with phi1, Phi, phi2 (the rotations' Bunge angles, `to_euler`), x, y, image
//        quality, confidence index, phase id, detector signal, pattern fit and any extra columns, every number rounded to
//        five decimals as numpy rounds (`np.round`: times 10⁵, half to even, divided) and the property columns held in
//        float32 as orix holds them. Points not indexed or not in data take orix's values (Euler 4π, IQ 0, CI −1, phase 0
//        on a multi-phase map and −1 on a one-phase map, detector signal 0, fit 180, extra 0). Coordinates restart at 0 on
//        the data extent with the map's steps (`create_coordinate_arrays`); a 1D map is one row with y step 1.
//
//        Parity: `tools/parity/sem` bundles `m8/write-ang-*` (figure F18): the written bytes equal orix's for the sdss map,
//        its ferrite points, a 10 × 10 window and the Ti head; orix reads each back to the written precision.
//

import FormatoCore
import Foundation

package nonisolated enum ANGWriter {
    package static let fileExtension = "ang"

    /// orix's `file_writer` keywords: which property feeds each column (nil: orix's search by name), extra columns, and the
    /// `OPERATOR:` line (orix writes `orix_v<version>`).
    package struct Options: Sendable, Equatable {
        package var imageQuality: String?
        package var confidenceIndex: String?
        package var detectorSignal: String?
        package var patternFit: String?
        package var extraProperties: [String]
        package var operatorName: String

        package init(imageQuality: String? = nil, confidenceIndex: String? = nil, detectorSignal: String? = nil, patternFit: String? = nil,
                     extraProperties: [String] = [], operatorName: String = "macTEM") {
            self.imageQuality = imageQuality; self.confidenceIndex = confidenceIndex; self.detectorSignal = detectorSignal
            self.patternFit = patternFit; self.extraProperties = extraProperties; self.operatorName = operatorName
        }
    }

    /// orix's `_get_prop_arrays` names, lowercased with underscores removed, in its order per column.
    static let searchNames: [[String]] = [["iq", "imagequality"], ["ci", "confidenceindex", "scores", "correlation"],
                                          ["ss", "semsignal", "detectorsignal"], ["fit", "patternfit"]]

    /// orix's `_EDAX_POINT_GROUP_ALIASES` (`orix.quaternion.symmetry`): the name EDAX writes for a proper point group.
    static let edaxAliases = ["121": "20", "2/m": "2", "222": "22", "422": "42", "321": "32", "622": "62", "432": "43", "m-3m": "m3m"]

    /// The file's text.
    package static func text(of map: CrystalMap, options: Options = Options()) throws -> String {
        let grid = try CrystalMapExtent(map)
        let n = grid.count
        let phases = map.phases.entries.filter { $0.id != PhaseList.notIndexedID }

        var header = "TEM_PIXperUM           1.000000\nx-star                 0.000000\ny-star                 0.000000\n"
            + "z-star                 0.000000\nWorkingDistance        0.000000\n\n"
        for (i, entry) in phases.enumerated().reversed() {
            let phase = entry.phase
            let lattice = (phase.lattice ?? CrystalMapExtent.defaultLattice).map { String(format: "%.3f", $0) }.joined(separator: " ")
            let name = phase.name.isEmpty ? "phase\(i + 1)" : phase.name
            var symmetry = "1"
            if let pg = phase.pointGroupName {
                let proper = PointGroup.named(pg)?.properSubgroup.name ?? pg
                symmetry = edaxAliases[proper] ?? proper
            }
            header += "Phase \(i + 1)\nMaterialName    \(name)\nFormula    \(name)\nInfo\nSymmetry    \(symmetry)\n"
                + "LatticeConstants    \(lattice)\nNumberFamilies    0\n"
        }
        header += "GRID: SqrGrid\nXSTEP: \(String(format: "%.6f", map.dx))\nYSTEP: \(String(format: "%.6f", map.dy))\n"
            + "NCOLS_ODD: \(grid.columns)\nNCOLS_EVEN: \(grid.columns)\nNROWS: \(grid.rows)\n\nOPERATOR: \(options.operatorName)\n\n"
            + "SAMPLEID:\n\nSCANID:\n"
        header += "\nColumn names: phi1, Phi, phi2, x, y, image_quality, confidence_index, phase_id, detector_signal, pattern_fit"
        for name in options.extraProperties { header += ", \(name)" }
        header += "\n"

        // Rotations: Bunge angles of the points in data, 0 elsewhere, rounded; 4π where not indexed or not in data.
        var euler = [[Double]](repeating: [], count: 3)
        let angles = map.rotationsInData.map(RotationConversions.qu2eu)
        for k in 0..<3 { euler[k] = map.mapData(angles.map { $0[k] }, fill: 0).map(round5) }
        let indexed = grid.indexed
        for i in 0..<n where !indexed[i] { for k in 0..<3 { euler[k][i] = 4 * .pi } }

        // Properties in float32, as orix's `prop_arrays`.
        let chosen = [options.imageQuality, options.confidenceIndex, options.detectorSignal, options.patternFit]
        var columns: [[Double]] = []
        for (k, given) in chosen.enumerated() {
            columns.append(try column(map, given: given, search: searchNames[k], grid: grid))
        }
        for name in options.extraProperties { columns.append(try column(map, given: name, search: [], grid: grid)) }
        for i in 0..<n where !indexed[i] {
            columns[0][i] = 0; columns[1][i] = -1; columns[2][i] = 0; columns[3][i] = 180
            for k in 4..<columns.count { columns[k][i] = 0 }
        }

        // Phase ids: position + 1 in the list (header order reversed); not indexed 0 on a multi-phase map, −1 on one phase.
        let originalIDs = map.mapData(map.phaseIDs.map(Double.init), fill: .nan)
        var phaseColumn = [Int](repeating: phases.count > 1 ? 0 : -1, count: n)
        for (i, entry) in phases.enumerated().reversed() {
            for p in 0..<n where originalIDs[p] == Double(entry.id) { phaseColumn[p] = i + 1 }
        }

        // Every format is built once with its column width (orix's `fmt`), as numpy's `savetxt` applies it to each row.
        let lead = "%8.5f  %8.5f  %8.5f  %\(width(grid.x.max() ?? 0)).5f  %\(width(grid.y.max() ?? 0)).5f  "
        let widths = columns.map { width($0.max() ?? 0) }
        let middle = "%\(widths[0]).5f  %\(widths[1]).5f  %2ld  %\(widths[2]).5f  %\(widths[3]).5f"
        let extras = widths.dropFirst(4).map { "  %\($0).5f" }
        var out = ""
        out.reserveCapacity(header.utf8.count + n * (70 + 12 * options.extraProperties.count))
        for line in header.split(separator: "\n", omittingEmptySubsequences: false).dropLast() { out += "# \(line)\n" }
        out += "# \n"
        for i in 0..<n {
            out += String(format: lead, euler[0][i], euler[1][i], euler[2][i], grid.x[i], grid.y[i])
            out += String(format: middle, columns[0][i], columns[1][i], phaseColumn[i], columns[2][i], columns[3][i])
            for (k, format) in extras.enumerated() { out += String(format: format, columns[4 + k][i]) }
            out += "\n"
        }
        return out
    }

    /// Writes the file through `FormatoFileWrite` (a scratch file first, then over `url`).
    package static func write(_ map: CrystalMap, to url: URL, options: Options = Options()) throws {
        try FormatoFileWrite.write(Data(try text(of: map, options: options).utf8), to: url)
    }

    // MARK: - Helpers

    /// numpy's `np.round(x, 5)`: x · 10⁵ rounded half to even, divided by 10⁵.
    static func round5(_ x: Double) -> Double { (x * 100_000.0).rounded(.toNearestOrEven) / 100_000.0 }

    /// orix's `_get_column_width`: the digits of the integer part of the column's largest value, a point, five decimals and
    /// a sign.
    static func width(_ largest: Double) -> Int { String(Int(largest.rounded(.down))).count + 7 }

    /// One property column on the extent, rounded to five decimals and held in float32 (orix's `_get_prop_array`); zeros
    /// when the map has no such property.
    private static func column(_ map: CrystalMap, given: String?, search: [String], grid: CrystalMapExtent) throws -> [Double] {
        let name: String?
        if let given {
            guard map.properties[given] != nil else { throw CrystalMapExtent.Refusal.noProperty(given) }
            name = given
        } else {
            name = CrystalMapExtent.property(in: map, named: search)
        }
        guard let name, let values = map.property(name) else { return [Double](repeating: 0, count: grid.count) }
        return map.mapData(values, fill: 0).map { Double(Float(round5($0))) }
    }
}

/// The rectangle a writer writes: the data extent's rows and columns (a 1D map is one row), x and y restarted at 0 with the
/// map's steps (orix's `create_coordinate_arrays`), and which of its points are indexed (false where not in data).
package nonisolated struct CrystalMapExtent: Sendable {
    package enum Refusal: Error, Equatable, Sendable, LocalizedError {
        /// A map with no axis to write (one point, or no points).
        case noGrid
        /// A property asked for by name that the map does not hold.
        case noProperty(String)

        package var errorDescription: String? {
            switch self {
            case .noGrid: "The map has no rows or columns to write."
            case .noProperty(let name): "The map has no property named \(name)."
            }
        }
    }

    /// orix's lattice when a phase has no structure: 1, 1, 1, 90°, 90°, 90°.
    static let defaultLattice: [Double] = [1, 1, 1, 90, 90, 90]

    package let rows: Int
    package let columns: Int
    package let dy: Double
    package let dx: Double
    package let x: [Double]
    package let y: [Double]
    package let indexed: [Bool]
    package var count: Int { rows * columns }

    package init(_ map: CrystalMap) throws {
        let shape = map.shape
        guard shape.count == 1 || shape.count == 2 else { throw Refusal.noGrid }
        rows = shape.count == 1 ? 1 : shape[0]
        columns = shape.count == 1 ? shape[0] : shape[1]
        dy = shape.count == 1 ? 1 : map.dy
        dx = map.dx
        guard rows > 0, columns > 0 else { throw Refusal.noGrid }
        let grid = CrystalMap.coordinates(shape: (rows, columns), steps: (dy, dx))
        x = grid.x
        y = grid.y
        indexed = map.mapData(map.isIndexed.map { $0 ? 1.0 : 0.0 }, fill: 0).map { $0 == 1 }
    }

    /// The first property whose name, lowercased with underscores removed, is one of `candidates` (tried in their order).
    static func property(in map: CrystalMap, named candidates: [String]) -> String? {
        let names = map.propertyNames
        for candidate in candidates {
            if let hit = names.first(where: { $0.lowercased().replacingOccurrences(of: "_", with: "") == candidate }) { return hit }
        }
        return nil
    }
}
