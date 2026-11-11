//
//  JourneyHelpers.swift
//  Role: what several journeys do the same way and the base (Journey.swift) does not hold: choosing a command of the View menu
//        from the menu bar, as a reader with a mouse does, opening a document from Help > Open Demo Data, and reading the number an
//        accessibility value carries, which the app writes in the reader's locale (a decimal comma on a German Mac).
//

import XCTest

extension Journey {
    /// The number an accessibility value is, "0,01250" or "0.01250": the app writes it with the reader's decimal mark and never
    /// groups digits, so the mark of the runner's locale and a comma both read as the decimal point. nil when the value is not
    /// one number (an empty value, a number with its unit: split the unit off first).
    nonisolated static func number(_ value: String) -> Double? {
        let mark = Locale.current.decimalSeparator ?? "."
        return Double(value.replacingOccurrences(of: mark, with: ".").replacingOccurrences(of: ",", with: "."))
    }

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

    /// Help > Open Demo Data > `title` (`DemoDocument.title`; the menu items have no identifiers, as SwiftUI commands). Fails when the
    /// menu, the submenu or the item is missing or the submenu is dimmed, and checks that macTEM is frontmost before each of the three
    /// clicks: a click on the menu bar of another app would land in that app.
    @MainActor
    func openDemoData(_ title: String, file: StaticString = #filePath, line: UInt = #line) throws {
        try requireFrontmost(file: file, line: line)
        let help = app.menuBars.menuBarItems["Help"].firstMatch
        XCTAssertTrue(help.waitForExistence(timeout: 10), "no Help menu", file: file, line: line)
        help.click()
        let submenu = app.menuItems["Open Demo Data"].firstMatch
        XCTAssertTrue(submenu.waitForExistence(timeout: 10), "no Open Demo Data in the Help menu", file: file, line: line)
        XCTAssertTrue(submenu.isEnabled, "Open Demo Data is disabled", file: file, line: line)
        try requireFrontmost(file: file, line: line)
        submenu.hover()
        let item = app.menuItems[title].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 10), "no \(title) in Open Demo Data", file: file, line: line)
        try requireFrontmost(file: file, line: line)
        item.click()
    }
}
