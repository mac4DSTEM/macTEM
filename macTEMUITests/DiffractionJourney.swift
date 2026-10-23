//
//  DiffractionJourney.swift
//  The Diffraction room on the planted Au pattern (`DemoDocuments.diffractionPattern`: centre (256, 256), Δq 0.0125 Å⁻¹/px, {111} at R 33.98,
//  {200} at 39.24, {220} as six spots at R 55.48): calibrate on the {111} ring, fit the {200} ring, click a {220} spot, export the readout, and
//  find the rows in the Results room. Ends on the {220} d-spacing (planted 1.4419 Å) read from the spot's row.
//  The annulus is dragged on the pane, from points computed from the pane's frame (the image fills it), never absolute. On the way (control
//  placement §5–§7): the Display section's colormap and log switch, R · q · d in the status line, the wheel's zoom badge and the double-click
//  fit (the fit's Stop is the infobar's; the unit tests pin that the header has none).
//

import XCTest

nonisolated final class DiffractionJourney: Journey {
    private static let side = 512.0

    /// The half-side (px) the pane shows about the centre: it opens on the pattern's own extent, so a pixel offset maps to the box by it.
    @MainActor private func halfSide() -> Double {
        let value = waitValue("diffraction.view", timeout: 30) { (Double($0) ?? 0) > 0 }
        return Double(value) ?? Self.side / 2
    }

    /// A point of the pattern at (dx, dy) pixels from the centre, as a normalised offset on the pane (the pane is the image's box, and the
    /// view is centred on the pattern's centre and shows ±`halfSide` pixels of the image's ±256).
    @MainActor private func at(_ dx: Double, _ dy: Double = 0) -> XCUICoordinate {
        let k = (Self.side / 2) / halfSide()      // box points per image point, over the image box
        return waitFor("diffraction.pane").coordinate(withNormalizedOffset: CGVector(dx: 0.5 + dx * k / Self.side, dy: 0.5 + dy * k / Self.side))
    }

    /// The d (Å) a readout row shows, read from its accessibility value.
    @MainActor private func d(of tag: String) -> Double {
        let value = waitValue("diffraction.row.\(tag).d", timeout: 60) { !$0.isEmpty }
        return Double(value) ?? .nan
    }

    @MainActor func testCalibrateOnTheGoldRingThenIndexTheNextRingAndASpot() throws {
        try step("launch with the demo pattern") {
            launch(["--demo-diffraction-fixture", "--export-dir", "macTEM-ui-export"])
            waitFor("diffraction.pane", timeout: 60)
            showInspector(waitingFor: "diffraction.calibrate")
        }
        try step("the pane opens on the pattern, not on the whole frame") {
            let half = halfSide()
            XCTAssertLessThan(half, 128, "the rings reach 70 px; the view must not show the whole 512 px frame: ±\(half)")
            XCTAssertGreaterThan(half, 70, "and must include them")
        }
        try step("the file's axis is the scale until a ring sets one") {
            let scale = waitValue("diffraction.scale") { !$0.isEmpty }
            XCTAssertEqual(Double(scale) ?? .nan, 0.0125 * 1.01, accuracy: 1e-5, "scale: \(scale)")
        }
        try step("Display: the colormap and the log switch") {
            showInspector(waitingFor: "diffraction.colormap")
            element("diffraction.colormap").click()
            app.menuItems["Gray"].firstMatch.click()
            waitValue("diffraction.colormap") { $0.localizedCaseInsensitiveContains("gray") }
            // A switch's value is a number (1 on), as StackJourney reads it.
            let log = waitFor("diffraction.log")
            // Below the histogram the switch can sit at the window's bottom edge, where a click lands outside it: scroll the inspector
            // until the switch is well inside the window (whichever way the wheel's sign runs).
            let window = app.windows.firstMatch.frame
            for dy in [-120.0, -120, -120, 120, 120, 120, 120, 120, 120] where log.frame.maxY > window.maxY - 40 {
                waitFor("diffraction.colormap").scroll(byDeltaX: 0, deltaY: dy)
            }
            XCTAssertLessThan(log.frame.maxY, window.maxY - 40, "the log switch is not inside the window: \(log.frame) in \(window)")
            XCTAssertEqual(log.value as? Int, 1, "the pattern opens in log")
            log.click()
            let off = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in log.value as? Int == 0 }, object: nil)
            XCTAssertEqual(XCTWaiter().wait(for: [off], timeout: 10), .completed, "the log switch never turned off")
            log.click()
            let on = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in log.value as? Int == 1 }, object: nil)
            XCTAssertEqual(XCTWaiter().wait(for: [on], timeout: 10), .completed, "the log switch never turned back on")
        }
        try step("hovering the pattern puts R, q and d in the status line") {
            at(45).hover()
            waitStatus(containing: ["R ", "q ", "d "])
        }
        try step("the wheel zooms about the centre, a double-click fits again") {
            wheelZoom("diffraction.pane", until: "diffraction.zoomBadge")
            waitFor("diffraction.pane").doubleClick()
            waitGone("diffraction.zoomBadge")
        }
        try step("drag an annulus on the {111} ring and calibrate") {
            at(30).click(forDuration: 0.1, thenDragTo: at(36.5))
            waitFor("diffraction.calibrate").click()
            let scale = waitValue("diffraction.scale", timeout: 120) { (Double($0) ?? 1) < 0.01255 }
            XCTAssertEqual(Double(scale) ?? .nan, 0.0125, accuracy: 0.0125 * 0.01, "fitted scale: \(scale)")
        }
        try step("drag an annulus on the {200} ring") {
            at(37.5).click(forDuration: 0.1, thenDragTo: at(41.5))
        }
        try step("fit the {200} ring") {
            waitFor("diffraction.fitRing").click()
            let family = waitValue("diffraction.row.ring2.family", timeout: 120) { !$0.isEmpty }
            XCTAssertEqual(family, "{200}")
            XCTAssertEqual(d(of: "ring2"), 2.0391, accuracy: 4e-3)
        }
        try step("click a spot on the {220} ring") {
            element("diffraction.tool").radioButtons["Spot"].firstMatch.click()
            let r = 55.48 * 0.5.squareRoot()
            at(r, r).click()
            let family = waitValue("diffraction.row.spot1.family", timeout: 60) { !$0.isEmpty }
            XCTAssertEqual(family, "{220}")
            XCTAssertEqual(d(of: "spot1"), 1.4419, accuracy: 3e-3)
        }
        try step("export the readout") {
            waitFor("diffraction.export").click()
            let bar = waitFor("status.bar", timeout: 30)
            let done = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS[c] 'exported' OR value CONTAINS[c] 'exported'"), object: bar)
            XCTAssertEqual(XCTWaiter().wait(for: [done], timeout: 30), .completed, "status bar: \(bar.label)")
        }
        try step("the Results room lists the calibration, the rings and the spot") {
            waitFor("workspace.results").click()
            waitFor("results.table", timeout: 30)
            let rows = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'results.row.'"))
            XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 30), "the table has no rows")
            XCTAssertGreaterThanOrEqual(rows.count, 4, "calibration, two rings and a spot")
        }
    }
}
