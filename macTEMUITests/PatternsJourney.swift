//
//  PatternsJourney.swift
//  The Patterns room on the generated demo dataset (docs/sem/design/ebsd-patterns-room.md §9): launch with `--demo-ebsd-fixture`, see the
//  scan map and the live pattern pane, hover the map and read the position in the status line, pin with Space, step with the arrow keys and
//  read the pinned position in the pattern pane's header, then change the map's colormap in the Display section. A screenshot at every step.
//

import XCTest

nonisolated final class PatternsJourney: Journey {
    /// The pattern pane's header ("Pattern · row 3 · col 4 · pinned"), by its identifier.
    @MainActor private func patternTitle() -> String {
        let e = waitFor("patterns.pattern.title", timeout: 30)
        return !e.label.isEmpty ? e.label : ((e.value as? String) ?? "")
    }

    @MainActor func testTheDemoDatasetOpensInPatternsAndThePaneFollowsThePointer() throws {
        try step("launch with the demo EBSD dataset") { launch(["--demo-ebsd-fixture"]) }
        try step("the Patterns room shows the scan map and the pattern pane") {
            waitFor("patterns.room", timeout: 30)
            waitFor("patterns.map", timeout: 30)
            waitFor("patterns.pattern", timeout: 30)
            XCTAssertEqual(app.windows.firstMatch.title, "Demo EBSD")
            XCTAssertTrue(patternTitle().hasPrefix("Pattern · row 0 · col 0"), patternTitle())
        }
        try step("hovering the map puts the position and its mean in the status line") {
            waitFor("patterns.map").coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.4)).hover()
            let line = waitStatus(containing: ["row", "col", "mean"], timeout: 30)
            XCTAssertTrue(patternTitle().hasSuffix("hovering"), "\(patternTitle()) · \(line)")
        }
        try step("Space pins the hovered position; → steps it by one") {
            try requireFrontmost()
            app.typeKey(.space, modifierFlags: [])
            waitFor("workspace.patterns", timeout: 10).hover()   // the pointer off the map (on the room row): the pinned pattern is shown
            let pinned = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in self.patternTitle().hasSuffix("pinned") }, object: nil)
            XCTAssertEqual(XCTWaiter().wait(for: [pinned], timeout: 20), .completed, patternTitle())
            let before = patternTitle()
            app.typeKey(.rightArrow, modifierFlags: [])
            let stepped = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in self.patternTitle() != before }, object: nil)
            XCTAssertEqual(XCTWaiter().wait(for: [stepped], timeout: 20), .completed, "the header stayed \(before)")
            XCTAssertTrue(patternTitle().hasSuffix("pinned"), patternTitle())
        }
        try step("the Calibration rows read the demo file's values") {
            showInspector(waitingFor: "patterns.calibration.step")
            let step = element("patterns.calibration.step")
            XCTAssertTrue((step.value as? String ?? step.label).contains("µm"), "step: \(step.value ?? "") / \(step.label)")
            let beam = element("patterns.calibration.beam")
            XCTAssertTrue((beam.value as? String ?? beam.label).contains("20"), "beam: \(beam.value ?? "") / \(beam.label)")
        }
        try step("the Display section changes the map's colormap") {
            let popup = waitFor("patterns.colormap", timeout: 20)
            try requireFrontmost()
            popup.click()
            let item = app.menuItems["Viridis"].firstMatch
            XCTAssertTrue(item.waitForExistence(timeout: 10), "no Viridis in the colormap menu")
            item.click()
            waitFor("patterns.map", timeout: 10)
        }
    }
}
