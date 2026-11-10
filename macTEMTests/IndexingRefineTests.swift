//
//  IndexingRefineTests.swift
//  The Indexing room's Refine stage (design §3, §4; D-SEM-109): a Dictionary run's indexed rows refined block by block with
//  kikuchipy's refine_orientation (`EBSDRefinement`'s pattern-level calls), landed in order on a copy of the run kept beside it.
//  Two blocks of `m4/refine-dictionary-nickel-block` give exactly one call over every indexed point, and their crystal map is
//  kikuchipy's refined map at `SEMRefineDictionaryParityTests`' bounds; then the room's path on the shipped Ni scan at a coarse 10°:
//  Index → Refine under one verb, the exports and Open in Maps on the refinement, Compare's `Refined`, the switch, staleness (a Refine
//  edit refines alone), Stop, one phase, and the Output words.
//  Red before: no Refine stage. Also red when `crystalMap()` rebuilds a refinement from `dictionary.bestRotations` (the refined
//  orientations lost silently), a block lands out of order, a Refine edit stales the Dictionary run, or Stop keeps landing blocks or
//  marks the Dictionary run stopped.
//

import XCTest
import FormatoCore
import TEMCore
import TEMSession
@testable import macTEM

nonisolated final class IndexingRefineTests: XCTestCase {

    /// The repo's own source file at `path`, read beside this test file.
    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    private func squeezed(_ text: String) -> String { text.split(whereSeparator: \.isWhitespace).joined(separator: " ") }

    /// The shipped nickel scan, opened as the window opens it, with the Indexing room bound to it and the shipped master pattern open.
    @MainActor private func openNickel() async throws -> (patterns: EBSDSession, indexing: IndexingSession) {
        let url = try XCTUnwrap(DemoDocuments.Shipped.nickelEBSD.url, "DemoData/ is not in the bundle")
        let patterns = EBSDSession()
        let indexing = IndexingSession(patterns: patterns)
        patterns.onBind = { indexing.bind($0) }
        patterns.onClose = { indexing.close() }
        await patterns.open(url: url).value
        for _ in 0..<6000 where patterns.isMapping || patterns.isComputingMean || patterns.isProcessing { try await Task.sleep(for: .milliseconds(5)) }
        let master = try XCTUnwrap(DemoDocuments.Shipped.nickelMasterPattern.url, "DemoData/ holds no master pattern")
        await indexing.openMasterPattern(url: master).value
        return (patterns, indexing)
    }

    // MARK: - Blocks against one call, and the refined map against kikuchipy

    /// F9's 6 × 6 block as a dictionary run (the stored best matches, two points masked out), refined in two blocks of three rows at
    /// the bundle's 1°: each point exactly as one `refineOrientations` call over all 34 indexed points gives it, a block out of order
    /// dropped, and the refinement's crystal map kikuchipy's refined map (`is_in_data`, phase ids, under 0.1°, scores at rtol 1e-4,
    /// `num_evals`); the helpers' numbers.
    func testRefiningInBlocksEqualsOneCall() throws {
        let ref = try SEMParityReference.load("m4/refine-dictionary-nickel-block")
        let mp = try EMsoftMasterPatternReader.read(url: try XCTUnwrap(ref.inputURL(1)), type: .ebsd, projection: .lambert, hemisphere: .both)
        let master = try EBSDRefinement.Master(mp, energy: try XCTUnwrap(ref.values["energy"] as? Double))
        let d = try XCTUnwrap(ref.values["detector"] as? [String: Any])
        let shape = try XCTUnwrap(d["shape"] as? [Int])
        let pc = try XCTUnwrap(d["pc"] as? [Double])
        let detector = EBSDDetectorGeometry(rows: shape[0], columns: shape[1], pixelSize: 1, binning: d["binning"] as? Int ?? 1,
                                            sampleTilt: try XCTUnwrap(d["sample_tilt"] as? Double),
                                            projectionCenters: [SIMD3(pc[0], pc[1], pc[2])])
        let pixels = shape[0] * shape[1]
        let patterns = try ref.array("patterns").values
        XCTAssertEqual(patterns.count, 36 * pixels)

        // The dictionary result as SEMRefineDictionaryParityTests builds it, landed on the room's result.
        let inData = try ref.array("navigation_mask").values.map { $0 == 0 }
        let q = try ref.array("start_quaternions").values
        let starts = stride(from: 0, to: q.count, by: 4).map { SIMD4(q[$0], q[$0 + 1], q[$0 + 2], q[$0 + 3]) }
        let simIndices = try ref.array("start_simulation_indices").values.map { Int($0) }
        var rotations = [SIMD4<Double>](repeating: SIMD4(1, 0, 0, 0), count: 36)
        var indices = [Int](repeating: -1, count: 36), scores = [Double](repeating: .nan, count: 36)
        var j = 0
        for i in 0 ..< 36 where inData[i] {
            rotations[i] = starts[j]; indices[i] = simIndices[j]; scores[i] = 0.5
            j += 1
        }
        let matched = DictionaryIndexing.Result(navigationShape: [6, 6], keepN: 1, isInData: inData, scores: scores,
                                                simulationIndices: indices, rotations: rotations)
        let ni = IndexingPhase(name: "ni", spaceGroup: 225, lattice: [3.52, 3.52, 3.52, 90, 90, 90], source: .preset, color: "tab:blue")
        var base = IndexingResult(scanRows: 6, scanColumns: 6, phases: [ni], metric: .ncc)
        base.land(matched, rows: 0..<6)
        XCTAssertEqual(base.indexedCount, 34)

        // Two blocks of three rows, refined and landed in order; a block that does not follow is dropped.
        XCTAssertEqual(IndexingRefinement.blocks(rows: 6, columns: 6, limit: 3), [0..<3, 3..<6])
        var refined = IndexingResult(refining: base)
        XCTAssertEqual(refined.rowsDone, 0)
        XCTAssertEqual(refined.metric, .ncc)
        XCTAssertTrue(refined.isRefined)
        XCTAssertFalse(base.isRefined)
        let settings = IndexingRefineSettings(target: .orientation, trustAngle: 1)
        let refine = { (rows: Range<Int>) throws -> IndexingRefinedBlock in
            try IndexingRefinement.refine(base, rows: rows, experimental: Array(patterns[(rows.lowerBound * 6 * pixels)..<(rows.upperBound * 6 * pixels)]),
                                          isFloat32: false, detector: detector, master: master, signalMask: nil, settings: settings)
        }
        let second = try refine(3..<6)
        refined.landRefined(second)
        XCTAssertEqual(refined.rowsDone, 0, "a block that does not follow is dropped")
        refined.landRefined(try refine(0..<3))
        refined.landRefined(second)
        XCTAssertEqual(refined.rowsDone, 6)
        XCTAssertTrue(refined.isComplete)

        // Exactly one call over every indexed point, from the same starts.
        let points = (0..<36).filter { (base.solutions[$0]?.phase ?? -1) >= 0 }
        XCTAssertEqual(points.count, 34)
        var values: [Float] = []
        for i in points { values += patterns[(i * pixels)..<((i + 1) * pixels)].map { Float($0) } }
        let one = try EBSDRefinement.refineOrientations(EBSDRefinement.Patterns(count: 34, pixels: pixels, values: values, isFloat32: false),
                                                        starts: EBSDRefinement.startingEuler(rotations: points.map { base.solutions[$0]?.quaternion ?? .zero }),
                                                        detector: detector, master: master, settings: settings.solver(signalMask: nil))
        for (k, i) in points.enumerated() {
            let s = try XCTUnwrap(refined.solutions[i])
            XCTAssertEqual(s.quaternion, RotationConversions.eu2qu(one[k].euler), "point \(i)")
            XCTAssertEqual(s.confidence, one[k].score, "point \(i)")
            XCTAssertEqual(s.phase, 0, "point \(i)")
            XCTAssertEqual(refined.evaluations[i], one[k].evaluations, "point \(i)")
        }
        for i in 0..<36 where !points.contains(i) {
            XCTAssertEqual(refined.solutions[i]?.phase, -1, "point \(i)")
            XCTAssertEqual(refined.evaluations[i], 0, "point \(i)")
        }

        // The refinement's crystal map: kikuchipy's refined map, from the refined points, never from the dictionary's matches.
        let map = try XCTUnwrap(try refined.crystalMap(steps: (1.5, 1.5), scanUnit: "um"))
        XCTAssertEqual(map.isInData.map { $0 ? 1.0 : 0.0 }, try ref.array("refined_is_in_data").values)
        XCTAssertEqual(map.scanUnit, "um")
        SEMAssertParity(map.phaseIDs.map(Double.init), try ref.array("refined_phase_id"))
        let e = try ref.array("refined_euler").values
        let reference = stride(from: 0, to: e.count, by: 3).map { SIMD3(e[$0], e[$0 + 1], e[$0 + 2]) }
        let ours = Orientations(quaternions: map.rotationsInData, symmetry: PointGroup.oh)
        let theirs = Orientations(quaternions: reference.map(RotationConversions.eu2qu), symmetry: PointGroup.oh)
        let angles = ours.angles(with: theirs).map { $0 * 180 / .pi }
        XCTAssertEqual(angles.count, 34)
        XCTAssertLessThan(try XCTUnwrap(angles.max()), 0.1, "largest misorientation \(angles.max() ?? .nan) degrees")
        SEMAssertParity(try XCTUnwrap(map.property("scores")), try ref.array("refined_scores"))
        XCTAssertEqual(map.properties["num_evals"], refined.evaluations.map(Double.init))
        XCTAssertEqual(map.phases[id: 0]?.name, "ni")
        XCTAssertEqual(map.phases[id: 0]?.color, "tab:blue")
        let best = try XCTUnwrap(base.dictionary).bestRotations
        for i in points {
            XCTAssertEqual(map.rotations[i], Rotation(try XCTUnwrap(refined.solutions[i]).quaternion).q, "point \(i)")
        }
        let moved = points.map { Rotation(map.rotations[$0]).angle(with: Rotation(best[$0])) * 180 / .pi }
        XCTAssertGreaterThan(moved.reduce(0, +) / Double(moved.count), 0.01, "the map is the refined one, not the dictionary's matches")
        XCTAssertEqual(refined.similarity.map(\.bitPattern), base.similarity.map(\.bitPattern), "the dictionary's OSM is kept")
        XCTAssertEqual(refined.dictionary?.simulationIndices, base.dictionary?.simulationIndices, "the dictionary's matches are kept")
        XCTAssertEqual(refined.simulationIndex(at: EBSDPosition(row: 2, column: 3)), base.simulationIndex(at: EBSDPosition(row: 2, column: 3)))

        // The helpers.
        let room = IndexingRefinement.blocks(rows: 55, columns: 75, limit: 55)
        XCTAssertEqual(room.count, 10)
        XCTAssertEqual(room.first, 0..<6)
        XCTAssertEqual(room.last, 54..<55)
        XCTAssertEqual(IndexingRefinement.blocks(rows: 55, columns: 75, limit: 2).first, 0..<2, "never above the dictionary's block")
        let spread = try XCTUnwrap(IndexingRefinement.meanAndDeviation([SIMD3(0.40, 0.20, 0.5), SIMD3(0.42, 0.22, 0.5), SIMD3(0.44, 0.24, 0.5)]))
        let sd = (0.0008 / 3).squareRoot()
        for (got, want) in zip([spread.mean.x, spread.mean.y, spread.mean.z, spread.deviation.x, spread.deviation.y, spread.deviation.z],
                               [0.42, 0.22, 0.5, sd, sd, 0]) {
            XCTAssertEqual(got, want, accuracy: 1e-12)
        }
        XCTAssertNil(IndexingRefinement.meanAndDeviation([]))
        XCTAssertEqual(IndexingRefineSettings().trustRegion, [2, 2, 2])
        XCTAssertEqual(IndexingRefineSettings(target: .projectionCenter).trustRegion, [0.05, 0.05, 0.05])
        XCTAssertEqual(IndexingRefineSettings(target: .both).trustRegion, [2, 2, 2, 0.05, 0.05, 0.05])
        XCTAssertEqual(IndexingRefineSettings.roomDefault, IndexingRefineSettings(target: .orientation, trustAngle: 2, trustPC: 0.05))
        XCTAssertNotNil(IndexingRefineSettings(trustAngle: 0).refusal)
        XCTAssertNotNil(IndexingRefineSettings(target: .both, trustPC: 2).refusal)
        XCTAssertNil(IndexingRefineSettings(target: .projectionCenter, trustAngle: 0).refusal, "a field the target does not use is not checked")
        XCTAssertTrue(IndexingRefineSettings().refinesAlike(IndexingRefineSettings(trustPC: 0.2)), "a PC edit leaves an orientation refinement")
        XCTAssertFalse(IndexingRefineSettings().refinesAlike(IndexingRefineSettings(trustAngle: 3)))
        let mask = [true, false, false, true]
        XCTAssertEqual(IndexingRefineSettings().solver(signalMask: mask).signalMask, mask)
        XCTAssertEqual(IndexingRefineSettings().solver(signalMask: nil).trustRegion, [2, 2, 2])
        XCTAssertEqual(IndexingRefineSettings().solver(signalMask: nil).options, NelderMead.Options(), "SciPy's defaults")
        XCTAssertEqual(IndexingRefineSettings().words, "Orientation · ±2° · Nelder–Mead")
    }

    // MARK: - The room's path

    /// Refine › After indexing on the shipped Ni scan at 10° (the room's whole path): one Index runs Dictionary then Refine, the room
    /// shows the refinement (NCC, the dictionary's layers), its exports and Open in Maps are the refined map, Compare holds
    /// Dictionary against Refined, the switch picks the run on screen, a Refine edit stales the refinement only and Index then refines
    /// alone, Stop keeps the Dictionary run, several phases are refused, and the Output words belong to the Dictionary run.
    @MainActor func testRefineThroughTheRoom() async throws {
        let started = Date()
        let (_, indexing) = try await openNickel()
        indexing.setMethod(.dictionary)
        indexing.editDictionarySettings { $0.resolution = 10 }
        indexing.setRefinesAfterIndexing(true)
        XCTAssertNil(indexing.refusal, indexing.refusal ?? "")
        XCTAssertTrue(indexing.verbHelp.hasSuffix("with Dictionary (ni), then refine the orientations"), indexing.verbHelp)

        // One verb, the stale stages in order: Dictionary, then Refine in the same turn.
        let record = SEMSessionRecord()
        var events: [String] = []
        indexing.onEvent = {
            events.append($0)
            record.note($0, in: .indexing)
        }
        let first = Date()
        await indexing.index().value
        print("Index → Refine (10° dictionary, Orientation ±2°): \(String(format: "%.1f", Date().timeIntervalSince(first))) s; "
            + events.filter { $0.hasPrefix("Indexed ") || $0.hasPrefix("Refined ") }.joined(separator: "; "))
        let dictionary = try XCTUnwrap(indexing.runs[.dictionary])
        XCTAssertTrue(dictionary.result.isComplete)
        XCTAssertFalse(dictionary.wasStopped)
        let shown = try XCTUnwrap(indexing.shownRun)
        XCTAssertNotNil(shown.refinement)
        XCTAssertEqual(shown.refinement?.base, dictionary.id)
        XCTAssertEqual(shown.id, indexing.refinedRun?.id)
        XCTAssertEqual(shown.title, "Dictionary · Refined")
        XCTAssertTrue(indexing.result?.isComplete == true)
        XCTAssertFalse(indexing.isIndexing)
        XCTAssertFalse(indexing.isRefining)
        XCTAssertEqual(indexing.progress, 1)
        XCTAssertNotNil(shown.seconds)
        let indexed = try XCTUnwrap(events.firstIndex { $0.hasPrefix("Indexed 4125 of 4125 patterns with Dictionary") }, "\(events)")
        XCTAssertTrue(events.last?.hasPrefix("Refined 4125 of 4125 patterns (orientations) in ") == true, "\(events)")
        XCTAssertGreaterThan(events.count - 1, indexed)
        let scores = try XCTUnwrap(indexing.refinementScores)
        XCTAssertGreaterThan(scores.after, scores.before, "the refinement raises the mean NCC")
        XCTAssertEqual(scores.metric, "NCC")
        XCTAssertNil(indexing.refinedProjectionCentre, "Orientation holds the PC")
        XCTAssertEqual(indexing.availableLayers, IndexingLayer.layers(for: .dictionary))
        XCTAssertEqual(indexing.result?.scoreTitle, "NCC")
        XCTAssertEqual(indexing.dictionaryPlans.count, 1)
        XCTAssertFalse(indexing.isStale)

        // The exports and Open in Maps: the refined map, the dictionary's record with the refinement added.
        let result = try XCTUnwrap(indexing.result)
        let map = try XCTUnwrap(try indexing.crystalMap())
        XCTAssertEqual(map.pointCount, 4125)
        let solutions = result.solutions.compactMap { $0 }
        XCTAssertEqual(solutions.count, 4125)
        XCTAssertEqual(map.rotations, solutions.map { Rotation($0.quaternion).q }, "the map holds the refined orientations")
        let best = try XCTUnwrap(dictionary.result.dictionary).bestRotations
        let moved = (0..<4125).filter { Rotation(map.rotations[$0]).angle(with: Rotation(best[$0])) > 1e-6 }.count
        XCTAssertGreaterThan(moved, 4125 / 2, "most points moved from the dictionary's best match")
        let evaluations = try XCTUnwrap(map.property("num_evals"))
        XCTAssertTrue(zip(map.phaseIDs, evaluations).allSatisfy { $0 != 0 || $1 > 0 }, "every refined point has its evaluations")
        XCTAssertNoThrow(try ANGWriter.text(of: map, options: IndexingResult.dictionaryAngOptions))
        let method = try XCTUnwrap(try JSONSerialization.jsonObject(with: try XCTUnwrap(try indexing.methodJSON())) as? [String: Any])
        let refinement = try XCTUnwrap(method["refinement"] as? [String: Any])
        XCTAssertEqual(refinement["call"] as? String, "EBSD.refine_orientation")
        XCTAssertEqual(refinement["trustRegion"] as? [Double], [2, 2, 2])
        XCTAssertEqual(refinement["refined"] as? Int, 4125)
        XCTAssertEqual(method["samplingResolutionDegrees"] as? Double, 10, "the dictionary's keys stay")
        XCTAssertEqual(method["indexed"] as? Int, 4125)
        let maps = try XCTUnwrap(try indexing.mapsDocument())
        XCTAssertEqual(maps.format, "Indexing room · Dictionary · Refined")
        XCTAssertEqual(maps.source, .indexing(run: shown.id, method: .dictionary))
        XCTAssertNil(indexing.staleness(ofRun: shown.id, method: .dictionary))
        let exported = IndexingRoomState.record(.ang, data: Data(), layer: .ipfZ, method: .dictionary, refined: true, fileName: "patterns_v2.h5")
        XCTAssertEqual(exported.methods, [.dictionaryIndexing, .patternRefinement, .angWriter])
        let rows = SEMSessionLedger.indexingRows(indexing, record: record, since: nil)
        XCTAssertEqual(rows.first?.label, "Refined dictionary indexing")
        XCTAssertEqual(rows.first.map { Array($0.methods.prefix(2)) }, [.dictionaryIndexing, .patternRefinement])
        XCTAssertEqual(rows.first?.fields.first { $0.name == "Refine" }?.value, "Orientation · ±2° · Nelder–Mead")
        XCTAssertTrue(rows.first?.log.contains { $0.text.hasPrefix("Refined ") } == true)

        // Compare: the Dictionary run against its refinement, within the trust region.
        indexing.setShowsCompare(true)
        indexing.setCompareA(.dictionary)
        indexing.setCompareB(.refined)
        XCTAssertEqual([indexing.compareA, indexing.compareB], [.dictionary, .refined])
        XCTAssertNil(indexing.compareAbsence(.refined))
        await indexing.refreshComparison().value
        let median = try XCTUnwrap(indexing.comparison?.medianDegrees)
        XCTAssertGreaterThan(median, 0)
        XCTAssertLessThan(median, 6, "±2° on each Euler angle")
        indexing.setShowsCompare(false)

        // The switch: off shows the run as indexed, on the refinement again.
        indexing.setRefinesAfterIndexing(false)
        XCTAssertEqual(indexing.shownRun?.id, dictionary.id)
        XCTAssertNil(indexing.shownRun?.refinement)
        indexing.setRefinesAfterIndexing(true)
        XCTAssertEqual(indexing.shownRun?.id, shown.id)

        // A Refine edit stales the refinement, never the Dictionary run: Index refines alone (at the bundle's 1°, the fewest evaluations).
        indexing.editRefineSettings { $0.trustAngle = 1 }
        XCTAssertTrue(indexing.isRefinementStale)
        XCTAssertTrue(indexing.isStale)
        XCTAssertFalse(indexing.isStale(of: .dictionary))
        XCTAssertTrue(indexing.staleness(ofRun: shown.id, method: .dictionary)?.contains("Refine changed") == true)
        XCTAssertEqual(indexing.verbHelp, "Refine the orientations of the \(4125.formatted()) patterns indexed with Dictionary (ni)")
        let before = events.count
        let alone = Date()
        await indexing.index().value
        print("Refine alone (Orientation ±1°): \(String(format: "%.1f", Date().timeIntervalSince(alone))) s; \(events.last ?? "")")
        XCTAssertEqual(indexing.runs[.dictionary]?.id, dictionary.id, "refined alone")
        XCTAssertFalse(events[before...].contains { $0.hasPrefix("Indexed ") }, "\(events[before...])")
        XCTAssertTrue(events.last?.hasPrefix("Refined ") == true, "\(events)")
        XCTAssertNotEqual(indexing.refinedRun?.id, shown.id)
        XCTAssertFalse(indexing.isRefinementStale)
        XCTAssertNotNil(indexing.staleness(ofRun: shown.id, method: .dictionary), "the refinement in Maps was replaced")

        // Stop in the Refine stage keeps the Dictionary run as it was and shows it while nothing was refined.
        indexing.editRefineSettings { $0.target = .both }
        let stopped = indexing.index()
        XCTAssertTrue(indexing.isRefining)
        XCTAssertEqual(BusyOperation.indexingLine(indexing, dataset: try XCTUnwrap(indexing.patterns.dataset)), "Refine · Both · 0 of \(4125.formatted())")
        indexing.stop()
        await stopped.value
        XCTAssertFalse(indexing.isIndexing)
        XCTAssertFalse(indexing.isRefining)
        XCTAssertEqual(indexing.refinedRun?.wasStopped, true)
        XCTAssertEqual(indexing.refinedRun?.result.rowsDone, 0)
        XCTAssertEqual(indexing.runs[.dictionary]?.wasStopped, false)
        XCTAssertEqual(indexing.shownRun?.id, dictionary.id, "a refinement stopped before a block leaves the run as indexed on screen")
        XCTAssertTrue(events.last?.hasPrefix("Stopped refinement at row 0 of 55") == true, "\(events)")
        XCTAssertEqual(indexing.compareAbsence(.refined), "The refinement was stopped before a row landed")

        // One phase at a time.
        let al = try XCTUnwrap(IndexingPhase.presets.first { $0.name == "Al" })
        indexing.addPhase(al)
        XCTAssertTrue(indexing.refusal?.hasPrefix("Refine one phase at a time") == true, indexing.refusal ?? "")
        XCTAssertFalse(indexing.canIndex)
        indexing.setRefinesAfterIndexing(false)
        XCTAssertNil(indexing.refusal, indexing.refusal ?? "")

        // The Output words belong to the Dictionary run.
        XCTAssertTrue(IndexingInfoFormat.isLine("Refined 4125 of 4125 patterns (orientations) in 1.0 s", of: .dictionary))
        XCTAssertTrue(IndexingInfoFormat.isLine("Stopped refinement at row 3 of 55; the refined rows stay", of: .dictionary))
        XCTAssertFalse(IndexingInfoFormat.isLine("Refined 4125 of 4125 patterns (orientations) in 1.0 s", of: .hough))
        let n = { (v: Double) in UnitDisplay.number(v, digits: 3) }
        XCTAssertEqual(IndexingInfoFormat.refinementScores((before: 0.41234, after: 0.45321, metric: "NCC")), "NCC \(n(0.41234)) → \(n(0.45321))")
        XCTAssertEqual(IndexingInfoFormat.refinementScores((before: 0.91, after: 0.45321, metric: "NDP")), "NDP \(n(0.91)) → NCC \(n(0.45321))")
        print("testRefineThroughTheRoom: \(String(format: "%.1f", Date().timeIntervalSince(started))) s")
    }

    // MARK: - The inspector's wiring

    /// The Refine section sits under Dictionary, closed, its switch and settings the session's, each control identified.
    func testTheRefineSectionIsWired() throws {
        let inspector = squeezed(try source("macTEM/UI/IndexingRoomInspector.swift"))
        XCTAssertTrue(inspector.contains("case .dictionary: IndexingDictionarySection(session: session) IndexingRefineSection(session: session)"))
        XCTAssertTrue(inspector.contains("InspectorSection(\"Refine\", status: status, startsExpanded: false)"))
        XCTAssertTrue(inspector.contains("set: { session.setRefinesAfterIndexing($0) }"))
        XCTAssertTrue(inspector.contains("session.editRefineSettings { $0.target = target }"))
        XCTAssertTrue(inspector.contains("session.resetRefineSettings()"))
        for id in ["isOn", "target", "trustAngle", "trustPC", "solver", "score", "pc", "reset", "refusal"] {
            XCTAssertTrue(inspector.contains(".accessibilityIdentifier(\"indexing.refine.\(id)\")"), id)
        }
    }
}
