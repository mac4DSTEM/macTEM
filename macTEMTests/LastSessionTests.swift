//
//  LastSessionTests.swift
//  Pins File > Reopen Last Session: the record (`LastSession`, TEMSession; mac4DSTEM's recovery record, for a window of many files)
//  and the app's side of it (`AppState.open(urls:)`, the selection and the room write the record; `reopenLastSession` opens the last
//  launch's files again, then its selection and its room, and names a file that is gone). Saving is injected as a recorder or as
//  defaults of the test's own, so no test reads or writes a person's record. Red before: no `LastSession`, no `lastSession`, no
//  `reopenLastSession`.
//

import XCTest
import Foundation
import TEMCore
import TEMSession
@testable import macTEM

nonisolated final class LastSessionTests: XCTestCase {

    /// Every record the store was told, in order.
    private final class Recorder {
        var saved: [LastSessionRecord] = []
    }

    /// Two copies of a committed fixture, `a.dm4` and `b.dm4`, in a folder of the test's own.
    private func twoFiles() throws -> (a: URL, b: URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("last-session-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let source = URL(fileURLWithPath: FileRoutingTests.fixture("planted-2d.dm4"))
        let a = folder.appendingPathComponent("a.dm4"), b = folder.appendingPathComponent("b.dm4")
        try FileManager.default.copyItem(at: source, to: a)
        try FileManager.default.copyItem(at: source, to: b)
        return (a, b)
    }

    /// Defaults of the test's own, emptied after it.
    private func scratchDefaults() throws -> UserDefaults {
        let suite = "mactem-last-session-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        return defaults
    }

    // MARK: The record

    /// Only files taken in with a bookmark are recorded, each once, in order; the record is saved only when it changes; closing
    /// everything, or holding only a demo made in memory, keeps the last files open as the record. Red under: a demo or a file named
    /// twice recorded; a save on every call; an empty set saved over the last one.
    @MainActor func testTheRecordListsFilesWithABookmarkOnceAndKeepsTheLastFilesOpen() {
        let recorder = Recorder()
        let session = LastSession(previous: nil, persist: { recorder.saved.append($0) })
        let a = URL(fileURLWithPath: "/data/a.dm4"), b = URL(fileURLWithPath: "/data/b.h5")
        let fileA = RecentFile(path: a.path, displayName: "a.dm4", bookmark: Data([1]))
        let fileB = RecentFile(path: b.path, displayName: "b.h5", bookmark: Data([2]))
        session.remember(fileA)
        session.remember(fileB)
        session.update(open: [a, DemoDocuments.latticeURL, b, a], selected: b, room: "patterns")
        XCTAssertEqual(recorder.saved, [LastSessionRecord(files: [fileA, fileB], selectedPath: "/data/b.h5", room: "patterns")])
        XCTAssertEqual(session.current, recorder.saved.last)
        session.update(open: [a, b], selected: b, room: "patterns")
        XCTAssertEqual(recorder.saved.count, 1, "the same record is not saved again")
        session.update(open: [], selected: nil, room: "image")
        XCTAssertEqual(recorder.saved.count, 1, "closing everything keeps the last files open as the record")
        session.update(open: [DemoDocuments.latticeURL], selected: DemoDocuments.latticeURL, room: "image")
        XCTAssertEqual(recorder.saved.count, 1, "a demo made in memory is never recorded")
        session.update(open: [b], selected: DemoDocuments.latticeURL, room: "maps")
        XCTAssertEqual(recorder.saved.last, LastSessionRecord(files: [fileB], selectedPath: nil, room: "maps"))
        XCTAssertNil(session.previous, "this launch's record is not the previous launch's")
    }

    /// The sentences for files that could not be reopened. Red under: a missing file not named; the disk not named.
    func testTheFilesNotReopenedAreNamed() {
        XCTAssertNil(AppState.notReopened(gone: [], offline: []))
        XCTAssertEqual(AppState.notReopened(gone: ["b.dm4"], offline: []),
                       "b.dm4 is no longer where it was (moved, renamed or deleted), so it was not reopened.")
        XCTAssertEqual(AppState.notReopened(gone: ["b.dm4", "c.h5"], offline: [(name: "d.ang", volume: "NAS")]),
                       "b.dm4 and c.h5 are no longer where they were (moved, renamed or deleted), so they were not reopened. "
                           + "d.ang is on NAS, which is not connected, so it was not reopened.")
    }

    // MARK: Through the app

    /// Two files opened through the app's Open, the second selected and the FFT room entered, leave a record that the next launch
    /// reads back from the defaults: the two paths in order, the selected one and the room. Red under: no record written; the order,
    /// the selection or the room not recorded.
    @MainActor func testTheRecordOfTwoOpenFilesComesBackAtTheNextLaunch() async throws {
        let (a, b) = try twoFiles()
        let defaults = try scratchDefaults()
        let state = AppState(launch: LaunchOptions(arguments: []), lastSession: LastSession.stored(in: defaults))
        XCTAssertNil(state.lastSession.previous, "no launch before this one")
        await state.open(urls: [a, b])?.value
        let second = try XCTUnwrap(state.openItems.items.first { $0.url == b })
        state.openItems.select(second.id)
        state.selectWorkspace(.fft)
        XCTAssertEqual(state.navigation.workspaceArea, .fft)

        let record = try XCTUnwrap(LastSession.stored(in: defaults).previous, "the next launch reads the record")
        XCTAssertEqual(record.files.map(\.path), [a.standardizedFileURL.path, b.standardizedFileURL.path])
        XCTAssertEqual(record.files.map(\.displayName), ["a.dm4", "b.dm4"])
        XCTAssertTrue(record.files.allSatisfy { !$0.bookmark.isEmpty }, "each with a bookmark that opens it after a relaunch")
        XCTAssertEqual(record.selectedPath, b.standardizedFileURL.path)
        XCTAssertEqual(record.room, WorkspaceArea.fft.rawValue)
        XCTAssertEqual(state.lastSession.current, record)
    }

    /// The next launch opens nothing by itself; Reopen Last Session with one file deleted since opens the other, lands in the room the
    /// last launch was in, and names the missing one in the status line. Red under: a launch that reopens on its own; one missing file
    /// stopping the others; the missing file not named.
    @MainActor func testReopeningWithOneFileGoneOpensTheOtherAndNamesTheMissingOne() async throws {
        let (a, b) = try twoFiles()
        let defaults = try scratchDefaults()
        let first = AppState(launch: LaunchOptions(arguments: []), lastSession: LastSession.stored(in: defaults))
        await first.open(urls: [a, b])?.value
        first.selectWorkspace(.fft)
        try FileManager.default.removeItem(at: b)

        let next = AppState(launch: LaunchOptions(arguments: []), lastSession: LastSession.stored(in: defaults))
        XCTAssertNotNil(next.lastSession.previous, "the menu offers the last launch's files")
        XCTAssertTrue(next.openItems.items.isEmpty, "nothing is reopened at launch")
        await next.reopenLastSession()?.value
        XCTAssertEqual(next.openItems.items.map(\.url.lastPathComponent), ["a.dm4"], "the file still there is opened")
        XCTAssertEqual(next.navigation.workspaceArea, .fft, "in the room the last launch was in")
        XCTAssertTrue(next.statusText.contains("b.dm4"), next.statusText)
        XCTAssertNotNil(next.lastSession.previous, "a record with a file still there is kept")
    }

    /// A bare `AppState` (a test's, a UI-testing launch's) keeps its record in memory and writes nothing to the standard defaults.
    /// Red under: the bare state writing to `UserDefaults.standard`.
    @MainActor func testABareAppStateWritesNothingToTheStandardDefaults() async throws {
        let (a, _) = try twoFiles()
        let before = UserDefaults.standard.data(forKey: LastSession.defaultsKey)
        let state = AppState(launch: LaunchOptions(arguments: []))
        await state.open(urls: [a])?.value
        state.selectWorkspace(.fft)
        XCTAssertEqual(state.lastSession.current?.files.map(\.displayName), ["a.dm4"], "the record is kept in memory")
        XCTAssertEqual(UserDefaults.standard.data(forKey: LastSession.defaultsKey), before)
        XCTAssertNil(state.lastSession.previous)
        XCTAssertNil(state.reopenLastSession(), "no previous launch, nothing to reopen")
    }
}
