//
//  OpenItemsRereadTests.swift
//  `OpenItems.reread`: a resident item is read again from its file, ahead of the queue, and keeps showing its image until the new
//  read answers (the Calibration section's databar switch uses it); an item not in the list is ignored.
//

import XCTest
import FormatoCore
import ImagoCore
import TEMCore
import TEMSession
@testable import macTEM

nonisolated final class OpenItemsRereadTests: XCTestCase {
    private actor Counter {
        var reads: [String] = []
        func note(_ path: String) { reads.append(path) }
    }

    private static func image(_ name: String, height: Int) -> CalibratedImage {
        CalibratedImage(width: 2, height: height, pixels: Array(repeating: 1, count: 2 * height), x: nil, y: nil, fileName: name, source: "page 1", voltage: nil)
    }

    @MainActor func testRereadReadsTheFileAgainAndSwapsTheImage() async throws {
        let counter = Counter()
        let items = OpenItems(identify: { FileIdentity(path: $0.path, resourceID: nil) }) { request in
            await counter.note(request.url.path)
            let n = await counter.reads.count
            let image = Self.image(request.url.lastPathComponent, height: n == 1 ? 4 : 3)
            return OpenedImage(image: image, canvas: AppState.canvas(for: image), metadata: AcquisitionMetadata(), url: request.url, thumbnail: nil, bookmark: nil)
        }
        let url = URL(fileURLWithPath: "/tmp/sem.tif")
        items.open(urls: [url])
        await items.settled()
        let item = try XCTUnwrap(items.selected)
        XCTAssertEqual(item.session.image?.height, 4)
        items.reread(item)
        XCTAssertEqual(item.session.image?.height, 4, "the image shown stays until the new read answers")
        await items.settled()
        XCTAssertEqual(item.session.image?.height, 3, "the new read's image")
        let reads = await counter.reads
        XCTAssertEqual(reads.count, 2)
        XCTAssertEqual(item.residency, .resident)
    }

    @MainActor func testRereadOfAnItemNotInTheListDoesNothing() async throws {
        let counter = Counter()
        let items = OpenItems(identify: { FileIdentity(path: $0.path, resourceID: nil) }) { request in
            await counter.note(request.url.path)
            let image = Self.image(request.url.lastPathComponent, height: 2)
            return OpenedImage(image: image, canvas: AppState.canvas(for: image), metadata: AcquisitionMetadata(), url: request.url, thumbnail: nil, bookmark: nil)
        }
        let url = URL(fileURLWithPath: "/tmp/a.tif")
        items.open(urls: [url])
        await items.settled()
        let item = try XCTUnwrap(items.selected)
        items.close(item.id)
        items.reread(item)
        await items.settled()
        let reads = await counter.reads
        XCTAssertEqual(reads.count, 1, "a closed item is not read")
    }
}
