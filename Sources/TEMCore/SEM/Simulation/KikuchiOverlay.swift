//
//  KikuchiOverlay.swift
//  Role: what the pattern pane's simulation overlay draws (docs/sem/design/simulation-overlay.md §2, §4): for the pattern at a scan
//        position, the geometrical Kikuchi simulation (`GeometricalKikuchiSimulation`) of the orientation the dataset's crystal map holds
//        there, seen from that position's projection centre, with the bands of the phase's families. Pure: the room's session asks it
//        and draws the answer.
//
//  The families (decision in docs/decisions.md): every plane with a spacing of at least `minDSpacing` Å (`KikuchiReflectors.minDSpacing`)
//  that the lattice centring allows, one plane per direction (the lowest order the centring allows: (222) is the same line as (111)),
//  grouped into the point group's families and ordered by spacing, largest first; then symmetrised as kikuchipy's tutorial does.
//  For the demo nickel at 1.0 Å these are kikuchipy's tutorial families {111}, {200}, {220} and {311} (figure F14). A lattice stated with
//  every edge under 2 is read as nm (orix and EMsoft files) and turned into Å for the bound; the geometry does not depend on the unit.
//  The lines end on the circle of the scan's largest r_max, as kikuchipy's whole-scan `on_detector` (the tutorial's figure).
//

import Foundation

