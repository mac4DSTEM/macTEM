//
//  SessionSidecarFileTests+Attributes.swift
//  What a stored root attribute may be: its type, shape, size, storage, padding and encoding, each refusal by name.
//  Fixtures: SessionSidecarFileTests.swift.
//

import XCTest
import Darwin
import FormatoHDF5
import TEMCore

nonisolated extension SessionSidecarFileTests {
    // MARK: What a stored attribute may be

    /// A variable-length string is refused BY NAME, from its type, before any `H5Aread` (ADR 021): the global heap that holds
    /// its characters has no checksum, and reading a damaged one can spin forever. Each of the four attributes, planted
    /// variable-length in a sidecar that is otherwise valid (the same sidecar with the attribute fixed-length reads, the
    /// control, so the refusal is the type's and nothing else's). The identity is refused as a variable-length string, not
    /// as `.foreign` (its being there is what makes a file ours), the minimum reader before the source is looked at. Red
    /// under: the variable-length check removed (the string is then "read" as the eight bytes of a pointer, and refused as
    /// something else, or not refused); the check made a `.malformedAttribute`.
    func testAVariableLengthAttributeIsRefusedByNameWhicheverOfTheFourItIs() throws {
        let directory = try scratchDirectory()
        let names = [Sidecar.identityAttribute, Sidecar.minReaderAttribute, Sidecar.sourceAttribute, Sidecar.lineageAttribute]
        let values = ["1", "1", "{\"file\":\"scan.dm4\"}", "{\"nodes\":[]}"]
        func sidecar(variable: String?) -> [Planted] {
            zip(names, values).map { name, value in name == variable ? .variableText(name, value) : .text(name, value) }
        }
        let control = directory.appendingPathComponent("control.mactem.h5")
        try plant(control, sidecar(variable: nil))
        XCTAssertEqual(try Sidecar.read(url: control), Sidecar.Contents(schema: 1, minReader: 1, source: values[2], lineage: values[3]))
        for name in names {
            let url = directory.appendingPathComponent("\(name).mactem.h5")
            try plant(url, sidecar(variable: name))
            XCTAssertEqual(refusal { try Sidecar.read(url: url) }, .variableLengthString(name), "\(name) variable-length")
        }
        // An empty variable-length string is a variable-length string too, not an empty text.
        let empty = directory.appendingPathComponent("empty.mactem.h5")
        try plant(empty, [.text(Sidecar.identityAttribute, "1"), .text(Sidecar.minReaderAttribute, "1"),
                          .variableText(Sidecar.lineageAttribute, "")])
        XCTAssertEqual(refusal { try Sidecar.read(url: empty) }, .variableLengthString(Sidecar.lineageAttribute))
    }

    /// A sidecar written by slice A, whose attributes are variable-length, is never replaced by a write: the check of the
    /// file that is there reads its identity, and refuses the variable-length string by name, the file byte for byte as it
    /// was and nothing else in the folder. All four variable-length (slice A's own files), and the identity or the minimum
    /// reader alone (the two a write reads). Red under: the variable-length check removed (the write then refuses it as
    /// something else); the check made a `.malformedAttribute`; the check of the existing file removed from `write`.
    func testAVariableLengthSidecarIsNeverOverwrittenByAWrite() throws {
        let directory = try scratchDirectory()
        let cases: [(String, [Planted], String)] = [
            ("all", [.variableText(Sidecar.identityAttribute, "1"), .variableText(Sidecar.minReaderAttribute, "1"),
                     .variableText(Sidecar.sourceAttribute, "old source"), .variableText(Sidecar.lineageAttribute, "old lineage")],
             Sidecar.identityAttribute),
            ("identity", [.variableText(Sidecar.identityAttribute, "1"), .text(Sidecar.minReaderAttribute, "1"),
                          .text(Sidecar.sourceAttribute, "s"), .text(Sidecar.lineageAttribute, "l")], Sidecar.identityAttribute),
            ("minreader", [.text(Sidecar.identityAttribute, "1"), .variableText(Sidecar.minReaderAttribute, "1"),
                           .text(Sidecar.sourceAttribute, "s"), .text(Sidecar.lineageAttribute, "l")], Sidecar.minReaderAttribute),
        ]
        for (label, attributes, refused) in cases {
            let url = directory.appendingPathComponent("\(label).mactem.h5")
            try plant(url, attributes)
            let before = try bytes(url)
            XCTAssertEqual(refusal { try Sidecar.write(source: "new source", lineage: "new lineage", to: url) },
                           .variableLengthString(refused), label)
            XCTAssertEqual(try bytes(url), before, "\(label): the variable-length sidecar was replaced")
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted(),
                       cases.map { "\($0.0).mactem.h5" }.sorted(), "a write left something in the folder")
    }

    /// A variable-length string is refused from its type and its characters are never fetched. The sidecars here have the
    /// signature of their global heap broken, where an `H5Aread` of the string fails at once (the damaged object SIZE that
    /// makes it spin forever, ADR 021, cannot be planted in a test that must be able to fail: the signature can). So the
    /// refusal is the variable-length one, in each of the four attributes, on a read and on the check a write makes; had the
    /// string been read first, the refusal would be `.hdf5`, reading the attribute. Each file really has its heap broken
    /// (counted), and the write leaves the file as it was. Red under: the variable-length check moved after the read; the
    /// check removed.
    func testAVariableLengthStringIsRefusedWithoutItsGlobalHeapBeingRead() throws {
        let directory = try scratchDirectory()
        let names = [Sidecar.identityAttribute, Sidecar.minReaderAttribute, Sidecar.sourceAttribute, Sidecar.lineageAttribute]
        let values = ["1", "1", "{}", "{}"]
        for name in names {
            let url = directory.appendingPathComponent("\(name).mactem.h5")
            try plant(url, zip(names, values).map { $0 == name ? .variableText($0, $1) : .text($0, $1) })
            XCTAssertGreaterThan(try breakGlobalHeaps(in: url), 0, "\(name): no global heap to break")
            XCTAssertEqual(refusal { try Sidecar.read(url: url) }, .variableLengthString(name), "\(name) on read")
        }
        let slice = directory.appendingPathComponent("sliceA.mactem.h5")
        try plant(slice, zip(names, values).map { .variableText($0, $1) })
        XCTAssertGreaterThan(try breakGlobalHeaps(in: slice), 0)
        let before = try bytes(slice)
        XCTAssertEqual(refusal { try Sidecar.write(source: "s", lineage: "l", to: slice) }, .variableLengthString(Sidecar.identityAttribute))
        XCTAssertEqual(try bytes(slice), before)
    }

    /// An integer, which is not a string at all, is refused by name, in the lineage and in the source. (A fixed-length
    /// string used to be on this list: since ADR 021 it is the right kind, and a variable-length one has its own
    /// refusal, above.) Red under: the class check removed (the integer's four bytes are then read as text).
    func testAnAttributeThatIsNotAStringIsRefused() throws {
        let directory = try scratchDirectory()
        for (label, name) in [("lineage", Sidecar.lineageAttribute), ("source", Sidecar.sourceAttribute)] {
            let url = directory.appendingPathComponent("\(label).mactem.h5")
            try plant(url, [.text(Sidecar.identityAttribute, "1"), .text(Sidecar.minReaderAttribute, "1"), .integer(name, 5)])
            XCTAssertEqual(refusal { try Sidecar.read(url: url) }, .malformedAttribute(name), label)
        }
    }

    /// An array of one fixed-length string is not a scalar. Red under: the rank and element-count check removed (a one-element
    /// array reads safely into the one-element buffer, so this case alone is safe to mutate).
    func testAnArrayOfOneStringIsNotAScalar() throws {
        let url = try scratchDirectory().appendingPathComponent("a.mactem.h5")
        try plant(url, [.text(Sidecar.identityAttribute, "1"), .text(Sidecar.minReaderAttribute, "1"),
                        .textArray(Sidecar.lineageAttribute, ["one"])])
        XCTAssertEqual(refusal { try Sidecar.read(url: url) }, .malformedAttribute(Sidecar.lineageAttribute))
    }

    /// Arrays of other lengths are refused before any read: an array of two would be written over the one-element buffer.
    /// Red under: the rank and count check removed with the buffer made big enough for any array (the elements read
    /// together as one text).
    func testAnArrayOfSeveralStringsIsRefusedBeforeItIsRead() throws {
        let directory = try scratchDirectory()
        for (index, values) in [["a", "b"], [String](), ["a", "b", "c", "d", "e"]].enumerated() {
            let url = directory.appendingPathComponent("a\(index).mactem.h5")
            try plant(url, [.text(Sidecar.identityAttribute, "1"), .text(Sidecar.minReaderAttribute, "1"),
                            .textArray(Sidecar.sourceAttribute, values)])
            XCTAssertEqual(refusal { try Sidecar.read(url: url) }, .malformedAttribute(Sidecar.sourceAttribute), "\(values.count) strings")
        }
    }

    /// An array of variable-length strings is refused as not a scalar, before its type is looked at and long before any
    /// read, whatever its length (a variable-length array is as much a global-heap read as a scalar). Red under: the
    /// rank and element-count check removed (the array then reaches the variable-length check and is refused as that, a
    /// different refusal).
    func testAnArrayOfVariableLengthStringsIsRefusedAsNotAScalar() throws {
        let directory = try scratchDirectory()
        for (index, values) in [["one"], ["a", "b"], [String]()].enumerated() {
            let url = directory.appendingPathComponent("v\(index).mactem.h5")
            try plant(url, [.text(Sidecar.identityAttribute, "1"), .text(Sidecar.minReaderAttribute, "1"),
                            .variableTextArray(Sidecar.lineageAttribute, values)])
            XCTAssertEqual(refusal { try Sidecar.read(url: url) }, .malformedAttribute(Sidecar.lineageAttribute), "\(values.count) strings")
        }
    }

    /// The writer's cap on a string is exact: 4 MiB + 1 is refused with its size, in the source and in the lineage, creating
    /// nothing (ADR 023 a puts 60,000 bytes of text in all far below it, so these refusals are the per-string check that comes
    /// first). A stored text of 4 MiB, 4 MiB + 1 or 5 MiB is in dense attribute storage and the reader refuses the file as
    /// that, `.denseAttributeStorage`, before any attribute is looked at (ADR 023 d'); the reader's own 4 MiB cap on a
    /// declared size is therefore unreachable and is not tested. Red under: the cap removed from the write; the writer's
    /// comparison made strict (`>=`); the dense refusal removed (the 4 MiB text is then read whole).
    func testTheFourMebibyteWriteCapIsExactAndAStoredFourMebibyteIsRefusedAsDense() throws {
        let directory = try scratchDirectory()
        let cap = Sidecar.maxStringBytes
        XCTAssertEqual(cap, 4 << 20)
        let text = String(repeating: "x", count: cap)

        for (label, attribute, size) in [("lineage-cap", Sidecar.lineageAttribute, cap), ("lineage+1", Sidecar.lineageAttribute, cap + 1),
                                         ("lineage5", Sidecar.lineageAttribute, 5 << 20), ("source5", Sidecar.sourceAttribute, 5 << 20)] {
            let url = directory.appendingPathComponent("\(label).mactem.h5")
            try plant(url, [.text(Sidecar.identityAttribute, "1"), .text(Sidecar.minReaderAttribute, "1"),
                            .bytes(attribute, [UInt8](repeating: 0x61, count: size))])
            XCTAssertEqual(refusal { try Sidecar.read(url: url) }, .denseAttributeStorage, label)
        }

        let none = directory.appendingPathComponent("none.mactem.h5")
        XCTAssertEqual(refusal { try Sidecar.write(source: "s", lineage: text + "x", to: none) },
                       .stringTooLong(attribute: Sidecar.lineageAttribute, bytes: cap + 1))
        XCTAssertEqual(refusal { try Sidecar.write(source: text + "x", lineage: "l", to: none) },
                       .stringTooLong(attribute: Sidecar.sourceAttribute, bytes: cap + 1))
        XCTAssertFalse(FileManager.default.fileExists(atPath: none.path))
    }

    /// ADR 023 d', P3. A sidecar whose root keeps its attributes in dense storage (a fractal heap and a B-tree) is refused by
    /// name, `.denseAttributeStorage`, from the root's object header alone, before any attribute is opened: whichever of the
    /// four attributes is the big one, at 65,600 bytes, 100,000, 4 MiB and 4 MiB + 1; and a file whose attributes are many
    /// (44 small ones, which the library also moves to dense storage) the same. "Before any attribute is opened" is seen in
    /// the order: a dense file with no identity marker, with a newer minimum reader, or with a variable-length identity is
    /// refused as dense, where the same file at 30,000 bytes (compact) is `.foreign`, `.newerMinReader` and
    /// `.variableLengthString`. The replace check of a save reads the same header, so a save over a dense file is refused
    /// as dense and leaves its bytes. Red under: the check removed (the big text is read, or refused as something else); the
    /// check after the first attribute is looked at (the foreign, newer and variable-length files are then those refusals);
    /// the attribute-message bit tested the wrong way round (every compact file is then refused: other tests); the header
    /// read as `META_SIZE` (the bit is then never set).
    func testADenseAttributeStorageSidecarIsRefusedByNameBeforeAnyAttributeIsLookedAt() throws {
        let directory = try scratchDirectory()
        let cap = Sidecar.maxStringBytes
        let names = [Sidecar.identityAttribute, Sidecar.minReaderAttribute, Sidecar.sourceAttribute, Sidecar.lineageAttribute]
        func sidecar(_ name: String, holding bytes: [UInt8]) -> [Planted] {
            names.map { $0 == name ? .bytes($0, bytes) : .text($0, $0 == Sidecar.sourceAttribute ? "{}" : "1") }
        }
        for name in names {
            for size in [65_600, 100_000, cap, cap + 1] {
                let url = directory.appendingPathComponent("dense-\(name)-\(size).mactem.h5")
                // 0xFF is not UTF-8 and the cap + 1 text is over the reader's string cap: each would be its own refusal if looked at
                try plant(url, sidecar(name, holding: [UInt8](repeating: 0xFF, count: size)))
                XCTAssertEqual(refusal { try Sidecar.read(url: url) }, .denseAttributeStorage, "\(name) at \(size) B")
            }
        }
        // many small attributes: the library moves them to dense storage too
        let many = directory.appendingPathComponent("many.mactem.h5")
        try plant(many, [.text(Sidecar.identityAttribute, "1"), .text(Sidecar.minReaderAttribute, "1"), .text(Sidecar.sourceAttribute, "{}"),
                         .text(Sidecar.lineageAttribute, "{}")] + (0..<40).map { .text("extra_\($0)", "v") })
        XCTAssertEqual(refusal { try Sidecar.read(url: many) }, .denseAttributeStorage, "44 attributes")

        // the order: dense before the identity, the minimum reader or the type of an attribute is looked at
        let big = String(repeating: "y", count: 100_000), small = String(repeating: "y", count: 30_000)
        let cases: [(String, (String) -> [Planted], Sidecar.Refusal)] = [
            ("foreign", { [.text("title", "hello"), .text(Sidecar.lineageAttribute, $0)] }, .foreign),
            ("newer", { [.text(Sidecar.identityAttribute, "1"), .text(Sidecar.minReaderAttribute, "2"), .text(Sidecar.lineageAttribute, $0)] },
             .newerMinReader(found: 2, supported: 1)),
            ("variable", { [.variableText(Sidecar.identityAttribute, "1"), .text(Sidecar.minReaderAttribute, "1"), .text(Sidecar.lineageAttribute, $0)] },
             .variableLengthString(Sidecar.identityAttribute)),
        ]
        for (label, attributes, compactRefusal) in cases {
            let dense = directory.appendingPathComponent("order-\(label)-dense.mactem.h5")
            try plant(dense, attributes(big))
            XCTAssertEqual(refusal { try Sidecar.read(url: dense) }, .denseAttributeStorage, "\(label), dense")
            let compact = directory.appendingPathComponent("order-\(label)-compact.mactem.h5")
            try plant(compact, attributes(small))
            XCTAssertEqual(refusal { try Sidecar.read(url: compact) }, compactRefusal, "\(label), the same file compact")
        }

        // the replace check of a save reads the same header: refused as dense, the file as it was
        let before = try bytes(many)
        XCTAssertEqual(refusal { try Sidecar.write(source: "{}", lineage: "{}", to: many) }, .denseAttributeStorage)
        XCTAssertEqual(try bytes(many), before)
        let reason = Sidecar.Refusal.denseAttributeStorage.reason
        XCTAssertTrue(reason.contains("dense") && reason.contains("delete the file"), reason)
    }

    /// ADR 023 d', the other side: what is not dense is not refused as dense. A root with no attributes at all (an HDF5 file
    /// that is not a sidecar) and a root with attributes that are not ours are `.foreign`, as before; a sidecar of eight
    /// attributes (four of ours and four more, the most the header keeps) and every file the writer writes up to the cap read
    /// whole. Red under: the attribute count not asked (the empty root is refused as dense); the attribute-message bit tested
    /// the wrong way round (the compact files are refused as dense); the header read as `META_SIZE` (the bit is then never set).
    func testACompactRootAndARootWithoutAttributesAreNotTakenForDenseStorage() throws {
        let directory = try scratchDirectory()
        let empty = directory.appendingPathComponent("empty.mactem.h5")
        try plant(empty, [])
        XCTAssertEqual(refusal { try Sidecar.read(url: empty) }, .foreign)
        let others = directory.appendingPathComponent("others.mactem.h5")
        try plant(others, [.text("title", "hello"), .text("author", "x"), .integer("version", 3)])
        XCTAssertEqual(refusal { try Sidecar.read(url: others) }, .foreign)
        let eight = directory.appendingPathComponent("eight.mactem.h5")
        try plant(eight, [.text(Sidecar.identityAttribute, "1"), .text(Sidecar.minReaderAttribute, "1"), .text(Sidecar.sourceAttribute, "{}"),
                          .text(Sidecar.lineageAttribute, "{\"n\":1}")] + (0..<4).map { .text("extra_\($0)", "v") })
        XCTAssertEqual(try Sidecar.read(url: eight), Sidecar.Contents(schema: 1, minReader: 1, source: "{}", lineage: "{\"n\":1}"))
        let written = directory.appendingPathComponent("written.mactem.h5")
        let lineage = String(repeating: "z", count: 59_000)
        try Sidecar.write(source: "{}", lineage: lineage, to: written)
        XCTAssertEqual(try Sidecar.read(url: written).lineage, lineage)
        // a replace over a compact sidecar is allowed, and the file read again is the new one
        try Sidecar.write(source: "{}", lineage: "{}", to: eight)
        XCTAssertEqual(try Sidecar.read(url: eight).lineage, "{}")
    }

    /// Text that is not UTF-8 is refused by name, not repaired into text with a replacement character. Red under: the
    /// checked conversion replaced by `String(decoding:)`, which repairs.
    func testInvalidUTF8IsRefused() throws {
        let url = try scratchDirectory().appendingPathComponent("u.mactem.h5")
        try plant(url, [.text(Sidecar.identityAttribute, "1"), .text(Sidecar.minReaderAttribute, "1"),
                        .bytes(Sidecar.lineageAttribute, [0x7B, 0xC3, 0x28, 0xFF, 0x7D])])   // {, a broken Ã, (, 0xFF, }
        XCTAssertEqual(refusal { try Sidecar.read(url: url) }, .invalidUTF8(Sidecar.lineageAttribute))
    }

    /// The character set is not part of the contract on read: an ASCII-charset fixed-length string (what a writer that
    /// does not mark UTF-8 produces, h5py's np.bytes_ among them) is read as the text it is, in the source and in the
    /// lineage and in both markers. The bytes are still checked as UTF-8. Red under: a read that refuses any character
    /// set but UTF-8.
    func testAnASCIICharsetStringIsRead() throws {
        let url = try scratchDirectory().appendingPathComponent("ascii.mactem.h5")
        try plant(url, [.asciiText(Sidecar.identityAttribute, "1"), .asciiText(Sidecar.minReaderAttribute, "1"),
                        .asciiText(Sidecar.sourceAttribute, "{\"file\":\"scan.dm4\"}"), .asciiText(Sidecar.lineageAttribute, "{\"v\":1}")])
        XCTAssertEqual(try Sidecar.read(url: url),
                       Sidecar.Contents(schema: 1, minReader: 1, source: "{\"file\":\"scan.dm4\"}", lineage: "{\"v\":1}"))
    }

    /// The text is what comes before the first NUL, and after it there is nothing but NULs: the padding. h5py pads a short
    /// text out to the field's width with NULs (`string_dtype("utf-8", length: N)`), so a field of 12 bytes holding five
    /// reads as the five, as does a field of only NULs (an empty text) and one NUL after the text (the form a C writer
    /// gives). The markers read the same: "1" in a field of 4 is the schema 1. Red under: the text taken to the full size
    /// ignoring the NUL (the padding then comes back as part of the text).
    func testTextPaddedWithSeveralNULsReadsAsTheText() throws {
        let directory = try scratchDirectory()
        let url = directory.appendingPathComponent("padded.mactem.h5")
        try plant(url, [.paddedText(Sidecar.identityAttribute, "1", size: 4), .paddedText(Sidecar.minReaderAttribute, "1", size: 4),
                        .paddedText(Sidecar.sourceAttribute, "\u{00C5}\u{00B5}x", size: 12),
                        .paddedText(Sidecar.lineageAttribute, "{\"v\":1}", size: 64)])
        XCTAssertEqual(try Sidecar.read(url: url), Sidecar.Contents(schema: 1, minReader: 1, source: "\u{00C5}\u{00B5}x", lineage: "{\"v\":1}"))

        let empty = directory.appendingPathComponent("allnul.mactem.h5")
        try plant(empty, [.text(Sidecar.identityAttribute, "1"), .text(Sidecar.minReaderAttribute, "1"),
                          .paddedText(Sidecar.sourceAttribute, "", size: 8), .paddedText(Sidecar.lineageAttribute, "", size: 1)])
        XCTAssertEqual(try Sidecar.read(url: empty), Sidecar.Contents(schema: 1, minReader: 1, source: "", lineage: ""))

        let terminated = directory.appendingPathComponent("terminated.mactem.h5")
        try plant(terminated, [.terminatedText(Sidecar.identityAttribute, "1"), .terminatedText(Sidecar.minReaderAttribute, "1"),
                               .terminatedText(Sidecar.sourceAttribute, "{}"), .terminatedText(Sidecar.lineageAttribute, "")])
        XCTAssertEqual(try Sidecar.read(url: terminated), Sidecar.Contents(schema: 1, minReader: 1, source: "{}", lineage: ""))
    }

    /// What the reader does with the two other paddings, written down (Gate B 2026-10-14, finding 4): NULLTERM reads as the
    /// text before its terminator (above, with the empty text); SPACEPAD has no NUL at all, so the whole field is the text
    /// and the spaces are part of it — the reader trims nothing, and a source or lineage written by such a tool would carry
    /// its padding into JSON (where trailing whitespace is harmless) but into the identity marker it makes "1  " malformed,
    /// by name. Red under: the reader trimming trailing spaces (the source then loses them; the marker is then read as "1").
    func testSpacePaddedTextIsReadWithItsSpacesAndAMarkerWithSpacesIsMalformed() throws {
        let directory = try scratchDirectory()
        let url = directory.appendingPathComponent("space.mactem.h5")
        try plant(url, [.text(Sidecar.identityAttribute, "1"), .text(Sidecar.minReaderAttribute, "1"),
                        .spacePaddedText(Sidecar.sourceAttribute, "{}", size: 6), .spacePaddedText(Sidecar.lineageAttribute, "[]", size: 3)])
        let read = try Sidecar.read(url: url)
        XCTAssertEqual(Array((read.source ?? "?").utf8), Array("{}    ".utf8))
        XCTAssertEqual(Array((read.lineage ?? "?").utf8), Array("[] ".utf8))
        let marker = directory.appendingPathComponent("marker.mactem.h5")
        try plant(marker, [.spacePaddedText(Sidecar.identityAttribute, "1", size: 3), .text(Sidecar.minReaderAttribute, "1"),
                           .text(Sidecar.sourceAttribute, "{}"), .text(Sidecar.lineageAttribute, "[]")])
        XCTAssertEqual(refusal { try Sidecar.read(url: marker) }, .malformedAttribute(Sidecar.identityAttribute))
    }

    /// The text is stored and read byte for byte, in whichever normal form it came: "é" composed (C3 A9) and decomposed
    /// (65 CC 81) are one string to Swift's `==`, so a round trip compared with `==` cannot see a layer that normalises on
    /// write or on read. Compared here by UTF-8 bytes, in the file and after the read, in the source and in the lineage; the
    /// two files differ from each other (Gate B 2026-10-14, finding 4). Red under: the writer storing the composed form
    /// (`precomposedStringWithCanonicalMapping`); the reader returning the decomposed form.
    func testTheTextIsStoredAndReadByteForByteInTheNormalFormItCameIn() throws {
        let directory = try scratchDirectory()
        let composed = "{\"file\":\"caf\u{00E9} \u{00C5}.dm4\"}"
        let decomposed = "{\"file\":\"cafe\u{0301} A\u{030A}.dm4\"}"
        XCTAssertEqual(composed, decomposed)                                      // Swift calls them equal ...
        XCTAssertNotEqual(Array(composed.utf8), Array(decomposed.utf8))           // ... they are not the same bytes
        var seen: [[UInt8]] = []
        for (label, text) in [("composed", composed), ("decomposed", decomposed)] {
            let url = directory.appendingPathComponent("\(label).mactem.h5")
            try Sidecar.write(source: text, lineage: text, to: url)
            for name in [Sidecar.sourceAttribute, Sidecar.lineageAttribute] {
                XCTAssertEqual(try storedForm(name, at: url).bytes, Array(text.utf8), "\(label) \(name) in the file")
            }
            let read = try Sidecar.read(url: url)
            XCTAssertEqual(Array((read.source ?? "?").utf8), Array(text.utf8), "\(label) source after the read")
            XCTAssertEqual(Array((read.lineage ?? "?").utf8), Array(text.utf8), "\(label) lineage after the read")
            seen.append(Array((read.lineage ?? "?").utf8))
        }
        XCTAssertNotEqual(seen[0], seen[1], "the two normal forms came back as one")
    }

    /// The file is written in the library's latest format, which the writer sets itself (Gate B 2026-10-14, finding 2): a
    /// text over about 65,499 bytes does not fit an old-format object header and goes to dense storage, which the 'earliest'
    /// bound cannot write at all. For sizes up to the writer's cap (ADR 023 a; the switch itself is beyond it), the file is written, reads
    /// back equal, and has a superblock of version 2 or later and version-2 object headers ("OHDR") — the layout every
    /// current reader, h5py included, takes. (The bundled library's own default is already this bound, so removing the
    /// writer's setting is not seen here; setting the bound to 'earliest' is.) Red under: the writer's bounds set to
    /// (earliest, earliest).
    func testAWrittenFileIsInTheLatestFormatWhateverTheLineageSize() throws {
        let directory = try scratchDirectory()
        for size in [100, 30_000, 59_000, 59_996] {
            let url = directory.appendingPathComponent("l\(size).mactem.h5")
            let lineage = String(repeating: "x", count: size)
            try Sidecar.write(source: "{}", lineage: lineage, to: url)
            XCTAssertEqual(try Sidecar.read(url: url).lineage, lineage, "\(size) B read back")
            let raw = [UInt8](try bytes(url))
            XCTAssertEqual(Array(raw[0..<8]), [0x89, 0x48, 0x44, 0x46, 0x0D, 0x0A, 0x1A, 0x0A], "\(size) B: the HDF5 signature")
            XCTAssertGreaterThanOrEqual(raw[8], 2, "\(size) B: superblock version \(raw[8])")
            XCTAssertNotNil(raw.firstRange(of: Array("OHDR".utf8)), "\(size) B: no version-2 object header")
        }
    }

    /// ADR 023 a, P1 and P2. The writer refuses, by name, a save whose four attributes' text together is over 60,000 bytes (the
    /// identity marker and the minimum reader one byte each, the source and the lineage): exactly 60,000 is written, one byte
    /// more is `.sidecarTooLarge(bytes:)` and NOTHING is written or changed (no file where there was none, the old file's
    /// bytes, nothing left in the folder), whether the bytes are in the lineage, in the source, or split between them (each
    /// under the cap, the sum over it). Every file at a range of sizes up to within 100 bytes of the cap holds its attributes
    /// in the object header: it carries no fractal heap ("FRHP") or B-tree ("BTHD") of dense storage, and re-reads equal
    /// (h5py's reading of the attribute message is the harness's). Red under: the cap removed (a 60,001-byte save is written);
    /// the cap at `<` (60,000 exactly is refused); the cap on the lineage alone (a source of 59,000 bytes beside a lineage
    /// of 2,000 is written); the cap counting the source alone.
    func testTheWriterRefusesMoreThanSixtyThousandBytesOfTextAndWritesNothing() throws {
        let directory = try scratchDirectory()
        XCTAssertEqual(Sidecar.maxTotalTextBytes, 60_000)
        XCTAssertEqual(Sidecar.totalTextBytes(sourceBytes: 3, lineageBytes: 5), 10)
        func total(_ source: String, _ lineage: String) -> Int { 2 + source.utf8.count + lineage.utf8.count }
        // the sizes up to within 100 bytes of the cap: written, compact, equal
        for lineageBytes in [0, 1, 1_000, 10_000, 30_000, 50_000, 59_000, 59_900, 59_986] {
            let url = directory.appendingPathComponent("l\(lineageBytes).mactem.h5")
            let source = "{\"file\":\"s\"}", lineage = String(repeating: "\u{00B5}", count: lineageBytes / 2) + String(repeating: "y", count: lineageBytes % 2)
            XCTAssertLessThanOrEqual(total(source, lineage), 60_000)
            try Sidecar.write(source: source, lineage: lineage, to: url)
            XCTAssertEqual(try Sidecar.read(url: url), Sidecar.Contents(schema: 1, minReader: 1, source: source, lineage: lineage))
            let raw = [UInt8](try bytes(url))
            XCTAssertNil(raw.firstRange(of: Array("FRHP".utf8)), "\(lineageBytes) B: a fractal heap, dense storage")
            XCTAssertNil(raw.firstRange(of: Array("BTHD".utf8)), "\(lineageBytes) B: a B-tree header, dense storage")
            XCTAssertNotNil(raw.firstRange(of: Array("OHDR".utf8)))
        }
        // exactly at the cap: the identity and the minimum reader are one byte each
        let source = "{}"
        let atCap = String(repeating: "x", count: 60_000 - 2 - source.utf8.count)
        let capFile = directory.appendingPathComponent("cap.mactem.h5")
        try Sidecar.write(source: source, lineage: atCap, to: capFile)
        XCTAssertEqual(try Sidecar.read(url: capFile).lineage, atCap)
        // one byte over, on the lineage, on the source, and split: refused by name, nothing written
        let before = try bytes(capFile)
        for (label, s, l) in [("lineage", source, atCap + "x"), ("source", source + String(repeating: "s", count: 1) + atCap, ""),
                              ("split", String(repeating: "s", count: 30_000), String(repeating: "l", count: 29_999))] {
            let fresh = directory.appendingPathComponent("over-\(label).mactem.h5")
            XCTAssertEqual(refusal { try Sidecar.write(source: s, lineage: l, to: fresh) }, .sidecarTooLarge(bytes: total(s, l)), label)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fresh.path), "\(label): a file was written")
            XCTAssertEqual(refusal { try Sidecar.write(source: s, lineage: l, to: capFile) }, .sidecarTooLarge(bytes: total(s, l)), label)
            XCTAssertEqual(try bytes(capFile), before, "\(label): the old sidecar changed")
        }
        XCTAssertEqual(refusal { try Sidecar.write(source: "s", lineage: atCap + "xxxxxx", to: capFile) }, .sidecarTooLarge(bytes: 60_005))
        // "split" is over only by the sum: each attribute alone is far under the cap
        XCTAssertEqual(total(String(repeating: "s", count: 30_000), String(repeating: "l", count: 29_999)), 60_001)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasPrefix("over-") }, [])
        let sentence = Sidecar.Refusal.sidecarTooLarge(bytes: 60_001).reason
        XCTAssertTrue(sentence.contains("60001") && sentence.contains("60000") && sentence.contains("Remove some marks"), sentence)
    }

    /// A sidecar whose lineage attribute is missing reads as `lineage == nil` — not as an empty text and not as an error —
    /// and that is the file layer's whole contract (Gate B 2026-10-14, finding 3: damage to the NAME of a lineage makes the
    /// attribute unfindable and the file then looks exactly like this; in dense storage, over 65,499 bytes, it is refused
    /// before that, ADR 023 d', so the plant is a compact one of 30,000 bytes). What the
    /// restore does with nil is `SessionRestore`'s, which refuses it by name (`.missingLineage`, slice B's tests). The
    /// control is the same file with the lineage under its right name. Red under: nil read as "".
    func testAMissingLineageAttributeReadsAsNilNotAsEmptyAndTheSourceStillReads() throws {
        let directory = try scratchDirectory()
        let big = String(repeating: "y", count: 30_000)
        let named = directory.appendingPathComponent("named.mactem.h5")
        try plant(named, [.text(Sidecar.identityAttribute, "1"), .text(Sidecar.minReaderAttribute, "1"),
                          .text(Sidecar.sourceAttribute, "{}"), .text(Sidecar.lineageAttribute, big)])
        XCTAssertEqual(try Sidecar.read(url: named).lineage, big)
        let damaged = directory.appendingPathComponent("damaged.mactem.h5")
        try plant(damaged, [.text(Sidecar.identityAttribute, "1"), .text(Sidecar.minReaderAttribute, "1"),
                            .text(Sidecar.sourceAttribute, "{}"), .text("mactem_lineagf", big)])
        let read = try Sidecar.read(url: damaged)
        XCTAssertNil(read.lineage)
        XCTAssertEqual(read.source, "{}")
        XCTAssertEqual(read, Sidecar.Contents(schema: 1, minReader: 1, source: "{}", lineage: nil))
    }

    /// The refusal of a variable-length string says what to do, because nothing else can: slice A's variable-length
    /// sidecar is refused by the read and by the replace check of a save, so a save never replaces it (Gate B 2026-10-14,
    /// finding 4). The sentence names the attribute and tells the user to delete the file. Red under: the sentence without
    /// "delete the file".
    func testTheVariableLengthRefusalTellsTheUserToDeleteTheSidecar() throws {
        let reason = Sidecar.Refusal.variableLengthString("mactem_lineage").reason
        XCTAssertTrue(reason.contains("mactem_lineage"), reason)
        XCTAssertTrue(reason.contains("delete the file"), reason)
        XCTAssertTrue(reason.contains("cannot replace"), reason)
    }

    /// Text, then a NUL, then more text is not a string a C reader would see whole, and not one this reader takes: it is
    /// `.malformedAttribute`, by name, in each of the four attributes, whether the second text follows at once or after more
    /// NULs, and a NUL before the text is the same. Red under: the padding check removed (the text is then cut at the NUL
    /// and the rest silently lost); the text taken to the full size ignoring the NUL (it then comes back with a NUL in it).
    func testTextThenANULThenMoreTextIsMalformed() throws {
        let directory = try scratchDirectory()
        let names = [Sidecar.identityAttribute, Sidecar.minReaderAttribute, Sidecar.sourceAttribute, Sidecar.lineageAttribute]
        let broken: [(String, [UInt8])] = [
            ("one NUL", Array("ab".utf8) + [0] + Array("cd".utf8)),
            ("NULs", Array("ab".utf8) + [0, 0, 0] + Array("cd".utf8)),
            ("leading NUL", [0] + Array("ab".utf8)),
            ("trailing text", Array("1".utf8) + [0, 0, 0x7A]),
        ]
        for name in names {
            for (label, bytes) in broken {
                let url = directory.appendingPathComponent("\(name)-\(label).mactem.h5")
                try plant(url, names.map { $0 == name ? .bytes($0, bytes) : .text($0, "1") })
                XCTAssertEqual(refusal { try Sidecar.read(url: url) }, .malformedAttribute(name), "\(name): \(label)")
            }
        }
    }

    /// A NUL ends a C string: written, it would end the text for any C reader and silently lose the rest (and this reader
    /// refuses it, below), so the writer refuses it, creating nothing. Red under: the NUL check removed (the text is then
    /// written whole).
    func testATextHoldingANULIsNotWritten() throws {
        let url = try scratchDirectory().appendingPathComponent("z.mactem.h5")
        XCTAssertEqual(refusal { try Sidecar.write(source: "a\u{0}b", lineage: "l", to: url) }, .embeddedNUL(Sidecar.sourceAttribute))
        XCTAssertEqual(refusal { try Sidecar.write(source: "s", lineage: "{\u{0}}", to: url) }, .embeddedNUL(Sidecar.lineageAttribute))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
}
