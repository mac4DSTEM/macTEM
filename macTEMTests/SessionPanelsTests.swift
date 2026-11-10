//
//  SessionPanelsTests.swift
//  The Replace and Save Anyway alerts of Save to Session (`SessionPanels.confirm`, the close question's sheet too): a window
//  closed under the alert answers Cancel, so the save that asked ends instead of hanging for the life of the process, which also
//  kept its file's place in the one-panel-per-file guard, so that file's next ⌘S did nothing; an alert ended the usual way gives
//  the user's answer.
//  Red before: `confirm` awaited the sheet with no willClose observer, and the await never returned.
//

import AppKit
import XCTest
@testable import macTEM

nonisolated final class SessionPanelsTests: XCTestCase {

    @MainActor private func shownWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 480, height: 320), styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        return window
    }

    /// A test window, the Replace alert as its sheet, the window closed: the await answers false (Cancel) within three seconds.
    /// A hang is endless, so any bound tells it from the answer; the answer takes the sheet's closing animation (about 0.3 s for
    /// a save panel, `ExportSnapshotTests`), so the bound is not a tight one a loaded Mac could miss. Before the fix the task is
    /// left suspended rather than awaited, so the test fails instead of hanging.
    @MainActor func testAWindowClosedUnderTheReplaceAlertAnswersCancel() async throws {
        let window = shownWindow()
        var answer: Bool?
        let sheet = Task.immediate {
            answer = await SessionPanels.confirm(title: "Replace?", detail: "", action: "Replace", on: window)
        }
        var waited = 0
        while window.attachedSheet == nil, waited < 300 {
            try await Task.sleep(for: .milliseconds(10))
            waited += 1
        }
        XCTAssertNotNil(window.attachedSheet, "setup: the alert is on the window")

        window.close()
        waited = 0
        while answer == nil, waited < 300 {
            try await Task.sleep(for: .milliseconds(10))
            waited += 1
        }
        let ended = answer
        XCTAssertEqual(ended, false, "a window closed under the alert is Cancel, within three seconds")
        if ended != nil { await sheet.value }
    }

    /// The alert's other end is the ordinary one: the first button is the action (true), so the closing observer changes nothing
    /// for an alert answered as usual. Red under: the helper answering Cancel whatever ended the sheet.
    @MainActor func testTheReplaceAlertGivesTheUsersAnswer() async throws {
        let window = shownWindow()
        defer { window.close() }
        var answer: Bool?
        let sheet = Task.immediate {
            answer = await SessionPanels.confirm(title: "Replace?", detail: "", action: "Replace", on: window)
        }
        var waited = 0
        while window.attachedSheet == nil, waited < 300 {
            try await Task.sleep(for: .milliseconds(10))
            waited += 1
        }
        let alert = try XCTUnwrap(window.attachedSheet, "setup: the alert is on the window")
        window.endSheet(alert, returnCode: .alertFirstButtonReturn)
        waited = 0
        while answer == nil, waited < 300 {
            try await Task.sleep(for: .milliseconds(10))
            waited += 1
        }
        let ended = answer
        XCTAssertEqual(ended, true, "the first button is the action")
        if ended != nil { await sheet.value }
    }
}
