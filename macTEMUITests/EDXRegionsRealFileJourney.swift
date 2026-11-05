//
//  EDXRegionsRealFileJourney.swift
//  The EDS room's per-region composition on the owner's real Velox spectrum images (1339, 1840 and the 1.7 GB 1456): draw regions on
//  the colour mix, Quantify each, read its composition and the region table, export the results. Opt-in like EDXRealFileJourney:
//      TEST_RUNNER_MACTEM_REAL_DATA=1 TEST_RUNNER_MACEM_DATA=<data folder> tools/run-tests.sh ui EDXRegionsRealFileJourney
//  Regions are drawn by the room's keyboard route (XCUITest's clicks and drags do not reach the drawing gestures); the compositions are attached, never asserted (no truth for these files yet).
//

import XCTest

nonisolated final class EDXRegionsRealFileJourney: Journey {
    static let exportName = "macTEM-edx-regions-export"
    static func edx(_ name: String) -> String { Journey.dataFolder + "stem-edx/" + name }

    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MACTEM_REAL_DATA"] == "1",
                          "set MACTEM_REAL_DATA=1 (and TEST_RUNNER_MACTEM_REAL_DATA=1 for xcodebuild) to run on the real files")
    }

    @MainActor func attach(_ name: String, _ string: String) {
        let a = XCTAttachment(string: string); a.name = name; a.lifetime = .keepAlways; add(a)
    }

    @MainActor func text(_ e: XCUIElement) -> String {
        if !e.label.isEmpty { return e.label }
        if let v = e.value as? String, !v.isEmpty { return v }
        return e.staticTexts.firstMatch.label
    }

    @MainActor func mixTile() -> XCUIElement { app.groups.matching(NSPredicate(format: "label BEGINSWITH 'Colour mix map'")).firstMatch }
    @MainActor func resultsHeader() -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Results ·' OR value BEGINSWITH 'Results ·'")).firstMatch
    }

    @MainActor func open(_ file: String) {
        launch(["--open", file, "--export-dir", Self.exportName])
        if !element("edx.room").waitForExistence(timeout: 60) {
            let sidebar = element("workspace.edx")
            if sidebar.waitForExistence(timeout: 300), sidebar.isEnabled { sidebar.click() }
        }
        waitFor("edx.room", timeout: 300)
        XCTAssertTrue(mixTile().waitForExistence(timeout: 600), "the colour mix tile never appeared")
        waitFor("edx.spectrum", timeout: 120)
    }

    @MainActor func showSettings(waitingFor id: String) {
        let picker = waitFor("inspector.tabPicker", timeout: 30)
        let tab = picker.buttons["Settings"]
        if tab.exists, !tab.isSelected { tab.click() }
        waitFor(id, timeout: 20)
    }

    @MainActor func chooseTool(_ index: Int) {
        showSettings(waitingFor: "edx.tool")
        element("edx.tool").radioButtons.element(boundBy: index).click()
    }

    @MainActor func quantify() {
        let verb = waitFor("workspace.primaryAction", timeout: 60)
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: verb)
        XCTAssertEqual(XCTWaiter().wait(for: [enabled], timeout: 300), .completed, "Quantify never became enabled")
        verb.click()
        waitFor("edx.compositionTable", timeout: 300)
        XCTAssertTrue(element("toolbar.display.idle").waitForExistence(timeout: 600), "the room did not come back to idle after Quantify")
    }

    /// Every composition row of the table as "El wt%" text, for the attachment.
    @MainActor func composition() -> String {
        let rows = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'edx.composition.' AND identifier ENDSWITH '.wt'")).allElementsBoundByIndex
        return rows.map { "\($0.identifier.replacingOccurrences(of: "edx.composition.", with: "")): \(text($0))" }.joined(separator: "\n")
    }

    @MainActor func waitHeader(_ suffix: String, timeout: TimeInterval = 30) -> Bool {
        let p = NSPredicate(format: "label == %@ OR value == %@", "Results · \(suffix)", "Results · \(suffix)")
        return app.staticTexts.matching(p).firstMatch.waitForExistence(timeout: timeout)
    }

    /// Chooses the tool (its index in the Tools control), focuses the colour mix with a click and presses Return; then `nudges` shift-arrow
    /// presses move the new region ten pixels each to the lower right, so a second region does not sit on the first.
    @MainActor func drawByKeyboard(tool: Int, nudges: Int) {
        chooseTool(tool)
        app.activate()
        mixTile().click()
        app.typeKey(.return, modifierFlags: [])
        for _ in 0..<nudges {
            app.typeKey(.rightArrow, modifierFlags: .shift)
            app.typeKey(.downArrow, modifierFlags: .shift)
        }
    }

    @MainActor func drive(_ name: String) throws {
        let file = Self.edx(name)
        try XCTSkipUnless(FileManager.default.fileExists(atPath: file), "the real file is not at \(file)")
        try step("open \(name)") { open(file) }
        try step("Quantify the whole map") {
            quantify()
            attach("whole map", composition())
        }
        // XCUITest's clicks and drags do not reach the drawing layer's gestures (EDXJourney: drawn shapes are checked by hand), so the regions
        // are drawn by the room's keyboard route: a click on the colour mix gives it the focus, Return draws the chosen tool's shape in the
        // middle of the scan, the arrows move it (shift: ten pixels).
        try step("Rectangle tool, Return on the colour mix: Region 1") {
            drawByKeyboard(tool: 1, nudges: 0)
            XCTAssertTrue(waitHeader("Region 1"), "after Return the results read \"\(text(resultsHeader()))\"")
        }
        try step("Quantify Region 1") {
            quantify()
            attach("Region 1", composition())
            XCTAssertFalse(composition().isEmpty, "no composition rows for Region 1")
        }
        try step("Ellipse tool, Return, moved off the first: Region 2") {
            drawByKeyboard(tool: 2, nudges: 6)
            XCTAssertTrue(waitHeader("Region 2"), "after Return the results read \"\(text(resultsHeader()))\"")
        }
        try step("Quantify Region 2") {
            quantify()
            attach("Region 2", composition())
        }
        try step("the region table lists both regions") {
            let table = element("edx.regionTable")
            if !table.waitForExistence(timeout: 20) {
                attach("region table", "no edx.regionTable on screen")
                return
            }
            for region in ["Region 1", "Region 2"] {
                XCTAssertTrue(element("edx.regionTable.\(region).pixels").waitForExistence(timeout: 30), "the region table has no row for \(region)")
                attach("\(region) pixels", (element("edx.regionTable.\(region).pixels").value as? String) ?? "?")
            }
        }
        try step("export Results CSV") {
            showSettings(waitingFor: "edx.export.results")
            let button = element("edx.export.results")
            XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: button)], timeout: 120), .completed, "Results CSV stayed disabled")
            button.click()
            let bar = waitFor("status.bar")
            let exported = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in self.text(bar).hasPrefix("Exported ") }, object: nil)
            XCTAssertEqual(XCTWaiter().wait(for: [exported], timeout: 60), .completed, "Results CSV: status line \"\(text(bar))\"")
            attach("status after export", text(bar))
        }
    }

    @MainActor func test01_Regions1339() throws { try drive("SI HAADF 1339 65000 x 20260508.emd") }
    @MainActor func test02_Regions1840() throws { try drive("SI HAADF 1840 23000 x 20260506.emd") }
    @MainActor func test03_Regions1456() throws { try drive("SI HAADF 1456 77000 x 20260420.emd") }
}
