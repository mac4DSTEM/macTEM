//
//  SEMMapPointerTests.swift
//  Who owns a plain press on an SEM map, and which scan point a pane point picks (`SEMMapPointer`, UI/SEMMapPick.swift, D-SEM-110), as
//  mac4DSTEM's `RealSpacePointerPolicyTests` pin its policy: the scrub at 1× and below, pan and grab above; a pixel owns the area it
//  covers at any zoom and pan; a point past the edge holds the edge's pixel; zoomed out, a press beside the picture is not on it.
//  Red before D-SEM-110: `SEMMapPointer` did not exist (the pointer moved the pattern, and a tap pinned at any zoom).
//

import ShellMetal
import XCTest
import TEMCore
@testable import macTEM

nonisolated final class SEMMapPointerTests: XCTestCase {

    /// A 40 × 30 scan in a 400 × 300 box: 10 points per pixel at 1×.
    private func geometry(zoom: CGFloat = 1, offset: CGSize = .zero) -> MarkGeometry {
        let box = CGSize(width: 400, height: 300)
        return MarkGeometry(transform: MetalDisplayTransform(paneSize: box, imageBox: box, zoom: zoom, offset: offset),
                            imageWidth: 40, imageHeight: 30)
    }

    /// At 1× a click scrubs, and zooming out keeps it (there is nothing to pan to); the float error a pinch leaves on its way back to 1×
    /// still scrubs; zoomed in, a plain drag pans and the marker's handle picks. Red under: the threshold at 1 exactly (1 + 1e-5 would
    /// pan), the modes swapped.
    func testOneAndBelowScrubAndAboveItPansAndGrabs() {
        for zoom in [1, 1 + 1e-5, 0.999, 0.5, 0.25] as [CGFloat] {
            XCTAssertEqual(SEMMapPointer.mode(zoom: zoom), .scrub, "zoom \(zoom)")
        }
        for zoom in [1.01, 1.05, 2, 8, 64] as [CGFloat] {
            XCTAssertEqual(SEMMapPointer.mode(zoom: zoom), .panAndGrab, "zoom \(zoom)")
        }
    }

    /// A pixel's centre, and any point within 0.49 px of it, picks that pixel; 0.51 px past it the next one, at 1× and at 3× panned.
    /// Red under: floor for round (the upper-left half of every pixel goes to the one before), x and y swapped, the zoom or the pan left
    /// out of the map.
    func testAPixelOwnsTheAreaItCoversAtAnyZoomAndPan() {
        for (zoom, offset) in [(1, CGSize.zero), (3, CGSize(width: -120, height: 75))] as [(CGFloat, CGSize)] {
            let g = geometry(zoom: zoom, offset: offset)
            for (column, row) in [(12, 7), (0, 0), (39, 29), (25, 3)] {
                func pick(_ dx: Double, _ dy: Double) -> EBSDPosition {
                    SEMMapPointer.position(at: g.panePoint(of: ImagePoint(x: Double(column) + dx, y: Double(row) + dy)), geometry: g)
                }
                let here = EBSDPosition(row: row, column: column)
                let at = "pixel (\(row), \(column)) at \(zoom)×"
                XCTAssertEqual(pick(0, 0), here, at)
                XCTAssertEqual(pick(0.49, -0.49), here, at)
                XCTAssertEqual(pick(-0.49, 0.49), here, at)
                if column < 39 { XCTAssertEqual(pick(0.51, 0), EBSDPosition(row: row, column: column + 1), at) }
                if row < 29 { XCTAssertEqual(pick(0, 0.51), EBSDPosition(row: row + 1, column: column), at) }
            }
        }
    }

    /// A drag past the picture's edge holds the edge's pixel on every side, however far it goes, and a degenerate point (NaN) reads the
    /// first pixel rather than trapping. Red under: no clamp (row −5 or column 46 reach the session), the clamp at the count instead of
    /// count − 1, an `Int` made from NaN or 1e12.
    func testAPointPastTheEdgeHoldsTheEdgesPixel() {
        let g = geometry()
        XCTAssertEqual(SEMMapPointer.position(at: CGPoint(x: -50, y: -50), geometry: g), .origin)
        XCTAssertEqual(SEMMapPointer.position(at: CGPoint(x: 465, y: 115), geometry: g), EBSDPosition(row: 11, column: 39))
        XCTAssertEqual(SEMMapPointer.position(at: CGPoint(x: 205, y: 1e12), geometry: g), EBSDPosition(row: 29, column: 20))
        XCTAssertEqual(SEMMapPointer.position(at: CGPoint(x: -1e12, y: 295), geometry: g), EBSDPosition(row: 29, column: 0))
        XCTAssertEqual(SEMMapPointer.position(at: CGPoint(x: CGFloat.nan, y: CGFloat.nan), geometry: g), .origin)
    }

    /// Zoomed out to 0.5× the picture is the middle 200 × 150 points of the box: a press there is on it, up to its edges, and a press
    /// beside it is not (it picks nothing). At 1× the picture is the box. Red under: the box's bounds for the picture's, the edges half a
    /// pixel off, NaN read as on the picture.
    func testZoomedOutAPressBesideThePictureIsNotOnIt() {
        let g = geometry(zoom: 0.5)
        XCTAssertTrue(SEMMapPointer.isOnImage(CGPoint(x: 200, y: 150), geometry: g))
        XCTAssertTrue(SEMMapPointer.isOnImage(CGPoint(x: 100.5, y: 75.5), geometry: g))
        XCTAssertTrue(SEMMapPointer.isOnImage(CGPoint(x: 299.5, y: 224.5), geometry: g))
        XCTAssertFalse(SEMMapPointer.isOnImage(CGPoint(x: 99, y: 150), geometry: g))
        XCTAssertFalse(SEMMapPointer.isOnImage(CGPoint(x: 200, y: 226), geometry: g))
        XCTAssertFalse(SEMMapPointer.isOnImage(CGPoint(x: 20, y: 20), geometry: g))
        XCTAssertFalse(SEMMapPointer.isOnImage(CGPoint(x: CGFloat.nan, y: 150), geometry: g))
        let one = geometry()
        XCTAssertTrue(SEMMapPointer.isOnImage(CGPoint(x: 0, y: 0), geometry: one))
        XCTAssertTrue(SEMMapPointer.isOnImage(CGPoint(x: 400, y: 300), geometry: one))
        XCTAssertFalse(SEMMapPointer.isOnImage(CGPoint(x: 401, y: 150), geometry: one))
    }
}
