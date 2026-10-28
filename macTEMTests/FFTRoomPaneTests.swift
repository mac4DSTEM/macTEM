//
//  FFTRoomPaneTests.swift
//  The FFT room's two panes ("The room"): what
//  they say (`FFTPaneFormat`), which pixels the source pane draws and how (`FFTSourceLayer`), where the region's outline,
//  handles and drags sit in pane points (`FFTRegionGeometry`, through `MarkGeometry`), and where the transform's bins,
//  spots and mask circles sit on a non-square box (`FFTSpectrumLayout`, `FFTSpotMarkers`). Every number is the closed form
//  of the registration, computed by hand in the test; no gesture, view or app host is needed. Each test names the
//  mutation(s) that turn it red. The room adds no arithmetic to a core's number: the region rules are lane A's, tested
//  there; what is pinned here is that the panes hand them the right points.
//

import ShellControls
import ShellLayout
import XCTest
import SwiftUI
import AppKit
import TEMCore
import TEMSession
import ImagoFilters
import ImagoCore
import ImagoFFT
@testable import macTEM
import ShellMetal

nonisolated final class FFTRoomPaneTests: XCTestCase {

    // MARK: Fixtures

    /// The source pane: a 300 × 200 image in a 600 × 400 box, 2 points per pixel at zoom 1.
    private func source(zoom: CGFloat = 1, offset: CGSize = .zero) -> MarkGeometry {
        FFTPaneGeometry.make(box: CGSize(width: 600, height: 400), width: 300, height: 200, zoom: zoom, offset: offset)
    }

    private let crop = PixelCrop(row: 40, col: 60, height: 64, width: 64)

    private func canvas(_ version: Int, _ side: Int = 4, range: ClosedRange<Float>? = 0...1) -> CanvasPixels {
        CanvasPixels(width: side, height: side, normalized: [Float](repeating: 0.5, count: side * side),
                     contentVersion: version, rawRange: range)
    }

    private let en = Locale(identifier: "en_US")

    private func assertEqual(_ a: CGPoint, _ b: CGPoint, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.x, b.x, accuracy: 1e-9, "x \(message)", file: file, line: line)
        XCTAssertEqual(a.y, b.y, accuracy: 1e-9, "y \(message)", file: file, line: line)
    }

    // MARK: The region outline

    /// The outline is the crop's PIXEL EDGES, not its pixel centres: the top-left is half a pixel before the first pixel
    /// and the bottom-right half a pixel past the last, at every zoom and pan. Red under: the outline drawn between the
    /// pixel centres (col, row … col + w − 1, row + h − 1); the zoom left out of the map.
    func testTheOutlineIsTheCropsPixelEdgesAtAnyZoomAndPan() {
        let g1 = source()
        let r1 = FFTRegionGeometry.rect(of: crop, in: g1)
        assertEqual(r1.origin, CGPoint(x: 120, y: 80))
        XCTAssertEqual(r1.width, 128, accuracy: 1e-9)
        XCTAssertEqual(r1.height, 128, accuracy: 1e-9)
        // Zoom 3 about the pane centre, panned (−30, 12): x = ((q.x + ½)·2 − 300)·3 − 30 + 300, y likewise with 200.
        let g3 = source(zoom: 3, offset: CGSize(width: -30, height: 12))
        let r3 = FFTRegionGeometry.rect(of: crop, in: g3)
        XCTAssertEqual(r3.minX, -270, accuracy: 1e-9)
        XCTAssertEqual(r3.minY, -148, accuracy: 1e-9)
        XCTAssertEqual(r3.width, 384, accuracy: 1e-9)
        XCTAssertEqual(r3.height, 384, accuracy: 1e-9)
    }

    /// Each corner is where the pane draws that pixel edge. Red under: two corners swapped.
    func testEachCornerIsDrawnAtItsOwnPixelEdge() {
        let g = source()
        assertEqual(FFTRegionGeometry.corner(.topLeft, of: crop, in: g), CGPoint(x: 120, y: 80))
        assertEqual(FFTRegionGeometry.corner(.topRight, of: crop, in: g), CGPoint(x: 248, y: 80))
        assertEqual(FFTRegionGeometry.corner(.bottomLeft, of: crop, in: g), CGPoint(x: 120, y: 208))
        assertEqual(FFTRegionGeometry.corner(.bottomRight, of: crop, in: g), CGPoint(x: 248, y: 208))
        // A non-square crop (a corner's x is the crop's width, its y the crop's height).
        let wide = PixelCrop(row: 10, col: 20, height: 30, width: 50)
        assertEqual(FFTRegionGeometry.corner(.bottomRight, of: wide, in: g), CGPoint(x: 140, y: 80))
    }

    // MARK: What a press takes

    /// A press within the handle radius of a corner resizes (even outside the square), a press inside moves, a press
    /// elsewhere is not ours (the pane pans); with no region every press draws. Red under: the corner test dropped; the
    /// disc's radius 4; the outside press taken as a move; the no-region press not a draw.
    func testAPressTakesACornerThenTheInsideThenNothing() {
        let g = source()   // the square spans (120, 80)…(248, 208)
        XCTAssertEqual(FFTRegionGeometry.grab(at: CGPoint(x: 122, y: 83), region: crop, in: g), .resize(.topLeft))
        XCTAssertEqual(FFTRegionGeometry.grab(at: CGPoint(x: 246, y: 206), region: crop, in: g), .resize(.bottomRight))
        XCTAssertEqual(FFTRegionGeometry.grab(at: CGPoint(x: 250, y: 80), region: crop, in: g), .resize(.topRight))
        XCTAssertEqual(FFTRegionGeometry.grab(at: CGPoint(x: 118, y: 211), region: crop, in: g), .resize(.bottomLeft))
        // 5.7 pt from the bottom-right corner, outside the square: the disc still takes it.
        XCTAssertEqual(FFTRegionGeometry.grab(at: CGPoint(x: 252, y: 212), region: crop, in: g), .resize(.bottomRight))
        XCTAssertEqual(FFTRegionGeometry.grab(at: CGPoint(x: 184, y: 144), region: crop, in: g), .move)
        XCTAssertEqual(FFTRegionGeometry.grab(at: CGPoint(x: 135, y: 95), region: crop, in: g), .move, "21 pt from a corner")
        XCTAssertNil(FFTRegionGeometry.grab(at: CGPoint(x: 100, y: 60), region: crop, in: g))
        XCTAssertNil(FFTRegionGeometry.grab(at: CGPoint(x: 256, y: 216), region: crop, in: g), "11.3 pt from the corner")
        XCTAssertEqual(FFTRegionGeometry.grab(at: CGPoint(x: 10, y: 10), region: nil, in: g), .draw)
    }

    /// The corner discs never swallow a small square: the radius is a third of the side at most, so the middle of a
    /// 6-point region (a 32-px region on a 3000-px image) still moves. Red under: the radius not capped.
    func testTheCornerDiscsLeaveTheMiddleOfASmallRegionToMove() {
        XCTAssertEqual(FFTRegionGeometry.handleRadius(forSide: 128), 8)
        XCTAssertEqual(FFTRegionGeometry.handleRadius(forSide: 24), 8)
        XCTAssertEqual(FFTRegionGeometry.handleRadius(forSide: 9), 3)
        XCTAssertEqual(FFTRegionGeometry.handleRadius(forSide: 0), 0)
        // 3000 × 2000 px in a 600 × 400 box: 0.2 pt per pixel, a 32-px square is 6.4 pt across.
        let g = FFTPaneGeometry.make(box: CGSize(width: 600, height: 400), width: 3000, height: 2000, zoom: 1, offset: .zero)
        let small = PixelCrop(row: 1000, col: 1000, height: 32, width: 32)   // (200, 200)…(206.4, 206.4)
        XCTAssertEqual(FFTRegionGeometry.grab(at: CGPoint(x: 203.2, y: 203.2), region: small, in: g), .move)
        XCTAssertEqual(FFTRegionGeometry.grab(at: CGPoint(x: 200.5, y: 200.5), region: small, in: g), .resize(.topLeft))
    }

    /// The overlay takes a press exactly where `grab` would act on it — the square and its four corner discs — and
    /// nowhere else, so no part of the pane is a dead zone that neither pans nor drags; with no region it is the whole
    /// pane. Red under: the discs left out of the shape; the shape the whole pane (the pan blocked); a press outside the
    /// square taken as a move (the shape and the grab then disagree).
    func testTheHitShapeIsWhereAPressIsTaken() {
        let g = source()
        let pane = CGRect(x: 0, y: 0, width: 600, height: 400)
        let shape = FFTRegionGeometry.hitShape(region: crop, in: g).path(in: pane)
        XCTAssertTrue(shape.contains(CGPoint(x: 184, y: 144)))
        XCTAssertTrue(shape.contains(CGPoint(x: 252, y: 212)), "the disc outside the square")
        XCTAssertFalse(shape.contains(CGPoint(x: 256, y: 216)))
        XCTAssertFalse(shape.contains(CGPoint(x: 100, y: 60)))
        var checked = 0
        for x in stride(from: 3.3, to: 600, by: 7.1) {
            for y in stride(from: 2.7, to: 400, by: 7.3) {
                let p = CGPoint(x: x, y: y)
                XCTAssertEqual(shape.contains(p), FFTRegionGeometry.grab(at: p, region: crop, in: g) != nil, "\(p)")
                checked += 1
            }
        }
        XCTAssertGreaterThan(checked, 4000)
        let whole = FFTRegionGeometry.hitShape(region: nil, in: g).path(in: pane)
        XCTAssertTrue(whole.contains(CGPoint(x: 5, y: 5)))
        XCTAssertTrue(whole.contains(CGPoint(x: 595, y: 395)))
    }

    // MARK: Pane points to image pixels

    /// A drag in pane points is a drag in image pixels divided by the points per pixel OF EACH AXIS at the current zoom:
    /// 30 points are 15 pixels at zoom 1 and 5 at zoom 3, and an axis drawn at 4 points per pixel moves 10 pixels for 40
    /// points. Red under: the zoom ignored; y divided by x's points per pixel; the translation used as pixels.
    func testAPaneTranslationIsDividedByThePointsPerPixelOfEachAxis() {
        let t = CGSize(width: 30, height: -18)
        let z1 = FFTRegionGeometry.pixels(ofPaneTranslation: t, in: source())
        XCTAssertEqual(z1.dx, 15, accuracy: 1e-12)
        XCTAssertEqual(z1.dy, -9, accuracy: 1e-12)
        let z3 = FFTRegionGeometry.pixels(ofPaneTranslation: t, in: source(zoom: 3))
        XCTAssertEqual(z3.dx, 5, accuracy: 1e-12)
        XCTAssertEqual(z3.dy, -3, accuracy: 1e-12)
        // 300 × 100 px in a 600 × 400 box: 2 points per pixel along x, 4 along y.
        let tall = FFTPaneGeometry.make(box: CGSize(width: 600, height: 400), width: 300, height: 100, zoom: 1, offset: .zero)
        let a = FFTRegionGeometry.pixels(ofPaneTranslation: CGSize(width: 30, height: 40), in: tall)
        XCTAssertEqual(a.dx, 15, accuracy: 1e-12)
        XCTAssertEqual(a.dy, 10, accuracy: 1e-12)
    }

    /// An inside drag moves the crop it was pressed on by the drag in image pixels at the zoom of the moment; a drag
    /// under 2 points leaves the crop where it is (a click is not a move). Red under: the zoom ignored; the translation
    /// used as pixels; the threshold removed (a 1-point click moves the crop).
    func testAnInsideDragMovesTheCropFromWhereItWasPressed() {
        let press = CGPoint(x: 184, y: 144)
        let moved = FFTRegionGeometry.proposed(.move, from: crop, press: press, location: CGPoint(x: 214, y: 126), in: source())
        XCTAssertEqual(moved, PixelCrop(row: 31, col: 75, height: 64, width: 64), "(+15, −9) px")
        let atZoom3 = FFTRegionGeometry.proposed(.move, from: crop, press: press, location: CGPoint(x: 214, y: 126),
                                                 in: source(zoom: 3))
        XCTAssertEqual(atZoom3, PixelCrop(row: 37, col: 65, height: 64, width: 64), "(+5, −3) px at zoom 3")
        // Far right: shifted into the image, never shrunk (lane A's rule; the wiring is what is pinned).
        let far = FFTRegionGeometry.proposed(.move, from: crop, press: press, location: CGPoint(x: 1184, y: 144), in: source())
        XCTAssertEqual(far, PixelCrop(row: 40, col: 236, height: 64, width: 64))
        // A move or resize under the threshold leaves the start crop (so a click moves nothing).
        let still = FFTRegionGeometry.proposed(.move, from: crop, press: press, location: CGPoint(x: 185.9, y: 144), in: source())
        XCTAssertEqual(still, crop, "1.9 pt would be a 1-pixel move")
        // On a 3000-px image 1.9 pt is 9.5 px: the threshold, not the rounding, is what stops it.
        let wide = FFTPaneGeometry.make(box: CGSize(width: 600, height: 400), width: 3000, height: 2000, zoom: 1, offset: .zero)
        let big = PixelCrop(row: 1000, col: 1000, height: 100, width: 100)
        XCTAssertEqual(FFTRegionGeometry.proposed(.move, from: big, press: CGPoint(x: 210, y: 210),
                                                  location: CGPoint(x: 211.9, y: 210), in: wide), big)
        XCTAssertEqual(FFTRegionGeometry.proposed(.move, from: big, press: CGPoint(x: 210, y: 210),
                                                  location: CGPoint(x: 212, y: 210), in: wide)?.col, 1010)
        XCTAssertNil(FFTRegionGeometry.proposed(.move, from: nil, press: press, location: CGPoint(x: 214, y: 126), in: source()),
                     "a move needs a crop to move")
    }

    /// A corner resizes about the OPPOSITE corner, by the drag from where the corner is — not to the pointer, which was
    /// pressed up to a disc's radius off it. Red under: the dragged corner pressed instead of the opposite one; the
    /// corner replaced by the pointer's position; the translation not divided by the points per pixel.
    func testACornerResizesAboutTheOppositeCornerByTheDrag() {
        // Bottom-right pressed 6 pt off its corner at (248, 208), dragged 40 pt right and down = 20 px each way.
        let br = FFTRegionGeometry.proposed(.resize(.bottomRight), from: crop, press: CGPoint(x: 254, y: 214),
                                            location: CGPoint(x: 294, y: 254), in: source())
        XCTAssertEqual(br, PixelCrop(row: 40, col: 60, height: 84, width: 84))
        // Top-left dragged (−20, −10) pt = (−10, −5) px: the bottom-right pixel edge (124, 104) stays, the side is the
        // larger extent, 74.
        let tl = FFTRegionGeometry.proposed(.resize(.topLeft), from: crop, press: CGPoint(x: 120, y: 80),
                                            location: CGPoint(x: 100, y: 70), in: source())
        XCTAssertEqual(tl, PixelCrop(row: 30, col: 50, height: 74, width: 74))
        // A wobble under 2 pt on a corner resizes nothing — on a 3000-px image 1.9 pt is 9.5 px, enough to grow the side.
        let far = FFTPaneGeometry.make(box: CGSize(width: 600, height: 400), width: 3000, height: 2000, zoom: 1, offset: .zero)
        let big = PixelCrop(row: 1000, col: 1000, height: 100, width: 100)   // (200, 200)…(220, 220)
        let corner = FFTRegionGeometry.corner(.bottomRight, of: big, in: far)
        let wobble = FFTRegionGeometry.proposed(.resize(.bottomRight), from: big, press: corner,
                                                location: CGPoint(x: corner.x + 1.9, y: corner.y), in: far)
        XCTAssertEqual(wobble, big)
        let grown = FFTRegionGeometry.proposed(.resize(.bottomRight), from: big, press: corner,
                                               location: CGPoint(x: corner.x + 2, y: corner.y), in: far)
        XCTAssertEqual(grown?.width, 110, "2 pt is 10 px: the side grows to 110")
    }

    /// A drag with no region draws R1's square from the press to the pointer, as image coordinates (off the image too:
    /// FFTRoomPaneTests' next test); under 2 points it makes nothing. Red under: the threshold removed; the press or the
    /// pointer held inside the image before the rule (zoom 0.5 shows the letterbox: 50, not 190); the pointer replaced by the
    /// press.
    func testADragWithNoRegionDrawsFromThePressAndAShortOneMakesNothing() {
        let g = source()
        // Press (100, 100) = pixel edge (50, 50); 30 px right, 15 px down: the larger extent 30 is raised to 32.
        let a = FFTRegionGeometry.proposed(.draw, from: nil, press: CGPoint(x: 100, y: 100), location: CGPoint(x: 160, y: 130), in: g)
        XCTAssertEqual(a, PixelCrop(row: 50, col: 50, height: 32, width: 32))
        // Up and to the left: the square extends toward the pointer from the press's pixel edge (200, 150).
        let b = FFTRegionGeometry.proposed(.draw, from: nil, press: CGPoint(x: 400, y: 300), location: CGPoint(x: 300, y: 200), in: g)
        XCTAssertEqual(b, PixelCrop(row: 100, col: 150, height: 50, width: 50))
        XCTAssertNil(FFTRegionGeometry.proposed(.draw, from: nil, press: CGPoint(x: 100, y: 100),
                                                location: CGPoint(x: 101, y: 101.5), in: g), "1.8 pt")
        XCTAssertNotNil(FFTRegionGeometry.proposed(.draw, from: nil, press: CGPoint(x: 100, y: 100),
                                                   location: CGPoint(x: 102, y: 100), in: g), "2 pt")
        // Zoomed out to 0.5 the image sits in the middle of the pane (1 pt per pixel, its centre at the pane's): a press in
        // the letterbox, pane (10, 10), is image (−140.5, −90.5), and the pointer at pane (200, 150) is (49.5, 49.5). R1 holds the
        // corner to the image — (0, 0) — and measures the side from the points as they are: 2⌊190/2⌋ = 190, not the 50 that
        // the pointer's distance from the image's own corner would give.
        let out = source(zoom: 0.5)
        let c = FFTRegionGeometry.proposed(.draw, from: nil, press: CGPoint(x: 10, y: 10), location: CGPoint(x: 200, y: 150), in: out)
        XCTAssertEqual(c, PixelCrop(row: 0, col: 0, height: 190, width: 190), "R1: the press is not held to the image first")
    }

    /// The pointer leaving the image does not stop the square: R1 measures from the pointer's image coordinates, off the
    /// image as well, and shifts the square in. On the 300 × 200 image (2 points per pixel) a press at pane (100, 100) is
    /// (49.5, 49.5), corner edge (50, 50); a pointer 40 px below the bottom edge, pane (300, 482) = (149.5, 240.5), gives
    /// 2⌊190/2⌋ = 190, shifted up to row 10; while the pointer moves down from the border the side keeps growing, 150, 160 … 190,
    /// where holding the pointer to the image stalled it at 150 (pane rows 402 … 482). Left and up, the same. Red under: the pointer (or the press)
    /// held to the image before R1's formula.
    func testADrawnSquareKeepsGrowingAfterThePointerLeavesTheImage() {
        let g = source()
        let press = CGPoint(x: 100, y: 100)
        // (Pointer rows chosen where the extent is odd, 151 … 191 px: away from the floor's tie, where float error decides.)
        for (y, side) in [(402.0, 150), (422.0, 160), (442.0, 170), (462.0, 180), (482.0, 190)] {
            let c = FFTRegionGeometry.proposed(.draw, from: nil, press: press, location: CGPoint(x: 300, y: y), in: g)
            XCTAssertEqual(c, PixelCrop(row: min(50, 200 - side), col: 50, height: side, width: side), "pointer at pane y = \(y)")
        }
        // Up and to the left, beyond the top-left corner: (−50.5, −30.5), extent 100 → 100, shifted to (0, 0).
        XCTAssertEqual(FFTRegionGeometry.proposed(.draw, from: nil, press: press, location: CGPoint(x: -100, y: -60), in: g),
                       PixelCrop(row: 0, col: 0, height: 100, width: 100))
        // A press beyond the image (zoom 0.5) with a pointer beyond it on the other side: the largest square.
        let out = source(zoom: 0.5)
        XCTAssertEqual(FFTRegionGeometry.proposed(.draw, from: nil, press: CGPoint(x: 5, y: 5), location: CGPoint(x: 700, y: 500), in: out),
                       PixelCrop(row: 0, col: 0, height: 200, width: 200), "S = 200, from the image's corner")
    }

    /// A resize past the border works the same way: the corner moves BY THE DRAG (the Image room's rule for a grabbed end,
    /// whatever the disc's offset from the corner), the target is not held to the image, and the square is drawn from the
    /// opposite corner and shifted in. The crop (row 40, col 200, 64 px) has its bottom-right corner at image (263.5, 103.5),
    /// pane (528, 208); dragged (+100 px, +10 px) = (+200 pt, +20 pt) it is at (363.5, 113.5): from the opposite corner
    /// (199.5, 39.5) the extent is 164, the square (row 40, col 200) 164 px across, shifted to (row 36, col 136). Pressed 6 pt off
    /// the corner the result is the same. Red under: the target held to the image (100 px across); the corner put at the
    /// pointer (the press's offset moves the crop).
    func testAResizeBeyondTheBorderIsDrawnFromTheOppositeCornerAndShiftedIn() {
        let g = source()
        let c = PixelCrop(row: 40, col: 200, height: 64, width: 64)
        let corner = FFTRegionGeometry.corner(.bottomRight, of: c, in: g)
        XCTAssertEqual(corner.x, 528, accuracy: 1e-9)
        XCTAssertEqual(corner.y, 208, accuracy: 1e-9)
        let expected = PixelCrop(row: 36, col: 136, height: 164, width: 164)
        XCTAssertEqual(FFTRegionGeometry.proposed(.resize(.bottomRight), from: c, press: corner,
                                                  location: CGPoint(x: corner.x + 200, y: corner.y + 20), in: g), expected)
        XCTAssertEqual(FFTRegionGeometry.proposed(.resize(.bottomRight), from: c, press: CGPoint(x: corner.x + 6, y: corner.y + 6),
                                                  location: CGPoint(x: corner.x + 206, y: corner.y + 26), in: g), expected,
                       "pressed 6 pt off the corner: the corner moved by the drag, not to the pointer")
        // Top-left past the top edge: the crop (row 150, col 100, 40 px) has its opposite corner at (139.5, 189.5) and its
        // top-left at pane (200, 300); dragged (−10 px, −200 px) it is at (89.5, −50.5), an extent of 240 → S = 200 (held to the
        // image first it would be 190).
        let low = PixelCrop(row: 150, col: 100, height: 40, width: 40)
        let tl = FFTRegionGeometry.corner(.topLeft, of: low, in: g)
        XCTAssertEqual(tl.x, 200, accuracy: 1e-9)
        XCTAssertEqual(tl.y, 300, accuracy: 1e-9)
        XCTAssertEqual(FFTRegionGeometry.proposed(.resize(.topLeft), from: low, press: tl, location: CGPoint(x: tl.x - 20, y: tl.y - 400), in: g),
                       PixelCrop(row: 0, col: 0, height: 200, width: 200))
    }

    /// The 2-pt threshold stops a CLICK from making a region, not a drag that has begun: until a draw has proposed once, a
    /// pointer within 2 pt of the press proposes nothing; after it, every sample proposes R1's square for its pointer, so a
    /// pointer brought back to the press gives the 32-px square (corner right and down for a zero extent), and one back on
    /// the other side of it the 32-px square toward that side. Driven through the pure drag state the overlay holds. Red
    /// under: the threshold applied on every sample (the 80-px square is kept, and committed, when the pointer comes back); the
    /// `hasProposed` flag not set by the first proposal.
    func testADrawReturnedToItsPressProposesTheMinimumSquare() {
        let g = source()
        let press = CGPoint(x: 100, y: 100)
        var drag = FFTRegionDrag(grab: .draw, start: nil)
        XCTAssertNil(drag.propose(press: press, location: CGPoint(x: 101, y: 100.5), in: g), "a click: nothing yet")
        XCTAssertFalse(drag.wrote)
        XCTAssertEqual(drag.propose(press: press, location: CGPoint(x: 260, y: 220), in: g),
                       PixelCrop(row: 50, col: 50, height: 80, width: 80))
        XCTAssertTrue(drag.wrote)
        XCTAssertEqual(drag.propose(press: press, location: CGPoint(x: 101, y: 100.5), in: g),
                       PixelCrop(row: 50, col: 50, height: 32, width: 32), "1.1 pt from the press, after drawing: R1's smallest")
        XCTAssertEqual(drag.propose(press: press, location: press, in: g), PixelCrop(row: 50, col: 50, height: 32, width: 32))
        XCTAssertEqual(drag.propose(press: press, location: CGPoint(x: 99, y: 99.5), in: g),
                       PixelCrop(row: 18, col: 18, height: 32, width: 32), "back on the other side: toward the pointer")
        // A move or resize under the threshold is still the start crop, and a drag that never left it wrote nothing.
        let c = crop
        var still = FFTRegionDrag(grab: .move, start: c)
        XCTAssertEqual(still.propose(press: CGPoint(x: 184, y: 144), location: CGPoint(x: 185, y: 144), in: g), c)
        XCTAssertFalse(still.wrote, "a click on the region commits nothing")
        XCTAssertEqual(still.propose(press: CGPoint(x: 184, y: 144), location: CGPoint(x: 214, y: 126), in: g),
                       PixelCrop(row: 31, col: 75, height: 64, width: 64))
        XCTAssertTrue(still.wrote)
        XCTAssertEqual(still.propose(press: CGPoint(x: 184, y: 144), location: CGPoint(x: 185, y: 144), in: g), c,
                       "a move brought back is the start crop, as before")
    }

    /// An arrow key nudges the crop one pixel (ten with ⇧) toward the arrow, held inside the image. Red under: up and
    /// down swapped; the step ignored; left and right swapped.
    func testAnArrowNudgesTheCropTowardTheArrow() {
        func nudge(_ c: PixelCrop, _ d: MoveCommandDirection, _ step: Int = 1) -> PixelCrop {
            FFTRegionGeometry.nudged(c, d, step: step, width: 300, height: 200)
        }
        XCTAssertEqual(nudge(crop, .right).col, 61)
        XCTAssertEqual(nudge(crop, .left).col, 59)
        XCTAssertEqual(nudge(crop, .up).row, 39)
        XCTAssertEqual(nudge(crop, .down).row, 41)
        XCTAssertEqual(nudge(crop, .down, 10).row, 50)
        XCTAssertEqual(nudge(crop, .left, 10).col, 50)
        XCTAssertEqual(nudge(PixelCrop(row: 0, col: 0, height: 64, width: 64), .left).col, 0, "held inside")
        XCTAssertEqual(nudge(crop, .up).width, 64, "the size is untouched")
    }

    // MARK: Which pixels the source pane draws, and how

    /// Original is the file as the Image room draws it (its colormap, window, gamma); every other view is its pixels
    /// LINEAR over their own range, gamma 1, in the file's colormap — so flipping between a region and a product is a
    /// blink comparison of like with like. The inverse has an accent border, the filters an orange one, and only
    /// Original carries the region's outline. A product that does not exist yet is not drawn. Red under: a product drawn
    /// with the file's window or gamma; ABSF and Wiener swapped; the filters' border the inverse's; the colormap not
    /// carried.
    @MainActor func testEachViewDrawsItsOwnPixelsLinearInTheFilesColormap() {
        let original = canvas(1)
        let key = FFTSpectrumKey(contentVersion: 9, crop: crop)
        let spectrum = FFTSpectrumProduct(key: key, width: 64, height: 64, spacingX: 0.1, spacingY: 0.1, unitsX: "1/nm",
                                          unitsY: "1/nm", canvas: canvas(2), defaultWindow: nil, profile: nil,
                                          region: canvas(3, 64))
        let spot = MaskedInverseFFT.Spot(kx: 5, ky: -3, radius: 3, edge: 2)
        let inverse = FFTMaskedInverseProduct(key: FFTMaskKey(spectrum: key, spots: [spot, spot, spot, spot]),
                                              canvas: canvas(4, 64), imaginaryMax: 0)
        let filtered = FFTFilterProduct(key: FFTFilterKey(spectrum: key, parameters: .defaults), absf: canvas(5, 64),
                                        wiener: canvas(6, 64), n: 64, passes: 3, finalDelta: 4.5)
        func layer(_ v: FFTAnalysis.SourceView, spectrum s: FFTSpectrumProduct? = nil, inverse i: FFTMaskedInverseProduct? = nil,
                   filtered f: FFTFilterProduct? = nil) -> FFTSourceLayer? {
            FFTSourceLayer.make(v, original: original, colormap: .viridis, window: (0.2, 0.8), gamma: 1.7, spectrum: s, inverse: i, filtered: f)
        }
        let o = layer(.original)
        XCTAssertEqual(o?.canvas, original)
        XCTAssertEqual(o?.colormap, .viridis)
        XCTAssertEqual(o?.window.low, 0.2)
        XCTAssertEqual(o?.window.high, 0.8)
        XCTAssertEqual(o?.gamma, 1.7)
        XCTAssertNil(o?.plate)
        XCTAssertEqual(o?.border, FFTSourceLayer.Border.plain)
        XCTAssertEqual(o?.drawsRegion, true)

        let r = layer(.region, spectrum: spectrum)
        XCTAssertEqual(r?.canvas, spectrum.region)
        XCTAssertEqual(r?.colormap, .viridis, "the file's colormap")
        XCTAssertEqual(r?.window.low, 0)
        XCTAssertEqual(r?.window.high, 1)
        XCTAssertEqual(r?.gamma, 1)
        XCTAssertEqual(r?.border, FFTSourceLayer.Border.plain)
        XCTAssertEqual(r?.drawsRegion, false)

        let m = layer(.maskedInverse, inverse: inverse)
        XCTAssertEqual(m?.canvas, inverse.canvas)
        XCTAssertEqual(m?.window.low, 0)
        XCTAssertEqual(m?.window.high, 1)
        XCTAssertEqual(m?.gamma, 1)
        XCTAssertEqual(m?.border, FFTSourceLayer.Border.accent)
        XCTAssertEqual(m?.drawsRegion, false)

        let a = layer(.absf, filtered: filtered), w = layer(.wiener, filtered: filtered)
        XCTAssertEqual(a?.canvas, filtered.absf)
        XCTAssertEqual(w?.canvas, filtered.wiener)
        XCTAssertEqual(a?.border, FFTSourceLayer.Border.orange)
        XCTAssertEqual(w?.border, FFTSourceLayer.Border.orange)
        XCTAssertEqual(a?.window.low, 0)
        XCTAssertEqual(w?.gamma, 1)
        XCTAssertEqual(a?.colormap, .viridis)

        XCTAssertNil(layer(.region), "no spectrum yet")
        XCTAssertNil(layer(.maskedInverse))
        XCTAssertNil(layer(.absf))
        XCTAssertNil(layer(.wiener))
    }

    // MARK: What the panes say

    /// The spectrum's header names WHAT IT IS OF, in column-then-row order for the corner and width-then-height for the
    /// size; the whole image has no corner. Red under: row and column swapped; the size given as height × width.
    func testTheHeaderNamesTheRegionOrTheWholeImage() {
        XCTAssertEqual(FFTPaneFormat.subject(crop: PixelCrop(row: 404, col: 812, height: 256, width: 256), width: 2048, height: 1024),
                       "region 256 × 256 px at (812, 404)")
        XCTAssertEqual(FFTPaneFormat.subject(crop: nil, width: 2048, height: 1024), "whole image 2048 × 1024 px")
        XCTAssertEqual(FFTPaneFormat.subject(crop: PixelCrop(row: 1, col: 2, height: 30, width: 50), width: 9, height: 9),
                       "region 50 × 30 px at (2, 1)", "width first")
        XCTAssertEqual(FFTPaneFormat.spokenSubject(crop: PixelCrop(row: 404, col: 812, height: 256, width: 256), width: 2048, height: 1024),
                       "Region 256 by 256 pixels at column 812, row 404")
        XCTAssertEqual(FFTPaneFormat.spokenSubject(crop: nil, width: 2048, height: 1024), "Whole image 2048 by 1024 pixels")
    }

    /// "Updating…" is shown only while a spectrum is on screen and the one asked for is another; with none on screen the
    /// pane says it is computing instead, and a picture older than a fifth of a second dims. Red under: the word shown
    /// with no spectrum; shown for a current one; the delay changed.
    func testUpdatingMeansASpectrumIsShownAndAnotherIsAskedFor() {
        XCTAssertEqual(FFTPaneFormat.updating, "Updating…")
        XCTAssertTrue(FFTPaneFormat.isUpdating(hasSpectrum: true, isCurrent: false))
        XCTAssertFalse(FFTPaneFormat.isUpdating(hasSpectrum: true, isCurrent: true))
        XCTAssertFalse(FFTPaneFormat.isUpdating(hasSpectrum: false, isCurrent: false))
        XCTAssertEqual(FFTPaneFormat.dimDelay, .milliseconds(200))
    }

    /// Each product's plate names the product and what it was computed from, in the design note's words. The filters'
    /// begin with the warning, every time. Red under: "Unvalidated" dropped from either filter's plate; a spot count not
    /// matching the product's key; the singular not used for one spot; the size of the filter taken from the region.
    @MainActor func testEachProductsPlateNamesItAndItsInputs() {
        let key = FFTSpectrumKey(contentVersion: 1, crop: crop)
        func spot(_ r: Double, _ e: Double) -> MaskedInverseFFT.Spot { MaskedInverseFFT.Spot(kx: 4, ky: 2, radius: r, edge: e) }
        XCTAssertEqual(FFTPaneFormat.maskedInversePlate(spots: 4, radius: 3, edge: 2, width: 256, height: 256, locale: en),
                       "Masked inverse · 4 spots and their Friedel partners · radius 3, edge 2 bins · 256 × 256 px")
        XCTAssertEqual(FFTPaneFormat.maskedInversePlate(spots: 1, radius: 3.5, edge: 0, width: 64, height: 64, locale: en),
                       "Masked inverse · 1 spot and its Friedel partner · radius 3.5, edge 0 bins · 64 × 64 px")
        XCTAssertEqual(FFTPaneFormat.filterPlate("ABSF", size: 512),
                       "Unvalidated · not compared with Digital Micrograph · ABSF · 512 × 512 px")
        XCTAssertEqual(FFTPaneFormat.filterPlate("Wiener", size: 512),
                       "Unvalidated · not compared with Digital Micrograph · Wiener · 512 × 512 px")
        XCTAssertEqual(FFTPaneFormat.regionPlate(crop: PixelCrop(row: 404, col: 812, height: 256, width: 256), width: 256, height: 256),
                       "Region · transformed pixels · 256 × 256 px at (812, 404)")
        XCTAssertEqual(FFTPaneFormat.regionPlate(crop: nil, width: 2048, height: 1024),
                       "Whole image · transformed pixels · 2048 × 1024 px")
        // The layer composes them from the products' own keys and canvases.
        let inverse = FFTMaskedInverseProduct(key: FFTMaskKey(spectrum: key, spots: [spot(2, 1), spot(2, 1), spot(2, 1)]),
                                              canvas: canvas(1, 64), imaginaryMax: 0)
        let filtered = FFTFilterProduct(key: FFTFilterKey(spectrum: key, parameters: .defaults), absf: canvas(2, 48),
                                        wiener: canvas(3, 48), n: 48, passes: 2, finalDelta: 5)
        let layerInverse = FFTSourceLayer.make(.maskedInverse, original: canvas(0), colormap: .gray, window: (0, 1), gamma: 1,
                                               spectrum: nil, inverse: inverse, filtered: nil)
        XCTAssertEqual(layerInverse?.plate?.hasPrefix("Masked inverse · 3 spots and their Friedel partners · radius 2, edge 1 bins"), true)
        let layerFilter = FFTSourceLayer.make(.wiener, original: canvas(0), colormap: .gray, window: (0, 1), gamma: 1,
                                              spectrum: nil, inverse: nil, filtered: filtered)
        XCTAssertEqual(layerFilter?.plate, "Unvalidated · not compared with Digital Micrograph · Wiener · 48 × 48 px")
        let layerAbsf = FFTSourceLayer.make(.absf, original: canvas(0), colormap: .gray, window: (0, 1), gamma: 1,
                                            spectrum: nil, inverse: nil, filtered: filtered)
        XCTAssertEqual(layerAbsf?.plate, "Unvalidated · not compared with Digital Micrograph · ABSF · 48 × 48 px")
    }

    /// The View menu names every view; one that cannot be chosen yet says why, BY CAUSE, in its own item: the Masked Inverse
    /// says "no spot" while nothing is measured and "none in mask" when measured spots exist but none is In Mask (the reason
    /// "measure a spot first" was false in the second case); the filters say "filter first". Red under: the filters available
    /// before a run; the inverse available with no spot in the mask; the region available with no transform; the two causes
    /// of the inverse swapped or merged; a reason missing from the title.
    @MainActor func testAViewThatDoesNotExistYetSaysWhyByItsCause() {
        func reason(_ v: FFTAnalysis.SourceView, spectrum: Bool = true, measured: Bool = false, mask: Bool = false,
                    filter: Bool = false) -> String? {
            FFTPaneFormat.unavailableReason(v, hasSpectrum: spectrum, hasMeasuredSpot: measured, hasMaskSpot: mask, hasFilterResult: filter)
        }
        XCTAssertNil(reason(.original, spectrum: false))
        XCTAssertNil(reason(.region))
        XCTAssertEqual(reason(.region, spectrum: false), "no transform yet")
        XCTAssertEqual(reason(.maskedInverse), "no spot", "nothing measured")
        XCTAssertEqual(reason(.maskedInverse, measured: true), "none in mask", "measured, but none is In Mask")
        XCTAssertNil(reason(.maskedInverse, measured: true, mask: true))
        XCTAssertNil(reason(.maskedInverse, mask: true), "a spot in the mask is a measured one")
        XCTAssertEqual(reason(.absf), "filter first")
        XCTAssertEqual(reason(.wiener), "filter first")
        XCTAssertNil(reason(.absf, filter: true))
        XCTAssertEqual(FFTPaneFormat.menuTitle(.absf, reason: "filter first", isSelected: false), "ABSF (filter first)")
        XCTAssertEqual(FFTPaneFormat.menuTitle(.wiener, reason: "filter first", isSelected: false), "Wiener (filter first)")
        XCTAssertEqual(FFTPaneFormat.menuTitle(.maskedInverse, reason: "no spot", isSelected: false), "Masked Inverse (no spot)")
        XCTAssertEqual(FFTPaneFormat.menuTitle(.maskedInverse, reason: "none in mask", isSelected: false), "Masked Inverse (none in mask)")
        XCTAssertEqual(FFTPaneFormat.menuTitle(.region, reason: "no transform yet", isSelected: false), "Region (no transform yet)")
        XCTAssertEqual(FFTPaneFormat.menuTitle(.absf, reason: nil, isSelected: false), "ABSF")
        XCTAssertEqual(FFTAnalysis.SourceView.allCases.map { FFTPaneFormat.title(of: $0) },
                       ["Original", "Region", "Masked Inverse", "ABSF", "Wiener"])
    }

    /// The View control is the one thing the narrowest header never gives up, so its FACE — the title of the view the pane
    /// shows — must fit with the file name truncating first. The reasons make the longest items wider than the header
    /// ("Masked Inverse (none in mask)" is 187 pt of text at the system font, "Masked Inverse (no spot)" 153 pt, against the
    /// 148 pt a face may take of the 164-pt header), so the view shown is its plain name — the pane says why in words under
    /// it — and the reasons stay on the other items of the open menu. The text is measured by NSString at the system font;
    /// a borderless menu button adds about 21 pt of chrome (67 pt measured for "Original", whose text is 46.8 pt), allowed 24
    /// here. Red under: the selected view carrying its reason (every reason title overflows); the face budget not the
    /// header's.
    @MainActor func testTheViewMenusFaceFitsTheNarrowestHeader() {
        XCTAssertEqual(FFTPaneFormat.maximumFaceWidth, Double(LayoutPolicy.imagePaneMinimum) - 2 * 8 - 2 * 8,
                       "the pane's minimum, less its padding and the header's gap and spacer")
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        func width(_ text: String) -> Double { Double((text as NSString).size(withAttributes: [.font: font]).width) }
        let chrome = 24.0
        var widest = 0.0
        for view in FFTAnalysis.SourceView.allCases {
            for reason in [nil, "no transform yet", "no spot", "none in mask", "filter first"] {
                let face = FFTPaneFormat.menuTitle(view, reason: reason, isSelected: true)
                XCTAssertEqual(face, FFTPaneFormat.title(of: view), "the view shown keeps its plain name")
                widest = max(widest, width(face))
                XCTAssertLessThanOrEqual(width(face) + chrome, FFTPaneFormat.maximumFaceWidth, face)
            }
        }
        XCTAssertGreaterThan(widest, 90, "the widest face is Masked Inverse, 94 pt of text")
        // The reasons are for the items that are not shown; the longest of them would not fit a face.
        XCTAssertGreaterThan(width("Masked Inverse (none in mask)") + chrome, FFTPaneFormat.maximumFaceWidth)
    }

    /// A missing product says what it is waiting for, a failure says why in the core's words; the Masked Inverse waits by the
    /// View menu's two causes — no spot measured, or measured spots none of them In Mask. Red under: a failure replaced by the
    /// waiting words; the two causes of the inverse swapped or merged.
    func testAMissingProductSaysWhatItIsWaitingFor() {
        func missing(_ view: FFTAnalysis.SourceView, working: Bool = false, failure: String? = nil, measured: Bool = false,
                     mask: Bool = false) -> (title: String, detail: String) {
            FFTPaneFormat.missing(view, isWorking: working, failure: failure, hasMeasuredSpot: measured, hasMaskSpot: mask)
        }
        XCTAssertEqual(missing(.absf, working: true).title, "Filtering…")
        XCTAssertEqual(missing(.wiener).title, "No filtered image yet")
        let failed = missing(.absf, failure: "the region is not square")
        XCTAssertEqual(failed.title, "No filtered image")
        XCTAssertEqual(failed.detail, "the region is not square")
        XCTAssertEqual(missing(.maskedInverse).title, "No masked inverse yet")
        XCTAssertEqual(missing(.maskedInverse).detail, "Click a spot in the transform, then keep it in the mask.", "nothing measured")
        XCTAssertEqual(missing(.maskedInverse, measured: true).title, "No masked inverse yet")
        XCTAssertEqual(missing(.maskedInverse, measured: true).detail, "Tick a spot's checkbox in the Spots section to put it in the mask.",
                       "measured, but none is In Mask")
        XCTAssertEqual(missing(.maskedInverse, measured: true, mask: true).title, "Computing the masked inverse…")
        XCTAssertEqual(missing(.maskedInverse, failure: "no power").title, "No masked inverse")
    }

    /// A refused spot is explained in the design note's words, and they are the inspector's own: the footer and the Spots
    /// section never disagree. Red under: a sentence of the pane's own in place of the inspector's.
    func testARefusedSpotIsExplainedInTheInspectorsWords() {
        XCTAssertEqual(FFTPaneFormat.refusal(.nearDC), "Not measured: the peak nearest the click is within 3 bins of the centre.")
        XCTAssertEqual(FFTPaneFormat.refusal(.nearEdge), "Not measured: the peak nearest the click is within 2 bins of the edge.")
        for failure in [SpotMeasurementError.mixedUnits("nm", "1/nm"), .outside(row: 1, col: 2), .fftSetup(width: 3, height: 3), .crop(crop), .nearDC] {
            XCTAssertEqual(FFTPaneFormat.refusal(failure), FFTRoomFormat.refusal(failure))
        }
    }

    // MARK: The transform's geometry

    private let w = 128, h = 96, dqx = 0.390625, dqy = 1 / 3.84   // 50 and 25 reciprocal units across: aspect 2

    private var key: FFTSpectrumKey { FFTSpectrumKey(contentVersion: 7, crop: nil) }

    /// A 128 × 96 spectrum with different spacings on its axes; the pixels are irrelevant to the geometry.
    @MainActor private func spectrum(unitsX: String = "1/nm", key: FFTSpectrumKey? = nil) -> FFTSpectrumProduct {
        FFTSpectrumProduct(key: key ?? self.key, width: w, height: h, spacingX: dqx, spacingY: dqy, unitsX: unitsX, unitsY: unitsX,
                           canvas: canvas(1, range: -8...0), defaultWindow: nil, profile: nil, region: canvas(2))
    }

    @MainActor private func place(zoom: CGFloat = 1, offset: CGSize = .zero) -> (box: CGSize, geometry: MarkGeometry) {
        FFTSpectrumLayout.place(spectrum(), in: CGSize(width: 700, height: 500), zoom: zoom, offset: offset)
    }

    /// The box draws a ring as a circle: its width over its height is (w·Δq_x) / (h·Δq_y), so a frequency covers the same
    /// number of points along either axis; and it is the largest such box in the pane. Red under: the aspect w : h (the
    /// points per unit frequency then differ by 1.5 between the axes); Δq_x and Δq_y swapped in the aspect.
    @MainActor func testTheBoxDrawsAFrequencyTheSameLengthOnBothAxes() {
        let (box, g) = place()
        XCTAssertEqual(box.width, 700, accuracy: 1e-9)
        XCTAssertEqual(box.height, 350, accuracy: 1e-9)
        let perUnitX = Double(g.pointsPerPixel) / dqx, perUnitY = Double(g.pointsPerPixelY) / dqy
        XCTAssertEqual(perUnitX, perUnitY, accuracy: 1e-9)
        XCTAssertEqual(perUnitX, 14, accuracy: 1e-9)
        // A tall pane limits the height instead.
        let tall = FFTSpectrumLayout.place(spectrum(), in: CGSize(width: 300, height: 500), zoom: 1, offset: .zero).box
        XCTAssertEqual(tall.width, 300, accuracy: 1e-9)
        XCTAssertEqual(tall.height, 150, accuracy: 1e-9)
    }

    /// A bin is drawn at its centre, the zero frequency (h/2, w/2) half a bin past the box's middle, and a point maps
    /// back to the same bin at zoom 1 and 3 — through the spectrum's own width and height. Red under: the spectrum's
    /// width and height swapped in the map; row and column swapped in the bin; the zoom left out of the map.
    @MainActor func testABinIsDrawnAtItsCentreAndAClickReturnsIt() {
        let (_, g1) = place()
        // Column 64 of 128 at 700/128 pt per bin: (64 + ½)·5.46875 = 352.734375; row 48 of 96 at 350/96 pt: (48 + ½)·3.6458333.
        let dc = g1.panePoint(of: ImagePoint(x: 64, y: 48))
        XCTAssertEqual(dc.x, 352.734375, accuracy: 1e-9)
        XCTAssertEqual(dc.y, 48.5 * 350.0 / 96.0, accuracy: 1e-9)
        let (_, g3) = place(zoom: 3, offset: CGSize(width: 10, height: -20))
        // (64.5/128·700 − 350)·3 + 10 + 350 = 368.203125
        XCTAssertEqual(g3.panePoint(of: ImagePoint(x: 64, y: 48)).x, 368.203125, accuracy: 1e-9)
        for g in [g1, g3] {
            for (r, c) in [(0, 0), (48, 64), (47, 100), (95, 127), (10, 3)] {
                let bin = FFTSpotMarkers.clickedBin(at: g.panePoint(of: ImagePoint(x: Double(c), y: Double(r))),
                                                    width: w, height: h, in: g)
                XCTAssertEqual(bin.row, r)
                XCTAssertEqual(bin.col, c)
            }
        }
        XCTAssertEqual(g1.imageWidth, w)
        XCTAssertEqual(g1.imageHeight, h)
    }

    /// The reciprocal scale bar's units per point are Δq_x·w / boxWidth / zoom — so ten bins drawn apart are ten spacings
    /// of the bar's own unit, at any zoom, and the unit's factor is applied once and named. Red under: Δq_y for the bar;
    /// the box's height for its width; the zoom left out; the unit factor dropped; the label not the unit's.
    @MainActor func testTheBarMeasuresWhatTheBinsAreDrawnAt() {
        let p = spectrum(unitsX: "1/m")
        let unit = FFTUnits.spectrumUnit("1/m")
        XCTAssertNotEqual(unit.factor, 1, "a unit the bar must convert")
        for zoom in [CGFloat(1), 3] {
            let (box, g) = FFTSpectrumLayout.place(p, in: CGSize(width: 700, height: 500), zoom: zoom, offset: .zero)
            let bar = FFTSpectrumLayout.bar(for: p, box: box, zoom: zoom)
            let ten = g.panePoint(of: ImagePoint(x: 74, y: 48)).x - g.panePoint(of: ImagePoint(x: 64, y: 48)).x
            XCTAssertEqual(bar.unitsPerPoint * Double(ten), 10 * dqx * unit.factor, accuracy: 1e-9 * abs(unit.factor), "zoom \(zoom)")
            XCTAssertEqual(bar.label, unit.label)
        }
        let (box, _) = place()
        XCTAssertEqual(FFTSpectrumLayout.bar(for: spectrum(), box: box, zoom: 1).unitsPerPoint, 50.0 / 700.0, accuracy: 1e-12)
    }

    /// The display window is the owner's where it has one and the product's default otherwise, as fractions of the
    /// canvas's range; with neither the full range. Red under: the owner's edge ignored; low and high swapped.
    @MainActor func testTheWindowIsTheOwnersEdgeElseTheDefault() {
        let spectrum = FFTSpectrumProduct(key: FFTSpectrumKey(contentVersion: 1, crop: nil), width: 4, height: 4, spacingX: 1, spacingY: 1,
                                          unitsX: "1/px", unitsY: "1/px", canvas: canvas(1, range: -8...0),
                                          defaultWindow: SpectrumDisplay.Window(low: -6, high: -2), profile: nil, region: canvas(2))
        let d = FFTSpectrumLayout.window(low: nil, high: nil, spectrum: spectrum)
        XCTAssertEqual(d.low, 0.25)
        XCTAssertEqual(d.high, 0.75)
        let lowOnly = FFTSpectrumLayout.window(low: -7, high: nil, spectrum: spectrum)
        XCTAssertEqual(lowOnly.low, 0.125)
        XCTAssertEqual(lowOnly.high, 0.75)
        let highOnly = FFTSpectrumLayout.window(low: nil, high: -1, spectrum: spectrum)
        XCTAssertEqual(highOnly.low, 0.25)
        XCTAssertEqual(highOnly.high, 0.875)
        let bare = FFTSpectrumProduct(key: spectrum.key, width: 4, height: 4, spacingX: 1, spacingY: 1, unitsX: "1/px", unitsY: "1/px",
                                      canvas: canvas(3, range: -8...0), defaultWindow: nil, profile: nil, region: canvas(4))
        let full = FFTSpectrumLayout.window(low: nil, high: nil, spectrum: bare)
        XCTAssertEqual(full.low, 0)
        XCTAssertEqual(full.high, 1)
    }

    // MARK: Spots and the mask on the transform

    /// A planted lattice on a non-square spectrum, measured by the core: one real `SpotMeasurement` to place.
    private func measuredSpot() throws -> SpotMeasurement {
        let pixels = (0..<(w * h)).map { i -> Float in
            let c = Double(i % w), r = Double(i / w)
            return Float(100 + 10 * cos(2 * .pi * (17.3 * c / Double(w) - 9.45 * r / Double(h))))
        }
        let image = CalibratedImage(width: w, height: h, pixels: pixels, x: AxisCalibration(scale: 0.02, unit: "nm", origin: 0),
                                    y: AxisCalibration(scale: 0.04, unit: "nm", origin: 0), fileName: "lattice", source: "", voltage: nil)
        return try SpotMeasurement.measure(image.micrograph, clickRow: h / 2 - 9, clickColumn: w / 2 + 17)
    }

    /// A measured spot is marked at its CENTROID, a refused or pending one at the bin that was clicked; a spot of another
    /// spectrum is not marked at all (its bin belongs to a transform no longer shown). Red under: the clicked bin used for
    /// a measured spot; a stale spot drawn; the selection lost.
    @MainActor func testASpotIsMarkedWhereItWasMeasuredOrClickedOnItsOwnSpectrum() throws {
        let m = try measuredSpot()
        let spots = [
            FFTSpot(number: 1, row: 39, col: 81, spectrumKey: key, outcome: .measured(m)),
            FFTSpot(number: 2, row: 48, col: 66, spectrumKey: key, outcome: .refused(.nearDC)),
            FFTSpot(number: 3, row: 20, col: 20, spectrumKey: key, outcome: .measuring),
            FFTSpot(number: 4, row: 30, col: 30, spectrumKey: FFTSpectrumKey(contentVersion: 8, crop: nil), outcome: .measured(m)),
            FFTSpot(number: 5, row: 60, col: 70, spectrumKey: key, outcome: .refused(.noPower)),
        ]
        let (_, g) = place(zoom: 3)
        let markers = FFTSpotMarkers.markers(spots, spectrum: key, selection: spots[1].id, in: g)
        XCTAssertEqual(markers.map(\.number), [1, 2, 3, 5])
        assertEqual(markers[3].point, g.panePoint(of: ImagePoint(x: 70, y: 60)), "a peakless spot is marked at the bin clicked")
        XCTAssertFalse(markers[3].isMeasured, "dashed, like a refusal")
        assertEqual(markers[0].point, g.panePoint(of: ImagePoint(x: m.centroidCol, y: m.centroidRow)))
        XCTAssertNotEqual(markers[0].point, g.panePoint(of: ImagePoint(x: 81, y: 39)), "not the clicked bin")
        assertEqual(markers[1].point, g.panePoint(of: ImagePoint(x: 66, y: 48)))
        assertEqual(markers[2].point, g.panePoint(of: ImagePoint(x: 20, y: 20)))
        XCTAssertEqual(markers.map(\.isMeasured), [true, false, false, false])
        XCTAssertEqual(markers.map(\.isSelected), [false, true, false, false])
    }

    /// A click within 6 points of a marker selects it (the nearest, if two are in reach); anywhere else it measures the
    /// bin under the pointer. Red under: a radius of 12; the first marker in reach instead of the nearest; the click
    /// always measuring; row and column swapped in the bin; a spot of another spectrum selectable.
    @MainActor func testAClickSelectsAMarkerInReachElseMeasuresTheBin() throws {
        let m = try measuredSpot()
        // Two markers about 4 pt apart: the first measured, the second a refusal at the next bin right.
        let spots = [FFTSpot(number: 1, row: 39, col: 81, spectrumKey: key, outcome: .measured(m)),
                     FFTSpot(number: 2, row: 39, col: 82, spectrumKey: key, outcome: .refused(.nearDC))]
        let (_, g) = place()
        let p = spectrum()
        let markers = FFTSpotMarkers.markers(spots, spectrum: key, selection: nil, in: g)
        let first = markers[0].point, second = markers[1].point
        XCTAssertLessThan(hypot(second.x - first.x, second.y - first.y), 6, "both in reach of a click between them")
        XCTAssertEqual(FFTSpotMarkers.hitRadius, 6)
        func click(_ at: CGPoint, _ among: [FFTSpot] = spots) -> FFTSpotMarkers.Click {
            FFTSpotMarkers.click(at: at, spots: among, selection: nil, spectrum: p, in: g)
        }
        // 5 pt left of the first marker, and 9 pt from the second: only the first is in reach.
        XCTAssertEqual(click(CGPoint(x: first.x - 5, y: first.y)), .select(spots[0].id))
        // Over the second marker: both in reach, the second nearer.
        XCTAssertEqual(click(second), .select(spots[1].id))
        XCTAssertEqual(click(CGPoint(x: second.x + 1, y: second.y)), .select(spots[1].id))
        // 6.5 pt right of the second marker (and 10 from the first): out of reach, so a measurement at that bin.
        let out = CGPoint(x: second.x + 6.5, y: second.y)
        let bin = FFTSpotMarkers.clickedBin(at: out, width: w, height: h, in: g)
        XCTAssertEqual(click(out), .measure(row: bin.row, col: bin.col))
        // Row and column: a pointer over bin (row 10, column 100) names row 10, column 100.
        XCTAssertEqual(click(g.panePoint(of: ImagePoint(x: 100, y: 10)), []), .measure(row: 10, col: 100))
        // A spot of another spectrum has no marker to select.
        let stale = [FFTSpot(number: 1, row: 39, col: 81, spectrumKey: FFTSpectrumKey(contentVersion: 8, crop: nil), outcome: .measured(m))]
        if case .measure = click(first, stale) {} else { XCTFail("a stale spot is not selectable") }
    }

    /// With the masked inverse shown, each spot IN the mask is circled at its centroid and its Friedel partner mirrored
    /// through the zero frequency, the radius converted to points on each axis separately (an ellipse on this box); a
    /// refused spot, one left out of the mask and one of another spectrum are not circled. Red under: the same radius on
    /// both axes; the partner at the spot's own place; an out-of-mask spot or a stale one circled; the radius in pixels as
    /// points.
    @MainActor func testTheMaskCirclesAreTheInMaskSpotsAndTheirPartnersInBins() throws {
        let m = try measuredSpot()
        let inMask = FFTSpot(number: 1, row: 39, col: 81, spectrumKey: key, outcome: .measured(m), inMask: true)
        let out = FFTSpot(number: 2, row: 39, col: 81, spectrumKey: key, outcome: .measured(m), inMask: false)
        let refused = FFTSpot(number: 3, row: 48, col: 66, spectrumKey: key, outcome: .refused(.nearDC), inMask: true)
        let stale = FFTSpot(number: 4, row: 39, col: 81, spectrumKey: FFTSpectrumKey(contentVersion: 8, crop: nil),
                            outcome: .measured(m), inMask: true)
        let peakless = FFTSpot(number: 5, row: 48, col: 66, spectrumKey: key, outcome: .refused(.noPower), inMask: true)
        for zoom in [CGFloat(1), 3] {
            let (_, g) = place(zoom: zoom)
            let circles = FFTSpotMarkers.maskCircles([inMask, out, refused, stale, peakless], spectrum: spectrum(), radius: 3, edge: 2, in: g)
            XCTAssertEqual(circles.count, 2, "one spot and its partner")
            XCTAssertEqual(circles.map(\.isPartner), [false, true])
            // 5.46875 pt per bin along x and 3.6458333 along y at zoom 1: an ellipse 3 bins in radius.
            for c in circles {
                XCTAssertEqual(c.radii.width, 3 * 5.46875 * zoom, accuracy: 1e-9)
                XCTAssertEqual(c.radii.height, 3 * (350.0 / 96.0) * zoom, accuracy: 1e-9)
            }
            let own = g.panePoint(of: ImagePoint(x: m.centroidCol, y: m.centroidRow))
            let partner = g.panePoint(of: ImagePoint(x: Double(2 * (w / 2)) - m.centroidCol, y: Double(2 * (h / 2)) - m.centroidRow))
            assertEqual(circles[0].centre, own)
            assertEqual(circles[1].centre, partner)
        }
    }

    // MARK: A spot as text

    /// A spot copied is its number, the inspector row's own text (d and |q| in the unit the transform shows them in) and,
    /// when measured, what was transformed. Red under: the subject omitted; the number omitted.
    func testACopiedSpotNamesItsNumbersAndWhatWasTransformed() throws {
        let m = try measuredSpot()
        let spot = FFTSpot(number: 2, row: 39, col: 81, spectrumKey: key, outcome: .measured(m))
        let d = FFTUnits.length(m.d, unit: m.units), q = FFTUnits.reciprocal(m.q, realUnit: m.units)
        let line = FFTPaneFormat.copyLine(spot, subject: "whole image 128 × 96 px", locale: en)
        let dText = UnitDisplay.number(d.value, digits: 4, locale: en)
        let qText = UnitDisplay.number(q.value, digits: 4, locale: en)
        XCTAssertEqual(line, "Spot 2 · d \(dText) \(d.label) · |q| \(qText) \(q.label) · whole image 128 × 96 px")
        let refused = FFTSpot(number: 3, row: 48, col: 66, spectrumKey: key, outcome: .refused(.nearDC))
        XCTAssertEqual(FFTPaneFormat.copyLine(refused, subject: "whole image 128 × 96 px", locale: en),
                       "Spot 3 · Not measured: the peak nearest the click is within 3 bins of the centre.")
        XCTAssertEqual(FFTPaneFormat.copyLine(FFTSpot(number: 4, row: 1, col: 1, spectrumKey: key), subject: "x", locale: en),
                       "Spot 4 · Measuring…")
        let none = FFTSpot(number: 5, row: 48, col: 66, spectrumKey: key, outcome: .refused(.noPower))
        XCTAssertEqual(FFTPaneFormat.copyLine(none, subject: "whole image 128 × 96 px", locale: en),
                       "Spot 5 · Not measured: there is no power in the window once its mean is removed (a constant image or region).")
    }

    // MARK: A marker's number

    /// A marker's number is drawn inside the pane for every ring that is on it: above and to the right of the ring where
    /// there is room (where it always was), flipped below it near the top edge, to its left near the right edge, both at
    /// the corner, and held inside the pane when the pane is too small for either side; a ring wholly off the pane has no
    /// number to place. The plate is the text plus 6 × 2 pt; the text here is the 7 × 13 pt of a bold caption digit. At the
    /// top, the old rule dropped the number of a ring within 21 pt of the edge (the finding's bare ring 6.5 pt below it).
    /// Red under: the flip dropped (the number off the pane, or not drawn); the flip without the pull-in; the ring's reach
    /// (7 pt) taken as 0; the box origin as before.
    func testAMarkersNumberIsPlacedInsideThePaneWheneverItsRingIsOnIt() {
        let pane = CGSize(width: 453, height: 453)
        let text = CGSize(width: 7, height: 13)
        func box(_ x: CGFloat, _ y: CGFloat, in size: CGSize? = nil, text t: CGSize? = nil) -> CGRect? {
            FFTSpotMarkers.labelBox(at: CGPoint(x: x, y: y), textSize: t ?? text, in: size ?? pane)
        }
        XCTAssertEqual(box(200, 200), CGRect(x: 208, y: 179, width: 13, height: 15), "room: above and to the right, as before")
        XCTAssertEqual(box(5.5, 6.5), CGRect(x: 13.5, y: 14.5, width: 13, height: 15), "the finding's ring, 6.5 pt below the top")
        XCTAssertEqual(box(100, 21)?.minY, 0, "21 pt: just room above")
        XCTAssertEqual(box(100, 20.9)?.minY ?? 0, 28.9, accuracy: 1e-9, "20.9 pt: below")
        XCTAssertEqual(box(447, 200), CGRect(x: 426, y: 179, width: 13, height: 15), "the right edge: to the left of the ring")
        XCTAssertEqual(box(431, 300)?.minX, 439, "452 ≤ 453: still on the right")
        XCTAssertEqual(box(440, 300)?.minX, 419, "461 > 453: on the left")
        XCTAssertEqual(box(450, 3), CGRect(x: 429, y: 11, width: 13, height: 15), "the top-right corner: below and to the left")
        XCTAssertEqual(box(2, 450), CGRect(x: 10, y: 429, width: 13, height: 15), "bottom and left edges have room")
        XCTAssertEqual(box(-5, -5), CGRect(x: 3, y: 3, width: 13, height: 15), "a ring half off the corner is on the pane")
        // A ring wholly off the pane has no number; one touching it by its reach does.
        XCTAssertNil(box(-7.5, 200))
        XCTAssertNil(box(460.5, 200))
        XCTAssertNil(box(200, -7.5))
        XCTAssertNil(box(200, 460.5))
        XCTAssertNotNil(box(-6.5, 200))
        XCTAssertNotNil(box(459.5, 200))
        XCTAssertNil(box(.nan, 200))
        // A pane smaller than the plate beside the ring: pulled in.
        let tiny = CGSize(width: 20, height: 16)
        XCTAssertEqual(box(10, 8, in: tiny), CGRect(x: 0, y: 1, width: 13, height: 15), "held inside the pane")
        // Everywhere the ring is on the pane, the plate is inside it.
        var placed = 0
        for x in stride(from: CGFloat(-7), through: 460, by: 3.7) {
            for y in stride(from: CGFloat(-7), through: 460, by: 3.7) {
                guard let b = box(x, y) else { continue }
                placed += 1
                XCTAssertGreaterThanOrEqual(b.minX, 0, "(\(x), \(y))")
                XCTAssertGreaterThanOrEqual(b.minY, 0, "(\(x), \(y))")
                XCTAssertLessThanOrEqual(b.maxX, pane.width, "(\(x), \(y))")
                XCTAssertLessThanOrEqual(b.maxY, pane.height, "(\(x), \(y))")
            }
        }
        XCTAssertGreaterThan(placed, 10_000)
    }

    // MARK: A double-click on the transform

    /// A double-click on the transform measures once. Its first click names a bin and measures it; its second either lands
    /// within the marker's 6 pt and selects that spot, or — zoomed in, where the centroid is farther than that from the
    /// pointer — names the same bin, which the owner selects instead of measuring again. The pane's own `click(at:)` is
    /// applied here through the same `FFTSpotMarkers.click`. The owner's spot answers are immediate or held until the test
    /// lets them go; it reaches `FFTAnalysis` as the pane does. Red under: `measureSpot` without its duplicate check (two
    /// spots at zoom 8); a click that selects nothing when a marker is in reach.
    @MainActor func testADoubleClickMeasuresOnceAndItsSecondClickSelectsThatSpot() async throws {
        let m = try measuredSpot()
        let product = spectrum()
        let image = CalibratedImage(width: 4, height: 4, pixels: [Float](repeating: 1, count: 16), x: nil, y: nil,
                                    fileName: "x", source: "", voltage: nil)
        func makeOwner() async throws -> FFTAnalysis {
            let analysis = FFTAnalysis(compute: FFTCompute(
                spectrum: { _, _ in product },
                spot: { _, _, _, _ in .measured(m) },
                maskedInverse: { _, _ in throw CancellationError() },
                filter: { _, _ in throw CancellationError() }))
            analysis.show(image, contentVersion: key.contentVersion)
            for _ in 0..<1000 where !analysis.isSpectrumCurrent { try await Task.sleep(for: .milliseconds(5)) }
            XCTAssertTrue(analysis.isSpectrumCurrent, "the spectrum landed")
            return analysis
        }
        func click(_ owner: FFTAnalysis, at p: CGPoint, in g: MarkGeometry) -> FFTSpotMarkers.Click {
            let what = FFTSpotMarkers.click(at: p, spots: owner.spots, selection: owner.selection, spectrum: product, in: g)
            switch what {
            case .select(let id): owner.selection = id
            case .measure(let row, let col): owner.measureSpot(row: row, col: col)
            }
            return what
        }
        for zoom in [CGFloat(1), 8] {
            let (_, g) = place(zoom: zoom)
            let at = g.panePoint(of: ImagePoint(x: 81, y: 39))        // the bin the planted peak's click names
            // (a) the second click comes while the first spot is still measuring: the marker is at the bin clicked
            let early = try await makeOwner()
            guard case .measure(39, 81) = click(early, at: at, in: g) else { return XCTFail("the first click measures bin (39, 81)") }
            XCTAssertEqual(early.spots.count, 1)
            guard case .select(let id) = click(early, at: at, in: g) else { return XCTFail("the second click selects the spot just made") }
            XCTAssertEqual(early.spots.count, 1, "zoom \(zoom): one spot")
            XCTAssertEqual(early.selection, id)
            XCTAssertEqual(early.spots[0].id, id)
            // (b) the second click comes after the answer: the marker is at the centroid
            let late = try await makeOwner()
            _ = click(late, at: at, in: g)
            for _ in 0..<1000 where late.spots.first?.measured == nil { try await Task.sleep(for: .milliseconds(5)) }
            XCTAssertNotNil(late.spots.first?.measured, "the spot landed")
            let second = click(late, at: at, in: g)
            XCTAssertEqual(late.spots.count, 1, "zoom \(zoom): the second click made no second spot")
            XCTAssertEqual(late.selection, late.spots[0].id)
            if zoom == 8 {
                guard case .measure(39, 81) = second else { return XCTFail("zoomed in, the centroid is out of reach: the same bin again, \(second)") }
            }
        }
    }

    // MARK: The transform's scale bar and the fields, in words

    /// The transform's scale bar is spoken as the number it prints and its unit in words — "per nanometre", "per pixel" —
    /// where the shared bar would say "px⁻¹" raw; any other unit as the shared bar says it ("1 nanometre"). Nothing is
    /// spoken for a bar that is not drawn. The 70 pt the bar aims at is `ScaleBar.targetPoints` (ShellControls), held to the layout's. Red under: the unit left as printed; the singular lost for nm; the aim changed in one file.
    @MainActor func testTheTransformsScaleBarSpeaksItsUnitInWords() throws {
        func spoken(_ perPoint: Double, _ label: String) -> String? { FFTSpectrumLayout.spokenBar(unitsPerPoint: perPoint, label: label, locale: en) }
        XCTAssertEqual(spoken(0.0125, "px\u{207B}\u{00B9}"), "Scale bar, 1 per pixel", "0.875 → the 1-2-5 value 1")
        XCTAssertEqual(spoken(0.00286, "px\u{207B}\u{00B9}"), "Scale bar, 0.2 per pixel", "0.2002 → 0.2")
        XCTAssertEqual(spoken(0.29, "nm\u{207B}\u{00B9}"), "Scale bar, 20 per nanometre", "20.3 → 20")
        XCTAssertEqual(spoken(0.0143, "nm\u{207B}\u{00B9}"), "Scale bar, 1 per nanometre")
        XCTAssertEqual(spoken(0.0143, "nm"), "Scale bar, 1 nanometre", "a diffraction image's spectrum: the shared bar's own words")
        XCTAssertEqual(spoken(0.7, "nm"), "Scale bar, 50 nanometres")
        XCTAssertEqual(spoken(0.7, "1/rad"), "Scale bar, 50 1/rad", "an unknown unit as written")
        XCTAssertNil(spoken(0, "nm\u{207B}\u{00B9}"))
        XCTAssertNil(spoken(.nan, "nm\u{207B}\u{00B9}"))
        XCTAssertNil(spoken(.infinity, "px\u{207B}\u{00B9}"))
        // The number is the bar's: ScaleBar prints nice125(unitsPerPoint × its 70 pt), and says the same.
        for perPoint in [0.0125, 0.00286, 0.29, 0.0143] {
            let printed = ScaleBar.format(ScaleBarMath.nice125(perPoint * 70), locale: en)
            XCTAssertTrue(spoken(perPoint, "nm\u{207B}\u{00B9}")?.contains(" \(printed) ") ?? false, "\(perPoint): \(printed)")
        }
        XCTAssertEqual(ScaleBar.targetPoints, FFTSpectrumLayout.barTargetPoints,
                       "ScaleBar's target length is no longer \(FFTSpectrumLayout.barTargetPoints) pt: the spoken bar must follow")
    }

    /// The Region fields speak "Left in pixels", "Top in pixels", "Size in pixels" — the unit named once — where the kit's
    /// speech would add the unit to the bare title as "Left, px" (read letter by letter). The row still shows Left, Top,
    /// Size. Red under: a spoken title that drops the unit or names another field. (The row passing `spokenTitle` to its
    /// field is held by `FFTRoomWiringTests`.)
    @MainActor func testTheRegionFieldsSpeakTheirUnitInWords() {
        for field in FFTRoomFormat.RegionField.allCases {
            XCTAssertEqual(NumericFieldSpeech.label(field.spokenTitle, unit: "px"), field.spokenTitle, "the unit is named once")
            XCTAssertTrue(field.spokenTitle.hasSuffix(" in pixels"))
            XCTAssertTrue(field.spokenTitle.hasPrefix(field.title), "the same field as the row's")
            XCTAssertEqual(NumericFieldSpeech.label(field.title, unit: "px"), "\(field.title), px", "what the bare title would say")
        }
    }

    // MARK: The box with two units

    /// The transform's box is square for the finding's image — x in nm, y in Å: the same physical pixel — where the raw
    /// numbers drew a 10 : 1 strip; and the box of the image with one unit is unchanged. Red under: the units not passed
    /// to the aspect.
    @MainActor func testTheBoxOfAnImageWithTwoLengthUnitsIsSquare() {
        let mixed = FFTSpectrumProduct(key: key, width: 128, height: 128, spacingX: 0.15625, spacingY: 0.015625, unitsX: "1/nm",
                                       unitsY: "1/\u{00C5}", canvas: canvas(1, range: -8...0), defaultWindow: nil, profile: nil,
                                       region: canvas(2))
        let (box, _) = FFTSpectrumLayout.place(mixed, in: CGSize(width: 600, height: 400), zoom: 1, offset: .zero)
        XCTAssertEqual(box.width, 400, accuracy: 1e-9)
        XCTAssertEqual(box.height, 400, accuracy: 1e-9)
        let uncomparable = FFTSpectrumProduct(key: key, width: 128, height: 128, spacingX: 0.15625, spacingY: 0.015625, unitsX: "1/nm",
                                              unitsY: "1/px", canvas: canvas(1, range: -8...0), defaultWindow: nil, profile: nil,
                                              region: canvas(2))
        XCTAssertEqual(FFTSpectrumLayout.place(uncomparable, in: CGSize(width: 600, height: 400), zoom: 1, offset: .zero).box,
                       CGSize(width: 400, height: 400), "units that do not compare: drawn square")
        XCTAssertEqual(place().box.width / place().box.height, 2, accuracy: 1e-9, "one unit: the old aspect")
    }

    /// With the transform's centre given, a number goes outward along the ray through its ring, and two rings side by side get plates that do
    /// not overlap. Red under: the plate above-right whatever the ray (it printed over its neighbour); a plate dropped or overlapping.
    func testNumbersFanOutwardFromTheCentreAndDoNotOverlap() throws {
        let pane = CGSize(width: 400, height: 400), centre = CGPoint(x: 200, y: 200), text = CGSize(width: 8, height: 12)
        let left = try XCTUnwrap(FFTSpotMarkers.labelBox(at: CGPoint(x: 150, y: 200), textSize: text, in: pane, awayFrom: centre))
        XCTAssertLessThan(left.maxX, 150, "a ring left of the centre is numbered to its left")
        let below = try XCTUnwrap(FFTSpotMarkers.labelBox(at: CGPoint(x: 200, y: 260), textSize: text, in: pane, awayFrom: centre))
        XCTAssertGreaterThan(below.minY, 260, "a ring below the centre is numbered below it")
        let first = try XCTUnwrap(FFTSpotMarkers.labelBox(at: CGPoint(x: 230, y: 160), textSize: text, in: pane, awayFrom: centre))
        let second = try XCTUnwrap(FFTSpotMarkers.labelBox(at: CGPoint(x: 232, y: 161), textSize: text, in: pane, awayFrom: centre, avoiding: [first]))
        XCTAssertFalse(first.intersects(second), "the second plate moved out of the first's way")
        XCTAssertTrue(CGRect(origin: .zero, size: pane).contains(second))
    }
}
