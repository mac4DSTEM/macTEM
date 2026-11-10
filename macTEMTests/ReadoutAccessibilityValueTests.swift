//
//  ReadoutAccessibilityValueTests.swift
//  A pane's accessibility value is what the pointer reads while it is over the pane, else the pane's own description (`ReadoutAccessibilityValue`), and
//  the EELS spectrum, the first pane to use it, speaks its own readout only: the room's one status-line readout is also written by the maps.
//

import XCTest
@testable import macTEM

nonisolated final class ReadoutAccessibilityValueTests: XCTestCase {

    /// The readout when there is one, else the fallback. Red under: the fallback always (the pointer's readout reached the status line only); an empty
    /// readout spoken as an empty value.
    func testTheValueIsTheReadoutWhileThereIsOneElseTheFallback() {
        XCTAssertEqual(ReadoutSpeech.value(readout: "532 eV · O K onset · 1200 counts", fallback: "283 to 1200 eV shown"), "532 eV · O K onset · 1200 counts")
        XCTAssertEqual(ReadoutSpeech.value(readout: nil, fallback: "283 to 1200 eV shown"), "283 to 1200 eV shown")
        XCTAssertEqual(ReadoutSpeech.value(readout: "", fallback: "283 to 1200 eV shown"), "283 to 1200 eV shown")
    }

    /// The EELS spectrum's readout is the status line's while the spectrum wrote it, and nothing once a map writes its pixel there or the pointer
    /// leaves. Red under: the spectrum speaking "row 4 · col 3" as its own value while the pointer is over a map.
    @MainActor func testTheSpectrumSpeaksItsOwnReadoutAndNeverAMapsPixel() {
        let state = EELSRoomState()
        XCTAssertNil(state.spectrumReadout)
        state.setSpectrumReadout("532 eV · O K onset · 1200 counts")
        XCTAssertEqual(state.readout, "532 eV · O K onset · 1200 counts", "the status line reads it as before")
        XCTAssertEqual(state.spectrumReadout, "532 eV · O K onset · 1200 counts")
        state.readout = "row 4 · col 3 · t/λ 0.52"
        XCTAssertNil(state.spectrumReadout, "a map's pixel is not the spectrum's readout")
        state.setSpectrumReadout("284 eV · 90 counts")
        XCTAssertEqual(state.spectrumReadout, "284 eV · 90 counts")
        state.setSpectrumReadout(nil)
        XCTAssertNil(state.readout)
        XCTAssertNil(state.spectrumReadout)
        state.setSpectrumReadout("284 eV · 90 counts")
        state.reset()
        XCTAssertNil(state.spectrumReadout, "a new file starts the view over")
    }

    /// The spectrum takes its value through the modifier, with what it shows as the fallback, and its hover writes the readout as the spectrum's. Red
    /// under: a static value (the label alone before); the readout read in the pane's own body.
    func testTheEELSSpectrumAppliesTheModifier() throws {
        let source = try FFTRoomWiringTests.squeezedUI("EELSRoom.swift")
        XCTAssertTrue(source.contains(".modifier(ReadoutAccessibilityValue(readout: { state.spectrumReadout }, fallback: spoken))"))
        XCTAssertTrue(source.contains("state.setSpectrumReadout(Self.readout(at: e, plot: plot))"))
        XCTAssertFalse(source.contains("state.readout = Self.readout(at: e, plot: plot)"), "the spectrum's hover marks its readout as its own")
        let modifier = try FFTRoomWiringTests.squeezedUI("ReadoutAccessibilityValue.swift")
        XCTAssertTrue(modifier.contains("content.accessibilityValue(ReadoutSpeech.value(readout: readout(), fallback: fallback))"),
                      "the readout is read in the modifier's body")
    }
}
