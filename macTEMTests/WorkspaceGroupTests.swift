//
//  WorkspaceGroupTests.swift
//  The sidebar's workspaces (2026-11-10, Paul: "isnt this all part of ebsd"): five workspaces in mac4DSTEM's shape, ⌘1…⌘5, each
//  room a part of one; Go to a workspace comes back to the room it was left in; a workspace with nothing for the open files cannot be
//  entered; the row that reads as selected is the part, or the workspace when it is one room.
//

import XCTest
@testable import macTEM

nonisolated final class WorkspaceGroupTests: XCTestCase {

    /// Every room is a part of exactly one workspace, in the rooms' own order. Red under: a room left out; EBSD's parts out of order.
    func testEveryRoomIsAPartOfOneWorkspace() {
        XCTAssertEqual(WorkspaceGroup.allCases.flatMap(\.parts).sorted { $0.rawValue < $1.rawValue },
                       WorkspaceArea.allCases.sorted { $0.rawValue < $1.rawValue })
        XCTAssertEqual(WorkspaceGroup.imaging.parts, [.image, .fft])
        XCTAssertEqual(WorkspaceGroup.spectroscopy.parts, [.edx, .eels])
        XCTAssertEqual(WorkspaceGroup.diffraction.parts, [.diffraction])
        XCTAssertEqual(WorkspaceGroup.ebsd.parts, [.patterns, .indexing, .maps])
        XCTAssertEqual(WorkspaceGroup.results.parts, [.results])
        XCTAssertEqual(WorkspaceGroup.allCases.filter(\.hasParts), [.imaging, .spectroscopy, .ebsd])
    }

    /// The row that reads as selected: the part in a workspace with parts, the workspace itself when it is one room. Red under: the
    /// workspace row lit while one of its parts is in front.
    func testTheSelectedRowIsThePartOrTheOneRoomWorkspace() {
        XCTAssertEqual(SidebarRoute.current(.maps), .room(.maps))
        XCTAssertEqual(SidebarRoute.current(.fft), .room(.fft))
        XCTAssertEqual(SidebarRoute.current(.diffraction), .workspace(.diffraction))
        XCTAssertEqual(SidebarRoute.current(.results), .workspace(.results))
    }

    /// Go to a workspace lands on its first part that can be entered, then on the part it was left in; a workspace with nothing for
    /// the open files is not entered. Red under: always the first part; entering Spectroscopy with no spectrum image open.
    @MainActor func testGoToAWorkspaceComesBackToItsLastPart() async throws {
        let state = AppState()
        await state.ebsd.bind(try DemoDocuments.ebsd()).value
        state.selectWorkspaceGroup(.ebsd)
        XCTAssertEqual(state.navigation.workspaceArea, .patterns)
        state.selectWorkspace(.indexing)
        XCTAssertNotNil(state.workspaceUnavailableReason(.spectroscopy), "no spectrum image is open")
        state.selectWorkspaceGroup(.spectroscopy)
        XCTAssertEqual(state.navigation.workspaceArea, .indexing, "a workspace with nothing open for it is not entered")
        state.edx.bind(DemoDocuments.edx())
        state.selectWorkspaceGroup(.spectroscopy)
        XCTAssertEqual(state.navigation.workspaceArea, .edx)
        state.selectWorkspaceGroup(.ebsd)
        XCTAssertEqual(state.navigation.workspaceArea, .indexing, "back to the part EBSD was left in")
    }

    /// The sidebar binding writes through the navigation seam. Red under: a workspace row that does nothing.
    @MainActor func testTheSidebarSelectionGoesThroughTheSeam() {
        let state = AppState()
        state.sidebarRoute.wrappedValue = .workspace(.results)
        XCTAssertEqual(state.navigation.workspaceArea, .results)
        state.sidebarRoute.wrappedValue = .room(.fft)
        XCTAssertEqual(state.navigation.workspaceArea, .fft)
        XCTAssertEqual(state.sidebarRoute.wrappedValue, .room(.fft))
    }
}
