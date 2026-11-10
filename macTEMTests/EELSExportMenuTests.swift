//
//  EELSExportMenuTests.swift
//  The EELS room's exports in the File menu (#259): `ExportSnapshot.eelsAvailability` lists them only while the EELS room shows a
//  spectrum image and enables each by the rule of its button in the room's inspector; the menu lists every kind the room writes,
//  each named as its button; and an item writes through the room's own export (`RoomExports.eels`), the call the button makes.
//

import TEMSession
import XCTest
@testable import macTEM

nonisolated final class EELSExportMenuTests: XCTestCase {

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    private func squeezed(_ text: String) -> String { text.split(whereSeparator: \.isWhitespace).joined(separator: " ") }

    /// The items are listed only in the EELS room with a spectrum image, and each follows its own fact. Red under: the items
    /// listed in another room or with nothing open; an item enabled by another's fact.
    @MainActor func testTheRuleListsTheItemsOnlyInTheEELSRoomAndEnablesEachByItsOwnFact() {
        func rule(area: WorkspaceArea = .eels, image: Bool = true, spectrum: Bool = true, map: Bool = true, edges: Int = 2,
                  method: Bool = true, regions: Int = 1) -> EELSExportAvailability? {
            ExportSnapshot.eelsAvailability(area: area, hasSpectrumImage: image, hasSpectrum: spectrum, hasThicknessMap: map,
                                            fittedEdges: edges, hasMethodRecord: method, regionRows: regions)
        }
        XCTAssertEqual(rule(), EELSExportAvailability(spectrum: true, maps: true, results: true, method: true, regions: true))
        for area in WorkspaceArea.allCases where area != .eels {
            XCTAssertNil(rule(area: area), "\(area.title) lists no EELS export")
        }
        XCTAssertNil(rule(image: false), "the EELS room with nothing open lists none")
        XCTAssertEqual(rule(spectrum: false), EELSExportAvailability(spectrum: false, maps: true, results: true, method: true, regions: true))
        XCTAssertEqual(rule(map: false), EELSExportAvailability(spectrum: true, maps: false, results: true, method: true, regions: true))
        XCTAssertEqual(rule(edges: 0), EELSExportAvailability(spectrum: true, maps: true, results: false, method: true, regions: true))
        XCTAssertEqual(rule(method: false), EELSExportAvailability(spectrum: true, maps: true, results: true, method: false, regions: true))
        XCTAssertEqual(rule(regions: 0), EELSExportAvailability(spectrum: true, maps: true, results: true, method: true, regions: false))
    }

    /// The menu lists every kind the room writes, once, and each kind reads the flag of its inspector button: the two spectrum files
    /// the spectrum's, the maps and the per-pixel table the thickness map's. Red under: a kind left out of the menu; a kind on
    /// another's flag.
    func testTheMenuListsEveryKindOnItsOwnFlag() {
        XCTAssertEqual(EELSExportAvailability.menuKinds.count, EELSExportKind.allCases.count)
        XCTAssertEqual(Set(EELSExportAvailability.menuKinds), Set(EELSExportKind.allCases))
        XCTAssertEqual(Array(EELSExportAvailability.menuKinds.prefix(2)), [EELSExportKind.spectrum, EELSExportKind.spectrumMSA],
                       "the spectrum first, as the EDS items")
        let flags: [(EELSExportAvailability, Set<EELSExportKind>)] = [
            (EELSExportAvailability(spectrum: true, maps: false, results: false, method: false, regions: false), [.spectrum, .spectrumMSA]),
            (EELSExportAvailability(spectrum: false, maps: true, results: false, method: false, regions: false), [.mapsPNG, .diagnostics]),
            (EELSExportAvailability(spectrum: false, maps: false, results: true, method: false, regions: false), [.results]),
            (EELSExportAvailability(spectrum: false, maps: false, results: false, method: true, regions: false), [.method]),
            (EELSExportAvailability(spectrum: false, maps: false, results: false, method: false, regions: true), [.regions]),
        ]
        for (availability, enabled) in flags {
            XCTAssertEqual(Set(EELSExportKind.allCases.filter { availability.isEnabled($0) }), enabled)
        }
    }

    /// The window's rule on the demo spectrum image: nothing outside the EELS room; in it the spectrum, the thickness map the open
    /// makes and its method are on, and the results and the regions stay off until an edge is fitted and a region kept.
    /// Red under: the rule reading another session's facts.
    @MainActor func testTheWindowsRuleFollowsTheRoomAndTheSession() async throws {
        let state = AppState(launch: LaunchOptions(arguments: []))
        state.navigation.workspaceArea = .eels
        XCTAssertNil(ExportSnapshot.eelsAvailability(of: state), "no spectrum image yet")
        await state.eels.bind(try DemoDocuments.eels()).value
        await state.eels.settled()
        state.navigation.workspaceArea = .image
        XCTAssertNil(ExportSnapshot.eelsAvailability(of: state), "another room lists none")
        state.navigation.workspaceArea = .eels
        let opened = try XCTUnwrap(ExportSnapshot.eelsAvailability(of: state))
        XCTAssertTrue(opened.spectrum)
        XCTAssertTrue(opened.maps, state.eels.failure ?? "no thickness map")
        XCTAssertTrue(opened.method)
        XCTAssertFalse(opened.results, "no edge is fitted")
        XCTAssertFalse(opened.regions)
    }

    /// A menu export is the room's own: with a journey's export folder, Export Spectrum CSV… writes the room's file there and the
    /// status line says so. Red under: the call not reaching the room's export, or not passing the export folder.
    @MainActor func testAMenuExportWritesThroughTheRoomsOwnExport() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("EELSExportMenuTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let state = AppState(launch: LaunchOptions(arguments: ["--export-dir", folder.path]))
        await state.eels.bind(try DemoDocuments.eels()).value
        await state.eels.settled()
        RoomExports.eels(.spectrum, appState: state)
        XCTAssertEqual(state.statusText, "Exported Demo EELS spectrum.csv")
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("Demo EELS spectrum.csv").path))
    }

    /// The File menu draws the room's kinds behind the rule, each named as its inspector button and calling the room's export.
    /// Red under: the condition dropped (the items listed in every room); the items not following the rule.
    func testTheFileMenuDrawsTheKindsBehindTheRule() throws {
        let commands = squeezed(try source("macTEM/App/ExportCommands.swift"))
        XCTAssertTrue(commands.contains("let eels = appState.flatMap(ExportSnapshot.eelsAvailability(of:))"))
        XCTAssertTrue(commands.contains("if let appState, let eels { eelsItems(eels, appState: appState) }"), "listed only while the rule has them")
        XCTAssertTrue(commands.contains("Divider() ForEach(EELSExportAvailability.menuKinds) { kind in"))
        XCTAssertTrue(commands.contains("{ RoomExports.eels(kind, appState: appState) } .disabled(!eels.isEnabled(kind))"))
        XCTAssertEqual(EELSExportKind.allCases.map { "Export \($0.title)" }.sorted(),
                       ["Export Maps…", "Export Method JSON…", "Export Per-pixel CSV…", "Export Regions CSV…", "Export Results CSV…",
                        "Export Spectrum CSV…", "Export Spectrum MSA…"], "the inspector buttons' own titles")
    }
}
