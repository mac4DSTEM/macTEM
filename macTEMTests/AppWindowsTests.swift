//
//  AppWindowsTests.swift
//  The app's windows as their states (`AppWindows`, one file per window, 2026-11-10): the front window is the one last brought
//  forward; a window closed with marks not saved is parked and comes back with the next window, one with nothing to lose is let
//  go; the quit question names what every window, open or parked, would lose; the launch's documents go to the first window only;
//  a window's state is made once (`LazyAppState`); a batch is split one file per window, a second file gets a tab of its own, the
//  last-session record covers every window. The planted fixture (Fixtures/planted-2d.dm4) is copied per test.
//

import XCTest
import ImagoCore
@testable import macTEM
import TEMCore
import TEMSession

nonisolated final class AppWindowsTests: XCTestCase {

    private func plantedCopy(named name: String) throws -> URL {
        let source = try XCTUnwrap(Bundle(for: AppWindowsTests.self).url(forResource: "planted-2d", withExtension: "dm4"),
                                   "planted-2d.dm4 is not in the test bundle")
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mactem-windows-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent(name)
        try FileManager.default.copyItem(at: source, to: url)
        return url
    }

    /// A window's state with one file open and one distance drawn on it: its marks are not saved.
    @MainActor private func dirtyState(named name: String) async throws -> AppState {
        let state = AppState(launch: LaunchOptions(arguments: []))
        await state.open(urls: [try plantedCopy(named: name)])?.value
        let item = try XCTUnwrap(state.openItems.selected)
        let image = try XCTUnwrap(item.session.image, "the file is read")
        XCTAssertNil(item.measurements.add(ImageMark(kind: .distance, points: [ImagePoint(x: 1, y: 1), ImagePoint(x: 4, y: 3)]), on: image))
        return state
    }

    /// Red under: the front window staying the first one; a closed front window still named as front.
    @MainActor func testTheFrontWindowIsTheOneLastBroughtForward() {
        let windows = AppWindows()
        let a = AppState(launch: LaunchOptions(arguments: [])), b = AppState(launch: LaunchOptions(arguments: []))
        XCTAssertNil(windows.front)
        windows.enroll(a)
        windows.enroll(b)
        XCTAssertTrue(windows.front === b)
        windows.bringForward(a)
        XCTAssertTrue(windows.front === a)
        windows.enroll(a)
        XCTAssertEqual(windows.onScreen.count, 2, "a window that appears again is not listed twice")
        windows.withdraw(a)
        XCTAssertTrue(windows.front === b, "the front window closed: the one left is in front")
        windows.withdraw(b)
        XCTAssertNil(windows.front)
        XCTAssertTrue(windows.parked.isEmpty, "windows with nothing to lose are let go")
    }

    /// Red under: a window closed with unsaved marks released (its marks lost); the parked state not handed to the next window;
    /// the quit question leaving a parked window out.
    @MainActor func testAWindowClosedWithUnsavedMarksIsParkedAndComesBack() async throws {
        let windows = AppWindows()
        let dirty = try await dirtyState(named: "a.dm4")
        let clean = AppState(launch: LaunchOptions(arguments: []))
        windows.enroll(dirty)
        windows.enroll(clean)
        XCTAssertEqual(windows.quitQuestion, "The marks on “a.dm4” are not saved to its session file.")
        windows.withdraw(dirty)
        XCTAssertEqual(windows.parked.count, 1)
        XCTAssertEqual(windows.quitQuestion, "The marks on “a.dm4” are not saved to its session file.", "a parked window is still asked about")
        var made = 0
        let next = windows.stateForNewWindow { made += 1; return AppState(launch: LaunchOptions(arguments: [])) }
        XCTAssertTrue(next === dirty, "the next window takes the parked one over")
        XCTAssertEqual(made, 0)
        XCTAssertTrue(windows.parked.isEmpty)
        let fresh = windows.stateForNewWindow { made += 1; return AppState(launch: LaunchOptions(arguments: [])) }
        XCTAssertFalse(fresh === dirty)
        XCTAssertEqual(made, 1)
    }

    /// Red under: two windows' files not both named.
    @MainActor func testTheQuitQuestionNamesEveryWindowsFiles() async throws {
        let windows = AppWindows()
        windows.enroll(try await dirtyState(named: "a.dm4"))
        windows.enroll(try await dirtyState(named: "b.dm4"))
        XCTAssertEqual(windows.quitQuestion, "The marks on “a.dm4” and “b.dm4” are not saved to their session files.")
        XCTAssertNil(AppWindows().quitQuestion)
    }

    /// Red under: a second window opening the launch's demo again; a second window losing the UI-testing flag or the export folder.
    @MainActor func testTheLaunchDocumentsGoToTheFirstWindowOnly() {
        let windows = AppWindows()
        let launch = LaunchOptions(arguments: ["--ui-testing", "--demo-fixture", "--open", "/tmp/a.dm4", "--appearance", "light", "--export-dir", "out"])
        XCTAssertEqual(windows.launchOptionsForNewWindow(launch), launch)
        let second = windows.launchOptionsForNewWindow(launch)
        XCTAssertFalse(second.demoImage)
        XCTAssertTrue(second.openFiles.isEmpty)
        XCTAssertTrue(second.isUITesting)
        XCTAssertEqual(second.appearance, "light")
        XCTAssertEqual(second.exportDirectoryName, "out")
        XCTAssertEqual(second.exportDirectory, launch.exportDirectory)
    }

    /// A Finder open goes to the window in front; with none on screen it waits for the window it brings up, once. Red under: the
    /// batch dropped with no window, or handed over twice.
    @MainActor func testAFinderOpenGoesToTheFrontWindowOrWaitsForOne() async throws {
        let windows = AppWindows()
        let url = try plantedCopy(named: "a.dm4")
        windows.deliver(urls: [url])
        XCTAssertEqual(windows.takeWaitingURLs(), [url])
        XCTAssertNil(windows.takeWaitingURLs())
        let a = AppState(launch: LaunchOptions(arguments: [])), b = AppState(launch: LaunchOptions(arguments: []))
        windows.enroll(a)
        windows.enroll(b)
        windows.bringForward(a)
        windows.deliver(urls: [url])
        await a.lastOpen?.value
        XCTAssertEqual(a.openItems.items.map(\.url), [url])
        XCTAssertTrue(b.openItems.items.isEmpty)
        XCTAssertNil(windows.takeWaitingURLs())
    }

    /// One file per window: an empty window takes a batch's first file and each other file gets a tab; a window that holds a file,
    /// or has an Open on its way in, takes none but the files it holds already. Red under: a batch of three in one window; a file
    /// the window holds opened a second time in a tab.
    func testABatchIsSplitOneFilePerWindow() {
        func url(_ name: String) -> URL { URL(fileURLWithPath: "/tmp/mactem-per-window/\(name)") }
        let a = url("a.dm4"), b = url("b.dm4"), c = url("c.dm4")
        let empty = OpenBatch.perWindow([a, b, c], held: [], windowIsTaken: false)
        XCTAssertEqual(empty.here, [a])
        XCTAssertEqual(empty.elsewhere, [b, c])
        let taken = OpenBatch.perWindow([b, c], held: [a.standardizedFileURL.path], windowIsTaken: true)
        XCTAssertEqual(taken.here, [])
        XCTAssertEqual(taken.elsewhere, [b, c])
        let again = OpenBatch.perWindow([a, b], held: [a.standardizedFileURL.path], windowIsTaken: true)
        XCTAssertEqual(again.here, [a], "a file the window holds is selected there, not opened in a tab")
        XCTAssertEqual(again.elsewhere, [b])
    }

    /// A second file opened into a window that holds one asks for a new window and waits for it as its own batch; a file another
    /// window holds comes forward there and no window is asked for; a state no window shows takes everything, as before. Red under:
    /// both files as rows of one window; a window opened for a file that is open already.
    @MainActor func testAFileOpenedIntoATakenWindowGetsATabOfItsOwn() async throws {
        let windows = AppWindows()
        var asked = 0
        windows.openWindow = { asked += 1 }
        let a = try plantedCopy(named: "a.dm4"), b = try plantedCopy(named: "b.dm4"), c = try plantedCopy(named: "c.dm4")
        let first = AppState(launch: LaunchOptions(arguments: []))
        windows.enroll(first)
        await first.open(urls: [a, b])?.value
        XCTAssertEqual(first.openItems.items.map(\.url), [a], "the window keeps one file")
        XCTAssertEqual(asked, 1)
        // The window the app opened for b: it takes b's batch, as `ImageWindow` does when it appears.
        let second = AppState(launch: LaunchOptions(arguments: []))
        windows.enroll(second)
        await second.open(urls: try XCTUnwrap(windows.takeWaitingURLs()))?.value
        XCTAssertEqual(second.openItems.items.map(\.url), [b])
        XCTAssertNil(windows.takeWaitingURLs())
        XCTAssertEqual(asked, 1)

        var shown = 0
        first.showWindow = { shown += 1 }
        second.open(urls: [a])
        await first.lastOpen?.value
        XCTAssertEqual(asked, 1, "a is open in the first window: no new window")
        XCTAssertEqual(shown, 1, "its window comes forward")
        XCTAssertEqual(second.openItems.items.map(\.url), [b])

        second.open(urls: [c])
        XCTAssertEqual(asked, 2)
        XCTAssertEqual(windows.takeWaitingURLs(), [c])

        let alone = AppState(launch: LaunchOptions(arguments: []))
        await alone.open(urls: [a, b])?.value
        XCTAssertEqual(alone.openItems.items.map(\.url), [a, b], "a state no window shows takes the whole batch")
    }

    /// The last-session record covers every window on screen, in their order, and drops a closed window's file. Red under: the
    /// record holding only the file of the window that changed last.
    @MainActor func testTheLastSessionRecordCoversEveryWindow() async throws {
        let windows = AppWindows()
        let session = LastSession()
        let a = try plantedCopy(named: "a.dm4"), b = try plantedCopy(named: "b.dm4")
        let first = AppState(launch: LaunchOptions(arguments: []), lastSession: session)
        let second = AppState(launch: LaunchOptions(arguments: []), lastSession: session)
        windows.enroll(first)
        windows.enroll(second)
        await first.open(urls: [a])?.value
        await second.open(urls: [b])?.value
        XCTAssertEqual(session.current?.files.map(\.path), [a.standardizedFileURL.path, b.standardizedFileURL.path])
        XCTAssertEqual(session.current?.selectedPath, b.standardizedFileURL.path)
        windows.withdraw(second)
        XCTAssertEqual(session.current?.files.map(\.path), [a.standardizedFileURL.path])
    }

    /// A window asked for by `openInTabs` is a tab request, taken once by the window that comes up; a file another window holds asks
    /// for none. Red under: the new window left a window of its own (driven 2026-11-10); every new window, New Window too, made a tab.
    @MainActor func testOnlyAWindowOpenedForAFileIsMadeATab() async throws {
        let windows = AppWindows()
        windows.openWindow = {}
        XCTAssertFalse(windows.takeTabRequest(), "File > New Window and a restored window stay windows of their own")
        let a = try plantedCopy(named: "a.dm4"), b = try plantedCopy(named: "b.dm4")
        let first = AppState(launch: LaunchOptions(arguments: []))
        windows.enroll(first)
        await first.open(urls: [a, b])?.value
        XCTAssertTrue(windows.takeTabRequest(), "b's window is a tab")
        XCTAssertFalse(windows.takeTabRequest(), "once")
        first.open(urls: [a])
        XCTAssertFalse(windows.takeTabRequest(), "a is open here: no window, no tab")
    }

    /// Quitting closes every window: the record keeps them all. Red under: the record left with the last window's file (driven
    /// 2026-11-10: Reopen Last Session brought back one of two files).
    @MainActor func testQuittingKeepsEveryWindowInTheLastSession() async throws {
        let windows = AppWindows()
        let session = LastSession()
        let a = try plantedCopy(named: "a.dm4"), b = try plantedCopy(named: "b.dm4")
        let first = AppState(launch: LaunchOptions(arguments: []), lastSession: session)
        let second = AppState(launch: LaunchOptions(arguments: []), lastSession: session)
        windows.enroll(first)
        windows.enroll(second)
        await first.open(urls: [a])?.value
        await second.open(urls: [b])?.value
        windows.isTerminating = true
        windows.withdraw(first)
        windows.withdraw(second)
        XCTAssertEqual(session.current?.files.map(\.path), [a.standardizedFileURL.path, b.standardizedFileURL.path])
    }

    /// Red under: a state built before it is asked for, or built twice.
    @MainActor func testAWindowsStateIsMadeOnce() {
        var made = 0
        let holder = LazyAppState { made += 1; return AppState(launch: LaunchOptions(arguments: [])) }
        XCTAssertFalse(holder.isBuilt)
        XCTAssertEqual(made, 0)
        let first = holder.state
        XCTAssertTrue(holder.state === first)
        XCTAssertEqual(made, 1)
        XCTAssertTrue(holder.isBuilt)
    }
}
