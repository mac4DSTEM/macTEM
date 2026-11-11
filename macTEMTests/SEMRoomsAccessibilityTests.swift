//
//  SEMRoomsAccessibilityTests.swift
//  What VoiceOver hears in the SEM rooms beside what they draw: the opening bars of the Patterns, Indexing and Maps rooms say what
//  opens (#297), as the EELS room's does; the live pattern pane's value is the detector pixel under the pointer while it is over the
//  pattern, else which pattern it shows (#345), as the EELS spectrum's is. Red before: the bars had no label (VoiceOver found an
//  unnamed busy indicator), and the pattern pane's value was its title wherever the pointer was.
//

import XCTest
@testable import macTEM

nonisolated final class SEMRoomsAccessibilityTests: XCTestCase {

    private func ui(_ name: String) throws -> String { try FFTRoomWiringTests.squeezedUI(name) }

    // MARK: The opening bars (#297)

    /// Each room's opening bar is named by its own sentence, the words drawn under it. Red under: a label removed or another room's
    /// sentence.
    func testTheOpeningBarsSayWhatOpens() throws {
        let bar = "ProgressView().progressViewStyle(.linear).frame(maxWidth: EDXLayout.openingBarWidth) .accessibilityLabel("
        for (file, sentence) in [("PatternsRoom.swift", "Opening dataset"), ("IndexingRoom.swift", "Opening dataset"),
                                 ("MapsRoom.swift", "Opening orientation map"), ("EELSRoom.swift", "Opening spectrum image")] {
            let room = try ui(file)
            XCTAssertTrue(room.contains(bar + "\"\(sentence)\") Text(\"\(sentence)\").font(.headline)"), "\(file)'s opening bar")
        }
    }

    // MARK: The live pattern pane's value (#345)

    /// The pattern pane's readout is the status line's while the pane wrote it, and nothing once the scan map writes its position there
    /// or the pointer leaves. Red under: the pane speaking the map's "row 3 · col 7 · mean 118.3" as its own value.
    @MainActor func testThePatternPaneSpeaksItsOwnReadoutAndNeverTheMapsPosition() {
        let state = PatternsRoomState()
        XCTAssertNil(state.patternReadout)
        state.setPatternReadout("x 12, y 40 · 1834")
        XCTAssertEqual(state.readout, "x 12, y 40 · 1834", "the status line reads it as before")
        XCTAssertEqual(state.patternReadout, "x 12, y 40 · 1834")
        state.readout = "row 3 · col 7 · mean 118.3"
        XCTAssertNil(state.patternReadout, "the map's position is not the pattern's readout")
        state.setPatternReadout("x 0, y 0 · 12")
        XCTAssertEqual(state.patternReadout, "x 0, y 0 · 12")
        state.setPatternReadout(nil)
        XCTAssertNil(state.readout)
        XCTAssertNil(state.patternReadout)
    }

    /// The pane takes its value through the modifier, with its title as the fallback, and its hover writes the readout as the pane's
    /// own; no other file writes it. Red under: the static value (VoiceOver heard the title wherever the pointer was), the readout written
    /// unmarked, a second writer.
    func testTheLivePatternPaneAppliesTheModifier() throws {
        let room = try ui("PatternsRoom.swift")
        XCTAssertTrue(room.contains(".modifier(ReadoutAccessibilityValue(readout: { state.patternReadout }, fallback: title))"))
        XCTAssertFalse(room.contains(".accessibilityValue(title)"), "the static value is gone")
        XCTAssertTrue(room.contains("state.setPatternReadout(EBSDBrowsing.patternReadout(x: x, y: y, value: value))"))
        XCTAssertFalse(room.contains("state.readout = EBSDBrowsing.patternReadout"), "the pane's hover marks its readout as its own")
        XCTAssertTrue(room.contains("case .ended: state.setPatternReadout(nil)"))

        let root = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
        var writers: Set<String> = []
        for folder in ["macTEM/UI", "macTEM/App"] {
            let dir = root.appendingPathComponent(folder)
            for file in try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) where file.pathExtension == "swift" {
                let code = try String(contentsOf: file, encoding: .utf8)
                if code.contains(".setPatternReadout(") { writers.insert(file.lastPathComponent) }
            }
        }
        XCTAssertEqual(writers, ["PatternsRoom.swift"])
    }
}
