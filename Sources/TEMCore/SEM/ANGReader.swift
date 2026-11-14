//
//  ANGReader.swift
//  Role: EDAX TSL `.ang` orientation maps (also written by EMsoft's EMdpmerge, NanoMegas ASTAR Index and orix), read as orix 0.15.0's
//        `orix/io/plugins/ang.py` `file_reader` reads them (GPL-3.0-or-later): the header's phases (id, name, formula, symmetry,
//        lattice constants, with orix's regular expressions and its phase-name autogeneration from the formulas), the vendor from its
//        footprint in the header and the column names per vendor and column count, every column as a Double, the not-indexed
//        convention (EDAX and orix: confidence index -1), the map shape and step from the x and y columns as `CrystalMap` derives them,
//        and the rotations as unit quaternions from the Bunge Euler angles (`_conversions.eu2qu`, Rowenhorst et al. 2015 eqs. A.5-6),
//        all held in one `CrystalMap`.
//        The grid, step, projection centre and working distance of the header are read beside (orix leaves them in the file).
//        Parity: macTEMTests/ANGReaderTests.swift against ebsd-edax.truth.json (tools/parity/sem-readers/make_edax_fixtures.py).
//

import Foundation

/// A phase of the `.ang` header as parsed, before `CrystalMap` matches the list to the data.
package nonisolated struct ANGPhase: Sendable, Equatable {
    package var id: Int
    /// The `MaterialName`, or the formula when orix autogenerates names (every phase has a formula).
    package var name: String
    package var formula: String?
    /// orix's point-group name (`432`, `6/mmm`, ...) after its EDAX aliases (`43` is `432`).
    package var pointGroup: String?
    /// a, b, c, alpha, beta, gamma as written (orix's `Lattice`).
    package var lattice: [Double]
}

/// The header fields orix leaves in the file: the grid, step, map size, projection centre and working distance.
package nonisolated struct ANGHeader: Sendable, Equatable {
    /// `GRID:` as written (`SqrGrid`, `HexGrid`).
    package var grid: String?
    package var stepX: Double?
    package var stepY: Double?
    package var columnsOdd: Int?
    package var columnsEven: Int?
    package var rows: Int?
    /// `x-star`, `y-star`, `z-star`: the projection centre in the EDAX convention.
    package var projectionCenter: SIMD3<Double>?
    package var workingDistance: Double?
    package var temPixelsPerMicron: Double?
    /// Every header line as written, `#` included.
    package var lines: [String] = []

    package var isHexagonal: Bool { grid?.lowercased().hasPrefix("hex") == true }
}

/// One `.ang` file: its `CrystalMap` (orix's `file_reader` result: rotations from the Bunge angles, phase ids with -1 for not
/// indexed, the header's phases, x and y, every other column as a property) and what orix leaves in the file beside it.
package nonisolated struct ANGMap: Sendable, Equatable {
    package enum Vendor: String, Sendable, Equatable { case tsl, emsoft, astar, orix, unknown }

    package var url: URL
    package var header: ANGHeader
    package var vendor: Vendor
    /// The file's columns by orix's names, in file order (`euler1`, `euler2`, `euler3`, `x`, `y`, then the vendor's).
    package var columnNames: [String]
    /// The map; its scan unit is `um`, `nm` for an ASTAR file.
    package var map: CrystalMap

    package var pointCount: Int { map.pointCount }
    package var notIndexedCount: Int { map.phaseIDs.reduce(0) { $0 + ($1 == -1 ? 1 : 0) } }
}

