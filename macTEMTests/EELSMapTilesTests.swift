//
//  EELSMapTilesTests.swift
//  Two tiles of the EELS maps block as the drive of 2026-11-02 saw them on real spectrum images:
//  - the ZLP shift tile was almost all white: its diverging scale reached the largest |shift|, and one far pixel (a zero-loss peak lost at the scan's edge)
//    put every other pixel in the white of the centre. The scale then reached max(|p1|, |p99|), centred on 0; since the drive of 2026-11-12 (a
//    calibrated shift is mostly one offset, so the centred scale drew one solid colour) it runs from p1 to p99 on viridis, as exSpy users see it.
//  - an empty bubble stood over the colour mix: its scale bar opened a popover with nothing in it. It now lists the maps in the mix, as the EDS room's.
//  The tiles' colours change; the values, the hover readout and the numbers the exports write do not (they read the tile's raw values).
//
//  THE TRUTH: a planted shift map, 0.05 eV either way on every pixel but one at 5 eV, drawn offscreen through the tile's own raster.
//

import XCTest
import ShellMetal
import ShellSpectroscopy
import TEMCore
@testable import macTEM

nonisolated final class EELSMapTilesTests: XCTestCase {
    /// 40 × 25 shifts: ±0.05 eV in a ramp, and one pixel at 5 eV.
    private static func plantedShift() -> EELSMapTile {
        var values = (0..<1000).map { 0.05 * sin(Double($0) / 7) }
        values[0] = 5
        return EELSMapTile(id: "zlpShift", title: "ZLP shift", unit: "eV", width: 40, height: 25, values: values, version: 1, footer: nil)
    }

    /// The tile's pixels, as the tile draws them (default colouring, no window).
    private static func render(_ tile: EELSMapTile) -> [UInt8] {
        let scaled = EELSMapScale.scaled(tile.values, mode: EELSMapScale.mode(forTileID: tile.id))
        return MapRaster.rgba(values: scaled.values, coloring: EELSTileStyle.defaultColoring(tile.id), upper: 1, adjustment: MapAdjustment())
    }

    /// One pixel far out (a zero-loss peak the alignment lost) takes the end colour; the scale is the bulk's 1st to 99th percentile, not the far pixel's.
    /// Red under a plain min-to-max scale: the far pixel at 5 eV squeezed the other 999 into the bottom 2 % of the scale.
    func testOneFarPixelDoesNotSetTheShiftTilesScale() {
        let tile = Self.plantedShift()
        let scaled = EELSMapScale.scaled(tile.values, mode: EELSMapScale.mode(forTileID: tile.id))
        XCTAssertLessThan(scaled.high, 0.06, "the range is the bulk's, not the far pixel's")
        XCTAssertGreaterThan(scaled.low, -0.06)
        XCTAssertEqual(scaled.values[0], 1, "the far pixel takes the end colour")
        XCTAssertEqual(EELSTileStyle.defaultColoring("zlpShift"), .colormap(.viridis), "sequential, as exSpy users see the shift")
    }

    /// With Calibrate the shift is mostly one offset for the whole scan (−1 eV here) and a small drift across it: the tile spreads the drift over the
    /// whole scale. Red before (centred on 0, drive 2026-11-12): every pixel sat at the scale's end and the tile was one solid colour.
    func testAnOffsetShiftMapShowsItsDrift() {
        let values = (0..<1000).map { -1 + 0.02 * Double($0 % 40) / 39 }
        let tile = EELSMapTile(id: "zlpShift", title: "ZLP shift", unit: "eV", width: 40, height: 25, values: values, version: 1, footer: nil)
        let scaled = EELSMapScale.scaled(tile.values, mode: EELSMapScale.mode(forTileID: tile.id))
        XCTAssertEqual(scaled.values.min() ?? .nan, 0, accuracy: 1e-9)
        XCTAssertEqual(scaled.values.max() ?? .nan, 1, accuracy: 1e-9)
        XCTAssertGreaterThan(Set(Self.render(tile)).count, 20, "many colours, not one")
    }

    /// A file aligned at acquisition: one shift on almost every pixel (5e-5 eV, equal but for the last bits) and a few pixels far out (a lost
    /// zero-loss peak, up to 8 eV). Red before (drive 2026-11-12, 145_STEM): the percentiles were a rounding error apart, so the bulk was
    /// stretched to the top of the scale and the tile was solid yellow. The bulk now takes one colour and the far pixels their own.
    func testAShiftMapFlatButForRoundingShowsItsFarPixels() {
        var values = (0..<1000).map { 5e-5 + Double($0 % 3) * 1e-19 }
        values[10] = 8.12; values[20] = -3
        let scaled = EELSMapScale.scaled(values, mode: EELSMapScale.mode(forTileID: "zlpShift"))
        XCTAssertEqual(scaled.low, -3); XCTAssertEqual(scaled.high, 8.12)
        XCTAssertEqual(scaled.values[10], 1); XCTAssertEqual(scaled.values[20], 0)
        XCTAssertEqual(Set(scaled.values.enumerated().filter { $0.offset != 10 && $0.offset != 20 }.map { ($0.element * 1e6).rounded() }).count, 1,
                       "the bulk is one colour")
        let flat = EELSMapScale.scaled((0..<1000).map { 5e-5 + Double($0 % 3) * 1e-19 }, mode: .robustMinToMax)
        XCTAssertTrue(flat.values.allSatisfy { $0 == EELSMapScale.flatLevel }, "rounding error alone draws flat, mid-scale")
    }

    /// The colours move; the numbers do not: the tile's values are untouched and the readout reads them raw.
    func testTheValuesAndTheReadoutStayTheSame() {
        let tile = Self.plantedShift()
        let before = tile.values
        _ = EELSMapScale.scaled(tile.values, mode: .diverging)
        _ = Self.render(tile)
        XCTAssertEqual(tile.values, before)
        let en = Locale(identifier: "en_US")
        XCTAssertEqual(EELSRoomFormat.readout(x: 0, y: 0, tiles: [tile], refusal: nil, locale: en), "row 0 · col 0 · ZLP shift 5 eV")
        XCTAssertEqual(EELSRoomFormat.readout(x: 7, y: 0, tiles: [tile], refusal: nil, locale: en), "row 0 · col 7 · ZLP shift " + EELSRoomFormat.sig(before[7], 4, locale: en) + " eV")
    }

    /// A map of zeros and one far pixel: the percentiles are both 0, so the scale reaches the far pixel (never a scale of no width).
    func testAMapOfZerosFallsBackToItsLargestValue() {
        var values = [Double](repeating: 0, count: 1000); values[3] = -2
        let scaled = EELSMapScale.scaled(values, mode: .diverging)
        XCTAssertEqual(scaled.low, -2); XCTAssertEqual(scaled.high, 2)
        XCTAssertEqual(scaled.values[3], 0); XCTAssertEqual(scaled.values[0], 0.5)
    }

    /// The colour mix's scale bar opens the maps it chooses from (a checkbox each), as the EDS room's; it opened an empty popover. Red under: `EmptyView`.
    @MainActor func testTheMixPopoverListsTheMaps() throws {
        let maps = [Self.plantedShift(),
                    EELSMapTile(id: "edge-C-K", title: "C K", unit: "nm⁻²", width: 40, height: 25, values: [Double](repeating: 1, count: 1000), version: 1, footer: nil)]
        let items = EELSMixComposition.colorItems(maps: maps)
        XCTAssertEqual(items.map(\.id), ["zlpShift", "edge-C-K"])
        XCTAssertEqual(items.map(\.title), ["ZLP shift", "C K"])
        XCTAssertEqual(items[0].defaultColoring, .colormap(.viridis))
        let root = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
        let room = try String(contentsOf: root.appendingPathComponent("macTEM/UI/EELSRoom.swift"), encoding: .utf8)
        XCTAssertFalse(room.contains("controls: { EmptyView() }"), "a scale bar with nothing to open")
        XCTAssertTrue(room.contains("controls: { EELSMixPopover(maps: maps, state: state) }"))
    }
}
