//
//  IndexingDictionaryRoomTests.swift
//  Dictionary indexing in the Indexing room (P4-04 with #181, D-SEM-91, D-SEM-92): figure F9 through the room's own plan (the shipped
//  nickel scan's patterns as the Patterns room's default stages make them per pattern, the shipped Ni master pattern opened as the room
//  opens it, orix's 4° sampling of the file phase's point group, the detector built from the file's) held to the bundle
//  `m4/dictionary-indexing-nickel-ebsd-large` at the thresholds of `SEMDictionaryIndexingParityTests`; then the room's path at a coarse
//  10° (fast): Method · Dictionary, the dictionary's size and chunking, Stop, the run in chunks, the map and its layers, the status line,
//  the Results rows, the best match, the exports read back, staleness per method; the orientation similarity map against kikuchipy's
//  as blocks land; the refusals of the plan; the master pattern's loader. Several phases (#231, D-SEM-98): two phases through the room
//  (one dictionary each, merged as kikuchipy's `merge_crystal_maps`; held to kikuchipy in IndexingDictionaryPhasesTests), each phase's
//  master pattern.
//  Red before the wiring: no `DictionaryIndexingPlan`, no Method; red under a detector with the file's 4125 centres (the projection
//  refuses them) or the unbinned shape, a sampling of the wrong point group, the master pattern in the stereographic projection, a Stop
//  that keeps landing blocks, a Hough edit that stales a dictionary result.
//

import XCTest
import FormatoCore
import TEMCore
import TEMSession
@testable import macTEM

