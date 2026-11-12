//
//  QuitQuestionTests.swift
//  The quit question comes forward: macTEM is made the active app before it asks (`AppDelegate.applicationShouldTerminate`), so a
//  quit from the Dock or a script while another app is in front shows the question instead of waiting on it unseen (macTEM#487).
//

import XCTest

nonisolated final class QuitQuestionTests: XCTestCase {
    /// Red before: `runModal()` with no activation, the alert behind the frontmost app (driven 2026-11-11, a Dictionary run, Dock > Quit).
    func testTheQuitQuestionComesForwardBeforeItAsks() throws {
        let root = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
        let delegate = try String(contentsOf: root.appendingPathComponent("macTEM/App/AppDelegate.swift"), encoding: .utf8)
        let activate = try XCTUnwrap(delegate.range(of: "NSApp.activate()"), "macTEM is not brought forward before the question")
        let ask = try XCTUnwrap(delegate.range(of: "alert.runModal()"))
        XCTAssertLessThan(activate.lowerBound, ask.lowerBound, "it comes forward before it asks, not after")
        // From the Dock's Quit the system declines the activation (driven 2026-11-11): the Dock icon bounces until the person comes.
        let bounce = try XCTUnwrap(delegate.range(of: "NSApp.isActive ? nil : NSApp.requestUserAttention(.criticalRequest)"),
                                   "a quit from the background asks for attention")
        XCTAssertLessThan(bounce.lowerBound, ask.lowerBound)
        XCTAssertTrue(delegate.contains("NSApp.cancelUserAttentionRequest(attention)"), "the bounce stops once the question is answered")
    }
}
