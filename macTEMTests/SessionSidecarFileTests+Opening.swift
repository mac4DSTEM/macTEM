//
//  SessionSidecarFileTests+Opening.swift
//  The sidecar layer refuses what it must not read as its own: a foreign HDF5 file, a newer minimum reader, a file that cannot be opened.
//  Fixtures: SessionSidecarFileTests.swift.
//

import XCTest
import Darwin
import FormatoHDF5
import TEMCore

nonisolated extension SessionSidecarFileTests {
    // MARK: Foreign files (never read as ours, never overwritten)

    /// An HDF5 file without the identity marker is foreign on read. Red under: the identity read as "1" when absent.
    func testAForeignHDF5FileIsRefusedOnRead() throws {
        let url = try scratchDirectory().appendingPathComponent("f.mactem.h5")
        try plant(url, [.text("some_other_attribute", "hello"), .text(Sidecar.sourceAttribute, "{}")])
        XCTAssertEqual(refusal { try Sidecar.read(url: url) }, .foreign)
    }

    /// ... and a write never replaces it: refused by name, the file byte for byte as it was. Red under: the check of the
    /// existing file removed from `write`.
    func testAForeignHDF5FileIsNeverOverwritten() throws {
        let url = try scratchDirectory().appendingPathComponent("f.mactem.h5")
        try plant(url, [.text("some_other_attribute", "hello")])
        let before = try bytes(url)
        XCTAssertEqual(refusal { try Sidecar.write(source: "s", lineage: "l", to: url) }, .foreign)
        XCTAssertEqual(try bytes(url), before)
    }

    // MARK: The minimum reader (P2)

    /// A minimum reader newer than this build's is refused by name, with both numbers, BEFORE anything else is read: the
    /// source here is an integer and the lineage 50,000 bytes, the first of which would be its own refusal if it were read first.
    /// Red under: the check moved after the source and the lineage are read.
    func testANewerMinimumReaderIsRefusedBeforeAnythingElseIsRead() throws {
        let url = try scratchDirectory().appendingPathComponent("n.mactem.h5")
        try plant(url, [
            .text(Sidecar.identityAttribute, "2"), .text(Sidecar.minReaderAttribute, "2"),
            .integer(Sidecar.sourceAttribute, 7),
            .bytes(Sidecar.lineageAttribute, [UInt8](repeating: 0x61, count: 50_000)),
        ])
        XCTAssertEqual(refusal { try Sidecar.read(url: url) }, .newerMinReader(found: 2, supported: 1))
    }

    /// It is the MINIMUM reader that gates, not the writer's schema: a newer writer whose file this build can still read
    /// (schema 2, minimum reader 1) is read, and says which schema wrote it. Red under: the gate on the identity value.
    func testANewerWriterWhoseMinimumReaderIsOursIsRead() throws {
        let url = try scratchDirectory().appendingPathComponent("w.mactem.h5")
        try plant(url, [
            .text(Sidecar.identityAttribute, "2"), .text(Sidecar.minReaderAttribute, "1"),
            .text(Sidecar.sourceAttribute, "s"), .text(Sidecar.lineageAttribute, "l"),
        ])
        XCTAssertEqual(try Sidecar.read(url: url), Sidecar.Contents(schema: 2, minReader: 1, source: "s", lineage: "l"))
    }

    /// A write does not replace a sidecar this build cannot read: refused by name, the file as it was. Red under: the write
    /// checking the identity but not the minimum reader of the file it replaces.
    func testANewerMinimumReaderSidecarIsNeverOverwritten() throws {
        let url = try scratchDirectory().appendingPathComponent("n.mactem.h5")
        try plant(url, [
            .text(Sidecar.identityAttribute, "2"), .text(Sidecar.minReaderAttribute, "2"),
            .text(Sidecar.sourceAttribute, "s"), .text(Sidecar.lineageAttribute, "l"),
        ])
        let before = try bytes(url)
        XCTAssertEqual(refusal { try Sidecar.write(source: "x", lineage: "y", to: url) }, .newerMinReader(found: 2, supported: 1))
        XCTAssertEqual(try bytes(url), before)
    }

    /// The minimum reader gates before the identity's own spelling is judged: a future schema that spells its identity
    /// differently ("v2") still says, in its minimum reader, that this build cannot read it, and is refused as a newer file,
    /// not as a garbled one — on read and on write, the file left as it was. Red under: the identity's form judged before
    /// the minimum reader.
    func testANewerMinimumReaderIsNamedWhateverTheIdentityIsSpelledAs() throws {
        let directory = try scratchDirectory()
        for (index, identity) in ["v2", "two", "02", ""].enumerated() {
            let url = directory.appendingPathComponent("v\(index).mactem.h5")
            try plant(url, [.text(Sidecar.identityAttribute, identity), .text(Sidecar.minReaderAttribute, "2"),
                            .text(Sidecar.sourceAttribute, "s"), .text(Sidecar.lineageAttribute, "l")])
            let before = try bytes(url)
            XCTAssertEqual(refusal { try Sidecar.read(url: url) }, .newerMinReader(found: 2, supported: 1), "identity \"\(identity)\"")
            XCTAssertEqual(refusal { try Sidecar.write(source: "x", lineage: "y", to: url) }, .newerMinReader(found: 2, supported: 1),
                           "write over identity \"\(identity)\"")
            XCTAssertEqual(try bytes(url), before)
        }
    }

    /// A marker that is not a whole number from 1 in its plain spelling is garbled, not "readable by luck"; a missing
    /// minimum reader beside an identity is named too. Red under: the plain-spelling check removed ("01" and "+1" then
    /// read as 1).
    func testAGarbledOrMissingMarkerIsRefusedByName() throws {
        let directory = try scratchDirectory()
        for (index, garbled) in ["", "one", "01", "+1", "0", "-1", "1.0", " 1", "1\n"].enumerated() {
            let url = directory.appendingPathComponent("g\(index).mactem.h5")
            try plant(url, [.text(Sidecar.identityAttribute, "1"), .text(Sidecar.minReaderAttribute, garbled)])
            XCTAssertEqual(refusal { try Sidecar.read(url: url) }, .malformedAttribute(Sidecar.minReaderAttribute), "min reader \"\(garbled)\"")
        }
        let identity = directory.appendingPathComponent("i.mactem.h5")
        try plant(identity, [.text(Sidecar.identityAttribute, "v1"), .text(Sidecar.minReaderAttribute, "1")])
        XCTAssertEqual(refusal { try Sidecar.read(url: identity) }, .malformedAttribute(Sidecar.identityAttribute))
        let missing = directory.appendingPathComponent("m.mactem.h5")
        try plant(missing, [.text(Sidecar.identityAttribute, "1")])
        XCTAssertEqual(refusal { try Sidecar.read(url: missing) }, .missingAttribute(Sidecar.minReaderAttribute))
    }

    /// A newer WRITER whose minimum reader is ours reads (above) but is not written over: a replace would drop the group and
    /// the attributes this build cannot parse and mark the file as the older schema. Refused by name, the file as it was.
    /// Red under: the schema of the file being replaced not looked at in `write`.
    func testASidecarOfANewerSchemaIsNeverOverwritten() throws {
        let directory = try scratchDirectory()
        let url = directory.appendingPathComponent("w.mactem.h5")
        try plant(url, [
            .text(Sidecar.identityAttribute, "2"), .text(Sidecar.minReaderAttribute, "1"),
            .text(Sidecar.sourceAttribute, "s"), .text(Sidecar.lineageAttribute, "l"), .text("mactem_future_extra", "kept"),
        ])
        let before = try bytes(url)
        XCTAssertEqual(refusal { try Sidecar.write(source: "x", lineage: "y", to: url) }, .newerSchema(found: 2, supported: 1))
        XCTAssertEqual(try bytes(url), before)
        XCTAssertEqual(try Sidecar.read(url: url), Sidecar.Contents(schema: 2, minReader: 1, source: "s", lineage: "l"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [url.lastPathComponent])
    }

    /// Any newer schema, not only the next one. Red under: the check made for exactly one schema newer (the re-verifier's
    /// N7g, 2026-10-14).
    func testASidecarSeveralSchemasNewerIsNeverOverwrittenEither() throws {
        let directory = try scratchDirectory()
        let url = directory.appendingPathComponent("w3.mactem.h5")
        try plant(url, [.text(Sidecar.identityAttribute, "3"), .text(Sidecar.minReaderAttribute, "1"),
                        .text(Sidecar.sourceAttribute, "s"), .text(Sidecar.lineageAttribute, "l")])
        let before = try bytes(url)
        XCTAssertEqual(refusal { try Sidecar.write(source: "x", lineage: "y", to: url) }, .newerSchema(found: 3, supported: 1))
        XCTAssertEqual(try bytes(url), before)
    }

    // MARK: A file that cannot be opened (P3)

    /// Bytes that are not HDF5 — random bytes, text, an empty file, a folder — and a path that holds nothing are all
    /// `.cannotOpen`, never a result: the layer has no "no sidecar" answer. Red under: a missing file answered with an
    /// empty `Contents`; an open failure reported as `.foreign`.
    func testAFileThatCannotBeOpenedIsRefusedNeverAnswered() throws {
        let directory = try scratchDirectory()
        let random = directory.appendingPathComponent("random.mactem.h5")
        try Data((0..<4096).map { UInt8(truncatingIfNeeded: $0 &* 131 &+ 7) }).write(to: random)
        let text = directory.appendingPathComponent("text.mactem.h5")
        try Data("this is not HDF5\n".utf8).write(to: text)
        let empty = directory.appendingPathComponent("empty.mactem.h5")
        try Data().write(to: empty)
        let folder = directory.appendingPathComponent("folder.mactem.h5", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let missing = directory.appendingPathComponent("missing.mactem.h5")
        for url in [random, text, empty, folder, missing] {
            XCTAssertTrue(isCannotOpen(refusal { try Sidecar.read(url: url) }), url.lastPathComponent)
        }
    }

    /// A sidecar cut short is the same: refused, not partly read. Red under: as above.
    func testATruncatedSidecarCannotBeOpened() throws {
        let directory = try scratchDirectory()
        let url = directory.appendingPathComponent("t.mactem.h5")
        try Sidecar.write(source: "s", lineage: lineageLike(bytes: 50_000), to: url)
        let size = try bytes(url).count
        XCTAssertGreaterThan(size, 50_000)
        for length in [size / 2, 512, 8] {
            let cut = directory.appendingPathComponent("cut\(length).mactem.h5")
            try bytes(url).prefix(length).write(to: cut)
            XCTAssertTrue(isCannotOpen(refusal { try Sidecar.read(url: cut) }), "cut to \(length) of \(size) bytes")
        }
    }

    /// The refusal carries HDF5's own reason, from its error stack, not a stand-in: for a path that holds nothing it is the
    /// operating system's message. Red under: the detail dropped (every open failure then says "HDF5 gave no reason").
    func testACannotOpenRefusalCarriesTheReasonHDF5Gave() throws {
        let directory = try scratchDirectory()
        let junk = directory.appendingPathComponent("junk.mactem.h5")
        try Data("this is not HDF5\n".utf8).write(to: junk)
        let missing = directory.appendingPathComponent("missing.mactem.h5")
        for url in [junk, missing] {
            guard case .cannotOpen(let detail)? = refusal({ try Sidecar.read(url: url) }) else {
                XCTFail("expected .cannotOpen for \(url.lastPathComponent)"); continue
            }
            XCTAssertFalse(detail.isEmpty, url.lastPathComponent)
            XCTAssertFalse(detail.contains("gave no reason"), "\(url.lastPathComponent): \(detail)")
        }
        guard case .cannotOpen(let detail)? = refusal({ try Sidecar.read(url: missing) }) else { return }
        XCTAssertTrue(detail.contains("No such file or directory"), detail)
    }

    /// A write does not replace what it cannot identify: a file that cannot be opened is refused and left as it was, not
    /// replaced because "it is broken anyway". Red under: the open failure of the existing file ignored in `write`.
    func testAFileThatCannotBeOpenedIsNeverOverwritten() throws {
        let url = try scratchDirectory().appendingPathComponent("junk.mactem.h5")
        try Data("not HDF5, but someone's file\n".utf8).write(to: url)
        let before = try bytes(url)
        XCTAssertTrue(isCannotOpen(refusal { try Sidecar.write(source: "s", lineage: "l", to: url) }))
        XCTAssertEqual(try bytes(url), before)
    }

    /// A file the system does not let this process read is `.notPermitted`, named apart from `.cannotOpen` so the app can ask
    /// for the file (the sandbox grants only what the user chose): a mode-000 file, on a read and on the check a write makes
    /// (which leaves the file as it was). A path that holds nothing and a file that is not HDF5 stay `.cannotOpen` (P3). The
    /// sentence says macOS does not let macTEM read it. Red under: the probe removed (a denied read is `.cannotOpen`); a
    /// missing file or any failed probe called `.notPermitted`; EACCES left out.
    func testAFileTheSystemDoesNotLetUsReadIsNotPermittedAndNeverOverwritten() throws {
        XCTAssertNotEqual(geteuid(), 0, "root reads a mode-000 file; run this as a user")
        let directory = try scratchDirectory()
        let url = directory.appendingPathComponent("denied.mactem.h5")
        try Sidecar.write(source: "{}", lineage: "[]", to: url)
        let before = try bytes(url)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: url.path)
        addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path) }
        guard case .notPermitted(let detail)? = refusal({ try Sidecar.read(url: url) }) else {
            return XCTFail("expected .notPermitted")
        }
        XCTAssertTrue(detail.contains("Permission denied"), detail)
        guard case .notPermitted? = refusal({ try Sidecar.write(source: "s", lineage: "l", to: url) }) else {
            return XCTFail("a write over it must be refused as not permitted")
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        XCTAssertEqual(try bytes(url), before, "the file was left as it was")
        let junk = directory.appendingPathComponent("junk.mactem.h5")
        try Data("not HDF5\n".utf8).write(to: junk)
        XCTAssertTrue(isCannotOpen(refusal { try Sidecar.read(url: junk) }))
        XCTAssertTrue(isCannotOpen(refusal { try Sidecar.read(url: directory.appendingPathComponent("missing.mactem.h5")) }))
        XCTAssertTrue(Sidecar.Refusal.notPermitted("Permission denied").reason.contains("does not let macTEM read it"))
    }
}
