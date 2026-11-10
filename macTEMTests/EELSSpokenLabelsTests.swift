//
//  EELSSpokenLabelsTests.swift
//  The EELS room's small controls as VoiceOver meets them: a spinner or an opening bar says what is running, a reference row that selects on a click
//  is a button. Pinned at the source next to each control, in the rooms' existing style (`FFTRoomWiringTests.squeezedUI`), and as words where the
//  words are a pure function.
//

import XCTest
import TEMCore
@testable import macTEM

nonisolated final class EELSSpokenLabelsTests: XCTestCase {

    private func ui(_ name: String) throws -> String { try FFTRoomWiringTests.squeezedUI(name) }

    /// Each spinner says what runs, the opening bar says what opens, and a reference row is a button with the click as its action. Red under: an
    /// unlabelled progress indicator beside a text; a row VoiceOver meets as plain text and cannot press.
    func testSpinnersSayWhatRunsAndAReferenceRowIsAButton() throws {
        XCTAssertEqual(EELSStage.spinnerLabel(.fit), "Fitting")
        XCTAssertEqual(EELSStage.spinnerLabel(.align), "Aligning")
        XCTAssertEqual(EELSStage.spinnerLabel(.thickness), "Mapping the thickness")
        XCTAssertEqual(EELSStage.spinnerLabel(.deconvolve), "Deconvolving")
        XCTAssertEqual(EELSStage.spinnerLabel(nil), "Computing")
        for stage in EELSStage.allCases { XCTAssertFalse(EELSStage.spinnerLabel(stage).isEmpty, stage.title) }

        let room = try ui("EELSRoom.swift")
        XCTAssertTrue(room.contains("ProgressView().progressViewStyle(.linear).frame(maxWidth: EDXLayout.openingBarWidth) .accessibilityLabel(\"Opening spectrum image\")"),
                      "the opening bar")
        XCTAssertTrue(room.contains("ProgressView().controlSize(.regular).accessibilityLabel(\"Mapping the thickness\")"), "the maps block's spinner")
        XCTAssertTrue(room.contains("if session.isComputing { ProgressView().controlSize(.small).accessibilityLabel(EELSStage.spinnerLabel(session.computingStage)) }"),
                      "the results header's spinner")

        let inspector = try ui("EELSRoomInspector.swift")
        XCTAssertTrue(inspector.contains(".onTapGesture { selected = reference.id }"))
        XCTAssertTrue(inspector.contains(".accessibilityAddTraits(selected == reference.id ? [.isButton, .isSelected] : .isButton) "
                                         + ".accessibilityAction(.default) { selected = reference.id }"), "a reference row is a button VoiceOver can press")
    }

    /// A column header that is a symbol on screen is said in words, and both tables take their headers from the one table of words; a header that is
    /// a word already is said as it is drawn. Red under: "I" read as the letter, "t/λ" as "t slash lambda"; a symbol header with no words.
    func testSymbolColumnHeadersAreSaidInWords() throws {
        XCTAssertEqual(EELSColumnSpeech.spoken("I"), "intensity")
        XCTAssertEqual(EELSColumnSpeech.spoken("at%"), "atomic percent")
        XCTAssertEqual(EELSColumnSpeech.spoken("wt%"), "weight percent")
        XCTAssertEqual(EELSColumnSpeech.spoken("I total"), "total counts")
        XCTAssertEqual(EELSColumnSpeech.spoken("t/λ"), "t over lambda")
        XCTAssertEqual(EELSColumnSpeech.spoken("Edge"), "Edge", "a word is said as it is drawn")
        XCTAssertEqual(EELSColumnSpeech.spoken(edge: "Fe L2,3", column: "at%"), "Fe L2,3 atomic percent")
        XCTAssertEqual(EELSColumnSpeech.spoken(edge: "Fe L2,3", column: "I"), "Fe L2,3 intensity")
        for (drawn, words) in EELSColumnSpeech.words {
            XCTAssertFalse(words.isEmpty, drawn)
            XCTAssertNotEqual(words, drawn, "\(drawn) has words of its own")
        }

        let room = try ui("EELSRoom.swift")
        for symbol in ["I", "at%", "wt%"] {
            XCTAssertTrue(room.contains("TableColumn(EELSColumnSpeech.header(\"\(symbol)\")) { r in"), "the results table's \(symbol) column")
            XCTAssertFalse(room.contains("TableColumn(\"\(symbol)\")"), "\(symbol) is not a bare symbol header")
        }
        let regions = try ui("EELSRegionsTable.swift")
        XCTAssertTrue(regions.contains("EELSColumnSpeech.header(\"I total\") EELSColumnSpeech.header(\"t/λ\")"))
        XCTAssertTrue(regions.contains("ForEach(edges) { Text(\"\\($0.title)\").accessibilityLabel(EELSColumnSpeech.spoken(edge: $0.title, column: \"I\")) }"))
        XCTAssertTrue(regions.contains("Text(\"\\($0.title) at%\").accessibilityLabel(EELSColumnSpeech.spoken(edge: $0.title, column: \"at%\"))"))
    }
}
