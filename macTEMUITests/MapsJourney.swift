//
//  MapsJourney.swift
//  The Maps room's first slice (docs/sem/design/orientation-maps-room.md) on the shipped two-phase steel map: launch with `--demo-ang`,
//  the room shows the IPF-Z map with both phases' colour keys in the bottom pane and the unit cell of the pinned point beside the map;
//  a click on the map moves the orientation pane's point; the inspector's Map control switches to the phase map and its legend. A
//  screenshot at every step.
//

import XCTest

nonisolated final class MapsJourney: Journey {
    @MainActor private func label(_ id: String) -> String {
        let e = waitFor(id, timeout: 30)
        return !e.label.isEmpty ? e.label : ((e.value as? String) ?? "")
    }

    @MainActor func testTheShippedMapShowsItsIPFMapKeysAndPhases() throws {
        try step("launch with the shipped .ang: the IPF-Z map and the keys of both phases") {
            launch(["--demo-ang"])
            waitFor("maps.room", timeout: 30)
            waitFor("maps.map", timeout: 30)
            XCTAssertTrue(label("maps.map.title").contains("IPF-Z"), label("maps.map.title"))
            waitFor("maps.key.pane", timeout: 30)
            waitFor("maps.key.1", timeout: 30)
            waitFor("maps.key.2", timeout: 30)
            waitFor("maps.orientation.cell", timeout: 30)
        }
        try step("a click on the map moves the orientation pane's point") {
            try requireFrontmost()
            XCTAssertTrue(label("maps.orientation.title").contains("row 0 col 0"), label("maps.orientation.title"))
            let map = waitFor("maps.map")
            map.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.6)).click()
            let moved = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !self.label("maps.orientation.title").contains("row 0 col 0") },
                                                  object: nil)
            XCTAssertEqual(XCTWaiter().wait(for: [moved], timeout: 20), .completed, label("maps.orientation.title"))
            waitFor("maps.orientation.values")
        }
        try step("the Map control shows the phase map and its legend") {
            showInspector(waitingFor: "maps.layer")
            try requireFrontmost()
            waitFor("maps.layer").click()
            app.menuItems["Phase"].firstMatch.click()
            let phase = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in self.label("maps.map.title").contains("Phase") }, object: nil)
            XCTAssertEqual(XCTWaiter().wait(for: [phase], timeout: 30), .completed, label("maps.map.title"))
            waitFor("maps.legend.1", timeout: 20)
            waitFor("maps.legend.2", timeout: 20)
            waitFor("maps.phase.1")
            waitFor("maps.phase.2")
        }
    }
}
