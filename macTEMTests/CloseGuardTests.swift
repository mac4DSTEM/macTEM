//
//  CloseGuardTests.swift
//  What closing a file or quitting asks before it loses work (`CloseGuard`, `AppState.requestClose`, `AppState.quitQuestion`): a
//  file whose marks are not saved to its session file is named, and stays open until the answer; a save clears the question; a
//  file with nothing unsaved closes at once, as before; a room still working (an indexing run) is named at quit. The planted
//  fixture (Fixtures/planted-2d.dm4) is copied into a fresh temporary folder per test.
//  Red before: no `CloseGuard` and no `requestClose`; every close (`OpenItems.closeSelected`, `close`, `closeOthers`) removed a
//  file with unsaved marks without a word, and quitting asked nothing.
//

import XCTest
import ImagoCore
@testable import macTEM
import TEMCore
import TEMSession

nonisolated final class CloseGuardTests: XCTestCase {

    /// A copy of the planted fixture in a fresh temporary folder, removed after the test.
    private func plantedCopy(named name: String = "planted.dm4") throws -> URL {
        let source = try XCTUnwrap(Bundle(for: CloseGuardTests.self).url(forResource: "planted-2d", withExtension: "dm4"),
                                   "planted-2d.dm4 is not in the test bundle")
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mactem-close-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent(name)
        try FileManager.default.copyItem(at: source, to: url)
        return url
    }

    /// One distance drawn on `item`, as the Image room's tool draws it: its marks are then not saved.
    @MainActor private func drawADistance(on item: OpenItem) throws {
        let image = try XCTUnwrap(item.session.image, "the file is read")
        let mark = ImageMark(kind: .distance, points: [ImagePoint(x: 1, y: 1), ImagePoint(x: 4, y: 3)])
        XCTAssertNil(item.measurements.add(mark, on: image), "the mark is recorded")
        XCTAssertTrue(item.measurements.isDirty)
    }

    /// `item`'s marks saved as File > Save to Session records a save that was written (the write itself is `SessionUITests`').
    @MainActor private func markSaved(_ item: OpenItem) throws {
        let identity = try XCTUnwrap(item.openedIdentity, "the read gave the pixels' identity")
        let request = try item.measurements.saveRequest(opened: identity)
        item.measurements.didSave(request, opened: identity)
        XCTAssertFalse(item.measurements.isDirty)
    }

    // MARK: - The words

    /// Red under: a question when nothing would be lost; the number agreement lost; every name of a long list written out; Return
    /// on Close Anyway when no save is offered.
    func testTheQuestionNamesWhatWouldBeLost() {
        XCTAssertNil(CloseGuard.question(dirtyFiles: [], busyRooms: []))
        XCTAssertEqual(CloseGuard.question(dirtyFiles: ["scan.dm4"], busyRooms: []),
                       "The marks on “scan.dm4” are not saved to its session file.")
        XCTAssertEqual(CloseGuard.question(dirtyFiles: [], busyRooms: ["Indexing"]), "Indexing is still working.")
        XCTAssertEqual(CloseGuard.question(dirtyFiles: ["a.dm4", "b.dm4"], busyRooms: ["Indexing", "Maps"]),
                       "The marks on “a.dm4” and “b.dm4” are not saved to their session files. Indexing and Maps are still working.")
        XCTAssertEqual(CloseGuard.question(dirtyFiles: ["1", "2", "3", "4", "5"], busyRooms: []),
                       "The marks on “1”, “2”, “3” and 2 more are not saved to their session files.")
        XCTAssertEqual(CloseGuard.closeButtons(canSave: true), [.save, .discard, .cancel])
        XCTAssertEqual(CloseGuard.closeButtons(canSave: false), [.cancel, .discard], "Return never closes when no save is offered")
        XCTAssertEqual(CloseGuard.title(of: .discard, canSave: true), "Don't Save")
        XCTAssertEqual(CloseGuard.title(of: .discard, canSave: false), "Close Anyway")
    }

    // MARK: - Through the window's state

    /// An AppState with one file whose marks are not saved names the file; once they are saved, nothing is asked. Red under:
    /// `quitQuestion` leaving the files out, or `isDirty` not asked (a saved file still named).
    @MainActor func testAFileWithUnsavedMarksIsNamedUntilTheyAreSaved() async throws {
        let state = AppState()
        await state.open(urls: [try plantedCopy()])?.value
        let item = try XCTUnwrap(state.openItems.selected)
        XCTAssertNil(state.quitQuestion, "a file just opened has nothing unsaved")
        try drawADistance(on: item)
        XCTAssertEqual(state.quitQuestion, "The marks on “planted.dm4” are not saved to its session file.")
        try markSaved(item)
        XCTAssertNil(state.quitQuestion, "saved: nothing to ask")
    }

    /// Close on a file with unsaved marks leaves it open until the answer: Cancel keeps it, Don't Save closes it. Red under:
    /// `requestCloseSelected` closing at once (as `closeSelected` did); Cancel closing; Don't Save keeping the file; a second
    /// close replacing the question that is up.
    @MainActor func testCloseWaitsForTheAnswerWhenMarksAreNotSaved() async throws {
        let state = AppState()
        await state.open(urls: [try plantedCopy()])?.value
        let item = try XCTUnwrap(state.openItems.selected)
        try drawADistance(on: item)

        state.requestCloseSelected()
        XCTAssertEqual(state.openItems.items.map(\.id), [item.id], "the file stays open while the question is up")
        let asked = try XCTUnwrap(state.closeRequest, "a question is up")
        XCTAssertEqual(asked.items, [item.id])
        XCTAssertNil(asked.keeping)
        XCTAssertTrue(asked.canSave, "a read file with its pixels can be saved: Save to Session is offered")
        XCTAssertEqual(asked.question, "The marks on “planted.dm4” are not saved to its session file.")
        state.requestClose([item.id])
        XCTAssertEqual(state.closeRequest, asked, "one question at a time")

        state.answerClose(.cancel, to: asked)
        XCTAssertNil(state.closeRequest)
        XCTAssertEqual(state.openItems.items.map(\.id), [item.id], "Cancel keeps the file")
        XCTAssertTrue(item.measurements.isDirty, "and its marks")

        state.requestClose([item.id])
        let again = try XCTUnwrap(state.closeRequest)
        state.answerClose(.discard, to: asked)
        XCTAssertEqual(state.closeRequest, again, "an answer to a question no longer up changes nothing")
        XCTAssertEqual(state.openItems.items.count, 1)
        state.answerClose(.discard, to: again)
        XCTAssertNil(state.closeRequest)
        XCTAssertTrue(state.openItems.items.isEmpty, "Don't Save closes it")
    }

    /// Close Others over two files with unsaved marks asks about both; after Save to Session the file that saved closes and the
    /// one whose save did not happen stays, with the kept file selected; a file with nothing unsaved closes without a question.
    /// Red under: the save's answer closing every file; Close Others not selecting the kept file first; a clean file asked about.
    @MainActor func testAfterASaveTheSavedFilesCloseAndACleanFileClosesAtOnce() async throws {
        let state = AppState()
        await state.open(urls: [try plantedCopy(named: "a.dm4"), try plantedCopy(named: "b.dm4"), try plantedCopy(named: "c.dm4")])?.value
        XCTAssertEqual(state.openItems.items.count, 3)
        let a = state.openItems.items[0], b = state.openItems.items[1], c = state.openItems.items[2]
        try drawADistance(on: a)
        try drawADistance(on: b)

        state.requestCloseOthers(keeping: c.id)
        XCTAssertEqual(state.openItems.items.count, 3, "nothing closes while the question is up")
        let asked = try XCTUnwrap(state.closeRequest)
        XCTAssertEqual(asked.items, [a.id, b.id])
        XCTAssertEqual(asked.keeping, c.id)
        XCTAssertEqual(asked.question, "The marks on “a.dm4” and “b.dm4” are not saved to their session files.")

        try markSaved(a)   // a's save was written; b's panel was cancelled
        state.answerClose(.save, to: asked)
        XCTAssertEqual(state.openItems.items.map(\.id), [b.id, c.id], "the saved file closed, the unsaved one stayed")
        XCTAssertTrue(state.openItems.selected === c, "Close Others selects the kept file")

        state.requestClose([c.id])
        XCTAssertNil(state.closeRequest, "nothing unsaved: no question")
        XCTAssertEqual(state.openItems.items.map(\.id), [b.id], "and the file closed at once")
    }

    /// A room still working is named at quit: the shipped nickel scan opened as a person opens it and Hough indexing started.
    /// Red under: `busyRooms` leaving the Indexing room out, or `quitQuestion` leaving the rooms out.
    @MainActor func testARunningIndexingRunIsNamedAtQuit() async throws {
        let url = try XCTUnwrap(DemoDocuments.Shipped.nickelEBSD.url, "DemoData/ is not in the bundle")
        let state = AppState()
        await state.open(urls: [url])?.value
        for _ in 0..<4000 where !state.ebsd.hasDataset { try await Task.sleep(for: .milliseconds(5)) }
        for _ in 0..<12_000 where state.ebsd.isBusy || state.maps.isBusy { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(state.ebsd.hasDataset)
        XCTAssertFalse(state.busyRooms.contains("Indexing"), "nothing runs yet")

        let run = state.indexing.index()
        XCTAssertTrue(state.indexing.isIndexing)
        XCTAssertTrue(state.busyRooms.contains("Indexing"), "\(state.busyRooms)")
        let question = try XCTUnwrap(state.quitQuestion, "quitting now would end the run")
        XCTAssertTrue(question.contains("Indexing"), question)

        state.indexing.stop()
        await run.value
        XCTAssertFalse(state.busyRooms.contains("Indexing"), "stopped: the room is no longer named")
    }
}
