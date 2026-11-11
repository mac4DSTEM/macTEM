//
//  DemoDataJourney.swift
//  Help > Open Demo Data (macTEM#108), the way App Review meets it: launch with no file, open each of the four generated documents from
//  the menu, and see each land in its room with its data drawn (the lattice image, the Au pattern, the EDX maps, the EELS t/λ map); then
//  the shipped SEM-EDS spectrum (a real file in the bundle) lands in the EDS room with Quantify offered. The welcome canvas's Try Demo
//  Data opens the same list. The menu items have no identifiers (SwiftUI commands), so they are found by their titles, `DemoDocument.title`.
//  Before every click the journey checks that macTEM is the frontmost app and its window is on screen, and stops otherwise: a click on
//  the menu bar of another app would land in that app.
//

import XCTest

nonisolated final class DemoDataJourney: Journey {
    @MainActor func testEachDemoDocumentOpensFromTheHelpMenu() throws {
        try step("launch with no file") { launch() }
        try step("Lattice Image opens in the Image room") {
            try openDemoData("Lattice Image")
            waitFor("image.view", timeout: 30)
            XCTAssertTrue(app.staticTexts["Demo lattice"].firstMatch.waitForExistence(timeout: 30), "the sidebar never listed Demo lattice")
        }
        try step("Au Diffraction Pattern opens in the Diffraction room") {
            try openDemoData("Au Diffraction Pattern")
            waitFor("diffraction.pane", timeout: 60)
            waitValue("diffraction.view", timeout: 60) { (Journey.number($0) ?? 0) > 0 }
        }
        try step("EDX Spectrum Image opens in the EDX room with its maps") {
            try openDemoData("EDX Spectrum Image")
            waitFor("edx.room", timeout: 30)
            waitFor("maps.scaleBar.HAADF", timeout: 60)
        }
        try step("EELS Spectrum Image opens in the EELS room with its t/λ map") {
            try openDemoData("EELS Spectrum Image")
            waitFor("eels.room", timeout: 30)
            let tile = app.groups.matching(NSPredicate(format: "label BEGINSWITH %@", "t/\u{03BB} map")).firstMatch
            XCTAssertTrue(tile.waitForExistence(timeout: 90), "the t/λ map never appeared")
        }
        try step("SEM-EDS Spectrum (BAM TM002) opens in the EDX room from the bundle") {
            try openDemoData("SEM-EDS Spectrum (BAM TM002)")
            waitFor("edx.room", timeout: 30)
            waitStatus(containing: ["EDS_SEM_TM002.hspy"], timeout: 60)
            let verb = waitFor("workspace.primaryAction", timeout: 60)
            let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: verb)
            XCTAssertEqual(XCTWaiter().wait(for: [enabled], timeout: 90), .completed, "Quantify never became available on the shipped spectrum")
        }
    }

    /// The welcome canvas's Try Demo Data: the same documents, before any file is open.
    @MainActor func testTryDemoDataOnTheWelcomeCanvasOpensTheLatticeImage() throws {
        try step("launch with no file") { launch() }
        try step("Try Demo Data > Lattice Image from the welcome canvas") {
            try requireFrontmost()
            let door = waitFor("welcome.tryDemo", timeout: 20)
            door.click()
            let item = app.menuItems["Lattice Image"].firstMatch
            XCTAssertTrue(item.waitForExistence(timeout: 10), "no Lattice Image under Try Demo Data")
            try requireFrontmost()
            item.click()
            waitFor("image.view", timeout: 30)
            XCTAssertTrue(app.staticTexts["Demo lattice"].firstMatch.waitForExistence(timeout: 30), "the sidebar never listed Demo lattice")
        }
    }
}
