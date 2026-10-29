//
//  EDXRegionsTests.swift
//  The EDX room's part 2: ellipse and polygon regions, pinned regions and their CSV, the zeta and cross-section maps with their mass
//  thickness, the spectrum as `.msa`, and the maps figure. On EDXSessionTests' planted two-pixel Al-Mg-Si image.
//
//  WHAT IS PINNED (D12, D17): the room has no arithmetic of its own. A shape's spectrum is the kit's `SpectrumRegionShape` mask summed
//  (equal to the rectangle's where the shapes cover the same pixels); a map pixel is the kit's `EDXQuantification.quantify` on that
//  pixel's net counts to the bit; the pins CSV reads back; the MSA file is FormatoKit's writer and reads back through its reader.
//

import XCTest
import SwiftUI
import FormatoCore
import SpectroCore
import SpectroEDX
import ShellSpectroscopy
import FormatoMSA
import TEMCore
import TEMSession
@testable import macTEM

nonisolated final class EDXRegionsTests: XCTestCase {

    @MainActor private func openRoom() async -> EDXSession {
        let session = EDXSession()
        await session.bind(EDXSessionTests.source()).value
        await session.settled()
        return session
    }

    private static let left = EDXSessionTests.spectra().left.map { UInt64($0) }
    private static let both = zip(EDXSessionTests.spectra().left, EDXSessionTests.spectra().right).map { UInt64($0) + UInt64($1) }

    // MARK: Several regions

    /// Every shape drawn is kept as the next numbered region: two drawn shapes are two regions, each with its own pooled spectrum (the kit's sum of its pixels,
    /// exact), a table row with its pixel count and counts, and hiding one drops its layer but keeps its row. A shape drawn twice is one region; a deleted
    /// region's number is not reused. Red under: a second drawing replacing the first; the layer of a hidden region kept; numbers recycled.
    @MainActor func testDrawnShapesAreKeptAsRegionsEachWithItsOwnSpectrum() async throws {
        let session = await openRoom()
        let leftPixel = PixelRect(x0: 0, y0: 0, x1: 1, y1: 1), rightPixel = PixelRect(x0: 1, y0: 0, x1: 2, y1: 1)
        session.drawRectangle(leftPixel)
        session.drawRectangle(rightPixel)
        session.drawRectangle(rightPixel)
        await session.settled()
        XCTAssertEqual(session.pins.map(\.name), ["Region 1", "Region 2"])
        XCTAssertEqual(session.pins.map(\.number), [1, 2])
        XCTAssertEqual(session.selectedPin?.name, "Region 2", "the last drawn is the one selected")
        let (a, b) = (session.pins[0], session.pins[1])
        XCTAssertEqual(session.pinSpectra[a.id], Self.left.map { Double($0) })
        XCTAssertEqual(session.pinSpectra[b.id], EDXSessionTests.spectra().right.map { Double($0) })
        XCTAssertEqual(session.pinRows.map(\.pixels), [1, 1])
        XCTAssertEqual(session.pinRows[0].counts, Self.left.reduce(0, +))

        session.setPinVisible(b.id, false)
        await session.settled()
        XCTAssertNotNil(session.pinSpectra[a.id]); XCTAssertNil(session.pinSpectra[b.id], "a hidden region has no layer")
        XCTAssertEqual(session.pinRows.count, 2, "but keeps its row in the table")

        session.removePin(a.id)
        session.drawRectangle(leftPixel)
        await session.settled()
        XCTAssertEqual(session.pins.map(\.number), [2, 3], "a deleted region's number is not handed on")
        XCTAssertEqual(session.pins.last?.name, "Region 3")
    }

    /// A region edited on the map (moved) takes its new pixels: its layer and, when it is the selected one, the spectrum follow; an edit onto another region's
    /// pixels or off the scan changes nothing. Red under: the pin edited but the selected region left on the old pixels.
    @MainActor func testAnEditedRegionTakesItsNewPixels() async throws {
        let session = await openRoom()
        let leftPixel = PixelRect(x0: 0, y0: 0, x1: 1, y1: 1), rightPixel = PixelRect(x0: 1, y0: 0, x1: 2, y1: 1)
        session.drawRectangle(leftPixel)
        await session.settled()
        let id = session.pins[0].id
        session.setPinRegion(id, .rectangle(rightPixel))
        await session.settled()
        XCTAssertEqual(session.pins[0].region, .rectangle(rightPixel))
        XCTAssertEqual(session.spectrumCounts, EDXSessionTests.spectra().right.map { UInt64($0) }, "the selected region's spectrum follows")
        XCTAssertEqual(session.pinSpectra[id], EDXSessionTests.spectra().right.map { Double($0) })
        session.drawRectangle(leftPixel)
        session.setPinRegion(id, .rectangle(leftPixel))   // another region's pixels
        session.setPinRegion(id, .rectangle(PixelRect(x0: 5, y0: 5, x1: 6, y1: 6)))   // off the scan
        XCTAssertEqual(session.pins[0].region, .rectangle(rightPixel))
        let line = try XCTUnwrap(session.drawLine(from: PixelPoint(x: 0, y: 0.5), to: PixelPoint(x: 2, y: 0.5)))
        session.setLineEnds(line.id, from: PixelPoint(x: 0.5, y: 0.5), to: PixelPoint(x: 1.7, y: 0.5))
        XCTAssertEqual(session.lines[0].from.x, 0.5); XCTAssertEqual(session.lines[0].to.x, 1.7)
        session.setLineEnds(line.id, from: PixelPoint(x: 0.5, y: 0.5), to: PixelPoint(x: 0.9, y: 0.5))
        XCTAssertEqual(session.lines[0].to.x, 1.7, "a line shorter than a pixel is refused")
    }

    /// A pixel's spectrum is that pixel's counts, and a pixel off the grid has none.
    @MainActor func testThePointersPixelSpectrumIsThePixelsCounts() async {
        let session = await openRoom()
        XCTAssertEqual(session.pixelSpectrum(x: 0, y: 0), Self.left.map { Double($0) })
        XCTAssertEqual(session.pixelSpectrum(x: 1, y: 0), EDXSessionTests.spectra().right.map { Double($0) })
        XCTAssertNil(session.pixelSpectrum(x: 2, y: 0)); XCTAssertNil(session.pixelSpectrum(x: 0, y: -1))
    }

    // MARK: Lines

    /// The profile along a line on a ramp map (value = column) reads the ramp: ImagoKit's sampler at pixel centres, the scan grid's convention (pixel i covers
    /// [i, i+1)). Red under: the half-pixel shift dropped (the samples run 0.5...9.5).
    func testAProfileAlongALineReadsTheMapAtPixelCentres() {
        let w = 10, h = 3
        let values = (0..<(w * h)).map { Double($0 % w) }
        let line = EDXLine(name: "Line 1", number: 1, from: PixelPoint(x: 0.5, y: 1.5), to: PixelPoint(x: 9.5, y: 1.5))
        let p = EDXLineProfiles.profile(values: values, width: w, height: h, along: line)
        XCTAssertEqual(p.samples.count, 10)
        for (i, v) in p.samples.enumerated() { XCTAssertEqual(v, Double(i), accuracy: 1e-6) }
        XCTAssertEqual(p.positions.last ?? 0, 9, accuracy: 1e-9)
        let short = EDXLine(name: "x", number: 1, from: PixelPoint(x: 1, y: 1), to: PixelPoint(x: 1.4, y: 1))
        XCTAssertTrue(EDXLineProfiles.profile(values: values, width: w, height: h, along: short).samples.isEmpty)
    }

    /// Lines are numbered apart from regions, clamped to the scan and dropped when shorter than a pixel; the profile needs maps and a selected line.
    @MainActor func testLinesAreKeptClampedAndNumbered() async {
        let session = await openRoom()
        XCTAssertNil(session.drawLine(from: PixelPoint(x: 0, y: 0), to: PixelPoint(x: 0.3, y: 0)), "shorter than a pixel")
        let line = session.drawLine(from: PixelPoint(x: -3, y: 0.5), to: PixelPoint(x: 9, y: 0.5))
        XCTAssertEqual(line?.name, "Line 1")
        XCTAssertEqual(line?.from.x, 0); XCTAssertEqual(line?.to.x, 2, "clamped to the 2-pixel scan")
        XCTAssertEqual(session.selectedLineID, line?.id)
        session.removeLine(line!.id)
        XCTAssertEqual(session.drawLine(from: PixelPoint(x: 0, y: 0.5), to: PixelPoint(x: 2, y: 0.5))?.name, "Line 2")
        XCTAssertTrue(session.pins.isEmpty, "a line is not a region")
    }

    // MARK: Calibrated profiles

    /// A line profile is in the file's pixel unit when it states a pixel size, in scan pixels when it does not. Red under: the spacing left in pixels (an uncalibrated
    /// axis labelled nm).
    @MainActor func testAProfileIsInTheFilesPixelUnitWhenItHasOne() async throws {
        let plain = EDXSession()
        await plain.bind(EDXSessionTests.source()).value; await plain.settled()
        XCTAssertNil(plain.scanPixel, "no pixel size in the planted file")
        let calibrated = EDXSession()
        await calibrated.bind(EDXSessionTests.source(pixelSizeNM: 0.5)).value; await calibrated.settled()
        XCTAssertEqual(calibrated.scanPixel?.size, 0.5); XCTAssertEqual(calibrated.scanPixel?.unit, "nm")
        calibrated.drawLine(from: PixelPoint(x: 0, y: 0.5), to: PixelPoint(x: 2, y: 0.5))
        plain.drawLine(from: PixelPoint(x: 0, y: 0.5), to: PixelPoint(x: 2, y: 0.5))
        let withSize = EDXRegionBridge.series(calibrated), without = EDXRegionBridge.series(plain)
        XCTAssertFalse(withSize.isEmpty)
        XCTAssertEqual(try XCTUnwrap(withSize.first).spacing, 0.5 * (try XCTUnwrap(without.first).spacing), accuracy: 1e-12)
    }

    // MARK: Shapes

    /// A polygon, an ellipse and a rectangle that cover the same pixels sum the same spectrum, exactly; shapes covering both pixels
    /// give the whole map. Red under: the polygon or ellipse mask ignored (whole map summed); a vertex order that changes the sum.
    @MainActor func testShapesCoveringTheSamePixelsSumTheSameSpectrum() async {
        let session = await openRoom()
        session.selectRectangle(PixelRect(x0: 0, y0: 0, x1: 1, y1: 1))
        await session.settled()
        let rectangle = session.spectrumCounts
        XCTAssertEqual(rectangle, Self.left)

        session.selectPolygon([PixelPoint(x: 0, y: 0), PixelPoint(x: 1, y: 0), PixelPoint(x: 1, y: 1), PixelPoint(x: 0, y: 1)])
        await session.settled()
        XCTAssertEqual(session.spectrumCounts, rectangle, "a polygon over the left pixel")
        XCTAssertEqual(session.regionPixels, 1)
        XCTAssertEqual(session.regionName, "Region")

        session.selectPolygon([PixelPoint(x: 0, y: 1), PixelPoint(x: 1, y: 1), PixelPoint(x: 1, y: 0), PixelPoint(x: 0, y: 0)])
        XCTAssertEqual(session.region.cacheKey.hasPrefix("poly:"), true)
        await session.settled()
        XCTAssertEqual(session.spectrumCounts, rectangle, "the other winding")

        session.selectEllipse(PixelRect(x0: 0, y0: 0, x1: 1, y1: 1))
        await session.settled()
        XCTAssertEqual(session.spectrumCounts, rectangle, "an ellipse in the left pixel")

        session.selectPolygon([PixelPoint(x: 0, y: 0), PixelPoint(x: 2, y: 0), PixelPoint(x: 2, y: 1), PixelPoint(x: 0, y: 1)])
        await session.settled()
        XCTAssertEqual(session.spectrumCounts, Self.both, "a polygon over both pixels is the whole map")
        XCTAssertEqual(session.regionPixels, 2)
        session.selectEllipse(PixelRect(x0: 0, y0: 0, x1: 2, y1: 1))
        await session.settled()
        XCTAssertEqual(session.spectrumCounts, Self.both, "an ellipse whose centres lie inside")
    }

    /// A polygon of two vertices, one off the grid and a zero-area rectangle change nothing. Red under: an empty region selected.
    @MainActor func testAShapeThatHoldsNoPixelChangesNothing() async {
        let session = await openRoom()
        session.selectPolygon([PixelPoint(x: 0, y: 0), PixelPoint(x: 1, y: 1)])
        session.selectPolygon([PixelPoint(x: 5, y: 5), PixelPoint(x: 6, y: 5), PixelPoint(x: 6, y: 6)])
        session.selectEllipse(PixelRect(x0: 1, y0: 0, x1: 1, y1: 1))
        XCTAssertEqual(session.region, .wholeMap)
    }

    func testTheRegionSentencesNameTheShape() {
        XCTAssertEqual(EDXRoomFormat.region(.ellipse(PixelRect(x0: 1, y0: 2, x1: 5, y1: 6)), pixels: 12), "Ellipse · x 1–4, y 2–5 · 12 px")
        XCTAssertEqual(EDXRoomFormat.region(.polygon([PixelPoint(x: 0, y: 0), PixelPoint(x: 3, y: 0), PixelPoint(x: 0, y: 3)]), pixels: 4), "Polygon · 3 vertices · 4 px")
    }

    /// The outline of a region in a picture of 100 × 50 points over a 10 × 5 grid: a rectangle, an ellipse and a polygon sit where their
    /// pixels sit; the whole map has none. Red under: x and y scales swapped.
    func testTheOutlineSitsOnThePixels() throws {
        let size = CGSize(width: 100, height: 50)
        XCTAssertNil(EDXMapOutline.outline(of: .wholeMap, in: size, nx: 10, ny: 5))
        let rect = try XCTUnwrap(EDXMapOutline.outline(of: .rectangle(PixelRect(x0: 2, y0: 1, x1: 6, y1: 4)), in: size, nx: 10, ny: 5)).boundingRect
        XCTAssertEqual(rect, CGRect(x: 20, y: 10, width: 40, height: 30))
        let ellipse = try XCTUnwrap(EDXMapOutline.outline(of: .ellipse(PixelRect(x0: 2, y0: 1, x1: 6, y1: 4)), in: size, nx: 10, ny: 5)).boundingRect
        XCTAssertEqual(ellipse.minX, 20, accuracy: 1e-9); XCTAssertEqual(ellipse.width, 40, accuracy: 1e-9)
        let poly = try XCTUnwrap(EDXMapOutline.outline(of: .polygon([PixelPoint(x: 1, y: 1), PixelPoint(x: 4.5, y: 1), PixelPoint(x: 1, y: 3)]), in: size, nx: 10, ny: 5)).boundingRect
        XCTAssertEqual(poly, CGRect(x: 10, y: 10, width: 35, height: 20))
    }

    // MARK: Pins

    /// A pin keeps a region under a name; selecting it sums it; a region is pinned once; rename and remove work; a new image clears
    /// the pins. Red under: the pin not selecting its region; a duplicate pin; pins kept across files.
    @MainActor func testPinsKeepSelectAndRename() async throws {
        let session = await openRoom()
        XCTAssertNil(session.selectedPin)
        session.selectRectangle(PixelRect(x0: 0, y0: 0, x1: 1, y1: 1))
        let first = try XCTUnwrap(session.pinRegion())
        XCTAssertEqual(first.name, "Region 1")
        XCTAssertEqual(session.selectedPin?.id, first.id)
        XCTAssertEqual(session.pinRegion()?.id, first.id, "a region already pinned is not pinned twice")
        XCTAssertEqual(session.pins.count, 1)
        session.selectEllipse(PixelRect(x0: 1, y0: 0, x1: 2, y1: 1))
        XCTAssertNil(session.selectedPin)
        let second = try XCTUnwrap(session.pinRegion(named: "  Matrix  "))
        XCTAssertEqual(second.name, "Matrix")
        session.selectPin(first.id)
        await session.settled()
        XCTAssertEqual(session.spectrumCounts, Self.left, "selecting a pin sums its region")
        XCTAssertEqual(session.selectedPin?.id, first.id)
        session.renamePin(first.id, to: "Precipitate")
        session.renamePin(first.id, to: "   ")
        XCTAssertEqual(session.pins.first?.name, "Precipitate", "an empty name is refused")
        session.removePin(second.id)
        XCTAssertEqual(session.pins.map(\.name), ["Precipitate"])
        await session.bind(EDXSessionTests.source()).value
        XCTAssertTrue(session.pins.isEmpty, "a new image starts with no pins")
    }

    /// The pins CSV: counts and nets are the kit's, the composition is empty until the factors are complete and then sums to 100, and
    /// the file reads back to the same pins (names with commas and quotes, every shape). Red under: a lossy geometry; an unquoted name.
    @MainActor func testPinsCSVRoundTrips() async throws {
        let session = await openRoom()
        session.selectRectangle(PixelRect(x0: 0, y0: 0, x1: 1, y1: 1))
        session.pinRegion(named: "Left, \"hot\"")
        session.selectEllipse(PixelRect(x0: 0, y0: 0, x1: 2, y1: 1))
        session.pinRegion(named: "Both")
        session.selectPolygon([PixelPoint(x: 0.25, y: 0), PixelPoint(x: 2, y: 0), PixelPoint(x: 2, y: 1)])
        session.pinRegion(named: "Tri")
        session.selectWholeMap()
        session.pinRegion()
        let maybeCSV = await session.pinsCSV()
        let csv = try XCTUnwrap(maybeCSV)
        let lines = csv.split(separator: "\n").map(String.init)
        let header = try XCTUnwrap(lines.first { !$0.hasPrefix("#") })
        XCTAssertTrue(header.hasPrefix("name,shape,geometry,pixels,counts,net_"), header)
        XCTAssertTrue(lines.contains { $0.hasPrefix("\"Left, \"\"hot\"\"\",rectangle,0 0 1 1,1,\(Self.left.reduce(0, +)),") }, csv)
        XCTAssertTrue(lines.contains { $0.hasPrefix("Both,ellipse,0 0 2 1,2,\(Self.both.reduce(0, +)),") }, csv)
        let nets = lines.filter { !$0.hasPrefix("#") && !$0.hasPrefix("name,") }
        XCTAssertEqual(nets.count, 4)
        XCTAssertTrue(nets.allSatisfy { $0.hasSuffix(",,,") || $0.split(separator: ",", omittingEmptySubsequences: false).suffix(2).allSatisfy(\.isEmpty) },
                      "no composition before the factors are complete")

        let back = try XCTUnwrap(EDXPins.parse(csv))
        XCTAssertEqual(back.map(\.name), session.pins.map(\.name))
        XCTAssertEqual(back.map(\.region), session.pins.map(\.region))

        var draft = EDXTypedKDraft(elements: session.quantifiedSymbols, current: session.method)
        for i in draft.rows.indices { draft.rows[i].k = 1 + 0.1 * Double(i) }
        draft.source = "test"
        session.commitTypedK(draft, date: "2026-10-21")
        let maybeTyped = await session.pinsCSV()
        let typed = try XCTUnwrap(maybeTyped)
        let both = try XCTUnwrap(typed.split(separator: "\n").first { $0.hasPrefix("Both,") })
        let cells = both.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        let n = session.quantifiedSymbols.count
        XCTAssertEqual(cells.count, 5 + 3 * n)
        let wt = cells[(5 + n)..<(5 + 2 * n)].compactMap(Double.init)
        XCTAssertEqual(wt.count, n)
        XCTAssertEqual(wt.reduce(0, +), 100, accuracy: 1e-3 * 100, "wt% of a pin sums to 100 (printed to six digits)")
        XCTAssertNil(EDXPins.parse("a,b\n1,2\n"), "not a pins file")
    }

    // MARK: Zeta and cross section

    @MainActor private func setZeta(_ session: EDXSession, method: EDXMapMethod) {
        var draft = EDXFactorsDraft(method: method, elements: session.quantifiedSymbols, current: session.dose)
        for i in draft.rows.indices { draft.rows[i].value = method == .zeta ? 1000 * (1 + 0.1 * Double(i)) : 200 * (1 + 0.1 * Double(i)) }
        draft.beamCurrentNA = 0.5; draft.liveTimeSeconds = 0.01; draft.probeAreaNm2 = 1.5
        draft.source = "test factors"
        session.commitFactors(draft, date: "2026-10-21")
    }

    /// The zeta method's maps are the kit's per pixel, to the bit, with the mass thickness as its own tile; the footer names the
    /// factors, the dose and the badge. Red under: the dose not passed; the mass-thickness tile missing.
    @MainActor func testZetaMapsAreTheKitsPerPixelWithMassThickness() async throws {
        let session = await openRoom()
        session.setMapMethod(.zeta)
        session.setMapMode(.massThickness)
        guard case .blocked(let why) = session.mapsState else { return XCTFail("\(session.mapsState)") }
        XCTAssertTrue(why.hasPrefix("Type a zeta factor for "), why)
        setZeta(session, method: .zeta)
        await session.settled()
        XCTAssertEqual(session.mapsState, .done)
        let maps = try XCTUnwrap(session.quantMaps)
        let mass = try XCTUnwrap(maps.massThickness)
        let setup = EDXQuantificationSetup(elements: maps.elements, method: .zeta(zetaFactors: maps.elements.indices.map { 1000 * (1 + 0.1 * Double($0)) }),
                                           beamCurrentNA: 0.5, liveTimeSeconds: 0.01)
        let net = try maps.elements.map { s in try XCTUnwrap(session.tiles.first { $0.symbol == s }).values }
        for p in 0..<2 {
            let direct = try EDXQuantification.quantify(intensities: net.map { $0[p] }, setup: setup)
            XCTAssertEqual(mass[p], try XCTUnwrap(direct.massThickness), "ρt at pixel \(p)")
            for e in maps.elements.indices { XCTAssertEqual(maps.weightPercent[e][p], direct.weightPercent[e]) }
        }
        let tile = try XCTUnwrap(session.shownTiles.first)
        XCTAssertEqual(session.shownTiles.count, 1)
        XCTAssertEqual(tile.mode, .massThickness)
        XCTAssertEqual(tile.values, mass)
        let footer = try XCTUnwrap(tile.footer)
        XCTAssertTrue(footer.contains("zeta factors: test factors") && footer.contains("0.5 nA, 0.01 s") && footer.contains("validation: none"), footer)
        session.setMapMode(.weight)
        XCTAssertEqual(session.shownTiles.map(\.symbol), maps.elements)
        XCTAssertTrue(try XCTUnwrap(session.shownTiles.first?.footer).contains("zeta factors"))
    }

    /// Cross section needs the probe area as well, and gives its mass thickness; Cliff-Lorimer gives none and says so.
    /// Red under: the probe area left out of the setup; a mass-thickness tile for Cliff-Lorimer.
    @MainActor func testCrossSectionNeedsTheProbeAreaAndCliffLorimerHasNoMassThickness() async throws {
        let session = await openRoom()
        var typed = EDXTypedKDraft(elements: session.quantifiedSymbols, current: session.method)
        for i in typed.rows.indices { typed.rows[i].k = 1 + 0.1 * Double(i) }
        typed.source = "test"
        session.commitTypedK(typed, date: "2026-10-21")
        session.setMapMode(.massThickness)
        guard case .blocked(let none) = session.mapsState else { return XCTFail("\(session.mapsState)") }
        XCTAssertEqual(none, EDXQuantMaps.Refusal.noMassThickness.errorDescription)
        session.setMapMethod(.crossSection)
        setZeta(session, method: .crossSection)
        await session.settled()
        XCTAssertEqual(session.mapsState, .done)
        let maps = try XCTUnwrap(session.quantMaps)
        XCTAssertNotNil(maps.atoms)
        XCTAssertEqual(session.shownTiles.first?.mode, .massThickness)
        var draft = EDXFactorsDraft(method: .crossSection, elements: session.quantifiedSymbols, current: session.dose)
        draft.probeAreaNm2 = nil
        XCTAssertEqual(draft.incompleteReason, "Type the probe area.")
        session.setMapMethod(.cliffLorimer)
        guard case .blocked = session.mapsState else { return XCTFail("\(session.mapsState)") }
    }

    func testTheDoseSetupNamesWhatIsMissing() throws {
        var dose = EDXDoseInputs()
        let m = QuantificationMethod()
        XCTAssertThrowsError(try EDXQuantMaps.setup(method: m, mapMethod: .zeta, dose: dose, symbols: ["Al", "Si"])) {
            XCTAssertEqual($0 as? EDXQuantMaps.Refusal, .missingFactor(.zeta, ["Al", "Si"]))
        }
        dose.zeta = ["Al": 1, "Si": 2]
        XCTAssertThrowsError(try EDXQuantMaps.setup(method: m, mapMethod: .zeta, dose: dose, symbols: ["Al", "Si"])) { XCTAssertEqual($0 as? EDXQuantMaps.Refusal, .noSource) }
        dose.source = "x"
        XCTAssertThrowsError(try EDXQuantMaps.setup(method: m, mapMethod: .zeta, dose: dose, symbols: ["Al", "Si"])) { XCTAssertEqual($0 as? EDXQuantMaps.Refusal, .missingDose("beam current")) }
        dose.beamCurrentNA = 1
        XCTAssertThrowsError(try EDXQuantMaps.setup(method: m, mapMethod: .zeta, dose: dose, symbols: ["Al", "Si"])) { XCTAssertEqual($0 as? EDXQuantMaps.Refusal, .missingDose("live time")) }
        dose.liveTimeSeconds = 0.5
        let setup = try EDXQuantMaps.setup(method: m, mapMethod: .zeta, dose: dose, symbols: ["Al", "Si"])
        XCTAssertEqual(setup.method, .zeta(zetaFactors: [1, 2]))
        XCTAssertEqual(setup.beamCurrentNA, 1); XCTAssertEqual(setup.liveTimeSeconds, 0.5)
        dose.sectionsBarn = ["Al": 3, "Si": 4]
        XCTAssertThrowsError(try EDXQuantMaps.setup(method: m, mapMethod: .crossSection, dose: dose, symbols: ["Al", "Si"])) { XCTAssertEqual($0 as? EDXQuantMaps.Refusal, .missingDose("probe area")) }
        dose.probeAreaNm2 = 2
        XCTAssertEqual(try EDXQuantMaps.setup(method: m, mapMethod: .crossSection, dose: dose, symbols: ["Al", "Si"]).method, .crossSection(sectionsBarn: [3, 4], probeAreaNm2: 2))
    }

    // MARK: Files

    /// The spectrum as `.msa` is FormatoKit's writer: it reads back through FormatoKit's reader to the same counts and the same axis.
    /// Red under: counts rounded or reordered; the axis written in eV.
    @MainActor func testTheMSAFileReadsBackToTheSpectrum() async throws {
        let session = await openRoom()
        session.selectRectangle(PixelRect(x0: 0, y0: 0, x1: 1, y1: 1))
        await session.settled()
        let data = try XCTUnwrap(try session.spectrumMSA())
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("#FORMAT      : EMSA/MAS Spectral Data File\r\n"), String(text.prefix(60)))
        XCTAssertTrue(text.contains("#SIGNALTYPE  : EDS"), String(text.prefix(900)))
        XCTAssertTrue(text.contains("#BEAMKV"), "the beam energy is written: " + String(text.prefix(900)))
        let back = try MSAReader.parse(bytes: data, fileName: "x.msa")
        let axis = try XCTUnwrap(session.source).energyAxis
        XCTAssertEqual(back.signal.axes[0].size, Self.left.count)
        XCTAssertEqual(back.signal.axes[0].scale, axis.scale, accuracy: 1e-9)
        XCTAssertEqual(back.signal.axes[0].offset, axis.offset, accuracy: 1e-9)
        XCTAssertEqual(back.signal.data.doubles(), Self.left.map { Double($0) })
    }

    /// The scale bar comes from the file's pixel size through ImagoKit; none without one. The figure renders a PNG.
    /// Red under: a bar with no pixel size; a figure that is not a PNG.
    @MainActor func testTheFigureRendersAPNGWithItsScaleBar() async throws {
        XCTAssertNil(EDXExports.scaleBar(pixelSize: nil, unit: "nm", nx: 100, ny: 100))
        XCTAssertNil(EDXExports.scaleBar(pixelSize: 0.5, unit: nil, nx: 100, ny: 100))
        let bar = try XCTUnwrap(EDXExports.scaleBar(pixelSize: 0.5, unit: "nm", nx: 100, ny: 100))
        XCTAssertTrue(bar.fraction > 0 && bar.fraction < 1, "\(bar)")
        XCTAssertTrue(bar.label.hasSuffix("nm"), bar.label)

        let session = await openRoom()
        session.selectRectangle(PixelRect(x0: 0, y0: 0, x1: 1, y1: 1))
        await session.settled()
        let content = try XCTUnwrap(session.figureContent())
        XCTAssertEqual(content.tiles.count, session.tiles.count)
        let png = try XCTUnwrap(EDXMapsFigure.png(content))
        XCTAssertEqual(Array(png.prefix(8)), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        XCTAssertGreaterThan(png.count, 500)
        // With and without the scale bar: two different pictures. Red under: the toggles not reaching the figure.
        let bare = try XCTUnwrap(session.figureContent(scaleBar: false, regions: false))
        XCTAssertFalse(bare.showsScaleBar); XCTAssertFalse(bare.showsRegion)
        XCTAssertNotEqual(try XCTUnwrap(EDXMapsFigure.png(bare)), png)
    }
}
