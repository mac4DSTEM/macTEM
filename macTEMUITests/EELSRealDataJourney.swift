//
//  EELSRealDataJourney.swift
//  The EELS room driven on the owner's three EELS spectrum images ($MACEM_DATA/eels/EELS_1, EELS_2, EELS_3), one test per folder, one app session per file,
//  in the order a microscopist works: the layout, the Info rows, Align, Deconvolve and Fit (one Run), the Processing and Fitting stage states, the
//  "Computing … maps" line, the Maps segments with the display filter's tag, the fit-notes popover, three exports, a region drawn with Return and moved with the
//  arrow keys, the ⌥-hover pixel spectrum, and the profile's distance unit. A local journey, never per-PR CI: it skips when the data folder is absent.
//  Run it as
//      TEST_RUNNER_MACEM_DATA=<data folder> tools/run-tests.sh ui EELSRealDataJourney
//  (without TEST_RUNNER_MACEM_DATA the data folder is `data/` beside the repo, as `Journey.dataFolder` says).
//
//  Read-only on the data: the app is sandboxed and the EELS room writes no sidecar beside its file; the exports go to a relative --export-dir, which the app
//  resolves inside its own temporary folder. A failure is booked to its check and the run goes on; the summary attachment and the EELSDRIVE lines on stdout give
//  each check's verdict (PASS, FAIL, SKIP with why, or SHOT where only the screenshot can show it). Attachment names carry the folder name and a step, never a file
//  name.
//

import XCTest

