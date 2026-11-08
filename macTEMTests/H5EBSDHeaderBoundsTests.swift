//
//  H5EBSDHeaderBoundsTests.swift
//  The header numbers an EBSD reader counts, sizes and indexes by, checked before anything is sized by them. `ReaderNumber.int` makes
//  a float count or index the whole number Python's `int()` makes and answers nil where Swift's `Int(_:)` traps (NaN, infinity,
//  beyond Int's range), and the h5ebsd reader refuses such a number in words; `ReaderNumber.product` answers nil where `*` traps. A scan
//  or pattern of no rows or columns, or of more bytes than an Int counts, fails `EBSDDataset.validated()` with a sentence that names
//  the file, and the shipped Ni scan and every h5ebsd and EDAX fixture still open through `EBSDOpening.open` as their readers read
//  them. Oxford's camera mode with a height of 0 gives no binning; a Bruker region of interest with indices far apart is not
//  rectangular.
//  Red before the change: `Int(Double.nan)`, `Int(1e300)`, a binning of `1024 / 0` and `$1 - $0` of `Int.min` and `0` trap; a
//  dataset of 0 or -1 scan rows opened.
//

import Foundation
import FormatoCore
import TEMCore
import XCTest

nonisolated final class H5EBSDHeaderBoundsTests: XCTestCase {

    /// The shipped Ni scan (kikuchipy's `nickel_ebsd_large`, 55 x 75 patterns of 60 x 60), read beside this test file.
    private static let nickelScan = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("DemoData/nickel_ebsd_large/patterns_v2.h5")
    private static let fixturesFolder = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath().deletingLastPathComponent()
        .appendingPathComponent("Fixtures")

    /// A dataset as an h5ebsd reader fills it, of `scanRows` x `scanColumns` patterns of `patternRows` x `patternColumns` uint8.
    private static func dataset(scanRows: Int, scanColumns: Int, patternRows: Int = 60, patternColumns: Int = 60) -> EBSDDataset {
        let detector = EBSDDetectorGeometry(rows: patternRows, columns: patternColumns, projectionCenters: [SIMD3(0.5, 0.5, 0.5)])
        let source = EBSDPatternSource(url: URL(fileURLWithPath: "/hostile/scan.h5"), datasetPath: "/Scan 1/EBSD/Data/patterns",
                                       fileShape: [1, patternRows, patternColumns], dataType: .uint8)
        return EBSDDataset(format: .kikuchipyH5EBSD, manufacturer: "kikuchipy", version: "0.1", scanGroup: "Scan 1", scanGroups: ["Scan 1"],
                           scanRows: scanRows, scanColumns: scanColumns, patternRows: patternRows, patternColumns: patternColumns,
                           dataType: .uint8, stepY: 1.5, stepX: 1.5, detector: detector, patterns: source)
    }

    /// A float that converts gives the number `Int(_:)` and Python's `int()` give (truncated toward zero); NaN, infinity and a value
    /// beyond Int's range give nil, and the h5ebsd reader says so in a sentence. A product that overflows gives nil.
    func testReaderNumberGivesIntsNumberAndNilWhereIntTraps() {
        XCTAssertEqual(ReaderNumber.int(4.0), 4)
        XCTAssertEqual(ReaderNumber.int(59.9), 59, "truncated toward zero, as Python's int()")
        XCTAssertEqual(ReaderNumber.int(-2.5), -2)
        XCTAssertEqual(ReaderNumber.int(-1.0), -1)
        XCTAssertNil(ReaderNumber.int(Double.nan))
        XCTAssertNil(ReaderNumber.int(Double.infinity))
        XCTAssertNil(ReaderNumber.int(-Double.infinity))
        XCTAssertNil(ReaderNumber.int(1e300))
        XCTAssertNil(ReaderNumber.int(9_223_372_036_854_775_808.0), "2^63 is one past Int.max")
        XCTAssertEqual(ReaderNumber.int(-9_223_372_036_854_775_808.0), Int.min)
        XCTAssertThrowsError(try EBSDH5Reader.wholeNumber(Double.nan, "'n_rows' in '/Scan 1/EBSD/Header'")) { error in
            XCTAssertEqual((error as? EBSDReadError)?.text, "'n_rows' in '/Scan 1/EBSD/Header' is nan, not a whole number in range.")
        }
        XCTAssertEqual(try EBSDH5Reader.wholeNumber(55.0, "'n_rows' in '/Scan 1/EBSD/Header'"), 55)
        XCTAssertEqual(ReaderNumber.product([55, 75, 60, 60, 1]), 55 * 75 * 3600)
        XCTAssertEqual(ReaderNumber.product([]), 1)
        XCTAssertNil(ReaderNumber.product([Int.max / 2, 3]))
        XCTAssertNil(ReaderNumber.product([1 << 32, 1 << 32]))
    }

    /// A scan of 0 or -1 rows, a pattern of 0 rows, or a scan whose bytes overflow an Int fails validation with the file's name and
    /// the reason; a scan that can be read is itself.
    func testAnEmptyNegativeOrUncountableScanFailsValidationWithASentence() throws {
        XCTAssertThrowsError(try Self.dataset(scanRows: 0, scanColumns: 75).validated()) { error in
            XCTAssertEqual((error as? EBSDReadError)?.text, "scan.h5: its scan is 0 x 75 positions; a scan needs at least one row and one column.")
        }
        XCTAssertThrowsError(try Self.dataset(scanRows: -1, scanColumns: 75).validated()) { error in
            XCTAssertEqual((error as? EBSDReadError)?.text, "scan.h5: its scan is -1 x 75 positions; a scan needs at least one row and one column.")
        }
        XCTAssertThrowsError(try Self.dataset(scanRows: 3, scanColumns: 3, patternRows: 0, patternColumns: 60).validated()) { error in
            XCTAssertEqual((error as? EBSDReadError)?.text, "scan.h5: its patterns are 0 x 60 pixels; a pattern needs at least one row and one column.")
        }
        XCTAssertThrowsError(try Self.dataset(scanRows: Int.max / 2, scanColumns: 3).validated()) { error in
            let text = (error as? EBSDReadError)?.text ?? ""
            XCTAssertTrue(text.hasSuffix("patterns is more bytes than can be counted."), text)
        }
        XCTAssertThrowsError(try Self.dataset(scanRows: 1 << 20, scanColumns: 1 << 20, patternRows: 1 << 12, patternColumns: 1 << 12).validated(),
                             "2^64 bytes")
        let readable = Self.dataset(scanRows: 55, scanColumns: 75)
        XCTAssertEqual(try readable.validated(), readable)
    }

    /// The shipped Ni scan and the h5ebsd and EDAX fixtures open through the one door as their readers read them: validation refuses
    /// no file that reads.
    func testTheShippedScanAndTheFixturesStillOpen() throws {
        let nickel = try EBSDOpening.open(url: Self.nickelScan).dataset
        XCTAssertEqual([nickel.scanRows, nickel.scanColumns, nickel.patternRows, nickel.patternColumns], [55, 75, 60, 60])
        XCTAssertEqual(try nickel.validated(), nickel)
        for name in ["ebsd-kikuchipy-h5ebsd.h5", "ebsd-edax-h5ebsd.h5", "ebsd-bruker-h5ebsd.h5", "ebsd-bruker-roi-h5ebsd.h5", "ebsd-oxford.h5oina",
                     "ebsd-oxford-6.h5oina"] {
            let url = Self.fixturesFolder.appendingPathComponent(name)
            XCTAssertEqual(try EBSDOpening.open(url: url).dataset, try EBSDH5Reader.read(url: url), name)
        }
        for name in ["ebsd-edax-binary.up1", "ebsd-edax-binary.up2"] {
            let url = Self.fixturesFolder.appendingPathComponent(name)
            XCTAssertEqual(try EBSDOpening.open(url: url).dataset, try EDAXOpening.open(url: url), name)
        }
    }

    /// kikuchipy's binning from the camera mode, and none for a height of 0 or less (1024 over 0 trapped as an Int).
    func testAnOxfordCameraModeOfNoHeightGivesNoBinning() {
        XCTAssertEqual(EBSDH5Reader.oxfordBinning(cameraMode: "Speed 2 (60x60 px)"), 17, "round(1024 / 60)")
        XCTAssertEqual(EBSDH5Reader.oxfordBinning(cameraMode: "Speed 3 (80x88 px)"), 8)
        XCTAssertNil(EBSDH5Reader.oxfordBinning(cameraMode: "Broken (60x0 px)"))
        XCTAssertNil(EBSDH5Reader.oxfordBinning(cameraMode: "Broken (60x-4 px)"))
        XCTAssertNil(EBSDH5Reader.oxfordBinning(cameraMode: "Speed 2"))
    }

    /// A region of interest whose row or column indices lie further apart than an Int spans is not rectangular, where the gap between
    /// them trapped; a rectangular one still is.
    func testARegionOfInterestWithFarApartIndicesIsNotRectangular() {
        XCTAssertNil(EBSDH5Reader.rectangularROI(rows: [Int.min, Int.max], columns: [0, 0]))
        XCTAssertNil(EBSDH5Reader.rectangularROI(rows: [0, 0], columns: [Int.min, 0]))
        let square = EBSDH5Reader.rectangularROI(rows: [0, 0, 1, 1], columns: [0, 1, 0, 1])
        XCTAssertEqual(square?.rows, 2)
        XCTAssertEqual(square?.columns, 2)
    }
}
