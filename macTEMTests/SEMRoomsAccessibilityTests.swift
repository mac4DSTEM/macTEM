//
//  SEMRoomsAccessibilityTests.swift
//  What VoiceOver hears in the SEM rooms beside what they draw: the opening bars of the Patterns, Indexing and Maps rooms say what
//  opens (#297), as the EELS room's does; the live pattern pane's value is the detector pixel under the pointer while it is over the
//  pattern, else which pattern it shows (#345), as the EELS spectrum's is, and that pixel is read again when the pattern under a
//  resting pointer changes. Red before: the bars had no label (VoiceOver found an unnamed busy indicator), the pattern pane's value was
//  its title wherever the pointer was, and an arrow step under a resting pointer left the last pattern's value in the status line and
//  the pane's value.
//

import XCTest
import TEMSession
@testable import macTEM

nonisolated final class SEMRoomsAccessibilityTests: XCTestCase {

    private func ui(_ name: String) throws -> String { try FFTRoomWiringTests.squeezedUI(name) }

    /// A 3 × 2 pattern of counts 0, 10, …, 50, and the same pixels on a pattern ten times as bright: one normalised copy, so only the
    /// raw range tells them apart.
    private static let dim = CanvasPixels.make(width: 3, height: 2, pixels: [0, 10, 20, 30, 40, 50])
    private static let bright = CanvasPixels.make(width: 3, height: 2, pixels: [0, 100, 200, 300, 400, 500])

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

    /// The pattern pane's readout is the detector pixel under the pointer and its stored count, the status line's words, while the pane
    /// wrote them; nothing once the scan map writes its position there, off the pattern, on a pattern with no finite value, or once the
    /// pointer leaves. Red under: the pane speaking the map's "row 3 · col 7 · mean 118.3" as its own value, a count read off the
    /// normalised copy.
    @MainActor func testThePatternPaneSpeaksItsOwnReadoutAndNeverTheMapsPosition() {
        let state = PatternsRoomState()
        XCTAssertNil(state.patternReadout)
        state.hoverPattern(SIMD2(1, 1), on: Self.dim)
        XCTAssertEqual(state.readout, "x 1, y 1 · 40", "the status line reads it as before")
        XCTAssertEqual(state.patternReadout, "x 1, y 1 · 40")
        state.readout = "row 3 · col 7 · mean 118.3"
        XCTAssertNil(state.patternReadout, "the map's position is not the pattern's readout")
        state.hoverPattern(SIMD2(0, 0), on: Self.dim)
        XCTAssertEqual(state.patternReadout, "x 0, y 0 · 0")
        for outside in [SIMD2(3, 0), SIMD2(0, 2), SIMD2(-1, 0)] {
            state.hoverPattern(outside, on: Self.dim)
            XCTAssertNil(state.readout, "\(outside) is off the pattern")
        }
        state.hoverPattern(SIMD2(0, 0), on: CanvasPixels.make(width: 1, height: 1, pixels: [.nan]))
        XCTAssertNil(state.readout, "a pattern with no finite value reads nothing")
        state.hoverPattern(SIMD2(2, 1), on: Self.dim)
        XCTAssertEqual(state.readout, "x 2, y 1 · 50")
        state.hoverPattern(nil, on: Self.dim)
        XCTAssertNil(state.readout)
        XCTAssertNil(state.patternReadout)
    }

    /// Another pattern under a resting pointer (an arrow step, Raw or Processed) reads the same pixel again, so the status line and
    /// VoiceOver name the pattern shown; a pointer off the pattern reads nothing, the scan map's readout stays, and the pane going takes
    /// its own readout and the pixel with it. Red before: no `rereadPattern` (the last pattern's "x 1, y 1 · 40" stayed after the step).
    @MainActor func testThePatternReadoutGoesWithThePatternItNames() {
        let state = PatternsRoomState()
        state.hoverPattern(SIMD2(1, 1), on: Self.dim)
        state.rereadPattern(on: Self.bright)
        XCTAssertEqual(state.readout, "x 1, y 1 · 400", "the pixel read again on the pattern shown")
        XCTAssertEqual(state.patternReadout, "x 1, y 1 · 400")
        state.rereadPattern(on: nil)
        XCTAssertNil(state.readout, "no pattern: nothing to read")
        state.rereadPattern(on: Self.dim)
        XCTAssertEqual(state.readout, "x 1, y 1 · 40", "the pointer still rests on the pixel")

        state.hoverPattern(nil, on: Self.dim)
        state.rereadPattern(on: Self.bright)
        XCTAssertNil(state.readout, "a pointer off the pattern reads nothing")

        state.hoverPattern(SIMD2(2, 0), on: Self.dim)
        state.readout = "row 3 · col 7 · mean 118.3"
        state.rereadPattern(on: Self.bright)
        XCTAssertEqual(state.readout, "row 3 · col 7 · mean 118.3", "the scan map's readout stays")
        state.patternPaneLeft()
        XCTAssertEqual(state.readout, "row 3 · col 7 · mean 118.3", "the pane going leaves the map's readout")

        state.hoverPattern(SIMD2(0, 1), on: Self.dim)
        XCTAssertEqual(state.readout, "x 0, y 1 · 30")
        state.patternPaneLeft()
        XCTAssertNil(state.readout, "the pane going takes its readout")
        XCTAssertNil(state.patternReadout)
        state.rereadPattern(on: Self.bright)
        XCTAssertNil(state.readout, "and forgets the pixel")
    }

    /// The pane takes its value through the modifier, with its title as the fallback; its hover hands the pixel under the pointer to
    /// the state, which marks the readout as the pane's own; a change of the pattern (its pixels or its raw range) reads the pixel again,
    /// and the pane going clears it; no other file writes it. Red under: the static value (VoiceOver heard the title wherever the pointer
    /// was), the readout written unmarked, no re-read on a new pattern, a second writer.
    func testTheLivePatternPaneAppliesTheModifier() throws {
        let room = try ui("PatternsRoom.swift")
        XCTAssertTrue(room.contains(".modifier(ReadoutAccessibilityValue(readout: { state.patternReadout }, fallback: title))"))
        XCTAssertFalse(room.contains(".accessibilityValue(title)"), "the static value is gone")
        XCTAssertTrue(room.contains("state.hoverPattern(SIMD2(Int(q.x.rounded()), Int(q.y.rounded())), on: canvas)"))
        XCTAssertFalse(room.contains("state.readout = EBSDBrowsing.patternReadout"), "the pane's hover marks its readout as its own")
        XCTAssertTrue(room.contains("case .ended: state.hoverPattern(nil, on: canvas)"))
        XCTAssertTrue(room.contains(".modifier(RereadsThePatternPixel(presentation: session.patternPresentation, state: state))"))
        XCTAssertTrue(room.contains(".onChange(of: Shown(version: presentation.canvas?.contentVersion, range: presentation.canvas?.rawRange)) {"
                                    + " state.rereadPattern(on: presentation.canvas) }"))
        XCTAssertTrue(room.contains(".onDisappear { state.patternPaneLeft() }"))
        XCTAssertEqual(Self.dim.contentVersion, Self.bright.contentVersion, "the raw range is what tells these two patterns apart")

        let root = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
        var writers: Set<String> = []
        for folder in ["macTEM/UI", "macTEM/App"] {
            let dir = root.appendingPathComponent(folder)
            for file in try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) where file.pathExtension == "swift" {
                let code = try String(contentsOf: file, encoding: .utf8)
                if code.contains(".hoverPattern(") || code.contains(".rereadPattern(") || code.contains(".patternPaneLeft(") {
                    writers.insert(file.lastPathComponent)
                }
            }
        }
        XCTAssertEqual(writers, ["PatternsRoom.swift"])
    }
}
