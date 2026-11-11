//
//  TableFocusTests.swift
//  The SEM rooms' copyable tables take the keyboard when the person changes their selection (#353), as the EELS edges table does: the
//  keys' focusable container is the map and pattern panes only, so the Results, Bands and Grains tables sit outside it (a table inside
//  a focusable root never kept the keyboard: drives, 2026-11-11, grey rows and a dead ⌘C), and a selection the person makes focuses its
//  table once the change lands; the pick's own row selection leaves the keys on the map. Source pins: no unit test can click a table.
//

import XCTest

nonisolated final class TableFocusTests: XCTestCase {
    private func code(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
        return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The keys' container is the upper panes (and the Compare maps), never the whole room with its tables.
    func testTheKeysLiveOnTheMapAndPatternNotOnTheTables() throws {
        let indexing = try code("macTEM/UI/IndexingRoom.swift")
        XCTAssertTrue(indexing.contains("IndexedPatternPane(session: session, dataset: document.dataset) } // The keys live on the map"))
        XCTAssertTrue(indexing.contains(".modifier(IndexingKeyedRoom(session: session)) } bottom: {"), "on the upper split, before the tables")
        XCTAssertTrue(indexing.contains(".modifier(IndexingKeyedRoom(session: session, followsThePick: false))"), "the Compare maps")
        XCTAssertFalse(indexing.contains(".id(document.fileName) .modifier(IndexingKeyedRoom"), "not on the whole room")
        let maps = try code("macTEM/UI/MapsRoom.swift")
        XCTAssertTrue(maps.contains("upper(document) // The keys live on the map"))
        XCTAssertFalse(maps.contains(".id(document.id) .modifier(MapsKeyedRoom"), "not on the whole room")
    }

    /// The person's selection focuses its table once the change lands; the pick's row selection does not.
    func testThePersonsSelectionTakesTheKeysForTheTable() throws {
        let indexing = try code("macTEM/UI/IndexingRoom.swift")
        XCTAssertEqual(indexing.components(separatedBy: "@FocusState private var tableFocused: Bool").count - 1, 2, "Results and Bands")
        XCTAssertTrue(indexing.contains("Binding(get: { selection }, set: { picked in personPicked = true selection = picked })"))
        XCTAssertTrue(indexing.contains("if personPicked, !picked.isEmpty { tableFocused = true }"))
        XCTAssertTrue(indexing.contains(".onChange(of: selection) { _, picked in if !picked.isEmpty { tableFocused = true } }"), "Bands")
        XCTAssertEqual(indexing.components(separatedBy: ".focused($tableFocused)").count - 1, 2)
        XCTAssertTrue(indexing.contains("SelectsThePickedRow(patterns: session.patterns, columns: dataset.scanColumns, rows: rows, selection: $selection)"))
        let maps = try code("macTEM/UI/MapsRoomAnalysis.swift")
        XCTAssertTrue(maps.contains("personPicked = true session.selectGrains(picked)"))
        XCTAssertTrue(maps.contains("if personPicked, !picked.isEmpty { tableFocused = true }"))
    }

    /// With the keys on the map, ⌘C copies the picked point's Results row.
    func testTheKeysContainerCopiesThePickedRow() throws {
        let indexing = try code("macTEM/UI/IndexingRoom.swift")
        XCTAssertTrue(indexing.contains(".onCopyCommand(perform: pickedRow == nil ? nil : { copiedPickedRow() })"))
    }
}
