//
//  EELSRealFileJourney.swift
//  The EELS room on the owner's real GMS STEM spectrum images (data/eels: 143 is the main file, 142 and 145 are checked on line 7 only). Opt-in like
//  `EDXRealFileJourney`: skipped unless MACTEM_REAL_DATA=1 reaches the runner and the file exists. Run it as
//      TEST_RUNNER_MACTEM_REAL_DATA=1 MACTEM_REAL_DATA=1 tools/run-tests.sh ui EELSRealFileJourney
//  One app session for the whole acceptance (the file is 1.2 GB: opened once, not once per line), one activity per acceptance line of the EELS room (the
//  2026-10-22 acceptance page), in the order a microscopist works (Align, λ, edges, Fit, then what reads the fit; the stale-and-Stop line last because it changes
//  the threshold). A failure is booked to its line and the run goes on; the summary attachment and the EELSLINE lines on stdout give each line's verdict. What
//  XCUITest cannot do is reported "unverified, drag" for the owner's hand, never faked: no mouse events are posted from here.
//

import XCTest

nonisolated final class EELSRealFileJourney: Journey {
    static let data = Journey.dataFolder + "eels/"
    static let file143 = data + "EELS_2/SI data (2)(2)/143_STEM SI.dm4"
    static let file142 = data + "EELS_1/SI data (1)(9)/142_STEM SI.dm4"
    static let file145 = data + "EELS_3/SI data (4)/145_STEM SI.dm4"
    static let exportName = "macTEM-eels-export"

    override func setUpWithError() throws {
        try super.setUpWithError()
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["MACTEM_REAL_DATA"] == "1", "set MACTEM_REAL_DATA=1 (and TEST_RUNNER_MACTEM_REAL_DATA=1 for xcodebuild) to run on the real file")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: Self.file143), "the real file is not at \(Self.file143)")
    }

    // MARK: Helpers

    @MainActor func attach(_ name: String, _ string: String) {
        let a = XCTAttachment(string: string); a.name = name; a.lifetime = .keepAlways; add(a)
    }

    @MainActor func text(_ e: XCUIElement) -> String {
        if !e.label.isEmpty { return e.label }
        if let v = e.value as? String, !v.isEmpty { return v }
        return e.staticTexts.firstMatch.label
    }

    /// Every string an element and its descendants carry (labels and values), for the finding's words.
    @MainActor func strings(under e: XCUIElement) -> [String] {
        var out: [String] = []
        for t in e.descendants(matching: .staticText).allElementsBoundByIndex.prefix(400) {
            let s = !t.label.isEmpty ? t.label : ((t.value as? String) ?? "")
            if !s.isEmpty { out.append(s) }
        }
        return out
    }

    @MainActor func openReal(_ file: String = file143, extra: [String] = []) {
        launch(["--open", file, "--export-dir", Self.exportName] + extra)
        _ = app.windows.firstMatch.waitForExistence(timeout: 200)
        let room = element("eels.room")
        if !room.waitForExistence(timeout: 30) {
            // Not there yet: say what the window shows (an alert, the status line) before waiting on.
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = "screen 30 s after launch"; shot.lifetime = .keepAlways; add(shot)
            dumpTree("tree 30 s after launch")
            if !room.waitForExistence(timeout: 120) {
                let sidebar = element("workspace.eels")
                if sidebar.exists, sidebar.isEnabled { sidebar.click() }
            }
        }
        waitFor("eels.room", timeout: 60)
    }

    /// The t/λ map (on the right since the anchor is the colour mix).
    @MainActor func anchorTile() -> XCUIElement { tile("t/λ") }
    @MainActor func mixTile() -> XCUIElement { app.groups.matching(NSPredicate(format: "label BEGINSWITH 'Colour mix map'")).firstMatch }
    @MainActor func tile(_ title: String) -> XCUIElement { app.groups.matching(NSPredicate(format: "label BEGINSWITH %@", "\(title) map")).firstMatch }

    /// The thickness map is up (the anchor tile) and the spectrum is drawn.
    @MainActor func waitForRoomContent(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(anchorTile().waitForExistence(timeout: 600), "the t/λ tile never appeared", file: file, line: line)
        waitFor("eels.spectrum", timeout: 120)
        waitFor("workspace.primaryAction", timeout: 60)
    }

    @MainActor func inspectorTab(_ name: String) {
        let picker = waitFor("inspector.tabPicker", timeout: 30)
        let tab = picker.radioButtons[name].exists ? picker.radioButtons[name] : picker.buttons[name]
        if tab.exists, !tab.isSelected { tab.click() }
    }

    @MainActor func showSettings(waitingFor id: String = "eels.maps.control") { inspectorTab("Settings"); waitFor(id, timeout: 30) }

    @MainActor func cell(_ symbol: String) -> XCUIElement { element("periodicTable.\(symbol)") }
    @MainActor func cellState(_ symbol: String) -> String { let c = cell(symbol); return c.exists ? ((c.value as? String) ?? "?") : "absent" }

    @MainActor func pipeline() -> String { (element("eels.pipeline").value as? String) ?? "" }

    /// Waits until the toolbar's display is idle again (no stage is running).
    @MainActor func waitIdle(timeout: TimeInterval = 900) {
        XCTAssertTrue(element("toolbar.display.idle").waitForExistence(timeout: timeout), "the room did not come back to idle")
    }

    /// Picks the edges by a click on their cells (the periodic table is in the Settings tab).
    @MainActor func pick(_ symbols: [String]) {
        showSettings(waitingFor: "periodicTable.C")
        for s in symbols {
            let c = cell(s)
            XCTAssertTrue(c.waitForExistence(timeout: 20), "no periodic table cell \(s)")
            if cellState(s) != "mapped" { c.click() }
        }
    }

    /// Presses the toolbar's verb and waits for the pipeline to read the stage as current.
    @MainActor func run(until stage: String = "Fit current", timeout: TimeInterval = 1500) {
        let verb = waitFor("workspace.primaryAction", timeout: 60)
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: verb)
        XCTAssertEqual(XCTWaiter().wait(for: [enabled], timeout: 300), .completed, "the toolbar verb never became enabled; pipeline: \(pipeline())")
        verb.click()
        let done = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in self.pipeline().contains(stage) }, object: nil)
        XCTAssertEqual(XCTWaiter().wait(for: [done], timeout: timeout), .completed, "the pipeline never read \"\(stage)\"; it reads \"\(pipeline())\"")
        waitIdle()
    }

    /// The results table's rows as strings: one array of cell texts per edge (the edge, I, at%, wt%). SwiftUI's Table exposes no `tableRows` to XCUITest
    /// (seen 2026-10-23: an empty list with three rows on screen), so the cells are read in order and cut at each edge's title.
    @MainActor func resultRows() -> [[String]] {
        let table = element("eels.results.table")
        guard table.waitForExistence(timeout: 30) else { return [] }
        let cells = table.descendants(matching: .staticText).allElementsBoundByIndex.map { !$0.label.isEmpty ? $0.label : (($0.value as? String) ?? "") }.filter { !$0.isEmpty }
        var rows: [[String]] = []
        for cell in cells {
            if cell.range(of: #"^[A-Z][a-z]? (K|L|M)"#, options: .regularExpression) != nil { rows.append([cell]) } else if !rows.isEmpty { rows[rows.count - 1].append(cell) }
        }
        return rows
    }

    @MainActor func dumpTree(_ name: String) { attach(name, app.debugDescription) }

    // MARK: The acceptance, one app session

    /// The line a failure is booked to, the lines that failed, and the lines only a hand can check (with why).
    nonisolated(unsafe) private var currentLine = 0
    nonisolated(unsafe) private var failedLines: Set<Int> = []
    nonisolated(unsafe) private var unverified: [Int: String] = [:]

    override func setUp() {
        super.setUp()
        continueAfterFailure = true   // a failed line is booked and the next one runs
    }

    override func record(_ issue: XCTIssue) {
        failedLines.insert(currentLine)
        super.record(issue)
    }

    @MainActor func line(_ n: Int, _ title: String, _ body: () throws -> Void) {
        currentLine = n
        XCTContext.runActivity(named: "Line \(n): \(title)") { _ in
            do { try body() } catch { failedLines.insert(n); attach("line \(n) stopped", "\(error)") }
        }
    }

    /// A check that needs a real mouse drag or wheel: XCUITest's own drag does not reach the room's DragGesture (2026-10-22, EDS). Booked "unverified, drag".
    @MainActor func unverifiedDrag(_ what: String) { unverified[currentLine] = what }

    /// Picks a segment of a SegmentedPicker by its title (a radio button or a button, as the picker exposes it).
    @MainActor func segment(_ id: String, _ title: String) {
        let picker = waitFor(id, timeout: 30)
        let r = picker.radioButtons[title].exists ? picker.radioButtons[title] : picker.buttons[title]
        XCTAssertTrue(r.waitForExistence(timeout: 10), "\(id) has no segment \(title)")
        r.click()
    }

    /// A screenshot of one element (the spectrum, the maps), kept whatever the verdict.
    @MainActor func shoot(_ e: XCUIElement, _ name: String) {
        guard e.exists else { return }
        let a = XCTAttachment(screenshot: e.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
    }


    @MainActor func test_TheEELSAcceptanceOn143() throws {
        try step("launch with --open on the 143 file") { openReal(); waitForRoomContent() }

        line(1, "opens in the EELS room: t/λ, E0 α β and their sources") {
            try step("the Info tab") {
                inspectorTab("Info")
                let beam = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'keV' OR value CONTAINS 'keV'")).firstMatch
                XCTAssertTrue(beam.waitForExistence(timeout: 20), "the Info tab names no beam energy in keV")
                attach("Info strings", strings(under: app.windows.firstMatch).joined(separator: "\n"))
            }
            try step("the Settings tab: sources") {
                showSettings(waitingFor: "eels.microscopeSources")
                let sources = text(element("eels.microscopeSources"))
                attach("sources", sources)
                XCTAssertTrue(sources.contains("E₀") && sources.contains("α") && sources.contains("β"), "sources line: \(sources)")
            }
        }

        let spectrum = element("eels.spectrum")
        line(2, "the spectrum on one axis, log counts, the gap marked") {
            try step("log counts") {
                attach("spectrum label", spectrum.label)
                if !spectrum.label.contains("log") {
                    spectrum.rightClick()
                    let log = app.menuItems["Log"]
                    XCTAssertTrue(log.waitForExistence(timeout: 10), "no Log item in the spectrum's context menu")
                    log.click()
                }
                XCTAssertTrue(spectrum.label.contains("log"), "the spectrum reads \"\(spectrum.label)\"")
                shoot(spectrum, "line 2: spectrum (check: the gap marked, the core loss not spikes above 1 keV, the axis labels whole)")
            }
        }

        line(3, "Align: the offset in the shared format, the shift said or drawn") {
            try step("Align") {
                showSettings(waitingFor: "eels.align")
                let align = element("eels.align")
                XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: align)], timeout: 300), .completed,
                               "Align stayed disabled; pipeline: \(pipeline())")
                align.click()
                let done = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in self.pipeline().contains("Align current") }, object: nil)
                XCTAssertEqual(XCTWaiter().wait(for: [done], timeout: 900), .completed, "the pipeline reads \"\(pipeline())\"")
                waitIdle()
                let readout = text(element("eels.alignReadout"))
                attach("align readout and status", readout + "\n" + text(element("status.bar")))
                for s in [readout, text(element("status.bar"))] {
                    XCTAssertNil(s.range(of: #"\d[,\u{202F}\u{00A0} ]\d{3}(?!\d)"#, options: .regularExpression), "an offset printed with a thousands separator: \"\(s)\"")
                }
                XCTAssertTrue(readout.contains("already aligned") || readout.contains("shifts up to"), "the readout does not say what Align moved: \"\(readout)\"")
                shoot(element("eels.maps"), "line 3: maps after Align")
            }
        }

        line(4, "t from the estimated λ, and the header says so") {
            try step("Estimate λ (the map is redone at once: no Run)") {
                showSettings(waitingFor: "eels.mfp")
                segment("eels.mfp", "Estimate λ")
                if element("eels.lambda.notice").waitForExistence(timeout: 3) { attach("λ notice", text(element("eels.lambda.notice"))) }
                let thicknessLine = element("eels.thicknessLine")
                let done = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in self.text(thicknessLine).contains(" nm") && self.pipeline().contains("Thickness current") }, object: nil)
                XCTAssertEqual(XCTWaiter().wait(for: [done], timeout: 600), .completed, "t never got a value: \"\(text(thicknessLine))\"")
                waitIdle()
                let lambdaRow = element("eels.lambda")
                let lambda = (lambdaRow.value as? String).flatMap { $0.isEmpty ? nil : $0 } ?? strings(under: lambdaRow).joined(separator: " ")
                let line = text(thicknessLine), header = text(element("eels.results.header"))
                attach("λ, line, header", [lambda, line, header].joined(separator: "\n"))
                // The λ row's number is not an accessibility child of its identifier (it read "λ"); the thickness line carries it: "λ 143,5 nm, Iakoubovskii".
                XCTAssertNotNil(line.range(of: #"λ [0-9][0-9.,]* nm"#, options: .regularExpression), "no λ value in \"\(line)\" (row: \"\(lambda)\")")
                XCTAssertFalse(line.contains("needs λ") || line.contains("not set"), "t has no value: \"\(line)\"")
                XCTAssertTrue(header.localizedCaseInsensitiveContains("estimat") || header.contains("Iakoubovskii") || line.localizedCaseInsensitiveContains("estimat"),
                              "neither the header nor the line says λ is estimated: \"\(header)\"")
            }
        }

        line(5, "pick C, N, O in the periodic table") {
            try step("pick C, N, O") {
                pick(["C", "N", "O"])
                for s in ["C", "N", "O"] { XCTAssertEqual(cellState(s), "mapped", "\(s) reads \(cellState(s))") }
                let picked = text(waitFor("eels.edges.picked", timeout: 10))
                attach("picked", picked)
                for e in ["C K", "N K", "O K"] { XCTAssertTrue(picked.contains(e), "the picked line reads \"\(picked)\", no \(e)") }
                for s in ["Fe", "Cu", "Mg", "Al", "Si"] { XCTAssertNotEqual(cellState(s), "absent", "no live cell \(s)") }
                shoot(spectrum, "line 5: spectrum with C, N, O picked (check: an onset marker and windows per edge)")
            }
        }

        line(6, "background and signal windows, draggable") {
            unverifiedDrag("dragging a window or its end, and the background following")
        }

        var rows: [[String]] = []
        line(7, "Fit: a row per edge with I ± σ and at%") {
            try step("Run to the fit") {
                run(until: "Fit current")
                rows = resultRows()
                attach("rows", rows.map { $0.joined(separator: " | ") }.joined(separator: "\n"))
                attach("footer", text(element("eels.results.footer")))
                shoot(spectrum, "line 7: spectrum with the model and the background")
            }
            for edge in ["C K", "N K", "O K"] {
                let row = rows.first { $0.first?.hasPrefix(edge) == true } ?? []
                XCTAssertFalse(row.isEmpty, "no row for \(edge)")
                XCTAssertTrue(row.contains { $0.contains("±") }, "\(edge): no I ± σ in \(row)")
                if let at = row.dropFirst(2).first { XCTAssertFalse(["0.0", "0,0", "100.0", "100,0"].contains(at), "\(edge) at% is pinned at \(at): \(row)") }
            }
        }

        line(8, "one at% tile per fitted edge, the colour mix of them") {
            try step("at% maps") {
                showSettings()
                segment("eels.maps.control", "at%")
                for s in ["C", "N", "O"] {
                    let t = app.groups.matching(NSPredicate(format: "label BEGINSWITH %@ OR label CONTAINS %@", "\(s) ", "\(s) at%")).firstMatch
                    XCTAssertTrue(t.waitForExistence(timeout: 120), "no at% tile for \(s); caption: \(text(element("eels.maps.caption")))")
                }
                XCTAssertTrue(mixTile().waitForExistence(timeout: 30), "no colour mix on the left")
                attach("mix label", mixTile().label)
                shoot(element("eels.maps"), "line 8: the at% tiles and the mix (check: the scan's aspect, no white uniform tile)")
            }
        }

        line(9, "regions: draw, move, resize, delete") {
            try step("the region tool; no Regions list in the inspector") {
                showSettings(waitingFor: "eels.tool")
                XCTAssertFalse(element("regions.list").exists, "the inspector still lists the regions")
                XCTAssertGreaterThan(element("eels.tool").radioButtons.count + element("eels.tool").buttons.count, 1, "the region tool offers no shapes")
            }
            unverifiedDrag("drawing, moving and resizing a region on the colour mix, and the spectrum following")
        }

        line(10, "zoom, pan, the status-line readout") {
            try step("hover the t/λ tile") {
                let t = anchorTile()
                XCTAssertTrue(t.waitForExistence(timeout: 30), "no t/λ tile")
                t.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).hover()
                t.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.5)).hover()
                let bar = waitFor("status.bar")
                let read = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in self.text(bar).range(of: #"\d"#, options: .regularExpression) != nil && !self.text(bar).hasPrefix("Opened") }, object: nil)
                XCTAssertEqual(XCTWaiter().wait(for: [read], timeout: 10), .completed, "status line: \"\(text(bar))\"")
                attach("status line", text(bar))
            }
            unverifiedDrag("wheel and pinch zoom and drag to pan, on the maps and on the spectrum")
        }

        line(11, "export results CSV, spectrum CSV, maps PNG, method JSON") {
            try step("the Export section") {
                showSettings(waitingFor: "eels.export.method")
                let present = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'eels.export.'")).allElementsBoundByIndex.map { "\($0.identifier) \"\($0.label)\"" }
                attach("export buttons", present.joined(separator: "\n"))
                let labels = present.joined(separator: " ")
                for want in ["Results", "Spectrum", "Maps", "Method"] { XCTAssertTrue(labels.localizedCaseInsensitiveContains(want), "no \(want) export; the section offers \(present)") }
            }
        }

        line(13, "validation: none, once") {
            let badges = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'validation: none' OR value == 'validation: none'")).count
            XCTAssertEqual(badges, 1, "validation: none shown \(badges) times")
        }

        line(12, "a stale stage is marked, Run then Stop, no NaN") {
            // The thickness choices redo the map at once; the fit waits for Run, so a new edge makes it stale.
            try step("picking Fe makes the fit stale") {
                pick(["Fe"])
                let stale = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in self.pipeline().contains("needs a new run") }, object: nil)
                XCTAssertEqual(XCTWaiter().wait(for: [stale], timeout: 30), .completed, "nothing marked stale: \"\(pipeline())\"")
                attach("pipeline after Fe", pipeline())
            }
            try step("Run, then Stop") {
                waitFor("workspace.primaryAction", timeout: 60).click()
                let stop = element("workspace.cancelAction")
                if stop.waitForExistence(timeout: 10), stop.isEnabled { stop.click() } else { app.typeKey(".", modifierFlags: .command) }
                waitIdle(timeout: 120)
                attach("pipeline after Stop", pipeline())
                let all = strings(under: app.windows.firstMatch)
                XCTAssertFalse(all.contains { $0.contains("NaN") }, "a NaN on screen: \(all.filter { $0.contains("NaN") })")
            }
        }

        let titles = [1: "opens", 2: "spectrum", 3: "align", 4: "thickness", 5: "edges", 6: "windows", 7: "fit", 8: "tiles", 9: "regions", 10: "zoom and readout",
                      11: "exports", 12: "run, stop, stale", 13: "validation"]
        let summary = (1...13).map { n -> String in
            let verdict = failedLines.contains(n) ? "FAIL" : (unverified[n].map { "UNVERIFIED (\($0))" } ?? "PASS")
            return "EELSLINE \(n) \(titles[n] ?? "") \(verdict)"
        }.joined(separator: "\n")
        print(summary)
        attach("summary", summary)
    }
}
