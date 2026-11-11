//
//  MapsExportMenuTests.swift
//  The Maps room's exports in the File menu (#259): `ExportSnapshot.mapsAvailability` lists them only while the Maps room shows a
//  map and enables each by the rule of its button in the room's inspector; the menu lists the room's four files, each named as its
//  button; and an item writes through the room's own export (`RoomExports.maps`), the call the button makes. Run on the generated
//  demo scan's own crystal map, which the Maps room shows beside the patterns.
//

import TEMCore
import TEMSession
import XCTest
@testable import macTEM

nonisolated final class MapsExportMenuTests: XCTestCase {

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    private func squeezed(_ text: String) -> String { text.split(whereSeparator: \.isWhitespace).joined(separator: " ") }

    /// The items are listed only in the Maps room with a map, and each follows its own fact. Red under: the items listed in
    /// another room or with nothing open; an item enabled by another's fact.
    @MainActor func testTheRuleListsTheItemsOnlyInTheMapsRoomAndEnablesEachByItsOwnFact() {
        func rule(area: WorkspaceArea = .maps, map: Bool = true, picture: Bool = true, segmented: Bool = true,
                  texture: Bool = true) -> MapsExportAvailability? {
            ExportSnapshot.mapsAvailability(area: area, hasMap: map, hasPicture: picture, isSegmented: segmented, hasTexture: texture)
        }
        XCTAssertEqual(rule(), MapsExportAvailability(map: true, grains: true, texture: true))
        for area in WorkspaceArea.allCases where area != .maps {
            XCTAssertNil(rule(area: area), "\(area.title) lists no Maps export")
        }
        XCTAssertNil(rule(map: false), "the Maps room with nothing open lists none")
        XCTAssertEqual(rule(picture: false), MapsExportAvailability(map: false, grains: true, texture: true))
        XCTAssertEqual(rule(segmented: false), MapsExportAvailability(map: true, grains: false, texture: true))
        XCTAssertEqual(rule(texture: false), MapsExportAvailability(map: true, grains: true, texture: false))
    }

    /// Each file reads the flag of its inspector button: the grain table and the histogram both wait for Segment.
    /// Red under: a file on another's flag.
    func testEachFileReadsItsOwnFlag() {
        let map = MapsExportAvailability(map: true, grains: false, texture: false)
        XCTAssertEqual(MapsExportKind.allCases.filter { map.isEnabled($0) }, [.map])
        let grains = MapsExportAvailability(map: false, grains: true, texture: false)
        XCTAssertEqual(MapsExportKind.allCases.filter { grains.isEnabled($0) }, [.grains, .histogram])
        let texture = MapsExportAvailability(map: false, grains: false, texture: true)
        XCTAssertEqual(MapsExportKind.allCases.filter { texture.isEnabled($0) }, [.texture])
    }

    /// The window's rule and a menu export on the demo scan's map: nothing outside the Maps room; in it the map's file is on once
    /// its picture has landed and Export Map PNG… writes the room's figure into a journey's export folder; the grain files are off,
    /// and an export says why, until Segment has run. Red under: the rule reading another session's facts; the call not reaching
    /// the room's export.
    @MainActor func testTheWindowsRuleAndAMenuExportFollowTheMap() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MapsExportMenuTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let state = AppState(launch: LaunchOptions(arguments: ["--export-dir", folder.path]))
        state.navigation.workspaceArea = .maps
        XCTAssertNil(ExportSnapshot.mapsAvailability(of: state), "no map yet")
        await state.ebsd.bind(try DemoDocuments.ebsd()).value
        XCTAssertTrue(state.maps.hasMap, "the demo scan carries its own crystal map")
        try await waitUntil("the demo map's picture and colour keys", seconds: 20) { state.maps.raster != nil && !state.maps.keys.isEmpty }
        state.navigation.workspaceArea = .image
        XCTAssertNil(ExportSnapshot.mapsAvailability(of: state), "another room lists none")
        state.navigation.workspaceArea = .maps
        XCTAssertEqual(ExportSnapshot.mapsAvailability(of: state), MapsExportAvailability(map: true, grains: false, texture: false))

        RoomExports.maps(.grains, appState: state)
        XCTAssertEqual(state.statusText, "Nothing to export yet: segment the map first.")
        RoomExports.maps(.map, appState: state)
        XCTAssertEqual(state.statusText, "Exported Demo EBSD map IPF-Z.png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("Demo EBSD map IPF-Z.png").path))

        await state.maps.segment().value
        XCTAssertEqual(ExportSnapshot.mapsAvailability(of: state)?.grains, state.maps.analysis != nil, "the grain files follow Segment")
    }

    /// The File menu draws the room's four behind the rule, each named as its inspector button and calling the room's export.
    /// Red under: the condition dropped (the items listed in every room); a title drifting from the inspector's button.
    func testTheFileMenuDrawsTheFourBehindTheRule() throws {
        let commands = squeezed(try source("macTEM/App/ExportCommands.swift"))
        XCTAssertTrue(commands.contains("let maps = appState.flatMap(ExportSnapshot.mapsAvailability(of:))"))
        XCTAssertTrue(commands.contains("if let appState, let maps { mapsItems(maps, appState: appState) }"), "listed only while the rule has them")
        XCTAssertTrue(commands.contains("Divider() ForEach(MapsExportKind.allCases) { kind in"))
        XCTAssertTrue(commands.contains("{ RoomExports.maps(kind, appState: appState) } .disabled(!maps.isEnabled(kind))"))
        XCTAssertEqual(MapsExportKind.allCases.map(\.title), ["Map PNG…", "Grains CSV…", "Histogram CSV…", "Texture PNG…"])
        let inspector = try source("macTEM/UI/MapsRoomInspector.swift")
        for kind in MapsExportKind.allCases {
            XCTAssertTrue(inspector.contains("Button(\"\(kind.title)\")"), "\(kind.title) is the inspector button's own title")
        }
    }
}
