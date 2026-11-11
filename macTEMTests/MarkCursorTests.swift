//
//  MarkCursorTests.swift
//  The VoiceOver cursor of the Image room's marks and the Diffraction room's spots (`MarkCursor`, UI/MarkCursor.swift; macTEM#262):
//  where it starts, the step, the clamp, the words it is spoken in, and where its element sits. Pure, as mac4DSTEM's
//  `DiskLabelCursorTests`. What its actions make is ImageMeasurementsSessionTests' (marks) and DiffractionAnalysisTests' (spots).
//  Red before the change: there was no cursor; the marks and the spots were made only with the pointer.
//

import CoreGraphics
import XCTest
import TEMCore
import TEMSession
@testable import macTEM

nonisolated final class MarkCursorTests: XCTestCase {

    private typealias Pixel = MarkCursor.Pixel

    /// One step is 1 % of the axis, never below one pixel. Red under: a fiftieth (mac4DSTEM's), a step of zero on a small picture.
    func testAStepIsOneHundredthOfTheAxisAndAtLeastOnePixel() {
        XCTAssertEqual(MarkCursor.step(extent: 4096), 40)
        XCTAssertEqual(MarkCursor.step(extent: 512), 5)
        XCTAssertEqual(MarkCursor.step(extent: 199), 1)
        XCTAssertEqual(MarkCursor.step(extent: 40), 1)
        XCTAssertEqual(MarkCursor.step(extent: 1), 1)
        XCTAssertEqual(MarkCursor.step(extent: 0), 1)
    }

    /// The cursor starts on the picture's centre pixel, and a place off the picture (one moved on a larger picture) is held at its
    /// edge. Red under: the centre at width / 2 (off a one-pixel picture), no clamp, x clamped to the height.
    func testTheCursorStartsAtTheCentreAndIsHeldOnThePicture() {
        XCTAssertEqual(MarkCursor.resolved(nil, width: 40, height: 24), Pixel(x: 19, y: 11))
        XCTAssertEqual(MarkCursor.resolved(nil, width: 512, height: 512), Pixel(x: 255, y: 255))
        XCTAssertEqual(MarkCursor.resolved(nil, width: 1, height: 1), Pixel(x: 0, y: 0))
        XCTAssertEqual(MarkCursor.resolved(Pixel(x: 500, y: -4), width: 40, height: 24), Pixel(x: 39, y: 0))
        XCTAssertEqual(MarkCursor.resolved(Pixel(x: 7, y: 30), width: 40, height: 24), Pixel(x: 7, y: 23))
        XCTAssertEqual(MarkCursor.centre(width: 40, height: 24), Pixel(x: 19, y: 11))
    }

    /// Each move goes one step of its own axis in its direction; up is a smaller row, as the picture is drawn.
    /// Red under: two directions swapped, the width's step used for y, up as a larger row.
    func testEachMoveStepsItsAxisInItsDirection() {
        let start = Pixel(x: 500, y: 150)
        XCTAssertEqual(MarkCursor.moved(start, by: .right, width: 1000, height: 300), Pixel(x: 510, y: 150))
        XCTAssertEqual(MarkCursor.moved(start, by: .left, width: 1000, height: 300), Pixel(x: 490, y: 150))
        XCTAssertEqual(MarkCursor.moved(start, by: .down, width: 1000, height: 300), Pixel(x: 500, y: 153))
        XCTAssertEqual(MarkCursor.moved(start, by: .up, width: 1000, height: 300), Pixel(x: 500, y: 147))
    }

    /// A move past an edge stops on the last pixel, a move from a place off the picture starts from its edge, and nothing leaves
    /// 0…width − 1 by 0…height − 1. Red under: no clamp after the step; the clamp at width instead of width − 1; a place off the
    /// picture stepped from where it was (a step that lands off the picture again, or overflows).
    func testAMoveIsHeldOnThePicture() {
        XCTAssertEqual(MarkCursor.moved(Pixel(x: 0, y: 0), by: .left, width: 1000, height: 300), Pixel(x: 0, y: 0))
        XCTAssertEqual(MarkCursor.moved(Pixel(x: 0, y: 0), by: .up, width: 1000, height: 300), Pixel(x: 0, y: 0))
        XCTAssertEqual(MarkCursor.moved(Pixel(x: 999, y: 299), by: .right, width: 1000, height: 300), Pixel(x: 999, y: 299))
        XCTAssertEqual(MarkCursor.moved(Pixel(x: 999, y: 298), by: .down, width: 1000, height: 300), Pixel(x: 999, y: 299))
        XCTAssertEqual(MarkCursor.moved(Pixel(x: 995, y: 150), by: .right, width: 1000, height: 300), Pixel(x: 999, y: 150),
                       "a step past the edge stops on it")
        XCTAssertEqual(MarkCursor.moved(Pixel(x: 5000, y: -10), by: .left, width: 1000, height: 300), Pixel(x: 989, y: 0))
        XCTAssertEqual(MarkCursor.moved(Pixel(x: Int.max, y: Int.min), by: .right, width: 40, height: 24), Pixel(x: 39, y: 0))
        var p = Pixel(x: 3, y: 3)
        for move in [MarkCursor.Move.left, .up, .left, .up, .left, .up, .left, .up] { p = MarkCursor.moved(p, by: move, width: 40, height: 24) }
        XCTAssertEqual(p, Pixel(x: 0, y: 0))
    }

    /// A pixel is the point a click on its centre lands on: the integer column and row. Red under: the corner (x + 0.5) instead.
    func testAPixelIsItsCentreInImageCoordinates() {
        XCTAssertEqual(MarkCursor.imagePoint(Pixel(x: 12, y: 7)), ImagePoint(x: 12, y: 7))
    }

    /// The cursor is spoken in the status line's words, the Image room's with the point it sets next and then the readout of the
    /// pixel (its raw value) where there is one; no number is grouped, in any locale (a String, never a localized key). Red under: x
    /// and y swapped; a grouped "1,200"; the point and the count swapped; the readout dropped, or spoken without the place.
    func testTheCursorIsSpokenInTheReadoutsWords() {
        XCTAssertEqual(MarkCursor.spokenValue(Pixel(x: 1200, y: 88)), "x 1200, y 88")
        XCTAssertEqual(MarkCursor.spokenValue(Pixel(x: 120, y: 88), point: 2, of: 2), "Point 2 of 2, x 120, y 88")
        XCTAssertEqual(MarkCursor.spokenValue(Pixel(x: 4095, y: 1024), point: 1, of: 3), "Point 1 of 3, x 4095, y 1024")
        XCTAssertEqual(MarkCursor.spokenValue(Pixel(x: 2, y: 1), point: 1, of: 2, readout: "x 2, y 1 \u{00B7} 9744"),
                       "Point 1 of 2, x 2, y 1 \u{00B7} 9744")
        XCTAssertEqual(MarkCursor.spokenValue(Pixel(x: 2, y: 1), point: 1, of: 2, readout: ""), "Point 1 of 2, x 2, y 1")
    }

    /// The Image room's element is named by the tool's mark, and the pane's hint names it while a tool is chosen (the Measure note
    /// names only the pointer's gestures). Red under: one name for every tool; the hint left without the element, or naming one with Pan.
    func testTheElementIsNamedByItsToolAndThePaneHintNamesIt() {
        XCTAssertEqual(MarkCursor.elementLabel(.distance), "Distance point")
        XCTAssertEqual(MarkCursor.elementLabel(.angle), "Angle point")
        XCTAssertEqual(MarkCursor.elementLabel(.profile), "Profile point")
        XCTAssertEqual(MarkCursor.paneHint("Zoom.", kind: nil), "Zoom.")
        XCTAssertEqual(MarkCursor.paneHint("Zoom.", kind: .angle), "Zoom. Set the points of a mark with the actions of the Angle point.")
    }

    /// A place in image coordinates (the Diffraction room's pattern centre) is its nearest pixel, held on the picture; one that is not
    /// a number is none. Red under: truncation (255.6 to 255), no hold (a typed centre off the picture, or one that overflows `Int`),
    /// the column taken for the row.
    func testAPlaceIsItsNearestPixelOnThePicture() {
        XCTAssertEqual(MarkCursor.nearest(column: 255.6, row: 256.4, width: 512, height: 512), Pixel(x: 256, y: 256))
        XCTAssertEqual(MarkCursor.nearest(column: 30.2, row: 7.8, width: 40, height: 24), Pixel(x: 30, y: 8))
        XCTAssertEqual(MarkCursor.nearest(column: -12, row: 900, width: 40, height: 24), Pixel(x: 0, y: 23))
        XCTAssertEqual(MarkCursor.nearest(column: 1e300, row: -1e300, width: 40, height: 24), Pixel(x: 39, y: 0))
        XCTAssertNil(MarkCursor.nearest(column: .nan, row: 3, width: 40, height: 24))
        XCTAssertNil(MarkCursor.nearest(column: 3, row: .infinity, width: 40, height: 24))
    }

    /// The actions are named as the issue names them, one per direction. Red under: a renamed or a missing action.
    func testTheMovesAreNamedByTheirDirection() {
        XCTAssertEqual(MarkCursor.Move.allCases.map(\.actionName),
                       ["Move point left", "Move point right", "Move point up", "Move point down"])
        XCTAssertEqual(MarkCursor.placeActionName, "Place point at centre")
    }

    /// The element sits on the cursor's point, held inside the box so it stays on screen when the pixel is zoomed out of view; a
    /// point that is not a number puts it at the centre. Red under: no hold (the element off screen, out of VoiceOver's reach);
    /// a hold at the box's edge instead of half the element inside it.
    func testTheElementSitsOnTheCursorInsideTheBox() {
        let box = CGSize(width: 400, height: 240)
        let half = MarkCursor.elementSide / 2
        XCTAssertEqual(MarkCursor.elementCentre(CGPoint(x: 100, y: 50), in: box), CGPoint(x: 100, y: 50))
        XCTAssertEqual(MarkCursor.elementCentre(CGPoint(x: -300, y: 900), in: box), CGPoint(x: half, y: 240 - half))
        XCTAssertEqual(MarkCursor.elementCentre(CGPoint(x: 1000, y: -1), in: box), CGPoint(x: 400 - half, y: half))
        XCTAssertEqual(MarkCursor.elementCentre(CGPoint(x: CGFloat.nan, y: 10), in: box), CGPoint(x: 200, y: 120))
    }
}
