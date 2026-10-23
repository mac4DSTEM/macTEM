//
//  EDXRealFileJourney.swift
//  The EDS room on the owner's real Velox file (docs/design/eds-room-behaviour.md is the spec this drive checks). Opt-in: skipped
//  unless MACTEM_REAL_DATA=1 reaches the runner and the file exists. xcodebuild hands the runner only variables named
//  TEST_RUNNER_*, so run it as
//      TEST_RUNNER_MACTEM_REAL_DATA=1 MACTEM_REAL_DATA=1 tools/run-tests.sh ui EDXRealFileJourney
//  One method per acceptance line, numbered because XCTest runs methods alphabetically; each launches a fresh app on the file.
//  A finding (the room is wrong) fails the step with its words; what XCUITest cannot do says so and skips, it never fakes.
//

import XCTest

nonisolated final class EDXRealFileJourney: Journey {
    static let file1339 = Journey.dataFolder + "stem-edx/SI HAADF 1339 65000 x 20260508.emd"
    static let file1840 = Journey.dataFolder + "stem-edx/SI HAADF 1840 23000 x 20260506.emd"
    static let exportName = "macTEM-real-export"

    override func setUpWithError() throws {
        try super.setUpWithError()
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["MACTEM_REAL_DATA"] == "1", "set MACTEM_REAL_DATA=1 (and TEST_RUNNER_MACTEM_REAL_DATA=1 for xcodebuild) to run on the real file")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: Self.file1339), "the real file is not at \(Self.file1339)")
    }

    // MARK: Helpers

    @MainActor func openReal(_ files: [String] = [file1339], extra: [String] = []) {
        launch(files.flatMap { ["--open", $0] } + ["--export-dir", Self.exportName] + extra)
        if !element("edx.room").waitForExistence(timeout: 20) {
            let sidebar = element("workspace.edx")
            if sidebar.waitForExistence(timeout: 120), sidebar.isEnabled { sidebar.click() }
        }
        waitFor("edx.room", timeout: 120)
    }

    @MainActor func mixTile() -> XCUIElement { app.groups.matching(NSPredicate(format: "label BEGINSWITH 'Colour mix map'")).firstMatch }
    @MainActor func tile(_ name: String) -> XCUIElement { app.groups.matching(NSPredicate(format: "label BEGINSWITH %@", "\(name) map")).firstMatch }
    @MainActor func cell(_ symbol: String) -> XCUIElement { element("periodicTable.\(symbol)") }
    @MainActor func cellState(_ symbol: String) -> String { let c = cell(symbol); return c.exists ? ((c.value as? String) ?? "?") : "absent" }   // Eu and the other lanthanides sit in the folded block: absent
    @MainActor func resultsHeader() -> String {
        text(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Results ·' OR value BEGINSWITH 'Results ·'")).firstMatch)
    }
    @MainActor func text(_ e: XCUIElement) -> String {
        if !e.label.isEmpty { return e.label }
        if let v = e.value as? String, !v.isEmpty { return v }
        return e.staticTexts.firstMatch.label
    }

    /// The maps block and the spectrum are both up (the colour mix tile exists and the spectrum plot does).
    @MainActor func waitForRoomContent() {
        XCTAssertTrue(mixTile().waitForExistence(timeout: 120), "the colour mix tile never appeared")
        waitFor("edx.spectrum", timeout: 120)
        waitFor("workspace.primaryAction", timeout: 60)
    }

    @MainActor func attach(_ name: String, _ string: String) {
        let a = XCTAttachment(string: string); a.name = name; a.lifetime = .keepAlways; add(a)
    }

    /// Real mouse events posted from the runner (XCUITest's own drag does not reach SwiftUI's DragGesture), with tools/drive/drag.sh's
    /// guard: nothing is sent unless macTEM is the foreground app and both points lie inside its window. (drag.sh itself cannot run from
    /// the runner: System Events refuses the sandboxed runner, "Application isn't running".) Returns false when nothing was sent.
    @MainActor func realDrag(from a: CGPoint, to b: CGPoint) -> Bool {
        guard app.state == .runningForeground else { attach("drag refused", "macTEM is not frontmost"); return false }
        let w = app.windows.firstMatch.frame
        guard w.contains(a), w.contains(b) else { attach("drag refused", "a point is outside the window \(w)"); return false }
        func post(_ type: CGEventType, _ p: CGPoint) { CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap) }
        post(.mouseMoved, a); usleep(150_000)
        post(.leftMouseDown, a); usleep(100_000)
        for i in 1...20 {
            let t = Double(i) / 20
            post(.leftMouseDragged, CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)); usleep(20_000)
        }
        post(.leftMouseUp, b)
        return true
    }

    /// A real scroll wheel over a point (guarded like the drag).
    @MainActor func realScroll(at p: CGPoint, lines: Int32) -> Bool {
        guard app.state == .runningForeground, app.windows.firstMatch.frame.contains(p) else { return false }
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
        usleep(150_000)
        for _ in 0..<5 {
            CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: lines, wheel2: 0, wheel3: 0)?.post(tap: .cghidEventTap)
            usleep(40_000)
        }
        return true
    }

    @MainActor func point(in e: XCUIElement, _ dx: Double, _ dy: Double) -> CGPoint {
        CGPoint(x: e.frame.minX + e.frame.width * dx, y: e.frame.minY + e.frame.height * dy)
    }

    /// The inspector's Settings tab (the window restores the last tab a launch left, so a run after the Info test starts on Info).
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

    /// Runs Quantify and waits for the composition table.
    @MainActor func quantify() {
        let verb = waitFor("workspace.primaryAction", timeout: 60)
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: verb)
        XCTAssertEqual(XCTWaiter().wait(for: [enabled], timeout: 120), .completed, "Quantify never became enabled")
        verb.click()
        waitFor("edx.compositionTable", timeout: 180)
        // The table appears while the maps still run: the room is busy (the toolbar shows the running work, the exports that need
        // the fit are disabled) until the display is idle again (seen 2026-10-23: Results CSV clicked while disabled).
        XCTAssertTrue(element("toolbar.display.idle").waitForExistence(timeout: 180), "the room did not come back to idle after Quantify")
    }

    // MARK: 1. Opens

    @MainActor func test01_OpensWithMapsSpectrumAndBeamEnergy() throws {
        try step("launch on the real file; the EDS room") { openReal() }
        try step("maps block and spectrum are shown") { waitForRoomContent() }
        try step("the Info tab shows the beam energy") {
            let picker = waitFor("inspector.tabPicker", timeout: 20)
            let info = picker.radioButtons["Info"].exists ? picker.radioButtons["Info"] : picker.buttons["Info"]
            XCTAssertTrue(info.waitForExistence(timeout: 10), "no Info tab")
            info.click()
            let beam = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'keV' OR value CONTAINS 'keV'")).firstMatch
            XCTAssertTrue(beam.waitForExistence(timeout: 20), "the Info tab names no beam energy in keV")
            attach("beam row", text(beam))
            picker.buttons["Settings"].click()   // the window restores the last tab: leave it on Settings
        }
    }

    // MARK: 2. Auto ID from nothing

    @MainActor func test02_AutoIDWithNothingSelected() throws {
        try step("launch on the real file") { openReal(); waitForRoomContent() }
        try step("deselect every selected cell") {
            showSettings(waitingFor: "periodicTable.Al")
            let cells = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'periodicTable.'")).allElementsBoundByIndex
            for c in cells {
                var tries = 0
                while let v = c.value as? String, v == "mapped" || v == "fit only" || v.hasPrefix("proposed"), tries < 3 { c.click(); tries += 1 }
            }
            for s in ["Mg", "Al", "Si"] { XCTAssertNotEqual(cellState(s), "mapped", "\(s) is still selected after deselecting") }
        }
        var mg = "?"
        try step("Auto ID") {
            element("edx.autoID").click()
            let al = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in self.cellState("Al") == "mapped" }, object: nil)
            XCTAssertEqual(XCTWaiter().wait(for: [al], timeout: 120), .completed, "Auto ID never selected Al; it is \(cellState("Al"))")
            XCTAssertEqual(cellState("Si"), "mapped")
            mg = cellState("Mg")
            for s in ["Ba", "Eu", "Dy", "Hf", "Os"] {
                let v = cellState(s)
                XCTAssertFalse(v == "mapped" || v == "fit only" || v.hasPrefix("proposed"), "\(s) was picked or outlined: \(v)")
            }
        }
        try step("Mg state is \(mg)") {}
    }

    // MARK: 3. Role menu

    @MainActor func test03_RightClickAnElementOpensTheRoleMenu() throws {
        try step("launch") { openReal(); waitForRoomContent(); showSettings(waitingFor: "periodicTable.Al") }
        try step("right-click Al: the role menu") {
            cell("Al").rightClick()
            XCTAssertTrue(app.descendants(matching: .any)["Fit only"].waitForExistence(timeout: 10), "no role menu (Quantify / Fit only / Off)")
        }
        try step("Escape closes it") {
            app.typeKey(.escape, modifierFlags: [])
            XCTAssertFalse(app.descendants(matching: .any)["Fit only"].waitForExistence(timeout: 2), "the menu is still open")
        }
    }

    // MARK: 4. Draw, edit and delete a region

    @MainActor func test04_RectangleRegionDragAndDelete() throws {
        try step("launch") { openReal(); waitForRoomContent() }
        let mix = mixTile()
        XCTAssertEqual(resultsHeader().contains("Whole map"), true, "before drawing the results read: \(resultsHeader())")
        try step("Rectangle tool, drag on the colour mix") {
            chooseTool(1)
            if !realDrag(from: point(in: mix, 0.3, 0.3), to: point(in: mix, 0.6, 0.6)) {
                // Not faked: the synthesized drag does not reach the DragGesture.
                throw XCTSkip("the drag was refused by its guard (see the attachment)")
            }
            _ = app.staticTexts.matching(NSPredicate(format: "label == 'Results · Region 1' OR value == 'Results · Region 1'")).firstMatch.waitForExistence(timeout: 15)
        }
        // 2026-10-22: CGEvents posted from the runner left the room unchanged (Rectangle tool selected, header still Whole map). Whether the
        // events do not reach the app or the room ignores them is not decided from here, so this skips instead of calling it a finding.
        try XCTSkipUnless(resultsHeader().contains("Region 1"), "a posted drag with the Rectangle tool drew nothing (header \"\(resultsHeader())\"); draw by hand")
        try step("drag a handle (Select tool)") {
            chooseTool(0)
            XCTAssertTrue(realDrag(from: point(in: mix, 0.6, 0.6), to: point(in: mix, 0.7, 0.7)))
        }
        try step("Delete removes it; the header returns to Whole map") {
            app.typeKey(.delete, modifierFlags: [])
            let whole = app.staticTexts.matching(NSPredicate(format: "label == 'Results · Whole map' OR value == 'Results · Whole map'")).firstMatch
            XCTAssertTrue(whole.waitForExistence(timeout: 20), "the header reads \"\(resultsHeader())\" after Delete")
        }
    }

    // MARK: 5. Quantify

    @MainActor func test05_QuantifyListsMgAlSiWithUncertainties() throws {
        try step("launch") { openReal(); waitForRoomContent() }
        var mgListed = false
        try step("Quantify") {
            quantify()
            waitFor("edx.composition.Al", timeout: 120); waitFor("edx.composition.Si", timeout: 10)
            mgListed = element("edx.composition.Mg").waitForExistence(timeout: 5)
            let pm = app.staticTexts.matching(NSPredicate(format: "label CONTAINS '±' OR value CONTAINS '±'")).firstMatch
            XCTAssertTrue(pm.waitForExistence(timeout: 10), "no ± value in the table")
            waitFor("edx.notes", timeout: 10)   // the fit footer line
        }
        try step("Mg listed: \(mgListed)") {}
    }

    // MARK: 6. wt% and at% maps carry the filtered tag; Filter Off removes it

    @MainActor func test06_FilteredTagAndFilterOff() throws {
        try step("launch, Quantify") { openReal(); waitForRoomContent(); quantify() }
        try step("wt% maps carry the filtered tag") {
            showSettings(waitingFor: "edx.mapMode")
            let modes = element("edx.mapMode").radioButtons
            modes["wt%"].exists ? modes["wt%"].click() : modes.element(boundBy: 1).click()
            XCTAssertTrue(element("maps.filteredTag").waitForExistence(timeout: 120), "no filtered tag on the wt% tiles")
        }
        try step("at% maps carry it too") {
            let modes = element("edx.mapMode").radioButtons
            modes["at%"].exists ? modes["at%"].click() : modes.element(boundBy: 2).click()
            XCTAssertTrue(element("maps.filteredTag").waitForExistence(timeout: 120))
        }
        try step("Filter Off: the tag goes") {
            element("edx.mapFilter").click()
            app.menuItems["Off"].click()
            let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element("maps.filteredTag"))
            XCTAssertEqual(XCTWaiter().wait(for: [gone], timeout: 30), .completed, "the filtered tag is still shown with Filter Off")
        }
    }

    // MARK: 7. Mix ring and the display popover

    @MainActor func test07_ElementTileTogglesMixAndScaleBarOpensPopover() throws {
        try step("launch, Quantify") { openReal(); waitForRoomContent(); quantify() }
        try step("a click on an element tile toggles the mix") {
            let before = mixTile().label
            let al = tile("Al")
            XCTAssertTrue(al.waitForExistence(timeout: 60))
            al.click()
            let changed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label != %@", before), object: mixTile())
            XCTAssertEqual(XCTWaiter().wait(for: [changed], timeout: 20), .completed, "the mix label stayed \"\(before)\"")
        }
        try step("the scale bar opens histogram and Gamma") {
            element("maps.scaleBar.Si").click()
            XCTAssertTrue(app.sliders.matching(NSPredicate(format: "label CONTAINS[c] 'gamma'")).firstMatch.waitForExistence(timeout: 10)
                          || app.staticTexts["Gamma"].waitForExistence(timeout: 5), "no Gamma control in the popover")
            XCTAssertTrue(element("histogram.min").exists || app.otherElements["Intensity histogram"].exists, "no histogram in the popover")
        }
        try step("Escape closes the popover") { app.typeKey(.escape, modifierFlags: []) }
    }

    // MARK: 8. Zoom and reset

    @MainActor func test08_ScrollZoomsAndDoubleClickResets() throws {
        try step("launch") { openReal(); waitForRoomContent() }
        let bar = element("maps.scaleBar.Colour mix")
        var before = "", zoomed = ""
        try step("scroll over the colour mix") {
            XCTAssertTrue(bar.waitForExistence(timeout: 30))
            before = text(bar)
            if !realScroll(at: point(in: mixTile(), 0.5, 0.5), lines: 5) { throw XCTSkip("scroll refused by its guard") }
            _ = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in self.text(bar) != before }, object: nil)], timeout: 10)
            zoomed = text(bar)
        }
        try XCTSkipUnless(zoomed != before, "a posted scroll wheel left the colour mix's scale bar at \"\(before)\" (2026-10-22): not decidable from the runner; scroll by hand")
        try step("double-click resets: \(before) -> \(zoomed) -> back") {
            mixTile().doubleClick()
            let back = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in self.text(bar) == before }, object: nil)
            XCTAssertEqual(XCTWaiter().wait(for: [back], timeout: 10), .completed, "the scale bar reads \"\(self.text(bar))\", not \"\(before)\"")
        }
    }

    // MARK: 9. Hover reads a pixel value

    @MainActor func test09_HoverReadsAPixelValue() throws {
        try step("launch") { openReal(); waitForRoomContent() }
        try step("hover an element tile") {
            let t = tile("HAADF")
            XCTAssertTrue(t.waitForExistence(timeout: 30))
            t.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).hover()
            t.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.5)).hover()
            let bar = waitFor("status.bar")
            let read = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in self.text(bar).rangeOfCharacter(from: .decimalDigits) != nil && !self.text(bar).hasPrefix("Opened") }, object: nil)
            XCTAssertEqual(XCTWaiter().wait(for: [read], timeout: 10), .completed, "status line: \"\(text(bar))\"")
            attach("status line", text(bar))
        }
    }

    // MARK: 10. Exports

    /// The EDS room writes into --export-dir as the other rooms do (fixed 2026-10-23, found by this journey): the status line says "Exported <name>".
    @MainActor func test10_ExportsWriteFiles() throws {
        try step("launch, Quantify") { openReal(); waitForRoomContent(); quantify() }
        let bar = element("status.bar")
        for (id, name) in [("edx.export.results", "Results CSV"), ("edx.export.mapsPNG", "Maps")] {
            try step("press \(name)") {
                showSettings(waitingFor: id)
                let button = element(id)
                XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: button)], timeout: 60), .completed, "\(name) stayed disabled")
                button.click()
                let exported = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in self.text(bar).hasPrefix("Exported ") }, object: nil)
                XCTAssertEqual(XCTWaiter().wait(for: [exported], timeout: 30), .completed, "\(name): status line \"\(text(bar))\"")
                attach("status after \(name)", text(bar))
            }
        }
    }

    // MARK: 11. Open Files

    @MainActor func test11_SwitchBetweenTwoOpenFiles() throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: Self.file1840), "the second file is missing")
        try step("launch on two files") { openReal([Self.file1339, Self.file1840]); waitForRoomContent() }
        let display = element("toolbar.display.idle")
        var first = ""
        try step("the toolbar names a file") {
            XCTAssertTrue(display.waitForExistence(timeout: 120))
            first = text(display)
            attach("display", first)
        }
        try step("click the other row") {
            let list = waitFor("sidebar.openItems", timeout: 60)
            let target = first.contains("1840") ? "1339" : "1840"
            let row = list.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", target)).firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 120), "no open-items row for \(target)")
            row.click()
            // The other file is read again on the click (a spectrum image of this size takes tens of seconds), then the display is idle on it.
            _ = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in display.exists && self.text(display).contains(target) }, object: nil)], timeout: 240)
            attach("display after the click", text(display))
        }
        XCTAssertTrue(text(display).contains(first.contains("1840") ? "1339" : "1840"), "the room's file did not change: \"\(text(display))\"")
    }
}
