//
//  SessionSidecarFileTests+Writing.swift
//  Opening never writes; a write publishes only over the file it checked, leaves nothing behind when it fails, and closes its handles.
//  Fixtures: SessionSidecarFileTests.swift.
//

import XCTest
import Darwin
import FormatoHDF5
import TEMCore

nonisolated extension SessionSidecarFileTests {
    // MARK: Opening never writes; a failed write changes nothing

    /// Reading — a sidecar, a foreign file, a newer one, a file that is not HDF5 — changes neither the bytes nor the
    /// modification time. Red under: the read opening the file read-write and stamping a last-opened attribute.
    func testOpeningNeverWritesTheFile() throws {
        let directory = try scratchDirectory()
        let good = directory.appendingPathComponent("good.mactem.h5")
        try Sidecar.write(source: "s", lineage: lineageLike(bytes: 10_000), to: good)
        let foreign = directory.appendingPathComponent("foreign.mactem.h5")
        try plant(foreign, [.text("x", "y")])
        let newer = directory.appendingPathComponent("newer.mactem.h5")
        try plant(newer, [.text(Sidecar.identityAttribute, "2"), .text(Sidecar.minReaderAttribute, "2")])
        let junk = directory.appendingPathComponent("junk.mactem.h5")
        try Data("junk".utf8).write(to: junk)
        let urls = [good, foreign, newer, junk]
        func state(_ url: URL) throws -> (Data, Date?) {
            (try bytes(url), try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
        }
        let before = try urls.map(state)
        Thread.sleep(forTimeInterval: 1.1)       // a changed file would carry a later modification time
        for url in urls { _ = try? Sidecar.read(url: url) }
        let after = try urls.map(state)
        for (index, url) in urls.enumerated() {
            XCTAssertEqual(after[index].0, before[index].0, "\(url.lastPathComponent): bytes")
            XCTAssertEqual(after[index].1, before[index].1, "\(url.lastPathComponent): modification time")
        }
    }

    /// A write that fails — here, because the folder cannot take the rename — throws, leaves the old sidecar exactly as it
    /// was and readable, and leaves nothing else in the folder. Red under: the rename's failure ignored.
    func testAFailedWriteLeavesTheOldSidecarAndNothingElse() throws {
        let directory = try scratchDirectory()
        let url = directory.appendingPathComponent("keep.mactem.h5")
        try Sidecar.write(source: "old source", lineage: "old lineage", to: url)
        let before = try bytes(url)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
        addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path) }
        let failed = refusal { try Sidecar.write(source: "new source", lineage: "new lineage", to: url) }
        guard case .cannotWrite = failed else { return XCTFail("expected .cannotWrite, got \(String(describing: failed))") }
        XCTAssertEqual(try bytes(url), before)
        XCTAssertEqual(try Sidecar.read(url: url).source, "old source")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [url.lastPathComponent])

        // A first write into the same folder fails the same way and creates nothing.
        let fresh = directory.appendingPathComponent("fresh.mactem.h5")
        let refused = refusal { try Sidecar.write(source: "s", lineage: "l", to: fresh) }
        guard case .cannotWrite = refused else { return XCTFail("expected .cannotWrite, got \(String(describing: refused))") }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [url.lastPathComponent])
    }

    // MARK: Publishing only over the file that was checked (Gate B, 2026-10-13)

    /// A file that appears at the path between the existence check and the publish (here: after the sidecar is built, which
    /// takes as long as the sidecar is big) is not replaced: the write is refused as `.cannotWrite` and the file is byte for
    /// byte as it appeared. Run with RENAME_EXCL and as on a file system that lacks it (exFAT: the fallback looks at the
    /// path). Red under: the publish made with a plain `rename`; the fallback made a plain `rename`.
    func testAFileThatAppearsAfterTheCheckIsNotReplaced() throws {
        for withoutExclusiveRename in [false, true] {
            let url = try scratchDirectory().appendingPathComponent("race.mactem.h5")
            var appeared: Data?
            let seams = Sidecar.WriteSeams(beforePublish: {
                try? self.plant(url, [.text("somebody_elses", "precious")])
                appeared = try? Data(contentsOf: url)
            }, exclusiveRenameUnavailable: withoutExclusiveRename)
            let failed = refusal { try Sidecar.write(source: "s", lineage: "l", to: url, seams: seams) }
            guard case .cannotWrite(let operation, _)? = failed else {
                return XCTFail("expected .cannotWrite, got \(String(describing: failed)) (no RENAME_EXCL: \(withoutExclusiveRename))")
            }
            XCTAssertEqual(operation, "publishing the file")
            XCTAssertNotNil(appeared, "the seam did not plant the file")
            XCTAssertEqual(try bytes(url), appeared, "the file that appeared was replaced (no RENAME_EXCL: \(withoutExclusiveRename))")
            XCTAssertEqual(refusal { try Sidecar.read(url: url) }, .foreign)
        }
    }

    /// The refusal says what happened: a file appeared where the sidecar was to be created. Red under: an existing file on
    /// the create path reported as the system's generic text (the re-verifier's N8e, 2026-10-14).
    func testAFileThatAppearsBeforeThePublishIsNamedInTheRefusal() throws {
        let url = try scratchDirectory().appendingPathComponent("race.mactem.h5")
        let seams = Sidecar.WriteSeams(beforePublish: { try? self.plant(url, [.text("somebody_elses", "precious")]) })
        guard case .cannotWrite(_, let detail)? = refusal({ try Sidecar.write(source: "s", lineage: "l", to: url, seams: seams) })
        else { return XCTFail("expected .cannotWrite") }
        XCTAssertTrue(detail.contains("appeared"), detail)
    }

    /// The sidecar that was checked and replaced by another file before the publish — swapped for a foreign file, or taken
    /// away — is not the one the write was told is fine: refused, and what is at the path is left as it is (a file taken away
    /// stays away). Red under: the
    /// identity not looked at again before the rename (the plain `rename`, or RENAME_EXCL alone).
    func testASidecarSwappedOrRemovedAfterTheCheckIsNotReplaced() throws {
        let directory = try scratchDirectory()
        let url = directory.appendingPathComponent("swap.mactem.h5")
        try Sidecar.write(source: "s", lineage: "old", to: url)
        let intruder = directory.appendingPathComponent("intruder.tmp")
        try plant(intruder, [.text("somebody_elses", "precious")])
        let intruderBytes = try bytes(intruder)

        let swapped = Sidecar.WriteSeams(beforePublish: { _ = Darwin.rename(intruder.path, url.path) })
        guard case .cannotWrite(let operation, _)? = refusal({ try Sidecar.write(source: "s", lineage: "new", to: url, seams: swapped) })
        else { return XCTFail("expected .cannotWrite for the swapped file") }
        XCTAssertEqual(operation, "publishing the file")
        XCTAssertEqual(try bytes(url), intruderBytes, "the file swapped in after the check was replaced")

        // A sidecar taken away in that moment is not put back by the write either: what it checked is gone.
        let other = directory.appendingPathComponent("removed.mactem.h5")
        try Sidecar.write(source: "s", lineage: "mine", to: other)
        let removed = Sidecar.WriteSeams(beforePublish: { _ = Darwin.unlink(other.path) })
        guard case .cannotWrite? = refusal({ try Sidecar.write(source: "s", lineage: "new", to: other, seams: removed) })
        else { return XCTFail("expected .cannotWrite for the removed file") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: other.path), "a write over a removed file put one back")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [url.lastPathComponent])   // the intruder, and nothing else
    }

    /// Without RENAME_EXCL (exFAT, where a first sidecar is the usual case) a write still creates and still replaces. Red
    /// under: the fallback returning the ENOTSUP as a failure.
    func testAWriteWithoutExclusiveRenameCreatesAndReplaces() throws {
        let url = try scratchDirectory().appendingPathComponent("fallback.mactem.h5")
        let seams = Sidecar.WriteSeams(exclusiveRenameUnavailable: true)
        try Sidecar.write(source: "first", lineage: "1", to: url, seams: seams)
        XCTAssertEqual(try Sidecar.read(url: url).source, "first")
        try Sidecar.write(source: "second", lineage: "2", to: url, seams: seams)
        XCTAssertEqual(try Sidecar.read(url: url), Sidecar.Contents(schema: 1, minReader: 1, source: "second", lineage: "2"))
    }

    /// Something that is at the path, a link that points nowhere included, is "an existing file": it cannot be opened, so it
    /// is refused as that and left as it was, not written over because `fileExists` follows the link and says no. Red under:
    /// the existence check made with `FileManager.fileExists` (the write then fails later, as `.cannotWrite`).
    func testADanglingLinkAtTheSidecarsPathIsNotReplaced() throws {
        let directory = try scratchDirectory()
        let url = directory.appendingPathComponent("dangling.mactem.h5")
        let target = directory.appendingPathComponent("nowhere.mactem.h5").path
        try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: target)
        XCTAssertTrue(isCannotOpen(refusal { try Sidecar.write(source: "s", lineage: "l", to: url) }))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: url.path), target)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [url.lastPathComponent])
    }

    // MARK: A write that ends badly, and the things it must not leave (Gate B, 2026-10-13)

    /// The close of the file is where a full disk shows (the data is flushed there): a write whose file cannot be completed
    /// throws, and the old sidecar is as it was, readable, with nothing else in the folder and nothing in the system's
    /// replacement directory. The disk that cannot take the file is a file size limit set around this one write (the write
    /// that crosses it fails, with SIGXFSZ ignored); both are restored before anything else runs. Red under: the close
    /// status ignored (the half-written file is then published over the good one).
    func testAWriteThatFailsWhileTheFileIsBeingBuiltLeavesTheOldSidecarAndNothingElse() throws {
        let directory = try scratchDirectory()
        let url = directory.appendingPathComponent("limit.mactem.h5")
        try Sidecar.write(source: "old source", lineage: "old lineage", to: url)
        let before = try bytes(url)
        var scratches: [(file: URL, directory: URL?)] = []
        let seams = Sidecar.WriteSeams(scratchMade: { scratches.append(($0, $1)) })
        let big = String(repeating: "q", count: 55_000)
        let failed = withFileSizeLimit(16 << 10) { refusal { try Sidecar.write(source: "s", lineage: big, to: url, seams: seams) } }
        guard case .cannotWrite? = failed else { return XCTFail("expected .cannotWrite, got \(String(describing: failed))") }
        XCTAssertEqual(try bytes(url), before, "the old sidecar changed")
        XCTAssertEqual(try Sidecar.read(url: url).source, "old source")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [url.lastPathComponent])
        XCTAssertEqual(scratches.count, 1)
        for scratch in scratches { assertGone(scratch.file, scratch.directory) }
    }

    /// Nothing is left in the system's item replacement directory, wherever a write ends: created, replaced, refused by the
    /// folder (the rename fails), refused because a file appeared. A write refused before its file is built makes no scratch
    /// at all. The scratch is the system's directory, never a sibling of the target (a sandboxed app may not make one).
    /// Red under: the cleanup removed; the scratch made beside the target.
    func testNothingIsLeftBehindWhereverAWriteEnds() throws {
        var scratches: [(file: URL, directory: URL?)] = []
        let seams = Sidecar.WriteSeams(scratchMade: { scratches.append(($0, $1)) })
        let directory = try scratchDirectory()
        let url = directory.appendingPathComponent("a.mactem.h5")
        try Sidecar.write(source: "s", lineage: "l", to: url, seams: seams)                      // created
        try Sidecar.write(source: "s2", lineage: "l2", to: url, seams: seams)                    // replaced
        XCTAssertEqual(scratches.count, 2)

        let foreign = directory.appendingPathComponent("f.mactem.h5")                            // refused before a scratch exists
        try plant(foreign, [.text("x", "y")])
        XCTAssertEqual(refusal { try Sidecar.write(source: "s", lineage: "l", to: foreign, seams: seams) }, .foreign)
        let newer = directory.appendingPathComponent("n.mactem.h5")
        try plant(newer, [.text(Sidecar.identityAttribute, "2"), .text(Sidecar.minReaderAttribute, "2")])
        XCTAssertEqual(refusal { try Sidecar.write(source: "s", lineage: "l", to: newer, seams: seams) }, .newerMinReader(found: 2, supported: 1))
        XCTAssertEqual(scratches.count, 2, "a refused write made a scratch file")

        let locked = try scratchDirectory()                                                       // the rename fails
        let kept = locked.appendingPathComponent("kept.mactem.h5")
        try Sidecar.write(source: "s", lineage: "l", to: kept, seams: seams)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        for target in [kept, locked.appendingPathComponent("new.mactem.h5")] {
            guard case .cannotWrite? = refusal({ try Sidecar.write(source: "s", lineage: "l", to: target, seams: seams) })
            else { return XCTFail("expected .cannotWrite in a folder that takes no rename") }
        }
        XCTAssertEqual(scratches.count, 5)

        let racing = Sidecar.WriteSeams(scratchMade: { scratches.append(($0, $1)) },                // a file appears
                                        beforePublish: { try? self.plant(directory.appendingPathComponent("r.mactem.h5"), [.text("x", "y")]) })
        guard case .cannotWrite? = refusal({ try Sidecar.write(source: "s", lineage: "l", to: directory.appendingPathComponent("r.mactem.h5"), seams: racing) })
        else { return XCTFail("expected .cannotWrite for the file that appeared") }
        XCTAssertEqual(scratches.count, 6)

        for scratch in scratches {
            XCTAssertNotNil(scratch.directory, "no system replacement directory was used: the scratch is beside its target")
            XCTAssertNotEqual(scratch.file.deletingLastPathComponent().standardizedFileURL.path,
                              directory.standardizedFileURL.path, "the scratch file is beside its target")
            assertGone(scratch.file, scratch.directory)
        }
    }

    private func assertGone(_ file: URL, _ directory: URL?, line: UInt = #line) {
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "left behind: \(file.path)", line: line)
        if let directory { XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path), "left behind: \(directory.path)", line: line) }
    }

    /// Runs `body` with the process's file size limit at `limit` bytes and SIGXFSZ ignored, then puts both back. A write
    /// that would take a file over the limit fails (EFBIG) instead of killing the process. The limit is process-wide, so the
    /// stretch is one synchronous call and nothing else of this test host is writing a large file in it.
    private func withFileSizeLimit<T>(_ limit: Int, _ body: () -> T) -> T {
        var original = rlimit()
        XCTAssertEqual(getrlimit(RLIMIT_FSIZE, &original), 0)
        let previous = signal(SIGXFSZ, SIG_IGN)
        var limited = rlimit(rlim_cur: rlim_t(limit), rlim_max: original.rlim_max)
        XCTAssertEqual(setrlimit(RLIMIT_FSIZE, &limited), 0)
        defer {
            XCTAssertEqual(setrlimit(RLIMIT_FSIZE, &original), 0)
            signal(SIGXFSZ, previous)
        }
        return body()
    }

    // MARK: The path, the memory and the handles (Gate B, 2026-10-13)

    /// A replace never takes the path away: the sidecar is renamed over, not removed and then put back, so a reader
    /// polling the path (a second window, Spotlight, a backup) never finds it missing. A thread stats the path as fast as
    /// it can while the sidecar is rewritten 100 times (50 KB each). Red under: the old file removed before the rename (a
    /// run of this mutant found it missing in thousands of polls).
    func testThePathIsNeverMissingWhileItIsReplaced() throws {
        let url = try scratchDirectory().appendingPathComponent("atomic.mactem.h5")
        let lineage = String(repeating: "y", count: 50_000)
        try Sidecar.write(source: "s", lineage: lineage, to: url)
        let watch = PathWatch(path: url.path)
        watch.start()
        defer { _ = watch.stop() }
        for index in 0..<100 { try Sidecar.write(source: "s\(index)", lineage: lineage, to: url) }
        let (polls, missing) = watch.stop()
        XCTAssertGreaterThan(polls, 1000, "the watching thread hardly ran")
        XCTAssertEqual(missing, 0, "the sidecar's path was missing in \(missing) of \(polls + missing) polls during a replace")
    }

    /// Every file a read or a write opens is closed, on the way through and on a refusal. HDF5 shares one descriptor between
    /// opens of the same file, so only DISTINCT files show a handle left open: 80 sidecars, each read, replaced and read
    /// again, beside 80 foreign HDF5 files and 80 files that are not HDF5, each read and offered a write. Descriptors
    /// grow by no more than a handful (a leak is one a file or more, 80 and up). An attribute handle left open keeps its
    /// file open too (HDF5 closes a file only when nothing in it is open), so this is also what pins the read's handles
    /// since the test of freed string buffers went (ADR 021): 160 descriptors over the 80 files when the attribute is never
    /// closed. The read's type and space handles are copies, tied to no file; leaking them costs a few hundred bytes a
    /// read, which nothing here sees. Red under: the read's close removed; the close of the existing file in `write` removed;
    /// the read's attribute handle never closed.
    func testNoFileDescriptorIsLeftOpen() throws {
        let directory = try scratchDirectory()
        var good = [URL](), foreign = [URL](), junk = [URL]()
        for index in 0..<80 {
            let sidecar = directory.appendingPathComponent("g\(index).mactem.h5")
            try Sidecar.write(source: "s", lineage: "l", to: sidecar)
            good.append(sidecar)
            let other = directory.appendingPathComponent("f\(index).mactem.h5")
            try plant(other, [.text("x", "y")])
            foreign.append(other)
            let notHDF5 = directory.appendingPathComponent("j\(index).mactem.h5")
            try Data("not HDF5".utf8).write(to: notHDF5)
            junk.append(notHDF5)
        }
        let before = openDescriptors()
        XCTAssertGreaterThan(before, 2, "the descriptor count does not work")
        for index in 0..<80 {
            _ = try Sidecar.read(url: good[index])
            try Sidecar.write(source: "a", lineage: "b", to: good[index])
            _ = try Sidecar.read(url: good[index])
            XCTAssertEqual(refusal { try Sidecar.read(url: foreign[index]) }, .foreign)
            XCTAssertEqual(refusal { try Sidecar.write(source: "a", lineage: "b", to: foreign[index]) }, .foreign)
            XCTAssertTrue(isCannotOpen(refusal { try Sidecar.read(url: junk[index]) }))
            XCTAssertTrue(isCannotOpen(refusal { try Sidecar.write(source: "a", lineage: "b", to: junk[index]) }))
        }
        let grown = openDescriptors() - before
        XCTAssertLessThan(grown, 16, "file descriptors grew by \(grown) over 80 files each read, replaced and refused")
    }

    /// How many descriptors this process has open (probed with `fcntl`, which needs no file system access, so a sandbox
    /// cannot turn the count into a constant zero).
    private func openDescriptors() -> Int {
        (0..<Int(getdtablesize())).filter { fcntl(Int32($0), F_GETFD) != -1 }.count
    }

    /// Polls `stat` on one path from its own thread, counting the polls that find it and the polls that do not.
    nonisolated private final class PathWatch: @unchecked Sendable {
        private let path: String
        private let lock = NSLock()
        private let ended = DispatchSemaphore(value: 0)
        private var running = true
        private var found = 0
        private var missing = 0

        init(path: String) { self.path = path }

        func start() {
            Thread { [self] in
                var info = stat()
                while true {
                    let present = stat(path, &info) == 0
                    lock.lock()
                    if present { found += 1 } else { missing += 1 }
                    let carryOn = running
                    lock.unlock()
                    guard carryOn else { break }
                }
                ended.signal()
            }.start()
        }

        /// Stops the thread, waits for it, and returns what it counted. Safe to call twice.
        func stop() -> (polls: Int, missing: Int) {
            lock.lock()
            let alreadyStopped = !running
            running = false
            lock.unlock()
            if !alreadyStopped { ended.wait() }
            lock.lock()
            defer { lock.unlock() }
            return (found, missing)
        }
    }

    /// The reasons read as sentences a caller can put after "macTEM could not open the sidecar: ", one to a refusal, the
    /// variable-length string's among them (it says what the file holds, that macTEM does not read it, and why). Red under:
    /// a reason without its full stop; two refusals given one reason.
    func testEveryRefusalHasAReason() {
        let all: [Sidecar.Refusal] = [
            .noSourceName, .sourceIsASidecar("a.mactem.h5"), .nameTooLong(units: 260), .library("x"), .cannotOpen("x"),
            .hdf5(operation: "reading", detail: "x"), .foreign, .missingAttribute("m"), .malformedAttribute("m"),
            .newerMinReader(found: 2, supported: 1), .newerSchema(found: 2, supported: 1), .notPermitted("x"),
            .variableLengthString("m"), .stringTooLong(attribute: "m", bytes: 9), .invalidUTF8("m"),
            .embeddedNUL("m"), .sidecarTooLarge(bytes: 60_001), .denseAttributeStorage, .cannotWrite(operation: "creating", detail: "x"),
        ]
        for refusal in all { XCTAssertTrue(refusal.reason.hasSuffix("."), refusal.reason) }
        XCTAssertTrue(Sidecar.Refusal.variableLengthString("mactem_lineage").reason.contains("mactem_lineage"))
        XCTAssertEqual(Set(all.map(\.reason)).count, all.count, "two refusals share a reason")
    }
}
