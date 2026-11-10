//
//  RecentFilesTests.swift
//  Pins File > Open Recent: the list (`RecentFiles`, TEMSession; mac4DSTEM's RecentDatasetsTests, for files) and the app's side of
//  it (`AppState.open(urls:)` remembers a file it takes in and not one it refuses; `openRecent` opens an entry again and drops one
//  whose file is gone). Saving is injected as a recorder or as defaults of the test's own, so no test reads or writes a person's
//  recents. Red before: no `RecentFiles`, no `recents`, no `openRecent`.
//

import XCTest
import TEMCore
import TEMSession
@testable import macTEM

nonisolated final class RecentFilesTests: XCTestCase {

    /// Every list the store was told, in order.
    private final class Recorder {
        var saved: [[RecentFile]] = []
    }

    @MainActor private func makeList(_ entries: [RecentFile] = []) -> (list: RecentFiles, recorder: Recorder) {
        let recorder = Recorder()
        let list = RecentFiles(entries: entries) { recorder.saved.append($0) }
        return (list, recorder)
    }

    private func entry(_ path: String, bookmark: Data = Data()) -> RecentFile {
        RecentFile(path: path, displayName: URL(fileURLWithPath: path).lastPathComponent, bookmark: bookmark)
    }

    // MARK: The list

    /// A file remembered goes first and the list is saved. Red under: `remember` appending at the end; `save` not called.
    @MainActor func testRememberPutsTheFileFirstAndSavesTheList() {
        let (list, recorder) = makeList([entry("/data/old.dm4")])
        list.remember(entry("/data/new.dm4"))
        XCTAssertEqual(list.entries.map(\.path), ["/data/new.dm4", "/data/old.dm4"])
        XCTAssertEqual(recorder.saved.last?.map(\.path), ["/data/new.dm4", "/data/old.dm4"], "the change reaches the store, or a relaunch forgets it")
    }

    /// Opening a file again moves its entry to the front instead of adding a second one, with the newer bookmark.
    @MainActor func testRememberingAKnownPathMovesItInsteadOfAddingIt() {
        let (list, _) = makeList([entry("/data/a.dm4"), entry("/data/b.dm4", bookmark: Data([1]))])
        list.remember(entry("/data/b.dm4", bookmark: Data([2])))
        XCTAssertEqual(list.entries.map(\.path), ["/data/b.dm4", "/data/a.dm4"])
        XCTAssertEqual(list.entries.first?.bookmark, Data([2]), "the bookmark made last")
    }

    /// The list keeps eight, the oldest goes, and the saved list is cut too. Red under: no cap; the cap applied after the save.
    @MainActor func testTheListKeepsEightAndDropsTheOldest() {
        let (list, recorder) = makeList((0..<RecentFiles.capacity).map { entry("/data/\($0).dm4") })
        list.remember(entry("/data/newest.dm4"))
        XCTAssertEqual(RecentFiles.capacity, 8)
        XCTAssertEqual(list.entries.count, 8)
        XCTAssertEqual(list.entries.first?.path, "/data/newest.dm4")
        XCTAssertFalse(list.entries.contains { $0.path == "/data/7.dm4" }, "the oldest entry is the one that goes")
        XCTAssertEqual(recorder.saved.last?.count, 8, "the cap reaches the store, not only the list in memory")
    }

    /// Removing a path that is not listed and clearing an empty list save nothing; a removal and a clear that change the list save it.
    @MainActor func testRemoveAndClearSaveOnlyWhenTheListChanges() {
        let (list, recorder) = makeList([entry("/data/a.dm4"), entry("/data/b.dm4")])
        list.remove(path: "/data/never-there.dm4")
        XCTAssertTrue(recorder.saved.isEmpty, "a miss saves nothing")
        list.remove(path: "/data/a.dm4")
        XCTAssertEqual(recorder.saved.last?.map(\.path), ["/data/b.dm4"])
        list.clear()
        XCTAssertTrue(list.entries.isEmpty)
        XCTAssertEqual(recorder.saved.count, 2)
        XCTAssertEqual(recorder.saved.last, [], "Clear Menu reaches the store")
        list.clear()
        XCTAssertEqual(recorder.saved.count, 2, "clearing an empty list saves nothing")
    }

    /// A store that holds one path twice (a damaged or hand-edited list) and more than eight entries is read without a crash: each path
    /// once, the first kept, eight at most. Red under: the read keeping both (two menu rows for one file, on which a
    /// `Dictionary(uniqueKeysWithValues:)` for the titles would trap); no cap at the read.
    @MainActor func testADuplicatePathInTheStoredListIsOneEntry() {
        let twice = [entry("/data/a.dm4", bookmark: Data([1])), entry("/data/a.dm4", bookmark: Data([2]))]
        let saved = twice + (0..<9).map { entry("/data/\($0).dm4") }
        let (list, recorder) = makeList(saved)
        XCTAssertEqual(list.entries.count, 8)
        XCTAssertEqual(list.entries.filter { $0.path == "/data/a.dm4" }.count, 1)
        XCTAssertEqual(list.entries.first?.bookmark, Data([1]), "the first, the newest, is kept")
        XCTAssertEqual(list.title(of: list.entries[0]), "a.dm4")
        XCTAssertTrue(recorder.saved.isEmpty, "reading the list saves nothing")
    }

    /// The list kept in defaults comes back as it was left, from a store of the test's own.
    @MainActor func testTheStoredListComesBackFromItsDefaults() throws {
        let suite = "mactem-recent-files-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = RecentFiles.stored(in: defaults)
        XCTAssertTrue(first.entries.isEmpty)
        first.remember(entry("/data/a.dm4", bookmark: Data([1])))
        first.remember(entry("/data/b.dm4", bookmark: Data([2])))
        let again = RecentFiles.stored(in: defaults)
        XCTAssertEqual(again.entries, first.entries, "a relaunch reads the list as it was left")
        XCTAssertTrue(RecentFiles().entries.isEmpty, "a bare list starts empty: it reads no defaults")
    }

    // MARK: The titles

    /// Two files of one name are told apart by as many of their folders as it takes; a name of its own is the name alone; two paths that
    /// differ only above the root of the shorter one keep the whole path. Red under: the file name alone for every entry.
    func testTwoFilesOfOneNameAreToldApartByTheirFolders() {
        XCTAssertEqual(RecentFiles.menuTitles(for: ["/data/a.dm4", "/data/b.dm4"]), ["a.dm4", "b.dm4"])
        XCTAssertEqual(RecentFiles.menuTitles(for: ["/data/2026-11/scan.dm4", "/data/2026-10/scan.dm4", "/data/x.dm4"]),
                       ["2026-11/scan.dm4", "2026-10/scan.dm4", "x.dm4"])
        XCTAssertEqual(RecentFiles.menuTitles(for: ["/Volumes/NAS/inbox/scan.dm4", "/Users/paul/inbox/scan.dm4"]),
                       ["NAS/inbox/scan.dm4", "paul/inbox/scan.dm4"], "the parent folder alone is shared: one more")
        XCTAssertEqual(RecentFiles.menuTitles(for: ["/a/x.tif", "/b/a/x.tif"]), ["/a/x.tif", "b/a/x.tif"])
    }

    /// The titles follow the list: once no other entry shares the name, the name alone. Red under: titles made once, at the init.
    @MainActor func testTheTitlesFollowTheList() {
        let (list, _) = makeList([entry("/data/2026-11/scan.dm4"), entry("/data/2026-10/scan.dm4")])
        XCTAssertEqual(list.title(of: list.entries[0]), "2026-11/scan.dm4")
        XCTAssertEqual(list.title(of: list.entries[1]), "2026-10/scan.dm4")
        list.remove(path: "/data/2026-10/scan.dm4")
        XCTAssertEqual(list.title(of: list.entries[0]), "scan.dm4")
    }

    /// An entry on a disk under /Volumes that is not connected names that disk (its entry is kept); on a connected disk, or on the
    /// startup disk, nothing (a file that does not resolve there is gone).
    func testAFileOnADiskThatIsNotConnectedNamesTheDisk() {
        XCTAssertEqual(RecentFiles.absentVolume(of: "/Volumes/NAS/inbox/scan.dm4", exists: { _ in false }), "NAS")
        XCTAssertNil(RecentFiles.absentVolume(of: "/Volumes/NAS/inbox/scan.dm4", exists: { _ in true }))
        XCTAssertNil(RecentFiles.absentVolume(of: "/Users/paul/scan.dm4", exists: { _ in false }))
    }

    // MARK: Through the app's Open

    /// The app's Open remembers a file it takes in, with a bookmark, and not a file it refuses; Open Recent of the entry opens the file
    /// again (one entry still); an entry whose bookmark no longer resolves leaves the list and the status line names it. Red under:
    /// `open(urls:)` remembering nothing, or remembering refused files; `openRecent` keeping a dead entry.
    @MainActor func testTheAppsOpenRemembersWhatItOpensAndOpenRecentOpensItAgain() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("recent-files-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let image = folder.appendingPathComponent("planted.dm4")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: FileRoutingTests.fixture("planted-2d.dm4")), to: image)
        let refused = folder.appendingPathComponent("notes.xyz")
        try Data("hello".utf8).write(to: refused)

        let state = AppState(launch: LaunchOptions(arguments: []))
        XCTAssertTrue(state.recents.entries.isEmpty)
        await state.open(urls: [refused])?.value
        XCTAssertTrue(state.recents.entries.isEmpty, "a refused file is not remembered")
        await state.open(urls: [image])?.value
        XCTAssertEqual(state.recents.entries.map(\.displayName), ["planted.dm4"])
        let entry = try XCTUnwrap(state.recents.entries.first)
        XCTAssertFalse(entry.bookmark.isEmpty, "a bookmark that opens it after a relaunch")

        state.openItems.closeSelected()
        XCTAssertTrue(state.openItems.items.isEmpty)
        await state.openRecent(entry)?.value
        XCTAssertEqual(state.openItems.items.count, 1, "Open Recent opened the file again")
        XCTAssertEqual(state.recents.entries.map(\.displayName), ["planted.dm4"], "and it is one entry still")

        let gone = RecentFile(path: folder.appendingPathComponent("gone.dm4").path, displayName: "gone.dm4", bookmark: Data([1, 2, 3]))
        state.recents.remember(gone)
        let task = state.openRecent(gone)
        XCTAssertNil(task, "nothing to open")
        XCTAssertEqual(state.recents.entries.map(\.displayName), ["planted.dm4"], "a file that is gone leaves the list")
        XCTAssertTrue(state.statusText.contains("gone.dm4"), state.statusText)
        XCTAssertEqual(state.errorMessage?.contains("gone.dm4"), true, "the alert says it, not the status line alone")
    }
}
