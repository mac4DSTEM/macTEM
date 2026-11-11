//
//  SessionEventFormatTests.swift
//  The SEM sessions' Output lines write their numbers in the reader's locale, never grouped (Paul's drive, 2026-11-11: the status
//  line read "Indexed 1200 of 1200 patterns with Hough in 1.0 s" in German beside the Info's "Time 0,982 s"). Red before: no
//  `SessionEventFormat`, and the Processed, Indexed and Refined lines wrote `String(format: "%.1f")`.
//  The digits are `UnitDisplay`'s (#272): the dictionary run's start line and Segment's line write their angles as the rows beside them.
//

import XCTest
import TEMCore
@testable import TEMSession
@testable import macTEM

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

    /// The digits are `UnitDisplay.fixed`'s, as the Info rows beside the line: printf's rounding of a decimal tie, never "-0.0", the one
    /// dash for a value that is not finite. Red before: FormatStyle wrote "0.4", "-0.0" and "NaN".
    func testANumberRoundsAsUnitDisplay() {
        XCTAssertEqual(SessionEventFormat.fixed(0.35, 1, locale: en), "0.3")
        XCTAssertEqual(SessionEventFormat.fixed(-0.04, 1, locale: en), "0.0")
        XCTAssertEqual(SessionEventFormat.fixed(.nan, 1, locale: de), UnitDisplay.noValue)
    }

    /// A dictionary run's start line writes its resolution as the Dictionary section's size row does, in the locale given; its count
    /// never grouped. Red before: the line was built inside the run with FormatStyle at three significant digits, "2,68°" in German.
    func testTheDictionaryStartLineWritesTheResolutionAsTheSizeRow() {
        XCTAssertEqual(IndexingSession.dictionaryStartLine(points: 4125, phases: ["Ni"], resolution: 2.675, metric: "NCC", locale: de),
                       "Indexing 4125 patterns against the Ni dictionary at 2,675° (NCC)…")
        XCTAssertEqual(IndexingSession.dictionaryStartLine(points: 1200, phases: ["Ni", "Fe"], resolution: 2, metric: "NCC", locale: en),
                       "Indexing 1200 patterns against 2 dictionaries (Ni, Fe) at 2° (NCC); each point takes the phase of its best score…")
    }

    /// Segment's line writes its boundary angle as the Grains section's "Made with" row does (four significant digits). Red before: the
    /// line wrote two decimals by FormatStyle, "2.68°" beside the row's "2.675°".
    func testTheSegmentedLineWritesTheAngleAsTheGrainsRow() {
        let settings = MapAnalysisSettings(boundaryDegrees: 2.675, minimumSize: 1)
        XCTAssertEqual(OrientationMapSession.segmentedLine(grains: 14, settings: settings, locale: en),
                       "Segmented 14 grains (boundaries above 2.675°, at least 1 point)")
        XCTAssertEqual(OrientationMapSession.segmentedLine(grains: 1, settings: MapAnalysisSettings(boundaryDegrees: 5, minimumSize: 5), locale: de),
                       "Segmented 1 grain (boundaries above 5°, at least 5 points)")
        XCTAssertTrue(OrientationMapSession.segmentedLine(grains: 14, settings: settings, locale: de)
            .contains("above \(MapsRoomFormat.number(2.675, locale: de))°"), "the Grains row's angle")
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
