//
//  IndexingJourney.swift
//  The Indexing room on the shipped nickel scan (docs/sem/design/indexing-room.md §9, steps 1 to 3; the dictionary steps wait for
//  dictionary indexing): open the scan from Help › Open Demo Data, ⌘7, Index (enabled with the file's phase in the list), the map
//  fills (the empty sentence goes, the header counts the indexed points), hovering it puts the three Euler angles and the CI in the
//  status line (figure F8 on screen), a Results row pins its pattern and the detected bands are drawn over it. A screenshot at every
//  step.
//

import XCTest

nonisolated final class IndexingJourney: Journey {
    /// Help › Open Demo Data › `title` (DemoDataJourney's walk).
    @MainActor private func openDemo(_ title: String) throws {
        try requireFrontmost()
        let help = app.menuBars.menuBarItems["Help"].firstMatch
        XCTAssertTrue(help.waitForExistence(timeout: 10), "no Help menu")
        help.click()
        let submenu = app.menuItems["Open Demo Data"].firstMatch
        XCTAssertTrue(submenu.waitForExistence(timeout: 10), "no Open Demo Data in the Help menu")
        try requireFrontmost()
        submenu.hover()
        let item = app.menuItems[title].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 10), "no \(title) in Open Demo Data")
        try requireFrontmost()
        item.click()
    }

    /// An element's words, label and value.
    @MainActor private func words(_ id: String) -> String {
        let e = waitFor(id, timeout: 30)
        return "\(e.label) \((e.value as? String) ?? "")"
    }

    @MainActor private func waitWords(_ id: String, timeout: TimeInterval, _ check: @escaping (String) -> Bool) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in check(self.words(id)) }, object: nil)
        XCTAssertEqual(XCTWaiter().wait(for: [expectation], timeout: timeout), .completed, "\(id) read \"\(words(id))\"")
    }

    @MainActor func testIndexTheDemoScanAndReadTheSolution() throws {
        try step("launch with no file") { launch() }
        try step("the nickel scan opens in Patterns; ⌘7 enters Indexing before any run") {
            try openDemo("Ni EBSD Patterns (kikuchipy)")
            waitFor("patterns.room", timeout: 60)
            try requireFrontmost()
            app.typeKey("7", modifierFlags: .command)
            waitFor("indexing.room", timeout: 30)
            waitFor("indexing.map", timeout: 30)
            waitFor("indexing.map.empty", timeout: 30)
        }
        try step("Index is enabled with the file's phase in the Phases list") {
            showInspector(waitingFor: "indexing.layer")
            waitFor("indexing.phase.ni", timeout: 30)
            let verb = waitFor("workspace.primaryAction", timeout: 60)
            let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: verb)
            XCTAssertEqual(XCTWaiter().wait(for: [enabled], timeout: 60), .completed, "Index never became available on the demo scan")
            XCTAssertTrue(verb.label.contains("Index"), verb.label)
        }
        try step("Index fills the map row by row; the header counts the indexed points") {
            try requireFrontmost()
            waitFor("workspace.primaryAction", timeout: 10).click()
            waitGone("indexing.map.empty", timeout: 30)
            waitWords("indexing.map.count", timeout: 180) { $0.contains("indexed") && !$0.contains("reached") && !$0.contains("stopped") }
            waitWords("indexing.map.title", timeout: 10) { $0.contains("IPF-Z") }
        }
        try step("hovering the map puts the solution in the status line (figure F8)") {
            waitFor("indexing.map", timeout: 10).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).hover()
            let line = waitStatus(containing: ["φ₁", "Φ", "φ₂", "CI", "bands"], timeout: 30)
            XCTAssertTrue(line.contains("ni"), line)
        }
        try step("a Results row pins its pattern; the detected bands are drawn over it") {
            let table = waitFor("indexing.results", timeout: 30)
            let row = table.tableRows.element(boundBy: 10)
            XCTAssertTrue(row.waitForExistence(timeout: 30), "the Results table has no eleventh row")
            try requireFrontmost()
            row.click()
            waitWords("indexing.pattern.title", timeout: 30) { $0.contains("row 0 · col 10") && $0.contains("pinned") }
            waitFor("indexing.pattern.overlay", timeout: 30)
            waitWords("indexing.bands.title", timeout: 30) { $0.contains("matched") }
        }
    }
}
