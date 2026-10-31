//
//  ParticlesJourney.swift
//  The Particles section on the demo lattice: Show Objects with the defaults counts the five planted discs; the pointer over a disc names
//  the object in the status line, and Object Table opens a window of its own.
//

import XCTest

nonisolated final class ParticlesJourney: Journey {
    @MainActor func testShowObjectsCountsThePlantedFiveDiscs() throws {
        try step("launch with the demo image") {
            launch(["--demo-fixture"])
            XCTAssertTrue(app.staticTexts["Demo lattice"].firstMatch.waitForExistence(timeout: 30))
        }
        try step("show objects") {
            showInspector(waitingFor: "particles.show")
            waitFor("particles.show").click()
        }
        try step("five objects are counted") {
            let counted = waitValue("particles.counts", timeout: 60) { !$0.isEmpty }
            XCTAssertEqual(counted, "5", "counted objects")
            // The table and export buttons are in the window without scrolling the inspector.
            let table = waitFor("particles.table")
            XCTAssertTrue(app.windows.firstMatch.frame.contains(table.frame), "Object Table is below the fold: \(table.frame)")
        }
        try step("the pointer over a disc names the object") {
            // The 70-px disc at (330, 380) of the 512-px square image, which is fitted to the pane and centred in it.
            let pane = waitFor("image.view")
            let side = min(pane.frame.width, pane.frame.height)
            let x = (pane.frame.width - side) / 2 + side * 330 / 512, y = (pane.frame.height - side) / 2 + side * 380 / 512
            pane.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x, dy: y)).hover()
            waitStatus(containing: ["object"])
        }
        try step("Object Table opens its own window") {
            waitFor("particles.table").click()
            waitFor("particles.tableView", timeout: 20)
            XCTAssertGreaterThanOrEqual(app.windows.count, 2, "the table is a window beside the image")
        }
    }

    /// On a comma-locale Mac the size line reads "median length 0,6… nm", with the decimal mark of the pixel readout beside it.
    @MainActor func testTheSizeLineFollowsACommaLocale() throws {
        try step("launch with the demo image in a German locale") {
            launch(["--demo-fixture", "-AppleLocale", "de_DE"])
            XCTAssertTrue(app.staticTexts["Demo lattice"].firstMatch.waitForExistence(timeout: 30))
        }
        try step("show objects") {
            showInspector(waitingFor: "particles.show")
            waitFor("particles.show").click()
            _ = waitValue("particles.counts", timeout: 60) { !$0.isEmpty }
        }
        try step("the size line has a comma") {
            let line = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@ OR value BEGINSWITH %@", "median length", "median length")).firstMatch
            XCTAssertTrue(line.waitForExistence(timeout: 20), "no size line")
            let text = line.label.isEmpty ? ((line.value as? String) ?? "") : line.label
            XCTAssertTrue(text.contains(","), text)
            XCTAssertFalse(text.contains("."), text)
        }
    }
}
