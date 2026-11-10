//
//  EDSRoomDoorTests.swift
//  The EDS room's own Open button (#318): the shared room reads its file past the app's Open, so the window notes the file the
//  room comes to hold as one of the app's EDS files (`AppState.noteEDSRoomFile`, an interim until the room's door takes the
//  app's Open). With it the rules that read those files know the room holds it.
//

import XCTest
@testable import macTEM

nonisolated final class EDSRoomDoorTests: XCTestCase {

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    private func squeezed(_ text: String) -> String { text.split(whereSeparator: \.isWhitespace).joined(separator: " ") }

    /// A file the room opened itself becomes one of the app's EDS files: its fit belongs to it, and the room comes back to it
    /// with the selection once another file holds the room. Red before: the file was in none of them (no `noteEDSRoomFile`).
    @MainActor func testAFileTheRoomOpenedItselfIsOneOfTheAppsEDSFiles() {
        let state = AppState(launch: LaunchOptions(arguments: []))
        let url = URL(fileURLWithPath: "/Volumes/data/session/map.emd")
        XCTAssertFalse(AppState.edsFitBelongs(to: url, edsFiles: state.edsFiles, edsFile: "map.emd", edsPath: url.path, edsOpening: false),
                       "a file the app's Open never saw has no fit of its own")
        state.noteEDSRoomFile(path: url.path)
        XCTAssertEqual(state.edsFiles, [url])
        XCTAssertTrue(AppState.edsFitBelongs(to: url, edsFiles: state.edsFiles, edsFile: "map.emd", edsPath: url.path, edsOpening: false))
        let follow = AppState.roomsToFollow(selected: url, edsFiles: state.edsFiles, eelsFiles: [], edsFile: "other.emd", eelsFile: "",
                                            edsPath: "/Volumes/data/session/other.emd", edsOpening: false, eelsOpening: false)
        XCTAssertTrue(follow.eds, "selected again while another file holds the room, it is read into the room again")
        XCTAssertFalse(follow.eels)
    }

    /// A document without a file (the generated demo) adds nothing, and a file the app's Open already routed is not added twice.
    /// Red under: an empty path noted as a file; the set written again for a file it holds.
    @MainActor func testADocumentWithoutAFileAndAKnownFileAddNothing() {
        let state = AppState(launch: LaunchOptions(arguments: []))
        state.noteEDSRoomFile(path: nil)
        state.noteEDSRoomFile(path: "")
        XCTAssertTrue(state.edsFiles.isEmpty, "the generated demo has no file")
        state.noteEDSRoomFile(path: "/Volumes/data/a.emd")
        state.noteEDSRoomFile(path: "/Volumes/data/a.emd")
        XCTAssertEqual(state.edsFiles, [URL(fileURLWithPath: "/Volumes/data/a.emd")])
    }

    /// The window notes the file whenever the one the EDS room holds changes, and the interim is marked for removal.
    /// Red under: the call dropped; the marker lost.
    func testTheWindowNotesTheFileTheRoomHolds() throws {
        let view = squeezed(try source("macTEM/UI/ContentView.swift"))
        XCTAssertTrue(view.contains(".onChange(of: appState.edx.source?.metadata.filePath) { _, path in appState.noteEDSRoomFile(path: path) }"))
        XCTAssertTrue(view.contains("INTERIM, delete at MacEMUI"), "the call is marked for removal")
        XCTAssertTrue(try source("macTEM/App/EDSRoomDoor.swift").contains("INTERIM, delete at MacEMUI"), "and so is the rule")
    }
}