nonisolated final class EELSRealDataJourney: Journey {
    static let eelsFolder = Journey.dataFolder + "eels/"

    // MARK: Bookkeeping

    nonisolated(unsafe) private var label = ""
    nonisolated(unsafe) private var current = ""
    nonisolated(unsafe) private var order: [String] = []
    nonisolated(unsafe) private var failed: Set<String> = []
    nonisolated(unsafe) private var notes: [String: String] = [:]
    nonisolated(unsafe) private var shotNumber = 0

    override func setUp() {
        super.setUp()
        continueAfterFailure = true   // a failed check is booked and the next one runs
    }

    override func record(_ issue: XCTIssue) {
        if !current.isEmpty { failed.insert(current) }
        super.record(issue)
    }

    @MainActor func check(_ name: String, _ body: () throws -> Void) {
        current = name
        order.append(name)
        XCTContext.runActivity(named: "\(label): \(name)") { _ in
            do { try body() } catch { failed.insert(name); note("stopped: \(error)") }
        }
        current = ""
    }

    /// A verdict word that is not PASS or FAIL: SKIP (the file cannot do it) or SHOT (only the screenshot shows it).
    @MainActor func note(_ text: String) { notes[current] = text }

    /// A screenshot of the app's window, numbered in order and named by the folder and a neutral step.
    @MainActor func shot(_ step: String) {
        guard app != nil, app.windows.firstMatch.exists else { return }
        shotNumber += 1
        let a = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        a.name = String(format: "%@ %02d %@", label, shotNumber, step)
        a.lifetime = .keepAlways
        add(a)
    }

    @MainActor func attach(_ name: String, _ string: String) {
        let a = XCTAttachment(string: string); a.name = "\(label) \(name)"; a.lifetime = .keepAlways; add(a)
    }

    @MainActor func summarize() {
        let lines = order.map { name -> String in
            let verdict = failed.contains(name) ? "FAIL" : (notes[name] ?? "PASS")
            return "EELSDRIVE \(label) | \(name) | \(verdict)"
        }
        print(lines.joined(separator: "\n"))
        attach("summary", lines.joined(separator: "\n"))
    }

    // MARK: Finding the file

    /// The spectrum image in a folder: the shortest-named .dm4 over 50 MB (the SI itself; the Picker files and the maps are small, and a "_1" copy sorts after it).
    static func spectrumImage(in folder: String) -> String? {
        guard let walker = FileManager.default.enumerator(atPath: folder) else { return nil }
        var found: [(path: String, name: String)] = []
        for case let relative as String in walker where relative.lowercased().hasSuffix(".dm4") {
            let path = folder + "/" + relative
            let attributes = (try? FileManager.default.attributesOfItem(atPath: path)) ?? [:]
            let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            if size > 50_000_000 { found.append((path, (relative as NSString).lastPathComponent)) }
        }
        return found.min { ($0.name.count, $0.name) < ($1.name.count, $1.name) }?.path
    }

    // MARK: Helpers (the identifiers are the room's; see EELSRealFileJourney for the same waits)

    @MainActor func text(_ e: XCUIElement) -> String {
        if !e.label.isEmpty { return e.label }
        if let v = e.value as? String, !v.isEmpty { return v }
        return e.staticTexts.firstMatch.label
    }

    @MainActor func pipeline() -> String { (element("eels.pipeline").value as? String) ?? "" }

    @MainActor func inspectorTab(_ name: String) {
        let picker = waitFor("inspector.tabPicker", timeout: 30)
        let tab = picker.radioButtons[name].exists ? picker.radioButtons[name] : picker.buttons[name]
        if tab.exists, !tab.isSelected { tab.click() }
    }

    @MainActor func showSettings(waitingFor id: String) { inspectorTab("Settings"); waitFor(id, timeout: 30) }

    @MainActor func tile(_ title: String) -> XCUIElement { app.groups.matching(NSPredicate(format: "label BEGINSWITH %@", "\(title) map")).firstMatch }
    @MainActor func mixTile() -> XCUIElement { tile("Colour mix") }

    @MainActor func waitIdle(timeout: TimeInterval = 1500) {
        XCTAssertTrue(element("toolbar.display.idle").waitForExistence(timeout: timeout), "the room did not come back to idle")
    }

    @MainActor func until(_ timeout: TimeInterval, _ condition: @escaping () -> Bool) -> Bool {
        XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)], timeout: timeout) == .completed
    }

    /// The section header's spoken value ("current, expanded"): the stage state the trailing glyph draws.
    @MainActor func sectionState(_ title: String) -> String {
        let header = app.buttons.matching(NSPredicate(format: "label == %@", title)).firstMatch
        return header.exists ? ((header.value as? String) ?? "") : "absent"
    }

    @MainActor func segment(_ id: String, _ title: String) {
        let picker = waitFor(id, timeout: 30)
        let r = picker.radioButtons[title].exists ? picker.radioButtons[title] : picker.buttons[title]
        XCTAssertTrue(r.waitForExistence(timeout: 10), "\(id) has no segment \(title)")
        r.click()
    }

    @MainActor func cellState(_ symbol: String) -> String {
        let c = element("periodicTable.\(symbol)")
        return c.exists ? ((c.value as? String) ?? "?") : "absent"
    }

    /// The Info row's value by its label (an `InspectorValueRow`: two static texts, label then value).
    @MainActor func infoValue(_ label: String) -> String? {
        let texts = app.staticTexts.allElementsBoundByIndex.map { !$0.label.isEmpty ? $0.label : (($0.value as? String) ?? "") }
        guard let i = texts.firstIndex(of: label), i + 1 < texts.count else { return nil }
        return texts[i + 1]
    }

    /// Files in the app's export folder (the sandbox container's tmp), nil when the runner cannot list it.
    static func exported(_ dir: String) -> [String]? {
        let path = NSHomeDirectory() + "/Library/Containers/com.mac4dstem.macTEM/Data/tmp/" + dir
        return try? FileManager.default.contentsOfDirectory(atPath: path)
    }

    // MARK: The tests

    @MainActor func test_EELS_1() throws { try drive("EELS_1") }
    @MainActor func test_EELS_2() throws { try drive("EELS_2") }
    @MainActor func test_EELS_3() throws { try drive("EELS_3") }

    // MARK: The drive

    @MainActor func drive(_ folder: String) throws {
        label = folder
        let dir = Self.eelsFolder + folder
        try XCTSkipUnless(FileManager.default.fileExists(atPath: dir), "no data folder \(folder) under \(Self.eelsFolder)")
        let file = try XCTUnwrap(Self.spectrumImage(in: dir), "no spectrum image in \(folder)")
        let exportDir = "eels-drive-\(folder)-\(Int(Date().timeIntervalSince1970))"
        defer { summarize() }

        var opened = false
        check("opens in the EELS room") {
            launch(["--open", file, "--export-dir", exportDir])
            _ = app.windows.firstMatch.waitForExistence(timeout: 200)
            if !element("eels.room").waitForExistence(timeout: 180) {
                let sidebar = element("workspace.eels")
                if sidebar.exists, sidebar.isEnabled { sidebar.click() }
            }
            waitFor("eels.room", timeout: 60)
            opened = waitFor("eels.spectrum", timeout: 900).exists
            shot("room open")
        }
        guard opened else { return }

        var single = false
        var unit = "px"
        check("Info rows") {
            inspectorTab("Info")
            for row in ["File", "Read as", "Scan", "Channels", "Energy axis"] {
                XCTAssertTrue(app.staticTexts[row].waitForExistence(timeout: 20), "no Info row \(row)")
            }
            let scan = infoValue("Scan") ?? ""
            single = scan.hasPrefix("1 × 1 ")
            if let pixel = infoValue("Scan pixel"), let u = pixel.split(separator: " ").last { unit = String(u) }
            attach("info", "scan single: \(single), scan unit: \(unit)")
            shot("info rows")
        }

        check(single ? "single-spectrum layout" : "map grid") {
            if single {
                XCTAssertTrue(element("eels.spectrum").exists, "no spectrum")
                XCTAssertTrue(isAbsent("eels.maps"), "a 1 x 1 file shows maps")
                XCTAssertTrue(element("eels.results").exists, "no results beside the spectrum")
            } else {
                XCTAssertTrue(tile("t/\u{03BB}").waitForExistence(timeout: 900), "the t/λ tile never appeared")
                XCTAssertTrue(mixTile().waitForExistence(timeout: 60), "no colour mix tile")
            }
            waitIdle()
            shot(single ? "single spectrum" : "map grid")
        }

        check("Thickness: Processing state") {
            showSettings(waitingFor: "eels.pipeline")
            XCTAssertTrue(until(600) { self.pipeline().contains("Thickness current") }, "pipeline: \(pipeline())")
            let s = sectionState("Processing")
            attach("processing after thickness", s)
            XCTAssertFalse(s == "absent" || s.isEmpty, "the Processing header carries no state")
        }

        check("Align: Processing state") {
            showSettings(waitingFor: "eels.align")
            let align = element("eels.align")
            guard align.isEnabled else { note("SKIP (Align off for this file: no zero-loss peak)"); return }
            align.click()
            XCTAssertTrue(until(900) { self.pipeline().contains("Align current") }, "pipeline: \(pipeline())")
            waitIdle()
            // Align changes the cube the thickness map was made from, so Thickness (and with it Processing: stale wins) needs a new run until Run.
            let s = sectionState("Processing")
            attach("processing after align", "\(s)\npipeline: \(pipeline())")
            XCTAssertTrue(s.contains("needs a new run"), "Processing reads \"\(s)\" after Align")
            XCTAssertTrue(pipeline().contains("Thickness needs a new run"), "pipeline after Align: \(pipeline())")
            shot("after align")
        }

        // One Run does Thickness, Deconvolve and Fit: the deconvolution is chosen and the edges picked first.
        var deconvolveChosen = false
        check("Deconvolve chosen") {
            let picker = waitFor("eels.deconvolution", timeout: 30)
            guard picker.isEnabled else { note("SKIP (Deconvolution disabled)"); return }
            picker.click()
            let item = app.menuItems["Fourier-log"]
            guard item.waitForExistence(timeout: 10) else { note("SKIP (no Fourier-log item)"); app.typeKey(.escape, modifierFlags: []); return }
            item.click()
            deconvolveChosen = true
            if element("eels.deconvolution.notice").waitForExistence(timeout: 3) { note("SKIP (refused: see the deconvolution notice in the screenshot)"); deconvolveChosen = false }
        }

        var picked: [String] = []
        check("edges picked") {
            showSettings(waitingFor: "periodicTable.C")
            for s in ["C", "N", "O", "Fe", "Ti", "Si"] where picked.count < 3 {
                let state = cellState(s)
                guard state == "off" || state.hasPrefix("proposed") else { continue }
                element("periodicTable.\(s)").click()
                if cellState(s) == "mapped" { picked.append(s) }
            }
            attach("picked", picked.joined(separator: " "))
            XCTAssertGreaterThanOrEqual(picked.count, 1, "no edge could be picked")
            shot("edges picked")
        }

        var fitted = false
        var sawComputing = false
        check("Run: Deconvolve and Fit") {
            guard !picked.isEmpty else { note("SKIP (no edge)"); return }
            let verb = waitFor("workspace.primaryAction", timeout: 60)
            XCTAssertTrue(until(300) { verb.isEnabled }, "the verb never became enabled; pipeline: \(pipeline())")
            showSettings(waitingFor: "eels.pipeline")
            verb.click()
            // The Maps section's status line while the stages make maps; watched from the click to the fit. One predicate query, so a line that
            // clears between two reads is a miss, not a failed snapshot.
            let computing = app.descendants(matching: .any).matching(NSPredicate(
                format: "identifier == 'eels.mapsStatus' AND (label CONTAINS 'Computing' OR value CONTAINS 'Computing')")).firstMatch
            fitted = until(1800) {
                if !sawComputing, computing.exists { sawComputing = true }
                return self.pipeline().contains("Fit current")
            }
            XCTAssertTrue(fitted, "the pipeline never read Fit current: \(pipeline())")
            waitIdle()
            if deconvolveChosen { XCTAssertTrue(pipeline().contains("Deconvolve current"), "pipeline: \(pipeline())") }
            let f = sectionState("Fitting"), p = sectionState("Processing")
            attach("stage states after fit", "Processing: \(p)\nFitting: \(f)\npipeline: \(pipeline())")
            XCTAssertTrue(f.contains("current"), "Fitting reads \"\(f)\"")
            XCTAssertTrue(p.contains("current"), "Processing reads \"\(p)\"")
            shot("after fit")
        }

        check("Computing maps line appears, then clears") {
            guard fitted else { note("SKIP (no fit)"); return }
            guard !single else { note("SKIP (1 x 1: no Maps section)"); return }
            XCTAssertTrue(until(60) { !self.element("eels.mapsStatus").exists }, "the Computing line stayed after the run")
            XCTAssertTrue(element("eels.maps.caption").exists, "the caption did not come back")
            if !sawComputing { note("SHOT (the line was not seen while running: too quick to catch, or missing)") }
        }

        check("Maps segments at%, wt%, t/λ with the filtered tag") {
            guard !single else { note("SKIP (1 x 1: no maps)"); return }
            showSettings(waitingFor: "eels.maps.control")
            let filter = text(element("eels.mapFilter"))
            let filterOn = !filter.isEmpty && filter != "Off"
            attach("filter", filter)
            for seg in ["at%", "wt%", "t/\u{03BB}"] {
                segment("eels.maps.control", seg)
                if seg != "t/\u{03BB}", picked.count < 2 || !fitted {
                    attach("caption \(seg)", text(element("eels.maps.caption")))
                    shot("maps \(seg) refused")
                    continue
                }
                let want = seg == "t/\u{03BB}" ? tile("t/\u{03BB}") : tile(picked[0])
                XCTAssertTrue(want.waitForExistence(timeout: 120), "\(seg): no tile; caption \(text(element("eels.maps.caption")))")
                if filterOn {
                    XCTAssertTrue(element("maps.filteredTag").waitForExistence(timeout: 10), "\(seg): the filter is \(filter) and no tile says filtered")
                }
                shot("maps \(seg)")
            }
            if picked.count < 2 { note("SKIP (at% and wt% need two fitted elements; t/λ checked)") }
        }

        check("fit notes popover") {
            guard fitted else { note("SKIP (no fit)"); return }
            let footer = waitFor("eels.results.footer", timeout: 30)
            attach("footer", (footer.value as? String) ?? footer.label)
            footer.click()
            XCTAssertTrue(element("eels.notes").waitForExistence(timeout: 10), "the footer opened no notes popover")
            shot("fit notes")
            app.typeKey(.escape, modifierFlags: [])
        }

        check("exports: Spectrum MSA, Spectrum CSV, Method JSON") {
            showSettings(waitingFor: "eels.export.method")
            let bar = waitFor("status.bar", timeout: 30)
            for (id, name) in [("eels.export.spectrumMSA", "Spectrum MSA"), ("eels.export.spectrum", "Spectrum CSV"), ("eels.export.method", "Method JSON")] {
                let button = element(id)
                XCTAssertTrue(until(60) { button.exists && button.isEnabled }, "\(name) stayed disabled")
                guard button.isEnabled else { continue }
                button.click()
                XCTAssertTrue(until(30) { self.text(bar).hasPrefix("Exported ") }, "\(name): the status line never said Exported")
            }
            if let files = Self.exported(exportDir) {
                attach("exported", "\(files.count) files: " + files.map { ($0 as NSString).pathExtension }.sorted().joined(separator: ", "))
                XCTAssertGreaterThanOrEqual(files.count, 3, "the export folder holds \(files.count) files")
            } else {
                note("PASS (status line; the runner cannot list the app's container)")
            }
            shot("exports")
        }

        var regionDrawn = false
        check("Return draws a region, the arrows move it") {
            guard !single else { note("SKIP (1 x 1: no map to draw on)"); return }
            showSettings(waitingFor: "eels.tool")
            segment("eels.tool", "Rectangle")
            let mix = mixTile()
            XCTAssertTrue(mix.waitForExistence(timeout: 30), "no colour mix")
            mix.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.1)).click()
            app.typeKey(.return, modifierFlags: [])
            let total = element("eels.regionTable.Region 1.total")
            regionDrawn = total.waitForExistence(timeout: 120)
            XCTAssertTrue(regionDrawn, "Return drew no Region 1")
            guard regionDrawn else { return }
            _ = until(120) { !((total.value as? String) ?? "").isEmpty }
            shot("region drawn")
            let before = (total.value as? String) ?? ""
            for _ in 0..<3 { app.typeKey(.rightArrow, modifierFlags: [.shift]) }
            XCTAssertTrue(until(120) { ((total.value as? String) ?? "") != before }, "the arrows did not move Region 1 (its total did not change)")
            waitIdle(timeout: 300)
            shot("region moved")
        }

        check("option-hover draws the pixel spectrum") {
            guard !single else { note("SKIP (1 x 1: no map to hover)"); return }
            let t = tile("t/\u{03BB}")
            XCTAssertTrue(t.waitForExistence(timeout: 30), "no t/λ tile")
            XCUIElement.perform(withKeyModifiers: .option) {
                MainActor.assumeIsolated {
                    t.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.5)).hover()
                    t.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.5)).hover()
                    shot("option hover pixel spectrum")
                }
            }
            note("SHOT (the pixel layer is drawn, not an accessibility element: check the dashed pixel curve, white on the dark plot, near black on the light one)")
        }

        check("profile axis shows the file unit") {
            guard !single else { note("SKIP (1 x 1: no line)"); return }
            showSettings(waitingFor: "eels.tool")
            segment("eels.tool", "Line")
            let mix = mixTile()
            mix.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.9)).click()
            app.typeKey(.return, modifierFlags: [])
            let chart = element("profile.chart")
            XCTAssertTrue(chart.waitForExistence(timeout: 120), "no profile after Return with the line tool")
            // On macOS the chart is an AX group of its x bins: its axis title ("Distance (µm)") is drawn, not an element, and its spoken summary
            // ("… over 0.5 µm") does not reach the accessibility tree. A summary, when there is one, must end in the unit; else the screenshot shows it.
            let axis = app.staticTexts.matching(NSPredicate(format: "label == %@ OR value == %@", "Distance (\(unit))", "Distance (\(unit))")).firstMatch
            let axisShown = axis.exists
            let value = (chart.value as? String) ?? ""
            attach("profile unit", "expected \(unit); axis title element: \(axisShown); the summary ends with \(value.split(separator: " ").last.map(String.init) ?? "nothing")")
            if !value.isEmpty {
                XCTAssertTrue(value.hasSuffix(" \(unit)") || value.contains(" \(unit);"), "the profile summary is not in \(unit): \(value)")
            } else if !axisShown {
                note("SHOT (the axis title is drawn, not an accessibility element, and the chart exposes no summary: read Distance (\(unit)) in the screenshot)")
            }
            shot("profile")
        }
    }
}
