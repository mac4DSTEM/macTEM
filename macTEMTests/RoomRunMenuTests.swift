//
//  RoomRunMenuTests.swift
//  Workspace > Run (⌘R) runs the shown room's verb (Quantify, Run, Process, Index, Segment), titled with it and on only when the
//  toolbar's button can run it, as mac4DSTEM's Analysis > Run Current Task. Red before: the verb's only key was the toolbar button's
//  ⌘↩, listed in no menu and gone with the button while a run is in flight.
//

import XCTest
import TEMCore
import TEMSession
@testable import macTEM

nonisolated final class RoomRunMenuTests: XCTestCase {

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    private func squeezed(_ text: String) -> String { text.split(whereSeparator: \.isWhitespace).joined(separator: " ") }

    /// No document: nothing to run, and the item reads "Run". The Patterns room with the generated demo bound and Process available: the
    /// item is Process and ⌘R starts it; while it processes ⌘R is off.
    @MainActor func testRunIsTheRoomsVerbWhenItCanRun() async throws {
        let state = AppState()
        XCTAssertFalse(RoomPrimaryAction.canRun(RoomPrimaryAction.current(state)), "no document")
        XCTAssertEqual(RoomPrimaryAction.runTitle(state), "Run")
        XCTAssertEqual(RoomPrimaryAction.runTitle(nil), "Run", "no window")

        state.navigation.workspaceArea = .patterns
        await state.ebsd.bind(try DemoDocuments.ebsd()).value
        for _ in 0..<6000 where state.ebsd.isBusy || state.ebsd.isComputingMean {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(state.ebsd.canProcess, state.ebsd.processingRefusal?.sentence ?? "")
        XCTAssertEqual(RoomPrimaryAction.runTitle(state), "Process")
        XCTAssertTrue(RoomPrimaryAction.canRun(RoomPrimaryAction.current(state)))

        RoomPrimaryAction.runActive(state)
        XCTAssertTrue(state.ebsd.isProcessing, "⌘R runs the verb")
        XCTAssertFalse(RoomPrimaryAction.canRun(RoomPrimaryAction.current(state)), "off while it processes")
        RoomPrimaryAction.runActive(state)
        XCTAssertTrue(state.ebsd.isProcessing, "a second ⌘R does nothing")
        for _ in 0..<6000 where state.ebsd.isProcessing {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertFalse(state.ebsd.isProcessing)
    }

    /// The Workspace menu lists the verb with ⌘R, before Stop, run and gated through `RoomPrimaryAction`. Red under: no Run item, a
    /// second "r" key, the item enabled whatever the verb's state.
    func testTheWorkspaceMenuBindsRunToCommandR() throws {
        let app = try source("macTEM/App/macTEMApp.swift")
        let menu = squeezed(try XCTUnwrap(app.components(separatedBy: "CommandMenu(\"Workspace\")").last?
            .components(separatedBy: "CommandGroup(after: .help)").first))
        XCTAssertTrue(menu.contains("Button(RoomPrimaryAction.runTitle(appState)) { if let appState { RoomPrimaryAction.runActive(appState) } } "
            + ".keyboardShortcut(\"r\", modifiers: .command) .disabled(!RoomPrimaryAction.canRun(appState.flatMap { RoomPrimaryAction.current($0) }))"))
        let run = try XCTUnwrap(menu.range(of: "RoomPrimaryAction.runActive"))
        let stop = try XCTUnwrap(menu.range(of: "RoomPrimaryAction.stopActive"))
        XCTAssertLessThan(run.lowerBound, stop.lowerBound, "Run sits before Stop")
        XCTAssertEqual(app.components(separatedBy: ".keyboardShortcut(\"r\"").count - 1, 1, "⌘R is bound once")
    }
}
