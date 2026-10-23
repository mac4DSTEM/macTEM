//
//  InfoPlistTypesTests.swift
//  Pins the app's declared document types to what it can read: the host app's Info.plist lists exactly
//  `ImageOpening.readableExtensions` (Finder's "Open With" offers macTEM for those and no others). Mutations
//  each test must go red under: an extension dropped from (or added to) macTEM/Info.plist; an extension
//  added to `readableExtensions` alone. Also the launch environment that returns closed files' memory (ADR 012).
//

import XCTest
import TEMCore
@testable import macTEM

nonisolated final class InfoPlistTypesTests: XCTestCase {

    func testDeclaredDocumentExtensionsAreExactlyTheReadableOnes() throws {
        // The unit tests are hosted by the app: the bundle that holds `AppDelegate` is macTEM.app.
        let bundle = Bundle(for: AppDelegate.self)
        let types = try XCTUnwrap(bundle.object(forInfoDictionaryKey: "CFBundleDocumentTypes") as? [[String: Any]])
        let declared = types.flatMap { ($0["CFBundleTypeExtensions"] as? [String]) ?? [] }
        XCTAssertEqual(Set(declared), Set(ImageOpening.readableExtensions))
        XCTAssertEqual(declared.count, Set(declared).count, "an extension is declared once")
    }

    /// A closed file's pixels go back to the system (ADR 012): libmalloc keeps freed large blocks resident as a cache
    /// (1.8 GB with every file closed on the 2026-10-13 drive), and `MallocLargeCache=0`, set for every LaunchServices
    /// launch through `LSEnvironment`, turns that cache off. Xcode and xctest launches do not get it. Mutation: the
    /// `LSEnvironment` entry removed from macTEM/Info.plist, or its value not "0".
    func testLaunchesTurnOffTheLargeAllocationCache() throws {
        let bundle = Bundle(for: AppDelegate.self)
        let environment = try XCTUnwrap(bundle.object(forInfoDictionaryKey: "LSEnvironment") as? [String: String])
        XCTAssertEqual(environment["MallocLargeCache"], "0")
    }
}
