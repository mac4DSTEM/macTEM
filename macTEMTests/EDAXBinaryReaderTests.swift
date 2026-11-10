//
//  EDAXBinaryReaderTests.swift
//  The EDAX .up1/.up2 reader against kikuchipy 0.13.1 (`edax_binary.file_reader`): every Fixtures/ebsd-edax-binary*.up* reads with the
//  values of Fixtures/ebsd-edax.truth.json (tools/parity/sem-readers/make_edax_fixtures.py): the header, the navigation and pattern
//  shapes, the element type, kikuchipy's warning as the note, the first and last pattern and the sha256 of every pattern in map order;
//  version 2 and a damaged header (sizes whose products leave the Int range, an empty map) refused in words. Then the door
//  (`EDAXOpening`, one `EBSDDataset` whose patterns stay in the file): a hexagonal grid refused, the `.ang` next to the file paired by
//  name as the dataset's crystal map, the patterns read by map position bit-exact.
//

import CryptoKit
import FormatoCore
import TEMCore
import XCTest

nonisolated final class EDAXBinaryReaderTests: XCTestCase {

    nonisolated struct Header: Decodable {
        let sx: Int, sy: Int, nx: Int, ny: Int
        let patternOffset: Int, nPatterns: Int
        let dx: String, dy: String
        let isHex: Bool
        enum CodingKeys: String, CodingKey {
            case sx, sy, nx, ny, dx, dy
            case patternOffset = "pattern_offset", nPatterns = "n_patterns", isHex = "is_hex"
        }
    }

    nonisolated struct Truth: Decodable {
        let fileSHA256: String
        let version: Int
        let header: Header?
        let navShape: [Int]?
        let sigShape: [Int]?
        let dtype: String?
        let warnings: [String]?
        let patternsSHA256: String?
        let firstPattern: [Int]?
        let lastPattern: [Int]?
        let refused: String?
        enum CodingKeys: String, CodingKey {
            case version, header, dtype, warnings, refused
            case fileSHA256 = "file_sha256", navShape = "nav_shape", sigShape = "sig_shape", patternsSHA256 = "patterns_sha256"
            case firstPattern = "first_pattern", lastPattern = "last_pattern"
        }
    }

    nonisolated struct TruthFile: Decodable {
        let kikuchipy: String
        let up: [String: Truth]
    }

    static let fixturesFolder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")

    static func fixture(_ name: String) -> URL { fixturesFolder.appendingPathComponent(name) }

    static func truth() throws -> TruthFile {
        try JSONDecoder().decode(TruthFile.self, from: Data(contentsOf: fixture("ebsd-edax.truth.json")))
    }

    static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    private func ints(_ array: FormatoArray) -> [Int] { array.doubles().map { Int($0) } }

    func testTruthIsKikuchipy0131() throws {
        let truth = try Self.truth()
        XCTAssertEqual(truth.kikuchipy, "0.13.1")
        XCTAssertEqual(Set(truth.up.keys), ["ebsd-edax-binary.up1", "ebsd-edax-binary-hex.up2", "ebsd-edax-binary.up2", "ebsd-edax-binary-v2.up2"])
    }

    func testEveryFixtureReadsAsKikuchipyReadsIt() throws {
        for (name, expected) in try Self.truth().up where expected.refused == nil {
            let url = Self.fixture(name)
            XCTAssertEqual(Self.sha256(try Data(contentsOf: url)), expected.fileSHA256, "\(name): the fixture is not the one the truth was written from")
            let header = try XCTUnwrap(expected.header, name)
            let file = try EDAXBinaryReader.read(url: url)
            XCTAssertEqual(file.version, expected.version, name)
            XCTAssertEqual(file.patternColumns, header.sx, "\(name) sx")
            XCTAssertEqual(file.patternRows, header.sy, "\(name) sy")
            XCTAssertEqual(file.patternOffset, header.patternOffset, "\(name) offset")
            XCTAssertEqual(file.scanColumns, header.nx, "\(name) nx")
            XCTAssertEqual(file.scanRows, header.ny, "\(name) ny")
            XCTAssertEqual(file.patternCount, header.nPatterns, "\(name) n_patterns")
            let dx = try XCTUnwrap(Double(header.dx)), dy = try XCTUnwrap(Double(header.dy))
            XCTAssertEqual(file.stepX, dx, "\(name) dx")
            XCTAssertEqual(file.stepY, dy, "\(name) dy")
            XCTAssertEqual(file.isHexagonal, header.isHex, "\(name) is_hex")
            XCTAssertEqual(file.scanUnit, "um", name)
            XCTAssertEqual(file.dataType.rawValue, expected.dtype, "\(name) dtype")
            // kikuchipy's one navigation dimension is one row here.
            let nav = try XCTUnwrap(expected.navShape)
            XCTAssertEqual([file.scanRows, file.scanColumns], nav.count == 1 ? [1, nav[0]] : nav, "\(name) scan shape")
            XCTAssertEqual([file.patternRows, file.patternColumns], expected.sigShape, "\(name) pattern shape")
            XCTAssertEqual(file.note, expected.warnings?.first, "\(name) note")
            let all = try EDAXBinaryReader.allPatterns(file)
            XCTAssertEqual(all.shape, [file.scanRows, file.scanColumns, file.patternRows, file.patternColumns], "\(name) all patterns shape")
            XCTAssertEqual(Self.sha256(all.bytes), expected.patternsSHA256, "\(name): every pattern, bit for bit")
            let first = try EDAXBinaryReader.pattern(file, index: 0)
            XCTAssertEqual(first.shape, [file.patternRows, file.patternColumns], name)
            XCTAssertEqual(ints(first), expected.firstPattern, "\(name) first pattern")
            let last = try EDAXBinaryReader.pattern(file, row: file.scanRows - 1, column: file.scanColumns - 1)
            XCTAssertEqual(ints(last), expected.lastPattern, "\(name) last pattern")
            XCTAssertThrowsError(try EDAXBinaryReader.pattern(file, index: file.patternCount), name)
            XCTAssertThrowsError(try EDAXBinaryReader.pattern(file, row: file.scanRows, column: 0), name)
        }
    }

    func testVersion2IsRefusedAsUpstreamRefusesIt() throws {
        let expected = try XCTUnwrap(try Self.truth().up["ebsd-edax-binary-v2.up2"])
        let url = Self.fixture("ebsd-edax-binary-v2.up2")
        XCTAssertEqual(Self.sha256(try Data(contentsOf: url)), expected.fileSHA256)
        XCTAssertNotNil(expected.refused, "kikuchipy refuses version 2")
        XCTAssertThrowsError(try EDAXBinaryReader.read(url: url)) { error in
            let text = (error as? EDAXReadError)?.text ?? ""
            XCTAssertTrue(text.contains("version 2"), text)
        }
    }

    func testAShortFileAndAWrongExtensionAreRefusedInWords() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("edax-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        // A version 3 header that promises 3 x 4 patterns of 6 x 8 uint16 over 20 bytes of patterns.
        var bytes = Data()
        for word in [3, 8, 6, 42] as [UInt32] { withUnsafeBytes(of: word.littleEndian) { bytes.append(contentsOf: $0) } }
        bytes.append(0)
        for word in [4, 3] as [UInt32] { withUnsafeBytes(of: word.littleEndian) { bytes.append(contentsOf: $0) } }
        bytes.append(0)
        for value in [0.25, 0.5] { withUnsafeBytes(of: value.bitPattern.littleEndian) { bytes.append(contentsOf: $0) } }
        bytes.append(Data(count: 20))
        let short = folder.appendingPathComponent("short.up2")
        try bytes.write(to: short)
        XCTAssertThrowsError(try EDAXBinaryReader.read(url: short)) { error in
            XCTAssertTrue(((error as? EDAXReadError)?.text ?? "").contains("holds 0"), String(describing: error))
        }
        let header = folder.appendingPathComponent("header-only.up1")
        try Data([1, 0, 0]).write(to: header)
        XCTAssertThrowsError(try EDAXBinaryReader.read(url: header))
        let wrong = folder.appendingPathComponent("patterns.dat")
        try bytes.write(to: wrong)
        XCTAssertThrowsError(try EDAXBinaryReader.read(url: wrong)) { error in
            XCTAssertTrue(((error as? EDAXReadError)?.text ?? "").contains(".up1 or .up2"), String(describing: error))
        }
    }

    /// A header in the file's layout: version, sx, sy and the pattern offset, then from version 3 one pad byte, nx, ny, the hexagonal-grid
    /// flag (off) and the steps.
    private static func header(version: UInt32, sx: UInt32, sy: UInt32, offset: UInt32, nx: UInt32 = 1, ny: UInt32 = 1) -> Data {
        var bytes = Data()
        for word in [version, sx, sy, offset] { withUnsafeBytes(of: word.littleEndian) { bytes.append(contentsOf: $0) } }
        guard version >= 3 else { return bytes }
        bytes.append(0)
        for word in [nx, ny] { withUnsafeBytes(of: word.littleEndian) { bytes.append(contentsOf: $0) } }
        bytes.append(0)
        for value in [1.0, 1.0] { withUnsafeBytes(of: value.bitPattern.littleEndian) { bytes.append(contentsOf: $0) } }
        return bytes
    }

    func testADamagedHeaderIsRefusedInWordsInsteadOfTrapping() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("edax-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        func refusal(_ bytes: Data, _ name: String) throws -> String {
            let url = folder.appendingPathComponent(name)
            try bytes.write(to: url)
            do {
                _ = try EDAXBinaryReader.read(url: url)
                XCTFail("\(name) was read")
                return ""
            } catch {
                let text = (error as? EDAXReadError)?.text ?? String(describing: error)
                // A drop reads the same header: the refusal is the Open Files row's sentence, not a crash.
                XCTAssertEqual(FileRouting.inventory(path: url.path).refusal, text, name)
                return text
            }
        }
        // A pattern of (2^32 - 1)^2 pixels: sx * sy left the Int range and trapped.
        let huge = try refusal(Self.header(version: 3, sx: .max, sy: .max, offset: 42), "huge-pattern.up1")
        XCTAssertEqual(huge, "huge-pattern.up1 states a 4294967295 x 4294967295 pattern, larger than the whole file (42 bytes).")
        // A map of (2^32 - 1)^2 patterns: nx * ny left the Int range and trapped.
        let map = try refusal(Self.header(version: 3, sx: 1, sy: 1, offset: 42, nx: .max, ny: .max), "huge-map.up2")
        XCTAssertEqual(map, "huge-map.up2 states 4294967295 x 4294967295 patterns of 1 x 1 but holds 0.")
        // A map with no columns, and a version 1 file with no pattern after its header, opened as empty scans.
        let empty = try refusal(Self.header(version: 3, sx: 8, sy: 8, offset: 42, nx: 0, ny: 3), "no-columns.up1")
        XCTAssertEqual(empty, "no-columns.up1 states a 3 x 0 map.")
        let none = try refusal(Self.header(version: 1, sx: 8, sy: 8, offset: 16) + Data(count: 63), "no-pattern.up1")
        XCTAssertEqual(none, "no-pattern.up1 holds no complete 8 x 8 pattern after byte 16 (79 bytes).")
    }

    // MARK: The door

    func testAHexagonalGridIsRefusedAtTheDoorInWords() throws {
        let url = Self.fixture("ebsd-edax-binary-hex.up2")
        XCTAssertNoThrow(try EDAXBinaryReader.read(url: url), "the reader reads it as kikuchipy does")
        XCTAssertThrowsError(try EDAXOpening.open(url: url)) { error in
            let text = (error as? EDAXReadError)?.text ?? ""
            XCTAssertTrue(text.contains("hexagonal grid"), text)
            XCTAssertTrue(text.contains("ebsd-edax-binary-hex.up2"), text)
        }
        XCTAssertEqual(FileRouting.inventory(path: url.path).refusal, "ebsd-edax-binary-hex.up2 was acquired on a hexagonal grid; only square-grid EBSD maps are read.")
        XCTAssertThrowsError(try EDAXOpening.open(url: Self.fixture("ebsd-tsl-hex.ang"))) { error in
            let text = (error as? EDAXReadError)?.text ?? ""
            XCTAssertTrue(text.contains("hexagonal grid"), text)
        }
    }

    func testTheANGNextToTheFileIsPairedByNameAndGivesAVersion1FileItsGrid() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("edax-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let up1 = folder.appendingPathComponent("scan.up1")
        try FileManager.default.copyItem(at: Self.fixture("ebsd-edax-binary.up1"), to: up1)
        // Alone: nine patterns in one row, no map, kikuchipy's default detector; the patterns are the file's records, bit-exact.
        let alone = try EDAXOpening.open(url: up1)
        XCTAssertNil(alone.crystalMap)
        XCTAssertEqual(alone.format, .edaxBinary)
        XCTAssertEqual([alone.scanRows, alone.scanColumns], [1, 9])
        XCTAssertEqual(alone.notes, [])
        XCTAssertEqual(alone.detector.projectionCenters, [SIMD3(0.5, 0.5, 0.5)])
        let file = try EDAXBinaryReader.read(url: up1)
        XCTAssertEqual(alone.patterns.layout, .records(offset: file.patternOffset, recordBytes: file.bytesPerPattern, patternOffset: 0))
        XCTAssertEqual(try alone.allPatterns(), try EDAXBinaryReader.allPatterns(file))
        XCTAssertEqual(try EBSDPatternReader(alone).pattern(row: 0, column: 8), try EDAXBinaryReader.pattern(file, index: 8))
        XCTAssertEqual(FileRouting.inventory(path: up1.path), FileInventory(ebsdPatterns: true))
        // A 3 x 3 EDAX map with the same name: the scan takes its grid and step.
        let header = try String(contentsOf: Self.fixture("ebsd-tsl.ang"), encoding: .utf8).split(separator: "\n").filter { $0.hasPrefix("#") }
            .map { $0.replacingOccurrences(of: "NCOLS_ODD: 4", with: "NCOLS_ODD: 3").replacingOccurrences(of: "NCOLS_EVEN: 4", with: "NCOLS_EVEN: 3") }
        var rows: [String] = []
        for r in 0..<3 { for c in 0..<3 { rows.append("0.1 0.2 0.3 \(Double(c) * 2) \(Double(r) * 2) 100.0 0.5 1 1000 0.5") } }
        let ang = folder.appendingPathComponent("scan.ang")
        try (header + rows).joined(separator: "\n").appending("\n").write(to: ang, atomically: true, encoding: .utf8)
        let paired = try EDAXOpening.open(url: up1)
        let map = try XCTUnwrap(paired.crystalMap)
        XCTAssertEqual(map.pointCount, 9)
        XCTAssertEqual(map.shape, [3, 3])
        XCTAssertEqual(map.phaseIDs, [Int](repeating: 1, count: 9))
        XCTAssertEqual(map.phases.ids, [1])
        XCTAssertEqual(map.rotations[0], RotationConversions.eu2qu(SIMD3(0.1, 0.2, 0.3)))
        XCTAssertEqual(map.euler[0], SIMD3(0.1, 0.2, 0.3))
        XCTAssertEqual([paired.scanRows, paired.scanColumns], [3, 3])
        XCTAssertEqual(paired.stepX, 2)
        XCTAssertEqual(paired.stepY, 2)
        XCTAssertEqual(paired.notes, [])
        let angHeader = try ANGReader.read(url: ang).header
        XCTAssertEqual(paired.detector.projectionCenters, [paired.detector.brukerCenter(try XCTUnwrap(angHeader.projectionCenter), from: .tsl)], "the .ang's PC is TSL's")
        XCTAssertEqual(paired.sem.workingDistanceMM, angHeader.workingDistance)
        // Opened from the .ang side the same scan comes back, and the routing sends it to the Patterns room.
        let fromMap = try EDAXOpening.open(url: ang)
        XCTAssertEqual(fromMap.patterns.url, up1)
        XCTAssertEqual(fromMap, paired)
        XCTAssertEqual(FileRouting.inventory(path: ang.path), FileInventory(ebsdPatterns: true))
        XCTAssertEqual(try EBSDOpening.open(url: ang).dataset, paired)
        // A map of another point count is left out with a note; the patterns still open.
        try FileManager.default.removeItem(at: ang)
        try FileManager.default.copyItem(at: Self.fixture("ebsd-tsl.ang"), to: ang)
        let mismatched = try EDAXOpening.open(url: up1)
        XCTAssertNil(mismatched.crystalMap)
        XCTAssertEqual(mismatched.notes.count, 1)
        XCTAssertTrue(mismatched.notes[0].contains("12 points for 9 patterns"), mismatched.notes[0])
        XCTAssertEqual([mismatched.scanRows, mismatched.scanColumns], [1, 9])
        // A map alone, without its patterns: the pattern door refuses it with the sentence that names them (D-SEM-25); the routing sends it to
        // the Maps room (P3-04).
        try FileManager.default.removeItem(at: up1)
        XCTAssertThrowsError(try EDAXOpening.open(url: ang)) { error in
            XCTAssertTrue(((error as? EDAXReadError)?.text ?? "").hasPrefix("scan.ang is an orientation map without its patterns"), String(describing: error))
        }
        XCTAssertEqual(FileRouting.inventory(path: ang.path), FileInventory(orientationMap: true))
    }

    func testAnUnreadableCompanionLeavesANoteAndAnUnreadableMainFileThrows() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("edax-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let up2 = folder.appendingPathComponent("scan.up2")
        try FileManager.default.copyItem(at: Self.fixture("ebsd-edax-binary.up2"), to: up2)
        let ang = folder.appendingPathComponent("scan.ang")
        try "# GRID: SqrGrid\nnot a number\n".write(to: ang, atomically: true, encoding: .utf8)
        let scan = try EDAXOpening.open(url: up2)
        XCTAssertNil(scan.crystalMap)
        XCTAssertEqual(scan.notes.count, 1)
        XCTAssertTrue(scan.notes[0].hasPrefix("scan.ang next to it was not read:"), scan.notes[0])
        XCTAssertEqual([scan.scanRows, scan.scanColumns], [3, 4])
        XCTAssertThrowsError(try EDAXOpening.open(url: ang))
    }

    /// A companion `.ang` that reads but whose coordinates make no grid (here a second x that is NaN) is left out with the door's
    /// note, as an unreadable one is; the patterns open on their own. The `.ang` opened itself still fails. Red before: the open of
    /// the `.up2` threw the crystal map's refusal, which names neither file, and the patterns did not open.
    func testACompanionAngWhoseCoordinatesMakeNoGridLeavesANote() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("edax-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let up2 = folder.appendingPathComponent("scan.up2")
        try FileManager.default.copyItem(at: Self.fixture("ebsd-edax-binary.up2"), to: up2)
        let header = try String(contentsOf: Self.fixture("ebsd-tsl.ang"), encoding: .utf8).split(separator: "\n").filter { $0.hasPrefix("#") }
            .map(String.init)
        let rows = ["0.1 0.2 0.3 0 0 100.0 0.5 1 1000 0.5", "0.1 0.2 0.3 nan 0 100.0 0.5 1 1000 0.5"]
        let ang = folder.appendingPathComponent("scan.ang")
        try (header + rows).joined(separator: "\n").appending("\n").write(to: ang, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try ANGReader.read(url: ang)) { error in
            XCTAssertEqual(error as? CrystalMap.Refusal, .coordinates("x holds a value that is not a finite number"))
        }
        let scan = try EDAXOpening.open(url: up2)
        XCTAssertNil(scan.crystalMap)
        XCTAssertEqual([scan.scanRows, scan.scanColumns], [3, 4])
        XCTAssertEqual(scan.notes, ["scan.ang next to it was not read: The crystal map's coordinates make no grid: x holds a value that is not "
            + "a finite number."])
        XCTAssertEqual(try EBSDOpening.open(url: up2).dataset, scan)
        XCTAssertThrowsError(try EDAXOpening.open(url: ang), "the map opened itself keeps failing")
    }
}
