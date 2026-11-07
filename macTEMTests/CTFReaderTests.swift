//
//  CTFReaderTests.swift
//  CTFReader against orix 0.15.0: the Channel Text Files orix's reader tests write (Oxford, Bruker, ASTAR, EMsoft, MTEX) and the
//  head of orix-data's Ti_orientations.ctf (Fixtures/sem/oxford, from tools/parity/sem-readers/make_oxford_fixtures.py) read with
//  the values orix.io.load and orix.data.ti_orientations give: phases with lattice and Laue group exact, coordinates, phase ids,
//  Euler angles (the file's degrees to radians as orix converts them) and the vendor's property columns within 1e-12 (the numbers
//  are parsed, not computed; 1e-12 is the brief's bar), the map shape and steps orix derives from the coordinates. The whole Ti file is the opt-in real-data
//  test (MACTEM_REAL_DATA=1 with $MACEM_DATA/sem/Ti_orientations.ctf).
//

import TEMCore
import XCTest

nonisolated final class CTFReaderTests: XCTestCase {

    nonisolated struct Truth: Decodable {
        nonisolated struct Phase: Decodable {
            let id: Int
            let name: String
            let pointGroup: String?
            let spaceGroup: Int?
            let lattice: [Double]?
        }
        let shape: [Int]
        let size: Int
        let scanUnit: String
        let stepSizes: [Double]
        let x: [Double]
        let y: [Double]
        let phaseID: [Int]
        let eulerDegrees: [[Double]]
        let props: [String: [Double]]
        let propNames: [String]
        let phases: [Phase]
    }

    nonisolated struct TiTruth: Decodable {
        nonisolated struct Head: Decodable {
            let rows: Int
            let eulerDegrees: [[Double]]
            let all: [[Double]]
        }
        nonisolated struct Full: Decodable {
            let rows: Int
            let sampleRows: [Int]
            let sampleEulerDegrees: [[Double]]
        }
        let sha256: String
        let pointGroup: String
        let columns: [String]
        let head: Head
        let full: Full
    }

    static let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/sem/oxford")
    static let tolerance = 1e-12

    /// orix's radians of the file's degrees (`np.deg2rad`).
    static func radians(_ degrees: [[Double]]) -> [Double] { degrees.flatMap { $0 }.map { $0 * (Double.pi / 180) } }

    static func flat(_ euler: [SIMD3<Double>]) -> [Double] { euler.flatMap { [$0.x, $0.y, $0.z] } }

    func assertReadsAsOrix(_ name: String, vendor: CTFReader.Vendor, file: StaticString = #filePath, line: UInt = #line) throws {
        let truth = try JSONDecoder().decode(Truth.self, from: Data(contentsOf: Self.folder.appendingPathComponent(name + ".json")))
        let read = try CTFReader.read(path: Self.folder.appendingPathComponent(name).path)
        let map = read.map
        XCTAssertEqual(read.vendor, vendor, name, file: file, line: line)
        XCTAssertEqual(map.pointCount, truth.size, "\(name): points", file: file, line: line)
        XCTAssertEqual(map.shape, truth.shape, "\(name): shape", file: file, line: line)
        XCTAssertEqual(read.scanUnit, truth.scanUnit, name, file: file, line: line)
        assertClose([map.dy, map.dx], truth.stepSizes, "\(name): steps", file: file, line: line)
        assertClose(map.allX ?? [], truth.x, "\(name): x", file: file, line: line)
        assertClose(map.allY ?? [], truth.y, "\(name): y", file: file, line: line)
        XCTAssertEqual(map.phaseIDs, truth.phaseID, "\(name): phase ids", file: file, line: line)
        assertClose(Self.flat(map.euler), Self.radians(truth.eulerDegrees), "\(name): Euler angles", file: file, line: line)
        XCTAssertEqual(read.propertyNames, truth.propNames, "\(name): property names", file: file, line: line)
        XCTAssertEqual(Set(map.properties.keys), Set(truth.propNames), "\(name): property columns", file: file, line: line)
        for property in truth.propNames {
            assertClose(map.properties[property] ?? [], truth.props[property] ?? [], "\(name): \(property)", file: file, line: line)
        }
        // orix's phase list: the not-indexed phase (-1) first when a point has it, the file's phases after it with their ids.
        XCTAssertEqual(map.phases.ids, truth.phases.map(\.id), "\(name): phase ids", file: file, line: line)
        let indexed = truth.phases.filter { $0.id > 0 }
        for (ours, theirs) in zip(map.phases.entries.filter { $0.id > 0 }.map(\.phase), indexed) {
            XCTAssertEqual(ours.name, theirs.name, name, file: file, line: line)
            XCTAssertEqual(ours.pointGroupName, theirs.pointGroup, "\(name): point group of \(theirs.name)", file: file, line: line)
            XCTAssertEqual(ours.spaceGroup, theirs.spaceGroup, "\(name): space group of \(theirs.name)", file: file, line: line)
            assertClose(ours.lattice ?? [], theirs.lattice ?? [], "\(name): lattice of \(theirs.name)", file: file, line: line)
        }
    }

    func assertClose(_ ours: [Double], _ theirs: [Double], _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(ours.count, theirs.count, "\(what): count", file: file, line: line)
        guard ours.count == theirs.count else { return }
        if let worst = zip(ours, theirs).enumerated().max(by: { abs($0.element.0 - $0.element.1) < abs($1.element.0 - $1.element.1) }),
           abs(worst.element.0 - worst.element.1) > Self.tolerance {
            XCTFail("\(what): [\(worst.offset)] \(worst.element.0) vs orix \(worst.element.1)", file: file, line: line)
        }
    }

    func testOxfordFileReadsAsOrix() throws { try assertReadsAsOrix("oxford.ctf", vendor: .oxfordOrBruker) }
    func testBrukerFileWithCommaDecimalsReadsAsOrix() throws { try assertReadsAsOrix("bruker.ctf", vendor: .oxfordOrBruker) }
    func testASTARFileRegeneratesItsCoordinatesAsOrix() throws { try assertReadsAsOrix("astar.ctf", vendor: .astar) }
    func testEMsoftFileRenamesItsColumnsAsOrix() throws { try assertReadsAsOrix("emsoft.ctf", vendor: .emsoft) }
    func testMTEXFileWithoutSpaceGroupReadsAsOrix() throws { try assertReadsAsOrix("mtex.ctf", vendor: .mtex) }

    func testTheOxfordHeaderIsKept() throws {
        let read = try CTFReader.read(path: Self.folder.appendingPathComponent("oxford.ctf").path)
        let map = read.map
        XCTAssertEqual(read.header.first, "Channel Text File")
        XCTAssertEqual(map.phases.names, ["not_indexed", "Iron fcc", "Iron bcc"])
        XCTAssertEqual(map.phases.pointGroupNames, [nil, "m-3m", "m-3m"], "Laue group 11 as orix names it")
        XCTAssertEqual(CTFReader.laueGroups[11], "m-3m")
        XCTAssertEqual(map.phases.phases.map(\.spaceGroup), [nil, 225, 229])
        XCTAssertEqual(map.phases[id: 1]?.lattice, [3.66, 3.66, 3.66, 90, 90, 90])
        XCTAssertEqual(map.phases.colors, ["white", "tab:blue", "tab:orange"])
        XCTAssertEqual(map.shape, [5, 3])
        XCTAssertEqual(map.euler[0].y, 54.5696 * (Double.pi / 180))
    }

    /// orix-data's Ti_orientations.ctf (Krakow et al. 2017, CC BY 4.0) is an MTEX export without the Channel Text File header:
    /// the first line names its columns. orix reads phi1, Phi, phi2 with numpy and attaches the 622 point group by hand; the
    /// reader keeps every column under its name and the caller attaches the phase (D-SEM-19).
    func testTheTiOrientationTableReadsAsOrix() throws {
        let truth = try JSONDecoder().decode(TiTruth.self, from: Data(contentsOf: Self.folder.appendingPathComponent("ti_orientations.json")))
        let read = try CTFReader.read(path: Self.folder.appendingPathComponent("ti_orientations_head.ctf").path)
        let map = read.map
        XCTAssertEqual(read.vendor, .orientationTable)
        XCTAssertEqual(map.pointCount, truth.head.rows)
        XCTAssertEqual(read.header[0].split(separator: " ").map(String.init), truth.columns)
        assertClose(Self.flat(map.euler), Self.radians(truth.head.eulerDegrees), "Euler angles")
        XCTAssertEqual(map.phaseIDs, [Int](repeating: 1, count: truth.head.rows))
        XCTAssertEqual(read.propertyNames, ["bands", "bc", "bs", "error", "mad", "grainId", "mis2mean"])
        for (column, name) in truth.columns.enumerated() {
            let theirs = truth.head.all.map { $0[column] }
            let ours: [Double]
            switch name {
            case "phi1": ours = map.euler.map { $0.x * (180 / Double.pi) }
            case "Phi": ours = map.euler.map { $0.y * (180 / Double.pi) }
            case "phi2": ours = map.euler.map { $0.z * (180 / Double.pi) }
            case "phase": ours = map.phaseIDs.map(Double.init)
            case "x": ours = map.allX ?? []
            case "y": ours = map.allY ?? []
            default: ours = map.properties[name] ?? []
            }
            assertClose(ours, theirs, name)
        }
        XCTAssertEqual([map.dy, map.dx], [0.25, 0.25])
        XCTAssertEqual(map.phases.ids, [1], "no phase list in the file: one unnamed phase for id 1, as orix's CrystalMap makes it")
        XCTAssertEqual(truth.pointGroup, "622")
        var withPhase = map
        withPhase.phases = PhaseList([(1, CrystalPhase(name: "Ti", spaceGroup: 194, pointGroup: "622", lattice: [2.95, 2.95, 4.68, 90, 90, 120]))])
        XCTAssertEqual(withPhase.phases[id: 1]?.pointGroupName, truth.pointGroup)
        XCTAssertEqual(try withPhase.orientations().symmetry.name, "622")
    }

    /// The whole 193167-row file against orix, every 997th row: opt-in on a Mac with the file under $MACEM_DATA/sem/.
    func testTheWholeTiFileReadsAsOrix() throws {
        let flag = FileManager.default.fileExists(atPath: NSTemporaryDirectory() + "macTEM-real-data.flag")
        guard ProcessInfo.processInfo.environment["MACTEM_REAL_DATA"] == "1" || flag else { throw XCTSkip("opt-in: TEST_RUNNER_MACTEM_REAL_DATA=1, or create $TMPDIR/macTEM-real-data.flag") }
        let root = ProcessInfo.processInfo.environment["MACEM_DATA"] ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("data").path
        let path = root + "/sem/Ti_orientations.ctf"
        try XCTSkipUnless(FileManager.default.fileExists(atPath: path), "no real file at \(path)")
        let truth = try JSONDecoder().decode(TiTruth.self, from: Data(contentsOf: Self.folder.appendingPathComponent("ti_orientations.json")))
        let map = try CTFReader.read(path: path).map
        XCTAssertEqual(map.pointCount, truth.full.rows)
        for (row, euler) in zip(truth.full.sampleRows, truth.full.sampleEulerDegrees) {
            assertClose(Self.flat([map.euler[row]]), Self.radians([euler]), "row \(row)")
        }
        XCTAssertEqual(map.shape, [381, 507])
    }

    func testAFileWithoutColumnsIsRefusedByName() throws {
        XCTAssertThrowsError(try CTFReader.read(text: "Channel Text File\nPrj x\n")) { error in
            XCTAssertEqual(error as? CTFReader.Refusal, .noColumnLine)
        }
        XCTAssertThrowsError(try CTFReader.read(text: "Channel Text File\nPhase\tX\tY\tBands\tError\tEuler1\tEuler2\tEuler3\tMAD\tBC\tBS\n1 0 0 1 0 1 2 3 0 0 0\n")) { error in
            XCTAssertEqual(error as? CTFReader.Refusal, .noPhases)
        }
        let short = "Channel Text File\nPhases\t1\n3.6;3.6;3.6\t90;90;90\tNi\t11\t225\nPhase\tX\tY\tBands\tError\tEuler1\tEuler2\tEuler3\tMAD\tBC\tBS\n1 0 0 1 0 1 2\n"
        XCTAssertThrowsError(try CTFReader.read(text: short)) { error in
            XCTAssertEqual(error as? CTFReader.Refusal, .row(line: 5, columns: 7, needed: 11))
        }
        for refusal in [CTFReader.Refusal.notText, .noColumnLine, .noPhases, .row(line: 1, columns: 1, needed: 11), .number(line: 1, "x")] {
            XCTAssertTrue(refusal.reason.hasSuffix("."), refusal.reason)
        }
    }
}
