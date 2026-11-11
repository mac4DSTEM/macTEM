//
//  IndexingMapsHandOffTests.swift
//  The Indexing room's run in the Maps room without a file (D-SEM-99): `Open in Maps` shows exactly `IndexingSession.crystalMap()` (what
//  the .ang and .ctf exports write: the room's phase colours, the scan's steps and unit, the run's properties) beside the patterns, at
//  the pinned point, with the Maps room in front; the room holds one map of each source (a map file, the dataset's own map, the run)
//  and `Source` moves between them keeping the point and the layer, the pattern pane beside on the same point; a run the Indexing room
//  has moved on from is marked stale, with the cause; the dataset's maps go with the dataset. Run on the generated demo scan (30 × 40),
//  so the run is short.
//  Red before the change: no `Open in Maps`, no `.indexing` source, the Maps room holding only the map shown.
//

import XCTest
import TEMCore
import TEMSession
@testable import macTEM

nonisolated final class IndexingMapsHandOffTests: XCTestCase {

    /// The repo's own source file at `path`, read beside this test file.
    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    private func squeezed(_ text: String) -> String { text.split(whereSeparator: \.isWhitespace).joined(separator: " ") }

    /// A nickel map of `rows` × `columns` on 1.5 µm steps, with an `iq` property when asked.
    private static func map(rows: Int, columns: Int, iq: Bool = false) throws -> CrystalMap {
        let grid = CrystalMap.coordinates(shape: (rows, columns), steps: (1.5, 1.5))
        let n = rows * columns
        let ni = CrystalPhase(name: "Ni", spaceGroup: 225, pointGroup: "m-3m", lattice: [3.524, 3.524, 3.524, 90, 90, 90])
        return try CrystalMap(euler: (0..<n).map { SIMD3(Double($0) * 0.01, 0.2, 0.1) }, phaseIDs: Array(repeating: 0, count: n),
                              x: grid.x, y: grid.y, phaseList: PhaseList([(0, ni)]),
                              properties: iq ? ["iq": Array(repeating: 1, count: n)] : [:], scanUnit: "um")
    }

    // MARK: - Open in Maps through the window

    /// The demo scan opened as the window opens it, indexed with Hough, the run handed to Maps: the map Maps shows is the run's crystal
    /// map, its source the run, the pattern pane on the scan, the point the one pinned in Patterns; staleness by a setting, by the
    /// Patterns room's processing and by a later run; a source switch onto a stopped run's rows keeps the crosshair and the pattern
    /// pane together; the dataset's maps go when it closes.
    @MainActor func testOpenInMapsShowsTheRunsCrystalMap() async throws {
        let state = AppState(launch: LaunchOptions(arguments: []))
        let demo = try DemoDocuments.ebsd()
        await state.ebsd.bind(demo).value
        let ebsd = state.ebsd
        try await waitUntil("the demo scan's passes to end", seconds: 30) { !ebsd.isMapping && !ebsd.isComputingMean && !ebsd.isProcessing }
        let dataset = try XCTUnwrap(ebsd.dataset)
        XCTAssertEqual(state.maps.document?.source, .patterns, "the demo carries its own crystal map")

        XCTAssertEqual(state.indexing.openInMapsRefusal, "Index first")
        XCTAssertNil(state.openIndexingInMaps())
        XCTAssertEqual(state.statusText, "Index first")
        XCTAssertEqual(state.maps.document?.source, .patterns, "a refusal leaves the Maps room as it was")

        XCTAssertNil(state.indexing.refusal)
        await state.indexing.index().value
        let result = try XCTUnwrap(state.indexing.result)
        XCTAssertTrue(result.isComplete)
        XCTAssertNil(state.indexing.openInMapsRefusal)
        ebsd.pin(EBSDPosition(row: 4, column: 7))

        let drawn = try XCTUnwrap(state.openIndexingInMaps())
        await drawn.value
        let run = state.indexing.runGeneration
        XCTAssertEqual(state.navigation.workspaceArea, .maps)
        let shown = try XCTUnwrap(state.maps.map)
        XCTAssertEqual(shown, try state.indexing.crystalMap(), "the map Maps shows is the run's crystal map")
        XCTAssertEqual(state.maps.document?.source, .indexing(run: run, method: .hough))
        XCTAssertEqual(state.maps.fileName, "Demo EBSD")
        XCTAssertEqual(state.maps.pinned, EBSDPosition(row: 4, column: 7), "at the pattern pinned in Patterns")
        XCTAssertEqual(state.maps.gridShape.rows, 30)
        XCTAssertEqual(state.maps.gridShape.columns, 40)
        XCTAssertEqual(shown.dx, dataset.stepX)
        XCTAssertEqual(shown.dy, dataset.stepY)
        XCTAssertEqual(shown.scanUnit, dataset.scanUnit)
        let phase = try XCTUnwrap(shown.phases.entries.first { $0.id == 0 }?.phase)
        XCTAssertEqual(phase.color, state.indexing.phases[0].color, "the Indexing room's phase colour")
        for name in ["cm", "fit", "nmatch", "pq"] {
            XCTAssertTrue(state.maps.layers.contains(.property(name)), "no \(name) layer")
        }
        XCTAssertTrue(state.maps.isOnScan(of: dataset), "the live pattern pane shows the patterns beside the run")
        XCTAssertEqual(state.maps.sources.map(\.source), [.patterns, .indexing(run: run, method: .hough)])
        XCTAssertNil(state.mapsStaleness)
        XCTAssertEqual(MapsRoomFormat.sourceWords(.indexing(run: run, method: .hough)), "The Indexing room's Hough run")

        // A setting or the Patterns room's processing changed since the run stales it, each named; a later run too, and Open in Maps
        // is offered again only once that run has rows to hand over (this one is stopped at once).
        state.indexing.editSettings { $0.bands = 9 }
        XCTAssertEqual(state.mapsStaleness, "Stale: the Indexing room's phases or settings changed since this run.")
        state.indexing.editSettings { $0.bands = 10 }
        XCTAssertNil(state.mapsStaleness)
        let truncate = ebsd.pipeline.dynamicStage.truncate
        ebsd.editPipeline { $0.dynamicStage.truncate = truncate + 1 }
        XCTAssertEqual(state.mapsStaleness, "Stale: the Patterns room's processing changed since this run.")
        ebsd.editPipeline { $0.dynamicStage.truncate = truncate }
        XCTAssertNil(state.mapsStaleness)
        let again = state.indexing.index()
        XCTAssertEqual(state.indexing.openInMapsRefusal, "Stop the run or let it finish first")
        state.indexing.stop()
        await again.value
        XCTAssertEqual(state.indexing.openInMapsRefusal, "Index first")
        XCTAssertEqual(state.mapsStaleness, "Stale: the Indexing room has started another Hough run since.")
        XCTAssertEqual(state.maps.map, shown, "Maps keeps the run it was handed")

        // A stopped run's 12 rows in the run's place: switching onto it from a point past them puts the crosshair and the pattern
        // pane beside it at the origin together.
        let partial = OrientationMapSession.Document(fileName: "Demo EBSD", url: nil, map: try Self.map(rows: 12, columns: 40),
                                                     source: .indexing(run: run, method: .hough), format: "Indexing room · Hough")
        await state.maps.bind(partial).value
        let own = try XCTUnwrap(state.maps.sources.first { $0.source == .patterns })
        await state.showMapsSource(own.id)?.value
        XCTAssertEqual(state.maps.document?.source, .patterns)
        state.maps.pin(EBSDPosition(row: 20, column: 3))
        ebsd.pin(EBSDPosition(row: 20, column: 3))
        await state.showMapsSource(partial.id)?.value
        XCTAssertTrue(state.maps.isOnScan(of: dataset))
        XCTAssertEqual(state.maps.pinned, .origin, "row 20 is past the run's rows")
        XCTAssertEqual(ebsd.pinned, .origin, "the pattern pane follows the crosshair")

        ebsd.close()
        XCTAssertFalse(state.maps.hasMap)
        XCTAssertTrue(state.maps.sources.isEmpty)
    }

    // MARK: - The maps the room holds

    /// One map of each source: a map file, the dataset's own map, the Indexing run. `Source` moves between them at the same point and
    /// on the same layer where the map has them; the dataset's two go with it, and a map of the dataset shown gives way to the file.
    @MainActor func testTheRoomHoldsOneMapOfEachSourceAndTheDatasetsGoWithIt() async throws {
        let dataset = try DemoDocuments.ebsd().dataset
        let session = OrientationMapSession()
        let file = OrientationMapSession.Document(fileName: "a.ang", url: nil, map: try Self.map(rows: 30, columns: 40, iq: true),
                                                  source: .mapFile, format: ".ang (EDAX TSL)")
        let own = OrientationMapSession.Document(fileName: "Demo EBSD", url: nil, map: try Self.map(rows: 30, columns: 40),
                                                 source: .patterns, format: "generated")
        let run = OrientationMapSession.Document(fileName: "Demo EBSD", url: nil, map: try Self.map(rows: 12, columns: 40),
                                                 source: .indexing(run: 3, method: .hough), format: "Indexing room · Hough")

        await session.bind(file).value
        XCTAssertFalse(session.isOnScan(of: dataset), "a map file has no patterns, whatever its shape")
        session.patternsChanged(to: own)
        XCTAssertEqual(session.document?.source, .patterns, "a dataset's own map takes the place of a map file")
        XCTAssertTrue(session.isOnScan(of: dataset))
        await session.bind(run).value
        XCTAssertEqual(session.sources.map(\.source), [.mapFile, .patterns, .indexing(run: 3, method: .hough)])
        XCTAssertTrue(session.isOnScan(of: dataset), "a stopped run's first rows sit on the scan")
        XCTAssertNotEqual(own.id, run.id, "the same file's map from another source rebuilds the room's views")

        session.pin(EBSDPosition(row: 5, column: 9))
        await session.setLayer(.phase).value
        await session.showSource(own.id)?.value
        XCTAssertEqual(session.document?.source, .patterns)
        XCTAssertEqual(session.pinned, EBSDPosition(row: 5, column: 9))
        XCTAssertEqual(session.layer, .phase)
        await session.showSource(file.id)?.value
        await session.setLayer(.property("iq")).value
        session.pin(EBSDPosition(row: 20, column: 9))
        await session.showSource(run.id)?.value
        XCTAssertEqual(session.layer, .ipf(.z), "the run has no iq")
        XCTAssertEqual(session.pinned, .origin, "row 20 is past the run's 12 rows")
        XCTAssertNil(session.showSource(run.id), "the map shown already")
        XCTAssertEqual(session.sources.map(MapsRoomFormat.sourceTitle), ["File · a.ang", "File · Demo EBSD", "Hough · Indexing room"])

        session.patternsClosed()
        XCTAssertEqual(session.sources.map(\.source), [.mapFile])
        XCTAssertEqual(session.document?.source, .mapFile, "the run shown gives way to the map file held")
        session.patternsChanged(to: nil)
        XCTAssertEqual(session.document?.source, .mapFile, "a dataset without a map leaves a map file shown")

        session.close()
        XCTAssertTrue(session.sources.isEmpty)
        session.patternsChanged(to: own)
        session.patternsClosed()
        XCTAssertFalse(session.hasMap, "with no map file held the room goes back to its door")
    }

    /// File > Close Map closes the map shown, not every map held: with a map file and the dataset's own map held, ⌘W on the dataset's map
    /// shows the file's at the same point and layer, and the next ⌘W leaves the room at its door. Red before: one ⌘W emptied `sources`,
    /// the dataset's map gone until the dataset was opened again (macTEM#404).
    @MainActor func testCloseMapClosesTheMapShownOnly() async throws {
        let session = OrientationMapSession()
        let file = OrientationMapSession.Document(fileName: "a.ang", url: nil, map: try Self.map(rows: 30, columns: 40, iq: true),
                                                  source: .mapFile, format: ".ang (EDAX TSL)")
        let own = OrientationMapSession.Document(fileName: "Demo EBSD", url: nil, map: try Self.map(rows: 30, columns: 40),
                                                 source: .patterns, format: "generated")
        await session.bind(file).value
        await session.bind(own).value
        session.pin(EBSDPosition(row: 5, column: 9))
        await session.setLayer(.phase).value

        let state = AppState(launch: LaunchOptions(arguments: []))
        await state.maps.bind(file).value
        await state.maps.bind(own).value
        state.closeDocument(.orientationMap)
        XCTAssertEqual(state.maps.sources.map(\.source), [.mapFile], "⌘W in Maps closes the map shown, through the room's one close")

        await session.closeShown()?.value
        XCTAssertEqual(session.sources.map(\.source), [.mapFile], "the other map stays held")
        XCTAssertEqual(session.document?.source, .mapFile, "and is shown in its place")
        XCTAssertEqual(session.pinned, EBSDPosition(row: 5, column: 9))
        XCTAssertEqual(session.layer, .phase)
        XCTAssertNil(session.closeShown(), "the last map held")
        XCTAssertFalse(session.hasMap, "with none left the room goes back to its door")
        XCTAssertTrue(session.sources.isEmpty)
    }

    /// The words: the stale title, the Source row and Info for each source.
    func testTheSourcesAreNamed() throws {
        XCTAssertEqual(MapsRoomFormat.mapTitle(.ipf(.z)), "Map · IPF-Z")
        XCTAssertEqual(MapsRoomFormat.mapTitle(.ipf(.z), stale: true), "Map · IPF-Z · stale")
        XCTAssertEqual(MapsRoomFormat.sourceWords(.mapFile), "The map file")
        XCTAssertEqual(MapsRoomFormat.sourceWords(.patterns), "The pattern file's map")
        XCTAssertEqual(MapsRoomFormat.sourceWords(.indexing(run: 1, method: .dictionary)), "The Indexing room's Dictionary run")
        XCTAssertTrue(MapsRoomFormat.sourceNote(.indexing(run: 1, method: .hough)).contains("without a file"))
        let run = OrientationMapSession.Document(fileName: "Demo EBSD", url: nil, map: try Self.map(rows: 2, columns: 3),
                                                 source: .indexing(run: 1, method: .hough), format: "Indexing room · Hough")
        let info = Dictionary(MapsRoomFormat.infoRows(run).map { ($0.label, $0.value) }, uniquingKeysWith: { first, _ in first })
        XCTAssertEqual(info["Source"], "The Indexing room's Hough run on the pattern file")
        XCTAssertEqual(info["Format"], "Indexing room · Hough")
        XCTAssertEqual(info["Phase colours"], "The Indexing room's phase colours (orix's names)")
        XCTAssertEqual(info["Euler angles"], "Bunge (φ₁, Φ, φ₂), lab to crystal, from the run's rotations as orix converts them")
    }

    /// The Export section offers `Open in Maps` through the window's hand-off; the Maps inspector's Source pop-up moves between the
    /// maps held and the stale note shows; the room shows the patterns beside any map on the scan and rebuilds on a new source.
    func testTheRoomsAreWired() throws {
        let indexing = squeezed(try source("macTEM/UI/IndexingRoomInspector.swift"))
        XCTAssertTrue(indexing.contains("Button(\"Open in Maps\") { appState.openIndexingInMaps() }"))
        XCTAssertTrue(indexing.contains(".disabled(session.openInMapsRefusal != nil)"))
        XCTAssertTrue(indexing.contains(".accessibilityIdentifier(\"indexing.openInMaps\")"))
        let inspector = squeezed(try source("macTEM/UI/MapsRoomInspector.swift"))
        XCTAssertTrue(inspector.contains("set: { appState.showMapsSource($0) }"))
        XCTAssertTrue(inspector.contains("if let stale = appState.mapsStaleness"))
        let room = squeezed(try source("macTEM/UI/MapsRoom.swift"))
        XCTAssertTrue(room.contains("appState.maps.isOnScan(of: dataset)"))
        XCTAssertTrue(room.contains(".id(document.id)"))
        XCTAssertTrue(room.contains("staleness: appState.mapsStaleness"))
    }
}
