//
//  MasterPatternParityTests.swift
//  TEMCore's EMsoft master pattern reader (`EMsoftMasterPatternReader`) and its projection onto a detector
//  (`MasterPatternProjection`, figure F15) against kikuchipy 0.13.1's numbers in tools/parity/sem/references/m6/:
//  - read-master-pattern-ni: kikuchipy's in-package Ni 20 kV master pattern (uint8, 401 x 401, both hemispheres) in each
//    projection and hemisphere, the bytes exact (sha256 of the whole array, every 50th row, the hemisphere sums), the axes, the
//    phase, and the space-group-to-point-group table against orix for all 230 groups;
//  - read-master-pattern-dummy / -tkd / -ecp: float32 files of 11 energies, every energy, the nearest one and a range, exact;
//  - project-master-pattern-docs / -ni / -tilted: the docstring example, F15's Ni detector and a fully tilted non-square detector
//    with one centre per rotation on a multi-energy pattern: sample-to-detector matrix and gnomonic bounds (rtol 1e-7), direction
//    cosines (rtol 1e-7), float patterns within `np.allclose`'s defaults (rtol 1e-5, atol 1e-8), integer ones within one count.
//  The Metal float32 path is checked against the CPU path within `MasterPatternProjectionMetal.tolerance` (skipped without a GPU).
//  Red before the port: no reader or projection type. Red after: a hemisphere swapped, the stereographic flip dropped, a tilt sign
//  flipped (the matrix and every pattern move), the Lambert axes swapped, the rescale order changed (uint8 levels move).
//

import CryptoKit
import Foundation
import FormatoCore
import TEMCore
import XCTest

