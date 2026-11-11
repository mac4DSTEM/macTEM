//
//  SEMColumnSpeechTests.swift
//  The words VoiceOver says for the SEM rooms' symbol headers (#320, `SEMColumnSpeech`): each symbol the Maps and Indexing tables draw
//  has a word form, a header that is a word already is said as drawn, and the Maps room's Grains table and its orientation pane's Euler
//  line take their words from the one table, while what they draw stays as it was. Red before: no such table; "φ₁ °", "ECD µm" and
//  "GOS °" were read sign by sign.
//

import XCTest
@testable import macTEM

nonisolated final class SEMColumnSpeechTests: XCTestCase {

    private static let en = Locale(identifier: "en_US")
    private static let de = Locale(identifier: "de_DE")

    /// Every symbol header of the Maps Grains table and the Indexing Results and Bands tables has a word form; none is empty or the
    /// symbol again. Red under: a symbol left out of the table (said sign by sign), an empty word form.
    func testEverySymbolHeaderHasWords() {
        let expected = [
            "φ₁ °": "phi one, degrees", "Φ °": "capital phi, degrees", "φ₂ °": "phi two, degrees",
            "ECD µm": "equivalent circle diameter, micrometres", "ECD px": "equivalent circle diameter, pixels",
            "GOS °": "grain orientation spread, degrees", "CI": "confidence index", "PQ": "pattern quality", "OSM": "orientation similarity",
            "NCC": "normalised cross-correlation", "NDP": "normalised dot product", "Col": "column", "#": "number",
            "ρ px": "rho, pixels", "θ °": "theta, degrees", "Fit °": "Fit, degrees",
        ]
        for (drawn, words) in expected { XCTAssertEqual(SEMColumnSpeech.spoken(drawn), words, drawn) }
        for (symbol, words) in SEMColumnSpeech.symbols {
            XCTAssertFalse(words.isEmpty, symbol)
            XCTAssertNotEqual(words, symbol, symbol)
        }
    }

    /// A header that is a word, or words without a unit, is said as it is drawn. Red under: "Grain" or "d listed" rewritten.
    func testAWordHeaderIsSaidAsDrawn() {
        for drawn in ["Grain", "Phase", "Points", "Schmid", "Neighbours", "Row", "Bands", "Simulation", "Peak", "Width", "d listed", ""] {
            XCTAssertEqual(SEMColumnSpeech.spoken(drawn), drawn)
        }
    }

    /// The Grains table's titles: the five symbol ones are said in words, the five word ones as drawn. Red under: a symbol title the
    /// table of words does not know.
    func testTheGrainsTablesSymbolTitlesAreSaidInWords() {
        let titles = GrainTableFormat.titles(unit: "µm")
        let symbols = ["ECD µm", "φ₁ °", "Φ °", "φ₂ °", "GOS °"]
        for title in titles {
            if symbols.contains(title) {
                XCTAssertNotEqual(SEMColumnSpeech.spoken(title), title, title)
            } else {
                XCTAssertEqual(SEMColumnSpeech.spoken(title), title, title)
            }
        }
        XCTAssertEqual(Set(symbols).subtracting(titles), [], "each symbol title is one of the table's")
    }

    /// The orientation pane's Euler line is drawn as before and said in words, each value as drawn, in the reader's locale.
    /// Red under: the line read sign by sign, a spoken value other than the drawn one.
    func testTheEulerLineIsDrawnAsBeforeAndSaidInWords() {
        let radians = SIMD3(203.3, 38.8, 171.2) * (Double.pi / 180)
        let en = MapsRoomFormat.eulerValues(radians, locale: Self.en)
        XCTAssertEqual(en, ["203.3", "38.8", "171.2"])
        XCTAssertEqual(MapsRoomFormat.eulerLine(en), "φ₁ 203.3°  Φ 38.8°  φ₂ 171.2°")
        XCTAssertEqual(SEMColumnSpeech.spokenEuler(en), "phi one 203.3 degrees, capital phi 38.8 degrees, phi two 171.2 degrees")
        let de = MapsRoomFormat.eulerValues(radians, locale: Self.de)
        XCTAssertEqual(MapsRoomFormat.eulerLine(de), "φ₁ 203,3°  Φ 38,8°  φ₂ 171,2°")
        XCTAssertEqual(SEMColumnSpeech.spokenEuler(de), "phi one 203,3 degrees, capital phi 38,8 degrees, phi two 171,2 degrees")
        XCTAssertEqual(MapsRoomFormat.eulerValues(SIMD3(.nan, 0, 0), locale: Self.en), ["—", "0.0", "0.0"], "no value is a dash")
    }

    /// The Grains table draws each symbol header through the table of words, each title the copied one (`GrainTableFormat.titles`), and
    /// the orientation pane's Euler line carries its words. Red under: a header drawn as a bare string again, a drawn title other than
    /// the copied one, the Euler line without its label.
    func testTheMapsRoomTakesItsWordsFromTheTable() throws {
        let table = try FFTRoomWiringTests.squeezedUI("MapsRoomAnalysis.swift")
        for title in GrainTableFormat.titles(unit: "\\(unit)") {
            let drawn = table.contains("TableColumn(\"\(title)\"") || table.contains("TableColumn(SEMColumnSpeech.header(\"\(title)\")")
            XCTAssertTrue(drawn, "the table draws the copied title \(title)")
        }
        for title in ["ECD \\(unit)", "φ₁ °", "Φ °", "φ₂ °", "GOS °"] {
            XCTAssertTrue(table.contains("TableColumn(SEMColumnSpeech.header(\"\(title)\"), value:"), "\(title) is said in words")
            XCTAssertFalse(table.contains("TableColumn(\"\(title)\""), "\(title) drawn without its words")
        }
        let room = try FFTRoomWiringTests.squeezedUI("MapsRoom.swift")
        XCTAssertTrue(room.contains("let euler = MapsRoomFormat.eulerValues(found.euler) Text(verbatim: MapsRoomFormat.eulerLine(euler))"))
        XCTAssertTrue(room.contains(".accessibilityLabel(SEMColumnSpeech.spokenEuler(euler))"))
    }
}
