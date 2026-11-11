//
//  ShowOutputMenuTests.swift
//  View > Show Output (⌃⌘L) follows the Output pane's own rule (`ProcessAreaDocuments`): on wherever the pane has a document to sit
//  under, the EDS, EELS, Patterns, Indexing and Maps rooms' with no image open included, as mac4DSTEM's item follows its pane. Red
//  before: the item was on only with an image open, so with an .ang or an h5ebsd alone its key was dead while the pane worked.
//

import XCTest
import TEMCore
import TEMSession
@testable import macTEM

nonisolated final class ShowOutputMenuTests: XCTestCase {

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    private func squeezed(_ text: String) -> String { text.split(whereSeparator: \.isWhitespace).joined(separator: " ") }

    /// Each room with its own document and no image has the pane; the image rooms need the image. Red under: a room's case answering
    /// the image (the SEM and spectrum rooms dimmed without one), or the image rooms answering another room's document.
    func testEachRoomHasThePaneWithItsOwnDocumentAndNoImage() {
        let none = ProcessAreaDocuments()
        for room in WorkspaceArea.allCases { XCTAssertFalse(none.has(in: room), "\(room): nothing open") }
        let owners: [(WorkspaceArea, ProcessAreaDocuments)] = [
            (.edx, ProcessAreaDocuments(eds: true)), (.eels, ProcessAreaDocuments(eels: true)),
            (.patterns, ProcessAreaDocuments(dataset: true)), (.indexing, ProcessAreaDocuments(dataset: true)),
            (.maps, ProcessAreaDocuments(map: true)),
        ]
        for (room, documents) in owners {
            XCTAssertTrue(documents.has(in: room), "\(room) with its document and no image")
            for imageRoom in [WorkspaceArea.image, .fft, .diffraction, .results] {
                XCTAssertFalse(documents.has(in: imageRoom), "\(imageRoom) without an image")
            }
        }
        let image = ProcessAreaDocuments(image: true)
        for room in [WorkspaceArea.image, .fft, .diffraction, .results] { XCTAssertTrue(image.has(in: room), "\(room) with an image") }
        for room in [WorkspaceArea.edx, .eels, .patterns, .indexing, .maps] {
            XCTAssertFalse(image.has(in: room), "\(room): an image is not its document")
        }
    }

    /// The window with the generated EBSD scan bound and no image: the Patterns and Indexing rooms have the pane, the Image room has
    /// not. Red under: `processAreaDocuments` reading the image for the dataset.
    @MainActor func testTheSEMRoomsHaveThePaneWithADatasetAndNoImage() async throws {
        let state = AppState(launch: LaunchOptions(arguments: []))
        XCTAssertFalse(state.processAreaHasDocument, "nothing open")
        await state.ebsd.bind(try DemoDocuments.ebsd()).value
        try await waitUntil("the demo scan's passes to end", seconds: 30) { !state.ebsd.isBusy && !state.ebsd.isComputingMean }
        XCTAssertFalse(state.hasImage)
        for room in [WorkspaceArea.patterns, .indexing] {
            state.navigation.workspaceArea = room
            XCTAssertTrue(state.processAreaHasDocument, "\(room)")
        }
        state.navigation.workspaceArea = .image
        XCTAssertFalse(state.processAreaHasDocument, "no image in the Image room")
    }

    /// The View menu's item is gated by that rule, not by an open image. Red before: `.disabled(appState?.hasImage != true)`.
    func testShowOutputIsGatedByThePanesRule() throws {
        let app = squeezed(try source("macTEM/App/macTEMApp.swift"))
        XCTAssertTrue(app.contains(".keyboardShortcut(\"l\", modifiers: [.command, .control]) .disabled(appState?.processAreaHasDocument != true)"),
                      "Show Output's item")
        let view = squeezed(try source("macTEM/UI/WorkspaceView.swift"))
        XCTAssertTrue(view.contains("private var hasDocument: Bool { appState.processAreaHasDocument }"), "the pane's rule")
    }
}
