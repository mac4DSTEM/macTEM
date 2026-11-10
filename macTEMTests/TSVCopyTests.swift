//
//  TSVCopyTests.swift
//  ⌘C's lines keep their columns (#287): a tab or a line break inside a cell (a file's name) becomes a space in each of the three
//  table copies, which write their lines through one helper (`TSV.line`); and the error alert's Copy Details writes through the
//  app's one pasteboard writer (`SystemPaneTextWriter`).
//

import TEMCore
import XCTest
@testable import macTEM

nonisolated final class TSVCopyTests: XCTestCase {

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    /// One field per cell, whatever a cell holds: a tab, a line feed, a carriage return or the pair (one space) becomes a space.
    /// Red before: no such helper.
    func testALineKeepsOneFieldPerCell() {
        XCTAssertEqual(TSV.line(["a", "b"]), "a\tb")
        XCTAssertEqual(TSV.line(["a\tb", "c\r\nd", "e\nf", "g\rh"]), "a b\tc d\te f\tg h", "a CRLF is one space")
        XCTAssertEqual(TSV.line([]), "")
        XCTAssertEqual(TSV.line(["", ""]), "\t", "an empty cell keeps its column")
    }

    /// The SEM session table's ⌘C: a row whose source holds a tab pastes as its five columns, and a line break in a name does not
    /// start a row. Red before: six fields, and three lines for two rows.
    func testTheSEMSessionCopyKeepsFiveColumnsWhenASourceHoldsATab() {
        let row = SEMSessionRow(id: "export:0", kind: .export, label: "scan indexed.ang", value: "EDAX ANG", source: "a\tb.ang")
        let fields = ResultsSessionFormat.copyText([row]).components(separatedBy: "\t")
        XCTAssertEqual(fields.count, 5, "\(fields)")
        XCTAssertEqual(fields[2], "a b.ang")
        let dataset = SEMSessionRow(id: "dataset", kind: .dataset, label: "a\nb.h5", value: "HDF5", source: "Patterns")
        let lines = ResultsSessionFormat.copyText([row, dataset]).components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 2, "\(lines)")
        XCTAssertEqual(lines.last?.components(separatedBy: "\t").first, "a b.h5")
    }

    /// The image table's ⌘C line the same. Red before: six fields.
    func testTheResultsCopyLineKeepsFiveColumnsWhenASourceHoldsATab() {
        let line = ResultsFormat.copyLine(label: "Distance 1", value: "12.3 nm", source: "a\tb.dm4", record: "recorded", badge: "Current")
        XCTAssertEqual(line.components(separatedBy: "\t"), ["Distance 1", "12.3 nm", "a b.dm4", "recorded", "Current"])
    }

    /// The three table copies write their lines through the one helper, and none joins its cells itself.
    /// Red under: a formatter joining raw cells again.
    func testTheThreeTableCopiesWriteThroughTheOneHelper() throws {
        for path in ["macTEM/App/IndexingTableFormat.swift", "macTEM/App/ResultsFormat.swift", "macTEM/UI/ResultsSession.swift"] {
            let text = try source(path)
            XCTAssertTrue(text.contains("TSV.line("), path)
            XCTAssertFalse(text.contains("joined(separator: \"\\t\")"), "\(path) joins its cells itself")
        }
    }

    /// The error alert's Copy Details writes through the app's one pasteboard writer, not one of the window's own.
    /// Red before: the window cleared and set the general pasteboard itself.
    func testCopyDetailsWritesThroughTheOnePasteboardWriter() throws {
        let view = try source("macTEM/UI/ContentView.swift")
        XCTAssertTrue(view.contains("Button(\"Copy Details\") { SystemPaneTextWriter().write(appState.errorMessage ?? \"\") }"))
        XCTAssertFalse(view.contains("NSPasteboard"), "the window has no pasteboard code of its own")
    }
}
