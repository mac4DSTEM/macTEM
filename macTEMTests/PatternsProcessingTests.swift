//
//  PatternsProcessingTests.swift
//  The Patterns room's processing (P2-01, docs/sem/design/pattern-processing.md): `EBSDSession`'s pipeline, the Raw / Processed
//  display, the room's verb `Process` and the stage states, on the generated demo (no static background: the scan's mean stands
//  in) and on the shipped nickel scan (the north star: its pattern (0, 0) after Process is figure F2 within one grey level).
//  Red before the wiring: no `process()`; red when a change does not stale its stage, or the display ignores the pipeline.
//

import XCTest
import FormatoCore
import TEMCore
import TEMSession
@testable import macTEM

nonisolated final class PatternsProcessingTests: XCTestCase {

    @MainActor private func waitIdle(_ session: EBSDSession) async throws {
        for _ in 0..<6000 where session.isMapping || session.isComputingMean || session.isProcessing { try await Task.sleep(for: .milliseconds(5)) }
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
        for _ in 0..<2000 where session.patternIsProcessed { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(session.patternPresentation.canvas?.width, DemoDocuments.Truth.ebsdPatternSide)

        await session.process().value
        XCTAssertNil(session.firstStaleStage)
        XCTAssertEqual(session.processed?.dataset.patternRows, DemoDocuments.Truth.ebsdPatternSide / 2)
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
