//
//  OpenItemsTests.swift
//  Pins `OpenItems`, the owner of the files open in one window (V1-13, ADR 007), through a fake reader and a
//  path-only file identity: one file by several spellings is one item and a name in two folders is two (the real
//  resolver, on temp files); a batch opens each file once, in order, and selects its first; a file open already is
//  selected, not read again; a failed first read removes its item and returns the selection; closing selects the next,
//  else the previous; stepping wraps; the selection binding the list writes through and ⌘W; viewport and colormap stay
//  with their item through selection and eviction; the memory rule (8·W·H warm, 12·W·H selected, nothing cold; the
//  least recently selected go cold first, never the selected one nor one without a bookmark; eviction frees the old
//  session and presentation, not only empties them); a cold item keeps its thumbnail and is read again through its
//  bookmark, and follows the file when the bookmark resolves elsewhere; a re-read the selection left, or of a closed
//  item, is cancelled (the queue moves on without waiting) and its late answer, from a reader that ignored the
//  cancellation, is dropped; a selected file still queued for its first read is read next, once; no read moves the
//  selection; reads run one at a time; a view reading the selected item is not told of an unrelated open or close.
//  Every test names, in its comment, the change to the production code that turns it red.
//

import CoreGraphics
import Observation
import XCTest
import ImagoCore
import FormatoCore
import TEMCore
import TEMSession
import ShellMetal

