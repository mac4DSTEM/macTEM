//
//  EBSDH5Reader+OxfordMap.swift
//  Role: the orientation map of an Oxford Instruments H5OINA file that holds no patterns (AZtec's map export; #513), for the Maps room,
//        as it reads the `.ctf` AZtec writes for the same map (`CTFReader`, orix's ctf.py): Bunge Euler angles in radians kept as stored
//        (orientation of the crystal to the sample surface, CS1; no frame correction, as for a `.ctf`), phase 0 not indexed (-1), the
//        phases of `Header/Phases` by their group numbers with Oxford's Laue group ids (the `.ctf`'s 1 to 11) and space groups, the
//        columns `bands`, `error`, `MAD`, `BC`, `BS` under the `.ctf`'s names, MAD in degrees as the `.ctf` writes it (H5OINA stores
//        radians), µm. Neither kikuchipy nor orix reads an H5OINA map (kikuchipy 0.13.1 leaves an empty `xmap`), so the layout is the
//        H5OINA specification's (github.com/oinanoanalysis/h5oina, H5OINAFile.md), placed as MTEX and DREAM3D's EbsdLib place it:
//        the points row by row on the header's `X Cells` x `Y Cells` grid with its steps (MTEX's hdf5 config), each point at the cell
//        its `X` and `Y` give where they fill the grid once (EbsdLib's `BuildScanGridOrderFromPositions`). Lattice angles are stored in
//        radians as float32 and read in degrees, 90° and 120° exactly so (as MTEX snaps them).
//        A file without Euler angles, phases, cells or steps is refused in words that name it.
//        Tests: EBSDH5OxfordMapTests on the planted Fixtures/ebsd-oxford-map*.h5oina (tools/parity/sem-readers/make_h5oina_map_fixtures.py).
//

import Foundation
import FormatoCore
import FormatoHDF5

