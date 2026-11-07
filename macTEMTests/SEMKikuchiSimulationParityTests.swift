//
//  SEMKikuchiSimulationParityTests.swift
//  TEMCore's Kikuchi simulation (`CrystalLattice`, `KikuchiReflectors`, `KikuchiWavelength`, `GeometricalKikuchiSimulation`,
//  `KinematicMasterPattern`, `KikuchiOverlay`) against diffpy.structure, diffsims 0.7.0 and kikuchipy 0.13.1: the bundles
//  `m6/kikuchi-lattice`, `m6/kikuchi-scattering-tables`, `m6/kikuchi-reflectors-{ni,ti,al2cu}`, `m6/geometrical-simulation-nickel`
//  (figure F14), `m6/geometrical-band-edges-nickel`, `m6/geometrical-simulation-tilted`, `m6/kinematic-master-pattern-ni` and
//  `m6/kinematic-overlay-nickel` from tools/parity/sem/simulation_cases.py, at each bundle's tolerance (docs/parity.md). Red before
//  the port: none of the types exists. Red after the lattice left in diffpy's frame (the hexagonal zone axes move), a reflector counted with z ≤ 0 (every band twice), the sample-to-detector matrix not transposed
//  (the lines turn), zone axes not reduced by orix's rounding (labels and positions change), or a band edge at π/2 + θ: each moves
//  coordinates far beyond 1e-6 px or the master pattern beyond rtol 1e-5.
//

import Foundation
import TEMCore
import XCTest

