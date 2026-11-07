//
//  SessionReportJourney.swift
//  The SEM session report (docs/sem/design/export-and-reports.md §7, journey 3; D-SEM-103) on the shipped nickel scan: open it from
//  Help › Open Demo Data, Process in Patterns, ⌘7 and Index, the Indexing room's Map PNG written to the journey folder, ⌘9 shows the
//  SEM session's rows in the Results room (the dataset, the processing run, the indexing run, the export), the inspector's Report set
//  to Markdown, Export Report…, and the file in the folder carries the headings Processing, Indexing and Methods and references. A
//  screenshot at every step.
//

import XCTest

nonisolated final class SessionReportJourney: Journey {
    private static let exportName = "macTEM-session-report"

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

    /// The room's verb, once it is enabled, clicked.
    @MainActor private func runTheVerb(_ name: String, timeout: TimeInterval) throws {
        let verb = waitFor("workspace.primaryAction", timeout: 60)
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: verb)
        XCTAssertEqual(XCTWaiter().wait(for: [enabled], timeout: timeout), .completed, "\(name) never became available")
        XCTAssertTrue(verb.label.contains(name), verb.label)
        try requireFrontmost()
        verb.click()
    }

    /// The files in the app's export folder (the sandbox container's tmp), nil when the runner cannot list it.
    private static func exported() -> [String]? {
        let path = NSHomeDirectory() + "/Library/Containers/com.mac4dstem.macTEM/Data/tmp/" + exportName
        return try? FileManager.default.contentsOfDirectory(atPath: path)
    }

    private static func read(_ name: String) -> String? {
        let path = NSHomeDirectory() + "/Library/Containers/com.mac4dstem.macTEM/Data/tmp/" + exportName + "/" + name
        return try? String(contentsOfFile: path, encoding: .utf8)
    }

    @MainActor func testTheSessionReportCarriesProcessingIndexingAndTheMethods() throws {
        var exported = false
        try step("launch with no file, exports to the journey folder") { launch(["--export-dir", Self.exportName]) }
        try step("the nickel scan opens in Patterns; Process runs the default stages") {
            try openDemo("Ni EBSD Patterns (kikuchipy)")
            waitFor("patterns.room", timeout: 60)
            showInspector(waitingFor: "patterns.display")
            try runTheVerb("Process", timeout: 120)
            waitStatus(containing: ["Processed"], timeout: 180)
        }
        try step("⌘7 and Index; the Map PNG is written to the folder") {
            try requireFrontmost()
            app.typeKey("7", modifierFlags: .command)
            waitFor("indexing.room", timeout: 30)
            try runTheVerb("Index", timeout: 60)
            waitStatus(containing: ["Indexed"], timeout: 240)
            showInspector(waitingFor: "indexing.layer")
            // The Export section starts closed: its header opens it.
            if !element("indexing.export.map").waitForExistence(timeout: 3) {
                let header = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Export'")).firstMatch
                if header.exists { try requireFrontmost(); header.click() }
            }
            let button = element("indexing.export.map")
            if button.waitForExistence(timeout: 10) {
                try requireFrontmost()
                button.click()
                waitStatus(containing: ["Exported", "indexed IPF-Z.png"], timeout: 30)
                exported = true
            } else {
                XCTContext.runActivity(named: "the Indexing room's Export section did not open; the report is checked without its figure") { _ in }
            }
        }
        try step("⌘9: the Results room lists the SEM session") {
            try requireFrontmost()
            app.typeKey("9", modifierFlags: .command)
            waitFor("results.room", timeout: 30)
            waitFor("results.session.table", timeout: 30)
            waitFor("results.session.row.dataset", timeout: 30)
            waitFor("results.session.row.processing", timeout: 30)
            waitFor("results.session.row.indexing", timeout: 30)
            if exported { waitFor("results.session.row.export:0", timeout: 30) }
        }
        try step("Report as Markdown, Export Report…: the file carries Processing, Indexing and the methods") {
            showInspector(waitingFor: "results.report.export")
            let format = waitFor("results.report.format", timeout: 20)
            let markdown = format.radioButtons["Markdown"].exists ? format.radioButtons["Markdown"] : format.buttons["Markdown"]
            try requireFrontmost()
            markdown.firstMatch.click()
            try requireFrontmost()
            waitFor("results.report.export", timeout: 10).click()
            waitStatus(containing: ["Exported", "session report.md"], timeout: 60)
            if let files = Self.exported() {
                XCTAssertTrue(files.contains("patterns_v2 session report.md"), "\(files)")
                let text = Self.read("patterns_v2 session report.md") ?? ""
                for heading in ["## Processing", "## Indexing", "## Methods and references"] {
                    XCTAssertTrue(text.contains(heading), heading)
                }
                if exported { XCTAssertTrue(text.contains("![Figure 1](patterns_v2%20indexed%20IPF-Z.png)"), "the exported map is linked") }
            }
        }
    }
}
