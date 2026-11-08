//
//  RelatedFileAccessTests.swift
//  The sandbox grants the picked file, not the file beside it that a vendor scan is read with (mac4DSTEM#120, ported).
//  RelatedFileAccess asks for the companion as a related item, which macOS allows only for extensions Info.plist declares
//  with NSIsRelatedItemType. These hold the code's list and the built Info.plist together, and pin which sibling each format
//  asks for. Whether the grant works in the sandboxed app is a drive of a signed build on a real .ebsp/.ctf or .up1/.ang
//  pair (every signed build is sandboxed; the unit tests' host is not).
//

import XCTest
@testable import macTEM

nonisolated final class RelatedFileAccessTests: XCTestCase {

    /// Mutation: drop NSIsRelatedItemType from the EBSD type in macTEM/Info.plist, or add a companion to the code's list that
    /// no related type declares - red. Red before: no type was related.
    func testEveryCompanionExtensionIsARelatedItemTypeOfTheBuiltApp() throws {
        // The unit tests are hosted by the app: the bundle that holds `AppDelegate` is macTEM.app.
        let bundle = Bundle(for: AppDelegate.self)
        let types = try XCTUnwrap(bundle.object(forInfoDictionaryKey: "CFBundleDocumentTypes") as? [[String: Any]])
        let related = Set(types.filter { $0["NSIsRelatedItemType"] as? Bool == true }
            .flatMap { $0["CFBundleTypeExtensions"] as? [String] ?? [] })
        let needed = Set(RelatedFileAccess.companionExtensions.values.flatMap { $0 })
        XCTAssertEqual(needed, ["ang", "up1", "up2", "ebsp", "ctf"])
        XCTAssertTrue(needed.isSubset(of: related), "not declared related: \(needed.subtracting(related).sorted())")
    }

    /// Mutation: map "ebsp" to anything but "ctf", forget a direction of a pair, or lose the upper case - red.
    func testEachVendorFileAsksForItsSiblingBesideThePickedFile() {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("related-\(UUID().uuidString)")
        func names(_ file: String) -> [String] {
            RelatedFileAccess.companions(of: folder.appendingPathComponent(file)).map(\.lastPathComponent)
        }
        XCTAssertEqual(names("scan.up1"), ["scan.ang"])
        XCTAssertEqual(names("scan.up2"), ["scan.ang"])
        XCTAssertEqual(names("scan.ang"), ["scan.up1", "scan.up2"])
        XCTAssertEqual(names("scan.ebsp"), ["scan.ctf"])
        XCTAssertEqual(names("scan.ctf"), ["scan.ebsp"])
        XCTAssertEqual(names("SCAN.CTF"), ["SCAN.EBSP"], "an upper-case pair keeps its case")
        XCTAssertEqual(RelatedFileAccess.companions(of: folder.appendingPathComponent("scan.ebsp")).map(\.path),
                       [folder.appendingPathComponent("scan.ctf").path], "the sibling is in the picked file's folder")
        XCTAssertEqual(names("scan.h5"), [])
        XCTAssertEqual(names("scan.dm4"), [])
    }

    /// Outside the sandbox (the test host) the grant is harmless, and a second call for the same file adds nothing.
    func testGrantingTwiceIsHarmless() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("related-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let ebsp = folder.appendingPathComponent("scan.ebsp")
        try Data([0]).write(to: ebsp)
        try Data([0]).write(to: folder.appendingPathComponent("scan.ctf"))
        RelatedFileAccess.grant(for: ebsp)
        RelatedFileAccess.grant(for: ebsp)
        XCTAssertTrue(FileManager.default.isReadableFile(atPath: folder.appendingPathComponent("scan.ctf").path))
    }
}
