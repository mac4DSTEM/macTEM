//
//  PaneKeysTests.swift
//  The panes' keys (open-items "Arrows, ⌫ and ⌘C on a pane do nothing"; App/PaneKeys.swift): the router's table, the two
//  rooms' keys on real owners, Edit > Copy / Delete through the SAME path as the key (enabled exactly when the keys act, the
//  same text copied), and the source pins that keep the dead arrangement from coming back (focusable leaves with
//  `on…Command`, which never held focus: archive: pane-keys-gate-d-2026-10-14/). Tier 2: each test names the mutation
//  that turns it red. What no test reaches — that the container receives the keys and that the system's Edit items are
//  validated by its commands in the live window — is open on the drive ("Unverified on screen").
//

import XCTest
import SwiftUI
import TEMCore
import TEMSession
import ImagoCore
@testable import macTEM

nonisolated final class PaneKeysTests: XCTestCase {

    // MARK: Fixtures

    @MainActor private final class Writer: PaneTextWriter {
        var written: [String] = []
        func write(_ text: String) { written.append(text) }
    }

    /// An owner whose lanes answer at once (FFTRoomWiringTests' arrangement): the spectrum is a stand-in and a spot is the
    /// registered estimator's answer on `FFTAnalysisTests.plant`'s region A.
    @MainActor private func owner() -> FFTAnalysis {
        FFTAnalysis(compute: FFTCompute(
            spectrum: { _, key in FFTAnalysisTests.fakeSpectrum(key) },
            spot: { _, _, row, col in
                (try? FFTAnalysisTests.measured(row: row, col: col)).map { .measured($0) } ?? .measuring
            },
            maskedInverse: { _, key in FFTMaskedInverseProduct(key: key, canvas: FFTAnalysisTests.fakeCanvas(), imaginaryMax: 0) },
            filter: { _, key in
                FFTFilterProduct(key: key, absf: FFTAnalysisTests.fakeCanvas(), wiener: FFTAnalysisTests.fakeCanvas(), n: 64,
                                 passes: 3, finalDelta: 4.5)
            }))
    }

    @MainActor private func until(_ what: String, _ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<1000 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("timed out waiting for \(what)")
        throw FFTAnalysisTests.TimedOut()
    }

    /// Region A set, its spectrum shown and one spot measured and SELECTED.
    @MainActor private func ownerWithASelectedSpot() async throws -> FFTAnalysis {
        let analysis = owner()
        analysis.setRegion(FFTAnalysisTests.regionA, committed: true)
        analysis.show(FFTAnalysisTests.plant(), contentVersion: 1)
        try await until("the spectrum") { analysis.isSpectrumCurrent }
        analysis.measureSpot(row: 37, col: 40)
        try await until("the spot") { analysis.hasMeasuredSpot }
        analysis.selection = try XCTUnwrap(analysis.spots.last).id
        return analysis
    }

    @MainActor private func fftKeys(_ analysis: FFTAnalysis, _ pane: FFTKeyPane?, _ writer: Writer = Writer()) -> FFTRoomKeys {
        FFTRoomKeys(analysis: analysis, active: pane, sourceSize: (96, 64), writer: writer)
    }

    @MainActor private func markedImage() -> (ImageMeasurements, ImageMark) {
        let measurements = ImageMeasurements()
        let mark = ImageMark(kind: .distance, points: [ImagePoint(x: 2, y: 3), ImagePoint(x: 12, y: 3)])
        XCTAssertNil(measurements.add(mark, on: FFTAnalysisTests.plant()))
        return (measurements, mark)
    }

    private func text(of providers: [NSItemProvider]) async throws -> String? {
        guard let provider = providers.first else { return nil }
        return try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadObject(ofClass: NSString.self) { object, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: (object as? NSString).map { String($0) }) }
            }
        }
    }

    // MARK: The key

    /// A key press becomes a `PaneKey` by its key and modifiers alone. Red under: ← and → swapped; ⇧ not accepted on an arrow;
    /// the numeric-pad flag (set on every arrow by the system) not ignored; ⌘ or ⌥ accepted on an arrow or on ⌫; plain C
    /// accepted as Copy; ⌘C not accepted; Forward Delete dropped; Escape with a modifier accepted.
    func testAKeyIsReadFromItsKeyAndModifiersAlone() {
        XCTAssertEqual(PaneKey(key: .leftArrow, modifiers: []), .arrow(.left))
        XCTAssertEqual(PaneKey(key: .rightArrow, modifiers: []), .arrow(.right))
        XCTAssertEqual(PaneKey(key: .upArrow, modifiers: []), .arrow(.up))
        XCTAssertEqual(PaneKey(key: .downArrow, modifiers: [.shift]), .arrow(.down))
        XCTAssertEqual(PaneKey(key: .leftArrow, modifiers: [.numericPad]), .arrow(.left), "the system flags every arrow as numeric pad")
        // The raw values a real press carries, measured on a hosted view (refuter, probe1): ← 96 = numeric pad + function,
        // ⇧← 98, Forward Delete 64 = function.
        XCTAssertEqual(PaneKey(key: .leftArrow, modifiers: EventModifiers(rawValue: 96)), .arrow(.left), "a real ←")
        XCTAssertEqual(PaneKey(key: .leftArrow, modifiers: EventModifiers(rawValue: 98)), .arrow(.left), "a real ⇧←")
        XCTAssertEqual(PaneKey(key: .deleteForward, modifiers: EventModifiers(rawValue: 64)), .delete, "a real Forward Delete")
        XCTAssertNil(PaneKey(key: .leftArrow, modifiers: EventModifiers(rawValue: 96).union(.command)), "a real ⌘← is the menu's")
        XCTAssertEqual(PaneKey(key: .rightArrow, modifiers: [.shift, .numericPad, .capsLock]), .arrow(.right))
        XCTAssertNil(PaneKey(key: .leftArrow, modifiers: [.command]))
        XCTAssertNil(PaneKey(key: .upArrow, modifiers: [.option]))
        XCTAssertEqual(PaneKey(key: .delete, modifiers: []), .delete)
        XCTAssertEqual(PaneKey(key: .deleteForward, modifiers: []), .delete)
        XCTAssertNil(PaneKey(key: .delete, modifiers: [.command]), "⌘⌫ is the menu's, not ours")
        XCTAssertEqual(PaneKey(key: .escape, modifiers: []), .escape)
        XCTAssertNil(PaneKey(key: .escape, modifiers: [.shift]))
        XCTAssertEqual(PaneKey(key: KeyEquivalent("c"), modifiers: [.command]), .copy)
        XCTAssertNil(PaneKey(key: KeyEquivalent("c"), modifiers: []), "a plain c is a letter")
        XCTAssertNil(PaneKey(key: KeyEquivalent("c"), modifiers: [.command, .shift]))
        XCTAssertNil(PaneKey(key: KeyEquivalent("x"), modifiers: [.command]))
    }

    // MARK: The routers

    /// The FFT room's table. Red under: a direction swapped; the step ignoring ⇧; the arrows routed on the spectrum pane or with no pane pressed; ⌫ on the
    /// source pane routed to a spot or on the spectrum pane to the region; Copy routed from the source pane or with no spot;
    /// an action with nothing to act on (no region shown, no spot selected); Escape given an action.
    func testTheFFTRoomRoutesEachKeyToTheSelectedPanesAction() {
        func route(_ key: PaneKey, shift: Bool = false, _ pane: FFTKeyPane?, region: Bool = true, spot: Bool = true) -> PaneKeyAction? {
            PaneKeyRouter.fft(key, shift: shift, state: FFTKeyState(active: pane, regionShown: region, spotSelected: spot))
        }
        XCTAssertEqual(route(.arrow(.left), .source), .nudgeRegion(.left, step: 1))
        XCTAssertEqual(route(.arrow(.right), .source), .nudgeRegion(.right, step: 1))
        XCTAssertEqual(route(.arrow(.up), .source), .nudgeRegion(.up, step: 1))
        XCTAssertEqual(route(.arrow(.down), shift: true, .source), .nudgeRegion(.down, step: 10))
        XCTAssertNil(route(.arrow(.left), .spectrum), "the arrows are the source pane's")
        XCTAssertNil(route(.arrow(.left), .source, region: false), "no region shown, nothing to move")
        XCTAssertEqual(route(.delete, .source), .clearRegion)
        XCTAssertEqual(route(.delete, .spectrum), .deleteSpot)
        XCTAssertNil(route(.delete, .source, region: false, spot: true), "the spot is not the source pane's")
        XCTAssertNil(route(.delete, .spectrum, region: true, spot: false), "the region is not the spectrum pane's")
        XCTAssertEqual(route(.copy, .spectrum), .copySpot)
        XCTAssertNil(route(.copy, .source), "nothing on the source pane is copied")
        XCTAssertNil(route(.copy, .spectrum, spot: false))
        XCTAssertNil(route(.escape, .source))
        XCTAssertNil(route(.escape, .spectrum))
        for key in [PaneKey.arrow(.left), .delete, .copy] {
            XCTAssertNil(route(key, nil), "no pane pressed yet: the keys are for neither (\(key))")
        }
    }

    /// A press read to its key and ⇧, and a repeat only for an arrow. Red under: the ⇧ flag dropped (the press wrapper's old
    /// `shift: false`); a repeat of ⌫ or ⌘C read as a key; an arrow's repeat refused.
    func testAPressIsReadToItsKeyShiftAndRepeat() {
        let real = EventModifiers(rawValue: 98)
        let shifted = PaneKey.read(key: .rightArrow, modifiers: real, isRepeat: false)
        XCTAssertEqual(shifted?.key, .arrow(.right))
        XCTAssertEqual(shifted?.shift, true)
        XCTAssertEqual(PaneKey.read(key: .rightArrow, modifiers: EventModifiers(rawValue: 96), isRepeat: false)?.shift, false)
        XCTAssertEqual(PaneKey.read(key: .upArrow, modifiers: EventModifiers(rawValue: 96), isRepeat: true)?.key, .arrow(.up),
                       "a held arrow repeats")
        XCTAssertNil(PaneKey.read(key: .delete, modifiers: [], isRepeat: true), "a held ⌫ fires once")
        XCTAssertNil(PaneKey.read(key: KeyEquivalent("c"), modifiers: .command, isRepeat: true))
        XCTAssertEqual(PaneKey.read(key: .delete, modifiers: [], isRepeat: false)?.key, .delete)
        XCTAssertNil(PaneKey.read(key: .return, modifiers: [], isRepeat: false))
    }

    /// The Image room's table. Red under: Delete or Copy given an action with no mark selected; Escape given one with no angle in
    /// progress, or not given one with an angle; an arrow given an action.
    func testTheImageRoomRoutesDeleteCopyAndEscape() {
        func route(_ key: PaneKey, mark: Bool = true, angle: Bool = false) -> PaneKeyAction? {
            PaneKeyRouter.image(key, state: ImageKeyState(markSelected: mark, angleInProgress: angle))
        }
        XCTAssertEqual(route(.delete), .deleteMark)
        XCTAssertEqual(route(.copy), .copyMark)
        XCTAssertNil(route(.delete, mark: false))
        XCTAssertNil(route(.copy, mark: false))
        XCTAssertEqual(route(.escape, mark: false, angle: true), .cancelAngle)
        XCTAssertNil(route(.escape, mark: true, angle: false), "Escape drops an angle in progress; it deselects nothing")
        XCTAssertNil(route(.arrow(.left)))
    }

    // MARK: The FFT room's keys on a real owner

    /// An arrow moves the region (⇧ ten pixels, held inside the file) and ⌫ clears it, committed. Red under: the nudge writing
    /// uncommitted; the step 1 with ⇧; the file's size not passed (the nudge held inside 0 × 0); ⌫ on the source pane not clearing.
    @MainActor func testTheArrowsNudgeTheRegionAndDeleteClearsIt() throws {
        let analysis = owner()
        analysis.setRegion(FFTAnalysisTests.regionA, committed: true)   // row 0, col 16, 64 × 64 in a 96 × 64 file
        let keys = fftKeys(analysis, .source)
        XCTAssertTrue(keys.handle(.arrow(.right)))
        XCTAssertEqual(analysis.region?.col, 17)
        XCTAssertTrue(keys.handle(.arrow(.right), shift: true))
        XCTAssertEqual(analysis.region?.col, 27)
        XCTAssertTrue(keys.handle(.arrow(.right), shift: true))
        XCTAssertEqual(analysis.region?.col, 32, "held inside the 96 px file")
        XCTAssertTrue(keys.handle(.arrow(.left)))
        XCTAssertEqual(analysis.region?.col, 31)
        XCTAssertEqual(analysis.region?.row, 0)
        XCTAssertFalse(fftKeys(analysis, .spectrum).handle(.arrow(.left)), "the other pane is not ours")
        XCTAssertEqual(analysis.region?.col, 31)
        XCTAssertTrue(keys.handle(.delete))
        XCTAssertNil(analysis.region)
        XCTAssertFalse(keys.handle(.delete), "nothing left to clear")
    }

    /// The press path end to end on a real owner (the parts a `KeyPress` is made of): a real ⇧→ moves ten pixels, a repeat of →
    /// moves one more, a repeat of ⌫ does nothing, and an unrecognised key is ignored. Red under: the press wrapper's shift
    /// dropped; repeats of ⌫ routed.
    @MainActor func testTheRealPressMovesTheRegionAndARepeatedDeleteDoesNothing() {
        let analysis = owner()
        analysis.setRegion(FFTAnalysisTests.regionA, committed: true)
        let keys = fftKeys(analysis, .source)
        XCTAssertEqual(keys.handle(key: .rightArrow, modifiers: EventModifiers(rawValue: 98)), .handled)
        XCTAssertEqual(analysis.region?.col, 26, "⇧ → is ten pixels")
        XCTAssertEqual(keys.handle(key: .rightArrow, modifiers: EventModifiers(rawValue: 96), isRepeat: true), .handled)
        XCTAssertEqual(analysis.region?.col, 27, "a held arrow repeats")
        XCTAssertEqual(keys.handle(key: .delete, modifiers: [], isRepeat: true), .ignored)
        XCTAssertNotNil(analysis.region, "a held ⌫ does not clear")
        XCTAssertEqual(keys.handle(key: .return, modifiers: []), .ignored)
        XCTAssertEqual(keys.handle(key: .delete, modifiers: []), .handled)
        XCTAssertNil(analysis.region)
        XCTAssertEqual(fftKeys(analysis, nil).handle(key: .leftArrow, modifiers: EventModifiers(rawValue: 96)), .ignored)
    }

    /// A nudge is a COMMITTED region: the spots measured on the old one go (`FFTAnalysis.setRegion`), as for a typed field. Red
    /// under: `committed: false` in the nudge (the spots stay, on a region they were not measured for).
    @MainActor func testANudgeCommitsSoTheSpotsOfTheOldRegionGo() async throws {
        let analysis = try await ownerWithASelectedSpot()
        XCTAssertFalse(analysis.spots.isEmpty)
        XCTAssertTrue(fftKeys(analysis, .source).handle(.arrow(.left)))
        XCTAssertEqual(analysis.region?.col, 15)
        XCTAssertTrue(analysis.spots.isEmpty, "the spots of the old region are dropped")
    }

    /// A spot is only the keys' while a spectrum is shown without failure. Red under: `spotSelected` without the spectrum-present
    /// guard (released, or a failed ask: the owner drops the spectrum then, so the failure guard alone is not separately observable).
    @MainActor func testASpotIsNotKeyedWithoutAShownSpectrum() async throws {
        let analysis = try await ownerWithASelectedSpot()
        XCTAssertTrue(fftKeys(analysis, .spectrum).canDelete)
        analysis.release()
        XCTAssertNotNil(analysis.selection)
        XCTAssertFalse(fftKeys(analysis, .spectrum).canDelete, "released: no spectrum")
        XCTAssertFalse(fftKeys(analysis, .spectrum).canCopy)
        XCTAssertFalse(fftKeys(analysis, .spectrum).handle(.delete))
        XCTAssertFalse(analysis.spots.isEmpty)

        let failing = FailureSwitch()
        let flaky = FFTAnalysis(compute: FFTCompute(
            spectrum: { _, key in
                if failing.on { throw FFTAnalysisTests.TimedOut() }
                return FFTAnalysisTests.fakeSpectrum(key)
            },
            spot: { _, _, row, col in
                (try? FFTAnalysisTests.measured(row: row, col: col)).map { .measured($0) } ?? .measuring
            },
            maskedInverse: { _, key in FFTMaskedInverseProduct(key: key, canvas: FFTAnalysisTests.fakeCanvas(), imaginaryMax: 0) },
            filter: { _, key in
                FFTFilterProduct(key: key, absf: FFTAnalysisTests.fakeCanvas(), wiener: FFTAnalysisTests.fakeCanvas(), n: 64,
                                 passes: 3, finalDelta: 4.5)
            }))
        flaky.setRegion(FFTAnalysisTests.regionA, committed: true)
        flaky.show(FFTAnalysisTests.plant(), contentVersion: 1)
        try await until("the spectrum") { flaky.isSpectrumCurrent }
        flaky.measureSpot(row: 37, col: 40)
        try await until("the spot") { flaky.hasMeasuredSpot }
        XCTAssertTrue(fftKeys(flaky, .spectrum).canDelete)
        failing.on = true
        flaky.setRegion(FFTAnalysisTests.regionB, committed: false)   // another spectrum is asked for, and fails
        try await until("the failure") { flaky.spectrumFailure != nil }
        XCTAssertNil(flaky.spectrum, "a failed ask drops the spectrum (so the no-failure guard is belt and braces)")
        XCTAssertFalse(fftKeys(flaky, .spectrum).canDelete, "a failed ask: nothing is keyed")
        XCTAssertFalse(fftKeys(flaky, .spectrum).canCopy)
    }

    private nonisolated final class FailureSwitch: @unchecked Sendable { nonisolated(unsafe) var on = false }

    /// The region is only the source pane's while the file is what it shows. Red under: `regionShown` ignoring the View.
    @MainActor func testAHiddenRegionIsNotMovedOrCleared() async throws {
        let analysis = owner()
        analysis.setRegion(FFTAnalysisTests.regionA, committed: true)
        analysis.show(FFTAnalysisTests.plant(), contentVersion: 1)
        try await until("the spectrum") { analysis.isSpectrumCurrent }
        analysis.setSourceView(.region)
        let keys = fftKeys(analysis, .source)
        XCTAssertFalse(keys.handle(.arrow(.right)))
        XCTAssertFalse(keys.handle(.delete))
        XCTAssertEqual(analysis.region, FFTAnalysisTests.regionA)
    }

    /// ⌫ deletes the selected spot from the spectrum pane and ⌘C copies its line through the writer. Red under: ⌫ on the spectrum
    /// pane clearing the region; the copy writing nothing, or another line than the pane's (`FFTPaneFormat.copyLine`).
    @MainActor func testDeleteAndCopyActOnTheSelectedSpot() async throws {
        let analysis = try await ownerWithASelectedSpot()
        let writer = Writer()
        let keys = fftKeys(analysis, .spectrum, writer)
        let spot = try XCTUnwrap(analysis.spots.last)
        let spectrum = try XCTUnwrap(analysis.spectrum)
        let expected = FFTPaneFormat.copyLine(spot, subject: FFTPaneFormat.subject(crop: spectrum.key.crop, width: spectrum.width,
                                                                                    height: spectrum.height))
        XCTAssertTrue(keys.handle(.copy))
        XCTAssertEqual(writer.written, [expected])
        XCTAssertFalse(fftKeys(analysis, .source, writer).handle(.copy), "the source pane copies nothing")
        XCTAssertEqual(writer.written.count, 1)
        XCTAssertTrue(keys.handle(.delete))
        XCTAssertTrue(analysis.spots.isEmpty)
        XCTAssertEqual(analysis.region, FFTAnalysisTests.regionA, "the region is untouched by a spot's delete")
        XCTAssertFalse(keys.handle(.delete), "no spot selected any more")
    }

    /// Edit > Copy and Delete are enabled exactly when the keys act, and they do what the keys do: the menu's copy hands over the
    /// line the key writes, and its delete is the key's `handle`. Red under: Copy enabled with nothing selected (or on the
    /// source pane); Delete enabled on the wrong pane; the menu's text another than the key's.
    @MainActor func testEditCopyAndDeleteAreTheKeysPath() async throws {
        let analysis = try await ownerWithASelectedSpot()
        let writer = Writer()
        let spectrumKeys = fftKeys(analysis, .spectrum, writer)
        let sourceKeys = fftKeys(analysis, .source, writer)
        XCTAssertTrue(spectrumKeys.canCopy)
        XCTAssertTrue(spectrumKeys.canDelete)
        XCTAssertFalse(sourceKeys.canCopy, "Copy is grey with the source pane pressed last")
        XCTAssertTrue(sourceKeys.canDelete, "the region exists, so Delete clears it")
        let menuText = try await text(of: spectrumKeys.copyProviders())
        _ = spectrumKeys.handle(.copy)
        XCTAssertEqual(menuText, writer.written.first, "Edit > Copy and ⌘C copy the same line")
        XCTAssertNotNil(menuText)
        XCTAssertTrue(sourceKeys.copyProviders().isEmpty, "a disabled Copy hands over nothing")
        analysis.selection = nil
        XCTAssertFalse(fftKeys(analysis, .spectrum).canCopy, "nothing selected")
        XCTAssertFalse(fftKeys(analysis, .spectrum).canDelete)
        XCTAssertTrue(fftKeys(analysis, .spectrum).copyProviders().isEmpty)
        analysis.setRegion(nil, committed: true)
        XCTAssertFalse(fftKeys(analysis, .source).canDelete, "no region")
    }

    // MARK: The Image room's keys on a real owner

    /// ⌫ removes the selected mark, ⌘C writes its value, Escape drops the angle in progress; the Edit items follow the same
    /// router. Red under: Delete not removing; the copy writing another text than the label; Escape not calling the cancel;
    /// Copy enabled with no mark.
    @MainActor func testTheImageRoomKeysActOnTheSelectedMarkAndTheAngle() async throws {
        let (measurements, mark) = markedImage()
        let writer = Writer()
        var cancelled = 0
        func keys(angle: Bool = false) -> ImageRoomKeys {
            ImageRoomKeys(measurements: measurements, label: { _ in "12.43 nm" }, angleInProgress: angle,
                          cancelAngle: { cancelled += 1 }, writer: writer)
        }
        measurements.selection = nil   // adding a mark selects it
        XCTAssertFalse(keys().canCopy, "no mark selected: Copy is grey")
        XCTAssertFalse(keys().canDelete)
        XCTAssertTrue(keys().copyProviders().isEmpty)
        XCTAssertFalse(keys().handle(.delete))
        measurements.selection = mark.id
        XCTAssertTrue(keys().canCopy)
        XCTAssertTrue(keys().canDelete)
        let menuText = try await text(of: keys().copyProviders())
        XCTAssertTrue(keys().handle(.copy))
        XCTAssertEqual(writer.written, ["12.43 nm"])
        XCTAssertEqual(menuText, "12.43 nm", "Edit > Copy and ⌘C copy the same value")
        XCTAssertFalse(keys().handle(.escape), "no angle in progress: Escape goes on")
        XCTAssertEqual(cancelled, 0)
        XCTAssertTrue(keys(angle: true).handle(.escape))
        XCTAssertEqual(cancelled, 1)
        XCTAssertTrue(keys().handle(.delete))
        XCTAssertNil(measurements.mark(mark.id))
        XCTAssertFalse(keys().canCopy, "the mark is gone")
    }

    // MARK: The source pins

    /// The file's code with every `//` comment removed (a whole-line comment and a trailing one): a comment may name what the
    /// code replaced.
    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
        return text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            guard let comment = line.range(of: "//") else { return String(line) }
            return String(line[..<comment.lowerBound])
        }.joined(separator: "\n")
    }

    /// The part of `text` from `start` up to (not including) `end`, or to the end.
    private func slice(_ text: String, from start: String, to end: String? = nil) throws -> String {
        let begin = try XCTUnwrap(text.range(of: start), "\(start) is not in the file")
        let stop = end.flatMap { text.range(of: $0, range: begin.upperBound..<text.endIndex)?.lowerBound } ?? text.endIndex
        return String(text[begin.lowerBound..<stop])
    }

    /// The comment stripper strips (so the pins below are not tripped by a comment) and keeps the code.
    func testThePinsReadCodeNotComments() throws {
        let code = try source("macTEM/UI/FFTSourceImagePane.swift")
        XCTAssertTrue(code.contains("struct FFTRegionOverlay: View"), "the code is kept")
        XCTAssertFalse(code.contains("THE REGION'S GESTURES"), "the header comment is gone")
        XCTAssertGreaterThan(code.count, 5000, "the pin reads a real file")
    }

    /// The panes hold no focus of their own: Gate D showed focusable leaves never receive it, so a leaf with `on…Command` is a key
    /// that does nothing. Red under: any of these back in a pane's file.
    func testThePanesHoldNoFocusAndNoKeyCommands() throws {
        for path in ["macTEM/UI/FFTRoom.swift", "macTEM/UI/FFTSourceImagePane.swift", "macTEM/UI/FFTSpectrumImagePane.swift",
                     "macTEM/UI/ImagePane.swift", "macTEM/UI/ImageRoomMarks.swift"] {
            let code = try source(path)
            XCTAssertGreaterThan(code.count, 1000, "\(path) read as empty: the pin would be vacuous")
            for banned in [".focusable(", "@FocusState", ".focused(", ".onMoveCommand", ".onDeleteCommand", ".onCopyCommand",
                           ".onExitCommand", ".onKeyPress"] {
                XCTAssertFalse(code.contains(banned), "\(path) still has \(banned)")
            }
        }
    }

    /// Each room's root carries its keyed container, each container is E2's arrangement with the two Edit commands (the FFT one
    /// repeating for a held arrow, the Image one not), the press wrappers are one-liners over the pure reading, and each FFT
    /// pane says on ANY press that the keys are its. Red under: a room root without its modifier; a container without
    /// `.focusable()`, `.focusEffectDisabled()` or its `.onKeyPress`; a command not optional (always enabled); a press
    /// wrapper that passes other modifiers or phase; a pane without the press modifier (the keys stay with the other pane).
    func testEachRoomRootCarriesTheKeyedContainerAndEachPaneSaysItWasPressed() throws {
        XCTAssertTrue(try source("macTEM/UI/FFTRoom.swift").contains(".modifier(FFTKeyedRoom(analysis: item.fft"))
        XCTAssertTrue(try source("macTEM/UI/ImagePane.swift").contains(".modifier(ImageKeyedRoom(image: image"))
        let keys = try source("macTEM/App/PaneKeys.swift")
        let fft = try slice(keys, from: "struct FFTKeyedRoom: ViewModifier", to: "struct FFTPanePress")
        let image = try slice(keys, from: "struct ImageKeyedRoom: ViewModifier")
        let common = [".focusable()", ".focusEffectDisabled()",
                      ".onCopyCommand(perform: keys.canCopy ? { keys.copyProviders() } : nil)",
                      ".onDeleteCommand(perform: keys.canDelete ? { _ = keys.handle(.delete) } : nil)"]
        for part in common + [".onKeyPress(phases: [.down, .repeat]) { keys.handle($0) }"] {
            XCTAssertEqual(fft.components(separatedBy: part).count - 1, 1, "the FFT container carries \(part)")
        }
        for part in common + [".onKeyPress(phases: .down) { keys.handle($0) }"] {
            XCTAssertEqual(image.components(separatedBy: part).count - 1, 1, "the Image container carries \(part)")
        }
        XCTAssertTrue(keys.contains("handle(key: press.key, modifiers: press.modifiers, isRepeat: press.phase == .repeat)"),
                      "the FFT press wrapper hands the press over whole")
        XCTAssertTrue(keys.contains("handle(key: press.key, modifiers: press.modifiers)\n"), "and the Image one")
        let press = try slice(keys, from: "struct FFTPanePress: ViewModifier", to: "// MARK: - The Image room")
        XCTAssertTrue(press.contains(".simultaneousGesture(DragGesture(minimumDistance: 0).onChanged"), "any press, simultaneously")
        XCTAssertTrue(press.contains("if keyPane != pane { keyPane = pane }"))
        XCTAssertTrue(try source("macTEM/UI/FFTSourceImagePane.swift").contains(".modifier(FFTPanePress(pane: .source, keyPane: $keyPane))"))
        XCTAssertTrue(try source("macTEM/UI/FFTSpectrumImagePane.swift").contains(".modifier(FFTPanePress(pane: .spectrum, keyPane: $keyPane))"))
    }
}
