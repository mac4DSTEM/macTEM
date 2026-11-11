//
//  MapsJourney.swift
//  The Maps room's first slice (docs/sem/design/orientation-maps-room.md) on the shipped two-phase steel map: launch with `--demo-ang`,
//  the room shows the IPF-Z map with both phases' colour keys in the bottom pane and the unit cell of the pinned point beside the map;
//  a click on the map moves the orientation pane's point; the inspector's Map control switches to the phase map and its legend. P5-04:
//  Segment fills the Grains tab, a click outlines its grain, the Pole figures tab draws three stereograms and the IPF density, the
//  grain table exports as CSV. A screenshot at every step.
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

    @MainActor func testSegmentFillsTheGrainsAndTexture() throws {
        try step("launch with the shipped .ang and Segment from the toolbar") {
            launch(["--demo-ang", "--export-dir", "macTEM-ui-export"])
            waitFor("maps.map", timeout: 30)
            try requireFrontmost()
            let verb = waitFor("workspace.primaryAction", timeout: 60)
            let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: verb)
            XCTAssertEqual(XCTWaiter().wait(for: [enabled], timeout: 60), .completed, "Segment never became available")
            verb.click()
            waitStatus(containing: ["Segmented"], timeout: 120)
        }
        try step("the Grains tab lists the grains; a click on the map outlines its grain") {
            try requireFrontmost()
            app.radioButtons["Grains"].firstMatch.click()
            waitFor("maps.grains.table", timeout: 30)
            XCTAssertTrue(label("maps.grains.summary").contains("grains"), label("maps.grains.summary"))
            // The mean ECD at the grain table's decimals, two or more ("mean ECD 3.14 µm"), as the ECD column writes each grain.
            XCTAssertNotNil(label("maps.grains.summary").range(of: #"mean ECD \d+[.,]\d{2,} "#, options: .regularExpression), label("maps.grains.summary"))
            waitFor("maps.map").coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.4)).click()
            let outlined = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in self.label("maps.grain.outline").contains("outlined") },
                                                     object: nil)
            XCTAssertEqual(XCTWaiter().wait(for: [outlined], timeout: 20), .completed, label("maps.grain.outline"))
        }
        try step("the Pole figures tab draws {100}, {110}, {111} and the IPF density") {
            try requireFrontmost()
            app.radioButtons["Pole figures"].firstMatch.click()
            for k in 0..<4 { waitFor("maps.pole.\(k)", timeout: 120) }
        }
        try step("the Histogram tab counts the KAM of every point") {
            try requireFrontmost()
            app.radioButtons["Histogram"].firstMatch.click()
            waitFor("maps.histogram.bars", timeout: 30)
            XCTAssertTrue(label("maps.histogram.caption").contains("KAM"), label("maps.histogram.caption"))
        }
        try step("the grain table exports as CSV") {
            showInspector(waitingFor: "maps.layer")
            try requireFrontmost()
            // The Export section starts closed, as in the other rooms: its header opens it.
            if !element("maps.export.grains").waitForExistence(timeout: 3) { app.buttons["Export"].firstMatch.click() }
            let button = waitFor("maps.export.grains", timeout: 20)
            let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: button)
            XCTAssertEqual(XCTWaiter().wait(for: [enabled], timeout: 30), .completed, "Grains CSV stayed disabled")
            button.click()
            waitStatus(containing: ["grains.csv"], timeout: 30)
        }
    }
}
