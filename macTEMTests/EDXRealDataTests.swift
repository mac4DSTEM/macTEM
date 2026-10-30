//
//  EDXRealDataTests.swift
//  The EDS room end to end on the owner's real 1.7 GB Velox spectrum image (data/stem-edx): open, first spectrum, Auto ID, Quantify, a drawn region and its pooled
//  spectrum, a line profile. Opt-in (the file is the owner's data and the run is heavy): `TEST_RUNNER_MACTEM_REAL_DATA=1` or the flag file named in the skip message, under a memory cap. The test states
//  what each step took and the resident memory after it (printed as `REALDATA …` lines); the assertions are only that every step lands and that a region's counts are
//  the sum of its pixels' counts, so a slow step is a finding, not a failure.
//

import XCTest
import Darwin
import SpectroCore
import SpectroEDX
import TEMCore
import TEMSession
@testable import macTEM

nonisolated final class EDXRealDataTests: XCTestCase {

    private func residentMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) } }
        return kr == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : .nan
    }

    /// Every line goes to stdout and to a file the unit gate does not delete (its result bundle is temporary).
    private func say(_ text: String) {
        print(text)
        let path = NSTemporaryDirectory() + "realdata-timings.txt"
        if !FileManager.default.fileExists(atPath: path) { FileManager.default.createFile(atPath: path, contents: nil) }
        if let handle = FileHandle(forWritingAtPath: path) { handle.seekToEndOfFile(); handle.write(Data((text + "\n").utf8)); try? handle.close() }
    }

    private func line(_ step: String, _ since: Date) {
        say(String(format: "REALDATA %-34@ %8.2f s   resident %7.0f MB", step as NSString, Date().timeIntervalSince(since), residentMB()))
    }

    @MainActor func testTheOwnersVeloxSpectrumImageEndToEnd() async throws {
        // Opt-in: the environment variable, or a flag file (the host app of the unit tests does not always see the runner's environment).
        let flag = FileManager.default.fileExists(atPath: NSTemporaryDirectory() + "macTEM-real-data.flag") || FileManager.default.fileExists(atPath: NSTemporaryDirectory() + "macTEM-real-data.flag")
        guard ProcessInfo.processInfo.environment["MACTEM_REAL_DATA"] == "1" || flag else { throw XCTSkip("opt-in: TEST_RUNNER_MACTEM_REAL_DATA=1, or create $TMPDIR/macTEM-real-data.flag") }
        let data = ProcessInfo.processInfo.environment["MACEM_DATA"] ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("data").path
        var url = URL(fileURLWithPath: data + "/stem-edx/SI HAADF 1456 77000 x 20260420.emd")
        if !FileManager.default.fileExists(atPath: url.path) {   // a worktree outside the organization folder: its relative ../data is not the owner's
            url = URL(fileURLWithPath: NSHomeDirectory() + "/GitHub/mac4DSTEM_Organization/data/stem-edx/SI HAADF 1456 77000 x 20260420.emd")
        }
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path), "no real file at \(url.path)")

        var t = Date()
        say("REALDATA start                                   resident \(Int(residentMB())) MB")
        let loaded = try await Task.detached { try EDXOpening.open(url: url) }.value
        line("open (read the event stream)", t)
        let (nx, ny, channels) = (loaded.metadata.scanWidth, loaded.metadata.scanHeight, loaded.metadata.channelCount)
        say("REALDATA grid \(nx) x \(ny) px, \(channels) channels, beam \(loaded.metadata.beamEnergyKeV.map { "\($0) keV" } ?? "not stated")")

        let session = EDXSession()
        t = Date()
        await session.bind(loaded).value
        line("bind + first spectrum + Auto ID", t)
        t = Date(); await session.settled(); line("settled", t)
        say("REALDATA picks after Auto ID: \(session.picks.map(\.symbol).joined(separator: ", ")); \(session.tiles.count) maps; whole-map counts \(session.totalCounts)")
        XCTAssertGreaterThan(session.totalCounts, 0)
        XCTAssertFalse(session.tiles.isEmpty, "no maps after Auto ID")

        t = Date()
        _ = session.quantify()
        await session.settled()
        line("Quantify (fit, check, maps)", t)
        say("REALDATA fit: \(session.fit == nil ? "none (\(session.fitFailure ?? "no failure text"))" : "yes")")

        // A region: its pooled spectrum is the sum of its pixels' (the kit's mask, checked against the pixels read one by one on a few).
        t = Date()
        let box = PixelRect(x0: nx / 4, y0: ny / 4, x1: nx / 4 + 40, y1: ny / 4 + 30)
        session.drawRectangle(box)
        await session.settled()
        line("draw a 40 x 30 region (pool + table)", t)
        let pin = try XCTUnwrap(session.pins.first)
        let pooled = try XCTUnwrap(session.pinSpectra[pin.id], "no pooled spectrum")
        var expected = [Double](repeating: 0, count: pooled.count)
        for y in box.y0..<box.y1 { for x in box.x0..<box.x1 { if let px = session.pixelSpectrum(x: x, y: y) { for (i, v) in px.enumerated() { expected[i] += v } } } }
        XCTAssertEqual(pooled, expected, "the pooled spectrum is the sum of its pixels'")
        line("pixel-by-pixel check of that sum", t)

        t = Date()
        let hover = session.pixelSpectrum(x: nx / 2, y: ny / 2)
        line("one pixel's spectrum (hover layer)", t)
        XCTAssertEqual(hover?.count, channels)

        t = Date()
        let line1 = try XCTUnwrap(session.drawLine(from: PixelPoint(x: 1, y: Double(ny) / 2), to: PixelPoint(x: Double(nx) - 1, y: Double(ny) / 2)))
        let profiles = session.profiles()
        line("line profile on \(profiles.count) maps", t)
        XCTAssertFalse(profiles.isEmpty); _ = line1
    }

    // MARK: The proposer on the three labelled files

    /// The three of the owner's real files with what is certainly in them (Paul 2026-10-22): the big SI holds O, Si, Ni, Ge and Pt; the two Al-Mg-Si files O, Mg, Al,
    /// Si and Cu. The app's Auto ID (the refinement on the proposal's K lines, then the rules) and the room's own path (open, deselect every element, press
    /// Auto ID) must pick every true element and nothing outside the allowed: Cu (grid), Zr (on all three files, the instrument's), Fe and Mn on the Al alloys
    /// (minor alloying elements, SpectroKit's RealFileAutoIDTests), Ga on the FIB lamella. Opt-in as above.
    @MainActor func testTheProposerOnTheThreeLabelledFiles() async throws {
        let flag = FileManager.default.fileExists(atPath: NSTemporaryDirectory() + "macTEM-real-data.flag")
        guard ProcessInfo.processInfo.environment["MACTEM_REAL_DATA"] == "1" || flag else { throw XCTSkip("opt-in") }
        let base = NSHomeDirectory() + "/GitHub/mac4DSTEM_Organization/data/stem-edx/"
        let files: [(name: String, truth: Set<String>, allowed: Set<String>)] = [
            ("SI HAADF 1456 77000 x 20260420.emd", ["O", "Si", "Ni", "Ge", "Pt"], ["Cu", "Ga", "Zr"]),
            ("SI HAADF 1339 65000 x 20260508.emd", ["O", "Mg", "Al", "Si", "Cu"], ["Fe", "Mn", "Zr"]),
            ("SI HAADF 1840 23000 x 20260506.emd", ["O", "Mg", "Al", "Si", "Cu"], ["Fe", "Mn", "Zr"]),
        ]
        for file in files {
            let url = URL(fileURLWithPath: base + file.name)
            guard FileManager.default.fileExists(atPath: url.path) else { say("PROPOSER skipped (absent): \(file.name)"); continue }
            let loaded = try await Task.detached { try EDXOpening.open(url: url) }.value
            let beam = loaded.metadata.beamEnergyKeV ?? 200
            let t = Date()
            let outcome = try EDXCompute.autoID(spectrum: loaded.sum(mask: nil), axis: loaded.energyAxis, beam: beam, listed: [], computedK: true,
                                                regionName: "Whole map", metadata: loaded.metadata)
            let picks = Set(outcome.suggestions.map(\.symbol))
            say(String(format: "APPAUTOID %@ in %.1f s: picks %@; uncorroborated %d; first note: %@", file.name, Date().timeIntervalSince(t),
                       picks.sorted().joined(separator: " "), outcome.uncorroborated.count, outcome.notes.first ?? "-"))
            XCTAssert(file.truth.isSubset(of: picks), "\(file.name): the app's Auto ID missed \(file.truth.subtracting(picks).sorted())")
            XCTAssert(picks.isSubset(of: file.truth.union(file.allowed)), "\(file.name): the app's Auto ID added \(picks.subtracting(file.truth.union(file.allowed)).sorted())")
            // The room's own path, as drive 6 ran it: open (Auto ID at open), deselect every element, press Auto ID.
            let session = EDXSession()
            await session.bind(loaded).value
            await session.settled()
            for pick in session.picks { session.toggle(pick.symbol) }
            await session.settled()
            await session.runAutoID(explicit: true)?.value
            await session.settled()
            let room = Set(session.picks.map(\.symbol))
            say("ROOM \(file.name) picks after deselect all + Auto ID: " + session.picks.map { $0.role == .quantify ? $0.symbol : $0.symbol + "*" }.joined(separator: " "))
            XCTAssert(file.truth.isSubset(of: room), "\(file.name): the room missed \(file.truth.subtracting(room).sorted())")
            XCTAssert(room.isSubset(of: file.truth.union(file.allowed)), "\(file.name): the room added \(room.subtracting(file.truth.union(file.allowed)).sorted())")
        }
    }

}