nonisolated final class IndexingDictionaryRoomTests: XCTestCase {

    /// The shipped nickel scan, opened as the window opens it, with the Indexing room bound to it and the shipped master pattern open.
    @MainActor private func openNickel() async throws -> (patterns: EBSDSession, indexing: IndexingSession) {
        let url = try XCTUnwrap(DemoDocuments.Shipped.nickelEBSD.url, "DemoData/ is not in the bundle")
        let patterns = EBSDSession()
        let indexing = IndexingSession(patterns: patterns)
        patterns.onBind = { indexing.bind($0) }
        patterns.onClose = { indexing.close() }
        await patterns.open(url: url).value
        try await waitUntil("the nickel scan's passes to end", seconds: 30) {
            !patterns.isMapping && !patterns.isComputingMean && !patterns.isProcessing
        }
        let master = try XCTUnwrap(DemoDocuments.Shipped.nickelMasterPattern.url, "DemoData/ holds no master pattern")
        await indexing.openMasterPattern(url: master).value
        return (patterns, indexing)
    }

    // MARK: - Figure F9 through the room's plan

    /// F9 as the room builds it: the patterns from the room's source (the default stages per pattern, the chain F9 runs), the master
    /// pattern from the room's loader, the orientations from the room's sampling of the file phase, the detector from the file's
    /// (pattern shape, binning, tilts; its one centre set to F9's fixed PC, which F15's detector takes, as the file's mean is 0.002 off);
    /// against kikuchipy: the best match equal at 99.5 % of the points or more, the best scores within rtol 1e-2 (D-SEM-73).
    @MainActor func testFigureF9ThroughTheRoomsPlan() async throws {
        let (patterns, indexing) = try await openNickel()
        let master = try XCTUnwrap(indexing.master(for: try XCTUnwrap(indexing.phases.first)))
        XCTAssertEqual(master.summary, "ni · 20 kV · Lambert · 401 × 401")
        XCTAssertEqual(master.master.projection, .lambert)
        XCTAssertEqual(master.master.hemisphereCount, 2)
        guard case .success(let source) = indexing.source() else { return XCTFail("the default stages are readable per pattern") }
        XCTAssertEqual(source.kind, .perPattern)
        let dataset = try XCTUnwrap(patterns.dataset)
        XCTAssertEqual(dataset.detector.projectionCenters.count, 4125, "the file's per-point centres")
        var fileDetector = dataset.detector
        fileDetector.projectionCenters = [SIMD3(0.4214, 0.2142, 0.5013)]
        let ni = try XCTUnwrap(indexing.phases.first)
        let group = try XCTUnwrap(DictionaryIndexingPlan.pointGroup(of: ni))
        let rotations = try await DictionaryIndexingPlan.sample(resolution: DictionaryIndexingSettings.roomDefault.resolution, pointGroup: group)
        XCTAssertEqual(rotations.count, 11_935, "orix's m-3m sample at 4°")
        let plan = try DictionaryIndexingPlan(source: source, phase: ni, master: master, settings: .roomDefault,
                                              fileDetector: fileDetector, beamEnergy: dataset.sem.beamEnergyKeV, rotations: rotations)
        XCTAssertEqual(plan.blocks, [0..<55], "the demo scan is one block")
        XCTAssertEqual([plan.detector.rows, plan.detector.columns, plan.detector.binning], [60, 60, 8])
        XCTAssertEqual(plan.detector.sampleTilt, 70)
        XCTAssertEqual(plan.detector.tilt, 0)
        XCTAssertEqual(plan.detector.projectionCenters, [SIMD3(0.4214, 0.2142, 0.5013)])
        XCTAssertNil(plan.energy, "one energy in the master pattern: kikuchipy's default")
        XCTAssertEqual(plan.options.keepN, 5)
        XCTAssertEqual(plan.options.metric, .ncc)
        XCTAssertNil(plan.options.signalMask)
        XCTAssertEqual(plan.options.backend, DictionaryIndexingPlan.backend(points: 4125, dictionary: 11_935, keptPixels: 3600),
                       "one backend for the run, from the whole scan's work")
        let start = Date()
        let r = try await plan.indexBlock(0..<55)
        print("F9 through the room's plan: \(String(format: "%.1f", Date().timeIntervalSince(start))) s")
        let ref = try SEMParityReference.load("m4/dictionary-indexing-nickel-ebsd-large")
        let refIndices = try ref.array("ncc_simulation_indices").values, refScores = try ref.array("ncc_scores")
        let best = r.bestSimulationIndices
        let same = (0..<best.count).filter { best[$0] == Int(refIndices[$0 * 5]) }.count
        print("F9 through the room's plan: best match equal to kikuchipy's at \(same) of \(best.count) points")
        XCTAssertGreaterThanOrEqual(Double(same) / Double(best.count), 0.995)
        let refBest = stride(from: 0, to: refScores.values.count, by: 5).map { refScores.values[$0] }
        if let m = SEMParityCompare.mismatch(name: "F9 best scores through the room", actual: r.bestScores, expected: refBest, rtol: refScores.rtol, atol: 0) {
            XCTFail(m.description)
        }
    }

    // MARK: - The room's path

    /// Method · Dictionary on the demo scan at 10° (the room's whole path, fast): the size counted, Stop before a block lands keeps
    /// nothing, the run in chunks fills the map, the layers are the dictionary's, the status line and the rows carry the score, the best
    /// match is the simulated pattern of the point's orientation, the exports read back, a Hough edit leaves the result current.
    @MainActor func testDictionaryThroughTheRoom() async throws {
        let (patterns, indexing) = try await openNickel()
        XCTAssertEqual(indexing.method, .hough)
        indexing.setMethod(.dictionary)
        XCTAssertNil(indexing.refusal)
        XCTAssertTrue(indexing.canIndex)
        XCTAssertTrue(indexing.verbHelp.hasSuffix("patterns with Dictionary (ni)"), indexing.verbHelp)
        XCTAssertEqual(indexing.availableLayers, [.ipfZ, .ipfX, .ipfY, .euler, .phase, .score, .osm])

        indexing.editDictionarySettings { $0.resolution = 10 }
        for _ in 0..<4000 where indexing.dictionarySize == nil { try await Task.sleep(for: .milliseconds(5)) }
        let group = try XCTUnwrap(PointGroup.named("m-3m"))
        let expected = try await DictionaryIndexingPlan.sample(resolution: 10, pointGroup: group).count
        XCTAssertEqual(indexing.dictionarySize, expected)
        let cut = try XCTUnwrap(indexing.dictionaryChunking)
        XCTAssertEqual(cut.blocks, 1)
        XCTAssertEqual(cut.size, min(expected, (256 << 20) / ((3600 + 4125) * 8)))

        // Stop before the block lands keeps nothing and lands nothing after it.
        let stopped = indexing.index()
        XCTAssertTrue(indexing.isIndexing)
        XCTAssertEqual(indexing.result?.method, .dictionary)
        indexing.stop()
        await stopped.value
        XCTAssertFalse(indexing.isIndexing)
        XCTAssertTrue(indexing.wasStopped)
        XCTAssertEqual(indexing.result?.rowsDone, 0)
        XCTAssertNil(try indexing.crystalMap())

        var events: [String] = []
        indexing.onEvent = { events.append($0) }
        await indexing.index().value
        let result = try XCTUnwrap(indexing.result)
        XCTAssertEqual(result.method, .dictionary)
        XCTAssertTrue(result.isComplete)
        XCTAssertFalse(indexing.wasStopped)
        XCTAssertEqual(indexing.progress, 1)
        XCTAssertGreaterThan(indexing.chunksTotal, 0)
        XCTAssertEqual(indexing.chunksDone, indexing.chunksTotal)
        XCTAssertTrue(events.last?.hasPrefix("Indexed 4125 of 4125 patterns with Dictionary") == true, "\(events)")
        let dictionary = try XCTUnwrap(result.dictionary)
        XCTAssertEqual(dictionary.navigationShape, [55, 75])
        XCTAssertEqual(dictionary.keepN, 5)
        XCTAssertEqual(indexing.dictionaryPlans.map(\.rotations.count), [expected])
        let solutions = result.solutions.compactMap { $0 }
        XCTAssertEqual(solutions.count, 4125)
        XCTAssertEqual(solutions.map(\.quaternion), dictionary.bestRotations)
        XCTAssertEqual(solutions.map(\.confidence), dictionary.bestScores, "every demo pattern has contrast: each point carries its best score")

        // Each point's rotation is the dictionary's at its best simulation index. (A 10° dictionary is too coarse for these 60 × 60
        // patterns to land near F9's 4° best: kikuchipy 0.13.1 itself, at 10° on this scan and chain, sits a median 45.2° from
        // F9's best, measured 2026-11-07; F9's numbers are held at 4° by `testFigureF9ThroughTheRoomsPlan`.)
        let sampled = try XCTUnwrap(indexing.dictionaryPlans.first?.rotations)
        XCTAssertEqual(dictionary.bestSimulationIndices.map { sampled[$0] }, solutions.map(\.quaternion))

        // The map: IPF-Z of the best rotation; the score layer; Hough's layers are not offered.
        let rgba = try XCTUnwrap(indexing.mapRGBA)
        let colour = IPFColorKeyTSL(PointGroup.oh, direction: SIMD3(0, 0, 1)).color(of: [solutions[100].quaternion])[0]
        for c in 0..<3 { XCTAssertEqual(Double(rgba[100 * 4 + c]), (colour[c] * 255).rounded(), accuracy: 1, "channel \(c)") }
        indexing.setLayer(.fit)
        XCTAssertEqual(indexing.layer, .ipfZ, "a dictionary result has no fit")
        indexing.setLayer(.score)
        XCTAssertEqual(indexing.layer, .score)
        let range = try XCTUnwrap(indexing.mapPresentation.canvas?.rawRange, "the score layer is drawn through the Map Display")
        let lowest = try XCTUnwrap(dictionary.bestScores.min()), highest = try XCTUnwrap(dictionary.bestScores.max())
        XCTAssertEqual(range.lowerBound, Float(lowest))
        XCTAssertEqual(range.upperBound, Float(highest))

        // The orientation similarity map: kikuchipy's of the run's matches (every kept match, the four nearest neighbours), as a layer.
        let osm = try dictionary.orientationSimilarityMap().maps[0]
        XCTAssertEqual(result.similarity, osm)
        indexing.setLayer(.osm)
        XCTAssertEqual(indexing.layer, .osm)
        let osmRange = try XCTUnwrap(indexing.mapPresentation.canvas?.rawRange)
        let osmLowest = try XCTUnwrap(osm.min()), osmHighest = try XCTUnwrap(osm.max())
        XCTAssertEqual(osmRange, osmLowest...osmHighest)

        // The status line, the rows and the CSV carry the score and the simulation index.
        let position = EBSDPosition(row: 10, column: 20)
        let line = try XCTUnwrap(indexing.readout(at: position))
        XCTAssertTrue(line.hasPrefix("row 10 · col 20 · ni · φ₁"), line)
        XCTAssertTrue(line.contains("NCC"), line)
        XCTAssertTrue(line.contains("OSM"), line)
        let i = position.index(columns: 75)
        let row = try XCTUnwrap(result.rows.first { $0.id == i })
        XCTAssertEqual(row.confidence, dictionary.bestScores[i])
        XCTAssertEqual(row.simulationIndex, dictionary.simulationIndices[i * 5])
        XCTAssertTrue(row.fit.isNaN)
        XCTAssertEqual(row.similarity, Double(osm[i]))
        let csv = result.csv(stepX: 1.5, stepY: 1.5).split(separator: "\n")
        XCTAssertEqual(csv.first, "row,column,x,y,phase,phi1_deg,Phi_deg,phi2_deg,ncc,simulation_index,osm")
        XCTAssertEqual(csv.count, 4126)

        // The best match: the pinned point's best orientation simulated on the run's detector.
        indexing.pin(position)
        for _ in 0..<4000 where indexing.bestMatchPosition != position { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(indexing.bestMatchPosition, position)
        let canvas = try XCTUnwrap(indexing.bestMatchPresentation.canvas)
        XCTAssertEqual([canvas.width, canvas.height], [60, 60])
        XCTAssertTrue(indexing.detectedBands.allSatisfy { !$0.isMatched }, "a dictionary run matches no band")

        // The exports: the crystal map as kikuchipy builds it, the .ang's CI the best score, the method record in kikuchipy's names.
        let state = IndexingRoomState()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("IndexingDictionaryRoomTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        var reports: [String] = []
        for kind in IndexingExportKind.allCases { state.export(kind, from: indexing, directory: directory) { reports.append($0) } }
        XCTAssertEqual(reports, ["Exported patterns_v2 indexed OSM.png", "Exported patterns_v2 indexing results.csv",
                                 "Exported patterns_v2 indexed.ang", "Exported patterns_v2 indexed.ctf", "Exported patterns_v2 indexing method.json"])
        let xmap = try XCTUnwrap(try indexing.crystalMap())
        XCTAssertEqual(xmap.pointCount, 4125)
        XCTAssertEqual(xmap.property("scores"), dictionary.bestScores)
        XCTAssertEqual(xmap.property("simulation_indices"), dictionary.bestSimulationIndices.map(Double.init))
        XCTAssertEqual(xmap.phases[id: 0]?.color, indexing.phases[0].color)
        let ang = try ANGReader.read(url: directory.appendingPathComponent("patterns_v2 indexed.ang")).map
        XCTAssertEqual(ang.shape, [55, 75])
        let ci = try XCTUnwrap(ang.property("ci"))
        for (k, score) in dictionary.bestScores.enumerated() { XCTAssertEqual(ci[k], score, accuracy: 1e-5) }
        var worst = 0.0
        for (k, q) in ang.rotationsInData.enumerated() { worst = max(worst, Rotation(q).angle(with: Rotation(xmap.rotations[k]))) }
        XCTAssertLessThan(worst, 2.0e-5, "largest rotation difference \(worst) rad")
        let method = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("patterns_v2 indexing method.json"))) as? [String: Any]
        XCTAssertEqual(method?["dictionarySize"] as? Int, expected)
        XCTAssertEqual(method?["metric"] as? String, "ncc")
        XCTAssertEqual(method?["keepN"] as? Int, 5)
        XCTAssertEqual(method?["samplingResolutionDegrees"] as? Double, 10)
        XCTAssertEqual(method?["azimuthal"] as? Double, indexing.dictionaryPlans.first?.detector.azimuthal)
        XCTAssertEqual(method?["twist"] as? Double, indexing.dictionaryPlans.first?.detector.twist)

        // Staleness per method: a Hough edit leaves the dictionary result current, a dictionary edit stales it; picking Hough does not.
        indexing.editSettings { $0.bands = 9 }
        XCTAssertFalse(indexing.isStale)
        indexing.setReflectors(.bcc, named: "ni")
        XCTAssertFalse(indexing.isStale, "the reflector list is Hough's: it leaves a dictionary result current")
        indexing.setReflectors(.fcc, named: "ni")
        indexing.editDictionarySettings { $0.keep = 3 }
        XCTAssertTrue(indexing.isStale)
        XCTAssertTrue(indexing.verbHelp.hasSuffix("the inputs changed since the last run"), indexing.verbHelp)
        indexing.editDictionarySettings { $0.keep = 5 }
        XCTAssertFalse(indexing.isStale)
        indexing.setMethod(.hough)
        XCTAssertFalse(indexing.isStale)
        XCTAssertEqual(indexing.availableLayers, [.ipfZ, .ipfX, .ipfY, .euler, .phase, .score, .osm], "the result on screen keeps its layers")

        patterns.close()
        XCTAssertNil(indexing.result)
        XCTAssertTrue(indexing.dictionaryPlans.isEmpty)
        XCTAssertEqual(indexing.method, .hough)
        XCTAssertEqual(indexing.masterPatterns.map(\.fileName), ["ni_mc_mp_20kv_uint8_gzip_opts9.h5"],
                       "a master pattern is not the dataset's: it stays open")
        XCTAssertTrue(indexing.masterPicks.isEmpty, "the picks are the dataset's phases'")
    }

    // MARK: - Several phases

    /// Two phases on (#231, D-SEM-98): ni and the Al preset, which takes the shipped Ni master pattern (the only one open, of its space
    /// group), so the two dictionaries are the same patterns and every point ties. One dictionary per phase (m-3m sampled once), Stop
    /// before a block keeps nothing; the first phase takes each point, as kikuchipy's `np.nanargmax` does, with the one-phase run's
    /// matches; the OSM counts each shared match in both dictionaries, twice the one-phase map; the crystal map lists the phase that
    /// won points only, as `merge_crystal_maps` does; the method record lists both dictionaries; with Al first, Al takes every point.
    /// Red when a second phase is refused, when a tie takes the last phase, when the OSM's indices of the two phases collide.
    @MainActor func testTwoPhasesThroughTheRoom() async throws {
        let (_, indexing) = try await openNickel()
        indexing.setMethod(.dictionary)
        indexing.editDictionarySettings { $0.resolution = 10 }
        for _ in 0..<4000 where indexing.dictionarySize == nil { try await Task.sleep(for: .milliseconds(5)) }
        let single = try XCTUnwrap(indexing.dictionarySize)
        let singleChunks = try XCTUnwrap(indexing.dictionaryChunking).chunks
        await indexing.index().value
        let one = try XCTUnwrap(indexing.result)
        let d1 = try XCTUnwrap(one.dictionary)
        let backend = try XCTUnwrap(indexing.dictionaryPlans.first?.options.backend)

        let al = try XCTUnwrap(IndexingPhase.presets.first { $0.name == "Al" })
        indexing.addPhase(al)
        XCTAssertEqual(indexing.phasesOn.map(\.name), ["ni", "Al"])
        XCTAssertEqual(indexing.master(for: indexing.phases[1])?.fileName, "ni_mc_mp_20kv_uint8_gzip_opts9.h5",
                       "the latest master pattern opened of the phase's space group")
        XCTAssertNil(indexing.refusal, indexing.refusal ?? "")
        XCTAssertTrue(indexing.verbHelp.contains("patterns with Dictionary (ni, Al)"), indexing.verbHelp)
        for _ in 0..<4000 where indexing.dictionarySize == nil { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(indexing.dictionarySize, 2 * single, "one dictionary per phase")
        XCTAssertEqual(indexing.dictionaryChunking?.chunks, 2 * singleChunks)

        let stopped = indexing.index()
        indexing.stop()
        await stopped.value
        XCTAssertEqual(indexing.result?.rowsDone, 0)
        XCTAssertNil(try indexing.crystalMap())

        var events: [String] = []
        indexing.onEvent = { events.append($0) }
        await indexing.index().value
        let two = try XCTUnwrap(indexing.result)
        XCTAssertTrue(two.isComplete)
        XCTAssertEqual(two.phases.map(\.name), ["ni", "Al"])
        XCTAssertEqual(indexing.chunksDone, indexing.chunksTotal)
        XCTAssertNil(indexing.chunkPhase)
        XCTAssertEqual(indexing.dictionaryPlans.map(\.phase.name), ["ni", "Al"])
        XCTAssertEqual(indexing.dictionaryPlans.map(\.options.backend), [backend, backend], "one backend for every phase's dictionary")
        XCTAssertTrue(events.first?.hasPrefix("Indexing 4125 patterns against 2 dictionaries (ni, Al) at 10° (NCC)") == true, "\(events)")
        XCTAssertTrue(events.last?.hasPrefix("Indexed 4125 of 4125 patterns with Dictionary") == true, "\(events)")
        XCTAssertTrue(events.last?.hasSuffix(" s (ni 4125 · Al 0)") == true, "\(events)")

        // Tied at every point: the first phase, with the one-phase run's matches; each phase's own indices feed the OSM.
        XCTAssertEqual(two.countsByPhase, [4125, 0])
        let d2 = try XCTUnwrap(two.dictionary)
        XCTAssertEqual(d2.scores, d1.scores)
        XCTAssertEqual(d2.simulationIndices, d1.simulationIndices)
        XCTAssertEqual(d2.rotations, d1.rotations)
        XCTAssertEqual(two.solutions.compactMap { $0 }.map(\.confidence), d1.bestScores)
        XCTAssertEqual(two.phaseSimulationIndices, [d1.simulationIndices, d1.simulationIndices])
        XCTAssertEqual(two.similarity, one.similarity.map { 2 * $0 }, "each shared match counted in both dictionaries")

        // The layers, the status line, the best match read the merged map.
        indexing.setLayer(.score)
        let range = try XCTUnwrap(indexing.mapPresentation.canvas?.rawRange)
        XCTAssertEqual(range, Float(try XCTUnwrap(d1.bestScores.min()))...Float(try XCTUnwrap(d1.bestScores.max())))
        let position = EBSDPosition(row: 10, column: 20)
        let line = try XCTUnwrap(indexing.readout(at: position))
        XCTAssertTrue(line.hasPrefix("row 10 · col 20 · ni · φ₁"), line)
        indexing.pin(position)
        for _ in 0..<4000 where indexing.bestMatchPosition != position { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(indexing.bestMatchPosition, position)
        XCTAssertEqual(indexing.bestMatchPresentation.canvas.map { [$0.width, $0.height] }, [60, 60])

        // The exports: kikuchipy's merged map (Al wins no point, so it is not listed) and both dictionaries in the method record.
        let xmap = try XCTUnwrap(try indexing.crystalMap())
        XCTAssertEqual(xmap.phases.names, ["ni"])
        XCTAssertEqual(xmap.property("scores"), d1.bestScores)
        XCTAssertEqual(xmap.property("simulation_indices"), d1.bestSimulationIndices.map(Double.init))
        let record = try XCTUnwrap(try JSONSerialization.jsonObject(with: try XCTUnwrap(try indexing.methodJSON())) as? [String: Any])
        let listed = try XCTUnwrap(record["phases"] as? [[String: Any]])
        XCTAssertEqual(listed.map { $0["dictionarySize"] as? Int }, [single, single])
        XCTAssertEqual(listed.map { $0["indexed"] as? Int }, [4125, 0])
        XCTAssertNotNil(record["merge"] as? String)
        XCTAssertNotNil(record["orientationSimilarityMap"] as? String)
        XCTAssertEqual(record["indexed"] as? Int, 4125)

        // The first phase in the list takes a tie: with Al first, Al takes every point.
        let ni = indexing.phases[0]
        indexing.removePhase(named: "ni")
        indexing.addPhase(ni)
        XCTAssertEqual(indexing.phasesOn.map(\.name), ["Al", "ni"])
        await indexing.index().value
        XCTAssertEqual(indexing.result?.countsByPhase, [4125, 0])
        XCTAssertEqual(indexing.result?.dictionary?.simulationIndices, d1.simulationIndices)
        XCTAssertTrue(try XCTUnwrap(indexing.readout(at: position)).hasPrefix("row 10 · col 20 · Al · φ₁"))
    }

    /// Each phase on takes a master pattern (D-SEM-98): the one picked for it, else the latest opened with its space group and name,
    /// else the latest of its space group, else the latest opened (refused with both space groups named). A pick stales the run, a
    /// removed phase loses its pick, a newly opened file says which phases take it. Red when every phase takes one master pattern.
    @MainActor func testEachPhaseTakesAMasterPattern() async throws {
        let (_, indexing) = try await openNickel()
        indexing.setMethod(.dictionary)
        let ni = try XCTUnwrap(indexing.phases.first)
        let shipped = try XCTUnwrap(indexing.master(for: ni))
        let dummyURL = try XCTUnwrap(try SEMParityReference.load("m6/read-master-pattern-dummy").inputURL())
        var events: [String] = []
        indexing.onEvent = { events.append($0) }
        await indexing.openMasterPattern(url: dummyURL).value
        XCTAssertEqual(indexing.masterPatterns.count, 2)
        let dummy = try XCTUnwrap(indexing.masterPatterns.first { $0.id != shipped.id })
        XCTAssertEqual(dummy.master.phase.spaceGroup, 140)
        XCTAssertTrue(events.last?.hasPrefix("Opened the master pattern \(dummy.fileName)") == true, "\(events)")
        XCTAssertTrue(events.last?.hasSuffix("no phase on takes it: pick it for a phase under Dictionary") == true, "\(events)")
        XCTAssertEqual(indexing.master(for: ni)?.id, shipped.id, "ni keeps the master pattern of its space group and name")
        XCTAssertNil(indexing.refusal)

        // A phase of another space group takes the latest opened, and is refused with both space groups named.
        let fe = try XCTUnwrap(IndexingPhase.presets.first { $0.name == "Fe (α)" })
        indexing.addPhase(fe)
        let iron = try XCTUnwrap(indexing.phases.first { $0.name == "Fe (α)" })
        XCTAssertEqual(indexing.master(for: iron)?.id, dummy.id)
        XCTAssertEqual(indexing.refusal, "The master pattern is for \(dummy.master.phase.name) (space group 140), the phase is Fe (α) (space group 229).")

        // A pick is the phase's; it stales the run it changes.
        indexing.setPhase(named: "Fe (α)", isOn: false)
        XCTAssertNil(indexing.refusal)
        let before = indexing.currentInputs
        indexing.selectMasterPattern(dummy.id, forPhase: "ni")
        XCTAssertEqual(indexing.masterPicks, ["ni": dummy.id])
        XCTAssertEqual(indexing.master(for: ni)?.id, dummy.id)
        XCTAssertNotEqual(indexing.currentInputs, before, "the master pattern is part of the run's inputs")
        XCTAssertEqual(indexing.refusal, "The master pattern is for \(dummy.master.phase.name) (space group 140), the phase is ni (space group 225).")
        indexing.selectMasterPattern(shipped.id, forPhase: "ni")
        XCTAssertEqual(indexing.currentInputs, before)
        XCTAssertNil(indexing.refusal)
        indexing.selectMasterPattern("not open", forPhase: "ni")
        XCTAssertEqual(indexing.masterPicks["ni"], shipped.id, "a file that is not open is not picked")

        // Reopening a file names the phases that take it; a removed phase loses its pick.
        indexing.selectMasterPattern(dummy.id, forPhase: "Fe (α)")
        indexing.setPhase(named: "Fe (α)", isOn: true)
        await indexing.openMasterPattern(url: dummyURL).value
        XCTAssertEqual(events.last, "\(dummy.fileName) is already open; Fe (α) takes it", "\(events)")
        indexing.removePhase(named: "Fe (α)")
        XCTAssertNil(indexing.masterPicks["Fe (α)"])
        XCTAssertEqual(indexing.masterPicks["ni"], shipped.id)
    }

    // MARK: - The orientation similarity map as blocks land

    /// The room's OSM layer is kikuchipy's `orientation_similarity_map` (its defaults) of the rows landed: F9's matches landed in uneven
    /// blocks give `m4/orientation-similarity-map`'s F9 map exactly; a run stopped after 20 rows has kikuchipy's map of those 20 rows; a
    /// point not indexed shows none, while its matches still count for its neighbours, as in kikuchipy. Red when the row above a block
    /// keeps its border value, or when a block's first row is computed without the row above it.
    func testTheRoomsSimilarityMapIsKikuchipysAsBlocksLand() throws {
        let f9 = try SEMParityReference.load("m4/dictionary-indexing-nickel-ebsd-large")
        let indices = try f9.array("ncc_simulation_indices").values.map { Int($0) }
        let scores = try f9.array("ncc_scores").values
        let nickel = try XCTUnwrap(IndexingPhase.presets.first { $0.name == "Ni" })
        func block(_ rows: Range<Int>) -> DictionaryIndexing.Result {
            let a = rows.lowerBound * 75 * 5, b = rows.upperBound * 75 * 5
            return DictionaryIndexing.Result(navigationShape: [rows.count, 75], keepN: 5, isInData: Array(repeating: true, count: rows.count * 75),
                                             scores: Array(scores[a..<b]), simulationIndices: Array(indices[a..<b]),
                                             rotations: Array(repeating: SIMD4(1, 0, 0, 0), count: b - a))
        }

        var result = IndexingResult(scanRows: 55, scanColumns: 75, phases: [nickel], metric: .ncc)
        for rows in [0..<1, 1..<20] { result.land(block(rows), rows: rows) }
        let partial = try OrientationSimilarityMap.compute(simulationIndices: Array(indices[0..<(20 * 75 * 5)]), keepN: 5, rows: 20, columns: 75)
        XCTAssertEqual(Array(result.similarity[0..<(20 * 75)]), partial.maps[0], "stopped after 20 rows: kikuchipy's map of those rows")
        XCTAssertTrue(result.similarity[(20 * 75)...].allSatisfy(\.isNaN), "rows not landed have no OSM")
        XCTAssertNil(result.value(.osm, at: 20 * 75))

        for rows in [20..<21, 21..<55] { result.land(block(rows), rows: rows) }
        let ref = try SEMParityReference.load("m4/orientation-similarity-map")
        SEMAssertParity(result.similarity.map { $0.isNaN ? -1 : Double($0) }, try ref.array("f9_osm"))
        XCTAssertEqual(result.value(.osm, at: 0), Double(result.similarity[0]))
        XCTAssertEqual(result.rows[0].similarity, Double(result.similarity[0]))

        var unscored = block(0..<55)
        for k in 0..<5 { unscored.scores[k] = .nan }
        var masked = IndexingResult(scanRows: 55, scanColumns: 75, phases: [nickel], metric: .ncc)
        masked.land(unscored, rows: 0..<55)
        XCTAssertNil(masked.value(.osm, at: 0), "a point not indexed shows no OSM")
        XCTAssertTrue(masked.rows[0].similarity.isNaN)
        XCTAssertEqual(masked.similarity, result.similarity, "its matches still count for its neighbours")
    }

    // MARK: - Refusals

    /// The plan's refusals, in the room's words: a phase on, a master pattern of each phase's space group (D-SEM-98: every phase on
    /// is checked), settings in range, a centre, an energy the master pattern holds. Red under a master pattern of another phase
    /// accepted, a phase of another space group accepted beside one that fits.
    @MainActor func testTheDictionaryRefusesWhatItCannotIndex() async throws {
        let (_, indexing) = try await openNickel()
        indexing.setMethod(.dictionary)
        XCTAssertNil(indexing.dictionaryRefusal)
        let ni = try XCTUnwrap(indexing.phases.first)
        let master = try XCTUnwrap(indexing.master(for: ni))
        let detector = try XCTUnwrap(indexing.patterns.dataset?.detector)
        let fe = try XCTUnwrap(IndexingPhase.presets.first { $0.name == "Fe (α)" })
        XCTAssertEqual(DictionaryIndexingPlan.refusal(phases: [fe], master: master, settings: .roomDefault, detector: detector, beamEnergy: 20),
                       "The master pattern is for ni (space group 225), the phase is Fe (α) (space group 229).")
        var two = [ni, fe]
        two[1].isOn = true
        XCTAssertEqual(DictionaryIndexingPlan.refusal(phases: two, master: master, settings: .roomDefault, detector: detector, beamEnergy: 20),
                       "The master pattern is for ni (space group 225), the phase is Fe (α) (space group 229).")
        var al = try XCTUnwrap(IndexingPhase.presets.first { $0.name == "Al" })
        al.isOn = true
        XCTAssertNil(DictionaryIndexingPlan.refusal(phases: [ni, al], master: master, settings: .roomDefault, detector: detector, beamEnergy: 20),
                     "two phases of one space group share a master pattern")
        XCTAssertEqual(DictionaryIndexingPlan.refusal(phases: [ni, al], masters: [ni.id: master], settings: .roomDefault, detector: detector,
                                                      beamEnergy: 20),
                       "Open a master pattern for Al in Dictionary.")
        XCTAssertEqual(DictionaryIndexingPlan.refusal(phases: [ni], master: nil, settings: .roomDefault, detector: detector, beamEnergy: 20),
                       "Open a master pattern for ni in Dictionary.")
        var coarse = DictionaryIndexingSettings.roomDefault
        coarse.resolution = 20
        XCTAssertEqual(DictionaryIndexingPlan.refusal(phases: [ni], master: master, settings: coarse, detector: detector, beamEnergy: 20),
                       "The angular resolution runs from 1° to 15°.")
        var none = detector
        none.projectionCenters = []
        XCTAssertEqual(DictionaryIndexingPlan.refusal(phases: [ni], master: master, settings: .roomDefault, detector: none, beamEnergy: 20),
                       "The file states no projection centre, which dictionary indexing needs.")
        XCTAssertNil(DictionaryIndexingPlan.refusal(phases: [ni], master: master, settings: .roomDefault, detector: detector, beamEnergy: 15),
                     "one energy in the master pattern: the projection takes it whatever the beam")

        // A master pattern of several energies: the scan's beam energy picks one, and a beam energy of 0 (kikuchipy's h5ebsd writer
        // stores 0 when the signal has none) is none, so the highest is taken as kikuchipy does. Red when 0 kV is refused.
        var multi = master.master
        multi.energies = (10...20).map(Double.init)
        let unstated = try DictionaryIndexingPlan.energy(master: multi, beamEnergy: 0).get()
        XCTAssertNil(unstated.value)
        XCTAssertEqual(unstated.words, "20 kV, the highest; the scan states no beam energy")
        XCTAssertEqual(try DictionaryIndexingPlan.energy(master: multi, beamEnergy: 15).get().value, 15)
        if case .success = DictionaryIndexingPlan.energy(master: multi, beamEnergy: 30) { XCTFail("30 kV is outside 10 to 20 kV") }

        // One backend for a run: a 301 × 300 scan of 60 × 60 px patterns at about 800 orientations runs in blocks of 15 rows, and its
        // one-row last block alone would fall under the GPU's threshold; the run's choice holds for every block.
        XCTAssertEqual(DictionaryIndexingPlan.rowsPerBlock(scanRows: 301, scanColumns: 300, pixels: 3600), 15)
        XCTAssertEqual(DictionaryIndexingPlan.backend(points: 300, dictionary: 800, keptPixels: 3600), .cpu)
        XCTAssertEqual(DictionaryIndexingPlan.backend(points: 301 * 300, dictionary: 800, keptPixels: 3600),
                       DictionaryIndexingMetal.isAvailable ? .metal : .cpu)
        XCTAssertEqual(DictionaryIndexingPlan.detector(detector, rows: 30, columns: 30)?.binning, 16, "binning 2 folded in")
        XCTAssertEqual(DictionaryIndexingPlan.detector(detector, rows: 30, columns: 30)?.projectionCenters.count, 1)
        XCTAssertEqual(DictionaryIndexingPlan.detector(detector, rows: 30, columns: 30)?.rows, 30)

        // Fe (α) takes the latest master pattern opened, as none of its space group is open, and is refused beside ni.
        indexing.addPhase(fe)
        XCTAssertEqual(indexing.refusal, "The master pattern is for ni (space group 225), the phase is Fe (α) (space group 229).")
        XCTAssertFalse(indexing.canIndex)
        indexing.setPhase(named: "ni", isOn: false)
        XCTAssertEqual(indexing.refusal, "The master pattern is for ni (space group 225), the phase is Fe (α) (space group 229).")
        indexing.setMethod(.hough)
        XCTAssertNil(indexing.refusal, "Hough indexes against Fe (α) alone")

        // The circular signal mask leaves out the corners, as kikuchipy's negated circular window does.
        var masked = DictionaryIndexingSettings.roomDefault
        masked.signalMask = .circular
        let mask = try XCTUnwrap(try masked.signalMask(rows: 60, columns: 60))
        XCTAssertTrue(mask[0], "a corner is left out")
        XCTAssertFalse(mask[30 * 60 + 30], "the centre is compared")
        XCTAssertEqual(mask.filter { !$0 }.count, try PatternWindow.circular(rows: 60, columns: 60).values.filter { $0 != 0 }.count)
    }

    /// The loader refuses a file that is not a master pattern, with its name; the same file opened twice is one entry.
    @MainActor func testTheMasterPatternLoaderRefusesOtherFiles() async throws {
        let (_, indexing) = try await openNickel()
        XCTAssertEqual(indexing.masterPatterns.count, 1)
        let master = try XCTUnwrap(DemoDocuments.Shipped.nickelMasterPattern.url)
        await indexing.openMasterPattern(url: master).value
        XCTAssertEqual(indexing.masterPatterns.count, 1, "opened twice, listed once")
        let scan = try XCTUnwrap(DemoDocuments.Shipped.nickelEBSD.url)
        XCTAssertThrowsError(try IndexingMasterPattern.load(scan)) { error in
            XCTAssertEqual((error as? IndexingRefusal)?.sentence, "patterns_v2.h5 is not an EMsoft master pattern file.")
        }
        var failures = 0
        indexing.onFailure = { _ in failures += 1 }
        await indexing.openMasterPattern(url: scan).value
        XCTAssertEqual(failures, 1)
        XCTAssertEqual(indexing.masterPatterns.count, 1)
        XCTAssertEqual(indexing.master(for: try XCTUnwrap(indexing.phases.first))?.fileName, "ni_mc_mp_20kv_uint8_gzip_opts9.h5")
    }
}
