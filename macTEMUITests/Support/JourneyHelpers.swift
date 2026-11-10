//
//  JourneyHelpers.swift
//  Role: what several journeys do the same way and the base (Journey.swift) does not hold: choosing a command of the View menu
//        from the menu bar, as a reader with a mouse does.
//

import XCTest

extension Journey {
    /// View > `title` from the menu bar. Fails when the item is missing or dimmed, and checks that macTEM is frontmost before each
    /// of the two clicks: a click on the menu bar of another app would land in that app.
    @MainActor
    func chooseViewCommand(_ title: String, file: StaticString = #filePath, line: UInt = #line) throws {
        try requireFrontmost(file: file, line: line)
        let menu = app.menuBars.menuBarItems["View"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 10), "no View menu", file: file, line: line)
        menu.click()
        let item = app.menuItems[title].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 10), "no \(title) in the View menu", file: file, line: line)
        XCTAssertTrue(item.isEnabled, "View > \(title) is dimmed", file: file, line: line)
        try requireFrontmost(file: file, line: line)
        item.click()
    }
}
