//
//  SEMAccessibilityTests.swift
//  Every zoomable pane whose hint promises VoiceOver's Zoom in and Zoom out actions has them (#260): the six SEM picture panes (the
//  Patterns room's scan map and live pattern, the Indexing room's map, indexed pattern and best match, the Maps room's map) set the
//  hint but not the actions, so VoiceOver heard a promise nothing kept, and the three pattern panes could not be zoomed without a pointer.
//  Red before: PatternsRoom 2 hints and 0 actions, IndexingRoom 3 and 0, MapsRoom 1 and 0.
//

import XCTest

nonisolated final class SEMAccessibilityTests: XCTestCase {

    func testEveryPaneThatPromisesZoomActionsHasThem() throws {
        let folder = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("macTEM/UI")
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".swift") }.sorted()
        XCTAssertFalse(files.isEmpty)
        var panes = 0
        for name in files {
            let source = try String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)
            let hints = source.components(separatedBy: ".accessibilityHint(ZoomPan.accessibilityHint)").count - 1
            let actions = source.components(separatedBy: ".zoomPanAccessibilityActions(").count - 1
            XCTAssertEqual(hints, actions, "\(name): every pane that says it zooms with the actions has them")
            panes += hints
        }
        XCTAssertGreaterThanOrEqual(panes, 10, "the four TEM panes and the six SEM panes")
    }
}
