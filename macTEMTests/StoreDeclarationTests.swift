//
//  StoreDeclarationTests.swift
//  What the store is told against what the code does (#351). App Store Connect rejects an upload that calls a required-reason
//  API its privacy manifest does not declare, and the store's privacy answer and SECURITY.md rest on the app having no network client
//  entitlement. PrivacyManifestTests checks that the BUILT app's manifest holds today's reasons; these read the sources, the
//  manifest and the entitlements beside this test file, so a new call or a new entitlement goes red here before an upload does.
//  The kits' and MacEMUI's sources are other repositories and are not scanned.
//

import XCTest

nonisolated final class StoreDeclarationTests: XCTestCase {
    private let root = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath().deletingLastPathComponent()
        .deletingLastPathComponent()

    /// Apple's required-reason API families: the manifest category and the names that fall under it. A name ending in `(` is a
    /// call or an initialiser (`stat()` makes the struct `lstat` fills); the others are properties and resource keys, in both
    /// their key and their value spelling. `getattrlist`'s family serves two categories and is listed under the file timestamps.
    /// `@AppStorage` is SwiftUI's wrapper over UserDefaults.
    private static let families: [(category: String, symbols: [String])] = [
        ("NSPrivacyAccessedAPICategoryFileTimestamp",
         ["creationDate", "creationDateKey", "modificationDate", "fileModificationDate", "contentModificationDate",
          "contentModificationDateKey", "getattrlist(", "getattrlistbulk(", "fgetattrlist(", "getattrlistat(",
          "stat(", "fstat(", "fstatat(", "lstat("]),
        ("NSPrivacyAccessedAPICategorySystemBootTime", ["systemUptime", "mach_absolute_time("]),
        ("NSPrivacyAccessedAPICategoryDiskSpace",
         ["volumeAvailableCapacity", "volumeAvailableCapacityKey", "volumeAvailableCapacityForImportantUsage",
          "volumeAvailableCapacityForImportantUsageKey", "volumeAvailableCapacityForOpportunisticUsage",
          "volumeAvailableCapacityForOpportunisticUsageKey", "volumeTotalCapacity", "volumeTotalCapacityKey",
          "systemFreeSize", "systemSize", "statfs(", "statvfs(", "fstatfs(", "fstatvfs("]),
        ("NSPrivacyAccessedAPICategoryActiveKeyboards", ["activeInputModes"]),
        ("NSPrivacyAccessedAPICategoryUserDefaults", ["UserDefaults", "AppStorage"])
    ]

    /// The privacy manifest's categories and their reasons, read from the file the build copies into the app.
    private func declaredReasons() throws -> [String: [String]] {
        let url = root.appendingPathComponent("macTEM/PrivacyInfo.xcprivacy")
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil)
            as? [String: Any])
        let types = try XCTUnwrap(plist["NSPrivacyAccessedAPITypes"] as? [[String: Any]])
        var reasons: [String: [String]] = [:]
        for entry in types {
            let type = try XCTUnwrap(entry["NSPrivacyAccessedAPIType"] as? String)
            reasons[type] = entry["NSPrivacyAccessedAPITypeReasons"] as? [String] ?? []
        }
        return reasons
    }

    /// A source file's code: each line up to its `//` comment, where the `//` is not inside a string literal on that line. A name
    /// in a comment is not a use (a note on why a call is avoided must not ask for a manifest entry), so comments are left out;
    /// a name in a string literal stays in and counts. The sources hold no block comments, so none are read.
    private static func code(of source: String) -> String {
        let bytes = Array(source.utf8)
        var kept: [UInt8] = []
        kept.reserveCapacity(bytes.count)
        var inString = false
        var escaped = false
        var inComment = false
        for (index, byte) in bytes.enumerated() {
            if byte == UInt8(ascii: "\n") {
                inString = false
                escaped = false
                inComment = false
            } else if inComment {
                continue
            } else if inString {
                if escaped {
                    escaped = false
                } else if byte == UInt8(ascii: "\\") {
                    escaped = true
                } else if byte == UInt8(ascii: "\"") {
                    inString = false
                }
            } else if byte == UInt8(ascii: "\"") {
                inString = true
            } else if byte == UInt8(ascii: "/"), index + 1 < bytes.count, bytes[index + 1] == UInt8(ascii: "/") {
                inComment = true
                continue
            }
            kept.append(byte)
        }
        return String(decoding: kept, as: UTF8.self)
    }

    /// The whole names in `code`: each run of ASCII letters, digits and underscores, and the same run with `(` where a parenthesis
    /// follows it directly. So `stat(` is not found in `thermostat(`, nor `systemSize` in `fileSystemSize`.
    private static func names(in code: String) -> Set<String> {
        var names = Set<String>()
        var word: [UInt8] = []
        for byte in code.utf8 {
            let isNamePart = byte == UInt8(ascii: "_") || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
                || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte) || (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
            if isNamePart {
                word.append(byte)
            } else if !word.isEmpty {
                let name = String(decoding: word, as: UTF8.self)
                names.insert(name)
                if byte == UInt8(ascii: "(") { names.insert(name + "(") }
                word.removeAll(keepingCapacity: true)
            }
        }
        if !word.isEmpty { names.insert(String(decoding: word, as: UTF8.self)) }
        return names
    }

    /// Every required-reason family the app's own sources use is a category the privacy manifest declares with a reason.
    /// Mutation: `ProcessInfo.processInfo.systemUptime` or `statfs(` in a file under macTEM/ or Sources/, or the UserDefaults or
    /// file-timestamp entry dropped from macTEM/PrivacyInfo.xcprivacy - red.
    func testEveryRequiredReasonAPITheSourcesUseIsDeclaredInThePrivacyManifest() throws {
        let declared = try declaredReasons()
        var scanned = 0
        var usedCategories = Set<String>()
        for folder in ["macTEM", "Sources"] {
            let base = root.appendingPathComponent(folder)
            for path in try FileManager.default.subpathsOfDirectory(atPath: base.path).sorted() where path.hasSuffix(".swift") {
                let source = try String(contentsOf: base.appendingPathComponent(path), encoding: .utf8)
                let names = Self.names(in: Self.code(of: source))
                scanned += 1
                for family in Self.families {
                    for symbol in family.symbols where names.contains(symbol) {
                        usedCategories.insert(family.category)
                        XCTAssertFalse((declared[family.category] ?? []).isEmpty,
                                       "\(folder)/\(path) uses \(symbol): macTEM/PrivacyInfo.xcprivacy must declare \(family.category)")
                    }
                }
            }
        }
        XCTAssertGreaterThan(scanned, 100, "the scan did not find the app's and the package's sources")
        // The scan sees what is there today: the grants and recent files in UserDefaults, and the stat calls of the session
        // sidecars and the pattern files.
        XCTAssertTrue(usedCategories.contains("NSPrivacyAccessedAPICategoryUserDefaults"), "the scan found no UserDefaults use")
        XCTAssertTrue(usedCategories.contains("NSPrivacyAccessedAPICategoryFileTimestamp"), "the scan found no stat call")
    }

    /// The scan reads code and not comments, whole names and not parts of longer ones.
    /// Mutation: comments kept, a `//` inside a string literal taken for a comment, or names matched as substrings - red.
    func testTheScanReadsWholeNamesInCodeAndSkipsComments() {
        let source = [
            "let up = ProcessInfo.processInfo.systemUptime // not mach_absolute_time()",
            "    // statfs( is avoided here: no listed reason fits",
            "let page = \"https://example.com/\" + String(fstatvfs(descriptor, &volume))",
            "let quoted = \"a \\\" // b\" + String(describing: activeInputModes)",
            "thermostat(fileSystemSize)",
            "var info = stat()",
            "let store = UserDefaults(suiteName: name)"
        ].joined(separator: "\n")
        let names = Self.names(in: Self.code(of: source))
        XCTAssertTrue(names.contains("systemUptime"))
        XCTAssertFalse(names.contains("mach_absolute_time("), "a trailing comment is not code")
        XCTAssertFalse(names.contains("statfs("), "a comment line is not code")
        XCTAssertTrue(names.contains("fstatvfs("), "the // of a URL in a string literal does not start a comment")
        XCTAssertTrue(names.contains("activeInputModes"), "an escaped quote does not end the string literal")
        XCTAssertTrue(names.contains("thermostat(") && names.contains("fileSystemSize"))
        XCTAssertFalse(names.contains("systemSize"), "a name is matched whole")
        XCTAssertTrue(names.contains("stat("), "the struct initialiser is a use of stat")
        XCTAssertTrue(names.contains("UserDefaults") && names.contains("UserDefaults("))
    }

    /// The entitlements file holds the App Sandbox, user-selected read-write, app-scope bookmarks and the agent door's listener
    /// (`network.server`, loopback only, off until Settings > Agents), each on, and no other key of any prefix; and every
    /// configuration signs with that file. The store's privacy answer (Data Not Collected) and SECURITY.md say the app connects
    /// to no other computer, which holds because no network client entitlement is there.
    /// Mutation: com.apple.security.network.client or any other key added, a key turned off, or a configuration signed with
    /// another entitlements file - red.
    func testTheEntitlementsAreTheSandboxItsTwoFileKeysAndTheAgentDoorAndNothingElse() throws {
        let url = root.appendingPathComponent("macTEM/macTEM.entitlements")
        let entitlements = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil)
            as? [String: Any])
        XCTAssertEqual(entitlements.keys.sorted(), ["com.apple.security.app-sandbox", "com.apple.security.files.bookmarks.app-scope",
                                                    "com.apple.security.files.user-selected.read-write",
                                                    "com.apple.security.network.server"],
                       "the store's privacy answer and SECURITY.md name these four and no network client")
        for (key, value) in entitlements {
            XCTAssertEqual(value as? Bool, true, "\(key) is not on")
        }

        let project = try String(contentsOf: root.appendingPathComponent("macTEM.xcodeproj/project.pbxproj"), encoding: .utf8)
        let signed = project.components(separatedBy: "CODE_SIGN_ENTITLEMENTS = ").count - 1
        let withThisFile = project.components(separatedBy: "CODE_SIGN_ENTITLEMENTS = macTEM/macTEM.entitlements;").count - 1
        XCTAssertGreaterThan(signed, 0, "no configuration signs with an entitlements file")
        XCTAssertEqual(signed, withThisFile, "a configuration signs with an entitlements file other than macTEM/macTEM.entitlements")
    }
}