package nonisolated enum ANGReader {
    package static let readableExtensions = ["ang"]

    package static func read(url: URL) throws -> ANGMap {
        let text: String
        do { text = try String(contentsOf: url, encoding: .utf8) } catch {
            // orix opens the file with the locale's encoding; a Latin-1 header (an operator's name) is read as such.
            guard let latin = try? String(contentsOf: url, encoding: .isoLatin1) else {
                throw ANGReadError(text: "\(url.lastPathComponent) could not be read: \((error as NSError).localizedDescription)")
            }
            text = latin
        }
        return try read(text: text, url: url)
    }

    package static func read(text: String, url: URL) throws -> ANGMap {
        let name = url.lastPathComponent
        let lines = TextLines.split(text).map(String.init)   // LF, CRLF and CR, as Python's `open()` reads them for orix (#518)
        // _get_header: the leading lines that start with '#', at most 1000, each rstripped.
        var headerLines: [String] = []
        for line in lines.prefix(1000) {
            guard line.hasPrefix("#") else { break }
            headerLines.append(rstrip(line))
        }
        let header = parseHeader(headerLines)
        let (phaseFields, formulas) = try phasesFromHeader(headerLines)

        // np.loadtxt: every line that is not blank and not a comment, split on whitespace, equal column counts.
        var rows: [[Double]] = []
        var columnCount: Int?
        for (number, raw) in lines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            var row: [Double] = []
            row.reserveCapacity(fields.count)
            for field in fields {
                guard let value = Double(field) else {
                    throw ANGReadError(text: "\(name) line \(number + 1): '\(field)' is not a number.")
                }
                row.append(value)
            }
            if let columnCount, columnCount != row.count {
                throw ANGReadError(text: "\(name) line \(number + 1) has \(row.count) columns where the first row has \(columnCount).")
            }
            columnCount = row.count
            rows.append(row)
        }
        guard let columnCount, !rows.isEmpty else { throw ANGReadError(text: "\(name) has no data rows after its header.") }

        let (vendor, columnNames) = vendorColumns(headerLines, fileColumns: columnCount)
        guard columnNames.count <= columnCount else {
            throw ANGReadError(text: "\(name) has \(columnCount) columns; a \(vendor.rawValue) file needs at least \(columnNames.count) (\(columnNames.joined(separator: ", "))).")
        }
        let n = rows.count
        func column(_ i: Int) -> [Double] { rows.map { $0[i] } }
        var euler = [SIMD3<Double>](repeating: .zero, count: n)
        var x = [Double](repeating: 0, count: n), y = [Double](repeating: 0, count: n)
        var phaseIDs = [Int](repeating: 0, count: n)
        var properties: [String: [Double]] = [:]
        for (i, columnName) in columnNames.enumerated() {
            switch columnName {
            case "euler1": for k in 0..<n { euler[k].x = rows[k][i] }
            case "euler2": for k in 0..<n { euler[k].y = rows[k][i] }
            case "euler3": for k in 0..<n { euler[k].z = rows[k][i] }
            case "x": x = column(i)
            case "y": y = column(i)
            case "phase_id":
                for k in 0..<n {
                    let value = rows[k][i]
                    guard value.isFinite, value == value.rounded(), abs(value) < 1e15 else {
                        throw ANGReadError(text: "\(name) row \(k + 1): the phase id '\(value)' is not an integer.")
                    }
                    phaseIDs[k] = Int(value)
                }
            default: properties[columnName] = column(i)
            }
        }
        if vendor == .orix || vendor == .tsl, let ci = properties["ci"] {
            for k in 0..<n where ci[k] == -1 { phaseIDs[k] = -1 }
        }

        // The phase list: orix's PhaseList from the header fields and autogenerated names; `CrystalMap` matches it to the data's ids
        // and adds the not-indexed phase for -1.
        var phases: [ANGPhase] = []
        for (k, id) in phaseFields.ids.enumerated() {
            let pointGroup = try pointGroupName(phaseFields.pointGroups[k], file: name)
            phases.append(ANGPhase(id: id, name: phaseFields.names[k], formula: k < formulas.count ? formulas[k] : nil, pointGroup: pointGroup,
                                   lattice: phaseFields.lattices[k]))
        }
        phases.sort { $0.id < $1.id }
        autogenerateNames(&phases, formulas: formulas, ids: phaseFields.ids)

        let list = PhaseList(ids: phases.filter { $0.id != -1 }.map(\.id),
                             phases: phases.filter { $0.id != -1 }.map {
                                 CrystalPhase(name: $0.name, formula: $0.formula, pointGroup: $0.pointGroup, lattice: $0.lattice,
                                              latticeUnit: .angstrom)
                             }, assignColors: true)
        let map = try CrystalMap(rotations: euler.map(quaternion(fromBungeEuler:)), euler: euler, phaseIDs: phaseIDs, x: x, y: y,
                                 phaseList: list, properties: properties, scanUnit: vendor == .astar ? "nm" : "um")
        return ANGMap(url: url, header: header, vendor: vendor, columnNames: columnNames, map: map)
    }

    // MARK: Header

    /// The fields orix leaves in the header, by their keyword at the start of a line.
    static func parseHeader(_ lines: [String]) -> ANGHeader {
        var header = ANGHeader(lines: lines)
        var star = SIMD3<Double>(repeating: .nan)
        for line in lines {
            let body = line.drop(while: { $0 == "#" || $0 == " " || $0 == "\t" })
            let parts = body.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard let key = parts.first else { continue }
            let value = parts.dropFirst().joined(separator: " ")
            switch key {
            case "GRID:": header.grid = value
            case "XSTEP:": header.stepX = Double(value)
            case "YSTEP:": header.stepY = Double(value)
            case "NCOLS_ODD:": header.columnsOdd = Int(value)
            case "NCOLS_EVEN:": header.columnsEven = Int(value)
            case "NROWS:": header.rows = Int(value)
            case "x-star": star.x = Double(value) ?? .nan
            case "y-star": star.y = Double(value) ?? .nan
            case "z-star": star.z = Double(value) ?? .nan
            case "WorkingDistance": header.workingDistance = Double(value)
            case "TEM_PIXperUM": header.temPixelsPerMicron = Double(value)
            default: break
            }
        }
        if !star.x.isNaN, !star.y.isNaN, !star.z.isNaN { header.projectionCenter = star }
        return header
    }

    struct PhaseFields {
        var ids: [Int]
        var names: [String]
        var pointGroups: [String]
        var lattices: [[Double]]
    }

    /// `_get_phases_from_header`: each keyword's regular expression (`re.search`), the line split on blanks after `lstrip("# ")` and `rstrip(" ")`,
    /// ids filled in where the header has fewer `Phase` lines than names.
    static func phasesFromHeader(_ lines: [String]) throws -> (PhaseFields, [String]) {
        var ids: [String] = [], names: [String] = [], formulas: [String] = [], pointGroups: [String] = [], lattices: [[Double]] = []
        for line in lines {
            for key in ["ids", "names", "formulas", "point_groups", "lattice_constants"] {
                guard matches(line, key: key) else { continue }
                var group = line.drop(while: { $0 == "#" || $0 == " " })
                while group.last == " " { group = group.dropLast() }
                let parts = group.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
                switch key {
                case "names": names.append(parts.dropFirst().joined(separator: " "))
                case "lattice_constants":
                    var numbers: [Double] = []
                    for part in parts.dropFirst() {
                        guard let value = Double(part) else { throw ANGReadError(text: "The lattice constants line '\(line)' holds '\(part)', which is not a number.") }
                        numbers.append(value)
                    }
                    lattices.append(numbers)
                case "ids": ids.append(parts.last ?? "")
                case "formulas": formulas.append(parts.last ?? "")
                default: pointGroups.append(parts.last ?? "")
                }
            }
        }
        var phaseIDs: [Int] = []
        for id in ids {
            guard let value = Int(id) else { throw ANGReadError(text: "The phase id '\(id)' in the header is not an integer.") }
            phaseIDs.append(value)
        }
        let n = names.count
        if phaseIDs.isEmpty { phaseIDs = Array(0..<n) }
        else if n > phaseIDs.count {
            // The phases without a `Phase` line take the ids after the largest; an id with no room after it in an Int is refused
            // (orix's Python ints never run out).
            let largest = phaseIDs.max() ?? 0   // a phase list with no id starts after 0
            let next = largest.addingReportingOverflow(1)
            let end = next.partialValue.addingReportingOverflow(n - phaseIDs.count)
            guard !next.overflow, !end.overflow else {
                throw ANGReadError(text: "The phase id '\(largest)' in the header is too large to number the phases after it.")
            }
            phaseIDs += Array(next.partialValue..<end.partialValue)
        }
        // orix zips names with ids, point groups and lattice constants: a header short of one truncates to the shortest (zip), and a
        // header with more point groups or lattices than names is read by PhaseList as an error.
        let count = min(phaseIDs.count, n)
        guard pointGroups.count == n, lattices.count == n else {
            throw ANGReadError(text: "The header names \(n) phases but has \(pointGroups.count) Symmetry and \(lattices.count) LatticeConstants lines.")
        }
        return (PhaseFields(ids: Array(phaseIDs.prefix(count)), names: Array(names.prefix(count)), pointGroups: Array(pointGroups.prefix(count)),
                            lattices: Array(lattices.prefix(count))), formulas)
    }

    /// orix's `str_patterns`, searched anywhere in the line: the keyword, one or more blanks, then a character of the class.
    static func matches(_ line: String, key: String) -> Bool {
        let keyword: String
        switch key {
        case "ids": keyword = "# Phase"
        case "names": keyword = "# MaterialName"
        case "formulas": keyword = "# Formula"
        case "point_groups": keyword = "# Symmetry"
        default: keyword = "# LatticeConstants"
        }
        guard let range = line.range(of: keyword) else { return false }
        let rest = Array(line[range.upperBound...].unicodeScalars)
        if key == "lattice_constants" {
            // `([ \t+])(.*)`: one blank, tab or plus, then anything.
            return rest.first.map { $0 == " " || $0 == "\t" || $0 == "+" } ?? false
        }
        var i = 0
        while i < rest.count, rest[i] == " " || rest[i] == "\t" { i += 1 }
        guard i > 0, i < rest.count else { return false }
        let c = rest[i].value
        if key == "ids" { return (c >= 48 && c <= 57) || c == 32 }
        // `[A-z0-9 ]`: ASCII 65 to 122 (the letters and the six characters between the cases), digits and the blank.
        return (c >= 65 && c <= 122) || (c >= 48 && c <= 57) || c == 32
    }

    /// `_autogen_phase_names`: with one formula per phase the names become the formulas ordered by id; the point group is appended where
    /// a formula repeats, and a letter where it still does.
    static func autogenerateNames(_ phases: inout [ANGPhase], formulas: [String], ids: [Int]) {
        guard formulas.count == phases.count, !phases.isEmpty else { return }
        let order = ids.indices.sorted { ids[$0] < ids[$1] }
        var names = order.map { formulas[$0] }
        func repeats(_ names: [String]) -> Bool { Set(names).count < names.count }
        // Python's `chr(65 + i)`: A to Z, then on through Unicode past the 26th phase; a surrogate, which no Swift string holds, by
        // its number.
        func letter(_ i: Int) -> String {
            guard let code = UInt32(exactly: 65 + i), let scalar = Unicode.Scalar(code) else { return String(i) }
            return String(Character(scalar))
        }
        if repeats(names) { names = names.indices.map { names[$0] + "-" + (phases[$0].pointGroup ?? "None") } }
        if repeats(names) { names = names.indices.map { names[$0] + "-" + letter($0) } }
        for i in phases.indices { phases[i].name = names[i] }
    }

    /// The vendor by its footprint in the header (the last footprint in orix's order that any line holds; EDAX TSL when none), and the column
    /// names for the file's column count (`_get_vendor_columns`).
    static func vendorColumns(_ header: [String], fileColumns: Int) -> (ANGMap.Vendor, [String]) {
        var vendor = ANGMap.Vendor.tsl
        var footprintLine: String?
        let footprints: [(ANGMap.Vendor, String)] = [(.emsoft, "EMsoft"), (.astar, "ACOM"), (.orix, "Column names: phi1, Phi, phi2")]
        for (name, footprint) in footprints {
            if let line = header.first(where: { $0.contains(footprint) }) { vendor = name; footprintLine = line }
        }
        let base = ["euler1", "euler2", "euler3", "x", "y"]
        let variants: [[String]]
        switch vendor {
        case .tsl: variants = [base + ["iq", "ci", "phase_id", "detector_signal", "fit", "unknown1", "unknown2", "unknown3", "unknown4"],
                               base + ["iq", "ci", "phase_id", "detector_signal", "fit"]]
        case .emsoft: variants = [base + ["iq", "dp", "phase_id"]]
        case .astar: variants = [base + ["ind", "rel", "phase_id", "relx100"]]
        case .orix: variants = [base + ["iq", "ci", "phase_id", "detector_signal", "fit"]]
        case .unknown: variants = [base + ["unknown1", "unknown2", "phase_id"]]
        }
        if vendor == .orix, let footprintLine, footprintLine.contains("Column names") {
            var names = variants[0]
            // `footprint_line.split(":")[1]`: the text between the first and the second colon.
            let segments = footprintLine.split(separator: ":", omittingEmptySubsequences: false)
            let afterColon = segments.count > 1 ? String(segments[1]) : ""
            let extra = afterColon.split(separator: ",", omittingEmptySubsequences: false).dropFirst(names.count)
            names += extra.map { String($0).drop(while: { $0 == " " }).replacingOccurrences(of: " ", with: "_") }
            return (vendor, names)
        }
        if let names = variants.first(where: { $0.count == fileColumns }) { return (vendor, names) }
        var names = base + ["unknown1", "unknown2", "phase_id"]
        if fileColumns > names.count { for i in 0..<(fileColumns - names.count) { names.append("unknown\(i + 3)") } }
        return (.unknown, names)
    }

    /// orix's point-group names, and its EDAX aliases (`_EDAX_POINT_GROUP_ALIASES`); a name orix does not know is a refusal.
    static let pointGroupNames: Set<String> = ["1", "-1", "211", "121", "112", "2", "m11", "1m1", "11m", "m", "2/m", "222", "mm2", "mmm", "4", "-4", "4/m",
                                               "422", "4mm", "-42m", "4/mmm", "3", "-3", "321", "312", "32", "3m", "-3m", "6", "-6", "6/m", "622", "6mm",
                                               "-6m2", "6/mmm", "23", "m-3", "432", "-43m", "m-3m"]
    static let edaxAliases: [String: String] = ["20": "121", "2": "2/m", "22": "222", "42": "422", "32": "321", "62": "622", "43": "432", "m3m": "m-3m"]

    static func pointGroupName(_ symmetry: String, file: String) throws -> String {
        let name = edaxAliases[symmetry] ?? symmetry
        guard pointGroupNames.contains(name) else {
            throw ANGReadError(text: "\(file): the symmetry '\(symmetry)' in the header is not a point group orix knows.")
        }
        return name
    }

    // MARK: Numbers

    /// `eu2qu` (Rowenhorst et al. 2015, eqs. A.5 and A.6): Bunge (passive Z-X-Z) Euler angles in radians to a unit quaternion with a
    /// non-negative scalar part; orix's `from_euler` default direction (lab to crystal). The orientation core's
    /// `RotationConversions.eu2qu` (Sources/TEMCore/SEM/Orientation).
    package static func quaternion(fromBungeEuler eu: SIMD3<Double>) -> SIMD4<Double> {
        RotationConversions.eu2qu(eu)
    }

    private static func rstrip(_ line: String) -> String {
        var s = Substring(line)
        while let last = s.last, last == " " || last == "\t" || last == "\r" || last == "\n" { s = s.dropLast() }
        return String(s)
    }
}

package nonisolated struct ANGReadError: Error, LocalizedError, Equatable {
    package var text: String
    package var errorDescription: String? { text }
    package init(text: String) { self.text = text }
}
