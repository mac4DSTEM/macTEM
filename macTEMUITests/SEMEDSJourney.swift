//
//  SEMEDSJourney.swift
//  The EDS room on an SEM spectrum (docs/sem/design/sem-eds-room.md §8, D-SEM-107): launch `--demo-sem-eds` (the shipped BAM TM002 `.hspy`)
//  and see the shared EDS room take it as it takes a TEM spectrum: the five elements the file names picked, the toolbar's Quantify offered,
//  the composition table after it runs; Info says SEM, the take-off angle and exspy's line windows. Before every click the journey checks
//  that macTEM is the frontmost app with its window on screen.
//

import XCTest

nonisolated final class SEMEDSJourney: Journey {
    private static let lines = ["Al_Ka", "C_Ka", "Cu_La", "Mn_La", "Zr_La"]

    @MainActor func testSEMSpectrumGoesThroughTheSharedEDSRoom() throws {
        try step("launch on the shipped SEM-EDS spectrum") {
            launch(["--demo-sem-eds"])
            waitFor("edx.room", timeout: 30)
        }
        try step("the file's elements are picked and the room's Quantify is offered") {
            let verb = waitFor("workspace.primaryAction", timeout: 60)
            let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: verb)
            XCTAssertEqual(XCTWaiter().wait(for: [enabled], timeout: 90), .completed, "Quantify never became available on the SEM spectrum")
            try requireFrontmost()
            verb.click()
            waitFor("edx.compositionTable", timeout: 60)
        }
        try step("Info says SEM, the take-off angle and exspy's line windows") {
            try requireFrontmost()
            let info = app.buttons["Info"].firstMatch
            XCTAssertTrue(info.waitForExistence(timeout: 10), "no Info tab in the inspector")
            info.click()
            waitFor("edx.sem.takeOff", timeout: 10)
            let windows = app.buttons["Line Windows"].firstMatch
            XCTAssertTrue(windows.waitForExistence(timeout: 10), "no Line Windows section in Info")
            try requireFrontmost()
            windows.click()
            for line in Self.lines { waitFor("edx.sem.line.\(line)", timeout: 10) }
        }
    }
}
