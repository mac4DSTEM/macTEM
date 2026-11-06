//
//  NORDIFSettings.swift
//  Role: `Setting.txt` of a NORDIF acquisition (UF-1100, UF-420) read as kikuchipy 0.13.1 reads it
//        (`kikuchipy/io/plugins/nordif/_api.py`, `_get_settings_from_file`; GPL-3.0-or-later, kikuchipy developers):
//        the microscope, the detector angles, the acquisition and calibration pattern settings, the area and the
//        pattern positions. The parity is macTEMTests/Fixtures/sem/nordif/reference.json, emitted by
//        tools/parity/sem/nordif/reference.py; NORDIFReaderTests compares every field.
//
//  The file is tab-separated `key<TAB>value<TAB>unit` lines under `[Section]` headers, written in Latin-1 (kikuchipy
//  decodes it so; a UTF-8 copy reads with mojibake in the unit column, which no value reads from). kikuchipy reads each
//  value from a fixed line offset below its section header; this reader looks the key up within its section, which
//  gives the same values on every file of the parity set, including the three damaged ones, and refuses a file whose
//  required line is missing where kikuchipy would fail on `float("")`.
//
//  Conventions kept from kikuchipy, each with its line in `_api.py`:
//  - `Number of samples	3x3` reads as rows x columns (ny, nx); `Resolution	60x60` as width x height (sx, sy).
//  - The detector tilt is minus the `Elevation` angle (`tilt = -elevation`, never -0.0); `Tilt angle` is the sample
//    tilt; `Azimuthal` is the azimuthal angle. A NORDIF settings file carries no projection centre, binning or pixel
//    size: `detector` holds kikuchipy's `EBSDDetector` defaults for them (pc (0.5, 0.5, 0.5), binning 1, 1 µm).
//  - The scan step is `Step size`, the same in x and y.
//  - A calibration or acquisition position is the `(x,y)` in the key of its line (`Calibration (425,447)`), in pixels
//    of the electron image; a line without the parentheses is not a position (kikuchipy's regex).
//

import Foundation
import FormatoCore

