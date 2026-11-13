//
//  PhaseList.swift
//  orix 0.15.0's `Phase` and `PhaseList` (orix.crystal_map._phase, orix.crystal_map._phase_list): the phases of a crystal map
//  by id, ascending, each with its name, space group, point group, lattice and colour; the `not_indexed` phase (id −1, no
//  point group, white) that a map with unindexed points carries. GPL-3.0 (orix is GPL-3.0-or-later), see NOTICE.
//
//  Colours follow orix: a phase given without one takes the next of matplotlib's Tableau colours (`tab:blue`, `tab:orange`,
//  ...) not yet used, in that order; orix continues into the xkcd names after ten phases, the port cycles the ten.
//

import Foundation

/// orix's `Phase`: one crystal phase of a map.
package nonisolated struct CrystalPhase: Sendable, Equatable {
    package var name: String
    /// The formula when the file writes one beside the name (`.ang`).
    package var formula: String?
    package var spaceGroup: Int?
    /// The point group as orix names it (`m-3m`, `6/mmm`, `622`, `432`, ...); nil for `not_indexed`.
    package var pointGroupName: String?
    /// a, b, c (the file's unit, `latticeUnit`), alpha, beta, gamma (degrees).
    package var lattice: [Double]?
    /// A matplotlib colour name (`tab:blue`, `white`).
    package var color: String
    /// The unit of a, b, c where the source states it (.ang and .ctf: Å; an EMsoft master pattern: nm); nil where it does not (orix's
    /// .h5 keeps whatever its writer had, and kikuchipy keeps EMsoft's nm), and only then is the unit guessed (macEM#614).
    package var latticeUnit: LatticeUnit?

    package enum LatticeUnit: String, Sendable, Equatable, Codable {
        case angstrom, nanometre
    }

    package init(name: String, formula: String? = nil, spaceGroup: Int? = nil, pointGroup: String? = nil, lattice: [Double]? = nil,
                 color: String = "tab:blue", latticeUnit: LatticeUnit? = nil) {
        self.name = name; self.formula = formula; self.spaceGroup = spaceGroup; self.pointGroupName = pointGroup; self.lattice = lattice
        self.color = color; self.latticeUnit = latticeUnit
    }

    /// a, b, c in ångström, alpha, beta, gamma in degrees: by the stated unit, else by the guess a source with no unit leaves (every
    /// length under 2 is nm: no crystal has a cell edge under 2 Å, and EBSD phases rarely one over 2 nm). nil without six parameters.
    package var latticeInAngstrom: [Double]? {
        guard var p = lattice, p.count == 6 else { return nil }
        let nanometres: Bool
        switch latticeUnit {
        case .angstrom: nanometres = false
        case .nanometre: nanometres = true
        case nil: nanometres = p[0] < 2 && p[1] < 2 && p[2] < 2
        }
        if nanometres { p[0] *= 10; p[1] *= 10; p[2] *= 10 }
        return p
    }

    /// The point group as an orientation symmetry; nil when the phase names none or orix knows no group of that name.
    package var pointGroup: PointGroup? { pointGroupName.flatMap(PointGroup.named) }

    /// orix's `Phase.color_rgb` for the colours a phase list hands out: 0...1 per channel.
    package var colorRGB: SIMD3<Double>? { PhaseList.rgb[color] }

    /// `PhaseList.add_not_indexed`'s phase: no point group, white, orix's default lattice (1, 1, 1, 90°, 90°, 90°).
    package static let notIndexed = CrystalPhase(name: PhaseList.notIndexedName, lattice: [1, 1, 1, 90, 90, 90], color: "white")
}

