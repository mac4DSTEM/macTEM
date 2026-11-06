//
//  EBSDBrowsing.swift
//  Role: the pure part of the Patterns room (docs/sem/design/ebsd-patterns-room.md): a map position and the arrow-key arithmetic, a
//        pattern as the canvas takes it, the navigation map (the mean intensity of every pattern, one pass over the scan in rows),
//        the status line's words, the Calibration and Info rows, and the Metadata JSON export. Nothing here touches a view or a
//        session, so a test pins every row. The mean is a float64 sum over the stored counts, as numpy's `mean` over the pattern axes.
//

import Foundation
import FormatoCore

/// A position in the scan: row then column, as kikuchipy's navigation axes.
package nonisolated struct EBSDPosition: Sendable, Equatable, Hashable {
    package var row: Int
    package var column: Int

    package init(row: Int, column: Int) {
        self.row = row; self.column = column
    }

    package static let origin = EBSDPosition(row: 0, column: 0)

    /// The row-major index.
    package func index(columns: Int) -> Int { row * columns + column }

    package enum Direction: Sendable, Equatable, CaseIterable { case left, right, up, down }

    /// Moved `by` positions in `direction`, held inside the scan: an arrow at the edge stays there.
    package func stepped(_ direction: Direction, by count: Int, rows: Int, columns: Int) -> EBSDPosition {
        var next = self
        switch direction {
        case .left: next.column -= count
        case .right: next.column += count
        case .up: next.row -= count
        case .down: next.row += count
        }
        return next.clamped(rows: rows, columns: columns)
    }

    package func clamped(rows: Int, columns: Int) -> EBSDPosition {
        EBSDPosition(row: min(max(row, 0), max(rows - 1, 0)), column: min(max(column, 0), max(columns - 1, 0)))
    }

    package func isInside(rows: Int, columns: Int) -> Bool { row >= 0 && row < rows && column >= 0 && column < columns }
}

