//
//  SEMRoomsPickWiringTests.swift
//  The SEM maps pick as mac4DSTEM's real-space pane does (D-SEM-110), pinned at the source because a unit test drives no gesture (the
//  precedent is `FFTRoomWiringTests`): in the Patterns, Indexing, Compare and Maps views no hover moves the pattern (no `session.hover(`,
//  `patterns?.hover(`, `pinHovered` or Space), every map mounts the scrub layer at 1× and below and the shared marker with its handle
//  above, in the map's own coordinate space, the old crosshair is gone, ⌘-click still selects grains in Maps, and each room's root is
//  given the keyboard explicitly by a press on its map (`SEMRoomFocus`, `SEMRoomKeys`), not left to SwiftUI's defaults.
//  Red before: the four files hovered the pattern pane and drew `ScanMarker(`; the three keyed rooms pinned the hovered point on Space
//  and nothing gave their root the keyboard on a click.
//

import XCTest

nonisolated final class SEMRoomsPickWiringTests: XCTestCase {

    /// The four files that draw an SEM map.
    private let views = ["macTEM/UI/PatternsRoom.swift", "macTEM/UI/IndexingRoom.swift", "macTEM/UI/IndexingCompare.swift", "macTEM/UI/MapsRoom.swift"]

    /// The repo's own source file at `path`, read beside this test file, without its comment lines (a sentence about hovering is not code),
    /// every run of white space one space, so a check reads code, not its layout.
    private func code(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        return lines.joined(separator: "\n").split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// No hover moves the pattern and nothing pins on Space; every map scrubs at 1× and below, draws the shared marker (its handle zoomed
    /// in) and reads both in its own space; the box-and-arms crosshair is gone. Red under: a `session.hover(` left in a map's hover, the
    /// old `ScanMarker(` in any room, the scrub mounted at every zoom (zoomed in, the drag could not pan).
    func testNoHoverMovesThePatternAndEveryMapPicksByClickOrDrag() throws {
        for path in views {
            let text = try code(path)
            XCTAssertFalse(text.contains("session.hover("), "\(path) hovers the session")
            XCTAssertFalse(text.contains("patterns?.hover("), "\(path) hovers the Patterns room's session")
            XCTAssertFalse(text.contains("pinHovered"), "\(path) pins the hovered point")
            XCTAssertFalse(text.contains("== .space"), "\(path) reads Space")
            XCTAssertFalse(text.replacingOccurrences(of: "SEMScanMarker(", with: "").contains("ScanMarker("), "\(path) draws the old crosshair")
            XCTAssertTrue(text.contains("let mode = SEMMapPointer.mode(zoom: zp.effectiveZoom)"), path)
            XCTAssertTrue(text.contains("if mode == .scrub { SEMMapScrubLayer(geometry: geometry, zoomModel: zoomModel)"), path)
            XCTAssertTrue(text.contains("SEMScanMarker(position: "), path)
            XCTAssertTrue(text.contains("isHandle: mode == .panAndGrab"), path)
            XCTAssertTrue(text.contains(".frame(width: box.width, height: box.height) .coordinateSpace(.named(SEMMapPointer.space))"), path)
            // Once, last on the pane, outside ZoomPan's modifiers: inside them the press would be a child gesture of the pan and could take it.
            XCTAssertEqual(text.components(separatedBy: ".modifier(SEMMapPress())").count - 1, 1, path)
            XCTAssertTrue(text.contains(".modifier(SEMMapPress()) }"), "\(path) gives the room the keyboard from the pane")
        }
    }

    /// The Patterns, Indexing and Maps rooms' roots carry `SEMRoomFocus` (focusable, bound to its own focus state, the default focus, and
    /// the keyboard's owner on a press on a map), and the scrub, the handle and the press each take it. Maps keeps its ⌘-click. Red
    /// under: a root back on a bare `.focusable()` (the click left the keyboard where it was: PatternsJourney's arrows went nowhere), the
    /// default focus dropped, a scrub that picks without taking the keyboard, ⌘-click lost to the scrub.
    func testEachRoomsRootTakesTheKeyboardOnAPressOnItsMap() throws {
        for path in ["macTEM/UI/PatternsRoom.swift", "macTEM/UI/IndexingRoom.swift", "macTEM/UI/MapsRoom.swift"] {
            let text = try code(path)
            XCTAssertTrue(text.contains(".modifier(SEMRoomFocus()) .onKeyPress(phases: .down)"), path)
            XCTAssertFalse(text.contains(".focusable()"), "\(path) makes its own focusable root")
        }
        let pick = try code("macTEM/UI/SEMMapPick.swift")
        XCTAssertTrue(pick.contains(".focusable() .focusEffectDisabled()"))
        XCTAssertTrue(pick.contains(".focused($hasKeys)"))
        XCTAssertTrue(pick.contains(".defaultFocus($hasKeys, true)"))
        XCTAssertTrue(pick.contains(".environment(\\.semRoomKeys, SEMRoomKeys { if !hasKeys { hasKeys = true } })"))
        XCTAssertEqual(pick.components(separatedBy: "roomKeys.take()").count - 1, 3, "the scrub, the handle and the map press take the keyboard")
        XCTAssertTrue(pick.contains(".gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named(SEMMapPointer.space)).onChanged"))
        XCTAssertTrue(pick.contains("}, including: isHandle ? .all : .none) .allowsHitTesting(isHandle)"))
        XCTAssertTrue(try code("macTEM/UI/MapsRoom.swift").contains(".highPriorityGesture(SpatialTapGesture().modifiers(.command).onEnded"))
    }

    /// The titles and the pane values say where the pick is, never "hovering" or "pinned": the pattern panes through
    /// `EBSDBrowsing.patternTitle(_:)`, the orientation pane from the pick. Red under: the old `hovering:` title, " · pinned" in Maps.
    func testThePanesNameThePickWithoutHoverWords() throws {
        for path in views {
            let text = try code(path)
            XCTAssertFalse(text.contains("hovering:"), path)
            XCTAssertFalse(text.contains("pinned at row"), path)
            XCTAssertFalse(text.contains("\" · pinned\""), path)
        }
        XCTAssertTrue(try code("macTEM/UI/PatternsRoom.swift").contains("EBSDBrowsing.patternTitle(position) + (session.patternIsProcessed"))
        XCTAssertTrue(try code("macTEM/UI/IndexingRoom.swift").contains("EBSDBrowsing.patternTitle(position) + \" · as indexed\""))
        XCTAssertTrue(try code("macTEM/UI/MapsRoom.swift").contains("let point = session.pinned"))
    }
}
