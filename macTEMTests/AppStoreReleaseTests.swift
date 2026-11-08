//
//  AppStoreReleaseTests.swift
//  One tag, two builds (macTEM#103): tools/release.sh builds the Developer ID DMG, tools/release-store.sh the App Store
//  package. The export options and the script's guards are files a later edit can quietly break; these read them. Both
//  scripts check the built app through tools/lib/release-checks.sh: the three HDF5 frameworks and the demo files by name,
//  the store app's sandbox entitlements exactly.
//

import XCTest
import TEMSession

nonisolated final class AppStoreReleaseTests: XCTestCase {
    private let root = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath().deletingLastPathComponent()
        .deletingLastPathComponent()

    /// Mutation: method back to "developer-id", destination "upload", or another team - red.
    func testTheStoreExportOptionsExportAnAppStorePackageForTheTeam() throws {
        let url = root.appendingPathComponent("tools/lib/ExportOptions-AppStore.plist")
        let options = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil)
            as? [String: Any])
        XCTAssertEqual(options["method"] as? String, "app-store-connect")
        XCTAssertEqual(options["destination"] as? String, "export", "the export never uploads; --upload is its own step")
        XCTAssertEqual(options["teamID"] as? String, "3B8SMSSAX4")
        XCTAssertEqual(options["signingStyle"] as? String, "automatic")
    }

    /// Mutation: drop a product check, or let the script upload without --upload - red.
    func testTheStoreScriptChecksItsProductAndUploadsOnlyWhenAsked() throws {
        let script = try String(contentsOf: root.appendingPathComponent("tools/release-store.sh"), encoding: .utf8)
        for check in ["MACEM_STORE_BUILD=YES", "ARCHS=arm64", "pkgutil --check-signature", "com.apple.security.app-sandbox",
                      "get-task-allow", "PrivacyInfo.xcprivacy", "ITSAppUsesNonExemptEncryption", "Sparkle.framework",
                      "ExportOptions-AppStore.plist", "describe --exact-match --tags HEAD"] {
            XCTAssertTrue(script.contains(check), "release-store.sh no longer checks \(check)")
        }
        XCTAssertEqual(script.components(separatedBy: "--upload-app").count - 1, 1)
        let guardLine = try XCTUnwrap(script.range(of: "if (( UPLOAD == 1 )); then"))
        let uploadLine = try XCTUnwrap(script.range(of: "--upload-app"))
        XCTAssertLessThan(guardLine.lowerBound, uploadLine.lowerBound, "the upload sits behind --upload")
    }

    /// Both scripts run the shared checks on the app they built, and no framework comes from a (N) glob, which drops a path that
    /// does not exist (the old loops did, so an app that had lost a framework passed). The download's script keeps its tag,
    /// notarization and stapling. Mutation: a script stops sourcing the checks or calling one, or globs a framework again - red.
    func testBothReleaseScriptsRunTheSharedProductChecks() throws {
        for name in ["release.sh", "release-store.sh"] {
            let code = try Self.codeLines(of: root.appendingPathComponent("tools/\(name)"))
            for call in [". \"$ROOT/tools/lib/release-checks.sh\"", "assert_mactem_bundle_arm64_only \"$APP\"",
                         "assert_mactem_demo_data \"$APP\""] {
                XCTAssertTrue(code.contains { $0.hasPrefix(call) }, "\(name) does not run \(call)")
            }
            XCTAssertFalse(code.contains { $0.contains("/Frameworks/") && $0.contains("(N)") },
                           "\(name) takes a framework from a (N) glob")
        }
        let store = try Self.codeLines(of: root.appendingPathComponent("tools/release-store.sh"))
        XCTAssertTrue(store.contains { $0.hasPrefix("assert_mactem_store_entitlements \"$OUT/store-entitlements.plist\"") },
                      "release-store.sh does not check the store app's entitlements exactly")
        let download = try String(contentsOf: root.appendingPathComponent("tools/release.sh"), encoding: .utf8)
        for check in ["describe --exact-match --tags HEAD", "notarytool submit", "stapler staple", "get-task-allow"] {
            XCTAssertTrue(download.contains(check), "release.sh no longer runs \(check)")
        }
    }

    /// The checks name what they check: each HDF5 framework, each shipped demo file (`DemoDocuments.Shipped`), and the store app's
    /// sandbox entitlements as exactly those of macTEM.entitlements, which the store build signs with. Mutation: a framework or a demo
    /// file left out, a (N) glob, an entitlement added to one list and not the other (a network client among them) - red.
    func testTheReleaseChecksNameEachFrameworkDemoFileAndEntitlement() throws {
        let checks = try Self.codeLines(of: root.appendingPathComponent("tools/lib/release-checks.sh"))
        let code = checks.joined(separator: "\n")
        XCTAssertTrue(code.contains("for library in FormatoLibHDF5 FormatoLibSZ FormatoLibAEC; do"), "the three frameworks by name")
        XCTAssertFalse(code.contains("(N)"), "a (N) glob drops a path that does not exist")

        let demoLoop = try XCTUnwrap(checks.first { $0.hasPrefix("for file in ") && $0.hasSuffix("; do") }, "no loop over the demo files")
        let listed = demoLoop.dropFirst("for file in ".count).dropLast("; do".count).split(separator: " ").map(String.init)
        let shipped = DemoDocuments.Shipped.all.map(\.relativePath)
        XCTAssertEqual(listed.count, shipped.count)
        XCTAssertEqual(Set(listed), Set(shipped))

        let url = root.appendingPathComponent("macTEM/macTEM.entitlements")
        let entitlements = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil)
            as? [String: Any])
        let sandbox = entitlements.keys.filter { $0.hasPrefix("com.apple.security.") }.sorted()
        XCTAssertEqual(sandbox, ["com.apple.security.app-sandbox", "com.apple.security.files.bookmarks.app-scope",
                                 "com.apple.security.files.user-selected.read-write"], "the store listing declares these and no network")
        XCTAssertTrue(code.contains("local -a expected=(" + sandbox.joined(separator: " ") + ")"),
                      "the store check's list is not macTEM.entitlements's")
    }

    /// The code lines of a shell script, each without its leading blanks: no blank line, no comment.
    private static func codeLines(of url: URL) throws -> [String] {
        try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
            .map { line in String(line.drop { $0 == " " || $0 == "\t" }) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }
}