nonisolated final class MasterPatternParityTests: XCTestCase {

    // MARK: - Helpers

    private func readings(_ ref: SEMParityReference) throws -> [String: [String: Any]] {
        try XCTUnwrap(ref.values["readings"] as? [String: [String: Any]])
    }

    private func sha256(_ values: [Float], as type: FormatoDataType) -> String {
        var data = Data()
        switch type {
        case .uint8: data = Data(values.map { UInt8($0) })
        case .float32: values.withUnsafeBufferPointer { data = Data(buffer: $0) }
        default: XCTFail("unexpected type \(type)")
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func selection(_ kwargs: [String: Any]) -> EBSDMasterPattern.EnergySelection {
        if let range = kwargs["energy"] as? [Double], range.count == 2 { return .range(range[0], range[1]) }
        if let value = kwargs["energy"] as? Double { return .nearest(value) }
        return .all
    }

    private func checkReading(_ mp: EBSDMasterPattern, _ expected: [String: Any], _ label: String) throws {
        XCTAssertEqual(mp.shape, expected["shape"] as? [Int], label)
        XCTAssertEqual(mp.dataType.rawValue, expected["dtype"] as? String, label)
        XCTAssertEqual(mp.diffractionType.signalType, expected["signal_type"] as? String, label)
        let axes = try XCTUnwrap(expected["axes"] as? [[String: Any]])
        for axis in axes {
            let name = try XCTUnwrap(axis["name"] as? String)
            let size = try XCTUnwrap(axis["size"] as? Int)
            let offset = try XCTUnwrap(axis["offset"] as? Double)
            let scale = try XCTUnwrap(axis["scale"] as? Double)
            switch name {
            case "hemisphere": XCTAssertEqual(mp.hemisphereCount, size, label)
            case "energy":
                XCTAssertEqual(mp.energyAxis.size, size, label)
                XCTAssertEqual(mp.energyAxis.offset, offset, label)
                XCTAssertEqual(mp.energyAxis.scale, scale, accuracy: 1e-12, label)
            case "height", "width":
                XCTAssertEqual(mp.side, size, label)
                XCTAssertEqual(Double(mp.pixelOffset), offset, label)
            default: XCTFail("\(label): axis \(name)")
            }
        }
        let phase = try XCTUnwrap(expected["phase"] as? [String: Any])
        XCTAssertEqual(mp.phase.name, phase["name"] as? String, label)
        XCTAssertEqual(mp.phase.spaceGroup, phase["space_group"] as? Int, label)
        XCTAssertEqual(mp.phase.pointGroup, phase["point_group"] as? String, label)
        XCTAssertEqual(mp.phase.containsInversion, phase["inversion"] as? Bool, label)
        XCTAssertEqual(mp.phase.atomCount, phase["atoms"] as? Int, label)
        let lattice = try XCTUnwrap(phase["lattice"] as? [Double])
        XCTAssertEqual(mp.phase.lattice.count, 6, label)
        for (a, b) in zip(mp.phase.lattice, lattice) { XCTAssertEqual(a, b, accuracy: 1e-12, label) }
    }

    // MARK: - Reader

    /// The Ni 20 kV pattern in every projection and hemisphere: bytes, axes, phase. Mutation: the stereographic flip dropped
    /// (the sha256 and the rows move), the hemispheres swapped (the sums swap), xtalname's head taken as the tail ("ni.xtal").
    func testTheNickelMasterPatternReadsAsKikuchipyReadsIt() throws {
        let ref = try SEMParityReference.load("m6/read-master-pattern-ni")
        let url = try XCTUnwrap(ref.inputURL())
        XCTAssertEqual(EMsoftMasterPatternReader.sniff(url: url), .ebsd)
        let expected = try readings(ref)
        for projection in EBSDMasterPattern.Projection.allCases {
            for hemisphere in EBSDMasterPattern.Hemisphere.allCases {
                let key = "\(projection.rawValue)_\(hemisphere.rawValue)"
                let mp = try EMsoftMasterPatternReader.read(url: url, type: .ebsd, projection: projection, hemisphere: hemisphere)
                try checkReading(mp, try XCTUnwrap(expected[key]), key)
                XCTAssertEqual(mp.phase.name, "ni")
                XCTAssertEqual(mp.energies, [20])
                let fingerprint = try XCTUnwrap(ref.values["data_\(key)"] as? [String: Any])
                XCTAssertEqual(sha256(mp.values, as: mp.dataType), fingerprint["sha256"] as? String, key)
                if hemisphere == .both {
                    let rows = try ref.array("rows_\(key)")
                    var ours: [Double] = []
                    for h in 0 ..< 2 {
                        let pattern = Array(mp.pattern(hemisphere: h, energy: 0))
                        for r in stride(from: 0, to: mp.side, by: 50) {
                            ours += pattern[r * mp.side ..< (r + 1) * mp.side].map { Double($0) }
                        }
                    }
                    SEMAssertParity(ours, rows)
                    let sums = (0 ..< 2).map { h in mp.pattern(hemisphere: h, energy: 0).reduce(0.0) { $0 + Double($1) } }
                    SEMAssertParity(sums, try ref.array("sum_\(key)"))
                }
            }
        }
    }

    /// orix's point group and inversion of every space group. Mutation: a range boundary moved by one (-42m vs 4/mmm at 122/123).
    func testEverySpaceGroupMapsToOrixsPointGroup() throws {
        let ref = try SEMParityReference.load("m6/read-master-pattern-ni")
        let table = try XCTUnwrap(ref.values["point_groups"] as? [String: [String: Any]])
        XCTAssertEqual(table.count, 230)
        for number in 1 ... 230 {
            let row = try XCTUnwrap(table[String(number)])
            let ours = try XCTUnwrap(SpaceGroupPointGroup.pointGroup(ofSpaceGroup: number))
            XCTAssertEqual(ours.name, row["name"] as? String, "space group \(number)")
            XCTAssertEqual(ours.inversion, row["inversion"] as? Bool, "space group \(number)")
        }
        XCTAssertNil(SpaceGroupPointGroup.pointGroup(ofSpaceGroup: 0))
        XCTAssertNil(SpaceGroupPointGroup.pointGroup(ofSpaceGroup: 231))
    }

    /// Multi-energy float32 files of each diffraction type: every energy, the nearest to 15.4 kV and to 25 kV (the last), 12 to
    /// 16 kV, in each projection and hemisphere, exact. Mutation: the nearest pick in float64 on a tie, the range's upper index
    /// exclusive, the energy axis offset at the first file energy instead of the first read.
    func testMultiEnergyMasterPatternsOfEachTypeRead() throws {
        for (name, type) in [("dummy", EBSDMasterPattern.DiffractionType.ebsd), ("tkd", .tkd), ("ecp", .ecp)] {
            let ref = try SEMParityReference.load("m6/read-master-pattern-\(name)")
            let url = try XCTUnwrap(ref.inputURL())
            XCTAssertEqual(EMsoftMasterPatternReader.sniff(url: url), type, name)
            let expected = try readings(ref)
            XCTAssertGreaterThanOrEqual(expected.count, 12, name)
            for (key, reading) in expected {
                let kwargs = try XCTUnwrap(reading["kwargs"] as? [String: Any])
                let projection = try XCTUnwrap(EBSDMasterPattern.Projection(rawValue: try XCTUnwrap(kwargs["projection"] as? String)))
                let hemisphere = try XCTUnwrap(EBSDMasterPattern.Hemisphere(rawValue: try XCTUnwrap(kwargs["hemisphere"] as? String)))
                let mp = try EMsoftMasterPatternReader.read(url: url, type: type, projection: projection, hemisphere: hemisphere,
                                                            energy: selection(kwargs))
                try checkReading(mp, reading, "\(name)/\(key)")
                XCTAssertNil(mp.phase.name, "\(name)/\(key)")
                SEMAssertParity(mp.values.map { Double($0) }, try ref.array("data_\(key)"))
            }
        }
    }

    /// What the reader refuses, in words: a file of another program, a range holding no energy; and an energy outside the axis
    /// when a projection picks one.
    func testTheReaderRefusesWhatKikuchipyRefuses() throws {
        let ni = try XCTUnwrap(try SEMParityReference.load("m6/read-master-pattern-ni").inputURL())
        XCTAssertThrowsError(try EMsoftMasterPatternReader.read(url: ni, type: .tkd)) { error in
            XCTAssertTrue((error as? EBSDReadError)?.text.contains("EMTKDmaster.f90") == true, "\(error)")
        }
        let dummy = try XCTUnwrap(try SEMParityReference.load("m6/read-master-pattern-dummy").inputURL())
        XCTAssertThrowsError(try EMsoftMasterPatternReader.read(url: dummy, energy: .range(21, 30)))
        let mp = try EMsoftMasterPatternReader.read(url: dummy, projection: .lambert, hemisphere: .both)
        XCTAssertThrowsError(try mp.hemispheres(energy: 25))
        XCTAssertEqual(try mp.energyAxis.index(of: 12.4), 2)
        XCTAssertEqual(try mp.energyAxis.index(of: 12.5), 2, "half rounds towards zero")
        XCTAssertEqual(try mp.energyAxis.index(of: 12.6), 3)
        let refused = try EMsoftMasterPatternReader.read(url: ni, projection: .stereographic, hemisphere: .both)
        let detector = EBSDDetectorGeometry(rows: 10, columns: 10, projectionCenters: [SIMD3(0.5, 0.5, 0.5)])
        XCTAssertThrowsError(try MasterPatternProjection.project(master: refused, rotations: [SIMD4(1, 0, 0, 0)], detector: detector)) { error in
            XCTAssertEqual(error as? MasterPatternProjection.Error, .notLambert)
        }
    }

    // MARK: - Projection

    private struct ProjectionCase {
        let master: EBSDMasterPattern
        let detector: EBSDDetectorGeometry
        let rotations: [SIMD4<Double>]
        let ref: SEMParityReference
    }

    private func projectionCase(_ name: String) throws -> ProjectionCase {
        let ref = try SEMParityReference.load("m6/project-master-pattern-\(name)")
        let master = try EMsoftMasterPatternReader.read(url: try XCTUnwrap(ref.inputURL()), projection: .lambert, hemisphere: .both)
        let d = try XCTUnwrap(ref.values["detector"] as? [String: Any])
        let shape = try XCTUnwrap(d["shape"] as? [Int])
        func flatten(_ any: Any) -> [Double] {
            if let x = any as? Double { return [x] }
            if let list = any as? [Any] { return list.flatMap(flatten) }
            return []
        }
        let pcs = flatten(try XCTUnwrap(d["pc"]))
        XCTAssertEqual(pcs.count % 3, 0)
        let centres = stride(from: 0, to: pcs.count, by: 3).map { SIMD3(pcs[$0], pcs[$0 + 1], pcs[$0 + 2]) }
        let detector = EBSDDetectorGeometry(rows: shape[0], columns: shape[1], pixelSize: 1, binning: d["binning"] as? Int ?? 1,
                                            tilt: d["tilt"] as? Double ?? 0, azimuthal: d["azimuthal"] as? Double ?? 0,
                                            twist: d["twist"] as? Double ?? 0, sampleTilt: d["sample_tilt"] as? Double ?? 70,
                                            projectionCenters: centres)
        let q = try ref.array("quaternions").values
        let rotations = stride(from: 0, to: q.count, by: 4).map { SIMD4(q[$0], q[$0 + 1], q[$0 + 2], q[$0 + 3]) }
        return ProjectionCase(master: master, detector: detector, rotations: rotations, ref: ref)
    }

    private func checkProjection(_ name: String, file: StaticString = #filePath, line: UInt = #line) throws -> ProjectionCase {
        let c = try projectionCase(name)
        let d = c.detector
        SEMAssertParity(MasterPatternProjection.sampleToDetector(sampleTilt: d.sampleTilt, tilt: d.tilt, azimuthal: d.azimuthal, twist: d.twist),
                        try c.ref.array("sample_to_detector"), file: file, line: line)
        SEMAssertParity(d.projectionCenters.flatMap { MasterPatternProjection.gnomonicBounds(rows: d.rows, columns: d.columns, pc: $0) },
                        try c.ref.array("gnomonic_bounds"), file: file, line: line)
        let cosines = MasterPatternProjection.directionCosines(detector: d).flatMap { $0 }.flatMap { [$0.x, $0.y, $0.z] }
        SEMAssertParity(cosines, try c.ref.array("direction_cosines"), file: file, line: line)
        let dtypes = try XCTUnwrap(c.ref.values["dtypes"] as? [String])
        let energies = try XCTUnwrap(c.ref.values["energies"] as? [Any])
        for energyAny in energies {
            let energy = energyAny as? Double
            for dt in dtypes {
                let output = try XCTUnwrap(MasterPatternProjection.OutputType(rawValue: dt))
                let patterns = try MasterPatternProjection.project(master: c.master, rotations: c.rotations, detector: d, energy: energy, output: output)
                XCTAssertEqual(patterns.count, c.rotations.count, file: file, line: line)
                let suffix = energy.map { "_e" + String($0).replacingOccurrences(of: ".", with: "_") } ?? ""
                SEMAssertParity(patterns.values, try c.ref.array("patterns_\(dt)\(suffix)"),
                                shape: [c.rotations.count, d.rows, d.columns], file: file, line: line)
            }
        }
        return c
    }

    /// The docstring example: four identity rotations, one centre each. Mutation: the half-pixel step dropped (every pattern
    /// shifts by half a pixel), the gnomonic y range taken from the top instead of the bottom.
    func testTheDocsExampleProjectsAsKikuchipyProjectsIt() throws {
        _ = try checkProjection("docs")
    }

    /// Figure F15: the Ni master pattern on the north-star detector for three orientations, float32, uint8 and float64. Prints the
    /// uint8 patterns (base64, one line each) and writes them to $TMPDIR/macTEM-F15-ours.u8 for tools/parity/sem/master_pattern_figure.py.
    /// Mutation: the quaternion's vector part negated (the inverse rotation: patterns move), the Lambert X and Y swapped.
    func testFigureF15NickelMasterPatternOnTheNorthStarDetector() throws {
        let c = try checkProjection("ni")
        let patterns = try MasterPatternProjection.project(master: c.master, rotations: c.rotations, detector: c.detector, output: .uint8)
        let bytes = Data(patterns.values.map { UInt8($0) })
        for n in 0 ..< patterns.count {
            let n0 = n * c.detector.rows * c.detector.columns
            print("F15 ours pattern \(n) uint8 base64: \(bytes[n0 ..< n0 + c.detector.rows * c.detector.columns].base64EncodedString())")
        }
        try? bytes.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("macTEM-F15-ours.u8"))
    }

    /// Every detector angle at once, a non-square detector, one centre per rotation, a multi-energy master pattern at its highest
    /// energy and at 12.4 kV. Mutation: azimuthal or twist sign flipped, the varying centres applied in reverse order, the energy
    /// rounded up.
    func testATiltedDetectorWithVaryingCentresAndEnergies() throws {
        _ = try checkProjection("tilted")
        let c = try projectionCase("tilted")
        XCTAssertThrowsError(try MasterPatternProjection.project(master: c.master, rotations: Array(c.rotations.prefix(2)), detector: c.detector)) { error in
            XCTAssertEqual(error as? MasterPatternProjection.Error, .centreCount(centres: 3, rotations: 2))
        }
    }

    /// The float32 GPU path against the float64 CPU reference on the Ni pattern: F15's three orientations and 400 more spread over
    /// orientation space, every pixel within `MasterPatternProjectionMetal.tolerance`; the automatic backend picks the GPU at that
    /// size. Skipped where the Mac has no Metal device.
    func testTheMetalPathMatchesTheCPUReference() throws {
        guard MasterPatternProjectionMetal.isAvailable else { throw XCTSkip("no Metal device on this machine") }
        let c = try projectionCase("ni")
        var rotations = c.rotations
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        func uniform() -> Double {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return Double((z ^ (z >> 31)) >> 11) / Double(1 << 53)
        }
        for _ in 0 ..< 400 {
            // Shoemake's uniform random unit quaternion.
            let u1 = uniform(), u2 = uniform() * 2 * Double.pi, u3 = uniform() * 2 * Double.pi
            let a = (1 - u1).squareRoot(), b = u1.squareRoot()
            rotations.append(SIMD4(b * cos(u3), a * sin(u2), a * cos(u2), b * sin(u3)))
        }
        let cpu = try MasterPatternProjection.patternsFloat32(master: c.master, rotations: rotations, detector: c.detector, backend: .cpu)
        let gpu = try MasterPatternProjection.patternsFloat32(master: c.master, rotations: rotations, detector: c.detector, backend: .metal)
        XCTAssertEqual(gpu.count, cpu.count)
        var worst: Float = 0
        for (a, b) in zip(gpu, cpu) { worst = max(worst, abs(a - b)) }
        print("Metal vs CPU master pattern projection: \(rotations.count) patterns, largest difference \(worst)")
        XCTAssertLessThanOrEqual(Double(worst), MasterPatternProjectionMetal.tolerance)
        XCTAssertGreaterThanOrEqual(rotations.count * c.detector.rows * c.detector.columns, MasterPatternProjection.metalWorkThreshold)
        let automatic = try MasterPatternProjection.patternsFloat32(master: c.master, rotations: rotations, detector: c.detector)
        XCTAssertEqual(automatic, gpu)
    }
}
