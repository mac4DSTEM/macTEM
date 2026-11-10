//
//  CloseCommandTests.swift
//  What File > Close (⌘W) and Close Window (⇧⌘W) act on, by the window that is key (`CloseCommand`): the Objects window closes itself
//  with either; the image window closes the document its room shows with ⌘W (the window when it shows none) and itself with ⇧⌘W; with
//  no macTEM window key neither acts. Whether the keys reach the Objects window on screen is unverified here (a drive of the app).
//  Red before: no `CloseCommand`; the replaced Close items were disabled whenever no image window was focused, so with the Objects
//  window key ⌘W and ⇧⌘W did nothing, though its own comment promised ⌘W closes it.
//

import XCTest
@testable import macTEM

nonisolated final class CloseCommandTests: XCTestCase {

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    private func squeezed(_ text: String) -> String { text.split(whereSeparator: \.isWhitespace).joined(separator: " ") }

    /// The Objects window key: both items close it, whatever the image window holds. Red under: the Objects case dropped (the items
    /// fall back to the image window, which is not focused, and are off).
    func testTheObjectsWindowKeyClosesItselfWithEitherKey() {
        XCTAssertEqual(CloseCommand.close(objectsWindowKey: true, imageWindowFocused: false, shown: nil), .objectsWindow)
        XCTAssertEqual(CloseCommand.close(objectsWindowKey: true, imageWindowFocused: false, shown: .image), .objectsWindow)
        XCTAssertEqual(CloseCommand.closeWindow(objectsWindowKey: true, imageWindowFocused: false), .objectsWindow)
        XCTAssertEqual(CloseCommand.close(objectsWindowKey: true, imageWindowFocused: false, shown: nil).closeTitle, "Close")
    }

    /// The image window focused: ⌘W closes the document the room shows, titled with it, or the window when it shows none; ⇧⌘W the
    /// window. Nothing key: both off. Red under: the image window's rules changed by the Objects case.
    func testTheImageWindowClosesItsDocumentOrItselfAndNothingKeyIsOff() {
        XCTAssertEqual(CloseCommand.close(objectsWindowKey: false, imageWindowFocused: true, shown: .ebsdDataset), .document(.ebsdDataset))
        XCTAssertEqual(CloseCommand.close(objectsWindowKey: false, imageWindowFocused: true, shown: .image).closeTitle, "Close Image")
        XCTAssertEqual(CloseCommand.close(objectsWindowKey: false, imageWindowFocused: true, shown: nil), .imageWindow)
        XCTAssertEqual(CloseCommand.close(objectsWindowKey: false, imageWindowFocused: true, shown: nil).closeTitle, "Close")
        XCTAssertEqual(CloseCommand.closeWindow(objectsWindowKey: false, imageWindowFocused: true), .imageWindow)
        XCTAssertEqual(CloseCommand.close(objectsWindowKey: false, imageWindowFocused: false, shown: nil), .unavailable)
        XCTAssertEqual(CloseCommand.closeWindow(objectsWindowKey: false, imageWindowFocused: false), .unavailable)
    }

    /// The File menu routes both items through `CloseCommand`, and the Objects window says when it is key. Red under: the Objects
    /// window without its focused value (it is never seen as key), or an item gated by the image window alone.
    func testTheFileMenuAndTheObjectsWindowUseTheRule() throws {
        let window = squeezed(try source("macTEM/UI/ImageRoomParticles.swift"))
        let objects = try XCTUnwrap(window.components(separatedBy: "struct ParticleTableWindow: View {").last)
        XCTAssertTrue(objects.contains(".environment(appState)"), "the Objects window's body")
        XCTAssertTrue(objects.contains(".focusedSceneValue(\\.isObjectsWindow, true)"), "the Objects window says when it is key")
        let app = squeezed(try source("macTEM/App/macTEMApp.swift"))
        XCTAssertTrue(app.contains("Button(close.closeTitle) { runClose(close) } .keyboardShortcut(\"w\", modifiers: .command) "
            + ".disabled(close == .unavailable)"), "⌘W")
        XCTAssertTrue(app.contains("Button(\"Close Window\") { runClose(closeWindow) } .keyboardShortcut(\"w\", modifiers: [.command, .shift]) "
            + ".disabled(closeWindow == .unavailable)"), "⇧⌘W")
        XCTAssertTrue(app.contains("case .objectsWindow: dismissWindow(id: ParticleTableWindow.id)"), "the Objects window is the one closed")
    }
}
