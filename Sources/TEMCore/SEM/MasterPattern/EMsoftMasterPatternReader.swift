//
//  EMsoftMasterPatternReader.swift
//  Role: EMsoft's master pattern HDF5 files (EMEBSDmaster, EMTKDmaster, EMECPmaster and their OpenCL twins) read as kikuchipy
//        0.13.1 reads them: a port of `kikuchipy/io/plugins/_emsoft_master_pattern.py` (`EMsoftMasterPatternReader.read`,
//        `check_file_format`, `get_data_shape_slices`, `get_datasets`) with the three plugins' names
//        (`emsoft_{ebsd,tkd,ecp}_master_pattern/_api.py`) and the phase of `emsoft_ebsd/_api.py::_crystaldata2phase`,
//        GPL-3.0-or-later (NOTICE). The square Lambert or stereographic projection, the upper, lower or both hemispheres, every
//        energy, the nearest one or a range; the Lambert patterns of the asymmetric positions summed (`numset`) and cast back to
//        the stored type, the stereographic ones flipped up-down, as kikuchipy hands them.
//        One deliberate difference (decision in docs/decisions.md, row in docs/parity.md): an ECP file's Lambert dataset of rank 4
//        is read as (numset, energy, y, x) like the EBSD and TKD ones; kikuchipy applies the energy pick to its first axis there
//        and returns an empty array, so for that case the parity covers the whole-energy reading only.
//        Parity: macTEMTests/MasterPatternParityTests.swift against tools/parity/sem/references/m6/read-master-pattern-*.
//

import Foundation
import FormatoCore
import FormatoHDF5