nonisolated extension EBSDH5Reader {
    /// The datasets an H5OINA scan keeps its patterns in (kikuchipy's `pattern_dataset_names`).
    static let oxfordPatternNames = ["Unprocessed Patterns", "Processed Patterns"]

    /// Whether an H5OINA scan's `EBSD/Data` holds patterns; AZtec also exports the map alone.
    static func holdsOxfordPatterns(_ data: H5Group) -> Bool { oxfordPatternNames.contains { data.name(for: $0) != nil } }

    /// Oxford's Laue group ids, as the `.ctf` numbers them (`CTFWriter.laueIDs`, DREAM3D's `Ctf::LaueGroupTable`), by orix's names.
    static let oxfordLaueGroups: [Int: String] = Dictionary(uniqueKeysWithValues: CTFWriter.laueIDs.map { ($0.value, $0.key) })

    /// The map of the first scan of the H5OINA file at `url` (`probe` says it holds no patterns). Reads the whole map; run it off the
    /// main actor, inside the file's security scope.
    package static func readOxfordMap(url: URL) throws -> CrystalMap {
        do {
            let reader = try HDF5Reader(url: url)
            let top = try TopGroup(reader)
            guard format(ofManufacturer: top.manufacturer) == .oxfordH5OINA else {
                throw EBSDReadError(text: "\(url.lastPathComponent) is not an Oxford Instruments .h5oina file.")
            }
            guard let scan = top.scanGroups.first else {
                throw EBSDReadError(text: "\(url.lastPathComponent) holds no EBSD map: it has no group with 'EBSD/Data' and 'EBSD/Header'.")
            }
            return try readOxfordMap(H5File(reader: reader, url: url), scan: scan)
        } catch { throw EBSDReadError.wrap(error, file: url) }
    }

    static func readOxfordMap(_ file: H5File, scan: String) throws -> CrystalMap {
        let name = file.url.lastPathComponent
        let header = try H5Group(file, "/\(scan)/EBSD/Header")
        let data = try H5Group(file, "/\(scan)/EBSD/Data")
        guard let eulerInfo = try data.info("Euler"), let flatEuler = try data.doubles("Euler") else {
            throw EBSDReadError(text: "\(name) holds neither EBSD patterns nor orientations: its EBSD data has no Euler angles.")
        }
        guard let phaseColumn = try data.doubles("Phase") else {
            throw EBSDReadError(text: "\(name) has orientations but not the phase of each point: its EBSD data has no 'Phase'.")
        }
        guard let columns = try header.int("X Cells"), let rows = try header.int("Y Cells"), columns >= 1, rows >= 1 else {
            throw EBSDReadError(text: "\(name) does not give the map's size: its EBSD header needs 'X Cells' and 'Y Cells' of at least 1.")
        }
        let n = phaseColumn.count
        guard let cells = ReaderNumber.product([rows, columns]), cells == n else {
            throw EBSDReadError(text: "\(name) has \(n) points, but its header gives a map of \(columns) x \(rows) points.")
        }
        guard eulerInfo.shape == [n, 3], flatEuler.count == 3 * n else {
            throw EBSDReadError(text: "\(name) has Euler angles of shape \(eulerInfo.shape) for its \(n) points; \(n) x 3 are needed.")
        }
        let dx = try header.double("X Step"), dy = try header.double("Y Step")
        guard let dx, let dy, dx.isFinite, dx > 0, dy.isFinite, dy > 0 || rows == 1 else {
            throw EBSDReadError(text: "\(name) does not give the map's step: its EBSD header needs a positive 'X Step' and 'Y Step'.")
        }
        let phases = try oxfordPhases(header, file: name)

        // Where each stored point lies on the grid: its X and Y where they place every point once, else the order it is stored in.
        let xs = try data.doubles("X"), ys = try data.doubles("Y")
        let cellOf = xs.flatMap { x in ys.flatMap { y in
            oxfordGridOrder(x: x, y: y, columns: columns, rows: rows, dx: dx, dy: dy)
        } }
        func placed(_ values: [Double]) -> [Double] {
            guard let cellOf else { return values }
            var out = [Double](repeating: 0, count: n)
            for (i, cell) in cellOf.enumerated() { out[cell] = values[i] }
            return out
        }

        var euler = [SIMD3<Double>](repeating: .zero, count: n)
        var phaseIDs = [Int](repeating: 0, count: n)
        for i in 0..<n {
            let cell = cellOf?[i] ?? i
            euler[cell] = SIMD3(flatEuler[3 * i], flatEuler[3 * i + 1], flatEuler[3 * i + 2])
            let id = try wholeNumber(phaseColumn[i], "a phase of '/\(scan)/EBSD/Data/Phase'")
            phaseIDs[cell] = id == 0 ? PhaseList.notIndexedID : id
        }
        var properties: [String: [Double]] = [:]
        for (key, label) in [("Bands", "bands"), ("Error", "error"), ("Mean Angular Deviation", "MAD"), ("Band Contrast", "BC"), ("Band Slope", "BS")] {
            guard let values = try data.doubles(key), values.count == n else { continue }
            properties[label] = placed(key == "Mean Angular Deviation" ? values.map { $0 * 180 / Double.pi } : values)
        }
        let grid = CrystalMap.coordinates(shape: (rows: rows, columns: columns), steps: (dy: dy, dx: dx))
        return try CrystalMap(euler: euler, phaseIDs: phaseIDs, x: grid.x, y: rows > 1 ? grid.y : nil, phaseList: phases,
                              properties: properties, scanUnit: "um")
    }

    /// `Header/Phases`: one group per phase, named by its id (1, 2, ...), in id order; colours in orix's Tableau order, as for a `.ctf`.
    static func oxfordPhases(_ header: H5Group, file name: String) throws -> PhaseList {
        guard let list = try header.subgroup("Phases") else {
            throw EBSDReadError(text: "\(name) does not list its crystal phases: its EBSD header has no 'Phases'.")
        }
        var entries: [(id: Int, phase: CrystalPhase)] = []
        for groupName in list.names {
            guard let id = Int(groupName.trimmingCharacters(in: .whitespaces)), let group = try list.subgroup(groupName) else { continue }
            let phaseName = (try group.string("Phase Name") ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "\0").union(.whitespaces))
            // The id, as the `.ctf` and EbsdLib read it; where it is none of the eleven, the `Symbol` the specification puts beside it
            // (MTEX reads that), when it names a Laue group.
            let laue = try group.double("Laue Group")
            let fromID = laue.flatMap { ReaderNumber.int($0) }.flatMap { oxfordLaueGroups[$0] }
            let fromSymbol = oxfordLaueSymbol(group).map { oxfordLaueAliases[$0] ?? $0 }.flatMap { oxfordLaueGroups.values.contains($0) ? $0 : nil }
            guard let pointGroup = fromID ?? fromSymbol else {
                let given = laue.map { value in ReaderNumber.int(value).map { String($0) } ?? "\(value)" } ?? "none"
                throw EBSDReadError(text: "\(name): phase \(id) (\(phaseName.isEmpty ? "unnamed" : phaseName)) has Laue group \(given), "
                                    + "not one of Oxford's 1 to 11, so its symmetry is unknown.")
            }
            let spaceGroup = try group.double("Space Group").flatMap { ReaderNumber.int($0) }.flatMap { (1...230).contains($0) ? $0 : nil }
            var lattice: [Double]?
            if let lengths = try group.doubles("Lattice Dimensions"), let angles = try group.doubles("Lattice Angles"),
               lengths.count >= 3, angles.count >= 3 {
                lattice = Array(lengths.prefix(3)) + angles.prefix(3).map { oxfordDegrees($0) }
            }
            entries.append((id, CrystalPhase(name: phaseName, spaceGroup: spaceGroup, pointGroup: pointGroup, lattice: lattice)))
        }
        entries.sort { $0.id < $1.id }
        return PhaseList(ids: entries.map(\.id), phases: entries.map(\.phase), assignColors: true)
    }

    /// The Hermann-Mauguin spellings without the bar that a `Symbol` may carry, by orix's names.
    static let oxfordLaueAliases = ["m3m": "m-3m", "m3": "m-3"]

    /// The `Symbol` attribute of a phase's `Laue Group` dataset, trimmed; nil when there is none or it is not text.
    static func oxfordLaueSymbol(_ group: H5Group) -> String? {
        guard let datasetName = group.name(for: "Laue Group"),
              let value = try? group.file.reader.attribute("Symbol", of: group.path + "/" + datasetName) else { return nil }
        let text: String?
        switch value {
        case .text(let one): text = one
        case .texts(let many): text = many.first
        default: text = nil
        }
        return text?.trimmingCharacters(in: CharacterSet(charactersIn: "\0").union(.whitespaces))
    }

    /// A lattice angle stored in float32 radians, in degrees: exactly 90 or 120 where it is within one float32 step of 90° or 120°
    /// (MTEX snaps them within 1e-7 rad), so a cubic or hexagonal cell keeps its right angles.
    static func oxfordDegrees(_ radians: Double) -> Double {
        for (degrees, target) in [(90.0, Double.pi / 2), (120.0, 2 * Double.pi / 3)]
        where abs(radians - target) <= Double(Float(target).ulp) { return degrees }
        return radians * 180 / Double.pi
    }

    /// The grid cell (row-major index) of each stored point from its `x` and `y` (µm), as DREAM3D's EbsdLib places an H5OINA's points:
    /// cells counted from the smallest x and y in steps of `dx` and `dy`, rounded to the nearest. nil where the positions do not fill
    /// the `columns` x `rows` grid exactly once (a point off the grid, two on one cell, not finite) or where they already are the stored
    /// order; the points then stay in the order they are stored in, which is the map's row by row (the H5OINA layout, as MTEX reads it).
    package static func oxfordGridOrder(x: [Double], y: [Double], columns: Int, rows: Int, dx: Double, dy: Double) -> [Int]? {
        let n = x.count
        guard n == y.count, let cells = ReaderNumber.product([rows, columns]), cells == n, n > 0,
              dx.isFinite, dx > 0, rows == 1 || (dy.isFinite && dy > 0),
              x.allSatisfy(\.isFinite), y.allSatisfy(\.isFinite), let xMin = x.min(), let yMin = y.min() else { return nil }
        var cellOf = [Int](repeating: 0, count: n)
        var taken = [Bool](repeating: false, count: n)
        var identity = true
        for i in 0..<n {
            guard let column = ReaderNumber.int(((x[i] - xMin) / dx).rounded()),
                  let row = rows == 1 ? 0 : ReaderNumber.int(((y[i] - yMin) / dy).rounded()),
                  (0..<columns).contains(column), (0..<rows).contains(row) else { return nil }
            let cell = row * columns + column
            guard !taken[cell] else { return nil }
            taken[cell] = true
            cellOf[i] = cell
            if cell != i { identity = false }
        }
        return identity ? nil : cellOf
    }
}
