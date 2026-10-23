//
//  ImageStackTests.swift
//  An image stack read on demand (`ImageStackSource`, `ScopeHold`, TEMCore; `OpenItems.showFrame`, TEMSession; the open path in `AppState`):
//  a multi-page TIFF written here with a planted value in every pixel shows frame N having read that frame only, in a bounded amount of
//  memory, and holds the file's sandbox scope for its life.
//
//  THE TRUTH: frame f of the stack has the value `f * 100 + (x + y) % 50` at (x, y), 16 bits, so a frame read is checked pixel by pixel.
//  The reading is FormatoKit's `TIFFSignals` (its own gates are the kit's); these tests are the room's wiring.
//

import XCTest
import Darwin
import FormatoCore
import ImagoCore
#if canImport(TEMCore)
import TEMCore
import TEMSession
#endif
@testable import macTEM

nonisolated final class ImageStackTests: XCTestCase {

    static func planted(frame f: Int, x: Int, y: Int) -> UInt16 { UInt16(f * 100 + (x + y) % 50) }

    static func writeStack(frames: Int, width: Int, height: Int, to url: URL) throws {
        try DemoDocuments.writeStackTIFF(to: url, frames: frames, width: width, height: height) { f, x, y in planted(frame: f, x: x, y: y) }
    }

    static func tempStack(frames: Int, width: Int = 64, height: Int = 48) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("stack-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("stack.tif")
        try writeStack(frames: frames, width: width, height: height, to: url)
        return url
    }

    /// The process's physical footprint, bytes.
    static func footprint() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let r = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) } }
        return r == KERN_SUCCESS ? Int(info.phys_footprint) : 0
    }

    final class Counter: @unchecked Sendable { private let lock = NSLock(); private var n = 0; func add() { lock.lock(); n += 1; lock.unlock() }; var value: Int { lock.lock(); defer { lock.unlock() }; return n } }

    // MARK: Reading

    /// A stack opens with its frame count, size and no pixels read; frame N is that page's pixels exactly and is the only frame read.
    /// Red under: frames transposed; every frame read at the open; a frame off by one.
    func testAStackShowsFrameNHavingReadOnlyThatFrame() throws {
        let url = try Self.tempStack(frames: 12)
        let stack = try XCTUnwrap(try ImageStackSource.open(path: url.path))
        XCTAssertEqual(stack.frameCount, 12); XCTAssertEqual(stack.width, 64); XCTAssertEqual(stack.height, 48)
        XCTAssertEqual(stack.framesRead, 0, "opening reads no frame")
        let frame = try stack.frame(7)
        XCTAssertEqual(stack.framesRead, 1)
        XCTAssertEqual(frame.width, 64); XCTAssertEqual(frame.height, 48)
        XCTAssertEqual(frame.source, "frame 8 of 12")
        for (x, y) in [(0, 0), (63, 47), (10, 20), (33, 5)] { XCTAssertEqual(frame.pixels[y * 64 + x], Float(Self.planted(frame: 7, x: x, y: y)), "(\(x), \(y))") }
        XCTAssertThrowsError(try stack.frame(12)); XCTAssertThrowsError(try stack.frame(-1))
        XCTAssertEqual(stack.framesRead, 1, "a refused frame reads nothing")
    }

    /// One page is not a stack; the single-image reader keeps it. Red under: a one-page TIFF opened as a stack of one.
    func testASinglePageIsNotAStack() throws {
        let url = try Self.tempStack(frames: 1)
        XCTAssertNil(try ImageStackSource.open(path: url.path))
    }

    /// A 100-frame series shows frame 50 without loading the others: the process's footprint grows by far less than the file (52 MB), and
    /// one frame is read. Red under: the whole file read at the open (or mapped and touched); a frame cache that keeps every frame.
    func testAHundredFrameSeriesShowsOneFrameInBoundedMemory() throws {
        let url = try Self.tempStack(frames: 100, width: 512, height: 512)
        let fileBytes = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
        XCTAssertGreaterThan(fileBytes, 50_000_000)
        let before = Self.footprint()
        let stack = try XCTUnwrap(try ImageStackSource.open(path: url.path))
        let frame = try stack.frame(50)
        let grown = Self.footprint() - before
        XCTAssertEqual(stack.framesRead, 1)
        XCTAssertEqual(frame.pixels[100 * 512 + 100], Float(Self.planted(frame: 50, x: 100, y: 100)))
        XCTAssertLessThan(grown, 16_000_000, "showing one 0.5 MB frame (as 2 MB of Float32) grew the footprint by \(grown) bytes; the file is \(fileBytes)")
    }

    // MARK: The sandbox scope

    /// The scope is started once at the open and stopped once when released (twice releases stop once, and a holder that goes stops it);
    /// frames read in between are read under it. Red under: the scope stopped at the end of the open; stopped twice.
    func testTheScopeIsHeldUntilTheStackIsReleased() throws {
        let url = try Self.tempStack(frames: 4)
        let started = Counter(), stopped = Counter()
        let hold = ScopeHold(url: url, start: { _ in started.add(); return true }, stop: { _ in stopped.add() })
        let stack = try XCTUnwrap(try ImageStackSource.open(path: url.path, hold: hold))
        XCTAssertEqual(started.value, 1); XCTAssertEqual(stopped.value, 0)
        XCTAssertTrue(stack.holdsScope)
        _ = try stack.frame(1); _ = try stack.frame(3)
        XCTAssertEqual(stopped.value, 0, "still held while frames are read long after the open")
        stack.release(); stack.release()
        XCTAssertEqual(stopped.value, 1, "stopped once")
        XCTAssertFalse(stack.holdsScope)

        let ended = Counter()
        do { _ = ScopeHold(url: url, start: { _ in true }, stop: { _ in ended.add() }) }
        XCTAssertEqual(ended.value, 1, "a holder that goes stops its scope")
        let notGranted = Counter()
        let ungranted = ScopeHold(url: url, start: { _ in false }, stop: { _ in notGranted.add() })
        ungranted.release()
        XCTAssertEqual(notGranted.value, 0, "an access that was never granted is not stopped")
    }

    // MARK: Through the items

    /// The app's own open path opens a multi-page TIFF as a stack item, `showFrame` replaces the image with that frame, the newest request
    /// wins, and closing the item releases the stack. Red under: the stack refused as multi-page; a stale frame landing after a newer one.
    @MainActor func testTheOpenPathOpensAStackAndShowFrameMovesIt() async throws {
        let url = try Self.tempStack(frames: 20)
        let state = AppState(launch: LaunchOptions(arguments: []))
        await state.open(urls: [url])?.value
        let item = try XCTUnwrap(state.openItems.selected)
        let stack = try XCTUnwrap(item.stack, "opened as an image, not a stack: \(item.readFailure ?? "no failure")")
        XCTAssertEqual(stack.frameCount, 20)
        XCTAssertEqual(item.frame, 0)
        XCTAssertEqual(item.session.image?.pixels[0], Float(Self.planted(frame: 0, x: 0, y: 0)))
        XCTAssertEqual(stack.framesRead, 1, "the open read the first frame only")

        state.openItems.showFrame(item, to: 3)
        state.openItems.showFrame(item, to: 15)
        XCTAssertEqual(item.requestedFrame, 15)
        for _ in 0..<2000 where item.frame != 15 { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(item.frame, 15)
        let image = try XCTUnwrap(item.session.image)
        XCTAssertEqual(image.pixels[5 * 64 + 7], Float(Self.planted(frame: 15, x: 7, y: 5)))
        XCTAssertEqual(image.source, "frame 16 of 20")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(item.frame, 15, "a stale frame did not land after the newest")
        XCTAssertLessThanOrEqual(stack.framesRead, 3, "frame 0, possibly frame 3 (dropped), and frame 15")
        state.openItems.showFrame(item, to: 99)
        XCTAssertEqual(item.requestedFrame, 15, "a frame out of range asks for nothing")
        XCTAssertEqual(state.openItems.residentBytes, ResidentBytes.estimate(width: 64, height: 48, isSelected: true), "one frame resident")
        state.openItems.close(item.id)
        XCTAssertTrue(state.openItems.items.isEmpty)
    }

    /// The arrow keys' step stays inside the stack, and a window pinned on one frame is the window of the next (it is in raw values).
    @MainActor func testStepsStayInsideAndAHeldWindowSurvivesTheNextFrame() async throws {
        let url = try Self.tempStack(frames: 5)
        let state = AppState(launch: LaunchOptions(arguments: []))
        await state.open(urls: [url])?.value
        let item = try XCTUnwrap(state.openItems.selected)
        state.openItems.stepFrame(item, by: -1)
        XCTAssertEqual(item.requestedFrame, 0, "before the first frame there is nothing")
        XCTAssertNil(item.presentation.windowLow)
        item.presentation.holdCurrentRange()
        let held = try XCTUnwrap(item.presentation.windowLow)
        XCTAssertEqual(held, item.presentation.canvas?.rawRange?.lowerBound)
        state.openItems.stepFrame(item, by: 1)
        for _ in 0..<2000 where item.frame != 1 { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(item.frame, 1)
        XCTAssertEqual(item.presentation.windowLow, held, "the window is in raw values and stays")
        state.openItems.stepFrame(item, by: 99)
        XCTAssertEqual(item.requestedFrame, 4, "a step past the end goes to the end")
        state.openItems.stepFrame(item, by: 1)
        XCTAssertEqual(item.requestedFrame, 4)
    }

    /// The sidebar's thumbnail follows the frame shown. On the demo stack (a block that moves right by four pixels a frame) frame 1 and frame 6
    /// look different; a thumbnail left at the first frame is the same. Red under: `readFrame` answering no thumbnail.
    @MainActor func testTheThumbnailFollowsTheFrameShown() async throws {
        let url = try DemoDocuments.stackFile()
        let state = AppState(launch: LaunchOptions(arguments: []))
        await state.open(urls: [url])?.value
        let item = try XCTUnwrap(state.openItems.selected)
        let first = try XCTUnwrap(item.summary?.thumbnail)
        state.openItems.showFrame(item, to: 5)
        for _ in 0..<2000 where item.frame != 5 { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(item.frame, 5)
        XCTAssertNotEqual(item.summary?.thumbnail, first, "the thumbnail is of frame 6 now")
    }

    /// Closing an item that holds a stack releases its scope. Red under: the scope leaked until the process ends.
    @MainActor func testClosingAStackItemReleasesItsScope() async throws {
        let url = try Self.tempStack(frames: 3)
        let stopped = Counter()
        let hold = ScopeHold(url: url, start: { _ in true }, stop: { _ in stopped.add() })
        let stack = try XCTUnwrap(try ImageStackSource.open(path: url.path, hold: hold))
        let items = OpenItems(reader: { request in
            let image = try stack.frame(0)
            let canvas = AppState.canvas(for: image)
            return OpenedImage(image: image, canvas: canvas, metadata: AcquisitionMetadata(), url: request.url, thumbnail: nil, bookmark: nil, stack: stack)
        })
        items.open(urls: [url])
        await items.settled()
        let item = try XCTUnwrap(items.selected)
        XCTAssertNotNil(item.stack)
        XCTAssertEqual(stopped.value, 0)
        items.close(item.id)
        XCTAssertEqual(stopped.value, 1, "closing released the scope")
    }
}
