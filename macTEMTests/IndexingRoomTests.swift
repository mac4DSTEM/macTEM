//
//  IndexingRoomTests.swift
//  The Indexing room (P4-04, docs/sem/design/indexing-room.md): figure F8 through the room's own path (the shipped nickel scan opened
//  as a person opens it, the phase from its crystal map, the Patterns room's default processing per pattern, `Index`), held to the
//  bundle `m4/hough-indexing-nickel-large` at the thresholds of `SEMHoughIndexingParityTests` (docs/parity.md, "Hough indexing");
//  Stop, staleness, the pattern pane's bands, the status line, the exports; the band overlay's geometry against the Radon frame; the
//  phases' reflector lists; the room's place among the rooms.
//  Red before the room: no `IndexingSession`; red under a wrong pattern source (raw instead of processed), a PC other than the file's
//  mean, a band line mirrored or transposed, Stop that keeps landing rows, a phase change that does not stale the result.
//

import XCTest
import FormatoCore
import ShellLayout
import TEMCore
import TEMSession
@testable import macTEM

nonisolated final class IndexingRoomTests: XCTestCase {

    /// The shipped nickel scan, opened as the window opens it, with the Indexing room bound to it as `AppState` binds it.
    @MainActor private func openNickel() async throws -> (patterns: EBSDSession, indexing: IndexingSession) {
        let url = try XCTUnwrap(DemoDocuments.Shipped.nickelEBSD.url, "DemoData/ is not in the bundle")
        let patterns = EBSDSession()
        let indexing = IndexingSession(patterns: patterns)
        patterns.onBind = { indexing.bind($0) }
        patterns.onClose = { indexing.close() }
        await patterns.open(url: url).value
        for _ in 0..<6000 where patterns.isMapping || patterns.isComputingMean || patterns.isProcessing { try await Task.sleep(for: .milliseconds(5)) }
        return (patterns, indexing)
    }

    private func quaternions(_ values: [Double]) -> [SIMD4<Double>] {
        stride(from: 0, to: values.count, by: 4).map { SIMD4(values[$0], values[$0 + 1], values[$0 + 2], values[$0 + 3]) }
    }

    // MARK: - Figure F8 through the room

    /// F8 as a person makes it: open the demo scan, ⌘7, Index. The phase is the file's ("ni", Fm-3m, the FCC list), the patterns the
    /// Patterns room's default stages applied per pattern (static then dynamic background, kikuchipy's tutorial), the PC the file's
    /// mean; against kikuchipy + pyEBSDindex: the indexed count within one point, 99 % of the points both index within 1° (m-3m), the
    /// matched-band count equal on 95 %. Then the room's other promises on the same run.
    @MainActor func testFigureF8ThroughTheRoom() async throws {
        let (patterns, indexing) = try await openNickel()
        XCTAssertEqual(indexing.phases.map(\.name), ["ni"], "the phase of the file's crystal map")
        let ni = try XCTUnwrap(indexing.phases.first)
        XCTAssertEqual(ni.spaceGroup, 225)
        XCTAssertEqual(ni.reflectors, .fcc)
        XCTAssertEqual(ni.source, .file)
        XCTAssertEqual(ni.pointGroupName, "m-3m")
        XCTAssertEqual(patterns.pipeline, .roomDefault)
        guard case .success(let source) = indexing.source() else { return XCTFail("the default stages are readable per pattern") }
        XCTAssertEqual(source.kind, .perPattern, "the scan is not processed: each pattern goes through the stages as it is read")
        XCTAssertNil(indexing.refusal)
        XCTAssertTrue(indexing.canIndex)
        XCTAssertTrue(indexing.verbHelp.hasSuffix("patterns with Hough (ni)"), indexing.verbHelp)

        // Stop keeps what landed and lands nothing after it.
        let stopped = indexing.index()
        XCTAssertTrue(indexing.isIndexing)
        indexing.stop()
        await stopped.value
        XCTAssertFalse(indexing.isIndexing)
        XCTAssertTrue(indexing.wasStopped)
        XCTAssertEqual(indexing.result?.rowsDone, 0, "no row lands after Stop")
        XCTAssertNil(try indexing.crystalMap(), "no crystal map before a row has landed")

        var events: [String] = []
        indexing.onEvent = { events.append($0) }
        let started = Date()
        await indexing.index().value
        let seconds = Date().timeIntervalSince(started)
        let result = try XCTUnwrap(indexing.result)
        XCTAssertTrue(result.isComplete)
        XCTAssertFalse(indexing.isIndexing)
        XCTAssertFalse(indexing.wasStopped)
        XCTAssertEqual(indexing.progress, 1)
        XCTAssertEqual(indexing.resultSource, .perPattern)
        XCTAssertTrue(events.last?.hasPrefix("Indexed \(result.indexedCount) of 4125 patterns with Hough") == true, "\(events)")

        let ref = try SEMParityReference.load("m4/hough-indexing-nickel-large")
        let refPC = try XCTUnwrap(ref.values["pc_bruker"] as? [Double])
        let pc = try XCTUnwrap(indexing.resultProjectionCenter)
        XCTAssertEqual(pc.x, refPC[0], accuracy: 1e-12)
        XCTAssertEqual(pc.y, refPC[1], accuracy: 1e-12)
        XCTAssertEqual(pc.z, refPC[2], accuracy: 1e-12)
        let solutions = result.solutions.compactMap { $0 }
        let refPhase = try ref.array("phase").values
        XCTAssertEqual(solutions.count, refPhase.count)
        let indexed = solutions.filter { $0.phase >= 0 }.count
        let refIndexed = refPhase.filter { $0 >= 0 }.count
        let ours = solutions.map { $0.phase < 0 ? SIMD4<Double>(1, 0, 0, 0) : $0.quaternion }
        let theirs = quaternions(try ref.array("quaternion").values)
        let angles = Orientations(quaternions: ours, symmetry: PointGroup.oh)
            .angles(with: Orientations(quaternions: theirs, symmetry: PointGroup.oh)).map { $0 * 180 / .pi }
        let both = (0..<angles.count).filter { solutions[$0].phase >= 0 && refPhase[$0] >= 0 }
        let within = both.filter { angles[$0] < 1 }.count
        let refN = try ref.array("nmatch").values
        let sameN = (0..<refN.count).filter { Double(solutions[$0].matchedBands) == refN[$0] }.count
        print("F8 through the room: \(String(format: "%.1f", seconds)) s; indexed \(indexed) (reference \(refIndexed)); within 1 degree \(within) of \(both.count); same matched-band count \(sameN) of \(refN.count)")
        XCTAssertLessThanOrEqual(abs(indexed - refIndexed), 1)
        XCTAssertGreaterThanOrEqual(Double(within), 0.99 * Double(both.count))
        XCTAssertGreaterThanOrEqual(Double(sameN), 0.95 * Double(refN.count))
        XCTAssertEqual(result.indexedCount, indexed)
        XCTAssertEqual(result.countsByPhase, [indexed])

        // The map: one RGBA pixel per point; an indexed point carries orix's IPF-Z colour of its orientation.
        let rgba = try XCTUnwrap(indexing.mapRGBA)
        XCTAssertEqual(rgba.count, result.pointCount * 4)
        let first = try XCTUnwrap((0..<solutions.count).first { solutions[$0].phase >= 0 })
        let colour = IPFColorKeyTSL(PointGroup.oh, direction: SIMD3(0, 0, 1)).color(of: [solutions[first].quaternion])[0]
        for c in 0..<3 { XCTAssertEqual(Double(rgba[first * 4 + c]), (colour[c] * 255).rounded(), accuracy: 1, "channel \(c)") }

        // The status line and the CSV.
        let position = EBSDPosition(row: first / result.scanColumns, column: first % result.scanColumns)
        let line = try XCTUnwrap(indexing.readout(at: position))
        XCTAssertTrue(line.contains("φ₁") && line.contains("Φ") && line.contains("φ₂") && line.contains("CI"), line)
        XCTAssertTrue(line.hasPrefix("row \(position.row) · col \(position.column) · ni"), line)
        let csv = result.csv(stepX: 1.5, stepY: 1.5).split(separator: "\n")
        XCTAssertEqual(csv.first, "row,column,x,y,phase,phi1_deg,Phi_deg,phi2_deg,ci,fit_deg,matched_bands,pattern_quality")
        XCTAssertEqual(csv.count, result.pointCount + 1)

        // The pattern pane: the pinned pattern as indexed, its detected bands, those the solution matched named by family.
        patterns.pin(position)
        await indexing.showPattern().value
        XCTAssertEqual(indexing.patternPosition, position)
        XCTAssertEqual(indexing.detectedBands.count, HoughIndexingSettings.roomDefault.bands)
        let matched = indexing.detectedBands.filter(\.isMatched)
        XCTAssertFalse(matched.isEmpty)
        XCTAssertTrue(matched.allSatisfy { ["{002}", "{111}", "{022}", "{113}"].contains($0.family ?? "") }, "\(matched.map(\.family))")
        XCTAssertEqual(matched.count, solutions[first].matchedBands, "the overlay names the bands the solution counts, no more")
        XCTAssertLessThanOrEqual(matched.filter { $0.fitDegrees != nil }.count, 6, "QUEST weighs at most six bands")
        XCTAssertTrue(indexing.detectedBands.filter(\.isValid).allSatisfy { $0.start != nil && $0.end != nil }, "a valid band crosses its pattern")

        // The exports, written where a journey writes them.
        let state = IndexingRoomState()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("IndexingRoomTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        var reports: [String] = []
        for kind in IndexingExportKind.allCases { state.export(kind, from: indexing, directory: directory) { reports.append($0) } }
        XCTAssertEqual(reports, ["Exported patterns_v2 indexed IPF-Z.png", "Exported patterns_v2 indexing results.csv",
                                 "Exported patterns_v2 indexed.ang", "Exported patterns_v2 indexed.ctf", "Exported patterns_v2 indexing method.json"])

        // The run as orix's crystal map, as kikuchipy builds it (D-SEM-81) with the room's colours; the .ang and .ctf read back as it.
        let xmap = try XCTUnwrap(try indexing.crystalMap())
        XCTAssertEqual(xmap.pointCount, result.pointCount)
        XCTAssertEqual(xmap.isIndexed.filter { $0 }.count, result.indexedCount)
        XCTAssertEqual(xmap.phases.entries.filter { $0.id != PhaseList.notIndexedID }.map(\.phase.name), ["ni"])
        XCTAssertEqual(xmap.phases[id: 0]?.color, indexing.phases[0].color)
        XCTAssertEqual(xmap.property("nmatch"), solutions.map { Double($0.matchedBands) })
        XCTAssertEqual(xmap.scanUnit, patterns.document?.dataset.scanUnit)
        let ang = try ANGReader.read(url: directory.appendingPathComponent("patterns_v2 indexed.ang")).map
        let ctf = try CTFReader.read(path: directory.appendingPathComponent("patterns_v2 indexed.ctf").path)
        XCTAssertEqual(ctf.map.property("bands"), xmap.property("nmatch"), "the .ctf's Bands are the matched bands")
        for (format, back, bound) in [("ang", ang, 2.0e-5), ("ctf", ctf.map, 3.0e-6)] {
            XCTAssertEqual(back.shape, [result.scanRows, result.scanColumns], format)
            XCTAssertEqual(back.isIndexed, xmap.isIndexed, format)
            var worst = 0.0
            for (i, q) in back.rotationsInData.enumerated() where xmap.isIndexed[i] {
                worst = max(worst, Rotation(q).angle(with: Rotation(xmap.rotations[i])))
            }
            XCTAssertLessThan(worst, bound, "\(format): largest rotation difference \(worst) rad")
        }
        let method = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("patterns_v2 indexing method.json"))) as? [String: Any]
        XCTAssertEqual(method?["indexed"] as? Int, indexed)
        XCTAssertEqual(method?["patterns"] as? String, IndexingSource.Kind.perPattern.title)

        // A scalar layer is its values through the Map Display (D-SEM-96): the canvas spans the indexed points' CI, the points not
        // indexed are masked; its PNG is the pane's picture. The Euler layer is orix's Euler colour key of the orientation.
        XCTAssertFalse(indexing.isStale)
        indexing.setLayer(.confidence)
        XCTAssertFalse(indexing.isStale)
        XCTAssertTrue(indexing.showsScalarMap)
        XCTAssertNil(indexing.mapRGBA, "a scalar layer is not painted as RGBA")
        let canvas = try XCTUnwrap(indexing.mapPresentation.canvas)
        XCTAssertEqual([canvas.width, canvas.height], [result.scanColumns, result.scanRows])
        let ci = solutions.filter { $0.phase >= 0 }.map { Float($0.confidence) }
        let lowest = try XCTUnwrap(ci.min()), highest = try XCTUnwrap(ci.max())
        XCTAssertEqual(canvas.rawRange, lowest...highest)
        XCTAssertEqual(canvas.normalized.filter { $0 < 0 }.count, result.pointCount - indexed, "a point not indexed is masked")
        reports = []
        state.export(.mapPNG, from: indexing, directory: directory) { reports.append($0) }
        XCTAssertEqual(reports, ["Exported patterns_v2 indexed Confidence index.png"])
        indexing.setLayer(.euler)
        XCTAssertFalse(indexing.showsScalarMap)
        let euler = try XCTUnwrap(indexing.mapRGBA)
        let eulerColour = EulerColorKey(PointGroup.oh).color(of: [solutions[first].quaternion])[0]
        for c in 0..<3 { XCTAssertEqual(Double(euler[first * 4 + c]), (eulerColour[c] * 255).rounded(), accuracy: 1, "channel \(c)") }

        // A phase or processing change stales the result; undoing it makes it current again; a layer change never stales.
        indexing.setPhase(named: "ni", isOn: false)
        XCTAssertTrue(indexing.isStale)
        XCTAssertEqual(indexing.refusal, "Turn a phase on to index against it.")
        XCTAssertFalse(indexing.canIndex)
        indexing.setPhase(named: "ni", isOn: true)
        XCTAssertFalse(indexing.isStale)
        patterns.editPipeline { $0.dynamicStage.isOn = false }
        XCTAssertTrue(indexing.isStale)
        XCTAssertTrue(indexing.verbHelp.hasSuffix("the inputs changed since the last run"), indexing.verbHelp)

        // Closing the dataset sends the room back to its door.
        patterns.close()
        XCTAssertNil(indexing.result)
        XCTAssertNil(indexing.mapRGBA)
        XCTAssertTrue(indexing.phases.isEmpty)
    }

    // MARK: - The phases

    /// The reflector lists follow pyEBSDindex's defaults by lattice; the presets carry DiffractoKit's cells; a name already in the list
    /// is numbered; a phase without a crystal map phase's space group is refused. Red under: HCP on a cubic group, BCC for iron missing.
    @MainActor func testPhasesTakePyEBSDindexsReflectorListsAndThePresetsBuild() async throws {
        XCTAssertEqual(IndexingPhase.defaultReflectors(spaceGroup: 225), .fcc)
        XCTAssertEqual(IndexingPhase.defaultReflectors(spaceGroup: 227), .fcc, "pyEBSDindex's default for every group that is not BCC or HCP")
        XCTAssertEqual(IndexingPhase.defaultReflectors(spaceGroup: 229), .bcc)
        XCTAssertEqual(IndexingPhase.defaultReflectors(spaceGroup: 194), .hcp)
        XCTAssertEqual(IndexingPhase.presets.map(\.name), ["Ni", "Al", "Cu", "Au", "Fe (α)", "Si", "Mg"])
        XCTAssertEqual(IndexingPhase.presets.first { $0.name == "Fe (α)" }?.reflectors, .bcc)
        XCTAssertEqual(IndexingPhase.presets.first { $0.name == "Mg" }?.reflectors, .hcp)
        for phase in IndexingPhase.presets {
            XCTAssertNil(phase.refusal, phase.name)
            XCTAssertNoThrow(try phase.library(angleTolerance: 2, earlyExitBands: 10), phase.name)
        }
        XCTAssertEqual(IndexingPhase.uniqueName("Ni", among: ["Ni", "Ni 2"]), "Ni 3")
        XCTAssertEqual(IndexingPhase.uniqueName("Al", among: ["Ni"]), "Al")
        var hcpOnCubic = IndexingPhase(name: "x", spaceGroup: 225, lattice: [1, 1, 1, 90, 90, 90], source: .preset)
        hcpOnCubic.reflectors = .hcp
        XCTAssertNotNil(hcpOnCubic.refusal)
        XCTAssertFalse(IndexingPhase.Reflectors.hcp.fits(spaceGroup: 225))

        // The generated demo without its crystal map: Index asks for a phase; added presets take the next colours under unique names.
        let patterns = EBSDSession()
        let indexing = IndexingSession(patterns: patterns)
        patterns.onBind = { indexing.bind($0) }
        var demo = try DemoDocuments.ebsd()
        demo.dataset.crystalMap = nil
        await patterns.bind(demo).value
        XCTAssertTrue(indexing.phases.isEmpty)
        XCTAssertEqual(indexing.refusal, "Add a phase first: from the file, a preset or a CIF.")
        XCTAssertFalse(indexing.canIndex)
        indexing.addPhase(IndexingPhase.presets[0])
        indexing.addPhase(IndexingPhase.presets[0])
        XCTAssertEqual(indexing.phases.map(\.name), ["Ni", "Ni 2"])
        XCTAssertNotEqual(indexing.phases[0].color, indexing.phases[1].color)
        XCTAssertNotEqual(indexing.refusal, "Add a phase first: from the file, a preset or a CIF.")
        indexing.removePhase(named: "Ni 2")
        XCTAssertEqual(indexing.phases.map(\.name), ["Ni"])
        indexing.editSettings { $0.bands = 2 }
        XCTAssertNotNil(indexing.refusal, "two bands cannot vote a triplet")
        indexing.resetSettings()
        XCTAssertEqual(indexing.settings, .roomDefault)
    }

    // MARK: - The band overlay

    /// The band's centre line on the pattern, from its (ρ, θ) in the detector's frame (x right, y up from the centre): θ = 90° is a row,
    /// θ = 0 a column, clipped to the pixel edges. Red under a mirrored row or swapped axes.
    func testBandLinesSitWhereTheRadonFramePutsThem() throws {
        let row = try XCTUnwrap(IndexedBand.segment(rho: 4.5, theta: .pi / 2, rows: 60, columns: 60))
        XCTAssertEqual(row.start.y, 25, accuracy: 1e-9)
        XCTAssertEqual(row.end.y, 25, accuracy: 1e-9)
        XCTAssertEqual(min(row.start.x, row.end.x), -0.5, accuracy: 1e-9)
        XCTAssertEqual(max(row.start.x, row.end.x), 59.5, accuracy: 1e-9)
        let column = try XCTUnwrap(IndexedBand.segment(rho: 10.5, theta: 0, rows: 60, columns: 60))
        XCTAssertEqual(column.start.x, 40, accuracy: 1e-9)
        XCTAssertEqual(column.end.x, 40, accuracy: 1e-9)
        XCTAssertEqual(min(column.start.y, column.end.y), -0.5, accuracy: 1e-9)
        XCTAssertEqual(max(column.start.y, column.end.y), 59.5, accuracy: 1e-9)
        let diagonal = try XCTUnwrap(IndexedBand.segment(rho: 0, theta: .pi / 4, rows: 60, columns: 60))
        XCTAssertEqual(diagonal.start.x, diagonal.start.y, accuracy: 1e-9, "x = −y through the centre with y up: the main diagonal (row = column)")
        let antiDiagonal = try XCTUnwrap(IndexedBand.segment(rho: 0, theta: 3 * .pi / 4, rows: 60, columns: 60))
        XCTAssertEqual(antiDiagonal.start.x + antiDiagonal.start.y, 59, accuracy: 1e-9, "x = y through the centre with y up: the anti-diagonal")
        XCTAssertNil(IndexedBand.segment(rho: 100, theta: 0, rows: 60, columns: 60), "a line beyond the pattern is not drawn")
        XCTAssertEqual(IndexedBand.familyLabel([1, 1, 1]), "{111}")
        XCTAssertEqual(IndexedBand.familyLabel([1, 0, -1, 1]), "{10-11}")
    }

    /// The detector's own bands land where the pattern's stripes are: a bright row stripe and a bright column stripe on a 60 × 60
    /// pattern give lines through their middles. Red under any sign or axis slip between `HoughBandDetector` and the overlay.
    func testDetectedStripesAreDrawnOnTheirStripes() throws {
        let detector = try HoughBandDetector(rows: 60, columns: 60, settings: HoughIndexingSettings.roomDefault.detectorSettings)
        for (along, centre) in [(true, 25), (false, 40)] {
            var pattern = [Double](repeating: 10, count: 3600)
            for k in (centre - 1)...(centre + 1) {
                for j in 0..<60 { pattern[along ? k * 60 + j : j * 60 + k] = 200 }
            }
            let raw = try detector.detect(pattern)
            let bands = IndexedBand.bands(raw, solution: nil, libraries: [], rows: 60, columns: 60)
            let strongest = try XCTUnwrap(bands.filter(\.isValid).max { $0.peak < $1.peak })
            let start = try XCTUnwrap(strongest.start), end = try XCTUnwrap(strongest.end)
            if along {
                XCTAssertEqual(start.y, Double(centre), accuracy: 0.75)
                XCTAssertEqual(end.y, Double(centre), accuracy: 0.75)
                XCTAssertGreaterThan(abs(end.x - start.x), 55)
            } else {
                XCTAssertEqual(start.x, Double(centre), accuracy: 0.75)
                XCTAssertEqual(end.x, Double(centre), accuracy: 0.75)
                XCTAssertGreaterThan(abs(end.y - start.y), 55)
            }
            XCTAssertNil(strongest.family, "no solution: no family")
        }
    }

    // MARK: - The room among the rooms

    /// Indexing is the seventh room (⌘7, between Patterns and Results), entered with an EBSD dataset; its verb is Index.
    @MainActor func testTheRoomSitsAfterPatternsAndNeedsADataset() throws {
        XCTAssertEqual(WorkspaceArea.indexing.title, "Indexing")
        XCTAssertEqual(WorkspaceArea.indexing.systemImage, "scope")
        XCTAssertEqual(WorkspaceArea.indexing.shortcutDigit, "7")
        XCTAssertEqual(WorkspaceArea.allCases.firstIndex(of: .indexing), WorkspaceArea.allCases.firstIndex(of: .patterns).map { $0 + 1 })
        XCTAssertNil(RoomAvailability.reason(.indexing, holdings: RoomHoldings(ebsd: true)))
        XCTAssertEqual(RoomAvailability.reason(.indexing, holdings: RoomHoldings(images: true)), "No file open holds EBSD patterns")
        let state = AppState()
        XCTAssertNil(RoomPrimaryAction.current(state), "no verb in the Image room with nothing open")
        state.selectWorkspace(.indexing)
        XCTAssertEqual(state.navigation.workspaceArea, .indexing, "with nothing open every room can be entered")
        XCTAssertNil(RoomPrimaryAction.current(state), "no verb before a dataset")
        var demo = try DemoDocuments.ebsd()
        demo.dataset.crystalMap = nil
        state.ebsd.bind(demo)
        XCTAssertNotNil(state.indexing.patterns.document, "the window's Indexing room follows the Patterns room's dataset")
        let verb = RoomPrimaryAction.current(state)
        XCTAssertEqual(verb?.title, "Index")
        XCTAssertEqual(verb?.isEnabled, false, "no phase once the demo's crystal map is gone")
        XCTAssertEqual(verb?.help, "Add a phase first: from the file, a preset or a CIF.")
        XCTAssertEqual(BusyOperation.name(room: .indexing, appState: state), nil)
    }
}
