//
//  EELSResultsSplitTests.swift
//  The EELS results pane shares its height as a standard macOS results pane does: every fitted edge's row first (up to six), whole and clear of the
//  horizontal scroll bar, then the Regions section, which gives way first and scrolls in what is left (`EELSResultsSplit`, the function the pane
//  lays itself out by). And the Fitting section's Fit to reads in full under exact NNLS, with no unit (`EELSFitToRow`, the function the row shows).
//
//  THE TRUTH: the drive's results pane of 2026-11-11 (300 x 282 pt, three fitted edges and one region: C K whole, N K cut, O K hidden; Fit to read
//  "Signal win…" and "eV"), its lines above and below the tables taken from the pane's header and footer heights and the system fonts. Layout and
//  words only: no number of a result is read or changed.
//

import XCTest
import AppKit
import ShellLayout
import TEMCore
@testable import macTEM

nonisolated final class EELSResultsSplitTests: XCTestCase {

    /// The height the two tables share in the drive's 300 x 282 pt pane: the pane less its header and footer, the two dividers, the thickness line on
    /// two lines (it wraps at 300 pt) with its 5-pt padding, and the exponents line with its 2-pt padding.
    @MainActor private func drivesTablesHeight() -> CGFloat {
        func line(_ style: NSFont.TextStyle) -> CGFloat {
            let font = NSFont.preferredFont(forTextStyle: style)
            return (font.ascender - font.descender + font.leading).rounded(.up)
        }
        let headerFooterAndDividers: CGFloat = 2 * LayoutPolicy.paneHeaderHeight + 2
        let thicknessLine: CGFloat = 2 * line(.callout) + 10
        let exponentsLine: CGFloat = line(.caption1) + 2
        return 282 - headerFooterAndDividers - thicknessLine - exponentsLine
    }

    /// The drive's pane: three fitted edges and one region. Every edge's row is whole above the scroll bar's room, the Regions section keeps its
    /// caption in view in what is left, and the two fill the space without pushing anything out of the pane. Red under the split before: the
    /// Regions grid at its fixed height left the edges table a row and a half.
    @MainActor func testTheDrivesPaneShowsEveryEdgeRowWhole() {
        let available = drivesTablesHeight()
        let split = EELSResultsSplit.heights(available: available, edgeRows: 3, regionRows: 1)
        let rowsRoom = split.edges - EELSResultsSplit.tableHeaderHeight - 2 * EELSResultsSplit.tableInset - EELSResultsSplit.scrollBarAllowance
        XCTAssertGreaterThanOrEqual(rowsRoom, 3 * EELSResultsSplit.tableRowHeight, "every edge row whole: \(split) of \(available) pt")
        XCTAssertGreaterThanOrEqual(split.regions, EELSResultsSplit.regionsCaptionHeight, "the Regions caption stays in view: \(split)")
        XCTAssertEqual(split.edges + split.regions, available, accuracy: 0.001)
        // The split this replaces: the Regions section at its full height whatever the pane, the edges table the rest.
        let before = available - EELSResultsSplit.regionsHeight(rows: 1)
        XCTAssertLessThan(before, EELSResultsSplit.edgesFloor(rows: 3), "the drive's pane is one the fixed Regions height cut: \(before) pt")
    }

    /// The edges table's floor: its column headers, every edge's row up to six (more scroll inside it), its insets and the scroll bar's room; none
    /// before a fit, where the pane says what to do instead of showing a table.
    func testTheEdgesFloorHoldsEveryRowUpToSix() {
        let fixed = EELSResultsSplit.tableHeaderHeight + 2 * EELSResultsSplit.tableInset + EELSResultsSplit.scrollBarAllowance
        XCTAssertEqual(EELSResultsSplit.edgesFloor(rows: 1), fixed + EELSResultsSplit.tableRowHeight)
        XCTAssertEqual(EELSResultsSplit.edgesFloor(rows: 3), fixed + 3 * EELSResultsSplit.tableRowHeight)
        XCTAssertEqual(EELSResultsSplit.edgesFloor(rows: 6), fixed + 6 * EELSResultsSplit.tableRowHeight)
        XCTAssertEqual(EELSResultsSplit.edgesFloor(rows: 9), EELSResultsSplit.edgesFloor(rows: 6), "more than six scroll")
        XCTAssertEqual(EELSResultsSplit.edgesFloor(rows: 0), 0)
    }

    /// The Regions section gives way first: at its full height (every region up to five rows) while the pane has room, then down to its caption,
    /// header and one row, then less, scrolling, while the edges table keeps its floor. Only a pane shorter than that floor cuts the edges table, and
    /// the Regions section then has nothing. Without a region the edges table has the whole height, and before a fit the Regions section has its
    /// full height, as before.
    func testTheRegionsSectionGivesWayFirst() {
        let floorOfThree = EELSResultsSplit.edgesFloor(rows: 3)
        let oneRow = EELSResultsSplit.regionsHeight(rows: 1)
        var split = EELSResultsSplit.heights(available: 600, edgeRows: 3, regionRows: 2)
        XCTAssertEqual(split.regions, EELSResultsSplit.regionsHeight(rows: 2), "a tall pane: every region's row")
        XCTAssertEqual(split.edges, 600 - EELSResultsSplit.regionsHeight(rows: 2), "a tall pane: the edges table has the rest")
        split = EELSResultsSplit.heights(available: floorOfThree + oneRow, edgeRows: 3, regionRows: 4)
        XCTAssertEqual(split.edges, floorOfThree)
        XCTAssertEqual(split.regions, oneRow, "the caption, the header and one row of four regions")
        split = EELSResultsSplit.heights(available: floorOfThree + 30, edgeRows: 3, regionRows: 4)
        XCTAssertEqual(split.edges, floorOfThree, "the edges keep every row")
        XCTAssertEqual(split.regions, 30, "the Regions section scrolls in what is left")
        split = EELSResultsSplit.heights(available: floorOfThree - 10, edgeRows: 3, regionRows: 4)
        XCTAssertEqual(split.edges, floorOfThree - 10)
        XCTAssertEqual(split.regions, 0)
        split = EELSResultsSplit.heights(available: 240, edgeRows: 3, regionRows: 0)
        XCTAssertEqual(split.edges, 240)
        XCTAssertEqual(split.regions, 0)
        split = EELSResultsSplit.heights(available: 240, edgeRows: 0, regionRows: 1)
        XCTAssertEqual(split.regions, oneRow, "before a fit")
        XCTAssertEqual(split.edges, 240 - oneRow)
        split = EELSResultsSplit.heights(available: -5, edgeRows: 3, regionRows: 1)
        XCTAssertEqual(split.edges, 0)
        XCTAssertEqual(split.regions, 0)
        XCTAssertEqual(EELSResultsSplit.regionsHeight(rows: 12), EELSResultsSplit.regionsCaptionHeight + EELSResultsSplit.regionsGridMaximum,
                       "more than five regions scroll")
    }

    /// Fit to under exact NNLS: the words in full, as text with no unit; under MLLS the number field in eV with its prompt, as before. The tooltips
    /// keep their words. Red under: a disabled number field that read "Signal win…" and "eV".
    func testFitToReadsInFullWithNoUnitUnderExactNNLS() {
        XCTAssertEqual(EELSFitToRow.shown(.exactNNLS), .words("Signal windows"))
        if case let .words(words) = EELSFitToRow.shown(.exactNNLS) {
            XCTAssertFalse(words.contains("eV"), words)
        }
        XCTAssertEqual(EELSFitToRow.shown(.mlls), .field(unit: "eV", prompt: "Axis end"))
        XCTAssertEqual(EELSFitToRow.help(.exactNNLS), "Exact NNLS fits each edge on its own signal window: drag the windows on the spectrum")
        XCTAssertEqual(EELSFitToRow.help(.mlls), "The last energy of the MLLS window, included; 0 returns to the end of the core-loss axis")
    }
}
