//
//  DemoDataTests.swift
//  App Review needs a way to try macTEM without a microscope file (macTEM#105). Help > Open Demo Data opens the generated
//  documents; each must land in its room with data there.
//

import XCTest
@testable import macTEM

nonisolated final class DemoDataTests: XCTestCase {

    /// Mutation: point any case's `openDemo` at the wrong document, or drop the room switch - red.
    @MainActor func testEveryDemoOpensInItsRoomWithDataThere() async throws {
        for demo in DemoDocument.allCases {
            let state = AppState(launch: LaunchOptions(arguments: []))
            await state.openDemo(demo)?.value
            XCTAssertEqual(state.navigation.workspaceArea, demo.room, demo.title)
            XCTAssertNil(state.roomUnavailableReason(demo.room), "\(demo.title): \(demo.room) has no data")
        }
    }

    /// The four generated documents, one per room, then the shipped SEM-EDS spectrum (the EDS room again, as a real file) and the shipped nickel EBSD scan (Patterns).
    func testTheMenuOffersOneEntryPerRoomWithData() {
        XCTAssertEqual(DemoDocument.allCases.map(\.room), [.image, .diffraction, .edx, .eels, .edx, .patterns])
        XCTAssertEqual(Set(DemoDocument.allCases.map(\.title)).count, DemoDocument.allCases.count)
    }
}
