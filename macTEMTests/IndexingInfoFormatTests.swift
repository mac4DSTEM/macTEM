//
//  IndexingInfoFormatTests.swift
//  The Indexing room's Info words that no test named (`IndexingInfoFormat`, #341): the dash a run without a dictionary shows,
//  which Output lines belong to a method's run (the Results room groups them under it), a run's time at three significant
//  digits, and a count of points in the reader's grouping. The method, the indexed count and the projection centre are pinned
//  in SEMSessionLedgerTests and ProjectionCentreWordsTests, the singular "1 point" in CountWordsTests.
//  Each Output line here is one the Indexing session writes, with numbers filled in.
//  Red under: a changed word or dash, a line counted for the other method, the time at another number of digits.
//

import XCTest
import TEMCore
@testable import macTEM

nonisolated final class IndexingInfoFormatTests: XCTestCase {
    private static let posix = Locale(identifier: "en_US_POSIX")
    private static let german = Locale(identifier: "de_DE")

    /// A run that built no dictionary shows an en dash, in any locale.
    func testNoDictionaryReadsAsADash() {
        XCTAssertEqual(IndexingInfoFormat.dictionaries([]), "\u{2013}")
        XCTAssertEqual(IndexingInfoFormat.dictionaries([], locale: Self.german), "\u{2013}")
    }

    /// A run's closing line names its method after "with": it belongs to that method and not to the other.
    func testAnIndexedLineBelongsToTheMethodItNames() {
        let hough = "Indexed 4125 of 4125 patterns with Hough in 1.2 s"
        XCTAssertTrue(IndexingInfoFormat.isLine(hough, of: .hough))
        XCTAssertFalse(IndexingInfoFormat.isLine(hough, of: .dictionary))
        let dictionary = "Indexed 4000 of 4125 patterns with Dictionary in 12.3 s"
        XCTAssertTrue(IndexingInfoFormat.isLine(dictionary, of: .dictionary))
        XCTAssertFalse(IndexingInfoFormat.isLine(dictionary, of: .hough))
        let twoPhases = "Indexed 4125 of 4125 patterns with Dictionary in 12.3 s (Ni 4000 · Al 125)"
        XCTAssertTrue(IndexingInfoFormat.isLine(twoPhases, of: .dictionary))
        XCTAssertFalse(IndexingInfoFormat.isLine(twoPhases, of: .hough))
    }

    /// Each method has its own Stopped line, and the master pattern a dictionary run opened is the dictionary's.
    func testStoppedAndMasterPatternLinesBelongToTheirMethod() {
        let stoppedHough = "Stopped indexing after 12 of 55 rows; the indexed rows stay"
        XCTAssertTrue(IndexingInfoFormat.isLine(stoppedHough, of: .hough))
        XCTAssertFalse(IndexingInfoFormat.isLine(stoppedHough, of: .dictionary))
        let stoppedDictionary = "Stopped dictionary indexing after 3 of 9 chunks; 20 of 55 rows were indexed and stay"
        XCTAssertTrue(IndexingInfoFormat.isLine(stoppedDictionary, of: .dictionary))
        XCTAssertFalse(IndexingInfoFormat.isLine(stoppedDictionary, of: .hough))
        let master = "Opened the master pattern Ni.h5: Ni · 20 kV · Lambert · 401 × 401; Ni takes it"
        XCTAssertTrue(IndexingInfoFormat.isLine(master, of: .dictionary))
        XCTAssertFalse(IndexingInfoFormat.isLine(master, of: .hough))
    }

    /// A line about something else is neither method's: an export, and a line that only starts like a run's.
    func testAnotherLineBelongsToNeitherMethod() {
        for line in ["Exported patterns_v2 indexed IPF-Z.png", "Indexed map", "Stopped", ""] {
            XCTAssertFalse(IndexingInfoFormat.isLine(line, of: .hough), line)
            XCTAssertFalse(IndexingInfoFormat.isLine(line, of: .dictionary), line)
        }
    }

    /// A run's time keeps three significant digits, with the reader's decimal mark and no trailing zeros.
    func testARunsTimeKeepsThreeSignificantDigits() {
        XCTAssertEqual(IndexingInfoFormat.time(1.2345, locale: Self.posix), "1.23 s")
        XCTAssertEqual(IndexingInfoFormat.time(12.345, locale: Self.posix), "12.3 s")
        XCTAssertEqual(IndexingInfoFormat.time(0.5, locale: Self.posix), "0.5 s")
        XCTAssertEqual(IndexingInfoFormat.time(0, locale: Self.posix), "0 s")
        XCTAssertEqual(IndexingInfoFormat.time(1.2345, locale: Self.german), "1,23 s")
    }

    /// On screen a count of points is grouped as the reader's locale groups it.
    func testPointsAreGroupedAsTheReaderGroupsThem() {
        XCTAssertEqual(IndexingInfoFormat.points(3812, locale: Locale(identifier: "en_US")), "3,812 points")
        XCTAssertEqual(IndexingInfoFormat.points(3812, locale: Self.german), "3.812 points")
        XCTAssertEqual(IndexingInfoFormat.points(1, locale: Self.german), "1 point")
    }
}
