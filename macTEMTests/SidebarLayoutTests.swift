//
//  SidebarLayoutTests.swift
//  Pins the rooms list's height per system sidebar size (no gap under the rooms): the values measured on the
//  2026-10-13 scratch builds, and that a larger sidebar size never gets a shorter list. Mutations each test must go red
//  under: two sizes' heights swapped; a size falling through to another's height.
//

import ShellLayout
import SwiftUI
import XCTest
@testable import macTEM

nonisolated final class SidebarLayoutTests: XCTestCase {

    @MainActor func testTheRoomsListHeightFollowsTheSystemSidebarSize() {
        // Five workspaces (2026-11-10): one row per workspace and the header's 32 pt; a workspace with parts adds a row per part and
        // its section header's 32 pt (EBSD: three parts).
        XCTAssertEqual(LayoutPolicy.sidebarRoomsListHeight(.small, parts: 0), 182)
        XCTAssertEqual(LayoutPolicy.sidebarRoomsListHeight(.medium, parts: 0), 202)
        XCTAssertEqual(LayoutPolicy.sidebarRoomsListHeight(.large, parts: 0), 242)
        XCTAssertEqual(LayoutPolicy.sidebarRoomsListHeight(.small, parts: 3), 304)
        XCTAssertEqual(LayoutPolicy.sidebarRoomsListHeight(.medium, parts: 3), 336)
        XCTAssertEqual(LayoutPolicy.sidebarRoomsListHeight(.large, parts: 3), 400)
    }
}
