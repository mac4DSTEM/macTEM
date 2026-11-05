//
//  EELSResultsColumnsTests.swift
//  The EELS results table as the EDS room's (`EDXResultsColumns`): each column's minimum holds the longest cell the room's formatter writes inside a stated
//  bound, measured in the font the table draws it in, so at% and wt% are never cut ("95,88…", "not de…" on a real spectrum image, 2026-11-02).
//  A pane narrower than the four columns scrolls them, as the EDS room's table does.
//
//  THE TRUTH: the formatter's own strings for planted rows; the cell texts are pinned, so the change moves widths only, never a number.
//

import XCTest
import AppKit
import TEMCore
@testable import macTEM

nonisolated final class EELSResultsColumnsTests: XCTestCase {
    /// `.body.monospacedDigit()`: what a Table cell draws its text in (as the EDS room's test).
    private let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    private let bold = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
    /// A comma locale too: the drive's Mac wrote "95,88".
    private let locales = [Locale(identifier: "en_US"), Locale(identifier: "de_DE")]

    private func width(_ text: String, _ f: NSFont? = nil) -> CGFloat { (text as NSString).size(withAttributes: [.font: f ?? font]).width }

    private func row(i: Double? = 1, s: Double? = nil, at: Double? = nil, atSigma: Double? = nil, wt: Double? = nil, wtSigma: Double? = nil,
                     fitOnly: Bool = false, notDetected: Bool = false) -> EELSEdgeRow {
        EELSEdgeRow(id: "C_K", title: "C K", onsetEV: 284, intensity: i, arealDensityPerNM2: nil, atomicPercent: at, weightPercent: wt, unavailable: nil,
                    intensityStd: s, fitOnly: fitOnly, atomicSigma: atSigma, weightSigma: wtSigma, notDetected: notDetected)
    }

    private func widest(_ texts: [String]) -> (text: String, width: CGFloat) {
        texts.map { ($0, width($0)) }.max { $0.1 < $1.1 } ?? ("", 0)
    }

    /// at% and wt%: a value from 0 to 100 with a 1σ of 0.001 or more (the formatter writes three decimals at most), and the words a cell says instead.
    func testThePercentColumnsHoldTheLongestValueAndSigmaAndTheWords() {
        let values: [Double] = [0, 0.05, 1, 9.999, 12.34, 50, 95.88, 99.999, 100]
        let sigmas: [Double?] = [nil, 0.001, 0.0099, 0.01, 0.0199, 0.05, 0.099, 0.5, 0.99, 1, 5, 9.9, 10, 50, 99]
        var texts: [String] = []
        for locale in locales {
            for v in values { for s in sigmas {
                texts.append(EELSRoomFormat.atomicText(row(at: v, atSigma: s), locale: locale))
                texts.append(EELSRoomFormat.weightText(row(wt: v, wtSigma: s), locale: locale))
            } }
        }
        texts += [EELSRoomFormat.atomicText(row(fitOnly: true)), EELSRoomFormat.atomicText(row(notDetected: true)),
                  EELSRoomFormat.atomicText(row(i: 1, s: 1)), EELSRoomFormat.atomicText(row())]
        let w = widest(texts)
        XCTAssertLessThanOrEqual(w.width + EELSResultsColumns.cellAllowance, EELSResultsColumns.percentMinimum,
                                 "\"\(w.text)\" is \(w.width) pt; widen EELSResultsColumns.percentMinimum, do not let the cell be cut off")
    }

    /// I: an intensity from 10⁻⁶ to 10⁹ with a 1σ from a thousandth to ten times it, or a negative one (an edge under its noise) with a 1σ of at least a
    /// third of it (four significant digits, σ to two, a power of ten outside 0.01 to 100 000; the drive's intensities were 10⁻⁵ to 10⁻⁴).
    func testTheIntensityColumnHoldsTheLongestValueAndSigma() {
        var texts: [String] = []
        for locale in locales {
            for e in -6...9 { for m in [1.0, 4.999, 8.888, 9.999] {
                let i = m * pow(10, Double(e))
                for k in [0.001, 0.0123, 0.5, 1, 9.9] { texts.append(EELSRoomFormat.intensityText(row(i: i, s: i * k), locale: locale)) }
                for k in [0.34, 1, 9.9] { texts.append(EELSRoomFormat.intensityText(row(i: -i, s: i * k), locale: locale)) }
                texts.append(EELSRoomFormat.intensityText(row(i: i), locale: locale))
            } }
        }
        let w = widest(texts)
        XCTAssertLessThanOrEqual(w.width + EELSResultsColumns.cellAllowance, EELSResultsColumns.intensityMinimum,
                                 "\"\(w.text)\" is \(w.width) pt; widen EELSResultsColumns.intensityMinimum, do not let the σ be cut off")
    }

    /// Edge: the longest edge title, semibold, with the mark a refused edge carries.
    func testTheEdgeColumnHoldsTheLongestTitleAndItsMark() {
        let w = widest(["C K", "Fe L3", "Gd M5", "Ba M45", "Cu L23"])
        let semibold = width(w.text, bold)
        XCTAssertLessThanOrEqual(semibold + 4 + 16 + EELSResultsColumns.cellAllowance, EELSResultsColumns.edgeMinimum,
                                 "\"\(w.text)\" and its mark need \(semibold + 20) pt; widen EELSResultsColumns.edgeMinimum")
    }

    /// The table takes the measured widths (a column that went back to a literal would cut the cell again).
    func testTheTableTakesTheMeasuredWidths() throws {
        let root = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
        let room = try String(contentsOf: root.appendingPathComponent("macTEM/UI/EELSRoom.swift"), encoding: .utf8)
        XCTAssertEqual(room.components(separatedBy: "min: EELSResultsColumns.percentMinimum").count - 1, 2, "at% and wt%")
        XCTAssertEqual(room.components(separatedBy: "min: EELSResultsColumns.intensityMinimum").count - 1, 1, "I")
        XCTAssertEqual(room.components(separatedBy: "min: EELSResultsColumns.edgeMinimum").count - 1, 1, "Edge")
    }

    /// The cells' texts are the formatter's, unchanged: the widths move, no number does.
    func testTheCellTextsStayTheSame() {
        let en = Locale(identifier: "en_US")
        XCTAssertEqual(EELSRoomFormat.atomicText(row(at: 95.8812, atSigma: 0.1234), locale: en), "95.88 ± 0.12")
        XCTAssertEqual(EELSRoomFormat.weightText(row(wt: 7.26, wtSigma: nil), locale: en), "7.3")
        XCTAssertEqual(EELSRoomFormat.intensityText(row(i: 2.0071e-4, s: 1.73e-5), locale: en), "2.007e-4 ± 1.7e-5")
        XCTAssertEqual(EELSRoomFormat.atomicText(row(notDetected: true)), "not detected")
    }
}
