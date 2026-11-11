//
//  SessionEventFormatTests.swift
//  The SEM sessions' Output lines write their numbers in the reader's locale, never grouped (Paul's drive, 2026-11-11: the status
//  line read "Indexed 1200 of 1200 patterns with Hough in 1.0 s" in German beside the Info's "Time 0,982 s"). Red before: no
//  `SessionEventFormat`, and the Processed, Indexed and Refined lines wrote `String(format: "%.1f")`.
//

import XCTest
@testable import TEMSession

nonisolated final class SessionEventFormatTests: XCTestCase {
    private let de = Locale(identifier: "de_DE"), en = Locale(identifier: "en_US")

    /// The reader's decimal mark at the places asked for, rounded, and no thousands separator in either locale.
    func testANumberReadsInTheReadersLocaleUngrouped() {
        XCTAssertEqual(SessionEventFormat.fixed(1.0, 1, locale: de), "1,0")
        XCTAssertEqual(SessionEventFormat.fixed(0.982, 1, locale: de), "1,0")
        XCTAssertEqual(SessionEventFormat.fixed(1.0, 1, locale: en), "1.0")
        XCTAssertEqual(SessionEventFormat.fixed(1234.56, 1, locale: de), "1234,6")
        XCTAssertEqual(SessionEventFormat.fixed(1234.56, 1, locale: en), "1234.6")
        XCTAssertEqual(SessionEventFormat.fixed(0.4567, 3, locale: de), "0,457")
    }

    /// The Patterns and Indexing sessions' lines go through it: no printf-style number is left in either file.
    func testTheSEMSessionLinesUseIt() throws {
        let root = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
        for file in ["EBSDSession.swift", "IndexingSession.swift"] {
            let text = try String(contentsOf: root.appendingPathComponent("Sources/TEMSession/\(file)"), encoding: .utf8)
            XCTAssertFalse(text.contains("String(format: \"%."), "\(file) still writes a number with String(format:)")
            XCTAssertTrue(text.contains("SessionEventFormat.fixed("), file)
        }
    }
}
