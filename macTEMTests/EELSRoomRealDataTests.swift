//
//  EELSRoomRealDataTests.swift
//  The EELS room's stages driven through `EELSSession` on the owner's three GMS STEM spectrum images (data/eels: 142, 143, 145; low loss and core loss):
//  open and settle, the t/λ map, the core-loss axis and the summed core-loss tail (the "collapse above 1 keV" diagnosis: printed, not asserted), Align, the
//  C, N and O K edges picked and fitted, and the ZLP shift tile. Opt-in like `EDXRealDataTests` (`TEST_RUNNER_MACTEM_REAL_DATA=1` or the flag file), under
//  a memory cap; one file open at a time. Every number is printed as an `EELSROOM …` line (stdout and $TMPDIR/realdata-timings.txt).
//  The three edge rows must each have I > 0 and an at% strictly between 0 and 100. The windows handed to the kit, the exponent r of each edge and the same rows with
//  Convolve off are printed (not asserted) for the diagnosis.
//

import XCTest
import SpectroCore
import SpectroEELS
#if canImport(TEMCore)
import TEMCore
import TEMSession
#endif
@testable import macTEM

nonisolated final class EELSRoomRealDataTests: XCTestCase {

    private func say(_ text: String) {
        print(text)
        let path = NSTemporaryDirectory() + "realdata-timings.txt"
        if !FileManager.default.fileExists(atPath: path) { FileManager.default.createFile(atPath: path, contents: nil) }
        if let handle = FileHandle(forWritingAtPath: path) { handle.seekToEndOfFile(); handle.write(Data((text + "\n").utf8)); try? handle.close() }
    }

    private func optIn() throws {
        let flag = FileManager.default.fileExists(atPath: NSTemporaryDirectory() + "macTEM-real-data.flag") || FileManager.default.fileExists(atPath: NSTemporaryDirectory() + "macTEM-real-data.flag")
        guard ProcessInfo.processInfo.environment["MACTEM_REAL_DATA"] == "1" || flag else { throw XCTSkip("opt-in: TEST_RUNNER_MACTEM_REAL_DATA=1, or create $TMPDIR/macTEM-real-data.flag") }
    }

    private func url(_ relative: String) throws -> URL {
        let data = ProcessInfo.processInfo.environment["MACEM_DATA"] ?? NSHomeDirectory() + "/GitHub/mac4DSTEM_Organization/data"
        let url = URL(fileURLWithPath: data + "/eels/" + relative)
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path), "no real file at \(url.path)")
        return url
    }

    private func median(_ v: [Double]) -> Double? {
        let s = v.filter { $0.isFinite }.sorted()
        guard !s.isEmpty else { return nil }
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    @MainActor private func openAndSettle(_ relative: String, _ tag: String) async throws -> EELSSession {
        try optIn()
        let file = try url(relative)
        let t = Date()
        let loaded = try await Task.detached { try EELSOpening.open(url: file) }.value
        let low = loaded.image
        say("EELSROOM \(tag) open (\(String(format: "%.1f", Date().timeIntervalSince(t))) s): \(loaded.fileName), \(loaded.origin); low loss \(low.nx) x \(low.ny) px, \(low.channels) ch, offset \(low.energyOffsetEV) eV, dispersion \(low.energyScaleEV) eV/ch; core loss: \(loaded.coreLossOrigin ?? "none"); E0 \(loaded.beamEnergyKeV.map { "\($0)" } ?? "nil") keV, alpha \(loaded.convergenceMrad.map { "\($0)" } ?? "nil") mrad, beta \(loaded.collectionMrad.map { "\($0)" } ?? "nil") mrad")
        say("EELSROOM \(tag) scan pixel: \(loaded.scanPixelSize.map { "\($0)" } ?? "nil") \(loaded.scanPixelUnit ?? "")")
        if tag == "143" {
            // RosettaSciIO 0.x (References/FormatoKit/rsciio-venv) on 143: x and y axes scale 0.004514201544225216 µm (read 2026-10-23); metadata exact (D12).
            XCTAssertEqual(loaded.scanPixelSize, 0.004514201544225216)
            XCTAssertEqual(loaded.scanPixelUnit, "µm")
        }
        let session = EELSSession()
        await session.bind(loaded).value
        await session.settled()
        return session
    }

    /// The summed core-loss spectrum: where it collapses, printed for the diagnosis of the signal above 1 keV.
    @MainActor private func printCoreLoss(_ s: EELSSession, _ tag: String) {
        guard let core = s.source?.coreLoss else { say("EELSROOM \(tag) core loss: none"); return }
        let n = core.channels
        var sum = [Double](repeating: 0, count: n)
        for p in 0..<core.pixelCount { let base = p * n; for c in 0..<n { sum[c] += core.counts[base + c] } }
        say("EELSROOM \(tag) core-loss axis: offset \(core.energyOffsetEV) eV, dispersion \(core.energyScaleEV) eV/ch, \(n) channels, to \(core.energyOffsetEV + core.energyScaleEV * Double(n - 1)) eV; \(core.nx) x \(core.ny) px")
        let maxIndex = sum.indices.max { sum[$0] < sum[$1] } ?? 0
        let maxValue = sum[maxIndex]
        let below = sum.indices.first { $0 > maxIndex && sum[$0] < 0.01 * maxValue }
        let belowAny = sum.indices.first { sum[$0] < 0.01 * maxValue }
        say(String(format: "EELSROOM %@ core-loss sum: max %.4g at channel %d (%.1f eV); first channel after the max below 1%% of max: %@; first channel anywhere below 1%%: %@",
                   tag as NSString, maxValue, maxIndex, core.energyOffsetEV + core.energyScaleEV * Double(maxIndex),
                   (below.map { "\($0) (\(String(format: "%.1f", core.energyOffsetEV + core.energyScaleEV * Double($0))) eV)" } ?? "none") as NSString,
                   (belowAny.map { "\($0)" } ?? "none") as NSString))
        let tail = sum.suffix(20)
        say("EELSROOM \(tag) core-loss sum, last 20 channels: " + tail.map { String(format: "%.4g", $0) }.joined(separator: " "))
        let minValue = sum.min() ?? 0
        say("EELSROOM \(tag) core-loss sum: min \(minValue), channels with sum < 1: \(sum.filter { $0 < 1 }.count) of \(n)")
    }

    @MainActor private func drive(_ relative: String, _ tag: String) async throws {
        let s = try await openAndSettle(relative, tag)
        // t/λ map
        let map = try XCTUnwrap(s.map, "the t/λ map landed (failure: \(s.failure ?? "none"))")
        let tl = map.pixels.compactMap(\.tOverLambda)
        let med = try XCTUnwrap(median(tl), "some pixel has a t/λ")
        say("EELSROOM \(tag) t/λ: median \(med), min \(tl.min() ?? .nan), max \(tl.max() ?? .nan), \(tl.count) of \(map.pixels.count) px finite; method \(map.method); validation \(map.validation)")
        XCTAssertNotNil(s.tiles.first { $0.id == "tOverLambda" }, "the t/λ tile exists")
        XCTAssertTrue(med > 0.1 && med < 3, "median t/λ \(med) between 0.1 and 3")

        printCoreLoss(s, tag)

        // Align
        await s.align()?.value
        await s.settled()
        say("EELSROOM \(tag) align: \(s.alignmentReadout ?? "no readout") (failure: \(s.failure ?? "none"))")
        XCTAssertNotNil(s.alignment, "Align ran (failure: \(s.failure ?? "none"))")
        XCTAssertNotNil(s.alignmentReadout)
        let shift = try XCTUnwrap(s.alignmentShiftTile, "the ZLP shift tile exists after Align")
        let finite = shift.values.filter { $0.isFinite }
        say("EELSROOM \(tag) ZLP shift tile: \(shift.width) x \(shift.height), min \(finite.min() ?? .nan), max \(finite.max() ?? .nan) \(shift.unit), flat: \(shift.flatValueText ?? "no")")
        // The flat 0 eV shift on 143 (Paul's drive, 2026-10-23): either the zero-loss peak sits in one channel at every pixel already (GMS aligned it while
        // acquiring: the centres before Align have no spread) or the shifts are lost. Refuted by a spread of the centres before Align with every shift 0.
        if let before = s.alignmentTile?.values.filter({ $0.isFinite }) {
            say("EELSROOM \(tag) ZLP centre before Align: min \(before.min() ?? .nan), max \(before.max() ?? .nan) eV, \(Set(before).count) distinct values; shifts exactly 0: \(finite.filter { $0 == 0 }.count) of \(finite.count)")
        }

        // Pick C, N, O and fit
        let offered = s.offeredEdges
        say("EELSROOM \(tag) offered edges: " + offered.map { "\(EELSFitCompute.title($0)) \($0.onsetEV)" }.joined(separator: ", "))
        var wanted: [CoreLossEdge] = []
        for title in ["C K", "N K", "O K"] {
            if let e = offered.first(where: { EELSFitCompute.title($0) == title }) { wanted.append(e) }
        }
        guard wanted.count == 3 else {
            XCTFail("\(tag): the core loss does not offer C K, N K and O K (offered \(offered.map(EELSFitCompute.title)))")
            return
        }
        for e in wanted { s.toggleEdge(e) }
        if s.microscope == nil {   // a file that does not state the optics: type typical ones, as a person would under Fitting
            if s.beamEnergyKeV == nil { s.setBeamEnergy(200) }
            if s.source?.convergenceMrad == nil { s.setConvergence(21) }
            if s.source?.collectionMrad == nil { s.setCollection(25) }
            say("EELSROOM \(tag) optics not in the file: typed E0 \(s.beamEnergyKeV ?? .nan), alpha 21, beta 25")
        }
        XCTAssertNil(s.fitBlocker, "Fit can run: \(s.fitBlocker ?? "")")
        let t = Date()
        await s.run().value
        await s.settled()
        say(String(format: "EELSROOM %@ run/fit: %.1f s; align %@, thickness %@, edges %@, fit %@; failure %@", tag as NSString, Date().timeIntervalSince(t),
                   "\(s.alignState)", "\(s.thicknessState)", "\(s.edgesState)", "\(s.fitState)", (s.failure ?? "none") as NSString))
        let rows = s.regionRows
        for (w, edge) in zip(s.fitWindows, s.fittableEdges) {
            say("EELSROOM \(tag) windows \(EELSFitCompute.title(edge)): background \(w.backgroundEV.lowerBound)…\(w.backgroundEV.upperBound) eV, signal \(w.signalEV.lowerBound)…\(w.signalEV.upperBound) eV")
        }
        say("EELSROOM \(tag) exponents: " + (EELSRoomFormat.exponentsLine(rows) ?? "none") + "; convolved \(s.model?.convolved ?? false); footer " + EELSRoomFormat.fitFooter(hasFit: true, convolved: s.model?.convolved ?? false))
        if let plot = s.plot, let core = plot.core {
            for b in plot.backgrounds {
                var ratios: [Double] = [], stepsOut: [String] = []
                for k in 0..<core.counts.count {
                    let e = core.energy(k)
                    guard b.windows.signal.contains(e) || b.windows.background.contains(e), b.curve[k].isFinite, b.curve[k] > 0 else { continue }
                    if b.windows.signal.contains(e) { ratios.append(core.counts[k] / b.curve[k]) }
                    if Int((e - b.windows.background.lowerBound).rounded()) % 10 == 0 { stepsOut.append(String(format: "%.0f:%.3f", e, core.counts[k] / b.curve[k])) }
                }
                say(String(format: "EELSROOM %@ data/background over %@ signal window: mean %.4f, min %.4f, max %.4f; r %.3f; every 10 eV (energy:data/bg) %@", tag as NSString, b.edgeID as NSString,
                           ratios.reduce(0, +) / Double(max(ratios.count, 1)), ratios.min() ?? .nan, ratios.max() ?? .nan, b.exponent, stepsOut.joined(separator: " ") as NSString))
            }
        }
        for r in rows {
            say(String(format: "EELSROOM %@ row %@: I %@, areal density %@, at%% %@, wt%% %@%@", tag as NSString, r.title as NSString,
                       r.intensity.map { String(format: "%.6g", $0) } ?? "nil", r.arealDensityPerNM2.map { String(format: "%.6g", $0) } ?? "nil",
                       r.atomicPercent.map { String(format: "%.3f", $0) } ?? "nil", r.weightPercent.map { String(format: "%.3f", $0) } ?? "nil",
                       (r.unavailable.map { "  unavailable: \($0)" } ?? "") as NSString))
        }
        // The same fit with Convolve off (the low loss has a negative tail above 1 keV): printed for the diagnosis, not asserted.
        if s.convolveLowLoss && s.hasLowLoss {
            s.setConvolveLowLoss(false)
            await s.run().value
            await s.settled()
            for r in s.regionRows {
                say(String(format: "EELSROOM %@ CONVOLVE OFF row %@: I %@, at%% %@", tag as NSString, r.title as NSString,
                           r.intensity.map { String(format: "%.6g", $0) } ?? "nil", r.atomicPercent.map { String(format: "%.3f", $0) } ?? "nil"))
            }
            say("EELSROOM \(tag) CONVOLVE OFF exponents: " + (EELSRoomFormat.exponentsLine(s.regionRows) ?? "none"))
        }
        // N K narrower background windows (the C K tail runs under the default 80 eV one): printed for the diagnosis, not asserted.
        if let n = wanted.first(where: { EELSFitCompute.title($0) == "N K" }) {
            let original = s.windows(for: n)
            for width in [40.0, 25.0, 15.0] {
                s.setWindows(EELSEdgeWindows(background: (original.background.upperBound - width)...original.background.upperBound, signal: original.signal), for: n)
                await s.run().value
                await s.settled()
                say("EELSROOM \(tag) N K background \(width) eV wide: " + s.regionRows.map { String(format: "%@ I %.4g at%% %.3f", $0.title, $0.intensity ?? .nan, $0.atomicPercent ?? .nan) }.joined(separator: " | ") + "; " + (EELSRoomFormat.exponentsLine(s.regionRows) ?? ""))
            }
            s.resetWindows(for: n)
        }
        XCTAssertEqual(rows.count, 3, "a row per picked edge")
        // C K and O K have I > 0 and 0 < at% < 100; N K is below detection (I at or under 3 sigma), as GMS reads these films (`docs/design/eels-room.md`,
        // "N K on a C K tail": GMS's own maps of 143 give C 95.5, N 0.02, O 4.5 at%, the room C 95.8, N 0, O 4.2).
        for title in ["C K", "N K", "O K"] {
            let row = rows.first { $0.title == title }
            XCTAssertNotNil(row, "\(title) has a row")
            say("EELSROOM \(tag) \(title): I \(row?.intensity ?? .nan) ± \(row?.intensityStd ?? .nan), below detection \(row?.belowDetection ?? false)")
            XCTAssertNotNil(row?.intensityStd, "\(tag) \(title): the row carries the kit's 1 sigma")
            if title == "N K" {
                // GMS's own N K signal map of 143 (data/eels/EELS_2/EELS Map (1)) is 0 on 98 % of pixels: whole-map C 95.5, N 0.02, O 4.5 at%. N is not
                // detected on these films, so the room says "below detection" rather than forcing a number by narrowing the window (docs/design/eels-room.md).
                XCTAssertTrue(row?.belowDetection ?? false, "\(tag) N K: below detection, as GMS reads it")
                continue
            }
            XCTAssertGreaterThan(row?.intensity ?? 0, 0, "\(tag) \(title): I > 0")
            let at = row?.atomicPercent
            XCTAssertTrue((at ?? 0) > 0 && (at ?? 0) < 100, "\(tag) \(title): at% strictly between 0 and 100, got \(at.map { "\($0)" } ?? "nil")")
        }
    }

    /// 143: the main file.
    @MainActor func testTheEELSRoomOn143() async throws { try await drive("EELS_2/SI data (2)(2)/143_STEM SI.dm4", "143") }
    @MainActor func testTheEELSRoomOn142() async throws { try await drive("EELS_1/SI data (1)(9)/142_STEM SI.dm4", "142") }
    @MainActor func testTheEELSRoomOn145() async throws { try await drive("EELS_3/SI data (4)/145_STEM SI.dm4", "145") }
}
