//
//  ImageSessionTests.swift
//  Pins `ImageSession`'s open-token rule: only the latest open publishes. A superseded open's `finishOpen` returns
//  false and changes nothing (image, url, loading), whichever order the reads finish in; `failOpen` of a stale token
//  leaves the newer open loading; a failed open keeps the image already shown.
//

import XCTest
import FormatoCore
import TEMCore
import TEMSession

nonisolated final class ImageSessionTests: XCTestCase {

    private static func image(_ name: String, value: Float) -> CalibratedImage {
        CalibratedImage(width: 2, height: 1, pixels: [value, value + 1], x: nil, y: nil,
                        fileName: name, source: "ImageList.1", voltage: nil)
    }
    private static let a = image("a.dm4", value: 1)
    private static let b = image("b.dm4", value: 5)
    private static let urlA = URL(fileURLWithPath: "/data/a.dm4")
    private static let urlB = URL(fileURLWithPath: "/data/b.dm4")

    @MainActor func testASupersededOpenThatFinishesFirstChangesNothing() {
        let session = ImageSession()
        let first = session.beginOpen()
        let second = session.beginOpen()
        XCTAssertNotEqual(first, second)
        XCTAssertFalse(session.finishOpen(first, image: Self.a, url: Self.urlA, metadata: AcquisitionMetadata()), "the earlier open was superseded")
        XCTAssertNil(session.image)
        XCTAssertNil(session.url)
        XCTAssertTrue(session.isLoading, "the newer open is still running")
        XCTAssertTrue(session.finishOpen(second, image: Self.b, url: Self.urlB, metadata: AcquisitionMetadata()))
        XCTAssertEqual(session.image, Self.b)
        XCTAssertEqual(session.url, Self.urlB)
        XCTAssertFalse(session.isLoading)
    }

    @MainActor func testASupersededOpenThatFinishesLastNeverReplacesTheNewerImage() {
        let session = ImageSession()
        let first = session.beginOpen()
        let second = session.beginOpen()
        XCTAssertTrue(session.finishOpen(second, image: Self.b, url: Self.urlB, metadata: AcquisitionMetadata()))
        XCTAssertFalse(session.finishOpen(first, image: Self.a, url: Self.urlA, metadata: AcquisitionMetadata()), "a slower, earlier read is dropped")
        XCTAssertEqual(session.image, Self.b)
        XCTAssertEqual(session.url, Self.urlB)
        XCTAssertFalse(session.isLoading)
    }

    @MainActor func testAStaleFailureLeavesTheNewerOpenLoading() {
        let session = ImageSession()
        let first = session.beginOpen()
        let second = session.beginOpen()
        XCTAssertFalse(session.failOpen(first), "a superseded open's failure is not the user's news (no alert)")
        XCTAssertTrue(session.isLoading, "the failure of a superseded open does not end the newer one")
        XCTAssertTrue(session.failOpen(second), "the latest open's failure is reported")
        XCTAssertFalse(session.isLoading)
        XCTAssertNil(session.image)
    }

    @MainActor func testAFailedOpenKeepsTheImageAlreadyShown() {
        let session = ImageSession()
        let shown = session.beginOpen()
        XCTAssertTrue(session.finishOpen(shown, image: Self.a, url: Self.urlA, metadata: AcquisitionMetadata()))
        let next = session.beginOpen()
        XCTAssertTrue(session.isLoading)
        XCTAssertEqual(session.image, Self.a, "the shown image stays while the next one is read")
        session.failOpen(next)
        XCTAssertFalse(session.isLoading)
        XCTAssertEqual(session.image, Self.a)
        XCTAssertEqual(session.url, Self.urlA)
        // The token the shown image came from is spent: it cannot publish again over a later open.
        XCTAssertFalse(session.finishOpen(shown, image: Self.b, url: Self.urlB, metadata: AcquisitionMetadata()))
        XCTAssertEqual(session.image, Self.a)
    }
}
