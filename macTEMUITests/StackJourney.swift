//
//  StackJourney.swift
//  An image stack on the demo stack (24 frames, a bright block that moves right by one step per frame): the Image room's inspector says
//  "Frame 1 of 24", Next shows frame 2, the slider's value follows, and the shown frame (the one the image holds) catches up with the
//  request.
//

import XCTest

nonisolated final class StackJourney: Journey {
    @MainActor func testTheSliderStepsThroughTheFrames() throws {
        try step("launch with the demo stack") {
            launch(["--demo-stack-fixture"])
            XCTAssertTrue(app.staticTexts["Demo stack"].firstMatch.waitForExistence(timeout: 30) || element("sidebar.openItems").waitForExistence(timeout: 30))
        }
        try step("show the inspector") {
            if !element("image.stack.frame").waitForExistence(timeout: 3) { app.typeKey("i", modifierFlags: [.command, .option]) }
            waitFor("image.stack.frame", timeout: 30)
        }
        try step("frame 1 is shown") {
            let value = waitValue("image.stack.frame") { $0 == "1" }
            XCTAssertEqual(value, "1")
        }
        try step("step to the next frame") {
            waitFor("image.stack.next").click()
            waitValue("image.stack.frame", timeout: 30) { $0 == "2" }
        }
        try step("step three more") {
            for _ in 0..<3 { waitFor("image.stack.next").click() }
            waitValue("image.stack.frame", timeout: 30) { $0 == "5" }
        }
        try step("step back") {
            waitFor("image.stack.previous").click()
            waitValue("image.stack.frame", timeout: 30) { $0 == "4" }
        }
    }

    @MainActor func testArrowKeysStepAndTheContrastCanBeHeld() throws {
        try step("launch with the demo stack") {
            launch(["--demo-stack-fixture"])
            showInspector(waitingFor: "image.stack.frame")
        }
        try step("right arrow steps to frame 2, left arrow back") {
            waitFor("image.view").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
            app.typeKey(.rightArrow, modifierFlags: [])
            waitValue("image.stack.frame", timeout: 30) { $0 == "2" }
            app.typeKey(.rightArrow, modifierFlags: [])
            waitValue("image.stack.frame", timeout: 30) { $0 == "3" }
            app.typeKey(.leftArrow, modifierFlags: [])
            waitValue("image.stack.frame", timeout: 30) { $0 == "2" }
        }
        try step("hold the contrast and step on") {
            let hold = waitFor("image.stack.holdContrast")
            hold.click()
            XCTAssertEqual(hold.value as? Int, 1, "the toggle did not turn on")
            waitFor("image.stack.next").click()
            waitValue("image.stack.frame", timeout: 30) { $0 == "3" }
        }
    }
}
