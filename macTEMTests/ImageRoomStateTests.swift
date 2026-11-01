//
//  ImageRoomStateTests.swift
//  The Image room's two owners of the display and the measuring tools: the display window the shader takes (`DisplayWindow`, in
//  TEMSession/ImagePresentation.swift) and the marks on a file (`ImageMeasurements`). Each test names the mutation that
//  turns it red.
//

import ImagoCore
import XCTest
import TEMCore
import TEMSession
@testable import macTEM

nonisolated final class ImageRoomStateTests: XCTestCase {

    // MARK: The window the shader takes

    /// A window in raw values is the shader's fraction of the canvas's raw range; nil edges are the range's own. Red
    /// under: the window passed unmapped (raw values as fractions); low and high swapped; the range's low edge not
    /// subtracted.
    func testTheWindowIsAFractionOfTheRawRange() {
        let range: ClosedRange<Float> = -100...300
        let full = DisplayWindow.fractions(low: nil, high: nil, rawRange: range)
        XCTAssertEqual(full.low, 0)
        XCTAssertEqual(full.high, 1)
        let w = DisplayWindow.fractions(low: 0, high: 200, rawRange: range)
        XCTAssertEqual(w.low, 0.25)
        XCTAssertEqual(w.high, 0.75)
        let only = DisplayWindow.fractions(low: 100, high: nil, rawRange: range)
        XCTAssertEqual(only.low, 0.5)
        XCTAssertEqual(only.high, 1)
    }

    /// A window never draws the image blank: one outside the range is clamped into it, an empty or inverted one falls
    /// back to the full range, and so does an image with no finite range. Red under: the clamp removed; the fallback
    /// removed (an inverted window reaches the shader).
    func testAStaleOrEmptyWindowFallsBackToTheFullRange() {
        let range: ClosedRange<Float> = 0...10
        let wide = DisplayWindow.fractions(low: -50, high: 50, rawRange: range)
        XCTAssertEqual(wide.low, 0)
        XCTAssertEqual(wide.high, 1)
        let inverted = DisplayWindow.fractions(low: 8, high: 2, rawRange: range)
        XCTAssertEqual(inverted.low, 0)
        XCTAssertEqual(inverted.high, 1)
        let none = DisplayWindow.fractions(low: 3, high: 4, rawRange: nil)
        XCTAssertEqual(none.low, 0)
        XCTAssertEqual(none.high, 1)
        let constant = DisplayWindow.fractions(low: 3, high: 4, rawRange: 5...5)
        XCTAssertEqual(constant.low, 0)
        XCTAssertEqual(constant.high, 1)
    }

    // MARK: The marks on a file

    private func ramp() -> CalibratedImage {
        // value = column: a profile along a row reads its own column numbers.
        CalibratedImage(width: 8, height: 4, pixels: (0..<32).map { Float($0 % 8) },
                        x: AxisCalibration(scale: 0.5, unit: "nm", origin: 0), y: AxisCalibration(scale: 0.5, unit: "nm", origin: 0),
                        fileName: "ramp", source: "", voltage: nil)
    }

    /// A profile is computed from the image's pixels when its mark is made, moved and widened, and a distance mark has
    /// none. Red under: `add` not computing the profile; `move` not recomputing it; `setWidth` not clamping.
    @MainActor func testAProfileFollowsItsMark() throws {
        let image = ramp()
        let owner = ImageMeasurements()
        let profile = ImageMark(kind: .profile, points: [ImagePoint(x: 0, y: 1), ImagePoint(x: 6, y: 1)])
        owner.add(profile, on: image)
        owner.add(ImageMark(kind: .distance, points: [ImagePoint(x: 0, y: 0), ImagePoint(x: 3, y: 0)]), on: image)
        XCTAssertEqual(owner.marks.count, 2)
        XCTAssertNil(owner.profiles[owner.marks[1].id], "a distance has no profile")
        let first = try XCTUnwrap(owner.profiles[profile.id])
        XCTAssertEqual(first.samples.count, 7, "⌈6 + 1⌉ samples")
        XCTAssertEqual(first.samples.first ?? .nan, 0, accuracy: 1e-12)
        XCTAssertEqual(first.samples.last ?? .nan, 6, accuracy: 1e-12)
        owner.move(profile.id, point: 1, to: ImagePoint(x: 3, y: 1), on: image)
        XCTAssertEqual(owner.profiles[profile.id]?.samples.count, 4, "recomputed after the move")
        owner.setWidth(profile.id, 99, on: image)
        XCTAssertEqual(owner.mark(profile.id)?.width, ImageMeasurements.maximumWidth)
        XCTAssertEqual(owner.profiles[profile.id]?.width, ImageMeasurements.maximumWidth, "recomputed at the new width")
    }

    /// Adding selects the new mark; removing the selected one clears the selection and its profile; remove all empties
    /// the owner. Red under: `add` not selecting; `remove` leaving the profile or the selection behind.
    @MainActor func testAddingSelectsAndRemovingForgets() {
        let image = ramp()
        let owner = ImageMeasurements()
        let a = ImageMark(kind: .profile, points: [ImagePoint(x: 0, y: 0), ImagePoint(x: 2, y: 2)])
        let b = ImageMark(kind: .angle, points: [ImagePoint(x: 0, y: 0), ImagePoint(x: 2, y: 2), ImagePoint(x: 4, y: 0)])
        owner.add(a, on: image)
        XCTAssertEqual(owner.selection, a.id)
        owner.add(b, on: image)
        XCTAssertEqual(owner.selection, b.id)
        owner.selection = a.id
        owner.remove(a.id)
        XCTAssertNil(owner.selection)
        XCTAssertNil(owner.profiles[a.id])
        XCTAssertEqual(owner.marks.map(\.id), [b.id])
        owner.removeAll()
        XCTAssertTrue(owner.marks.isEmpty)
    }
}
