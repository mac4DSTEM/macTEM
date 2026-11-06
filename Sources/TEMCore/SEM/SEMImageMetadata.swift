//
//  SEMImageMetadata.swift
//  Role: what an SEM image TIFF records about its acquisition (design: docs/sem/design/sem-image-room.md), read from the vendor's own tag as RosettaSciIO 0.15.0's TIFF
//        reader (`rsciio/tiff/_api.py`: `_axes_fei`, `_axes_zeiss`, `mapping_fei`, `mapping_cz_sem`) and tifffile 2026.9.20
//        (`read_fei_metadata`, `read_cz_sem`) read it, plus the one thing neither maps and the Image room needs: the height of
//        the databar the vendor drew under the scan, so the room can show the scan alone. Three vendors:
//          Thermo Fisher / FEI (xT, Helios): tag 34682 (or 34680, SFEG), an INI text of `[Section]` and `Key=Value` lines.
//          Zeiss (SmartSEM): tag 34118 `CZ_SEM`, an upper-case key line followed by a `Name = value unit` line, and unnamed
//            numeric lines before the first key.
//          Tescan (MIRA, VEGA): tag 50431, an INI text with `[MAIN]` and `[SEM]`, as NexusLIMS's public `tescan_tif`
//            extractor reads it (RosettaSciIO has no Tescan branch; every Tescan value carries `tescanNote`).
//        SEM-only. A TEM TIFF (Velox, Digital Micrograph, ImageJ) reads nil here; `AcquisitionMetadata.read(path:)` (FormatoKit's
//        rules) stays the Acquisition section's source, and this type adds what SEM files record beyond it.
//
//  Parity (tools/parity/sem/sem-image, reference.json; SEMImageMetadataTests): on RosettaSciIO's SEM test TIFFs, every mapped value
//  equals the reference — texts exactly, numbers to 1e-9 relative (RosettaSciIO's own TIFF tests compare the axes at rtol 1e-6
//  and the metadata with `assert_deep_almost_equal`, 7 places). The fields RosettaSciIO does not map (spot, chamber pressure,
//  detector of a Thermo file, databar, Tescan altogether) compare with tifffile's parse of the same bytes and carry a note.
//
//  Units: metres, seconds, volts and pascals as the file stores them, converted to the units RosettaSciIO registers: beam energy
//  kV, working distance mm, beam current nA, dwell s, stage x/y/z in the file's own unit (`stageUnit`: metres for Thermo and
//  Tescan, millimetres for Zeiss, where RosettaSciIO converts Zeiss to mm and keeps Thermo as stored), rotation and tilt in
//  degrees as stored. Pixel size in metres. Every number is read by `pythonNumber` (an int or a float as Python's `int()` and
//  `float()` read them, less underscores and non-ASCII digits, which read as text here); a value that is empty or not a number
//  is nil ("not recorded"), never 0, as the kit's rule (b). A quantity that is not finite is nil.
//
//  DEVIATIONS from RosettaSciIO, each on purpose:
//  - A Zeiss value with a unit RosettaSciIO converts with pint; here the SI prefixes of m, s, A and Pa are converted (the
//    units SmartSEM writes) and the value is rounded to 7 significant digits as `float("%.6e" % v)` rounds it; an unknown unit
//    reads nil.
//  - The Zeiss and Thermo dates are read by format (`d MMM yyyy`, `M/d/yyyy`, `H:mm:ss`, `h:mm:ss a`) where RosettaSciIO's
//    dateutil parses any shape; a shape not listed reads nil.
//  - The databar: Thermo's `[PrivateFei] DatabarHeight` is read only when `[Image] ResolutionY` plus it equals the TIFF's
//    ImageLength (the three agree in every Helios file RosettaSciIO ships); Tescan's `[MAIN] ImageStripSize` only when it is
//    below the ImageLength; a Zeiss file is never cropped: SmartSEM draws its data zone into the scan's own rows and records
//    no height for it (decision D-SEM-22, docs/decisions.md).
//

