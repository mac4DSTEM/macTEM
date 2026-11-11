//
//  PaneDisplaySectionTests.swift
//  The rooms with a scan map and a pattern (Patterns, Indexing) have one Display section, second after Calibration, with a Map · Pattern
//  switch (control placement §2, §5; mac4DSTEM has one Display per pane). Red under: a "Map Display" or "Pattern Display" section back,
//  Display after the pipeline, the colormap identifiers the journeys use lost.
//

import XCTest

nonisolated final class PaneDisplaySectionTests: XCTestCase {

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    private func squeezed(_ text: String) -> String { text.split(whereSeparator: \.isWhitespace).joined(separator: " ") }

    func testPatternsHasOneDisplaySecondAfterCalibration() throws {
        let text = squeezed(try source("macTEM/UI/PatternsRoomInspector.swift"))
        XCTAssertFalse(text.contains("\"Pattern Display\""))
        XCTAssertTrue(text.contains("PaneDisplaySection(map: session.mapPresentation, pattern: session.patternPresentation, room: \"patterns\", mapColormapID: \"patterns.colormap\", patternColormapID: \"patterns.pattern.colormap\") PatternsVirtualImagesSection(session: session, dataset: dataset) PatternsProcessingSections(session: session, dataset: dataset) PatternsSimulationSection(session: session)"))
    }

    func testIndexingHasOneDisplaySecondAfterCalibration() throws {
        let text = squeezed(try source("macTEM/UI/IndexingRoomInspector.swift"))
        XCTAssertFalse(text.contains("\"Pattern Display\"") || text.contains("\"Map Display\""))
        XCTAssertTrue(text.contains("IndexingCalibrationSection(session: session, dataset: dataset) PaneDisplaySection(map: session.showsScalarMap ? session.mapPresentation : nil, pattern: session.patternPresentation, room: \"indexing\", mapColormapID: \"indexing.map.colormap\", patternColormapID: \"indexing.pattern.colormap\") { IndexingDisplayRows(session: session) } IndexingPhasesSection(session: session)"))
    }

    func testTheSwitchIsFullWidthAndOnlyWhenThereAreTwoPictures() throws {
        let text = squeezed(try source("macTEM/UI/PaneDisplaySection.swift"))
        XCTAssertTrue(text.contains("if map != nil { SegmentedPicker(label: \"Display of\""), "the shell's full-width segmented control, only with a scalar map")
        XCTAssertTrue(text.contains("private var shown: PaneDisplayTarget { map == nil ? .pattern : target }"))
    }
}
