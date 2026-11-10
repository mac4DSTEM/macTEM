//
//  MenuActionRelayTests.swift
//  Pins `MenuActionRelay`, the hand-off of "Open Image…" (⌘O) to a window that does not exist yet: a request is
//  taken exactly once (a second window appearing later does not repeat it), a second request before the take
//  replaces the first, `run` asks the window's AppState for the open panel, and `isEnabled` is enabled with no
//  focused window and with one unless that window is blocked (an open in flight). A Help > Open Demo Data entry is
//  handed over the same way and opens its document in the window that takes it.
//

import XCTest
@testable import macTEM
import ShellLayout

nonisolated final class MenuActionRelayTests: XCTestCase {

    @MainActor func testARequestIsTakenExactlyOnce() {
        let relay = MenuActionRelay()
        XCTAssertNil(relay.take(), "nothing asked for, nothing to take")
        relay.request(.openImage)
        XCTAssertEqual(relay.pendingAction, .openImage)
        XCTAssertEqual(relay.take(), .openImage)
        XCTAssertNil(relay.pendingAction)
        XCTAssertNil(relay.take(), "the next window to appear does not repeat the action")
    }

    /// The count the window watches rises with every request, so a minimised window (whose `.task` does not run
    /// again) is told; taking does not lower it. Red under: `request` not raising `requestCount`.
    @MainActor func testEveryRequestRaisesTheCountTheWindowWatches() {
        let relay = MenuActionRelay()
        let before = relay.requestCount
        relay.request(.openImage)
        XCTAssertEqual(relay.requestCount, before &+ 1)
        _ = relay.take()
        relay.request(.openImage)
        XCTAssertEqual(relay.requestCount, before &+ 2)
    }

    @MainActor func testASecondRequestBeforeTheTakeIsStillOneAction() {
        let relay = MenuActionRelay()
        relay.request(.openImage)
        relay.request(.openImage)
        XCTAssertEqual(relay.take(), .openImage)
        XCTAssertNil(relay.take())
    }

    @MainActor func testRunningOpenImageAsksTheWindowForTheOpenPanelOnce() {
        let state = AppState()
        let before = state.openImageRequest
        ShellLayout.MenuActionRelay<MenuAction>.run(.openImage, in: state)
        XCTAssertEqual(state.openImageRequest, before &+ 1)
    }

    /// Help > Open Demo Data with no window (#355): the entry is handed over as Open Image… is, taken once by the window that
    /// appears, and run there it opens the document in its room. Red before: `MenuAction` had no such action.
    @MainActor func testARequestedDemoIsTakenOnceAndRun() async {
        let relay = MenuActionRelay()
        relay.request(.openDemo(.ebsd))
        XCTAssertEqual(relay.take(), .openDemo(.ebsd))
        XCTAssertNil(relay.take(), "the next window to appear does not open it again")
        let state = AppState(launch: LaunchOptions(arguments: []))
        ShellLayout.MenuActionRelay<MenuAction>.run(.openDemo(.ebsd), in: state)
        XCTAssertEqual(state.navigation.workspaceArea, .patterns, "the document's room is shown")
        await state.lastOpen?.value
        XCTAssertNil(state.roomUnavailableReason(.patterns), "the Patterns room has the scan")
    }

    func testIsEnabledTruthTable() {
        // (hasFocusedWindow, blocked) → enabled.
        let table: [(Bool, Bool, Bool)] = [
            (false, false, true),   // no window: the item opens one
            (false, true, true),    // no window: nothing can block it
            (true, false, true),
            (true, true, false),    // the focused window is mid-open
        ]
        for (focused, blocked, enabled) in table {
            XCTAssertEqual(MenuActionRelay.isEnabled(hasFocusedWindow: focused, blocked: blocked), enabled,
                           "focused \(focused), blocked \(blocked)")
        }
    }
}
