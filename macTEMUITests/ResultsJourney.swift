//
//  ResultsJourney.swift
//  The Results room: a distance drawn in the Image room is a row of the table, and Export Results writes the CSV into the folder given by
//  --export-dir (no save panel is driven); the status bar says it was exported.
//

import XCTest

nonisolated final class ResultsJourney: Journey {
    @MainActor func testADistanceMarkIsAResultAndExportsAsCSV() throws {
        try step("launch with the demo image") {
            launch(["--demo-fixture", "--export-dir", "macTEM-ui-export"])
            XCTAssertTrue(app.staticTexts["Demo lattice"].firstMatch.waitForExistence(timeout: 30))
        }
        try step("draw a distance") { drawADistanceMark() }
        try step("the Results room lists it") {
            waitFor("workspace.results").click()
            waitFor("results.table", timeout: 30)
            let rows = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'results.row.'"))
            XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 30), "the table has no row for the distance")
        }
        try step("export the results (a plain button now, no menu)") {
            showInspector(waitingFor: "results.export")
            waitFor("results.export").click()
            let bar = waitFor("status.bar", timeout: 30)
            let done = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS[c] 'exported' OR value CONTAINS[c] 'exported'"), object: bar)
            XCTAssertEqual(XCTWaiter().wait(for: [done], timeout: 30), .completed, "status bar: \(bar.label)")
        }
    }
}
