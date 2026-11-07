//
//  CrystalMapParityTests.swift
//  TEMCore's crystal map model (Sources/TEMCore/SEM/CrystalMap: `CrystalMap`, `PhaseList`, `NeighbourMisorientation`,
//  `AngleHistogram`) against orix 0.15.0 through the bundles `m3/ti-neighbour-misorientations` (a committed 3 x 507 Ti map),
//  `m3/ti-neighbour-misorientations-full` (figure F7: orix-data's whole 381 x 507 Ti map, a downloaded dataset) and
//  `m3/crystal-map-sdss` (orix-data's two-phase .ang map, committed as Fixtures/ebsd-sdss-ferrite-austenite.ang).
//  Tolerances are the bundles' (docs/parity.md): counts, edges, shapes, ids, rows, columns and map data exact; misorientations
//  and angles atol 1e-7. Red before the port: none of these types exists. Red after a swapped neighbour order, a pair taken
//  across a row end, a histogram bin closed on the wrong side or a slice that loses its place in the grid.
//

import TEMCore
import XCTest

nonisolated final class CrystalMapParityTests: XCTestCase {

    private func flat(_ a: [SIMD4<Double>]) -> [Double] { a.flatMap { [$0[0], $0[1], $0[2], $0[3]] } }

    private func rows3(_ a: SEMParityReference.LoadedArray) -> [SIMD3<Double>] {
        stride(from: 0, to: a.values.count, by: 3).map { SIMD3(a.values[$0], a.values[$0 + 1], a.values[$0 + 2]) }
    }

    private static let ti = CrystalPhase(name: "Ti", spaceGroup: 194, pointGroup: "622", lattice: [2.95, 2.95, 4.68, 90, 90, 120])

    // MARK: - F7 on the committed map

    /// The first three rows of orix-data's Ti map (Bunge angles in degrees from fixtures/orientation_inputs.json, x and y on a
    /// 0.25 µm grid as the file writes them), 622 attached as `orix.data.ti_orientations` attaches it.
    func testNeighbourMisorientationsOfTheTiHeadMatchOrix() throws {
        let ref = try SEMParityReference.load("m3/ti-neighbour-misorientations")
        let degrees = rows3(try ref.array("euler_degrees"))
        XCTAssertEqual(degrees.count, 3 * 507)
        let grid = CrystalMap.coordinates(shape: (3, 507), steps: (0.25, 0.25))
        let map = try CrystalMap(euler: degrees.map { $0 * (.pi / 180) }, phaseIDs: Array(repeating: 1, count: degrees.count), x: grid.x, y: grid.y,
                                 phaseList: PhaseList([(1, Self.ti)]), scanUnit: "um")
        XCTAssertEqual(map.shape, [3, 507])
        XCTAssertEqual(map.dx, 0.25)
        XCTAssertEqual(map.dy, 0.25)

        let (h, v) = try NeighbourMisorientation.misorientations(of: map)
        XCTAssertEqual(h.quaternions.count, 1518)
        XCTAssertEqual(v.quaternions.count, 1014)
        SEMAssertParity(flat(h.quaternions), try ref.array("horizontal_misorientations"))
        SEMAssertParity(flat(v.quaternions), try ref.array("vertical_misorientations"))
        SEMAssertParity(h.angles, try ref.array("horizontal_angles"))
        SEMAssertParity(v.angles, try ref.array("vertical_angles"))

        let histogram = AngleHistogram(values: try NeighbourMisorientation.anglesDegrees(of: map), edges: NeighbourMisorientation.f7Edges)
        SEMAssertParity(histogram.edges, try ref.array("edges_degrees"))
        SEMAssertParity(histogram.counts.map(Double.init), try ref.array("counts"))
    }

    /// Figure F7: the neighbour disorientation angle histogram of orix-data's whole Ti map, counts and edges exact. The 29 MB
    /// file comes through tools/parity/sem/fetch-data.sh (References/sem-data/orix/Ti_orientations.ctf); without it the test
    /// skips and the committed 3 x 507 map above holds the port.
    func testFigureF7NeighbourMisorientationHistogramOfTheTiMap() throws {
        let ref = try SEMParityReference.load("m3/ti-neighbour-misorientations-full")
        let url = try XCTUnwrap(ref.inputURL())
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path), "fetch-data.sh has not fetched \(url.lastPathComponent)")
        let map = try Self.tiMap(url: url)
        XCTAssertEqual(map.shape, [381, 507])
        let (h, v) = try NeighbourMisorientation.misorientations(of: map)
        XCTAssertEqual(h.quaternions.count, 192_786)
        XCTAssertEqual(v.quaternions.count, 192_660)
        let radians = h.angles + v.angles
        let sample = try ref.array("sample_index").values.map { radians[Int($0)] }
        SEMAssertParity(sample, try ref.array("sample_angles"))
        let histogram = AngleHistogram(values: radians.map { $0 * 180 / .pi }, edges: NeighbourMisorientation.f7Edges)
        SEMAssertParity(histogram.edges, try ref.array("edges_degrees"))
        SEMAssertParity(histogram.counts.map(Double.init), try ref.array("counts"))
        Self.writeFigureF7(histogram)
    }

    /// orix-data's Ti table read by `CTFReader` (the orientation-table form), 622 attached as `orix.data.ti_orientations` does.
    static func tiMap(url: URL) throws -> CrystalMap {
        var map = try CTFReader.read(path: url.path).map
        map.phases = PhaseList([(1, ti)])
        return map
    }

    /// The figure's numbers as text beside the reference figure (`$TMPDIR/macTEM-F7-ours.txt`): edge, count per bin.
    static func writeFigureF7(_ histogram: AngleHistogram) {
        let lines = zip(histogram.edges, histogram.counts).map { "\($0.0)\t\($0.1)" }
        try? (lines.joined(separator: "\n") + "\n").write(toFile: NSTemporaryDirectory() + "macTEM-F7-ours.txt", atomically: true, encoding: .utf8)
    }

    // MARK: - The two-phase map

    private static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")

    private func sdssMap() throws -> CrystalMap {
        try ANGReader.read(url: Self.fixtures.appendingPathComponent("ebsd-sdss-ferrite-austenite.ang")).map
    }

    /// The reader's map is the model's map: the head of orix-data's Ti table read by `CTFReader` into a `CrystalMap`, its first
    /// three rows kept by a mask, 622 attached, gives the committed F7 numbers.
    func testTheCTFReaderHandsTheF7MapThrough() throws {
        let ref = try SEMParityReference.load("m3/ti-neighbour-misorientations")
        var map = try CTFReader.read(path: Self.fixtures.appendingPathComponent("sem/oxford/ti_orientations_head.ctf").path).map
        XCTAssertEqual(map.pointCount, 2000)
        map.phases = PhaseList([(1, Self.ti)])
        let head = map.masked((0..<map.size).map { $0 < 3 * 507 })
        XCTAssertEqual(head.shape, [3, 507])
        XCTAssertEqual(head.ids, Array(0..<(3 * 507)))
        let (h, v) = try NeighbourMisorientation.misorientations(of: head)
        SEMAssertParity(h.angles, try ref.array("horizontal_angles"))
        SEMAssertParity(v.angles, try ref.array("vertical_angles"))
        let histogram = AngleHistogram(values: try NeighbourMisorientation.anglesDegrees(of: head), edges: NeighbourMisorientation.f7Edges)
        SEMAssertParity(histogram.counts.map(Double.init), try ref.array("counts"))
    }

    func testTheTwoPhaseMapSlicesAsOrix() throws {
        let ref = try SEMParityReference.load("m3/crystal-map-sdss")
        let map = try sdssMap()
        XCTAssertEqual(map.shape, ref.values["shape"] as? [Int])
        XCTAssertEqual(map.size, ref.values["size"] as? Int)
        XCTAssertEqual(map.dx, ref.values["dx"] as? Double)
        XCTAssertEqual(map.dy, ref.values["dy"] as? Double)
        XCTAssertEqual(map.phases.ids, ref.values["phase_ids"] as? [Int])
        XCTAssertEqual(map.phases.names, ref.values["phase_names"] as? [String])
        XCTAssertEqual(map.phases.colors, ref.values["phase_colors"] as? [String])
        XCTAssertEqual(map.phases.pointGroupNames.compactMap { $0 }, ref.values["point_groups"] as? [String])
        XCTAssertEqual(map.allIndexed, ref.values["all_indexed"] as? Bool)
        XCTAssertEqual(map.isIndexed.filter { $0 }.count, ref.values["indexed_count"] as? Int)

        let slices = try XCTUnwrap(ref.values["phase_slices"] as? [String: [String: Any]])
        for (name, expected) in slices {
            let s = map[phase: name]
            XCTAssertEqual(s.size, expected["size"] as? Int, name)
            XCTAssertEqual(s.shape, expected["shape"] as? [Int], name)
            XCTAssertEqual(s.phasesInData.ids, expected["phases_in_data"] as? [Int], name)
        }

        let window = map.sliced(rows: 10..<20, columns: 5..<15)
        let w = try XCTUnwrap(ref.values["window"] as? [String: Any])
        XCTAssertEqual(window.size, w["size"] as? Int)
        XCTAssertEqual(window.shape, w["shape"] as? [Int])
        SEMAssertParity(window.row.map(Double.init), try ref.array("window_row"))
        SEMAssertParity(window.col.map(Double.init), try ref.array("window_col"))
        SEMAssertParity(window.ids.map(Double.init), try ref.array("window_id"))
        SEMAssertParity(try XCTUnwrap(window.mapData(named: "iq")), try ref.array("window_iq"))

        let ferrite = map[phase: try XCTUnwrap(ref.values["ferrite_name"] as? String)]
        SEMAssertParity(try XCTUnwrap(ferrite.mapData(named: "iq", fill: -1)), try ref.array("ferrite_iq_map"))
        SEMAssertParity(ferrite.row.map(Double.init), try ref.array("ferrite_row"))
        SEMAssertParity(ferrite.col.map(Double.init), try ref.array("ferrite_col"))
        SEMAssertParity(try XCTUnwrap(map.mapData(named: "phase_id")), try ref.array("phase_id_map"))

        let austenite = try map[phase: map.phases.names[0]].orientations()
        XCTAssertEqual(austenite.symmetry.name, ref.values["austenite_symmetry"] as? String)
        SEMAssertParity(flat(austenite.quaternions), try ref.array("austenite_quaternions"))
        XCTAssertThrowsError(try map.orientations()) { error in
            XCTAssertEqual(error as? CrystalMap.Refusal, .moreThanOnePhase(map.phases.names))
        }
    }

    // MARK: - orix's rules without a bundle

    /// A −1 in the phase ids adds `not_indexed` (white, no point group) in front; "indexed" slices it away; a phase list with
    /// more phases than the data drops the superfluous ones from the top, one with fewer gets free colours, both re-keyed to
    /// the data's ids (orix's `CrystalMap.__init__`).
    func testNotIndexedPointsAndPhaseListMatching() throws {
        let q = Array(repeating: SIMD4<Double>(1, 0, 0, 0), count: 6)
        let grid = CrystalMap.coordinates(shape: (2, 3))
        let ni = CrystalPhase(name: "Ni", pointGroup: "m-3m"), fe = CrystalPhase(name: "Fe", pointGroup: "m-3m", color: "tab:orange")
        let cu = CrystalPhase(name: "Cu", pointGroup: "m-3m", color: "tab:green")
        let map = try CrystalMap(rotations: q, phaseIDs: [1, -1, 1, 2, 2, -1], x: grid.x, y: grid.y,
                                 phaseList: PhaseList([(1, ni), (2, fe), (3, cu)]))
        XCTAssertEqual(map.phases.ids, [-1, 1, 2])
        XCTAssertEqual(map.phases.names, ["not_indexed", "Ni", "Fe"])
        XCTAssertEqual(map.phases[id: -1]?.color, "white")
        XCTAssertNil(map.phases[id: -1]?.pointGroup)
        XCTAssertEqual(map.isIndexed, [true, false, true, true, true, false])
        XCTAssertFalse(map.allIndexed)
        let indexed = map[phase: "indexed"]
        XCTAssertEqual(indexed.ids, [0, 2, 3, 4])
        XCTAssertEqual(indexed.phasesInData.ids, [1, 2])
        XCTAssertEqual(indexed.mapData(named: "phase_id")?.map { $0.isNaN ? -9 : $0 }, [1, -9, 1, 2, 2, -9])

        let renumbered = try CrystalMap(rotations: q, phaseIDs: [0, 0, 0, 4, 4, 4], x: grid.x, y: grid.y, phaseList: PhaseList([(1, ni)]))
        XCTAssertEqual(renumbered.phases.ids, [0, 4])
        // orix keeps a listed phase only under its own id: Ni (id 1) is not in the data, so both phases are new and unnamed.
        XCTAssertEqual(renumbered.phases.names, ["", ""])
        XCTAssertEqual(renumbered.phases.colors, ["tab:orange", "tab:green"])

        XCTAssertThrowsError(try CrystalMap(rotations: q, phaseIDs: [1, 2])) { error in
            XCTAssertEqual(error as? CrystalMap.Refusal, .lengthMismatch("phase ids"))
        }
    }

    /// A slice keeps its place in the grid (orix's `row`, `col`, `id`), a 1D map without coordinates takes x = 0, 1, 2, ...,
    /// and a neighbour operation on points that do not fill their rectangle is refused.
    func testSlicesKeepTheirPlaceAndPartialRectanglesAreRefused() throws {
        let q = (0..<12).map { i in Rotation.fromAxisAngle(SIMD3(0, 0, 1), Double(i) * 0.01).q }
        let grid = CrystalMap.coordinates(shape: (3, 4), steps: (2, 2))
        let map = try CrystalMap(rotations: q, phaseIDs: Array(repeating: 0, count: 12), x: grid.x, y: grid.y,
                                 phaseList: PhaseList([(0, CrystalPhase(name: "Ni", pointGroup: "m-3m"))]))
        XCTAssertEqual(map.row, [0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2])
        let window = map.sliced(rows: 1..<3, columns: 1..<3)
        XCTAssertEqual(window.ids, [5, 6, 9, 10])
        XCTAssertEqual(window.row, [0, 0, 1, 1])
        XCTAssertEqual(window.col, [0, 1, 0, 1])
        XCTAssertEqual(window.shape, [2, 2])
        XCTAssertEqual(window.sliced(rows: 1..<2).ids, [9, 10])
        XCTAssertEqual(window.mapData(named: "phase_id"), [0, 0, 0, 0])
        let (h, v) = try NeighbourMisorientation.misorientations(of: window)
        XCTAssertEqual(h.angles.count, 2)
        XCTAssertEqual(v.angles.count, 2)
        for a in h.angles { XCTAssertEqual(a, 0.01, accuracy: 1e-12) }
        for a in v.angles { XCTAssertEqual(a, 0.04, accuracy: 1e-12) }

        let line = try CrystalMap(rotations: Array(q.prefix(5)))
        XCTAssertEqual(line.shape, [5])
        XCTAssertEqual(line.x, [0, 1, 2, 3, 4])
        XCTAssertEqual(try NeighbourMisorientation.misorientations(of: line).vertical.quaternions.count, 0)

        let holed = map.masked([true, true, true, true, true, false, true, true, true, true, true, true])
        XCTAssertThrowsError(try NeighbourMisorientation.misorientations(of: holed)) { error in
            XCTAssertEqual(error as? CrystalMap.Refusal, .notARectangle(shape: [3, 4], points: 11))
        }
    }

    /// numpy's histogram rule: [e_i, e_i+1), the last bin closed, values outside and NaN left out.
    func testHistogramBinsAsNumpy() {
        let h = AngleHistogram(values: [0, 0.5, 1, 1.999, 2, 3, 3.0000001, -0.1, .nan], edges: [0, 1, 2, 3])
        XCTAssertEqual(h.counts, [2, 2, 2])
    }
}
