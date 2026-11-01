//
//  EELSResultsJourney.swift
//  The Results room lists what the EELS room computed on a real GMS STEM spectrum image (data/eels, the 145 file): after Run with C, N and O
//  picked, the thickness row of the whole map and one row per fitted edge. Opt-in like `EELSRealFileJourney`: skipped unless MACTEM_REAL_DATA=1
//  reaches the runner and the file exists under the data folder. It only reads the file; point MACEM_DATA at a copy to keep the owner's folder
//  untouched:
//      TEST_RUNNER_MACTEM_REAL_DATA=1 TEST_RUNNER_MACEM_DATA=<a copy> tools/run-tests.sh ui EELSResultsJourney
//

import XCTest

nonisolated final class EELSResultsJourney: Journey {
    static let file145 = Journey.dataFolder + "eels/EELS_3/SI data (4)/145_STEM SI.dm4"

    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MACTEM_REAL_DATA"] == "1", "set TEST_RUNNER_MACTEM_REAL_DATA=1 to run on the real file")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: Self.file145), "the real file is not at \(Self.file145)")
    }

    @MainActor private func attach(_ name: String, _ string: String) {
        let a = XCTAttachment(string: string); a.name = name; a.lifetime = .keepAlways; add(a)
    }

    @MainActor private func pipeline() -> String { (element("eels.pipeline").value as? String) ?? "" }

    @MainActor private func inspectorTab(_ name: String) {
        let picker = waitFor("inspector.tabPicker", timeout: 30)
        let tab = picker.radioButtons[name].exists ? picker.radioButtons[name] : picker.buttons[name]
        if tab.exists, !tab.isSelected { tab.click() }
    }

    /// The strings of every Value cell the Results table shows.
    @MainActor private func tableStrings() -> [String] {
        element("results.table").descendants(matching: .staticText).allElementsBoundByIndex.prefix(400)
            .map { !$0.label.isEmpty ? $0.label : (($0.value as? String) ?? "") }.filter { !$0.isEmpty }
    }

    @MainActor func testTheEELSRoomsThicknessAndEdgesAreListedInTheResultsRoom() throws {
        try step("launch with --open on the 145 file; the t/λ map is up") {
            launch(["--open", Self.file145])
            _ = app.windows.firstMatch.waitForExistence(timeout: 200)
            waitFor("eels.room", timeout: 300)
            let tile = app.groups.matching(NSPredicate(format: "label BEGINSWITH %@", "t/λ map")).firstMatch
            XCTAssertTrue(tile.waitForExistence(timeout: 600), "the t/λ tile never appeared")
        }
        try step("pick C, N and O, Run to the fit") {
            inspectorTab("Settings")
            for symbol in ["C", "N", "O"] {
                let cell = waitFor("periodicTable.\(symbol)", timeout: 30)
                if (cell.value as? String) != "mapped" { cell.click() }
            }
            let verb = waitFor("workspace.primaryAction", timeout: 60)
            let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: verb)
            XCTAssertEqual(XCTWaiter().wait(for: [enabled], timeout: 300), .completed, "Run never became enabled; pipeline: \(pipeline())")
            verb.click()
            let fitted = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in self.pipeline().contains("Fit current") }, object: nil)
            XCTAssertEqual(XCTWaiter().wait(for: [fitted], timeout: 1500), .completed, "the pipeline reads \"\(pipeline())\"")
            XCTAssertTrue(element("toolbar.display.idle").waitForExistence(timeout: 900), "the room did not come back to idle")
        }
        try step("the Results room lists the thickness and the C, N and O edges") {
            let results = waitFor("workspace.results", timeout: 60)
            XCTAssertTrue(results.isEnabled, "the Results room is not available for the file")
            results.click()
            waitFor("results.table", timeout: 60)
            let thickness = app.descendants(matching: .any).matching(NSPredicate(format: "identifier == 'results.row.eels:thickness:whole'")).firstMatch
            XCTAssertTrue(thickness.waitForExistence(timeout: 60), "no EELS thickness row")
            for edge in ["C-K1", "N-K1", "O-K1"] {
                let row = app.descendants(matching: .any).matching(NSPredicate(format: "identifier == %@", "results.row.eels:edge:whole:\(edge)")).firstMatch
                XCTAssertTrue(row.waitForExistence(timeout: 30), "no EELS row for \(edge)")
            }
            let strings = tableStrings()
            attach("Results table", strings.joined(separator: "\n"))
            XCTAssertTrue(strings.contains { $0.hasPrefix("t/λ ") && $0.contains("IQR") }, "no Value cell reads the t/λ line")
            XCTAssertFalse(strings.contains { $0.contains("NaN") }, "a NaN on screen")
        }
    }
}
