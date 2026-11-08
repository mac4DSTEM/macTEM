//
//  DocumentTargetTests.swift
//  What File > Close (⌘W) and Show in Finder act on (`DocumentTarget`, `AppState.closeDocument`): the document the room shows, the
//  selected image in the image rooms, the Patterns room's dataset in Patterns and Indexing, the map in Maps, the spectrum image in EDS
//  and EELS; nothing shown, the window. Run on the generated demo image and EBSD scan, so no file is read from disk.
//  Red before: no `DocumentTarget`; ⌘W closed the selected image in every room (in Maps an image that was not shown), with no image
//  open it closed the window in Patterns, and the dataset, the map or the spectrum image could never be closed.
//

import XCTest
import TEMCore
import TEMSession
@testable import macTEM

nonisolated final class DocumentTargetTests: XCTestCase {

    /// `DocumentTarget.of` with only what is named held.
    private static func target(_ area: WorkspaceArea, image: Bool = false, dataset: Bool = false, map: Bool = false,
                               eds: Bool = false, eels: Bool = false) -> DocumentTarget? {
        DocumentTarget.of(area: area, hasImage: image, hasDataset: dataset, hasMap: map, hasEDS: eds, hasEELS: eels)
    }

    /// Red under: the target taken from the selected image in every room (Maps closes the image); Patterns with no image falling back
    /// to the window; Indexing not on the Patterns room's dataset; a menu title that names the wrong document.
    func testTheTargetIsTheDocumentTheRoomShows() {
        XCTAssertEqual(Self.target(.maps, image: true, map: true), .orientationMap, "Maps closes its map, not the selected image")
        XCTAssertEqual(Self.target(.patterns, dataset: true), .ebsdDataset, "Patterns closes its dataset, not the window")
        XCTAssertEqual(Self.target(.indexing, image: true, dataset: true), .ebsdDataset, "Indexing runs on the Patterns room's dataset")
        XCTAssertEqual(Self.target(.image, image: true, dataset: true, map: true), .image)
        for area in [WorkspaceArea.fft, .diffraction, .results] {
            XCTAssertEqual(Self.target(area, image: true, eds: true), .image, "\(area.title) shows the selected image")
        }
        XCTAssertEqual(Self.target(.edx, image: true, eds: true, eels: true), .eds)
        XCTAssertEqual(Self.target(.eels, image: true, eds: true, eels: true), .eels)

        // A room that shows nothing: ⌘W closes the window, as the system's would.
        XCTAssertNil(Self.target(.image, dataset: true, map: true))
        XCTAssertNil(Self.target(.patterns, image: true))
        XCTAssertNil(Self.target(.maps, image: true, dataset: true))
        XCTAssertNil(Self.target(.results))

        XCTAssertEqual(DocumentTarget.image.closeTitle, "Close Image")
        XCTAssertEqual(DocumentTarget.ebsdDataset.closeTitle, "Close Dataset")
        XCTAssertEqual(DocumentTarget.orientationMap.closeTitle, "Close Map")
        XCTAssertEqual(DocumentTarget.eds.closeTitle, "Close Spectrum Image")
        XCTAssertEqual(DocumentTarget.eels.closeTitle, "Close Spectrum Image")
    }

    /// The demo image open and the demo EBSD scan bound, as the window holds them: ⌘W in Maps closes the maps and keeps the dataset
    /// and the image; ⌘W in Patterns closes the dataset, the Indexing room starting over, and keeps the image; in the Image room it is
    /// the image's again. The generated scan has no file, so Show in Finder has nothing to show for it. Red under: `closeDocument`
    /// closing the selected image whatever the target, or the dataset's close not reaching the Indexing room.
    @MainActor func testCloseActsOnTheShownDocumentAndKeepsTheImages() async throws {
        let state = AppState(launch: LaunchOptions(arguments: []))
        await state.open(urls: [DemoDocuments.latticeURL])?.value
        let images = state.openItems.items.map(\.id)
        XCTAssertEqual(images.count, 1, "the demo image is open")
        let demo = try DemoDocuments.ebsd()
        await state.ebsd.bind(demo).value
        XCTAssertTrue(state.maps.hasMap, "the demo carries its own crystal map")
        XCTAssertNotNil(state.indexing.fileIndexing)

        state.selectWorkspace(.maps)
        XCTAssertEqual(state.navigation.workspaceArea, .maps)
        XCTAssertEqual(state.documentTarget, .orientationMap)
        state.closeDocument(.orientationMap)
        XCTAssertFalse(state.maps.hasMap, "the map is closed")
        XCTAssertTrue(state.ebsd.hasDataset, "the dataset stays")
        XCTAssertEqual(state.openItems.items.map(\.id), images, "the image list is unchanged")

        state.selectWorkspace(.patterns)
        XCTAssertEqual(state.navigation.workspaceArea, .patterns)
        let target = try XCTUnwrap(state.documentTarget)
        XCTAssertEqual(target, .ebsdDataset)
        XCTAssertNil(state.documentURL, "the generated scan has no file")
        state.closeDocument(target)
        XCTAssertFalse(state.ebsd.hasDataset, "the dataset is closed")
        XCTAssertNil(state.indexing.fileIndexing, "the Indexing room starts over")
        XCTAssertEqual(state.openItems.items.map(\.id), images, "the image list is unchanged")
        XCTAssertNil(state.documentTarget, "Patterns shows nothing now: ⌘W closes the window")

        state.selectWorkspace(.image)
        XCTAssertEqual(state.documentTarget, .image)
        XCTAssertEqual(state.documentURL, state.openItems.selected?.url)
    }
}
