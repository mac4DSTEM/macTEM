//
//  EELSJourney.swift
//  The EELS room on the demo spectrum image (t/λ planted at 0.5 at every pixel): enter the room, let the map compute, point at a tile and
//  read the pixel's t/λ, which is the planted 0.50 within the kit's stated bias of the estimated threshold, with the unvalidated badge shown.
//  Since 1.0 the maps block is the colour mix (the anchor, where regions are drawn) and the maps the Maps control picks (t/λ by default, the ZLP shift
//  after Align unless it is flat, the fitted edges); I₀, I total and the ZLP centres are not drawn (`EELSMapsComposition.compose`), and the regions are rows
//  of the Results area's Regions table, not a list in the inspector.
//

import XCTest

nonisolated final class EELSJourney: Journey {
    /// The pointer rests on the t/λ map (the readout stands in the status line while it is over a map, control placement §7).
    @MainActor func pointAtTheThicknessMap() {
        waitFor("eels.maps", timeout: 60)
        let tile = app.groups.matching(NSPredicate(format: "label BEGINSWITH %@", "t/\u{03BB} map")).firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 60), "the t/λ map never appeared")
        tile.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.4)).hover()
    }

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
            pointAtTheThicknessMap()
            let value = thicknessFromStatusLine()
            let t = try XCTUnwrap(Double(value.replacingOccurrences(of: ",", with: ".")), "no number in \"\(value)\"")
            XCTAssertEqual(t, 0.5, accuracy: 0.01, "t/λ = \(t)")
        }
        try step("the window is titled by the file; the colour mix and the t/λ map are in view") {
            XCTAssertEqual(app.windows.firstMatch.title, "Demo EELS")
            let window = app.windows.firstMatch.frame
            for name in ["Colour mix map", "t/\u{03BB} map"] {
                let tile = app.groups.matching(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch
                XCTAssertTrue(tile.waitForExistence(timeout: 10), "\(name) missing")
                XCTAssertTrue(window.contains(tile.frame), "\(name) is cut off: \(tile.frame) in \(window)")
            }
            // The per-pixel CSV holds these; the block does not draw them any more.
            for name in ["I₀ map", "I total map", "ZLP centre map"] {
                XCTAssertFalse(app.groups.matching(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch.exists, "\(name) is drawn")
            }
        }
        try step("the badge is shown") {
            let badge = waitFor("eels.validationBadge")
            XCTAssertTrue(badge.label.contains("validation: none") || ((badge.value as? String) ?? "").contains("validation: none"), "badge: \(badge.label)")
        }
    }

    /// Run (the toolbar's verb) aligns the planted spectrum image, recomputes the thickness on the aligned cube and says so in the header and the Align
    /// section; the planted t/λ is still 0.5 afterwards (the alignment moved nothing: the planted peak is already at 0 eV). There is no "before" tile since 1.0:
    /// what Align did is the ZLP shift, read under the pointer with t/λ (and a tile only when it is not flat).
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
        try step("the planted half is still read after Align, with the shift Align applied") {
            pointAtTheThicknessMap()
            let value = thicknessFromStatusLine()
            let t = try XCTUnwrap(Double(value.replacingOccurrences(of: ",", with: ".")), "no number in \"\(value)\"")
            XCTAssertEqual(t, 0.5, accuracy: 0.01, "t/λ = \(t)")
            waitStatus(containing: ["ZLP shift"], timeout: 30)
            XCTAssertFalse(app.groups["ZLP centre (before) map"].firstMatch.exists, "the before tile is not drawn since 1.0")
        }
    }

    /// Regions are compared: two rectangles and a line (the launch draws them with the room's own calls, `--demo-regions`; a drag with real mouse events is checked by
    /// hand). The Results area's Regions table has a row for each region with its pixel count (planted: 4 x 4 = 16 and 8 x 8 = 64 of the 16 x 16 scan) and its t/λ from
    /// the summed spectrum, the planted 0.5 at every pixel and so in every region (the kit's estimated rule: within 0.01); a line is not a row; the profile along the
    /// line (selected when drawn) is the inset over the spectrum. No Regions list in the inspector and no Table or Profile tab since 1.0.
    @MainActor func testRegionsEachReadThePlantedHalf() throws {
        try step("launch with the demo EELS image and two regions") { launch(["--demo-eels-fixture", "--demo-regions"]) }
        try step("go to the EELS room") {
            waitFor("workspace.eels", timeout: 30).click()
            waitFor("eels.room", timeout: 30)
        }
        try step("the Regions table lists both regions with their pixels and thickness, and not the line") {
            waitFor("eels.regionTable", timeout: 60)
            XCTAssertEqual(waitValue("eels.regionTable.Region 1.pixels", timeout: 30) { !$0.isEmpty }, "16")
            XCTAssertEqual(waitValue("eels.regionTable.Region 2.pixels", timeout: 30) { !$0.isEmpty }, "64")
            XCTAssertFalse(element("eels.regionTable.Line 1.pixels").exists, "a line has a profile, not a row")
            for region in ["Region 1", "Region 2"] {
                let value = waitValue("eels.regionTable.\(region).tOverLambda", timeout: 60) { !$0.isEmpty }
                let t = try XCTUnwrap(Double(value.replacingOccurrences(of: ",", with: ".")), "no number in \"\(value)\"")
                XCTAssertEqual(t, 0.5, accuracy: 0.01, "\(region): t/λ = \(t)")
            }
        }
        try step("the line has a profile over the spectrum") {
            waitFor("profile.chart", timeout: 30)
        }
    }
}
