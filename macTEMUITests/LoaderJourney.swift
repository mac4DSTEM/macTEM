//
//  LoaderJourney.swift
//  Open by content: the demo EDX spectrum saved as an `.msa` file is opened through the app's own Open; it is routed to the EDX room (the
//  room is selected without a click), read as a one-pixel spectrum image, and Quantify lists Mg and Si.
//

import XCTest

nonisolated final class LoaderJourney: Journey {
    @MainActor func testAnMSAFileOpensInTheEDXRoom() throws {
        try step("launch and open the .msa") { launch(["--demo-msa-fixture"]) }
        try step("the EDX room is selected by the route") { waitFor("edx.room", timeout: 60) }
        try step("the sidebar highlights EDS alone") {
            // The rooms list's rows: the selected ones, by the room identifier each row carries.
            let selected = app.outlines.firstMatch.cells.matching(NSPredicate(format: "isSelected == true"))
            let names = selected.allElementsBoundByIndex.map { cell in
                cell.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'workspace.'")).firstMatch.identifier
            }
            XCTAssertEqual(names, ["workspace.edx"], "the sidebar highlights \(names)")
        }
        try step("quantify") {
            let verb = waitFor("workspace.primaryAction", timeout: 60)
            let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: verb)
            XCTAssertEqual(XCTWaiter().wait(for: [enabled], timeout: 90), .completed, "Auto ID picked nothing to quantify on the one-pixel spectrum")
            verb.click()
        }
        try step("the composition lists magnesium and silicon") {
            waitFor("edx.compositionTable", timeout: 120)
            waitFor("edx.composition.Mg", timeout: 120)
            waitFor("edx.composition.Si", timeout: 10)
            let mg = Double(waitValue("edx.composition.Mg.wt", timeout: 60) { !$0.isEmpty }) ?? .nan
            XCTAssertTrue(mg > 0 && mg < 100, "Mg \(mg) wt%")
        }
    }
}
