//
//  AppWindowsTests.swift
//  The app's windows as their states (`AppWindows`, one file per window, 2026-11-10): the front window is the one last brought
//  forward; a window closed with marks not saved is parked and comes back with the next window, one with nothing to lose is let
//  go; the quit question names what every window, open or parked, would lose; the launch's documents go to the first window only;
//  a window's state is made once (`LazyAppState`). The planted fixture (Fixtures/planted-2d.dm4) is copied per test.
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
        XCTAssertEqual(windows.open.count, 2, "a window that appears again is not listed twice")
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
