//
//  TableFocusTests.swift
//  The SEM rooms' copyable tables take the keyboard when the person changes their selection, never when the app does (#353; AppKit's
//  rule: a click makes the clicked view first responder, a selection the app sets moves nothing). The Indexing Results and Bands tables
//  and the Maps Grains table bind their selection through a setter that focuses the table; the pick's own row selection writes the
//  state directly; the Indexing room's root copies the picked point's row when it has the keys. Red before (drive, 2026-11-11): a
//  clicked row stayed grey under the room's focusable root and ⌘C copied nothing. Source pins: no unit test can click a SwiftUI table.
//

import XCTest

nonisolated final class TableFocusTests: XCTestCase {
    private func code(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
        return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    func testThePersonsSelectionTakesTheKeysForTheTable() throws {
        let indexing = try code("macTEM/UI/IndexingRoom.swift")
        XCTAssertEqual(indexing.components(separatedBy: "@FocusState private var tableFocused: Bool").count - 1, 2, "Results and Bands")
        XCTAssertEqual(indexing.components(separatedBy: "if !picked.isEmpty { tableFocused = true }").count - 1, 2, "a setter per table")
        XCTAssertEqual(indexing.components(separatedBy: "Table(rows, selection: picks, sortOrder: $sortOrder)").count - 1, 2, "both Results tables")
        XCTAssertTrue(indexing.contains("Table(session.detectedBands, selection: picks)"))
        XCTAssertEqual(indexing.components(separatedBy: ".focused($tableFocused)").count - 1, 2)
        // The pick selects its row through the state, not the table's setter, so a map pick leaves the arrows on the map.
        XCTAssertTrue(indexing.contains("SelectsThePickedRow(patterns: session.patterns, columns: dataset.scanColumns, rows: rows, selection: $selection)"))
        let maps = try code("macTEM/UI/MapsRoomAnalysis.swift")
        XCTAssertTrue(maps.contains("session.selectGrains(picked) if !picked.isEmpty { tableFocused = true }"))
        XCTAssertTrue(maps.contains(".focused($tableFocused) .onCopyCommand(perform: session.selectedGrains.isEmpty"))
    }

    func testTheIndexingRootCopiesThePickedRow() throws {
        let indexing = try code("macTEM/UI/IndexingRoom.swift")
        XCTAssertTrue(indexing.contains(".onCopyCommand(perform: pickedRow == nil ? nil : { copiedPickedRow() })"))
        XCTAssertTrue(indexing.contains("session.result?.rows.first { $0.position == session.patterns.pinned }"))
    }

    func testTheRoomRootTakesNoKeysOnAClickOfItsOwn() throws {
        let pick = try code("macTEM/UI/SEMMapPick.swift")
        XCTAssertTrue(pick.contains(".focusable(interactions: .activate)"))
    }
}
