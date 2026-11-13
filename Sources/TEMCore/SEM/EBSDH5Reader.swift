//
//  EBSDH5Reader.swift
//  Role: the h5ebsd family of EBSD pattern files (Jackson et al. 2014) in the four layouts kikuchipy 0.13.1 reads, over FormatoKit's
//        HDF5 layer: kikuchipy's own, Bruker Nano (Esprit), EDAX TSL (OIM Analysis) and Oxford Instruments H5OINA (AZtec). Each
//        `read` is a port of the matching `scan2dict` in `kikuchipy/io/plugins/<layout>/_api.py` (GPL-3.0-or-later): the same
//        header keys, the same defaults, the same projection-centre conversion to the Bruker convention, the same refusals (hex
//        grids, non-rectangular regions). The patterns themselves stay in the file and are read by map position (`EBSDPatternReader`).
//        Parity: macTEMTests/EBSDH5ReaderTests.swift against ebsd-h5ebsd.truth.json (tools/parity/sem-readers/make_h5ebsd_fixtures.py).
//        `content` says which room a file is for: the patterns for the Patterns room; a map without patterns (AZtec's H5OINA map
//        export, #513; orix's own HDF5 file, #514) for the Maps room, read by `readMap`; a file of a known maker that holds neither
//        (an EDS-only H5OINA; a Bruker or EDAX file saved without patterns, whose maps are not read yet) refused in a sentence.
//        Every refusal names the file in words a user reads (`EBSDReadError.wrap`): no HDF5 paths, no quoted dataset names.
//

import Foundation
import FormatoCore
import FormatoHDF5

