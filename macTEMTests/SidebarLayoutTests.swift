//
//  SidebarLayoutTests.swift
//  The sidebar is the workspaces and their parts, filling the column (2026-11-10): the open files are the window's tabs, so the
//  Open Files list, its fixed-height rooms list above it and the Image menu's file picker are gone. The rows keep their pitch per
//  system sidebar size. Red under: the list back in the sidebar; the rooms list held to a height again; two sizes' rows swapped.
//

import ShellLayout
import SwiftUI
import XCTest
@testable import macTEM

nonisolated final class SidebarLayoutTests: XCTestCase {

    private func squeezed(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    @MainActor func testTheRowsFollowTheSystemSidebarSize() {
        XCTAssertEqual(LayoutPolicy.sidebarRoomRowHeight(.small), 30)
        XCTAssertEqual(LayoutPolicy.sidebarRoomRowHeight(.medium), 34)
        XCTAssertEqual(LayoutPolicy.sidebarRoomRowHeight(.large), 42)
    }

    func testTheSidebarIsTheWorkspacesAlone() throws {
        let sidebar = try squeezed("macTEM/UI/WorkspaceSidebar.swift")
        XCTAssertFalse(sidebar.contains("OpenItemsList"), "no Open Files list: the tabs are the open files")
        XCTAssertFalse(sidebar.contains(".frame(height:"), "the workspaces fill the column")
        XCTAssertTrue(sidebar.contains("roomsList .environment(\\.defaultMinListRowHeight, LayoutPolicy.sidebarRoomRowHeight(sidebarRowSize)) .frame(maxHeight: .infinity)"))
        let app = try squeezed("macTEM/App/macTEMApp.swift")
        XCTAssertFalse(app.contains("Picker(\"Open Images\""), "no file picker in the Image menu")
        XCTAssertFalse(app.contains("Button(\"Previous Image\")") || app.contains("Button(\"Next Image\")"))
    }
}