/// orix's `PhaseList`: phases by id in ascending order.
package nonisolated struct PhaseList: Sendable, Equatable {
    package static let notIndexedName = "not_indexed"
    package static let notIndexedID = -1

    /// matplotlib's `TABLEAU_COLORS` in its order: the colours orix hands out first.
    package static let tableau = ["tab:blue", "tab:orange", "tab:green", "tab:red", "tab:purple", "tab:brown", "tab:pink",
                                  "tab:gray", "tab:olive", "tab:cyan"]
    /// The hex values of `tableau` and `white`, as matplotlib defines them.
    package static let rgb: [String: SIMD3<Double>] = {
        let hex: [String: UInt32] = ["tab:blue": 0x1f77b4, "tab:orange": 0xff7f0e, "tab:green": 0x2ca02c, "tab:red": 0xd62728,
                                     "tab:purple": 0x9467bd, "tab:brown": 0x8c564b, "tab:pink": 0xe377c2, "tab:gray": 0x7f7f7f,
                                     "tab:olive": 0xbcbd22, "tab:cyan": 0x17becf, "white": 0xffffff, "black": 0x000000]
        return hex.mapValues { SIMD3(Double(($0 >> 16) & 0xff) / 255, Double(($0 >> 8) & 0xff) / 255, Double($0 & 0xff) / 255) }
    }()

    package private(set) var ids: [Int]
    package private(set) var phases: [CrystalPhase]

    /// Phases with their ids; sorted by id as orix's `OrderedDict(sorted(...))`. A phase whose colour is already taken gets the
    /// next free Tableau colour, as orix's constructor does.
    package init(_ entries: [(id: Int, phase: CrystalPhase)] = []) {
        var used: [String] = []
        var fixed: [(id: Int, phase: CrystalPhase)] = []
        for (id, phase) in entries {
            var p = phase
            if used.contains(p.color), let free = PhaseList.tableau.first(where: { !used.contains($0) }) { p.color = free }
            used.append(p.color)
            fixed.append((id, p))
        }
        fixed.sort { $0.id < $1.id }
        ids = fixed.map(\.id)
        phases = fixed.map(\.phase)
    }

    /// orix's `PhaseList(names=..., point_groups=..., ids=...)` path: phases without a colour take Tableau colours in order.
    package init(ids: [Int], phases: [CrystalPhase], assignColors: Bool) {
        var list: [(id: Int, phase: CrystalPhase)] = []
        for (i, (id, phase)) in zip(ids, phases).enumerated() {
            var p = phase
            if assignColors { p.color = PhaseList.tableau[i % PhaseList.tableau.count] }
            list.append((id, p))
        }
        self.init(list)
    }

    /// orix's `PhaseList(ids=unique_phase_ids)`: unnamed phases (orix's `Phase()` has name ""), no symmetry, Tableau colours.
    package static func unnamed(ids: [Int]) -> PhaseList {
        PhaseList(ids: ids, phases: ids.map { _ in CrystalPhase(name: "") }, assignColors: true)
    }

    package var count: Int { ids.count }
    package var names: [String] { phases.map(\.name) }
    package var colors: [String] { phases.map(\.color) }
    package var pointGroupNames: [String?] { phases.map(\.pointGroupName) }
    package var entries: [(id: Int, phase: CrystalPhase)] { Array(zip(ids, phases)) }

    package subscript(id id: Int) -> CrystalPhase? {
        ids.firstIndex(of: id).map { phases[$0] }
    }

    /// `id_from_name`.
    package func id(named name: String) -> Int? {
        names.firstIndex(of: name).map { ids[$0] }
    }

    package func contains(id: Int) -> Bool { ids.contains(id) }

    /// `add_not_indexed`: the phase at id −1, named `not_indexed`, without point group, white.
    package mutating func addNotIndexed() {
        if let i = ids.firstIndex(of: PhaseList.notIndexedID) { phases[i] = .notIndexed; return }
        ids.insert(PhaseList.notIndexedID, at: 0)
        phases.insert(.notIndexed, at: 0)
    }

    /// Adds or replaces the phase at `id`, keeping ids ascending; a colour already used by another phase moves to the next free
    /// Tableau colour (orix's `add`).
    package mutating func set(_ phase: CrystalPhase, id: Int) {
        var p = phase
        let others = entries.filter { $0.id != id }.map(\.phase.color)
        if others.contains(p.color), let free = PhaseList.tableau.first(where: { !others.contains($0) }) { p.color = free }
        if let i = ids.firstIndex(of: id) { phases[i] = p; return }
        let at = ids.firstIndex { $0 > id } ?? ids.count
        ids.insert(id, at: at)
        phases.insert(p, at: at)
    }

    /// `__delitem__` by id.
    package mutating func remove(id: Int) {
        guard let i = ids.firstIndex(of: id) else { return }
        ids.remove(at: i)
        phases.remove(at: i)
    }

    /// The phases whose ids are in `keep`, in id order (orix's `phases[ids]`).
    package func restricted(to keep: Set<Int>) -> PhaseList {
        var out = self
        for id in ids where !keep.contains(id) { out.remove(id: id) }
        return out
    }
}
