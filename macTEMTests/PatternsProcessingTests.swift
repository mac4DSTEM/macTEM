//
//  PatternsProcessingTests.swift
//  The Patterns room's processing (P2-01, docs/sem/design/pattern-processing.md): `EBSDSession`'s pipeline, the Raw / Processed
//  display, the room's verb `Process` and the stage states, on the generated demo (no static background: the scan's mean stands
//  in) and on the shipped nickel scan (the north star: its pattern (0, 0) after Process is figure F2 within one grey level).
//  Red before the wiring: no `process()`; red when a change does not stale its stage, or the display ignores the pipeline, or a
//  stopped run lands over the run started after it.
//

import XCTest
import FormatoCore
import TEMCore
import TEMSession
@testable import macTEM

nonisolated final class PatternsProcessingTests: XCTestCase {

    @MainActor private func waitIdle(_ session: EBSDSession) async throws {
        try await waitUntil("the scan's passes to end", seconds: 30) { !session.isMapping && !session.isComputingMean && !session.isProcessing }
        XCTAssertFalse(session.isComputingMean || session.isProcessing)
    }

    @MainActor func testTheDemoWithoutABackgroundProcessesWithTheScansMean() async throws {
        let session = EBSDSession()
        await session.bind(try DemoDocuments.ebsd()).value
        XCTAssertEqual(session.pipeline.staticStage.source, .mean, "the generated demo carries no static background")
        XCTAssertEqual(session.patternDisplay, .raw)
        XCTAssertEqual(session.stageState(.staticBackground), .notRun)
        try await waitIdle(session)
        XCTAssertNotNil(session.scanMeanBackground)
        XCTAssertNil(session.processingRefusal)
        XCTAssertTrue(session.canProcess)
        await session.process().value
        let processed = try XCTUnwrap(session.processed)
        XCTAssertEqual(processed.dataset.patternCount, session.dataset?.patternCount)
        XCTAssertEqual(session.stageState(.staticBackground), .current)
        XCTAssertEqual(session.stageState(.dynamicBackground), .current)
        XCTAssertEqual(session.stageState(.intensity), .notRun, "intensity is off by default")
        XCTAssertEqual(session.patternDisplay, .processed, "Processed once a stage ran (design §2)")
        XCTAssertNil(session.firstStaleStage)
    }

    @MainActor func testAChangeStalesItsStageAndTheProcessedPatternFollowsIt() async throws {
        let session = EBSDSession()
        await session.bind(try DemoDocuments.ebsd()).value
        try await waitIdle(session)
        await session.process().value
        session.editPipeline { $0.dynamicStage.std = 12 }
        XCTAssertEqual(session.stageState(.staticBackground), .current)
        XCTAssertEqual(session.stageState(.dynamicBackground), .stale)
        XCTAssertEqual(session.stageState(.size), .stale, "a change stales every later stage")
        XCTAssertEqual(session.firstStaleStage, .dynamicBackground)

        // Binning shows at once on the processed pattern; Raw shows the file's pattern again.
        session.editPipeline { $0.binning = 2 }
        for _ in 0..<2000 where session.patternPresentation.canvas?.width != DemoDocuments.Truth.ebsdPatternSide / 2 {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(session.patternPresentation.canvas?.width, DemoDocuments.Truth.ebsdPatternSide / 2)
        XCTAssertTrue(session.patternIsProcessed)
        session.setPatternDisplay(.raw)
        try await waitUntil("the raw pattern to show", seconds: 10) { !session.patternIsProcessed }
        XCTAssertEqual(session.patternPresentation.canvas?.width, DemoDocuments.Truth.ebsdPatternSide)

        await session.process().value
        XCTAssertNil(session.firstStaleStage)
        XCTAssertEqual(session.processed?.dataset.patternRows, DemoDocuments.Truth.ebsdPatternSide / 2)
    }

    /// Stop then Process at once (a double click on the verb): the stopped run never lands and the new one does. Red while the runs
    /// shared one count: the stopped run landed as the new one with no result, and the new run's result was then thrown away.
    @MainActor func testStopThenProcessLandsTheNewRunNotTheStoppedOne() async throws {
        let session = EBSDSession()
        await session.bind(try DemoDocuments.ebsd()).value
        try await waitIdle(session)
        var events: [String] = []
        session.onEvent = { events.append($0) }
        session.process()
        session.stop()
        XCTAssertFalse(session.isProcessing)
        let second = session.process()
        XCTAssertTrue(session.isProcessing)
        await second.value
        XCTAssertFalse(session.isProcessing)
        XCTAssertNotNil(session.processed)
        XCTAssertEqual(session.processedWith, session.pipeline)
        XCTAssertEqual(events.filter { $0.hasPrefix("Processed ") }.count, 1, "\(events)")
    }

    @MainActor func testARefusedStageSaysWhyAndProcessDoesNotRun() async throws {
        let session = EBSDSession()
        await session.bind(try DemoDocuments.ebsd()).value
        try await waitIdle(session)
        session.editPipeline { $0.staticStage.source = .file }
        XCTAssertEqual(session.processingRefusal?.sentence, "The file carries no static background. Choose the scan's mean.")
        XCTAssertFalse(session.canProcess)
        var events: [String] = []
        session.onEvent = { events.append($0) }
        await session.process().value
        XCTAssertNil(session.processed)
        XCTAssertEqual(events.last, "Process: The file carries no static background. Choose the scan's mean.")
    }

    /// NLPAR in the room: Process runs it after the per-pattern stages, says its λ, and the processed pattern on screen is the scan's
    /// NLPAR result (it needs the neighbours, so the pane shows the run, not a one-pattern preview).
    @MainActor func testNLPARRunsWithProcessAndThePaneShowsItsResult() async throws {
        let session = EBSDSession()
        await session.bind(try DemoDocuments.ebsd()).value
        try await waitIdle(session)
        session.editPipeline { $0.nlpar.isOn = true }
        XCTAssertNil(session.processingRefusal)
        var events: [String] = []
        session.onEvent = { events.append($0) }
        await session.process().value
        let processed = try XCTUnwrap(session.processed)
        XCTAssertEqual(processed.dataset.dataType, .float32)
        XCTAssertEqual(session.stageState(.nlpar), .current)
        let lambda = try XCTUnwrap(session.nlparLambda)
        XCTAssertTrue(lambda > 0, "λ \(lambda)")
        XCTAssertTrue(events.last?.contains("NLPAR λ") ?? false, events.last ?? "")
        try await waitUntil("the processed pattern to show", seconds: 10) { session.patternIsProcessed }
        let canvas = try XCTUnwrap(session.patternPresentation.canvas)
        let pinned = session.pinned
        let expected = EBSDBrowsing.pixels(try processed.pattern(row: pinned.row, column: pinned.column))
        XCTAssertEqual(canvas.width, DemoDocuments.Truth.ebsdPatternSide)
        XCTAssertEqual(canvas.rawRange?.lowerBound, expected.min())
        XCTAssertEqual(canvas.rawRange?.upperBound, expected.max())
        session.editPipeline { $0.nlpar.searchRadius = 2 }
        XCTAssertEqual(session.stageState(.nlpar), .stale)
        XCTAssertEqual(session.stageState(.dynamicBackground), .current)
    }

    /// The pattern filters in the room (D-SEM-82): Equalise and the FFT filter preview on the pinned pattern at once; Average neighbours
    /// needs the scan, so Process runs it and the pane shows the run; a change to the FFT filter stales it and every later stage.
    @MainActor func testTheFilterStagesPreviewAndRunWithProcess() async throws {
        let session = EBSDSession()
        await session.bind(try DemoDocuments.ebsd()).value
        try await waitIdle(session)
        session.setPatternDisplay(.processed)
        session.editPipeline { $0.intensity.equalize = true; $0.fftFilter.isOn = true; $0.averaging.isOn = true }
        XCTAssertNil(session.processingRefusal)
        XCTAssertEqual(session.firstStaleStage, .staticBackground)
        await session.process().value
        let processed = try XCTUnwrap(session.processed)
        XCTAssertEqual(processed.dataset.dataType, session.dataset?.dataType)
        for stage in [PatternPipeline.Stage.intensity, .fftFilter, .averaging] { XCTAssertEqual(session.stageState(stage), .current, stage.title) }
        XCTAssertEqual(session.stageState(.size), .notRun)
        try await waitUntil("the processed pattern to show", seconds: 10) { session.patternIsProcessed }
        let canvas = try XCTUnwrap(session.patternPresentation.canvas)
        let expected = EBSDBrowsing.pixels(try processed.pattern(row: session.pinned.row, column: session.pinned.column))
        XCTAssertEqual(canvas.rawRange?.lowerBound, expected.min())
        XCTAssertEqual(canvas.rawRange?.upperBound, expected.max())

        session.editPipeline { $0.fftFilter.pass = .low }
        XCTAssertEqual(session.stageState(.intensity), .current)
        XCTAssertEqual(session.stageState(.fftFilter), .stale)
        XCTAssertEqual(session.stageState(.averaging), .stale)
        XCTAssertEqual(session.firstStaleStage, .fftFilter)
        session.editPipeline { $0.intensity.mode = .normalize }
        XCTAssertEqual(session.processingRefusal?.stage, .intensity)
    }

    @MainActor func testTheMethodJSONExportWritesTheStages() async throws {
        let session = EBSDSession()
        await session.bind(try DemoDocuments.ebsd()).value
        let state = PatternsRoomState()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("patterns-method-\(UUID().uuidString)")
        var reports: [String] = []
        state.export(.methodJSON, from: session, directory: dir) { reports.append($0) }
        XCTAssertEqual(reports, ["Exported Demo EBSD processing method.json"])
        let data = try Data(contentsOf: dir.appendingPathComponent("Demo EBSD processing method.json"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let steps = try XCTUnwrap(json["steps"] as? [[String: Any]])
        XCTAssertEqual(steps.first?["method"] as? String, "EBSD.remove_static_background")
    }

    /// North star F2 through the room: the shipped nickel scan, Process at the room's defaults, pattern (0, 0) of the processed set
    /// against kikuchipy's (Fixtures/sem/background, the background tests' reference) within one grey level on at most 1 % of its pixels.
    @MainActor func testFigureF2ThroughTheRoom() async throws {
        let url = try XCTUnwrap(DemoDocuments.Shipped.nickelEBSD.url, "DemoData/ is not in the bundle")
        let session = EBSDSession()
        await session.open(url: url).value
        XCTAssertEqual(session.pipeline, .roomDefault, "the file carries its static background")
        try await waitIdle(session)
        await session.process().value
        let processed = try XCTUnwrap(session.processed)
        let ours = PatternPipeline.unsigned(try processed.pattern(row: 0, column: 0), as: UInt8.self)
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/sem/background")
        let reference = try [UInt8](Data(contentsOf: folder.appendingPathComponent("p0_0_dynamic_frequency_subtract.u8")))
        XCTAssertEqual(ours.count, reference.count)
        let off = zip(ours, reference).filter { $0 != $1 }.count
        XCTAssertLessThanOrEqual(zip(ours, reference).map { abs(Int($0) - Int($1)) }.max() ?? 0, 1)
        XCTAssertLessThanOrEqual(Double(off), 0.01 * Double(reference.count), "\(off) pixels one grey level off")
    }
}
