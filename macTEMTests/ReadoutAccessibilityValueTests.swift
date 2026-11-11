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

    /// The Image pane speaks the pixel and its value under the pointer, the Diffraction pattern q and d, each as the status line reads them; else
    /// what they spoke before (the size, and the rings and spots). Red under: the static value, so VoiceOver heard the size wherever the pointer was.
    func testTheImageAndDiffractionPanesSpeakTheirReadout() throws {
        let image = try FFTRoomWiringTests.squeezedUI("ImagePane.swift")
        XCTAssertTrue(image.contains(#".modifier(ReadoutAccessibilityValue(readout: { appState.imageRoomTools.readout }, fallback: "\(image.width) by \(image.height) pixels"))"#))
        XCTAssertFalse(image.contains(#".accessibilityValue("\(image.width) by \(image.height) pixels")"#), "the static value is gone")
        let diffraction = try FFTRoomWiringTests.squeezedUI("DiffractionRoom.swift")
        XCTAssertTrue(diffraction.contains(#".modifier(ReadoutAccessibilityValue(readout: { appState.diffractionReadout }, fallback: "\(image.width) by \(image.height) pixels, \(UnitDisplay.count(analysis.rings.count, "ring", "rings")), \(UnitDisplay.count(analysis.spots.count, "spot", "spots"))"))"#))
        XCTAssertFalse(diffraction.contains(#".accessibilityValue("\(image.width) by \(image.height) pixels, "#), "the static value is gone")
    }

    /// Each pane speaks a readout only it writes, so it never says what the pointer reads over another pane (the EELS case above). Red under: a
    /// second writer of either readout in the app's sources.
    func testEachSpokenReadoutHasOneWriter() throws {
        let root = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
        var writers: [String: Set<String>] = ["imageRoomTools.readout =": [], "diffractionReadout =": []]
        for folder in ["macTEM/UI", "macTEM/App"] {
            let dir = root.appendingPathComponent(folder)
            for file in try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) where file.pathExtension == "swift" {
                let code = try String(contentsOf: file, encoding: .utf8).split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                for key in writers.keys where code.contains(where: { $0.contains(key) }) { writers[key]?.insert(file.lastPathComponent) }
            }
        }
        XCTAssertEqual(writers["imageRoomTools.readout ="], ["ImagePane.swift"])
        XCTAssertEqual(writers["diffractionReadout ="], ["DiffractionRoom.swift"])
    }
}
