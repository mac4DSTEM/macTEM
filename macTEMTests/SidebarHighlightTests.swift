//
//  SidebarHighlightTests.swift
//  The rooms list is rebuilt when a room's availability changes, so a row whose selection is disabled never keeps its highlight beside
//  the room that is shown (a lone .msa left Image lit beside EDS; LoaderJourney checks it on screen).
//

import XCTest
import TEMSession
import ShellEDXModel
@testable import macTEM

nonisolated final class SidebarHighlightTests: XCTestCase {

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    /// Red under: the rooms list without its availability identity.
    func testTheRoomsListIsKeyedByWhichRoomsAreAvailable() throws {
        let sidebar = try source("macTEM/UI/WorkspaceSidebar.swift").split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let rooms = try XCTUnwrap(sidebar.range(of: "private var roomsList: some View {"))
        let tail = sidebar[rooms.upperBound...]
        XCTAssertTrue(tail.contains(".id(WorkspaceArea.allCases.map { appState.roomUnavailableReason($0) == nil })"))
    }

    /// The key changes exactly when a room's availability does: with nothing open only nothing is available; a spectrum image opening makes
    /// EDS available and Image not. Red under: a key that ignores the spectrum rooms.
    @MainActor func testTheKeyFollowsTheSpectrumRooms() {
        let state = AppState()
        let key = { WorkspaceArea.allCases.map { state.roomUnavailableReason($0) == nil } }
        let empty = key()
        state.edx.bind(DemoDocuments.edx())
        XCTAssertNotEqual(key(), empty)
        XCTAssertEqual(key()[WorkspaceArea.allCases.firstIndex(of: .edx)!], true)
        XCTAssertEqual(key()[WorkspaceArea.allCases.firstIndex(of: .image)!], false)
    }
}