nonisolated final class OpenItemsTests: XCTestCase {

    // MARK: - Fixtures

    private static let a = URL(fileURLWithPath: "/data/a.dm4")
    private static let b = URL(fileURLWithPath: "/data/b.dm4")
    private static let c = URL(fileURLWithPath: "/data/c.dm4")
    private static let d = URL(fileURLWithPath: "/data/d.dm4")
    private static let e = URL(fileURLWithPath: "/data/e.dm4")

    nonisolated struct ReadFailure: LocalizedError, Sendable {
        let path: String
        var errorDescription: String? { "cannot read \(path)" }
    }

    /// A reader that answers every file with a 4 × 3 image (or the size it was told) and a thumbnail that names the read
    /// (`thumbnail(read:)`), records every request, makes a new bookmark with each read (or none), can be told to fail a
    /// file, to answer from another URL (a bookmark that resolved elsewhere), and can hold a file's read at a gate until
    /// released. A held read honours its task's cancellation as a real reader does — the gate opens and the read throws
    /// `CancellationError` — and records it; `ignoreCancellation` makes it a reader that never checks, whose answer then
    /// comes late.
    actor FakeReader {
        private(set) var requests: [ReadRequest] = []
        private(set) var maxInFlight = 0
        private(set) var cancelledPaths: [String] = []
        private var inFlight = 0
        private var sizes: [String: (width: Int, height: Int)] = [:]
        private var failing: Set<String> = []
        private var withoutBookmark: Set<String> = []
        private var held: Set<String> = []
        private var ignoringCancellation: Set<String> = []
        private var relocations: [String: URL] = [:]
        private var gates: [String: [CheckedContinuation<Void, Never>]] = [:]
        private var answered: [String: Int] = [:]

        var requestedPaths: [String] { requests.map { $0.url.path } }

        /// The thumbnail the fake answers with on the `n`-th read of a file: its second value is `n / 10`.
        nonisolated static func thumbnail(read n: Int) -> Thumbnail {
            Thumbnail(width: 2, height: 1, normalized: [Float(n) / 10, 1])!
        }

        func size(_ url: URL, _ width: Int, _ height: Int) { sizes[url.path] = (width, height) }
        func fail(_ url: URL, _ on: Bool = true) { if on { failing.insert(url.path) } else { failing.remove(url.path) } }
        func noBookmark(_ url: URL) { withoutBookmark.insert(url.path) }
        func hold(_ url: URL) { held.insert(url.path) }
        func ignoreCancellation(_ url: URL) { ignoringCancellation.insert(url.path) }
        /// Answers the reads of `url` as if its bookmark had resolved to `moved`.
        func relocate(_ url: URL, to moved: URL) { relocations[url.path] = moved }
        func release(_ url: URL) {
            held.remove(url.path)
            openGates(url.path)
        }
        private func openGates(_ path: String) {
            for gate in gates.removeValue(forKey: path) ?? [] { gate.resume() }
        }
        private func noteCancelled(_ path: String) {
            cancelledPaths.append(path)
            if !ignoringCancellation.contains(path) { openGates(path) }
        }
        /// Whether a read of `url` is held at its gate within about two seconds (a test whose set-up failed must not hang).
        func untilHeld(_ url: URL) async -> Bool {
            for _ in 0..<400 {
                if !(gates[url.path] ?? []).isEmpty { return true }
                try? await Task.sleep(for: .milliseconds(5))
            }
            return false
        }
        /// Whether a read of `url` was cancelled within about two seconds.
        func untilCancelled(_ url: URL) async -> Bool {
            for _ in 0..<400 {
                if cancelledPaths.contains(url.path) { return true }
                try? await Task.sleep(for: .milliseconds(5))
            }
            return false
        }
        /// Whether a read of `url` was asked for within about two seconds.
        func untilRequested(_ url: URL) async -> Bool {
            for _ in 0..<400 {
                if requests.contains(where: { $0.url.path == url.path }) { return true }
                try? await Task.sleep(for: .milliseconds(5))
            }
            return false
        }

        func read(_ request: ReadRequest) async throws -> OpenedImage {
            let path = request.url.path
            requests.append(request)
            inFlight += 1
            maxInFlight = max(maxInFlight, inFlight)
            defer { inFlight -= 1 }
            if held.contains(path) {
                await withTaskCancellationHandler {
                    await withCheckedContinuation { gates[path, default: []].append($0) }
                } onCancel: {
                    Task { await self.noteCancelled(path) }
                }
            }
            if !ignoringCancellation.contains(path) { try Task.checkCancellation() }
            if failing.contains(path) { throw ReadFailure(path: path) }
            let n = (answered[path] ?? 0) + 1
            answered[path] = n
            let (width, height) = sizes[path] ?? (4, 3)
            let image = CalibratedImage(width: width, height: height, pixels: [Float](repeating: Float(n), count: width * height),
                                        x: nil, y: nil, fileName: request.url.lastPathComponent, source: "fake", voltage: nil)
            let canvas = CanvasPixels(width: width, height: height, normalized: [Float](repeating: 0, count: width * height),
                                      contentVersion: n, rawRange: nil)
            let bookmark = withoutBookmark.contains(path) ? nil : Data("bookmark:\(path):\(n)".utf8)
            return OpenedImage(image: image, canvas: canvas, metadata: AcquisitionMetadata(),
                               url: relocations[path] ?? request.url, thumbnail: Self.thumbnail(read: n), bookmark: bookmark)
        }
    }

    /// A one-shot flag an observation's `onChange` (which is `@Sendable`) can raise.
    nonisolated final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var raised = false
        func raise() { lock.withLock { raised = true } }
        var isRaised: Bool { lock.withLock { raised } }
    }

    nonisolated struct NeverHeld: Error {}

    final class Failures {
        var urls: [URL] = []
        var messages: [String] = []
    }

    /// Identity by path alone: no file system.
    @MainActor private func makeItems(_ fake: FakeReader, budget: Int = .max) -> OpenItems {
        OpenItems(budgetBytes: budget, identify: { FileIdentity(path: $0.path) }, reader: { request in
            try await fake.read(request)
        })
    }

    @MainActor private func item(_ items: OpenItems, _ url: URL) throws -> OpenItem {
        try XCTUnwrap(items.items.first { $0.url == url }, "no item for \(url.lastPathComponent)")
    }

    /// Three 4 × 3 files read in order (a selected, b and c warm), then a budget that sends b, the least recently
    /// selected, cold. b carries a viewport and a colormap of its own. Warm costs 96 bytes, selected 144: 336 in all,
    /// 240 with b cold, under the budget of 250.
    @MainActor private func threeWithBCold(_ fake: FakeReader) async throws -> (OpenItems, a: OpenItem, b: OpenItem, c: OpenItem) {
        let items = makeItems(fake)
        items.open(urls: [Self.a, Self.b, Self.c])
        await items.settled()
        let a = try item(items, Self.a), b = try item(items, Self.b), c = try item(items, Self.c)
        b.viewport = ImageViewport(zoom: 3, offset: CGSize(width: 7, height: -8))
        b.presentation.colormap = .inferno
        b.presentation.windowLow = 3
        b.presentation.windowHigh = 9.5
        b.presentation.gamma = 0.5
        b.presentation.showsScaleBar = false
        items.budgetBytes = 250
        XCTAssertEqual(b.residency, .cold, "setup: the least recently selected went cold")
        XCTAssertEqual([a.residency, c.residency], [.resident, .resident], "setup")
        return (items, a, b, c)
    }

    /// Waits for the read of `url` to reach its gate; a read that never does ends the test instead of hanging it.
    private func waitUntilHeld(_ fake: FakeReader, _ url: URL) async throws {
        let isHeld = await fake.untilHeld(url)
        XCTAssertTrue(isHeld, "the read of \(url.lastPathComponent) never reached its gate")
        if !isHeld { throw NeverHeld() }
    }

    private func scratchDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenItemsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    // MARK: - File identity

    /// Red under: `FileIdentity.of` reading the URL as spelled (no `resolvingSymlinksInPath`) — the symlink then has
    /// the link's own identifier and opens a second item.
    @MainActor func testSeveralSpellingsOfOneFileAreOneItem() async throws {
        let directory = try scratchDirectory()
        let file = directory.appendingPathComponent("a.bin")
        try Data("x".utf8).write(to: file)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("sub"), withIntermediateDirectories: true)
        let dotted = directory.appendingPathComponent("sub").appendingPathComponent("..").appendingPathComponent("a.bin")
        let symlink = directory.appendingPathComponent("sub").appendingPathComponent("link.bin")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: file)
        let hardLink = directory.appendingPathComponent("hard.bin")
        try FileManager.default.linkItem(at: file, to: hardLink)

        let fake = FakeReader()
        let items = OpenItems(reader: { request in try await fake.read(request) })
        let outcome = items.open(urls: [file, dotted, symlink, hardLink])
        await items.settled()
        XCTAssertEqual(items.items.count, 1, "`..`, a symlink and a hard link name the file again")
        XCTAssertEqual(outcome.opened.count, 1)
        XCTAssertEqual(outcome.alreadyOpen, [], "the other three spellings repeat the batch's own first file")
        let reads = await fake.requestedPaths.count
        XCTAssertEqual(reads, 1, "one file is read once")
    }

    /// Red under: `FileIdentity.isSameFile` comparing file names only.
    @MainActor func testTheSameNameInTwoFoldersIsTwoItems() async throws {
        let directory = try scratchDirectory()
        var files: [URL] = []
        for folder in ["one", "two"] {
            let sub = directory.appendingPathComponent(folder, isDirectory: true)
            try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
            let file = sub.appendingPathComponent("x.bin")
            try Data(folder.utf8).write(to: file)
            files.append(file)
        }
        let fake = FakeReader()
        let items = OpenItems(reader: { request in try await fake.read(request) })
        items.open(urls: files)
        await items.settled()
        XCTAssertEqual(items.items.map(\.url), files, "two files that share a name are two items")
    }

    /// Red under: `isSameFile` comparing resolved paths only (the file system's identifier ignored).
    func testTheFileSystemsIdentifierDecidesWhenBothSidesHaveOneElseThePath() {
        let x = ResourceIdentifier(NSNumber(value: 1)), y = ResourceIdentifier(NSNumber(value: 2))
        XCTAssertTrue(FileIdentity(path: "/v/a", resourceID: x).isSameFile(as: FileIdentity(path: "/v/b", resourceID: x)),
                      "a hard link: two paths, one identifier")
        XCTAssertFalse(FileIdentity(path: "/v/a", resourceID: x).isSameFile(as: FileIdentity(path: "/v/a", resourceID: y)),
                       "a file replaced under the same path is another file")
        XCTAssertTrue(FileIdentity(path: "/v/a").isSameFile(as: FileIdentity(path: "/v/a", resourceID: x)),
                      "one side unanswered: the path decides")
        XCTAssertFalse(FileIdentity(path: "/v/a").isSameFile(as: FileIdentity(path: "/v/b")))
    }

    // MARK: - Opening

    /// Red under: the batch selecting its last new item, not its first (`select(opened.last?.id ?? first.id)`).
    @MainActor func testABatchWithARepeatOpensEachFileOnceInOrderAndSelectsTheFirst() async throws {
        let fake = FakeReader()
        let items = makeItems(fake)
        let outcome = items.open(urls: [Self.a, Self.b, Self.a])
        XCTAssertEqual(items.items.map(\.url), [Self.a, Self.b], "a is named twice and opened once")
        XCTAssertEqual(items.selectedID, items.items[0].id, "the first file of the batch is selected at once")
        XCTAssertEqual(items.selected?.residency, .reading, "…while it is read")
        XCTAssertEqual(items.selected?.session.isLoading, true)
        XCTAssertEqual(outcome.opened, items.items.map(\.id))
        XCTAssertEqual(outcome.alreadyOpen, [], "a repeat inside the batch is not a file that was open before it")
        await items.settled()
        let order = await fake.requestedPaths
        XCTAssertEqual(order, [Self.a.path, Self.b.path], "read in the order given")
        XCTAssertEqual(items.items.map(\.residency), [.resident, .resident])
        XCTAssertEqual(items.selectedID, items.items[0].id)
    }

    /// Red under: the check for a file open already removed (`if let existing = Optional<OpenItem>.none`).
    @MainActor func testAFileAlreadyOpenIsSelectedNotReadAgain() async throws {
        let fake = FakeReader()
        let items = makeItems(fake)
        items.open(urls: [Self.a, Self.b])
        await items.settled()
        let a = try item(items, Self.a)
        items.select(items.items[1].id)
        let outcome = items.open(urls: [Self.a])
        await items.settled()
        XCTAssertEqual(items.items.count, 2, "a is not opened twice")
        XCTAssertEqual(items.selectedID, a.id, "…it is selected")
        XCTAssertEqual(outcome.opened, [])
        XCTAssertEqual(outcome.alreadyOpen, [a.id])
        let reads = await fake.requestedPaths.count
        XCTAssertEqual(reads, 2, "and not read again")
    }

    /// Red under: the batch selecting its first new item rather than its first file (`select(opened.first?.id ?? first.id)`).
    @MainActor func testTheFirstFileOfABatchIsSelectedWhetherNewOrOpenAlready() async throws {
        let fake = FakeReader()
        let items = makeItems(fake)
        items.open(urls: [Self.a, Self.b])
        await items.settled()
        let a = try item(items, Self.a)
        items.select(items.items[1].id)
        items.open(urls: [Self.c, Self.a])
        XCTAssertEqual(items.selectedID, try item(items, Self.c).id, "the new file named first")
        await items.settled()
        items.open(urls: [Self.a, Self.d])
        XCTAssertEqual(items.selectedID, a.id, "the open file named first, not the new one after it")
        await items.settled()
        XCTAssertEqual(items.items.map(\.url), [Self.a, Self.b, Self.c, Self.d])
    }

    /// Red under: a first read that fails keeps its item (`item.endRead(…)` in place of `remove(…)`).
    @MainActor func testAFailedFirstReadRemovesItsItemAndTellsTheApp() async throws {
        let fake = FakeReader()
        await fake.fail(Self.b)
        let items = makeItems(fake)
        let failures = Failures()
        items.onReadFailure = { url, error in
            failures.urls.append(url)
            failures.messages.append((error as? LocalizedError)?.errorDescription ?? "")
        }
        items.open(urls: [Self.a, Self.b])
        await items.settled()
        XCTAssertEqual(items.items.map(\.url), [Self.a], "the file that could not be opened is not left in the list")
        XCTAssertEqual(failures.urls, [Self.b])
        XCTAssertEqual(failures.messages, ["cannot read /data/b.dm4"])
    }

    /// Red under: the selection not returned to where it was (`selectionPreferred: nil`, so the neighbour rule picks b).
    @MainActor func testAFailedFirstReadReturnsTheSelectionToWhatWasSelectedBefore() async throws {
        let fake = FakeReader()
        let items = makeItems(fake)
        items.open(urls: [Self.a, Self.b])
        await items.settled()
        let a = try item(items, Self.a)
        XCTAssertEqual(items.selectedID, a.id)
        await fake.fail(Self.c)
        items.open(urls: [Self.c])
        XCTAssertEqual(items.selectedID, items.items.last?.id, "c is selected while it is read")
        await items.settled()
        XCTAssertEqual(items.items.map(\.url), [Self.a, Self.b])
        XCTAssertEqual(items.selectedID, a.id, "the old selection returns, not the neighbour b")
    }

    // MARK: - Closing, selecting, stepping

    /// Red under: the successor of a closed selected item always the first (`items.first` in `remove`).
    @MainActor func testClosingTheSelectedItemSelectsTheNextElseThePrevious() async throws {
        let fake = FakeReader()
        let items = makeItems(fake)
        items.open(urls: [Self.a, Self.b, Self.c, Self.d])
        await items.settled()
        let a = try item(items, Self.a), b = try item(items, Self.b), c = try item(items, Self.c), d = try item(items, Self.d)
        items.select(b.id)
        items.close(b.id)
        XCTAssertEqual(items.items.map(\.url), [Self.a, Self.c, Self.d])
        XCTAssertEqual(items.selectedID, c.id, "the next takes the closed one's place")
        items.select(d.id)
        items.close(d.id)
        XCTAssertEqual(items.selectedID, c.id, "the last closed: the previous")
        items.close(a.id)
        XCTAssertEqual(items.selectedID, c.id, "closing another item leaves the selection")
        items.close(c.id)
        XCTAssertNil(items.selectedID)
        XCTAssertEqual(items.items.count, 0)
    }

    /// Red under: stepping clamped at the ends (`min(max(current + delta, 0), items.count - 1)`) instead of wrapping.
    @MainActor func testPreviousAndNextWrapAround() async throws {
        let fake = FakeReader()
        let items = makeItems(fake)
        items.selectNext()
        items.selectPrevious()
        XCTAssertNil(items.selectedID, "nothing open, nothing to step to")
        items.open(urls: [Self.a, Self.b, Self.c])
        await items.settled()
        let ids = items.items.map(\.id)
        XCTAssertEqual(items.selectedID, ids[0])
        items.selectNext(); XCTAssertEqual(items.selectedID, ids[1])
        items.selectNext(); XCTAssertEqual(items.selectedID, ids[2])
        items.selectNext(); XCTAssertEqual(items.selectedID, ids[0], "after the last, the first")
        items.selectPrevious(); XCTAssertEqual(items.selectedID, ids[2], "before the first, the last")
        items.selectPrevious(); XCTAssertEqual(items.selectedID, ids[1])
        items.close(ids[0])
        items.close(ids[2])
        items.selectNext(); XCTAssertEqual(items.selectedID, ids[1], "one item: it stays")
        items.selectPrevious(); XCTAssertEqual(items.selectedID, ids[1])
    }

    /// Red under: one viewport for all items (`OpenItem.viewport` backed by a shared static).
    @MainActor func testEachItemKeepsItsOwnViewportAndColormapAcrossSelection() async throws {
        let fake = FakeReader()
        let items = makeItems(fake)
        items.open(urls: [Self.a, Self.b])   // the fake answers both with the same pixels
        await items.settled()
        let a = try item(items, Self.a), b = try item(items, Self.b)
        let zoomed = ImageViewport(zoom: 4, offset: CGSize(width: 10.5, height: -5.25))
        a.viewport = zoomed
        b.presentation.colormap = .viridis
        items.select(b.id)
        XCTAssertEqual(b.viewport, .initial, "b has not been zoomed")
        items.select(a.id)
        items.select(b.id)
        items.select(a.id)
        XCTAssertEqual(a.viewport, zoomed, "back on a, its zoom and pan are exactly what they were")
        XCTAssertEqual(a.presentation.colormap, .gray)
        XCTAssertEqual(b.presentation.colormap, .viridis)
        XCTAssertEqual(b.viewport, .initial)
    }

    /// What `List(selection:)` writes through. Red under: the setter assigning `selected` directly
    /// (`selected = items.first { $0.id == newValue }`): a write of nil then clears the selection, and a write of an id
    /// skips the budget check of `select` (c, the least recently selected, would stay warm).
    @MainActor func testTheSelectionBindingSelectsAndIgnoresNilAndUnknownIds() async throws {
        let fake = FakeReader()
        await fake.size(Self.b, 10, 10)
        await fake.size(Self.c, 10, 10)
        let items = makeItems(fake, budget: 12 * 12 + 8 * 100 * 2)   // 1744: a selected, b and c warm
        items.open(urls: [Self.a, Self.b, Self.c])
        await items.settled()
        let a = try item(items, Self.a), b = try item(items, Self.b), c = try item(items, Self.c)
        XCTAssertEqual(items.selection, a.id, "reads as the selected id")
        items.selection = b.id
        XCTAssertEqual(items.selectedID, b.id, "a write selects")
        XCTAssertTrue(items.selected === b)
        XCTAssertEqual(c.residency, .cold, "…through `select`: b's texture needs room, c is the least recently selected")
        items.selection = nil
        XCTAssertEqual(items.selectedID, b.id, "nil, the list asking for no selection, changes nothing")
        items.selection = UUID()
        XCTAssertEqual(items.selectedID, b.id, "an id that is not open changes nothing")
        items.selection = a.id
        XCTAssertEqual(items.selection, a.id)
    }

    /// "Close Others": the kept item stays, selected, and the others close; an id not open changes nothing. Red under:
    /// `closeOthers` without its guard (an id not open closes everything); the loop closing the kept item too.
    @MainActor func testCloseOthersKeepsTheOneItemSelectedAndClosesTheRest() async throws {
        let fake = FakeReader()
        let items = makeItems(fake)
        items.open(urls: [Self.a, Self.b, Self.c])
        await items.settled()
        let b = try item(items, Self.b)
        items.closeOthers(keeping: UUID())
        XCTAssertEqual(items.items.count, 3, "an id not open closes nothing")
        items.closeOthers(keeping: b.id)
        XCTAssertEqual(items.items.map(\.url), [Self.b])
        XCTAssertEqual(items.selectedID, b.id)
    }

    /// ⌘W. Red under: `closeSelected` closing the first item (`remove(items[0], …)`) instead of the selected one.
    @MainActor func testCloseSelectedClosesTheSelectedItemAndWithNoneOpenDoesNothing() async throws {
        let fake = FakeReader()
        let items = makeItems(fake)
        items.closeSelected()
        XCTAssertNil(items.selectedID, "nothing open, nothing to close")
        items.open(urls: [Self.a, Self.b, Self.c])
        await items.settled()
        let a = try item(items, Self.a), c = try item(items, Self.c)
        items.select(items.items[1].id)
        items.closeSelected()
        XCTAssertEqual(items.items.map(\.url), [Self.a, Self.c], "the selected b closed, not the first")
        XCTAssertEqual(items.selectedID, c.id, "the next takes its place")
        items.closeSelected()
        XCTAssertEqual(items.items.map(\.url), [Self.a])
        XCTAssertEqual(items.selectedID, a.id, "the last closed: the previous")
        items.closeSelected()
        XCTAssertEqual(items.items.count, 0)
        XCTAssertNil(items.selectedID)
        items.closeSelected()
        XCTAssertEqual(items.items.count, 0)
    }

    // MARK: - Memory

    /// Red under: the estimate counting the pixels only (`warmBytesPerPixel` and `selectedBytesPerPixel` both 4).
    func testResidentBytesAre8WHWarmAnd12WHSelected() {
        XCTAssertEqual(ResidentBytes.estimate(width: 4096, height: 4096, isSelected: false), 128 << 20, "128 MiB warm")
        XCTAssertEqual(ResidentBytes.estimate(width: 4096, height: 4096, isSelected: true), 192 << 20, "192 MiB selected")
        XCTAssertEqual(ResidentBytes.estimate(width: 5760, height: 4092, isSelected: false), 8 * 5760 * 4092)
    }

    /// Red under: an item that holds nothing counted as warm (`guard residency != .reading` in `residentBytes`).
    @MainActor func testAnItemHoldsTwelveWHSelectedEightWHWarmAndNothingCold() async throws {
        let fake = FakeReader()
        await fake.size(Self.b, 5, 2)
        let items = makeItems(fake)
        items.open(urls: [Self.a, Self.b])
        XCTAssertEqual(items.residentBytes, 0, "nothing is held while the first reads run")
        await items.settled()
        XCTAssertEqual(items.residentBytes, 12 * 12 + 8 * 10, "a (4 × 3) selected, b (5 × 2) warm")
        items.select(items.items[1].id)
        XCTAssertEqual(items.residentBytes, 8 * 12 + 12 * 10, "the selected one costs the texture too")

        let fake2 = FakeReader()
        let (items2, _, b, _) = try await threeWithBCold(fake2)
        XCTAssertEqual(b.residentBytes(isSelected: false), 0)
        XCTAssertEqual(items2.residentBytes, 12 * 12 + 8 * 12, "a selected and c warm; the cold b holds nothing")
    }

    /// Red under: the provisional budget changed from a quarter of physical memory.
    @MainActor func testTheProvisionalBudgetIsAQuarterOfPhysicalMemory() {
        let items = OpenItems(reader: { request in throw ReadFailure(path: request.url.path) })
        XCTAssertEqual(items.budgetBytes, Int(ProcessInfo.processInfo.physicalMemory / 4))
    }

    private static func candidate(_ n: Int, bytes: Int = 100, last: Int, selected: Bool = false, bookmark: Bool = true) -> EvictionCandidate {
        EvictionCandidate(id: UUID(uuidString: "00000000-0000-0000-0000-00000000000\(n)")!, bytes: bytes, lastSelected: last,
                          isSelected: selected, hasBookmark: bookmark)
    }

    /// Red under: the most recently selected first (the sort reversed); and under: an item that holds nothing listed
    /// (`bytes > 0` dropped from the filter), since the cold, oldest candidate would come first.
    func testEvictionTakesTheLeastRecentlyUsedFirstAndStopsWithinBudget() {
        let cold = Self.candidate(0, bytes: 0, last: 0)
        let oldest = Self.candidate(1, last: 1), middle = Self.candidate(3, last: 3), newest = Self.candidate(5, last: 5)
        let selected = Self.candidate(9, last: 9, selected: true)
        let all = [newest, cold, selected, oldest, middle]   // 400 held
        XCTAssertEqual(EvictionPolicy.evictions(all, budget: 250), [oldest.id, middle.id], "the oldest, then the next, until 200 ≤ 250")
        XCTAssertEqual(EvictionPolicy.evictions(all, budget: 350), [oldest.id], "one is enough")
        XCTAssertEqual(EvictionPolicy.evictions(all, budget: 400), [], "within budget: nothing")
        XCTAssertEqual(EvictionPolicy.evictions(all, budget: 0), [oldest.id, middle.id, newest.id], "everything that may go")
    }

    /// Red under: the selected item allowed to go (`!candidates[$0].isSelected` dropped from the filter).
    func testEvictionNeverTakesTheSelectedItem() {
        let selected = Self.candidate(1, bytes: 500, last: 0, selected: true)   // the oldest, and the biggest
        let other = Self.candidate(2, last: 7)
        XCTAssertEqual(EvictionPolicy.evictions([selected, other], budget: 10), [other.id],
                       "the selected item stays although it is oldest and the total stays over the budget")
    }

    /// Red under: an item without a bookmark allowed to go (`hasBookmark` dropped from the filter).
    func testEvictionNeverTakesAnItemWithoutABookmark() {
        let unreadable = Self.candidate(1, last: 0, bookmark: false)   // the oldest
        let other = Self.candidate(2, last: 7)
        XCTAssertEqual(EvictionPolicy.evictions([unreadable, other], budget: 10), [other.id],
                       "its pixels are the only copy")
    }

    /// Red under: the item forgetting its viewport as it goes cold (`viewport = .initial` in `goCold`), its colormap or
    /// its window, gamma or scale bar (a line of `keepSettings(of:)` removed), its pixels staying (the `session = ImageSession()` swap
    /// removed), or a new budget evicting nothing (`didSet` of `budgetBytes` emptied).
    @MainActor func testTheLeastRecentlySelectedItemGoesColdAndKeepsWhatIsTheUsers() async throws {
        let fake = FakeReader()
        let (items, a, b, c) = try await threeWithBCold(fake)
        XCTAssertNil(b.session.image, "the pixels are released")
        XCTAssertNil(b.presentation.canvas, "…and the display copy")
        XCTAssertFalse(b.session.isLoading)
        XCTAssertEqual(b.viewport, ImageViewport(zoom: 3, offset: CGSize(width: 7, height: -8)))
        XCTAssertEqual(b.presentation.colormap, .inferno)
        XCTAssertEqual(b.presentation.windowLow, 3, "the contrast window too (V1-4)")
        XCTAssertEqual(b.presentation.windowHigh, 9.5)
        XCTAssertEqual(b.presentation.gamma, 0.5)
        XCTAssertFalse(b.presentation.showsScaleBar)
        XCTAssertEqual(b.summary?.width, 4, "the row still knows its size")
        XCTAssertEqual(b.summary?.fileName, "b.dm4")
        XCTAssertNotNil(b.bookmark)
        XCTAssertEqual(items.items.count, 3, "cold is not closed")
        XCTAssertNotNil(a.session.image)
        XCTAssertNotNil(c.presentation.canvas)
        XCTAssertEqual(items.selectedID, a.id)
    }

    /// Red under: `evictToBudget()` removed from `select`.
    @MainActor func testSelectingAnItemChecksTheBudgetAgain() async throws {
        let fake = FakeReader()
        await fake.size(Self.b, 10, 10)
        await fake.size(Self.c, 10, 10)
        // a (12 px) selected + b and c (100 px) warm: 144 + 800 + 800 = 1744, exactly the budget.
        let items = makeItems(fake, budget: 12 * 12 + 8 * 100 * 2)
        items.open(urls: [Self.a, Self.b, Self.c])
        await items.settled()
        let a = try item(items, Self.a), b = try item(items, Self.b), c = try item(items, Self.c)
        XCTAssertEqual([a.residency, b.residency, c.residency], [.resident, .resident, .resident], "setup: within budget")
        items.select(b.id)   // b now costs 1200: 96 + 1200 + 800 = 2096
        XCTAssertEqual(c.residency, .cold, "c, the least recently selected, made room")
        XCTAssertEqual([a.residency, b.residency], [.resident, .resident])
    }

    /// Red under: `evictToBudget()` removed from `remove`: the item that takes the closed one's place now costs its texture.
    @MainActor func testClosingTheSelectedItemChecksTheBudgetForTheNewSelection() async throws {
        let fake = FakeReader()
        await fake.size(Self.b, 10, 10)
        await fake.size(Self.c, 10, 10)
        let items = makeItems(fake, budget: 12 * 12 + 8 * 100 * 2)   // 1744: a selected, b and c warm
        items.open(urls: [Self.a, Self.b, Self.c])
        await items.settled()
        let a = try item(items, Self.a), b = try item(items, Self.b), c = try item(items, Self.c)
        items.close(a.id)   // b is selected: 1200 + 800 = 2000
        XCTAssertEqual(items.selectedID, b.id)
        XCTAssertEqual(c.residency, .cold, "c made room for b's texture")
        XCTAssertEqual(b.residency, .resident)
    }

    /// The fixture `noBookmark` made: an item whose read made no bookmark has its pixels as the only copy.
    /// Red under: `hasBookmark: true` in the candidates of `evictToBudget` (the item's bookmark not consulted): b, the
    /// least recently selected, then goes cold.
    @MainActor func testAnItemWithoutABookmarkIsNeverSentColdWhateverItsAge() async throws {
        let fake = FakeReader()
        await fake.noBookmark(Self.b)
        let items = makeItems(fake)
        items.open(urls: [Self.a, Self.b, Self.c])
        await items.settled()
        let b = try item(items, Self.b), c = try item(items, Self.c)
        XCTAssertNil(b.bookmark, "setup: no bookmark could be made")
        XCTAssertNotNil(c.bookmark, "setup")
        items.budgetBytes = 250   // 144 + 96 + 96 held: one warm item must go, and b is the older
        XCTAssertEqual(b.residency, .resident, "b is not evicted: nothing could read it again")
        XCTAssertEqual(c.residency, .cold, "c goes in its place")
        XCTAssertEqual(items.items.map(\.url), [Self.a, Self.b, Self.c])
    }

    /// Red under: `session = ImageSession()` and `presentation = ImagePresentation()` removed from `goCold` (the item
    /// keeps the objects that hold the pixels): they stay alive.
    @MainActor func testEvictionFreesTheSessionAndThePresentationThatHeldThePixels() async throws {
        let fake = FakeReader()
        let items = makeItems(fake)
        items.open(urls: [Self.a, Self.b, Self.c])
        await items.settled()
        let b = try item(items, Self.b)
        weak let oldSession = b.session
        weak let oldPresentation = b.presentation
        XCTAssertNotNil(oldSession, "setup: b's own session holds its pixels")
        XCTAssertNotNil(oldPresentation, "setup")
        XCTAssertNotNil(b.presentation.canvas, "setup")
        items.budgetBytes = 250
        XCTAssertEqual(b.residency, .cold, "setup: the least recently selected went")
        XCTAssertNil(oldSession, "the session that held the pixels is freed, not only emptied")
        XCTAssertNil(oldPresentation, "…and the presentation that held the display copy")
        XCTAssertNil(b.session.image, "the item has fresh, empty ones")
        XCTAssertNil(b.presentation.canvas)
    }

    // MARK: - Thumbnail

    /// The 96-pixel box is the app's cap on ImagoKit's `Thumbnail.init?(…maxSide:)`; the kit pins the guard, this pins the
    /// number the app passes. Red under: `defaultMaxSide` changed.
    func testAThumbnailIsInsideTheBoxAndHasOneValuePerPixel() {
        XCTAssertEqual(Thumbnail.defaultMaxSide, 96)
        let ok = Thumbnail(width: 96, height: 12, normalized: [Float](repeating: 0.5, count: 96 * 12), maxSide: 96)
        XCTAssertEqual(ok?.width, 96, "96 on the longer side is the most")
        XCTAssertEqual(ok?.height, 12)
        XCTAssertNotNil(Thumbnail(width: 1, height: 96, normalized: [Float](repeating: 0, count: 96), maxSide: 96))
        XCTAssertNil(Thumbnail(width: 97, height: 1, normalized: [Float](repeating: 0, count: 97), maxSide: 96), "wider than the box")
        XCTAssertNil(Thumbnail(width: 1, height: 97, normalized: [Float](repeating: 0, count: 97), maxSide: 96), "taller than the box")
        XCTAssertNil(Thumbnail(width: 0, height: 4, normalized: [], maxSide: 96), "no pixels")
        XCTAssertNil(Thumbnail(width: 4, height: 0, normalized: [], maxSide: 96), "no pixels")
        XCTAssertNil(Thumbnail(width: 2, height: 2, normalized: [0, 0, 0], maxSide: 96), "three values for four pixels")
        XCTAssertNil(Thumbnail(width: 2, height: 2, normalized: [0, 0, 0, 0, 0], maxSide: 96), "five values for four pixels")
    }

    /// The row keeps its picture when the pixels go. Red under: the summary built without the answer's thumbnail
    /// (`ImageSummary(opened.image, thumbnail: nil)` in `publish`), or the cold item's summary dropped (`summary = nil`
    /// in `goCold`); and, for the re-read, under the old picture kept over the new (`thumbnail: summary?.thumbnail ??
    /// opened.thumbnail`).
    @MainActor func testTheThumbnailTheReaderMadeStaysWithItsItemThroughEvictionAndTheReReadReplacesIt() async throws {
        let fake = FakeReader()
        let (items, a, b, _) = try await threeWithBCold(fake)
        XCTAssertEqual(a.summary?.thumbnail, FakeReader.thumbnail(read: 1), "the resident item's row")
        XCTAssertEqual(b.residency, .cold)
        XCTAssertEqual(b.summary?.thumbnail, FakeReader.thumbnail(read: 1), "the cold item's row keeps its picture")
        items.select(b.id)
        items.restoreSelected()
        XCTAssertEqual(b.summary?.thumbnail, FakeReader.thumbnail(read: 1), "…while it is read again")
        await items.settled()
        XCTAssertEqual(b.summary?.thumbnail, FakeReader.thumbnail(read: 2), "the picture of the new read replaces it")
    }

    // MARK: - Re-reading a cold item

    /// Red under: the re-read ignoring the bookmark (`bookmark: nil` in the request), the answer's new bookmark not kept
    /// (the `if let renewed` line removed), or the read that fills the budget not evicting (`evictToBudget()` removed
    /// from `finishRead`).
    @MainActor func testSelectingAColdItemReadsItAgainThroughItsBookmarkAndKeepsItsViewport() async throws {
        let fake = FakeReader()
        let (items, a, b, c) = try await threeWithBCold(fake)
        let firstBookmark = try XCTUnwrap(b.bookmark)
        items.select(b.id)
        XCTAssertEqual(b.residency, .cold, "selecting alone reads nothing: the caller waits for the selection to rest")
        items.restoreSelected()
        XCTAssertEqual(b.residency, .reading)
        XCTAssertTrue(b.session.isLoading)
        await items.settled()
        XCTAssertEqual(b.residency, .resident)
        XCTAssertEqual(b.session.image?.pixels.first, 2, "the second read's pixels")
        XCTAssertNotNil(b.presentation.canvas)
        XCTAssertEqual(b.viewport, ImageViewport(zoom: 3, offset: CGSize(width: 7, height: -8)), "zoom and pan intact")
        XCTAssertEqual(b.presentation.colormap, .inferno)
        let requests = await fake.requests
        let first = try XCTUnwrap(requests.first)
        XCTAssertNil(first.bookmark, "a file's first read is by the URL the sandbox just granted")
        let again = try XCTUnwrap(requests.last)
        XCTAssertEqual(again.url, Self.b)
        XCTAssertEqual(again.bookmark, firstBookmark, "the re-read goes through the item's bookmark")
        XCTAssertEqual(b.bookmark, Data("bookmark:/data/b.dm4:2".utf8), "the bookmark the re-read made replaces the old one")
        XCTAssertEqual(a.residency, .resident)
        XCTAssertEqual(c.residency, .cold, "b is selected again, 336 over 250: the least recently selected of the others went")
    }

    /// Red under: an evicted item's failed re-read removing it (`if item.hasBeenRead` replaced by `if false`).
    @MainActor func testAFailedRereadKeepsTheItemColdAndSaysWhy() async throws {
        let fake = FakeReader()
        let (items, _, b, _) = try await threeWithBCold(fake)
        let failures = Failures()
        items.onReadFailure = { url, _ in failures.urls.append(url) }
        await fake.fail(Self.b)
        items.select(b.id)
        items.restoreSelected()
        await items.settled()
        XCTAssertEqual(items.items.count, 3, "the file may come back: the item stays")
        XCTAssertEqual(b.residency, .cold)
        XCTAssertEqual(b.readFailure, "cannot read /data/b.dm4")
        XCTAssertFalse(b.session.isLoading)
        XCTAssertEqual(items.selectedID, b.id, "and stays selected")
        XCTAssertEqual(failures.urls, [Self.b])
        await fake.fail(Self.b, false)
        items.restoreSelected()
        await items.settled()
        XCTAssertEqual(b.residency, .resident, "asking again reads it")
        XCTAssertNil(b.readFailure)
    }

    /// Red under: `restoreSelected()` removed from `open`, so opening a file that is open, selected and cold does nothing.
    @MainActor func testOpeningTheSelectedColdFileAgainReadsItAgain() async throws {
        let fake = FakeReader()
        let (items, _, b, _) = try await threeWithBCold(fake)
        items.select(b.id)
        let outcome = items.open(urls: [Self.b])
        XCTAssertEqual(outcome.alreadyOpen, [b.id])
        XCTAssertEqual(b.residency, .reading, "the user asked for the file: no waiting for the selection to rest")
        await items.settled()
        XCTAssertEqual(b.residency, .resident)
        XCTAssertEqual(items.items.count, 3)
    }

    /// The bookmark resolved to another path: the file moved since it was opened. Red under: the item not following the
    /// file (the `if let movedTo { url = …; fileIdentity = … }` block removed from `publish`, or `url: url` back in its
    /// `finishOpen`): opening the file at its new path then makes a second item and reads it again.
    @MainActor func testAFileTheBookmarkFoundMovedIsTheSameItemAtItsNewPath() async throws {
        let fake = FakeReader()
        let (items, _, b, _) = try await threeWithBCold(fake)
        let moved = URL(fileURLWithPath: "/elsewhere/b.dm4")
        await fake.relocate(Self.b, to: moved)
        items.select(b.id)
        items.restoreSelected()
        await items.settled()
        XCTAssertEqual(b.residency, .resident)
        XCTAssertEqual(b.url, moved, "the item follows the file")
        XCTAssertEqual(b.session.url, moved, "…and so does the session that shows it")
        let readsBefore = await fake.requests.count
        let outcome = items.open(urls: [moved])
        XCTAssertEqual(outcome.opened, [], "the file at its new path is not a new file")
        XCTAssertEqual(outcome.alreadyOpen, [b.id])
        XCTAssertEqual(items.items.count, 3)
        XCTAssertEqual(items.selectedID, b.id)
        await items.settled()
        let readsAfter = await fake.requests.count
        XCTAssertEqual(readsAfter, readsBefore, "and it is not read again")
    }

    /// The reader here never checks its cancellation (`ignoreCancellation`), so its answer does come, late: the list
    /// must drop it itself.
    /// Red under: the selection leaving a re-read not dropping it (the guard of `dropRereadOfSelected` made to always
    /// return), or `readGeneration &+= 1` removed from `cancelRead`: the late answer then fills the item.
    @MainActor func testAReReadTheSelectionLeftIsDroppedAndNeverSelectsItsItem() async throws {
        let fake = FakeReader()
        let (items, a, b, _) = try await threeWithBCold(fake)
        await fake.hold(Self.b)
        await fake.ignoreCancellation(Self.b)
        items.select(b.id)
        items.restoreSelected()
        try await waitUntilHeld(fake, Self.b)
        XCTAssertTrue(b.session.isLoading)
        items.select(a.id)
        XCTAssertEqual(b.residency, .cold, "nobody is waiting for b any more")
        XCTAssertFalse(b.session.isLoading)
        await fake.release(Self.b)
        await items.settled()
        XCTAssertEqual(b.residency, .cold, "the late answer is dropped")
        XCTAssertNil(b.session.image)
        XCTAssertEqual(items.selectedID, a.id, "and did not take the selection")
    }

    /// Red under: a finished read selecting its item (`select(item.id)` in `finishRead`).
    @MainActor func testNoReadMovesTheSelection() async throws {
        let fake = FakeReader()
        await fake.hold(Self.c)
        let items = makeItems(fake)
        items.open(urls: [Self.a, Self.b, Self.c])
        try await waitUntilHeld(fake, Self.c)   // a and b have been read; c is waiting at its gate
        let b = try item(items, Self.b)
        items.select(b.id)
        await fake.release(Self.c)
        await items.settled()
        XCTAssertEqual(items.selectedID, b.id, "c finishing after the user chose b does not take the selection")
        XCTAssertEqual(items.items.map(\.residency), [.resident, .resident, .resident], "and its answer is published")
    }

    /// Red under: a first read dropped when the selection leaves its item (`leaving.hasBeenRead` removed from the guard of
    /// `dropRereadOfSelected`): the file the user just opened would stay cold, with no bookmark and no summary.
    @MainActor func testLeavingAFileBeforeItsFirstReadEndsDoesNotDropTheRead() async throws {
        let fake = FakeReader()
        let items = makeItems(fake)
        items.open(urls: [Self.a, Self.b])
        let a = try item(items, Self.a), b = try item(items, Self.b)
        items.select(b.id)   // the user clicks b while a is still being read
        await items.settled()
        XCTAssertEqual(a.residency, .resident, "a is still read: it is the user's file, only a re-read is dropped")
        XCTAssertNotNil(a.bookmark)
        XCTAssertEqual(items.selectedID, b.id)
    }

    /// The reader here never checks its cancellation, so its answer does come, late: the list must drop it itself.
    /// Red under: closing an item not cancelling its read (`item.cancelRead()` removed from `remove`), or
    /// `readGeneration &+= 1` removed from `cancelRead`: the answer then fills an item no list holds.
    @MainActor func testClosingAnItemWhileItIsReadDropsItsAnswer() async throws {
        let fake = FakeReader()
        await fake.hold(Self.b)
        await fake.ignoreCancellation(Self.b)
        let items = makeItems(fake)
        items.open(urls: [Self.a, Self.b])
        try await waitUntilHeld(fake, Self.b)
        let b = try item(items, Self.b)
        items.close(b.id)
        await fake.release(Self.b)
        await items.settled()
        XCTAssertEqual(items.items.map(\.url), [Self.a])
        XCTAssertNil(b.session.image, "a closed item is not filled by a late read")
    }

    // MARK: - Cancellation

    /// A reader that checks its cancellation (the fake does, at its gate) ends at once, and the queue behind it moves on
    /// without waiting for a release. Red under: closing an item not cancelling its read (`item.cancelRead()` removed
    /// from `remove`, or `readTask?.cancel()` from `cancelRead`): the reader is never told, and c is not read while b's
    /// read is held.
    @MainActor func testClosingAnItemWhileItIsReadCancelsItsReadAndTheQueueMovesOn() async throws {
        let fake = FakeReader()
        await fake.hold(Self.b)
        let items = makeItems(fake)
        items.open(urls: [Self.a, Self.b, Self.c])
        try await waitUntilHeld(fake, Self.b)
        let b = try item(items, Self.b)
        items.close(b.id)
        let cancelled = await fake.untilCancelled(Self.b)
        XCTAssertTrue(cancelled, "the reader of the closed file is told to stop")
        let cRead = await fake.untilRequested(Self.c)
        XCTAssertTrue(cRead, "c is read although b was never released: the queue did not wait for b")
        await fake.release(Self.b)   // only needed when the checks above failed: lets the queue end
        await items.settled()
        XCTAssertEqual(items.items.map(\.url), [Self.a, Self.c])
        XCTAssertEqual(items.items.map(\.residency), [.resident, .resident])
        XCTAssertNil(b.session.image)
    }

    /// Red under: the selection leaving a re-read not cancelling it (`leaving.cancelRead()` removed from
    /// `dropRereadOfSelected`): the reader is never told, and d is not read while b's re-read is held.
    @MainActor func testALeftRereadIsCancelledAndTheQueueMovesOn() async throws {
        let fake = FakeReader()
        let (items, _, b, _) = try await threeWithBCold(fake)
        await fake.hold(Self.b)
        items.select(b.id)
        items.restoreSelected()
        try await waitUntilHeld(fake, Self.b)
        let outcome = items.open(urls: [Self.d])   // d is selected: nobody is waiting for b's pixels any more
        XCTAssertEqual(outcome.opened.count, 1)
        let cancelled = await fake.untilCancelled(Self.b)
        XCTAssertTrue(cancelled, "the reader of the re-read the selection left is told to stop")
        let dRead = await fake.untilRequested(Self.d)
        XCTAssertTrue(dRead, "d is read although b was never released")
        await fake.release(Self.b)   // only needed when the checks above failed
        await items.settled()
        XCTAssertEqual(b.residency, .cold)
        XCTAssertNil(b.session.image)
        XCTAssertNil(b.readFailure, "a read dropped is nobody's news")
        XCTAssertEqual(try item(items, Self.d).residency, .resident)
        XCTAssertEqual(items.selectedID, try item(items, Self.d).id)
    }

    // MARK: - Read order

    /// Red under: each queued file getting its own worker (`worker = Task { … }` without the `worker == nil` check): b
    /// then starts while a is held.
    @MainActor func testReadsRunOneAtATimeInTheOrderAsked() async throws {
        let fake = FakeReader()
        await fake.hold(Self.a)
        let items = makeItems(fake)
        items.open(urls: [Self.a, Self.b, Self.c])
        try await waitUntilHeld(fake, Self.a)
        for _ in 0..<50 { await Task.yield() }
        let whileHeld = await fake.requestedPaths
        XCTAssertEqual(whileHeld, [Self.a.path], "b and c wait for a")
        await fake.release(Self.a)
        await items.settled()
        let order = await fake.requestedPaths
        XCTAssertEqual(order, [Self.a.path, Self.b.path, Self.c.path])
        let most = await fake.maxInFlight
        XCTAssertEqual(most, 1, "a batch's transient peak is one read")
    }

    /// Red under: the re-read of the selected item queued behind the others (`atFront: false` in `restoreSelected`).
    @MainActor func testTheRereadOfTheSelectedItemGoesAheadOfTheFilesStillWaiting() async throws {
        let fake = FakeReader()
        let (items, _, b, _) = try await threeWithBCold(fake)
        await fake.hold(Self.d)
        items.open(urls: [Self.d, Self.e])
        try await waitUntilHeld(fake, Self.d)   // d is being read; e waits
        items.select(b.id)
        items.restoreSelected()
        await fake.release(Self.d)
        await items.settled()
        let order = await fake.requestedPaths
        XCTAssertEqual(Array(order.suffix(3)), [Self.d.path, Self.b.path, Self.e.path], "b, which the user is waiting for, before e")
    }

    /// A file of a batch the user picks before its turn is read next. Red under: `restoreSelected` handling only the
    /// cold item (its `.reading` case removed): c then stays behind b.
    @MainActor func testASelectedFileStillWaitingForItsFirstReadIsReadNext() async throws {
        let fake = FakeReader()
        await fake.hold(Self.a)
        let items = makeItems(fake)
        items.open(urls: [Self.a, Self.b, Self.c])
        try await waitUntilHeld(fake, Self.a)   // a is being read; b and c wait
        let c = try item(items, Self.c)
        items.select(c.id)
        items.restoreSelected()
        XCTAssertEqual(c.residency, .reading, "still waiting for its turn")
        await fake.release(Self.a)
        await items.settled()
        let order = await fake.requestedPaths
        XCTAssertEqual(order, [Self.a.path, Self.c.path, Self.b.path], "c, which the user chose, before b, which nobody waits for")
        XCTAssertEqual(items.items.map(\.residency), [.resident, .resident, .resident])
        XCTAssertEqual(items.selectedID, c.id)
    }

    /// Asking for the selected file whose read is already running starts no second read of it. Red under: the
    /// `.reading` case of `restoreSelected` calling `enqueue(item, atFront: true)` (a second `beginReading`): the
    /// running read is superseded and a is read twice.
    @MainActor func testRestoringTheSelectedFileWhoseReadIsRunningStartsNoSecondRead() async throws {
        let fake = FakeReader()
        await fake.hold(Self.a)
        let items = makeItems(fake)
        items.open(urls: [Self.a, Self.b])
        try await waitUntilHeld(fake, Self.a)   // a is selected and being read; b waits
        items.restoreSelected()
        items.restoreSelected()
        await fake.release(Self.a)
        await items.settled()
        let order = await fake.requestedPaths
        XCTAssertEqual(order, [Self.a.path, Self.b.path], "each file is read once")
        XCTAssertEqual(items.items.map(\.residency), [.resident, .resident])
    }

    // MARK: - Observation

    /// Whether anything `access` read changes under `change` (the one-shot form of `withObservationTracking`).
    @MainActor private func isTold(by change: () -> Void, of access: () -> Void) -> Bool {
        let told = Flag()
        withObservationTracking(access, onChange: { told.raise() })
        change()
        return told.isRaised
    }

    /// A view that reads the selected item is told when the selection moves, not when another file is opened or
    /// closed. Red under: `selected` looked up in `items` (a computed `selectedID.flatMap(item(_:))`) instead of
    /// stored: the append and the removal change `items`, which it then depends on.
    @MainActor func testOpeningOrClosingAnotherFileDoesNotTellAReaderOfTheSelectedItem() async throws {
        let fake = FakeReader()
        let items = makeItems(fake)
        items.open(urls: [Self.a, Self.b])
        await items.settled()
        let a = try item(items, Self.a), b = try item(items, Self.b)
        XCTAssertEqual(items.selectedID, a.id, "setup")
        let readSelection = { _ = items.selected; _ = items.selectedID; _ = items.selection }

        XCTAssertFalse(isTold(by: { items.open(urls: [Self.a, Self.c]) }, of: readSelection),
                       "c opened while a stays selected")
        await items.settled()
        let c = try item(items, Self.c)
        XCTAssertFalse(isTold(by: { items.close(c.id) }, of: readSelection), "an unselected item closed")
        XCTAssertFalse(isTold(by: { items.close(b.id) }, of: readSelection), "another unselected item closed")
        XCTAssertEqual(items.items.map(\.url), [Self.a])
        XCTAssertTrue(isTold(by: { items.open(urls: [Self.d]) }, of: readSelection),
                      "control: the selection moving to the new file is news")
        await items.settled()
        XCTAssertEqual(items.selectedID, try item(items, Self.d).id)
    }

    /// A renewed bookmark is opaque data no view shows. Red under: `@ObservationIgnored` removed from
    /// `OpenItem.bookmark`.
    @MainActor func testARenewedBookmarkIsNotNewsToAReader() async throws {
        let fake = FakeReader()
        let (items, _, b, _) = try await threeWithBCold(fake)
        items.select(b.id)
        let before = try XCTUnwrap(b.bookmark)
        let bookmarkTold = Flag(), residencyTold = Flag()
        withObservationTracking({ _ = b.bookmark }, onChange: { bookmarkTold.raise() })
        withObservationTracking({ _ = b.residency }, onChange: { residencyTold.raise() })
        items.restoreSelected()
        await items.settled()
        XCTAssertNotEqual(b.bookmark, before, "setup: the re-read made a new bookmark")
        XCTAssertTrue(residencyTold.isRaised, "control: what is shown (the residency) is observed")
        XCTAssertFalse(bookmarkTold.isRaised, "the bookmark is not")
    }
}
