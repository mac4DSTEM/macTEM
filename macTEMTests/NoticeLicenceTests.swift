//
//  NoticeLicenceTests.swift
//  NOTICE and the licence texts it names. A licence that asks for its text to travel with the binary (Apache-2.0 §4(a), for
//  DefDAP's ports in SEM/Grains and SEM/Deformation) ships as a file under Licenses/, which the project copies into the bundle as
//  a folder reference; a URL alone is not a copy. These read NOTICE and Licenses/ beside this test file and the app the tests run in.
//

import XCTest

nonisolated final class NoticeLicenceTests: XCTestCase {
    private let root = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath().deletingLastPathComponent()
        .deletingLastPathComponent()

    /// NOTICE's paragraphs (blank-line separated), each with its line breaks and runs of spaces folded into one space.
    private func noticeParagraphs() throws -> [String] {
        let notice = try String(contentsOf: root.appendingPathComponent("NOTICE"), encoding: .utf8)
        return notice.components(separatedBy: "\n\n")
            .map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            .filter { !$0.isEmpty }
    }

    /// The files under `Licenses/` a paragraph names (the folder named on its own is not a file).
    private func licenceFiles(in paragraph: String) -> [String] {
        let separators = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-/")).inverted
        return paragraph.components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
            .filter { $0.hasPrefix("Licenses/") && $0.count > "Licenses/".count }
    }

    /// Every paragraph that cites the Apache License names its text under Licenses/, and that file is the Apache License 2.0.
    /// Red before Licenses/DefDAP-LICENSE.txt: both DefDAP paragraphs cited the licence by its URL only.
    func testEveryApacheLicensedPortNamesItsLicenceTextInLicenses() throws {
        let apache = try noticeParagraphs().filter { $0.contains("Apache License") }
        XCTAssertGreaterThanOrEqual(apache.count, 2, "NOTICE cites the Apache License for DefDAP's grain and slip ports")
        for paragraph in apache {
            let files = licenceFiles(in: paragraph)
            XCTAssertFalse(files.isEmpty, "an Apache-licensed paragraph cites its licence by URL only: \(paragraph.prefix(90))")
            for file in files {
                let url = root.appendingPathComponent(file)
                guard FileManager.default.fileExists(atPath: url.path) else {
                    XCTFail("NOTICE names \(file), which is not in the repository")
                    continue
                }
                let text = try String(contentsOf: url, encoding: .utf8)
                XCTAssertTrue(text.contains("Apache License") && text.contains("Version 2.0, January 2004"),
                              "\(file) is not the Apache License 2.0")
            }
        }
    }

    /// Every licence text NOTICE names is in the repository's Licenses/ and in the app the tests run in
    /// (Contents/Resources/Licenses/). Red under: a misspelt name, a file left out of Licenses/, the folder reference dropped.
    func testEveryLicenceTextNOTICENamesShipsInTheBundle() throws {
        let named = try Set(noticeParagraphs().flatMap { licenceFiles(in: $0) })
        XCTAssertTrue(named.contains("Licenses/DefDAP-LICENSE.txt"), "NOTICE does not name DefDAP's licence text")
        let resources = try XCTUnwrap(Bundle.main.resourceURL, "the tests run without the app's bundle")
        for file in named.sorted() {
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(file).path), "\(file) is not in the repository")
            XCTAssertTrue(FileManager.default.fileExists(atPath: resources.appendingPathComponent(file).path), "\(file) is not in the app bundle")
        }
    }
}
