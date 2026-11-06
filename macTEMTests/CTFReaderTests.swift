//
//  CTFReaderTests.swift
//  CTFReader against orix 0.15.0: the Channel Text Files orix's reader tests write (Oxford, Bruker, ASTAR, EMsoft, MTEX) and the
//  head of orix-data's Ti_orientations.ctf (Fixtures/sem/oxford, from tools/parity/sem-readers/make_oxford_fixtures.py) read with
//  the values orix.io.load and orix.data.ti_orientations give: phases with lattice and Laue group exact, coordinates, phase ids,
//  Euler angles in degrees and the vendor's property columns within 1e-12 (the numbers are parsed, not computed; 1e-12 is
//  the brief's bar), the map shape and steps orix derives from the coordinates. The whole Ti file is the opt-in real-data
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

    func assertReadsAsOrix(_ name: String, vendor: CrystalMapData.Vendor, file: StaticString = #filePath, line: UInt = #line) throws {
        let truth = try JSONDecoder().decode(Truth.self, from: Data(contentsOf: Self.folder.appendingPathComponent(name + ".json")))
        let map = try CTFReader.read(path: Self.folder.appendingPathComponent(name).path)
        XCTAssertEqual(map.vendor, vendor, name, file: file, line: line)
        XCTAssertEqual(map.pointCount, truth.size, "\(name): points", file: file, line: line)
        XCTAssertEqual(map.shape, truth.shape, "\(name): shape", file: file, line: line)
        XCTAssertEqual(map.scanUnit, truth.scanUnit, name, file: file, line: line)
        assertClose(map.stepSizes, truth.stepSizes, "\(name): steps", file: file, line: line)
        assertClose(map.x, truth.x, "\(name): x", file: file, line: line)
        assertClose(map.y, truth.y, "\(name): y", file: file, line: line)
        XCTAssertEqual(map.phaseID, truth.phaseID, "\(name): phase ids", file: file, line: line)
        assertClose(map.eulerDegrees, truth.eulerDegrees.flatMap { $0 }, "\(name): Euler angles", file: file, line: line)
        XCTAssertEqual(map.propertyNames, truth.propNames, "\(name): property names", file: file, line: line)
        for property in truth.propNames {
            assertClose(map.properties[property] ?? [], truth.props[property] ?? [], "\(name): \(property)", file: file, line: line)
        }
        // orix lists the not-indexed phase (-1) first; the file's phases follow with their ids.
        let indexed = truth.phases.filter { $0.id > 0 }
        XCTAssertEqual(map.phases.map(\.id), indexed.map(\.id), "\(name): phase ids in the header", file: file, line: line)
        for (ours, theirs) in zip(map.phases, indexed) {
            XCTAssertEqual(ours.name, theirs.name, name, file: file, line: line)
            XCTAssertEqual(ours.pointGroup, theirs.pointGroup, "\(name): point group of \(theirs.name)", file: file, line: line)
            XCTAssertEqual(ours.spaceGroup, theirs.spaceGroup, "\(name): space group of \(theirs.name)", file: file, line: line)
            assertClose(ours.lattice, theirs.lattice ?? [], "\(name): lattice of \(theirs.name)", file: file, line: line)
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
        let map = try CTFReader.read(path: Self.folder.appendingPathComponent("oxford.ctf").path)
        XCTAssertEqual(map.header.first, "Channel Text File")
        XCTAssertEqual(map.phases.map(\.name), ["Iron fcc", "Iron bcc"])
        XCTAssertEqual(map.phases.map(\.laueGroupID), [11, 11])
        XCTAssertEqual(map.phases.map(\.pointGroup), ["m-3m", "m-3m"])
        XCTAssertEqual(map.phases.map(\.spaceGroup), [225, 229])
        XCTAssertEqual(map.phases[0].lattice, [3.66, 3.66, 3.66, 90, 90, 90])
        XCTAssertEqual(map.shape, [5, 3])
        XCTAssertEqual(map.euler(at: 0).Phi, 54.5696)
    }

    /// orix-data's Ti_orientations.ctf (Krakow et al. 2017, CC BY 4.0) is an MTEX export without the Channel Text File header:
    /// the first line names its columns. orix reads phi1, Phi, phi2 with numpy and attaches the 622 point group by hand; the
    /// reader keeps every column under its name and the caller attaches the phase (D-SEM-12).
    func testTheTiOrientationTableReadsAsOrix() throws {
        let truth = try JSONDecoder().decode(TiTruth.self, from: Data(contentsOf: Self.folder.appendingPathComponent("ti_orientations.json")))
        let map = try CTFReader.read(path: Self.folder.appendingPathComponent("ti_orientations_head.ctf").path)
        XCTAssertEqual(map.vendor, .orientationTable)
        XCTAssertEqual(map.pointCount, truth.head.rows)
        XCTAssertEqual(map.header[0].split(separator: " ").map(String.init), truth.columns)
        assertClose(map.eulerDegrees, truth.head.eulerDegrees.flatMap { $0 }, "Euler angles")
        XCTAssertEqual(map.phaseID, [Int](repeating: 1, count: truth.head.rows))
        XCTAssertEqual(map.propertyNames, ["bands", "bc", "bs", "error", "mad", "grainId", "mis2mean"])
        for (column, name) in truth.columns.enumerated() {
            let theirs = truth.head.all.map { $0[column] }
            let ours: [Double]
            switch name {
            case "phi1": ours = stride(from: 0, to: map.eulerDegrees.count, by: 3).map { map.eulerDegrees[$0] }
            case "Phi": ours = stride(from: 1, to: map.eulerDegrees.count, by: 3).map { map.eulerDegrees[$0] }
            case "phi2": ours = stride(from: 2, to: map.eulerDegrees.count, by: 3).map { map.eulerDegrees[$0] }
            case "phase": ours = map.phaseID.map(Double.init)
            case "x": ours = map.x
            case "y": ours = map.y
            default: ours = map.properties[name] ?? []
            }
            assertClose(ours, theirs, name)
        }
        XCTAssertEqual(map.stepSizes, [0.25, 0.25])
        XCTAssertEqual(truth.pointGroup, "622")
        var withPhase = map
        withPhase.phases = [CrystalMapData.Phase(id: 1, name: "Ti", lattice: [2.95, 2.95, 4.68, 90, 90, 120], laueGroupID: 9, pointGroup: "622", spaceGroup: 194)]
        XCTAssertEqual(withPhase.phases[0].pointGroup, truth.pointGroup)
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
        let map = try CTFReader.read(path: path)
        XCTAssertEqual(map.pointCount, truth.full.rows)
        for (row, euler) in zip(truth.full.sampleRows, truth.full.sampleEulerDegrees) {
            let ours = map.euler(at: row)
            assertClose([ours.phi1, ours.Phi, ours.phi2], euler, "row \(row)")
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
