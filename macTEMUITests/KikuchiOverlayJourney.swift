//
//  KikuchiOverlayJourney.swift
//  The geometrical Kikuchi overlay (docs/sem/design/simulation-overlay.md, figure F14) on the shipped demo nickel scan, whose file carries
//  its crystal map: launch with `--open DemoData/nickel_ebsd_large/patterns_v2.h5`, open the inspector's Simulation section, turn the
//  overlay to Geometrical and see the layer over the pattern with its {111}, {200}, {220} and {311} bands and zone axes; Min d at 1.5 Å
//  drops the {311} bands; Off removes the layer. A screenshot at every step. The demo file is in the repo, so the journey always runs.
//

import XCTest

nonisolated final class KikuchiOverlayJourney: Journey {
    static let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("DemoData/nickel_ebsd_large/patterns_v2.h5").path

    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(FileManager.default.fileExists(atPath: Self.file), "the demo nickel is not at \(Self.file)")
    }

    @MainActor private func lineCount() -> Int {
        element("patterns.pattern.overlay").descendants(matching: .any).matching(identifier: "patterns.overlay.line").count
    }

    @MainActor private func segment(_ id: String, _ title: String) {
        let picker = waitFor(id, timeout: 30)
        let r = picker.radioButtons[title].exists ? picker.radioButtons[title] : picker.buttons[title]
        XCTAssertTrue(r.waitForExistence(timeout: 10), "\(id) has no segment \(title)")
        r.click()
    }

    @MainActor func testTheGeometricalOverlayDrawsTheNickelBandsOnThePattern() throws {
        try step("open the demo nickel in the Patterns room") {
            launch(["--open", Self.file])
            waitFor("patterns.room", timeout: 60)
            waitFor("patterns.pattern", timeout: 60)
        }
        try step("Simulation: Geometrical draws the bands and zone axes of the stored orientation") {
            showInspector(waitingFor: "patterns.display")
            try requireFrontmost()
            let header = app.buttons.matching(NSPredicate(format: "label == %@", "Simulation")).firstMatch
            XCTAssertTrue(header.waitForExistence(timeout: 20), "no Simulation section")
            header.click()
            let picker = waitFor("patterns.overlay", timeout: 20)
            let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: picker)
            XCTAssertEqual(XCTWaiter().wait(for: [enabled], timeout: 30), .completed, "the overlay is not offered on a file with orientations")
            segment("patterns.overlay", "Geometrical")
            waitFor("patterns.pattern.overlay", timeout: 30)
            let drawn = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in self.lineCount() >= 4 }, object: nil)
            XCTAssertEqual(XCTWaiter().wait(for: [drawn], timeout: 30), .completed, "\(lineCount()) bands drawn")
            let summary = waitFor("patterns.overlay.summary", timeout: 20)
            XCTAssertTrue((summary.label + (summary.value as? String ?? "")).contains("ni"), summary.label)
            XCTAssertGreaterThan(element("patterns.pattern.overlay").descendants(matching: .any)
                .matching(identifier: "patterns.overlay.zoneAxis").count, 0, "no zone axes drawn")
        }
        try step("Min d at 1.5 Å keeps fewer bands") {
            let before = lineCount()
            try requireFrontmost()
            let field = waitFor("patterns.overlay.minD", timeout: 20)
            field.doubleClick()
            app.typeKey("a", modifierFlags: .command)
            field.typeText("1.5\r")
            let fewer = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in self.lineCount() < before }, object: nil)
            XCTAssertEqual(XCTWaiter().wait(for: [fewer], timeout: 30), .completed, "\(lineCount()) bands, \(before) before")
        }
        try step("Off removes the layer") {
            try requireFrontmost()
            segment("patterns.overlay", "Off")
            let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element("patterns.pattern.overlay"))
            XCTAssertEqual(XCTWaiter().wait(for: [gone], timeout: 30), .completed, "the overlay stayed")
        }
    }
}
