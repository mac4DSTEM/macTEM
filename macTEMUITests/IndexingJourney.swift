//
//  IndexingJourney.swift
//  The Indexing room on the shipped nickel scan (docs/sem/design/indexing-room.md §9, steps 1 to 4): open the scan from Help › Open
//  Demo Data, EBSD › Indexing, Index (enabled with the file's phase in the list), the map fills (the empty sentence goes, the header counts the
//  indexed points), hovering it puts the three Euler angles and the CI in the status line (figure F8 on screen), a Results row picks its
//  pattern and the detected bands are drawn over it, a click on the map picks its point and → steps it at once (D-SEM-110: the click takes
//  the keyboard back from the table); then Method · Dictionary with the shipped Ni master pattern: the dictionary's size
//  at 4°, Index, the map fills again, the status line carries the NCC score and the Best match pane the picked point's simulated
//  pattern (figure F9 on screen); then Display › Compare (§9 step 4, D-SEM-97): Hough against the file's own indexing side by side,
//  the disorientation histogram's median under 1°, hovering a compared map puts both solutions and their disorientation in the status
//  line; B · Dictionary compares the two runs (the 4° dictionary's grid reads above 1°). A screenshot at every step.
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

    /// The median in Compare's footer ("… · median 0.44° · …", either decimal mark); nil without one.
    private static func median(_ footer: String) -> Double? {
        guard let range = footer.range(of: "median ") else { return nil }
        let number = footer[range.upperBound...].prefix { $0 != "°" }
        return Double(number.replacingOccurrences(of: ",", with: "."))
    }

    /// The row and column a pattern header names ("Pattern · row 12 · col 40 · as indexed"); nil when it names none.
    private static func position(in text: String) -> (row: Int, column: Int)? {
        guard let range = text.range(of: #"row \d+ · col \d+"#, options: .regularExpression) else { return nil }
        let numbers = text[range].split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        return numbers.count == 2 ? (numbers[0], numbers[1]) : nil
    }

    @MainActor private func waitWords(_ id: String, timeout: TimeInterval, _ check: @escaping (String) -> Bool) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in check(self.words(id)) }, object: nil)
        XCTAssertEqual(XCTWaiter().wait(for: [expectation], timeout: timeout), .completed, "\(id) read \"\(words(id))\"")
    }

    @MainActor func testIndexTheDemoScanAndReadTheSolution() throws {
        try step("launch with no file") { launch() }
        try step("the nickel scan opens in EBSD › Patterns; the Indexing part enters Indexing before any run") {
            try openDemo("Ni EBSD Patterns (kikuchipy)")
            waitFor("patterns.room", timeout: 60)
            try requireFrontmost()
            waitFor("workspace.indexing", timeout: 30).click()
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
        try step("a Results row picks its pattern; the detected bands are drawn over it") {
            let table = waitFor("indexing.results", timeout: 30)
            let row = table.tableRows.element(boundBy: 10)
            XCTAssertTrue(row.waitForExistence(timeout: 30), "the Results table has no eleventh row")
            try requireFrontmost()
            row.click()
            waitWords("indexing.pattern.title", timeout: 30) { $0.contains("row 0 · col 10") }
            waitFor("indexing.pattern.overlay", timeout: 30)
            waitWords("indexing.bands.title", timeout: 30) { $0.contains("matched") }
        }
        try step("a click on the map picks its point and takes the arrows back from the Results table") {
            try requireFrontmost()
            waitFor("indexing.map", timeout: 10).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
            waitWords("indexing.pattern.title", timeout: 30) { !$0.contains("row 0 · col 10") && Self.position(in: $0) != nil }
            let title = words("indexing.pattern.title")
            let picked = try XCTUnwrap(Self.position(in: title), title)
            // ↓, not →: a table that kept the keyboard would move its selection to the next row in scan order (one column on), and
            // ignores → (which reaches the room through the focus chain either way).
            app.typeKey(.downArrow, modifierFlags: [])
            waitWords("indexing.pattern.title", timeout: 30) { $0.contains("row \(picked.row + 1) · col \(picked.column) ·") }
        }
        try step("Method · Dictionary names the dictionary's size against the shipped master pattern") {
            showInspector(waitingFor: "indexing.method")
            let method = waitFor("indexing.method", timeout: 10)
            try requireFrontmost()
            (method.radioButtons["Dictionary"].exists ? method.radioButtons["Dictionary"] : method.buttons["Dictionary"]).click()
            waitFor("indexing.dictionary.master.ni", timeout: 30)
            waitWords("indexing.dictionary.summary.ni", timeout: 60) { $0.contains("401 × 401") }
            waitWords("indexing.dictionary.size", timeout: 120) { $0.contains("patterns at 4°") }
            let verb = waitFor("workspace.primaryAction", timeout: 10)
            let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: verb)
            XCTAssertEqual(XCTWaiter().wait(for: [enabled], timeout: 60), .completed, "Index never became available with Dictionary")
        }
        try step("Index with Dictionary fills the map; the status line carries the NCC and the best match shows (figure F9)") {
            try requireFrontmost()
            waitFor("workspace.primaryAction", timeout: 10).click()
            waitWords("indexing.results.title", timeout: 60) { $0.contains("Dictionary") }
            waitWords("indexing.map.count", timeout: 900) { $0.contains("indexed") && !$0.contains("reached") && !$0.contains("stopped") }
            waitFor("indexing.map", timeout: 10).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).hover()
            let line = waitStatus(containing: ["φ₁", "Φ", "φ₂", "NCC"], timeout: 30)
            XCTAssertTrue(line.contains("ni"), line)
            waitWords("indexing.bestMatch.title", timeout: 60) { $0.contains("NCC") && $0.contains("simulation") }
        }
        try step("Display › Compare: Hough against the file's indexing on one zoom, the median under 1°") {
            showInspector(waitingFor: "indexing.showCompare")
            let compare = waitFor("indexing.showCompare", timeout: 10)
            try requireFrontmost()
            compare.click()
            waitFor("indexing.compare", timeout: 30)
            waitWords("indexing.compareA", timeout: 10) { $0.contains("Hough") }
            waitWords("indexing.compareB", timeout: 10) { $0.contains("File") }
            waitWords("indexing.compare.footer", timeout: 120) { Self.median($0) != nil }
            let footer = words("indexing.compare.footer")
            XCTAssertLessThan(try XCTUnwrap(Self.median(footer), footer), 1, footer)
            waitFor("indexing.compare.mapA", timeout: 10).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).hover()
            let line = waitStatus(containing: ["Hough", "File", "disorientation"], timeout: 30)
            XCTAssertTrue(line.contains("°"), line)
        }
        try step("B · Dictionary compares the two runs; the median reads the dictionary's grid") {
            let b = waitFor("indexing.compareB", timeout: 10)
            try requireFrontmost()
            b.click()
            let item = app.menuItems["Dictionary"].firstMatch
            XCTAssertTrue(item.waitForExistence(timeout: 10), "no Dictionary in B")
            item.click()
            waitWords("indexing.compare.histogram.title", timeout: 30) { $0.contains("Hough against Dictionary") }
            waitWords("indexing.compare.footer", timeout: 120) { (Self.median($0) ?? 0) > 1 }
        }
    }
}
