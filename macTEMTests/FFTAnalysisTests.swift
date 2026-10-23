//
//  FFTAnalysisTests.swift
//  The FFT room's owner (archive: roadmap-registrations-2026-10-15.md V1-6, "The room": R2, the live-update rule, and the products it publishes). Two halves.
//  The LANES, with an injected `FFTCompute` whose jobs park on a continuation the test finishes in its own order, so P4 is
//  deterministic: a superseded result is never published, the newest key is always computed last, two jobs of one lane
//  never overlap, a committed region clears the spots — and the rest of the owner's rules (what a read, a release, a
//  filter's parameters and the mask's inputs do). The PRODUCTS, with `FFTCompute.live` on a small planted image: each
//  product equals its core called directly on the same crop, so the room adds no arithmetic to a core's number (P1).
//  Package-level: imports only TEMCore and TEMSession, so the file runs under `swift test` and in the app's test bundle.
//  Every test names, in its comment, the change to the production code that turns it red.
//

import XCTest
import TEMCore
import TEMSession
import ImagoCore
import ImagoFFT
import ImagoFilters

nonisolated final class FFTAnalysisTests: XCTestCase {

    // MARK: - Fixtures

    /// Three 64 px squares of the planted image, left, top and right.
    nonisolated static let regionA = PixelCrop(row: 0, col: 16, height: 64, width: 64)
    nonisolated static let regionB = PixelCrop(row: 0, col: 0, height: 64, width: 64)
    nonisolated static let regionC = PixelCrop(row: 0, col: 32, height: 64, width: 64)

    /// A 96 × 64 image (or another size) at 0.05 × 0.04 nm/px: a DC, two lattices that sit exactly on bins of a 64 px
    /// window — (kx, ky) = (8, 5) and (12, −3) — and a smooth texture, so every core has something to find and nothing
    /// is degenerate.
    nonisolated static func plant(width: Int = 96, height: Int = 64) -> CalibratedImage {
        var pixels = [Float](repeating: 0, count: width * height)
        for r in 0..<height {
            for c in 0..<width {
                let a = 2 * Double.pi * Double(8 * c + 5 * r) / 64
                let b = 2 * Double.pi * Double(12 * c - 3 * r) / 64
                pixels[r * width + c] = Float(100 + 10 * cos(a) + 6 * cos(b) + 3 * sin(0.37 * Double(c)) * cos(0.21 * Double(r)))
            }
        }
        return CalibratedImage(width: width, height: height, pixels: pixels, x: AxisCalibration(scale: 0.05, unit: "nm", origin: 0),
                               y: AxisCalibration(scale: 0.04, unit: "nm", origin: 0), fileName: "plant", source: "", voltage: nil)
    }

    /// An image of the given size and axes whose pixels are all `value` (or, with `nan`, one of them NaN): no power but the DC.
    nonisolated static func flat(width: Int = 96, height: Int = 64, value: Float = 100, nan: Bool = false) -> CalibratedImage {
        var pixels = [Float](repeating: value, count: width * height)
        if nan { pixels[5 * width + 7] = .nan }
        return CalibratedImage(width: width, height: height, pixels: pixels, x: AxisCalibration(scale: 0.05, unit: "nm", origin: 0),
                               y: AxisCalibration(scale: 0.04, unit: "nm", origin: 0), fileName: "flat", source: "", voltage: nil)
    }

    /// A 160 × 64 image whose left 96 columns are `plant`'s lattice and whose right 64 are constant: region A lies on the
    /// lattice, `flatRegion` on the constant half.
    nonisolated static func halfFlat() -> CalibratedImage {
        let lattice = plant(width: 160, height: 64)
        var pixels = lattice.pixels
        for r in 0..<64 { for c in 96..<160 { pixels[r * 160 + c] = 100 } }
        return CalibratedImage(width: 160, height: 64, pixels: pixels, x: lattice.x, y: lattice.y, fileName: "half", source: "",
                               voltage: nil)
    }

    nonisolated static let flatRegion = PixelCrop(row: 0, col: 96, height: 64, width: 64)

    /// The registered estimator's answer for a click on `plant`'s region A.
    nonisolated static func measured(row: Int, col: Int) throws -> SpotMeasurement {
        try SpotMeasurement.measure(plant().micrograph, crop: regionA, clickRow: row, clickColumn: col)
    }

    nonisolated static func fakeCanvas(_ size: Int = 64) -> CanvasPixels {
        CanvasPixels(width: size, height: size, normalized: [Float](repeating: 0, count: size * size), contentVersion: 1, rawRange: nil)
    }

    nonisolated static func fakeSpectrum(_ key: FFTSpectrumKey, size: Int = 64) -> FFTSpectrumProduct {
        FFTSpectrumProduct(key: key, width: size, height: size, spacingX: 0.3125, spacingY: 0.390625, unitsX: "1/nm",
                           unitsY: "1/nm", canvas: fakeCanvas(size), defaultWindow: nil, profile: nil, region: fakeCanvas(size))
    }

    /// What the owner asked of the spot lane.
    nonisolated struct SpotAsk: Sendable, Equatable {
        let crop: PixelCrop?
        let row: Int
        let col: Int
    }

    nonisolated struct TimedOut: Error {}

    /// One lane's jobs, each parked until the test finishes it, in the test's own order. `mostAtOnce` is the most jobs
    /// that were out at the same moment (a job is out from the owner asking until the test finishes it).
    actor ParkedJobs<Ask: Sendable, Answer: Sendable> {
        private(set) var asked: [Ask] = []
        private(set) var mostAtOnce = 0
        private var atOnce = 0
        private var parked: [Int: CheckedContinuation<Result<Answer, any Error>, Never>] = [:]

        func run(_ ask: Ask) async throws -> Answer {
            let index = asked.count
            asked.append(ask)
            atOnce += 1
            mostAtOnce = max(mostAtOnce, atOnce)
            let result = await withCheckedContinuation { (continuation: CheckedContinuation<Result<Answer, any Error>, Never>) in
                parked[index] = continuation
            }
            return try result.get()
        }

        func finish(_ index: Int, _ result: Result<Answer, any Error>) {
            guard let continuation = parked.removeValue(forKey: index) else { return }
            atOnce -= 1
            continuation.resume(returning: result)
        }

        /// Ends the test's loose ends: a job still parked is answered with a cancellation, so no continuation leaks.
        func failAll() {
            let loose = parked
            parked = [:]
            atOnce = 0
            for continuation in loose.values { continuation.resume(returning: .failure(CancellationError())) }
        }
    }

    /// An owner on parked jobs, and the means to finish them.
    @MainActor final class Rig {
        let spectra: ParkedJobs<FFTSpectrumKey, FFTSpectrumProduct>
        let spotJobs: ParkedJobs<SpotAsk, FFTSpot.Outcome>
        let masks: ParkedJobs<FFTMaskKey, FFTMaskedInverseProduct>
        let filters: ParkedJobs<FFTFilterKey, FFTFilterProduct>
        let owner: FFTAnalysis

        init() {
            let spectra = ParkedJobs<FFTSpectrumKey, FFTSpectrumProduct>()
            let spotJobs = ParkedJobs<SpotAsk, FFTSpot.Outcome>()
            let masks = ParkedJobs<FFTMaskKey, FFTMaskedInverseProduct>()
            let filters = ParkedJobs<FFTFilterKey, FFTFilterProduct>()
            self.spectra = spectra
            self.spotJobs = spotJobs
            self.masks = masks
            self.filters = filters
            owner = FFTAnalysis(compute: FFTCompute(
                spectrum: { _, key in try await spectra.run(key) },
                spot: { _, crop, row, col in (try? await spotJobs.run(SpotAsk(crop: crop, row: row, col: col))) ?? .measuring },
                maskedInverse: { _, key in try await masks.run(key) },
                filter: { _, key in try await filters.run(key) }))
        }

        func drain() async {
            await spectra.failAll()
            await spotJobs.failAll()
            await masks.failAll()
            await filters.failAll()
        }

        /// Finishes the `n`-th spectrum job with a product of the key it was asked for.
        func finishSpectrum(_ n: Int, size: Int = 64) async {
            let key = await spectra.asked[n]
            await spectra.finish(n, .success(FFTAnalysisTests.fakeSpectrum(key, size: size)))
        }

        func finishMask(_ n: Int) async {
            let key = await masks.asked[n]
            await masks.finish(n, .success(FFTMaskedInverseProduct(key: key, canvas: FFTAnalysisTests.fakeCanvas(), imaginaryMax: 0)))
        }

        func finishFilter(_ n: Int) async {
            let key = await filters.asked[n]
            await filters.finish(n, .success(FFTFilterProduct(key: key, absf: FFTAnalysisTests.fakeCanvas(),
                                                              wiener: FFTAnalysisTests.fakeCanvas(), n: 64, passes: 3, finalDelta: 4.5)))
        }
    }

    /// A rig that answers its loose jobs with a cancellation when the test ends.
    @MainActor private func makeRig() -> Rig {
        let rig = Rig()
        addTeardownBlock { await rig.drain() }
        return rig
    }

    /// Waits for `condition` for about eight seconds (the machine may be building other things); a state that never comes
    /// ends the test instead of hanging it.
    @MainActor private func until(_ what: String, _ condition: @MainActor () async -> Bool) async throws {
        for _ in 0..<1600 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("timed out waiting for: \(what)")
        throw TimedOut()
    }

    /// Lets the owner act on everything it has been told, for the checks that something did NOT happen.
    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(80))
    }

    /// A rig whose owner shows the plant with `region` committed, and whose spectrum for it has landed.
    @MainActor private func landed(region: PixelCrop? = FFTAnalysisTests.regionA, version: Int = 1) async throws -> Rig {
        let rig = makeRig()
        rig.owner.setRegion(region, committed: true)
        rig.owner.show(Self.plant(), contentVersion: version)
        try await until("the spectrum is asked for") { await rig.spectra.asked.count == 1 }
        await rig.finishSpectrum(0)
        try await until("the spectrum lands") { rig.owner.isSpectrumCurrent }
        return rig
    }

    /// Measures a spot at (row, col) and finishes its job with `outcome`; returns once it has landed.
    @MainActor private func measure(_ rig: Rig, row: Int, col: Int, _ outcome: FFTSpot.Outcome) async throws {
        let n = await rig.spotJobs.asked.count
        rig.owner.measureSpot(row: row, col: col)
        try await until("the spot job starts") { await rig.spotJobs.asked.count == n + 1 }
        await rig.spotJobs.finish(n, .success(outcome))
        try await until("the spot lands") {
            if case .measuring? = rig.owner.spots.last?.outcome { return false }
            return true
        }
    }

    /// A rig with the spectrum landed, one measured spot, a filter run landed (the pane then shows ABSF), and the masked
    /// inverse shown and landed.
    @MainActor private func everything() async throws -> (rig: Rig, spot: SpotMeasurement) {
        let rig = try await landed()
        let spot = try Self.measured(row: 37, col: 40)
        try await measure(rig, row: 37, col: 40, .measured(spot))
        rig.owner.runFilter()
        try await until("the filter starts") { await rig.filters.asked.count == 1 }
        await rig.finishFilter(0)
        try await until("the filter lands") { rig.owner.filtered != nil }
        rig.owner.setSourceView(.maskedInverse)
        try await until("the inverse starts") { await rig.masks.asked.count == 1 }
        await rig.finishMask(0)
        try await until("the inverse lands") { rig.owner.maskedInverse != nil }
        return (rig, spot)
    }

    // MARK: - R2, the lanes

    /// A result whose key is no longer wanted is never published, and the wanted key's job runs next. Red under: a job's
    /// answer published without comparing its key to the wanted one (job 0's whole-image spectrum appears after the
    /// region was asked for).
    @MainActor func testASupersededSpectrumIsNeverPublished() async throws {
        let rig = makeRig()
        rig.owner.show(Self.plant(), contentVersion: 1)
        try await until("job 0 starts") { await rig.spectra.asked.count == 1 }
        rig.owner.setRegion(Self.regionA, committed: true)
        await rig.finishSpectrum(0)
        try await until("job 1 starts") { await rig.spectra.asked.count == 2 }
        XCTAssertNil(rig.owner.spectrum, "job 0 answered for the whole image, no longer the key wanted: dropped")
        XCTAssertFalse(rig.owner.isSpectrumCurrent)
        await rig.finishSpectrum(1)
        try await until("job 1 lands") { rig.owner.isSpectrumCurrent }
        XCTAssertEqual(rig.owner.spectrum?.key, FFTSpectrumKey(contentVersion: 1, crop: Self.regionA))
    }

    /// While a job runs, the samples of a region drag replace each other: only the newest is computed, and last. Red
    /// under: the pending key dropped when the job ends (nothing follows job 0); the pending key kept as the FIRST asked
    /// rather than replaced (job 1 would be region A, a stale sample).
    @MainActor func testTheNewestKeyIsComputedLastAndTheSamplesBetweenAreNever() async throws {
        let rig = makeRig()
        rig.owner.show(Self.plant(), contentVersion: 1)
        try await until("job 0 starts") { await rig.spectra.asked.count == 1 }
        for crop in [Self.regionA, Self.regionB, Self.regionC] { rig.owner.setRegion(crop, committed: false) }
        await rig.finishSpectrum(0)
        try await until("the newest sample is computed") { await rig.spectra.asked.count == 2 }
        let asked = await rig.spectra.asked
        XCTAssertEqual(asked.map(\.crop), [nil, Self.regionC], "the whole image, then only the newest sample")
        await rig.finishSpectrum(1)
        try await until("the newest sample lands") { rig.owner.isSpectrumCurrent }
        XCTAssertEqual(rig.owner.spectrum?.key.crop, Self.regionC)
        try await settle()
        let count = await rig.spectra.asked.count
        XCTAssertEqual(count, 2, "nothing else was asked")
    }

    /// A lane runs at most one job: a request while one runs waits behind it. Red under: a request that starts a job
    /// although one runs (two jobs out at once).
    @MainActor func testTwoJobsOfALaneNeverOverlap() async throws {
        let rig = makeRig()
        rig.owner.show(Self.plant(), contentVersion: 1)
        try await until("job 0 starts") { await rig.spectra.asked.count == 1 }
        rig.owner.setRegion(Self.regionA, committed: false)
        rig.owner.setRegion(Self.regionB, committed: false)
        try await settle()
        var asked = await rig.spectra.asked.count
        var most = await rig.spectra.mostAtOnce
        XCTAssertEqual(asked, 1, "the samples wait behind the running job")
        XCTAssertEqual(most, 1)
        await rig.finishSpectrum(0)
        try await until("the waiting sample starts") { await rig.spectra.asked.count == 2 }
        rig.owner.setRegion(Self.regionC, committed: false)
        try await settle()
        asked = await rig.spectra.asked.count
        most = await rig.spectra.mostAtOnce
        XCTAssertEqual(asked, 2)
        XCTAssertEqual(most, 1)
        await rig.finishSpectrum(1)
        try await until("the last sample starts") { await rig.spectra.asked.count == 3 }
        let last = await rig.spectra.asked.last
        XCTAssertEqual(last?.crop, Self.regionC)
    }

    /// Spots are one FIFO lane: each click its own job, in the order clicked, one at a time. Red under: the spot lane
    /// starting a job although one is out; the queue run newest first.
    @MainActor func testSpotsAreMeasuredInOrderOneAtATime() async throws {
        let rig = try await landed()
        for (row, col) in [(37, 40), (29, 44), (31, 33)] { rig.owner.measureSpot(row: row, col: col) }
        try await until("the first spot starts") { await rig.spotJobs.asked.count == 1 }
        try await settle()
        var asked = await rig.spotJobs.asked
        XCTAssertEqual(asked.count, 1, "the other clicks wait their turn")
        XCTAssertEqual(rig.owner.spots.map(\.number), [1, 2, 3])
        await rig.spotJobs.finish(0, .success(.measured(try Self.measured(row: 37, col: 40))))
        try await until("the second spot starts") { await rig.spotJobs.asked.count == 2 }
        await rig.spotJobs.finish(1, .success(.measured(try Self.measured(row: 29, col: 44))))
        try await until("the third spot starts") { await rig.spotJobs.asked.count == 3 }
        await rig.spotJobs.finish(2, .success(.refused(.nearDC)))
        try await until("the third spot lands") { rig.owner.spots.allSatisfy { if case .measuring = $0.outcome { false } else { true } } }
        asked = await rig.spotJobs.asked
        XCTAssertEqual(asked.map { [$0.row, $0.col] }, [[37, 40], [29, 44], [31, 33]], "in the order clicked")
        let most = await rig.spotJobs.mostAtOnce
        XCTAssertEqual(most, 1)
        XCTAssertNotNil(rig.owner.spots[0].measured)
        XCTAssertNotNil(rig.owner.spots[1].measured)
        guard case .refused(.nearDC) = rig.owner.spots[2].outcome else { return XCTFail("the third is the refusal it was answered") }
    }

    /// A spot's answer lands only on the spectrum it was clicked on: when the region has moved on, it is dropped (and the
    /// spot, which can never be answered, goes). Red under: a spot's answer taken without comparing its spectrum's key
    /// to the wanted one.
    @MainActor func testASpotAnsweredForASpectrumNoLongerWantedIsDropped() async throws {
        let rig = try await landed()
        rig.owner.measureSpot(row: 37, col: 40)
        try await until("the spot starts") { await rig.spotJobs.asked.count == 1 }
        rig.owner.setRegion(Self.regionB, committed: false)
        await rig.spotJobs.finish(0, .success(.measured(try Self.measured(row: 37, col: 40))))
        try await settle()
        XCTAssertTrue(rig.owner.spots.isEmpty, "the answer was for region A's spectrum; region B is asked for now: \(rig.owner.spots)")
    }

    /// A click still waiting for its turn when the region moves on is never measured: its spectrum is not the one asked
    /// for, so it goes without a job. Red under: the check at the start of a spot's turn removed (a second job is asked).
    @MainActor func testAWaitingSpotWhoseSpectrumMovedOnIsNeverMeasured() async throws {
        let rig = try await landed()
        rig.owner.measureSpot(row: 37, col: 40)
        rig.owner.measureSpot(row: 29, col: 44)
        try await until("the first spot starts") { await rig.spotJobs.asked.count == 1 }
        rig.owner.setRegion(Self.regionB, committed: false)
        await rig.spotJobs.finish(0, .success(.measured(try Self.measured(row: 37, col: 40))))
        try await settle()
        let asked = await rig.spotJobs.asked.count
        XCTAssertEqual(asked, 1, "the second click was on region A's spectrum, no longer the one asked for")
        XCTAssertTrue(rig.owner.spots.isEmpty)
    }

    /// A spot is measured only on the spectrum shown and asked for: before it lands, and while the region is being
    /// dragged, a click is ignored. Red under: `measureSpot` not checking `isSpectrumCurrent`.
    @MainActor func testMeasureSpotIsIgnoredWhileTheSpectrumIsNotCurrent() async throws {
        let rig = makeRig()
        rig.owner.setRegion(Self.regionA, committed: true)
        rig.owner.show(Self.plant(), contentVersion: 1)
        rig.owner.measureSpot(row: 37, col: 40)
        XCTAssertTrue(rig.owner.spots.isEmpty, "no spectrum yet")
        try await until("the spectrum is asked for") { await rig.spectra.asked.count == 1 }
        await rig.finishSpectrum(0)
        try await until("the spectrum lands") { rig.owner.isSpectrumCurrent }
        rig.owner.measureSpot(row: 37, col: 40)
        XCTAssertEqual(rig.owner.spots.count, 1)
        rig.owner.setRegion(Self.regionB, committed: false)
        XCTAssertFalse(rig.owner.isSpectrumCurrent)
        rig.owner.measureSpot(row: 29, col: 44)
        XCTAssertEqual(rig.owner.spots.count, 1, "the spectrum shown is region A's, region B is asked for")
    }

    /// A click on the bin of an existing spot selects it; a click on another bin makes a new spot, selected, numbered on
    /// from the last. Red under: the duplicate check removed (a third spot); the new spot not selected.
    @MainActor func testAClickInAnExistingSpotsBinSelectsIt() async throws {
        let rig = try await landed()
        rig.owner.measureSpot(row: 37, col: 40)
        rig.owner.measureSpot(row: 29, col: 44)
        XCTAssertEqual(rig.owner.spots.count, 2)
        XCTAssertEqual(rig.owner.selection, rig.owner.spots[1].id, "a new spot is selected")
        rig.owner.measureSpot(row: 37, col: 40)
        XCTAssertEqual(rig.owner.spots.count, 2, "the bin already holds a spot")
        XCTAssertEqual(rig.owner.selection, rig.owner.spots[0].id)
        XCTAssertEqual(rig.owner.spots.map(\.number), [1, 2])
    }

    /// Numbers are not reused while the spots stand, and start again from 1 once none is left. Red under: the number
    /// taken as count + 1 (a spot removed from the middle gives its number twice); the counter not reset.
    @MainActor func testSpotNumbersAreNotReusedWhileTheSpotsStand() async throws {
        let rig = try await landed()
        for (row, col) in [(37, 40), (29, 44), (31, 33)] { rig.owner.measureSpot(row: row, col: col) }
        rig.owner.removeSpot(rig.owner.spots[1].id)
        rig.owner.measureSpot(row: 40, col: 40)
        XCTAssertEqual(rig.owner.spots.map(\.number), [1, 3, 4])
        rig.owner.removeAllSpots()
        XCTAssertTrue(rig.owner.spots.isEmpty)
        XCTAssertNil(rig.owner.selection)
        rig.owner.measureSpot(row: 37, col: 40)
        XCTAssertEqual(rig.owner.spots.map(\.number), [1])
    }

    /// Removing the selected spot leaves nothing selected; removing another spot keeps the selection. Red under: the
    /// selection left on a spot that is gone; every removal clearing the selection.
    @MainActor func testRemovingTheSelectedSpotClearsTheSelection() async throws {
        let rig = try await landed()
        for (row, col) in [(37, 40), (29, 44), (31, 33)] { rig.owner.measureSpot(row: row, col: col) }
        let ids = rig.owner.spots.map(\.id)
        XCTAssertEqual(rig.owner.selection, ids[2], "the newest spot is selected")
        rig.owner.removeSpot(ids[0])
        XCTAssertEqual(rig.owner.selection, ids[2], "another spot's removal keeps the selection")
        rig.owner.removeSpot(ids[2])
        XCTAssertNil(rig.owner.selection, "the selected spot is gone")
        XCTAssertEqual(rig.owner.spots.map(\.id), [ids[1]])
    }

    // MARK: - The region

    /// A committed region that differs from the last committed one removes the spots, the masked inverse and the
    /// filters' result, and the pane shows the file again. Red under: the spots kept across a committed region; the
    /// masked inverse kept; the filters' result kept; the source view left on a product that no longer exists.
    @MainActor func testACommittedRegionChangeClearsSpotsInverseAndFilter() async throws {
        let (rig, _) = try await everything()
        XCTAssertEqual(rig.owner.sourceView, .maskedInverse)
        XCTAssertNotNil(rig.owner.maskedInverse)
        XCTAssertNotNil(rig.owner.filtered)
        XCTAssertEqual(rig.owner.spots.count, 1)
        // The drag's samples, then its end.
        rig.owner.setRegion(Self.regionB, committed: false)
        rig.owner.setRegion(Self.regionB, committed: true)
        XCTAssertTrue(rig.owner.spots.isEmpty, "their bins belong to the old transform")
        XCTAssertNil(rig.owner.selection)
        XCTAssertNil(rig.owner.maskedInverse)
        XCTAssertNil(rig.owner.filtered)
        XCTAssertEqual(rig.owner.sourceView, .original, "the masked inverse view falls back to the file")
        XCTAssertEqual(rig.owner.region, Self.regionB)
        XCTAssertEqual(rig.owner.wantedSpectrumKey, FFTSpectrumKey(contentVersion: 1, crop: Self.regionB))
    }

    /// An ABSF or Wiener view falls back too. Red under: the fallback only for the masked inverse.
    @MainActor func testACommittedRegionChangeLeavesAnAbsfViewForTheFile() async throws {
        let (rig, _) = try await everything()
        rig.owner.setSourceView(.wiener)
        XCTAssertEqual(rig.owner.sourceView, .wiener)
        rig.owner.setRegion(nil, committed: true)
        XCTAssertEqual(rig.owner.sourceView, .original)
        XCTAssertNil(rig.owner.filtered)
        rig.owner.setSourceView(.absf)
        XCTAssertEqual(rig.owner.sourceView, .original, "a filter view needs a filter result")
    }

    /// A drag's samples do not clear the spots, and a drag that ends where it began (the last committed region) does not
    /// either. Red under: an uncommitted change treated as committed; every committed call clearing.
    @MainActor func testAnUncommittedRegionChangeKeepsTheSpots() async throws {
        let rig = try await landed()
        try await measure(rig, row: 37, col: 40, .measured(try Self.measured(row: 37, col: 40)))
        rig.owner.setRegion(Self.regionB, committed: false)
        rig.owner.setRegion(Self.regionC, committed: false)
        XCTAssertEqual(rig.owner.spots.count, 1, "samples of a drag do not clear")
        XCTAssertEqual(rig.owner.region, Self.regionC, "the region follows the drag")
        rig.owner.setRegion(Self.regionA, committed: true)
        XCTAssertEqual(rig.owner.spots.count, 1, "the drag ended on the region committed before: nothing changed")
        rig.owner.setRegion(Self.regionB, committed: true)
        XCTAssertTrue(rig.owner.spots.isEmpty)
    }

    /// The filters' result and a run asked for belong to the crop they were made for, and any change of region — a drag's
    /// sample as well as a committed one — takes them away: an answer for region A that lands while region B is the one
    /// transformed is dropped (R2: published only if its key still equals the wanted one), and never switches the pane to
    /// an ABSF of a region no longer shown. Red under: the filter lane's wanted key left as the stored one (the answer lands:
    /// ABSF of A beside B's transform); the run kept across an uncommitted sample.
    @MainActor func testAFilterAnsweredForARegionNoLongerTransformedIsNotPublished() async throws {
        let rig = try await landed()
        rig.owner.runFilter()
        try await until("the filter starts") { await rig.filters.asked.count == 1 }
        rig.owner.setRegion(Self.regionB, committed: false)         // a drag's sample: region B is now the one transformed
        XCTAssertFalse(rig.owner.isFiltering, "the run asked for is no longer wanted")
        await rig.finishFilter(0)
        try await settle()
        XCTAssertNil(rig.owner.filtered, "the answer was for region A")
        XCTAssertEqual(rig.owner.sourceView, .original, "the pane is not switched to a product of another region")
        XCTAssertFalse(rig.owner.isFiltering)
        XCTAssertEqual(rig.owner.wantedSpectrumKey?.crop, Self.regionB)
    }

    /// A Filter pending behind a run that is going is not started for a region that has moved on. Red under: the pending
    /// key started because the filter lane's wanted key is the stored one (a second job is asked for region A while B is
    /// transformed).
    @MainActor func testAFilterWaitingBehindARunIsNotStartedForAnOldRegion() async throws {
        let rig = try await landed()
        rig.owner.runFilter()
        try await until("the first run starts") { await rig.filters.asked.count == 1 }
        var changed = HRTEMFilter.Parameters.defaults
        changed.delta = 8
        rig.owner.setFilterParameters(changed)                      // the first run is no longer wanted
        rig.owner.runFilter()                                       // the second waits behind it
        XCTAssertTrue(rig.owner.isFiltering)
        rig.owner.setRegion(Self.regionB, committed: false)
        await rig.finishFilter(0)
        try await settle()
        let asked = await rig.filters.asked.count
        XCTAssertEqual(asked, 1, "the waiting run was for region A, which is no longer transformed")
        XCTAssertNil(rig.owner.filtered)
        XCTAssertFalse(rig.owner.isFiltering)
    }

    /// A drag that takes the region away and brings it back to where it began does not bring the result back, and a sample
    /// at the very crop of the result keeps it. Red under: the result kept across the sample (an uncommitted change
    /// ignored by the filters); dropped by a sample that changes nothing.
    @MainActor func testAFilterResultGoesWithAnyRegionChangeAndStaysGone() async throws {
        let rig = try await landed()
        rig.owner.runFilter()
        try await until("the filter starts") { await rig.filters.asked.count == 1 }
        rig.owner.setRegion(Self.regionA, committed: false)         // the same crop: nothing changed
        await rig.finishFilter(0)
        try await until("the filter lands") { rig.owner.filtered != nil }
        XCTAssertEqual(rig.owner.sourceView, .absf)
        rig.owner.setRegion(Self.regionA, committed: false)
        XCTAssertNotNil(rig.owner.filtered, "a sample at the same crop changes nothing")
        rig.owner.setRegion(Self.regionB, committed: false)
        XCTAssertNil(rig.owner.filtered, "region B is not what the result was made for")
        XCTAssertEqual(rig.owner.sourceView, .original, "the ABSF view falls back with its result")
        rig.owner.setRegion(Self.regionA, committed: true)          // the drag ended where it began: the last committed region
        XCTAssertNil(rig.owner.filtered, "not brought back")
        XCTAssertEqual(rig.owner.sourceView, .original)
    }

    // MARK: - A read, and the room's coming and going

    /// A file read again with different pixels removes the spots and every product, and the spectrum is asked for on the
    /// new pixels. Red under: spots kept across a new content version; the products kept; the spectrum asked on the old
    /// version.
    @MainActor func testAReadWithNewPixelsClearsTheSpotsAndProducts() async throws {
        let (rig, _) = try await everything()
        rig.owner.show(Self.plant(), contentVersion: 2)
        XCTAssertTrue(rig.owner.spots.isEmpty)
        XCTAssertNil(rig.owner.spectrum)
        XCTAssertNil(rig.owner.maskedInverse)
        XCTAssertNil(rig.owner.filtered)
        XCTAssertEqual(rig.owner.sourceView, .original)
        XCTAssertEqual(rig.owner.region, Self.regionA, "the region still fits")
        XCTAssertEqual(rig.owner.wantedSpectrumKey, FFTSpectrumKey(contentVersion: 2, crop: Self.regionA))
        try await until("the spectrum is asked for again") { await rig.spectra.asked.count == 2 }
        let key = await rig.spectra.asked[1]
        XCTAssertEqual(key.contentVersion, 2)
    }

    /// A file read again with the same pixels keeps the spots and the spectrum, and asks for nothing. Red under: the
    /// spots cleared on every show; the spectrum asked for again although held.
    @MainActor func testAReadWithTheSamePixelsKeepsTheSpotsAndAsksForNothing() async throws {
        let rig = try await landed()
        try await measure(rig, row: 37, col: 40, .measured(try Self.measured(row: 37, col: 40)))
        rig.owner.show(Self.plant(), contentVersion: 1)
        try await settle()
        XCTAssertEqual(rig.owner.spots.count, 1)
        XCTAssertTrue(rig.owner.isSpectrumCurrent)
        let asked = await rig.spectra.asked.count
        XCTAssertEqual(asked, 1)
    }

    /// A region that no longer fits the image read again is cleared; one that still does is kept. Red under: the
    /// validity check removed (the region stays 64 px on a 48 px image); a region always cleared.
    @MainActor func testARegionThatNoLongerFitsIsClearedOnARead() async throws {
        let rig = try await landed()
        rig.owner.show(Self.plant(width: 48, height: 48), contentVersion: 2)
        XCTAssertNil(rig.owner.region, "a 64 px square does not fit a 48 × 48 image")
        XCTAssertEqual(rig.owner.wantedSpectrumKey, FFTSpectrumKey(contentVersion: 2, crop: nil))
        let fits = try await landed()
        fits.owner.show(Self.plant(), contentVersion: 2)
        XCTAssertEqual(fits.owner.region, Self.regionA, "it still fits the new read")
    }

    /// `release` drops every product and the image, keeps the settings and the spots' bins, and an answer that comes
    /// after it is not published. Red under: a product kept; the spots or a setting cleared; the wanted spectrum key kept.
    @MainActor func testReleaseDropsTheProductsAndALateAnswer() async throws {
        let (rig, _) = try await everything()
        rig.owner.setMask(radius: 6, edge: 3)
        try await until("the inverse is asked again") { await rig.masks.asked.count == 2 }
        rig.owner.release()
        XCTAssertNil(rig.owner.spectrum)
        XCTAssertNil(rig.owner.maskedInverse)
        XCTAssertNil(rig.owner.filtered)
        XCTAssertNil(rig.owner.wantedSpectrumKey)
        XCTAssertFalse(rig.owner.isSpectrumCurrent)
        XCTAssertEqual(rig.owner.spots.count, 1, "the spots' bins stay")
        XCTAssertEqual(rig.owner.region, Self.regionA)
        XCTAssertEqual(rig.owner.maskRadius, 6)
        XCTAssertEqual(rig.owner.sourceView, .maskedInverse)
        await rig.finishMask(1)
        try await settle()
        XCTAssertNil(rig.owner.maskedInverse, "an answer after release is not published")
    }

    /// The room shown again after `release`: the spectrum is asked for again, a spot whose answer was lost is measured
    /// again, and the answer a running job gives for the key asked again is dropped (the job began before the release).
    /// Red under: `release` not invalidating the lanes; a spot left measuring for ever.
    @MainActor func testAnAnswerFromBeforeAReleaseIsDroppedWhenTheRoomIsShownAgain() async throws {
        let rig = try await landed()
        rig.owner.measureSpot(row: 37, col: 40)
        try await until("the spot starts") { await rig.spotJobs.asked.count == 1 }
        rig.owner.release()
        rig.owner.show(Self.plant(), contentVersion: 1)
        try await until("the spectrum is asked for again") { await rig.spectra.asked.count == 2 }
        await rig.spotJobs.finish(0, .success(.measured(try Self.measured(row: 37, col: 40))))
        try await until("the spot is asked for again") { await rig.spotJobs.asked.count == 2 }
        XCTAssertEqual(rig.owner.spots.count, 1)
        guard case .measuring = rig.owner.spots[0].outcome else { return XCTFail("the lost answer was not taken") }
        await rig.finishSpectrum(1)
        try await until("the spectrum lands") { rig.owner.isSpectrumCurrent }
        await rig.spotJobs.finish(1, .success(.measured(try Self.measured(row: 37, col: 40))))
        try await until("the spot lands") { rig.owner.spots.first?.measured != nil }
    }

    /// A spectrum that was running at `release` and is wanted again when the room returns is computed again, not taken
    /// from the old job. Red under: `release` not invalidating the spectrum lane.
    @MainActor func testASpectrumRunningAtReleaseIsNotTakenWhenTheRoomReturns() async throws {
        let rig = makeRig()
        rig.owner.show(Self.plant(), contentVersion: 1)
        try await until("job 0 starts") { await rig.spectra.asked.count == 1 }
        rig.owner.release()
        rig.owner.show(Self.plant(), contentVersion: 1)
        await rig.finishSpectrum(0)
        try await until("job 1 starts") { await rig.spectra.asked.count == 2 }
        XCTAssertNil(rig.owner.spectrum, "job 0 began before the release")
        await rig.finishSpectrum(1)
        try await until("job 1 lands") { rig.owner.isSpectrumCurrent }
    }

    // MARK: - The masked inverse

    /// The masked inverse is wanted only while the pane shows it, and only from the spots measured on the spectrum shown
    /// and in the mask: a refused spot (no centroid) and a spot taken out are not in it. Red under: a refused spot in the
    /// mask; In Mask ignored; the inverse computed while not shown; the inverse kept after the pane leaves it.
    @MainActor func testTheInverseIsComputedOnlyWhileShownAndOnlyFromMeasuredInMaskSpots() async throws {
        let rig = try await landed()
        let first = try Self.measured(row: 37, col: 40), third = try Self.measured(row: 29, col: 44)
        try await measure(rig, row: 37, col: 40, .measured(first))
        try await measure(rig, row: 31, col: 33, .refused(.nearDC))
        try await measure(rig, row: 29, col: 44, .measured(third))
        rig.owner.setInMask(rig.owner.spots[2].id, false)
        try await settle()
        var asked = await rig.masks.asked.count
        XCTAssertEqual(asked, 0, "nothing is computed while the pane shows the file")
        XCTAssertNil(rig.owner.maskedInverse)

        rig.owner.setSourceView(.maskedInverse)
        try await until("the inverse starts") { await rig.masks.asked.count == 1 }
        let key = await rig.masks.asked[0]
        let spectrumKey = FFTSpectrumKey(contentVersion: 1, crop: Self.regionA)
        XCTAssertEqual(key, FFTMaskKey(spectrum: spectrumKey, spots: [
            first.maskSpot(radius: FFTMask.defaultRadius, edge: FFTMask.defaultEdge)]),
                       "one spot: the refused one has no centroid, the third is out of the mask")
        await rig.finishMask(0)
        try await until("the inverse lands") { rig.owner.maskedInverse != nil }
        XCTAssertTrue(rig.owner.isMaskedInverseCurrent)

        rig.owner.setInMask(rig.owner.spots[2].id, true)
        try await until("the inverse follows In Mask") { await rig.masks.asked.count == 2 }
        let both = await rig.masks.asked[1]
        XCTAssertEqual(both.spots.count, 2)
        await rig.finishMask(1)
        try await until("the second inverse lands") { rig.owner.maskedInverse?.key == both }

        rig.owner.setSourceView(.original)
        XCTAssertNil(rig.owner.maskedInverse, "held only while shown")
        try await settle()
        asked = await rig.masks.asked.count
        XCTAssertEqual(asked, 2)
    }

    /// With no measured in-mask spot there is no inverse and nothing is computed. Red under: a job asked with no spots.
    @MainActor func testWithNoSpotInTheMaskNothingIsComputed() async throws {
        let rig = try await landed()
        rig.owner.setSourceView(.maskedInverse)
        rig.owner.measureSpot(row: 37, col: 40)             // still measuring
        try await settle()
        var asked = await rig.masks.asked.count
        XCTAssertEqual(asked, 0, "a spot not yet measured is not in the mask")
        XCTAssertNil(rig.owner.maskedInverse)
        try await until("the spot starts") { await rig.spotJobs.asked.count == 1 }
        await rig.spotJobs.finish(0, .success(.refused(.nearEdge)))
        try await until("the refusal lands") { rig.owner.spots.first.map { if case .measuring = $0.outcome { false } else { true } } ?? false }
        try await settle()
        asked = await rig.masks.asked.count
        XCTAssertEqual(asked, 0, "a refused spot is not in the mask")
    }

    /// A spot the estimator answered with no number has no centroid: it is not in the mask, and the masked inverse that the
    /// pane shows does not wait for it for ever. The core answers a window of zero or non-finite power (a constant region)
    /// with NaN rather than a refusal; the owner now shows the kit's `.noPower` refusal. On the live compute: a region of the constant half
    /// of the image gives a peakless spot, `hasMaskSpot` stays false (the pane says "No masked inverse yet", not "Computing…"),
    /// no inverse is wanted or asked for and none fails; the lattice region of the same image still measures and its inverse
    /// lands. Red under: the NaN answer wrapped as measured (the spot is in the mask, its key never equals itself, the
    /// inverse never lands, `maskFailure` stays nil).
    @MainActor func testASpotWithNoPeakIsNeverInTheMaskAndTheInverseDoesNotWaitForIt() async throws {
        let owner = FFTAnalysis()
        owner.setRegion(Self.flatRegion, committed: true)
        owner.show(Self.halfFlat(), contentVersion: 1)
        try await until("the spectrum of the constant region lands") { owner.isSpectrumCurrent }
        owner.measureSpot(row: 37, col: 40)
        try await until("the spot is answered") {
            guard let spot = owner.spots.first else { return false }
            if case .measuring = spot.outcome { return false }
            return true
        }
        guard case .refused(.noPower) = owner.spots[0].outcome else { return XCTFail("no power here: \(owner.spots[0].outcome)") }
        XCTAssertNil(owner.spots[0].measured)
        XCTAssertFalse(owner.hasMeasuredSpot)
        XCTAssertFalse(owner.hasMaskSpot, "a peakless spot is not a spot in the mask")
        owner.setSourceView(.maskedInverse)
        try await settle()
        XCTAssertNil(owner.wantedMaskKey, "nothing to pass")
        XCTAssertNil(owner.maskedInverse)
        XCTAssertNil(owner.maskFailure)

        // The same image, on its lattice: a spot measures, and its inverse lands.
        owner.setRegion(Self.regionA, committed: true)
        try await until("the lattice region's spectrum lands") { owner.isSpectrumCurrent && owner.spectrum?.key.crop == Self.regionA }
        owner.measureSpot(row: 37, col: 40)
        try await until("the lattice spot is measured") { owner.spots.first?.measured != nil }
        XCTAssertTrue(owner.hasMaskSpot)
        owner.setSourceView(.maskedInverse)
        try await until("the masked inverse lands") { owner.isMaskedInverseCurrent }
    }

    /// Defence in depth: a spot that IS measured with a centre that is not a number (an answer injected, as the core can give
    /// one for a constant image) is left out of the mask key, which could never equal itself — no job is asked for it.
    /// Red under: the finite check removed from `wantedMaskKey` (a key with NaN centres is wanted and asked for).
    @MainActor func testASpotWhoseCentreIsNotANumberIsNeverInTheMaskKey() async throws {
        let finite = try Self.measured(row: 37, col: 40)
        let nan = SpotMeasurement(
            clickedRow: finite.clickedRow, clickedCol: finite.clickedCol, snappedRow: finite.snappedRow, snappedCol: finite.snappedCol,
            centroidRow: .nan, centroidCol: .nan, width: finite.width, height: finite.height, qx: finite.qx, qy: finite.qy, q: finite.q,
            d: finite.d, units: finite.units, reciprocalUnits: finite.reciprocalUnits, neighbour: finite.neighbour, precision: finite.precision)
        let rig = try await landed()
        try await measure(rig, row: 37, col: 40, .measured(nan))
        XCTAssertNotNil(rig.owner.spots[0].measured)
        rig.owner.setSourceView(.maskedInverse)
        try await settle()
        XCTAssertNil(rig.owner.wantedMaskKey)
        let asked = await rig.masks.asked.count
        XCTAssertEqual(asked, 0, "no job for a mask that could never land")
        XCTAssertNil(rig.owner.maskedInverse)
        // A finite spot beside it is the whole key.
        let good = try Self.measured(row: 29, col: 44)
        try await measure(rig, row: 29, col: 44, .measured(good))
        try await until("the inverse of the finite spot starts") { await rig.masks.asked.count == 1 }
        let key = await rig.masks.asked[0]
        XCTAssertEqual(key.spots, [good.maskSpot(radius: FFTMask.defaultRadius, edge: FFTMask.defaultEdge)])
    }

    /// The owner tells the two causes of there being no masked inverse apart: no spot is measured (refused, peakless and
    /// measuring spots have no centroid), or spots are measured but none is In Mask. Red under: `hasMaskSpot` standing for
    /// both; a refused or peakless spot counted as measured.
    @MainActor func testTheOwnerTellsNoSpotFromNoSpotInTheMask() async throws {
        let rig = try await landed()
        XCTAssertFalse(rig.owner.hasMeasuredSpot)
        XCTAssertFalse(rig.owner.hasMaskSpot)
        try await measure(rig, row: 31, col: 33, .refused(.nearDC))
        try await measure(rig, row: 29, col: 44, .refused(.noPower))
        XCTAssertEqual(rig.owner.spots.count, 2)
        XCTAssertFalse(rig.owner.hasMeasuredSpot, "a refusal and a peakless spot are not measured")
        XCTAssertFalse(rig.owner.hasMaskSpot)
        try await measure(rig, row: 37, col: 40, .measured(try Self.measured(row: 37, col: 40)))
        XCTAssertTrue(rig.owner.hasMeasuredSpot)
        XCTAssertTrue(rig.owner.hasMaskSpot)
        let measured = try XCTUnwrap(rig.owner.spots.last)
        rig.owner.setInMask(measured.id, false)
        XCTAssertTrue(rig.owner.hasMeasuredSpot, "measured, and out of the mask")
        XCTAssertFalse(rig.owner.hasMaskSpot)
        rig.owner.setInMask(measured.id, true)
        XCTAssertTrue(rig.owner.hasMaskSpot)
        rig.owner.removeAllSpots()
        XCTAssertFalse(rig.owner.hasMeasuredSpot)
        XCTAssertFalse(rig.owner.hasMaskSpot)
    }

    /// The mask's radius and edge are clamped to the registered ranges, a value that is not a number leaves the current
    /// one, and the inverse follows the mask: while a job runs the newest mask waits, the ones between are never
    /// computed. Red under: no clamp; the inverse not asked again when the mask changes; the oldest mask kept pending.
    @MainActor func testTheMaskIsClampedAndTheInverseFollowsIt() async throws {
        let (rig, _) = try await everything()
        rig.owner.setMask(radius: 100, edge: -4)
        XCTAssertEqual(rig.owner.maskRadius, 32)
        XCTAssertEqual(rig.owner.maskEdge, 0)
        try await until("the inverse is asked for the first mask") { await rig.masks.asked.count == 2 }
        rig.owner.setMask(radius: 0.2, edge: 99)
        XCTAssertEqual(rig.owner.maskRadius, 1)
        XCTAssertEqual(rig.owner.maskEdge, 16)
        rig.owner.setMask(radius: .nan, edge: 5)
        XCTAssertEqual(rig.owner.maskRadius, 1, "a value that is not a number leaves the radius")
        XCTAssertEqual(rig.owner.maskEdge, 5)
        await rig.finishMask(1)
        try await until("the newest mask is asked for") { await rig.masks.asked.count == 3 }
        let asked = await rig.masks.asked
        XCTAssertEqual(asked[1].spots.map(\.radius), [32])
        XCTAssertEqual(asked[2].spots.map(\.radius), [1])
        XCTAssertEqual(asked[2].spots.map(\.edge), [5], "the mask between (edge 16) was never computed")
        XCTAssertEqual(rig.owner.maskedInverse?.key.spots.first?.radius, FFTMask.defaultRadius,
                       "the answer for radius 32 was for a mask no longer wanted: dropped, the one shown stays")
        await rig.finishMask(2)
        try await until("the newest inverse lands") { rig.owner.isMaskedInverseCurrent }
        XCTAssertEqual(rig.owner.maskedInverse?.key, asked[2])
    }

    // MARK: - The filters

    /// Filter asks once for the transformed square; ABSF is shown when it lands. Red under: the pane left on the file;
    /// `isFiltering` left on.
    @MainActor func testFilterAsksOnceAndShowsAbsfWhenItLands() async throws {
        let rig = try await landed()
        XCTAssertFalse(rig.owner.isFiltering)
        rig.owner.runFilter()
        XCTAssertTrue(rig.owner.isFiltering)
        try await until("the filter starts") { await rig.filters.asked.count == 1 }
        let key = await rig.filters.asked[0]
        XCTAssertEqual(key, FFTFilterKey(spectrum: FFTSpectrumKey(contentVersion: 1, crop: Self.regionA), parameters: .defaults))
        XCTAssertEqual(rig.owner.sourceView, .original, "the pane changes when the result lands, not before")
        await rig.finishFilter(0)
        try await until("the filter lands") { rig.owner.filtered != nil }
        XCTAssertFalse(rig.owner.isFiltering)
        XCTAssertEqual(rig.owner.sourceView, .absf)
        XCTAssertNil(rig.owner.filterFailure)
        rig.owner.runFilter()
        try await settle()
        let asked = await rig.filters.asked.count
        XCTAssertEqual(asked, 1, "this very run is on screen")
    }

    /// New parameters remove the last run's result — and the answer of a run still going. Red under: the result kept;
    /// the pane left on a product that is gone; a run's answer published after its parameters changed.
    @MainActor func testNewFilterParametersRemoveTheResult() async throws {
        let rig = try await landed()
        rig.owner.runFilter()
        try await until("the filter starts") { await rig.filters.asked.count == 1 }
        var changed = HRTEMFilter.Parameters.defaults
        changed.delta = 8
        rig.owner.setFilterParameters(changed)
        XCTAssertFalse(rig.owner.isFiltering, "the run asked for is no longer wanted")
        await rig.finishFilter(0)
        try await settle()
        XCTAssertNil(rig.owner.filtered, "the answer was for the old parameters")
        XCTAssertEqual(rig.owner.sourceView, .original)

        rig.owner.runFilter()
        try await until("the second run starts") { await rig.filters.asked.count == 2 }
        await rig.finishFilter(1)
        try await until("the second run lands") { rig.owner.filtered != nil }
        XCTAssertEqual(rig.owner.sourceView, .absf)
        var again = changed
        again.step = 3
        rig.owner.setFilterParameters(again)
        XCTAssertNil(rig.owner.filtered)
        XCTAssertEqual(rig.owner.sourceView, .original, "an ABSF view falls back with its result")
        XCTAssertEqual(rig.owner.filterParameters, again)
    }

    /// Pixels the filters cannot take are refused in plain words that point at Use Centred Square, with nothing asked.
    /// Red under: the filterable check removed (a job is asked on 96 × 64); the refusal not worded.
    @MainActor func testFilterOnASizeItCannotTakeFailsInWords() async throws {
        let rig = try await landed(region: nil)
        rig.owner.runFilter()
        let failure = try XCTUnwrap(rig.owner.filterFailure)
        XCTAssertTrue(failure.contains("96 × 64"), failure)
        XCTAssertTrue(failure.contains("Use Centred Square"), failure)
        XCTAssertFalse(rig.owner.isFiltering)
        try await settle()
        let asked = await rig.filters.asked.count
        XCTAssertEqual(asked, 0)
    }

    /// A parameter out of its range is refused with the core's own words, before any job. Red under: the range check
    /// removed (a job is asked with delta 60).
    @MainActor func testAnOutOfRangeFilterParameterIsRefusedInTheCoresWords() async throws {
        let rig = try await landed()
        var bad = HRTEMFilter.Parameters.defaults
        bad.delta = 60
        rig.owner.setFilterParameters(bad)
        rig.owner.runFilter()
        XCTAssertEqual(rig.owner.filterFailure, HRTEMFilterError.parameterOutOfRange("delta").errorDescription)
        try await settle()
        let asked = await rig.filters.asked.count
        XCTAssertEqual(asked, 0)
    }

    /// A refusal is news of the last Filter press only: committing a square the filters can take (Use Centred Square,
    /// the refusal's own button) clears it, and Filter then asks for that square. Red under: the refusal kept across a
    /// committed region.
    @MainActor func testACommittedRegionClearsAFilterRefusal() async throws {
        let rig = try await landed(region: nil)
        rig.owner.runFilter()
        XCTAssertNotNil(rig.owner.filterFailure, "the whole 96 × 64 image is not square")
        let centred = try XCTUnwrap(FFTRegion.centredSquare(width: 96, height: 64))
        rig.owner.setRegion(centred, committed: true)
        XCTAssertNil(rig.owner.filterFailure, "the refusal was for the whole image")
        rig.owner.runFilter()
        try await until("the filter starts") { await rig.filters.asked.count == 1 }
        let key = await rig.filters.asked[0]
        XCTAssertEqual(key.spectrum.crop, centred)
    }

    /// New parameters clear a refusal of the old ones, and Filter then runs on them. Red under: the refusal kept across
    /// new parameters.
    @MainActor func testNewFilterParametersClearARefusal() async throws {
        let rig = try await landed()
        var bad = HRTEMFilter.Parameters.defaults
        bad.delta = 60
        rig.owner.setFilterParameters(bad)
        rig.owner.runFilter()
        XCTAssertNotNil(rig.owner.filterFailure)
        rig.owner.setFilterParameters(.defaults)
        XCTAssertNil(rig.owner.filterFailure, "the refusal was of delta 60")
        rig.owner.runFilter()
        try await until("the filter starts") { await rig.filters.asked.count == 1 }
        let key = await rig.filters.asked[0]
        XCTAssertEqual(key.parameters, .defaults)
    }

    // MARK: - Failures, in words

    /// A job that throws leaves no product for its key and says why, in the core's words or a plain sentence. Red under:
    /// the failure swallowed; a failure published for a key no longer wanted.
    @MainActor func testAFailureIsReportedInWords() async throws {
        let rig = makeRig()
        rig.owner.setRegion(Self.regionA, committed: true)
        rig.owner.show(Self.plant(), contentVersion: 1)
        try await until("the spectrum is asked for") { await rig.spectra.asked.count == 1 }
        await rig.spectra.finish(0, .failure(PowerSpectrumError.crop(Self.regionA)))
        try await until("the failure lands") { rig.owner.spectrumFailure != nil }
        XCTAssertNil(rig.owner.spectrum)
        let words = try XCTUnwrap(rig.owner.spectrumFailure)
        XCTAssertTrue(words.contains("64 × 64"), words)
        rig.owner.setRegion(Self.regionB, committed: false)
        XCTAssertNil(rig.owner.spectrumFailure, "asked again: the last failure is not the new answer's")

        let withFilter = try await landed()
        withFilter.owner.runFilter()
        try await until("the filter starts") { await withFilter.filters.asked.count == 1 }
        await withFilter.filters.finish(0, .failure(HRTEMFilterError.nonFinitePixel))
        try await until("the filter's failure lands") { withFilter.owner.filterFailure != nil }
        XCTAssertEqual(withFilter.owner.filterFailure, HRTEMFilterError.nonFinitePixel.errorDescription)
        XCTAssertNil(withFilter.owner.filtered)
        XCTAssertFalse(withFilter.owner.isFiltering)
    }

    /// A masked inverse that cannot be computed leaves no product and says why; the words go when the inverse is no
    /// longer wanted. Red under: the failure swallowed; the failure kept after the pane leaves the inverse.
    @MainActor func testAMaskedInverseFailureIsReportedInWords() async throws {
        let rig = try await landed()
        try await measure(rig, row: 37, col: 40, .measured(try Self.measured(row: 37, col: 40)))
        rig.owner.setSourceView(.maskedInverse)
        try await until("the inverse starts") { await rig.masks.asked.count == 1 }
        await rig.masks.finish(0, .failure(MaskedInverseFFTError.fftSetup(width: 64, height: 64)))
        try await until("the failure lands") { rig.owner.maskFailure != nil }
        XCTAssertNil(rig.owner.maskedInverse)
        let words = try XCTUnwrap(rig.owner.maskFailure)
        XCTAssertTrue(words.contains("64 × 64"), words)
        rig.owner.setSourceView(.original)
        XCTAssertNil(rig.owner.maskFailure, "nothing asked of the inverse: nothing failed")
    }

    // MARK: - P1, the products equal their cores

    private func finite(_ values: [Float]) -> ClosedRange<Float>? {
        let finite = values.filter(\.isFinite)
        guard let low = finite.min(), let high = finite.max() else { return nil }
        return low...high
    }

    /// The live spectrum of a region is the core's: its display canvas, its histogram, its range, its default window, its
    /// radial profile, its axes, and the transformed pixels alone for the Region view. Red under: the spectrum of the
    /// whole image; the canvas normalised another way; the profile of another width; the region canvas drawn from the
    /// uncropped image; spacings swapped.
    func testTheLiveSpectrumIsTheCoresOnTheRegion() async throws {
        let image = Self.plant()
        let key = FFTSpectrumKey(contentVersion: 5, crop: Self.regionA)
        let product = try await FFTCompute.live.spectrum(image, key)

        let spectrum = try PowerSpectrum.compute(image.micrograph, crop: Self.regionA)
        let display = SpectrumDisplay.make(spectrum)
        XCTAssertEqual(product.key, key)
        XCTAssertEqual(product.width, 64)
        XCTAssertEqual(product.height, 64)
        XCTAssertEqual(product.spacingX, spectrum.spacingX)
        XCTAssertEqual(product.spacingY, spectrum.spacingY)
        XCTAssertNotEqual(product.spacingX, product.spacingY, "the planted pixels are anisotropic")
        XCTAssertEqual(product.unitsX, "1/nm")
        XCTAssertEqual(product.unitsY, "1/nm")
        XCTAssertEqual(product.canvas.width, 64)
        XCTAssertEqual(product.canvas.height, 64)
        XCTAssertEqual(product.canvas.normalized, FloatImage(width: 64, height: 64, pixels: display.values).normalized(),
                       "element for element")
        XCTAssertEqual(product.canvas.rawRange, finite(display.values))
        XCTAssertEqual(product.canvas.histogram, IntensityHistogram.compute(display.values))
        XCTAssertEqual(product.defaultWindow, display.defaultWindow)

        let profile = try XCTUnwrap(product.profile)
        let expected = try RadialProfile.compute(spectrum)
        XCTAssertEqual(profile.width, expected.width)
        XCTAssertEqual(profile.units, expected.units)
        XCTAssertEqual(profile.mean, expected.mean)
        XCTAssertEqual(profile.count, expected.count)

        let cropped = try XCTUnwrap(image.micrograph.cropped(Self.regionA))
        XCTAssertEqual(product.region.width, 64)
        XCTAssertEqual(product.region.height, 64)
        XCTAssertEqual(product.region.normalized, FloatImage(width: 64, height: 64, pixels: cropped.pixels).normalized())
        XCTAssertEqual(product.region.rawRange, finite(cropped.pixels))
        XCTAssertNil(product.region.histogram)
    }

    /// The whole image: any shape, no crop. Red under: the width and height swapped; a crop made up for the whole image.
    func testTheLiveSpectrumOfTheWholeImageIsTheCores() async throws {
        let image = Self.plant()
        let product = try await FFTCompute.live.spectrum(image, FFTSpectrumKey(contentVersion: 5, crop: nil))
        let spectrum = try PowerSpectrum.compute(image.micrograph)
        let display = SpectrumDisplay.make(spectrum)
        XCTAssertEqual(product.width, 96)
        XCTAssertEqual(product.height, 64)
        XCTAssertEqual(product.canvas.width, 96)
        XCTAssertEqual(product.canvas.height, 64)
        XCTAssertEqual(product.canvas.normalized, FloatImage(width: 96, height: 64, pixels: display.values).normalized())
        XCTAssertEqual(product.region.normalized, FloatImage(width: 96, height: 64, pixels: image.pixels).normalized())
        XCTAssertEqual(product.spacingX, spectrum.spacingX)
        XCTAssertEqual(product.spacingY, spectrum.spacingY)
    }

    /// A crop outside the image is the core's failure, not a made-up product. Red under: the crop clamped or ignored.
    func testTheLiveSpectrumOfARegionOutsideTheImageFails() async throws {
        let outside = PixelCrop(row: 0, col: 64, height: 64, width: 64)
        do {
            _ = try await FFTCompute.live.spectrum(Self.plant(), FFTSpectrumKey(contentVersion: 1, crop: outside))
            XCTFail("a region outside the image was transformed")
        } catch let failure as PowerSpectrumError {
            XCTAssertEqual(failure, .crop(outside))
        }
    }

    /// The live spot is the estimator's answer on the same crop and bin, or its refusal. Red under: the crop dropped
    /// (the whole image measured); row and column swapped; a refusal turned into a measurement.
    func testTheLiveSpotIsTheEstimatorsAnswerOrRefusal() async throws {
        let image = Self.plant()
        let outcome = await FFTCompute.live.spot(image, FFTSpectrumKey(contentVersion: 0, crop: Self.regionA), 37, 40)
        let direct = try SpotMeasurement.measure(image.micrograph, crop: Self.regionA, clickRow: 37, clickColumn: 40)
        guard case .measured(let m) = outcome else { return XCTFail("a lattice spot was not measured: \(outcome)") }
        XCTAssertEqual(m.d, direct.d)
        XCTAssertEqual(m.centroidRow, direct.centroidRow)
        XCTAssertEqual(m.centroidCol, direct.centroidCol)
        XCTAssertEqual(m.snappedRow, direct.snappedRow)
        XCTAssertEqual(m.snappedCol, direct.snappedCol)
        XCTAssertEqual(m.units, direct.units)
        // The planted lattice (8, 5) cycles per 64 px: d = 1 / |q| with each axis's own step.
        let q = ((8 / (64 * 0.05)) * (8 / (64 * 0.05)) + (5 / (64 * 0.04)) * (5 / (64 * 0.04))).squareRoot()
        XCTAssertEqual(m.d, 1 / q, accuracy: 0.002 / q)

        let nearDC = await FFTCompute.live.spot(image, FFTSpectrumKey(contentVersion: 0, crop: Self.regionA), 32, 32)
        guard case .refused(.nearDC) = nearDC else { return XCTFail("a click on the DC was not refused: \(nearDC)") }
        let nearEdge = await FFTCompute.live.spot(image, FFTSpectrumKey(contentVersion: 0, crop: Self.regionA), 62, 62)
        guard case .refused(.nearEdge) = nearEdge else { return XCTFail("a click beside the edge was not refused: \(nearEdge)") }
        let outside = PixelCrop(row: 0, col: 64, height: 64, width: 64)
        let none = await FFTCompute.live.spot(image, FFTSpectrumKey(contentVersion: 0, crop: outside), 37, 40)
        guard case .refused(.crop(let refusedCrop)) = none else { return XCTFail("a region outside the image was measured: \(none)") }
        XCTAssertEqual(refusedCrop, outside)
    }

    /// The live spot of pixels with no power to measure — constant, all zero, one NaN pixel, a constant region of a lattice
    /// image — is the kit's own refusal (`.noPower`, or `.nonFinite` for the NaN), not a measurement with a NaN d, |q| and centroid and
    /// not an app-side guard (ImagoKit 0.6.0 refuses by name). The lattice on the same click still measures. Red under: an app guard that
    /// maps the refusal to another outcome; the NaN answer wrapped as `.measured`.
    func testTheLiveSpotOfPixelsWithNoPowerHasNoPeak() async throws {
        let cases: [(String, CalibratedImage, PixelCrop?, SpotMeasurementError)] = [
            ("constant", Self.flat(), nil, .noPower), ("zero", Self.flat(value: 0), nil, .noPower),
            ("one NaN pixel", Self.flat(nan: true), nil, .nonFinite), ("the constant half", Self.halfFlat(), Self.flatRegion, .noPower)]
        for (what, image, crop, expected) in cases {
            XCTAssertThrowsError(try SpotMeasurement.measure(image.micrograph, crop: crop, clickRow: 20, clickColumn: 40),
                                 "the setup: the core refuses (noPower or nonFinite, ImagoKit 0.6.0) for \(what)")
            let outcome = await FFTCompute.live.spot(image, FFTSpectrumKey(contentVersion: 0, crop: crop), 20, 40)
            guard case .refused(let kitError) = outcome else { return XCTFail("\(what): not the kit's refusal: \(outcome)") }
            XCTAssertEqual(kitError, expected, what)
        }
        let lattice = await FFTCompute.live.spot(Self.halfFlat(), FFTSpectrumKey(contentVersion: 0, crop: Self.regionA), 37, 40)
        guard case .measured(let m) = lattice else { return XCTFail("the lattice region was not measured: \(lattice)") }
        XCTAssertTrue(m.d.isFinite && m.q.isFinite && m.centroidRow.isFinite && m.centroidCol.isFinite)
    }

    /// The live masked inverse is the core's on the transformed pixels with the key's spots. Red under: the inverse of
    /// the uncropped image; the canvas not normalised; the imaginary part dropped.
    func testTheLiveMaskedInverseIsTheCoresOnTheRegion() async throws {
        let image = Self.plant()
        let spots = [MaskedInverseFFT.Spot(kx: 8, ky: 5, radius: 3, edge: 2), MaskedInverseFFT.Spot(kx: 12, ky: -3, radius: 2, edge: 0)]
        let key = FFTMaskKey(spectrum: FFTSpectrumKey(contentVersion: 5, crop: Self.regionA), spots: spots)
        let product = try await FFTCompute.live.maskedInverse(image, key)
        let cropped = try XCTUnwrap(image.micrograph.cropped(Self.regionA))
        let direct = try MaskedInverseFFT.compute(cropped, spots: spots)
        XCTAssertEqual(product.key, key)
        XCTAssertEqual(product.canvas.width, 64)
        XCTAssertEqual(product.canvas.height, 64)
        XCTAssertEqual(product.canvas.normalized, FloatImage(width: 64, height: 64, pixels: direct.image.float32Values).normalized())
        XCTAssertEqual(product.canvas.rawRange, finite(direct.image.float32Values))
        XCTAssertEqual(product.imaginaryMax, direct.imaginaryMax)
        let wholeImage = try MaskedInverseFFT.compute(image.micrograph, spots: spots)
        XCTAssertNotEqual(wholeImage.width, product.canvas.width, "the whole image is another size")
    }

    /// The live filter is the core's on the transformed pixels, both outputs and the run's counts; on a square image the
    /// uncropped filter is also valid and differs. Red under: the filter on the uncropped image; ABSF and Wiener
    /// swapped; the counts of another run.
    func testTheLiveFilterIsTheCoresOnTheRegion() async throws {
        for image in [Self.plant(), Self.plant(width: 96, height: 96)] {
            let crop = image.height == 96 ? PixelCrop(row: 16, col: 16, height: 64, width: 64) : Self.regionA
            var parameters = HRTEMFilter.Parameters.defaults
            parameters.delta = 4
            let key = FFTFilterKey(spectrum: FFTSpectrumKey(contentVersion: 5, crop: crop), parameters: parameters)
            let product = try await FFTCompute.live.filter(image, key)
            let cropped = try XCTUnwrap(image.micrograph.cropped(crop))
            let direct = try HRTEMFilter.filter(cropped, parameters: parameters)
            let outputs = try HRTEMFilter.outputs(direct, like: cropped)
            XCTAssertEqual(product.key, key)
            XCTAssertEqual(product.absf.width, 64)
            XCTAssertEqual(product.absf.normalized, FloatImage(width: 64, height: 64, pixels: outputs.absf.pixels).normalized())
            XCTAssertEqual(product.wiener.normalized, FloatImage(width: 64, height: 64, pixels: outputs.wiener.pixels).normalized())
            XCTAssertNotEqual(product.absf.normalized, product.wiener.normalized)
            XCTAssertEqual(product.absf.rawRange, finite(outputs.absf.pixels))
            XCTAssertEqual(product.n, direct.n)
            XCTAssertEqual(product.passes, direct.passes)
            XCTAssertEqual(product.finalDelta, direct.finalDelta)
            if image.height == 96 {
                let whole = try HRTEMFilter.filter(image.micrograph, parameters: parameters)
                XCTAssertNotEqual(whole.n, product.absf.width, "the uncropped image is another size")
            }
        }
    }

    /// A filter run on pixels it cannot take throws the core's failure. Red under: a square cut from the image behind
    /// the user's back.
    func testTheLiveFilterOfTheWholeNonSquareImageIsRefused() async throws {
        let key = FFTFilterKey(spectrum: FFTSpectrumKey(contentVersion: 5, crop: nil), parameters: .defaults)
        do {
            _ = try await FFTCompute.live.filter(Self.plant(), key)
            XCTFail("a 96 × 64 image was filtered")
        } catch let failure as HRTEMFilterError {
            XCTAssertEqual(failure, .notSquare(width: 96, height: 64))
        }
    }

    /// Every canvas takes a fresh version from a serial far above small integers, so a product is never mistaken for
    /// another's texture and never equals a hash by accident. Red under: a constant or hashed version; one version for
    /// the spectrum and the region.
    func testProductCanvasesTakeFreshVersions() async throws {
        let key = FFTSpectrumKey(contentVersion: 5, crop: Self.regionA)
        let one = try await FFTCompute.live.spectrum(Self.plant(), key)
        let two = try await FFTCompute.live.spectrum(Self.plant(), key)
        let versions = [one.canvas.contentVersion, one.region.contentVersion, two.canvas.contentVersion, two.region.contentVersion]
        XCTAssertEqual(Set(versions).count, 4, "each canvas, each time")
        for version in versions { XCTAssertGreaterThanOrEqual(version, 1 << 62) }
        XCTAssertEqual(one.canvas.normalized, two.canvas.normalized, "equal in value, still two textures")
    }

    // MARK: - The owner on the live compute

    /// The room end to end on `FFTCompute.live`, off the main actor: a region's spectrum lands, a click measures the
    /// planted lattice, the masked inverse and the filter land, and `release` takes them away. Red under: any lane
    /// failing to publish; the live closures not wired to the cores.
    @MainActor func testTheRoomRunsOnTheLiveCompute() async throws {
        let owner = FFTAnalysis()
        owner.setRegion(Self.regionA, committed: true)
        owner.show(Self.plant(), contentVersion: 7)
        try await until("the spectrum lands") { owner.isSpectrumCurrent }
        XCTAssertEqual(owner.spectrum?.key, FFTSpectrumKey(contentVersion: 7, crop: Self.regionA))
        XCTAssertNotNil(owner.spectrum?.profile)
        XCTAssertNil(owner.spectrumFailure)

        owner.measureSpot(row: 37, col: 40)
        try await until("the spot is measured") { owner.spots.first?.measured != nil }
        let q = ((8 / (64 * 0.05)) * (8 / (64 * 0.05)) + (5 / (64 * 0.04)) * (5 / (64 * 0.04))).squareRoot()
        let d = try XCTUnwrap(owner.spots.first?.measured?.d)
        XCTAssertEqual(d, 1 / q, accuracy: 0.002 / q, "the planted lattice's d")

        owner.setSourceView(.maskedInverse)
        try await until("the masked inverse lands") { owner.isMaskedInverseCurrent }
        XCTAssertEqual(owner.maskedInverse?.canvas.width, 64)

        owner.runFilter()
        try await until("the filter lands") { owner.filtered != nil }
        XCTAssertEqual(owner.sourceView, .absf)
        XCTAssertEqual(owner.filtered?.n, 64)
        XCTAssertNil(owner.filterFailure)

        owner.setRegion(Self.regionC, committed: true)
        try await until("the new region's spectrum lands") { owner.isSpectrumCurrent }
        XCTAssertTrue(owner.spots.isEmpty)
        XCTAssertNil(owner.filtered)
        XCTAssertEqual(owner.spectrum?.key.crop, Self.regionC)

        owner.release()
        XCTAssertNil(owner.spectrum)
        XCTAssertNil(owner.maskedInverse)
    }

    /// A spot's angle is the kit's `SpotMeasurement.angle` to the first measured spot; the reference has none, a refused spot has none, and removing the reference
    /// moves it to the next measured one. Red under: the angle taken to the previous spot (the third spot's angle changes with the second).
    @MainActor func testAngleIsToTheFirstMeasuredSpot() throws {
        let a = try Self.measured(row: 37, col: 40), b = try Self.measured(row: 29, col: 44), c = try Self.measured(row: 31, col: 33)
        func spot(_ n: Int, _ outcome: FFTSpot.Outcome) -> FFTSpot { FFTSpot(number: n, row: 0, col: 0, spectrumKey: FFTSpectrumKey(contentVersion: 1, crop: nil), outcome: outcome) }
        let spots = [spot(1, .refused(.nearDC)), spot(2, .measured(a)), spot(3, .measured(b)), spot(4, .measuring), spot(5, .measured(c))]
        let angles = FFTSpotAngles.angles(spots)
        XCTAssertNil(angles[spots[0].id]); XCTAssertNil(angles[spots[1].id], "the reference has no angle"); XCTAssertNil(angles[spots[3].id])
        XCTAssertEqual(angles[spots[2].id]?.reference, 2)
        XCTAssertEqual(try XCTUnwrap(angles[spots[2].id]).degrees, try SpotMeasurement.angle(a, b), accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(angles[spots[4].id]).degrees, try SpotMeasurement.angle(a, c), accuracy: 1e-12)
        let without = FFTSpotAngles.angles(Array(spots.dropFirst(2)))
        XCTAssertNil(without[spots[2].id], "the first measured spot is the reference now")
        XCTAssertEqual(without[spots[4].id]?.reference, 3)
    }
}
