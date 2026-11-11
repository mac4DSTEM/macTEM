//
//  SpokenControlNameTests.swift
//  Controls VoiceOver could not name (#297): the Particles section's Minimum area stepper, whose label is its value on screen
//  ("12 px²", so the control was called by its value), the FFT source pane's filtering spinner, which had a tooltip and no label, and
//  three spinners with neither: the one beside "Opening image" and the FFT spectrum pane's two (its header's and the computing state's).
//  Nothing drawn changes, so the lines are read as text, and the stepper's spoken value is the pure count it is written with.
//  Red before the change: none of these controls carried an accessibility label.
//

import XCTest
import TEMCore

nonisolated final class SpokenControlNameTests: XCTestCase {

    /// The stepper is called by its row's title and valued in words, on the control that carries its identifier.
    /// Red under: the label removed (VoiceOver names the stepper "12 px²"), the value left as the symbol, the two moved to another control.
    func testTheMinimumAreaStepperIsNamedAndValued() throws {
        let section = try FFTRoomWiringTests.squeezedUI("ImageRoomParticles.swift")
        XCTAssertTrue(section.contains("InspectorRow(\"Minimum area\") { Stepper(value: Binding(get: { settings.minimumArea }"))
        XCTAssertTrue(section.contains(
            ".accessibilityLabel(\"Minimum area\") .accessibilityValue(UnitDisplay.count(settings.minimumArea, \"square pixel\", \"square pixels\")) "
                + ".accessibilityIdentifier(\"particles.minimumArea\")"))
        XCTAssertEqual(UnitDisplay.count(1, "square pixel", "square pixels"), "1 square pixel")
        XCTAssertEqual(UnitDisplay.count(12, "square pixel", "square pixels"), "12 square pixels")
        XCTAssertEqual(UnitDisplay.count(1200, "square pixel", "square pixels"), "1200 square pixels", "the number as it is, not grouped")
    }

    /// The spinner beside the FFT source pane's View menu says what is running.
    /// Red under: the label removed (VoiceOver finds a busy indicator with no name; the tooltip is not spoken).
    func testTheFilteringSpinnerSaysWhatRuns() throws {
        let pane = try FFTRoomWiringTests.squeezedUI("FFTSourceImagePane.swift")
        XCTAssertTrue(pane.contains(
            "if analysis.isFiltering { ProgressView().controlSize(.small).help(\"Filtering\u{2026}\").accessibilityLabel(\"Filtering\") }"))
    }

    /// The spinner shown while an image opens and the FFT spectrum pane's two spinners say what runs. The words drawn beside a spinner are an
    /// element of their own and do not name it, and the FFT header draws no words at all when it is narrow.
    /// Red under: a label removed (VoiceOver finds a busy indicator with no name).
    func testTheOpeningAndFFTSpinnersSayWhatRuns() throws {
        let workspace = try FFTRoomWiringTests.squeezedUI("WorkspaceView.swift")
        XCTAssertTrue(workspace.contains("ProgressView() .controlSize(.small) .accessibilityLabel(\"Opening image\") Text(\"Opening image\")"),
                      "the image-opening spinner")
        let pane = try FFTRoomWiringTests.squeezedUI("FFTSpectrumImagePane.swift")
        XCTAssertTrue(pane.contains("ProgressView().controlSize(.small).accessibilityLabel(\"Updating\") } .fixedSize()"), "the header's spinner")
        XCTAssertTrue(pane.contains("if failure == nil { ProgressView().controlSize(.small).accessibilityLabel(\"Computing the spectrum\") }"),
                      "the computing state's spinner")
    }
}
