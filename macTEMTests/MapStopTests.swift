//
//  MapStopTests.swift
//  Stop (⌘.) ends the Maps room's Segment and the dictionary's orientation sampling where they are, not after their passes: the grain
//  analysis asks before each row of the boundaries and of KAM and before each grain of the flood fill and of the statistics, the
//  sampling before each slab of its grid. A stopped Segment stays busy until its pass has returned, so a second one never runs beside
//  it, and what the stopped pass made never lands. Red before: these passes took no `isCancelled` and ran to their end after Stop, and
//  Segment, stopped, could start again at once while the first pass still ran. Uncancelled, the numbers are the ones MapsAnalysisTests
//  holds to DefDAP.
//

import Foundation
import TEMCore
import TEMSession
import XCTest
@testable import macTEM

nonisolated final class MapStopTests: XCTestCase {

    private static let sdss = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures").appendingPathComponent("ebsd-sdss-ferrite-austenite.ang")
    private static let defdap = MapAnalysisSettings(boundaryDegrees: 10, minimumSize: 10, kamMaxDegrees: 5)

    private func minusOneForNaN(_ a: [Double]) -> [Double] { a.map { $0.isNaN ? -1 : $0 } }

    /// The grain analysis asked to stop throws `CancellationError`, before its first row or part way through; asked and never told to
    /// stop, it is the analysis it was. Red before: no `isCancelled` parameter.
    func testAStoppedSegmentationThrowsCancellation() throws {
        let map = try ANGReader.read(url: Self.sdss).map
        XCTAssertThrowsError(try MapAnalysis.run(map, settings: Self.defdap, isCancelled: { true })) {
            XCTAssertTrue($0 is CancellationError, "\($0)")
        }

        // Part way: the boundaries' first five rows are made, and the pass stops at the sixth.
        var asked = 0
        let stopsAtTheSixthRow = { () -> Bool in
            asked += 1
            return asked > 5
        }
        do {
            _ = try MapAnalysis.run(map, settings: Self.defdap, isCancelled: stopsAtTheSixthRow)
            XCTFail("a pass told to stop part way returns nothing")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertEqual(asked, 6, "nothing more is asked once the pass has stopped")

        let grainMap = try GrainMap(map: map)
        XCTAssertThrowsError(try KernelAverageMisorientation.map(grainMap, isCancelled: { true })) {
            XCTAssertTrue($0 is CancellationError, "\($0)")
        }
        XCTAssertThrowsError(try GrainAnalysis.run(grainMap, isCancelled: { true })) {
            XCTAssertTrue($0 is CancellationError, "\($0)")
        }

        var checks = 0
        let neverStops = { () -> Bool in
            checks += 1
            return false
        }
        let asking = try MapAnalysis.run(map, settings: Self.defdap, isCancelled: neverStops)
        let plain = try MapAnalysis.run(map, settings: Self.defdap)
        XCTAssertGreaterThan(checks, 2 * grainMap.rows, "asked through the boundaries and KAM")
        XCTAssertEqual(asking.grains.segmentation.grainMap, plain.grains.segmentation.grainMap)
        XCTAssertEqual(minusOneForNaN(asking.grains.kam), minusOneForNaN(plain.grains.kam))
        XCTAssertEqual(asking.table.map(\.points), plain.table.map(\.points))
        XCTAssertEqual(minusOneForNaN(asking.table.map(\.gosDegrees)), minusOneForNaN(plain.table.map(\.gosDegrees)))
    }

    /// The dictionary's sample asked to stop throws `CancellationError`, and a cancelled sampling task ends without a sample. Red
    /// before: no `isCancelled` parameter, and a cancelled 1° sample walked its whole grid and returned it.
    func testAStoppedSamplingThrowsCancellation() async throws {
        XCTAssertThrowsError(try OrientationSampling.fundamental(resolution: 10, pointGroup: PointGroup.oh, isCancelled: { true })) {
            XCTAssertTrue($0 is CancellationError, "\($0)")
        }
        let sampling = Task.detached { try await DictionaryIndexingPlan.sample(resolution: 1, pointGroup: PointGroup.oh) }
        sampling.cancel()
        do {
            let rotations = try await sampling.value
            XCTFail("a cancelled sampling returned \(rotations.count) orientations")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        let asking = try OrientationSampling.fundamental(resolution: 10, pointGroup: PointGroup.oh, isCancelled: { false })
        XCTAssertEqual(asking, try OrientationSampling.fundamental(resolution: 10, pointGroup: PointGroup.oh))
    }

    /// Segment, Stop, Segment: the second is refused while the first pass returns (Segment stays busy), a second Stop has nothing to
    /// stop, and the stopped pass's analysis never lands; once it has returned, Segment runs. Red before: Stop cleared `isSegmenting`
    /// at once and a second pass started beside the first.
    @MainActor func testAStoppedSegmentStaysBusyUntilItsPassReturns() async throws {
        let session = OrientationMapSession()
        await session.open(url: Self.sdss).value
        session.setAnalysisSettings(Self.defdap)
        var events: [String] = []
        session.onEvent = { events.append($0) }

        let first = session.segment()
        XCTAssertTrue(session.isSegmenting)
        session.stop()
        XCTAssertTrue(session.isSegmenting, "busy until the stopped pass has returned")
        XCTAssertFalse(session.canSegment)
        session.stop()
        XCTAssertEqual(events.filter { $0 == "Stopped segmenting" }.count, 1, "a second Stop has nothing to stop")
        let refused = session.segment()
        XCTAssertEqual(events.filter { $0 == "Segmenting grains…" }.count, 1, "no second pass starts")
        await first.value
        await refused.value
        XCTAssertFalse(session.isSegmenting)
        XCTAssertNil(session.analysis, "the stopped pass's analysis never lands")

        XCTAssertTrue(session.canSegment)
        await session.segment().value
        XCTAssertNotNil(session.analysis)
        XCTAssertFalse(session.isSegmenting)
    }
}
