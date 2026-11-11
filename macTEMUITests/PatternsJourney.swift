//
//  PatternsJourney.swift
//  The Patterns room on the generated demo dataset (docs/sem/design/ebsd-patterns-room.md §9): launch with `--demo-ebsd-fixture`, see the
//  scan map and the live pattern pane, hover the map and read the position in the status line while the pattern stays where it is, click
//  the map to pick that position (D-SEM-110), step it with the arrow keys right after the click, drag over the map and see the pattern end
//  where the drag ended, change the map's colormap in the Display section, then the Virtual images section: a
//  tile on the map, the colour mix of three tiles and the tiles pane (north star F1 on the demo dataset), then the image quality and average dot product maps (F3), listed in the Map menu before the tiles. A screenshot at every step.
//

import XCTest

nonisolated final class PatternsJourney: Journey {
    /// The pattern pane's header ("Pattern · row 3 · col 4"), by its identifier.
    @MainActor private func patternTitle() -> String {
        let e = waitFor("patterns.pattern.title", timeout: 30)
        return !e.label.isEmpty ? e.label : ((e.value as? String) ?? "")
    }

    /// Waits until the pattern pane's header reads `title`, whole (a prefix "col 4" would also take "col 41").
    @MainActor private func waitTitle(_ title: String, timeout: TimeInterval = 20, file: StaticString = #filePath, line: UInt = #line) {
        let shown = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in self.patternTitle() == title }, object: nil)
        XCTAssertEqual(XCTWaiter().wait(for: [shown], timeout: timeout), .completed, "the pattern header never read \(title); last \(patternTitle())",
                       file: file, line: line)
    }

    /// The row and column a status line names ("row 12 · col 40 · mean 118.3"); nil when it names none.
    private static func position(in text: String) -> (row: Int, column: Int)? {
        guard let range = text.range(of: #"row \d+ · col \d+"#, options: .regularExpression) else { return nil }
        let numbers = text[range].split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        return numbers.count == 2 ? (numbers[0], numbers[1]) : nil
    }

    @MainActor func testTheDemoDatasetOpensInPatternsAndThePaneFollowsThePick() throws {
        try step("launch with the demo EBSD dataset") { launch(["--demo-ebsd-fixture"]) }
        try step("the Patterns room shows the scan map and the pattern pane") {
            waitFor("patterns.room", timeout: 30)
            waitFor("patterns.map", timeout: 30)
            waitFor("patterns.pattern", timeout: 30)
            XCTAssertEqual(app.windows.firstMatch.title, "Demo EBSD")
            // The pointer off the map (on the room's row), wherever the last journey left it: the pane shows the first point.
            try requireFrontmost()
            waitFor("workspace.patterns", timeout: 10).hover()
            let first = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in self.patternTitle().hasPrefix("Pattern · row 0 · col 0") }, object: nil)
            XCTAssertEqual(XCTWaiter().wait(for: [first], timeout: 20), .completed, patternTitle())
        }
        try step("hovering the map puts the position and its mean in the status line; the pattern stays where it is") {
            waitFor("patterns.map").coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.4)).hover()
            let line = waitStatus(containing: ["row", "col", "mean"], timeout: 30)
            XCTAssertTrue(patternTitle().hasPrefix("Pattern · row 0 · col 0"), "hovering moved the pattern: \(patternTitle()) · \(line)")
        }
        try step("a click on the map picks the position under it; → then steps it by one, ⇧→ by ten") {
            let line = waitStatus(containing: ["row", "col", "mean"], timeout: 10)
            let hovered = try XCTUnwrap(Self.position(in: line), "no row and col in the status line: \(line)")
            try requireFrontmost()
            waitFor("patterns.map").coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.4)).click()
            waitTitle("Pattern · row \(hovered.row) · col \(hovered.column)")
            // Right after the click: the click gave the room the keyboard (the demo scan is 40 columns wide, so neither step meets the edge).
            app.typeKey(.rightArrow, modifierFlags: [])
            waitTitle("Pattern · row \(hovered.row) · col \(hovered.column + 1)")
            app.typeKey(.rightArrow, modifierFlags: .shift)
            waitTitle("Pattern · row \(hovered.row) · col \(hovered.column + 11)")
        }
        try step("a drag over the map moves the pick with it; the pattern ends where the drag ended") {
            try requireFrontmost()
            let map = waitFor("patterns.map")
            let before = patternTitle()
            map.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.4))
                .press(forDuration: 0.1, thenDragTo: map.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.7)))
            // The status line names the position under the pointer where the drag ended: off the map and back, so it reads afresh.
            waitFor("workspace.patterns", timeout: 10).hover()
            map.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.7)).hover()
            let line = waitStatus(containing: ["row", "col", "mean"], timeout: 10)
            let end = try XCTUnwrap(Self.position(in: line), "no row and col in the status line: \(line)")
            waitTitle("Pattern · row \(end.row) · col \(end.column)")
            XCTAssertNotEqual(patternTitle(), before, "the drag left the pattern where the keys had put it")
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
        try step("Virtual images: a tile on the map, the colour mix, the tiles pane") {
            let choice = waitFor("patterns.map.choice", timeout: 30)
            let landed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: choice)
            XCTAssertEqual(XCTWaiter().wait(for: [landed], timeout: 60), .completed, "the pass over the scan did not land")
            try requireFrontmost()
            choice.click()
            let tile = app.menuItems["Tile r2 c1"].firstMatch
            XCTAssertTrue(tile.waitForExistence(timeout: 10), "no tile in the Map menu")
            tile.click()
            let title = waitFor("patterns.map.title", timeout: 10)
            XCTAssertTrue((title.label + (title.value as? String ?? "")).contains("r2 c1"), title.label)
            for (name, tileName) in [("red", "r2 c1"), ("green", "r2 c2"), ("blue", "r2 c3")] {
                try requireFrontmost()
                waitFor("patterns.mix.\(name)", timeout: 10).click()
                let item = app.menuItems[tileName].firstMatch
                XCTAssertTrue(item.waitForExistence(timeout: 10), "no \(tileName) in the \(name) menu")
                item.click()
            }
            let mixed = waitFor("patterns.map.title", timeout: 10)
            XCTAssertTrue((mixed.label + (mixed.value as? String ?? "")).contains("colour mix"), mixed.label)
            try requireFrontmost()
            waitFor("patterns.tiles", timeout: 10).click()
            waitFor("patterns.tiles.pane", timeout: 20)
            waitFor("patterns.tile.r0-c0", timeout: 20)
        }
        try step("Quality maps: image quality, then the average dot product, on the scan map (north star F3)") {
            for (item, words) in [("Image quality", "image quality"), ("Average dot product", "average dot product")] {
                try requireFrontmost()
                waitFor("patterns.map.choice", timeout: 10).click()
                let entry = app.menuItems[item].firstMatch
                XCTAssertTrue(entry.waitForExistence(timeout: 10), "no \(item) in the Map menu")
                entry.click()
                let title = waitFor("patterns.map.title", timeout: 10)
                XCTAssertTrue((title.label + (title.value as? String ?? "")).contains(words), title.label)
                waitFor("patterns.map", timeout: 60)
            }
        }
    }

    /// Virtual images › Map lists the whole-scan maps first, the two quality maps right after the virtual BSE, then under one divider the
    /// grid's tiles; the pop-up shows the chosen map. A walk of its own, so it does not wait on the pointer and key steps above.
    @MainActor func testTheMapMenuListsTheQualityMapsBeforeTheTiles() throws {
        try step("launch with the demo EBSD dataset; the pass over the scan lands") {
            launch(["--demo-ebsd-fixture"])
            waitFor("patterns.map", timeout: 30)
            showInspector(waitingFor: "patterns.map.choice")
            let landed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: element("patterns.map.choice"))
            XCTAssertEqual(XCTWaiter().wait(for: [landed], timeout: 60), .completed, "the pass over the scan did not land")
        }
        try step("the Map menu lists the quality maps right after the virtual BSE, before the tiles") {
            try requireFrontmost()
            let choice = waitFor("patterns.map.choice", timeout: 10)
            XCTAssertEqual(choice.value as? String, "Mean intensity", "the pop-up does not show the chosen map")
            choice.click()
            let quality = app.menuItems["Image quality"].firstMatch
            let tile = app.menuItems["Tile r0 c0"].firstMatch
            XCTAssertTrue(quality.waitForExistence(timeout: 10), "no Image quality in the Map menu")
            XCTAssertTrue(tile.waitForExistence(timeout: 10), "no Tile r0 c0 in the Map menu")
            XCTAssertLessThan(quality.frame.minY, tile.frame.minY, "Image quality is listed after the tiles")
            // The open menu is its own window, which the step's window screenshot leaves out: its own shot shows the divider and the check mark.
            let menu = choice.menus.firstMatch
            if menu.exists {
                let shot = XCTAttachment(screenshot: menu.screenshot())
                shot.name = "the Map menu, open"
                shot.lifetime = .keepAlways
                add(shot)
            }
            app.typeKey(.escape, modifierFlags: [])
        }
    }
}
