//
//  ParticlesRealFileJourney.swift
//  The Image room's Particles section on the owner's real Ceta images (TIFF and Velox EMD, the low-magnification ones and the HRTEM
//  630 kx and 1.05 Mx). Opt-in like the other real-file journeys: skipped unless MACTEM_REAL_DATA=1 reaches the runner and the file
//  exists. xcodebuild hands the runner only variables named TEST_RUNNER_*, so run it as
//      TEST_RUNNER_MACTEM_REAL_DATA=1 TEST_RUNNER_MACEM_DATA=<data folder> tools/run-tests.sh ui ParticlesRealFileJourney
//  Each method opens one file, shows objects with the defaults, reads the counts, opens the object table and exports the CSV into
//  --export-dir. A finding (the section is wrong) fails the step with its words; the counts are attached, never asserted (no truth yet).
//

import XCTest

nonisolated final class ParticlesRealFileJourney: Journey {
    static let exportName = "macTEM-particles-export"
    static func tem(_ name: String) -> String { Journey.dataFolder + "tem/" + name }

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

    /// The whole walk on one file: open, Show Objects, counts, the table, the CSV.
    @MainActor func drive(_ name: String) throws {
        let file = Self.tem(name)
        try XCTSkipUnless(FileManager.default.fileExists(atPath: file), "the real file is not at \(file)")
        try step("open \(name)") {
            launch(["--open", file, "--export-dir", Self.exportName])
            waitFor("image.view", timeout: 120)
            showInspector(waitingFor: "particles.show")
        }
        try step("show objects") {
            let show = waitFor("particles.show", timeout: 30)
            let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: show)
            XCTAssertEqual(XCTWaiter().wait(for: [enabled], timeout: 60), .completed, "Show Objects stayed disabled")
            show.click()
        }
        try step("counts") {
            let counted = waitValue("particles.counts", timeout: 180) { !$0.isEmpty }
            attach("counted", counted)
            attach("counts line", text(element("particles.counts")))
            if element("particles.density").exists { attach("density line", text(element("particles.density"))) }
            let sizes = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'median' OR value BEGINSWITH 'median'")).firstMatch
            if sizes.exists { attach("size line", text(sizes)) }
            XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'not calibrated'")).firstMatch.exists,
                           "a calibrated Ceta image reads as not calibrated")
            let table = waitFor("particles.table")
            XCTAssertTrue(app.windows.firstMatch.frame.contains(table.frame), "Object Table is below the fold: \(table.frame)")
        }
        // XCUITest's snapshot of a window builds every row of its table: on the HRTEM images (10 000 objects and more under the default
        // threshold) one query keeps the app's main thread busy past XCUITest's 30 s (2026-11-05, spindump in NSTableView
        // viewAtColumn:row:makeIfNecessary:). A person scrolling the table builds only the rows in view, so the drive stops short of it there.
        let counted = Int(((element("particles.counts").value as? String) ?? "").filter(\.isNumber)) ?? 0   // a whole number, never grouped
        if counted > 2000 { attach("object table", "not opened: \(counted) counted objects, more than XCUITest's snapshot of the table can take") }
        else { try step("object table") {
            waitFor("particles.table").click()
            let view = waitFor("particles.tableView", timeout: 30)
            let rows = view.tableRows.firstMatch.exists || view.outlineRows.firstMatch.exists ? 1 : 0   // SwiftUI's Table is an outline
            attach("table rows", "\(rows)")
            XCTAssertTrue(rows > 0 || counted == 0, "the table lists no row")
            let tableWindow = app.windows.matching(NSPredicate(format: "title == 'Objects'")).firstMatch
            if tableWindow.exists {
                let shot = XCTAttachment(screenshot: tableWindow.screenshot()); shot.name = "the Objects window"; shot.lifetime = .keepAlways; add(shot)
                tableWindow.typeKey("w", modifierFlags: .command)
            }
        } }
        try step("export CSV") {
            let export = waitFor("particles.export", timeout: 20)
            export.click()
            let bar = waitFor("status.bar", timeout: 20)
            let exported = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in self.text(bar).hasPrefix("Exported ") }, object: nil)
            let saved = XCTWaiter().wait(for: [exported], timeout: 30)
            if saved != .completed, app.sheets.firstMatch.exists {
                let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot()); shot.name = "a save panel instead"; shot.lifetime = .keepAlways; add(shot)
                app.sheets.firstMatch.buttons["Cancel"].click()
            }
            XCTAssertEqual(saved, .completed, "Export CSV with --export-dir: status line \"\(text(bar))\"")
            attach("status after export", text(bar))
        }
    }

    @MainActor func test01_Ceta1305TIFF() throws { try drive("Camera Ceta 1305 17500 x 20260605 Ceta.tif") }
    @MainActor func test02_Ceta1306TIFF() throws { try drive("Camera Ceta 1306 28500 x 20260605 Ceta.tif") }
    @MainActor func test03_Ceta1309TIFF() throws { try drive("Camera Ceta 1309 36000 x 20260605 Ceta.tif") }
    @MainActor func test04_Ceta1309EMD() throws { try drive("Camera Ceta 1309 36000 x 20260605.emd") }
    @MainActor func test05_HRTEM1620TIFF() throws { try drive("Camera Ceta 1620 630 kx 20260605 Ceta.tif") }
    @MainActor func test06_HRTEM1623TIFF() throws { try drive("Camera Ceta 1623 1.05 Mx 20260605 Ceta.tif") }
    @MainActor func test07_HRTEM1631TIFF() throws { try drive("Camera Ceta 1631 1.05 Mx 20260605 Ceta.tif") }
}
