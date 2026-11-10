//
//  RoomRequirementsTests.swift
//  The Requirements section (macTEM#396, mac4DSTEM's `RequirementsSection`): a room's inspector lists what its verb waits for, read from
//  the verb's own blocker, so the list and the toolbar never disagree. Red before: no `RoomRequirements`; red when a blocked verb lists
//  nothing, when a ready one lists something, or when a room's Settings tab does not open with the section.
//

import XCTest
import ShellLayout
import TEMCore
import TEMSession
@testable import macTEM

nonisolated final class RoomRequirementsTests: XCTestCase {

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    private func squeezed(_ text: String) -> String { text.split(whereSeparator: \.isWhitespace).joined(separator: " ") }

    /// Indexing with no phase: the toolbar's Index is off and the Requirements section says why, in the toolbar's own words.
    @MainActor func testABlockedIndexListsTheVerbsOwnReason() throws {
        let state = AppState()
        state.selectWorkspace(.indexing)
        XCTAssertEqual(RoomRequirements.unmet(state), [], "nothing open: the empty inspector says what to open")
        var demo = try DemoDocuments.ebsd()
        demo.dataset.crystalMap = nil
        state.ebsd.bind(demo)
        let verb = try XCTUnwrap(RoomPrimaryAction.current(state))
        XCTAssertFalse(verb.isEnabled)
        let unmet = RoomRequirements.unmet(state)
        XCTAssertEqual(unmet.map(\.id), ["indexing.index"])
        XCTAssertEqual(unmet.first?.title, verb.help, "the requirement is the gate's own sentence")
        XCTAssertNil(unmet.first?.opens, "the phase is added in this room")
    }

    /// Indexing with its phase: Index can run, so the section is absent.
    @MainActor func testAReadyIndexListsNothing() throws {
        let state = AppState()
        state.selectWorkspace(.indexing)
        state.ebsd.bind(try DemoDocuments.ebsd())
        if RoomPrimaryAction.current(state)?.isEnabled == true {
            XCTAssertEqual(RoomRequirements.unmet(state), [])
        } else {
            XCTAssertEqual(RoomRequirements.unmet(state).first?.title, RoomPrimaryAction.current(state)?.help)
        }
    }

    /// Rooms without a gate list nothing.
    @MainActor func testTheImageRoomListsNothing() {
        let state = AppState()
        XCTAssertEqual(RoomRequirements.unmet(state), [])
    }

    /// Each gated room's Settings tab opens with the section, before the room's own controls (mac4DSTEM: readiness first).
    func testEachGatedRoomOpensWithRequirements() throws {
        let text = squeezed(try source("macTEM/UI/WorkspaceInspector.swift"))
        for room in ["EELSRoomSettings()", "PatternsRoomSettings()", "IndexingRoomSettings()", "MapsRoomSettings()"] {
            XCTAssertTrue(text.contains("InspectorScrollColumn { RoomRequirementsSection() \(room)"), room)
        }
    }
}
