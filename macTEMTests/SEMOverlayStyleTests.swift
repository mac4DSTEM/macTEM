//
//  SEMOverlayStyleTests.swift
//  The Indexing room's detected bands are stroked as mac4DSTEM strokes its overlays (Paul, 2026-11-11: "cant really see the orange
//  lines in the patterns indicating indexing"). The values are mac4DSTEM's `ApertureOutline` and `PatternFitLegend` constants
//  (mac4DSTEM/UI/PaneOverlays.swift); the band overlay draws through them, every dark track before any line, the track solid under
//  a dashed line. Red before: no `SEMOverlayStyle`, the unmatched bands on a dashed black 0.45 track 3 pt wide under a 1.25 pt line,
//  the tracks drawn between the lines, the family labels on a shadow.
//

import XCTest
import SwiftUI
@testable import macTEM

nonisolated final class SEMOverlayStyleTests: XCTestCase {

    /// mac4DSTEM's overlay recipe, value for value: a 3.5 pt under-stroke at 0.6, a 1.5 pt line at 0.9, a [4, 3] dash; the label plate
    /// a capsule at 0.48 with 7 and 3 pt of padding.
    func testTheStrokesAreMac4DSTEMsOverlayRecipe() {
        XCTAssertEqual(SEMOverlayStyle.haloWidth, 3.5)
        XCTAssertEqual(SEMOverlayStyle.haloOpacity, 0.6)
        XCTAssertEqual(SEMOverlayStyle.lineWidth, 1.5)
        XCTAssertEqual(SEMOverlayStyle.lineOpacity, 0.9)
        XCTAssertEqual(SEMOverlayStyle.dash, [4, 3])
        XCTAssertEqual(SEMOverlayStyle.plateOpacity, 0.48)
        XCTAssertEqual(SEMOverlayStyle.plateHorizontalPadding, 7)
        XCTAssertEqual(SEMOverlayStyle.plateVerticalPadding, 3)
        XCTAssertGreaterThan(SEMOverlayStyle.haloWidth - SEMOverlayStyle.lineWidth, 1.5, "a track a point wider than the line each side")
    }

    /// The track is solid whatever the line's dash, so a dashed band reads on an unbroken dark track; a solid line has no dash.
    func testTheTrackIsSolidUnderADashedLine() {
        XCTAssertEqual(SEMOverlayStyle.halo.dash, [])
        XCTAssertEqual(SEMOverlayStyle.halo.lineWidth, SEMOverlayStyle.haloWidth)
        XCTAssertEqual(SEMOverlayStyle.line(dashed: true).dash, SEMOverlayStyle.dash)
        XCTAssertEqual(SEMOverlayStyle.line(dashed: true).lineWidth, SEMOverlayStyle.lineWidth)
        XCTAssertEqual(SEMOverlayStyle.line(dashed: false).dash, [])
    }

    /// The band overlay draws through the style: both tracks before either line (a track drawn after a line cut it where two bands
    /// crossed), no private widths, opacities or dash left, the family labels on the plate instead of a shadow.
    func testTheBandOverlayDrawsTheTracksFirstThroughTheStyle() throws {
        let root = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("macTEM/UI/IndexingRoom.swift"), encoding: .utf8)
        let begin = try XCTUnwrap(text.range(of: "private struct DetectedBandsOverlay: View {"))
        let end = try XCTUnwrap(text.range(of: "\n}\n", range: begin.upperBound..<text.endIndex))
        let overlay = String(text[begin.lowerBound..<end.upperBound])
        for stale in ["0.45", "0.55", "1.25", "[5, 4]", ".shadow("] {
            XCTAssertFalse(overlay.contains(stale), "the overlay still draws \(stale)")
        }
        let halos = overlay.ranges(of: "style: SEMOverlayStyle.halo)")
        let lines = overlay.ranges(of: "style: SEMOverlayStyle.line(dashed:")
        XCTAssertEqual(halos.count, 2, "a track for the matched and one for the unmatched bands")
        XCTAssertEqual(lines.count, 2, "a line for the matched and one for the unmatched bands")
        XCTAssertLessThan(try XCTUnwrap(halos.last).lowerBound, try XCTUnwrap(lines.first).lowerBound, "every track before any line")
        XCTAssertTrue(overlay.contains(".background(Color.black.opacity(SEMOverlayStyle.plateOpacity), in: Capsule())"))
    }
}
