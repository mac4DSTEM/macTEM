//
//  EELSAlignOptionsTests.swift
//  Align's Signal range and Crop as real controls (SpectroKit `ZeroLossAlignmentOptions.signalRangeEV` and `.crop`).
//
//  THE TRUTH: the kit's own `EELSAlignment.alignZeroLossPeak` called directly on the planted cubes. At the defaults (±5 eV about 0, cut to the axis; Crop on)
//  the room's alignment is the one it made before the controls existed, value for value; with other options it is the kit's with those options.
//

import XCTest
import AppKit
import SwiftUI
import SpectroEELS
import TEMCore
import TEMSession
@testable import macTEM

nonisolated final class EELSAlignOptionsTests: XCTestCase {

    /// The options the room passed before this change, written out as they were: the window ±5 eV cut to the axis, the kit's defaults otherwise.
    private static func todaysOptions(_ low: LowLossSpectrumImage) -> ZeroLossAlignmentOptions {
        let axisHigh = low.energyOffsetEV + low.energyScaleEV * Double(low.channels - 1)
        var options = ZeroLossAlignmentOptions()
        let lo = max(low.energyOffsetEV, -5), hi = min(axisHigh, 5)
        if lo < hi { options.signalRangeEV = lo...hi }
        return options
    }

    private func assertSame(_ a: ZeroLossAlignment, _ b: ZeroLossAlignment, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.aligned.counts, b.aligned.counts, what, file: file, line: line)
        XCTAssertEqual(a.aligned.channels, b.aligned.channels, what, file: file, line: line)
        XCTAssertEqual(a.aligned.energyOffsetEV, b.aligned.energyOffsetEV, what, file: file, line: line)
        XCTAssertEqual(a.shiftEV, b.shiftEV, what, file: file, line: line)
        XCTAssertEqual(a.initialCentreEV, b.initialCentreEV, what, file: file, line: line)
        XCTAssertEqual(a.keptChannels, b.keptChannels, what, file: file, line: line)
        XCTAssertEqual(a.alsoAligned.map(\.counts), b.alsoAligned.map(\.counts), what, file: file, line: line)
        XCTAssertEqual(a.alsoAligned.map(\.energyOffsetEV), b.alsoAligned.map(\.energyOffsetEV), what, file: file, line: line)
    }

    /// The default choice gives the kit what the room gave it before: ±5 eV cut to the axis, Crop on. A window that misses the axis leaves the kit's whole axis.
    /// Red under: no `EELSAlignChoice`.
    func testTheDefaultChoiceIsTodaysOptions() throws {
        let choice = EELSAlignChoice()
        XCTAssertEqual(choice.signalRangeEV, -5...5)
        XCTAssertTrue(choice.crop)
        let shifted = try EELSOpeningTests.shiftedImage()
        XCTAssertEqual(choice.kitOptions(for: shifted), Self.todaysOptions(shifted))
        XCTAssertEqual(choice.kitOptions(axisLowEV: -2, axisHighEV: 100).signalRangeEV, -2...5, "cut to the axis")
        XCTAssertNil(choice.kitOptions(axisLowEV: 10, axisHighEV: 100).signalRangeEV, "a window off the axis: the whole axis, as before")
        let other = EELSAlignChoice(signalRangeEV: -2...3, crop: false).kitOptions(axisLowEV: -5, axisHighEV: 100)
        XCTAssertEqual(other.signalRangeEV, -2...3)
        XCTAssertFalse(other.crop)
        XCTAssertEqual(other.calibrate, ZeroLossAlignmentOptions().calibrate)
        XCTAssertEqual(other.subpixel, ZeroLossAlignmentOptions().subpixel)
        XCTAssertEqual(other.interpolationPoints, ZeroLossAlignmentOptions().interpolationPoints)
    }

    /// At the defaults the room's alignment equals the kit's with today's options, value for value: the low loss and the core loss aligned with it, on both
    /// planted files. No number moves.
    @MainActor func testAtTheDefaultsNoNumberMoves() async throws {
        for loaded in [LoadedEELS(fileName: "shifted.dm4", image: try EELSOpeningTests.shiftedImage(), beamEnergyKeV: nil, convergenceMrad: 0, collectionMrad: 10,
                                  origin: "planted"),
                       try EELSRoomStatesTests.loaded(single: false)] {
            let session = EELSSession()
            await session.bind(loaded).value
            await session.settled()
            await session.align()?.value
            let room = try XCTUnwrap(session.alignment, session.failure ?? "no alignment")
            let kit = try EELSAlignment.alignZeroLossPeak(loaded.image, alsoAlign: loaded.coreLoss.map { [$0] } ?? [], options: Self.todaysOptions(loaded.image))
            assertSame(room, kit, loaded.fileName)
            XCTAssertEqual(session.alignState, .current)
        }
    }

    /// Other options reach the kit: a narrower window and Crop off give the kit's alignment with those options (Crop off keeps every channel). A change of
    /// option stales Align (and the Processing title) until it runs again. Red under: the controls change nothing.
    @MainActor func testTheOptionsReachTheKitAndStaleAlign() async throws {
        let loaded = try EELSRoomStatesTests.loaded(single: false)
        let session = EELSSession()
        await session.bind(loaded).value
        await session.settled()
        await session.align()?.value
        XCTAssertEqual(session.alignState, .current)

        session.setAlignSignalRange(fromEV: -2, toEV: 3)
        XCTAssertEqual(session.alignState, .stale, "the alignment on screen was made with the old window")
        XCTAssertEqual(session.processingState, .stale)
        session.setAlignCrop(false)
        await session.align()?.value
        XCTAssertEqual(session.alignState, .current)
        let room = try XCTUnwrap(session.alignment, session.failure ?? "no alignment")
        var options = ZeroLossAlignmentOptions(); options.signalRangeEV = -2...3; options.crop = false
        let kit = try EELSAlignment.alignZeroLossPeak(loaded.image, alsoAlign: loaded.coreLoss.map { [$0] } ?? [], options: options)
        assertSame(room, kit, "-2…3 eV, no crop")
        XCTAssertEqual(room.aligned.channels, loaded.image.channels, "Crop off keeps the size")

        session.setAlignCrop(true)
        XCTAssertEqual(session.alignState, .stale)
        session.setAlignSignalRange(fromEV: -5, toEV: 5)
        XCTAssertEqual(session.alignState, .stale, "the window is back, Crop still differs from the run")
        session.setAlignCrop(false)
        session.setAlignSignalRange(fromEV: -2, toEV: 3)
        XCTAssertEqual(session.alignState, .current, "back to the options it ran with")

        // The shifted file (pixels 0, 0.5 and 1 eV off): the options change the numbers, and the room's are the kit's.
        let shifted = LoadedEELS(fileName: "shifted.dm4", image: try EELSOpeningTests.shiftedImage(), beamEnergyKeV: nil, convergenceMrad: 0, collectionMrad: 10,
                                 origin: "planted")
        let other = EELSSession()
        await other.bind(shifted).value
        await other.settled()
        other.setAlignSignalRange(fromEV: -2, toEV: 3)
        other.setAlignCrop(false)
        await other.align()?.value
        let moved = try XCTUnwrap(other.alignment, other.failure ?? "no alignment")
        assertSame(moved, try EELSAlignment.alignZeroLossPeak(shifted.image, options: options), "shifted, -2…3 eV, no crop")
        XCTAssertEqual(moved.aligned.channels, shifted.image.channels)
        let atDefaults = try EELSAlignment.alignZeroLossPeak(shifted.image, options: Self.todaysOptions(shifted.image))
        XCTAssertLessThan(atDefaults.aligned.channels, shifted.image.channels, "the default crops this file")
    }

    /// A window that does not start below its end is refused with a sentence and changes nothing; a good one clears the sentence. A new file starts at the
    /// defaults. Red under: an empty window passed on to the kit.
    @MainActor func testAnEmptyWindowIsRefused() async throws {
        let session = EELSSession()
        await session.bind(try EELSRoomStatesTests.loaded(single: false)).value
        await session.settled()
        session.setAlignSignalRange(fromEV: 3, toEV: 3)
        XCTAssertEqual(session.alignChoice, EELSAlignChoice())
        XCTAssertEqual(session.alignNotice, "The signal range must start below its end; it is still \(EELSRoomFormat.eV(-5)) to \(EELSRoomFormat.eV(5)) eV.")
        session.setAlignSignalRange(fromEV: -3, toEV: 4)
        XCTAssertNil(session.alignNotice)
        XCTAssertEqual(session.alignChoice.signalRangeEV, -3...4)
        session.setAlignCrop(false)
        await session.bind(try EELSRoomStatesTests.loaded(single: false)).value
        XCTAssertEqual(session.alignChoice, EELSAlignChoice(), "a new file starts at the defaults")
    }

    /// The Processing section with its Signal range fields and Crop switch, after an Align whose options were then changed (Align stale), rendered offscreen.
    /// Writes `macTEM-98c1.png` when MACEM_SHOT_DIR is set; otherwise only checks that it renders.
    @MainActor func testTheProcessingSectionRendersOffscreen() async throws {
        let session = EELSSession()
        await session.bind(try EELSRoomStatesTests.loaded(single: false)).value
        await session.settled()
        await session.align()?.value
        session.setAlignSignalRange(fromEV: -2, toEV: 3)
        let canvas = NSSize(width: 320, height: 520)
        let view = ScrollView { EELSProcessingSection(session: session).padding(.horizontal, 12) }
            .frame(width: canvas.width, height: canvas.height).background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .light)
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: canvas), styleMask: [.borderless], backing: .buffered, defer: true)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: canvas)
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        XCTAssertGreaterThan(rep.pixelsWide, 0)
        guard let dir = ProcessInfo.processInfo.environment["MACEM_SHOT_DIR"] else { return }
        let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("macTEM-98c1.png"))
    }
}
