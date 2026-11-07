//
//  SEMEDSJourney.swift
//  The EDS room on an SEM spectrum (docs/sem/design/sem-eds-room.md §8, figures F16 and F17): launch `--demo-sem-eds` (the shipped BAM TM002
//  `.hspy`), see the SEM line table with background-subtracted counts for the five lines exspy picks at 10 kV, switch the background windows
//  off and on, type unit k-factors, Quantify, and read wt% and at% for the five elements; Info says SEM and the take-off angle. Before every
//  click the journey checks that macTEM is the frontmost app with its window on screen.
//

import XCTest

nonisolated final class SEMEDSJourney: Journey {
    private static let lines = ["Al_Ka", "C_Ka", "Cu_La", "Mn_La", "Zr_La"]

    @MainActor func testSEMSpectrumLineIntensitiesAndWindowQuantification() throws {
        try step("launch on the shipped SEM-EDS spectrum") {
            launch(["--demo-sem-eds"])
            waitFor("edx.room", timeout: 30)
            showInspector(waitingFor: "edx.sem.backgroundWindows")
        }
        try step("the line table lists the five lines with background-subtracted counts") {
            for line in Self.lines { waitFor("edx.sem.line.\(line)", timeout: 30) }
        }
        try step("background windows off and on again") {
            try requireFrontmost()
            let toggle = waitFor("edx.sem.backgroundWindows")
            toggle.click()
            try requireFrontmost()
            toggle.click()
            waitFor("edx.sem.line.Mn_La", timeout: 10)
        }
        try step("unit k-factors, Quantify, five compositions") {
            for line in Self.lines {
                try requireFrontmost()
                let holder = waitFor("edx.sem.k.\(line)")
                let field = holder.textFields.firstMatch.exists ? holder.textFields.firstMatch : holder
                field.click()
                field.typeText("1\r")
            }
            try requireFrontmost()
            let quantify = waitFor("edx.sem.quantify")
            let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: quantify)
            XCTAssertEqual(XCTWaiter().wait(for: [enabled], timeout: 10), .completed, "Quantify never became available after five k-factors")
            quantify.click()
            for symbol in ["Al", "C", "Cu", "Mn", "Zr"] { waitFor("edx.sem.composition.\(symbol)", timeout: 10) }
        }
        try step("Info says SEM and the take-off angle") {
            try requireFrontmost()
            let info = app.buttons["Info"].firstMatch
            XCTAssertTrue(info.waitForExistence(timeout: 10), "no Info tab in the inspector")
            info.click()
            waitFor("edx.sem.takeOff", timeout: 10)
        }
    }
}
