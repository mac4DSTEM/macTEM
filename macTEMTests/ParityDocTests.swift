//
//  ParityDocTests.swift
//  docs/parity.md against the readers it describes: the h5ebsd rows say what `EBSDH5Reader` refuses, in the reader's own words, and
//  name the test that reaches those refusals, so a sentence reworded in the code and not on the page goes red here; the EDAX EDS row
//  says that the sandboxed app opens a map without its pixel size when the `.ipr` is not of the map's own name; the Thermo/FEI and
//  `cliffLorimer` rows name the kits' own ports of the same upstream code, so a later fix to one copy finds the others.
//  These read the page beside this test file; the page's line breaks do not count (a sentence may wrap).
//

import TEMCore
import XCTest

nonisolated final class ParityDocTests: XCTestCase {
    private let root = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath().deletingLastPathComponent()
        .deletingLastPathComponent()

    /// `text` with every run of spaces and line breaks made one space, so a sentence the page wraps still matches.
    private func flat(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// docs/parity.md as it is on disk.
    private func page() throws -> String {
        try String(contentsOf: root.appendingPathComponent("docs/parity.md"), encoding: .utf8)
    }

    /// The section of docs/parity.md under `## <heading>`, up to the next `## ` heading, flattened.
    private func section(_ heading: String) throws -> String {
        let text = try page()
        let start = try XCTUnwrap(text.range(of: "\n## \(heading)\n"), "docs/parity.md has no section '## \(heading)'")
        let rest = text[start.upperBound...]
        return flat(String(rest[..<(rest.range(of: "\n## ")?.lowerBound ?? rest.endIndex)]))
    }

    /// The table row of docs/parity.md that starts with `prefix`, flattened.
    private func row(startingWith prefix: String) throws -> String {
        let line = try page().split(separator: "\n").first { $0.hasPrefix(prefix) }
        return try flat(String(XCTUnwrap(line, "docs/parity.md has no row that starts with \(prefix)")))
    }

    /// The Readers section names `H5EBSDHeaderBoundsTests` and quotes the reader's refusals as the code words them: the tail of the
    /// sentence `wholeNumber` throws for NaN, and the two size sentences of `EBSDDataset.sizeRefusal` with the numbers the page uses.
    /// Red before #422: the page named neither the test nor any of these sentences.
    func testTheH5EBSDRowsStateTheirRefusals() throws {
        let readers = try section("Readers (exact)")
        XCTAssertTrue(readers.contains("H5EBSDHeaderBoundsTests"), "the h5ebsd rows do not name H5EBSDHeaderBoundsTests")
        var number = ""
        XCTAssertThrowsError(try EBSDH5Reader.wholeNumber(.nan, "x")) { number = ($0 as? EBSDReadError)?.text ?? "\($0)" }
        XCTAssertTrue(number.hasPrefix("x is nan, "), number)
        let tail = String(number.dropFirst("x is nan, ".count))
        XCTAssertFalse(tail.isEmpty, number)
        XCTAssertTrue(readers.contains(tail), "the Readers section does not say \"\(tail)\"")
        let sizes = [EBSDDataset.sizeRefusal(scanRows: 0, scanColumns: 75, patternRows: 60, patternColumns: 60, byteSize: 1),
                     EBSDDataset.sizeRefusal(scanRows: 55, scanColumns: 75, patternRows: 0, patternColumns: 60, byteSize: 1)]
        for size in sizes {
            let sentence = try flat(XCTUnwrap(size, "a scan or pattern of no rows is refused"))
            XCTAssertTrue(readers.contains(sentence), "the Readers section does not say \"\(sentence)\"")
        }
    }

    /// The `EDAXEDSReader.read` row says that an EDAX map's `.ipr`, named after its electron image, is read in the sandboxed app only
    /// when that name is the map's own (`RelatedFileAccess` asks macOS for a sibling of the picked file's name alone), and that the map
    /// otherwise opens without a pixel size, the reader's note unshown. Red before #424: the row named the `.ipr` and no limit.
    func testTheEDAXMapRowStatesTheIPRLimit() throws {
        let edax = try row(startingWith: "| `EDAXEDSReader.read`")
        XCTAssertTrue(edax.contains("RelatedFileAccess"), "the EDAXEDSReader.read row does not say which .ipr the sandboxed app can read")
        XCTAssertTrue(edax.contains("pixel size"), "the EDAXEDSReader.read row does not say the map can open without its pixel size")
        XCTAssertTrue(edax.contains("SEMEDSFile.notes"), "the EDAXEDSReader.read row does not say where the reader's note goes")
    }

    /// The Thermo/FEI row names FormatoKit's own FEI INI parsers, and the `cliffLorimer` row SpectroKit's Cliff-Lorimer and its public
    /// route. Red before #284: neither row named a kit counterpart.
    func testTheSEMPortsNameTheirKitCounterparts() throws {
        let fei = try row(startingWith: "| `SEMImageMetadata.read` (Thermo/FEI")
        XCTAssertTrue(fei.contains("FormatoKit"), "the Thermo/FEI row does not name FormatoKit")
        XCTAssertTrue(fei.contains("feiSections"), "the Thermo/FEI row does not name FormatoKit's FEI INI parsers")
        let cliffLorimer = try row(startingWith: "| `cliffLorimer`")
        XCTAssertTrue(cliffLorimer.contains("SpectroKit"), "the cliffLorimer row does not name SpectroKit")
        XCTAssertTrue(cliffLorimer.contains("CliffLorimer.weightFractions"), "the cliffLorimer row does not name SpectroKit's port")
        XCTAssertTrue(cliffLorimer.contains("EDXQuantification"), "the cliffLorimer row does not name SpectroKit's public route")
    }
}
