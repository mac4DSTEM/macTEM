//
//  Journey.swift
//  Role: the base of every UI journey (the suite's UI-testing design, 2026-10-21): launch the real app fresh with the demo
//        arguments, walk it as a user would, and attach a screenshot at every named step (kept always, so the run's
//        .xcresult holds them whatever the verdict). A journey stops at its first failure; waits are on existence or on a value,
//        never a sleep; a control is found by its accessibility identifier, never by its label.
//
//        No other app shares this file yet (mac4DSTEM's UI target is the sibling brief); when it lands the two are kept in step
//        like the other shared files.
//

import XCTest

nonisolated class Journey: XCTestCase {
    /// The owner's data folder for the real-file journeys: $MACEM_DATA (TEST_RUNNER_MACEM_DATA from the shell), else `data/` beside
    /// the repo, as the suite keeps it. A journey whose file is not there skips.
    static let dataFolder: String = {
        if let folder = ProcessInfo.processInfo.environment["MACEM_DATA"], !folder.isEmpty { return folder.hasSuffix("/") ? folder : folder + "/" }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("data").path + "/"
    }()

    @MainActor var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
    }

    /// Launches the app with the UI-testing arguments and the demo ones the journey needs. A fresh process every time.
    @MainActor
    func launch(_ extra: [String] = []) {
        let launched = XCUIApplication()
        // -NSTreatUnknownArgumentsAsOpen NO: AppKit turns a launch argument that is a path to a type the app declares (CFBundleDocumentTypes: .dm4, .dm3,
        // .tif) into an open-documents event instead of a plain launch, and SwiftUI then shows no window at all (2026-10-23: the EELS journey on 143_STEM SI.dm4
        // waited on an idle app with no window, System Events counted 0 windows, a reopen event made one; the EDS journey opens .emd files, which macTEM does not
        // declare, so its path stayed a plain argument). `--open <path>` is read by LaunchOptions, never by AppKit.
        // -ApplePersistenceIgnoreState YES: no restored windows either, so every launch is the same window.
        launched.launchArguments = ["--ui-testing", "-NSTreatUnknownArgumentsAsOpen", "NO", "-ApplePersistenceIgnoreState", "YES"] + extra
        launched.launch()
        launched.activate()
        _ = launched.windows.firstMatch.waitForExistence(timeout: 20)
        app = launched
        addTeardownBlock { await MainActor.run { launched.terminate() } }
    }

    /// Stops the journey unless macTEM is frontmost with its window on screen and hittable: a click on another app would land in that app. Call it before a click.
    @MainActor func requireFrontmost(file: StaticString = #filePath, line: UInt = #line) throws {
        guard app.state == .runningForeground else {
            XCTFail("macTEM is not the frontmost app (state \(app.state.rawValue)): no click", file: file, line: line)
            throw XCTSkip("not frontmost")
        }
        let window = app.windows.firstMatch
        guard window.exists, window.isHittable, window.frame.width > 0, window.frame.height > 0 else {
            XCTFail("macTEM's window is not on screen: no click", file: file, line: line)
            throw XCTSkip("no window on screen")
        }
    }

    /// A step the user took: runs it, then attaches a screenshot named by it.
    @MainActor
    func step(_ name: String, _ body: () throws -> Void) throws {
        try body()
        // The app's window only (the whole desktop would catch other apps); nothing when it has no window.
        guard app.windows.firstMatch.exists else { return }
        let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// The element with this identifier, whatever it is (a control, a table, a text).
    @MainActor
    func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    /// True when no element carries this identifier: for a control the sources declare and this state must not show (the EELS maps on a
    /// 1 x 1 file). The inventory's identifier check reads this identifier like any other, so one that no source declares any more fails
    /// there: the absence of a deleted control cannot fail on screen, and a journey asserts on what took its place instead.
    @MainActor
    func isAbsent(_ id: String) -> Bool {
        !element(id).exists
    }

    /// Waits for the element and fails with its name when it does not appear.
    @discardableResult
    @MainActor
    func waitFor(_ id: String, timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let e = element(id)
        XCTAssertTrue(e.waitForExistence(timeout: timeout), "\(id) did not appear within \(Int(timeout)) s", file: file, line: line)
        return e
    }

    /// Waits until the element's accessibility value satisfies `check`, and returns it.
    @discardableResult
    @MainActor
    func waitValue(_ id: String, timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line,
                   where check: @escaping (String) -> Bool) -> String {
        let e = waitFor(id, timeout: timeout, file: file, line: line)
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in check((e.value as? String) ?? "") }, object: nil)
        XCTAssertEqual(XCTWaiter().wait(for: [expectation], timeout: timeout), .completed,
                       "\(id) never read as expected; last value \"\((e.value as? String) ?? "")\"", file: file, line: line)
        return (e.value as? String) ?? ""
    }

    /// Waits until the window's status line (label or value) contains every one of `words`, and returns its text.
    @discardableResult
    @MainActor
    func waitStatus(containing words: [String], timeout: TimeInterval = 20, file: StaticString = #filePath, line: UInt = #line) -> String {
        let bar = waitFor("status.bar", timeout: timeout, file: file, line: line)
        let text = { "\(bar.label) \((bar.value as? String) ?? "")" }
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in words.allSatisfy { text().contains($0) } }, object: nil)
        XCTAssertEqual(XCTWaiter().wait(for: [expectation], timeout: timeout), .completed,
                       "the status line never read \(words); last \"\(text())\"", file: file, line: line)
        return text()
    }

    /// Scrolls the wheel over `id` until `badge` appears (the sign of a wheel step differs between XCUITest and a mouse, so both ways).
    @MainActor
    func wheelZoom(_ id: String, until badge: String, file: StaticString = #filePath, line: UInt = #line) {
        let pane = waitFor(id, file: file, line: line)
        for dy in [8.0, -8.0, 16.0, -16.0] where !element(badge).waitForExistence(timeout: 2) {
            pane.scroll(byDeltaX: 0, deltaY: dy)
        }
        XCTAssertTrue(element(badge).waitForExistence(timeout: 5), "the wheel over \(id) never showed \(badge)", file: file, line: line)
    }

    /// Waits until the element with `id` is gone.
    @MainActor
    func waitGone(_ id: String, timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line) {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element(id))
        XCTAssertEqual(XCTWaiter().wait(for: [gone], timeout: timeout), .completed, "\(id) is still there", file: file, line: line)
    }

    /// Brings a room to the front when an open did not: the room's own row when the sidebar lists it, else its workspace's row. Since the
    /// five workspaces (2026-11-10) the sidebar lists Imaging, Spectroscopy, Diffraction, EBSD and Results, and a part's row (Image, FFT,
    /// EDS, EELS, Patterns, Indexing, Maps) only while its workspace is in front; a workspace's row goes to the room it was last in, or
    /// to its first one that can be entered. A row that cannot be entered is left alone: the caller's wait on the room says what is missing.
    @MainActor
    func bringToFront(room: String, in workspace: String, timeout: TimeInterval = 0) {
        let part = element("workspace.\(room)")
        if !part.exists {
            let row = element("workspace.\(workspace)")
            if row.waitForExistence(timeout: timeout), row.isEnabled { row.click() }
        }
        if part.waitForExistence(timeout: 5), part.isEnabled { part.click() }
    }

    /// Shows the inspector when the launch left it hidden, and waits for a control of the room that is entered (an identifier of it).
    @MainActor
    func showInspector(waitingFor id: String) {
        if !element(id).waitForExistence(timeout: 3) { app.typeKey("i", modifierFlags: [.command, .option]) }
        waitFor(id, timeout: 20)
    }

    /// Chooses the Distance tool and drags a mark across the middle of the image (the one drag the suite allows itself: taken from the
    /// element's frame, never absolute), and returns the value the first mark's row reads, "0,0123 nm · 49 px".
    @MainActor
    @discardableResult
    func drawADistanceMark() -> String {
        showInspector(waitingFor: "image.tool")
        element("image.tool").radioButtons["Distance"].firstMatch.click()
        let pane = waitFor("image.view")
        pane.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)).click(forDuration: 0.1, thenDragTo: pane.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5)))
        return waitValue("image.mark", timeout: 20) { !$0.isEmpty }
    }

    /// The leading number of a value such as "0,5012 nm · 49 px" (a comma or a point as the decimal), and its unit word.
    static func leading(_ value: String) -> (number: Double, unit: String)? {
        let parts = value.split(separator: " ")
        guard let first = parts.first, let n = Double(first.replacingOccurrences(of: ",", with: ".")) else { return nil }
        return (n, parts.count > 1 ? String(parts[1]) : "")
    }
}
