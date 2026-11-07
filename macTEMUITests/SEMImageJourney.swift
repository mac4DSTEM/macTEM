//
//  SEMImageJourney.swift
//  The Image room on the demo SEM image (a Thermo-style TIFF, 512 x 471 with a 29-row databar; design §9): the Info tab's Acquisition
//  section names the detector, the HV and the databar; the Display section's `Databar · Hide · Show` is on Hide and the Size row says the
//  scan alone (442 rows); Show draws the 29 rows as a strip under the picture while the image stays the scan (442 rows), Hide
//  removes the strip again. Each step's screenshot is the record of the strip for the taste check.
//

import XCTest

nonisolated final class SEMImageJourney: Journey {
    @MainActor private func infoTab() {
        let picker = waitFor("inspector.tabPicker", timeout: 20)
        (picker.radioButtons["Info"].exists ? picker.radioButtons["Info"] : picker.buttons["Info"]).click()
    }

    @MainActor private func settingsTab() {
        let picker = waitFor("inspector.tabPicker", timeout: 20)
        (picker.radioButtons["Settings"].exists ? picker.radioButtons["Settings"] : picker.buttons["Settings"]).click()
    }

    @MainActor func testTheAcquisitionRowsAndTheDatabarControl() throws {
        try step("launch with the demo SEM image") {
            launch(["--demo-sem-tiff-fixture"])
            XCTAssertTrue(app.staticTexts["Demo SEM image.tif"].firstMatch.waitForExistence(timeout: 30) || element("sidebar.openItems").waitForExistence(timeout: 30))
        }
        try step("the Databar control is on Hide in Display") {
            showInspector(waitingFor: "image.sem.databar")
            let databar = waitFor("image.sem.databar")
            XCTAssertTrue(databar.radioButtons["Hide"].isSelected, "hiding the databar is the default")
        }
        try step("the Info tab's Acquisition section names the file's record") {
            infoTab()
            XCTAssertTrue((waitFor("image.sem.detector", timeout: 20).value as? String)?.contains("ETD") == true)
            XCTAssertTrue((waitFor("image.sem.hv").value as? String)?.contains("15 kV") == true)
            XCTAssertTrue((waitFor("image.sem.workingDistance").value as? String)?.contains("10 mm") == true)
            XCTAssertTrue((waitFor("image.sem.databar").value as? String)?.contains("29 rows") == true)
            XCTAssertTrue(app.staticTexts["512 × 442 px"].firstMatch.waitForExistence(timeout: 10), "the Size row is the scan alone")
        }
        try step("Show draws the databar as a strip under the picture") {
            settingsTab()
            waitFor("image.sem.databar", timeout: 20).radioButtons["Show"].click()
            let strip = waitFor("image.sem.databarStrip", timeout: 20)
            let picture = waitFor("image.view")
            XCTAssertEqual(strip.frame.width, picture.frame.width, accuracy: 1, "the strip is as wide as the picture")
            XCTAssertEqual(strip.frame.minY, picture.frame.maxY, accuracy: 1, "the strip sits right under the picture")
            XCTAssertGreaterThan(strip.frame.height, 0)
            infoTab()
            XCTAssertTrue(app.staticTexts["512 × 442 px"].firstMatch.waitForExistence(timeout: 10), "the image stays the scan alone")
        }
        try step("Hide removes the strip") {
            settingsTab()
            waitFor("image.sem.databar", timeout: 20).radioButtons["Hide"].click()
            XCTAssertTrue(element("image.sem.databarStrip").waitForNonExistence(timeout: 10))
            infoTab()
            XCTAssertTrue(app.staticTexts["512 × 442 px"].firstMatch.waitForExistence(timeout: 10))
        }
    }
}
