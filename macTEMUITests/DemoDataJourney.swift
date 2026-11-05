//
//  DemoDataJourney.swift
//  Help > Open Demo Data (macTEM#108), the way App Review meets it: launch with no file, open each of the four generated documents from
//  the menu, and see each land in its room with its data drawn (the lattice image, the Au pattern, the EDX maps, the EELS t/λ map).
//  The menu items have no identifiers (SwiftUI commands), so they are found by their titles, `DemoDocument.title`.
//  Before every click the journey checks that macTEM is the frontmost app and its window is on screen, and stops otherwise: a click on
//  the menu bar of another app would land in that app.
//

import XCTest

nonisolated final class DemoDataJourney: Journey {
    /// Help > Open Demo Data > `title`, with the frontmost check before each of the three clicks.
    @MainActor private func openDemo(_ title: String) throws {
        try requireFrontmost()
        let help = app.menuBars.menuBarItems["Help"].firstMatch
        XCTAssertTrue(help.waitForExistence(timeout: 10), "no Help menu")
        help.click()
        let submenu = app.menuItems["Open Demo Data"].firstMatch
        XCTAssertTrue(submenu.waitForExistence(timeout: 10), "no Open Demo Data in the Help menu")
        XCTAssertTrue(submenu.isEnabled, "Open Demo Data is disabled")
        try requireFrontmost()
        submenu.hover()
        let item = app.menuItems[title].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 10), "no \(title) in Open Demo Data")
        try requireFrontmost()
        item.click()
    }

    @MainActor func testEachDemoDocumentOpensFromTheHelpMenu() throws {
        try step("launch with no file") { launch() }
        try step("Lattice Image opens in the Image room") {
            try openDemo("Lattice Image")
            waitFor("image.view", timeout: 30)
            XCTAssertTrue(app.staticTexts["Demo lattice"].firstMatch.waitForExistence(timeout: 30), "the sidebar never listed Demo lattice")
        }
        try step("Au Diffraction Pattern opens in the Diffraction room") {
            try openDemo("Au Diffraction Pattern")
            waitFor("diffraction.pane", timeout: 60)
            waitValue("diffraction.view", timeout: 60) { (Double($0) ?? 0) > 0 }
        }
        try step("EDX Spectrum Image opens in the EDX room with its maps") {
            try openDemo("EDX Spectrum Image")
            waitFor("edx.room", timeout: 30)
            waitFor("maps.scaleBar.HAADF", timeout: 60)
        }
        try step("EELS Spectrum Image opens in the EELS room with its t/λ map") {
            try openDemo("EELS Spectrum Image")
            waitFor("eels.room", timeout: 30)
            let tile = app.groups.matching(NSPredicate(format: "label BEGINSWITH %@", "t/\u{03BB} map")).firstMatch
            XCTAssertTrue(tile.waitForExistence(timeout: 90), "the t/λ map never appeared")
        }
    }
}
