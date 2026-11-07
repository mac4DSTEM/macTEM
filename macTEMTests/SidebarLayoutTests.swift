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
        // Eight rooms since the Indexing room (P4-04): one row per room and the header's 32 pt.
        XCTAssertEqual(LayoutPolicy.sidebarRoomsListHeight(.small), 272)
        XCTAssertEqual(LayoutPolicy.sidebarRoomsListHeight(.medium), 304)
        XCTAssertEqual(LayoutPolicy.sidebarRoomsListHeight(.large), 368)
    }
}
