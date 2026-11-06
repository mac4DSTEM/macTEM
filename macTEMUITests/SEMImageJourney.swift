//
//  SEMImageJourney.swift
//  The Image room on the demo SEM image (a Thermo-style TIFF, 512 x 471 with a 29-row databar): the Info tab's SEM section names the
//  vendor, the detector and the databar; the Calibration section's switch is on and the Size row says the scan alone (442 rows);
//  turning the switch off shows the whole frame (471 rows), on again the scan.
//

import XCTest

nonisolated final class SEMImageJourney: Journey {
    @MainActor func testTheSEMSectionAndTheDatabarSwitch() throws {
        try step("launch with the demo SEM image") {
            launch(["--demo-sem-tiff-fixture"])
            XCTAssertTrue(app.staticTexts["Demo SEM image.tif"].firstMatch.waitForExistence(timeout: 30) || element("sidebar.openItems").waitForExistence(timeout: 30))
        }
        try step("the databar switch is on in Calibration") {
            showInspector(waitingFor: "image.sem.cropDatabar")
            let toggle = waitFor("image.sem.cropDatabar")
            XCTAssertEqual(toggle.value as? Int, 1, "cropping is the default")
        }
        try step("the Info tab's SEM section names the file's record") {
            let picker = waitFor("inspector.tabPicker", timeout: 20)
            let info = picker.radioButtons["Info"].exists ? picker.radioButtons["Info"] : picker.buttons["Info"]
            info.click()
            let vendor = waitFor("image.sem.vendor", timeout: 20)
            XCTAssertTrue((vendor.value as? String)?.contains("Thermo") == true, "\(String(describing: vendor.value))")
            XCTAssertTrue((waitFor("image.sem.detector").value as? String)?.contains("ETD") == true)
            XCTAssertTrue((waitFor("image.sem.databar").value as? String)?.contains("29 rows") == true)
            XCTAssertTrue((waitFor("image.sem.workingDistance").value as? String)?.contains("10 mm") == true)
            XCTAssertTrue(app.staticTexts["512 × 442 px"].firstMatch.waitForExistence(timeout: 10), "the Size row is the scan alone")
        }
        try step("turning the switch off shows the whole frame") {
            let picker = waitFor("inspector.tabPicker", timeout: 20)
            let settings = picker.radioButtons["Settings"].exists ? picker.radioButtons["Settings"] : picker.buttons["Settings"]
            settings.click()
            let toggle = waitFor("image.sem.cropDatabar", timeout: 20)
            toggle.click()
            XCTAssertEqual(toggle.value as? Int, 0)
            let info = picker.radioButtons["Info"].exists ? picker.radioButtons["Info"] : picker.buttons["Info"]
            info.click()
            XCTAssertTrue(app.staticTexts["512 × 471 px"].firstMatch.waitForExistence(timeout: 30), "the databar is back")
        }
        try step("and on again the scan") {
            let picker = waitFor("inspector.tabPicker", timeout: 20)
            let settings = picker.radioButtons["Settings"].exists ? picker.radioButtons["Settings"] : picker.buttons["Settings"]
            settings.click()
            waitFor("image.sem.cropDatabar", timeout: 20).click()
            let info = picker.radioButtons["Info"].exists ? picker.radioButtons["Info"] : picker.buttons["Info"]
            info.click()
            XCTAssertTrue(app.staticTexts["512 × 442 px"].firstMatch.waitForExistence(timeout: 30))
        }
    }
}
