//
//  PatternProcessingJourney.swift
//  The Patterns room's processing (docs/sem/design/pattern-processing.md §8) on the generated demo dataset: launch with
//  `--demo-ebsd-fixture`, the pattern pane shows the raw pattern; Process (the toolbar's verb) runs the stages over the scan and the pane
//  switches to the processed pattern ("· processed" in its header); Raw shows the stored pattern again. A screenshot at every step.
//

import XCTest

nonisolated final class PatternProcessingJourney: Journey {
    @MainActor private func patternTitle() -> String {
        let e = waitFor("patterns.pattern.title", timeout: 30)
        return !e.label.isEmpty ? e.label : ((e.value as? String) ?? "")
    }

    @MainActor func testProcessRunsTheStagesAndThePaneShowsTheProcessedPattern() throws {
        try step("launch with the demo EBSD dataset: the raw pattern") {
            launch(["--demo-ebsd-fixture"])
            waitFor("patterns.room", timeout: 30)
            XCTAssertFalse(patternTitle().contains("processed"), patternTitle())
        }
        try step("Process runs the stages; the pane shows the processed pattern") {
            showInspector(waitingFor: "patterns.display")
            let run = waitFor("workspace.primaryAction", timeout: 30)
            let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: run)
            XCTAssertEqual(XCTWaiter().wait(for: [enabled], timeout: 60), .completed, "Process is enabled once the scan's mean has landed")
            try requireFrontmost()
            run.click()
            let processed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in self.patternTitle().contains("processed") }, object: nil)
            XCTAssertEqual(XCTWaiter().wait(for: [processed], timeout: 60), .completed, patternTitle())
        }
        try step("Raw shows the stored pattern again") {
            try requireFrontmost()
            let display = waitFor("patterns.display", timeout: 20)
            let raw0 = display.radioButtons["Raw"].exists ? display.radioButtons["Raw"] : display.buttons["Raw"]
            raw0.firstMatch.click()
            let raw = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !self.patternTitle().contains("processed") }, object: nil)
            XCTAssertEqual(XCTWaiter().wait(for: [raw], timeout: 30), .completed, patternTitle())
        }
    }
}
