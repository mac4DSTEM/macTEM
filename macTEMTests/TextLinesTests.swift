//
//  TextLinesTests.swift
//  A text file saved on Windows (CRLF) or by a classic Mac program (CR) reads as its LF original, as Python's universal newlines
//  read it for orix (#518). AZtec on Windows writes its .ctf with CRLF; the reader split on "\n", which in Swift never matches the
//  one Character "\r\n", so the whole file was one line and was refused for having no column line.
//  Red before: every CRLF and CR case of the .ctf fixtures (refused: "no `Phase X Y ...` column line"), the CR cases of the .ang
//  fixtures, and TextLines, which did not exist.
//

import TEMCore
import XCTest

nonisolated final class TextLinesTests: XCTestCase {

    /// The three line ends Python reads as one, and an LF text split exactly as `split(separator: "\n")` splits it.
    func testTheThreeLineEndsSplitAsPythonsUniversalNewlines() {
        XCTAssertEqual(TextLines.split("a\nb\r\nc\rd"), ["a", "b", "c", "d"])
        XCTAssertEqual(TextLines.split("a\r\n\r\nb\r\n"), ["a", "", "b", ""], "an empty line and a last line end stay, as with LF")
        XCTAssertEqual(TextLines.split("a\r\r\nb"), ["a", "", "b"], "CR then CRLF are two line ends, as in Python")
        let lf = "Channel Text File\nPrj\tx\n\nPhase\tX\tY\n1\t0\t0\n"
        XCTAssertEqual(TextLines.split(lf), lf.split(separator: "\n", omittingEmptySubsequences: false))
        XCTAssertEqual(TextLines.split(""), [""])
    }

    /// The two line ends besides LF that Python's universal newlines read.
    static let lineEnds: [(label: String, bytes: [UInt8])] = [("CRLF", [0x0D, 0x0A]), ("CR", [0x0D])]

    /// `bytes` with every LF replaced by `lineEnd`, byte for byte, so the file's own encoding (a Latin-1 .ctf) is kept.
    static func withLineEnds(_ bytes: Data, _ lineEnd: [UInt8]) -> Data {
        Data(bytes.flatMap { $0 == 0x0A ? lineEnd : [$0] })
    }

    static func text(_ bytes: Data) throws -> String {
        try XCTUnwrap(String(data: bytes, encoding: .utf8) ?? String(data: bytes, encoding: .isoLatin1))
    }

    /// Every planted .ctf (Oxford, Bruker with comma decimals, ASTAR, EMsoft, MTEX, the Ti table) saved with CRLF or CR reads to
    /// the same file as its LF original: header, vendor, map, phases, columns.
    func testACTFSavedOnWindowsOrAClassicMacReadsAsItsLFOriginal() throws {
        for name in ["oxford.ctf", "bruker.ctf", "astar.ctf", "emsoft.ctf", "mtex.ctf", "ti_orientations_head.ctf"] {
            let bytes = try Data(contentsOf: CTFReaderTests.folder.appendingPathComponent(name))
            XCTAssertFalse(bytes.contains(0x0D), "\(name): the fixture is LF only")
            let original = try CTFReader.read(text: Self.text(bytes))
            for (label, end) in Self.lineEnds {
                let read = try CTFReader.read(text: Self.text(Self.withLineEnds(bytes, end)))
                XCTAssertEqual(read, original, "\(name) with \(label)")
            }
        }
    }

    /// The path a double-click takes: a CRLF .ctf on disk opens with its map, as the drive's AZtec file did not.
    func testACRLFCTFOnDiskOpens() throws {
        let bytes = try Data(contentsOf: CTFReaderTests.folder.appendingPathComponent("oxford.ctf"))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("crlf-\(UUID().uuidString).ctf")
        try Self.withLineEnds(bytes, [0x0D, 0x0A]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let read = try CTFReader.read(path: url.path)
        XCTAssertEqual(read.header.first, "Channel Text File", "no \\r left on a header line")
        XCTAssertEqual(read.map.shape, [5, 3])
        XCTAssertEqual(read.map.phases.names, ["not_indexed", "Iron fcc", "Iron bcc"])
    }

    /// Every .ang fixture saved with CRLF (read before) or CR (refused or misread before) reads to the same map as its LF original.
    func testAnANGSavedOnWindowsOrAClassicMacReadsAsItsLFOriginal() throws {
        for name in ["ebsd-tsl.ang", "ebsd-tsl-hex.ang", "ebsd-sdss-ferrite-austenite.ang"] {
            let url = EDAXBinaryReaderTests.fixture(name)
            let bytes = try Data(contentsOf: url)
            XCTAssertFalse(bytes.contains(0x0D), "\(name): the fixture is LF only")
            let original = try ANGReader.read(text: Self.text(bytes), url: url)
            for (label, end) in Self.lineEnds {
                let read = try ANGReader.read(text: Self.text(Self.withLineEnds(bytes, end)), url: url)
                XCTAssertEqual(read, original, "\(name) with \(label)")
            }
        }
    }
}
