//
//  EDXMapsTests.swift
//  The EDX room's composition maps (wt%, at%), typed k-factors and Stop: `EDXQuantMaps` and `EDXTypedKDraft` (TEMCore) and the
//  maps pass of `EDXSession` (TEMSession), on EDXSessionTests' planted two-pixel Al-Mg-Si image.
//
//  WHAT IS PINNED (D12, D17): the room has no arithmetic of its own, so a map pixel equals the kit's `EDXQuantification.quantify`
//  on that pixel's net counts to the bit; the composition sums to 100; the same room's pooled fit with the same typed k lands within
//  a written bound of the map (two estimators of the same areas: the fit's and the window's). The kit's own gates (SpectroKit
//  docs/parity.md) are the reference for the kit's numbers; these tests are the room's wiring.
//

import XCTest
import SpectroCore
import SpectroEDX
import TEMCore
import TEMSession
@testable import macTEM

nonisolated final class EDXMapsTests: XCTestCase {

    /// Arbitrary positive Cliff-Lorimer k-factors (Si as the unit): the test is of wiring, the values are not a reference.
    static let k: [String: Double] = ["Al": 1.12, "Mg": 1.31, "Si": 1.0]
    static let source = "test k-factors (EDXMapsTests)"

    @MainActor private func openRoom() async -> EDXSession {
        let session = EDXSession()
        await session.bind(EDXSessionTests.source()).value
        await session.settled()
        return session
    }

    @MainActor private func type(_ session: EDXSession, source: String = EDXMapsTests.source) {
        var draft = EDXTypedKDraft(elements: session.quantifiedSymbols, current: session.method)
        for i in draft.rows.indices { draft.rows[i].k = Self.k[draft.rows[i].element] ?? 1.0 }
        draft.source = source
        session.commitTypedK(draft, date: "2026-10-21")
    }

    /// The net-count maps of the quantified elements, the way the room hands them to the kit.
    @MainActor private func nets(_ session: EDXSession, _ symbols: [String]) throws -> [[Double]] {
        try symbols.map { s in try XCTUnwrap(session.tiles.first { $0.symbol == s }, s).values }
    }

    // MARK: The maps are the kit's

    /// With typed k, wt% and at% maps are the kit's per-pixel Cliff-Lorimer on the net-count maps, to the bit; the tiles carry the
    /// kit's values, the k source and the badge; at% is the conversion of the same wt% pixel. Red under: arithmetic of the room's
    /// own; the wrong element order; the badge missing from a footer.
    @MainActor func testTypedKMapsAreTheKitsPerPixelQuantification() async throws {
        let session = await openRoom()
        type(session)
        session.setMapMode(.weight)
        await session.settled()
        XCTAssertEqual(session.mapsState, .done)
        let maps = try XCTUnwrap(session.quantMaps)
        XCTAssertTrue(Set(maps.elements).isSuperset(of: ["Al", "Mg", "Si"]))
        XCTAssertEqual(maps.validation, "none")

        let net = try nets(session, maps.elements)
        let setup = EDXQuantificationSetup(elements: maps.elements, method: .cliffLorimer(kFactors: maps.elements.map { Self.k[$0] ?? 1.0 }, thicknessNm: nil))
        for p in 0..<2 {
            let direct = try EDXQuantification.quantify(intensities: net.map { $0[p] }, setup: setup)
            for e in maps.elements.indices {
                XCTAssertEqual(maps.weightPercent[e][p], direct.weightPercent[e], "\(maps.elements[e]) wt% at pixel \(p)")
                XCTAssertEqual(maps.atomicPercent[e][p], direct.atomicPercent[e], "\(maps.elements[e]) at% at pixel \(p)")
            }
            XCTAssertEqual(maps.weightPercent.reduce(0) { $0 + $1[p] }, 100, accuracy: 1e-9, "wt% sums to 100")
            XCTAssertEqual(maps.atomicPercent.reduce(0) { $0 + $1[p] }, 100, accuracy: 1e-9, "at% sums to 100")
        }

        XCTAssertEqual(session.shownTiles.map(\.symbol), maps.elements)
        for (i, tile) in session.shownTiles.enumerated() {
            XCTAssertEqual(tile.mode, .weight)
            XCTAssertEqual(tile.values, maps.weightPercent[i])
            let footer = try XCTUnwrap(tile.footer)
            XCTAssertTrue(footer.contains("validation: none"), footer)
            XCTAssertTrue(footer.contains("typed k: \(Self.source)"), footer)
            XCTAssertTrue(footer.contains("absorption not applied: type the thickness"), footer)
        }
        session.setMapMode(.atomic)
        XCTAssertEqual(session.mapsState, .done, "at% is the same pass: no second run")
        XCTAssertEqual(session.shownTiles.map(\.values), maps.atomicPercent)
        session.setMapMode(.net)
        XCTAssertEqual(session.shownTiles, session.tiles)
        XCTAssertTrue(session.shownTiles.allSatisfy { $0.mode == .net && $0.footer == nil })
    }

    /// One quantified spectrum and a small map against the previous path: the room's pooled fit of the left pixel with the same typed
    /// k, and the left pixel of the map. The two estimate the same line areas (the fit's, the window's), so they agree within the bound
    /// below, which is the fit's own bias on this spectrum (SpectroKit gates: areas within 3 % of planted) carried through the
    /// composition. Red under: the map using another k order than the fit; the fit ignoring the typed k.
    @MainActor func testMapAgreesWithThePooledFitOnTheSameTypedK() async throws {
        let session = await openRoom()
        type(session)
        session.selectRectangle(PixelRect(x0: 0, y0: 0, x1: 2, y1: 1))
        session.setMapMode(.weight)
        await session.settled()
        let maps = try XCTUnwrap(session.quantMaps)
        session.selectRectangle(PixelRect(x0: 0, y0: 0, x1: 1, y1: 1))
        await session.settled()
        await session.quantify()?.value
        await session.settled()
        let fit = try XCTUnwrap(session.fit, session.fitFailure ?? "no fit")
        XCTAssertEqual(fit.method.kFactorSource, .typed)
        XCTAssertEqual(fit.method.kSource, Self.source)
        let left = try XCTUnwrap(session.quantMaps)
        for row in fit.rows {
            guard let wt = row.weightPercent, let e = left.elements.firstIndex(of: row.element) else { continue }
            let delta = abs(wt - left.weightPercent[e][0])
            XCTContext.runActivity(named: "\(row.element): fit \(wt) wt%, map \(left.weightPercent[e][0]) wt%, delta \(delta)") { _ in }
            XCTAssertEqual(left.weightPercent[e][0], wt, accuracy: 0.5, "\(row.element) wt%")
        }
        _ = maps
    }

    // MARK: What the maps need

    /// The computed k comes from the fit: before Quantify the strip says so and the net tiles stay; once the fit has run the maps are
    /// the kit's per-pixel Cliff-Lorimer with the fit's own k, to the bit; switching to typed k follows. Red under: a guessed k;
    /// the maps not following the fit.
    @MainActor func testComputedKComesFromTheFit() async throws {
        let session = await openRoom()
        session.setMapMode(.atomic)
        guard case .blocked(let why) = session.mapsState else { return XCTFail("\(session.mapsState)") }
        XCTAssertTrue(why.contains("press Quantify"), why)
        XCTAssertEqual(session.shownTiles, session.tiles, "net tiles stay while the maps cannot be made")
        XCTAssertNil(session.quantMaps)

        await session.quantify()?.value
        await session.settled()
        XCTAssertEqual(session.mapsState, .done, "\(session.mapsState)")
        let fit = try XCTUnwrap(session.fit, session.fitFailure ?? "no fit")
        let fitK = try XCTUnwrap(fit.kFactors)
        let maps = try XCTUnwrap(session.quantMaps)
        let net = try nets(session, maps.elements)
        let setup = EDXQuantificationSetup(elements: maps.elements, method: .cliffLorimer(kFactors: maps.elements.map { s in fitK.first { $0.element == s }!.k }, thicknessNm: nil))
        for p in 0..<2 {
            let direct = try EDXQuantification.quantify(intensities: net.map { $0[p] }, setup: setup)
            for e in maps.elements.indices {
                XCTAssertEqual(maps.weightPercent[e][p], direct.weightPercent[e], "\(maps.elements[e]) wt% at pixel \(p)")
                XCTAssertEqual(maps.atomicPercent[e][p], direct.atomicPercent[e])
            }
        }
        let footer = try XCTUnwrap(session.shownTiles.first?.footer)
        XCTAssertTrue(footer.contains("computed k: ") && footer.contains("validation: none"), footer)

        type(session)
        await session.settled()
        XCTAssertTrue(try XCTUnwrap(session.shownTiles.first?.footer).contains("typed k: \(Self.source)"))
        session.setKFactorSource(.computed)
        await session.settled()
        XCTAssertTrue(try XCTUnwrap(session.shownTiles.first?.footer).contains("computed k: "), "back to the fit's k")
        session.selectRectangle(PixelRect(x0: 0, y0: 0, x1: 1, y1: 1))
        await session.settled()
        XCTAssertEqual(session.mapsState, .done)
        XCTAssertFalse(try XCTUnwrap(session.shownTiles.first?.footer).contains("masked px"), "a region never masks the maps")
    }

    /// With the file's geometry and a typed thickness the maps apply the kit's absorption (one take-off angle) and the footer says so;
    /// a mass thickness appears; without the geometry, or the thickness, it says why. Red under: absorption claimed but not passed
    /// to the kit; a Cliff-Lorimer mass-thickness tile with no correction.
    @MainActor func testAbsorptionIsAppliedToTheMapsWhenTheFileAndThicknessAllowIt() async throws {
        let session = EDXSession()
        await session.bind(EDXSessionTests.source(geometry: true)).value
        await session.settled()
        type(session)
        session.setMapMode(.weight)
        await session.settled()
        XCTAssertTrue(try XCTUnwrap(session.shownTiles.first?.footer).contains("absorption not applied: type the thickness"))
        session.changeMethod { $0.thickness = .init(nanometres: 80, sigmaNanometres: 8) }
        await session.settled()
        let footer = try XCTUnwrap(session.shownTiles.first?.footer)
        XCTAssertTrue(footer.contains("absorption applied (take-off "), footer)
        let maps = try XCTUnwrap(session.quantMaps)
        let angle = try EDXQuantification.takeOffDegrees(metadata: try XCTUnwrap(session.source).metadata)
        let net = try nets(session, maps.elements)
        let energies = try maps.elements.map { try XCTUnwrap(XRayLines.line("\($0)_Ka")?.energy) }
        let setup = EDXQuantificationSetup(elements: maps.elements, method: .cliffLorimer(kFactors: maps.elements.map { Self.k[$0] ?? 1.0 }, thicknessNm: 80),
                                           absorption: EDXAbsorptionSetting(takeOffDegrees: angle, lineEnergiesKeV: energies))
        let direct = try EDXQuantification.quantify(intensities: net.map { $0[0] }, setup: setup)
        for e in maps.elements.indices { XCTAssertEqual(maps.weightPercent[e][0], direct.weightPercent[e], "\(maps.elements[e])") }
        XCTAssertNotNil(maps.massThickness, "Cliff-Lorimer with absorption gives a mass thickness")
        session.setMapMode(.massThickness)
        XCTAssertEqual(session.shownTiles.first?.mode, .massThickness)

        let plain = await openRoom()
        type(plain)
        plain.changeMethod { $0.thickness = .init(nanometres: 80, sigmaNanometres: 8) }
        plain.setMapMode(.weight)
        await plain.settled()
        let why = try XCTUnwrap(plain.shownTiles.first?.footer)
        XCTAssertTrue(why.contains("absorption not applied: "), why)
        XCTAssertFalse(why.contains("type the thickness"), "the thickness is typed; the geometry is what is missing: \(why)")
    }

    /// A missing k names its element; a missing source is its own sentence; one quantified element is not a composition.
    /// Red under: a default k filled in; a source-less set accepted.
    func testTheSetupNamesWhatIsMissing() throws {
        var m = QuantificationMethod()
        m.kFactorSource = .typed
        m.typedK = [.init(element: "Al", k: 1.1)]
        XCTAssertThrowsError(try EDXQuantMaps.setup(method: m, symbols: ["Al", "Si"])) {
            XCTAssertEqual($0 as? EDXQuantMaps.Refusal, .missingK(["Si"]))
            XCTAssertEqual(($0 as? LocalizedError)?.errorDescription, "Type a k-factor for Si under Quantification.")
        }
        m.typedK.append(.init(element: "Si", k: 1.0))
        XCTAssertThrowsError(try EDXQuantMaps.setup(method: m, symbols: ["Al", "Si"])) { XCTAssertEqual($0 as? EDXQuantMaps.Refusal, .noSource) }
        m.kSource = "Williams and Carter, table 35.1"; m.kDate = "2026-10-21"
        XCTAssertThrowsError(try EDXQuantMaps.setup(method: m, symbols: ["Al"])) { XCTAssertEqual($0 as? EDXQuantMaps.Refusal, .tooFewElements(1)) }
        let setup = try EDXQuantMaps.setup(method: m, symbols: ["Al", "Si"])
        XCTAssertEqual(setup.elements, ["Al", "Si"])
        XCTAssertEqual(setup.method, .cliffLorimer(kFactors: [1.1, 1.0], thicknessNm: nil))
        XCTAssertNil(setup.absorption)
        m.kFactorSource = .computed
        XCTAssertThrowsError(try EDXQuantMaps.setup(method: m, symbols: ["Al", "Si"])) { XCTAssertEqual($0 as? EDXQuantMaps.Refusal, .needsFit) }
    }

    // MARK: Region, failures

    /// The maps cover the whole scan whatever the region: the region defines the results table and the fit, never the maps.
    /// Red under: the region passed to the composition pass as the mask (the pixel outside is 0 and the footer counts it).
    @MainActor func testTheMapsCoverTheWholeScanWhateverTheRegion() async throws {
        let session = await openRoom()
        type(session)
        session.selectRectangle(PixelRect(x0: 0, y0: 0, x1: 1, y1: 1))
        session.setMapMode(.weight)
        await session.settled()
        let maps = try XCTUnwrap(session.quantMaps)
        for e in maps.elements.indices {
            XCTAssertGreaterThan(maps.weightPercent[e][1], 0, "outside the region, still composed")
        }
        XCTAssertFalse(try XCTUnwrap(session.shownTiles.first?.footer).contains("masked px"))
    }

    /// A pixel the kit cannot quantify comes back NaN with its reason, counted in the footer, and the others are unaffected.
    /// Red under: the failure drawn as zero; the count or reason dropped.
    func testAFailedPixelIsNaNWithItsReasonInTheFooter() throws {
        var m = QuantificationMethod()
        m.kFactorSource = .typed
        m.typedK = [.init(element: "Al", k: 1.0), .init(element: "Si", k: 1.0)]
        m.kSource = "unit"; m.kDate = "2026-10-21"
        let setup = try EDXQuantMaps.setup(method: m, symbols: ["Al", "Si"])
        let maps = try EDXQuantMaps.run(maps: [[10, -5, 30], [10, 5, 10]], nx: 3, ny: 1, setup: setup, region: .wholeMap)
        XCTAssertTrue(maps.weightPercent[0][1].isNaN)
        XCTAssertNotNil(maps.failures[1])
        XCTAssertEqual(maps.weightPercent[0][0] + maps.weightPercent[1][0], 100, accuracy: 1e-9)
        let footer = EDXQuantMaps.footer(mode: .atomic, factorText: "typed k: unit", absorptionText: "absorption not applied to maps", result: maps, masked: 0)
        XCTAssertTrue(footer.contains("1 failed px: Intensities must be finite and not negative."), footer)
        XCTAssertTrue(footer.hasSuffix("validation: none"), footer)
        XCTAssertTrue(footer.hasPrefix("1 failed px: "), "the failed count leads, as mac4DSTEM's footer does: \(footer)")
        XCTAssertTrue(footer.contains("per-pixel, no \u{03C3}; pool a region for a \u{03C3} \u{00B7} at% \u{00B7} typed k: unit"), footer)
    }

    /// A NaN composition pixel is hatched, not black like a zero; a finite pixel is unchanged by the width.
    /// Red under: NaN drawn as zero (indistinguishable from a masked pixel).
    func testANaNPixelIsHatched() {
        let values: [Double] = [.nan, .nan, .nan, .nan, .nan, .nan, .nan, 10]
        let px = EDXMapRaster.rgba(values: values, hue: 0, width: 8)
        XCTAssertEqual(Array(px[0..<4]), [120, 120, 120, 255])
        XCTAssertEqual(Array(px[12..<16]), [40, 40, 40, 255], "stripes alternate every three pixels")
        XCTAssertEqual(px[28], 255, "the finite maximum is still full red")
        XCTAssertEqual(Array(EDXMapRaster.rgba(values: values, hue: 0)[0..<4]), [0, 0, 0, 255], "without a width: black as before")
    }

    // MARK: Typed k draft

    /// The sheet's draft commits only when every element has a positive k, no σ is negative and the source is named.
    /// Red under: Done enabled with a missing k or an empty source.
    func testTheDraftIsCompleteOnlyWithEveryKAndASource() {
        var d = EDXTypedKDraft(elements: ["Al", "Si"], current: QuantificationMethod())
        XCTAssertEqual(d.incompleteReason, "Type a positive k for Al, Si.")
        d.rows[0].k = 1.1
        XCTAssertEqual(d.incompleteReason, "Type a positive k for Si.")
        d.rows[1].k = 0
        XCTAssertEqual(d.incompleteReason, "Type a positive k for Si.", "zero is not a k")
        d.rows[1].k = 1.0
        XCTAssertEqual(d.incompleteReason, "Name where the k-factors come from.")
        d.source = "  \n"
        XCTAssertFalse(d.isComplete)
        d.source = "Williams and Carter"
        d.rows[1].sigmaPercent = -3
        XCTAssertEqual(d.incompleteReason, "σ of Si must not be negative.")
        d.rows[1].sigmaPercent = 10
        XCTAssertTrue(d.isComplete)
        XCTAssertEqual(d.entries, [.init(element: "Al", k: 1.1, relativeSigma: nil), .init(element: "Si", k: 1.0, relativeSigma: 0.1)])
    }

    /// Reopening the sheet shows what was typed; committing writes the method and the date; an incomplete draft writes nothing.
    @MainActor func testCommitWritesTheMethodAndReopeningShowsIt() async {
        let session = await openRoom()
        var bad = EDXTypedKDraft(elements: session.quantifiedSymbols, current: session.method)
        session.commitTypedK(bad, date: "2026-10-21")
        XCTAssertEqual(session.method.kFactorSource, .computed, "an incomplete draft writes nothing")
        type(session)
        XCTAssertEqual(session.method.kFactorSource, .typed)
        XCTAssertEqual(session.method.kDate, "2026-10-21")
        XCTAssertEqual(session.method.kSource, Self.source)
        bad = EDXTypedKDraft(elements: session.quantifiedSymbols, current: session.method)
        XCTAssertTrue(bad.isComplete, "the draft starts from the method")
        XCTAssertEqual(bad.rows.first { $0.element == "Al" }?.k, Self.k["Al"])
    }

    // MARK: Stop

    /// Stop ends an open's chain (the first spectrum, then Auto ID) and leaves the room usable. Red under: Auto ID starting after
    /// the stop; the busy flag left on.
    @MainActor func testStopEndsTheChainAfterAnOpen() async {
        let session = EDXSession()
        let chain = session.bind(EDXSessionTests.source())
        XCTAssertTrue(session.isBusy, "the first spectrum is being summed")
        session.stop()
        XCTAssertFalse(session.isBusy)
        await chain.value
        await session.settled()
        XCTAssertEqual(session.autoID, .idle, "Auto ID did not start after Stop")
        XCTAssertTrue(session.picks.isEmpty)
        session.selectWholeMap()   // no change: still whole map
        session.selectRectangle(PixelRect(x0: 0, y0: 0, x1: 1, y1: 1))
        await session.settled()
        XCTAssertEqual(session.spectrumCounts, EDXSessionTests.spectra().left.map { UInt64($0) }, "the room works after a Stop")
        await session.runAutoID()?.value
        await session.settled()
        XCTAssertTrue(Set(session.picks.map(\.symbol)).isSuperset(of: ["Al", "Mg", "Si"]))
        XCTAssertFalse(session.isBusy)
    }

    /// Stop on a running fit clears it with the reason (a half-made number is not shown), and Quantify runs it again.
    /// Red under: the previous fit left on screen; the fitting flag stuck.
    @MainActor func testStopOnAFitClearsItAndQuantifyRunsItAgain() async throws {
        let session = await openRoom()
        session.selectRectangle(PixelRect(x0: 0, y0: 0, x1: 1, y1: 1))
        await session.settled()
        session.quantify()
        XCTAssertTrue(session.isFitting)
        XCTAssertTrue(session.isBusy)
        session.stop()
        XCTAssertFalse(session.isFitting)
        XCTAssertFalse(session.isBusy)
        XCTAssertNil(session.fit)
        XCTAssertEqual(session.fitFailure, "Stopped.")
        await session.settled()
        XCTAssertNil(session.fit, "the stopped pass did not land")
        await session.quantify()?.value
        await session.settled()
        XCTAssertNotNil(session.fit)
        XCTAssertNil(session.fitFailure)
    }

    /// Stop with nothing running changes nothing.
    @MainActor func testStopWithNothingRunningIsANoOp() async {
        let session = await openRoom()
        var events: [String] = []
        session.onEvent = { events.append($0) }
        session.stop()
        XCTAssertTrue(events.isEmpty)
        XCTAssertFalse(session.picks.isEmpty)
    }

    // MARK: The display filter of the quantified maps (EDXMapFilter)

    /// A single 9 at the centre of a 3 × 3: the 3 × 3 average makes every pixel 1 (the window holds the centre; reflect keeps the edges inside the picture);
    /// off is the identity; a NaN pixel stays NaN and the others average over the finite ones only.
    func testTheKernelOnAKnownArray() {
        var a = [Double](repeating: 0, count: 9); a[4] = 9
        XCTAssertEqual(EDXMapFilter.mean3x3.apply(a, width: 3, height: 3), [Double](repeating: 1, count: 9))
        XCTAssertEqual(EDXMapFilter.off.apply(a, width: 3, height: 3), a)
        let gaussian = EDXMapFilter.gaussian1px.apply(a, width: 3, height: 3)
        XCTAssertEqual(gaussian.reduce(0, +), 9, accuracy: 1e-9, "a symmetric kernel with reflected edges keeps the total")
        XCTAssertLessThan(gaussian[4], 9); XCTAssertGreaterThan(gaussian[0], 0)
        var b = [Double](repeating: 2, count: 9); b[4] = .nan
        let out = EDXMapFilter.mean3x3.apply(b, width: 3, height: 3)
        XCTAssertTrue(out[4].isNaN, "a missing pixel is not invented")
        XCTAssertEqual(out.enumerated().filter { $0.offset != 4 }.map(\.element), [Double](repeating: 2, count: 8), "NaN is skipped, not counted as 0")
        XCTAssertEqual(EDXMapFilter.mean3x3.apply([1, 2], width: 3, height: 3), [1, 2], "a wrong shape is left alone")
    }

    func testTheDisplayRangeIsThe1stTo99thPercentile() throws {
        let values = (0...100).map(Double.init) + [.nan]
        let range = try XCTUnwrap(EDXMapFilter.displayRange(of: values))
        XCTAssertEqual(range.lowerBound, 1, accuracy: 1e-12); XCTAssertEqual(range.upperBound, 99, accuracy: 1e-12)
        XCTAssertNil(EDXMapFilter.displayRange(of: [3, 3, .nan]))
        XCTAssertNil(EDXMapFilter.displayRange(of: []))
    }
}
