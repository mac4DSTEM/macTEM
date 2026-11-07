//
//  SEMSlipParityTests.swift
//  TEMCore's slip analysis (Sources/TEMCore/SEM/Deformation: `DefDAPQuat`, `SlipSystemSet`, `SlipPhase`, `SlipTraceAnalysis`,
//  `NyeTensor`) against DefDAP 1.3.1 through the committed bundles `m5/slip-ti` (hcp titanium, orix-data Ti_orientations.ctf
//  corner) and `m5/slip-sdss` (fcc austenite and bcc ferrite, orix-data sdss_ferrite_austenite.ang), emitted from
//  tools/parity/sem/fixtures/slip_inputs.json. Tolerances are the bundles' (docs/parity.md): slip-system indices exact, unit
//  vectors and quaternions within 1e-12, grain averages within 1e-10, Schmid factors and trace angles within 1e-6, Nye tensor
//  and GND rtol 1e-5. Red before the port: none of these types exists. Red after a swapped product order, a symmetry list out of
//  DefDAP's order, the wrong hexagonal orthonormalisation or the y derivative in place of the x one: the arrays move by far more
//  than the tolerance.
//

import Foundation
import TEMCore
import XCTest

nonisolated final class SEMSlipParityTests: XCTestCase {

    // MARK: - Inputs

    /// One map of the fixture: DefDAP quaternions in map order, the phases (index = DefDAP phase id − 1) and the phase per point.
    private struct SlipMap {
        let rows: Int
        let columns: Int
        let stepMicrons: Double
        let phases: [SlipPhase]
        let phaseIndex: [Int]
        let quaternions: [SIMD4<Double>]
    }

    private func fixture(_ ref: SEMParityReference) throws -> [String: Any] {
        let url = try XCTUnwrap(ref.inputURL(), "the bundle names fixtures/slip_inputs.json")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private func radians(_ degrees: [Double]) -> [Double] {
        [degrees[0], degrees[1], degrees[2], degrees[3] * Double.pi / 180, degrees[4] * Double.pi / 180, degrees[5] * Double.pi / 180]
    }

    private func numbers(_ any: Any?) throws -> [Double] {
        try XCTUnwrap(any as? [Any]).map { try XCTUnwrap(($0 as? NSNumber)?.doubleValue) }
    }

    private func rows3(_ any: Any?) throws -> [SIMD3<Double>] {
        try XCTUnwrap(any as? [Any]).map { row in
            let r = try numbers(row)
            return SIMD3(r[0], r[1], r[2])
        }
    }

    /// The Ti corner as `case_m5_slip_ti` builds it: degrees * π / 180, one hexagonal phase.
    private func tiMap(_ ref: SEMParityReference) throws -> SlipMap {
        let t = try XCTUnwrap(try fixture(ref)["ti"] as? [String: Any])
        let shape = try numbers(t["shape"]).map { Int($0) }
        let eu = try rows3(t["euler_degrees"]).map { $0 * Double.pi / 180 }
        let phase = try SlipPhase(name: try XCTUnwrap(t["phase"] as? String), laueGroup: 9,
                                  spaceGroup: try XCTUnwrap((t["space_group"] as? NSNumber)?.intValue),
                                  lattice: radians(try numbers(t["lattice_angstrom_degrees"])))
        return SlipMap(rows: shape[0], columns: shape[1], stepMicrons: try XCTUnwrap((t["step_um"] as? NSNumber)?.doubleValue),
                       phases: [phase], phaseIndex: Array(repeating: 0, count: eu.count), quaternions: eu.map(DefDAPQuat.fromEuler))
    }

    /// The duplex steel as `case_m5_slip_sdss` builds it: DefDAP's EDAX frame change (φ1 − π/2, wrapped), fcc and bcc phases.
    private func sdssMap(_ ref: SEMParityReference) throws -> SlipMap {
        let t = try XCTUnwrap(try fixture(ref)["sdss"] as? [String: Any])
        let shape = try numbers(t["shape"]).map { Int($0) }
        let eu = try rows3(t["euler_radians"]).map { e -> SIMD3<Double> in
            var p1 = e[0] - Double.pi / 2
            if p1 < 0 { p1 += 2 * Double.pi }
            return SIMD3(p1, e[1], e[2])
        }
        let phases = try XCTUnwrap(t["phases"] as? [[String: Any]]).map { p in
            try SlipPhase(name: try XCTUnwrap(p["name"] as? String), laueGroup: 11,
                          spaceGroup: try XCTUnwrap((p["space_group"] as? NSNumber)?.intValue),
                          lattice: radians(try numbers(p["lattice_angstrom_degrees"])))
        }
        let ids = try numbers(t["phase_id"]).map { Int($0) - 1 }
        return SlipMap(rows: shape[0], columns: shape[1], stepMicrons: try XCTUnwrap((t["step_um"] as? NSNumber)?.doubleValue),
                       phases: phases, phaseIndex: ids, quaternions: eu.map(DefDAPQuat.fromEuler))
    }

    private func map(for caseName: String, _ ref: SEMParityReference) throws -> SlipMap {
        caseName == "m5/slip-ti" ? try tiMap(ref) : try sdssMap(ref)
    }

    private static let cases = ["m5/slip-ti", "m5/slip-sdss"]

    private func flat(_ a: [SIMD4<Double>]) -> [Double] { a.flatMap { [$0[0], $0[1], $0[2], $0[3]] } }
    private func flat(_ a: [SIMD3<Double>]) -> [Double] { a.flatMap { [$0.x, $0.y, $0.z] } }

    /// The array's tolerance, NaN in the reference only where NaN here (a plane parallel to the map has no trace).
    private func assertParity(_ actual: [Double], _ reference: SEMParityReference.LoadedArray,
                              file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.count, reference.values.count, reference.name, file: file, line: line)
        var a: [Double] = [], b: [Double] = []
        for (x, y) in zip(actual, reference.values) {
            if y.isNaN {
                XCTAssertTrue(x.isNaN, "\(reference.name): NaN in the reference", file: file, line: line)
            } else {
                a.append(x)
                b.append(y)
            }
        }
        if let m = SEMParityCompare.mismatch(name: reference.name, actual: a, expected: b, rtol: reference.rtol, atol: reference.atol) {
            XCTFail(m.description, file: file, line: line)
        }
    }

    // MARK: - Parity

    func testSlipSystemsAreDefDAPs() throws {
        for name in Self.cases {
            let ref = try SEMParityReference.load(name)
            let m = try map(for: name, ref)
            let phases = try XCTUnwrap(ref.values["phases"] as? [[String: Any]])
            XCTAssertEqual(phases.count, m.phases.count, name)
            for (k, (p, ours)) in zip(phases, m.phases).enumerated() {
                let set = try XCTUnwrap(ours.slipSystems, "\(name): phase \(k) has slip systems")
                XCTAssertEqual(p["slip_system_file"] as? String, ours.slipSystemFile?.rawValue, name)
                XCTAssertEqual(p["trace_colours"] as? [String], set.traceColours, name)
                let groups = try XCTUnwrap(p["groups"] as? [[[String: [Int]]]])
                XCTAssertEqual(groups.map { $0.map { $0["plane"] ?? [] } }, set.groups.map { $0.map(\.planeIndices) }, "\(name): planes by group")
                XCTAssertEqual(groups.map { $0.map { $0["direction"] ?? [] } }, set.groups.map { $0.map(\.directionIndices) }, "\(name): directions by group")
                if let c = p["c_over_a"] as? NSNumber {
                    XCTAssertEqual(ours.cOverA ?? .nan, c.doubleValue, accuracy: 1e-15, name)
                }
                SEMAssertParity(flat(set.flattened.map(\.plane)), try ref.array("slip_planes_\(k)"))
                SEMAssertParity(flat(set.flattened.map(\.direction)), try ref.array("slip_directions_\(k)"))
            }
        }
    }

    func testQuaternionsFromEulerAnglesAreDefDAPs() throws {
        for name in Self.cases {
            let ref = try SEMParityReference.load(name)
            let m = try map(for: name, ref)
            SEMAssertParity(flat(m.quaternions), try ref.array("quaternions"), shape: [m.rows, m.columns, 4])
        }
    }

    func testGrainAveragesSchmidFactorsAndTracesMatchDefDAP() throws {
        for name in Self.cases {
            let ref = try SEMParityReference.load(name)
            let m = try map(for: name, ref)
            let points = try ref.array("grain_points").values.map { Int($0) }
            let offsets = try ref.array("grain_offsets").values.map { Int($0) }
            let phaseOf = try ref.array("grain_phase").values.map { Int($0) }
            XCTAssertEqual(offsets.count, phaseOf.count + 1, name)
            let averages = phaseOf.indices.map { g in
                SlipTraceAnalysis.averageOrientation(of: Array(points[offsets[g]..<offsets[g + 1]]), in: m.quaternions,
                                                     structure: m.phases[phaseOf[g]].crystal.structure)
            }
            SEMAssertParity(flat(averages), try ref.array("grain_average_orientation"))
            for (k, phase) in m.phases.enumerated() {
                let grains = phaseOf.indices.filter { phaseOf[$0] == k }
                guard !grains.isEmpty else { continue }
                let set = try XCTUnwrap(phase.slipSystems)
                let schmid = grains.flatMap { SlipTraceAnalysis.schmidFactors(orientation: averages[$0], load: SIMD3(1, 0, 0), systems: set).joined() }
                assertParity(schmid, try ref.array("grain_schmid_x_\(k)"))
                let traces = grains.map { SlipTraceAnalysis.traces(orientation: averages[$0], systems: set) }
                assertParity(traces.flatMap { $0.map(\.angle) }, try ref.array("grain_trace_angles_\(k)"))
                assertParity(traces.flatMap { $0.map(\.inclination) }, try ref.array("grain_trace_inclinations_\(k)"))
            }
        }
    }

    func testPerOrientationSchmidFactorsAndTracesMatchDefDAP() throws {
        for name in Self.cases {
            let ref = try SEMParityReference.load(name)
            let m = try map(for: name, ref)
            for (k, phase) in m.phases.enumerated() {
                guard ref.manifest.arrays["sample_points_\(k)"] != nil else { continue }
                let set = try XCTUnwrap(phase.slipSystems)
                let points = try ref.array("sample_points_\(k)").values.map { Int($0) }
                XCTAssertTrue(points.allSatisfy { m.phaseIndex[$0] == k }, "\(name): sample points of phase \(k)")
                let q = points.map { m.quaternions[$0] }
                assertParity(q.flatMap { SlipTraceAnalysis.schmidFactors(orientation: $0, load: SIMD3(1, 0, 0), systems: set).joined() },
                             try ref.array("sample_schmid_x_\(k)"))
                assertParity(q.flatMap { SlipTraceAnalysis.schmidFactors(orientation: $0, load: SIMD3(0, 1, 0), systems: set).joined() },
                             try ref.array("sample_schmid_y_\(k)"))
                let traces = q.map { SlipTraceAnalysis.traces(orientation: $0, systems: set) }
                assertParity(traces.flatMap { $0.map(\.angle) }, try ref.array("sample_trace_angles_\(k)"))
                assertParity(traces.flatMap { $0.map(\.inclination) }, try ref.array("sample_trace_inclinations_\(k)"))
            }
        }
    }

    func testNyeTensorAndGNDMatchDefDAPBothWays() throws {
        for name in Self.cases {
            let ref = try SEMParityReference.load(name)
            let m = try map(for: name, ref)
            // DefDAP takes the primary (first) phase's symmetries for the whole map.
            let structure = m.phases[0].crystal.structure
            let modes: [(NyeTensor.Derivatives, String)] = [(.separate, ""), (.defdap131, "_defdap_1_3_1")]
            for (mode, suffix) in modes {
                let r = NyeTensor.compute(quaternions: m.quaternions, rows: m.rows, columns: m.columns, stepMicrons: m.stepMicrons,
                                          structure: structure, derivatives: mode)
                SEMAssertParity(r.gnd, try ref.array("gnd" + suffix), shape: [m.rows, m.columns])
                var window: [Double] = []
                for i in 0..<3 {
                    for j in 0..<3 {
                        for row in 0..<30 {
                            for column in 0..<40 { window.append(r.alpha(i, j, row: row, column: column)) }
                        }
                    }
                }
                SEMAssertParity(window, try ref.array("nye" + suffix + "_window"), shape: [3, 3, 30, 40])
            }
        }
    }

    // MARK: - Hand numbers

    func testSchmidFactorAndTraceOfTheCubeOrientationByHand() throws {
        let fcc = try SlipSystemSet.load(.cubicFCC, crystal: .cubic)
        let identity = DefDAPQuat.fromEuler(SIMD3(0, 0, 0))
        // Load along [001] on (111)[01-1]: |cos φ cos λ| = (1/√3)(1/√2) = 0.40825.
        let sf = SlipTraceAnalysis.schmidFactors(orientation: identity, load: SIMD3(0, 0, 1), systems: fcc)
        XCTAssertEqual(sf[0][0], 1 / (3.0.squareRoot() * 2.0.squareRoot()), accuracy: 1e-15)
        // (111) cuts the map plane along [-110]: 45° from +y; the plane is 54.7356° from the map plane.
        let t = SlipTraceAnalysis.traces(orientation: identity, systems: fcc)
        XCTAssertEqual(t[0].angle, Double.pi / 4, accuracy: 1e-15)
        XCTAssertEqual(t[0].inclination, acos(1 / 3.0.squareRoot()), accuracy: 1e-15)
        XCTAssertEqual(fcc.groups.count, 4)
        XCTAssertEqual(fcc.groups[0][0].planeLabel, "(111)")
        XCTAssertEqual(fcc.groups[0][0].directionLabel, "[011\u{0305}]")
    }

    func testAUniformMapHasNoDislocationContent() {
        let q = Array(repeating: DefDAPQuat.fromEuler(SIMD3(0.3, 0.7, 1.1)), count: 12)
        let r = NyeTensor.compute(quaternions: q, rows: 3, columns: 4, stepMicrons: 0.5, structure: .cubic)
        XCTAssertTrue(r.gnd.allSatisfy { abs($0) < 1e3 }, "\(r.gnd)")
    }

    func testAFileRowWithoutSixIntegersIsRefusedAsDefDAPRefusesIt() {
        let text = "# Plane normal then slip direction\nred\n1\t1\t1\t0\t1\n"
        XCTAssertThrowsError(try SlipSystemSet.parse(text, crystal: .cubic)) { error in
            XCTAssertEqual(error as? SlipSystemSet.LoadError, .notValid(line: 3))
        }
        XCTAssertThrowsError(try SlipPhase(name: "x", laueGroup: 7, spaceGroup: nil, lattice: [1, 1, 1, 1, 1, 1]))
    }

    func testEverySlipSystemFileLoadsAndOnlyDefDAPsBCCFileHoldsSystemsOutOfTheirPlane() throws {
        for file in SlipSystemFile.allCases {
            let set = try SlipSystemSet.load(file, crystal: file.isHexagonal ? .hexagonal(cOverA: 1.587) : .cubic)
            XCTAssertFalse(set.groups.isEmpty, file.rawValue)
            for s in set.flattened { XCTAssertEqual(Vector3.dot(s.plane, s.plane), 1, accuracy: 1e-14, file.rawValue) }
            let outOfPlane = set.flattened.filter { !$0.isConsistent }
            if file == .cubicBCC {
                // DefDAP 1.3.1's {123}<111> rows: 12 of 24 put the direction out of the plane, e.g. (123)[111] (n·d = 6).
                XCTAssertEqual(outOfPlane.count, 12)
                XCTAssertTrue(outOfPlane.allSatisfy { Set($0.planeIndices.map(abs)) == [1, 2, 3] })
                XCTAssertEqual(set.consistent.flattened.count, 36)
                XCTAssertTrue(set.consistent.flattened.allSatisfy(\.isConsistent))
            } else {
                XCTAssertEqual(outOfPlane.count, 0, file.rawValue)
                XCTAssertEqual(set.consistent, set, file.rawValue)
            }
        }
    }
}