/// A dynamically simulated Kikuchi master pattern as kikuchipy's `EBSDMasterPattern` / `ECPMasterPattern` holds it after reading.
package nonisolated struct EBSDMasterPattern: Sendable, Equatable {
    /// Which EMsoft program wrote the file.
    package enum DiffractionType: String, Sendable, CaseIterable {
        case ebsd = "EBSD", tkd = "TKD", ecp = "ECP"

        /// The Monte Carlo name list that holds `Ebinsize` (`cl_parameters_group_name`).
        var monteCarloNameList: String { self == .tkd ? "MCCLfoilNameList" : "MCCLNameList" }
        /// The energies dataset in `EMData/<type>master` (`energy_string`).
        var energyDataset: String { self == .ecp ? "EkeV" : "EkeVs" }
        /// kikuchipy's signal type: a TKD master pattern is an `EBSDMasterPattern`.
        package var signalType: String { self == .ecp ? "ECPMasterPattern" : "EBSDMasterPattern" }
    }

    package enum Projection: String, Sendable, CaseIterable { case lambert, stereographic }
    package enum Hemisphere: String, Sendable, CaseIterable { case upper, lower, both }

    /// Which energies to read (kikuchipy's `energy`): all of them, the one nearest a value, or every one within a range (keV).
    package enum EnergySelection: Sendable, Equatable {
        case all
        case nearest(Double)
        case range(Double, Double)
    }

    /// A phase as `_crystaldata2phase` builds it from `CrystalData`, named from the Monte Carlo `xtalname` as the reader does.
    package struct Phase: Sendable, Equatable {
        /// "None" where the file names none (kikuchipy assigns `None`, orix stores `str(None)`).
        package var name: String
        package var spaceGroup: Int
        /// The point group of the space group (orix's `get_point_group(number, proper=False)` name, e.g. `m-3m`).
        package var pointGroup: String
        /// Whether that point group holds the inversion (orix's `contains_inversion`).
        package var containsInversion: Bool
        /// a, b, c (nm, as EMsoft writes them), alpha, beta, gamma (degrees).
        package var lattice: [Double]
        package var atomCount: Int
    }

    /// One energy axis entry of the hyperspy signal: offset, scale and size (keV).
    package struct EnergyAxis: Sendable, Equatable {
        package var offset: Double
        package var scale: Double
        package var size: Int

        /// hyperspy's `UniformDataAxis.value2index(value)` with `round`: the value truncated at 1e-12 of an index, rounded half
        /// towards zero for a non-negative value (half away from zero for a negative one), refused outside the axis.
        package func index(of value: Double) throws -> Int {
            let raw = ((value - offset) / scale * 1e12).rounded(.towardZero) / 1e12
            // hyperspy's `round_half_towards_zero` and `round_half_away_from_zero` (misc/_array_tools.py).
            let towardsZero = raw >= 0 ? (raw - 0.5).rounded(.up) : (raw + 0.5).rounded(.down)
            let awayFromZero = raw >= 0 ? (raw + 0.5).rounded(.down) : (raw - 0.5).rounded(.up)
            let rounded = value >= 0 ? towardsZero : awayFromZero
            guard rounded.isFinite, rounded >= 0, rounded < Double(size) else {
                throw EBSDReadError(text: "\(value) keV is outside the master pattern's energies (\(offset) to \(offset + scale * Double(size - 1)) keV).")
            }
            return Int(rounded)
        }
    }

    package var diffractionType: DiffractionType
    package var projection: Projection
    package var hemisphere: Hemisphere
    /// The stored element type (uint8 or float32 in EMsoft's and kikuchipy's files).
    package var dataType: FormatoDataType
    /// Hemispheres held: 2 for `.both`, else 1 (upper first).
    package var hemisphereCount: Int
    /// The energies read, in keV, in file order.
    package var energies: [Double]
    /// The side of the square pattern in px (`2 npx + 1`).
    package var side: Int
    /// The intensities, C order (hemisphere, energy, row, column); every stored uint8 or float32 value is exact in Float.
    package var values: [Float]
    package var phase: Phase
    /// The energy axis hyperspy builds: offset the first energy read, scale the Monte Carlo `Ebinsize`.
    package var energyAxis: EnergyAxis

    /// kikuchipy's array shape after `squeeze`: (hemisphere,) (energy,) row, column, each of size 1 dropped.
    package var shape: [Int] {
        [hemisphereCount, energies.count, side, side].filter { $0 != 1 }
    }

    /// The pixel offset hyperspy gives both signal axes: `-side // 2` (floor division).
    package var pixelOffset: Int { Int((-Double(side) / 2).rounded(.down)) }

    /// The pattern of one hemisphere (0 upper, 1 lower when both are held) and one energy index, row-major `side x side`.
    package func pattern(hemisphere h: Int, energy e: Int) -> ArraySlice<Float> {
        let n = side * side
        let start = (h * energies.count + e) * n
        return values[start ..< start + n]
    }

    /// The upper and lower Lambert patterns a projection samples (`_get_master_pattern_arrays_from_energy`): with several
    /// energies, the one at `energy` keV on the energy axis (the highest when nil); with one hemisphere, it serves as both.
    package func hemispheres(energy: Double?) throws -> (upper: ArraySlice<Float>, lower: ArraySlice<Float>) {
        var e = 0
        if energies.count > 1 {
            let value = energy ?? (energyAxis.offset + energyAxis.scale * Double(energyAxis.size - 1))
            e = try energyAxis.index(of: value)
        }
        let upper = pattern(hemisphere: 0, energy: e)
        let lower = hemisphereCount == 2 ? pattern(hemisphere: 1, energy: e) : upper
        return (upper, lower)
    }
}