package nonisolated enum EBSDBrowsing {
    /// A stored pattern as pixel values, row-major (uint8, uint16 and every other stored type through `doubles()`).
    package static func pixels(_ pattern: FormatoArray) -> [Float] {
        pattern.doubles().map(Float.init)
    }

    /// The mean intensity of every pattern in map order, as `[Float]` of `scanRows * scanColumns`: a float64 sum over the stored counts
    /// per pattern. Reads the scan one row at a time through `access`; `progress` is told after every row (0...1); `isCancelled`
    /// stops the pass with nil.
    package static func meanIntensityMap(_ access: any EBSDPatternAccess, progress: (Double) -> Void = { _ in },
                                         isCancelled: () -> Bool = { false }) throws -> [Float]? {
        let dataset = access.dataset
        let rows = dataset.scanRows, columns = dataset.scanColumns, pixels = dataset.patternPixels
        guard pixels > 0 else { return [Float](repeating: 0, count: rows * columns) }
        var out = [Float](repeating: 0, count: rows * columns)
        for row in 0..<rows {
            if isCancelled() { return nil }
            let values = try access.row(row).doubles()
            for column in 0..<columns {
                let start = column * pixels
                var sum = 0.0
                for i in start..<(start + pixels) { sum += values[i] }
                out[row * columns + column] = Float(sum / Double(pixels))
            }
            progress(Double(row + 1) / Double(rows))
        }
        return out
    }

    /// The scan unit as shown: the files write "um".
    package static func unitLabel(_ unit: String) -> String { unit == "um" ? "µm" : UnitDisplay.label(unit) }

    /// The status line over the map (control placement §7): "row 12 · col 40 · mean 118.3", then the shown virtual image's value
    /// ("· r2 c1 12 034") when the map is not the mean.
    package static func mapReadout(_ position: EBSDPosition, mean: Float?, map: (label: String, value: Float)? = nil) -> String {
        var text = "row \(position.row) · col \(position.column)"
        if let mean { text += " · mean \(UnitDisplay.number(Double(mean), digits: 4))" }
        if let map { text += " · \(map.label) \(UnitDisplay.number(Double(map.value), digits: 6))" }
        return text
    }

    /// The status line over the pattern: the detector pixel and its stored value, "x 10, y 20 · 143".
    package static func patternReadout(x: Int, y: Int, value: Float) -> String {
        "x \(x), y \(y) · \(UnitDisplay.number(Double(value), digits: 5))"
    }

    /// The live pane's header sentence: "Pattern · row 12 · col 40 · hovering" / "· pinned".
    package static func patternTitle(_ position: EBSDPosition, hovering: Bool) -> String {
        "Pattern · row \(position.row) · col \(position.column) · \(hovering ? "hovering" : "pinned")"
    }

    /// The toolbar's centre: "55 × 75 of 60 × 60".
    package static func capsuleDetail(_ dataset: EBSDDataset) -> String {
        "\(dataset.scanRows) × \(dataset.scanColumns) of \(dataset.patternRows) × \(dataset.patternColumns)"
    }

    /// One row of the Calibration or Info section.
    package struct Row: Sendable, Equatable, Identifiable {
        package var label: String
        package var value: String
        /// Two phases are two "Phase" rows: the value tells them apart.
        package var id: String { label + "·" + value }
        /// The label as an accessibility identifier's tail: "sample-tilt".
        package var key: String { label.lowercased().replacingOccurrences(of: " ", with: "-") }

        package init(_ label: String, _ value: String) { self.label = label; self.value = value }
    }

    /// The Calibration section (design §4): the geometry the file states, in its own words; a value the file lacks says so.
    package static func calibrationRows(_ dataset: EBSDDataset) -> [Row] {
        let unit = unitLabel(dataset.scanUnit)
        let detector = dataset.detector
        var rows = [
            Row("Step", "\(UnitDisplay.number(dataset.stepX)) \(unit) × \(UnitDisplay.number(dataset.stepY)) \(unit)"),
            Row("Scan", "\(dataset.scanRows) × \(dataset.scanColumns)"),
            Row("Pattern", "\(dataset.patternRows) × \(dataset.patternColumns) px" + (detector.binning > 1 ? " · binned \(detector.binning)×" : "")),
            Row("Beam", dataset.sem.beamEnergyKeV.map { "\(UnitDisplay.number($0)) kV" } ?? "None in the file"),
            Row("Sample tilt", "\(UnitDisplay.number(detector.sampleTilt))°"),
            Row("Detector tilt", "\(UnitDisplay.number(detector.tilt))°"),
        ]
        if detector.azimuthal != 0 { rows.append(Row("Azimuthal", "\(UnitDisplay.number(detector.azimuthal))°")) }
        if detector.twist != 0 { rows.append(Row("Twist", "\(UnitDisplay.number(detector.twist))°")) }
        if let pc = detector.projectionCenters.first {
            let one = "(\(UnitDisplay.number(pc.x, digits: 4)), \(UnitDisplay.number(pc.y, digits: 4)), \(UnitDisplay.number(pc.z, digits: 4)))"
            rows.append(Row("Projection centre", detector.projectionCenters.count > 1 ? "\(one) · first of \(detector.projectionCenters.count)" : one))
        } else {
            rows.append(Row("Projection centre", "None in the file"))
        }
        rows.append(Row("Convention", "Bruker"))
        if let map = dataset.crystalMap {
            for phase in map.phases {
                var words = phase.name
                if let group = phase.spaceGroup { words += " (space group \(group)" + (phase.lattice?.first.map { ", \(UnitDisplay.number($0, digits: 4)) Å" } ?? "") + ")" }
                rows.append(Row("Phase", words))
            }
        }
        return rows
    }

    /// The Info tab (design §5): what the file is.
    package static func infoRows(_ dataset: EBSDDataset, fileName: String) -> [Row] {
        var rows = [
            Row("File", fileName),
            Row("Format", dataset.version.isEmpty ? dataset.format.rawValue : "\(dataset.format.rawValue) \(dataset.version)"),
            Row("Scan", dataset.scanGroups.count > 1 ? "\(dataset.scanGroup) · of \(dataset.scanGroups.count)" : dataset.scanGroup),
            Row("Patterns", "\(dataset.patternCount) · \(dataset.patternRows) × \(dataset.patternColumns) px · \(dataset.dataType.rawValue)"),
            Row("Detector pixel", "\(UnitDisplay.number(dataset.detector.pixelSize)) µm"),
        ]
        if let microscope = dataset.sem.microscope, !microscope.isEmpty { rows.append(Row("Microscope", microscope)) }
        if let mag = dataset.sem.magnification { rows.append(Row("Magnification", "\(UnitDisplay.number(mag))×")) }
        if let wd = dataset.sem.workingDistanceMM { rows.append(Row("Working distance", "\(UnitDisplay.number(wd)) mm")) }
        rows.append(Row("Static background", dataset.staticBackground == nil ? "None in the file" : "In the file"))
        rows.append(Row("Indexed", dataset.crystalMap.map { "\($0.phases.count) \($0.phases.count == 1 ? "phase" : "phases") in the file" } ?? "Not in the file"))
        return rows
    }

    /// The Metadata JSON export: the dataset's header as the readers hold it (locale-free numbers), one object.
    package static func metadataJSON(_ dataset: EBSDDataset, fileName: String) throws -> Data {
        let detector = dataset.detector
        var object: [String: Any] = [
            "file": fileName,
            "format": dataset.format.rawValue,
            "manufacturer": dataset.manufacturer,
            "version": dataset.version,
            "scan_group": dataset.scanGroup,
            "scan_groups": dataset.scanGroups,
            "scan_shape": [dataset.scanRows, dataset.scanColumns],
            "pattern_shape": [dataset.patternRows, dataset.patternColumns],
            "dtype": dataset.dataType.rawValue,
            "step": [dataset.stepY, dataset.stepX],
            "scan_unit": dataset.scanUnit,
            "detector": [
                "shape": [detector.rows, detector.columns], "px_size": detector.pixelSize, "binning": detector.binning,
                "tilt": detector.tilt, "azimuthal": detector.azimuthal, "twist": detector.twist, "sample_tilt": detector.sampleTilt,
                "pc_convention": "bruker",
                "pc": detector.projectionCenters.map { [$0.x, $0.y, $0.z] },
            ] as [String: Any],
            "static_background": dataset.staticBackground != nil,
        ]
        var sem: [String: Any] = [:]
        if let v = dataset.sem.beamEnergyKeV { sem["beam_energy_kev"] = v }
        if let v = dataset.sem.magnification { sem["magnification"] = v }
        if let v = dataset.sem.workingDistanceMM { sem["working_distance_mm"] = v }
        if let v = dataset.sem.microscope { sem["microscope"] = v }
        object["sem"] = sem
        if let map = dataset.crystalMap {
            object["phases"] = map.phases.map { phase -> [String: Any] in
                var p: [String: Any] = ["name": phase.name]
                if let g = phase.spaceGroup { p["space_group"] = g }
                if let g = phase.pointGroup { p["point_group"] = g }
                if let l = phase.lattice { p["lattice"] = l }
                return p
            }
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    }
}
