//
//  AppStoreReleaseTests.swift
//  One tag, two builds (macTEM#103): tools/release.sh builds the Developer ID DMG, tools/release-store.sh the App Store
//  package. The export options and the script's guards are files a later edit can quietly break; these read them.
//

import XCTest

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
}
