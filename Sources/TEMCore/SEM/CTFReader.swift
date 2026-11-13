//
//  CTFReader.swift
//  Role: read a Channel Text File (`.ctf`, Oxford Instruments' text orientation map, also written by Bruker Esprit, NanoMegas
//        ASTAR, EMsoft's EMdpmerge and MTEX) as orix 0.15.0 reads it (orix/io/plugins/ctf.py, GPL-3.0-or-later). Port, step
//        for step: the header up to the `Phase<tab>X<tab>Y` column line (at most 1000 lines), the vendor from the header's
//        wording (EMsoft, ASTAR, MTEX, else Oxford or Bruker), the `Phases` block (lattice `a;b;c` and `α;β;γ` with a comma
//        or a point as the decimal mark, the name, the Laue group id, the space group with 0 meaning none), then the eleven
//        columns by position: phase, x, y, bands, error, Euler1, Euler2, Euler3, MAD, BC, BS (a phase of 0 is not indexed;
//        EMsoft's last three are named DP, OSM and IQ); ASTAR coordinates are regenerated from the header's cells and steps
//        when their rounded decimals give another map shape, as orix does. The scan unit is µm.
//
//        A second form, the headerless orientation table (first line the column names `phi1 Phi phi2 phase bands ...`,
//        orix-data's Ti_orientations.ctf exported from MTEX): orix.data.ti_orientations reads its three Euler columns with
//        numpy and attaches the 622 point group by hand; this reader keeps every column under its name and leaves the
//        phase list to the caller (D-SEM-19).
//
//        The result is the dataset's `CrystalMap` (Euler angles in radians as orix holds them, the file's phase ids with -1 for
//        not indexed and orix's `not_indexed` phase, the coordinates, the vendor's columns by name) with the vendor and the
//        header lines beside it.
//
//        The parity test reads the files orix's own tests write and the head of Ti_orientations.ctf at 1e-12
//        (macTEMTests/Fixtures/sem/oxford, from tools/parity/sem-readers/make_oxford_fixtures.py).
//

import Foundation

