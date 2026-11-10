//
//  SessionStackMarksTests.swift
//  Marks on an image stack and on a demo image, and the session file: a stack opens with an identity (its first frame's pixels, the
//  stack as the object: `SessionSourceIdentity.ofStack`), a mark drawn on any frame is recorded against the stack, saved beside the
//  file and restored when it opens again; a demo image made in memory can never be saved, and the Measure tail and the Results
//  export say its marks are not kept instead of promising Save to Session (⌘S). Every `Red under:` names the change to the production
//  code that turns the test red.
//

import ImagoCore
import XCTest
import Foundation
import TEMCore
import TEMSession
@testable import macTEM

nonisolated final class SessionStackMarksTests: XCTestCase {

    // MARK: - Fixtures

    /// Frame `index` of a stack of `count` frames of 40 × 24 pixels, each frame with its own pixels, as `ImageStackSource` names it.
    nonisolated private static func frame(_ index: Int, of count: Int) -> CalibratedImage {
        let width = 40, height = 24
        return CalibratedImage(width: width, height: height,
                               pixels: (0..<width * height).map { Float(($0 * 37 + ($0 / width) * 11 + index * 31) % 97) },
                               x: AxisCalibration(scale: 0.5, unit: "nm", origin: 0), y: AxisCalibration(scale: 2.0, unit: "nm", origin: 0),
                               fileName: "stack.tif", source: "frame \(index + 1) of \(count)", voltage: nil)
    }

    /// A multi-page TIFF of `frames` frames in a folder of its own, removed after the test.
    private func stackFile(frames: Int) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionStackMarksTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("stack.tif")
        try DemoDocuments.writeStackTIFF(to: url, frames: frames, width: 64, height: 48) { f, x, y in UInt16(f * 100 + (x + y) % 50) }
        return url
    }

    private func distance(_ a: (Double, Double), _ b: (Double, Double)) -> ImageMark {
        ImageMark(kind: .distance, points: [ImagePoint(x: a.0, y: a.1), ImagePoint(x: b.0, y: b.1)])
    }

    // MARK: - A demo image

    /// The first mark on Help > Open Demo Data's lattice says the marks are not kept, in the Measure tail and in the Results export's
    /// session line, and offers no Save. Red under: the tail's ⌘S promise for a file that can never be saved.
    @MainActor func testADemoImageSaysItsMarksAreNotKeptAndOffersNoSave() async throws {
        let state = AppState(launch: LaunchOptions(arguments: []))
        await state.open(urls: [DemoDocuments.latticeURL])?.value
        let item = try XCTUnwrap(state.openItems.selected)
        let image = try XCTUnwrap(item.session.image, "the demo lattice is read")
        XCTAssertNil(item.measurements.add(distance((10, 10), (40, 30)), on: image), "the mark is recorded")
        let tail = SessionFormat.tail(SessionTailInput(item: item))
        XCTAssertEqual(tail.lines.map(\.text), ["Marks on demo images are not kept in a session file."])
        XCTAssertFalse(tail.lines.contains { $0.text.contains("Save to Session") }, "\(tail.lines.map(\.text))")
        XCTAssertFalse(tail.showsSave)
        XCTAssertFalse(item.canSave)
        XCTAssertEqual(ExportSnapshot.sessionSentence(of: item), "Marks on demo images are not kept in a session file.")
    }

    /// A file that can be saved keeps the ⌘S promise; one that never can says its marks are not kept, and nothing else changes.
    /// Red under: the not-kept sentence for every file, or the promise for a demo image.
    @MainActor func testTheTailPromisesASaveOnlyForAFileThatCanEverBeSaved() {
        var input = SessionTailInput(fileName: "scan.dm4.mactem.h5", sidecar: .none, notes: [], needsAccess: false,
                                     newerVersion: nil, hasMarks: true, isDirty: true, canSave: true, isSaving: false,
                                     savedAt: nil)
        XCTAssertTrue(input.canEverSave, "a file can be saved unless it is said otherwise")
        XCTAssertEqual(SessionFormat.tail(input).lines.map(\.text),
                       ["Not saved. Save to Session (⌘S) keeps the marks in scan.dm4.mactem.h5, beside the image."])
        input.canEverSave = false
        input.canSave = false
        let demo = SessionFormat.tail(input)
        XCTAssertEqual(demo.lines.map(\.text), [SessionFormat.notKept])
        XCTAssertFalse(demo.showsSave)
        input.hasMarks = false
        input.isDirty = false
        XCTAssertEqual(SessionFormat.tail(input), SessionTail(), "no marks: nothing to say")
    }

    // MARK: - An image stack

    /// A distance drawn on frame 2 of a stack is recorded against the stack, so the save restores it when the stack opens again on
    /// frame 1: one mark drawn, none kept aside. A single image still records its own object. Red under: the node naming the frame
    /// shown ("frame 2 of 3"), which the restore keeps and does not draw.
    @MainActor func testAMarkOnFrameTwoIsRecordedAgainstTheStackAndRestoredWithIt() throws {
        let frames = (0..<3).map { Self.frame($0, of: 3) }
        XCTAssertEqual(frames[1].source, "frame 2 of 3")
        let identity = SessionSourceIdentity.ofStack(firstFrame: frames[0], frameCount: 3, fileByteSize: 4096)
        XCTAssertEqual(identity, SessionSourceIdentity(fileName: "stack.tif", byteSize: 4096, object: "stack of 3 frames", width: 40,
                                                       height: 24, pixelSHA256: SessionSourceIdentity.fingerprint(of: frames[0].pixels)))
        let owner = ImageMeasurements()
        owner.noteOpened(identity)
        let mark = distance((3, 4), (30, 20))
        XCTAssertNil(owner.add(mark, on: frames[1]), "the mark is recorded")
        let nodeID = try XCTUnwrap(owner.nodeID(of: mark.id))
        XCTAssertEqual(owner.lineage.node(id: nodeID)?.parameters["object"], "stack of 3 frames")

        let request = try owner.saveRequest(opened: identity)
        let contents = SessionSidecarFile.Contents(schema: 1, minReader: 1, source: request.source, lineage: request.lineage)
        let restored = try SessionRestore.restore(contents, opened: identity, x: frames[0].x, y: frames[0].y)
        XCTAssertEqual(restored.marks.count, 1, "the mark drawn on frame 2 is drawn again")
        XCTAssertEqual(restored.kept, 0, "no node is kept aside")
        XCTAssertEqual(restored.marks.first?.mark.points, mark.points)

        // A single image: the node names the image's own object, as before.
        let single = CalibratedImage(width: 40, height: 24, pixels: frames[2].pixels, x: frames[2].x, y: frames[2].y,
                                     fileName: "scan.dm4", source: "ImageList.1", voltage: nil)
        let alone = ImageMeasurements()
        alone.noteOpened(SessionSourceIdentity.of(single, fileByteSize: 4096))
        let other = distance((1, 1), (9, 9))
        XCTAssertNil(alone.add(other, on: single))
        let otherNode = try XCTUnwrap(alone.nodeID(of: other.id))
        XCTAssertEqual(alone.lineage.node(id: otherNode)?.parameters["object"], "ImageList.1")
    }

    /// A multi-page TIFF opened through the app's own path has the stack's identity, so Save to Session is offered for a mark drawn
    /// on frame 2; the save writes the session file beside the stack, and opening the stack again restores the mark. Red under: the
    /// stack's read giving no identity (Save never offered, `nothingToSave`), or no sidecar read beside a stack.
    @MainActor func testAStackSavesItsMarksAndRestoresThemWhenOpenedAgain() async throws {
        let url = try stackFile(frames: 3)
        let state = AppState(launch: LaunchOptions(arguments: []))
        await state.open(urls: [url])?.value
        let item = try XCTUnwrap(state.openItems.selected)
        let stack = try XCTUnwrap(item.stack, "opened as a stack: \(item.readFailure ?? "no failure")")
        let identity = try XCTUnwrap(item.openedIdentity, "the stack's read gave its identity")
        XCTAssertEqual(identity.object, "stack of 3 frames")
        let frame1 = try stack.frame(0)
        XCTAssertEqual(identity.pixelSHA256, SessionSourceIdentity.fingerprint(of: frame1.pixels), "frame 1's pixels")
        XCTAssertEqual(item.measurements.sidecar, .none, "no session file beside it yet")

        // A distance on frame 2, as the room draws it on the frame shown.
        let frame2 = try stack.frame(1)
        XCTAssertEqual(frame2.source, "frame 2 of 3")
        let points = [ImagePoint(x: 3, y: 4), ImagePoint(x: 30, y: 20)]
        XCTAssertNil(item.measurements.add(ImageMark(kind: .distance, points: points), on: frame2), "the mark is recorded")
        XCTAssertTrue(item.canSave, "Save to Session is offered for a stack")
        XCTAssertNotEqual(SessionFormat.tail(SessionTailInput(item: item)).lines.first?.text, SessionFormat.notKept)

        let sidecar = try SessionSidecarFile.sidecarURL(forSource: url)
        let saved = try await SessionSaving.save(item, to: .url(sidecar))
        XCTAssertEqual(saved.marks, 1)
        XCTAssertFalse(item.measurements.isDirty)
        state.openItems.close(item.id)

        await state.open(urls: [url])?.value
        let again = try XCTUnwrap(state.openItems.selected)
        XCTAssertNotNil(again.stack)
        XCTAssertEqual(again.measurements.sidecar, .restored, "the session file beside the stack is read at its open")
        XCTAssertEqual(again.measurements.marks.map(\.points), [points], "the mark drawn on frame 2 is drawn again")
        state.openItems.close(again.id)
    }
}
