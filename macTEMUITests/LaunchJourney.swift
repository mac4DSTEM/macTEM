//
//  LaunchJourney.swift
//  The app launches and the generated demo image opens: the sidebar lists it and the status bar says it opened.
//

import XCTest

nonisolated final class LaunchJourney: Journey {
    @MainActor func testTheDemoImageOpensAtLaunch() throws {
        try step("launch with the demo image") { launch(["--demo-fixture"]) }
        try step("the demo image is listed") {
            waitFor("sidebar.openItems", timeout: 30)
            XCTAssertTrue(app.staticTexts["Demo lattice"].firstMatch.waitForExistence(timeout: 30), "the sidebar never listed Demo lattice")
        }
        try step("the status bar says it opened") {
            // While the pointer rests on the image the status line is its hover readout (control placement §7): rest it on the sidebar first.
            waitFor("sidebar.openItems", timeout: 30).hover()
            let bar = waitFor("status.bar", timeout: 30)
            let predicate = NSPredicate(format: "label CONTAINS[c] 'Opened' OR value CONTAINS[c] 'Opened'")
            let done = XCTNSPredicateExpectation(predicate: predicate, object: bar)
            XCTAssertEqual(XCTWaiter().wait(for: [done], timeout: 30), .completed, "status bar: \(bar.label) / \((bar.value as? String) ?? "")")
        }
    }

    /// The rooms in light mode (the overnight review had no light screenshot), one screenshot each, to be read for contrast of the badges,
    /// colour bars, hatching and the periodic table. The assertion is only that each room draws; the judgement is the screenshot's.
    @MainActor func testTheDiffractionRoomInLightMode() throws {
        try step("launch the Diffraction room in light mode") {
            launch(["--demo-diffraction-fixture", "--appearance", "light"])
            waitFor("diffraction.pane", timeout: 60)
        }
    }

    @MainActor func testTheSpectrumRoomsInLightMode() throws {
        try step("launch in light mode") {
            launch(["--demo-spectrum-fixture", "--demo-eels-fixture", "--appearance", "light"])
        }
        try step("the EDX room in light mode") {
            waitFor("workspace.edx", timeout: 30).click()
            waitFor("workspace.primaryAction", timeout: 60)
            waitFor("maps.scaleBar.HAADF", timeout: 30)
        }
        try step("the EELS room in light mode") {
            waitFor("workspace.eels", timeout: 30).click()
            waitFor("eels.maps", timeout: 60)
        }
    }
}
