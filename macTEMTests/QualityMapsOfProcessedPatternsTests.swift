//
//  QualityMapsOfProcessedPatternsTests.swift
//  macEM#192: the Patterns room's quality maps are made from the processed scan once a Process run has landed (its background
//  removed), and the map's title and the inspector note say which patterns they came from. Before a run they stay the patterns as
//  stored. Red before: the maps stayed the raw patterns' after a run, titled "(raw patterns)" for good.
//

import Foundation
import TEMCore
import TEMSession
import XCTest
@testable import macTEM

nonisolated final class QualityMapsOfProcessedPatternsTests: XCTestCase {

    @MainActor func testAProcessRunRemakesTheQualityMapsFromItsPatterns() async throws {
        let session = EBSDSession()
        await session.bind(try DemoDocuments.ebsd()).value
        try await waitUntil("the mean and map passes to end", seconds: 30) { !session.isComputingMean && !session.isMapping }
        session.showMap(.imageQuality)
        try await waitUntil("the raw quality pass to end", seconds: 30) { !session.isQualityMapping }
        let rawIQ = try XCTUnwrap(session.imageQualityMap)
        XCTAssertFalse(session.qualityOfProcessed)
        let raw = try await PatternQuality.maps(of: try XCTUnwrap(session.document).access)
        XCTAssertEqual(rawIQ, raw.imageQuality.map(Float.init), "before a run: the patterns as stored")

        XCTAssertTrue(session.canProcess)
        await session.process().value
        let processed = try XCTUnwrap(session.processed)
        try await waitUntil("the processed quality pass to end", seconds: 30) { !session.isQualityMapping && session.imageQualityMap != nil }
        XCTAssertTrue(session.qualityOfProcessed)
        let expected = try await PatternQuality.maps(of: processed)
        XCTAssertEqual(session.imageQualityMap, expected.imageQuality.map(Float.init))
        XCTAssertEqual(session.dotProductMap, expected.dotProduct.map(Float.init))
        XCTAssertNotEqual(session.imageQualityMap, rawIQ, "the background removal changes the image quality")
    }

    func testTheWordsNameThePatterns() {
        XCTAssertEqual(EBSDSession.qualitySourceWords(ofProcessed: false), "(raw patterns)")
        XCTAssertEqual(EBSDSession.qualitySourceWords(ofProcessed: true), "(processed patterns)")
        XCTAssertTrue(EBSDSession.qualityNote(ofProcessed: true).hasPrefix("Of the processed scan"))
        XCTAssertTrue(EBSDSession.qualityNote(ofProcessed: false).hasPrefix("Of the patterns as stored"))
    }
}
