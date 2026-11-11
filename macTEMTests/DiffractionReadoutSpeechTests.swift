//
//  DiffractionReadoutSpeechTests.swift
//  What VoiceOver calls the Diffraction readout's columns (#320): the headers are symbols and units ("R px", "q Å⁻¹", "Δd/d %") and the
//  first is empty, so each column carries its words; the ring that sets the scale says so, where the cell shows only "●". The table's
//  own lines are read as text. Whether the system's table header speaks a `Text`'s accessibility label is not something a unit test
//  reaches: unverified on screen.
//  Red before the change: no `Column.spoken`, no `spokenName`, no `spokenMark`; the headers were plain titles.
//

import XCTest
import TEMCore
@testable import macTEM

nonisolated final class DiffractionReadoutSpeechTests: XCTestCase {

    private typealias Column = DiffractionReadoutFormat.Column

    /// Every column has words, and the words hold nothing VoiceOver reads sign by sign: letters, spaces and commas only.
    /// Red under: a column left without words (the empty first header), a unit symbol or a Greek letter in the spoken form.
    func testEveryHeaderHasAWordForm() {
        for column in Column.allCases {
            XCTAssertFalse(column.spoken.isEmpty, "\(column) is called nothing")
            XCTAssertTrue(column.spoken.allSatisfy { $0.isLetter || $0 == " " || $0 == "," }, "\(column) is spoken as \"\(column.spoken)\"")
        }
        XCTAssertEqual(Set(Column.allCases.map(\.spoken)).count, Column.allCases.count, "no two columns are called the same")
    }

    /// A header of symbols is spelled out, the unit in words; a header that is words already is spoken as drawn.
    /// Red under: "R px" spoken as drawn, the empty header unnamed, a word header renamed away from what is on screen.
    func testASymbolHeaderIsSpelledOutAndAWordHeaderIsSpokenAsDrawn() {
        XCTAssertEqual(Column.name.spoken, "Ring or spot")
        XCTAssertEqual(Column.radius.spoken, "radius, pixels")
        XCTAssertEqual(Column.q.spoken, "q, inverse \u{00E5}ngstr\u{00F6}ms")
        XCTAssertEqual(Column.d.spoken, "d, \u{00E5}ngstr\u{00F6}ms")
        XCTAssertEqual(Column.delta.spoken, "delta d over d, percent")
        let words: [Column] = [.family, .dListed, .odds, .verdict]
        for column in words {
            XCTAssertEqual(column.spoken, column.title, "\(column) is words already")
        }
        XCTAssertEqual(Column.name.spoken, Column.name.copiedTitle, "the first column has one name, spoken and copied")
    }

    private static func row(_ kind: DiffractionReadoutRow.Kind, _ number: Int, calibrating: Bool) -> DiffractionReadoutRow {
        DiffractionReadoutRow(id: UUID(), kind: kind, number: number, radiusPx: 33.98, q: 0.42477, d: 2.3542, family: "{111}", dListed: 2.3546,
                              deltaPercent: -0.01, oddsText: "12:1", verdict: "matches {111}", validation: "", isCalibrating: calibrating)
    }

    /// The first cell is called by its name without the mark, and the ring that sets the scale says so as its value.
    /// Red under: "●" left in the spoken name, the meaning said for a row that does not set the scale, the drawn cell changed.
    func testTheRingThatSetsTheScaleSaysSo() {
        let calibrating = Self.row(.ring, 1, calibrating: true)
        let other = Self.row(.spot, 2, calibrating: false)
        XCTAssertEqual(DiffractionReadoutFormat.spokenName(calibrating), "Ring 1")
        XCTAssertEqual(DiffractionReadoutFormat.spokenMark(calibrating), "sets the scale")
        XCTAssertEqual(DiffractionReadoutFormat.spokenName(other), "Spot 2")
        XCTAssertEqual(DiffractionReadoutFormat.spokenMark(other), "")
        XCTAssertEqual(DiffractionReadoutFormat.cell(.name, calibrating), "Ring 1 \u{25CF}", "the cell is drawn as before")
        XCTAssertEqual(DiffractionReadoutFormat.cell(.name, other), "Spot 2")
    }

    /// The table's header carries each column's words, and the first cell its spoken name and value; that every column takes that header
    /// is held by TableCopyFormatTests. Red under: a column on a plain title again, the header's label dropped, the mark's meaning off the cell.
    func testTheReadoutTableSpeaksItsHeaders() throws {
        let table = try FFTRoomWiringTests.squeezedUI("DiffractionRoom.swift")
        XCTAssertTrue(table.contains("private func header(_ column: Column) -> Text { Text(column.title).accessibilityLabel(column.spoken) }"))
        XCTAssertFalse(table.contains("TableColumn(Column."), "no column on a plain title")
        XCTAssertFalse(table.contains("TableColumn(\""), "no column on a literal title")
        XCTAssertTrue(table.contains(
            ".help(row.isCalibrating ? \"Set the scale\" : \"\") .accessibilityLabel(DiffractionReadoutFormat.spokenName(row)) "
                + ".accessibilityValue(DiffractionReadoutFormat.spokenMark(row))"))
    }
}
