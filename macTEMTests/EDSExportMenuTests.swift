//
//  EDSExportMenuTests.swift
//  The EDS room's exports in the File menu (#259): `ExportSnapshot.edsAvailability` lists them only while the EDS room shows a
//  spectrum image and enables each by the rule of its button in the room's inspector; `ExportCommands` draws the five behind
//  that rule; and an item writes through the room's own export (`RoomExports.eds`), the call the inspector's button makes.
//

import ShellEDXModel
import ShellSpectroscopy
import TEMSession
import XCTest
@testable import macTEM

nonisolated final class EDSExportMenuTests: XCTestCase {

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    private func squeezed(_ text: String) -> String { text.split(whereSeparator: \.isWhitespace).joined(separator: " ") }

    /// The items are listed only in the EDS room with a spectrum image, and each follows its own fact. Red under: the items listed
    /// in another room or with nothing open; an item enabled by another's fact; the results on while a fit or its check runs.
    @MainActor func testTheRuleListsTheItemsOnlyInTheEDSRoomAndEnablesEachByItsOwnFact() {
        func rule(area: WorkspaceArea = .edx, image: Bool = true, channels: Int = 2048, maps: Int = 3, fit: Bool = true,
                  running: Bool = false, regions: Int = 1) -> EDSExportAvailability? {
            ExportSnapshot.edsAvailability(area: area, hasSpectrumImage: image, spectrumChannels: channels, shownMaps: maps, hasFit: fit,
                                           fitRunning: running, keptRegions: regions)
        }
        XCTAssertEqual(rule(), EDSExportAvailability(spectrum: true, maps: true, results: true, regions: true))
        for area in WorkspaceArea.allCases where area != .edx {
            XCTAssertNil(rule(area: area), "\(area.title) lists no EDS export")
        }
        XCTAssertNil(rule(image: false), "the EDS room with nothing open lists none")
        XCTAssertEqual(rule(channels: 0), EDSExportAvailability(spectrum: false, maps: true, results: true, regions: true))
        XCTAssertEqual(rule(maps: 0), EDSExportAvailability(spectrum: true, maps: false, results: true, regions: true),
                       "a single spectrum has no maps")
        XCTAssertEqual(rule(fit: false), EDSExportAvailability(spectrum: true, maps: true, results: false, regions: true))
        XCTAssertEqual(rule(running: true), EDSExportAvailability(spectrum: true, maps: true, results: false, regions: true),
                       "a fit being run again is not exported")
        XCTAssertEqual(rule(regions: 0), EDSExportAvailability(spectrum: true, maps: true, results: true, regions: false))
    }

    /// The window's rule on the demo spectrum image: nothing outside the EDS room; in it the spectrum is on and the results stay
    /// off until Quantify has a fit; a kept region turns the regions on. Red under: the rule reading another session's facts.
    @MainActor func testTheWindowsRuleFollowsTheRoomTheFitAndTheRegions() async throws {
        let state = AppState(launch: LaunchOptions(arguments: []))
        state.navigation.workspaceArea = .edx
        XCTAssertNil(ExportSnapshot.edsAvailability(of: state), "no spectrum image yet")
        await state.edx.bind(DemoDocuments.edx()).value
        await state.edx.settled()
        state.navigation.workspaceArea = .image
        XCTAssertNil(ExportSnapshot.edsAvailability(of: state), "another room lists none")
        state.navigation.workspaceArea = .edx
        let opened = try XCTUnwrap(ExportSnapshot.edsAvailability(of: state))
        XCTAssertTrue(opened.spectrum)
        XCTAssertFalse(opened.results, "nothing is quantified until the Quantify verb")
        XCTAssertFalse(opened.regions)
        await state.edx.quantify()?.value
        await state.edx.settled()
        XCTAssertNotNil(state.edx.fit, state.edx.fitFailure ?? "no fit")
        XCTAssertEqual(ExportSnapshot.edsAvailability(of: state)?.results, true)
        state.edx.pinRegion()
        XCTAssertEqual(ExportSnapshot.edsAvailability(of: state)?.regions, true)
    }

    /// A menu export is the room's own: with a journey's export folder, Export Spectrum CSV… leaves one CSV there and the status
    /// line says so. Red under: the call not reaching the room's export, or not passing the export folder.
    @MainActor func testAMenuExportWritesThroughTheRoomsOwnExport() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("EDSExportMenuTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let state = AppState(launch: LaunchOptions(arguments: ["--export-dir", folder.path]))
        await state.edx.bind(DemoDocuments.edx()).value
        await state.edx.settled()
        await RoomExports.eds(.spectrum, appState: state).value
        let written = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        XCTAssertEqual(written.count, 1, "\(written)")
        XCTAssertEqual(written.first.map { ($0 as NSString).pathExtension }, "csv")
        XCTAssertTrue(state.statusText.hasPrefix("Exported "), state.statusText)
    }

    /// The File menu draws the five behind the rule, each calling the room's export with its own kind, and none takes a key.
    /// Red under: the condition dropped (the items listed in every room); two items writing the same kind; a `.disabled` swapped.
    func testTheFileMenuDrawsTheFiveBehindTheRule() throws {
        let commands = squeezed(try source("macTEM/App/ExportCommands.swift"))
        XCTAssertTrue(commands.contains("let eds = appState.flatMap(ExportSnapshot.edsAvailability(of:))"))
        XCTAssertTrue(commands.contains("if let appState, let eds { edsItems(eds, appState: appState) }"), "listed only while the rule has them")
        let items: [(title: String, kind: String, flag: String)] = [
            ("Export Spectrum CSV…", "spectrum", "spectrum"), ("Export Maps…", "mapsPNG", "maps"), ("Export Results CSV…", "results", "results"),
            ("Export Method JSON…", "method", "results"), ("Export Regions CSV…", "pins", "regions"),
        ]
        let drawn = items.map { "Button(\"\($0.title)\") { RoomExports.eds(.\($0.kind), appState: appState) } .disabled(!eds.\($0.flag))" }
        XCTAssertTrue(commands.contains("Divider() " + drawn.joined(separator: " ")), "the five, in mac4DSTEM's order, after a divider")
        XCTAssertEqual(commands.components(separatedBy: "RoomExports.eds(").count - 1, 5, "no other EDS item")
    }
}
