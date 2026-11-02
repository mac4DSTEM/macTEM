//
//  EELSMapTilesTests.swift
//  Two tiles of the EELS maps block as the drive of 2026-11-02 saw them on real spectrum images:
//  - the ZLP shift tile was almost all white: its diverging scale reached the largest |shift|, and one far pixel (a zero-loss peak lost at the scan's edge)
//    put every other pixel in the white of the centre. The scale now reaches max(|p1|, |p99|), still centred on 0, on the same red-blue map.
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

    /// Red under the largest-|value| scale: 999 of 1000 pixels were within 1 % of the centre, drawn near white.
    func testOneFarPixelNoLongerWhitensTheShiftTile() {
        let tile = Self.plantedShift()
        let rgba = Self.render(tile)
        let nearWhite = stride(from: 0, to: rgba.count, by: 4).filter { rgba[$0] > 230 && rgba[$0 + 1] > 230 && rgba[$0 + 2] > 230 }.count
        XCTAssertLessThan(nearWhite, 300, "\(nearWhite) of 1000 pixels near white: the scale is still set by the one far pixel")
        let scaled = EELSMapScale.scaled(tile.values, mode: .diverging)
        XCTAssertEqual(scaled.high, -scaled.low, "centred on 0")
        XCTAssertLessThan(scaled.high, 0.06, "the range is the bulk's, not the far pixel's")
        XCTAssertEqual(scaled.values[0], 1, "the far pixel takes the end colour")
        XCTAssertEqual(EELSTileStyle.defaultColoring("zlpShift"), .colormap(.rdbu), "the red-blue diverging map")
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
        XCTAssertEqual(items[0].defaultColoring, .colormap(.rdbu))
        let root = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
        let room = try String(contentsOf: root.appendingPathComponent("macTEM/UI/EELSRoom.swift"), encoding: .utf8)
        XCTAssertFalse(room.contains("controls: { EmptyView() }"), "a scale bar with nothing to open")
        XCTAssertTrue(room.contains("controls: { EELSMixPopover(maps: maps, state: state) }"))
    }
}