package nonisolated enum EBSDH5Reader {
    /// The layouts kikuchipy's `H5EBSDReader.supported_manufacturers` names, by the lowercased `manufacturer` of the top group.
    package static func format(ofManufacturer manufacturer: String) -> EBSDFileFormat? {
        switch manufacturer.lowercased() {
        case "kikuchipy": return .kikuchipyH5EBSD
        case "bruker nano": return .brukerH5EBSD
        case "edax": return .edaxH5EBSD
        case "oxford instruments": return .oxfordH5OINA
        default: return nil
        }
    }

    /// What the top group says the file is: the layout, or nil when the file is not an h5ebsd file of a known manufacturer
    /// (no `manufacturer` and `version` datasets, or no scan group with `EBSD/Data` and `EBSD/Header`). One HDF5 open; run off the main actor.
    package static func sniff(url: URL) -> EBSDFileFormat? {
        guard let reader = try? HDF5Reader(url: url), let top = try? TopGroup(reader), !top.scanGroups.isEmpty else { return nil }
        return format(ofManufacturer: top.manufacturer)
    }

    /// What an EBSD HDF5 file holds, and so which room opens it.
    package enum Content: Equatable, Sendable {
        /// Patterns in this layout: the Patterns room (`read`).
        case patterns(EBSDFileFormat)
        /// An orientation map without patterns: the Maps room (`readMap`).
        case map(MapLayout)
        /// A file of a maker the readers know that macEM does not open, and the sentence that says what it holds.
        case refused(String)
    }

    /// The layouts of an orientation map without patterns that `readMap` reads.
    package enum MapLayout: Equatable, Sendable {
        /// AZtec's map export: an H5OINA scan without patterns (#513, EBSDH5Reader+OxfordMap.swift).
        case oxford
        /// orix's own HDF5 file (`orix.io.save`, orix 0.15.0's io/plugins/orix_hdf5.py): `manufacturer` orix and a `crystal_map`
        /// group; kikuchipy's dictionary indexing saves its maps so.
        case orix
    }

    /// Which room the HDF5 file at `url` is for, from its top group and the names in its first scan's `EBSD/Data` (one HDF5 open;
    /// run off the main actor): nil when it is no EBSD file of a maker the readers know (no `manufacturer` and `version`, or
    /// another maker), so the file's other routes decide.
    package static func content(url: URL) -> Content? {
        guard let reader = try? HDF5Reader(url: url), let top = try? TopGroup(reader) else { return nil }
        let name = url.lastPathComponent
        if top.manufacturer == "orix" { return (try? reader.kind(of: "/crystal_map")) == .group ? .map(.orix) : nil }
        guard let format = format(ofManufacturer: top.manufacturer) else { return nil }
        guard let scan = top.scanGroups.first else {
            if format == .oxfordH5OINA, top.holdsEDS {
                return .refused("\(name) holds EDS data from AZtec but no EBSD data. macEM does not read EDS from an .h5oina file yet; "
                                + "a spectrum AZtec exports as .msa opens in the EDS room.")
            }
            return .refused("\(name) holds no EBSD patterns and no orientation map.")
        }
        guard let data = try? H5Group(H5File(reader: reader, url: url), "/\(scan)/EBSD/Data") else { return .patterns(format) }
        switch format {
        case .oxfordH5OINA:
            return holdsOxfordPatterns(data) ? .patterns(format) : .map(.oxford)
        case .brukerH5EBSD where data.name(for: "RawPatterns") == nil:
            return .refused("\(name) is a Bruker Esprit file saved without its EBSD patterns. macEM does not read its orientation map "
                            + "yet; the map exported as .ang or .ctf opens in the Maps room.")
        case .edaxH5EBSD where data.name(for: "Pattern") == nil:
            return .refused("\(name) is an EDAX OIM file saved without its EBSD patterns. macEM does not read its orientation map yet; "
                            + "the map exported as .ang opens in the Maps room.")
        default:
            return .patterns(format)
        }
    }

    /// The orientation map of the HDF5 file at `url` that `content` gives the Maps room, and its layout. Reads the whole map; run it
    /// off the main actor, inside the file's security scope. Any other file is refused in its sentence.
    package static func readMap(url: URL) throws -> (map: CrystalMap, layout: MapLayout) {
        let name = url.lastPathComponent
        switch content(url: url) {
        case .map(.oxford):
            let map = try readOxfordMap(url: url)
            return (map, .oxford)
        case .map(.orix):
            let map = try readOrixMap(url: url)
            return (map, .orix)
        case .refused(let sentence): throw EBSDReadError(text: sentence)
        case .patterns: throw EBSDReadError(text: "\(name) holds EBSD patterns: it opens in the Patterns room, which shows its map.")
        case nil: throw EBSDReadError(text: "\(name) is not an orientation map macEM reads (.ang, .ctf, .h5oina or orix's .h5).")
        }
    }

    /// The crystal map of orix's own HDF5 file at `url` (`orix.io.load`, `dict2crystalmap`): the map as `readCrystalMap` reads a
    /// kikuchipy file's, at `/crystal_map`.
    package static func readOrixMap(url: URL) throws -> CrystalMap {
        do {
            let reader = try HDF5Reader(url: url)
            guard (try? reader.kind(of: "/crystal_map")) == .group else {
                throw EBSDReadError(text: "\(url.lastPathComponent) holds no orientation map: orix saves one as its crystal map.")
            }
            return try readCrystalMap(H5File(reader: reader, url: url), path: "/crystal_map", scan: nil, steps: (dy: 1, dx: 1))
        } catch { throw EBSDReadError.wrap(error, file: url) }
    }

    /// The scan `scanGroup` (the first scan group when nil) of the h5ebsd file at `url`.
    package static func read(url: URL, scanGroup: String? = nil) throws -> EBSDDataset {
        do {
            let reader = try HDF5Reader(url: url)
            let top = try TopGroup(reader)
            guard let format = format(ofManufacturer: top.manufacturer) else {
                throw EBSDReadError(text: "\(url.lastPathComponent) is an EBSD file written by \(top.manufacturer), which macEM does not read; it reads kikuchipy, Bruker Esprit, EDAX OIM and Oxford AZtec files.")
            }
            guard !top.scanGroups.isEmpty else {
                throw EBSDReadError(text: "\(url.lastPathComponent) holds no EBSD scan.")
            }
            let group: String
            if let scanGroup {
                guard top.scanGroups.contains(scanGroup) else {
                    throw EBSDReadError(text: "\(url.lastPathComponent) has no scan named \(scanGroup); its scans are \(top.scanGroups.joined(separator: ", ")).")
                }
                group = scanGroup
            } else { group = top.scanGroups[0] }
            let file = H5File(reader: reader, url: url)
            var dataset: EBSDDataset
            switch format {
            case .kikuchipyH5EBSD: dataset = try readKikuchipy(file, scan: group)
            case .brukerH5EBSD: dataset = try readBruker(file, scan: group)
            case .edaxH5EBSD: dataset = try readEDAX(file, scan: group)
            case .oxfordH5OINA: dataset = try readOxford(file, scan: group, version: top.version)
            case .generated, .oxfordBinary, .edaxBinary, .nordif: throw EBSDReadError(text: "\(url.lastPathComponent) is not an h5ebsd file.")
            }
            dataset.manufacturer = top.manufacturer; dataset.version = top.version; dataset.scanGroups = top.scanGroups
            return dataset
        } catch { throw EBSDReadError.wrap(error, file: url) }
    }

    // MARK: - The top group

    /// `manufacturer` and `version` (lowercased, as kikuchipy keeps them; EDAX writes the names with a leading space, stripped like `_hdf5group2dict` does) and the scan groups: every top group that holds `EBSD/Data` and
    /// `EBSD/Header` (`H5EBSDReader.get_manufacturer_version`, `get_scan_groups`, `check_file`). `holdsEDS`: a top group holds an
    /// `EDS` group (an H5OINA scan's EDS data, H5OINAFile.md).
    struct TopGroup {
        var manufacturer: String
        var version: String
        var scanGroups: [String]
        var holdsEDS = false

        init(_ reader: HDF5Reader) throws {
            var manufacturer: String?, version: String?
            var groups: [String] = [], eds = false
            for name in try reader.children(of: "/") {
                switch try reader.kind(of: "/" + name) {
                case .dataset:
                    let key = name.lowercased().trimmingCharacters(in: .whitespaces)
                    if key == "manufacturer" { manufacturer = try reader.readStrings("/" + name).first?.lowercased() }
                    else if key == "version" || key == "format version" { version = try reader.readStrings("/" + name).first?.lowercased() }
                case .group:
                    if try reader.exists("/\(name)/EBSD/Data"), try reader.exists("/\(name)/EBSD/Header") { groups.append(name) }
                    if try reader.exists("/\(name)/EDS") { eds = true }
                case .other: continue
                }
            }
            guard let manufacturer else { throw EBSDReadError(text: "it is not an EBSD file (it does not name the software that wrote it).") }
            guard let version else { throw EBSDReadError(text: "it is not an EBSD file (it does not give its format version).") }
            self.manufacturer = manufacturer; self.version = version; self.scanGroups = groups; self.holdsEDS = eds
        }
    }

    // MARK: - A group's datasets as kikuchipy's `_hdf5group2dict` reads them

    struct H5File {
        var reader: HDF5Reader
        var url: URL
    }

    /// The datasets of one group, looked up by name as `_hdf5group2dict` fills its dictionary: a one-element array is the element,
    /// a byte string is text, a name with leading whitespace (EDAX) is stripped.
    struct H5Group {
        let file: H5File
        let path: String
        let names: [String]

        init(_ file: H5File, _ path: String) throws {
            self.file = file; self.path = path
            names = try file.reader.exists(path) ? file.reader.children(of: path) : []
        }

        func name(for key: String) -> String? {
            if names.contains(key) { return key }
            return names.first { $0.drop(while: { $0 == " " }) == key }
        }

        func kind(_ key: String) -> HDF5ObjectKind? {
            guard let name = name(for: key) else { return nil }
            return try? file.reader.kind(of: path + "/" + name)
        }

        func subgroup(_ key: String) throws -> H5Group? {
            guard let name = name(for: key), kind(key) == .group else { return nil }
            return try H5Group(file, path + "/" + name)
        }

        /// Every value of a numeric dataset, in C order; nil when absent or not numeric.
        func doubles(_ key: String) throws -> [Double]? {
            guard let name = name(for: key), kind(key) == .dataset else { return nil }
            let full = path + "/" + name
            guard case .numeric = try file.reader.datasetInfo(full).type else { return nil }
            return try file.reader.readDataset(full).doubles()
        }

        func array(_ key: String) throws -> FormatoArray? {
            guard let name = name(for: key), kind(key) == .dataset else { return nil }
            let full = path + "/" + name
            guard case .numeric = try file.reader.datasetInfo(full).type else { return nil }
            return try file.reader.readDataset(full)
        }

        func info(_ key: String) throws -> HDF5DatasetInfo? {
            guard let name = name(for: key), kind(key) == .dataset else { return nil }
            return try file.reader.datasetInfo(path + "/" + name)
        }

        /// A scalar (a one-element dataset, or the first element: kikuchipy's `.get(key, default)` yields a scalar for `(1,)` datasets).
        func double(_ key: String) throws -> Double? { try doubles(key)?.first }

        func int(_ key: String) throws -> Int? {
            guard let value = try double(key) else { return nil }
            return try EBSDH5Reader.wholeNumber(value, "the \(key) its \(place) gives")
        }

        /// Where the group sits, in words: its EBSD header or data, its SEM header, a crystal map's (no HDF5 path).
        var place: String {
            let last = path.split(separator: "/").last.map(String.init) ?? ""
            switch last {
            case "Header": return path.contains("/SEM") ? "SEM header" : "EBSD header"
            case "Data": return "EBSD data"
            case "SEM": return "SEM header"
            case "header": return "crystal map's header"
            case "data": return "crystal map"
            default: return "file"
            }
        }

        func string(_ key: String) throws -> String? {
            guard let name = name(for: key), kind(key) == .dataset else { return nil }
            let full = path + "/" + name
            guard case .string = try file.reader.datasetInfo(full).type else { return nil }
            return try file.reader.readStrings(full).first
        }

        func required(_ key: String) throws -> Double {
            guard let value = try double(key) else { throw EBSDReadError(text: "its \(place) does not give the \(key).") }
            return value
        }

        func requiredInt(_ key: String) throws -> Int { try EBSDH5Reader.wholeNumber(try required(key), "the \(key) its \(place) gives") }
    }

    // MARK: - Shared pieces

    /// `value`, a count or index the file stores as a float, as Python's `int()` makes it (`ReaderNumber.int`); refused in words where
    /// Swift's `Int(_:)` would trap (NaN, infinity, beyond Int's range). `what` names it for the sentence.
    package static func wholeNumber(_ value: Double, _ what: String) throws -> Int {
        guard let number = ReaderNumber.int(value) else { throw EBSDReadError(text: "\(what) is \(value), not a whole number in range.") }
        return number
    }

    /// The pattern dataset's shape and type checked against the scan: (n, sy, sx) or (ny, nx, sy, sx), with sy and sx the header's
    /// (`H5EBSDReader.get_data`; a shorter dataset is zero-padded there and here, a longer one is read up to the scan). The scan and
    /// the dataset are sized here, before any reader multiplies by them: at least one row and column each, and their bytes countable.
    static func patternSource(_ file: H5File, data: H5Group, name: String, scanRows: Int, scanColumns: Int, rows: Int, columns: Int,
                              order: [Int?]? = nil) throws -> EBSDPatternSource {
        guard let datasetName = data.name(for: name), let info = try data.info(name) else {
            throw EBSDReadError(text: "it holds no EBSD patterns.")
        }
        guard case .numeric(let type) = info.type else {
            throw EBSDReadError(text: "its EBSD patterns are not stored as numbers.")
        }
        let shape = info.shape
        let patternShape = Array(shape.suffix(2))
        guard shape.count == 3 || shape.count == 4, patternShape == [rows, columns] else {
            // Sizes width × height (columns × rows), as the toolbar and Info give them (D-SEM-112).
            let stored = shape.count >= 2 ? "patterns of \(shape[shape.count - 1]) × \(shape[shape.count - 2]) pixels" : "no patterns of two sides"
            throw EBSDReadError(text: "it stores \(stored), but its header gives \(columns) × \(rows) patterns in a \(scanColumns) × \(scanRows) scan.")
        }
        if let refusal = EBSDDataset.sizeRefusal(scanRows: scanRows, scanColumns: scanColumns, patternRows: rows, patternColumns: columns,
                                                 byteSize: type.byteSize) {
            throw EBSDReadError(text: "\(file.url.lastPathComponent): \(refusal)")
        }
        guard ReaderNumber.product(shape + [type.byteSize]) != nil else {
            throw EBSDReadError(text: "its EBSD patterns are more bytes than can be counted.")
        }
        return EBSDPatternSource(url: file.url, datasetPath: data.path + "/" + datasetName, fileShape: shape, dataType: type, fileIndexByPosition: order)
    }

    /// Per-pattern centres (one array per component, each `n` long) as a list of `n` centres; a single value as one centre;
    /// a mismatch with the scan padded with 0.5 (kikuchipy's warning path).
    static func centers(x: [Double]?, y: [Double]?, z: [Double]?, scanCount: Int) -> [SIMD3<Double>] {
        let xs = x ?? [0.5], ys = y ?? [0.5], zs = z ?? [0.5]
        let n = max(xs.count, ys.count, zs.count)
        if n <= 1 { return [SIMD3(xs.first ?? 0.5, ys.first ?? 0.5, zs.first ?? 0.5)] }
        func at(_ values: [Double], _ i: Int) -> Double { values.count == 1 ? values[0] : (i < values.count ? values[i] : 0.5) }
        let count = n >= scanCount ? n : scanCount
        return (0..<count).map { SIMD3(at(xs, $0), at(ys, $0), at(zs, $0)) }
    }

    // MARK: - kikuchipy

    static func readKikuchipy(_ file: H5File, scan: String) throws -> EBSDDataset {
        let header = try H5Group(file, "/\(scan)/EBSD/Header")
        let data = try H5Group(file, "/\(scan)/EBSD/Data")
        let ny = try header.requiredInt("n_rows")
        let nx = try header.requiredInt("n_columns")
        let sy = try header.requiredInt("pattern_height")
        let sx = try header.requiredInt("pattern_width")
        let dy = try header.double("step_y") ?? 1
        let dx = try header.double("step_x") ?? 1
        let pxSize = try header.double("detector_pixel_size") ?? 1
        let source = try patternSource(file, data: data, name: "patterns", scanRows: ny, scanColumns: nx, rows: sy, columns: sx)
        let pcx = try header.doubles("pcx")
        let pcy = try header.doubles("pcy")
        let pcz = try header.doubles("pcz")
        let pc = centers(x: pcx, y: pcy, z: pcz, scanCount: ny * nx)
        let binning = try header.int("binning") ?? 1
        let tilt = try header.double("elevation_angle") ?? 0
        let azimuthal = try header.double("azimuth_angle") ?? 0
        let twist = try header.double("twist_angle") ?? 0
        let sampleTilt = try header.double("sample_tilt") ?? 70
        let detector = EBSDDetectorGeometry(rows: sy, columns: sx, pixelSize: pxSize, binning: binning, tilt: tilt, azimuthal: azimuthal,
                                            twist: twist, sampleTilt: sampleTilt, projectionCenters: pc)
        let semGroup = try H5Group(file, "/\(scan)/SEM/Header")
        let beam = try semGroup.double("beam_energy")
        let magnification = try semGroup.double("magnification")
        let wd = try semGroup.double("working_distance")
        let microscope = try semGroup.string("microscope")
        let sem = EBSDSEMHeader(beamEnergyKeV: beam, magnification: magnification, workingDistanceMM: wd, microscope: microscope)
        var crystalMap: CrystalMap?
        if try file.reader.exists("/\(scan)/EBSD/CrystalMap/crystal_map") {
            crystalMap = try readCrystalMap(file, path: "/\(scan)/EBSD/CrystalMap/crystal_map", scan: (rows: ny, columns: nx), steps: (dy: dy, dx: dx))
        }
        let background = try header.array("static_background")
        return EBSDDataset(format: .kikuchipyH5EBSD, manufacturer: "", version: "", scanGroup: scan, scanGroups: [], scanRows: ny, scanColumns: nx,
                           patternRows: sy, patternColumns: sx, dataType: source.dataType, stepY: dy, stepX: dx, detector: detector,
                           staticBackground: background, sem: sem, crystalMap: crystalMap, patterns: source)
    }

    /// orix's `dict2crystalmap`: Euler angles, phase ids, the phases of the header by id, every other column as a property, the
    /// points `is_in_data` keeps, x and y from the file or, where it writes none, from the scan grid (orix's
    /// `create_coordinate_arrays` with the scan's steps; `scan` nil leaves them to `CrystalMap`, x = 0, 1, 2, … as orix does).
    /// A map of several rotations a point (`rotations_per_point`, kikuchipy's best matches) keeps the first of each, the one orix's
    /// `CrystalMap.orientations` shows, and of each property with as many columns its first.
    static func readCrystalMap(_ file: H5File, path: String, scan: (rows: Int, columns: Int)?, steps: (dy: Double, dx: Double)) throws -> CrystalMap {
        let data = try H5Group(file, path + "/data")
        let header = try H5Group(file, path + "/header")
        /// A column of one value a point; of a 2-D (points, k) dataset the first of each row.
        func perPoint(_ key: String) throws -> [Double]? {
            guard let values = try data.doubles(key), let shape = try data.info(key)?.shape else { return nil }
            guard shape.count == 2, shape[1] > 1 else { return values }
            return stride(from: 0, to: values.count, by: shape[1]).map { values[$0] }
        }
        let phi1 = try perPoint("phi1")
        let Phi = try perPoint("Phi")
        let phi2 = try perPoint("phi2")
        guard let phi1, let Phi, let phi2 else {
            throw EBSDReadError(text: "its crystal map holds no orientations (no Euler angles).")
        }
        let n = min(phi1.count, Phi.count, phi2.count)
        let euler = (0..<n).map { SIMD3(phi1[$0], Phi[$0], phi2[$0]) }
        let phaseColumn = try data.doubles("phase_id") ?? [Double](repeating: 0, count: n)
        let phaseIDs = try phaseColumn.map { try wholeNumber($0, "a phase id of the crystal map") }
        var phases: [(id: Int, phase: CrystalPhase)] = []
        if let list = try header.subgroup("phases") {
            for id in list.names.sorted(by: { (Int($0) ?? 0) < (Int($1) ?? 0) }) {
                guard let phase = try list.subgroup(id) else { continue }
                var lattice: [Double]?
                if let structure = try phase.subgroup("structure"), let latticeGroup = try structure.subgroup("lattice") {
                    lattice = try latticeGroup.doubles("abcABG")
                }
                let name = try phase.string("name") ?? ""
                let spaceGroup = try phase.int("space_group")
                // orix writes a phase without a point or space group as the text "None" (`dict2phase`).
                let pointGroup = try phase.string("point_group").flatMap { $0 == "None" ? nil : $0 }
                let color = try phase.string("color") ?? PhaseList.tableau[phases.count % PhaseList.tableau.count]
                phases.append((Int(id) ?? phases.count, CrystalPhase(name: name, spaceGroup: spaceGroup, pointGroup: pointGroup, lattice: lattice, color: color)))
            }
        }
        var properties: [String: [Double]] = [:]
        let standard: Set<String> = ["phi1", "Phi", "phi2", "phase_id", "is_in_data", "id", "x", "y", "z"]
        for name in data.names where !standard.contains(name) {
            if let values = try perPoint(name), values.count == n { properties[name] = values }
        }
        var x = try data.doubles("x").flatMap { $0.count == n ? $0 : nil }
        var y = try data.doubles("y").flatMap { $0.count == n ? $0 : nil }
        if x == nil, y == nil, let scan, scan.rows * scan.columns == n {
            let grid = CrystalMap.coordinates(shape: scan, steps: steps)
            x = grid.x
            y = scan.rows > 1 ? grid.y : nil
        }
        // orix's `dict2crystalmap` takes the map's length unit from `header/scan_unit` ("um" in kikuchipy's files, NUL-padded); its
        // default "px" stands only when the header has none. Without it a µm map drew its scale bar and grain sizes in px.
        let unit = try header.string("scan_unit")?.trimmingCharacters(in: CharacterSet(charactersIn: "\0").union(.whitespaces))
        // orix keeps every point of the map it was cut from and hides the others (`is_in_data`, h5py's bool); a mask of another
        // length, or none, keeps them all.
        var inData: [Bool]?
        if data.kind("is_in_data") == .dataset, let name = data.name(for: "is_in_data") {
            let full = data.path + "/" + name
            let mask = (try? file.reader.readBooleans(full)) ?? (try? data.doubles("is_in_data"))?.map { $0 != 0 }
            if let mask, mask.count == n { inData = mask }
        }
        return try CrystalMap(euler: euler, phaseIDs: Array(phaseIDs.prefix(n)), x: x, y: y, phaseList: phases.isEmpty ? nil : PhaseList(phases),
                              properties: properties, scanUnit: unit.flatMap { $0.isEmpty ? nil : $0 } ?? "px", isInData: inData)
    }

    /// The sentence for a scan on a grid other than a square one (kikuchipy reads square grids only).
    static func gridRefusal(_ grid: String?) -> String {
        guard let grid, !grid.isEmpty else { return "it does not say which grid it was acquired on; only square-grid EBSD maps are read." }
        return "it was acquired on a \(grid.lowercased().contains("hex") ? "hexagonal" : grid) grid; only square-grid EBSD maps are read."
    }

    // MARK: - Bruker Nano

    static func readBruker(_ file: H5File, scan: String) throws -> EBSDDataset {
        let header = try H5Group(file, "/\(scan)/EBSD/Header")
        let data = try H5Group(file, "/\(scan)/EBSD/Data")
        let grid = try header.string("Grid Type")
        guard grid == "isometric" else { throw EBSDReadError(text: Self.gridRefusal(grid)) }
        var ny: Int
        var nx: Int
        var order: [Int?]?
        let semGroup = try H5Group(file, "/\(scan)/EBSD/SEM")
        let iy = try semGroup.doubles("IY")
        let ix = try semGroup.doubles("IX")
        if let iy, let ix {
            let rows = try iy.map { try wholeNumber($0, "an 'IY' of the region of interest") }
            let columns = try ix.map { try wholeNumber($0, "an 'IX' of the region of interest") }
            guard let roi = rectangularROI(rows: rows, columns: columns) else {
                throw EBSDReadError(text: "its region of interest is not a rectangle; only rectangular regions are read.")
            }
            ny = roi.rows; nx = roi.columns; order = roi.fileIndexByPosition
        } else {
            ny = try header.requiredInt("NROWS")
            nx = try header.requiredInt("NCOLS")
        }
        let sy = try header.requiredInt("PatternHeight")
        let sx = try header.requiredInt("PatternWidth")
        let dy = try header.required("YSTEP")
        let dx = try header.required("XSTEP")
        let statedFullHeight = try header.double("DetectorFullHeightMicrons")
        let statedUnclippedHeight = try header.double("UnClippedPatternHeight")
        let pxSize = (statedFullHeight ?? 1) / (statedUnclippedHeight ?? 1)
        let source = try patternSource(file, data: data, name: "RawPatterns", scanRows: ny, scanColumns: nx, rows: sy, columns: sx, order: order)
        // PCs stay in file order for a region of interest, as kikuchipy 0.13.1 leaves them (docs/parity.md).
        let pcx = try data.doubles("PCX")
        let pcy = try data.doubles("PCY")
        let dd = try data.doubles("DD")
        let pc = centers(x: pcx, y: pcy, z: dd, scanCount: ny * nx)
        let tilt = try header.double("CameraTilt") ?? 0
        // kikuchipy reads 'Sample Tilt' (with the space) and so takes 0 where Esprit writes 'SampleTilt'; matched (docs/parity.md).
        let statedSampleTilt = try header.double("Sample Tilt")
        var detector = EBSDDetectorGeometry(rows: sy, columns: sx, pixelSize: pxSize, binning: 1, tilt: tilt, azimuthal: 0, twist: 0,
                                            sampleTilt: statedSampleTilt ?? 0, projectionCenters: pc)
        if statedFullHeight == nil || statedUnclippedHeight == nil { detector.assumed.insert(.pixelSize) }
        if pcx == nil || pcy == nil || dd == nil { detector.assumed.insert(.projectionCenter) }
        if statedSampleTilt == nil { detector.assumed.insert(.sampleTilt) }
        let kv = try header.double("KV")
        let magnification = try header.double("Magnification")
        let wd = try header.double("WD")
        let sem = EBSDSEMHeader(beamEnergyKeV: kv, magnification: magnification, workingDistanceMM: wd)
        let background = try header.array("StaticBackground")
        return EBSDDataset(format: .brukerH5EBSD, manufacturer: "", version: "", scanGroup: scan, scanGroups: [], scanRows: ny, scanColumns: nx,
                           patternRows: sy, patternColumns: sx, dataType: source.dataType, stepY: dy, stepX: dx, detector: detector,
                           staticBackground: background, sem: sem, patterns: source)
    }

    /// `_bruker_roi_is_rectangular` and the index map of `get_data`: the region's rows and columns when every row and column index of
    /// the region is used the same number of times with no gap, and for each map position (row-major in the region) the file index
    /// of its pattern (`np.ravel_multi_index(...).argsort()`).
    package static func rectangularROI(rows: [Int], columns: [Int]) -> (rows: Int, columns: Int, fileIndexByPosition: [Int?])? {
        guard !rows.isEmpty, rows.count == columns.count, let minRow = rows.min(), let maxRow = rows.max(),
              let minColumn = columns.min(), let maxColumn = columns.max() else { return nil }
        func contiguousEvenCounts(_ values: [Int]) -> Bool {
            var counts: [Int: Int] = [:]
            for v in values { counts[v, default: 0] += 1 }
            let keys = counts.keys.sorted()
            // The keys ascend, so `$0 + 1` cannot overflow where `$1 - $0` of two far-apart indices would.
            guard zip(keys, keys.dropFirst()).allSatisfy({ $1 == $0 + 1 }) else { return false }
            return Set(counts.values).count == 1
        }
        guard contiguousEvenCounts(rows), contiguousEvenCounts(columns) else { return nil }
        let ny = maxRow - minRow + 1
        let nx = maxColumn - minColumn + 1
        let ravelled = (0..<rows.count).map { (rows[$0] - minRow) * nx + (columns[$0] - minColumn) }
        let argsort = ravelled.indices.sorted { ravelled[$0] < ravelled[$1] }
        var order = [Int?](repeating: nil, count: ny * nx)
        for (position, fileIndex) in argsort.enumerated() where position < order.count { order[position] = fileIndex }
        return (ny, nx, order)
    }

    // MARK: - EDAX TSL

    static func readEDAX(_ file: H5File, scan: String) throws -> EBSDDataset {
        let header = try H5Group(file, "/\(scan)/EBSD/Header")
        let data = try H5Group(file, "/\(scan)/EBSD/Data")
        let grid = try header.string("Grid Type")
        guard grid == "SqrGrid" else { throw EBSDReadError(text: Self.gridRefusal(grid)) }
        let ny = try header.requiredInt("nRows")
        let nx = try header.requiredInt("nColumns")
        let sy = try header.requiredInt("Pattern Height")
        let sx = try header.requiredInt("Pattern Width")
        let dy = try header.double("Step Y") ?? 1
        let dx = try header.double("Step X") ?? 1
        let source = try patternSource(file, data: data, name: "Pattern", scanRows: ny, scanColumns: nx, rows: sy, columns: sx)
        var pc = SIMD3(0.5, 0.5, 0.5)
        var pcStated = false
        if let calibration = try header.subgroup("Pattern Center Calibration") {
            let x = try calibration.double("x-star"), y = try calibration.double("y-star"), z = try calibration.double("z-star")
            pc = SIMD3(x ?? 0.5, y ?? 0.5, z ?? 0.5)
            pcStated = x != nil && y != nil && z != nil
        }
        let tilt = try header.double("Camera Elevation Angle") ?? 0
        let azimuthal = try header.double("Camera Azimuthal Angle") ?? 0
        let statedSampleTilt = try header.double("Sample Tilt")
        var detector = EBSDDetectorGeometry(rows: sy, columns: sx, pixelSize: 1, binning: 1, tilt: tilt, azimuthal: azimuthal, twist: 0,
                                            sampleTilt: statedSampleTilt ?? 70, projectionCenters: [])
        detector.projectionCenters = [detector.brukerCenter(pc, from: .tsl)]
        detector.assumed = [.pixelSize]
        if !pcStated { detector.assumed.insert(.projectionCenter) }
        if statedSampleTilt == nil { detector.assumed.insert(.sampleTilt) }
        let prias = try H5Group(file, "/\(scan)/SEM-PRIAS Images/Header")
        let magnification = try prias.double("Mag")
        let wd = try header.double("Working Distance")
        let sem = EBSDSEMHeader(magnification: magnification, workingDistanceMM: wd)
        return EBSDDataset(format: .edaxH5EBSD, manufacturer: "", version: "", scanGroup: scan, scanGroups: [], scanRows: ny, scanColumns: nx,
                           patternRows: sy, patternColumns: sx, dataType: source.dataType, stepY: dy, stepX: dx, detector: detector, sem: sem,
                           patterns: source)
    }

    // MARK: - Oxford Instruments H5OINA

    /// kikuchipy's `OxfordH5EBSDReader.scan2dict`: the processed patterns, or with `processed` false the unprocessed ones. A scan that
    /// holds only the other kind reads that one (kikuchipy refuses it with a KeyError; AZtec can save either alone, #514). The map
    /// the scan holds beside its patterns comes with them (`readOxfordMap`, which kikuchipy 0.13.1 leaves empty) when it reads; a
    /// map that does not never keeps the patterns from opening.
    static func readOxford(_ file: H5File, scan: String, version: String, processed: Bool = true) throws -> EBSDDataset {
        let header = try H5Group(file, "/\(scan)/EBSD/Header")
        let data = try H5Group(file, "/\(scan)/EBSD/Data")
        // A map exported without its patterns (#513) is the Maps room's: said in words, not as the 'Pattern Height' it lacks.
        guard holdsOxfordPatterns(data) else {
            throw EBSDReadError(text: "\(file.url.lastPathComponent) holds an orientation map but no EBSD patterns: it opens in the Maps room.")
        }
        let ny = try header.requiredInt("Y Cells")
        let nx = try header.requiredInt("X Cells")
        let sy = try header.requiredInt("Pattern Height")
        let sx = try header.requiredInt("Pattern Width")
        let dy = try header.double("Y Step") ?? 1
        let dx = try header.double("X Step") ?? 1
        let asked = processed ? "Processed Patterns" : "Unprocessed Patterns"
        let name = data.name(for: asked) != nil ? asked : oxfordPatternNames.first { data.name(for: $0) != nil } ?? asked
        let source = try patternSource(file, data: data, name: name, scanRows: ny, scanColumns: nx, rows: sy, columns: sx)
        var detector = EBSDDetectorGeometry(rows: sy, columns: sx, pixelSize: 1, binning: 1, tilt: 0, azimuthal: 0, twist: 0, sampleTilt: 70,
                                            projectionCenters: [])
        // H5OINA stores the angles as float32 and kikuchipy converts them with `np.rad2deg`, which for float32 is `x * 180 / pi` in
        // float32; matched (docs/parity.md), so the degrees are the reference's to the last bit. numpy's float32 pi is pi rounded to
        // nearest (3.1415927); Swift's `Float.pi` is rounded toward zero (3.1415925) and lands one ulp away.
        let pi32 = Float(Double.pi)
        func degrees(_ radians: Double) -> Double { Double(Float(radians) * 180 / pi32) }
        detector.assumed = [.pixelSize, .sampleTilt]
        if let tiltAngle = try header.double("Tilt Angle") { detector.sampleTilt = degrees(tiltAngle); detector.assumed.remove(.sampleTilt) }
        if let euler = try header.doubles("Detector Orientation Euler"), euler.count > 1 { detector.tilt = Double(Float(degrees(euler[1])) - 90) }
        if let binning = try oxfordBinning(header: header, version: version) { detector.binning = binning }
        let pcx = try data.doubles("Pattern Center X")
        let pcy = try data.doubles("Pattern Center Y")
        let dd = try data.doubles("Detector Distance")
        let oxfordCenters = centers(x: pcx, y: pcy, z: dd, scanCount: ny * nx)
        detector.projectionCenters = oxfordCenters.map { detector.brukerCenter($0, from: .oxford) }
        if pcx == nil || pcy == nil || dd == nil { detector.assumed.insert(.projectionCenter) }
        let kv = try header.double("Beam Voltage")
        let magnification = try header.double("Magnification")
        let wd = try header.double("Working Distance")
        let sem = EBSDSEMHeader(beamEnergyKeV: kv, magnification: magnification, workingDistanceMM: wd)
        let background = try header.array("Processed Static Background")
        let map = try? readOxfordMap(file, scan: scan)
        return EBSDDataset(format: .oxfordH5OINA, manufacturer: "", version: "", scanGroup: scan, scanGroups: [], scanRows: ny, scanColumns: nx,
                           patternRows: sy, patternColumns: sx, dataType: source.dataType, stepY: dy, stepX: dx, detector: detector,
                           staticBackground: background, sem: sem, crystalMap: map, patterns: source)
    }

    /// kikuchipy's `get_binning`: the camera mode string `... (WxH px)`; 1024 over the height, 8 for the 88-row Speed 3 mode. The dataset is
    /// `Camera Mode` from H5OINA 7.0 and `Camera Binning Mode` before.
    static func oxfordBinning(header: H5Group, version: String) throws -> Int? {
        let major = Int(version.split(separator: ".").first ?? "") ?? 0
        let key = major >= 7 ? "Camera Mode" : "Camera Binning Mode"
        guard let mode = try header.string(key) else { return nil }
        return oxfordBinning(cameraMode: mode)
    }

    /// The binning a camera mode string `... (WxH px)` gives (`get_binning`); nil when it holds no such size, or a height of 0 or less,
    /// which gives no binning (1024 over 0 is no number of pixels).
    package static func oxfordBinning(cameraMode mode: String) -> Int? {
        guard let open = mode.lastIndex(of: "("), let close = mode[open...].firstIndex(of: ")") else { return nil }
        let inside = mode[mode.index(after: open)..<close]   // "60x60 px"
        guard inside.hasSuffix(" px") else { return nil }
        let dims = inside.dropLast(3).split(separator: "x")
        guard dims.count == 2, let height = Int(dims[1]), height > 0 else { return nil }
        return height == 88 ? 8 : Int((1024.0 / Double(height)).rounded())
    }
}
