//
//  EDXSessionTests.swift
//  The EDX room's owner, `EDXSession` (TEMSession), and its compute (`EDXCompute`, TEMCore), on a planted spectrum.
//
//  THE TRUTH: `Fixtures/edx-planted-cell.json` is one noise-free Al-Mg-Si spectrum from SpectroKit's planted set
//  (Tests/SpectroEDXTests/Fixtures, cell M.s.N6.rho0p05, rounded to counts) with its planted true line areas: Al 1e6, Mg 5e4,
//  Si 1e4 counts. The room puts it in the left pixel of a 2 x 1 spectrum image, half of it in the right one.
//
//  WHAT IS PINNED, and how (D12): sums, windows and maps are integer counts and are exact; the fit through the room is the
//  kit's own `PooledQuantifier.run` on the same input and must equal it to the bit (the room adds no arithmetic); and the
//  fitted areas are compared with the planted truth within a tolerance written where it is used. The kit's own gates
//  (SpectroKit docs/edx-stage-gates-registration.md) are the reference for the kit's numbers; these tests are the room's wiring.
//

import XCTest
import SpectroCore
import SpectroEDX
import TEMCore
import TEMSession

nonisolated final class EDXSessionTests: XCTestCase {

    // MARK: The planted image

    struct Planted: Decodable {
        struct Axis: Decodable { let channels: Int; let offset_keV: Double; let scale_keV: Double; let first_channel: Int }
        let axis: Axis
        let areas: [String: Double]
        let counts: [Int]
    }

    static let planted: Planted = {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/edx-planted-cell.json")
        return try! JSONDecoder().decode(Planted.self, from: Data(contentsOf: url))
    }()

    /// The left pixel holds the planted spectrum, the right one half of it (rounded half to even is not needed: counts / 2 floors).
    static func spectra() -> (left: [UInt32], right: [UInt32]) {
        let p = planted
        var left = [UInt32](repeating: 0, count: p.axis.channels), right = left
        for (j, c) in p.counts.enumerated() { left[p.axis.first_channel + j] = UInt32(c); right[p.axis.first_channel + j] = UInt32(c / 2) }
        return (left, right)
    }

    static func source(beam: Double? = 200, geometry: Bool = false, pixelSizeNM: Double? = nil) -> LoadedSpectrumImage {
        let p = planted, (left, right) = spectra()
        var meta = SpectrumImageMetadata(fileName: "planted.emd", filePath: "/data/planted.emd", scanWidth: 2, scanHeight: 1,
                                         channelCount: p.axis.channels, energyOffsetEV: p.axis.offset_keV * 1000,
                                         energyDispersionEV: p.axis.scale_keV * 1000)
        meta.origin = .veloxEMD
        meta.beamEnergyKeV = beam
        if let pixelSizeNM { meta.scanPixelSize = pixelSizeNM; meta.scanPixelUnit = "nm" }
        if geometry {
            // The detector segments of SpectroKit's planted Velox stream (four equal segments), with a tilt the stream does not state.
            let stream = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/velox-stream-spectrum.emd")
            meta.detectors = try! EDXOpening.open(url: stream).metadata.detectors
            meta.alphaTiltDegrees = -16.87; meta.betaTiltDegrees = 0
        }
        return LoadedSpectrumImage(image: DenseSpectrumImage(ny: 1, nx: 2, channels: p.axis.channels, counts: left + right),
                                   metadata: meta, energyAxis: EnergyAxis(offset: p.axis.offset_keV, scale: p.axis.scale_keV, size: p.axis.channels),
                                   scanImage: [10, 20])
    }

    @MainActor private func openRoom(beam: Double? = 200) async -> EDXSession {
        let session = EDXSession()
        await session.bind(Self.source(beam: beam)).value
        await session.settled()
        return session
    }

    // MARK: Open

    /// Opening starts on the whole map and sums every pixel; Auto ID runs on open and applies what it proposes. Red under: the
    /// whole map summed over a mask; Auto ID not run on open; its picks not applied.
    @MainActor func testBindingSumsTheWholeMapAndAutoIDPicksTheElements() async {
        let session = await openRoom()
        let (left, right) = Self.spectra()
        XCTAssertEqual(session.region, .wholeMap)
        XCTAssertEqual(session.spectrumCounts, zip(left, right).map { UInt64($0) + UInt64($1) }, "the whole map is every pixel, exactly")
        XCTAssertEqual(session.regionPixels, 2)
        XCTAssertEqual(session.totalCounts, session.spectrumCounts.reduce(0, +))
        guard case .done(let outcome) = session.autoID else { return XCTFail("Auto ID did not finish: \(session.autoID)") }
        XCTAssertEqual(outcome.region, "Whole map")
        let picked = Set(session.picks.map(\.symbol))
        XCTAssertTrue(picked.isSuperset(of: ["Al", "Mg", "Si"]), "the planted elements are found: \(picked)")
        XCTAssertEqual(session.tiles.count, session.picks.filter { $0.role == .quantify }.count, "a map per quantified element")
        XCTAssertNil(session.fit, "nothing is quantified until the verb")
    }

    /// A file without a beam energy cannot run Auto ID; the sentence says what to type, and typing it makes the run possible.
    /// Red under: Auto ID running without a beam.
    @MainActor func testAutoIDNeedsTheBeamEnergy() async {
        let session = EDXSession()
        await session.bind(Self.source(beam: nil)).value
        XCTAssertEqual(session.autoID, .failed(EDXCompute.autoIDNeedsBeamNote))
        XCTAssertTrue(session.picks.isEmpty)
        session.changeMethod { $0.beamEnergyKeV = 200 }
        XCTAssertEqual(session.beamEnergy, 200)
        await session.runAutoID()?.value
        await session.settled()
        guard case .done = session.autoID else { return XCTFail("\(session.autoID)") }
        XCTAssertTrue(Set(session.picks.map(\.symbol)).isSuperset(of: ["Al", "Mg", "Si"]))
    }

    // MARK: Region

    /// A rectangle sums only its pixels, exactly; the whole map comes back. Red under: the mask ignored; the cache keyed by
    /// the region's name instead of its pixels.
    @MainActor func testARegionSumsItsPixelsOnly() async {
        let session = await openRoom()
        session.selectRectangle(PixelRect(x0: 0, y0: 0, x1: 1, y1: 1))
        await session.settled()
        XCTAssertEqual(session.spectrumCounts, Self.spectra().left.map { UInt64($0) })
        XCTAssertEqual(session.regionPixels, 1)
        XCTAssertEqual(session.regionName, "Region")
        session.selectRectangle(PixelRect(x0: 1, y0: 0, x1: 2, y1: 1))
        await session.settled()
        XCTAssertEqual(session.spectrumCounts, Self.spectra().right.map { UInt64($0) }, "another rectangle is another sum")
        session.selectRectangle(PixelRect(x0: 5, y0: 5, x1: 9, y1: 9))
        XCTAssertEqual(session.region, .rectangle(PixelRect(x0: 1, y0: 0, x1: 2, y1: 1)), "a rectangle off the grid changes nothing")
        session.selectWholeMap()
        await session.settled()
        XCTAssertEqual(session.regionPixels, 2)
        XCTAssertEqual(session.spectrumCounts.reduce(0, +), session.totalCounts)
    }

    // MARK: Elements

    /// A click picks to quantify, a second takes it out and remembers that the person did; Auto ID does not put it back. An
    /// element the line table cannot serve is refused. Fit only keeps the element's lines but gives it no map. Red under: the
    /// dismissed set not consulted; an unavailable element picked; a map for a fit-only element.
    @MainActor func testPicksRolesAndDismissals() async {
        let session = await openRoom()
        XCTAssertTrue(session.picks.contains { $0.symbol == "Al" })
        session.toggle("Al")
        XCTAssertFalse(session.picks.contains { $0.symbol == "Al" })
        XCTAssertTrue(session.dismissed.contains("Al"))
        await session.runAutoID()?.value
        await session.settled()
        XCTAssertFalse(session.picks.contains { $0.symbol == "Al" }, "a person's removal is not undone by Auto ID")
        session.toggle("Al")
        XCTAssertEqual(session.picks.first { $0.symbol == "Al" }?.role, .quantify)
        XCTAssertFalse(session.dismissed.contains("Al"))
        session.setRole(.fitOnly, of: "Al")
        await session.settled()
        XCTAssertEqual(session.picks.first { $0.symbol == "Al" }?.manual, true)
        XCTAssertFalse(session.tiles.contains { $0.symbol == "Al" }, "a fit-only element has no map")
        XCTAssertTrue(session.windowRows.contains { $0.symbol == "Al" }, "but its window is read")
        let before = session.picks
        session.toggle("Be")
        session.toggle("Og")
        XCTAssertEqual(session.picks, before, "no usable line: refused")
        XCTAssertNotNil(EDXElements.unavailableReason(symbol: "Be"))
        XCTAssertNotNil(EDXElements.unavailableReason(symbol: "Og"))
        XCTAssertNil(EDXElements.unavailableReason(symbol: "Al"))
    }

    /// The maps are the kit's, window by window, and the table's counts are the kit's net counts in the region's spectrum. Red
    /// under: a map of the wrong window; counts read from the whole map while a region is selected.
    @MainActor func testMapsAndWindowCountsAreTheKits() async throws {
        let session = await openRoom()
        let source = try XCTUnwrap(session.source)
        XCTAssertFalse(session.tiles.isEmpty)
        XCTAssertFalse(session.windowRows.isEmpty)
        let windows = ElementWindows.build(picks: session.picks.map { ElementWindows.Pick(symbol: $0.symbol) },
                                           axis: source.energyAxis, beamEnergyKeV: source.metadata.beamEnergyKeV)
        let maps = ElementWindows.maps(image: source, windows: windows)
        for tile in session.tiles {
            let i = try XCTUnwrap(windows.firstIndex { $0.element == tile.symbol })
            XCTAssertEqual(tile.values, maps[i], "\(tile.symbol)")
        }
        session.selectRectangle(PixelRect(x0: 0, y0: 0, x1: 1, y1: 1))
        await session.settled()
        let counts = ElementWindows.netCounts(spectrum: session.spectrumCounts, windows: windows)
        for row in session.windowRows {
            let i = try XCTUnwrap(windows.firstIndex { $0.element == row.symbol })
            XCTAssertEqual(row.net, counts[i]?.net, "\(row.symbol)")
            XCTAssertEqual(row.sigma, counts[i]?.sigma, "\(row.symbol)")
        }
    }

    // MARK: Quantify

    /// The verb on the left pixel: the room's fit equals the kit's `PooledQuantifier.run` on the same input, to the bit, and the
    /// fitted areas land on the planted truth (tolerance written where it is used). Red under: the room changing the
    /// method before the fit; a different region's spectrum fitted; the k source not filled in.
    @MainActor func testQuantifyEqualsTheKitAndRecoversThePlantedAreas() async throws {
        let session = await openRoom()
        session.selectRectangle(PixelRect(x0: 0, y0: 0, x1: 1, y1: 1))
        await session.settled()
        await session.quantify()?.value
        await session.settled()
        let fit = try XCTUnwrap(session.fit, "fit failure: \(session.fitFailure ?? "none")")
        XCTAssertNil(session.fitFailure)
        XCTAssertTrue(session.quantifyActive)
        XCTAssertNotNil(fit.unlistedCheck, "the unlisted-line check landed on the fit")
        XCTAssertNotEqual(fit.abundanceCaveat, "unlisted-line check running")

        // The kit, called directly with the inputs the room describes.
        let source = try XCTUnwrap(session.source)
        var method = QuantificationMethod()
        method.elements = session.picks.map { QuantificationMethod.ElementState(symbol: $0.symbol, role: $0.role == .quantify ? .quantify : .fitOnly, isManual: $0.manual) }
            + session.dismissed.sorted().map { QuantificationMethod.ElementState(symbol: $0, role: .off, isManual: true) }
        let input = PooledQuantificationInput(counts: Self.spectra().left.map { UInt64($0) }, axis: source.energyAxis, method: method,
                                              metadata: source.metadata, regionName: "Region", pixelCount: 1)
        let direct = try PooledQuantifier.run(input, tables: EDXCompute.tables)
        XCTAssertEqual(fit.rows.map(\.element), direct.rows.map(\.element))
        for (a, b) in zip(fit.rows, direct.rows) {
            XCTAssertEqual(a.net, b.net, "\(a.element) net")
            XCTAssertEqual(a.sigma, b.sigma, "\(a.element) sigma")
            XCTAssertEqual(a.atomicPercent, b.atomicPercent, "\(a.element) at%")
            XCTAssertEqual(a.weightPercent, b.weightPercent, "\(a.element) wt%")
        }
        XCTAssertEqual(fit.method.kFactorSource, .computed)
        XCTAssertFalse(fit.method.kSource.isEmpty, "the run names where its k came from")

        // The fitted areas against the planted truth, and the same areas pinned. The fit recovers the planted areas to within the
        // kit's own bias on this spectrum: Al -1.29 %, Mg -0.98 %, Si -2.59 % (run of 2026-10-21, Debug with SWIFT_OPTIMIZATION_LEVEL=-O;
        // the fit's continuum is the kit's Kramers form, the planted one a different "family" form, and Si K-alpha sits beside Al
        // K-alpha, the weak-line bias the fit's own warning names). The bound is 3 %: a wiring fault (a wrong region, a wrong
        // window, an element left out) moves an area by far more. The pin is the regression: the room has no arithmetic of its own,
        // so these numbers move only when the kit's fit does, and then in a commit of their own with the reason.
        let truth = Self.planted.areas
        let pinned: [(element: String, fitted: Double)] = [("Al", 987_084.187148377), ("Mg", 49_511.781907676865), ("Si", 9_741.175285607535)]
        for (element, expected) in pinned {
            let row = try XCTUnwrap(fit.rows.first { $0.element == element }, element)
            let area = try XCTUnwrap(truth[element])
            XCTAssertEqual(row.net, area, accuracy: 0.03 * area, "\(element): fitted \(row.net), planted \(area)")
            XCTAssertEqual(row.net, expected, accuracy: 1e-7 * expected, "\(element) pinned")
        }
        XCTAssertEqual(fit.rows.compactMap(\.atomicPercent).reduce(0, +), 100, accuracy: 1e-6, "at% sums to 100")
    }

    /// Before the verb a setting only changes the method; after it the fit follows the setting. Red under: a setting refitting
    /// before Quantify; no refit after it.
    @MainActor func testSettingsRefitOnlyAfterTheVerb() async throws {
        let session = await openRoom()
        session.selectRectangle(PixelRect(x0: 0, y0: 0, x1: 1, y1: 1))
        session.changeMethod { $0.estimator = .poissonMaximumLikelihood }
        await session.settled()
        XCTAssertNil(session.fit)
        XCTAssertEqual(session.method.estimator, .poissonMaximumLikelihood)
        await session.quantify()?.value
        await session.settled()
        XCTAssertEqual(session.fit?.method.estimator, .poissonMaximumLikelihood)
        session.changeMethod { $0.estimator = .leastSquares }
        await session.settled()
        XCTAssertEqual(session.fit?.method.estimator, .leastSquares, "live from the verb on")
    }

    /// Quantify refuses with no quantified element; a fit-only room has no verb. Red under: the verb running on an empty set.
    @MainActor func testTheVerbNeedsAQuantifiedElement() async {
        let session = await openRoom()
        for pick in session.picks { session.setRole(.fitOnly, of: pick.symbol) }
        XCTAssertFalse(session.canQuantify)
        XCTAssertNotNil(session.quantifyBlocker)
        XCTAssertNil(session.quantify())
        XCTAssertFalse(session.quantifyActive)
    }

    // MARK: Export

    /// What the Export section writes: the results table under the app's name, the method with its hash, the spectrum. Red under:
    /// the kit's neutral title; the method JSON not the fit's; the spectrum not the region's.
    @MainActor func testTheExportsNameTheAppTheMethodAndTheRegion() async throws {
        let session = await openRoom()
        XCTAssertNil(session.resultsCSV, "no results before the verb")
        XCTAssertNil(session.methodJSON)
        let csv0 = try XCTUnwrap(session.spectrumCSV)
        XCTAssertTrue(csv0.contains("region: Whole map"))
        session.selectRectangle(PixelRect(x0: 0, y0: 0, x1: 1, y1: 1))
        await session.settled()
        await session.quantify()?.value
        await session.settled()
        let results = try XCTUnwrap(session.resultsCSV)
        XCTAssertTrue(results.hasPrefix("# macTEM Spectroscopy quantification, region: Region\n"))
        XCTAssertTrue(results.contains("\nelement,line,net_counts,"))
        let method = try XCTUnwrap(session.methodJSON)
        let fit = try XCTUnwrap(session.fit)
        XCTAssertEqual(method, SpectroscopyExport.methodJSON(fit.method))
        XCTAssertTrue(method.contains(fit.method.hash))
        let spectrum = try XCTUnwrap(session.spectrumCSV)
        let lines = spectrum.split(separator: "\n")
        XCTAssertEqual(lines.count, 3 + Self.planted.axis.channels, "two header lines, the column line, a row per channel")
        XCTAssertEqual(lines[2], "energy_keV,counts")
        XCTAssertEqual(session.exportStem, "planted_Region")
    }

    // MARK: Files

    /// A file that is not a spectrum image is refused in words, and the room stays as it was. Red under: the error swallowed;
    /// the room left "opening".
    @MainActor func testAFileThatIsNotASpectrumImageIsRefused() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("edx-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("notes.emd")
        try Data("not hdf5".utf8).write(to: url)
        let session = EDXSession()
        var failure: String?
        session.onFailure = { failure = ($0 as? LocalizedError)?.errorDescription }
        await session.open(url: url).value
        XCTAssertEqual(failure, "notes.emd is not an EDX spectrum image.")
        XCTAssertFalse(session.hasImage)
        XCTAssertFalse(session.isOpening)
    }

    /// A real Velox spectrum stream (SpectroKit's planted file: 4 x 3 pixels, 4096 channels of 20 eV from -1932.21348 eV) opens
    /// through the room: the grid, the axis and the sum are the file's. Red under: the reader not reached; the grid transposed.
    @MainActor func testAVeloxSpectrumStreamOpens() async throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/velox-stream-spectrum.emd")
        let session = EDXSession()
        var events: [String] = []
        session.onEvent = { events.append($0) }
        await session.open(url: url).value
        await session.settled()
        let source = try XCTUnwrap(session.source)
        XCTAssertEqual(source.nx, 4)
        XCTAssertEqual(source.ny, 3)
        XCTAssertEqual(source.channels, 4096)
        XCTAssertEqual(source.energyAxis.scale, 0.02, accuracy: 1e-12)
        XCTAssertEqual(source.energyAxis.offset, -1.93221348, accuracy: 1e-9)
        XCTAssertEqual(session.regionPixels, 12)
        XCTAssertEqual(session.totalCounts, source.sum(mask: nil).reduce(0, +))
        XCTAssertGreaterThan(session.totalCounts, 0)
        XCTAssertEqual(events.first, "Opening velox-stream-spectrum.emd…")
        XCTAssertTrue(events.contains { $0.hasPrefix("Opened — 4 × 3 px") }, "\(events)")
        XCTAssertEqual(EDXOpening.isSpectrumImage(at: url), true)
        session.close()
        XCTAssertFalse(session.hasImage)
        XCTAssertTrue(session.spectrumCounts.isEmpty)
    }

    /// Quantify with no beam energy fails in the kit's words and leaves no fit and no fitting flag. Red under: the failure swallowed.
    @MainActor func testAFitWithoutABeamEnergyFailsInWords() async {
        let session = EDXSession()
        await session.bind(Self.source(beam: nil)).value
        session.toggle("Al")
        await session.quantify()?.value
        await session.settled()
        XCTAssertNil(session.fit)
        XCTAssertNotNil(session.fitFailure)
        XCTAssertFalse(session.isFitting)
    }

    /// A fit-only element is fitted but not quantified: it has no row in the table. Red under: the role mapped to quantify.
    @MainActor func testAFitOnlyElementGetsNoRow() async throws {
        let session = await openRoom()
        session.setRole(.fitOnly, of: "Si")
        session.selectRectangle(PixelRect(x0: 0, y0: 0, x1: 1, y1: 1))
        await session.quantify()?.value
        await session.settled()
        let fit = try XCTUnwrap(session.fit, session.fitFailure ?? "")
        XCTAssertFalse(fit.rows.contains { $0.element == "Si" })
        XCTAssertTrue(fit.rows.contains { $0.element == "Al" })
    }

    /// Auto ID's report lists only what it applied: an element the person removed is not claimed. Red under: all suggestions stored.
    /// An automatic run (open, a region change) does not claim what the person took out; the Auto ID button asks for the whole proposal and does.
    /// Red under: the button honouring the dismissals (drive 6: deselect all, then Auto ID found nothing).
    @MainActor func testAutoIDDoesNotClaimWhatTheUserRemovedUnlessAskedExplicitly() async {
        let session = await openRoom()
        session.toggle("Al")
        await session.runAutoID()?.value
        await session.settled()
        guard case .done(let outcome) = session.autoID else { return XCTFail("\(session.autoID)") }
        XCTAssertFalse(outcome.suggestions.contains { $0.symbol == "Al" }, "an automatic run keeps the dismissal")
        XCTAssertFalse(session.picks.contains { $0.symbol == "Al" })
        await session.runAutoID(explicit: true)?.value
        await session.settled()
        XCTAssertTrue(session.picks.contains { $0.symbol == "Al" }, "the button finds Al again")
        XCTAssertTrue(session.dismissed.isEmpty)
    }

    /// A region still under the pointer: the spectrum follows it while the drag runs (Paul's drive, 2026-10-23: "I can drag it but see the
    /// changes only after I let go"); the selected region, the results and the fit wait for the release. Ending the preview without a new
    /// region puts the selected region's spectrum back; a region committed on release wins over a preview still in flight.
    @MainActor func testADragPreviewsTheSpectrumAndTheReleaseCommits() async {
        let session = EDXSession()
        await session.bind(Self.source()).value
        await session.settled()
        let whole = session.plot.data, rows = session.windowRows
        let left = Self.spectra().left.map(Double.init)
        await session.previewRegion(.rectangle(PixelRect(x0: 0, y0: 0, x1: 1, y1: 1)))?.value
        XCTAssertEqual(session.plot.data, left, "the plot is the left pixel's spectrum while dragging")
        XCTAssertEqual(session.region, .wholeMap, "the selected region waits for the release")
        XCTAssertEqual(session.windowRows, rows, "the results wait for the release")
        await session.previewRegion(nil)?.value
        XCTAssertEqual(session.plot.data, whole, "no region was committed: the selected region's spectrum is back")

        // A preview in flight when the region is committed does not overwrite the committed spectrum.
        let late = session.previewRegion(.rectangle(PixelRect(x0: 1, y0: 0, x1: 2, y1: 1)))
        session.previewRegion(nil)
        session.selectRectangle(PixelRect(x0: 0, y0: 0, x1: 1, y1: 1))
        await late?.value
        await session.settled()
        XCTAssertEqual(session.plot.data, left)
        XCTAssertEqual(session.region, .rectangle(PixelRect(x0: 0, y0: 0, x1: 1, y1: 1)))
    }

    /// A region drawn while Auto ID runs restarts it on the new region. Red under: left idle.
    @MainActor func testARegionDrawnDuringAutoIDRestartsIt() async {
        let session = EDXSession()
        let open = session.bind(Self.source())
        session.selectRectangle(PixelRect(x0: 0, y0: 0, x1: 1, y1: 1))
        await open.value
        await session.settled()
        if case .done(let outcome) = session.autoID { XCTAssertEqual(outcome.region, "Region") } else { XCTFail("\(session.autoID)") }
    }

    /// The fitted curves are the kit's whole-axis arrays cut to the fitted channels, starting at that channel's energy.
    /// The axis refinement before Auto ID needs two K lines three keV apart at three limits: one line, or two close ones, cannot anchor it.
    func testAutoIDRefinesOnTwoWellSeparatedKLinesOnly() {
        func c(_ el: String, _ group: String, _ e: Double, _ sig: Double) -> ElementCandidate {
            ElementCandidate(element: el, group: group, energyKeV: e, net: 1000 * sig, sigma: 10, sigmaZero: 10, criticalLevel: 500, detectionLimit: 1000,
                             conflicts: [], suggestedRole: .fitOnly, holeRegionNote: nil, misfit: 1)
        }
        func result(_ cs: [ElementCandidate]) -> ProposalResult { ProposalResult(candidates: cs, sumPeaks: [], refused: [], currie: .standard, notes: [], passes: 1, settled: true) }
        XCTAssertNil(EDXCompute.refinementAnchors(result([c("Cu", "Cu_Ka", 8.05, 20)])), "one line")
        XCTAssertNil(EDXCompute.refinementAnchors(result([c("Al", "Al_Ka", 1.49, 20), c("Si", "Si_Ka", 1.74, 20)])), "two lines too close")
        XCTAssertNil(EDXCompute.refinementAnchors(result([c("Al", "Al_Ka", 1.49, 20), c("Cu", "Cu_Ka", 8.05, 2)])), "the second below three limits")
        XCTAssertNil(EDXCompute.refinementAnchors(result([c("Al", "Al_Ka", 1.49, 20), c("Hf", "Hf_La", 7.9, 20)])), "an L line is no anchor")
        XCTAssertEqual(EDXCompute.refinementAnchors(result([c("Al", "Al_Ka", 1.49, 20), c("Cu", "Cu_Ka", 8.05, 5), c("Zr", "Zr_Ka", 15.78, 4)])), ["Al", "Cu", "Zr"])
    }

    /// A find the kit could not confirm (its K or L line outside the fitted range: `ElementCandidate.unconfirmable`) is listed as uncorroborated and never
    /// added; a proposed pick by an M line whose L line the kit confirmed is added (Pt by Mα on the owner's 1456, reported by its stronger Lα group).
    func testUnconfirmableFindsAreUncorroboratedAndConfirmedOnesAreAdded() {
        func c(_ el: String, _ group: String, _ e: Double, unconfirmable: Bool) -> ElementCandidate {
            ElementCandidate(element: el, group: group, energyKeV: e, net: 20_000, sigma: 10, sigmaZero: 10, criticalLevel: 500, detectionLimit: 1000,
                             conflicts: [], suggestedRole: .fitOnly, holeRegionNote: nil, misfit: 1,
                             possibleReason: unconfirmable ? "Found by its Lα alone." : nil, unconfirmable: unconfirmable)
        }
        let r = ProposalResult(candidates: [c("Ba", "Ba_La", 4.47, unconfirmable: true), c("Pt", "Pt_La", 9.44, unconfirmable: false)],
                               sumPeaks: [], refused: [], currie: .standard, notes: [], passes: 1, settled: true)
        let axis = EnergyAxis(offset: 0, scale: 0.01, size: 4000)
        let settings = FitSettings.standard(elements: [], axis: axis, resolutionMnKaEV: 130, beamEnergy: 200)
        let o = EDXCompute.outcome(of: r, settings: settings, axis: axis, computedK: true, regionName: "R")
        XCTAssertEqual(o.suggestions.map(\.symbol), ["Pt"])
        XCTAssertEqual(o.uncorroborated.count, 1)
        XCTAssertTrue(o.uncorroborated.first?.hasPrefix("Ba by") == true, "\(o.uncorroborated)")
    }

    func testTheFittedCurveIsCutToTheFitRange() {
        let plot = EDXPlot(energyStart: 1, energyStep: 0.5, data: Array(repeating: 0, count: 10), model: (0..<10).map(Double.init), fitChannels: 5..<9)
        let part = plot.fitted(plot.model)
        XCTAssertEqual(part.values, [5, 6, 7, 8])
        XCTAssertEqual(part.start, 3.5, accuracy: 1e-12)
        XCTAssertTrue(plot.fitted([1, 2]).values.isEmpty, "a curve shorter than the range")
    }
}
