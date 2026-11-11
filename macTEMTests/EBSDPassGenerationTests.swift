//
//  EBSDPassGenerationTests.swift
//  The Patterns room's passes land on their own terms (`EBSDSession`): a new virtual-image grid restarts only the virtual-image pass,
//  so the scan's mean, Process and the quality pass that were running when the grid changed still land. On the generated demo, which
//  carries no static background, so binding it starts the scan's mean.
//  Red while one count guarded every pass: the new grid dropped their landings, the mean never came, and Process and Indexing stayed
//  refused ("Computing the scan's mean pattern…") until the file was opened again.
//

import XCTest
import TEMCore
import TEMSession
@testable import macTEM

nonisolated final class EBSDPassGenerationTests: XCTestCase {

    /// A new grid before the scan's mean lands: the mean still lands and Process can run. The test does not suspend between the bind
    /// and the new grid, so the detached mean cannot land before the grid changes.
    @MainActor func testANewGridDuringTheMeanPassKeepsTheMean() async throws {
        let session = EBSDSession()
        let firstPattern = session.bind(try DemoDocuments.ebsd())
        XCTAssertTrue(session.isComputingMean, "the generated demo carries no static background")
        session.setVirtualGrid(VirtualBSEGrid(3))
        await firstPattern.value
        XCTAssertEqual(session.patternPosition, EBSDPosition.origin, "the first pattern still lands")
        try await waitUntil("the mean and map passes to end", seconds: 30) { !session.isComputingMean && !session.isMapping }
        XCTAssertFalse(session.isComputingMean)
        XCTAssertNotNil(session.scanMeanBackground)
        XCTAssertNil(session.processingRefusal)
        XCTAssertTrue(session.canProcess)
        XCTAssertEqual(session.virtualImages?.count, 10, "the virtual-image pass ran again on the 3 x 3 grid")
    }

    /// A new grid while Process runs: the run lands and the room is no longer busy.
    @MainActor func testANewGridDuringProcessKeepsTheRun() async throws {
        let session = EBSDSession()
        await session.bind(try DemoDocuments.ebsd()).value
        try await waitUntil("the mean and map passes to end", seconds: 30) { !session.isComputingMean && !session.isMapping }
        XCTAssertTrue(session.canProcess)
        let run = session.process()
        XCTAssertTrue(session.isProcessing)
        session.setVirtualGrid(VirtualBSEGrid(3))
        await run.value
        XCTAssertFalse(session.isProcessing)
        XCTAssertNotNil(session.processed)
        XCTAssertEqual(session.processedWith, session.pipeline)
    }

    /// A new grid while the quality pass runs: both quality maps land and the pass ends.
    @MainActor func testANewGridDuringTheQualityPassKeepsTheQualityMaps() async throws {
        let session = EBSDSession()
        await session.bind(try DemoDocuments.ebsd()).value
        session.showMap(.imageQuality)
        XCTAssertTrue(session.isQualityMapping)
        session.setVirtualGrid(VirtualBSEGrid(3))
        for _ in 0..<6000 where session.isQualityMapping { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(session.isQualityMapping)
        XCTAssertEqual(session.imageQualityMap?.count, DemoDocuments.Truth.ebsdScanRows * DemoDocuments.Truth.ebsdScanColumns)
        XCTAssertNotNil(session.dotProductMap)
    }
}
