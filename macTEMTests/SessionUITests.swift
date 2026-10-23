//
//  SessionUITests.swift
//  The app's side of the session sidecar (archive: roadmap-registrations-2026-10-15.md V1-2 slice B, the UI slice; archive: v12-session-ui-design-2026-10-14.md):
//  what the sidecar beside a file made of its first read (`SessionOpening.outcome`: none, restored, refused, needs access),
//  how `OpenItems` acts on it — the first read restores, a re-read never does, a read that was closed under it adopts
//  nothing, a re-read of other pixels notes the difference —, `SessionSaving` (the first save to a chosen URL, a later one,
//  a file changed by another app, a lost grant, `canSave`'s reasons, the alert's words, the panel's rule), and every sentence
//  of the Measure tail (`SessionFormat`). Every `Red under:` names the change to the production code that turns the test red.
//

import ImagoCore
import XCTest
import Foundation
import FormatoCore
import TEMCore
import TEMSession
@testable import macTEM

nonisolated final class SessionUITests: XCTestCase {

    // MARK: - Fixtures

    nonisolated private static func image(shift: Int = 0, fileName: String = "scan.dm4", source: String = "ImageList.1") -> CalibratedImage {
        let width = 40, height = 24
        return CalibratedImage(width: width, height: height,
                               pixels: (0..<width * height).map { Float(($0 * 37 + ($0 / width) * 11 + shift * 31) % 97) },
                               x: AxisCalibration(scale: 0.5, unit: "nm", origin: 0), y: AxisCalibration(scale: 2.0, unit: "nm", origin: 0),
                               fileName: fileName, source: source, voltage: nil)
    }

    nonisolated private static func identity(_ image: CalibratedImage) -> SessionSourceIdentity {
        SessionSourceIdentity.of(image, fileByteSize: 4096)
    }

    private func scratch() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionUITests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func marks(_ count: Int) -> [ImageMark] {
        (0..<count).map { i in
            ImageMark(kind: .distance, points: [ImagePoint(x: 2 + Double(i), y: 3), ImagePoint(x: 20, y: 10 + Double(i))])
        }
    }

    /// Writes a sidecar for `count` marks drawn on `image`, beside `source`, and returns its URL.
    @MainActor @discardableResult
    private func plantSidecar(beside source: URL, marks count: Int, image: CalibratedImage = SessionUITests.image()) throws -> URL {
        let owner = ImageMeasurements()
        owner.noteOpened(Self.identity(image))
        for mark in marks(count) { owner.add(mark, on: image) }
        let request = try owner.saveRequest(opened: Self.identity(image))
        let url = try SessionSidecarFile.sidecarURL(forSource: source)
        try? FileManager.default.removeItem(at: url)
        try SessionSave.write(request, to: url)
        return url
    }

    /// A reader that answers every read with `image(shift:)` and the scripted sidecar outcome; a read can be held.
    actor Reader {
        private var outcomes: [SidecarOutcome] = []
        private var shifts: [Int] = []
        private var holdFirst = false
        private var gate: CheckedContinuation<Void, Never>?
        private(set) var reads = 0

        func script(outcomes: [SidecarOutcome], shifts: [Int] = []) { self.outcomes = outcomes; self.shifts = shifts }
        func hold() { holdFirst = true }
        func release() { gate?.resume(); gate = nil }
        func untilHeld() async -> Bool {
            for _ in 0..<400 { if gate != nil { return true }; try? await Task.sleep(for: .milliseconds(5)) }
            return false
        }

        func read(_ request: ReadRequest) async throws -> OpenedImage {
            reads += 1
            let n = reads - 1
            if holdFirst && n == 0 { await withCheckedContinuation { gate = $0 } }
            let image = SessionUITests.image(shift: n < shifts.count ? shifts[n] : 0)
            let canvas = CanvasPixels(width: image.width, height: image.height,
                                      normalized: [Float](repeating: 0, count: image.width * image.height),
                                      contentVersion: reads, rawRange: nil)
            return OpenedImage(image: image, canvas: canvas, metadata: AcquisitionMetadata(), url: request.url,
                               thumbnail: nil, bookmark: Data("b\(reads)".utf8),
                               identity: SessionUITests.identity(image),
                               sidecar: n < outcomes.count ? outcomes[n] : .none)
        }
    }

    @MainActor private func makeItems(_ reader: Reader, budget: Int = .max) -> OpenItems {
        OpenItems(budgetBytes: budget, identify: { FileIdentity(path: $0.path) }, reader: { try await reader.read($0) })
    }

    /// The outcome the real function gives for a sidecar planted with `count` marks.
    @MainActor private func restoredOutcome(in directory: URL, marks count: Int, source: URL) throws -> SidecarOutcome {
        try plantSidecar(beside: source, marks: count)
        let image = Self.image()
        return SessionOpening.outcome(source: source, sidecar: nil, opened: Self.identity(image), image: image)
    }

    /// One file read and resident, with the scripted outcomes.
    @MainActor private func openedItem(_ reader: Reader, _ source: URL, budget: Int = .max) async throws -> (OpenItems, OpenItem) {
        let items = makeItems(reader, budget: budget)
        items.open(urls: [source])
        await items.settled()
        return (items, try XCTUnwrap(items.items.first))
    }

    // MARK: - What the sidecar made of a read

    /// Red under: `outcome` answering `.restored` when no file is there (fileExists dropped).
    @MainActor func testNoSidecarIsNone() throws {
        let source = try scratch().appendingPathComponent("scan.dm4")
        let image = Self.image()
        XCTAssertEqual(SessionOpening.outcome(source: source, sidecar: nil, opened: Self.identity(image), image: image), .none)
    }

    /// Red under: the outcome built without `SessionRestore.restore` (marks not decoded), or the sidecar name not derived.
    @MainActor func testASidecarBesideTheImageIsRestoredWithItsMarks() throws {
        let source = try scratch().appendingPathComponent("scan.dm4")
        try plantSidecar(beside: source, marks: 3)
        let image = Self.image()
        guard case .restored(let restored) = SessionOpening.outcome(source: source, sidecar: nil,
                                                                    opened: Self.identity(image), image: image) else {
            return XCTFail("expected a restore")
        }
        XCTAssertEqual(restored.marks.count, 3)
        XCTAssertEqual(restored.verdict, .adopt)
    }

    /// Red under: a file that is not HDF5 mapped to `.none` (or to a restore).
    @MainActor func testAFileThatIsNotASessionIsRefusedWithItsReason() throws {
        let source = try scratch().appendingPathComponent("scan.dm4")
        try Data("not hdf5".utf8).write(to: SessionSidecarFile.sidecarURL(forSource: source))
        let image = Self.image()
        guard case .refused(let reason) = SessionOpening.outcome(source: source, sidecar: nil,
                                                                 opened: Self.identity(image), image: image) else {
            return XCTFail("expected a refusal")
        }
        XCTAssertTrue(reason.contains("not an HDF5 file"), reason)
    }

    /// Red under: the verdict's refusal mapped to a restore (the `catch` in `outcome` dropped).
    @MainActor func testMarksDrawnOnAnotherObjectAreRefusedWithTheVerdictsSentence() throws {
        let source = try scratch().appendingPathComponent("scan.dm4")
        try plantSidecar(beside: source, marks: 1, image: Self.image(source: "ImageList.2 · HAADF"))
        let image = Self.image()
        guard case .refused(let sentence) = SessionOpening.outcome(source: source, sidecar: nil,
                                                                   opened: Self.identity(image), image: image) else {
            return XCTFail("expected a refusal")
        }
        XCTAssertTrue(sentence.contains("ImageList.2 · HAADF"), sentence)
    }

    /// Red under: a sidecar opened as an image given a sidecar of its own (`sourceIsASidecar` mapped to a refusal).
    @MainActor func testAnImageThatIsItselfASidecarHasNoSidecar() throws {
        let source = try scratch().appendingPathComponent("scan.dm4.mactem.h5")
        let image = Self.image()
        XCTAssertEqual(SessionOpening.outcome(source: source, sidecar: nil, opened: Self.identity(image), image: image), .none)
    }

    /// A sidecar the system will not let the process read is named apart (the sandbox's way): file mode 000 stands in for it.
    /// Red under: `.notPermitted` mapped to `.refused` in `outcome`.
    @MainActor func testAnUnreadableSidecarNeedsAccess() throws {
        let source = try scratch().appendingPathComponent("scan.dm4")
        let sidecar = try plantSidecar(beside: source, marks: 1)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: sidecar.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: sidecar.path) }
        let image = Self.image()
        let outcome = SessionOpening.outcome(source: source, sidecar: nil, opened: Self.identity(image), image: image)
        XCTAssertEqual(outcome, .needsAccess)
    }

    // MARK: - OpenItems acts on it

    /// Red under: the adopt call dropped from `OpenItem.publish`.
    @MainActor func testTheFirstReadRestoresTheMarksAndTheItemIsNotDirty() async throws {
        let directory = try scratch()
        let source = directory.appendingPathComponent("scan.dm4")
        let reader = Reader()
        await reader.script(outcomes: [try restoredOutcome(in: directory, marks: 2, source: source)])
        let (_, item) = try await openedItem(reader, source)
        XCTAssertEqual(item.measurements.marks.count, 2)
        XCTAssertEqual(item.measurements.sidecar, .restored)
        XCTAssertFalse(item.measurements.isDirty)
        XCTAssertEqual(AppState.sessionSuffix(of: item), " · restored 2 marks")
    }

    /// A re-read of an evicted item never restores or refuses again.
    /// Red under: `if first` dropped in `OpenItem.publish` (the re-read's outcome is then acted on).
    @MainActor func testAReReadNeverActsOnTheSidecarAgain() async throws {
        let source = URL(fileURLWithPath: "/data/scan.dm4"), other = URL(fileURLWithPath: "/data/other.dm4")
        let reader = Reader()
        await reader.script(outcomes: [.none, .none, .refused("it is broken")])
        let items = makeItems(reader)
        items.open(urls: [source, other])
        await items.settled()
        let item = try XCTUnwrap(items.items.first { $0.url == source })
        items.select(try XCTUnwrap(items.items.first { $0.url == other }).id)
        items.budgetBytes = 100                       // the unselected one goes cold
        XCTAssertEqual(item.residency, .cold, "set-up")
        items.select(item.id)
        items.restoreSelected()
        await items.settled()
        XCTAssertEqual(item.residency, .resident, "set-up: the item was read again")
        XCTAssertEqual(item.measurements.sidecar, .none, "the re-read's outcome was not acted on")
    }

    /// Red under: the item's read acted on before `finishOpen`'s token check (a closed item still adopts).
    @MainActor func testAReadClosedUnderItAdoptsNothing() async throws {
        let directory = try scratch()
        let source = directory.appendingPathComponent("scan.dm4")
        let reader = Reader()
        await reader.script(outcomes: [try restoredOutcome(in: directory, marks: 2, source: source)])
        await reader.hold()
        let items = makeItems(reader)
        items.open(urls: [source])
        let held = await reader.untilHeld()
        XCTAssertTrue(held)
        let item = try XCTUnwrap(items.items.first)
        items.close(item.id)
        await reader.release()
        await items.settled()
        XCTAssertTrue(item.measurements.marks.isEmpty)
        XCTAssertEqual(item.measurements.sidecar, .none)
    }

    /// Red under: `noteOpened` not called in `publish`.
    @MainActor func testAReReadOfOtherPixelsNotesTheDifferenceOnMarksDrawn() async throws {
        let source = URL(fileURLWithPath: "/data/scan.dm4"), other = URL(fileURLWithPath: "/data/other.dm4")
        let reader = Reader()
        await reader.script(outcomes: [], shifts: [0, 0, 5])
        let items = makeItems(reader)
        items.open(urls: [source, other])
        await items.settled()
        let item = try XCTUnwrap(items.items.first { $0.url == source })
        item.measurements.add(marks(1)[0], on: Self.image())
        items.select(try XCTUnwrap(items.items.first { $0.url == other }).id)
        items.budgetBytes = 100
        XCTAssertEqual(item.residency, .cold, "set-up")
        items.select(item.id)
        items.restoreSelected()
        await items.settled()
        XCTAssertEqual(item.measurements.notes, [.pixelsDiffer])
    }

    /// Red under: `.needsAccess` not setting the item's flag.
    @MainActor func testAHiddenSidecarFlagsTheItemAndTurnsSavingOff() async throws {
        let source = URL(fileURLWithPath: "/data/scan.dm4")
        let reader = Reader()
        await reader.script(outcomes: [.needsAccess])
        let (_, item) = try await openedItem(reader, source)
        XCTAssertTrue(item.sidecarNeedsAccess)
        item.measurements.add(marks(1)[0], on: Self.image())
        XCTAssertFalse(item.canSave)
        XCTAssertEqual(AppState.sessionSuffix(of: item), " · session file needs access")
    }

    /// Red under: `canSave` ignoring `savingRefusal`.
    @MainActor func testARefusedSidecarTurnsSavingOffAndSaysSo() async throws {
        let source = URL(fileURLWithPath: "/data/scan.dm4")
        let reader = Reader()
        await reader.script(outcomes: [.refused("the marks were drawn elsewhere")])
        let (_, item) = try await openedItem(reader, source)
        item.measurements.add(marks(1)[0], on: Self.image())
        XCTAssertFalse(item.canSave)
        XCTAssertEqual(AppState.sessionSuffix(of: item), " · session file not used")
    }

    /// Red under: `isDirty` dropped from `canSave` (a clean file offers Save).
    @MainActor func testSaveIsOfferedOnlyWhenSomethingChanged() async throws {
        let source = URL(fileURLWithPath: "/data/scan.dm4")
        let reader = Reader()
        let (_, item) = try await openedItem(reader, source)
        XCTAssertFalse(item.canSave, "nothing drawn")
        item.measurements.add(marks(1)[0], on: Self.image())
        XCTAssertTrue(item.canSave)
    }

    // MARK: - Saving

    /// Red under: `didSave` not called by `SessionSaving.save` (the file stays dirty), or the request not written.
    @MainActor func testTheFirstSaveWritesTheFileAndAReopenRestoresIt() async throws {
        let directory = try scratch()
        let source = directory.appendingPathComponent("scan.dm4")
        let (_, item) = try await openedItem(Reader(), source)
        for mark in marks(3) { item.measurements.add(mark, on: Self.image()) }
        let target = try SessionSidecarFile.sidecarURL(forSource: source)
        let saved = try await SessionSaving.save(item, to: .url(target))
        XCTAssertEqual(saved.marks, 3)
        XCTAssertFalse(item.measurements.isDirty)
        XCTAssertNotNil(item.lastSavedAt)
        XCTAssertFalse(item.canSave)
        let image = Self.image()
        guard case .restored(let restored) = SessionOpening.outcome(source: source, sidecar: nil,
                                                                    opened: Self.identity(image), image: image) else {
            return XCTFail("the saved file did not restore")
        }
        XCTAssertEqual(restored.marks.count, 3)
    }

    /// Red under: `expectedOnDisk` not carried by `didSave` (the second save refuses `changedOnDisk`).
    @MainActor func testALaterSaveRewritesWhatThisWindowWrote() async throws {
        let directory = try scratch()
        let source = directory.appendingPathComponent("scan.dm4")
        let (_, item) = try await openedItem(Reader(), source)
        item.measurements.add(marks(1)[0], on: Self.image())
        let target = try SessionSidecarFile.sidecarURL(forSource: source)
        _ = try await SessionSaving.save(item, to: .url(target))
        item.measurements.add(marks(2)[1], on: Self.image())
        let saved = try await SessionSaving.save(item, to: .url(target))
        XCTAssertEqual(saved.marks, 2)
    }

    /// A file another app wrote since is not overwritten.
    /// Red under: the `changedOnDisk` check dropped from `SessionSave.write` — or `save` swallowing the refusal.
    @MainActor func testAFileChangedSinceTheLastSaveIsNotOverwritten() async throws {
        let directory = try scratch()
        let source = directory.appendingPathComponent("scan.dm4")
        let (_, item) = try await openedItem(Reader(), source)
        item.measurements.add(marks(1)[0], on: Self.image())
        let target = try SessionSidecarFile.sidecarURL(forSource: source)
        _ = try await SessionSaving.save(item, to: .url(target))
        try plantSidecar(beside: source, marks: 5)    // another app's file, other marks
        item.measurements.add(marks(2)[1], on: Self.image())
        do {
            _ = try await SessionSaving.save(item, to: .url(target))
            XCTFail("expected a refusal")
        } catch let failure as SessionSaving.Failure {
            guard case .refused(let name, .changedOnDisk) = failure else { return XCTFail("\(failure)") }
            XCTAssertEqual(name, "scan.dm4.mactem.h5")
            XCTAssertTrue(item.measurements.isDirty, "a refused save leaves the file unsaved")
        }
    }

    /// Red under: the resolve's failure not mapped to `grantLost`.
    @MainActor func testABookmarkThatDoesNotResolveIsALostGrant() async throws {
        let source = try scratch().appendingPathComponent("scan.dm4")
        let (_, item) = try await openedItem(Reader(), source)
        item.measurements.add(marks(1)[0], on: Self.image())
        do {
            _ = try await SessionSaving.save(item, to: .bookmark(Data("garbage".utf8)))
            XCTFail("expected a failure")
        } catch SessionSaving.Failure.grantLost {
            XCTAssertTrue(SessionSaving.Failure.grantLost.dropsGrant)
        }
        XCTAssertFalse(item.isSaving)
    }

    /// Red under: `canSave` not checked in `save` (a clean file is written).
    @MainActor func testSavingACleanFileWritesNothing() async throws {
        let source = try scratch().appendingPathComponent("scan.dm4")
        let (_, item) = try await openedItem(Reader(), source)
        let target = try SessionSidecarFile.sidecarURL(forSource: source)
        do {
            _ = try await SessionSaving.save(item, to: .url(target))
            XCTFail("expected a failure")
        } catch SessionSaving.Failure.nothingToSave {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }

    /// Red under: the permission test dropped from `Failure.errorDescription` or `isPermissionDenied`.
    @MainActor func testTheAlertNamesTheFileAndSaysWhenToChooseAgain() {
        let denied = SessionSaving.Failure.refused(name: "scan.dm4.mactem.h5", .file(.cannotWrite(
            operation: "publishing the file", detail: "Operation not permitted")))
        XCTAssertEqual(denied.errorDescription, "Could not save scan.dm4.mactem.h5. The write failed while publishing the file "
                       + "(Operation not permitted); nothing was changed. Save again and choose the file in the panel.")
        XCTAssertTrue(denied.dropsGrant)
        let changed = SessionSaving.Failure.refused(name: "scan.dm4.mactem.h5", .changedOnDisk)
        XCTAssertEqual(changed.errorDescription, "Could not save scan.dm4.mactem.h5. The session file beside it has changed "
                       + "since this window read it")
        XCTAssertFalse(changed.dropsGrant)
    }

    /// Red under: the name or the folder comparison dropped from `panelRefusal`.
    @MainActor func testThePanelAcceptsOnlyTheDerivedNameInTheImagesFolder() {
        let expected = URL(fileURLWithPath: "/data/Å/scan.dm4.mactem.h5")
        XCTAssertNil(SessionSaving.panelRefusal(chosen: expected, expected: expected))
        let decomposed = URL(fileURLWithPath: "/data/Å/scan.dm4.mactem.h5".decomposedStringWithCanonicalMapping)
        XCTAssertNil(SessionSaving.panelRefusal(chosen: decomposed, expected: expected), "NFC and NFD are one name")
        let sentence = "Keep the name “scan.dm4.mactem.h5” and the image's folder, so macTEM finds the session file when you open the image."
        XCTAssertEqual(SessionSaving.panelRefusal(chosen: URL(fileURLWithPath: "/data/Å/other.h5"), expected: expected), sentence)
        XCTAssertEqual(SessionSaving.panelRefusal(chosen: URL(fileURLWithPath: "/elsewhere/scan.dm4.mactem.h5"), expected: expected), sentence)
    }

    @MainActor func testTheInfobarLineCountsMarks() {
        XCTAssertEqual(SessionSaving.savedLine(name: "a.h5", marks: 1), "Saved a.h5 — 1 mark")
        XCTAssertEqual(SessionSaving.savedLine(name: "a.h5", marks: 3), "Saved a.h5 — 3 marks")
    }

    // MARK: - Overlapping saves, the byte budget's words

    /// Slice B core's Gate B finding 5: a second Save while one writes waits its turn and then takes its request afresh. A
    /// mark moved while the first writes is in the file after the second, nothing is refused, and the file ends saved.
    /// Red under: `beginSaving` not waiting (the second takes its request against what the first has not yet recorded:
    /// refused as changed on disk, or written over); the entry guard refusing a save that asks while one writes (the second
    /// throws `nothingToSave`, and the move is lost).
    @MainActor func testASaveAskedWhileOneWritesWaitsAndLosesNeither() async throws {
        let directory = try scratch()
        let source = directory.appendingPathComponent("scan.dm4")
        let (_, item) = try await openedItem(Reader(), source)
        let image = Self.image()
        item.measurements.add(marks(1)[0], on: image)
        let id = try XCTUnwrap(item.measurements.marks.first?.id)
        let target = try SessionSidecarFile.sidecarURL(forSource: source)

        let first = Task.immediate { try await SessionSaving.save(item, to: .url(target)) }
        XCTAssertTrue(item.isSaving, "the first save runs to its write")
        item.measurements.move(id, point: 1, to: ImagePoint(x: 31, y: 17), on: image)   // while the first writes
        XCTAssertTrue(item.measurements.isDirty)
        let second = Task.immediate { try await SessionSaving.save(item, to: .url(target)) }
        _ = try await first.value
        _ = try await second.value

        XCTAssertFalse(item.isSaving)
        XCTAssertEqual(item.mostSavesHolding, 1, "the two saves never held the place together")
        XCTAssertFalse(item.measurements.isDirty, "the second save recorded the move")
        guard case .restored(let restored) = SessionOpening.outcome(source: source, sidecar: nil,
                                                                    opened: Self.identity(image), image: image) else {
            return XCTFail("the saved file did not restore")
        }
        XCTAssertEqual(restored.marks.first?.mark.points.last, ImagePoint(x: 31, y: 17))
    }

    /// Saves that ask in a row are served in order, and one that waited and finds nothing left to write returns what the
    /// one ahead wrote, without writing again.
    /// Red under: `lastSaved` not kept (the waiter throws `nothingToSave`); the waiter writing a clean file.
    @MainActor func testASaveThatWaitedAndFindsNothingLeftReturnsTheOneAheads() async throws {
        let directory = try scratch()
        let source = directory.appendingPathComponent("scan.dm4")
        let (_, item) = try await openedItem(Reader(), source)
        for mark in marks(2) { item.measurements.add(mark, on: Self.image()) }
        let target = try SessionSidecarFile.sidecarURL(forSource: source)
        let first = Task.immediate { try await SessionSaving.save(item, to: .url(target)) }
        let second = Task.immediate { try await SessionSaving.save(item, to: .url(target)) }
        let a = try await first.value
        let at = item.lastSavedAt
        let b = try await second.value
        XCTAssertEqual(a.url, b.url)
        XCTAssertEqual(b.marks, 2)
        XCTAssertEqual(item.lastSavedAt, at, "the second wrote nothing")
        XCTAssertFalse(item.isSaving)
    }

    /// A save refused as too large says what happened and what to do, with the record's size and the limit — from the
    /// writer's refusal and from the owner's.
    /// Red under: the over-budget branch dropped from `Failure.errorDescription` (the generic sentence then lacks the advice).
    @MainActor func testASaveRefusedAsTooLargeSaysSoAndWhatToDo() {
        let limit = SessionSidecarFile.maxTotalTextBytes.formatted()
        let expected = "Could not save scan.dm4.mactem.h5. The marks and their record would take \(61_234.formatted()) bytes of "
            + "text; a session file holds \(limit). Remove some marks, then save again."
        let writer = SessionSaving.Failure.refused(name: "scan.dm4.mactem.h5", .file(.sidecarTooLarge(bytes: 61_234)))
        XCTAssertEqual(writer.errorDescription, expected)
        let owner = SessionSaving.Failure.refused(name: "scan.dm4.mactem.h5",
                                                  .lineage(.tooLargeToSave(bytes: 61_234, limit: SessionSidecarFile.maxTotalTextBytes)))
        XCTAssertEqual(owner.errorDescription, expected)
        XCTAssertFalse(writer.dropsGrant, "a too-large record is not a lost grant")
    }

    /// Every sentence of a refused mark: the budget (named, and nil for a move or a width), the full record, a point that is not
    /// a number, and the tail's standing line.
    /// Red under: a case of `MarkRefusalText` merged into another, or its advice dropped.
    @MainActor func testARefusedMarkSaysWhatHappenedAndWhatToDo() {
        let limit = SessionSidecarFile.maxTotalTextBytes.formatted()
        let budget = SessionLineage.Refusal.tooLargeToSave(bytes: 60_300, limit: SessionSidecarFile.maxTotalTextBytes)
        XCTAssertEqual(MarkRefusalText.refused(budget, .added),
                       "The mark was not added. With it the session record would take \(60_300.formatted()) bytes of text, over the "
                       + "\(limit) a session file holds. Remove a mark to make room.")
        XCTAssertEqual(MarkRefusalText.refused(nil, .moved),
                       "The mark was not moved. With it the session record would take more than the \(limit) bytes of text a "
                       + "session file holds. Remove a mark to make room.")
        XCTAssertTrue(MarkRefusalText.refused(nil, .widthChanged).hasPrefix("The width was not changed."))
        let full = "The session record is full: it holds \(2000.formatted()) entries, removed marks included. "
            + "To start a new record, move the session file aside and open the image again."
        XCTAssertEqual(MarkRefusalText.refused(.tooManyNodes(2001), .added), "The mark was not added. " + full)
        XCTAssertEqual(MarkRefusalText.refused(.idsExhausted, .added), "The mark was not added. " + full)
        XCTAssertEqual(MarkRefusalText.refused(.notFinite, .added), "The mark was not added. A point of it is not a number.")
        XCTAssertEqual(MarkRefusalText.standing(budget),
                       "The session record is full: another mark would take it to \(60_300.formatted()) bytes of text, over the "
                       + "\(limit) a session file holds. Remove a mark to draw another.")
        XCTAssertEqual(MarkRefusalText.standing(.tooManyNodes(2001)), full)
    }

    /// The Measure tail says, beside the state line, that the next mark would be refused; and no two lines share an identity.
    /// Red under: the `recording` line dropped from `SessionFormat.tail`; `SessionTailLine.id` made a position.
    @MainActor func testTheTailWarnsWhileTheNextMarkWouldBeRefusedAndItsLinesHaveIdentities() {
        let budget = SessionLineage.Refusal.tooLargeToSave(bytes: 60_300, limit: SessionSidecarFile.maxTotalTextBytes)
        let tail = SessionFormat.tail(input {
            $0.sidecar = .restored; $0.notes = [.pixelsDiffer, .calibrationDiffers]; $0.recording = budget
        })
        XCTAssertEqual(tail.lines.last?.text, MarkRefusalText.standing(budget))
        XCTAssertEqual(tail.lines.last?.kind, .warning(symbol: "exclamationmark.triangle.fill"))
        XCTAssertEqual(Set(tail.lines.map(\.id)).count, tail.lines.count)
        XCTAssertEqual(tail.lines.map(\.id), tail.lines.map(\.text))
        XCTAssertNil(SessionFormat.tail(input()).lines.first { $0.text.contains("record is full") })
    }

    /// A move the record declines (a longer number past the budget) is told apart from a move that changed nothing: marks
    /// are added until the record refuses one, then each is moved to a many-digit place until one is declined. The declined
    /// mark stays where it was; a move to where a mark already is is no refusal.
    /// Red under: `MarkEdits.move` returning false always (nothing is said); true always (a no-op is called a refusal);
    /// comparing the point before the move after it.
    @MainActor func testAMoveTheRecordDeclinesIsToldApartFromANoOp() throws {
        let image = Self.image()
        let owner = ImageMeasurements()
        owner.noteOpened(Self.identity(image))
        var refusal: SessionLineage.Refusal?
        for _ in 0..<2_000 where refusal == nil {
            refusal = owner.add(ImageMark(kind: .distance, points: [ImagePoint(x: 1, y: 1), ImagePoint(x: 2, y: 2)]), on: image)
        }
        guard case .tooLargeToSave = refusal else { return XCTFail("expected the budget, got \(String(describing: refusal))") }

        let first = try XCTUnwrap(owner.marks.first)
        XCTAssertFalse(MarkEdits.move(first.id, point: 0, to: first.points[0], on: image, in: owner), "a move to where it is")
        let longer = ImagePoint(x: 20.123456789012345, y: 10.987654321098765)
        var declined: ImageMark?
        for mark in owner.marks where declined == nil {
            if MarkEdits.move(mark.id, point: 0, to: longer, on: image, in: owner) { declined = mark }
        }
        let refused = try XCTUnwrap(declined, "the budget must decline one of the moves")
        XCTAssertEqual(owner.mark(refused.id)?.points, refused.points, "the declined mark stays where it was")
        XCTAssertNotEqual(owner.marks.first?.points[0], first.points[0], "the first moves were taken")
    }

    /// A width change is no refusal while the record takes it, and none when the width is already that.
    /// Red under: `MarkEdits.setWidth` returning true when nothing was refused.
    @MainActor func testAWidthTheRecordTakesIsNoRefusal() throws {
        let image = Self.image()
        let owner = ImageMeasurements()
        owner.noteOpened(Self.identity(image))
        owner.add(ImageMark(kind: .profile, points: [ImagePoint(x: 1, y: 1), ImagePoint(x: 20, y: 10)]), on: image)
        let id = try XCTUnwrap(owner.marks.first?.id)
        XCTAssertFalse(MarkEdits.setWidth(id, 5, on: image, in: owner))
        XCTAssertEqual(owner.mark(id)?.width, 5)
        XCTAssertFalse(MarkEdits.setWidth(id, 5, on: image, in: owner))
    }

    // MARK: - Refuter findings (1, 2, 4, 7)

    /// Finding 1: a stored grant counts only while it resolves to `<image>.mactem.h5` beside the image. A bookmark follows its
    /// file when it is moved, renamed or trashed; the moved file is neither read nor written.
    /// Red under: the `panelRefusal` check dropped from `grantedURL` (the aside file is granted).
    @MainActor func testAGrantCountsOnlyForTheSessionFileBesideTheImage() throws {
        let directory = try scratch()
        let source = directory.appendingPathComponent("scan.dm4")
        let expected = try SessionSidecarFile.sidecarURL(forSource: source)
        let other = try scratch()
        XCTAssertEqual(SessionSaving.grantedURL(Data(), source: source, resolve: { _ in expected }), expected)
        XCTAssertNil(SessionSaving.grantedURL(Data(), source: source,
                                              resolve: { _ in directory.appendingPathComponent("old.h5") }), "renamed")
        XCTAssertNil(SessionSaving.grantedURL(Data(), source: source,
                                              resolve: { _ in other.appendingPathComponent(expected.lastPathComponent) }), "moved")
        XCTAssertNil(SessionSaving.grantedURL(Data(), source: source, resolve: { _ in nil }), "unresolved")
    }

    /// Finding 1 end to end, with a real security-scoped bookmark: the sidecar moved aside after the grant was made is not
    /// restored at open (the grant is dropped), and a save through the grant does not write into it.
    /// Red under: the check dropped from `grantedURL` — the aside file is restored, and written.
    @MainActor func testAMovedSessionFileWithAGrantIsNeitherRestoredNorWritten() async throws {
        let directory = try scratch()
        let source = directory.appendingPathComponent("scan.dm4")
        let sidecar = try plantSidecar(beside: source, marks: 2)
        guard let bookmark = try? sidecar.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil,
                                                       relativeTo: nil) else {
            throw XCTSkip("this host cannot make a security-scoped bookmark")
        }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "SessionUITests-\(UUID().uuidString)"))
        SessionGrants.store(bookmark, forSource: source, defaults: defaults)
        let aside = directory.appendingPathComponent("aside.h5")
        try FileManager.default.moveItem(at: sidecar, to: aside)
        let asideBytes = try Data(contentsOf: aside)

        let image = Self.image()
        let outcome = SessionGrants.outcome(source: source, opened: Self.identity(image), image: image, defaults: defaults)
        XCTAssertEqual(outcome, .none, "nothing is restored from the moved file")
        XCTAssertNil(SessionGrants.bookmark(forSource: source, defaults: defaults), "the grant is dropped")

        let (_, item) = try await openedItem(Reader(), source)
        item.measurements.add(marks(1)[0], on: image)
        do {
            _ = try await SessionSaving.save(item, to: .bookmark(bookmark))
            XCTFail("expected a lost grant")
        } catch SessionSaving.Failure.grantLost {}
        XCTAssertEqual(try Data(contentsOf: aside), asideBytes, "the moved file is not written")
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecar.path))
    }

    /// Finding 2: a file another app changed is answered with Replace, once, and only through `replaceAndSave`; a plain save
    /// leaves the other file as it is. Only this refusal offers it.
    /// Red under: `replaceRefusedSidecar` not called by `replaceAndSave` (still refused); `offersReplace` true for any refusal.
    @MainActor func testAFileAnotherAppChangedCanBeReplacedOnlyByReplaceAndSave() async throws {
        let directory = try scratch()
        let source = directory.appendingPathComponent("scan.dm4")
        let (_, item) = try await openedItem(Reader(), source)
        let image = Self.image()
        item.measurements.add(marks(1)[0], on: image)
        let target = try SessionSidecarFile.sidecarURL(forSource: source)
        _ = try await SessionSaving.save(item, to: .url(target))
        try plantSidecar(beside: source, marks: 5)
        item.measurements.add(marks(2)[1], on: image)
        do {
            _ = try await SessionSaving.save(item, to: .url(target))
            XCTFail("expected a refusal")
        } catch let failure as SessionSaving.Failure {
            XCTAssertTrue(failure.offersReplace)
        }
        func restoredCount() -> Int {
            guard case .restored(let restored) = SessionOpening.outcome(source: source, sidecar: nil,
                                                                        opened: Self.identity(image), image: image) else { return -1 }
            return restored.marks.count
        }
        XCTAssertEqual(restoredCount(), 5, "a refused save leaves the other file as it is")
        let saved = try await SessionSaving.replaceAndSave(item, to: .url(target))
        XCTAssertEqual(saved.marks, 2)
        XCTAssertEqual(restoredCount(), 2, "Replace wrote this window's marks")
        XCTAssertFalse(item.measurements.isDirty)
        // the permission is spent: the next change by another app is refused again
        try plantSidecar(beside: source, marks: 4)
        item.measurements.add(marks(3)[2], on: image)
        do {
            _ = try await SessionSaving.save(item, to: .url(target))
            XCTFail("expected a refusal")
        } catch let failure as SessionSaving.Failure {
            XCTAssertTrue(failure.offersReplace)
        }
        XCTAssertFalse(SessionSaving.Failure.grantLost.offersReplace)
        XCTAssertFalse(SessionSaving.Failure.refused(name: "a.h5", .readOnly(2)).offersReplace)
        XCTAssertEqual(SessionFormat.replaceTitle(name: "scan.dm4.mactem.h5"),
                       "scan.dm4.mactem.h5 has changed since this window read it.")
        XCTAssertTrue(SessionFormat.replaceDetail(name: "x").hasSuffix("Replacing loses what the other file holds."))
    }

    /// Finding 4: Choose Session File… says what became of the file, and a file that was read ends "needs access".
    /// Red under: `.none` leaving `sidecarNeedsAccess` set; a restored file that is not adopted leaving it set; a line
    /// saying "chosen" whatever happened.
    @MainActor func testChoosingASessionFileSaysWhatBecameOfItAndClearsNeedsAccess() async throws {
        let source = URL(fileURLWithPath: "/data/scan.dm4")
        let reader = Reader()
        await reader.script(outcomes: [.needsAccess])
        let (_, item) = try await openedItem(reader, source)
        XCTAssertTrue(item.sidecarNeedsAccess)
        let image = Self.image()
        XCTAssertFalse(item.adopt(.none, identity: Self.identity(image), on: image))
        XCTAssertFalse(item.sidecarNeedsAccess, "the chosen file was not there: nothing is hidden")

        item.adopt(.needsAccess, identity: Self.identity(image), on: image)
        item.measurements.add(marks(1)[0], on: image)                    // marks already drawn: a restore is dropped
        let directory = try scratch()
        let restored = try restoredOutcome(in: directory, marks: 2, source: directory.appendingPathComponent("scan.dm4"))
        XCTAssertFalse(item.adopt(restored, identity: Self.identity(image), on: image))
        XCTAssertFalse(item.sidecarNeedsAccess, "it was read")

        let name = "scan.dm4.mactem.h5"
        XCTAssertEqual(SessionFormat.chosenLine(.none, adopted: false, name: name), "No session file was found at that place.")
        XCTAssertEqual(SessionFormat.chosenLine(.refused("x"), adopted: false, name: name), "\(name) was not used.")
        XCTAssertEqual(SessionFormat.chosenLine(restored, adopted: true, name: name), "Restored the marks from \(name)")
        XCTAssertEqual(SessionFormat.chosenLine(restored, adopted: false, name: name),
                       "The marks in \(name) were not restored: marks are already drawn in this window. Remove them first.")
    }

    /// Finding 7: `MarkEdits` tells a refusal from a no-op by its own copy of the owner's clamp; on the edges of the image
    /// and the ends of the width range the two agree (a move or width the owner clamps to where the mark already is is no
    /// refusal; one that lands is none either).
    /// Red under: either copy's bound changed (−0.5 → −0.4, W − 0.5 → W, width cap 25 → 26): `MarkEdits` then says "refused"
    /// for a no-op.
    @MainActor func testMarkEditsClampAgreesWithTheOwnersOnTheEdges() throws {
        let image = Self.image()                       // 40 × 24
        let owner = ImageMeasurements()
        owner.noteOpened(Self.identity(image))
        let lowX = -0.5, highX = Double(image.width) - 0.5, lowY = -0.5, highY = Double(image.height) - 0.5
        owner.add(ImageMark(kind: .distance, points: [ImagePoint(x: lowX, y: lowY), ImagePoint(x: highX, y: highY)]), on: image)
        let id = try XCTUnwrap(owner.marks.first?.id)
        let edges: [(Int, ImagePoint, [Double])] = [
            (0, ImagePoint(x: lowX, y: lowY), [-1e9, (-0.5).nextDown, -0.6]),
            (1, ImagePoint(x: highX, y: highY), [1e9, highX.nextUp, 41])]
        for (index, edge, fars) in edges {
            for far in fars {
                let target = ImagePoint(x: far, y: far)
                XCTAssertFalse(MarkEdits.move(id, point: index, to: target, on: image, in: owner), "\(index) \(far)")
                XCTAssertEqual(owner.mark(id)?.points[index], edge, "the owner holds the end on the edge")
            }
        }
        XCTAssertFalse(MarkEdits.move(id, point: 0, to: ImagePoint(x: 10, y: 10), on: image, in: owner), "a landing move")
        XCTAssertEqual(owner.mark(id)?.points[0], ImagePoint(x: 10, y: 10))

        owner.add(ImageMark(kind: .profile, points: [ImagePoint(x: 1, y: 1), ImagePoint(x: 20, y: 10)], width: ImageMeasurements.maximumWidth), on: image)
        let profile = try XCTUnwrap(owner.marks.last?.id)
        XCTAssertEqual(owner.mark(profile)?.width, ImageMeasurements.maximumWidth)
        for wide in [ImageMeasurements.maximumWidth, ImageMeasurements.maximumWidth + 1, 1_000] {
            XCTAssertFalse(MarkEdits.setWidth(profile, wide, on: image, in: owner), "width \(wide)")
            XCTAssertEqual(owner.mark(profile)?.width, ImageMeasurements.maximumWidth)
        }
        XCTAssertFalse(MarkEdits.setWidth(profile, 1, on: image, in: owner))
        for narrow in [1, 0, -5] {
            XCTAssertFalse(MarkEdits.setWidth(profile, narrow, on: image, in: owner), "width \(narrow)")
            XCTAssertEqual(owner.mark(profile)?.width, 1)
        }
    }

    // MARK: - The words

    private func input(_ edit: (inout SessionTailInput) -> Void = { _ in }) -> SessionTailInput {
        var input = SessionTailInput(fileName: "scan.dm4.mactem.h5", sidecar: .none, notes: [], needsAccess: false,
                                     newerVersion: nil, hasMarks: true, isDirty: true, canSave: true, isSaving: false,
                                     savedAt: nil)
        edit(&input)
        return input
    }

    private func texts(_ tail: SessionTail) -> [String] { tail.lines.map(\.text) }

    /// Red under: the first-mark sentence changed or dropped.
    @MainActor func testTheTailSaysNotSavedAndOffersSave() {
        let tail = SessionFormat.tail(input())
        XCTAssertEqual(texts(tail), ["Not saved. Save to Session (⌘S) keeps the marks in scan.dm4.mactem.h5, beside the image."])
        XCTAssertTrue(tail.showsSave)
        XCTAssertEqual(SessionFormat.tail(input { $0.hasMarks = false; $0.isDirty = false; $0.canSave = false }),
                       SessionTail(), "no marks, no file: nothing to say")
    }

    /// Red under: Save drawn dimmed instead of omitted when clean.
    @MainActor func testTheTailOmitsSaveWhenCleanAndShowsWhereTheMarksAre() {
        let restored = SessionFormat.tail(input { $0.sidecar = .restored; $0.isDirty = false; $0.canSave = false })
        XCTAssertEqual(texts(restored), ["Restored from scan.dm4.mactem.h5."])
        XCTAssertFalse(restored.showsSave)
        let saved = SessionFormat.tail(input {
            $0.sidecar = .saved; $0.isDirty = false; $0.canSave = false
            $0.savedAt = Date(timeIntervalSince1970: 1_791_900_000)
        }, locale: Locale(identifier: "en_GB"))
        XCTAssertEqual(texts(saved).count, 1)
        XCTAssertTrue(texts(saved)[0].hasPrefix("Saved at ") && texts(saved)[0].hasSuffix(" to scan.dm4.mactem.h5."), texts(saved)[0])
        let changed = SessionFormat.tail(input { $0.sidecar = .restored })
        XCTAssertEqual(texts(changed), ["Changed since restored from scan.dm4.mactem.h5."])
        XCTAssertTrue(changed.showsSave)
    }

    /// Red under: a note's sentence changed, or a note shown as a plain line (no warning symbol).
    @MainActor func testTheTailCarriesTheRestoreNotes() {
        let tail = SessionFormat.tail(input {
            $0.sidecar = .restored; $0.isDirty = false; $0.canSave = false
            $0.notes = [.pixelsDiffer, .renamed(from: "old.dm4")]
        })
        XCTAssertEqual(texts(tail), [
            "Restored from scan.dm4.mactem.h5.",
            "The image differs from when the marks were drawn. The values shown are measured on this image.",
            "This session file was saved for “old.dm4”; the image is the same.",
        ])
        XCTAssertEqual(tail.lines[1].kind, .warning(symbol: "exclamationmark.triangle.fill"))
        XCTAssertEqual(tail.lines[2].kind, .note)
    }

    /// Red under: a refusal that still offers Save, or drops Show in Finder.
    @MainActor func testTheTailExplainsARefusedFileAndOffersNoSave() {
        let tail = SessionFormat.tail(input { $0.sidecar = .refused("the marks were drawn on “A”."); $0.canSave = false })
        XCTAssertEqual(texts(tail), [
            "scan.dm4.mactem.h5 was not used.",
            "The marks were drawn on “A”.",
            "Saving to scan.dm4.mactem.h5 is off, so the file is never overwritten. Marks drawn here stay in this window.",
        ])
        XCTAssertFalse(tail.showsSave)
        XCTAssertTrue(tail.showsFinder)
    }

    /// Red under: the newer-version branch after the refused one, or the version dropped from the sentence.
    @MainActor func testTheTailExplainsANewerFile() {
        let tail = SessionFormat.tail(input { $0.newerVersion = 2; $0.canSave = false })
        XCTAssertEqual(tail.lines[0].text,
                       "scan.dm4.mactem.h5 was written by a newer macTEM (lineage version 2); its marks are not shown.")
        XCTAssertTrue(tail.showsFinder)
        XCTAssertFalse(tail.showsSave)
    }

    /// Red under: Choose Session File… enabled with marks drawn (a restore adopts only into an empty lineage).
    @MainActor func testTheTailOffersChooseSessionFileAndSaysWhyItIsOff() {
        let free = SessionFormat.tail(input { $0.needsAccess = true; $0.hasMarks = false; $0.canSave = false })
        XCTAssertEqual(free.chooseFile, "")
        XCTAssertEqual(free.lines[0].kind, .warning(symbol: "lock.fill"))
        XCTAssertEqual(free.lines[1].text, "Saving is off until you choose it, so its marks are not overwritten.")
        let blocked = SessionFormat.tail(input { $0.needsAccess = true; $0.canSave = false })
        XCTAssertEqual(blocked.chooseFile, "Remove the marks drawn here to restore the session file's marks.")
        XCTAssertFalse(blocked.showsSave)
    }

    @MainActor func testTheInfobarSuffixes() {
        typealias S = ImageMeasurements.Sidecar
        XCTAssertEqual(AppState.sessionSuffix(sidecar: .restored, marks: 3, notes: [], needsAccess: false, readOnly: false),
                       " · restored 3 marks")
        XCTAssertEqual(AppState.sessionSuffix(sidecar: .restored, marks: 1, notes: [], needsAccess: false, readOnly: false),
                       " · restored 1 mark")
        XCTAssertEqual(AppState.sessionSuffix(sidecar: .restored, marks: 3, notes: [.pixelsDiffer], needsAccess: false,
                                              readOnly: false), " · restored 3 marks (image differs)")
        XCTAssertEqual(AppState.sessionSuffix(sidecar: .none, marks: 0, notes: [], needsAccess: false, readOnly: true),
                       " · session file is newer")
        XCTAssertEqual(AppState.sessionSuffix(sidecar: .none, marks: 0, notes: [], needsAccess: false, readOnly: false), "")
    }

    // MARK: - The Lineage rows

    private func lineageFixture() throws -> (SessionLineage, ImageMark) {
        var lineage = SessionLineage()
        let t: Int64 = 1_791_900_000_000
        try lineage.add(kind: "fft", parameters: [:], recorded: t)                                    // s1: not drawn
        try lineage.add(kind: "distance", parameters: [:], recorded: t)                               // s2: removed, cited
        try lineage.add(kind: "export", parameters: [:], inputs: [.init(step: "s2", role: "image")], recorded: t)   // s3
        lineage.remove(id: "s2", at: t + 60_000)
        try lineage.add(kind: "distance", parameters: [:], recorded: t)                               // s4: a mark
        return (lineage, ImageMark(kind: .distance, points: [ImagePoint(x: 0, y: 0), ImagePoint(x: 20, y: 0)]))
    }

    /// Red under: a node with no mark drawn as a button, a removed node not dimmed, or the citer not named.
    func testTheLineageRowsTellTheRecordApartFromTheMarks() throws {
        let (lineage, mark) = try lineageFixture()
        let rows = LineageFormat.rows(lineage: lineage, marks: [(nodeID: "s4", mark: mark)], x: Self.image().x, y: Self.image().y,
                                      now: SessionLineage.date(milliseconds: 1_791_900_000_000), locale: Locale(identifier: "en_GB"))
        XCTAssertEqual(rows.map(\.id), ["s1", "s2", "s3", "s4"])
        XCTAssertEqual(rows.map { $0.markID == nil }, [true, true, true, false])
        XCTAssertTrue(rows[0].isOpaque)
        XCTAssertEqual(rows[0].value, "fft", "the stored kind verbatim")
        XCTAssertTrue(rows[0].caption.hasPrefix("s1 · ") && rows[0].caption.hasSuffix(" · kept unchanged, not drawn"), rows[0].caption)
        XCTAssertTrue(rows[1].isRemoved)
        XCTAssertTrue(rows[1].caption.hasPrefix("s2 · removed ") && rows[1].caption.hasSuffix(" · kept because s3 uses it"), rows[1].caption)
        XCTAssertEqual(rows[3].value, MarkFormat.value(mark, x: Self.image().x, y: Self.image().y, locale: Locale(identifier: "en_GB")))
        XCTAssertTrue(rows[3].spoken.contains("recorded"), rows[3].spoken)
        XCTAssertTrue(rows[3].caption.hasPrefix("s4 · "))
    }

    /// The value comes from the mark and the file's axes, never the stored results.
    /// Red under: the row's value read from `node.results`.
    func testALineageRowsValueIsMeasuredAgainOnTheAxes() throws {
        var lineage = SessionLineage()
        try lineage.add(kind: "distance", parameters: [:], results: ["length": "999"], recorded: 1_791_900_000_000)
        let mark = ImageMark(kind: .distance, points: [ImagePoint(x: 0, y: 0), ImagePoint(x: 20, y: 0)])
        let rows = LineageFormat.rows(lineage: lineage, marks: [(nodeID: "s1", mark: mark)], x: Self.image().x, y: Self.image().y)
        XCTAssertFalse(rows[0].value.contains("999"))
        XCTAssertTrue(rows[0].value.contains("10"), rows[0].value)      // 20 px at 0.5 nm a column
    }
}
