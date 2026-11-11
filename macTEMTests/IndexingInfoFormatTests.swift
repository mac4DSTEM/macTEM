//
//  IndexingInfoFormatTests.swift
//  The Indexing room's Info words that no test named (`IndexingInfoFormat`, #341): the dash a run without a dictionary shows,
//  which Output lines belong to a method's run (the Results room groups them under it), a run's time at three significant
//  digits, and a count never grouped. The method, the indexed count and the projection centre are pinned in SEMSessionLedgerTests
//  and ProjectionCentreWordsTests, the singular "1 point" in CountWordsTests.
//  The room writes its numbers one way (#272): the counts on screen as the report writes them, the projection centre of the Calibration
//  row, the Results header and the Refine rows as the Patterns room writes it, the tilts in the Patterns room's words, the Dictionary
//  section's rows and every missing value as `UnitDisplay.noValue`, the typed fields on `Num`'s styles and `TypedWholeNumber` (#425).
//  Each Output line here is one the Indexing session writes, with numbers filled in.
//  Red under: a changed word or dash, a line counted for the other method, the time at another number of digits, a grouped count.
//

import XCTest
import TEMCore
import TEMSession
@testable import macTEM

nonisolated final class IndexingInfoFormatTests: XCTestCase {
    private static let posix = Locale(identifier: "en_US_POSIX")
    private static let us = Locale(identifier: "en_US")
    private static let german = Locale(identifier: "de_DE")
    private static let pc = SIMD3<Double>(0.4215, 0.2163, 0.5323)

    /// A source file of macTEM/UI, its whitespace squeezed.
    private func ui(_ name: String) throws -> String { try FFTRoomWiringTests.squeezedUI(name) }

    /// A Hough run of nickel over a 55 × 75 scan, every point indexed.
    private func everyPointIndexed() throws -> IndexingResult {
        let ni = try XCTUnwrap(IndexingPhase.presets.first { $0.name == "Ni" })
        var result = IndexingResult(scanRows: 55, scanColumns: 75, phases: [ni])
        var indexed = HoughIndexer.Solution()
        indexed.phase = 0
        for row in 0..<55 { result.land(Array(repeating: indexed, count: 75), at: row) }
        return result
    }

    /// A run that built no dictionary shows the one dash every room's tables show, in any locale. Red before: an en dash ("–").
    func testNoDictionaryReadsAsTheOneDash() {
        XCTAssertEqual(IndexingInfoFormat.dictionaries([]), UnitDisplay.noValue)
        XCTAssertEqual(IndexingInfoFormat.dictionaries([], locale: Self.german), UnitDisplay.noValue)
        XCTAssertEqual(IndexingInfoFormat.dictionaries([], locale: Self.us), UnitDisplay.noValue)
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

    /// A count reads on screen as the report writes it, never grouped, as `Num` writes every number and the SEM-EDS rows their counts.
    /// Red before: "3,812 points" in en_US and "4.125 of 4.125" in German beside the report's "3812 points" and "4125 of 4125".
    func testCountsAreNeverGrouped() throws {
        let result = try everyPointIndexed()
        for locale in [Self.us, Self.german, Self.posix] {
            XCTAssertEqual(IndexingInfoFormat.count(1_234_567, locale: locale), "1234567", locale.identifier)
            XCTAssertEqual(IndexingInfoFormat.points(3812, locale: locale), "3812 points", locale.identifier)
            XCTAssertEqual(IndexingInfoFormat.indexed(result, locale: locale), "4125 of 4125", locale.identifier)
        }
        XCTAssertEqual(IndexingInfoFormat.count(0, locale: Self.german), "0")
        XCTAssertEqual(IndexingInfoFormat.points(1, locale: Self.german), "1 point")
    }

    /// The Results table's header names the run, its counts never grouped and its PC as the Calibration row writes it. Red before: the
    /// view wrote "4.125 of 4.125 indexed · PC (0,4215, 0,2163, 0,5323)" in German, a decimal comma and the list's one mark.
    func testTheResultsHeaderWritesItsNumbersOneWay() throws {
        let result = try everyPointIndexed()
        XCTAssertEqual(IndexingInfoFormat.resultsHeader(result, run: "Hough", projectionCentre: Self.pc, locale: Self.german),
                       "Results · Hough · Ni · 4125 of 4125 indexed · PC (0,4215; 0,2163; 0,5323)")
        XCTAssertEqual(IndexingInfoFormat.resultsHeader(result, run: "Hough", projectionCentre: Self.pc, locale: Self.us),
                       "Results · Hough · Ni · 4125 of 4125 indexed · PC (0.4215, 0.2163, 0.5323)")
        XCTAssertEqual(IndexingInfoFormat.resultsHeader(result, run: "Dictionary · Refined", projectionCentre: nil, locale: Self.german),
                       "Results · Dictionary · Refined · Ni · 4125 of 4125 indexed")
        let room = try ui("IndexingRoom.swift")
        XCTAssertTrue(room.contains("return IndexingInfoFormat.resultsHeader(result, run: session.shownRun?.title ?? result.method.title,"))
        XCTAssertFalse(room.contains(".formatted()"), "the map's count line and the best match's header write their counts one way")
    }

    /// The projection centre reads as three numbers on the Calibration row and the Refine section's mean and deviation, parted by
    /// semicolons where the decimal mark is a comma, as the Patterns room writes it. Red before: "(0,4215, 0,2163, 0,5323)" in German.
    func testThePCTripleIsLocaleSafe() throws {
        XCTAssertEqual(IndexingInfoFormat.triple(Self.pc, locale: Self.german), "(0,4215; 0,2163; 0,5323)")
        XCTAssertEqual(IndexingInfoFormat.triple(Self.pc, locale: Self.us), "(0.4215, 0.2163, 0.5323)")
        XCTAssertEqual(IndexingInfoFormat.triple(Self.pc, locale: Self.german), UnitDisplay.triple(Self.pc, digits: 4, locale: Self.german))
        let inspector = try ui("IndexingRoomInspector.swift")
        XCTAssertTrue(inspector.contains("InspectorValueRow(\"PC\", IndexingInfoFormat.triple(pc))"), "the Calibration row")
        XCTAssertTrue(inspector.contains("let mean = IndexingInfoFormat.triple(pc.mean), deviation = IndexingInfoFormat.triple(pc.deviation)"))
    }

    /// The Calibration section's tilts read as the Patterns room's Calibration rows: "Detector tilt", in the reader's decimal mark.
    /// Red before: the Indexing room said "Camera tilt" for the angle the Patterns room calls the detector's.
    func testTheTiltsAreThePatternsRoomsRows() throws {
        var dataset = try DemoDocuments.ebsd().dataset
        dataset.detector.sampleTilt = 70
        dataset.detector.tilt = 10.5
        XCTAssertEqual(IndexingInfoFormat.tiltRows(dataset.detector, locale: Self.german).map(\.label), ["Sample tilt", "Detector tilt"])
        XCTAssertEqual(IndexingInfoFormat.tiltRows(dataset.detector, locale: Self.german).map(\.value), ["70°", "10,5°"])
        XCTAssertEqual(IndexingInfoFormat.tiltRows(dataset.detector, locale: Self.us).map(\.value), ["70°", "10.5°"])
        for locale in [Self.german, Self.us] {
            let patterns = EBSDBrowsing.calibrationRows(dataset, locale: locale).filter { $0.label.hasSuffix(" tilt") }
            XCTAssertEqual(IndexingInfoFormat.tiltRows(dataset.detector, locale: locale), patterns, locale.identifier)
        }
        let inspector = try ui("IndexingRoomInspector.swift")
        XCTAssertTrue(inspector.contains("ForEach(IndexingInfoFormat.tiltRows(detector)) { row in InspectorValueRow(row.label, row.value) }"))
        XCTAssertFalse(inspector.contains("Camera tilt"))
    }

    /// The Dictionary section's size and Chunk rows: counts never grouped, the resolution in the reader's decimal mark, a count of one
    /// chunk in the singular, the one dash before there is anything to show. Red before: "11.935 patterns at 4°" in German and an en
    /// dash for no value.
    func testTheDictionaryRowsWriteTheirNumbersOneWay() throws {
        XCTAssertEqual(IndexingInfoFormat.dictionarySize([11935], resolution: 4, countable: true, locale: Self.german), "11935 patterns at 4°")
        XCTAssertEqual(IndexingInfoFormat.dictionarySize([11935, 2047], resolution: 2.5, countable: true, locale: Self.german),
                       "11935 + 2047 patterns at 2,5°")
        XCTAssertEqual(IndexingInfoFormat.dictionarySize([11935, 2047], resolution: 2.5, countable: true, locale: Self.us),
                       "11935 + 2047 patterns at 2.5°")
        XCTAssertEqual(IndexingInfoFormat.dictionarySize(nil, resolution: 2.5, countable: true, locale: Self.german), "Counting at 2,5°")
        XCTAssertEqual(IndexingInfoFormat.dictionarySize(nil, resolution: 4, countable: false, locale: Self.us), UnitDisplay.noValue)

        XCTAssertEqual(IndexingInfoFormat.chunking((size: 2000, chunks: 6, blocks: 1), dictionaries: 1, locale: Self.german), "2000 patterns · 6 chunks")
        XCTAssertEqual(IndexingInfoFormat.chunking((size: 11935, chunks: 1, blocks: 3), dictionaries: 2, locale: Self.us),
                       "11935 patterns · 1 chunk over 2 dictionaries per block · 3 blocks")
        XCTAssertEqual(IndexingInfoFormat.chunking(nil, dictionaries: 1, locale: Self.us), UnitDisplay.noValue)
        XCTAssertEqual(IndexingInfoFormat.chunking((size: 0, chunks: 0, blocks: 1), dictionaries: 1, locale: Self.german), UnitDisplay.noValue)

        let inspector = try ui("IndexingRoomInspector.swift")
        XCTAssertTrue(inspector.contains("return IndexingInfoFormat.dictionarySize(sizes, resolution: settings.resolution, countable: countable)"))
        XCTAssertTrue(inspector.contains("IndexingInfoFormat.chunking(session.dictionaryChunking, dictionaries: session.phasesOn.count)"))
        XCTAssertTrue(inspector.contains("InspectorValueRow(\"Also held\", \"\\(other.method.title) · \\(IndexingInfoFormat.indexed(other.result)) indexed\""))
        XCTAssertFalse(inspector.contains("\"\u{2013}\""), "no en dash stands for a missing value")
        XCTAssertFalse(inspector.contains(".formatted()"), "no grouped count")
    }

    /// The inspector's typed fields take the shared styles (`Num.wholeField`, `Num.decimalField`) and the shared typed whole number
    /// (`TypedWholeNumber`, #425) in Keep, Bands, ρ bins, θ bins and Early exit. Red before: private `whole` and `decimal` styles in the
    /// Dictionary, Hough and Refine sections and a private copy of the typed-number rule.
    func testTheTypedFieldsShareTheAppsStylesAndRule() throws {
        let inspector = try ui("IndexingRoomInspector.swift")
        XCTAssertFalse(inspector.contains("FloatingPointFormatStyle"), "no private field style")
        XCTAssertFalse(inspector.contains("WholeNumberEntry"), "no private typed-number rule")
        XCTAssertEqual(inspector.components(separatedBy: "= TypedWholeNumber.value(v) }").count - 1, 5, "Keep, Bands, ρ bins, θ bins, Early exit")
        XCTAssertEqual(inspector.components(separatedBy: "format: Num.wholeField,").count - 1, 5, "the same five")
        XCTAssertEqual(inspector.components(separatedBy: "format: Num.decimalField,").count - 1, 7,
                       "Resolution, ρ mask, ρ width, θ width, Tolerance, Angle trust, PC trust")
    }
}
