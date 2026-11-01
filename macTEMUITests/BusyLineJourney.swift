//
//  BusyLineJourney.swift
//  The toolbar's busy line names the running work: during Quantify on the owner's real Velox file it reads "Quantifying…" (or the
//  line check that follows the fit), never the open sentence that the status line still holds. Opt-in like EDXRealFileJourney:
//      TEST_RUNNER_MACTEM_REAL_DATA=1 MACTEM_REAL_DATA=1 tools/run-tests.sh ui BusyLineJourney
//  with TEST_RUNNER_MACEM_DATA pointing at a copy of the data folder when the run may write next to the file.
//

import XCTest

nonisolated final class BusyLineJourney: Journey {
    static let file = Journey.dataFolder + "stem-edx/SI HAADF 1339 65000 x 20260508.emd"

    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MACTEM_REAL_DATA"] == "1", "set MACTEM_REAL_DATA=1 (and TEST_RUNNER_MACTEM_REAL_DATA=1) to run on the real file")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: Self.file), "the real file is not at \(Self.file)")
    }

    @MainActor func testQuantifyNamesItselfOnTheBusyLine() throws {
        try step("open the real file in the EDS room") {
            launch(["--open", Self.file])
            if !element("edx.room").waitForExistence(timeout: 20) {
                let sidebar = element("workspace.edx")
                if sidebar.waitForExistence(timeout: 120), sidebar.isEnabled { sidebar.click() }
            }
            waitFor("edx.room", timeout: 120)
            waitFor("edx.spectrum", timeout: 120)
            XCTAssertTrue(app.groups.matching(NSPredicate(format: "label BEGINSWITH %@", "Colour mix map")).firstMatch.waitForExistence(timeout: 120),
                          "the colour mix tile never appeared")
        }
        try step("Quantify; the busy line names the fit") {
            let verb = waitFor("workspace.primaryAction", timeout: 60)
            // Not while the open's Auto ID still runs: the verb is then its Cancel, and a click would stop it.
            let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true AND NOT (label BEGINSWITH %@)", "Cancel"), object: verb)
            XCTAssertEqual(XCTWaiter().wait(for: [enabled], timeout: 120), .completed, "Quantify never became enabled")
            verb.click()
            // Found by its text, as the clock journey does: the identifier inside the ticking TimelineView is not resolved by XCUITest.
            let busy = app.toolbars.staticTexts.matching(NSPredicate(format: "label MATCHES %@", ".* · [0-9]+( s|:[0-9][0-9])( · ETA .*)?")).firstMatch
            XCTAssertTrue(busy.waitForExistence(timeout: 60), "no busy line in the toolbar")
            let line = busy.exists ? busy.label : "(gone)"
            let a = XCTAttachment(string: line); a.name = "busy line"; a.lifetime = .keepAlways; add(a)
            XCTAssertTrue(line.hasPrefix("Quantifying") || line.hasPrefix("Checking for unlisted lines") || line == "(gone)", "the busy line reads \"\(line)\"")
            XCTAssertFalse(line.hasPrefix("Opened"), "the busy line still names the open")
        }
    }
}
