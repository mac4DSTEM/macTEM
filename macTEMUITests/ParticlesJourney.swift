//
//  ParticlesJourney.swift
//  The Particles section on the demo lattice: Show Objects with the defaults counts the five planted discs.
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