package nonisolated enum EMsoftMasterPatternReader {
    /// The diffraction type whose EMsoft program wrote the file (`EMheader/<type>master/ProgramName` is `EM<type>master.f90` or
    /// `EM<type>masterOpenCL.f90`), or nil when it is no EMsoft master pattern file. One HDF5 open; run off the main actor.
    package static func sniff(url: URL) -> EBSDMasterPattern.DiffractionType? {
        guard let reader = try? HDF5Reader(url: url) else { return nil }
        return EBSDMasterPattern.DiffractionType.allCases.first { (try? checkFormat(reader, $0)) != nil }
    }

    /// The master pattern file at `url` of `type` (kikuchipy's plugin), in `projection` and `hemisphere`, for `energy`.
    /// kikuchipy's defaults are stereographic, upper, all energies; a projection onto a detector needs Lambert.
    package static func read(url: URL, type: EBSDMasterPattern.DiffractionType = .ebsd, projection: EBSDMasterPattern.Projection = .stereographic,
                             hemisphere: EBSDMasterPattern.Hemisphere = .upper, energy: EBSDMasterPattern.EnergySelection = .all) throws -> EBSDMasterPattern {
        do {
            let reader = try HDF5Reader(url: url)
            try checkFormat(reader, type)
            let t = type.rawValue
            let dataGroup = "/EMData/\(t)master"
            let nml = "/NMLparameters"

            // The phase (`_crystaldata2phase`), named from `MCCLNameList/xtalname` (`os.path.split(...)[0]`, then `splitext`).
            let spaceGroup = try storedCount(requiredDouble(reader, "/CrystalData/SpaceGroupNumber"), path: "/CrystalData/SpaceGroupNumber")
            let lattice = try reader.readDataset("/CrystalData/LatticeParameters").doubles()
            let atoms = try storedCount(requiredDouble(reader, "/CrystalData/Natomtypes"), path: "/CrystalData/Natomtypes")
            let xtalPath = "\(nml)/MCCLNameList/xtalname"
            // Without one kikuchipy sets `phase.name = None`, which orix's setter stores as the text "None".
            let name = try reader.exists(xtalPath) ? try reader.readStrings(xtalPath).first.map { splitExtension(pathHead($0)) } ?? "None" : "None"
            guard let group = SpaceGroupPointGroup.pointGroup(ofSpaceGroup: spaceGroup) else {
                throw EBSDReadError(text: "the file's space group \(spaceGroup) is not one of the 230.")
            }
            let phase = EBSDMasterPattern.Phase(name: name, spaceGroup: spaceGroup, pointGroup: group.name,
                                                containsInversion: group.inversion, lattice: lattice, atomCount: atoms)

            // The energies and the slice of them (`get_data_shape_slices`). EMsoft writes them as float32: compared as float32.
            let energies = try reader.readDataset("\(dataGroup)/\(type.energyDataset)").doubles()
            guard !energies.isEmpty else { throw EBSDReadError(text: "the file lists no energies in '\(dataGroup)/\(type.energyDataset)'.") }
            let npxPath = "\(nml)/\(t)MasterNameList/npx"
            let side = try patternSide(npx: requiredDouble(reader, npxPath), path: npxPath)
            let picked = try energyIndices(Array(energies), selection: energy)
            let binSize = try requiredDouble(reader, "\(nml)/\(type.monteCarloNameList)/Ebinsize")

            // The datasets (`get_datasets`): upper (NH) first.
            let label = projection == .stereographic ? "masterSP" : "mLP"
            let names: [String]
            switch hemisphere {
            case .both: names = ["\(label)NH", "\(label)SH"]
            case .upper: names = ["\(label)NH"]
            case .lower: names = ["\(label)SH"]
            }
            // Room for every hemisphere is reserved once the first is read, never from the stored npx alone.
            var values: [Float] = []
            var dataType: FormatoDataType?
            for dataset in names {
                let (stored, block) = try readHemisphere(reader, path: "\(dataGroup)/\(dataset)", projection: projection,
                                                         energies: picked, energyCount: energies.count, side: side)
                if let dataType, dataType != stored {
                    throw EBSDReadError(text: "the two hemispheres are stored as \(dataType.rawValue) and \(stored.rawValue).")
                }
                dataType = stored
                if values.isEmpty { values.reserveCapacity(names.count * block.count) }
                values += block
            }
            guard let dataType else { throw EBSDReadError(text: "no master pattern dataset was read.") }
            let read = picked.map { energies[$0] }
            return EBSDMasterPattern(diffractionType: type, projection: projection, hemisphere: hemisphere, dataType: dataType,
                                     hemisphereCount: names.count, energies: read, side: side, values: values, phase: phase,
                                     energyAxis: .init(offset: Double(Float(read[0])), scale: binSize, size: read.count))
        } catch { throw EBSDReadError.wrap(error, file: url) }
    }

    // MARK: - Pieces

    /// `check_file_format`: the program name must be EMsoft's master pattern program of this diffraction type.
    static func checkFormat(_ reader: HDF5Reader, _ type: EBSDMasterPattern.DiffractionType) throws {
        let t = type.rawValue
        let path = "/EMheader/\(t)master/ProgramName"
        guard try reader.exists(path), let program = try reader.readStrings(path).first,
              program == "EM\(t)master.f90" || program == "EM\(t)masterOpenCL.f90" else {
            throw EBSDReadError(text: "the file is not created with one of the supported EMsoft programs (EM\(t)master.f90, EM\(t)masterOpenCL.f90).")
        }
    }

    /// The indices of the energies to read (`get_data_shape_slices`), compared in float32 as numpy compares a float32 array with
    /// a Python number: the nearest (`argmin` of the absolute difference, the first on a tie), or `energies >= low` up to the last
    /// `energies <= high`.
    static func energyIndices(_ energies: [Double], selection: EBSDMasterPattern.EnergySelection) throws -> [Int] {
        let e32 = energies.map { Float($0) }
        switch selection {
        case .all:
            return Array(e32.indices)
        case .nearest(let value):
            let v = Float(value)
            var best = 0
            for i in e32.indices where abs(e32[i] - v) < abs(e32[best] - v) { best = i }
            return [best]
        case .range(let low, let high):
            let lo = Float(low), hi = Float(high)
            guard let first = e32.firstIndex(where: { $0 >= lo }), let last = e32.lastIndex(where: { $0 <= hi }), last >= first else {
                throw EBSDReadError(text: "no energy of the file (\(energies.map { String($0) }.joined(separator: ", ")) keV) lies within \(low) to \(high) keV.")
            }
            return Array(first ... last)
        }
    }

    /// One hemisphere's patterns for the picked energies, `side x side` each. A Lambert dataset is (numset, energy, y, x): the
    /// asymmetric positions are summed and cast back to the stored type (`data.sum(axis).astype(data.dtype)`: uint8 wraps at 256);
    /// a stereographic dataset is (energy, y, x), flipped up-down.
    static func readHemisphere(_ reader: HDF5Reader, path: String, projection: EBSDMasterPattern.Projection, energies picked: [Int],
                               energyCount: Int, side: Int) throws -> (FormatoDataType, [Float]) {
        guard try reader.exists(path) else { throw EBSDReadError(text: "the file has no dataset '\(path)'.") }
        let info = try reader.datasetInfo(path)
        guard case .numeric(let type) = info.type, type == .uint8 || type == .float32 || type == .float64 || type == .uint16 else {
            throw EBSDReadError(text: "'\(path)' is stored as \(info.type), not as uint8, uint16, float32 or float64 numbers.")
        }
        let shape = info.shape
        // `side` comes from patternSide, so its square fits an Int; room for the patterns is reserved once the shape holds them.
        let n = side * side
        var out: [Float] = []
        switch (projection, shape.count) {
        case (.lambert, 4):
            guard shape[1] == energyCount, shape[2] == side, shape[3] == side else {
                throw EBSDReadError(text: "'\(path)' has shape \(shape), not (numset, \(energyCount), \(side), \(side)).")
            }
            try reserve(&out, patterns: picked.count, of: n, path: path, shape: shape)
            let numset = shape[0]
            for e in picked {
                let block = try reader.readDataset(path, start: [0, e, 0, 0], count: [numset, 1, side, side]).doubles()
                for p in 0 ..< n {
                    var sum = 0.0
                    for s in 0 ..< numset { sum += block[s * n + p] }
                    out.append(cast(sum, to: type))
                }
            }
        case (.lambert, 3), (.stereographic, 3):
            guard shape[0] == energyCount, shape[1] == side, shape[2] == side else {
                throw EBSDReadError(text: "'\(path)' has shape \(shape), not (\(energyCount), \(side), \(side)).")
            }
            try reserve(&out, patterns: picked.count, of: n, path: path, shape: shape)
            for e in picked {
                let block = try reader.readDataset(path, start: [e, 0, 0], count: [1, side, side]).doubles()
                if projection == .stereographic {
                    for r in stride(from: side - 1, through: 0, by: -1) {
                        for c in 0 ..< side { out.append(Float(block[r * side + c])) }
                    }
                } else {
                    out.append(contentsOf: block.map { Float($0) })
                }
            }
        default:
            throw EBSDReadError(text: "'\(path)' has shape \(shape), which is not a \(projection.rawValue) master pattern layout.")
        }
        return (type, out)
    }

    /// A sum cast back to the stored type as numpy's `astype` does: an integer type wraps modulo its range, a float32 rounds.
    static func cast(_ sum: Double, to type: FormatoDataType) -> Float {
        switch type {
        case .uint8: return Float(UInt64(sum) % 256)
        case .uint16: return Float(UInt64(sum) % 65_536)
        default: return Float(sum)
        }
    }

    static func requiredDouble(_ reader: HDF5Reader, _ path: String) throws -> Double {
        guard try reader.exists(path), let value = try reader.readDataset(path).doubles().first else {
            throw EBSDReadError(text: "the file has no '\(path)'.")
        }
        return value
    }

    /// A count the file stores as a number (a space group, a number of atom types, npx), as Int(_:) truncates it; one that
    /// is not finite or does not fit an Int is refused rather than trapped on.
    static func storedCount(_ value: Double, path: String) throws -> Int {
        guard let n = Int(exactly: value.rounded(.towardZero)) else {
            throw EBSDReadError(text: "the file's '\(path)' is \(value), which is not a count.")
        }
        return n
    }

    /// The side of the square pattern, `2 npx + 1` px, from the stored npx; refused when npx is not a count or the side's
    /// square overflows an Int (no dataset has that shape), so nothing is sized from a damaged npx.
    package static func patternSide(npx: Double, path: String) throws -> Int {
        let half = try storedCount(npx, path: path)
        let doubled = half.multipliedReportingOverflow(by: 2)
        let side = doubled.partialValue.addingReportingOverflow(1)
        let area = side.partialValue.multipliedReportingOverflow(by: side.partialValue)
        guard !doubled.overflow, !side.overflow, !area.overflow else {
            throw EBSDReadError(text: "the file's '\(path)' is \(npx), a pattern side no dataset has.")
        }
        return side.partialValue
    }

    /// Room in `out` for `patterns` patterns of `n` values, once the dataset's shape is known to hold them.
    private static func reserve(_ out: inout [Float], patterns: Int, of n: Int, path: String, shape: [Int]) throws {
        let total = patterns.multipliedReportingOverflow(by: n)
        guard !total.overflow else { throw EBSDReadError(text: "'\(path)' has shape \(shape), more values than macTEM holds.") }
        out.reserveCapacity(total.partialValue)
    }

    /// `os.path.split(path)[0]`: everything before the last slash, trailing slashes removed unless only slashes remain.
    static func pathHead(_ path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        let head = String(path[...slash])
        let trimmed = head.replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        return trimmed.isEmpty ? head : trimmed
    }

    /// `os.path.splitext(path)[0]`: the last component's extension removed (a leading dot is no extension).
    static func splitExtension(_ path: String) -> String {
        let start = path.lastIndex(of: "/").map { path.index(after: $0) } ?? path.startIndex
        let last = path[start...]
        guard let dot = last.lastIndex(of: "."), last[last.startIndex ..< dot].contains(where: { $0 != "." }) else { return path }
        return String(path[..<dot])
    }
}