package nonisolated enum CTFReader {
    package enum Refusal: Error, Equatable {
        case notText
        case noColumnLine
        case noPhases
        case phase(line: Int, String)
        case row(line: Int, columns: Int, needed: Int)
        case number(line: Int, String)
        case missingColumn(String)
        /// An orientation table naming one property column twice.
        case repeatedColumn(String)
        /// An ASTAR header whose `XCells` and `YCells` are not a count of cells, or whose cells do not hold the file's points.
        case cells(points: Int)

        package var reason: String {
            switch self {
            case .notText: "it is not a text file."
            case .noColumnLine: "it has no `Phase X Y ...` column line in its first 1000 lines and no column names on its first line."
            case .noPhases: "its header has no `Phases` line with a count of phases."
            case .phase(let line, let what): "its phase on line \(line) is not read: \(what)."
            case .row(let line, let columns, let needed): "line \(line) has \(columns) columns; \(needed) are needed."
            case .number(let line, let text): "line \(line) holds `\(text)` where a number is needed."
            case .missingColumn(let name): "its column names lack `\(name)`."
            case .repeatedColumn(let name): "its column names hold `\(name)` twice."
            case .cells(let points): "its header's `XCells` and `YCells` are not a grid of its \(points) points."
            }
        }
    }

    /// orix's Laue group ids (`laue_ids` in ctf.py), except 10: orix 0.15.0 names it "m3", a point group its own `Phase` does not
    /// know, so its loader raises on a `.ctf` with a Laue-10 phase (pyrite, for one). Read as "m-3", as Oxford means it and as
    /// `CTFWriter.laueIDs` and the H5OINA reader write it (#515; docs/parity.md).
    package static let laueGroups: [Int: String] = [
        1: "-1", 2: "2/m", 3: "mmm", 4: "4/m", 5: "4/mmm", 6: "-3", 7: "-3m", 8: "6/m", 9: "6/mmm", 10: "m-3", 11: "m-3m",
    ]

    /// Who wrote the file, as orix detects it from the header; `orientationTable` is a headerless export (first line the
    /// column names, as orix-data's Ti_orientations.ctf from MTEX).
    package enum Vendor: String, Sendable {
        case oxfordOrBruker = "oxford_or_bruker"
        case emsoft
        case astar
        case mtex
        case orientationTable = "orientation_table"
    }

    /// One `.ctf` file: the map, who wrote it, and its header.
    package struct File: Sendable, Equatable {
        package var map: CrystalMap
        package var vendor: Vendor
        /// The header lines above the data, verbatim.
        package var header: [String]
        /// The vendor's per-point columns beyond phase, coordinates and Euler angles, in file order (the keys of `map.properties`).
        package var propertyNames: [String]
        /// µm, in every form the reader knows.
        package var scanUnit: String { "um" }
        package var pointCount: Int { map.pointCount }
    }

    package static func read(path: String) throws -> File {
        let data = try Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped)
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw Refusal.notText
        }
        return try read(text: text)
    }

    /// Degrees to radians as numpy's `deg2rad` computes it.
    static func radians(_ degrees: Double) -> Double { degrees * (Double.pi / 180) }

    package static func read(text: String) throws -> File {
        // LF, CRLF (AZtec on Windows) and CR end a line, as Python's `open()` reads them for orix (#518).
        let lines = TextLines.split(text)

        // _get_header: the lines up to the column line, and the vendor.
        var header: [String] = []
        var columnLine: Int?
        var vendors: [Vendor] = []
        for (index, line) in lines.enumerated() where index < 1000 {
            if line.hasPrefix("Phase\tX\tY") { columnLine = index; break }
            if line.contains("EMsoft v. "), line.contains("; BANDS=pattern index, MAD=CI, BC=OSM, BS=IQ"),
               line.range(of: #"EMsoft v\. ([A-Za-z0-9]+(_[A-Za-z0-9]+)+); BANDS=pattern index, MAD=CI, BC=OSM, BS=IQ"#, options: .regularExpression) != nil {
                vendors.append(.emsoft)
            }
            if line.range(of: #"Author[\t\s]File created from ACOM RES results"#, options: .regularExpression) != nil { vendors.append(.astar) }
            if line.contains("Created from mtex") { vendors.append(.mtex) }
            header.append(String(line))
        }
        guard let columnLine else { return try readOrientationTable(lines: lines) }
        let vendor = vendors.count == 1 ? vendors[0] : Vendor.oxfordOrBruker

        let phases = try phasesFromHeader(header)
        let rows = try numberRows(lines: lines, from: columnLine + 1, needed: 11, phaseColumn: 0)

        var x = [Double](), y = [Double](), phaseID = [Int](), euler = [SIMD3<Double>]()
        x.reserveCapacity(rows.count); y.reserveCapacity(rows.count); phaseID.reserveCapacity(rows.count)
        euler.reserveCapacity(rows.count)
        var bands = [Double](), error = [Double](), mad = [Double](), bc = [Double](), bs = [Double]()
        for row in rows {
            let id = Int(row[0])
            phaseID.append(id == 0 ? -1 : id)
            x.append(row[1]); y.append(row[2])
            bands.append(row[3]); error.append(row[4])
            euler.append(SIMD3(radians(row[5]), radians(row[6]), radians(row[7])))
            mad.append(row[8]); bc.append(row[9]); bs.append(row[10])
        }
        let names = vendor == .emsoft ? ["bands", "error", "DP", "OSM", "IQ"] : ["bands", "error", "MAD", "BC", "BS"]
        let properties = Dictionary(uniqueKeysWithValues: zip(names, [bands, error, mad, bc, bs]))

        if vendor == .astar { try fixASTARCoordinates(header: header, x: &x, y: &y) }

        let map = try CrystalMap(euler: euler, phaseIDs: phaseID, x: x, y: y, phaseList: phases, properties: properties, scanUnit: "um")
        return File(map: map, vendor: vendor, header: header, propertyNames: names)
    }

    // MARK: - The header

    /// `_get_phases_from_header`.
    static func phasesFromHeader(_ header: [String]) throws -> PhaseList {
        guard let phasesLine = header.firstIndex(where: { $0.hasPrefix("Phases") }) else { throw Refusal.noPhases }
        let fields = header[phasesLine].split(separator: "\t", omittingEmptySubsequences: false)
        guard fields.count > 1, let count = Int(fields[1].trimmingCharacters(in: .whitespaces)), count >= 0 else { throw Refusal.noPhases }
        var phases: [CrystalPhase] = []
        for i in 0..<count {
            let lineNumber = phasesLine + 1 + i
            guard lineNumber < header.count else { throw Refusal.phase(line: lineNumber + 1, "the header ends before it") }
            let parts = header[lineNumber].split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 5 else { throw Refusal.phase(line: lineNumber + 1, "it has \(parts.count) tab-separated fields, 5 are needed") }
            let constants = (parts[0] + ";" + parts[1]).split(separator: ";", omittingEmptySubsequences: false)
                .map { Double($0.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)) }
            let lattice = constants.compactMap { $0 }
            guard constants.count == 6, lattice.count == 6 else {
                throw Refusal.phase(line: lineNumber + 1, "its lattice `\(parts[0])\t\(parts[1])` is not six numbers")
            }
            guard let laue = Int(parts[3].trimmingCharacters(in: .whitespaces)), let group = laueGroups[laue] else {
                throw Refusal.phase(line: lineNumber + 1, "its Laue group id `\(parts[3])` is not 1 to 11")
            }
            guard let spaceGroup = Int(parts[4].trimmingCharacters(in: .whitespaces)) else {
                throw Refusal.phase(line: lineNumber + 1, "its space group `\(parts[4])` is not a number")
            }
            phases.append(CrystalPhase(name: parts[2], spaceGroup: spaceGroup == 0 ? nil : spaceGroup, pointGroup: group,
                                       lattice: lattice))
        }
        // orix's `PhaseList(**phases)`: ids 1, 2, ... in header order, colours in matplotlib's Tableau order.
        return PhaseList(ids: (0..<count).map { $0 + 1 }, phases: phases, assignColors: true)
    }

    /// `XCells`/`YCells` and `XStep`/`YStep` from the header (a comma as the decimal mark is read as a point).
    static func headerValue(_ header: [String], key: String) -> Double? {
        for line in header where line.hasPrefix(key) {
            let rest = line.dropFirst(key.count).trimmingCharacters(in: .whitespaces)
            return Double(rest.replacingOccurrences(of: ",", with: "."))
        }
        return nil
    }

    /// `_fix_astar_coords`: when the coordinates' decimals round to another extent than the header's cells, the
    /// coordinates are regenerated from the header's steps (orix compares the x slice with the y cells; kept as is). Cells that
    /// are no count (not finite, or beyond an Int), or whose grid would not hold the file's points (the map could not be built from
    /// it), are refused before the new coordinates are allocated. Coordinates `CrystalMap.checkedSlices` refuses (not finite, or a
    /// step far finer than their spread) are left as read, for the map to refuse.
    static func fixASTARCoordinates(header: [String], x: inout [Double], y: inout [Double]) throws {
        guard let slices = try? CrystalMap.checkedSlices([("x", x), ("y", y)]), slices.count == 2,
              let cellsX = headerValue(header, key: "XCells"), let cellsY = headerValue(header, key: "YCells"),
              let stepX = headerValue(header, key: "XStep"), let stepY = headerValue(header, key: "YStep") else { return }
        // The cells truncated as `Int(_:)` truncates them.
        guard let rows = Int(exactly: cellsY.rounded(.towardZero)), let columns = Int(exactly: cellsX.rounded(.towardZero)) else {
            throw Refusal.cells(points: x.count)
        }
        let found = [slices[0].stop + 1, slices[1].stop + 1]
        let shape = [rows, columns]
        guard found != shape else { return }
        let cells = rows.multipliedReportingOverflow(by: columns)
        guard rows >= 0, columns >= 0, !cells.overflow, cells.partialValue == x.count else { throw Refusal.cells(points: x.count) }
        var newX = [Double](), newY = [Double]()
        newX.reserveCapacity(cells.partialValue); newY.reserveCapacity(cells.partialValue)
        for row in 0..<rows {
            for column in 0..<columns {
                newY.append(Double(row) * stepY)
                newX.append(Double(column) * stepX)
            }
        }
        x = newX
        y = newY
    }

    // MARK: - The rows

    /// numpy.loadtxt below the header: blank and `#` lines skipped, whitespace-separated numbers, at least `needed` a row. The field in
    /// `phaseColumn` must be a phase id (`isPhaseID`).
    static func numberRows(lines: [Substring], from start: Int, needed: Int, phaseColumn: Int? = nil) throws -> [[Double]] {
        var rows: [[Double]] = []
        rows.reserveCapacity(max(0, lines.count - start))
        for index in start..<lines.count {
            let line = lines[index]
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard let first = fields.first, !first.hasPrefix("#") else { continue }
            guard fields.count >= needed else { throw Refusal.row(line: index + 1, columns: fields.count, needed: needed) }
            var row = [Double]()
            row.reserveCapacity(fields.count)
            for (k, field) in fields.enumerated() {
                guard let value = Double(field), k != phaseColumn || isPhaseID(value) else {
                    throw Refusal.number(line: index + 1, String(field))
                }
                row.append(value)
            }
            rows.append(row)
        }
        return rows
    }

    /// A phase id `Int(_:)` takes, truncating as orix's `int()` does: finite and inside Int's range (`Int(_:)` traps on anything else).
    static func isPhaseID(_ value: Double) -> Bool { Int(exactly: value.rounded(.towardZero)) != nil }

    // MARK: - The orientation table

    /// A headerless export: the first line names the columns, every other line is one point.
    static func readOrientationTable(lines: [Substring]) throws -> File {
        guard let nameLine = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else { throw Refusal.noColumnLine }
        let names = lines[nameLine].split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard names.contains("phi1"), names.contains("Phi"), names.contains("phi2") else { throw Refusal.noColumnLine }
        let rows = try numberRows(lines: lines, from: nameLine + 1, needed: names.count, phaseColumn: names.firstIndex(of: "phase"))
        func column(_ name: String) -> [Double]? {
            guard let i = names.firstIndex(of: name) else { return nil }
            return rows.map { $0[i] }
        }
        var euler = [SIMD3<Double>]()
        euler.reserveCapacity(rows.count)
        guard let i1 = names.firstIndex(of: "phi1"), let i2 = names.firstIndex(of: "Phi"), let i3 = names.firstIndex(of: "phi2") else {
            throw Refusal.noColumnLine
        }
        for row in rows { euler.append(SIMD3(radians(row[i1]), radians(row[i2]), radians(row[i3]))) }
        // A phase that is not a whole number (NaN in a damaged export) is not indexed, -1, never `Int(NaN)`.
        let phaseID = column("phase").map { $0.map { CheckedConversion.int($0).map { $0 == 0 ? -1 : $0 } ?? -1 } } ?? [Int](repeating: 1, count: rows.count)
        let taken: Set<String> = ["phi1", "Phi", "phi2", "phase", "x", "y"]
        let propertyNames = names.filter { !taken.contains($0) }
        var seen: Set<String> = []
        for name in propertyNames {
            guard seen.insert(name).inserted else { throw Refusal.repeatedColumn(name) }
        }
        let properties = Dictionary(uniqueKeysWithValues: propertyNames.map { ($0, column($0) ?? []) })   // every name is a column
        let map = try CrystalMap(euler: euler, phaseIDs: phaseID, x: column("x"), y: column("y"), properties: properties, scanUnit: "um")
        return File(map: map, vendor: .orientationTable, header: [String(lines[nameLine])], propertyNames: propertyNames)
    }
}
