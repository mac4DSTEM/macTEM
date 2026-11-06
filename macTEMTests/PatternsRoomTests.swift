//
//  PatternsRoomTests.swift
//  The Patterns room's first slice (SEM program P1-06): the position arithmetic and the arrow keys, the mean-intensity map through
//  `EBSDBrowsing` on a planted scan and on the kikuchipy fixture (each pattern's mean is numpy's mean over the pattern axes, a float64
//  sum: exact to rounding), the session's hover, pin and step through `EBSDSession`, the generated demo dataset, the Calibration and
//  Info rows, the metadata export, and the routing of an h5ebsd file into the room through the app's own Open.
//

import XCTest
import SwiftUI
import FormatoCore
import TEMCore
import TEMSession
@testable import macTEM

nonisolated final class PatternsRoomTests: XCTestCase {

    private func fixture(_ name: String, _ ext: String) throws -> URL {
        try XCTUnwrap(Bundle(for: PatternsRoomTests.self).url(forResource: name, withExtension: ext), "\(name).\(ext) is not in the test bundle")
    }

    private func truthPatterns() throws -> (first: [Int], last: [Int]) {
        let file = try JSONDecoder().decode(EBSDH5ReaderTests.TruthFile.self, from: Data(contentsOf: fixture("ebsd-h5ebsd.truth", "json")))
        let truth = try XCTUnwrap(file.files["ebsd-kikuchipy-h5ebsd.h5"])
        return (truth.firstPattern, truth.lastPattern)
    }

    /// A 2 x 3 scan of 2 x 2 uint16 patterns whose pixels are the map index times 10 plus the pixel index: every mean is known.
    private func planted() throws -> EBSDMemoryPatterns {
        var bytes = Data()
        for k in 0..<6 { for p in 0..<4 { var v = UInt16(k * 10 + p).littleEndian; withUnsafeBytes(of: &v) { bytes.append(contentsOf: $0) } } }
        let dataset = EBSDDataset(format: .generated, manufacturer: "test", version: "", scanGroup: "s", scanGroups: ["s"], scanRows: 2, scanColumns: 3,
                                  patternRows: 2, patternColumns: 2, dataType: .uint16, stepY: 2, stepX: 1,
                                  detector: EBSDDetectorGeometry(rows: 2, columns: 2, projectionCenters: []),
                                  patterns: EBSDPatternSource(url: URL(fileURLWithPath: "/planted"), datasetPath: "", fileShape: [2, 3, 2, 2], dataType: .uint16))
        return try EBSDMemoryPatterns(dataset: dataset, bytes: bytes)
    }

    // MARK: Positions and keys

    /// An arrow moves one (⇧ ten) and stops at the scan's edge; the index is row-major. Red under: a step past the edge, or columns and rows swapped.
    func testArrowStepsStayInsideTheScan() {
        let p = EBSDPosition(row: 2, column: 3)
        XCTAssertEqual(p.stepped(.right, by: 1, rows: 5, columns: 8), EBSDPosition(row: 2, column: 4))
        XCTAssertEqual(p.stepped(.left, by: 10, rows: 5, columns: 8), EBSDPosition(row: 2, column: 0))
        XCTAssertEqual(p.stepped(.down, by: 10, rows: 5, columns: 8), EBSDPosition(row: 4, column: 3))
        XCTAssertEqual(p.stepped(.up, by: 1, rows: 5, columns: 8), EBSDPosition(row: 1, column: 3))
        XCTAssertEqual(p.index(columns: 8), 19)
        XCTAssertTrue(p.isInside(rows: 3, columns: 4)); XCTAssertFalse(p.isInside(rows: 2, columns: 4))
        XCTAssertEqual(EBSDPosition(row: -3, column: 99).clamped(rows: 5, columns: 8), EBSDPosition(row: 0, column: 7))
    }

    func testTheArrowKeysReadAsStepsAndNothingElseDoes() {
        XCTAssertEqual(PatternsKeys.step(key: .rightArrow, modifiers: [])?.direction, .right)
        XCTAssertEqual(PatternsKeys.step(key: .rightArrow, modifiers: [])?.count, 1)
        XCTAssertEqual(PatternsKeys.step(key: .upArrow, modifiers: .shift)?.count, 10)
        XCTAssertNil(PatternsKeys.step(key: .leftArrow, modifiers: .command))
        XCTAssertNil(PatternsKeys.step(key: .space, modifiers: []))
    }

    // MARK: The mean-intensity map

    /// Each map value is the mean of its pattern's stored pixels (a float64 sum, as numpy's `mean` over the signal axes), in map order; the
    /// pass reads the scan row by row and reports its progress. Red under: a sum over the wrong axis, a Float accumulator, a transposed map.
    func testTheMeanMapIsEachPatternsMeanOnAPlantedScan() throws {
        let access = try planted()
        var reported: [Double] = []
        let map = try XCTUnwrap(EBSDBrowsing.meanIntensityMap(access, progress: { reported.append($0) }))
        XCTAssertEqual(map, (0..<6).map { Float(Double($0 * 10) + 1.5) })
        XCTAssertEqual(reported, [0.5, 1])
        XCTAssertNil(try EBSDBrowsing.meanIntensityMap(access, isCancelled: { true }), "a cancelled pass answers nil")
        XCTAssertEqual(try access.row(1).doubles().map(Int.init), (3..<6).flatMap { k in (0..<4).map { k * 10 + $0 } })
    }

    func testTheMeanMapOfTheKikuchipyFixtureIsTheMeanOfItsPatterns() throws {
        let dataset = try EBSDH5Reader.read(url: fixture("ebsd-kikuchipy-h5ebsd", "h5"))
        let reader = try EBSDPatternReader(dataset)
        let map = try XCTUnwrap(EBSDBrowsing.meanIntensityMap(reader))
        XCTAssertEqual(map.count, dataset.patternCount)
        let truth = try truthPatterns()
        func mean(_ values: [Int]) -> Double { Double(values.reduce(0, +)) / Double(values.count) }
        XCTAssertEqual(Double(map[0]), mean(truth.first), accuracy: 1e-4)
        XCTAssertEqual(Double(map[map.count - 1]), mean(truth.last), accuracy: 1e-4)
        // The row read is the same bytes as the patterns read one by one.
        let row = try reader.row(0)
        XCTAssertEqual(row.shape, [dataset.scanColumns, dataset.patternRows, dataset.patternColumns])
        XCTAssertEqual(row.bytes.prefix(dataset.patternPixels), try reader.pattern(row: 0, column: 0).bytes)
    }

    // MARK: The session

    /// Binding a dataset shows pattern (0, 0) at once and starts the map; hovering shows the hovered pattern and leaving the map returns to the
    /// pinned one; Space pins the hovered position; an arrow steps the pinned one. Red under: the pane not following the pointer, a step past the edge.
    @MainActor func testTheSessionFollowsHoverPinAndTheKeys() async throws {
        let session = EBSDSession()
        var events: [String] = []
        session.onEvent = { events.append($0) }
        await session.bind(try DemoDocuments.ebsd()).value
        XCTAssertEqual(session.patternPosition, .origin)
        XCTAssertEqual(session.patternPresentation.canvas?.width, DemoDocuments.Truth.ebsdPatternSide)
        XCTAssertTrue(events.first?.hasPrefix("Opened Demo EBSD") == true, "\(events)")

        session.hover(EBSDPosition(row: 3, column: 4))
        XCTAssertEqual(session.shown, EBSDPosition(row: 3, column: 4))
        for _ in 0..<2000 where session.patternPosition != EBSDPosition(row: 3, column: 4) { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(session.patternPosition, EBSDPosition(row: 3, column: 4))
        XCTAssertEqual(session.pinned, .origin, "hovering pins nothing")

        session.pinHovered()
        XCTAssertEqual(session.pinned, EBSDPosition(row: 3, column: 4))
        session.hover(nil)
        XCTAssertEqual(session.shown, EBSDPosition(row: 3, column: 4), "off the map the pinned pattern is shown")
        session.step(.right, by: 10)
        XCTAssertEqual(session.pinned, EBSDPosition(row: 3, column: 14))
        session.step(.right, by: 100)
        XCTAssertEqual(session.pinned, EBSDPosition(row: 3, column: DemoDocuments.Truth.ebsdScanColumns - 1), "an arrow stops at the edge")
        for _ in 0..<2000 where session.patternPosition != session.pinned { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(session.patternPosition, session.pinned)

        for _ in 0..<4000 where session.isMapping { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(session.isMapping)
        XCTAssertEqual(session.meanIntensities?.count, DemoDocuments.Truth.ebsdScanRows * DemoDocuments.Truth.ebsdScanColumns)
        XCTAssertEqual(session.mapPresentation.canvas?.width, DemoDocuments.Truth.ebsdScanColumns)
        XCTAssertNotNil(session.meanIntensity(at: .origin))
        XCTAssertNil(session.meanIntensity(at: EBSDPosition(row: 999, column: 0)))

        // The virtual images (P1-07): the pass landed the whole detector's sum and the 5 x 5 tiles; the map follows the choice; the mix needs three tiles.
        XCTAssertEqual(session.virtualGrid, VirtualBSEGrid(5))
        XCTAssertEqual(session.virtualImages?.count, 26)
        let meanCanvas = session.mapPresentation.canvas?.contentVersion
        session.showMap(.bse)
        XCTAssertNotEqual(session.mapPresentation.canvas?.contentVersion, meanCanvas, "the BSE sum is another picture")
        XCTAssertEqual(session.mapValue(at: .origin)?.label, "BSE")
        XCTAssertEqual(try XCTUnwrap(session.mapValue(at: .origin)?.value), try XCTUnwrap(session.meanIntensity(at: .origin)) * 3600, accuracy: 0.5)
        let tile = VirtualBSETile(row: 2, column: 1)
        session.showMap(.tile(tile))
        XCTAssertEqual(session.mapValue(at: .origin)?.label, "r2 c1")
        XCTAssertFalse(session.hasMix)
        session.setMixTile(tile, channel: 0); session.setMixTile(VirtualBSETile(row: 2, column: 2), channel: 1)
        XCTAssertFalse(session.hasMix)
        session.setMixTile(VirtualBSETile(row: 2, column: 3), channel: 2)
        XCTAssertTrue(session.hasMix)
        XCTAssertEqual(session.mapChoice, .mix)
        XCTAssertEqual(session.mixRGBA?.count, 30 * 40 * 4)
        XCTAssertNil(session.mapValue(at: .origin), "the mix has no one value")
        // A new grid runs the pass again and drops the mix.
        session.setVirtualGrid(VirtualBSEGrid(3))
        XCTAssertNil(session.virtualImages); XCTAssertFalse(session.hasMix); XCTAssertEqual(session.mapChoice, .mean)
        for _ in 0..<4000 where session.isMapping { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(session.virtualImages?.count, 10)

        session.close()
        XCTAssertFalse(session.hasDataset); XCTAssertNil(session.patternPosition)
    }

    /// Opening the kikuchipy fixture through the session (the file path, off the main actor): the pattern on screen is pattern (0, 0) of the file,
    /// exactly (the canvas is normalised over the pattern's own range; mapped back it is the stored bytes).
    @MainActor func testOpeningTheKikuchipyFixtureShowsPatternZeroExactly() async throws {
        let session = EBSDSession()
        await session.open(url: try fixture("ebsd-kikuchipy-h5ebsd", "h5")).value
        XCTAssertFalse(session.isOpening)
        XCTAssertEqual(session.fileName, "ebsd-kikuchipy-h5ebsd.h5")
        XCTAssertEqual(session.dataset?.format, .kikuchipyH5EBSD)
        let canvas = try XCTUnwrap(session.patternPresentation.canvas)
        let range = try XCTUnwrap(canvas.rawRange)
        let truth = try truthPatterns().first
        XCTAssertEqual(canvas.normalized.count, truth.count)
        for (n, expected) in zip(canvas.normalized, truth) {
            XCTAssertEqual(Double(range.lowerBound + n * (range.upperBound - range.lowerBound)), Double(expected), accuracy: 1e-3)
        }
        for _ in 0..<4000 where session.isMapping { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(session.meanIntensities?.count, 9)
    }

    // MARK: The demo dataset

    /// The generated dataset is deterministic, the planted shape, and its grains read in the mean map: a grain with a higher level has a higher
    /// mean at its seed. Red under: a changed seed or level (a fixture move), the grains lost in the noise.
    func testTheDemoDatasetIsDeterministicAndItsGrainsShowInTheMeanMap() throws {
        let a = try DemoDocuments.ebsd(), b = try DemoDocuments.ebsd()
        let bytesA = try XCTUnwrap(a.access as? EBSDMemoryPatterns).bytes, bytesB = try XCTUnwrap(b.access as? EBSDMemoryPatterns).bytes
        XCTAssertEqual(bytesA, bytesB, "a fixed seed: the same patterns every time")
        XCTAssertEqual(a.dataset.scanRows, 30); XCTAssertEqual(a.dataset.scanColumns, 40)
        XCTAssertEqual(a.dataset.patternRows, 60); XCTAssertEqual(a.dataset.dataType, .uint8)
        XCTAssertEqual(a.dataset.stepX, 1.5); XCTAssertEqual(a.dataset.sem.beamEnergyKeV, 20); XCTAssertEqual(a.dataset.detector.sampleTilt, 70)
        XCTAssertEqual(a.dataset.format, .generated)
        let map = try XCTUnwrap(EBSDBrowsing.meanIntensityMap(a.access))
        let means = DemoDocuments.Truth.ebsdGrainSeeds.map { map[$0.row * 40 + $0.column] }
        for g in 1..<means.count { XCTAssertGreaterThan(means[g], means[g - 1], "grain \(g) sits on a higher level than grain \(g - 1)") }
        XCTAssertEqual(DemoDocuments.Truth.ebsdGrain(row: 5, column: 6), 0)
        XCTAssertEqual(DemoDocuments.Truth.ebsdGrain(row: 14, column: 38), 5)
    }

    // MARK: Rows, readouts and the export

    func testTheRowsAndReadoutsReadTheFile() throws {
        let dataset = try EBSDH5Reader.read(url: fixture("ebsd-kikuchipy-h5ebsd", "h5"))
        let rows = EBSDBrowsing.calibrationRows(dataset)
        func value(_ label: String) -> String? { rows.first { $0.label == label }?.value }
        XCTAssertEqual(value("Scan"), "3 × 3")
        XCTAssertEqual(value("Pattern"), "60 × 60 px · binned 8×")
        XCTAssertEqual(value("Beam"), "20 kV")
        XCTAssertEqual(value("Convention"), "Bruker")
        XCTAssertTrue(value("Projection centre")?.contains("first of 9") == true, value("Projection centre") ?? "none")
        XCTAssertTrue(value("Step")?.contains("µm") == true)
        XCTAssertEqual(rows.filter { $0.label == "Phase" }.count, 1)
        XCTAssertEqual(Set(rows.map(\.id)).count, rows.count, "every row has its own identity")
        XCTAssertEqual(rows.first { $0.label == "Sample tilt" }?.key, "sample-tilt")
        let info = EBSDBrowsing.infoRows(dataset, fileName: "x.h5")
        XCTAssertEqual(info.first?.value, "x.h5")
        XCTAssertTrue(info.contains { $0.label == "Format" && $0.value.hasPrefix("kikuchipy h5ebsd") })
        XCTAssertTrue(info.contains { $0.label == "Scan" && $0.value.contains("of 2") }, "the fixture holds two scans")
        XCTAssertEqual(EBSDBrowsing.mapReadout(EBSDPosition(row: 12, column: 40), mean: 118.25), "row 12 · col 40 · mean \(UnitDisplay.number(118.25, digits: 4))")
        XCTAssertEqual(EBSDBrowsing.mapReadout(.origin, mean: nil), "row 0 · col 0")
        XCTAssertEqual(EBSDBrowsing.patternTitle(EBSDPosition(row: 1, column: 2), hovering: true), "Pattern · row 1 · col 2 · hovering")
        XCTAssertEqual(EBSDBrowsing.capsuleDetail(dataset), "3 × 3 of 60 × 60")
        let json = try JSONSerialization.jsonObject(with: EBSDBrowsing.metadataJSON(dataset, fileName: "x.h5")) as? [String: Any]
        XCTAssertEqual(json?["scan_shape"] as? [Int], [3, 3])
        XCTAssertEqual((json?["detector"] as? [String: Any])?["binning"] as? Int, 8)
        XCTAssertEqual(((json?["phases"] as? [[String: Any]])?.first?["name"]) as? String, "ni")
    }

    /// The Export section's two files: the metadata JSON and the pattern PNG, written to the journeys' folder without a panel.
    @MainActor func testTheExportsWriteTheirFiles() async throws {
        let session = EBSDSession()
        await session.bind(try DemoDocuments.ebsd()).value
        let state = PatternsRoomState()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("patterns-export-\(UUID().uuidString)")
        var reports: [String] = []
        state.export(.metadataJSON, from: session, directory: dir) { reports.append($0) }
        state.export(.patternPNG, from: session, directory: dir) { reports.append($0) }
        XCTAssertEqual(reports, ["Exported Demo EBSD metadata.json", "Exported Demo EBSD pattern r0 c0.png"])
        let png = try Data(contentsOf: dir.appendingPathComponent("Demo EBSD pattern r0 c0.png"))
        XCTAssertEqual([UInt8](png.prefix(4)), [0x89, 0x50, 0x4E, 0x47])
        // The map, once the pass has landed: the mean, then the colour mix through its own encoder.
        for _ in 0..<4000 where session.isMapping { try await Task.sleep(for: .milliseconds(5)) }
        state.export(.mapPNG, from: session, directory: dir) { reports.append($0) }
        XCTAssertEqual(reports.last, "Exported Demo EBSD map mean.png")
        for (channel, column) in [1, 2, 3].enumerated() { session.setMixTile(VirtualBSETile(row: 2, column: column), channel: channel) }
        state.export(.mapPNG, from: session, directory: dir) { reports.append($0) }
        XCTAssertEqual(reports.last, "Exported Demo EBSD map mix.png")
        let mix = try Data(contentsOf: dir.appendingPathComponent("Demo EBSD map mix.png"))
        XCTAssertEqual([UInt8](mix.prefix(4)), [0x89, 0x50, 0x4E, 0x47])
    }

    // MARK: Routing

    /// An h5ebsd file is inventoried as EBSD patterns by content (`.h5` and `.h5oina`), lands in the Patterns room before anything else, and a
    /// Velox file is not one; the room is available exactly when the window holds a dataset.
    func testAnH5EBSDFileIsInventoriedAsPatterns() throws {
        XCTAssertEqual(FileRouting.inventory(path: try fixture("ebsd-kikuchipy-h5ebsd", "h5").path), FileInventory(ebsdPatterns: true))
        XCTAssertEqual(FileRouting.inventory(path: try fixture("ebsd-oxford", "h5oina").path), FileInventory(ebsdPatterns: true))
        XCTAssertFalse(FileRouting.inventory(path: try fixture("velox-haadf-last", "emd").path).ebsdPatterns)
        XCTAssertEqual(FileInventory(image: true, edsSpectrumImage: true, ebsdPatterns: true).landing, .patterns)
        XCTAssertGreaterThan(FileInventory.Landing.patterns.richness, FileInventory.Landing.eds.richness)
        XCTAssertTrue(FileRouting.openableExtensions.contains("h5oina"))
        XCTAssertNotNil(RoomAvailability.reason(.patterns, holdings: RoomHoldings(images: true)))
        XCTAssertNil(RoomAvailability.reason(.patterns, holdings: RoomHoldings(ebsd: true)))
        XCTAssertNotNil(RoomAvailability.reason(.image, holdings: RoomHoldings(ebsd: true)))
        XCTAssertEqual(RoomAvailability.fallback(holdings: RoomHoldings(ebsd: true)), .patterns)
    }

    /// The app's Open sends the fixture to the Patterns room: the room is selected, the session holds the file, no image item is made.
    @MainActor func testTheAppsOpenRoutesAnH5EBSDFileToThePatternsRoom() async throws {
        let state = AppState(launch: LaunchOptions(arguments: []))
        await state.open(urls: [try fixture("ebsd-kikuchipy-h5ebsd", "h5")])?.value
        XCTAssertEqual(state.navigation.workspaceArea, .patterns)
        for _ in 0..<2000 where !state.ebsd.hasDataset { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(state.ebsd.fileName, "ebsd-kikuchipy-h5ebsd.h5")
        XCTAssertTrue(state.openItems.items.isEmpty, "a pattern dataset is not an open image")
        XCTAssertEqual(state.windowTitle, "ebsd-kikuchipy-h5ebsd.h5")
        XCTAssertNil(state.roomUnavailableReason(.patterns))
        XCTAssertNotNil(state.roomUnavailableReason(.image))
    }

    /// `--demo-ebsd-fixture` lands in the Patterns room with the demo dataset bound.
    @MainActor func testTheLaunchArgumentOpensTheDemoDataset() async throws {
        let state = AppState(launch: LaunchOptions(arguments: ["--demo-ebsd-fixture"]))
        XCTAssertEqual(state.navigation.workspaceArea, .patterns)
        XCTAssertEqual(state.ebsd.fileName, "Demo EBSD")
    }
}
