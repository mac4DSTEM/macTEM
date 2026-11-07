//
//  IndexingCompareTests.swift
//  The Indexing room keeps the last run of each method, and compares two results (#230, D-SEM-97), on the generated demo scan
//  (30 × 40, its own Ni crystal map on the grid) through the window's `AppState`: a Dictionary run leaves the Hough run, its exports,
//  its staleness and the Maps room's view of it as they were, and `Method` picks the run on screen; Compare's sources, its defaults,
//  why a side is empty (not run, running, stopped before a row), the comparison of a run with the file's indexing (every indexed
//  point compared, the rest left out), the swap, the layer, and the room's wiring. The numbers are held to orix in
//  SEMIndexingCompareParityTests and on the shipped scan in IndexingRoomTests (F8).
//  Red before: a Dictionary run dropped the Hough result and its libraries; no Compare.
//

import XCTest
import TEMCore
import TEMSession
@testable import macTEM

nonisolated final class IndexingCompareTests: XCTestCase {

    /// The repo's own source file at `path`, read beside this test file.
    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    private func squeezed(_ text: String) -> String { text.split(whereSeparator: \.isWhitespace).joined(separator: " ") }

    /// The generated demo opened as the window opens it.
    @MainActor private func openDemo() async throws -> AppState {
        let state = AppState(launch: LaunchOptions(arguments: []))
        await state.ebsd.bind(try DemoDocuments.ebsd()).value
        let ebsd = state.ebsd
        for _ in 0..<6000 where ebsd.isMapping || ebsd.isComputingMean || ebsd.isProcessing { try await Task.sleep(for: .milliseconds(5)) }
        return state
    }

    /// Method · Dictionary at a coarse 10°, once the shipped master pattern is open and the dictionary counted.
    @MainActor private func pickDictionary(_ indexing: IndexingSession) async throws {
        indexing.setMethod(.dictionary)
        indexing.editDictionarySettings { $0.resolution = 10 }
        for _ in 0..<6000 where indexing.currentMaster == nil || indexing.dictionarySize == nil { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertNil(indexing.refusal, indexing.refusal ?? "")
    }

    // MARK: - The last run of each method

    @MainActor func testTheRoomKeepsTheLastRunOfEachMethod() async throws {
        let state = try await openDemo()
        let indexing = state.indexing
        XCTAssertTrue(indexing.runs.isEmpty)
        await indexing.index().value
        let hough = try XCTUnwrap(indexing.runs[.hough])
        XCTAssertTrue(hough.result.isComplete)
        XCTAssertNotNil(hough.houghPlan)
        XCTAssertNil(indexing.otherRun)

        // Handed to Maps, the Hough run stays current through a run of the other method.
        await state.openIndexingInMaps()?.value
        XCTAssertEqual(state.maps.document?.source, .indexing(run: hough.id, method: .hough))
        XCTAssertNil(state.mapsStaleness)

        try await pickDictionary(indexing)
        XCTAssertEqual(indexing.result?.method, .hough, "before a Dictionary run the Hough run stays on screen")
        await indexing.index().value
        XCTAssertEqual(indexing.result?.method, .dictionary)
        XCTAssertTrue(indexing.result?.isComplete == true)
        let kept = try XCTUnwrap(indexing.runs[.hough], "a Dictionary run leaves the Hough run")
        XCTAssertEqual(kept.id, hough.id)
        XCTAssertEqual(kept.result.solutions, hough.result.solutions)
        XCTAssertNotNil(kept.houghPlan)
        XCTAssertEqual(indexing.otherRun?.method, .hough)
        XCTAssertNil(state.mapsStaleness, "the Hough run in Maps is still the room's Hough run")

        // Method picks the run on screen, its layers, its exports.
        indexing.setLayer(.score)
        indexing.setMethod(.hough)
        XCTAssertEqual(indexing.result?.method, .hough)
        XCTAssertEqual(indexing.availableLayers, IndexingLayer.layers(for: .hough))
        XCTAssertEqual(indexing.layer, .ipfZ, "Score is not a Hough layer")
        XCTAssertNotNil(try indexing.crystalMap())
        XCTAssertNotNil(try indexing.methodJSON())
        XCTAssertNil(indexing.dictionaryPlan, "the plan on screen is the Hough run's")
        XCTAssertEqual(indexing.otherRun?.method, .dictionary)
        indexing.setMethod(.dictionary)
        XCTAssertEqual(indexing.result?.method, .dictionary)
        XCTAssertNotNil(indexing.dictionaryPlan)

        // Staleness is each run's own.
        indexing.editSettings { $0.bands = 9 }
        XCTAssertTrue(indexing.isStale(of: .hough))
        XCTAssertFalse(indexing.isStale(of: .dictionary))
        XCTAssertFalse(indexing.isStale, "the Dictionary run is on screen")
        XCTAssertEqual(state.mapsStaleness, "Stale: the Indexing room's phases or settings changed since this run.")
        indexing.editSettings { $0.bands = 10 }
        XCTAssertNil(state.mapsStaleness)

        // A later Hough run (stopped at once) replaces the one Maps shows.
        indexing.setMethod(.hough)
        let again = indexing.index()
        indexing.stop()
        await again.value
        XCTAssertNotEqual(indexing.runs[.hough]?.id, hough.id)
        XCTAssertEqual(state.mapsStaleness, "Stale: the Indexing room has started another Hough run since.")

        state.ebsd.close()
        XCTAssertTrue(indexing.runs.isEmpty)
        XCTAssertNil(indexing.result)
    }

    // MARK: - Compare

    @MainActor func testCompareOnTheDemoScan() async throws {
        let state = try await openDemo()
        let indexing = state.indexing
        let points = 30 * 40
        XCTAssertNotNil(indexing.fileIndexing, "the demo's crystal map lies on the scan's grid")
        XCTAssertEqual(indexing.compareSources, [.hough, .dictionary, .file])
        XCTAssertEqual(indexing.compareA, .hough)
        XCTAssertEqual(indexing.compareB, .file)
        XCTAssertFalse(indexing.showsCompare)

        indexing.setShowsCompare(true)
        XCTAssertTrue(indexing.showsCompare)
        XCTAssertEqual(indexing.compareAbsence(.hough), "Index with Hough to compare it")
        XCTAssertNil(indexing.compareAbsence(.file))
        await indexing.refreshComparison().value
        XCTAssertNil(indexing.comparison)

        // A Hough run against the file: every point Hough indexed is compared, the rest left out.
        await indexing.index().value
        await indexing.refreshComparison().value
        let comparison = try XCTUnwrap(indexing.comparison)
        let hough = try XCTUnwrap(indexing.runs[.hough]).result
        XCTAssertEqual(comparison.comparedCount, hough.indexedCount)
        for i in 0..<points {
            let indexed = (hough.solutions[i]?.phase ?? -1) >= 0
            XCTAssertEqual(comparison.angles[i].isNaN, !indexed, "point \(i)")
            XCTAssertEqual(comparison.outcomes[i], indexed ? .compared : .noneInA, "point \(i)")
        }
        let pictures = try XCTUnwrap(indexing.comparePictures)
        XCTAssertEqual(pictures.a.count, points * 4)
        XCTAssertEqual(pictures.b.count, points * 4)
        XCTAssertEqual(pictures.layer, .ipfZ)

        // Picking B's source for A swaps them.
        indexing.setCompareA(.file)
        XCTAssertEqual(indexing.compareA, .file)
        XCTAssertEqual(indexing.compareB, .hough)
        await indexing.refreshComparison().value
        XCTAssertEqual(indexing.comparison?.comparedCount, comparison.comparedCount)

        // B Dictionary: empty until it has run, waiting while it runs, said when stopped before a row.
        indexing.setCompareB(.dictionary)
        XCTAssertEqual(indexing.compareAbsence(.dictionary), "Index with Dictionary to compare it")
        try await pickDictionary(indexing)
        let running = indexing.index()
        XCTAssertEqual(indexing.compareAbsence(.dictionary), "Dictionary is indexing: Compare follows when the run ends")
        XCTAssertNil(indexing.comparison)
        indexing.stop()
        await running.value
        XCTAssertEqual(indexing.compareAbsence(.dictionary), "The Dictionary run was stopped before a row landed")
        await indexing.index().value
        await indexing.refreshComparison().value
        let dictionary = try XCTUnwrap(indexing.runs[.dictionary]).result
        XCTAssertGreaterThan(dictionary.indexedCount, 0)
        XCTAssertEqual(indexing.comparison?.comparedCount, dictionary.indexedCount, "the file holds every point")

        // The layer: IPF-X draws both on IPF-X; a layer that is not IPF draws them on IPF-Z.
        indexing.setLayer(.ipfX)
        await indexing.refreshComparison().value
        XCTAssertEqual(indexing.comparePictures?.layer, .ipfX)
        indexing.setLayer(.score)
        XCTAssertEqual(indexing.compareLayer, .ipfZ)
        await indexing.refreshComparison().value
        XCTAssertEqual(indexing.comparePictures?.layer, .ipfZ)

        indexing.setShowsCompare(false)
        XCTAssertNil(indexing.comparison)
        indexing.setShowsCompare(true)
        await indexing.refreshComparison().value
        XCTAssertNotNil(indexing.comparison)
        state.ebsd.close()
        XCTAssertFalse(indexing.showsCompare)
        XCTAssertNil(indexing.comparison)
        XCTAssertNil(indexing.fileIndexing)
    }

    /// The bottom pane holds Compare while it is on; the Display section's switch and its two pop-ups; the tiles share one zoom and
    /// publish no View › Zoom target (the indexed map keeps it).
    func testTheComparisonIsWired() throws {
        let room = squeezed(try source("macTEM/UI/IndexingRoom.swift"))
        XCTAssertTrue(room.contains("if session.showsCompare {"))
        XCTAssertTrue(room.contains("IndexingComparePane(session: session, state: state, dataset: document.dataset)"))
        XCTAssertTrue(room.contains("session.refreshComparison()"))
        let inspector = squeezed(try source("macTEM/UI/IndexingRoomInspector.swift"))
        XCTAssertTrue(inspector.contains("set: { session.setShowsCompare($0) }"))
        XCTAssertTrue(inspector.contains("set: { session.setCompareA($0) }"))
        XCTAssertTrue(inspector.contains("set: { session.setCompareB($0) }"))
        for id in ["indexing.showCompare", "indexing.compareA", "indexing.compareB", "indexing.info.otherRun"] {
            XCTAssertTrue(inspector.contains(".accessibilityIdentifier(\"\(id)\")"), id)
        }
        let compare = try source("macTEM/UI/IndexingCompare.swift")
        XCTAssertEqual(compare.components(separatedBy: "PaneZoomModel()").count - 1, 1, "one zoom for both maps")
        XCTAssertFalse(compare.contains(".zoomCommandTarget("), "the indexed map keeps View › Zoom")
    }
}
