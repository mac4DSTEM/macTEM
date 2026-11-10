//
//  RoomWordsTests.swift
//  Role: the rooms' one-line descriptions, which the sidebar shows as each row's help tag and VoiceOver hint, say what the room does today.
//

import XCTest
@testable import macTEM

nonisolated final class RoomWordsTests: XCTestCase {
    /// Red before: the EELS line named only the low-loss thickness map, and the Indexing line only Hough indexing.
    func testEveryRoomSubtitleSaysWhatTheRoomDoes() {
        for area in WorkspaceArea.allCases { XCTAssertFalse(area.subtitle.isEmpty, "\(area)") }
        XCTAssertTrue(WorkspaceArea.indexing.subtitle.contains("dictionary"), "dictionary indexing ships beside Hough")
        XCTAssertTrue(WorkspaceArea.eels.subtitle.contains("core-loss edges"), "the room fits core-loss edges, not only t/λ")
    }
}
