//
//  TableCopyFormatTests.swift
//  ⌘C in the Image room's object table and in the Diffraction room's readout (#353): the selected row as tab-separated text under
//  the table's column titles, the cells as the table shows them, numbers in the reader's locale without grouping; nothing for no
//  rows; and the tables' own lines, which draw their cells through the same functions and carry the copy command.
//  Red before the change: no `ParticleTableFormat`, no `DiffractionReadoutFormat`, no `onCopyCommand` on either table.
//

import XCTest
import TEMCore
@testable import macTEM

nonisolated final class TableCopyFormatTests: XCTestCase {

    private static let en = Locale(identifier: "en_US")
    private static let de = Locale(identifier: "de_DE")

    private func ui(_ name: String) throws -> String { try FFTRoomWiringTests.squeezedUI(name) }

    // MARK: The pasteboard's lines

    /// A tab or a line break inside a cell becomes a space, so a cell never opens a column or a row; no rows copy nothing.
    /// Red under: a cell's tab kept (the paste lands one column off), a header copied alone.
    func testACellNeverOpensAColumnOrARow() {
        XCTAssertEqual(TableCopyText.line(["a\tb", "c\r\nd", "e\nf", "g\rh"]), "a b\tc d\te f\tg h")
        XCTAssertEqual(TableCopyText.text(titles: ["x", "y"], rows: [["1", "2"], ["3", "4"]]), "x\ty\n1\t2\n3\t4")
        XCTAssertEqual(TableCopyText.text(titles: ["x", "y"], rows: []), "")
    }

    // MARK: The object table

    private static let objects = [
        ParticleRow(id: 3, counted: true, note: "", area: 97.389, length: 15.94, width: 6.126, angle: 37.26),
        ParticleRow(id: 1204, counted: false, note: "edge", area: 12_345, length: 0.873, width: 0.25, angle: -4.04),
    ]

    /// An object's row copies under the table's titles with the precision the table shows: three significant digits for the
    /// lengths and the area, one decimal for the angle, the number never grouped, "counted" or why not.
    /// Red under: a cell at another precision than the table's, the titles without the unit, a grouped object number.
    func testAnObjectRowCopiesAsTheTableShowsIt() {
        XCTAssertEqual(ParticleTableFormat.copyText(Self.objects, unit: "nm", locale: Self.en),
                       ["#\tLength (nm)\tWidth (nm)\tAngle (\u{00B0})\tArea (nm\u{00B2})\tNote",
                        "3\t15.9\t6.13\t37.3\t97.4\tcounted",
                        "1204\t0.873\t0.25\t-4.0\t12300\tedge"].joined(separator: "\n"))
        XCTAssertEqual(ParticleTableFormat.copyText([Self.objects[0]], unit: "px", locale: Self.de),
                       "#\tLength (px)\tWidth (px)\tAngle (\u{00B0})\tArea (px\u{00B2})\tNote\n3\t15,9\t6,13\t37,3\t97,4\tcounted",
                       "the reader's decimal mark, as the table shows it")
        XCTAssertEqual(ParticleTableFormat.copyText([], unit: "nm", locale: Self.en), "", "no row selected copies nothing")
        XCTAssertEqual(ParticleTableFormat.titles(unit: "nm").count, ParticleTableFormat.cells(Self.objects[0], locale: Self.en).count)
    }

    /// The object table draws the angle and the note through the format, shows the object's number ungrouped, and carries the copy
    /// command, dimmed with no row selected. Red under: the command removed (Edit > Copy dims with a row selected), always enabled,
    /// or a cell drawn by another expression than the one copied.
    func testTheObjectTableCopiesItsSelectedRow() throws {
        let table = try ui("ImageRoomParticles.swift")
        XCTAssertTrue(table.contains(".onCopyCommand(perform: rows.contains(where: { $0.id == selected }) ? { copied(rows, selected: selected) } : nil)"))
        XCTAssertTrue(table.contains("return [NSItemProvider(object: ParticleTableFormat.copyText(picked, unit: scale.unit) as NSString)]"))
        XCTAssertTrue(table.contains("TableColumn(\"#\", value: \\.id) { Text(verbatim: \"\\($0.id)\").monospacedDigit() }"))
        XCTAssertTrue(table.contains("{ Text(ParticleTableFormat.angle($0)).monospacedDigit() }"))
        XCTAssertTrue(table.contains("TableColumn(\"Note\") { Text(ParticleTableFormat.note($0))"))
        for title in ["\"Length (\\(scale.unit))\"", "\"Width (\\(scale.unit))\"", "\"Angle (\u{00B0})\"", "\"Area (\\(scale.unit)\u{00B2})\""] {
            XCTAssertTrue(table.contains("TableColumn(\(title), value:"), "the table's title \(title) is the copied one")
        }
    }

    // MARK: The Diffraction readout

    private static func readout() -> [DiffractionReadoutRow] {
        [DiffractionReadoutRow(id: UUID(), kind: .ring, number: 1, radiusPx: 33.982, q: 0.424771, d: 2.35419, family: "{111}", dListed: 2.3546,
                               deltaPercent: -0.0127, oddsText: "12:1", verdict: "matches {111}", validation: "", isCalibrating: true),
         DiffractionReadoutRow(id: UUID(), kind: .spot, number: 2, radiusPx: 55.48, q: nil, d: nil, family: nil, dListed: nil,
                               deltaPercent: nil, oddsText: nil, verdict: "two\tfamilies\nin reach", validation: "")]
    }

    /// A ring and a spot copy under the readout's titles with the table's decimals (R two, q five, d four, Δd/d signed to two), a
    /// dash where there is no value, the calibrating ring marked as the table marks it.
    /// Red under: a column dropped or out of the table's order, d at the CSV's precision, a verdict's line break kept.
    func testAReadoutRowCopiesAsTheTableShowsIt() {
        let rows = Self.readout()
        let header = "Ring or spot\tR px\tq \u{00C5}\u{207B}\u{00B9}\td \u{00C5}\tfamily\td listed\t\u{0394}d/d %\todds\tverdict"
        XCTAssertEqual(DiffractionReadoutFormat.copyText(rows, locale: Self.en),
                       [header,
                        "Ring 1 \u{25CF}\t33.98\t0.42477\t2.3542\t{111}\t2.3546\t-0.01\t12:1\tmatches {111}",
                        "Spot 2\t55.48\t\u{2014}\t\u{2014}\t\u{2014}\t\u{2014}\t\u{2014}\t\u{2014}\ttwo families in reach"].joined(separator: "\n"))
        XCTAssertEqual(DiffractionReadoutFormat.copyText([rows[0]], locale: Self.de),
                       header + "\nRing 1 \u{25CF}\t33,98\t0,42477\t2,3542\t{111}\t2,3546\t-0,01\t12:1\tmatches {111}")
        XCTAssertEqual(DiffractionReadoutFormat.copyText([], locale: Self.en), "")
    }

    /// The columns are the table's nine, in its order; only the first is drawn without a title, and it is named in the copied text.
    func testTheReadoutsColumnsAreTheTablesNine() {
        let columns = DiffractionReadoutFormat.Column.allCases
        XCTAssertEqual(columns, [.name, .radius, .q, .d, .family, .dListed, .delta, .odds, .verdict])
        XCTAssertEqual(columns.filter { $0.title.isEmpty }, [.name])
        XCTAssertEqual(columns.map(\.copiedTitle).filter(\.isEmpty), [], "every copied column has a title")
        XCTAssertEqual(DiffractionReadoutFormat.cells(Self.readout()[0], locale: Self.en).count, columns.count)
    }

    /// The readout table draws every title and cell through the format (a header is the column's title, `header`, pinned with its spoken
    /// label by DiffractionReadoutSpeechTests) and carries the copy command beside Delete, dimmed with no row selected. Red under: the
    /// command removed or always enabled, a column drawn by its own expression.
    func testTheReadoutTableCopiesItsSelectedRow() throws {
        let table = try ui("DiffractionRoom.swift")
        XCTAssertTrue(table.contains(".onCopyCommand(perform: rows.contains(where: { $0.id == selected }) ? { copied(selected) } : nil)"))
        XCTAssertTrue(table.contains("return [NSItemProvider(object: DiffractionReadoutFormat.copyText(picked) as NSString)]"))
        for column in ["name", "radius", "q", "d", "family", "dListed", "delta", "odds", "verdict"] {
            XCTAssertTrue(table.contains("TableColumn(header(.\(column))) { row in Text(DiffractionReadoutFormat.cell(.\(column), row))"),
                          "the \(column) column is the format's title and cell")
        }
    }
}
