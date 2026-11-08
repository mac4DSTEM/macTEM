//
//  EDXRoomTests.swift
//  How macTEM mounts the shared EDX room (MacEMUI's ShellSpectroscopy; the room's own rules are tested there): the toolbar's
//  verb, the shell's slots (the room is built and last, the shell mounts it, `AppState` composes its two owners once, no export
//  command acts in it), the rooms list and the follow rule. The wiring tests go red when their line reverts.
//

import ShellLayout
import ShellSpectroscopy
import ShellEDXModel
import XCTest
import UniformTypeIdentifiers
import SpectroCore
import SpectroEDX
import TEMSession
@testable import macTEM

nonisolated final class EDXRoomTests: XCTestCase {

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    private func squeezed(_ text: String) -> String { text.split(whereSeparator: \.isWhitespace).joined(separator: " ") }

    // MARK: The verb is the toolbar's (design 2026-10-22, §2.2)

    /// Quantify is the room's one verb, in the toolbar (the room's header has none: MacEMUI's EDXRoomTests). Red under: the verb gone
    /// from the toolbar.
    func testQuantifyIsTheToolbarsVerb() throws {
        let verb = squeezed(try source("macTEM/UI/RoomPrimaryAction.swift"))
        XCTAssertTrue(verb.contains("title: \"Quantify\""))
        XCTAssertTrue(squeezed(try source("macTEM/UI/ContentView.swift")).contains("PrimaryActionButton(RoomPrimaryAction.current(appState))"))
    }

    @MainActor func testTheEDSRoomHasTheVerbOnlyWithASpectrumImage() {
        let state = AppState()
        state.navigation.workspaceArea = .edx
        XCTAssertNil(RoomPrimaryAction.current(state), "no spectrum image: no verb")
        state.edx.bind(DemoDocuments.edx())
        let action = RoomPrimaryAction.current(state)
        XCTAssertEqual(action?.title, "Quantify")
        XCTAssertEqual(action?.isEnabled, state.edx.canQuantify)
        state.navigation.workspaceArea = .image
        XCTAssertNil(RoomPrimaryAction.current(state), "the Image room has no verb")
    }

    /// While a spectrum image opens the toolbar's verb is running, so it shows Stop, and Stop ends the open (Paul's drive, 2026-10-23).
    /// Red under: no verb while opening (the open could be stopped only with ⌘.).
    @MainActor func testTheEDSVerbStopsAnOpenInFlight() async throws {
        let state = AppState()
        state.navigation.workspaceArea = .edx
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("not-yet-\(UUID().uuidString).emd")
        try Data(count: 64).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let open = state.edx.open(url: url)
        let action = try XCTUnwrap(RoomPrimaryAction.current(state), "opening: the verb is there")
        XCTAssertTrue(action.isRunning)
        action.stop?()
        XCTAssertFalse(state.edx.isOpening)
        await open.value
        XCTAssertFalse(state.edx.hasImage, "nothing was bound")
    }

    // MARK: The room states

    @MainActor func testTheRoomStatesStartWithNothingSolo() {
        XCTAssertNil(EDXRoomState().soloTile)
        XCTAssertNil(EELSRoomState().soloTile)
    }

    // MARK: The shell's slots

    /// The rooms list in the order the work goes (Paul 2026-10-22): looking (Prepare, Image, FFT), the spectra (EDS, EELS), then Diffraction and Results; the keys follow
    /// the list. Red under: EDS and EELS after Results.
    @MainActor func testTheRoomsListInTheOrderTheWorkGoes() {
        XCTAssertEqual(WorkspaceArea.allCases.map(\.title), ["Image", "FFT", "EDS", "EELS", "Diffraction", "Patterns", "Indexing", "Maps", "Results"])
        XCTAssertTrue(WorkspaceArea.edx.isBuilt)
        XCTAssertEqual(WorkspaceArea.edx.shortcutDigit, "3")
        XCTAssertEqual(WorkspaceArea.eels.shortcutDigit, "4")
        XCTAssertEqual(WorkspaceArea.diffraction.shortcutDigit, "5")
        XCTAssertEqual(WorkspaceArea.patterns.shortcutDigit, "6")
        XCTAssertEqual(WorkspaceArea.indexing.shortcutDigit, "7")
        XCTAssertEqual(WorkspaceArea.maps.shortcutDigit, "8")
        XCTAssertEqual(WorkspaceArea.results.shortcutDigit, "9")
    }

    /// The spectrum rooms follow the selected file: a file that opened into the EDS room is reopened there when its row is selected while another file
    /// holds the room; the file already in the room, a file with no spectrum image, or a room still opening ask for nothing. Red under: no follow (drive 6).
    @MainActor func testTheSpectrumRoomsFollowTheSelectedFile() {
        let a = URL(fileURLWithPath: "/data/SI 1339.emd"), b = URL(fileURLWithPath: "/data/SI 1840.emd"), image = URL(fileURLWithPath: "/data/Ceta.emd")
        let eds: Set<URL> = [a, b], eels: Set<URL> = [a]
        XCTAssertEqual(AppState.roomsToFollow(selected: a, edsFiles: eds, eelsFiles: eels, edsFile: "SI 1840.emd", eelsFile: "", edsOpening: false, eelsOpening: false).eds, true)
        XCTAssertEqual(AppState.roomsToFollow(selected: a, edsFiles: eds, eelsFiles: eels, edsFile: "SI 1840.emd", eelsFile: "", edsOpening: false, eelsOpening: false).eels, true)
        XCTAssertEqual(AppState.roomsToFollow(selected: b, edsFiles: eds, eelsFiles: eels, edsFile: "SI 1840.emd", eelsFile: "", edsOpening: false, eelsOpening: false).eds, false, "already in the room")
        XCTAssertEqual(AppState.roomsToFollow(selected: image, edsFiles: eds, eelsFiles: eels, edsFile: "SI 1840.emd", eelsFile: "", edsOpening: false, eelsOpening: false).eds, false, "no spectrum image")
        XCTAssertEqual(AppState.roomsToFollow(selected: a, edsFiles: eds, eelsFiles: eels, edsFile: "SI 1840.emd", eelsFile: "", edsOpening: true, eelsOpening: false).eds, false, "still opening")
        XCTAssertEqual(AppState.roomsToFollow(selected: nil, edsFiles: eds, eelsFiles: eels, edsFile: "", eelsFile: "", edsOpening: false, eelsOpening: false).eds, false)
        // The list's URL is resolved and standardised (drive 6 on screen: the raw URL never matched it).
        let viaTmp = URL(fileURLWithPath: "/tmp/../data/SI 1339.emd")
        XCTAssertEqual(AppState.roomsToFollow(selected: viaTmp, edsFiles: eds, eelsFiles: eels, edsFile: "SI 1840.emd", eelsFile: "", edsOpening: false, eelsOpening: false).eds, true, "another spelling of the same path")
        XCTAssertTrue(squeezed((try? source("macTEM/App/AppState.swift")) ?? "").contains("openItems.onSelect = { [weak self] _ in self?.spectrumRoomsFollowSelection() }"),
                      "the selection reaches the rooms through the list's own callback, not a view's observation (it did not fire on screen)")
    }

    /// Two spectrum images of one name in two folders (day 1's and day 2's SI.emd) are told apart by the path the room's reader states, as the
    /// Results room's `edsFitBelongs` does: selecting day 2's while day 1's holds the rooms reads it into them, selecting day 1's asks for nothing,
    /// and a reader that states no path (a document made in memory) is still told by its name. Red under: the rooms held by name only (day 2's
    /// never reached them, and Quantify ran on day 1's while day 2's was selected).
    @MainActor func testTwoSpectrumImagesOfOneNameAreToldApartByTheirFolder() {
        let day1 = URL(fileURLWithPath: "/data/day1/SI.emd"), day2 = URL(fileURLWithPath: "/data/day2/SI.emd")
        let both: Set<URL> = [day1, day2]
        let toDay2 = AppState.roomsToFollow(selected: day2, edsFiles: both, eelsFiles: both, edsFile: "SI.emd", eelsFile: "SI.emd",
                                            edsPath: day1.path, eelsPath: day1.path, edsOpening: false, eelsOpening: false)
        XCTAssertTrue(toDay2.eds, "day 1's holds the EDS room: day 2's is read into it")
        XCTAssertTrue(toDay2.eels, "and into the EELS room")
        let toDay1 = AppState.roomsToFollow(selected: day1, edsFiles: both, eelsFiles: both, edsFile: "SI.emd", eelsFile: "SI.emd",
                                            edsPath: day1.path, eelsPath: day1.path, edsOpening: false, eelsOpening: false)
        XCTAssertFalse(toDay1.eds, "day 1's is already in the EDS room")
        XCTAssertFalse(toDay1.eels, "day 1's is already in the EELS room")
        let respelled = AppState.roomsToFollow(selected: day1, edsFiles: both, eelsFiles: both, edsFile: "SI.emd", eelsFile: "",
                                               edsPath: "/data/day2/../day1/SI.emd", edsOpening: false, eelsOpening: false)
        XCTAssertFalse(respelled.eds, "another spelling of the room's path is the same file")
        let noPath = AppState.roomsToFollow(selected: day2, edsFiles: both, eelsFiles: both, edsFile: "SI.emd", eelsFile: "",
                                            edsOpening: false, eelsOpening: false)
        XCTAssertFalse(noPath.eds, "a reader that states no path is told by its name")
        XCTAssertTrue(squeezed((try? source("macTEM/App/AppState+Open.swift")) ?? "")
            .contains("edsPath: edx.source?.metadata.filePath ?? \"\", eelsPath: eels.filePath, edsOpening: edx.isOpening, eelsOpening: eels.isOpening)"),
                      "the selection's follow passes both readers' paths")
    }

    @MainActor func testTheEDXRoomCanBeEnteredWithNoImageOpen() {
        let state = AppState()
        XCTAssertFalse(state.hasImage)
        state.selectWorkspace(.edx)
        XCTAssertEqual(state.navigation.workspaceArea, .edx)
        XCTAssertFalse(state.edx.hasImage)
    }

    /// The shell mounts the room in its three slots, `AppState` composes the two owners in one line each, the menu enters the room with
    /// no image, and no export command acts in it. Red under: a slot removed; an owner composed twice; the menu rule dropped.
    func testTheShellMountsTheRoomInItsSlots() throws {
        let view = squeezed(try source("macTEM/UI/WorkspaceView.swift"))
        XCTAssertTrue(view.contains("if appState.navigation.workspaceArea == .edx { EDXRoom(session: appState.edx, state: appState.edxRoom, actions: appState.edxActions, openExtensions: EDXOpening.readableExtensions) } else if appState.navigation.workspaceArea == .eels { EELSRoom() } else if appState.navigation.workspaceArea == .patterns { PatternsRoom() } else if appState.navigation.workspaceArea == .indexing { IndexingRoom() } else if appState.navigation.workspaceArea == .maps { MapsRoom() } else if let item = appState.openItems.selected {"))
        let inspector = squeezed(try source("macTEM/UI/WorkspaceInspector.swift"))
        XCTAssertTrue(inspector.contains("if appState.navigation.workspaceArea == .edx { InspectorScrollColumn {"))
        XCTAssertTrue(inspector.contains("EDXRoomSettings(session: appState.edx, state: appState.edxRoom, actions: appState.edxActions)"))
        XCTAssertTrue(inspector.contains("EDXRoomInfo(session: appState.edx)"))
        XCTAssertTrue(inspector.contains("WorkspaceInspectorFrame("), "the inspector's toggle is the shell's, always enabled")
        let app = try source("macTEM/App/AppState.swift")
        XCTAssertEqual(app.components(separatedBy: "EDXSession(host: .macTEM)").count - 1, 1)
        XCTAssertEqual(app.components(separatedBy: "EDXRoomState()").count - 1, 1)
        XCTAssertTrue(app.contains("edx.onEvent = { [weak self] in self?.statusText = $0 }"))
        XCTAssertTrue(app.contains("edx.onFailure = { [weak self] in self?.present($0) }"))
        let menu = squeezed(try source("macTEM/App/macTEMApp.swift"))
        XCTAssertTrue(menu.contains(".disabled(appState.map { $0.roomUnavailableReason(area) != nil } ?? true)"), "the file decides which rooms open")
    }

    @MainActor func testNoImageExportCommandActsInTheEDXRoom() {
        let image = ExportSnapshot.availability(hasImage: true, area: .edx, isLoading: false, profileHasSamples: true, resultRows: 3)
        XCTAssertEqual(image, ExportAvailability(image: false, profile: false, results: false))
        let fft = ExportSnapshot.fftAvailability(hasImage: true, area: .edx, isLoading: false, spectrumIsCurrent: true, profileHasBins: true, measuredSpots: 2)
        XCTAssertFalse(fft.transform); XCTAssertFalse(fft.profile); XCTAssertFalse(fft.spots)
    }
}
