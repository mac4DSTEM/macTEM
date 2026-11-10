//
//  FolderGrantsTests.swift
//  The grant of a NORDIF scan's folder (`FolderGrants`, asked for by `FolderPanels`): an Open asks for the folder only when the
//  sandbox refuses the `Setting.txt` beside the scan; a grant is kept by the folder's path, as a session sidecar's is
//  (`SessionGrants`), reaches a scan in that folder or below it, and counts only while it resolves to where it was granted. The
//  unit tests' host is not sandboxed, so the sandbox's refusal (EPERM) is the decision's input here: whether the panel's grant
//  opens the scan is a drive of a signed build on a real NORDIF folder. Every `Red under:` names the change to the production code
//  that turns the test red.
//

import XCTest
import Darwin
import Foundation
import TEMCore
import TEMSession
@testable import macTEM

nonisolated final class FolderGrantsTests: XCTestCase {
    private static let nordif = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/sem/nordif")

    /// A fresh folder, removed after the test.
    private func scratch() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("FolderGrantsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    /// A NORDIF acquisition folder, `acquisition` inside a fresh folder, holding the fixture's `Pattern.dat` and `Setting.txt`.
    private func acquisition() throws -> (parent: URL, folder: URL, scan: URL) {
        let parent = try scratch()
        let folder = parent.appendingPathComponent("acquisition", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in ["Pattern.dat", "Setting.txt"] {
            try FileManager.default.copyItem(at: Self.nordif.appendingPathComponent(name), to: folder.appendingPathComponent(name))
        }
        return (parent, folder, folder.appendingPathComponent("Pattern.dat"))
    }

    /// Defaults of their own, removed after the test.
    private func defaults() throws -> UserDefaults {
        let name = "FolderGrantsTests-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: name) }
        return try XCTUnwrap(UserDefaults(suiteName: name))
    }

    /// The decision: the folder is asked for only for a refused scan whose settings file the sandbox would not open. Red under:
    /// `asksForFolder` asking for any refused `.dat` (a file mode, a `.dat` with no settings file beside it, a file that is not a
    /// `.dat`), or for a scan the routing opened.
    func testAnOpenAsksForTheFolderOnlyWhenTheSandboxRefusesTheSettingsFile() {
        XCTAssertTrue(FolderGrants.asksForFolder(refused: true, settingsError: EPERM), "the sandbox's refusal: the folder is asked for")
        XCTAssertFalse(FolderGrants.asksForFolder(refused: false, settingsError: 0), "readable: the scan opens")
        XCTAssertFalse(FolderGrants.asksForFolder(refused: true, settingsError: EACCES), "a file mode, which no grant changes")
        XCTAssertFalse(FolderGrants.asksForFolder(refused: true, settingsError: ENOENT), "no settings file: not NORDIF's")
        XCTAssertFalse(FolderGrants.asksForFolder(refused: true, settingsError: nil), "not a .dat")
        XCTAssertFalse(FolderGrants.asksForFolder(refused: false, settingsError: EPERM), "routed already")
    }

    /// A remembered grant of the scan's folder, or of a folder around it, is found and held for the read, the settings file opens
    /// and nothing is asked; a file in another folder, or one that is not read with its folder, gets none. Red under: `hold` looking
    /// only at the scan's own folder (the grant around it is not found), or holding a grant for any file.
    func testARememberedGrantOfTheFolderOrOneAroundItIsHeldAndNothingIsAsked() throws {
        let (parent, folder, scan) = try acquisition()
        let defaults = try defaults()
        XCTAssertNil(FolderGrants.hold(forFolderOf: scan, defaults: defaults, resolve: { _ in folder }), "nothing stored")

        FolderGrants.store(Data("grant".utf8), forFolder: folder, defaults: defaults)
        let held = try XCTUnwrap(FolderGrants.hold(forFolderOf: scan, defaults: defaults, resolve: { _ in folder }))
        XCTAssertEqual(FolderGrants.path(of: held.url), FolderGrants.path(of: folder))
        XCTAssertEqual(NORDIFOpening.settingsOpenError(scan), 0)
        XCTAssertFalse(FolderGrants.asksForFolder(refused: FileRouting.inventory(path: scan.path).refusal != nil,
                                                  settingsError: NORDIFOpening.settingsOpenError(scan)), "nothing is asked")
        held.release()

        FolderGrants.drop(forFolder: folder, defaults: defaults)
        FolderGrants.store(Data("grant".utf8), forFolder: parent, defaults: defaults)
        let around = try XCTUnwrap(FolderGrants.hold(forFolderOf: scan, defaults: defaults, resolve: { _ in parent }),
                                   "a grant of the folder around it")
        XCTAssertEqual(FolderGrants.path(of: around.url), FolderGrants.path(of: parent))
        around.release()

        XCTAssertNil(FolderGrants.hold(forFolderOf: folder.appendingPathComponent("scan.dm4"), defaults: defaults, resolve: { _ in parent }),
                     "a file that is not read with its folder")
        let elsewhere = try scratch().appendingPathComponent("Pattern.dat")
        XCTAssertNil(FolderGrants.hold(forFolderOf: elsewhere, defaults: defaults, resolve: { _ in parent }), "a scan in another folder")
    }

    /// A grant counts only while it resolves to the folder it was granted for: a bookmark follows a folder that was moved or
    /// renamed, and that folder is not around the scan any more. Such a grant is dropped, as a session file's is. Red under: the
    /// path check dropped from `grantedFolder` (the moved folder is held), or a grant that does not resolve kept.
    func testAGrantThatResolvesElsewhereOrNotAtAllIsDropped() throws {
        let folder = try scratch()
        let other = try scratch()
        let scan = folder.appendingPathComponent("Pattern.dat")
        let defaults = try defaults()
        let path = FolderGrants.path(of: folder)
        XCTAssertEqual(FolderGrants.grantedFolder(Data(), path: path, resolve: { _ in folder }), folder)
        XCTAssertNil(FolderGrants.grantedFolder(Data(), path: path, resolve: { _ in other }), "moved")
        XCTAssertNil(FolderGrants.grantedFolder(Data(), path: path, resolve: { _ in nil }), "unresolved")

        FolderGrants.store(Data("grant".utf8), forFolder: folder, defaults: defaults)
        XCTAssertNil(FolderGrants.hold(forFolderOf: scan, defaults: defaults, resolve: { _ in other }))
        XCTAssertNil(FolderGrants.bookmark(forFolder: folder, defaults: defaults), "the moved grant is dropped")
        FolderGrants.store(Data("grant".utf8), forFolder: folder, defaults: defaults)
        XCTAssertNil(FolderGrants.hold(forFolderOf: scan, defaults: defaults, resolve: { _ in nil }))
        XCTAssertNil(FolderGrants.bookmark(forFolder: folder, defaults: defaults), "the unresolved grant is dropped")
    }

    /// The store records, finds and drops a folder's bookmark by the folder's path, as `SessionGrants` does an image's. Red under:
    /// `store(nil, …)` keeping the old grant; a key that is not the folder's path (another folder finds it, or the same folder
    /// written another way does not).
    func testTheStoreRecordsAndDropsAFoldersGrantByItsPath() throws {
        let folder = try scratch()
        let other = try scratch()
        let defaults = try defaults()
        XCTAssertNil(FolderGrants.bookmark(forFolder: folder, defaults: defaults))
        FolderGrants.store(Data("grant".utf8), forFolder: folder, defaults: defaults)
        XCTAssertEqual(FolderGrants.bookmark(forFolder: folder, defaults: defaults), Data("grant".utf8))
        XCTAssertEqual(FolderGrants.bookmark(forFolder: folder.appendingPathComponent("."), defaults: defaults), Data("grant".utf8),
                       "the same folder, written another way")
        XCTAssertNil(FolderGrants.bookmark(forFolder: other, defaults: defaults))
        FolderGrants.store(nil, forFolder: folder, defaults: defaults)
        XCTAssertNil(FolderGrants.bookmark(forFolder: folder, defaults: defaults), "nil drops the grant")
    }

    /// End to end with a real security-scoped bookmark of the folder (what the panel's choice is kept as): stored, it is held for
    /// the scan through the system's resolver; once the folder has moved, the bookmark follows it, the grant is dropped and nothing
    /// is held. Red under: the path check dropped from `grantedFolder` (the moved folder is held).
    func testARealFolderBookmarkIsHeldWhereItWasMadeAndDroppedOnceTheFolderMoves() throws {
        let (parent, folder, scan) = try acquisition()
        guard let bookmark = try? SecurityScopedBookmark.make(for: folder) else {
            throw XCTSkip("this host cannot make a security-scoped bookmark")
        }
        let defaults = try defaults()
        FolderGrants.store(bookmark, forFolder: folder, defaults: defaults)
        let held = try XCTUnwrap(FolderGrants.hold(forFolderOf: scan, defaults: defaults))
        XCTAssertEqual(FolderGrants.path(of: held.url), FolderGrants.path(of: folder))
        held.release()

        try FileManager.default.moveItem(at: folder, to: parent.appendingPathComponent("moved", isDirectory: true))
        XCTAssertNil(FolderGrants.hold(forFolderOf: scan, defaults: defaults), "the folder moved: no grant reaches the scan")
        XCTAssertNil(FolderGrants.bookmark(forFolder: folder, defaults: defaults), "the grant is dropped")
    }

    /// The panel takes the scan's folder or one around it and refuses any other with a sentence that names the folder; its
    /// message says what is asked for and why. Red under: `panelRefusal` taking any folder, or refusing the one around the scan.
    func testThePanelTakesTheScansFolderOrOneAroundIt() throws {
        let (parent, folder, scan) = try acquisition()
        let other = try scratch()
        XCTAssertNil(FolderGrants.panelRefusal(chosen: folder, file: scan))
        XCTAssertNil(FolderGrants.panelRefusal(chosen: parent, file: scan), "a folder around it")
        let sentence = "Choose “acquisition”, the folder that holds Pattern.dat, or a folder around it."
        XCTAssertEqual(FolderGrants.panelRefusal(chosen: other, file: scan), sentence, "another folder")
        XCTAssertEqual(FolderGrants.panelRefusal(chosen: folder.appendingPathComponent("inner", isDirectory: true), file: scan), sentence,
                       "a folder inside it")
        let ask = FolderGrants.askSentence(for: scan)
        XCTAssertTrue(ask.contains("“acquisition”") && ask.contains("Setting.txt") && ask.contains("Pattern.dat"), ask)
    }

    /// The Open's routing asks for no folder for a scan whose settings file a file mode refuses (it keeps the refusal that names
    /// the settings file: no folder grant changes a file mode), nor for a readable scan (the Patterns room's). Red under:
    /// `inventories` setting `asksForFolder` from the refusal alone.
    func testTheRoutingAsksForNoFolderForAFileModeOrAReadableScan() async throws {
        XCTAssertNotEqual(geteuid(), 0, "root reads a mode-000 file; run this as a user")
        let (_, folder, scan) = try acquisition()
        let routed = await AppState.inventories([scan])
        let readable = try XCTUnwrap(routed.first)
        XCTAssertEqual(readable.inventory, FileInventory(ebsdPatterns: true))
        XCTAssertFalse(readable.asksForFolder)

        let settings = folder.appendingPathComponent("Setting.txt")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: settings.path)
        addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: settings.path) }
        let again = await AppState.inventories([scan])
        let refused = try XCTUnwrap(again.first)
        XCTAssertNotNil(refused.inventory.refusal)
        XCTAssertEqual(refused.inventory.refusal, NORDIFOpening.unreadableSettingsRefusal(scan))
        XCTAssertFalse(refused.asksForFolder, "a file mode is not the sandbox's")
    }
}
