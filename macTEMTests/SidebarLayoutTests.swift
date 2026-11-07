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
        // Nine rooms since the Maps room (P3-04) after Indexing (P4-04): one row per room and the header's 32 pt.
        XCTAssertEqual(LayoutPolicy.sidebarRoomsListHeight(.small), 302)
        XCTAssertEqual(LayoutPolicy.sidebarRoomsListHeight(.medium), 338)
        XCTAssertEqual(LayoutPolicy.sidebarRoomsListHeight(.large), 410)
    }
}
