//
//  ResultsLedgerTests.swift
//  The Results room's ledger (`ResultsLedger`; TEMSession): the rows of a file's marks and FFT spots, derived from
//  their owners and never stored — marks in creation order with the owner's own numbers and their lineage node, spots as the FFT
//  room numbered them, a refused spot and one with no peak listed with their reasons, a spot still measuring absent, the region a spot
//  was made on, the groups in their order, the next call answering for a mark removed or moved. Tier 2.
//
//  Mutations sampled (each alone, the named test went red): a spot still measuring listed (the measuring test); the marks' order
//  reversed (the order test); a removed mark kept in a cache (the derived test); the spot's region taken from the room's current
//  region instead of its own key (the region test); the lineage node dropped (the marks test).
//

import XCTest
import FormatoCore
import TEMCore
import TEMSession
import ImagoFFT
import ImagoCore
import ShellEDXModel
import SpectroEDX
@testable import macTEM

nonisolated final class ResultsLedgerTests: XCTestCase {

    private static let nmX = AxisCalibration(scale: 0.5, unit: "nm", origin: 0)
    private static let nmY = AxisCalibration(scale: 0.8, unit: "nm", origin: 0)

    nonisolated private static func image(width: Int = 40, height: Int = 30, x: AxisCalibration? = ResultsLedgerTests.nmX,
                                          y: AxisCalibration? = ResultsLedgerTests.nmY, fileName: String = "scan.dm4") -> CalibratedImage {
        CalibratedImage(width: width, height: height, pixels: (0..<width * height).map { Float($0 % 97) }, x: x, y: y,
                        fileName: fileName, source: "ImageList.1", voltage: nil)
    }

    @MainActor private func idle() -> FFTAnalysis { FFTAnalysis() }

    // MARK: Marks

    /// Marks in creation order, each with the owner's own numbers, a label numbered within its kind, a stable id and its lineage node.
    /// Red under: the order reversed; the lineage dropped; the numbering shared between kinds; a length not the owner's.
    @MainActor func testMarksAreListedInCreationOrderWithTheOwnersNumbers() throws {
        let image = Self.image()
        let owner = ImageMeasurements()
        owner.add(ImageMark(kind: .distance, points: [ImagePoint(x: 2, y: 3), ImagePoint(x: 14.5, y: 20.25)]), on: image)
        owner.add(ImageMark(kind: .angle, points: [ImagePoint(x: 5, y: 5), ImagePoint(x: 10, y: 10), ImagePoint(x: 20, y: 6)]), on: image)
        owner.add(ImageMark(kind: .profile, points: [ImagePoint(x: 1, y: 1), ImagePoint(x: 30, y: 12)], width: 3), on: image)
        owner.add(ImageMark(kind: .distance, points: [ImagePoint(x: 0, y: 0), ImagePoint(x: 3, y: 4)]), on: image)

        let rows = ResultsLedger.rows(image: image, measurements: owner, analysis: idle())
        XCTAssertEqual(rows.map(\.label), ["Distance 1", "Angle 1", "Profile 1", "Distance 2"])
        XCTAssertEqual(rows.map(\.product), [.distance, .angle, .profile, .distance])
        XCTAssertEqual(rows.map(\.id), owner.marks.map { "mark:\($0.id.uuidString)" })
        XCTAssertEqual(rows.map(\.lineage), owner.marks.map { owner.nodeID(of: $0.id) })
        XCTAssertTrue(rows.allSatisfy { $0.lineage != nil }, "every mark has a node in the record")

        let first = ImageMeasurement.distance(ImagePoint(x: 2, y: 3), ImagePoint(x: 14.5, y: 20.25), x: Self.nmX, y: Self.nmY)
        XCTAssertEqual(rows[0].entry("length_px")?.value, first.pixels)
        XCTAssertEqual(rows[0].entry("length")?.value, first.physical)
        XCTAssertEqual(rows[0].entry("length")?.unit, "nm")
        let angle = ImageMeasurement.angle(ImagePoint(x: 5, y: 5), vertex: ImagePoint(x: 10, y: 10), ImagePoint(x: 20, y: 6),
                                           x: Self.nmX, y: Self.nmY)
        XCTAssertEqual(rows[1].entry("angle")?.value, angle?.degrees)
        XCTAssertEqual(rows[2].entry("width")?.value, 3)
        XCTAssertEqual(rows[3].entry("length_px")?.value, 5, "(0,0) to (3,4)")
        XCTAssertTrue(rows.allSatisfy { $0.group == .marks })
    }

    /// An uncalibrated image gives pixels only, and an angle on its pixel grid says so. Red under: a physical length invented.
    @MainActor func testAnUncalibratedImageGivesPixelsOnly() {
        let image = Self.image(x: nil, y: nil)
        let owner = ImageMeasurements()
        owner.add(ImageMark(kind: .distance, points: [ImagePoint(x: 0, y: 0), ImagePoint(x: 3, y: 4)]), on: image)
        owner.add(ImageMark(kind: .angle, points: [ImagePoint(x: 5, y: 5), ImagePoint(x: 10, y: 10), ImagePoint(x: 20, y: 6)]), on: image)
        let rows = ResultsLedger.rows(image: image, measurements: owner, analysis: idle())
        XCTAssertNil(rows[0].entry("length"))
        XCTAssertEqual(rows[0].entry("length_px")?.value, 5)
        XCTAssertEqual(rows[1].entry("angle")?.text, "taken on the pixel grid")
    }

    /// DERIVED, NEVER STORED: removing a mark or moving an end changes the next call, and two calls on one state agree. Red under:
    /// the ledger caching its rows.
    @MainActor func testTheLedgerIsDerivedNotStored() throws {
        let image = Self.image()
        let owner = ImageMeasurements()
        owner.add(ImageMark(kind: .distance, points: [ImagePoint(x: 0, y: 0), ImagePoint(x: 3, y: 4)]), on: image)
        owner.add(ImageMark(kind: .distance, points: [ImagePoint(x: 0, y: 0), ImagePoint(x: 6, y: 8)]), on: image)
        let analysis = idle()
        let before = ResultsLedger.rows(image: image, measurements: owner, analysis: analysis)
        XCTAssertEqual(before, ResultsLedger.rows(image: image, measurements: owner, analysis: analysis))
        XCTAssertEqual(before.count, 2)

        owner.move(owner.marks[0].id, point: 1, to: ImagePoint(x: 6, y: 8), on: image)
        let moved = ResultsLedger.rows(image: image, measurements: owner, analysis: analysis)
        XCTAssertEqual(moved[0].entry("length_px")?.value, 10)
        XCTAssertEqual(moved[0].id, before[0].id, "the id stands while the measurement stands")

        owner.remove(owner.marks[0].id)
        let after = ResultsLedger.rows(image: image, measurements: owner, analysis: analysis)
        XCTAssertEqual(after.map(\.id), [before[1].id])
        XCTAssertEqual(after[0].label, "Distance 1", "the numbering follows the marks that are there")
        owner.removeAll()
        XCTAssertTrue(ResultsLedger.rows(image: image, measurements: owner, analysis: analysis).isEmpty)
    }

    /// An angle whose arm has zero length is listed with its reason and no angle (a result a reader needs). Red under: the row
    /// dropped; the reason lost.
    @MainActor func testAnAngleWithAnArmOfZeroLengthIsListedWithItsReason() {
        let image = Self.image()
        let owner = ImageMeasurements()
        owner.add(ImageMark(kind: .angle, points: [ImagePoint(x: 5, y: 5), ImagePoint(x: 5, y: 5), ImagePoint(x: 9, y: 2)]), on: image)
        let rows = ResultsLedger.rows(image: image, measurements: owner, analysis: idle())
        XCTAssertEqual(rows.count, 1)
        XCTAssertNil(rows[0].entry("angle"))
        XCTAssertEqual(rows[0].refusal, "no angle: an arm has zero length")
    }

    // MARK: Spots

    /// A rig whose owner shows the plant on region A with its spectrum landed; its spot jobs are parked for the test to answer.
    @MainActor private func landedRig(region: PixelCrop? = FFTAnalysisTests.regionA) async throws -> FFTAnalysisTests.Rig {
        let rig = FFTAnalysisTests.Rig()
        addTeardownBlock { await rig.drain() }
        rig.owner.setRegion(region, committed: true)
        rig.owner.show(FFTAnalysisTests.plant(), contentVersion: 1)
        try await until("the spectrum is asked for") { await rig.spectra.asked.count == 1 }
        await rig.finishSpectrum(0)
        try await until("the spectrum lands") { rig.owner.isSpectrumCurrent }
        return rig
    }

    @MainActor private func until(_ what: String, _ condition: @MainActor () async -> Bool) async throws {
        for _ in 0..<1600 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("timed out waiting for: \(what)")
        throw FFTAnalysisTests.TimedOut()
    }

    /// Four clicks: a measurement, a refusal, a click with no peak, and one still measuring. The first three are listed in the order
    /// the FFT room numbered them, the last is absent; the refused two carry their reasons and no number. Red under: a spot still
    /// measuring listed; a refusal dropped; a measured row without the estimator's d.
    @MainActor func testSpotsAreListedMeasuredRefusedAndNoPeakNotMeasuring() async throws {
        let rig = try await landedRig()
        let image = FFTAnalysisTests.plant()
        for (n, click) in [(37, 40), (31, 33), (29, 44), (20, 50)].enumerated() {
            rig.owner.measureSpot(row: click.0, col: click.1)
            try await until("click \(n) is asked for") { await rig.spotJobs.asked.count == n + 1 }
            if n == 0 { await rig.spotJobs.finish(0, .success(.measured(try FFTAnalysisTests.measured(row: 37, col: 40)))) }
            if n == 1 { await rig.spotJobs.finish(1, .success(.refused(.nearDC))) }
            if n == 2 { await rig.spotJobs.finish(2, .success(.refused(.noPower))) }
            // n == 3 stays parked: the spot is still measuring.
        }
        try await until("the first three are answered") {
            rig.owner.spots.count == 4 && rig.owner.spots.prefix(3).allSatisfy { if case .measuring = $0.outcome { false } else { true } }
        }
        let rows = ResultsLedger.rows(image: image, measurements: ImageMeasurements(), analysis: rig.owner)
        XCTAssertEqual(rows.map(\.label), ["Spot 1", "Spot 2", "Spot 3"], "the fourth is still measuring: it has no result yet")
        XCTAssertEqual(rows.map(\.id), rig.owner.spots.prefix(3).map { "spot:\($0.id.uuidString)" })
        XCTAssertTrue(rows.allSatisfy { $0.product == .spot && $0.group == .spots && $0.lineage == nil })

        let m = try FFTAnalysisTests.measured(row: 37, col: 40)
        XCTAssertEqual(rows[0].entry("d")?.value, m.d)
        XCTAssertEqual(rows[0].entry("q")?.value, m.q)
        XCTAssertNil(rows[0].refusal)
        XCTAssertEqual(rows[1].refusal, ResultRow.reason(.nearDC))
        XCTAssertNil(rows[1].entry("d"))
        XCTAssertEqual(rows[1].entry("click_row")?.value, 31)
        XCTAssertEqual(rows[1].entry("click_col")?.value, 33)
        XCTAssertEqual(rows[2].refusal, ResultRow.reason(.noPower), "the kit's reason, not an app sentence")

        // The fourth lands: the next call lists it, in place, nothing else changed.
        await rig.spotJobs.finish(3, .success(.measured(try FFTAnalysisTests.measured(row: 20, col: 50))))
        try await until("the fourth is answered") { rig.owner.spots.count == 4 && !rig.owner.spots.contains { if case .measuring = $0.outcome { true } else { false } } }
        let later = ResultsLedger.rows(image: image, measurements: ImageMeasurements(), analysis: rig.owner)
        XCTAssertEqual(later.map(\.label), ["Spot 1", "Spot 2", "Spot 3", "Spot 4"])
        XCTAssertEqual(Array(later.prefix(3)), rows)
    }

    /// A spot carries the region its own spectrum was transformed from; no region is the whole image. Red under: the region read
    /// from the room's current one; the whole image given a crop.
    @MainActor func testASpotCarriesItsRegion() async throws {
        let rig = try await landedRig(region: FFTAnalysisTests.regionA)
        rig.owner.measureSpot(row: 37, col: 40)
        try await until("the click is asked for") { await rig.spotJobs.asked.count == 1 }
        await rig.spotJobs.finish(0, .success(.measured(try FFTAnalysisTests.measured(row: 37, col: 40))))
        try await until("the spot is answered") { rig.owner.hasMeasuredSpot }
        // A live drag moves the room's region; the spot stays the one made on region A.
        rig.owner.setRegion(FFTAnalysisTests.regionB, committed: false)
        let rows = ResultsLedger.rows(image: FFTAnalysisTests.plant(), measurements: ImageMeasurements(), analysis: rig.owner)
        let region = FFTAnalysisTests.regionA
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].entry("region_col")?.value, Double(region.col))
        XCTAssertEqual(rows[0].entry("region_row")?.value, Double(region.row))
        XCTAssertEqual(rows[0].entry("region_width")?.value, 64)
        XCTAssertEqual(rows[0].entry("region_height")?.value, 64)

        let whole = try await landedRig(region: nil)
        whole.owner.measureSpot(row: 40, col: 60)
        try await until("the whole-image click is asked for") { await whole.spotJobs.asked.count == 1 }
        await whole.spotJobs.finish(0, .success(.refused(.nearEdge)))
        try await until("the whole-image spot is answered") {
            whole.owner.spots.count == 1 && !whole.owner.spots.contains { if case .measuring = $0.outcome { true } else { false } }
        }
        let wholeRows = ResultsLedger.rows(image: FFTAnalysisTests.plant(), measurements: ImageMeasurements(), analysis: whole.owner)
        XCTAssertEqual(wholeRows[0].entry("region_col")?.value, 0)
        XCTAssertEqual(wholeRows[0].entry("region_width")?.value, 96)
        XCTAssertEqual(wholeRows[0].entry("region_height")?.value, 64)
    }

    /// The groups follow `ResultRow.Group.allCases`: all the marks, then the spots, whatever was measured first. Red under: the
    /// groups interleaved by time. `rows` switches over the group exhaustively (the compiler holds that a new group has a source).
    @MainActor func testMarksComeBeforeSpots() async throws {
        let rig = try await landedRig()
        rig.owner.measureSpot(row: 37, col: 40)
        try await until("the click is asked for") { await rig.spotJobs.asked.count == 1 }
        await rig.spotJobs.finish(0, .success(.measured(try FFTAnalysisTests.measured(row: 37, col: 40))))
        try await until("the spot is answered") { rig.owner.hasMeasuredSpot }
        let image = FFTAnalysisTests.plant()
        let owner = ImageMeasurements()
        owner.add(ImageMark(kind: .distance, points: [ImagePoint(x: 0, y: 0), ImagePoint(x: 3, y: 4)]), on: image)
        let rows = ResultsLedger.rows(image: image, measurements: owner, analysis: rig.owner)
        XCTAssertEqual(rows.map(\.group), [.marks, .spots])
        XCTAssertEqual(ResultRow.Group.allCases, [.marks, .spots, .calibration, .rings, .eds, .eelsThickness, .eelsEdges])
    }

    // MARK: An open item

    /// The ledger of an open item is that of its own image, marks and spots; no pixels (cold) give no rows. Red under: another item's
    /// owners read.
    @MainActor func testAnItemsLedgerIsItsOwn() async throws {
        let a = URL(fileURLWithPath: "/data/one/a.dm4"), b = URL(fileURLWithPath: "/data/two/b.dm4")
        let items = OpenItems(identify: { FileIdentity(path: $0.path) }, reader: { request in
            let image = Self.image(fileName: request.url.lastPathComponent)
            return OpenedImage(image: image, canvas: AppState.canvas(for: image), metadata: AcquisitionMetadata(), url: request.url,
                               thumbnail: nil, bookmark: nil)
        })
        items.open(urls: [a, b])
        await items.settled()
        let itemA = try XCTUnwrap(items.items.first { $0.url == a })
        let itemB = try XCTUnwrap(items.items.first { $0.url == b })
        let imageA = try XCTUnwrap(itemA.session.image)
        itemA.measurements.add(ImageMark(kind: .distance, points: [ImagePoint(x: 0, y: 0), ImagePoint(x: 3, y: 4)]), on: imageA)
        XCTAssertEqual(ResultsLedger.rows(of: itemA).count, 1)
        XCTAssertTrue(ResultsLedger.rows(of: itemB).isEmpty, "a's marks are not b's")
    }

    // MARK: EDS

    /// A quantified EDS region is listed, one row per fitted element, after the image's groups, with the fit's own numbers (net, at%, wt%
    /// and their sigma) and the region it was summed over. Red under: the ledger ignoring the EDS fit; a number taken from another row.
    @MainActor func testAQuantifiedEDSRegionIsListedOneRowPerElement() async throws {
        let session = EDXSession(host: .macTEM)
        await session.bind(DemoDocuments.edx()).value
        await session.settled()
        await session.quantify()?.value
        await session.settled()
        let fit = try XCTUnwrap(session.fit, session.fitFailure ?? "no fit")
        let eds = ResultsLedger.EDSResults(regionName: session.regionName, fit: fit)
        let image = Self.image()
        let marks = ImageMeasurements()
        marks.add(ImageMark(kind: .distance, points: [ImagePoint(x: 0, y: 0), ImagePoint(x: 3, y: 4)]), on: image)
        let rows = ResultsLedger.rows(image: image, measurements: marks, analysis: idle(), eds: eds)
        let edsRows = rows.filter { $0.group == .eds }
        XCTAssertEqual(edsRows.map(\.label), fit.rows.map { "\($0.element) · Whole map" })
        XCTAssertEqual(rows.first?.group, .marks, "the image's groups first")
        XCTAssertEqual(rows.last?.group, .eds)
        for row in fit.rows {
            let listed = try XCTUnwrap(edsRows.first { $0.label.hasPrefix(row.element + " ") })
            XCTAssertEqual(listed.product, .edsComposition)
            XCTAssertEqual(listed.entry("net")?.value, row.net, row.element)
            XCTAssertEqual(listed.entry("net_sigma")?.value, row.sigma, row.element)
            XCTAssertEqual(listed.entry("at")?.value, row.atomicPercent, row.element)
            XCTAssertEqual(listed.entry("at_sigma")?.value, row.atomicSigma, row.element)
            XCTAssertEqual(listed.entry("wt")?.value, row.weightPercent, row.element)
            XCTAssertEqual(listed.entry("wt_sigma")?.value, row.weightSigma, row.element)
            XCTAssertEqual(listed.entry("region")?.text, "Whole map")
        }
        let mg = try XCTUnwrap(edsRows.first { $0.label.hasPrefix("Mg ") })
        XCTAssertNotNil(mg.entry("wt")?.value, "the planted Mg has a wt%")
        let shown = ResultsFormat.value(mg, x: nil, y: nil, locale: Locale(identifier: "en_US"))
        XCTAssertTrue(shown.contains(" at% · ") && shown.hasSuffix(" wt%") && shown.contains(" ± "), shown)
        XCTAssertEqual(ResultsFormat.source(mg, imageWidth: 40, imageHeight: 30), "EDS · Whole map")
        XCTAssertTrue(ResultsLedger.rows(image: image, measurements: marks, analysis: idle()).allSatisfy { $0.group != .eds },
                      "no fit: no EDS row")
    }

    /// A row the kit refused has no number (the kit writes 0 there), a row at the fit's bound reads as not detected in the kit's words, an
    /// at% the fit refused says why in the Value column, and the kit's caveat on an at% is kept. Red under: the refused row's 0 written as a
    /// net; the bound row shown as "net 0 counts".
    @MainActor func testTheEDSRowsKeepTheKitsRefusalsAndFlags() async throws {
        let session = EDXSession(host: .macTEM)
        await session.bind(DemoDocuments.edx()).value
        await session.settled()
        await session.quantify()?.value
        await session.settled()
        // The kit's Row has no public initialiser: a real row of the demo fit, edited into each case.
        let base = try XCTUnwrap(session.fit?.rows.first, session.fitFailure ?? "no fit")
        func kitRow(_ element: String, net: Double, sigma: Double) -> PooledQuantification.Row {
            var r = base
            r.element = element; r.net = net; r.sigma = sigma; r.failure = nil; r.atBound = false
            r.atomicPercent = nil; r.atomicSigma = nil; r.weightPercent = nil; r.weightSigma = nil
            return r
        }
        var row = kitRow("Cu", net: 0, sigma: 0)
        row.failure = "no line in the fitted range"
        let refused = ResultRow.edsComposition(id: "r", row: row, regionName: "Whole map", abundanceRefusal: nil)
        XCTAssertEqual(refused.refusal, "no line in the fitted range")
        XCTAssertNil(refused.entry("net")?.value)
        XCTAssertNil(refused.entry("net_sigma")?.value)
        var bound = kitRow("Fe", net: 0, sigma: 12)
        bound.atBound = true
        let held = ResultRow.edsComposition(id: "b", row: bound, regionName: "Whole map", abundanceRefusal: nil)
        XCTAssertEqual(held.entry("net")?.value, 0)
        XCTAssertEqual(ResultsFormat.edsValue(held), "Not detected: " + ResultRow.edsAtBound)
        let plain = kitRow("Mg", net: 900, sigma: 30)
        let noAt = ResultRow.edsComposition(id: "n", row: plain, regionName: "Whole map", abundanceRefusal: "at% needs two quantified elements")
        XCTAssertTrue(ResultsFormat.edsValue(noAt, locale: Locale(identifier: "en_US")).hasSuffix(" · at%: at% needs two quantified elements"))
        var withAt = plain
        withAt.atomicPercent = 40
        let caveated = ResultRow.edsComposition(id: "c", row: withAt, regionName: "Whole map", abundanceRefusal: nil,
                                                abundanceCaveat: "assumes the listed elements only")
        XCTAssertEqual(caveated.entry("caveat")?.text, "assumes the listed elements only")
    }

    /// The EDS room holds one file: its fit belongs to an open item only when that item's file opened into the EDS room and is the one
    /// the room holds, and not while the room is opening another. Red under: another file's composition listed under this one.
    func testTheEDSFitIsListedOnlyUnderItsOwnFile() {
        let a = URL(fileURLWithPath: "/data/one/a.emd"), b = URL(fileURLWithPath: "/data/two/b.emd")
        XCTAssertTrue(AppState.edsFitBelongs(to: a, edsFiles: [a, b], edsFile: "a.emd", edsOpening: false))
        XCTAssertFalse(AppState.edsFitBelongs(to: b, edsFiles: [a, b], edsFile: "a.emd", edsOpening: false), "the room holds a")
        XCTAssertFalse(AppState.edsFitBelongs(to: a, edsFiles: [b], edsFile: "a.emd", edsOpening: false), "a did not open into the EDS room")
        XCTAssertFalse(AppState.edsFitBelongs(to: a, edsFiles: [a], edsFile: "a.emd", edsOpening: true), "the room is opening")
        let twin = URL(fileURLWithPath: "/data/two/a.emd")
        XCTAssertTrue(AppState.edsFitBelongs(to: a, edsFiles: [a, twin], edsFile: "a.emd", edsPath: a.path, edsOpening: false))
        XCTAssertFalse(AppState.edsFitBelongs(to: twin, edsFiles: [a, twin], edsFile: "a.emd", edsPath: a.path, edsOpening: false),
                       "a file of the same name in another folder")
    }
}