/// The crystallographic point group of each of the 230 space groups, with whether it holds the inversion: orix 0.15.0's
/// `get_point_group(number, proper=False)` and `contains_inversion` (the table is checked against orix in the parity bundle).
package nonisolated enum SpaceGroupPointGroup {
    private static let table: [(last: Int, name: String, inversion: Bool)] = [
        (1, "1", false), (2, "-1", true), (5, "2", false), (9, "m", false), (15, "2/m", true), (24, "222", false),
        (46, "mm2", false), (74, "mmm", true), (80, "4", false), (82, "-4", false), (88, "4/m", true), (98, "422", false),
        (110, "4mm", false), (122, "-42m", false), (142, "4/mmm", true), (146, "3", false), (148, "-3", true), (155, "32", false),
        (161, "3m", false), (167, "-3m", true), (173, "6", false), (174, "-6", false), (176, "6/m", true), (182, "622", false),
        (186, "6mm", false), (190, "-6m2", false), (194, "6/mmm", true), (199, "23", false), (206, "m-3", true), (214, "432", false),
        (220, "-43m", false), (230, "m-3m", true),
    ]

    package static func pointGroup(ofSpaceGroup number: Int) -> (name: String, inversion: Bool)? {
        guard (1 ... 230).contains(number), let row = table.first(where: { number <= $0.last }) else { return nil }
        return (row.name, row.inversion)
    }
}
