//
//  ImageJourney.swift
//  The Image room on the demo lattice: change the colormap, choose the Distance tool and drag a mark across the image; the mark's row in
//  the inspector reads a length in nm that is above zero (the lattice is calibrated at 0.0123 nm per pixel, so a drag over 40 % of 512 px
//  is about 2.5 nm). On the way (control placement §6, §7): the pointer's pixel is in the status line, the wheel zooms and shows the badge,
//  ⌘0 fits again.
//

import XCTest

nonisolated final class ImageJourney: Journey {
    @MainActor func testAColormapAndADistanceMarkOnTheDemoLattice() throws {
        try step("launch with the demo image") {
            launch(["--demo-fixture"])
            XCTAssertTrue(app.staticTexts["Demo lattice"].firstMatch.waitForExistence(timeout: 30))
        }
        try step("choose the Viridis colormap") {
            showInspector(waitingFor: "image.colormap")
            element("image.colormap").click()
            app.menuItems["Viridis"].firstMatch.click()
            let value = waitValue("image.colormap") { $0.localizedCaseInsensitiveContains("viridis") }
            XCTAssertTrue(value.localizedCaseInsensitiveContains("viridis"))
        }
        try step("hovering the image puts the pixel and its value in the status line") {
            waitFor("image.view").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).hover()
            waitStatus(containing: ["x 2", "y 2", "\u{00B7}"])
        }
        try step("the wheel zooms, the badge shows it, ⌘0 fits again") {
            wheelZoom("image.view", until: "image.zoomBadge")
            waitFor("image.view").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).hover()
            app.typeKey("0", modifierFlags: .command)
            waitGone("image.zoomBadge")
        }
        try step("drag a distance mark") {
            let value = drawADistanceMark()
            let (length, unit) = try XCTUnwrap(Self.leading(value), "no number in \"\(value)\"")
            XCTAssertEqual(unit, "nm", "the lattice is calibrated: \"\(value)\"")
            XCTAssertGreaterThan(length, 0.5, "a drag over 40 % of the width is about 2.5 nm: \"\(value)\"")
            XCTAssertLessThan(length, 6, "\"\(value)\"")
        }
    }
}
