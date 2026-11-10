//
//  ImageRoomToolsTests.swift
//  The Image room's measuring tools (`ImageRoomTools.Tool`, #286): what each is called in the Measure section's picker and the
//  Image menu, the kind of mark it draws, its symbol, and its ⌃⌘ digit. The tools share the digits 1 to 4 with the rooms on
//  purpose (⌃⌘ against ⌘), so nothing here compares the two.
//

import XCTest
import TEMSession
@testable import macTEM

nonisolated final class ImageRoomToolsTests: XCTestCase {

    /// The tools in the picker's and the menu's order, by title. Red under: a renamed title, a tool added or dropped, a new order.
    @MainActor func testTheToolsArePanDistanceAngleAndProfileInThatOrder() {
        XCTAssertEqual(ImageRoomTools.Tool.allCases.map { $0.title }, ["Pan", "Distance", "Angle", "Profile"])
        XCTAssertEqual(ImageRoomTools.Tool.allCases.map { $0.id }, ["pan", "distance", "angle", "profile"])
        XCTAssertEqual(ImageRoomTools.Tool.allCases.map { $0.systemImage }, ["hand.raised", "ruler", "angle", "chart.xyaxis.line"])
    }

    /// The ⌃⌘ digits are 1 to 4 in the tools' order, one each. Red under: a changed digit, two tools on one digit.
    @MainActor func testTheShortcutDigitsAreOneToFourInOrderAndUnique() {
        let digits = ImageRoomTools.Tool.allCases.map { $0.shortcutDigit }
        XCTAssertEqual(digits, ["1", "2", "3", "4"])
        XCTAssertEqual(Set(digits).count, ImageRoomTools.Tool.allCases.count, "two tools share a digit")
        XCTAssertEqual(ImageRoomTools.Tool.pan.shortcutDigit, "1")
        XCTAssertEqual(ImageRoomTools.Tool.distance.shortcutDigit, "2")
        XCTAssertEqual(ImageRoomTools.Tool.angle.shortcutDigit, "3")
        XCTAssertEqual(ImageRoomTools.Tool.profile.shortcutDigit, "4")
    }

    /// Pan draws no mark; each other tool draws the mark of its own name, and every kind of mark has exactly one tool (the marks
    /// list finds a mark's symbol by its kind). Red under: a mark kind on Pan, two tools swapped, a kind without a tool.
    @MainActor func testOnlyPanDrawsNoMarkAndEachOtherToolDrawsItsOwnKind() {
        XCTAssertNil(ImageRoomTools.Tool.pan.markKind)
        XCTAssertEqual(ImageRoomTools.Tool.distance.markKind, .distance)
        XCTAssertEqual(ImageRoomTools.Tool.angle.markKind, .angle)
        XCTAssertEqual(ImageRoomTools.Tool.profile.markKind, .profile)
        for tool in ImageRoomTools.Tool.allCases {
            XCTAssertEqual(tool.markKind, ImageMark.Kind(rawValue: tool.rawValue), "\(tool.title) draws another tool's mark")
        }
        for kind in ImageMark.Kind.allCases {
            XCTAssertEqual(ImageRoomTools.Tool.allCases.filter { $0.markKind == kind }.count, 1, "\(kind.rawValue) has not one tool")
        }
    }

    /// A window starts on Pan with no cursor readout. Red under: another default tool.
    @MainActor func testAWindowStartsOnPan() {
        let tools = ImageRoomTools()
        XCTAssertEqual(tools.tool.id, "pan")
        XCTAssertNil(tools.readout)
    }
}