nonisolated final class SEMKikuchiSimulationParityTests: XCTestCase {

    private static let demoScan = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("DemoData/nickel_ebsd_large/patterns_v2.h5")

    /// simulation_cases.json's phases and detector, as the bundles were emitted from them.
    private struct Cases: Decodable {
        struct Phase: Decodable {
            let space_group: Int
            let lattice: [Double]
        }
        struct Detector: Decodable {
            let shape: [Int]
            let px_size: Double
            let binning: Int
            let sample_tilt: Double, tilt: Double, azimuthal: Double, twist: Double
            let pc: [[Double]]
        }
        let phases: [String: Phase]
        let tilted_detector: Detector
    }

    private func cases() throws -> Cases {
        let ref = try SEMParityReference.load("m6/geometrical-simulation-tilted")
        let url = try XCTUnwrap(ref.inputURL())
        return try JSONDecoder().decode(Cases.self, from: Data(contentsOf: url))
    }

    private func triples(_ values: [Double]) -> [SIMD3<Double>] {
        stride(from: 0, to: values.count, by: 3).map { SIMD3(values[$0], values[$0 + 1], values[$0 + 2]) }
    }

    private func quads(_ values: [Double]) -> [SIMD4<Double>] {
        stride(from: 0, to: values.count, by: 4).map { SIMD4(values[$0], values[$0 + 1], values[$0 + 2], values[$0 + 3]) }
    }

    /// diffpy's frame, as the lattice bundle stores it; `.orixAligned` is the frame the simulations work in.
    private func lattice(_ p: [Double]) throws -> CrystalLattice { try XCTUnwrap(CrystalLattice.diffpy(parameters: p)) }

    private func ints(_ v: [SIMD3<Double>]) -> [Double] { v.flatMap { [$0.x.rounded(), $0.y.rounded(), $0.z.rounded()] } }

    // MARK: - Lattice and tables

    func testLatticeBasesAsDiffpyAndOrix() throws {
        let ref = try SEMParityReference.load("m6/kikuchi-lattice")
        let lattices = try XCTUnwrap(ref.values["lattices"] as? [[Double]])
        let hkl = try XCTUnwrap(ref.values["hkl"] as? [[Double]]).map { SIMD3($0[0], $0[1], $0[2]) }
        var base: [Double] = [], rec: [Double] = [], obase: [Double] = [], orec: [Double] = [], volume: [Double] = [], rnorm: [Double] = []
        for p in lattices {
            let l = try lattice(p)
            base += l.base.flatMap { [$0.x, $0.y, $0.z] }
            rec += l.recbase.flatMap { [$0.x, $0.y, $0.z] }
            let o = l.orixAligned
            let closed = try XCTUnwrap(CrystalLattice(parameters: p))
            for (x, y) in zip(closed.base, o.base) {
                for k in 0..<3 { XCTAssertEqual(x[k], y[k], accuracy: 1e-12, "orix's closed-form base is diffpy's re-aligned one, \(p)") }
            }
            obase += o.base.flatMap { [$0.x, $0.y, $0.z] }
            orec += o.recbase.flatMap { [$0.x, $0.y, $0.z] }
            volume.append(l.volume)
            rnorm += hkl.map { l.rnorm($0) }
        }
        SEMAssertParity(base, try ref.array("base"))
        SEMAssertParity(rec, try ref.array("recbase"))
        SEMAssertParity(obase, try ref.array("orix_base"))
        SEMAssertParity(orec, try ref.array("orix_recbase"))
        SEMAssertParity(volume, try ref.array("volume"))
        SEMAssertParity(rnorm, try ref.array("rnorm"))
        XCTAssertEqual(CrystalLattice.cosd(-90), 0, "diffpy takes the angle modulo 360 before its exact table")
    }

    func testScatteringTablesAreDiffsims() throws {
        let ref = try SEMParityReference.load("m6/kikuchi-scattering-tables")
        XCTAssertEqual(KikuchiScatteringTables.xraySymbols, try XCTUnwrap(ref.values["xray_symbols"] as? [String]))
        XCTAssertEqual(KikuchiScatteringTables.doyleTurnerElements, try XCTUnwrap(ref.values["doyle_turner_elements"] as? [String]))
        SEMAssertParity(KikuchiScatteringTables.xray.flatMap { $0 }, try ref.array("xray"))
        SEMAssertParity(KikuchiScatteringTables.doyleTurner.flatMap { $0 }, try ref.array("doyle_turner"))
        let constants = try XCTUnwrap(ref.values["constants"] as? [String: Double])
        XCTAssertEqual(KikuchiWavelength.c, constants["c"])
        XCTAssertEqual(KikuchiWavelength.e, constants["e"])
        XCTAssertEqual(KikuchiWavelength.h, constants["h"])
        XCTAssertEqual(KikuchiWavelength.electronMass, constants["m_e"])
    }

    // MARK: - Reflectors

    private func assertReflectors(_ name: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let ref = try SEMParityReference.load("m6/kikuchi-reflectors-\(name)")
        let l = try lattice(try XCTUnwrap(ref.values["lattice"] as? [Double])).orixAligned
        let group = try XCTUnwrap(PointGroup.named(try XCTUnwrap(ref.values["point_group"] as? String)))
        let families = try XCTUnwrap(ref.values["families"] as? [[Double]]).map { SIMD3($0[0], $0[1], $0[2]) }
        let (reflectors, multiplicity) = KikuchiReflectors.symmetrised(families, lattice: l, pointGroup: group)
        SEMAssertParity(ints(reflectors.hkl), try ref.array("symmetrised_hkl"), file: file, line: line)
        SEMAssertParity(reflectors.hkl.flatMap { [$0.x, $0.y, $0.z] }, try ref.array("symmetrised_hkl_float"), file: file, line: line)
        SEMAssertParity(multiplicity.map(Double.init), try ref.array("multiplicity"), file: file, line: line)
        SEMAssertParity(reflectors.dSpacing, try ref.array("dspacing"), file: file, line: line)

        let minD = try XCTUnwrap(ref.values["min_dspacing"] as? Double)
        let all = KikuchiReflectors.minDSpacing(minD, lattice: l)
        SEMAssertParity(ints(all.hkl), try ref.array("min_dspacing_hkl"), file: file, line: line)
        let centering = try XCTUnwrap((ref.values["centering"] as? String)?.first)
        XCTAssertEqual(SpaceGroupCentering.letter(try XCTUnwrap(ref.values["space_group"] as? Int)), centering, file: file, line: line)
        if ref.manifest.arrays["min_dspacing_allowed"] != nil {
            let allowed = try XCTUnwrap(all.allowed(centering: centering), file: file, line: line)
            SEMAssertParity(allowed.map { $0 ? 1 : 0 }, try ref.array("min_dspacing_allowed"), file: file, line: line)
        } else {
            XCTAssertNil(all.allowed(centering: centering), "diffsims raises for a primitive hexagonal lattice", file: file, line: line)
        }

        // |F| on the expanded cell, the wavelength and the Bragg angles at each voltage.
        let cellRows = try XCTUnwrap(ref.values["cell_atoms"] as? [[Any]])
        let symbols = KikuchiScatteringTables.xraySymbols
        let cell: [KikuchiAtom] = try cellRows.map { row in
            let symbol = try XCTUnwrap(row[0] as? String), xyz = try XCTUnwrap(row[1] as? [Double]), occ = try XCTUnwrap(row[2] as? Double)
            let z = try XCTUnwrap(symbols.firstIndex(of: symbol)) + 1
            return KikuchiAtom(z: z, position: SIMD3(xyz[0], xyz[1], xyz[2]), occupancy: occ)
        }
        SEMAssertParity(reflectors.structureFactors(cell: cell), try ref.array("structure_factor_abs"), file: file, line: line)
        let orbitSize = try XCTUnwrap(ref.values["first_orbit_size"] as? Int)
        let orbitZ = try XCTUnwrap(symbols.firstIndex(of: try XCTUnwrap(ref.values["first_orbit_element"] as? String))) + 1
        let orbit = Array(repeating: KikuchiAtom(z: orbitZ, position: .zero), count: orbitSize)
        let voltages = try XCTUnwrap(ref.values["voltages"] as? [Double])
        let lambdas = voltages.map { KikuchiWavelength.refractionCorrected(voltage: $0, orbit: orbit, cellVolume: l.volume) }
        SEMAssertParity(lambdas, try ref.array("wavelength_nm"), file: file, line: line)
        SEMAssertParity(lambdas.flatMap { reflectors.braggAngles(wavelengthNM: $0) }, try ref.array("theta"), file: file, line: line)
    }

    func testNickelReflectorsAsDiffsims() throws { try assertReflectors("ni") }
    func testTitaniumReflectorsAsDiffsims() throws { try assertReflectors("ti") }
    func testAl2CuReflectorsAsDiffsims() throws { try assertReflectors("al2cu") }

    // MARK: - Geometrical simulation

    private func assertSimulation(_ sim: GeometricalKikuchiSimulation, _ ref: SEMParityReference, prefix: String,
                                  file: StaticString = #filePath, line: UInt = #line) throws {
        let hkl = try ref.array(prefix + "lines_hkl")
        SEMAssertParity(ints(sim.lines.map(\.hkl)), hkl, shape: hkl.shape, file: file, line: line)
        guard sim.lines.count == hkl.shape[0] else { return }
        SEMAssertParity(sim.lines.flatMap { [$0.pixel[0], $0.pixel[1], $0.pixel[2], $0.pixel[3]] }, try ref.array(prefix + "lines_px"), file: file, line: line)
        SEMAssertParity(sim.lines.flatMap { [$0.gnomonic[0], $0.gnomonic[1], $0.gnomonic[2], $0.gnomonic[3]] }, try ref.array(prefix + "lines_gnomonic"),
                        file: file, line: line)
        let uvw = try ref.array(prefix + "zone_axes_uvw")
        SEMAssertParity(sim.zoneAxes.flatMap { [Double($0.uvw.x), Double($0.uvw.y), Double($0.uvw.z)] }, uvw, shape: uvw.shape, file: file, line: line)
        guard sim.zoneAxes.count == uvw.shape[0] else { return }
        SEMAssertParity(sim.zoneAxes.flatMap { [$0.pixel.x, $0.pixel.y] }, try ref.array(prefix + "zone_axes_px"), file: file, line: line)
        SEMAssertParity(sim.zoneAxes.flatMap { [$0.gnomonic.x, $0.gnomonic.y] }, try ref.array(prefix + "zone_axes_gnomonic"), file: file, line: line)
        XCTAssertEqual(sim.zoneAxes.map(\.label), ref.values[prefix + "zone_axes_labels"] as? [String], file: file, line: line)
    }

    /// Figure F14: the {111}, {200}, {220} and {311} bands and their zone axes on nickel_ebsd_large at (0, 0) and three more points.
    func testFigureF14GeometricalSimulationOfTheNickelAsKikuchipy() throws {
        let ref = try SEMParityReference.load("m6/geometrical-simulation-nickel")
        let l = try lattice(try XCTUnwrap(ref.values["lattice"] as? [Double])).orixAligned
        let reflectors = KikuchiReflectors(lattice: l, hkl: triples(try ref.array("reflectors_hkl").values))
        let d = try XCTUnwrap(ref.values["detector"] as? [String: Any])
        let shape = try XCTUnwrap(d["shape"] as? [Int])
        let detector = EBSDDetectorGeometry(rows: shape[0], columns: shape[1], pixelSize: try XCTUnwrap(d["px_size"] as? Double),
                                            binning: try XCTUnwrap(d["binning"] as? Int), tilt: try XCTUnwrap(d["tilt"] as? Double),
                                            azimuthal: try XCTUnwrap(d["azimuthal"] as? Double), twist: try XCTUnwrap(d["twist"] as? Double),
                                            sampleTilt: try XCTUnwrap(d["sample_tilt"] as? Double), projectionCenters: [])
        let points = try XCTUnwrap(ref.values["points"] as? [[Int]])
        let rotations = quads(try ref.array("rotations").values), pcs = triples(try ref.array("pcs").values)
        let maxR = try XCTUnwrap(ref.manifest.scalars["max_r_gnomonic"]?.value)
        for (i, p) in points.enumerated() {
            let sim = GeometricalKikuchiSimulation.simulate(reflectors: reflectors, rotation: rotations[i], detector: detector, pc: pcs[i], maxRGnomonic: maxR)
            try assertSimulation(sim, ref, prefix: "p\(p[0])_\(p[1])_")
            if i == 0 {
                // The figure script's "ours" (tools/parity/sem/simulation_figure.py --ours): the lines and zone axes in pixels.
                let lines = sim.lines.flatMap { [$0.pixel[0], $0.pixel[1], $0.pixel[2], $0.pixel[3]] }
                let axes = sim.zoneAxes.flatMap { [$0.pixel.x, $0.pixel.y] }
                print("F14 ours lines float64 base64:", lines.withUnsafeBytes { Data($0).base64EncodedString() })
                print("F14 ours zone axes float64 base64:", axes.withUnsafeBytes { Data($0).base64EncodedString() })
            }
        }
    }

    /// The whole path the pattern pane takes: the demo file opened, its crystal map, PCs and phase, the overlay's own families at 1 Å,
    /// the scan's r_max: pattern (0, 0) is F14.
    func testOverlayOnTheDemoNickelIsFigureF14() throws {
        let ref = try SEMParityReference.load("m6/geometrical-simulation-nickel")
        let (dataset, _) = try EBSDOpening.open(url: Self.demoScan)
        let map = try XCTUnwrap(dataset.crystalMap)
        let phase = try XCTUnwrap(map.phases[id: map.allPhaseIDs[0]])
        let bands = try XCTUnwrap(KikuchiOverlay.bands(for: phase, minDSpacing: 1.0))
        XCTAssertEqual(bands.families, [SIMD3(1, 1, 1), SIMD3(2, 0, 0), SIMD3(2, 2, 0), SIMD3(3, 1, 1)], "kikuchipy's tutorial families")
        XCTAssertEqual(bands.labels, ["{111}", "{200}", "{220}", "{311}"])
        SEMAssertParity(ints(bands.reflectors.hkl), try ref.array("reflectors_hkl"))
        let maxR = KikuchiOverlay.scanMaxR(dataset)
        SEMAssertParity(maxR, ref, scalar: "max_r_gnomonic")
        for p in try XCTUnwrap(ref.values["points"] as? [[Int]]) {
            let result = KikuchiOverlay.pattern(dataset, at: EBSDPosition(row: p[0], column: p[1]), maxR: maxR) { _, _ in bands }
            guard case .success(let overlay) = result else { return XCTFail("no overlay at \(p): \(result)") }
            XCTAssertEqual(overlay.phase, "ni")
            try assertSimulation(overlay.simulation, ref, prefix: "p\(p[0])_\(p[1])_")
            XCTAssertEqual(overlay.lineLabels.count, overlay.simulation.lines.count)
        }
    }

    /// The band edges (#201): each F14 line's two small circles at π/2 ∓ θ about its reflector, as kikuchipy's `plot(mode="bands")`
    /// draws them (orix's `get_circle`, 360 steps), put on the detector of pattern (0, 0) with diffsims' θ at the file's 20 kV.
    /// Red before: the simulation has no edges (and no `braggAngles`); red with the edge at π/2 ± θ swapped, θ in degrees, or a
    /// circle about the crystal-frame g instead of the detector-frame one.
    func testBandEdgesAsKikuchipyBands() throws {
        let ref = try SEMParityReference.load("m6/geometrical-band-edges-nickel")
        let nickel = try SEMParityReference.load("m6/geometrical-simulation-nickel")
        var p = try XCTUnwrap(nickel.values["lattice"] as? [Double])
        p[0] *= 10; p[1] *= 10; p[2] *= 10   // the overlay's lattice is in Å (KikuchiOverlay.lattice), as the bundle's θ
        let reflectors = KikuchiReflectors(lattice: try XCTUnwrap(CrystalLattice(parameters: p)), hkl: triples(try nickel.array("reflectors_hkl").values))
        let d = try XCTUnwrap(nickel.values["detector"] as? [String: Any])
        let shape = try XCTUnwrap(d["shape"] as? [Int])
        let detector = EBSDDetectorGeometry(rows: shape[0], columns: shape[1], pixelSize: try XCTUnwrap(d["px_size"] as? Double),
                                            binning: try XCTUnwrap(d["binning"] as? Int), tilt: try XCTUnwrap(d["tilt"] as? Double),
                                            azimuthal: try XCTUnwrap(d["azimuthal"] as? Double), twist: try XCTUnwrap(d["twist"] as? Double),
                                            sampleTilt: try XCTUnwrap(d["sample_tilt"] as? Double), projectionCenters: [])
        let rotation = quads(try nickel.array("rotations").values)[0], pc = triples(try nickel.array("pcs").values)[0]
        let maxR = try XCTUnwrap(ref.manifest.scalars["max_r_gnomonic"]?.value)
        let steps = try XCTUnwrap(ref.values["steps"] as? Int)
        let bare = GeometricalKikuchiSimulation.simulate(reflectors: reflectors, rotation: rotation, detector: detector, pc: pc, maxRGnomonic: maxR)
        let hkl = try ref.array("lines_hkl")
        SEMAssertParity(ints(bare.lines.map(\.hkl)), hkl, shape: hkl.shape)
        XCTAssertTrue(bare.lines.allSatisfy(\.edges.isEmpty), "no edges without Bragg angles")
        SEMAssertParity(bare.lines.flatMap { [$0.detector.x, $0.detector.y, $0.detector.z] }, try ref.array("vector_detector"))
        // The bundle's θ for each line's reflector; the rest get none drawn (they make no line).
        let lineTheta = try ref.array("theta").values
        var theta = [Double](repeating: 0, count: reflectors.count)
        for (k, line) in bare.lines.enumerated() where k < lineTheta.count { theta[line.reflector] = lineTheta[k] }
        let sim = GeometricalKikuchiSimulation.simulate(reflectors: reflectors, rotation: rotation, detector: detector, pc: pc, maxRGnomonic: maxR,
                                                        braggAngles: theta, edgeSteps: steps)
        XCTAssertEqual(sim.lines.map(\.hkl), bare.lines.map(\.hkl), "the edges do not change which lines are drawn")
        XCTAssertEqual(sim.lines.map(\.pixel), bare.lines.map(\.pixel))
        XCTAssertTrue(sim.lines.allSatisfy { $0.edges.count == 2 && $0.edges.allSatisfy { $0.pixel.count == steps } })
        // The bundle holds no NaN: kikuchipy's masked points are 0 there and 0 in `edges_visible`.
        let points = sim.lines.flatMap { $0.edges.flatMap(\.gnomonic) }
        SEMAssertParity(points.map { (p: SIMD2<Double>) -> Double in p.x.isNaN ? 0 : 1 }, try ref.array("edges_visible"))
        func unmasked(_ p: [SIMD2<Double>]) -> [Double] { p.flatMap { $0.x.isNaN ? [0, 0] : [$0.x, $0.y] } }
        SEMAssertParity(unmasked(points), try ref.array("edges_gnomonic"))
        SEMAssertParity(unmasked(sim.lines.flatMap { $0.edges.flatMap(\.pixel) }), try ref.array("edges_px"))
        // Every band shows at least one arc beside its centre line (an edge can fall wholly outside r_max).
        for line in sim.lines {
            XCTAssertTrue(line.edges.contains { !$0.pixelRuns.isEmpty }, "\(line.hkl) has no visible edge")
        }
    }

    /// The overlay's own θ (the relativistic wavelength at the file's beam energy, no mean inner potential: decision D-SEM-94) is
    /// diffsims' within 0.1 %, and the demo nickel's overlay draws every band with its two edges when it is asked for.
    func testOverlayBandEdgesOnTheDemoNickel() throws {
        let ref = try SEMParityReference.load("m6/geometrical-band-edges-nickel")
        let (dataset, _) = try EBSDOpening.open(url: Self.demoScan)
        XCTAssertEqual(dataset.sem.beamEnergyKeV, try XCTUnwrap(ref.values["beam_energy_kev"] as? Double))
        let map = try XCTUnwrap(dataset.crystalMap)
        let phase = try XCTUnwrap(map.phases[id: map.allPhaseIDs[0]])
        let bands = try XCTUnwrap(KikuchiOverlay.bands(for: phase, minDSpacing: 1.0))
        let maxR = KikuchiOverlay.scanMaxR(dataset)
        let result = KikuchiOverlay.pattern(dataset, at: .origin, maxR: maxR, beamEnergyKeV: dataset.sem.beamEnergyKeV) { _, _ in bands }
        guard case .success(let overlay) = result else { return XCTFail("no overlay: \(result)") }
        let theta = try XCTUnwrap(overlay.lineTheta)
        let reference = try ref.array("theta").values
        XCTAssertEqual(theta.count, reference.count)
        for (ours, theirs) in zip(theta, reference) {
            XCTAssertEqual(ours, theirs, accuracy: 1e-3 * theirs, "θ within 0.1 % of diffsims' (the mean inner potential left out)")
            XCTAssertGreaterThan(ours, theirs, "without the inner potential the wavelength is longer, so θ larger")
        }
        XCTAssertTrue(overlay.simulation.lines.allSatisfy { $0.edges.count == 2 })
        let off = KikuchiOverlay.pattern(dataset, at: .origin, maxR: maxR) { _, _ in bands }
        guard case .success(let plain) = off else { return XCTFail("no overlay: \(off)") }
        XCTAssertNil(plain.lineTheta)
        XCTAssertTrue(plain.simulation.lines.allSatisfy(\.edges.isEmpty), "no edges unless asked")
    }

    /// `Overlay CSV…`: one row per band and per zone axis, the indices with their signs, the ends in detector pixels exactly as the
    /// simulation holds them, θ when the edges were computed.
    func testOverlayCSVHoldsTheLinesAndZoneAxes() throws {
        let (dataset, _) = try EBSDOpening.open(url: Self.demoScan)
        let map = try XCTUnwrap(dataset.crystalMap)
        let phase = try XCTUnwrap(map.phases[id: map.allPhaseIDs[0]])
        let bands = try XCTUnwrap(KikuchiOverlay.bands(for: phase, minDSpacing: 1.0))
        let result = KikuchiOverlay.pattern(dataset, at: .origin, maxR: KikuchiOverlay.scanMaxR(dataset), beamEnergyKeV: 20) { _, _ in bands }
        guard case .success(let overlay) = result else { return XCTFail("no overlay: \(result)") }
        let rows = KikuchiOverlay.csv(overlay).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        XCTAssertEqual(rows.first, "feature,h_or_u,k_or_v,l_or_w,label,x1_px,y1_px,x2_px,y2_px,theta_rad")
        XCTAssertEqual(rows.last, "", "the file ends with a newline")
        let body = rows.dropFirst().dropLast().map { $0.split(separator: ",", omittingEmptySubsequences: false).map(String.init) }
        XCTAssertTrue(body.allSatisfy { $0.count == 10 })
        let bandRows = body.filter { $0[0] == "band" }, axisRows = body.filter { $0[0] == "zone_axis" }
        XCTAssertEqual(bandRows.count, overlay.simulation.lines.count)
        XCTAssertEqual(axisRows.count, overlay.simulation.zoneAxes.count)
        for (row, line) in zip(bandRows, overlay.simulation.lines) {
            XCTAssertEqual(row[1...3].map { Double($0)! }, [line.hkl.x, line.hkl.y, line.hkl.z].map { $0.rounded() }, "the indices as integers")
            XCTAssertEqual(row[5...8].map { Double($0)!.bitPattern }, [line.pixel[0], line.pixel[1], line.pixel[2], line.pixel[3]].map(\.bitPattern))
            XCTAssertTrue(["{111}", "{200}", "{220}", "{311}"].contains(row[4]), row[4])
            XCTAssertGreaterThan(Double(row[9]) ?? 0, 0)
        }
        for (row, axis) in zip(axisRows, overlay.simulation.zoneAxes) {
            XCTAssertEqual(row[4], "[\(axis.uvw.x)\(axis.uvw.y)\(axis.uvw.z)]")
            XCTAssertEqual(Double(row[5])?.bitPattern, axis.pixel.x.bitPattern)
            XCTAssertEqual(row[7], "")
        }
        XCTAssertEqual(KikuchiOverlay.plainMiller(SIMD3(-1, -2, 1), brackets: "[]"), "[-1-21]")
    }

    /// The Kinematical overlay (#201, D-SEM-95): kikuchipy's band rule on the square Lambert grid's directions, both hemispheres, then
    /// `get_patterns` of that master pattern for two points of the nickel scan. Red before: there is no Lambert kinematical master
    /// pattern; red with the lower hemisphere's z not negated (the lower half equals the upper), rows and columns swapped (X along
    /// rows), or the Lambert vectors left unnormalised (the band rule's arccos reads the wrong angles).
    func testKinematicOverlayOfTheNickelAsKikuchipy() throws {
        let ref = try SEMParityReference.load("m6/kinematic-overlay-nickel")
        let nickel = try SEMParityReference.load("m6/geometrical-simulation-nickel")
        var p = try XCTUnwrap(nickel.values["lattice"] as? [Double])
        p[0] *= 10; p[1] *= 10; p[2] *= 10
        let reflectors = KikuchiReflectors(lattice: try XCTUnwrap(CrystalLattice(parameters: p)), hkl: triples(try ref.array("reflectors_hkl").values))
        let half = try XCTUnwrap(ref.values["half_size"] as? Int)
        let kv = try XCTUnwrap(ref.values["voltage_kv"] as? Double)
        let phase = CrystalPhase(name: "ni", spaceGroup: 225, pointGroup: "m-3m", lattice: p)
        XCTAssertEqual(KinematicMasterPattern.lambertVector(x: 0, y: 0), SIMD3(0, 0, 1))
        let master = KinematicMasterPattern.lambert(reflectors: reflectors, theta: try ref.array("theta").values, halfSize: half, scaling: .none,
                                                    energyKeV: kv, phase: phase)
        XCTAssertEqual(master.side, 2 * half + 1)
        XCTAssertEqual(master.projection, .lambert)
        XCTAssertEqual(master.hemisphere, .both)
        SEMAssertParity(master.values.map(Double.init), try ref.array("lambert"))
        let d = try XCTUnwrap(ref.values["detector"] as? [String: Any])
        let shape = try XCTUnwrap(d["shape"] as? [Int])
        let rotations = quads(try ref.array("rotations").values), pcs = triples(try ref.array("pcs").values)
        var patterns: [Double] = []
        for (q, pc) in zip(rotations, pcs) {
            let detector = EBSDDetectorGeometry(rows: shape[0], columns: shape[1], pixelSize: try XCTUnwrap(d["px_size"] as? Double),
                                                binning: try XCTUnwrap(d["binning"] as? Int), tilt: try XCTUnwrap(d["tilt"] as? Double),
                                                azimuthal: try XCTUnwrap(d["azimuthal"] as? Double), twist: try XCTUnwrap(d["twist"] as? Double),
                                                sampleTilt: try XCTUnwrap(d["sample_tilt"] as? Double), projectionCenters: [pc])
            patterns += try MasterPatternProjection.project(master: master, rotations: [q], detector: detector, output: .float32).values
        }
        SEMAssertParity(patterns, try ref.array("patterns"))
    }

    /// The overlay's own path on the demo nickel: the point's phase, the overlay's bands at 1 Å, its θ at the file's 20 kV (no inner
    /// potential), the scan's orientation and PC: the simulated pattern correlates with kikuchipy's above 0.95 (θ differs by 0.07 %,
    /// which moves a few band-edge pixels of the Lambert grid), and Kinematical off leaves it out.
    func testKinematicalOverlayOnTheDemoNickel() throws {
        let ref = try SEMParityReference.load("m6/kinematic-overlay-nickel")
        let (dataset, _) = try EBSDOpening.open(url: Self.demoScan)
        let map = try XCTUnwrap(dataset.crystalMap)
        let phase = try XCTUnwrap(map.phases[id: map.allPhaseIDs[0]])
        let bands = try XCTUnwrap(KikuchiOverlay.bands(for: phase, minDSpacing: 1.0))
        SEMAssertParity(ints(bands.reflectors.hkl), try ref.array("reflectors_hkl"))
        let kv = try XCTUnwrap(dataset.sem.beamEnergyKeV)
        let half = try XCTUnwrap(ref.values["half_size"] as? Int)
        let maxR = KikuchiOverlay.scanMaxR(dataset)
        let result = KikuchiOverlay.pattern(dataset, at: .origin, maxR: maxR, master: { _, phase, b in
            KikuchiOverlay.masterPattern(b, phase: phase, beamEnergyKeV: kv, halfSize: half)
        }) { _, _ in bands }
        guard case .success(let overlay) = result else { return XCTFail("no overlay: \(result)") }
        let simulated = try XCTUnwrap(overlay.simulated).map(Double.init)
        XCTAssertEqual(overlay.simulatedRows, dataset.detector.rows)
        XCTAssertEqual(overlay.simulatedColumns, dataset.detector.columns)
        let reference = Array(try ref.array("patterns").values.prefix(simulated.count))
        func centred(_ v: [Double]) -> [Double] { let m = v.reduce(0, +) / Double(v.count); return v.map { $0 - m } }
        let a = centred(simulated), b = centred(reference)
        var ab = 0.0, aa = 0.0, bb = 0.0
        for k in a.indices {
            ab += a[k] * b[k]; aa += a[k] * a[k]; bb += b[k] * b[k]
        }
        let ncc = ab / (aa * bb).squareRoot()
        XCTAssertGreaterThan(ncc, 0.95, "the overlay's kinematical pattern is kikuchipy's up to the inner potential")
        XCTAssertEqual(KikuchiOverlay.masterPatternPicture(bands, beamEnergyKeV: kv, halfSize: 20).count, 41 * 41)
        guard case .success(let plain) = KikuchiOverlay.pattern(dataset, at: .origin, maxR: maxR, bands: { _, _ in bands }) else {
            return XCTFail("no overlay")
        }
        XCTAssertNil(plain.simulated)
    }

    func testTiltedTitaniumDetectorAsKikuchipy() throws {
        let ref = try SEMParityReference.load("m6/geometrical-simulation-tilted")
        let c = try cases()
        let ti = try XCTUnwrap(c.phases["ti"])
        let l = try lattice(ti.lattice).orixAligned
        // The hexagonal families symmetrised by 6/mmm in orix's frame, as the bundle's reflectors.
        let reflectors = KikuchiReflectors(lattice: l, hkl: triples(try ref.array("reflectors_hkl_float").values))
        let t = c.tilted_detector
        let detector = EBSDDetectorGeometry(rows: t.shape[0], columns: t.shape[1], pixelSize: t.px_size, binning: t.binning, tilt: t.tilt,
                                            azimuthal: t.azimuthal, twist: t.twist, sampleTilt: t.sample_tilt, projectionCenters: [])
        let rotations = quads(try ref.array("rotations").values)
        for i in rotations.indices {
            let pc = SIMD3(t.pc[i][0], t.pc[i][1], t.pc[i][2])
            try assertSimulation(GeometricalKikuchiSimulation.simulate(reflectors: reflectors, rotation: rotations[i], detector: detector, pc: pc),
                                 ref, prefix: "o\(i)_")
        }
    }

    func testRoundIndicesAsOrix() {
        // MTEX's rounding: the closest smallest integers, not a plain round.
        XCTAssertEqual(GeometricalKikuchiSimulation.roundIndices(SIMD3(0.5, 0.25, 0.25), maxIndex: 20), SIMD3(2, 1, 1))
        XCTAssertEqual(GeometricalKikuchiSimulation.roundIndices(SIMD3(-2, 4, 6), maxIndex: 20), SIMD3(-1, 2, 3))
        XCTAssertEqual(GeometricalKikuchiSimulation.roundIndices(SIMD3(1, 1.0 / 3, 0), maxIndex: 20), SIMD3(3, 1, 0))
    }

    func testMillerTextBarsNegativeIndices() {
        XCTAssertEqual(KikuchiOverlay.millerText(SIMD3(1, -2, 1), brackets: "[]"), "[12\u{0305}1]")
        XCTAssertEqual(KikuchiOverlay.millerText(SIMD3(3, 1, 1), brackets: "{}"), "{311}")
    }

    // MARK: - Master pattern

    func testKinematicMasterPatternOfNickelAsKikuchipy() throws {
        let ref = try SEMParityReference.load("m6/kinematic-master-pattern-ni")
        let c = try cases()
        let ni = try XCTUnwrap(c.phases["ni"])
        let l = try lattice(ni.lattice).orixAligned
        let reflectors = KikuchiReflectors(lattice: l, hkl: triples(try ref.array("reflectors_hkl").values))
        // The tutorial's nickel at 20 kV: the expanded fcc cell and its one orbit of four.
        let cell = [SIMD3(0.0, 0, 0), SIMD3(0, 0.5, 0.5), SIMD3(0.5, 0, 0.5), SIMD3(0.5, 0.5, 0)].map { KikuchiAtom(z: 28, position: $0) }
        let structureFactor = reflectors.structureFactors(cell: cell)
        SEMAssertParity(structureFactor, try ref.array("structure_factor_abs"))
        let voltage = try XCTUnwrap(ref.values["voltage"] as? Double)
        let theta = reflectors.braggAngles(wavelengthNM: KikuchiWavelength.refractionCorrected(voltage: voltage, orbit: cell, cellVolume: l.volume))
        SEMAssertParity(theta, try ref.array("theta"))
        let half = try XCTUnwrap(ref.values["half_size"] as? Int)
        for scaling in KinematicMasterPattern.Scaling.allCases {
            let mp = KinematicMasterPattern.calculate(reflectors: reflectors, theta: theta, structureFactor: structureFactor, halfSize: half,
                                                      hemisphere: .both, scaling: scaling)
            let expected = try ref.array("master_pattern_\(scaling.rawValue)")
            SEMAssertParity(mp.flatMap { $0 }, expected, shape: [2, 2 * half + 1, 2 * half + 1])
        }
    }
}