package nonisolated enum KikuchiOverlay {
    /// What the overlay draws and with which bands.
    package struct Settings: Sendable, Hashable {
        /// The smallest interplanar spacing whose bands are drawn, Å.
        package var minDSpacing: Double
        package var zoneAxes: Bool
        package var labels: Bool

        package init(minDSpacing: Double = 1.0, zoneAxes: Bool = true, labels: Bool = true) {
            self.minDSpacing = minDSpacing; self.zoneAxes = zoneAxes; self.labels = labels
        }
    }

    /// A phase's bands for the overlay: the symmetrised reflectors and each family's label.
    package struct Bands: Sendable, Equatable {
        package var reflectors: KikuchiReflectors
        /// The family representatives, largest spacing first.
        package var families: [SIMD3<Int>]
        /// "{111}" per family.
        package var labels: [String]
    }

    /// Why a position has no overlay.
    package enum Absence: Error, Sendable, Equatable {
        /// The dataset has no crystal map.
        case noOrientations
        /// The point is not indexed (or not in the map's data).
        case notIndexed
        /// The point's phase has no usable lattice.
        case noLattice(phase: String)

        package var sentence: String {
            switch self {
            case .noOrientations: "No orientations in this dataset"
            case .notIndexed: "Not indexed"
            case .noLattice(let phase): "Phase \(phase) has no lattice parameters"
            }
        }
    }

    /// One position's overlay.
    package struct Pattern: Sendable, Equatable {
        package var phase: String
        package var simulation: GeometricalKikuchiSimulation
        /// The family label of each line, in `simulation.lines` order.
        package var lineLabels: [String]
    }

    // MARK: Bands

    /// The lattice of a phase in Å, in orix's frame; nil without six parameters.
    package static func lattice(of phase: CrystalPhase) -> CrystalLattice? {
        guard var p = phase.lattice, p.count == 6, p[0] > 0, p[1] > 0, p[2] > 0 else { return nil }
        if p[0] < 2, p[1] < 2, p[2] < 2 { p[0] *= 10; p[1] *= 10; p[2] *= 10 }
        return CrystalLattice(parameters: p)
    }

    /// The phase's point group: its own name, else its space group's, else the identity group.
    package static func pointGroup(of phase: CrystalPhase) -> PointGroup {
        if let group = phase.pointGroup { return group }
        if let sg = phase.spaceGroup, let entry = SpaceGroupPointGroup.pointGroup(ofSpaceGroup: sg), let group = PointGroup.named(entry.name) {
            return group
        }
        return .c1
    }

    /// The overlay's bands for `phase` down to `minDSpacing` Å (the rule in the file header); nil without a lattice.
    package static func bands(for phase: CrystalPhase, minDSpacing: Double) -> Bands? {
        guard let lattice = lattice(of: phase), minDSpacing > 0 else { return nil }
        let group = pointGroup(of: phase)
        let all = KikuchiReflectors.minDSpacing(minDSpacing, lattice: lattice)
        let allowed = phase.spaceGroup.flatMap(SpaceGroupCentering.letter).flatMap { all.allowed(centering: $0) }
        let allowedHKL = all.hkl.indices.filter { allowed?[$0] ?? true }.map { all.hkl[$0] }
        // One plane per direction: the lowest order allowed.
        var lowest: [SIMD3<Int>: SIMD3<Int>] = [:]
        for v in allowedHKL {
            let h = SIMD3(Int(v.x), Int(v.y), Int(v.z))
            let g = gcd(gcd(abs(h.x), abs(h.y)), abs(h.z))
            let direction = h / g
            if let kept = lowest[direction] {
                if gcd(gcd(abs(kept.x), abs(kept.y)), abs(kept.z)) > g { lowest[direction] = h }
            } else {
                lowest[direction] = h
            }
        }
        let planes = Set(lowest.values)
        // Group into families by the point group; the representative is the member with the largest (h, k, l).
        var assigned = Set<SIMD3<Int>>()
        var families: [(rep: SIMD3<Int>, d: Double)] = []
        for h in planes.sorted(by: { ($0.x, $0.y, $0.z) > ($1.x, $1.y, $1.z) }) where !assigned.contains(h) {
            let members = KikuchiReflectors.symmetrised([SIMD3(Double(h.x), Double(h.y), Double(h.z))], lattice: lattice, pointGroup: group)
                .reflectors.hkl.map { SIMD3(Int($0.x.rounded()), Int($0.y.rounded()), Int($0.z.rounded())) }
            let present = members.filter { planes.contains($0) }
            assigned.formUnion(present)
            assigned.insert(h)
            let rep = (present + [h]).max { ($0.x, $0.y, $0.z) < ($1.x, $1.y, $1.z) }!
            families.append((rep, lattice.dSpacing(SIMD3(Double(rep.x), Double(rep.y), Double(rep.z)))))
        }
        families.sort { $0.d != $1.d ? $0.d > $1.d : ($0.rep.x, $0.rep.y, $0.rep.z) > ($1.rep.x, $1.rep.y, $1.rep.z) }
        let reps = families.map(\.rep)
        let reflectors = KikuchiReflectors.symmetrised(reps.map { SIMD3(Double($0.x), Double($0.y), Double($0.z)) }, lattice: lattice, pointGroup: group).reflectors
        return Bands(reflectors: reflectors, families: reps, labels: reps.map { millerText($0, brackets: "{}") })
    }

    /// The bands of explicit families (kikuchipy's tutorial: `ReciprocalLatticeVector(phase, hkl=families).symmetrise()`).
    package static func bands(for phase: CrystalPhase, families: [SIMD3<Int>]) -> Bands? {
        guard let lattice = lattice(of: phase) else { return nil }
        let reflectors = KikuchiReflectors.symmetrised(families.map { SIMD3(Double($0.x), Double($0.y), Double($0.z)) }, lattice: lattice,
                                                       pointGroup: pointGroup(of: phase)).reflectors
        return Bands(reflectors: reflectors, families: families, labels: families.map { millerText($0, brackets: "{}") })
    }

    // MARK: One position

    /// The largest r_max over the dataset's projection centres (the circle every line ends on).
    package static func scanMaxR(_ dataset: EBSDDataset) -> Double {
        let detector = dataset.detector
        return detector.projectionCenters.map { detector.rMax($0) }.max() ?? 0
    }

    /// The projection centre at `position` (the dataset's one, or its own when the file stores one per pattern).
    package static func projectionCenter(_ dataset: EBSDDataset, at position: EBSDPosition) -> SIMD3<Double>? {
        let pcs = dataset.detector.projectionCenters
        guard !pcs.isEmpty else { return nil }
        let index = position.index(columns: dataset.scanColumns)
        return pcs.count == dataset.patternCount && pcs.indices.contains(index) ? pcs[index] : pcs[0]
    }

    /// The overlay at `position`, or why there is none. `bands` maps a phase id to its bands (the session caches them per phase).
    package static func pattern(_ dataset: EBSDDataset, at position: EBSDPosition, maxR: Double,
                                bands: (Int, CrystalPhase) -> Bands?) -> Result<Pattern, Absence> {
        guard let map = dataset.crystalMap, let pc = projectionCenter(dataset, at: position) else { return .failure(.noOrientations) }
        let index = position.index(columns: dataset.scanColumns)
        guard map.rotations.indices.contains(index), map.isInData[index] else { return .failure(.notIndexed) }
        let id = map.allPhaseIDs[index]
        guard id != PhaseList.notIndexedID, let phase = map.phases[id: id] else { return .failure(.notIndexed) }
        guard let b = bands(id, phase) else { return .failure(.noLattice(phase: phase.name)) }
        let simulation = GeometricalKikuchiSimulation.simulate(reflectors: b.reflectors, rotation: map.rotations[index],
                                                               detector: dataset.detector, pc: pc, maxRGnomonic: maxR)
        let labels = simulation.lines.map { b.labels[b.reflectors.family[$0.reflector]] }
        return .success(Pattern(phase: phase.name, simulation: simulation, lineLabels: labels))
    }

    // MARK: Text

    /// Miller indices as a crystallographer writes them: a negative index with a bar over it (a combining overline after each digit),
    /// inside `brackets` ("[]" for a direction, "{}" for a family): [1̄21], {311}.
    package static func millerText(_ v: SIMD3<Int>, brackets: String) -> String {
        let pair = Array(brackets)
        var body = ""
        for i in [v.x, v.y, v.z] {
            guard i < 0 else { body += String(i); continue }
            for digit in String(-i) { body.append(digit); body.append("\u{0305}") }
        }
        return pair.count == 2 ? "\(pair[0])\(body)\(pair[1])" : body
    }

    private static func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? max(a, 1) : gcd(b, a % b) }
}
