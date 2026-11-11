//
//  PatternProcessAdmissionTests.swift
//  Process refuses a scan that would not fit in memory (`PatternPipeline.processAdmission`, TEMCore; `EBSDSession.process`): the
//  run's estimate (the per-pattern output, three times it for neighbour averaging, three float32 copies for NLPAR) beside the
//  processed scan already held may take half the Mac's memory. The admission is Process's alone, so the one-pattern preview and the
//  indexer's streamed patterns (`refusal(for:background:)`, `processingRefusal`) stay open for the same scan.
//  Red before the change: there is no admission, and Process starts on any scan.
//

import XCTest
import FormatoCore
import TEMCore
import TEMSession

nonisolated final class PatternProcessAdmissionTests: XCTestCase {
    private static let sixteenGB: UInt64 = 16 << 30

    /// A 500 x 500 scan of 120 x 120 uint8 patterns: 3.6 GB as stored.
    private func largeDataset() throws -> EBSDDataset {
        var dataset = try DemoDocuments.ebsd().dataset
        dataset.scanRows = 500
        dataset.scanColumns = 500
        dataset.patternRows = 120
        dataset.patternColumns = 120
        return dataset
    }

    func testNLPAROnALargeScanIsRefusedWhileThePreviewStaysOpen() throws {
        let large = try largeDataset()
        var nlpar = PatternPipeline.roomDefault
        nlpar.nlpar.isOn = true
        XCTAssertEqual(nlpar.estimatedProcessBytes(for: large), 43_200_000_000, "three float32 copies of the scan")
        let refusal = try XCTUnwrap(nlpar.processAdmission(for: large, heldBytes: 0, physicalMemory: Self.sixteenGB))
        XCTAssertEqual(refusal.stage, .nlpar)
        XCTAssertEqual(refusal.sentence,
                       "Process would hold about 40.2 GB in memory, more than half of this Mac's 16 GB. Bin the patterns or turn NLPAR off.")
        let background = try FormatoArray(dataType: .uint8, shape: [120, 120], bytes: Data(count: 120 * 120))
        XCTAssertNil(nlpar.refusal(for: large, background: background), "the preview and Indexing read this refusal; it stays nil")

        var binned = nlpar
        binned.binning = 4
        XCTAssertNil(binned.processAdmission(for: large, heldBytes: 0, physicalMemory: Self.sixteenGB), "binning by 4 brings it under")
    }

    func testThePerPatternStagesAndAveragingAreCountedWithWhatIsHeld() throws {
        let large = try largeDataset()
        let plain = PatternPipeline.roomDefault
        XCTAssertEqual(plain.estimatedProcessBytes(for: large), 3_600_000_000)
        XCTAssertNil(plain.processAdmission(for: large, heldBytes: 0, physicalMemory: Self.sixteenGB))
        let beside = try XCTUnwrap(plain.processAdmission(for: large, heldBytes: 5 << 30, physicalMemory: Self.sixteenGB),
                                   "the last processed scan stays held while the new one runs")
        XCTAssertEqual(beside.sentence, "Process would hold about 8.4 GB in memory, more than half of this Mac's 16 GB. Bin the patterns.")

        var averaging = plain
        averaging.averaging.isOn = true
        XCTAssertEqual(averaging.estimatedProcessBytes(for: large), 10_800_000_000)
        XCTAssertEqual(averaging.processAdmission(for: large, heldBytes: 0, physicalMemory: Self.sixteenGB)?.stage, .averaging)
        var normalised = plain
        normalised.intensity.mode = .normalize
        XCTAssertEqual(normalised.estimatedProcessBytes(for: large), 14_400_000_000, "Normalise holds float32")

        var nlpar = plain
        nlpar.nlpar.isOn = true
        XCTAssertNil(nlpar.processAdmission(for: try DemoDocuments.ebsd().dataset, heldBytes: 0, physicalMemory: Self.sixteenGB),
                     "the demo is admitted")
    }

    /// The session asks before it starts: refused, Process says why and holds nothing, while the preview's refusal stays nil; with the
    /// memory back, the same scan processes.
    @MainActor func testTheSessionRefusesProcessThatWouldNotFit() async throws {
        let session = EBSDSession()
        await session.bind(try DemoDocuments.ebsd()).value
        try await waitUntil("the demo scan's map and mean passes to end", seconds: 30) { !session.isMapping && !session.isComputingMean }
        session.physicalMemory = 1 << 20
        XCTAssertNil(session.processingRefusal, "the preview and Indexing stay open")
        let refusal = try XCTUnwrap(session.processAdmission)
        var events: [String] = []
        session.onEvent = { events.append($0) }
        await session.process().value
        XCTAssertNil(session.processed)
        XCTAssertFalse(session.isProcessing)
        XCTAssertEqual(events.last, "Process: " + refusal.sentence)

        session.physicalMemory = Self.sixteenGB
        XCTAssertNil(session.processAdmission)
        await session.process().value
        XCTAssertNotNil(session.processed)
    }
}