import Foundation
import FormatoCore
import FormatoTIFF
import ImagoCore

/// What an SEM TIFF records; nil fields are "not recorded".
package nonisolated struct SEMImageMetadata: Sendable, Equatable {
    package enum Vendor: String, Sendable, Equatable {
        case thermo = "Thermo Fisher / FEI"
        case zeiss = "Zeiss"
        case tescan = "Tescan"
    }

    package let vendor: Vendor
    /// The width of the TIFF's first page, in pixels (the Zeiss scale is stated for a 1024-pixel line).
    package let imageWidth: Int
    /// The height of the TIFF's first page, in pixels, databar included.
    package let imageHeight: Int
    /// Pixel size along x and y in metres; nil where the file states none.
    package var pixelSizeX: Double?
    package var pixelSizeY: Double?
    /// Beam energy in kV.
    package var beamEnergyKV: Double?
    /// The nominal magnification as a number, or as the text the file wrote where it is not one ("50.00 K X").
    package var magnification: Double?
    package var magnificationText: String?
    package var workingDistanceMM: Double?
    package var detector: String?
    /// Dwell per pixel in seconds.
    package var dwellS: Double?
    package var beamCurrentNA: Double?
    /// The spot setting: a number (Thermo's and Zeiss's spot index, Tescan's spot diameter in metres as `spotSizeUnit` says).
    package var spotSize: Double?
    package var spotSizeUnit: String?
    package var chamberPressurePa: Double?
    package var stageX: Double?
    package var stageY: Double?
    package var stageZ: Double?
    /// The unit of `stageX/Y/Z` as stored and as RosettaSciIO reports it: "m" (Thermo, Tescan) or "mm" (Zeiss).
    package var stageUnit: String
    package var stageRotationDeg: Double?
    package var stageTiltDeg: Double?
    package var instrument: String?
    /// ISO date "yyyy-MM-dd" and time "HH:mm:ss" as RosettaSciIO's `General.date` and `General.time`.
    package var date: String?
    package var time: String?
    package var user: String?
    /// The rows of the databar under the scan; nil when the file records none (a Zeiss file) or the record disagrees with
    /// the image height.
    package var databarRows: Int?
    /// Every field of the vendor block, raw, in the file's order: "Section.Key" (Thermo, Tescan) or the CZ_SEM key with its
    /// display name, and the value as written. The Info tab's "Vendor fields" disclosure.
    package var rawFields: [RawField] = []

    package struct RawField: Sendable, Equatable {
        package let key: String
        package let value: String
        package init(key: String, value: String) { self.key = key; self.value = value }
    }

    /// The field the pixel size was read from, for the Calibration section's Source row ("Thermo PixelWidth").
    package var pixelSizeSource: String? {
        guard pixelSizeX != nil else { return nil }
        switch vendor {
        case .thermo: return rawFields.contains { $0.key == "Scan.PixelWidth" } ? "Thermo PixelWidth" : "Thermo HFW / ResolutionX"
        case .zeiss: return "Zeiss CZ_SEM"
        case .tescan: return "Tescan PixelSizeX"
        }
    }

    package init(vendor: Vendor, imageWidth: Int, imageHeight: Int, stageUnit: String) {
        self.vendor = vendor
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.stageUnit = stageUnit
    }

    /// The rows of the scan itself: the image height less the databar.
    package var scanRows: Int { imageHeight - (databarRows ?? 0) }

    /// The notes this reader attaches, worded once.
    package static let unvalidatedNote = "no published reader maps this field; read as stored in the vendor's tag"
    package static let tescanNote = "RosettaSciIO has no Tescan reader; read as NexusLIMS's tescan_tif reads the header"
    package static let zeissDatabarNote = "SmartSEM draws its data zone into the scan and records no height for it; the image is not cropped"

    // MARK: Reading

    /// The SEM record of the TIFF at `path`; nil when the file is not an SEM TIFF of the three vendors, or cannot be read.
    /// Never throws: the open has succeeded when the app asks, and a record that cannot be read is no record.
    package static func read(path: String) -> SEMImageMetadata? {
        guard ["tif", "tiff"].contains((path as NSString).pathExtension.lowercased()),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped) else { return nil }
        return read(data: data)
    }

    package static func read(data: Data) -> SEMImageMetadata? {
        guard let file = try? TIFFFile(data: data), let page = file.directories.first,
              let width = page[256]?.integer, let height = page[257]?.integer, width > 0, height > 0 else { return nil }
        // RosettaSciIO's order: FEI before Zeiss (`_parse_scale_unit`); Tescan last, outside it.
        if page[34680] != nil || page[34682] != nil {
            return thermo(page, width: Int(width), height: Int(height))
        }
        if let tag = page[34118] {
            return zeiss(tag, width: Int(width), height: Int(height))
        }
        if let tag = page[50431] {
            return tescan(tag, width: Int(width), height: Int(height))
        }
        return nil
    }

    // MARK: Thermo Fisher / FEI

    /// tifffile's `fei_metadata`: tag 34680 then 34682, each an INI; a later section replaces an earlier of the same name.
    package static func thermo(_ page: TIFFDirectory, width: Int, height: Int) -> SEMImageMetadata {
        var sections: [String: [String: String]] = [:]
        var raw: [RawField] = []
        for code in [34680, 34682] {
            guard let tag = page[code] else { continue }
            for (name, body) in feiSections(pythonText(tag.raw)) {
                sections[name] = body
                raw += body.sorted { $0.key < $1.key }.map { RawField(key: "\(name).\($0.key)", value: $0.value) }
            }
        }
        func value(_ section: String, _ key: String) -> String? { sections[section]?[key] }
        func number(_ section: String, _ key: String) -> Double? { value(section, key).flatMap(pythonNumber) }

        var m = SEMImageMetadata(vendor: .thermo, imageWidth: width, imageHeight: height, stageUnit: "m")
        m.rawFields = raw
        // `_axes_fei`: [Scan] PixelWidth/PixelHeight, else [IRBeam] HFW / [Image] ResolutionX and VFW / ResolutionY; a
        // missing key leaves the axes unset, a value that is not a number raises there (the file then opens uncalibrated).
        if let w = value("Scan", "PixelWidth"), let h = value("Scan", "PixelHeight") {
            if let x = pythonNumber(w), let y = pythonNumber(h) { m.pixelSizeX = x; m.pixelSizeY = y }
        } else if let hfw = value("IRBeam", "HFW"), let vfw = value("IRBeam", "VFW"),
                  let rx = value("Image", "ResolutionX"), let ry = value("Image", "ResolutionY") {
            if let hfw = pythonNumber(hfw), let vfw = pythonNumber(vfw), let rx = pythonNumber(rx), let ry = pythonNumber(ry) {
                m.pixelSizeX = finite(hfw / rx)
                m.pixelSizeY = finite(vfw / ry)
            }
        }
        m.beamEnergyKV = finite(number("Beam", "HV").map { $0 * 1e-3 })                    // `_parse_beam_energy_FEI`
        m.workingDistanceMM = finite(number("Stage", "WorkingDistance").map { $0 * 1e3 })  // `_parse_working_distance_FEI`
        m.beamCurrentNA = finite(number("EBeam", "BeamCurrent").map { $0 * 1e9 })          // `_parse_beam_current_FEI`
        m.dwellS = finite(number("Scan", "Dwelltime"))
        m.stageX = finite(number("Stage", "StageX"))
        m.stageY = finite(number("Stage", "StageY"))
        m.stageZ = finite(number("Stage", "StageZ"))
        m.stageRotationDeg = finite(number("Stage", "StageR"))
        m.stageTiltDeg = finite(number("Stage", "StageT"))
        m.instrument = text(value("System", "SystemType"))
        m.user = text(value("User", "User"))
        m.date = value("User", "Date").flatMap(isoDate)
        m.time = value("User", "Time").flatMap(isoTime)
        // Not mapped by RosettaSciIO (`unvalidatedNote`): the detector, the spot, the chamber pressure, the databar.
        m.detector = text(value("Detectors", "Name"))
        m.spotSize = finite(number("Beam", "Spot"))
        m.chamberPressurePa = finite(number("Vacuum", "ChPressure"))
        if let bar = number("PrivateFei", "DatabarHeight"), let rows = number("Image", "ResolutionY"),
           bar > 0, bar == bar.rounded(), rows == rows.rounded(), Int(rows) + Int(bar) == height {
            m.databarRows = Int(bar)
        }
        return m
    }

    /// tifffile's `read_fei_metadata`: `[name]` starts a section, the first "=" splits a key from its value, both stripped;
    /// a line without "=" is skipped; a repeated key replaces the earlier (an empty value included).
    package static func feiSections(_ text: String) -> [(String, [String: String])] {
        var result: [(String, [String: String])] = []
        var current: [String: String] = [:]
        var name: String?
        func close() { if let name { result.append((name, current)) } }
        for raw in pythonSplitLines(text) {
            let line = pythonStrip(raw)
            if line.hasPrefix("[") {
                close()
                current = [:]
                name = String(line.dropFirst().dropLast())
                continue
            }
            guard let eq = line.firstIndex(of: "=") else { continue }
            current[pythonStrip(String(line[..<eq]))] = pythonStrip(String(line[line.index(after: eq)...]))
        }
        close()
        // A later section of the same name replaces the earlier (a dict's assignment), keeping the first's position.
        var merged: [(String, [String: String])] = []
        for (n, body) in result {
            if let i = merged.firstIndex(where: { $0.0 == n }) { merged[i].1 = body } else { merged.append((n, body)) }
        }
        return merged
    }

    // MARK: Zeiss

    /// One value of a CZ_SEM key line: the display name, the value as tifffile's `read_cz_sem` leaves it, and its unit.
    package struct ZeissValue: Equatable, Sendable {
        package let name: String
        package let number: Double?
        package let text: String
        package let unit: String?

        package init(name: String, number: Double?, text: String, unit: String?) {
            self.name = name
            self.number = number
            self.text = text
            self.unit = unit
        }
    }

    /// tifffile's `read_cz_sem`, the whole tag: the unnamed values before the first key, and every key.
    package static func czSEM(_ text: String) -> (unnamed: [Double?], keyed: [String: ZeissValue]) {
        var unnamed: [Double?] = []
        var keyed: [String: ZeissValue] = [:]
        var key: String?
        for line in pythonSplitLines(text) {
            if pythonIsUpper(line) {
                key = line.lowercased()
            } else if let k = key {
                var parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                if parts.count != 2 { parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false) }
                guard parts.count == 2 else { continue }
                let name = pythonStrip(String(parts[0]))
                let value = pythonStrip(String(parts[1]))
                let words = pythonSplit(value)
                var entry: ZeissValue
                if words.count == 2, let n = pythonNumber(words[0]) {
                    entry = ZeissValue(name: name, number: n, text: words[0], unit: words[1])
                } else if let n = pythonNumber(value) {
                    entry = ZeissValue(name: name, number: n, text: value, unit: nil)
                } else {
                    // tifffile turns "No"/"Off" and "Yes"/"On" into booleans here; they are kept as their text.
                    entry = ZeissValue(name: name, number: nil, text: value, unit: nil)
                }
                keyed[k] = entry
                key = nil
            } else {
                unnamed.append(pythonNumber(line))
            }
        }
        return (unnamed, keyed)
    }

    package static func zeiss(_ tag: TIFFTag, width: Int, height: Int) -> SEMImageMetadata {
        let (unnamed, keyed) = czSEM(pythonText(tag.raw))
        var m = SEMImageMetadata(vendor: .zeiss, imageWidth: width, imageHeight: height, stageUnit: "mm")
        m.rawFields = keyed.sorted { $0.key < $1.key }.map { key, v in
            RawField(key: "\(key) (\(v.name))", value: v.unit.map { "\(v.text) \($0)" } ?? v.text)
        }
        // `_axes_zeiss`: `op["CZ_SEM"][""][3] * 1024 / shape[1]`, metres; an IndexError or TypeError there leaves the file
        // uncalibrated.
        if unnamed.count > 3, let scale = unnamed[3] {
            m.pixelSizeX = scale * 1024 / Double(width)
            m.pixelSizeY = m.pixelSizeX
        }
        func plain(_ key: String) -> Double? { keyed[key].flatMap { $0.number } }              // `_parse_tuple_Zeiss`
        func converted(_ key: String, to unit: String) -> Double? {                          // `_parse_tuple_Zeiss_with_units`
            guard let v = keyed[key], let n = v.number, let from = v.unit else { return nil }
            return convert(n, from: from, to: unit)
        }
        m.beamEnergyKV = finite(plain("ap_actualkv"))
        if let mag = keyed["ap_mag"] {
            if let n = mag.number { m.magnification = n } else { m.magnificationText = mag.text }
        }
        m.stageX = finite(converted("ap_stage_at_x", to: "mm"))
        m.stageY = finite(converted("ap_stage_at_y", to: "mm"))
        m.stageZ = finite(converted("ap_stage_at_z", to: "mm"))
        m.stageRotationDeg = finite(plain("ap_stage_at_r"))
        m.stageTiltDeg = finite(plain("ap_stage_at_t"))
        m.workingDistanceMM = finite(converted("ap_wd", to: "mm"))
        m.dwellS = finite(converted("dp_dwell_time", to: "s"))
        m.beamCurrentNA = finite(converted("ap_iprobe", to: "nA"))
        m.detector = keyed["dp_detector_type"].flatMap { text($0.text) }
        m.instrument = keyed["sv_serial_number"].flatMap { text($0.text) }
        m.date = keyed["ap_date"].flatMap { isoDate($0.text) }
        m.time = keyed["ap_time"].flatMap { isoTime($0.text) }
        m.user = keyed["sv_user_name"].flatMap { text($0.text) }
        // Not mapped by RosettaSciIO (`unvalidatedNote`).
        m.spotSize = finite(plain("ap_spotsize"))
        m.chamberPressurePa = finite(converted("ap_chamber_pressure", to: "Pa"))
        return m
    }

    // MARK: Tescan

    /// NexusLIMS `tescan_tif`: the INI from the first `[MAIN]` marker, NULs removed, `[MAIN]` and `[SEM]` sections of `Key=Value`
    /// lines (configparser, keys case-preserved). Pixel sizes, WD, spot and stage in metres, HV in volts, dwell in seconds,
    /// pressure in pascals; `ImageStripSize` the rows of the info strip under the scan.
    package static func tescan(_ tag: TIFFTag, width: Int, height: Int) -> SEMImageMetadata {
        var header = pythonText(tag.raw)
        if let main = header.range(of: "[MAIN]") { header = String(header[main.lowerBound...]) }
        var sections: [String: [String: String]] = [:]
        for (name, body) in feiSections(header) { sections[name, default: [:]].merge(body) { _, new in new } }
        func value(_ section: String, _ key: String) -> String? { sections[section]?[key] }
        func number(_ section: String, _ key: String) -> Double? { value(section, key).flatMap(pythonNumber) }

        var m = SEMImageMetadata(vendor: .tescan, imageWidth: width, imageHeight: height, stageUnit: "m")
        m.rawFields = sections.sorted { $0.key < $1.key }.flatMap { name, body in
            body.sorted { $0.key < $1.key }.map { RawField(key: "\(name).\($0.key)", value: $0.value) }
        }
        if let x = number("MAIN", "PixelSizeX"), let y = number("MAIN", "PixelSizeY") { m.pixelSizeX = x; m.pixelSizeY = y }
        m.beamEnergyKV = finite((number("SEM", "HV") ?? number("SEM", "AcceleratorVoltage")).map { $0 * 1e-3 })
        m.workingDistanceMM = finite(number("SEM", "WD").map { $0 * 1e3 })
        m.detector = text(value("SEM", "Detector") ?? value("SEM", "Detector0"))
        m.magnification = finite(number("MAIN", "Magnification"))
        m.dwellS = finite(number("SEM", "DwellTime"))
        m.spotSize = finite(number("SEM", "SpotSize"))
        if m.spotSize != nil { m.spotSizeUnit = "m" }
        m.chamberPressurePa = finite(number("SEM", "ChamberPressure"))
        m.beamCurrentNA = finite(number("SEM", "PredictedBeamCurrent").map { $0 * 1e-3 })   // picoamperes there
        m.stageX = finite(number("SEM", "StageX"))
        m.stageY = finite(number("SEM", "StageY"))
        m.stageZ = finite(number("SEM", "StageZ"))
        m.stageRotationDeg = finite(number("SEM", "StageRotation"))
        m.stageTiltDeg = finite(number("SEM", "StageTilt"))
        m.instrument = text(value("MAIN", "Device"))
        m.user = text(value("MAIN", "FullUserName") ?? value("MAIN", "UserName"))
        m.date = value("MAIN", "Date").flatMap(isoDate)
        m.time = value("MAIN", "Time").flatMap(isoTime)
        if let strip = number("MAIN", "ImageStripSize"), strip > 0, strip == strip.rounded(), Int(strip) < height {
            m.databarRows = Int(strip)
        }
        return m
    }

    // MARK: Values

    private static func finite(_ x: Double?) -> Double? { x.flatMap { $0.isFinite ? $0 : nil } }
    private static func text(_ s: String?) -> String? { s.flatMap { $0.isEmpty ? nil : $0 } }

    /// pint's conversion for the units SmartSEM writes, then `float("%.6e" % v)`: 7 significant digits.
    package static func convert(_ value: Double, from: String, to: String) -> Double? {
        guard let f = siFactor(from), let t = siFactor(to), f.base == t.base else { return nil }
        let converted = value * f.scale / t.scale
        guard converted.isFinite, let rounded = Double(String(format: "%.6e", converted)) else { return nil }
        return rounded
    }

    /// The base unit and the factor to it of an SI-prefixed m, s, A or Pa (µ as U+00B5 or U+03BC, "u" too).
    package static func siFactor(_ unit: String) -> (base: String, scale: Double)? {
        let bases = ["m", "s", "A", "Pa"]
        let prefixes: [String: Double] = ["": 1, "k": 1e3, "M": 1e6, "m": 1e-3, "µ": 1e-6, "μ": 1e-6, "u": 1e-6, "n": 1e-9, "p": 1e-12, "f": 1e-15]
        for base in bases where unit.hasSuffix(base) {
            let prefix = String(unit.dropLast(base.count))
            if let p = prefixes[prefix] { return (base, p) }
        }
        return nil
    }

    // MARK: Dates (RosettaSciIO: dateutil, `.date().isoformat()` and `.time().isoformat()`)

    /// "06/13/2016" (month first; a first field above 12 is the day, as dateutil reads it), "23 Dec 2015", "2016-06-13".
    package static func isoDate(_ text: String) -> String? {
        let s = pythonStrip(text)
        let months = ["jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6, "jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12]
        func iso(_ y: Int, _ mo: Int, _ d: Int) -> String? {
            guard (1...12).contains(mo), (1...31).contains(d), y >= 1 else { return nil }
            return String(format: "%04d-%02d-%02d", y, mo, d)
        }
        let slash = s.split(separator: "/").map(String.init)
        if slash.count == 3, let a = Int(slash[0]), let b = Int(slash[1]), let y = Int(slash[2]) {
            return a > 12 ? iso(y, b, a) : iso(y, a, b)
        }
        let dash = s.split(separator: "-").map(String.init)
        if dash.count == 3, let y = Int(dash[0]), let mo = Int(dash[1]), let d = Int(dash[2]), dash[0].count == 4 {
            return iso(y, mo, d)
        }
        let words = pythonSplit(s)
        if words.count == 3, let d = Int(words[0]), let mo = months[String(words[1].prefix(3)).lowercased()], let y = Int(words[2]) {
            return iso(y, mo, d)
        }
        return nil
    }

    /// "05:06:40 PM", "9:40:32", "17:06:40" → "HH:mm:ss".
    package static func isoTime(_ text: String) -> String? {
        let words = pythonSplit(pythonStrip(text))
        guard let clock = words.first else { return nil }
        let parts = clock.split(separator: ":").map(String.init)
        guard parts.count == 3, var h = Int(parts[0]), let m = Int(parts[1]), let sec = Int(parts[2]),
              (0...23).contains(h), (0...59).contains(m), (0...59).contains(sec) else { return nil }
        if words.count == 2 {
            switch words[1].uppercased() {
            case "PM": if h < 12 { h += 12 }
            case "AM": if h == 12 { h = 0 }
            default: return nil
            }
        } else if words.count > 2 { return nil }
        return String(format: "%02d:%02d:%02d", h, m, sec)
    }

    // MARK: Python's text rules (tifffile reads the tag through them)

    /// tifffile's `bytes2str`: the bytes up to the first NUL, UTF-8 or else cp1252.
    package static func pythonText(_ raw: Data) -> String {
        let bytes = raw.prefix { $0 != 0 }
        return String(data: bytes, encoding: .utf8) ?? String(data: bytes, encoding: .windowsCP1252) ?? ""
    }

    /// `str.splitlines()`: \r\n, \r, \n, \v, \f, U+001C–U+001E, U+0085, U+2028, U+2029; no trailing empty line.
    package static func pythonSplitLines(_ s: String) -> [String] {
        var lines: [String] = []
        var current = ""
        var scalars = s.unicodeScalars.makeIterator()
        var pending: Unicode.Scalar? = nil
        func next() -> Unicode.Scalar? {
            if let p = pending { pending = nil; return p }
            return scalars.next()
        }
        while let c = next() {
            switch c.value {
            case 0x0D:
                if let n = scalars.next() { if n.value != 0x0A { pending = n } }
                lines.append(current); current = ""
            case 0x0A, 0x0B, 0x0C, 0x1C, 0x1D, 0x1E, 0x85, 0x2028, 0x2029:
                lines.append(current); current = ""
            default:
                current.unicodeScalars.append(c)
            }
        }
        if !current.isEmpty { lines.append(current) }
        return lines
    }

    /// `str.isupper()`: at least one cased character and no lower-case one.
    package static func pythonIsUpper(_ s: String) -> Bool {
        var cased = false
        for c in s {
            if c.isLowercase { return false }
            if c.isUppercase { cased = true }
        }
        return cased
    }

    package static func pythonStrip(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// `str.split()` with no argument: runs of whitespace separate, none at the ends.
    package static func pythonSplit(_ s: String) -> [String] {
        s.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).map(String.init)
    }

    /// `astype(value, (int, float))` as a number: Python's `int()` then `float()` of the text (ASCII digits, a sign, a
    /// point, an exponent, inf and nan; whitespace around it); nil where both raise.
    package static func pythonNumber(_ s: String) -> Double? {
        let t = pythonStrip(s)
        guard !t.isEmpty, t.unicodeScalars.allSatisfy({ $0.isASCII }), !t.contains("_") else { return nil }
        if let i = Int(t) { return Double(i) }
        let lower = t.lowercased()
        let body = lower.hasPrefix("+") || lower.hasPrefix("-") ? String(lower.dropFirst()) : lower
        if ["inf", "infinity", "nan"].contains(body) {
            let negative = lower.hasPrefix("-")
            return body == "nan" ? .nan : (negative ? -.infinity : .infinity)
        }
        // Python's float() grammar: digits, a point, an exponent (no hex, which Swift's Double would read).
        guard body.first.map({ $0.isNumber || $0 == "." }) == true,
              body.allSatisfy({ "0123456789.e+-".contains($0) }), !body.hasPrefix("e"), !body.hasSuffix("e") else { return nil }
        return Double(t)
    }
}
