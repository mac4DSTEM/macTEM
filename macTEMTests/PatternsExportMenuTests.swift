//
//  PatternsExportMenuTests.swift
//  The Patterns room's exports in the File menu (#259): `ExportSnapshot.patternsAvailability` lists them only while the Patterns
//  room shows a dataset and follows the map and the overlay; the menu lists every kind the room writes, each named as its
//  inspector button; and an item writes through the room's own export (`RoomExports.patterns`), the call the button makes.
//

import TEMSession
import XCTest
@testable import macTEM

nonisolated final class PatternsExportMenuTests: XCTestCase {

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    private func squeezed(_ text: String) -> String { text.split(whereSeparator: \.isWhitespace).joined(separator: " ") }

    /// The items are listed only in the Patterns room with a dataset; the map item follows the map, and the overlay items need the
    /// overlay on and orientations to draw it from. Red under: the items listed in another room or with nothing open; the overlay
    /// items on for a dataset without orientations.
    @MainActor func testTheRuleListsTheItemsOnlyInThePatternsRoomAndFollowsTheMapAndTheOverlay() {
        func rule(area: WorkspaceArea = .patterns, dataset: Bool = true, map: Bool = true, overlayOn: Bool = true,
                  canOverlay: Bool = true) -> PatternsExportAvailability? {
            ExportSnapshot.patternsAvailability(area: area, hasDataset: dataset, mapLanded: map, overlayOn: overlayOn, canOverlay: canOverlay)
        }
        XCTAssertEqual(rule(), PatternsExportAvailability(map: true, overlay: true))
        for area in WorkspaceArea.allCases where area != .patterns {
            XCTAssertNil(rule(area: area), "\(area.title) lists no Patterns export")
        }
        XCTAssertNil(rule(dataset: false), "the Patterns room with nothing open lists none")
        XCTAssertEqual(rule(map: false), PatternsExportAvailability(map: false, overlay: true))
        XCTAssertEqual(rule(overlayOn: false), PatternsExportAvailability(map: true, overlay: false))
        XCTAssertEqual(rule(canOverlay: false), PatternsExportAvailability(map: true, overlay: false),
                       "a dataset without orientations has no overlay to write")
    }

    /// Each kind reads its own flag: the map the map's, the two overlay files the overlay's, and the pattern and the two JSON
    /// files are there whenever the items are listed. Red under: a kind on another's flag.
    func testEachKindReadsItsOwnFlag() {
        let none = PatternsExportAvailability(map: false, overlay: false)
        XCTAssertEqual(PatternsExportKind.allCases.filter { none.isEnabled($0) }, [.patternPNG, .metadataJSON, .methodJSON])
        let map = PatternsExportAvailability(map: true, overlay: false)
        XCTAssertEqual(PatternsExportKind.allCases.filter { map.isEnabled($0) }, [.mapPNG, .patternPNG, .metadataJSON, .methodJSON])
        let overlay = PatternsExportAvailability(map: false, overlay: true)
        XCTAssertEqual(PatternsExportKind.allCases.filter { overlay.isEnabled($0) },
                       [.patternPNG, .overlayPNG, .overlayCSV, .metadataJSON, .methodJSON])
    }

    /// The window's rule on the demo dataset: nothing outside the Patterns room; in it the map is on once its pass has landed, and
    /// the overlay items come on with the Kikuchi overlay. Red under: the rule reading another session's facts.
    @MainActor func testTheWindowsRuleFollowsTheRoomTheMapAndTheOverlay() async throws {
        let state = AppState(launch: LaunchOptions(arguments: []))
        state.navigation.workspaceArea = .patterns
        XCTAssertNil(ExportSnapshot.patternsAvailability(of: state), "no dataset yet")
        await state.ebsd.bind(try DemoDocuments.ebsd()).value
        try await waitUntil("the map pass to end", seconds: 20) { !state.ebsd.isMapping }
        state.navigation.workspaceArea = .image
        XCTAssertNil(ExportSnapshot.patternsAvailability(of: state), "another room lists none")
        state.navigation.workspaceArea = .patterns
        XCTAssertEqual(ExportSnapshot.patternsAvailability(of: state), PatternsExportAvailability(map: true, overlay: false),
                       state.ebsd.mapFailure ?? "the mean map lands with the open, and the overlay is off")
        state.ebsd.setOverlayOn(true)
        XCTAssertEqual(ExportSnapshot.patternsAvailability(of: state), PatternsExportAvailability(map: true, overlay: true))
    }

    /// A menu export is the room's own: with a journey's export folder, Export Metadata JSON… writes the room's file there and the
    /// status line says so; and where the item's fact is missing at the pattern on screen, the room says what is missing.
    /// Red under: the call not reaching the room's export, or not passing the export folder.
    @MainActor func testAMenuExportWritesThroughTheRoomsOwnExport() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("PatternsExportMenuTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let state = AppState(launch: LaunchOptions(arguments: ["--export-dir", folder.path]))
        await state.ebsd.bind(try DemoDocuments.ebsd()).value
        RoomExports.patterns(.metadataJSON, appState: state)
        XCTAssertEqual(state.statusText, "Exported Demo EBSD metadata.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("Demo EBSD metadata.json").path))
        RoomExports.patterns(.overlayCSV, appState: state)
        XCTAssertEqual(state.statusText, "Nothing to export yet: no Kikuchi overlay is on the pattern.")
    }

    /// The File menu draws the room's kinds behind the rule, each named as its inspector button and calling the room's export.
    /// Red under: the condition dropped (the items listed in every room); the items not following the rule.
    func testTheFileMenuDrawsTheKindsBehindTheRule() throws {
        let commands = squeezed(try source("macTEM/App/ExportCommands.swift"))
        XCTAssertTrue(commands.contains("let patterns = appState.flatMap(ExportSnapshot.patternsAvailability(of:))"))
        XCTAssertTrue(commands.contains("if let appState, let patterns { patternsItems(patterns, appState: appState) }"),
                      "listed only while the rule has them")
        XCTAssertTrue(commands.contains("Divider() ForEach(PatternsExportKind.allCases) { kind in"))
        XCTAssertTrue(commands.contains("{ RoomExports.patterns(kind, appState: appState) } .disabled(!patterns.isEnabled(kind))"))
        XCTAssertEqual(PatternsExportKind.allCases.map { "Export \($0.title)" },
                       ["Export Map PNG…", "Export Pattern PNG…", "Export Pattern with Overlay…", "Export Overlay CSV…",
                        "Export Metadata JSON…", "Export Method JSON…"], "the inspector buttons' own titles, in their order")
    }
}
