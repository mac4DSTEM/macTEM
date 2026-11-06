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
//        phase list to the caller (D-SEM-17).
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

        package var reason: String {
            switch self {
            case .notText: "it is not a text file."
            case .noColumnLine: "it has no `Phase X Y ...` column line in its first 1000 lines and no column names on its first line."
            case .noPhases: "its header has no `Phases` line."
            case .phase(let line, let what): "its phase on line \(line) is not read: \(what)."
            case .row(let line, let columns, let needed): "line \(line) has \(columns) columns; \(needed) are needed."
            case .number(let line, let text): "line \(line) holds `\(text)` where a number is needed."
            case .missingColumn(let name): "its column names lack `\(name)`."
            }
        }
    }

    /// orix's Laue group ids (`laue_ids` in ctf.py).
    package static let laueGroups: [Int: String] = [
        1: "-1", 2: "2/m", 3: "mmm", 4: "4/m", 5: "4/mmm", 6: "-3", 7: "-3m", 8: "6/m", 9: "6/mmm", 10: "m3", 11: "m-3m",
    ]

    package static func read(path: String) throws -> CrystalMapData {
        let data = try Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped)
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw Refusal.notText
        }
        return try read(text: text)
    }

    package static func read(text: String) throws -> CrystalMapData {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> Substring in
            line.last == "\r" ? line.dropLast() : line
        }

        // _get_header: the lines up to the column line, and the vendor.
        var header: [String] = []
        var columnLine: Int?
        var vendors: [CrystalMapData.Vendor] = []
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
        let vendor = vendors.count == 1 ? vendors[0] : CrystalMapData.Vendor.oxfordOrBruker

        let phases = try phasesFromHeader(header)
        let rows = try numberRows(lines: lines, from: columnLine + 1, needed: 11)

        var x = [Double](), y = [Double](), phaseID = [Int](), euler = [Double]()
        x.reserveCapacity(rows.count); y.reserveCapacity(rows.count); phaseID.reserveCapacity(rows.count)
        euler.reserveCapacity(3 * rows.count)
        var bands = [Double](), error = [Double](), mad = [Double](), bc = [Double](), bs = [Double]()
        for row in rows {
            let id = Int(row[0])
            phaseID.append(id == 0 ? -1 : id)
            x.append(row[1]); y.append(row[2])
            bands.append(row[3]); error.append(row[4])
            euler.append(row[5]); euler.append(row[6]); euler.append(row[7])
            mad.append(row[8]); bc.append(row[9]); bs.append(row[10])
        }
        let names = vendor == .emsoft ? ["bands", "error", "DP", "OSM", "IQ"] : ["bands", "error", "MAD", "BC", "BS"]
        let properties = Dictionary(uniqueKeysWithValues: zip(names, [bands, error, mad, bc, bs]))

        if vendor == .astar { fixASTARCoordinates(header: header, x: &x, y: &y) }

        return CrystalMapData(phases: phases, x: x, y: y, phaseID: phaseID, eulerDegrees: euler, propertyNames: names,
                              properties: properties, scanUnit: "um", vendor: vendor, header: header)
    }

    // MARK: - The header

    /// `_get_phases_from_header`.
    static func phasesFromHeader(_ header: [String]) throws -> [CrystalMapData.Phase] {
        guard let phasesLine = header.firstIndex(where: { $0.hasPrefix("Phases") }) else { throw Refusal.noPhases }
        let fields = header[phasesLine].split(separator: "\t", omittingEmptySubsequences: false)
        guard fields.count > 1, let count = Int(fields[1].trimmingCharacters(in: .whitespaces)) else { throw Refusal.noPhases }
        var phases: [CrystalMapData.Phase] = []
        for i in 0..<count {
            let lineNumber = phasesLine + 1 + i
            guard lineNumber < header.count else { throw Refusal.phase(line: lineNumber + 1, "the header ends before it") }
            let parts = header[lineNumber].split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 5 else { throw Refusal.phase(line: lineNumber + 1, "it has \(parts.count) tab-separated fields, 5 are needed") }
            let constants = (parts[0] + ";" + parts[1]).split(separator: ";", omittingEmptySubsequences: false)
                .map { Double($0.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)) }
            guard constants.count == 6, !constants.contains(where: { $0 == nil }) else {
                throw Refusal.phase(line: lineNumber + 1, "its lattice `\(parts[0])\t\(parts[1])` is not six numbers")
            }
            guard let laue = Int(parts[3].trimmingCharacters(in: .whitespaces)), let group = laueGroups[laue] else {
                throw Refusal.phase(line: lineNumber + 1, "its Laue group id `\(parts[3])` is not 1 to 11")
            }
            guard let spaceGroup = Int(parts[4].trimmingCharacters(in: .whitespaces)) else {
                throw Refusal.phase(line: lineNumber + 1, "its space group `\(parts[4])` is not a number")
            }
            phases.append(CrystalMapData.Phase(id: i + 1, name: parts[2], lattice: constants.map { $0! }, laueGroupID: laue,
                                               pointGroup: group, spaceGroup: spaceGroup == 0 ? nil : spaceGroup))
        }
        return phases
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
    /// coordinates are regenerated from the header's steps (orix compares the x slice with the y cells; kept as is).
    static func fixASTARCoordinates(header: [String], x: inout [Double], y: inout [Double]) {
        let slices = CrystalMapData.dataSlices(coordinates: [x, y], steps: [CrystalMapData.stepSize(x), CrystalMapData.stepSize(y)])
        guard slices.count == 2,
              let cellsX = headerValue(header, key: "XCells"), let cellsY = headerValue(header, key: "YCells"),
              let stepX = headerValue(header, key: "XStep"), let stepY = headerValue(header, key: "YStep") else { return }
        let found = [slices[0].stop + 1, slices[1].stop + 1]
        let shape = [Int(cellsY), Int(cellsX)]
        guard found != shape else { return }
        var newX = [Double](), newY = [Double]()
        newX.reserveCapacity(shape[0] * shape[1]); newY.reserveCapacity(shape[0] * shape[1])
        for row in 0..<shape[0] {
            for column in 0..<shape[1] {
                newY.append(Double(row) * stepY)
                newX.append(Double(column) * stepX)
            }
        }
        x = newX
        y = newY
    }

    // MARK: - The rows

    /// numpy.loadtxt below the header: blank and `#` lines skipped, whitespace-separated numbers, at least `needed` a row.
    static func numberRows(lines: [Substring], from start: Int, needed: Int) throws -> [[Double]] {
        var rows: [[Double]] = []
        rows.reserveCapacity(max(0, lines.count - start))
        for index in start..<lines.count {
            let line = lines[index]
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard let first = fields.first, !first.hasPrefix("#") else { continue }
            guard fields.count >= needed else { throw Refusal.row(line: index + 1, columns: fields.count, needed: needed) }
            var row = [Double]()
            row.reserveCapacity(fields.count)
            for field in fields {
                guard let value = Double(field) else { throw Refusal.number(line: index + 1, String(field)) }
                row.append(value)
            }
            rows.append(row)
        }
        return rows
    }

    // MARK: - The orientation table

    /// A headerless export: the first line names the columns, every other line is one point.
    static func readOrientationTable(lines: [Substring]) throws -> CrystalMapData {
        guard let nameLine = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else { throw Refusal.noColumnLine }
        let names = lines[nameLine].split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard names.contains("phi1"), names.contains("Phi"), names.contains("phi2") else { throw Refusal.noColumnLine }
        let rows = try numberRows(lines: lines, from: nameLine + 1, needed: names.count)
        func column(_ name: String) -> [Double]? {
            guard let i = names.firstIndex(of: name) else { return nil }
            return rows.map { $0[i] }
        }
        var euler = [Double]()
        euler.reserveCapacity(3 * rows.count)
        let i1 = names.firstIndex(of: "phi1")!, i2 = names.firstIndex(of: "Phi")!, i3 = names.firstIndex(of: "phi2")!
        for row in rows { euler.append(row[i1]); euler.append(row[i2]); euler.append(row[i3]) }
        let phaseID = column("phase").map { $0.map { Int($0) == 0 ? -1 : Int($0) } } ?? [Int](repeating: 1, count: rows.count)
        let taken: Set<String> = ["phi1", "Phi", "phi2", "phase", "x", "y"]
        let propertyNames = names.filter { !taken.contains($0) }
        let properties = Dictionary(uniqueKeysWithValues: propertyNames.map { ($0, column($0)!) })
        return CrystalMapData(phases: [], x: column("x") ?? [], y: column("y") ?? [], phaseID: phaseID, eulerDegrees: euler,
                              propertyNames: propertyNames, properties: properties, scanUnit: "um", vendor: .orientationTable,
                              header: [String(lines[nameLine])])
    }
}
