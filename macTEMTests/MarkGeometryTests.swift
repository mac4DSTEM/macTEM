//
//  MarkGeometryTests.swift
//  The marks' map (V1-5, `MarkGeometry` in UI/ImageRoomMarks.swift): image coordinates (a pixel's centre at integers)
//  to pane points through the shader's own `MetalDisplayTransform`, so a mark sits on the pixel it names at every zoom
//  and pan. Each test names the mutation that turns it red.
//

import ShellMetal
import XCTest
import TEMCore
@testable import macTEM

nonisolated final class MarkGeometryTests: XCTestCase {

    private func geometry(zoom: CGFloat = 1, offset: CGSize = .zero) -> MarkGeometry {
        let box = CGSize(width: 400, height: 240)
        return MarkGeometry(transform: MetalDisplayTransform(paneSize: box, imageBox: box, zoom: zoom, offset: offset),
                            imageWidth: 40, imageHeight: 24)
    }

    /// The image's outer edges are the box's edges; pixel (0, 0)'s centre is half a pixel in. Red under: the +0.5
    /// dropped from `panePoint` (the image shifts half a pixel up-left); the width used for y.
    func testTheImageEdgesAreTheBoxEdgesAtZoomOne() {
        let g = geometry()
        XCTAssertEqual(g.panePoint(of: ImagePoint(x: -0.5, y: -0.5)), CGPoint(x: 0, y: 0))
        XCTAssertEqual(g.panePoint(of: ImagePoint(x: 39.5, y: 23.5)), CGPoint(x: 400, y: 240))
        XCTAssertEqual(g.panePoint(of: ImagePoint(x: 0, y: 0)), CGPoint(x: 5, y: 5), "10 points per pixel")
    }

    /// Forward and back agree with the SHADER's inverse (`uv(atPanePoint:)`) at a zoom and a pan, to 1e-9 px. Red under:
    /// the zoom left out of `panePoint`, the offset added twice, the pane centre for the box centre.
    func testThePaneMapIsTheShadersMapAtAnyZoomAndPan() {
        for (zoom, offset) in [(1.0, CGSize.zero), (4.0, CGSize(width: 37, height: -21)), (0.5, .zero), (12.0, CGSize(width: -900, height: 300))] {
            let g = geometry(zoom: zoom, offset: offset)
            for q in [ImagePoint(x: -0.5, y: -0.5), ImagePoint(x: 12.25, y: 3.75), ImagePoint(x: 39.5, y: 23.5)] {
                let back = g.imagePoint(atPanePoint: g.panePoint(of: q))
                XCTAssertEqual(back.x, q.x, accuracy: 1e-9, "x at zoom \(zoom)")
                XCTAssertEqual(back.y, q.y, accuracy: 1e-9, "y at zoom \(zoom)")
            }
        }
        // Zoom 4 about the pane centre: the centre pixel stays put, a point 10 pt right of it moves to 40 pt right.
        let g = geometry(zoom: 4)
        let centre = g.panePoint(of: ImagePoint(x: 19.5, y: 11.5))
        XCTAssertEqual(centre, CGPoint(x: 200, y: 120))
        XCTAssertEqual(g.panePoint(of: ImagePoint(x: 20.5, y: 11.5)).x, 240, accuracy: 1e-9)
    }

    /// A mark ends on the pixels: a point dragged outside is held at the image's edge. Red under: no clamp; the clamp
    /// at 0…W instead of −0.5…W − 0.5.
    func testAPointOutsideTheImageIsHeldAtItsEdge() {
        let g = geometry()
        XCTAssertEqual(g.clamped(ImagePoint(x: -3, y: 100)), ImagePoint(x: -0.5, y: 23.5))
        XCTAssertEqual(g.clamped(ImagePoint(x: 7.25, y: 4)), ImagePoint(x: 7.25, y: 4))
        XCTAssertEqual(g.pointsPerPixel, 10)
        XCTAssertEqual(geometry(zoom: 3).pointsPerPixel, 30)
    }
}
