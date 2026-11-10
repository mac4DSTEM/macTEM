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
}
