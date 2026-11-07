//
//  EBSDH5Reader.swift
//  Role: the h5ebsd family of EBSD pattern files (Jackson et al. 2014) in the four layouts kikuchipy 0.13.1 reads, over FormatoKit's
//        HDF5 layer: kikuchipy's own, Bruker Nano (Esprit), EDAX TSL (OIM Analysis) and Oxford Instruments H5OINA (AZtec). Each
//        `read` is a port of the matching `scan2dict` in `kikuchipy/io/plugins/<layout>/_api.py` (GPL-3.0-or-later): the same
//        header keys, the same defaults, the same projection-centre conversion to the Bruker convention, the same refusals (hex
//        grids, non-rectangular regions). The patterns themselves stay in the file and are read by map position (`EBSDPatternReader`).
//        Parity: macTEMTests/EBSDH5ReaderTests.swift against ebsd-h5ebsd.truth.json (tools/parity/sem-readers/make_h5ebsd_fixtures.py).
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
        guard let reader = try? HDF5Reader(url: url), let top = try? TopGroup(reader) else { return nil }
        guard let format = format(ofManufacturer: top.manufacturer), !top.scanGroups.isEmpty else { return nil }
        return format
    }

    /// The scan `scanGroup` (the first scan group when nil) of the h5ebsd file at `url`.
    package static func read(url: URL, scanGroup: String? = nil) throws -> EBSDDataset {
        do {
            let reader = try HDF5Reader(url: url)
            let top = try TopGroup(reader)
            guard let format = format(ofManufacturer: top.manufacturer) else {
                throw EBSDReadError(text: "\(url.lastPathComponent) is an h5ebsd file of '\(top.manufacturer)', which is not among the supported manufacturers (kikuchipy, Bruker Nano, EDAX, Oxford Instruments).")
            }
            guard !top.scanGroups.isEmpty else {
                throw EBSDReadError(text: "\(url.lastPathComponent) has no top group with subgroups 'EBSD/Data' and 'EBSD/Header'.")
            }
            let group: String
            if let scanGroup {
                guard top.scanGroups.contains(scanGroup) else {
                    throw EBSDReadError(text: "Scan '\(scanGroup)' is not among the scans \(top.scanGroups) in \(url.lastPathComponent).")
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
            case .generated: throw EBSDReadError(text: "\(url.lastPathComponent) is not an h5ebsd file.")
            }
            dataset.manufacturer = top.manufacturer; dataset.version = top.version; dataset.scanGroups = top.scanGroups
            return dataset
        } catch { throw EBSDReadError.wrap(error, file: url) }
    }

    // MARK: - The top group

    /// `manufacturer` and `version` (lowercased, as kikuchipy keeps them; EDAX writes the names with a leading space, stripped like `_hdf5group2dict` does) and the scan groups: every top group that holds `EBSD/Data` and
    /// `EBSD/Header` (`H5EBSDReader.get_manufacturer_version`, `get_scan_groups`, `check_file`).
    struct TopGroup {
        var manufacturer: String
        var version: String
        var scanGroups: [String]

        init(_ reader: HDF5Reader) throws {
            var manufacturer: String?, version: String?
            var groups: [String] = []
            for name in try reader.children(of: "/") {
                switch try reader.kind(of: "/" + name) {
                case .dataset:
                    let key = name.lowercased().trimmingCharacters(in: .whitespaces)
                    if key == "manufacturer" { manufacturer = try reader.readStrings("/" + name).first?.lowercased() }
                    else if key == "version" || key == "format version" { version = try reader.readStrings("/" + name).first?.lowercased() }
                case .group:
                    if try reader.exists("/\(name)/EBSD/Data"), try reader.exists("/\(name)/EBSD/Header") { groups.append(name) }
                case .other: continue
                }
            }
            guard let manufacturer else { throw EBSDReadError(text: "the top group has no 'manufacturer' dataset: not an h5ebsd file.") }
            guard let version else { throw EBSDReadError(text: "the top group has no 'version' dataset: not an h5ebsd file.") }
            self.manufacturer = manufacturer; self.version = version; self.scanGroups = groups
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
            return Int(value)
        }

        func string(_ key: String) throws -> String? {
            guard let name = name(for: key), kind(key) == .dataset else { return nil }
            let full = path + "/" + name
            guard case .string = try file.reader.datasetInfo(full).type else { return nil }
            return try file.reader.readStrings(full).first
        }

        func required(_ key: String) throws -> Double {
            guard let value = try double(key) else { throw EBSDReadError(text: "the header has no '\(key)' dataset.") }
            return value
        }

        func requiredInt(_ key: String) throws -> Int { Int(try required(key)) }
    }

    // MARK: - Shared pieces

    /// The pattern dataset's shape and type checked against the scan: (n, sy, sx) or (ny, nx, sy, sx), with sy and sx the header's
    /// (`H5EBSDReader.get_data`; a shorter dataset is zero-padded there and here, a longer one is read up to the scan).
    static func patternSource(_ file: H5File, data: H5Group, name: String, scanRows: Int, scanColumns: Int, rows: Int, columns: Int,
                              order: [Int?]? = nil) throws -> EBSDPatternSource {
        guard let datasetName = data.name(for: name), let info = try data.info(name) else {
            throw EBSDReadError(text: "could not find patterns in the expected dataset 'EBSD/Data/\(name)'.")
        }
        guard case .numeric(let type) = info.type else {
            throw EBSDReadError(text: "the patterns in 'EBSD/Data/\(name)' are stored as \(info.type), not as numbers.")
        }
        let shape = info.shape
        let patternShape = Array(shape.suffix(2))
        guard shape.count == 3 || shape.count == 4, patternShape == [rows, columns] else {
            throw EBSDReadError(text: "the patterns in 'EBSD/Data/\(name)' have shape \(shape); the header says \(rows) x \(columns) patterns in a \(scanRows) x \(scanColumns) scan.")
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
        var crystalMap: EBSDCrystalMapData?
        if try file.reader.exists("/\(scan)/EBSD/CrystalMap/crystal_map") {
            crystalMap = try readCrystalMap(file, path: "/\(scan)/EBSD/CrystalMap/crystal_map")
        }
        let background = try header.array("static_background")
        return EBSDDataset(format: .kikuchipyH5EBSD, manufacturer: "", version: "", scanGroup: scan, scanGroups: [], scanRows: ny, scanColumns: nx,
                           patternRows: sy, patternColumns: sx, dataType: source.dataType, stepY: dy, stepX: dx, detector: detector,
                           staticBackground: background, sem: sem, crystalMap: crystalMap, patterns: source)
    }

    /// orix's `dict2crystalmap` fields: Euler angles, phase ids, the phases of the header, every other column as a property.
    static func readCrystalMap(_ file: H5File, path: String) throws -> EBSDCrystalMapData {
        let data = try H5Group(file, path + "/data")
        let header = try H5Group(file, path + "/header")
        let phi1 = try data.doubles("phi1")
        let Phi = try data.doubles("Phi")
        let phi2 = try data.doubles("phi2")
        guard let phi1, let Phi, let phi2 else {
            throw EBSDReadError(text: "the crystal map has no Euler angle datasets 'phi1', 'Phi', 'phi2'.")
        }
        let n = min(phi1.count, Phi.count, phi2.count)
        let euler = (0..<n).map { SIMD3(phi1[$0], Phi[$0], phi2[$0]) }
        let phaseColumn = try data.doubles("phase_id") ?? [Double](repeating: 0, count: n)
        let phaseIDs = phaseColumn.map { Int($0) }
        var phases: [EBSDPhase] = []
        if let list = try header.subgroup("phases") {
            for id in list.names.sorted(by: { (Int($0) ?? 0) < (Int($1) ?? 0) }) {
                guard let phase = try list.subgroup(id) else { continue }
                var lattice: [Double]?
                if let structure = try phase.subgroup("structure"), let latticeGroup = try structure.subgroup("lattice") {
                    lattice = try latticeGroup.doubles("abcABG")
                }
                let name = try phase.string("name") ?? ""
                let spaceGroup = try phase.int("space_group")
                let pointGroup = try phase.string("point_group")
                phases.append(EBSDPhase(name: name, spaceGroup: spaceGroup, pointGroup: pointGroup, lattice: lattice))
            }
        }
        var properties: [String: [Double]] = [:]
        let standard: Set<String> = ["phi1", "Phi", "phi2", "phase_id", "is_in_data", "id", "x", "y", "z"]
        for name in data.names where !standard.contains(name) {
            if let values = try data.doubles(name), values.count == n { properties[name] = values }
        }
        return EBSDCrystalMapData(euler: euler, phaseIDs: phaseIDs, phases: phases, properties: properties)
    }

    // MARK: - Bruker Nano

    static func readBruker(_ file: H5File, scan: String) throws -> EBSDDataset {
        let header = try H5Group(file, "/\(scan)/EBSD/Header")
        let data = try H5Group(file, "/\(scan)/EBSD/Data")
        let grid = try header.string("Grid Type")
        guard grid == "isometric" else { throw EBSDReadError(text: "only square grids are supported, not '\(grid ?? "none")'.") }
        var ny: Int
        var nx: Int
        var order: [Int?]?
        let semGroup = try H5Group(file, "/\(scan)/EBSD/SEM")
        let iy = try semGroup.doubles("IY")
        let ix = try semGroup.doubles("IX")
        if let iy, let ix {
            let rows = iy.map { Int($0) }
            let columns = ix.map { Int($0) }
            guard let roi = rectangularROI(rows: rows, columns: columns) else {
                throw EBSDReadError(text: "only a rectangular region of interest is supported.")
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
        let fullHeight = try header.double("DetectorFullHeightMicrons") ?? 1
        let unclippedHeight = try header.double("UnClippedPatternHeight") ?? 1
        let pxSize = fullHeight / unclippedHeight
        let source = try patternSource(file, data: data, name: "RawPatterns", scanRows: ny, scanColumns: nx, rows: sy, columns: sx, order: order)
        // PCs stay in file order for a region of interest, as kikuchipy 0.13.1 leaves them (docs/parity.md).
        let pcx = try data.doubles("PCX")
        let pcy = try data.doubles("PCY")
        let dd = try data.doubles("DD")
        let pc = centers(x: pcx, y: pcy, z: dd, scanCount: ny * nx)
        let tilt = try header.double("CameraTilt") ?? 0
        // kikuchipy reads 'Sample Tilt' (with the space) and so takes 0 where Esprit writes 'SampleTilt'; matched (docs/parity.md).
        let sampleTilt = try header.double("Sample Tilt") ?? 0
        let detector = EBSDDetectorGeometry(rows: sy, columns: sx, pixelSize: pxSize, binning: 1, tilt: tilt, azimuthal: 0, twist: 0,
                                            sampleTilt: sampleTilt, projectionCenters: pc)
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
            guard zip(keys, keys.dropFirst()).allSatisfy({ $1 - $0 == 1 }) else { return false }
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
        guard grid == "SqrGrid" else { throw EBSDReadError(text: "only square grids are supported, not '\(grid ?? "none")'.") }
        let ny = try header.requiredInt("nRows")
        let nx = try header.requiredInt("nColumns")
        let sy = try header.requiredInt("Pattern Height")
        let sx = try header.requiredInt("Pattern Width")
        let dy = try header.double("Step Y") ?? 1
        let dx = try header.double("Step X") ?? 1
        let source = try patternSource(file, data: data, name: "Pattern", scanRows: ny, scanColumns: nx, rows: sy, columns: sx)
        var pc = SIMD3(0.5, 0.5, 0.5)
        if let calibration = try header.subgroup("Pattern Center Calibration") {
            let x = try calibration.double("x-star") ?? 0.5
            let y = try calibration.double("y-star") ?? 0.5
            let z = try calibration.double("z-star") ?? 0.5
            pc = SIMD3(x, y, z)
        }
        let tilt = try header.double("Camera Elevation Angle") ?? 0
        let azimuthal = try header.double("Camera Azimuthal Angle") ?? 0
        let sampleTilt = try header.double("Sample Tilt") ?? 70
        var detector = EBSDDetectorGeometry(rows: sy, columns: sx, pixelSize: 1, binning: 1, tilt: tilt, azimuthal: azimuthal, twist: 0,
                                            sampleTilt: sampleTilt, projectionCenters: [])
        detector.projectionCenters = [detector.brukerCenter(pc, from: .tsl)]
        let prias = try H5Group(file, "/\(scan)/SEM-PRIAS Images/Header")
        let magnification = try prias.double("Mag")
        let wd = try header.double("Working Distance")
        let sem = EBSDSEMHeader(magnification: magnification, workingDistanceMM: wd)
        return EBSDDataset(format: .edaxH5EBSD, manufacturer: "", version: "", scanGroup: scan, scanGroups: [], scanRows: ny, scanColumns: nx,
                           patternRows: sy, patternColumns: sx, dataType: source.dataType, stepY: dy, stepX: dx, detector: detector, sem: sem,
                           patterns: source)
    }

    // MARK: - Oxford Instruments H5OINA

    static func readOxford(_ file: H5File, scan: String, version: String, processed: Bool = true) throws -> EBSDDataset {
        let header = try H5Group(file, "/\(scan)/EBSD/Header")
        let data = try H5Group(file, "/\(scan)/EBSD/Data")
        let ny = try header.requiredInt("Y Cells")
        let nx = try header.requiredInt("X Cells")
        let sy = try header.requiredInt("Pattern Height")
        let sx = try header.requiredInt("Pattern Width")
        let dy = try header.double("Y Step") ?? 1
        let dx = try header.double("X Step") ?? 1
        let name = processed ? "Processed Patterns" : "Unprocessed Patterns"
        let source = try patternSource(file, data: data, name: name, scanRows: ny, scanColumns: nx, rows: sy, columns: sx)
        var detector = EBSDDetectorGeometry(rows: sy, columns: sx, pixelSize: 1, binning: 1, tilt: 0, azimuthal: 0, twist: 0, sampleTilt: 70,
                                            projectionCenters: [])
        // H5OINA stores the angles as float32 and kikuchipy converts them with `np.rad2deg`, which for float32 is `x * 180 / pi` in
        // float32; matched (docs/parity.md), so the degrees are the reference's to the last bit. numpy's float32 pi is pi rounded to
        // nearest (3.1415927); Swift's `Float.pi` is rounded toward zero (3.1415925) and lands one ulp away.
        let pi32 = Float(Double.pi)
        func degrees(_ radians: Double) -> Double { Double(Float(radians) * 180 / pi32) }
        if let tiltAngle = try header.double("Tilt Angle") { detector.sampleTilt = degrees(tiltAngle) }
        if let euler = try header.doubles("Detector Orientation Euler"), euler.count > 1 { detector.tilt = Double(Float(degrees(euler[1])) - 90) }
        if let binning = try oxfordBinning(header: header, version: version) { detector.binning = binning }
        let pcx = try data.doubles("Pattern Center X")
        let pcy = try data.doubles("Pattern Center Y")
        let dd = try data.doubles("Detector Distance")
        let oxfordCenters = centers(x: pcx, y: pcy, z: dd, scanCount: ny * nx)
        detector.projectionCenters = oxfordCenters.map { detector.brukerCenter($0, from: .oxford) }
        let kv = try header.double("Beam Voltage")
        let magnification = try header.double("Magnification")
        let wd = try header.double("Working Distance")
        let sem = EBSDSEMHeader(beamEnergyKeV: kv, magnification: magnification, workingDistanceMM: wd)
        let background = try header.array("Processed Static Background")
        return EBSDDataset(format: .oxfordH5OINA, manufacturer: "", version: "", scanGroup: scan, scanGroups: [], scanRows: ny, scanColumns: nx,
                           patternRows: sy, patternColumns: sx, dataType: source.dataType, stepY: dy, stepX: dx, detector: detector,
                           staticBackground: background, sem: sem, patterns: source)
    }

    /// kikuchipy's `get_binning`: the camera mode string `... (WxH px)`; 1024 over the height, 8 for the 88-row Speed 3 mode. The dataset is
    /// `Camera Mode` from H5OINA 7.0 and `Camera Binning Mode` before.
    static func oxfordBinning(header: H5Group, version: String) throws -> Int? {
        let major = Int(version.split(separator: ".").first ?? "") ?? 0
        let key = major >= 7 ? "Camera Mode" : "Camera Binning Mode"
        guard let mode = try header.string(key) else { return nil }
        guard let open = mode.lastIndex(of: "("), let close = mode[open...].firstIndex(of: ")") else { return nil }
        let inside = mode[mode.index(after: open)..<close]   // "60x60 px"
        guard inside.hasSuffix(" px") else { return nil }
        let dims = inside.dropLast(3).split(separator: "x")
        guard dims.count == 2, let height = Int(dims[1]) else { return nil }
        return height == 88 ? 8 : Int((1024.0 / Double(height)).rounded())
    }
}
