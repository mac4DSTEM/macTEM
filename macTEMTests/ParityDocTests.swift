//
//  ParityDocTests.swift
//  docs/parity.md against the readers it describes: the h5ebsd rows say what `EBSDH5Reader` refuses, in the reader's own words, and
//  name the test that reaches those refusals, so a sentence reworded in the code and not on the page goes red here.
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

    /// The section of docs/parity.md under `## <heading>`, up to the next `## ` heading, flattened.
    private func section(_ heading: String) throws -> String {
        let page = try String(contentsOf: root.appendingPathComponent("docs/parity.md"), encoding: .utf8)
        let start = try XCTUnwrap(page.range(of: "\n## \(heading)\n"), "docs/parity.md has no section '## \(heading)'")
        let rest = page[start.upperBound...]
        return flat(String(rest[..<(rest.range(of: "\n## ")?.lowerBound ?? rest.endIndex)]))
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
}
