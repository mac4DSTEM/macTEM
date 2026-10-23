//
//  EELSJourney.swift
//  The EELS room on the demo spectrum image (t/λ planted at 0.5 at every pixel): enter the room, let the map compute, point at a tile and
//  read the pixel's t/λ, which is the planted 0.50 within the kit's stated bias of the estimated threshold, with the unvalidated badge shown.
//

import XCTest

nonisolated final class EELSJourney: Journey {
    /// The t/λ the status line reads under the pointer ("row 4 · col 3 · t/λ 0.5 · …", the room's one readout since the maps block
    /// became MacEMUI's, 2026-10-23): the number after "t/λ ", as a string.
    @MainActor func thicknessFromStatusLine() -> String {
        let bar = waitFor("status.bar", timeout: 60)
        func line() -> String { !bar.label.isEmpty ? bar.label : ((bar.value as? String) ?? bar.staticTexts.firstMatch.label) }
        let read = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in line().contains("t/\u{03BB} ") }, object: nil)
        XCTAssertEqual(XCTWaiter().wait(for: [read], timeout: 60), .completed, "status line: \"\(line())\"")
        return line().components(separatedBy: "t/\u{03BB} ").last?.components(separatedBy: " ").first ?? ""
    }

    @MainActor func testTheDemoThicknessReadsThePlantedHalf() throws {
        try step("launch with the demo EELS image") { launch(["--demo-eels-fixture"]) }
        try step("go to the EELS room") {
            waitFor("workspace.eels", timeout: 30).click()
            waitFor("eels.room", timeout: 30)
        }
        try step("point at the thickness map") {
            let tiles = waitFor("eels.maps", timeout: 60)
            // A click points at the pixel as hovering does (and keeps it when the mouse leaves for the readout).
            tiles.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.2)).click()
            let value = thicknessFromStatusLine()
            let t = try XCTUnwrap(Double(value.replacingOccurrences(of: ",", with: ".")), "no number in \"\(value)\"")
            XCTAssertEqual(t, 0.5, accuracy: 0.01, "t/λ = \(t)")
        }
        try step("the window is titled by the file and all four tiles are in view") {
            XCTAssertEqual(app.windows.firstMatch.title, "Demo EELS")
            let window = app.windows.firstMatch.frame
            for name in ["t/λ map", "ZLP centre map", "I₀ map", "I total map"] {
                let tile = app.groups[name].firstMatch
                XCTAssertTrue(tile.waitForExistence(timeout: 10), "\(name) missing")
                XCTAssertTrue(window.contains(tile.frame), "\(name) is cut off: \(tile.frame) in \(window)")
            }
            XCTAssertTrue(app.staticTexts["Every pixel: 0 eV"].firstMatch.exists, "the flat zero-loss tile says so in words")
        }
        try step("the badge is shown") {
            let badge = waitFor("eels.validationBadge")
            XCTAssertTrue(badge.label.contains("validation: none") || ((badge.value as? String) ?? "").contains("validation: none"), "badge: \(badge.label)")
        }
    }

    /// Run (the toolbar's verb) aligns the planted spectrum image, recomputes the thickness on the aligned cube and says so in the header and the Align
    /// section; the planted t/λ is still 0.5 afterwards (the alignment moved nothing: the planted peak is already at 0 eV).
    @MainActor func testRunAlignsAndKeepsThePlantedHalf() throws {
        try step("launch with the demo EELS image") { launch(["--demo-eels-fixture"]) }
        try step("go to the EELS room") {
            waitFor("workspace.eels", timeout: 30).click()
            waitFor("eels.room", timeout: 30)
        }
        try step("Run aligns, then maps the thickness") {
            let run = waitFor("workspace.primaryAction", timeout: 30)
            let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: run)
            XCTAssertEqual(XCTWaiter().wait(for: [enabled], timeout: 60), .completed, "Run is enabled while Align has not run")
            run.click()
            let pipeline = waitValue("eels.pipeline", timeout: 60) { $0.contains("Align current") }
            XCTAssertTrue(pipeline.contains("Thickness current"), pipeline)
            XCTAssertTrue(waitFor("eels.alignReadout", timeout: 30).exists)
        }
        try step("the planted half is still read after Align") {
            let tiles = waitFor("eels.maps", timeout: 60)
            tiles.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.2)).click()
            let value = thicknessFromStatusLine()
            let t = try XCTUnwrap(Double(value.replacingOccurrences(of: ",", with: ".")), "no number in \"\(value)\"")
            XCTAssertEqual(t, 0.5, accuracy: 0.01, "t/λ = \(t)")
            XCTAssertTrue(app.groups["ZLP centre (before) map"].firstMatch.waitForExistence(timeout: 10), "the before tile is shown")
        }
    }

    /// Regions are compared: two rectangles and a line (the launch draws them with the room's own calls, `--demo-regions`; a drag with real mouse events is checked by
    /// hand) are listed in the inspector; the Table tab has a row for each region with its pixel count (planted: 4 x 4 = 16 and 8 x 8 = 64 of the 16 x 16 scan) and its
    /// t/λ from the summed spectrum, the planted 0.5 at every pixel and so in every region (the kit's estimated rule: within 0.01); hiding a region keeps its row; the
    /// Profile tab plots the line.
    @MainActor func testRegionsEachReadThePlantedHalf() throws {
        try step("launch with the demo EELS image and two regions") { launch(["--demo-eels-fixture", "--demo-regions"]) }
        try step("go to the EELS room; the regions are listed") {
            waitFor("workspace.eels", timeout: 30).click()
            waitFor("eels.room", timeout: 30)
            waitFor("regions.name.Region 1", timeout: 60)
            waitFor("regions.name.Region 2", timeout: 10)
            waitFor("regions.name.Line 1", timeout: 10)
        }
        try step("the table lists both regions with their pixels and thickness") {
            element("spectrum.tabs").radioButtons["Table"].firstMatch.click()
            waitFor("eels.regionTable", timeout: 30)
            XCTAssertEqual(waitValue("eels.regionTable.Region 1.pixels", timeout: 30) { !$0.isEmpty }, "16")
            XCTAssertEqual(waitValue("eels.regionTable.Region 2.pixels", timeout: 30) { !$0.isEmpty }, "64")
            for region in ["Region 1", "Region 2"] {
                let value = waitValue("eels.regionTable.\(region).tOverLambda", timeout: 60) { !$0.isEmpty }
                let t = try XCTUnwrap(Double(value.replacingOccurrences(of: ",", with: ".")), "no number in \"\(value)\"")
                XCTAssertEqual(t, 0.5, accuracy: 0.01, "\(region): t/λ = \(t)")
            }
        }
        try step("hiding a region keeps its row") {
            element("regions.visibility.Region 2").click()
            XCTAssertTrue(element("eels.regionTable.Region 2.pixels").waitForExistence(timeout: 10))
        }
        try step("the line has a profile") {
            element("spectrum.tabs").radioButtons["Profile"].firstMatch.click()
            waitFor("profile.chart", timeout: 30)
        }
    }
}
