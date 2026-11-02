//
//  EELSKeyboardCursorTests.swift
//  The EELS room's keyboard and cursor, as the EDS room's: Return draws the chosen tool's shape in the middle of the scan and the arrows move the selected
//  region (`EDXRegionBridge.drawByKeyboard`, `nudgeSelected`); ⌥ while hovering a map draws that pixel's low loss and core loss as a temporary layer on the
//  plot (control placement §7); the line profile's axis is in the scan's pixel unit and its value axis is named after the maps it reads.
//
//  THE TRUTH: the planted 4 x 3 low loss of `EELSRoomTests` and the core loss of `EELSControlsTests` (every pixel a known spectrum). A pixel's layer is
//  the stored counts of that pixel, value for value; a region drawn by Return is the middle half of the scan.
//

import XCTest
import AppKit
import SwiftUI
import ShellSpectroscopy
import SpectroCore
import SpectroEDX
import SpectroEELS
import TEMCore
import TEMSession
import ShellEDXModel
@testable import macTEM

nonisolated final class EELSKeyboardCursorTests: XCTestCase {

    @MainActor private func room(scanPixel: (Double, String)? = nil) async throws -> EELSSession {
        let loaded = LoadedEELS(fileName: "keys.dm4", image: try EELSRoomTests.image(), beamEnergyKeV: 200, convergenceMrad: 0, collectionMrad: 10,
                                origin: "planted", coreLoss: try EELSControlsTests.core(), coreLossOrigin: "planted core",
                                scanPixelSize: scanPixel?.0, scanPixelUnit: scanPixel?.1)
        let session = EELSSession()
        await session.bind(loaded).value
        session.setThreshold(.fixed(2.5))
        await session.settled()
        return session
    }

    // MARK: Regions by keyboard

    /// Return with a shape tool draws it in the middle half of the 4 x 3 scan, kept and selected as a drawn region; the arrow tool leaves the key alone.
    /// Red under: Return draws nothing; the line tool draws a region; the arrow tool draws.
    @MainActor func testReturnDrawsTheChosenToolsShapeInTheMiddle() async throws {
        let session = try await room()
        let state = EELSRoomState()
        state.tool = .pointer
        XCTAssertFalse(EELSRegionBridge.drawByKeyboard(in: session, state: state), "the arrow tool leaves Return alone")
        XCTAssertTrue(session.pins.isEmpty)

        state.tool = .rectangle
        XCTAssertTrue(EELSRegionBridge.drawByKeyboard(in: session, state: state))
        XCTAssertEqual(session.pins.map(\.region), [.rectangle(PixelRect(x0: 1, y0: 1, x1: 3, y1: 2))])
        XCTAssertEqual(session.selectedPinID, session.pins.first?.id, "a drawn region selects itself")
        XCTAssertFalse(state.linesFocused)

        state.tool = .ellipse
        XCTAssertTrue(EELSRegionBridge.drawByKeyboard(in: session, state: state))
        XCTAssertEqual(session.pins.last?.region, .ellipse(PixelRect(x0: 1, y0: 1, x1: 3, y1: 2)))

        state.tool = .polygon
        XCTAssertTrue(EELSRegionBridge.drawByKeyboard(in: session, state: state))
        XCTAssertEqual(session.pins.last?.region, .polygon([PixelPoint(x: 1, y: 1), PixelPoint(x: 3, y: 1), PixelPoint(x: 3, y: 2), PixelPoint(x: 1, y: 2)]))

        state.tool = .line
        XCTAssertTrue(EELSRegionBridge.drawByKeyboard(in: session, state: state))
        let line = try XCTUnwrap(session.lines.first)
        XCTAssertEqual(line.from, PixelPoint(x: 1, y: 1.5)); XCTAssertEqual(line.to, PixelPoint(x: 3, y: 1.5))
        XCTAssertEqual(session.selectedLineID, line.id)
        XCTAssertTrue(state.linesFocused)
        XCTAssertEqual(session.pins.count, 3, "a line is not a region")
    }

    /// The arrows move the selected region a pixel (shift: ten), kept on the scan; nothing selected, or at the scan's edge, leaves the key alone.
    /// Red under: the region does not move; it leaves the scan; a step of one with shift.
    @MainActor func testTheArrowsMoveTheSelectedRegion() async throws {
        let session = try await room()
        let state = EELSRoomState()
        XCTAssertFalse(EELSRegionBridge.nudgeSelected(dx: 1, dy: 0, in: session, state: state), "nothing selected")
        state.tool = .rectangle
        EELSRegionBridge.drawByKeyboard(in: session, state: state)
        XCTAssertTrue(EELSRegionBridge.nudgeSelected(dx: 1, dy: 0, in: session, state: state))
        XCTAssertEqual(session.pins.first?.region, .rectangle(PixelRect(x0: 2, y0: 1, x1: 4, y1: 2)))
        XCTAssertFalse(EELSRegionBridge.nudgeSelected(dx: 1, dy: 0, in: session, state: state), "at the scan's right edge")
        XCTAssertTrue(EELSRegionBridge.nudgeSelected(dx: 0, dy: -1, in: session, state: state))
        XCTAssertEqual(session.pins.first?.region, .rectangle(PixelRect(x0: 2, y0: 0, x1: 4, y1: 1)))

        XCTAssertTrue(EELSRegionBridge.arrowStep(.leftArrow, shift: false)! == (-1, 0))
        XCTAssertTrue(EELSRegionBridge.arrowStep(.downArrow, shift: true)! == (0, 10))
        XCTAssertNil(EELSRegionBridge.arrowStep(.return, shift: false))
        XCTAssertTrue(EELSRegionBridge.nudgeSelected(dx: -10, dy: 0, in: session, state: state))
        XCTAssertEqual(session.pins.first?.region, .rectangle(PixelRect(x0: 0, y0: 0, x1: 2, y1: 1)), "kept on the scan")
    }

    // MARK: The hovered pixel's spectrum

    /// ⌥ over a map: the pixel's stored low loss and core loss are two temporary layers on the plot's own axes; without ⌥, or off the maps, none.
    /// Red under: no pixel layer; a layer that is a region's sum; a layer drawn without ⌥; a layer in the legend.
    @MainActor func testOptionHoverDrawsThePixelsLowLossAndCoreLoss() async throws {
        let session = try await room()
        let state = EELSRoomState()
        let plot = try XCTUnwrap(session.plot)
        let core = try XCTUnwrap(plot.core)

        state.hoverPixel = EELSHoverPixel(x: 2, y: 1)
        XCTAssertNil(state.spectrumPixel, "no ⌥: no pixel layer")
        XCTAssertTrue(EELSLowerPane.layers(session, pixel: state.spectrumPixel).filter(\.isTemporary).isEmpty)

        state.optionHeld = true
        let pixel = try XCTUnwrap(state.spectrumPixel)
        let layers = EELSLowerPane.layers(session, pixel: pixel).filter(\.isTemporary)
        XCTAssertEqual(layers.count, 2)
        let image = try EELSRoomTests.image(), coreImage = try EELSControlsTests.core()
        let p = 1 * image.nx + 2
        let low = try XCTUnwrap(layers.first { $0.id == "pixel-low" })
        XCTAssertEqual(low.counts, Array(image.counts[(p * image.channels)..<((p + 1) * image.channels)]), "the pixel's stored low loss")
        XCTAssertEqual(low.origin, plot.low.origin); XCTAssertEqual(low.step, plot.low.step)
        let coreLayer = try XCTUnwrap(layers.first { $0.id == "pixel-core" })
        XCTAssertEqual(coreLayer.counts, Array(coreImage.counts[(p * coreImage.channels)..<((p + 1) * coreImage.channels)]), "the pixel's stored core loss")
        XCTAssertEqual(coreLayer.origin, core.origin); XCTAssertEqual(coreLayer.step, core.step)
        XCTAssertNotEqual(low.counts, plot.low.counts, "a pixel, not the whole map's sum")
        XCTAssertTrue(EELSLowerPane.legendLayers(EELSLowerPane.layers(session, pixel: pixel)).allSatisfy { !$0.isTemporary }, "the pixel is not in the legend")

        state.hoverPixel = nil
        XCTAssertNil(state.spectrumPixel, "off the maps: no pixel layer")
        XCTAssertNil(EELSPixelSpectrum.low(image, x: 4, y: 0), "off the scan")
        XCTAssertNil(EELSPixelSpectrum.core(coreImage, x: 0, y: 0, answered: [Bool](repeating: false, count: 12)), "a pixel the kit did not answer")
    }

    // MARK: Line profile labels

    /// The profile's distance is in the scan's pixel unit (the positions times the pixel size) when the file states one, else in pixels; the value axis is
    /// named after the maps it reads, never "Value". Red under: "px" on a calibrated scan; spacing left in pixels; "Value".
    @MainActor func testTheProfileUsesTheScanUnitAndTheMapsTitle() async throws {
        let session = try await room(scanPixel: (2.5, "nm"))
        XCTAssertNotNil(session.drawLine(from: PixelPoint(x: 0, y: 1.5), to: PixelPoint(x: 4, y: 1.5)))
        let series = EELSRegionBridge.series(session) { _ in 0.5 }
        let raw = session.profiles()
        XCTAssertFalse(series.isEmpty)
        for (s, p) in zip(series, raw) { XCTAssertEqual(s.spacing, (p.positions[1] - p.positions[0]) * 2.5, accuracy: 1e-12, s.name) }
        XCTAssertEqual(EELSRegionBridge.profileUnit(session), "nm")
        let title = EELSRegionBridge.profileValueTitle(session)
        XCTAssertNotEqual(title, "Value")
        XCTAssertTrue(title.hasPrefix("t/λ"), title)

        let bare = try await room()
        XCTAssertEqual(EELSRegionBridge.profileUnit(bare), "px")
        XCTAssertNotNil(bare.drawLine(from: PixelPoint(x: 0, y: 1.5), to: PixelPoint(x: 4, y: 1.5)))
        let bareSeries = EELSRegionBridge.series(bare) { _ in 0.5 }
        for (s, p) in zip(bareSeries, bare.profiles()) { XCTAssertEqual(s.spacing, p.positions[1] - p.positions[0], accuracy: 1e-12) }

        XCTAssertEqual(EELSRegionBridge.profileValueTitle(maps: [("t/λ", "")]), "t/λ")
        XCTAssertEqual(EELSRegionBridge.profileValueTitle(maps: [("t", "nm")]), "t (nm)")
        XCTAssertEqual(EELSRegionBridge.profileValueTitle(maps: [("C", "at%"), ("N", "at%")]), "C, N (at%)")
        XCTAssertEqual(EELSRegionBridge.profileValueTitle(maps: [("t/λ", ""), ("I total", "counts")]), "t/λ, I total")
    }

    // MARK: The picture

    /// The spectrum with the hovered pixel's layers and the profile inset with its labels, rendered offscreen from the planted room. Writes
    /// `macTEM-98-keys.png` when MACEM_SHOT_DIR is set; otherwise only checks that it renders.
    @MainActor func testTheSpectrumWithThePixelLayerRendersOffscreen() async throws {
        let session = try await room(scanPixel: (2.5, "nm"))
        session.drawLine(from: PixelPoint(x: 0, y: 1.5), to: PixelPoint(x: 4, y: 1.5))
        let state = EELSRoomState()
        state.hoverPixel = EELSHoverPixel(x: 3, y: 2)
        state.optionHeld = true
        let canvas = NSSize(width: 900, height: 360)
        let host = NSHostingView(rootView: EELSLowerPane(session: session, state: state).frame(width: canvas.width, height: canvas.height)
            .background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .light))
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
        try data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("macTEM-98-keys.png"))
    }
}
