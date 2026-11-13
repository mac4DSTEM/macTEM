//
//  IndexingPhase.swift
//  Role: one phase the Indexing room indexes against (docs/sem/design/indexing-room.md §4, Phases): its name, space group, lattice
//        and the reflector families its Hough library is built from (`HoughReflectorLibrary`), where it came from (the file's crystal
//        map, a built-in preset or a CIF) and whether it is on. The point group (orix's, from the space group) colours its IPF maps.
//
//  The reflectors follow pyEBSDindex's defaults by lattice (D-SEM-83): the HCP list for the hexagonal Laue groups (space groups
//  168 to 194, the only ones its 4-index list is defined for), the BCC list for the body-centred cubic groups, the FCC list for
//  every other group, which is what `addphase` takes when no library type is named. The built-in presets carry DiffractoKit's
//  `CrystalPresets` lattice constants (the two apps' presets) with the space group each structure has.
//

import DiffractoCore
import Foundation

package nonisolated struct IndexingPhase: Sendable, Equatable, Identifiable, Codable {
    /// Where the phase came from.
    package enum Source: String, Sendable, Codable, Equatable {
        case file, preset, cif

        package var title: String {
            switch self {
            case .file: "from the file"
            case .preset: "built in"
            case .cif: "from a CIF"
            }
        }
    }

    /// The reflector families of the Hough library: pyEBSDindex's three default lists.
    package enum Reflectors: String, Sendable, Codable, CaseIterable, Identifiable {
        case fcc, bcc, hcp

        package var id: String { rawValue }

        package var title: String {
            switch self {
            case .fcc: "FCC"
            case .bcc: "BCC"
            case .hcp: "HCP"
            }
        }

        /// The families as `HoughReflectorLibrary` takes them.
        package var families: [[Int]] {
            switch self {
            case .fcc: HoughReflectorLibrary.fccReflectors
            case .bcc: HoughReflectorLibrary.bccReflectors
            case .hcp: HoughReflectorLibrary.hcpReflectors
            }
        }

        /// Whether the list can be built for `spaceGroup`: the 4-index HCP list needs a hexagonal Laue group (6/m or 6/mmm).
        package func fits(spaceGroup: Int) -> Bool {
            self != .hcp || IndexingPhase.hexagonalSpaceGroups.contains(spaceGroup)
        }
    }

    /// The phase's name in the room (unique in its list) and in the results.
    package var name: String
    /// The space group (1...230).
    package var spaceGroup: Int
    /// a, b, c (any one length unit) and alpha, beta, gamma in degrees.
    package var lattice: [Double]
    /// The unit of a, b, c: Å for a preset or a CIF, the file's where it states one (macEM#614); nil where it does not.
    package var latticeUnit: CrystalPhase.LatticeUnit?
    package var source: Source
    package var isOn: Bool
    package var reflectors: Reflectors
    /// A matplotlib colour name (`tab:blue`), the phase's colour on the Phase map (orix's).
    package var color: String

    package var id: String { name }

    package init(name: String, spaceGroup: Int, lattice: [Double], source: Source, isOn: Bool = true, reflectors: Reflectors? = nil,
                 color: String = "tab:blue", latticeUnit: CrystalPhase.LatticeUnit? = nil) {
        self.name = name
        self.spaceGroup = spaceGroup
        self.lattice = lattice
        self.latticeUnit = latticeUnit ?? (source == .file ? nil : .angstrom)
        self.source = source
        self.isOn = isOn
        self.reflectors = reflectors ?? Self.defaultReflectors(spaceGroup: spaceGroup)
        self.color = color
    }

    // MARK: - Symmetry

    /// The hexagonal space groups (Laue groups 6/m and 6/mmm).
    package static let hexagonalSpaceGroups = 168...194
    /// The body-centred cubic space groups: I23, I2₁3, Im-3, Ia-3, I432, I4₁32, I-43m, I-43d, Im-3m, Ia-3d.
    package static let bodyCentredCubicSpaceGroups: Set<Int> = [197, 199, 204, 206, 211, 214, 217, 220, 229, 230]

    /// pyEBSDindex's reflector list for a lattice (D-SEM-83): HCP for the hexagonal groups, BCC for the body-centred cubic ones, FCC
    /// for every other group (`addphase`'s default).
    package static func defaultReflectors(spaceGroup: Int) -> Reflectors {
        if hexagonalSpaceGroups.contains(spaceGroup) { return .hcp }
        if bodyCentredCubicSpaceGroups.contains(spaceGroup) { return .bcc }
        return .fcc
    }

    /// The point group as orix names it ("m-3m", "6/mmm"), from the space group.
    package var pointGroupName: String? { SpaceGroupPointGroup.pointGroup(ofSpaceGroup: spaceGroup)?.name }

    /// The point group as an orientation symmetry, for the IPF colour key.
    package var pointGroup: PointGroup? { pointGroupName.flatMap(PointGroup.named) }

    /// The phase's colour on the Phase map, 0...1 per channel (tab:blue when the name is not one orix hands out).
    package var colorRGB: SIMD3<Double> { PhaseList.rgb[color] ?? PhaseList.rgb["tab:blue"] ?? SIMD3(0.12, 0.47, 0.71) }

    /// The phase as a crystal map writes it (orix's `Phase`).
    package var crystalPhase: CrystalPhase {
        CrystalPhase(name: name, spaceGroup: spaceGroup, pointGroup: pointGroupName, lattice: lattice, color: color, latticeUnit: latticeUnit)
    }

    /// Why the phase cannot be indexed against, in the room's words; nil when it can.
    package var refusal: String? {
        guard (1...230).contains(spaceGroup) else { return "\(name): space group \(spaceGroup) is outside 1 to 230." }
        guard lattice.count == 6, lattice.allSatisfy(\.isFinite), lattice[0] > 0, lattice[1] > 0, lattice[2] > 0,
              lattice[3] > 0, lattice[4] > 0, lattice[5] > 0, lattice[3] < 180, lattice[4] < 180, lattice[5] < 180 else {
            return "\(name): the lattice parameters do not describe a cell."
        }
        guard reflectors.fits(spaceGroup: spaceGroup) else {
            return "\(name): the HCP reflector list is written in four indices, which only a hexagonal space group (168 to 194) takes."
        }
        return nil
    }

    /// The phase's Hough reflector library (`addphase(name, spacegroup, lattice, polefamilies, nband_earlyexit)`).
    package func library(angleTolerance: Double, earlyExitBands: Int) throws -> HoughReflectorLibrary {
        try HoughReflectorLibrary(name: name, spaceGroup: spaceGroup, lattice: lattice, reflectors: reflectors.families,
                                  earlyExitBands: earlyExitBands, angleTolerance: angleTolerance)
    }

    // MARK: - Where phases come from

    /// The built-in phases, lattice constants in Å from DiffractoKit's `CrystalPresets` (the two apps' presets).
    package static let presets: [IndexingPhase] = {
        func cubic(_ name: String, _ structure: CrystalStructure, _ spaceGroup: Int) -> IndexingPhase {
            let a = structure.cell.a
            return IndexingPhase(name: name, spaceGroup: spaceGroup, lattice: [a, a, a, 90, 90, 90], source: .preset)
        }
        let mg = CrystalPresets.magnesium.cell
        return [
            cubic("Ni", CrystalPresets.nickel, 225),
            cubic("Al", CrystalPresets.aluminum, 225),
            cubic("Cu", CrystalPresets.copper, 225),
            cubic("Au", CrystalPresets.gold, 225),
            cubic("Fe (α)", CrystalPresets.iron, 229),
            cubic("Si", CrystalPresets.silicon, 227),
            IndexingPhase(name: "Mg", spaceGroup: 194, lattice: [mg.a, mg.b, mg.c, mg.alphaDeg, mg.betaDeg, mg.gammaDeg], source: .preset),
        ]
    }()

    /// The phases of a file's crystal map that can be indexed against (a name, a space group and six lattice parameters), in the map's
    /// order with the map's colours; and the names of those left out for want of a space group or a lattice.
    package static func fromCrystalMap(_ phases: PhaseList) -> (phases: [IndexingPhase], skipped: [String]) {
        var kept: [IndexingPhase] = [], skipped: [String] = []
        for (id, phase) in phases.entries where id != PhaseList.notIndexedID && phase.name != PhaseList.notIndexedName {
            guard let spaceGroup = phase.spaceGroup, (1...230).contains(spaceGroup), let lattice = phase.lattice, lattice.count == 6 else {
                skipped.append(phase.name)
                continue
            }
            kept.append(IndexingPhase(name: phase.name, spaceGroup: spaceGroup, lattice: lattice, source: .file, color: phase.color,
                                      latticeUnit: phase.latticeUnit))
        }
        return (kept, skipped)
    }

    /// The phase of a structure read from a CIF; refused when the file states no space group number (the Hough library is built from
    /// the space group's Laue group).
    package static func fromCIF(_ structure: CrystalStructure, name: String) throws -> IndexingPhase {
        guard let spaceGroup = structure.spaceGroupNumber, (1...230).contains(spaceGroup) else {
            throw IndexingRefusal("\(name): the CIF states no space group number, which the Hough library is built from.")
        }
        let cell = structure.cell
        return IndexingPhase(name: name, spaceGroup: spaceGroup, lattice: [cell.a, cell.b, cell.c, cell.alphaDeg, cell.betaDeg, cell.gammaDeg],
                             source: .cif)
    }

    /// `name`, or `name 2`, `name 3`… when the list already holds it.
    package static func uniqueName(_ name: String, among names: [String]) -> String {
        guard names.contains(name) else { return name }
        var n = 2
        while names.contains("\(name) \(n)") { n += 1 }
        return "\(name) \(n)"
    }
}

/// Why the room cannot index, in its words (shown under the verb and in the status line).
package nonisolated struct IndexingRefusal: Error, Equatable, Sendable, LocalizedError {
    package let sentence: String
    package init(_ sentence: String) { self.sentence = sentence }
    package var errorDescription: String? { sentence }
}
