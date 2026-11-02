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
        XCTAssertTrue(EELSLowerPane.layers(session, pixel: state.spectrumPixel, scheme: .light).filter(\.isTemporary).isEmpty)

        state.optionHeld = true
        let pixel = try XCTUnwrap(state.spectrumPixel)
        let layers = EELSLowerPane.layers(session, pixel: pixel, scheme: .light).filter(\.isTemporary)
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
        XCTAssertTrue(EELSLowerPane.legendLayers(EELSLowerPane.layers(session, pixel: pixel, scheme: .light)).allSatisfy { !$0.isTemporary }, "the pixel is not in the legend")

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
        let title = EELSRegionBridge.profileValueTitle(session, state: EELSRoomState())
        XCTAssertNotEqual(title, "Value")
        XCTAssertTrue(title.hasPrefix("t/λ"), title)

        let bare = try await room()
        XCTAssertEqual(EELSRegionBridge.profileUnit(bare), "px")
        XCTAssertNotNil(bare.drawLine(from: PixelPoint(x: 0, y: 1.5), to: PixelPoint(x: 4, y: 1.5)))
        let bareSeries = EELSRegionBridge.series(bare) { _ in 0.5 }
        for (s, p) in zip(bareSeries, bare.profiles()) { XCTAssertEqual(s.spacing, p.positions[1] - p.positions[0], accuracy: 1e-12) }
        // The title's rule: `testTheProfileKeepsOneQuantityAndAShortTitle`.
    }

    // MARK: The profile reads the maps the Maps control shows

    /// The planted room aligned and fitted for C, N and O: it then holds fourteen maps (t/λ, ZLP centre before and after, I₀, I total, three edges, three
    /// at%, three wt%).
    @MainActor private func fitted() async throws -> EELSSession {
        let session = try await room(scanPixel: (2.5, "nm"))
        session.setConvolveLowLoss(false)
        for (edge, _) in EELSControlsTests.amounts { session.toggleEdge(edge) }
        await session.run().value
        await session.settled()
        XCTAssertNotNil(session.model, session.failure ?? "no fit")
        XCTAssertNotNil(session.drawLine(from: PixelPoint(x: 0, y: 1.5), to: PixelPoint(x: 4, y: 1.5)))
        return session
    }

    /// With every map held and one Maps segment picked, the profile's series and its value axis are the shown maps of that segment's quantity, in the
    /// order the block shows them, as the EDS room's profile is its map mode's tiles: t/λ alone on t/λ (its edge maps are another unit), the at% maps
    /// on at%, the wt% maps on wt%. Each series is the line's own profile of that map, value for value. Red under: every map the room holds (14 series,
    /// "t/λ, ZLP centre, I₀, I total, C K, …"); at% and wt% both listed; units mixed on one axis.
    @MainActor func testTheProfileReadsOnlyTheShownMapsOfOneQuantity() async throws {
        let session = try await fitted()
        let state = EELSRoomState()
        XCTAssertEqual(session.displayedTiles.count, 14, session.displayedTiles.map(\.title).joined(separator: ", "))
        let all = Dictionary(session.profiles().map { ($0.id, $0.samples) }, uniquingKeysWith: { a, _ in a })

        state.maps = .tOverLambda
        XCTAssertEqual(EELSMapsBlock.shownMaps(session, state).count, 4, "t/λ and the three edge maps are on screen")
        var series = EELSRegionBridge.series(session, state: state) { _ in 0.5 }
        XCTAssertEqual(series.map(\.name), ["t/λ"])
        XCTAssertEqual(EELSRegionBridge.profileValueTitle(session, state: state), "t/λ")

        state.maps = .atomicPercent
        series = EELSRegionBridge.series(session, state: state) { _ in 0.5 }
        XCTAssertEqual(series.map(\.id), ["at-C", "at-N", "at-O"])
        XCTAssertEqual(series.map(\.name), ["C", "N", "O"])
        XCTAssertEqual(EELSRegionBridge.profileValueTitle(session, state: state), "at%")
        for s in series { XCTAssertEqual(s.values, all[s.id], "the line's own profile of \(s.id)") }

        state.maps = .weightPercent
        series = EELSRegionBridge.series(session, state: state) { _ in 0.5 }
        XCTAssertEqual(series.map(\.id), ["wt-C", "wt-N", "wt-O"])
        XCTAssertEqual(EELSRegionBridge.profileValueTitle(session, state: state), "wt%")
        for s in series { XCTAssertEqual(s.values, all[s.id], "the line's own profile of \(s.id)") }
    }

    /// The rule on its own: the segment's quantity (the at% or wt% maps on those segments, else the first map shown), every shown map of its unit, in order;
    /// the title one short quantity name. Red under: the shown list unfiltered; a title that lists every map.
    func testTheProfileKeepsOneQuantityAndAShortTitle() {
        func tile(_ id: String, _ title: String, _ unit: String) -> EELSMapTile {
            EELSMapTile(id: id, title: title, unit: unit, width: 1, height: 1, values: [0], version: 0, footer: nil)
        }
        let shown = [tile("tOverLambda", "t/λ", ""), tile("edge-C", "C K", "intensity"), tile("edge-N", "N K", "intensity")]
        XCTAssertEqual(EELSRegionBridge.profileMaps(shown: shown, segment: .tOverLambda).map(\.id), ["tOverLambda"])
        let at = [tile("tOverLambda", "t/λ", ""), tile("at-C", "C", "at%"), tile("at-N", "N", "at%")]
        XCTAssertEqual(EELSRegionBridge.profileMaps(shown: at, segment: .atomicPercent).map(\.id), ["at-C", "at-N"])
        let zlp = [tile("zlpShift", "ZLP shift", "eV"), tile("edge-C", "C K", "intensity")]
        XCTAssertEqual(EELSRegionBridge.profileMaps(shown: zlp, segment: .zlp).map(\.id), ["zlpShift"])
        XCTAssertEqual(EELSRegionBridge.profileMaps(shown: [], segment: .atomicPercent).map(\.id), [])

        XCTAssertEqual(EELSRegionBridge.profileValueTitle(maps: [("t/λ", "")]), "t/λ")
        XCTAssertEqual(EELSRegionBridge.profileValueTitle(maps: [("t", "nm")]), "t (nm)")
        XCTAssertEqual(EELSRegionBridge.profileValueTitle(maps: [("C", "at%"), ("N", "at%"), ("O", "at%")]), "at%")
        XCTAssertEqual(EELSRegionBridge.profileValueTitle(maps: [("C", "wt%"), ("N", "wt%")]), "wt%")
        XCTAssertEqual(EELSRegionBridge.profileValueTitle(maps: [("C K", "intensity"), ("N K", "intensity")]), "2 maps (intensity)")
        XCTAssertEqual(EELSRegionBridge.profileValueTitle(maps: [("t/λ", ""), ("I total", "counts")]), "t/λ", "the first map's quantity, never a mix")
    }

    // MARK: The hovered pixel's colour

    /// The hovered pixel's layers are dark in the light appearance and light in the dark one, so they read on either plot (white vanished on the light
    /// plot). Red under: white in the light appearance.
    @MainActor func testTheHoveredPixelShowsInBothAppearances() async throws {
        let session = try await room()
        let pixel = EELSHoverPixel(x: 2, y: 1)
        func luminance(_ c: RegionColor) -> Double { 0.2126 * c.red + 0.7152 * c.green + 0.0722 * c.blue }
        let light = EELSLowerPane.layers(session, pixel: pixel, scheme: .light).filter(\.isTemporary)
        XCTAssertEqual(light.count, 2)
        for layer in light {
            XCTAssertNotEqual(layer.color, RegionColor(red: 1, green: 1, blue: 1), layer.id)
            XCTAssertLessThan(luminance(layer.color), 0.35, "dark on the light plot: \(layer.id)")
        }
        let dark = EELSLowerPane.layers(session, pixel: pixel, scheme: .dark).filter(\.isTemporary)
        XCTAssertEqual(dark.count, 2)
        for layer in dark { XCTAssertGreaterThan(luminance(layer.color), 0.65, "light on the dark plot: \(layer.id)") }
        XCTAssertEqual(EELSLowerPane.pixelColor(.light), light[0].color)
    }

    /// The fitted room's lower pane in the light appearance, on t/λ and on at%, with the hovered pixel: written as `macTEM-98fix1-<tag>-<segment>.png`
    /// when MACEM_SHOT_DIR is set (tag MACEM_SHOT_TAG, default "after"); otherwise only checks that it renders.
    @MainActor func testTheProfileInsetRendersOffscreenOnEachSegment() async throws {
        let session = try await fitted()
        let env = ProcessInfo.processInfo.environment
        for segment in [EELSMapsSegment.tOverLambda, .atomicPercent] {
            let state = EELSRoomState()
            state.maps = segment
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
            guard let dir = env["MACEM_SHOT_DIR"] else { continue }
            let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            let name = "macTEM-98fix1-\(env["MACEM_SHOT_TAG"] ?? "after")-\(segment == .tOverLambda ? "tlambda" : "at").png"
            try data.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
        }
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
