//
//  ResultsLedgerEELSTests.swift
//  The Results room lists what the EELS room computed for the file: the thickness (the whole map's t/λ line and each drawn region's t/λ) and the
//  fitted edges (the whole map's summed fit and each region's), with the kit's numbers unchanged, its refusals in words, its caveats kept and
//  its validation word; and nothing while the room is recomputing or holds a result from before the person's last choice.
//
//  THE TRUTH: a 2 x 2 low loss whose pixels plant t/λ = 0.5 + 0.25 k (as `EELSRoomTests`, cut exactly by a fixed 2.5 eV threshold) beside a 2 x 2
//  power-law core loss from 600 eV with the Fe L3 and Cu L3 edges picked (as the window test there). The ledger makes no number (D12, D17): every
//  value is compared with the session's own field.
//

import XCTest
import ImagoCore
import ImagoFFT
import SpectroCore
import SpectroEDX
import SpectroEELS
import ShellEDXModel
import TEMCore
import TEMSession
@testable import macTEM

nonisolated final class ResultsLedgerEELSTests: XCTestCase {

    private static func image() -> CalibratedImage {
        CalibratedImage(width: 40, height: 30, pixels: (0..<1200).map { Float($0 % 97) }, x: AxisCalibration(scale: 0.5, unit: "nm", origin: 0),
                        y: AxisCalibration(scale: 0.5, unit: "nm", origin: 0), fileName: "si.dm4", source: "ImageList.1", voltage: nil)
    }

    private static func loaded(beam: Double? = 200) throws -> LoadedEELS {
        let nx = 2, ny = 2, lowChannels = 256
        var low = [Double](repeating: 0, count: nx * ny * lowChannels)
        for k in 0..<(nx * ny) {
            let base = k * lowChannels
            low[base + 9] = 300; low[base + 10] = 1400; low[base + 11] = 300
            let tail = 2000 * (exp(0.5 + 0.25 * Double(k)) - 1) / 100
            for c in 30..<130 { low[base + c] = tail }
        }
        let coreChannels = 400
        var core = [Double](repeating: 0, count: nx * ny * coreChannels)
        for p in 0..<(nx * ny) { for c in 0..<coreChannels { core[p * coreChannels + c] = 5e5 * pow((600 + Double(c)) / 600, -3) } }
        return LoadedEELS(fileName: "si.dm4",
                          image: try LowLossSpectrumImage(nx: nx, ny: ny, channels: lowChannels, counts: low, energyOffsetEV: -5, energyScaleEV: 0.5),
                          beamEnergyKeV: beam, convergenceMrad: 0, collectionMrad: 10, origin: "planted",
                          coreLoss: try CoreLossSpectrumImage(nx: nx, ny: ny, channels: coreChannels, counts: core, energyOffsetEV: 600, energyScaleEV: 1),
                          coreLossOrigin: "planted core", filePath: "/data/one/si.dm4")
    }

    /// The room after Thickness and Fit, with one region drawn.
    @MainActor private func fittedRoom() async throws -> EELSSession {
        let session = EELSSession()
        await session.bind(try Self.loaded()).value
        session.setThreshold(.fixed(2.5))
        await session.settled()
        session.drawRegion(.rectangle(PixelRect(x0: 0, y0: 0, x1: 1, y1: 2)))
        session.setConvolveLowLoss(false)
        session.toggleEdge(.ironL3); session.toggleEdge(.copperL3)
        await session.fit()?.value
        await session.settled()
        return session
    }

    @MainActor private func rows(_ eels: ResultsLedger.EELSResults?) -> [ResultRow] {
        let image = Self.image()
        let marks = ImageMeasurements()
        marks.add(ImageMark(kind: .distance, points: [ImagePoint(x: 0, y: 0), ImagePoint(x: 3, y: 4)]), on: image)
        return ResultsLedger.rows(image: image, measurements: marks, analysis: FFTAnalysis(), eels: eels)
    }

    /// A settled EELS room is listed after the image's groups: the thickness (the whole map's median and quartiles of the kit's per-pixel t/λ,
    /// then the region's t/λ of its summed spectrum), then every fitted edge of the whole map and of the region, each with the kit's own I, sigma,
    /// at% and wt% and the result's validation word. Red under: the ledger ignoring the EELS room; a number taken from another row or region.
    @MainActor func testASettledEELSRoomIsListedThicknessThenEdgesWithTheKitsNumbers() async throws {
        let session = try await fittedRoom()
        let map = try XCTUnwrap(session.map, session.failure ?? "no map")
        let model = try XCTUnwrap(session.regionModel, session.failure ?? session.fitRefusal ?? "no fit")
        XCTAssertEqual(map.validation, ResultRow.Product.eelsKitValidation, "the kit's own word is the badge's")
        XCTAssertEqual(model.validation, ResultRow.Product.eelsKitValidation, "the kit's own word is the badge's")
        let region = try XCTUnwrap(session.pinRows.first, "the region has its row")
        XCTAssertFalse(region.edges.isEmpty, "the region was fitted")

        let listed = rows(try XCTUnwrap(ResultsLedger.EELSResults.settled(session)))
        XCTAssertEqual(listed.first?.group, .marks, "the image's groups first")
        XCTAssertEqual(listed.map(\.group).filter { $0 != .marks }, [.eelsThickness, .eelsThickness] + Array(repeating: .eelsEdges, count: 2 * 2))

        let thickness = listed.filter { $0.group == .eelsThickness }
        // A failure, not a crash of the test host, when the rows are missing.
        guard thickness.count == 2 else { return XCTFail("the thickness rows: \(thickness.map(\.label))") }
        let stats = try XCTUnwrap(EELSThicknessStats.of(map, region: nil))
        XCTAssertEqual(thickness[0].label, "t/λ · Whole map")
        XCTAssertEqual(thickness[0].entry("t_over_lambda")?.value, stats.median)
        XCTAssertEqual(thickness[0].entry("t_over_lambda_q1")?.value, stats.q1)
        XCTAssertEqual(thickness[0].entry("t_over_lambda_q3")?.value, stats.q3)
        XCTAssertEqual(thickness[0].entry("pixels")?.value, 4)
        XCTAssertNil(thickness[0].entry("thickness")?.value, "no λ: no t")
        XCTAssertEqual(thickness[0].entry("thickness")?.text, ResultRow.eelsNeedsLambda)
        XCTAssertEqual(thickness[0].entry("validation")?.text, map.validation)
        XCTAssertEqual(thickness[1].label, "t/λ · \(region.pin.name)")
        XCTAssertEqual(thickness[1].entry("t_over_lambda")?.value, region.tOverLambda)
        XCTAssertEqual(thickness[1].entry("pixels")?.value, Double(region.pixels))
        let en = Locale(identifier: "en_US")
        XCTAssertEqual(ResultsFormat.value(thickness[0], x: nil, y: nil, locale: en),
                       "t/λ \(EELSRoomFormat.fixed(stats.median, 3, locale: en)) (IQR \(EELSRoomFormat.fixed(stats.q1, 3, locale: en))–"
                       + "\(EELSRoomFormat.fixed(stats.q3, 3, locale: en))) · t needs λ")
        XCTAssertEqual(ResultsFormat.source(thickness[1], imageWidth: 40, imageHeight: 30), "EELS · \(region.pin.name)")

        let edges = listed.filter { $0.group == .eelsEdges }
        let expected = session.regionRows.map { ($0, "Whole map") } + region.edges.map { ($0, region.pin.name) }
        XCTAssertEqual(edges.map(\.label), expected.map { "\($0.0.title) · \($0.1)" })
        for (row, (kit, place)) in zip(edges, expected) {
            XCTAssertEqual(row.product, .eelsEdge)
            XCTAssertEqual(row.refusal, kit.unavailable, row.label)
            if kit.unavailable == nil {
                XCTAssertEqual(row.entry("intensity")?.value, kit.intensity, row.label)
                XCTAssertEqual(row.entry("intensity_sigma")?.value, kit.intensityStd, row.label)
                XCTAssertEqual(row.entry("at")?.value, kit.atomicPercent, row.label)
                XCTAssertEqual(row.entry("wt")?.value, kit.weightPercent, row.label)
                XCTAssertEqual(row.entry("exponent_r")?.value, kit.exponent, row.label)
            }
            XCTAssertEqual(row.entry("onset")?.value, kit.onsetEV, row.label)
            XCTAssertEqual(row.entry("region")?.text, place)
            XCTAssertEqual(row.entry("validation")?.text, model.validation)
            XCTAssertEqual(ResultsFormat.source(row, imageWidth: 40, imageHeight: 30), "EELS · \(place)")
        }
        XCTAssertTrue(rows(nil).allSatisfy { $0.group == .marks }, "no EELS room: no EELS row")
    }

    /// Nothing from before the last choice: a pick changed and not yet fitted drops the edges and keeps the thickness; a threshold being recomputed drops
    /// everything until it lands; a refused λ (the beam energy unknown) lists nothing, as the old map stays on screen there. Red under: the old fit
    /// listed after a new pick; the map listed while it is being made again; the map from before a refusal listed under it.
    @MainActor func testNothingStaleIsListedWhileTheRoomRecomputesOrRefuses() async throws {
        let session = try await fittedRoom()
        XCTAssertNotNil(ResultsLedger.EELSResults.settled(session)?.edges.first)
        session.toggleEdge(.copperL3)   // unpicked: the fit on screen is of Fe and Cu
        XCTAssertEqual(session.fitState, .stale)
        let picked = try XCTUnwrap(ResultsLedger.EELSResults.settled(session), "the thickness is still current")
        XCTAssertTrue(picked.edges.isEmpty, "a fit from before the pick is not listed")
        XCTAssertFalse(picked.regionEdges)
        XCTAssertNotNil(picked.map)
        XCTAssertTrue(rows(picked).allSatisfy { $0.group != .eelsEdges })

        session.setThreshold(.fixed(3))
        XCTAssertTrue(session.isComputing)
        XCTAssertNil(ResultsLedger.EELSResults.settled(session), "nothing while the map is made again")
        await session.settled()
        XCTAssertNotNil(ResultsLedger.EELSResults.settled(session)?.map)

        let blind = EELSSession()
        await blind.bind(try Self.loaded(beam: nil)).value
        await blind.settled()
        XCTAssertNotNil(ResultsLedger.EELSResults.settled(blind)?.map)
        blind.setMeanFreePath(.iakoubovskii(density: 2.3, convergenceMrad: 0, collectionMrad: 10))
        await blind.settled()
        XCTAssertNotNil(blind.failure, "the λ estimate needs the beam energy")
        XCTAssertNotNil(blind.map, "the room keeps the previous map")
        XCTAssertNil(ResultsLedger.EELSResults.settled(blind), "the previous map is not listed under the refused choice")
    }

    /// A pass stopped mid-way leaves the previous map on screen: it is stale (Run makes it again) and not listed under the new threshold; a
    /// region refitted while an edge was unpicked is not listed beside a fit of both edges once the edge is picked again; a rename made while
    /// the regions are computed is kept when they land. Red under: the map compared by its cube alone; the regions' rows without the inputs
    /// they were made from; the landing rows written over the rename.
    @MainActor func testAStoppedPassAndARegionFromAnotherPickAreNotListed() async throws {
        let session = try await fittedRoom()
        session.setThreshold(.fixed(3))
        session.stop()
        XCTAssertFalse(session.isBusy)
        XCTAssertNil(session.failure)
        XCTAssertEqual(session.thicknessState, .stale, "the map is of the 2.5 eV threshold")
        XCTAssertNil(ResultsLedger.EELSResults.settled(session)?.map, "the old map is not listed under the new threshold")
        session.setThreshold(.fixed(2.5))
        await session.settled()
        XCTAssertNotNil(ResultsLedger.EELSResults.settled(session)?.map)

        session.toggleEdge(.copperL3)
        let pin = try XCTUnwrap(session.drawRegion(.rectangle(PixelRect(x0: 1, y0: 0, x1: 2, y1: 2))))
        session.renamePin(pin.id, to: "Right half")
        await session.settled()
        XCTAssertEqual(session.pinRows.last?.pin.name, "Right half", "the rename made while the rows were computed is kept")
        session.toggleEdge(.copperL3)
        XCTAssertEqual(session.fitState, .current, "the same picks as the fit on screen")
        let back = try XCTUnwrap(ResultsLedger.EELSResults.settled(session))
        XCTAssertFalse(back.edges.isEmpty)
        XCTAssertFalse(back.regionEdges, "the regions were fitted with Fe alone")
        XCTAssertTrue(rows(back).filter { $0.group == .eelsEdges }.allSatisfy { $0.entry("region")?.text == "Whole map" })
    }

    /// The kit's refusals and flags reach the row in words and never as a 0: an edge the kit could not fit has its reason and no number; an at%
    /// the room has not got says why; an edge at or under 3 sigma says it is below detection; the sigma's caveat and an exponent at its bound are kept;
    /// a region with no t/λ has the kit's reason. Red under: a refused edge's I written as a number; the below-detection row shown as an at%.
    @MainActor func testTheEELSRowsKeepTheKitsRefusalsAndFlags() {
        let en = Locale(identifier: "en_US")
        let why = EELSFitCompute.words(.fitFailed)
        XCTAssertNotEqual(why, "fitFailed", "the kit's case in words, not its name")
        let failed = EELSEdgeRow(id: "Fe-L3", title: "Fe L3", onsetEV: 708, intensity: 0, arealDensityPerNM2: nil, atomicPercent: nil, weightPercent: nil,
                                 unavailable: why, intensityStd: 0, atomicUnavailable: why)
        let refused = ResultRow.eelsEdge(id: "r", row: failed, regionName: "Whole map", validation: "none")
        XCTAssertEqual(refused.refusal, why)
        XCTAssertNil(refused.entry("intensity")?.value)
        XCTAssertNil(refused.entry("intensity_sigma")?.value)
        XCTAssertEqual(ResultsFormat.value(refused, x: nil, y: nil, locale: en), "The edge model could not be fitted (the least-squares solve failed or the spectrum has no support)")

        let weak = EELSEdgeRow(id: "Cu-L3", title: "Cu L3", onsetEV: 931, intensity: 2, arealDensityPerNM2: nil, atomicPercent: 3.1, weightPercent: 6.2,
                               unavailable: nil, intensityStd: 1, exponentAtBound: true)
        let below = ResultRow.eelsEdge(id: "b", row: weak, regionName: "Whole map", validation: "none")
        XCTAssertEqual(below.entry("below_detection")?.text, ResultRow.eelsBelowDetection)
        XCTAssertEqual(ResultsFormat.eelsEdgeValue(below, locale: en), "I 2 ± 1 · below detection")
        XCTAssertEqual(below.entry("caveat")?.text, ResultRow.eelsSigmaCaveat)
        XCTAssertEqual(below.entry("exponent_at_bound")?.text, ResultRow.eelsExponentAtBound)

        let alone = EELSEdgeRow(id: "C-K1", title: "C K", onsetEV: 284, intensity: 4.3e7, arealDensityPerNM2: nil, atomicPercent: nil, weightPercent: nil,
                                unavailable: nil, intensityStd: 2.1e5, atomicUnavailable: EELSEdgeRow.atomicNeedsTwo)
        let one = ResultRow.eelsEdge(id: "o", row: alone, regionName: "Whole map", validation: "none")
        XCTAssertEqual(ResultsFormat.eelsEdgeValue(one, locale: en), "I 4.3e7 ± 2.1e5 · at%: " + EELSEdgeRow.atomicNeedsTwo)

        let pin = EDXPin(name: "Region 1", region: .rectangle(PixelRect(x0: 0, y0: 0, x1: 1, y1: 1)), number: 1)
        let dark = EELSRegionRow(pin: pin, pixels: 1, totalCounts: 0, tOverLambda: nil, edges: [], tUnavailable: "I_0 <= 0")
        let noT = ResultRow.eelsRegionThickness(id: "t", row: dark, validation: "none")
        XCTAssertEqual(noT.refusal, "I_0 <= 0")
        XCTAssertNil(noT.entry("t_over_lambda")?.value)

        // A region whose edge fit the kit refused as a whole is one row with the kit's words, not silently no row.
        let windowless = EELSRegionRow(pin: pin, pixels: 1, totalCounts: 10, tOverLambda: 0.5, edges: [], edgesUnavailable: "Fe L: signal window holds 1 channels, needs 2.")
        let listed = rows(ResultsLedger.EELSResults(map: nil, lambdaSource: nil, edges: [], fitValidation: "none", regions: [windowless],
                                                    regionThickness: false, regionEdges: true)).filter { $0.group == .eelsEdges }
        XCTAssertEqual(listed.map(\.label), ["Edges · Region 1"])
        XCTAssertEqual(listed.first?.refusal, "Fe L: signal window holds 1 channels, needs 2.")
    }

    /// A one-element fit says why it has no at% in the room's words (EELSFitCompute.rows), and the region row keeps the kit's reason for a missing
    /// t/λ (EELSRegionCompute.row). Red under: the reason dropped, so the Results room could only show a dash.
    @MainActor func testTheRoomsRowsCarryWhyAValueIsMissing() async throws {
        let session = EELSSession()
        await session.bind(try Self.loaded()).value
        session.setThreshold(.fixed(2.5))
        await session.settled()
        session.setConvolveLowLoss(false)
        session.toggleEdge(.ironL3)
        await session.fit()?.value
        await session.settled()
        let row = try XCTUnwrap(session.regionRows.first, session.failure ?? session.fitRefusal ?? "no fit")
        XCTAssertNil(row.atomicPercent)
        XCTAssertEqual(row.atomicUnavailable, EELSEdgeRow.atomicNeedsTwo)

        let empty = try LowLossSpectrumImage(nx: 1, ny: 1, channels: 64, counts: [Double](repeating: 0, count: 64), energyOffsetEV: -5, energyScaleEV: 0.5)
        let pin = EDXPin(name: "Region 1", region: .rectangle(PixelRect(x0: 0, y0: 0, x1: 1, y1: 1)), number: 1)
        let dark = try XCTUnwrap(EELSRegionCompute.row(pin: pin, low: empty, core: nil, edges: [], microscope: nil, convolve: false,
                                                       threshold: .fixed(2.5), meanFreePath: nil))
        XCTAssertNil(dark.tOverLambda)
        XCTAssertFalse((dark.tUnavailable ?? "").isEmpty, "the kit's reason is kept")
    }

    /// The EELS room holds one file: its results belong to the item whose file opened into the room and is the one it holds, told apart from a
    /// file of the same name in another folder by its path. Red under: another file's results listed under this one.
    func testTheEELSResultsAreListedOnlyUnderTheirOwnFile() {
        let a = URL(fileURLWithPath: "/data/one/si.dm4"), twin = URL(fileURLWithPath: "/data/two/si.dm4")
        XCTAssertTrue(AppState.eelsResultsBelong(to: a, eelsFiles: [a, twin], eelsFile: "si.dm4", eelsPath: a.path, eelsOpening: false))
        XCTAssertFalse(AppState.eelsResultsBelong(to: twin, eelsFiles: [a, twin], eelsFile: "si.dm4", eelsPath: a.path, eelsOpening: false))
        XCTAssertFalse(AppState.eelsResultsBelong(to: a, eelsFiles: [], eelsFile: "si.dm4", eelsPath: a.path, eelsOpening: false), "a did not open in the EELS room")
        XCTAssertFalse(AppState.eelsResultsBelong(to: a, eelsFiles: [a], eelsFile: "si.dm4", eelsPath: a.path, eelsOpening: true), "the room is opening")
    }
}