package nonisolated struct NORDIFSettings: Equatable, Sendable {
    /// A length in the `[Area]` section: `89.200 (223)	µm (px)`.
    package struct Measure: Equatable, Sendable {
        package var micrometres: Double
        package var pixels: Int

        package init(micrometres: Double, pixels: Int) {
            self.micrometres = micrometres
            self.pixels = pixels
        }
    }

    /// `WxH` in pixels.
    package struct Resolution: Equatable, Sendable {
        package var width: Int
        package var height: Int

        package init(width: Int, height: Int) {
            self.width = width
            self.height = height
        }
    }

    /// `[Acquisition settings]` or `[Calibration settings]`.
    package struct PatternSettings: Equatable, Sendable {
        package var frameRateFPS: Double?
        package var resolution: Resolution
        package var exposureUS: Double?
        package var gain: Double?
    }

    /// A pattern position in pixels of the electron image, as written in the key: `Calibration (425,447)` is x 425, y 447.
    package struct Position: Equatable, Sendable {
        package var x: Int
        package var y: Int

        package init(x: Int, y: Int) {
            self.x = x
            self.y = y
        }
    }

    /// `[Area]`: the scanned region in the electron image.
    package struct Area: Equatable, Sendable {
        package var top: Measure?
        package var left: Measure?
        package var width: Measure?
        package var height: Measure?
        /// `Step size`, µm; the scan step in x and y.
        package var stepUM: Double
        /// `Number of samples	3x3`: rows (ny) then columns (nx), kikuchipy's order.
        package var rows: Int
        package var columns: Int
        package var scanTime: String?
    }

    /// The detector geometry kikuchipy builds from the file (`EBSDDetector(**detector)`), with its defaults for what
    /// the file does not carry.
    package struct Detector: Equatable, Sendable {
        /// Pattern rows and columns (sy, sx).
        package var rows: Int
        package var columns: Int
        /// Projection centre in kikuchipy's Bruker convention; the file carries none, so the default (0.5, 0.5, 0.5).
        package var pcx: Double = 0.5
        package var pcy: Double = 0.5
        package var pcz: Double = 0.5
        /// `Tilt angle`, degrees.
        package var sampleTiltDeg: Double
        /// Minus `Elevation`, degrees.
        package var tiltDeg: Double
        /// `Azimuthal`, degrees.
        package var azimuthalDeg: Double
        package var binning: Int = 1
        package var pixelSizeUM: Double = 1
    }

    package enum Refusal: Error, Equatable {
        case notSettings(String)
        case missing(section: String, key: String)
        case notANumber(section: String, key: String, value: String)
        case noCalibrationPatterns

        /// The app's words, after "<file> cannot be read: ".
        package var reason: String {
            switch self {
            case .notSettings(let name): "\(name) is not a NORDIF settings file (no [Microscope] section)."
            case .missing(let section, let key): "its [\(section)] section has no '\(key)' line."
            case .notANumber(let section, let key, let value): "its [\(section)] '\(key)' value '\(value)' is not a number."
            case .noCalibrationPatterns: "it lists no calibration patterns (no 'Calibration (x,y)' line under [Calibration patterns])."
            }
        }
    }

    package var softwareVersion: String?
    package var manufacturer: String
    package var model: String
    /// kikuchipy's `Acquisition_instrument.SEM.microscope`: manufacturer and model.
    package var microscope: String { "\(manufacturer) \(model)" }
    package var magnification: Int
    package var scanDirection: String?
    package var acceleratingVoltageKV: Double
    package var workingDistanceMM: Double
    package var tiltAngleDeg: Double
    /// `[Electron image] Resolution`, the area overview's size; nil when the line is missing.
    package var electronImageResolution: Resolution?
    package var detectorModel: String?
    /// `[Detector angles]` Euler 1 to 3, degrees.
    package var eulerDeg: [Double]
    package var azimuthalDeg: Double
    package var elevationDeg: Double
    package var acquisition: PatternSettings
    package var calibration: PatternSettings?
    package var specimenName: String?
    package var area: Area
    package var acquisitionPositions: [Position]
    package var calibrationPositions: [Position]
    /// The file's lines as read (kikuchipy's `original_metadata.nordif_header`).
    package var lines: [String]

    /// The detector kikuchipy builds for the acquisition patterns.
    package var detector: Detector {
        var tilt = -elevationDeg
        if tilt == 0 { tilt = 0 }   // never -0.0 (kikuchipy's `np.isclose` guard)
        return Detector(rows: acquisition.resolution.height, columns: acquisition.resolution.width,
                        sampleTiltDeg: tiltAngleDeg, tiltDeg: tilt, azimuthalDeg: azimuthalDeg)
    }

    package static func read(path: String) throws -> NORDIFSettings {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try parse(data, fileName: formatoDisplayFileName(path))
    }

    package static func parse(_ data: Data, fileName: String) throws -> NORDIFSettings {
        // Latin-1 decodes every byte, as kikuchipy's `open(encoding="latin-1")`.
        let text = String(data: data, encoding: .isoLatin1) ?? String(decoding: data, as: UTF8.self)
        // Python's `splitlines`: a trailing newline ends the last line and opens no empty one.
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map {
            var line = Substring($0)
            if line.hasSuffix("\r") { line = line.dropLast() }
            return String(line)
        }
        if lines.last == "" { lines.removeLast() }
        return try parse(lines: lines, fileName: fileName)
    }

    package static func parse(lines: [String], fileName: String) throws -> NORDIFSettings {
        let file = Sections(lines: lines)
        guard file.has("Microscope") else { throw Refusal.notSettings(fileName) }

        let acquisition = try patternSettings(file, section: "Acquisition settings")
        var calibration: PatternSettings?
        if file.has("Calibration settings") { calibration = try patternSettings(file, section: "Calibration settings") }
        let samples = try file.required("Area", "Number of samples")
        let (rows, columns) = try pair(samples, section: "Area", key: "Number of samples")
        let area = Area(top: measure(file, "Top"), left: measure(file, "Left"), width: measure(file, "Width"), height: measure(file, "Height"),
                        stepUM: try file.number("Area", "Step size"), rows: rows, columns: columns, scanTime: file.value("Area", "Scan time"))

        return NORDIFSettings(
            softwareVersion: file.value("NORDIF", "Software version"),
            manufacturer: file.value("Microscope", "Manufacturer") ?? "",
            model: file.value("Microscope", "Model") ?? "",
            magnification: try file.integer("Microscope", "Magnification"),
            scanDirection: file.value("Microscope", "Scan direction"),
            acceleratingVoltageKV: try file.number("Microscope", "Accelerating voltage"),
            workingDistanceMM: try file.number("Microscope", "Working distance"),
            tiltAngleDeg: try file.number("Microscope", "Tilt angle"),
            electronImageResolution: file.value("Electron image", "Resolution").flatMap { try? resolution($0, section: "Electron image") },
            detectorModel: file.value("EBSD detector", "Model"),
            eulerDeg: try ["Euler 1", "Euler 2", "Euler 3"].map { try file.number("Detector angles", $0) },
            azimuthalDeg: try file.number("Detector angles", "Azimuthal"),
            elevationDeg: try file.number("Detector angles", "Elevation"),
            acquisition: acquisition,
            calibration: calibration,
            specimenName: file.value("Specimen", "Name"),
            area: area,
            acquisitionPositions: positions(file, section: "Acquisition patterns", word: "Acquisition"),
            calibrationPositions: positions(file, section: "Calibration patterns", word: "Calibration"),
            lines: lines
        )
    }

    // MARK: - Parsing

    /// The file as sections of `key	value	unit` entries, in file order.
    private struct Sections {
        struct Entry {
            var key: String
            var value: String
            var unit: String
        }

        var sections: [(name: String, entries: [Entry])] = []

        init(lines: [String]) {
            for line in lines {
                let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                let key = fields[0]
                if key.hasPrefix("["), key.hasSuffix("]") {
                    sections.append((String(key.dropFirst().dropLast()), []))
                } else if !sections.isEmpty, !key.isEmpty {
                    sections[sections.count - 1].entries.append(
                        Entry(key: key, value: fields.count > 1 ? fields[1] : "", unit: fields.count > 2 ? fields[2] : ""))
                }
            }
        }

        func has(_ section: String) -> Bool { sections.contains { $0.name == section } }

        func entries(_ section: String) -> [Entry] { sections.first { $0.name == section }?.entries ?? [] }

        func value(_ section: String, _ key: String) -> String? { entries(section).first { $0.key == key }?.value }

        func required(_ section: String, _ key: String) throws -> String {
            guard let value = value(section, key) else { throw Refusal.missing(section: section, key: key) }
            return value
        }

        func number(_ section: String, _ key: String) throws -> Double {
            let value = try required(section, key)
            guard let number = Double(value.trimmingCharacters(in: .whitespaces)) else {
                throw Refusal.notANumber(section: section, key: key, value: value)
            }
            return number
        }

        func integer(_ section: String, _ key: String) throws -> Int {
            let value = try required(section, key)
            guard let number = Int(value.trimmingCharacters(in: .whitespaces)) else {
                throw Refusal.notANumber(section: section, key: key, value: value)
            }
            return number
        }
    }

    private static func patternSettings(_ file: Sections, section: String) throws -> PatternSettings {
        PatternSettings(frameRateFPS: file.value(section, "Frame rate").flatMap(Double.init),
                        resolution: try resolution(try file.required(section, "Resolution"), section: section),
                        exposureUS: file.value(section, "Exposure time").flatMap(Double.init),
                        gain: file.value(section, "Gain").flatMap(Double.init))
    }

    /// `AxB` as two integers.
    private static func pair(_ value: String, section: String, key: String) throws -> (Int, Int) {
        let parts = value.split(separator: "x").map { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 2, let a = parts[0], let b = parts[1] else {
            throw Refusal.notANumber(section: section, key: key, value: value)
        }
        return (a, b)
    }

    private static func resolution(_ value: String, section: String) throws -> Resolution {
        let (width, height) = try pair(value, section: section, key: "Resolution")
        return Resolution(width: width, height: height)
    }

    /// `89.200 (223)` in the `[Area]` section; nil when the line is missing or does not carry both numbers.
    private static func measure(_ file: Sections, _ key: String) -> Measure? {
        guard let value = file.value("Area", key) else { return nil }
        let parts = value.split(whereSeparator: { $0 == " " || $0 == "(" || $0 == ")" })
        guard parts.count == 2, let um = Double(parts[0]), let px = Int(parts[1]) else { return nil }
        return Measure(micrometres: um, pixels: px)
    }

    /// Every `<word> (x,y)` key of the section, as kikuchipy's `Calibration \((.*)\)`.
    private static func positions(_ file: Sections, section: String, word: String) -> [Position] {
        file.entries(section).compactMap { entry in
            guard entry.key.hasPrefix("\(word) ("), entry.key.hasSuffix(")") else { return nil }
            let inner = entry.key.dropFirst(word.count + 2).dropLast()
            let parts = inner.split(separator: ",").map { Int($0.trimmingCharacters(in: .whitespaces)) }
            guard parts.count == 2, let x = parts[0], let y = parts[1] else { return nil }
            return Position(x: x, y: y)
        }
    }
}
