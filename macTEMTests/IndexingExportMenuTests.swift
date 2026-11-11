//
//  IndexingExportMenuTests.swift
//  The Indexing room's exports in the File menu (#259): `ExportSnapshot.indexingAvailability` lists them only while the Indexing
//  room shows a dataset and enables them once the run on screen has reached a point, the rule of the room's Export buttons; the
//  menu lists every kind the room writes, each named as its button; and an item writes through the room's own export
//  (`RoomExports.indexing`), the call the button makes. Run on the generated demo scan (30 × 40), so the run is short.
//

import TEMSession
import XCTest
@testable import macTEM

nonisolated final class IndexingExportMenuTests: XCTestCase {

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    private func squeezed(_ text: String) -> String { text.split(whereSeparator: \.isWhitespace).joined(separator: " ") }

    /// The items are listed only in the Indexing room with a dataset, and are enabled once a point is reached. Red under: the
    /// items listed in another room or with nothing open; the items on before a run.
    @MainActor func testTheRuleListsTheItemsOnlyInTheIndexingRoomAndEnablesThemOnceAPointIsReached() {
        XCTAssertEqual(ExportSnapshot.indexingAvailability(area: .indexing, hasDataset: true, reachedPoints: 1200),
                       IndexingExportAvailability(indexed: true))
        for area in WorkspaceArea.allCases where area != .indexing {
            XCTAssertNil(ExportSnapshot.indexingAvailability(area: area, hasDataset: true, reachedPoints: 1200),
                         "\(area.title) lists no Indexing export")
        }
        XCTAssertNil(ExportSnapshot.indexingAvailability(area: .indexing, hasDataset: false, reachedPoints: 0),
                     "the Indexing room with nothing open lists none")
        XCTAssertEqual(ExportSnapshot.indexingAvailability(area: .indexing, hasDataset: true, reachedPoints: 0),
                       IndexingExportAvailability(indexed: false), "listed, and off until Index has reached a point")
    }

    /// The window's rule and a menu export on the demo scan: nothing outside the Indexing room; in it the items are off, and an
    /// export says why, until Index has run; then they are on and Export Results CSV… writes the room's file into a journey's
    /// export folder. Red under: the rule reading another session's facts; the call not reaching the room's export.
    @MainActor func testTheWindowsRuleAndAMenuExportFollowTheRun() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("IndexingExportMenuTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let state = AppState(launch: LaunchOptions(arguments: ["--export-dir", folder.path]))
        state.navigation.workspaceArea = .indexing
        XCTAssertNil(ExportSnapshot.indexingAvailability(of: state), "no dataset yet")
        await state.ebsd.bind(try DemoDocuments.ebsd()).value
        let ebsd = state.ebsd
        try await waitUntil("the demo scan's passes to end", seconds: 30) { !ebsd.isMapping && !ebsd.isComputingMean && !ebsd.isProcessing }
        state.navigation.workspaceArea = .patterns
        XCTAssertNil(ExportSnapshot.indexingAvailability(of: state), "another room lists none")
        state.navigation.workspaceArea = .indexing
        XCTAssertEqual(ExportSnapshot.indexingAvailability(of: state), IndexingExportAvailability(indexed: false))
        RoomExports.indexing(.resultsCSV, appState: state)
        XCTAssertEqual(state.statusText, "Nothing to export yet: Index has not run.")

        XCTAssertNil(state.indexing.refusal)
        await state.indexing.index().value
        XCTAssertEqual(ExportSnapshot.indexingAvailability(of: state), IndexingExportAvailability(indexed: true))
        RoomExports.indexing(.resultsCSV, appState: state)
        XCTAssertEqual(state.statusText, "Exported Demo EBSD indexing results.csv")
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("Demo EBSD indexing results.csv").path))
    }

    /// The File menu draws the room's kinds behind the rule, each named as its inspector button and calling the room's export.
    /// Red under: the condition dropped (the items listed in every room); the items not following the rule.
    func testTheFileMenuDrawsTheKindsBehindTheRule() throws {
        let commands = squeezed(try source("macTEM/App/ExportCommands.swift"))
        XCTAssertTrue(commands.contains("let indexing = appState.flatMap(ExportSnapshot.indexingAvailability(of:))"))
        XCTAssertTrue(commands.contains("if let appState, let indexing { indexingItems(indexing, appState: appState) }"),
                      "listed only while the rule has them")
        XCTAssertTrue(commands.contains("Divider() ForEach(IndexingExportKind.allCases) { kind in"))
        XCTAssertTrue(commands.contains("{ RoomExports.indexing(kind, appState: appState) } .disabled(!indexing.indexed)"))
        XCTAssertEqual(IndexingExportKind.allCases.map { "Export \($0.title)" },
                       ["Export Map PNG…", "Export Results CSV…", "Export EDAX ANG…", "Export Oxford CTF…", "Export Method JSON…"],
                       "the inspector buttons' own titles, in their order")
    }
}
