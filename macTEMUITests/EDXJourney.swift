//
//  EDXJourney.swift
//  The EDX room on the demo spectrum image: Auto ID has found the planted elements, Quantify fills the composition table, and
//  Mg and Si are in it with a wt% (the planted fractions are the generator's, `DemoDocuments.Truth`).
//

import XCTest

nonisolated final class EDXJourney: Journey {
    @MainActor func testAutoIDAndQuantifyFindMagnesiumAndSilicon() throws {
        try step("launch with the demo spectrum image") { launch(["--demo-spectrum-fixture"]) }
        try step("go to the EDX room") {
            waitFor("workspace.edx", timeout: 30).click()
            waitFor("edx.room", timeout: 30)
        }
        try step("quantify") {
            let verb = waitFor("workspace.primaryAction", timeout: 60)
            // Auto ID runs on open; the verb is enabled once an element is picked to quantify.
            let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: verb)
            XCTAssertEqual(XCTWaiter().wait(for: [enabled], timeout: 60), .completed, "Auto ID picked nothing to quantify")
            verb.click()
        }
        try step("every map has a scale bar that opens its colours") {
            waitFor("maps.scaleBar.HAADF", timeout: 30)
            let bars = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'maps.scaleBar.'")).count
            XCTAssertGreaterThanOrEqual(bars, 4, "the colour mix, HAADF and the element maps each carry a scale bar")
        }
        try step("the composition lists magnesium and silicon") {
            waitFor("edx.compositionTable", timeout: 120)
            waitFor("edx.composition.Mg", timeout: 120)
            waitFor("edx.composition.Si", timeout: 10)
            let mg = Double(waitValue("edx.composition.Mg.wt", timeout: 60) { !$0.isEmpty }) ?? .nan
            let si = Double(waitValue("edx.composition.Si.wt", timeout: 60) { !$0.isEmpty }) ?? .nan
            XCTAssertTrue(mg > 0 && mg < 100 && si > 0 && si < 100, "Mg \(mg) wt%, Si \(si) wt%")
        }
    }

    /// The maps block: the tiles are fitted to the space, with no tile size to choose and no map shown alone (both rooms pass `soloEnabled: false` since 1.0);
    /// a double click on a map is the zoom reset (MacEMUI `MapTileView`): the wheel zooms every tile, the scale bar's length follows, a double click returns it
    /// to the whole scan, and the grid stays as it was.
    @MainActor func testADoubleClickResetsTheZoomAndKeepsTheGrid() throws {
        try step("launch with the demo spectrum image") { launch(["--demo-spectrum-fixture"]) }
        try step("go to the EDX room") {
            waitFor("workspace.edx", timeout: 30).click()
            waitFor("edx.room", timeout: 30)
        }
        let haadf = app.groups["HAADF map"].firstMatch
        let mg = app.groups["Mg map, Kα"].firstMatch
        try step("there is no tile size control") {
            XCTAssertTrue(haadf.waitForExistence(timeout: 30))
            XCTAssertTrue(mg.waitForExistence(timeout: 60))
            XCTAssertFalse(element("maps.tileSize").exists, "the maps scale with the panes")
        }
        // The scale bar's length text ("5 px"): the one thing on a tile that says its zoom.
        let bar = { self.waitFor("maps.scaleBar.HAADF", timeout: 30).staticTexts.firstMatch.label }
        let whole = bar()
        try step("the wheel zooms the maps") {
            for dy in [8.0, -8.0, 16.0, -16.0] where bar() == whole { haadf.scroll(byDeltaX: 0, deltaY: dy) }
            XCTAssertNotEqual(bar(), whole, "the wheel over the HAADF map never changed its scale bar (\(whole))")
        }
        try step("a double click returns to the whole scan and keeps the grid") {
            let width = haadf.frame.width
            haadf.doubleClick()
            let back = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in bar() == whole }, object: nil)
            XCTAssertEqual(XCTWaiter().wait(for: [back], timeout: 10), .completed, "the scale bar reads \(bar()), not \(whole)")
            XCTAssertTrue(mg.exists, "the other maps stay: no map is shown alone")
            XCTAssertEqual(haadf.frame.width, width, accuracy: 1, "the tile keeps its size")
        }
    }

    /// Regions are compared: two rectangles and a line (the launch draws them with the room's own calls, `--demo-regions`; a drag with real mouse events is checked
    /// by hand, because XCUITest's synthesized drag does not reach SwiftUI's DragGesture). Since 1.0 there is no Regions list in the inspector: the Results area has a
    /// Regions table with a row for each region and its pixel count (planted: 4 x 4 = 16 and 8 x 8 = 64 of the 16 x 16 scan) and, the pixels all alike, a net count
    /// that scales with the pixels (64/16 = 4, within 30 %: the demo's Mg varies across the scan, the right region holds brighter pixels); a line is not a row; the
    /// profile along the line (selected when drawn) is the inset over the spectrum.
    @MainActor func testRegionsAreComparedInTheTableAndTheLineHasAProfile() throws {
        try step("launch with the demo spectrum image and two regions") { launch(["--demo-spectrum-fixture", "--demo-regions"]) }
        try step("go to the EDX room") {
            waitFor("workspace.edx", timeout: 30).click()
            waitFor("edx.room", timeout: 30)
        }
        try step("the Regions table lists both regions with their pixels, and not the line") {
            waitFor("edx.regionTable", timeout: 60)
            XCTAssertEqual(waitValue("edx.regionTable.Region 1.pixels", timeout: 30) { !$0.isEmpty }, "16")
            XCTAssertEqual(waitValue("edx.regionTable.Region 2.pixels", timeout: 30) { !$0.isEmpty }, "64")
            XCTAssertFalse(element("edx.regionTable.Line 1.pixels").exists, "a line has a profile, not a row")
        }
        try step("the net counts scale with the pixels") {
            let one = Double(waitValue("edx.regionTable.Region 1.Mg.net", timeout: 60) { !$0.isEmpty }) ?? .nan
            let two = Double(waitValue("edx.regionTable.Region 2.Mg.net", timeout: 60) { !$0.isEmpty }) ?? .nan
            XCTAssertEqual(two / one, 4, accuracy: 1.2, "Mg net: \(one) in 16 pixels, \(two) in 64")
        }
        try step("the line has a profile over the spectrum") {
            waitFor("profile.chart", timeout: 30)
        }
    }

    /// The colour mix is the anchor tile with every quantified map in it; a click on an element map takes it out (and back in), and the scale bar of a map opens its colour controls.
    @MainActor func testClickingMapsMakesCustomMixesAndTheScaleBarOpensColours() throws {
        try step("launch with the demo spectrum image") { launch(["--demo-spectrum-fixture"]) }
        try step("go to the EDX room; the colour mix holds every map") {
            waitFor("workspace.edx", timeout: 30).click()
            waitFor("edx.room", timeout: 30)
            waitFor("workspace.primaryAction", timeout: 60)
            XCTAssertTrue(app.groups["Colour mix map, Mg + Al + Si"].firstMatch.waitForExistence(timeout: 60), "the planted elements are all in the mix")
        }
        try step("a click on the Mg map takes it out of the mix") {
            app.groups["Mg map, Kα"].firstMatch.click()
            XCTAssertTrue(app.groups["Colour mix map, Al + Si"].firstMatch.waitForExistence(timeout: 20), "Mg is out")
            app.groups["Mg map, Kα"].firstMatch.click()
            XCTAssertTrue(app.groups["Colour mix map, Mg + Al + Si"].firstMatch.waitForExistence(timeout: 20), "and back in")
        }
        try step("the scale bar of a map opens its colours") {
            element("maps.scaleBar.Mg").click()
            waitFor("maps.color", timeout: 10)
        }
    }
}
