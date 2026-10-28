//
//  EDXRoomRealDataTests.swift
//  The EDS room's acceptance lines (docs/design/eds-room-behaviour.md) driven through `EDXSession` on the owner's real Velox spectrum images
//  (data/stem-edx): Auto ID with nothing selected, with a region, after a deselect-all; regions drawn, moved, deleted, overlaid; Quantify with a sigma per
//  element; the wt% maps over the whole scan; the six exports; and the Open Files selection following a document switch. Opt-in like `EDXRealDataTests`
//  (`TEST_RUNNER_MACTEM_REAL_DATA=1` or the flag file), under a memory cap. Each test opens the one file it needs and lets the session go before it
//  returns (1456 is 1.7 GB and is opened by one test only). Every number is printed as a `ROOM …` line to stdout and to $TMPDIR/realdata-timings.txt.
//  Two Auto ID tests are RED today by design (Mg is missed on 1339 and 1840); they stay red until the proposer finds Mg.
//

import XCTest
import Darwin
import SpectroCore
import SpectroEDX
#if canImport(TEMCore)
import TEMCore
import TEMSession
#endif
@testable import macTEM
import ShellEDXModel
import ShellSpectroscopy

nonisolated final class EDXRoomRealDataTests: XCTestCase {

    private func say(_ text: String) {
        print(text)
        let path = NSTemporaryDirectory() + "realdata-timings.txt"
        if !FileManager.default.fileExists(atPath: path) { FileManager.default.createFile(atPath: path, contents: nil) }
        if let handle = FileHandle(forWritingAtPath: path) { handle.seekToEndOfFile(); handle.write(Data((text + "\n").utf8)); try? handle.close() }
    }

    private static let f1339 = "SI HAADF 1339 65000 x 20260508.emd"
    private static let f1840 = "SI HAADF 1840 23000 x 20260506.emd"
    private static let f1456 = "SI HAADF 1456 77000 x 20260420.emd"
    private static let wrong = ["Ba", "Eu", "Dy", "Hf", "Os"]

    private func optIn() throws {
        let flag = FileManager.default.fileExists(atPath: NSTemporaryDirectory() + "macTEM-real-data.flag") || FileManager.default.fileExists(atPath: NSTemporaryDirectory() + "macTEM-real-data.flag")
        guard ProcessInfo.processInfo.environment["MACTEM_REAL_DATA"] == "1" || flag else { throw XCTSkip("opt-in: TEST_RUNNER_MACTEM_REAL_DATA=1, or create $TMPDIR/macTEM-real-data.flag") }
    }

    private func url(_ name: String) throws -> URL {
        let data = ProcessInfo.processInfo.environment["MACEM_DATA"] ?? NSHomeDirectory() + "/GitHub/mac4DSTEM_Organization/data"
        let url = URL(fileURLWithPath: data + "/stem-edx/" + name)
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path), "no real file at \(url.path)")
        return url
    }

    /// Opens one file into a bound, settled session (Auto ID at open has run).
    @MainActor private func room(_ name: String) async throws -> (session: EDXSession, loaded: LoadedSpectrumImage) {
        try optIn()
        let file = try url(name)
        let loaded = try await Task.detached { try EDXOpening.open(url: file) }.value
        let session = EDXSession(host: .macTEM)
        await session.bind(loaded).value
        await session.settled()
        say("ROOM open \(name): \(loaded.metadata.scanWidth) x \(loaded.metadata.scanHeight) px, \(loaded.metadata.channelCount) channels; picks at open: \(picksText(session))")
        return (session, loaded)
    }

    @MainActor private func picksText(_ s: EDXSession) -> String { s.picks.map { $0.role == .quantify ? $0.symbol : $0.symbol + "*" }.joined(separator: " ") }
    @MainActor private func pickSet(_ s: EDXSession) -> Set<String> { Set(s.picks.map(\.symbol)) }

    @MainActor private func deselectAll(_ s: EDXSession) async {
        for pick in s.picks { s.toggle(pick.symbol) }
        await s.settled()
    }

    @MainActor private func autoIDFromNothing(_ s: EDXSession) async -> Set<String> {
        await deselectAll(s)
        XCTAssertTrue(s.picks.isEmpty, "every element deselected")
        await s.runAutoID(explicit: true)?.value
        await s.settled()
        return pickSet(s)
    }

    @MainActor private func report(_ s: EDXSession, _ label: String, truth: [String]) {
        let picks = pickSet(s)
        say("ROOM \(label): picks \(picksText(s)); missed \(Set(truth).subtracting(picks).sorted().joined(separator: " ")); wrong-list hits \(picks.intersection(Self.wrong).sorted().joined(separator: " "))")
        if case .done(let o) = s.autoID { for n in o.notes.prefix(10) { say("ROOM   note: \(n)") }; for u in o.uncorroborated { say("ROOM   uncorroborated: \(u)") } }
    }

    // MARK: Auto ID

    /// RED TODAY, kept red: Mg is missed on 1339 (the proposer finds Al and Si, not Mg). Green when the picks hold Al, Mg, Si and none of Ba, Eu, Dy, Hf, Os.
    @MainActor func testAutoIDWithNothingSelectedOnWholeMap1339() async throws {
        let (s, _) = try await room(Self.f1339)
        let picks = await autoIDFromNothing(s)
        report(s, "1339 whole map, nothing selected", truth: ["Al", "Mg", "Si"])
        for e in ["Al", "Mg", "Si"] { XCTAssertTrue(picks.contains(e), "Auto ID must find \(e) (picks: \(picks.sorted()))") }
        XCTAssertTrue(picks.isDisjoint(with: Self.wrong), "no \(Self.wrong) (picks: \(picks.sorted()))")
    }

    /// Same expectation on 1840; red today if Mg is missed there too (see the printed picks).
    @MainActor func testAutoIDWithNothingSelectedOnWholeMap1840() async throws {
        let (s, _) = try await room(Self.f1840)
        let picks = await autoIDFromNothing(s)
        report(s, "1840 whole map, nothing selected", truth: ["Al", "Mg", "Si"])
        for e in ["Al", "Mg", "Si"] { XCTAssertTrue(picks.contains(e), "Auto ID must find \(e) (picks: \(picks.sorted()))") }
        XCTAssertTrue(picks.isDisjoint(with: Self.wrong), "no \(Self.wrong) (picks: \(picks.sorted()))")
    }

    /// The big file, opened once for the whole test: Auto ID from nothing finds O, Si, Ni, Ge, Pt.
    @MainActor func testAutoIDWithNothingSelectedOnWholeMap1456() async throws {
        let (s, _) = try await room(Self.f1456)
        let picks = await autoIDFromNothing(s)
        report(s, "1456 whole map, nothing selected", truth: ["O", "Si", "Ni", "Ge", "Pt"])
        for e in ["O", "Si", "Ni", "Ge", "Pt"] { XCTAssertTrue(picks.contains(e), "Auto ID must find \(e) (picks: \(picks.sorted()))") }
        XCTAssertTrue(picks.isDisjoint(with: Self.wrong), "no \(Self.wrong) (picks: \(picks.sorted()))")
    }

    /// A quarter of the scan selected (the region is not pinned), nothing picked, Auto ID: the same expectation as the whole map (red while Mg is missed).
    @MainActor func testAutoIDWithARectangleRegionOn1339() async throws {
        let (s, loaded) = try await room(Self.f1339)
        let nx = loaded.metadata.scanWidth, ny = loaded.metadata.scanHeight
        await deselectAll(s)
        s.selectRectangle(PixelRect(x0: 0, y0: 0, x1: nx / 2, y1: ny / 2))
        await s.settled()
        say("ROOM 1339 region quarter: regionPixels \(s.regionPixels) of \(nx * ny)")
        XCTAssertEqual(s.regionPixels, (nx / 2) * (ny / 2))
        await s.runAutoID(explicit: true)?.value
        await s.settled()
        report(s, "1339 quarter region, nothing selected", truth: ["Al", "Mg", "Si"])
        let picks = pickSet(s)
        for e in ["Al", "Mg", "Si"] { XCTAssertTrue(picks.contains(e), "Auto ID must find \(e) in the region (picks: \(picks.sorted()))") }
        XCTAssertTrue(picks.isDisjoint(with: Self.wrong), "no \(Self.wrong) (picks: \(picks.sorted()))")
    }

    /// Drive 6: after the open's Auto ID, deselect every element and press Auto ID: the same picks come back.
    @MainActor func testDeselectAllThenAutoIDBringsTheSamePicksBack() async throws {
        let (s, _) = try await room(Self.f1339)
        let atOpen = pickSet(s)
        XCTAssertFalse(atOpen.isEmpty, "Auto ID at open found something")
        await deselectAll(s)
        XCTAssertTrue(s.picks.isEmpty)
        await s.runAutoID(explicit: true)?.value
        await s.settled()
        say("ROOM 1339 drive 6: at open \(atOpen.sorted().joined(separator: " ")); after deselect all + Auto ID \(pickSet(s).sorted().joined(separator: " "))")
        XCTAssertEqual(pickSet(s), atOpen)
    }

    // MARK: Regions

    @MainActor func testARectangleHasPixelsAndWindowRowsMovesAndIsDeleted() async throws {
        let (s, loaded) = try await room(Self.f1339)
        let nx = loaded.metadata.scanWidth, ny = loaded.metadata.scanHeight
        let box = PixelRect(x0: nx / 8, y0: ny / 8, x1: nx / 8 + nx / 4, y1: ny / 8 + ny / 4)
        s.drawRectangle(box)
        await s.settled()
        say("ROOM region: regionPixels \(s.regionPixels), box \(box.width) x \(box.height); window rows: " + s.windowRows.map { "\($0.symbol) \($0.line) net \(Int($0.net))" }.joined(separator: "; "))
        XCTAssertEqual(s.regionPixels, box.width * box.height)
        XCTAssertFalse(s.windowRows.isEmpty, "the table has window rows for the picks")
        let pin = try XCTUnwrap(s.pins.first)
        XCTAssertEqual(s.pins.count, 1)
        // Move it.
        let moved = PixelRect(x0: box.x0 + 10, y0: box.y0 + 10, x1: box.x1 + 10, y1: box.y1 + 10)
        s.setPinRegion(pin.id, .rectangle(moved))
        await s.settled()
        XCTAssertEqual(s.pins.first?.region, .rectangle(moved))
        XCTAssertEqual(s.region, .rectangle(moved), "the selected region followed the move")
        XCTAssertEqual(s.regionPixels, moved.width * moved.height)
        say("ROOM region moved: regionPixels \(s.regionPixels); window rows \(s.windowRows.count)")
        // Delete it.
        s.removePin(pin.id)
        await s.settled()
        XCTAssertTrue(s.pins.isEmpty)
        XCTAssertTrue(s.pinSpectra.isEmpty)
        say("ROOM region deleted: pins \(s.pins.count), pinSpectra \(s.pinSpectra.count), region \(s.region.name)")
    }

    @MainActor func testTwoRegionsOverlay() async throws {
        let (s, loaded) = try await room(Self.f1339)
        let nx = loaded.metadata.scanWidth, ny = loaded.metadata.scanHeight
        s.drawRectangle(PixelRect(x0: 0, y0: 0, x1: nx / 4, y1: ny / 4))
        s.drawRectangle(PixelRect(x0: nx / 2, y0: ny / 2, x1: nx / 2 + nx / 4, y1: ny / 2 + ny / 4))
        await s.settled()
        say("ROOM two regions: pins \(s.pins.map(\.name).joined(separator: ", ")); pinSpectra \(s.pinSpectra.count); pinRows \(s.pinRows.count)")
        XCTAssertEqual(s.pins.count, 2)
        XCTAssertEqual(s.pinSpectra.count, 2, "both regions' spectra are overlaid")
    }

    // MARK: Quantify, maps, exports

    /// Quantifies Al, Mg and Si on a drawn region of 1339 (and leaves the room quantified for the callers).
    @MainActor private func quantified() async throws -> (EDXSession, LoadedSpectrumImage) {
        let (s, loaded) = try await room(Self.f1339)
        await deselectAll(s)
        for e in ["Al", "Mg", "Si"] { s.toggle(e) }
        await s.settled()
        let nx = loaded.metadata.scanWidth, ny = loaded.metadata.scanHeight
        s.drawRectangle(PixelRect(x0: nx / 4, y0: ny / 4, x1: nx / 4 + nx / 2, y1: ny / 4 + ny / 2))
        await s.settled()
        _ = s.quantify()
        await s.settled()
        return (s, loaded)
    }

    @MainActor func testQuantifyARegionGivesWtAtAndASigmaPerElement() async throws {
        let (s, _) = try await quantified()
        let fit = try XCTUnwrap(s.fit, "the pooled fit landed (failure: \(s.fitFailure ?? "none"))")
        for r in fit.rows {
            say(String(format: "ROOM quantify %@: at%% %@ ± %@, wt%% %@ ± %@, net %.0f%@", r.element as NSString,
                       r.atomicPercent.map { String(format: "%.2f", $0) } ?? "-", r.atomicSigma.map { String(format: "%.2f", $0) } ?? "-",
                       r.weightPercent.map { String(format: "%.2f", $0) } ?? "-", r.weightSigma.map { String(format: "%.2f", $0) } ?? "-", r.net,
                       (r.failure.map { "  failure: \($0)" } ?? "") as NSString))
        }
        XCTAssertEqual(Set(fit.rows.map(\.element)), ["Al", "Mg", "Si"])
        for r in fit.rows {
            XCTAssertNotNil(r.atomicPercent, "\(r.element) at%"); XCTAssertNotNil(r.weightPercent, "\(r.element) wt%")
            XCTAssertNotNil(r.atomicSigma, "\(r.element) sigma at%"); XCTAssertNotNil(r.weightSigma, "\(r.element) sigma wt%")
        }
        let footer = fit.footerLines.joined(separator: "\n")
        say("ROOM quantify footer:\n" + footer)
        // The fit's footer names the method: the k source, the continuum or the estimator.
        XCTAssertTrue(footer.contains("k:") || footer.localizedCaseInsensitiveContains("cliff"), "the footer names the quantification method")
        // `validation: none` once in the results words: the sentence the CSV carries (the panel's badge reads "at%, wt%: validation none").
        let words = ([fit.abundanceCaveat].compactMap { $0 } + fit.warnings + fit.footerLines).joined(separator: "\n")
        let csv = try XCTUnwrap(s.resultsCSV)
        let validationLines = csv.split(separator: "\n").filter { $0.hasPrefix("# validation:") }
        say("ROOM quantify validation: hasAbundance \(fit.hasAbundance); '# validation:' lines in the results CSV \(validationLines.count): \(validationLines.first.map(String.init) ?? "-"); mentions of validation in footer words \(words.components(separatedBy: "validation").count - 1)")
        XCTAssertTrue(fit.hasAbundance, "at% was computed")
        XCTAssertEqual(validationLines.count, 1, "the validation statement appears once")
        XCTAssertTrue(validationLines.first?.localizedCaseInsensitiveContains("\"none\"") == true || validationLines.first?.localizedCaseInsensitiveContains("none") == true || validationLines.first?.contains("UNVALIDATED") == true)
    }

    @MainActor func testWtPercentMapsCoverTheWholeScanWithoutMasking() async throws {
        let (s, loaded) = try await quantified()
        let (nx, ny) = (loaded.metadata.scanWidth, loaded.metadata.scanHeight)
        s.setMapMode(.weight)
        await s.settled()
        say("ROOM maps wt%: mapsState \(s.mapsState); tiles " + s.shownTiles.map { "\($0.symbol) (\($0.mode.title), \($0.values.count) values)" }.joined(separator: ", "))
        XCTAssertEqual(s.mapsState, .done)
        XCTAssertEqual(Set(s.shownTiles.map(\.symbol)), ["Al", "Mg", "Si"], "a tile per quantified element")
        for t in s.shownTiles {
            XCTAssertEqual(t.mode, .weight)
            XCTAssertEqual(t.values.count, nx * ny, "\(t.symbol): the whole scan, not the region")
            let footer = t.footer ?? ""
            say("ROOM maps footer \(t.symbol): \(footer)")
            XCTAssertFalse(footer.contains("masked px"), "no masked pixels: the region never masks the maps")
        }
    }

    @MainActor func testTheSixExportsAreNonEmptyWithTheirColumns() async throws {
        let (s, _) = try await quantified()
        s.setMapMode(.weight)
        await s.settled()

        let results = try XCTUnwrap(s.resultsCSV)
        XCTAssertTrue(results.split(separator: "\n").contains { $0.hasPrefix("element,line,net_counts") && $0.contains("at_percent") && $0.contains("sigma_at_percent") }, "results CSV header")
        XCTAssertGreaterThan(results.split(separator: "\n").filter { !$0.hasPrefix("#") }.count, 3, "header plus a row per element")

        let spectrum = try XCTUnwrap(s.spectrumCSV)
        XCTAssertTrue(spectrum.split(separator: "\n").contains("energy_keV,counts"), "spectrum CSV header")
        XCTAssertGreaterThan(spectrum.count, 1000)

        let msa = try XCTUnwrap(try s.spectrumMSA())
        XCTAssertGreaterThan(msa.count, 1000)
        XCTAssertTrue(String(decoding: msa.prefix(200), as: UTF8.self).contains("#FORMAT"), "MSA header")

        let regionsText = await s.pinsCSV()
        let regions = try XCTUnwrap(regionsText)
        XCTAssertTrue(regions.split(separator: "\n").contains { $0.hasPrefix("name,shape,geometry,pixels,counts") && $0.contains("net_Al") && $0.contains("wt_Al") && $0.contains("at_Al") }, "regions CSV header")
        XCTAssertGreaterThan(regions.split(separator: "\n").filter { !$0.hasPrefix("#") }.count, 1, "a region row")

        let json = try XCTUnwrap(s.methodJSON)
        XCTAssertTrue(json.contains("\"method\"") && json.contains("\"sha256\""), "method JSON")
        XCTAssertNotNil(try? JSONSerialization.jsonObject(with: Data(json.utf8)), "method JSON parses")

        let content = try XCTUnwrap(s.figureContent())
        let png = try XCTUnwrap(EDXMapsFigure.png(content))
        XCTAssertEqual(Array(png.prefix(8)), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        say("ROOM exports: results CSV \(results.count) B, spectrum CSV \(spectrum.count) B, MSA \(msa.count) B, regions CSV \(regions.count) B, method JSON \(json.count) B, maps PNG \(png.count) B (\(content.tiles.count) tiles)")
        say("ROOM regions CSV header: " + (regions.split(separator: "\n").first { !$0.hasPrefix("#") }.map(String.init) ?? "-"))
    }

    // MARK: Document switch

    /// Two spectrum files in one batch (`--open a --open b`, a multi-selection in the panel): Open Files selects the first, and the EDS room holds the first too,
    /// so the room and the selection agree at launch. Red under: both opened into the room in turn, the room held the last while the first row was selected
    /// (the EDS screen journey, step 11, 2026-10-23: clicking the selected row changed nothing).
    @MainActor func testTwoFilesInOneBatchPutTheFirstInTheEDSRoom() async throws {
        try optIn()
        let a = try url(Self.f1339), b = try url(Self.f1840)
        let state = AppState()
        await state.open(urls: [a, b])?.value
        for _ in 0..<600 where state.edx.isOpening || state.edx.fileName.isEmpty { try await Task.sleep(for: .milliseconds(100)) }
        await state.edx.settled()
        say("ROOM batch: the EDS room holds '\(state.edx.fileName)', selected '\(state.openItems.selected?.url.lastPathComponent ?? "none")', edsFiles \(state.edsFiles.count)")
        XCTAssertEqual(state.edx.fileName, a.lastPathComponent, "the room holds the batch's first file")
        XCTAssertEqual(state.edsFiles, [a, b])
        if let selected = state.openItems.selected { XCTAssertEqual(selected.url, a, "Open Files selects the first") }
    }

    /// Opens 1339 then 1840 through `AppState.open(urls:)`, selects 1339's item and follows: the EDS room holds 1339 again. If `AppState.open` cannot run
    /// headless (no security scope, a panel), the follow rule is checked on `AppState.roomsToFollow` alone and the test says so.
    @MainActor func testSwitchingDocumentsMakesTheEDSRoomFollowTheSelection() async throws {
        try optIn()
        let a = try url(Self.f1339), b = try url(Self.f1840)
        let state = AppState()
        // `AppState.open` starts the room's own read and returns before it lands; the session keeps that task private, so the wait is on its state (bounded, 60 s).
        func roomHolds(_ name: String) async throws {
            for _ in 0..<600 where state.edx.isOpening || state.edx.fileName != name { try await Task.sleep(for: .milliseconds(100)) }
            await state.edx.settled()
        }
        await state.open(urls: [a])?.value
        try await roomHolds(a.lastPathComponent)
        await state.open(urls: [b])?.value
        try await roomHolds(b.lastPathComponent)
        say("ROOM switch: after both opens the EDS room holds '\(state.edx.fileName)'; open items \(state.openItems.items.map { $0.url.lastPathComponent }); edsFiles \(state.edsFiles.map(\.lastPathComponent).sorted())")
        guard state.edsFiles.contains(a), state.edsFiles.contains(b), state.edx.fileName == b.lastPathComponent else {
            say("ROOM switch: AppState.open did not route both files into the EDS room headless; checking roomsToFollow only")
            let follow = AppState.roomsToFollow(selected: a, edsFiles: [a, b], eelsFiles: [], edsFile: b.lastPathComponent, eelsFile: "", edsOpening: false, eelsOpening: false)
            XCTAssertTrue(follow.eds); XCTAssertFalse(follow.eels)
            XCTFail("AppState.open(urls:) did not open both into the EDS room headless; only roomsToFollow was checked")
            return
        }
        guard let item = state.openItems.items.first(where: { $0.url == a }) else {
            // The EDS file's HAADF companion did not become an open item headless: the follow decision is checked on its own.
            let follow = AppState.roomsToFollow(selected: a, edsFiles: state.edsFiles, eelsFiles: [], edsFile: state.edx.fileName, eelsFile: "", edsOpening: false, eelsOpening: false)
            say("ROOM switch: no open item for 1339 headless (items \(state.openItems.items.count)); roomsToFollow says eds \(follow.eds)")
            XCTAssertTrue(follow.eds)
            XCTFail("no open item for 1339 headless; only roomsToFollow was checked")
            return
        }
        state.openItems.select(item.id)
        XCTAssertEqual(state.openItems.selected?.url, a)
        state.spectrumRoomsFollowSelection()
        await state.edx.settled()
        try await roomHolds(a.lastPathComponent)
        say("ROOM switch: after select + follow the EDS room holds '\(state.edx.fileName)'")
        XCTAssertEqual(state.edx.fileName, a.lastPathComponent)
    }
}
