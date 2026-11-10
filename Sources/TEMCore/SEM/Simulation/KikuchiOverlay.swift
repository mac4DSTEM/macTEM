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
        /// Draw each band's two edges at the Bragg angle for the file's beam energy (the design's `Band width`).
        package var bandWidth: Bool
        /// Draw the kinematical simulation of the pattern (the master pattern of the bands put on the detector) under the lines.
        package var kinematical: Bool
        /// The simulated pattern's opacity over the experimental one, 0 to 1 (the design's `Blend`).
        package var blend: Double

        package init(minDSpacing: Double = 1.0, zoneAxes: Bool = true, labels: Bool = true, bandWidth: Bool = false, kinematical: Bool = false,
                     blend: Double = 0.5) {
            self.minDSpacing = minDSpacing; self.zoneAxes = zoneAxes; self.labels = labels; self.bandWidth = bandWidth
            self.kinematical = kinematical; self.blend = blend
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
        /// The family representative of each line, in `simulation.lines` order.
        package var lineFamilies: [SIMD3<Int>] = []
        /// The Bragg angle of each line (radians) when the band edges were asked for and the file states its beam energy.
        package var lineTheta: [Double]? = nil
        /// The kinematical simulation of this pattern, row-major in the detector's shape (band counts, kikuchipy's `get_patterns` of
        /// the kinematical master pattern in float32), when it was asked for.
        package var simulated: [Float]? = nil
        /// The simulated pattern's shape (the detector's), 0 without one.
        package var simulatedRows = 0
        package var simulatedColumns = 0

        /// What it draws, counted (`drawnWords(bands:zoneAxes:)`): the Simulation sections' summaries and the exported figure's
        /// Description say it in these words.
        package var drawnWords: String { KikuchiOverlay.drawnWords(bands: simulation.lines.count, zoneAxes: simulation.zoneAxes.count) }
    }

    /// An overlay's bands and zone axes, counted, one in the singular: "12 bands, 4 zone axes", "1 band, 1 zone axis".
    package static func drawnWords(bands: Int, zoneAxes: Int) -> String {
        UnitDisplay.count(bands, "band", "bands") + ", " + UnitDisplay.count(zoneAxes, "zone axis", "zone axes")
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

    /// The Bragg angle of each of `bands`' reflectors at `beamEnergyKeV`: θ = arcsin(λ |g| / 2) with the relativistic wavelength
    /// (`KikuchiWavelength.refractionCorrected` without the mean inner potential: a file's phase carries no atoms the app reads, and
    /// the potential moves θ by 0.07 % at 20 kV, decision D-SEM-94).
    package static func braggAngles(_ bands: Bands, beamEnergyKeV: Double) -> [Double] {
        let lambda = KikuchiWavelength.refractionCorrected(voltage: 1000 * beamEnergyKeV, orbit: [], cellVolume: bands.reflectors.lattice.volume)
        return bands.reflectors.braggAngles(wavelengthNM: lambda)
    }

    /// The kinematical master pattern of a phase's overlay bands (decision D-SEM-95): kikuchipy's band rule on the square Lambert grid
    /// (`KinematicMasterPattern.lambert`), every band intensity 1 (a file's phase carries no atoms for |F|), θ at `beamEnergyKeV`.
    package static func masterPattern(_ bands: Bands, phase: CrystalPhase, beamEnergyKeV: Double, halfSize: Int = 200) -> EBSDMasterPattern {
        KinematicMasterPattern.lambert(reflectors: bands.reflectors, theta: braggAngles(bands, beamEnergyKeV: beamEnergyKeV), halfSize: halfSize,
                                       scaling: .none, energyKeV: beamEnergyKeV, phase: phase)
    }

    /// The kinematical master pattern's picture: the upper hemisphere in the stereographic projection (kikuchipy's
    /// `calculate_master_pattern`, every band intensity 1), row-major `(2 halfSize + 1)²`.
    package static func masterPatternPicture(_ bands: Bands, beamEnergyKeV: Double, halfSize: Int = 100) -> [Double] {
        KinematicMasterPattern.calculate(reflectors: bands.reflectors, theta: braggAngles(bands, beamEnergyKeV: beamEnergyKeV), structureFactor: [],
                                         halfSize: halfSize, hemisphere: .upper, scaling: .none)[0]
    }

    /// `masterPattern` and, with `picture`, `masterPatternPicture` of the same bands, off the caller's actor: the overlay's
    /// kinematical simulation is made once per phase and spacing, and the 401 × 401 Lambert grid of every band would stall the pane
    /// that asked for it. The numbers are those two functions'.
    @concurrent package static func kinematicalMaster(_ bands: Bands, phase: CrystalPhase, beamEnergyKeV: Double,
                                                      picture: Bool) async -> (master: EBSDMasterPattern, picture: [Double]?) {
        let master = masterPattern(bands, phase: phase, beamEnergyKeV: beamEnergyKeV)
        let stereographic: [Double]? = picture ? masterPatternPicture(bands, beamEnergyKeV: beamEnergyKeV) : nil
        return (master: master, picture: stereographic)
    }

    /// The overlay at `position`, or why there is none. `bands` maps a phase id to its bands (the session caches them per phase).
    /// With `beamEnergyKeV` each line carries its band's two edges. With `master` (a phase id, the phase and its bands to the phase's
    /// kinematical master pattern), the pattern carries its kinematical simulation for the point's orientation and projection centre.
    package static func pattern(_ dataset: EBSDDataset, at position: EBSDPosition, maxR: Double, beamEnergyKeV: Double? = nil,
                                master: ((Int, CrystalPhase, Bands) -> EBSDMasterPattern?)? = nil,
                                bands: (Int, CrystalPhase) -> Bands?) -> Result<Pattern, Absence> {
        guard let map = dataset.crystalMap, let pc = projectionCenter(dataset, at: position) else { return .failure(.noOrientations) }
        let index = position.index(columns: dataset.scanColumns)
        guard map.rotations.indices.contains(index), map.isInData[index] else { return .failure(.notIndexed) }
        let id = map.allPhaseIDs[index]
        guard id != PhaseList.notIndexedID, let phase = map.phases[id: id] else { return .failure(.notIndexed) }
        guard let b = bands(id, phase) else { return .failure(.noLattice(phase: phase.name)) }
        return .success(pattern(phase: phase.name, rotation: map.rotations[index], bands: b, detector: dataset.detector, pc: pc, maxR: maxR,
                                beamEnergyKeV: beamEnergyKeV, master: master?(id, phase, b)))
    }

    /// The overlay of one orientation: `bands` of the phase named `phase` at `rotation` (orix's, crystal to sample) on `detector` with
    /// projection centre `pc`, the lines ending on the circle of `maxR`. With `beamEnergyKeV` each line carries its band's two edges;
    /// with `master` the pattern carries its kinematical simulation on `detector`'s rows and columns. The Patterns room's overlay (a
    /// file's orientation) and the Indexing room's (a run's solution) both come through here.
    package static func pattern(phase: String, rotation: SIMD4<Double>, bands b: Bands, detector: EBSDDetectorGeometry, pc: SIMD3<Double>,
                                maxR: Double, beamEnergyKeV: Double? = nil, master: EBSDMasterPattern? = nil) -> Pattern {
        let theta = beamEnergyKeV.flatMap { $0 > 0 ? braggAngles(b, beamEnergyKeV: $0) : nil }
        let simulation = GeometricalKikuchiSimulation.simulate(reflectors: b.reflectors, rotation: rotation, detector: detector, pc: pc,
                                                               maxRGnomonic: maxR, braggAngles: theta)
        let labels = simulation.lines.map { b.labels[b.reflectors.family[$0.reflector]] }
        let families = simulation.lines.map { b.families[b.reflectors.family[$0.reflector]] }
        var simulated: [Float]?
        if let master {
            var one = detector
            one.projectionCenters = [pc]
            simulated = (try? MasterPatternProjection.project(master: master, rotations: [rotation], detector: one, output: .float32))
                .map { $0.values.map { Float($0) } }
        }
        return Pattern(phase: phase, simulation: simulation, lineLabels: labels, lineFamilies: families,
                       lineTheta: theta.map { t in simulation.lines.map { t[$0.reflector] } }, simulated: simulated,
                       simulatedRows: simulated == nil ? 0 : detector.rows, simulatedColumns: simulated == nil ? 0 : detector.columns)
    }

    // MARK: Export

    /// The overlay as CSV (simulation-overlay.md §4, `Overlay CSV`): one row per band line, then one per zone axis, in detector pixels
    /// (x right, y down, pixel centres at integers as kikuchipy's on_detector). Columns: feature (`band` or `zone_axis`), the
    /// indices (h, k, l or u, v, w), the family or the direction with its signs written out ({-111}, [-101]), the line's
    /// ends x1, y1, x2, y2 on the r_max circle (a zone axis fills x1, y1), and θ in radians when the band edges were computed.
    /// Numbers in their shortest round-trip form, POSIX.
    package static func csv(_ pattern: Pattern) -> String {
        func n(_ x: Double) -> String { x.isFinite ? "\(x)" : "" }
        func i(_ x: Double) -> String { "\(Int(x.rounded()))" }
        var rows = ["feature,h_or_u,k_or_v,l_or_w,label,x1_px,y1_px,x2_px,y2_px,theta_rad"]
        for (k, line) in pattern.simulation.lines.enumerated() {
            let theta = pattern.lineTheta.map { n($0[k]) } ?? ""
            let label = pattern.lineFamilies.indices.contains(k) ? plainMiller(pattern.lineFamilies[k], brackets: "{}") : ""
            rows.append(["band", i(line.hkl.x), i(line.hkl.y), i(line.hkl.z), label,
                         n(line.pixel[0]), n(line.pixel[1]), n(line.pixel[2]), n(line.pixel[3]), theta].joined(separator: ","))
        }
        for axis in pattern.simulation.zoneAxes {
            rows.append(["zone_axis", "\(axis.uvw.x)", "\(axis.uvw.y)", "\(axis.uvw.z)",
                         plainMiller(axis.uvw, brackets: "[]"),
                         n(axis.pixel.x), n(axis.pixel.y), "", "", ""].joined(separator: ","))
        }
        return rows.joined(separator: "\n") + "\n"
    }

    /// Miller indices for a CSV read by other programs: the signs written out, "{-111}", "[-1-21]".
    package static func plainMiller(_ v: SIMD3<Int>, brackets: String) -> String {
        let pair = Array(brackets)
        return "\(pair[0])\(v.x)\(v.y)\(v.z)\(pair[1])"
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
