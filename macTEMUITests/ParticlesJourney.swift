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
}
