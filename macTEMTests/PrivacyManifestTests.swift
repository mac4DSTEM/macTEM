//
//  PrivacyManifestTests.swift
//  App Store Connect rejects an upload whose bundle uses a required-reason API without a privacy manifest, and asks the
//  export-compliance question on every build unless Info.plist answers it (macTEM#101). These read the BUILT host app.
//

import XCTest

nonisolated final class PrivacyManifestTests: XCTestCase {

    /// Mutation: delete macTEM/PrivacyInfo.xcprivacy, or drop its UserDefaults entry - red.
    func testTheAppDeclaresNoTrackingAndItsRequiredReasons() throws {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/PrivacyInfo.xcprivacy")
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil)
            as? [String: Any])
        XCTAssertEqual(plist["NSPrivacyTracking"] as? Bool, false)
        XCTAssertEqual((plist["NSPrivacyCollectedDataTypes"] as? [Any])?.count, 0)
        let types = (plist["NSPrivacyAccessedAPITypes"] as? [[String: Any]]) ?? []
        let reasons = Dictionary(uniqueKeysWithValues: types.compactMap { entry -> (String, [String])? in
            guard let type = entry["NSPrivacyAccessedAPIType"] as? String else { return nil }
            return (type, entry["NSPrivacyAccessedAPITypeReasons"] as? [String] ?? [])
        })
        XCTAssertEqual(reasons["NSPrivacyAccessedAPICategoryUserDefaults"], ["CA92.1"])
        XCTAssertTrue(reasons["NSPrivacyAccessedAPICategoryFileTimestamp"]?.contains("3B52.1") == true)
    }

    /// Mutation: remove the key from macTEM/Info.plist - red.
    func testTheAppDeclaresNoNonExemptEncryption() {
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "ITSAppUsesNonExemptEncryption") as? Bool, false)
    }
}
