//
//  FFTJourney.swift
//  The FFT room on the demo lattice: enter the room, click the first lattice spot on the transform and read its d-spacing from the
//  inspector, then take a Hann window and let Find Spots put the reflections on the transform; the first spot, again, must read the
//  planted 0.235 nm within one FFT bin. The lattice repeats every 19.1 px, so its first spot is 512 / 19.1
//  = 26.8 bins from the centre along x; one bin is 0.0098 nm of d here, which is the tolerance. The Display section is second and open
//  (control placement §2): its histogram is there without a click.
//

import XCTest

nonisolated final class FFTJourney: Journey {
    @MainActor func testTheFirstLatticeSpotReadsThePlantedSpacing() throws {
        try step("launch with the demo image") {
            launch(["--demo-fixture"])
            XCTAssertTrue(app.staticTexts["Demo lattice"].firstMatch.waitForExistence(timeout: 30))
        }
        try step("go to the FFT room") {
            waitFor("workspace.fft").click()
            waitFor("fft.room", timeout: 30)
        }
        try step("show the inspector") {
            // The inspector is hidden at launch; the spot's spacing is read there.
            if !element("fft.region.centredSquare").waitForExistence(timeout: 3) { app.typeKey("i", modifierFlags: [.command, .option]) }
            waitFor("fft.region.centredSquare", timeout: 20)
        }
        try step("Display is open: the spectrum's histogram shows without a click") {
            waitFor("histogram.min", timeout: 60)
        }
        try step("click the first lattice spot") {
            // The transform fills its pane square: 512 bins across, the centre in the middle; the spot is 27 bins to the right.
            let pane = app.groups["Fourier transform"].firstMatch
            XCTAssertTrue(pane.waitForExistence(timeout: 60), "the transform never appeared")
            pane.coordinate(withNormalizedOffset: CGVector(dx: 0.5 + 27.0 / 512.0, dy: 0.5)).click()
        }
        try step("read the spacing") { try readFirstSpacing() }
        try step("take a Hann window") {
            waitFor("fft.window").click()
            app.menuItems["Hann"].firstMatch.click()
            XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "value CONTAINS 'Hann window'")).firstMatch.waitForExistence(timeout: 30)
                          || element("fft.spots.find").waitForExistence(timeout: 30))
        }
        try step("find spots") {
            let find = waitFor("fft.spots.find", timeout: 60)
            let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: find)
            XCTAssertEqual(XCTWaiter().wait(for: [enabled], timeout: 60), .completed)
            find.click()
        }
        try step("read the spacing of the first found spot") { try readFirstSpacing() }
    }

    /// The first spot's d from the inspector: "0.2351 nm", a number and its unit, within one bin of the planted 0.235 nm.
    @MainActor private func readFirstSpacing() throws {
        let value = waitValue("fft.spotSpacing", timeout: 60) { !$0.isEmpty }
        let parts = value.split(separator: " ")
        XCTAssertEqual(parts.last.map(String.init), "nm", "unit in \"\(value)\"")
        let d = try XCTUnwrap(parts.first.flatMap { Double($0) }, "no number in \"\(value)\"")
        XCTAssertEqual(d, 0.235, accuracy: 0.0098, "d = \(d) nm")
    }
}
