//
//  IndexingTableFormatTests.swift
//  The Indexing room's Results table copied with ⌘C (D-SEM-96): the selected rows as TSV under the table's column titles, the cells as
//  the table shows them, numbers in the reader's locale without grouping; nothing for no rows; a click pins its row's pattern, a wide
//  selection (⌘A, a ⇧-range) leaves the pin; the table selects several rows and copies them. The Bands table copies its selected bands
//  the same way (#353).
//  Red before the change: no `IndexingTableFormat`, a single selection, no `onCopyCommand` on the table; no selection and no copy on the
//  Bands table.
//

import XCTest
import TEMCore
@testable import macTEM

nonisolated final class IndexingTableFormatTests: XCTestCase {

    private static let en = Locale(identifier: "en_US")
    private static let de = Locale(identifier: "de_DE")

    /// The repo's own source file at `path`, read beside this test file.
    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    private func squeezed(_ text: String) -> String { text.split(whereSeparator: \.isWhitespace).joined(separator: " ") }

    private static func nickel() throws -> IndexingPhase { try XCTUnwrap(IndexingPhase.presets.first { $0.name == "Ni" }) }

    /// One Hough row of nickel: an indexed point (CI 0.8234, fit 0.512°, 9 bands, PQ 12 345.6) and a point not indexed (2 bands, PQ 812.4).
    private static func houghRows() throws -> [IndexingResult.Row] {
        var indexed = HoughIndexer.Solution()
        indexed.quaternion = SIMD4(0.9, 0.3, -0.2, 0.25) / (0.81 + 0.09 + 0.04 + 0.0625).squareRoot()
        indexed.phase = 0
        indexed.confidence = 0.8234
        indexed.fit = 0.512
        indexed.matchedBands = 9
        indexed.patternQuality = 12345.6
        var missed = HoughIndexer.Solution()
        missed.matchedBands = 2
        missed.patternQuality = 812.4
        var result = IndexingResult(scanRows: 1, scanColumns: 2, phases: [try nickel()])
        result.land([indexed, missed], at: 0)
        return result.rows
    }

    /// A Hough row copies its cells as the table shows them, under the table's titles; a point not indexed has dashes for its angles
    /// and fit.
    func testAHoughRowCopiesAsTheTableShowsIt() throws {
        let rows = try Self.houghRows()
        let e = rows[0]
        let text = IndexingTableFormat.copyText(rows, method: .hough, scoreTitle: "CI", locale: Self.en)
        let one = String(format: "%.1f", e.phi1), two = String(format: "%.1f", e.capitalPhi), three = String(format: "%.1f", e.phi2)
        XCTAssertEqual(text, ["Row\tCol\tPhase\tφ₁ °\tΦ °\tφ₂ °\tCI\tFit °\tBands\tPQ",
                              "0\t0\tNi\t\(one)\t\(two)\t\(three)\t0.823\t0.51\t9\t12350",
                              "0\t1\tnot indexed\t—\t—\t—\t0.000\t—\t2\t812.4"].joined(separator: "\n"))
    }

    /// A dictionary row copies the score (titled by its metric), the simulation index and the OSM; a point the run did not index (no
    /// contrast, NaN score) keeps its simulation index and has no OSM.
    func testADictionaryRowCopiesScoreSimulationAndOSM() throws {
        let q = SIMD4<Double>(1, 0, 0, 0)
        var result = IndexingResult(scanRows: 1, scanColumns: 2, phases: [try Self.nickel()], metric: .ncc)
        result.land(DictionaryIndexing.Result(navigationShape: [1, 2], keepN: 1, isInData: [true, true], scores: [0.41234, .nan],
                                              simulationIndices: [17, 3], rotations: [q, q]), rows: 0..<1)
        let rows = result.rows
        let osm = rows[0].similarity
        XCTAssertTrue(osm.isFinite)
        let text = IndexingTableFormat.copyText(rows, method: .dictionary, scoreTitle: result.scoreTitle, locale: Self.en)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines[0], "Row\tCol\tPhase\tφ₁ °\tΦ °\tφ₂ °\tNCC\tSimulation\tOSM")
        XCTAssertEqual(lines[1].split(separator: "\t").suffix(3).map(String.init), ["0.412", "17", String(format: "%.2f", osm)])
        XCTAssertEqual(lines[2], "0\t1\tnot indexed\t—\t—\t—\t0.000\t3\t—")
    }

    /// No rows copy nothing (the table offers no Copy then); a tab or line break in a phase's name does not break the columns.
    func testNoRowsCopyNothingAndCellsStayInTheirColumns() throws {
        XCTAssertEqual(IndexingTableFormat.copyText([], method: .hough, scoreTitle: "CI"), "")
        var phase = try Self.nickel()
        phase.name = "Ni\tfcc\nmatrix"
        var s = HoughIndexer.Solution()
        s.quaternion = SIMD4(1, 0, 0, 0); s.phase = 0; s.confidence = 0.5; s.fit = 1; s.matchedBands = 8; s.patternQuality = 10
        var result = IndexingResult(scanRows: 1, scanColumns: 1, phases: [phase])
        result.land([s], at: 0)
        let line = IndexingTableFormat.copyText(result.rows, method: .hough, scoreTitle: "CI", locale: Self.en).split(separator: "\n")[1]
        XCTAssertEqual(line.split(separator: "\t", omittingEmptySubsequences: false).count, 10)
        XCTAssertEqual(line.split(separator: "\t")[2], "Ni fcc matrix")
    }

    /// German numbers take a decimal comma and no thousands separator, so a spreadsheet in that locale reads them as numbers.
    func testGermanNumbersTakeACommaAndNoGrouping() throws {
        let rows = try Self.houghRows()
        let cells = IndexingTableFormat.cells(rows[0], method: .hough, locale: Self.de)
        XCTAssertEqual(Array(cells.suffix(4)), ["0,823", "0,51", "9", "12350"])
        XCTAssertEqual(IndexingTableFormat.number(1234.7, locale: Self.de), "1235")
        XCTAssertEqual(IndexingTableFormat.angle(271.54, locale: Self.de), "271,5")
        XCTAssertEqual(IndexingTableFormat.angle(.nan, locale: Self.de), UnitDisplay.noValue)
    }

    /// The Results table's Simulation column and the Bands table's Family and Fit ° cells write a missing value as `UnitDisplay.noValue`,
    /// the dash ⌘C copies for the same Simulation cell and every room's tables show, in any locale. Red before: the three cells wrote
    /// an en dash ("–") on screen.
    func testAMissingCellIsTheOneDash() throws {
        XCTAssertEqual(IndexingTableFormat.simulation(-1), UnitDisplay.noValue)
        XCTAssertEqual(IndexingTableFormat.simulation(17), "17")
        XCTAssertEqual(IndexingTableFormat.simulation(12345), "12345", "never grouped")
        XCTAssertEqual(IndexingTableFormat.bandFamily(nil, isValid: true), UnitDisplay.noValue)
        XCTAssertEqual(IndexingTableFormat.bandFamily(nil, isValid: false), "invalid")
        XCTAssertEqual(IndexingTableFormat.bandFamily("{111}", isValid: true), "{111}")
        for locale in [Self.de, Self.en] { XCTAssertEqual(IndexingTableFormat.bandFit(nil, locale: locale), UnitDisplay.noValue, locale.identifier) }
        XCTAssertEqual(IndexingTableFormat.bandFit(0.4567, locale: Self.de), "0,46")
        XCTAssertEqual(IndexingTableFormat.bandFit(0.4567, locale: Self.en), "0.46")

        let room = squeezed(try source("macTEM/UI/IndexingRoom.swift"))
        XCTAssertTrue(room.contains("TableColumn(\"Simulation\", value: \\.simulationIndex) { Text(IndexingTableFormat.simulation($0.simulationIndex))"))
        XCTAssertTrue(room.contains("TableColumn(\"Family\") { Text(IndexingTableFormat.bandFamily($0.family, isValid: $0.isValid)) }"))
        XCTAssertTrue(room.contains("TableColumn(SEMColumnSpeech.header(\"Fit °\")) { Text(IndexingTableFormat.bandFit($0.fitDegrees))"))
        XCTAssertFalse(room.contains("\"\u{2013}\""), "no en dash stands for a missing value")
    }

    /// A click (one row in place of others), a ⌘-click that adds one, or ⇧ by one row pins that row; a click inside a wide selection
    /// that leaves one row pins it; ⌘A, a ⇧-range, a ⌘-click that removes one of several and an emptied selection leave the pin.
    func testTheRowsPinOnlyForASingleRow() {
        XCTAssertEqual(IndexingTableFormat.pinTarget(old: [], new: [5]), 5)
        XCTAssertEqual(IndexingTableFormat.pinTarget(old: [1], new: [2]), 2)
        XCTAssertEqual(IndexingTableFormat.pinTarget(old: [1, 2], new: [2]), 2)
        XCTAssertEqual(IndexingTableFormat.pinTarget(old: [1], new: [1, 2]), 2)
        XCTAssertNil(IndexingTableFormat.pinTarget(old: [1], new: [1, 2, 3]))
        XCTAssertNil(IndexingTableFormat.pinTarget(old: [], new: Set(0..<10)))
        XCTAssertNil(IndexingTableFormat.pinTarget(old: [1, 2, 3], new: [1, 3]))
        XCTAssertNil(IndexingTableFormat.pinTarget(old: [1, 2], new: []))
    }

    /// The table selects several rows, copies them with ⌘C through `IndexingTableFormat` (Copy is off with nothing selected), pins
    /// through `pinTarget`, and its column titles are the copy's.
    func testTheTableCopiesItsSelectionUnderItsOwnTitles() throws {
        let room = squeezed(try source("macTEM/UI/IndexingRoom.swift"))
        XCTAssertTrue(room.contains("@State private var selection: Set<IndexingResult.Row.ID> = []"))
        XCTAssertTrue(room.contains(".onCopyCommand(perform: selection.isEmpty ? nil : { copied() })"))
        XCTAssertTrue(room.contains("IndexingTableFormat.copyText(picked, method: result.method, scoreTitle: result.scoreTitle)"))
        XCTAssertTrue(room.contains("IndexingTableFormat.pinTarget(old: old, new: new)"))
        for title in IndexingTableFormat.titles(method: .hough, scoreTitle: "CI") + IndexingTableFormat.titles(method: .dictionary, scoreTitle: "NCC")
        where title != "NCC" {
            let drawn = room.contains("TableColumn(\"\(title)\"") || room.contains("TableColumn(SEMColumnSpeech.header(\"\(title)\")")
            XCTAssertTrue(drawn, "the table has no column \(title)")
        }
        XCTAssertTrue(room.contains("TableColumn(SEMColumnSpeech.header(result.scoreTitle)"))
    }

    // MARK: - The Bands table (#353)

    /// Two of a pattern's detected bands (a bright row stripe and a bright column stripe on a 60 × 60 pattern, no solution) copy under
    /// the Bands table's titles as the table shows them: the rank, ρ and θ to two decimals, the peak and the width to four significant
    /// digits, a dash for the family and the fit of a band no solution matched; the reader's decimal mark; nothing for no band.
    /// Red before: no `bandsCopyText` (the table had no selection and no ⌘C).
    func testTwoBandsCopyAsTheTableShowsThem() throws {
        let detector = try HoughBandDetector(rows: 60, columns: 60, settings: HoughIndexingSettings.roomDefault.detectorSettings)
        var pattern = [Double](repeating: 10, count: 3600)
        for k in 24...26 {
            for j in 0..<60 { pattern[k * 60 + j] = 200; pattern[j * 60 + k + 15] = 200 }
        }
        let detected = IndexedBand.bands(try detector.detect(pattern), solution: nil, libraries: [], rows: 60, columns: 60)
        let bands = Array(detected.filter(\.isValid).prefix(2))
        XCTAssertEqual(bands.count, 2, "both stripes are found")
        func two(_ v: Double) -> String {   // two decimals; a value that rounds to zero has no sign
            let text = String(format: "%.2f", v)
            return text == "-0.00" ? "0.00" : text
        }
        func line(_ b: IndexedBand) -> String {
            ["\(b.id)", two(b.rho), two(b.thetaDegrees), IndexingTableFormat.number(b.peak, locale: Self.en),
             IndexingTableFormat.number(b.width, locale: Self.en), "\u{2014}", "\u{2014}"].joined(separator: "\t")
        }
        let header = "#\t\u{03C1} px\t\u{03B8} \u{00B0}\tPeak\tWidth\tFamily\tFit \u{00B0}"
        XCTAssertEqual(IndexingTableFormat.bandsCopyText(bands, locale: Self.en), ([header] + bands.map(line)).joined(separator: "\n"))

        let de = IndexingTableFormat.bandCells(bands[0], locale: Self.de)
        XCTAssertEqual(de[1], two(bands[0].rho).replacingOccurrences(of: ".", with: ","), "the reader's decimal mark")
        XCTAssertEqual(de.count, IndexingTableFormat.bandTitles.count)
        XCTAssertEqual(IndexingTableFormat.bandsCopyText([], locale: Self.en), "", "no band selected copies nothing")
    }

    /// The Bands table selects several bands and copies them with ⌘C through `bandsCopyText` in the table's order (Copy is off with
    /// nothing selected); other bands clear the selection, so a rank picked on one detection is not copied from the next: another point,
    /// and also the same point detected again (new processing, the detector's band count), which keeps the position; its cells are drawn
    /// by the functions the copy writes them with. Red before: `Table(session.detectedBands)` with no selection and no copy; then the
    /// selection cleared only on another position, so a re-detected pattern kept its ranks and Copy stayed on for ranks gone.
    func testTheBandsTableCopiesItsSelectedBands() throws {
        let room = squeezed(try source("macTEM/UI/IndexingRoom.swift"))
        XCTAssertTrue(room.contains("@State private var selection: Set<IndexedBand.ID> = []"))
        XCTAssertTrue(room.contains("Table(session.detectedBands, selection: picks) {"), "through the setter that takes the keys (TableFocusTests)")
        XCTAssertTrue(room.contains(".onCopyCommand(perform: selection.isEmpty ? nil : { copiedBands() })"))
        XCTAssertTrue(room.contains("let picked = session.detectedBands.filter { selection.contains($0.id) }"), "the bands in the table's order")
        XCTAssertTrue(room.contains("NSItemProvider(object: IndexingTableFormat.bandsCopyText(picked) as NSString)"))
        XCTAssertTrue(room.contains(".onChange(of: session.detectedBands) { selection = [] }"), "other bands clear the selection")
        XCTAssertFalse(room.contains(".onChange(of: session.patternPosition) { selection = [] }"), "a re-detection keeps the position")

        // What the change compares: the same detection read again is the same rows (a refresh keeps the selection); the same point
        // detected for fewer bands is not (ranks 7 to 9 are gone, so the selection goes).
        var pattern = [Double](repeating: 10, count: 3600)
        for k in 24...26 {
            for j in 0..<60 { pattern[k * 60 + j] = 200; pattern[j * 60 + k + 15] = 200 }
        }
        func detected(bands: Int) throws -> [IndexedBand] {
            var settings = HoughIndexingSettings.roomDefault.detectorSettings
            settings.bands = bands
            let detector = try HoughBandDetector(rows: 60, columns: 60, settings: settings)
            return IndexedBand.bands(try detector.detect(pattern), solution: nil, libraries: [], rows: 60, columns: 60)
        }
        let nine = try detected(bands: 9)
        XCTAssertEqual(nine.count, 9)
        XCTAssertEqual(try detected(bands: 9), nine, "the same detection again: the selection stays")
        XCTAssertNotEqual(try detected(bands: 6), nine, "fewer bands at the same point: the selection goes")
        for cell in ["Text(IndexingTableFormat.angle($0.rho, digits: 2))", "Text(IndexingTableFormat.angle($0.thetaDegrees, digits: 2))",
                     "Text(IndexingTableFormat.number($0.peak))", "Text(IndexingTableFormat.number($0.width))"] {
            XCTAssertTrue(room.contains(cell), "the table draws \(cell) as the copy writes it")
        }
    }
}
