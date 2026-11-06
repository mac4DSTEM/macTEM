//
//  OxfordBinaryReaderTests.swift
//  OxfordBinaryReader against kikuchipy 0.13.1: kikuchipy's own patterns.ebsp and the dummy layouts its reader tests write
//  (Fixtures/sem/oxford, from tools/parity/sem-readers/make_oxford_fixtures.py) read with the values kikuchipy.load gives:
//  version, shapes, pixel type, steps, the beam and map positions, the file order, and every pixel bit-exact (the `.u8`/`.u16`
//  file beside each `.json` is the pattern array in map order as numpy returned it). Red before the reader existed: the
//  fixtures had no reader.
//

import TEMCore
import XCTest

nonisolated final class OxfordBinaryReaderTests: XCTestCase {

    nonisolated struct Truth: Decodable {
        let refused: String?
        let loadFails: Bool?
        let version: Int?
        let nPatternsInHeader: Int?
        let navigationShape: [Int]?
        let signalShape: [Int]?
        let dtype: String?
        let stepSizes: [Double]?
        let scanUnit: String?
        let map1dID: [Int]?
        let fileOrder: [Int]?
        let beamX: [Double]?
        let beamY: [Double]?
        let mapX: [Double]?
        let mapY: [Double]?
        let patterns: String?
        enum CodingKeys: String, CodingKey {
            case refused, loadFails, version, nPatternsInHeader, navigationShape, signalShape, dtype, stepSizes, scanUnit, map1dID,
                 fileOrder, patterns
            case beamX = "beam_x"
            case beamY = "beam_y"
            case mapX = "map_x"
            case mapY = "map_y"
        }
    }

    static let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/sem/oxford")

    static func truth(_ name: String) throws -> Truth {
        try JSONDecoder().decode(Truth.self, from: Data(contentsOf: folder.appendingPathComponent(name + ".json")))
    }

    /// The pixels numpy returned, little-endian, as the reader's pixel type.
    static func referencePixels(_ truth: Truth) throws -> EBSDPatternSet.Pixels {
        let bytes = try Data(contentsOf: folder.appendingPathComponent(XCTUnwrap(truth.patterns)))
        if truth.dtype == "uint16" {
            return .uint16(bytes.withUnsafeBytes { raw in (0..<(raw.count / 2)).map { UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: 2 * $0, as: UInt16.self)) } })
        }
        return .uint8([UInt8](bytes))
    }

    func assertReads(_ name: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let truth = try Self.truth(name)
        let path = Self.folder.appendingPathComponent(name).path
        if let refused = truth.refused {
            XCTAssertThrowsError(try OxfordBinaryReader.read(path: path), name, file: file, line: line) { error in
                XCTAssertEqual(error as? OxfordBinaryReader.Refusal, .compressed, "\(name): \(refused)", file: file, line: line)
            }
            return
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        XCTAssertEqual(try OxfordBinaryReader.patternCountInHeader(data: data), truth.nPatternsInHeader, "\(name): patterns in header", file: file, line: line)
        if truth.loadFails == true {
            // kikuchipy's conftest spaces the version-5 start table by the 16-byte header while writing the 24-byte one; kikuchipy
            // fails on it too (its own test checks only the count above).
            XCTAssertThrowsError(try OxfordBinaryReader.read(path: path), "\(name): kikuchipy cannot load it either", file: file, line: line)
            return
        }
        let set = try OxfordBinaryReader.read(path: path)
        XCTAssertEqual(set.navigationShape, truth.navigationShape, "\(name): navigation shape", file: file, line: line)
        XCTAssertEqual(set.patternShape, truth.signalShape, "\(name): pattern shape", file: file, line: line)
        XCTAssertEqual(set.pixels.bitsPerPixel, truth.dtype == "uint16" ? 16 : 8, "\(name): pixel type", file: file, line: line)
        XCTAssertEqual(set.stepSizes, truth.stepSizes, "\(name): steps", file: file, line: line)
        XCTAssertEqual(set.scanUnit, truth.scanUnit, "\(name): scan unit", file: file, line: line)
        XCTAssertEqual(set.map1DIDs, truth.map1dID, "\(name): map 1D ids", file: file, line: line)
        XCTAssertEqual(set.fileOrder, truth.fileOrder, "\(name): file order", file: file, line: line)
        XCTAssertEqual(set.beamX, truth.beamX, "\(name): beam x", file: file, line: line)
        XCTAssertEqual(set.beamY, truth.beamY, "\(name): beam y", file: file, line: line)
        XCTAssertEqual(set.mapX.map { $0.map(Double.init) }, truth.mapX, "\(name): map x", file: file, line: line)
        XCTAssertEqual(set.mapY.map { $0.map(Double.init) }, truth.mapY, "\(name): map y", file: file, line: line)
        XCTAssertEqual(set.pixels, try Self.referencePixels(truth), "\(name): pixels bit-exact", file: file, line: line)
        XCTAssertEqual(set.patternCount * set.pixelsPerPattern, set.pixels.count, "\(name): pixel count", file: file, line: line)
    }

    /// kikuchipy's test file: nickel_ebsd_small as a version-2 .ebsp, 3 x 3 patterns of 60 x 60 uint8, rolled one record in the
    /// file so the start table reorders them; the step 1.5 µm from the footers.
    func testKikuchipysPatternsReadBitExact() throws {
        try assertReads("patterns.ebsp")
        let set = try OxfordBinaryReader.read(path: Self.folder.appendingPathComponent("patterns.ebsp").path)
        XCTAssertEqual(set.navigationShape, [3, 3])
        XCTAssertEqual(set.stepSizes, [1.5, 1.5])
        XCTAssertEqual(set.fileOrder, [8, 0, 1, 2, 3, 4, 5, 6, 7])
        XCTAssertEqual(set.pattern(at: 0).count, 3600)
    }

    /// Every layout kikuchipy's reader tests write: versions 0, 1, 2, 4 (and the 5/6 count), uint16, a bigger map with
    /// 62 x 73 patterns, a file missing one pattern (a 1D list in pixels), and a compressed file refused by name.
    func testEveryKikuchipyLayoutReadsAsKikuchipy() throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: Self.folder.path)
            .filter { $0.hasPrefix("dummy-") && $0.hasSuffix(".ebsp") }.sorted()
        XCTAssertEqual(names.count, 10, "the fixture set")
        for name in names { try assertReads(name) }
    }

    func testAFileMissingOnePatternIsAListInPixels() throws {
        let set = try OxfordBinaryReader.read(path: Self.folder.appendingPathComponent("dummy-v2-missing.ebsp").path)
        XCTAssertEqual(set.navigationShape, [5])
        XCTAssertEqual(set.scanUnit, "px")
        XCTAssertEqual(set.map1DIDs, [1, 2, 3, 4, 5])
        XCTAssertEqual(set.beamY, [0, 1, 1, 1, 0])
        XCTAssertEqual(set.beamX, [2, 0, 1, 2, 0])
    }

    func testAVersion0FileHasNoPositions() throws {
        let set = try OxfordBinaryReader.read(path: Self.folder.appendingPathComponent("dummy-v0.ebsp").path)
        XCTAssertEqual(set.navigationShape, [6])
        XCTAssertNil(set.beamX)
        XCTAssertNil(set.beamY)
        XCTAssertNil(set.mapX)
    }

    func testTooShortAndTruncatedFilesAreRefusedByName() throws {
        XCTAssertThrowsError(try OxfordBinaryReader.read(data: Data([1, 2, 3]))) { error in
            XCTAssertEqual(error as? OxfordBinaryReader.Refusal, .tooShort)
        }
        let whole = try Data(contentsOf: Self.folder.appendingPathComponent("patterns.ebsp"))
        XCTAssertThrowsError(try OxfordBinaryReader.read(data: whole.prefix(whole.count - 100))) { error in
            guard case .truncated? = error as? OxfordBinaryReader.Refusal else { return XCTFail("\(error)") }
        }
        for refusal in [OxfordBinaryReader.Refusal.tooShort, .compressed, .noPatternTable, .truncated(needed: 2, have: 1)] {
            XCTAssertTrue(refusal.reason.hasSuffix("."), refusal.reason)
        }
    }
}
