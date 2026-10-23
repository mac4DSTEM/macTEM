//
//  SessionSidecarFileTests.swift
//  The session sidecar's HDF5 file layer (archive: roadmap-registrations-2026-10-15.md V1-2 slice A, ADR 020): the name rule, the four root attributes written
//  and read back, and every refusal by name — a foreign HDF5 file, a newer minimum reader (P2), a file that cannot be
//  opened (P3), an attribute of the wrong kind, a string over 4 MiB, invalid UTF-8. The parity against h5py 3.16.0, which
//  writes and reads the same files independently, is tools/parity/sidecar-parity; these pin the layer's own rules without Python.
//  Files the layer would never write (a foreign file, a newer minimum reader, a wrong-kind attribute) are planted with the
//  same HDF5 binding, through `TestHDF5Library.withLibrary` (TestHDF5Binding.swift: the same libhdf5 image and the same `HDF5Serial` lock as FormatoKit's).
//  Each test names the mutation of SessionSidecarFile.swift it was broken by.
//  The Gate B tests of 2026-10-13 pin what the first set could not see: a file that appears (or is swapped) between the
//  check and the publish, a failed close, nothing left in the system's replacement directory, the path never missing
//  during a replace, and the file handles closed (the test of the freed string buffers went with the variable-length read
//  it measured: ADR 021). Failure injection is the layer's own
//  `WriteSeams` (a file appearing at the one moment it can) and, for a disk that cannot take the file, a file size limit
//  set around one write. The re-verifier's three (2026-10-14) pin a letter both normal forms rewrite, a schema two
//  newer, and the refusal's wording when a file appears.
//  ADR 021 (2026-10-14) retires the variable-length string: the four attributes are fixed-length, null-padded UTF-8, and a
//  variable-length one is refused by name from its type, before any `H5Aread`. The fixtures follow: what `Planted.text`,
//  `.bytes` and `.asciiText` plant is what the writer writes; `.variableText` is slice A's old form, planted to be refused.
//  The tests it adds pin one rule of its registration each (archive: roadmap-registrations-2026-10-15.md V1-2, "Slice B, step 1"): the refusal by name for each
//  of the four attributes, a variable-length sidecar never overwritten, the cap on the declared size, text then NUL then
//  text, h5py's padding, the empty text as one NUL, and the layout the writer produces.
//

import XCTest
import Darwin
import FormatoHDF5
import TEMCore

nonisolated final class SessionSidecarFileTests: XCTestCase {
    private typealias Sidecar = SessionSidecarFile

    // MARK: Fixtures

    private func scratchDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionSidecarFileTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    /// The refusal `body` throws, or nil (and a failure) if it returns or throws anything else.
    private func refusal<T>(_ body: () throws -> T, file: StaticString = #filePath, line: UInt = #line) -> Sidecar.Refusal? {
        do {
            _ = try body()
            XCTFail("expected a refusal; it returned", file: file, line: line)
        } catch let refusal as Sidecar.Refusal {
            return refusal
        } catch {
            XCTFail("expected a Refusal, got \(error)", file: file, line: line)
        }
        return nil
    }

    private func isCannotOpen(_ refusal: Sidecar.Refusal?) -> Bool {
        if case .cannotOpen = refusal { return true }
        return false
    }

    /// An attribute a sidecar never holds, or holds in a form this layer never writes: planted with the binding. `text`,
    /// `bytes` and `asciiText` are the form the writer writes (ADR 021): a scalar fixed-length string, null-padded, as long
    /// as its bytes (one NUL when there are none, HDF5 having no size 0). The others are forms the reader meets from
    /// elsewhere, or must refuse.
    nonisolated private enum Planted {
        case text(String, String)                   // fixed-length UTF-8, NULLPAD, size = the UTF-8 bytes: the writer's form
        case bytes(String, [UInt8])                 // the same, from raw bytes (not necessarily UTF-8)
        case asciiText(String, String)              // the same with the ASCII character set (h5py's np.bytes_)
        case paddedText(String, String, size: Int)  // the same in a field of `size` bytes, NULs after the text (h5py's string_dtype(length:))
        case terminatedText(String, String)         // NULLTERM, size = bytes + 1, a trailing NUL: what a C writer's H5T_C_S1 gives
        case spacePaddedText(String, String, size: Int)  // SPACEPAD: the text, then spaces up to `size` (what a Fortran or fixed-width writer gives)
        case integer(String, Int32)                 // a scalar 32-bit integer
        case textArray(String, [String])            // a rank-1 array of fixed-length strings
        case variableText(String, String)           // a scalar variable-length UTF-8 string: slice A's form, refused since ADR 021
        case variableTextArray(String, [String])    // a rank-1 array of variable-length strings
    }

    private static let nullTerminated: Int32 = 0    // H5T_STR_NULLTERM
    private static let nullPadded: Int32 = 1        // H5T_STR_NULLPAD
    private static let spacePadded: Int32 = 2       // H5T_STR_SPACEPAD

    /// `H5Tset_strpad`, looked up on the binding's own handle as the source does (the binding's symbol list has none).
    private func setPadding(_ type: Int64, _ padding: Int32, _ h5: TestHDF5Library) -> Int32 {
        typealias SetStrpad = @convention(c) (Int64, Int32) -> Int32
        guard let symbol = dlsym(h5.handle, "H5Tset_strpad") else { return -1 }
        return unsafeBitCast(symbol, to: SetStrpad.self)(type, padding)
    }

    /// Creates an HDF5 file at `url` holding exactly `attributes` on its root.
    private func plant(_ url: URL, _ attributes: [Planted], file: StaticString = #filePath, line: UInt = #line) throws {
        try TestHDF5Library.withLibrary { h5 in
            let id = url.path.withCString { h5.h5fcreate($0, h5FileTruncate, h5DefaultProperty, h5DefaultProperty) }
            XCTAssertGreaterThanOrEqual(id, 0, "creating \(url.lastPathComponent)", file: file, line: line)
            defer { _ = h5.h5fclose(id) }
            for attribute in attributes { put(attribute, on: id, h5, file: file, line: line) }
        }
    }

    private func put(_ attribute: Planted, on id: Int64, _ h5: TestHDF5Library, file: StaticString, line: UInt) {
        func variableLengthType() -> Int64 {
            let type = h5.h5tcopy(h5.stringC1)
            _ = h5.h5tsetSize(type, UInt.max)
            _ = h5.h5tsetCset(type, h5UTF8CharacterSet)
            return type
        }
        /// A fixed-length string type of `size` bytes.
        func fixedLengthType(size: Int, characterSet: Int32, padding: Int32) -> Int64 {
            let type = h5.h5tcopy(h5.stringC1)
            XCTAssertGreaterThanOrEqual(h5.h5tsetSize(type, UInt(size)), 0, "a string type of \(size) bytes", file: file, line: line)
            _ = h5.h5tsetCset(type, characterSet)
            XCTAssertGreaterThanOrEqual(setPadding(type, padding, h5), 0, "the padding", file: file, line: line)
            return type
        }
        func create(_ name: String, _ type: Int64, _ space: Int64, _ write: (Int64) -> Int32) {
            let handle = name.withCString { h5.h5acreate2(id, $0, type, space, h5DefaultProperty, h5DefaultProperty) }
            XCTAssertGreaterThanOrEqual(handle, 0, "creating \(name)", file: file, line: line)
            XCTAssertGreaterThanOrEqual(write(handle), 0, "writing \(name)", file: file, line: line)
            _ = h5.h5aclose(handle)
        }
        let scalar = h5.h5screate(h5ScalarDataspace)
        defer { _ = h5.h5sclose(scalar) }
        /// `value` in a field of `size` bytes (default: as long as the value, one NUL when it is empty), NULs after it.
        func fixedLengthString(_ name: String, _ value: [UInt8], size: Int? = nil, characterSet: Int32 = h5UTF8CharacterSet,
                               padding: Int32 = SessionSidecarFileTests.nullPadded) {
            let width = size ?? max(value.count, 1)
            precondition(width >= value.count, "the field is shorter than the value")
            let type = fixedLengthType(size: width, characterSet: characterSet, padding: padding)
            defer { _ = h5.h5tclose(type) }
            let field = value + [UInt8](repeating: 0, count: width - value.count)
            create(name, type, scalar) { handle in field.withUnsafeBufferPointer { h5.h5awrite(handle, type, $0.baseAddress) } }
        }
        func variableLengthString(_ name: String, _ value: [UInt8]) {
            let type = variableLengthType()
            defer { _ = h5.h5tclose(type) }
            let terminated = value + [0]
            create(name, type, scalar) { handle in
                terminated.withUnsafeBufferPointer { buffer in
                    var pointer: UnsafePointer<CChar>? = UnsafeRawPointer(buffer.baseAddress!).assumingMemoryBound(to: CChar.self)
                    return withUnsafePointer(to: &pointer) { h5.h5awrite(handle, type, $0) }
                }
            }
        }
        switch attribute {
        case .text(let name, let value):
            fixedLengthString(name, Array(value.utf8))
        case .asciiText(let name, let value):
            fixedLengthString(name, Array(value.utf8), characterSet: 0)          // H5T_CSET_ASCII
        case .bytes(let name, let value):
            fixedLengthString(name, value)
        case .paddedText(let name, let value, let size):
            fixedLengthString(name, Array(value.utf8), size: size)
        case .terminatedText(let name, let value):
            fixedLengthString(name, Array(value.utf8) + [0], padding: SessionSidecarFileTests.nullTerminated)
        case .spacePaddedText(let name, let value, let size):
            let field = Array(value.utf8) + [UInt8](repeating: 0x20, count: size - value.utf8.count)
            fixedLengthString(name, field, padding: SessionSidecarFileTests.spacePadded)
        case .integer(let name, let value):
            create(name, h5.nativeInt, scalar) { handle in
                var copy = value
                return withUnsafePointer(to: &copy) { h5.h5awrite(handle, h5.nativeInt, $0) }
            }
        case .textArray(let name, let values):
            let width = max(values.map { $0.utf8.count }.max() ?? 1, 1)
            let type = fixedLengthType(size: width, characterSet: h5UTF8CharacterSet, padding: SessionSidecarFileTests.nullPadded)
            defer { _ = h5.h5tclose(type) }
            var dims = [UInt64(values.count)]
            let space = h5.h5screateSimple(1, &dims, nil)
            defer { _ = h5.h5sclose(space) }
            let field = values.flatMap { Array($0.utf8) + [UInt8](repeating: 0, count: width - $0.utf8.count) }
            create(name, type, space) { handle in field.withUnsafeBufferPointer { h5.h5awrite(handle, type, $0.baseAddress) } }
        case .variableText(let name, let value):
            variableLengthString(name, Array(value.utf8))
        case .variableTextArray(let name, let values):
            let type = variableLengthType()
            defer { _ = h5.h5tclose(type) }
            var dims = [UInt64(values.count)]
            let space = h5.h5screateSimple(1, &dims, nil)
            defer { _ = h5.h5sclose(space) }
            let pointers: [UnsafeMutablePointer<CChar>?] = values.map { strdup($0) }
            defer { pointers.forEach { free($0) } }
            create(name, type, space) { handle in
                pointers.withUnsafeBufferPointer { h5.h5awrite(handle, type, $0.baseAddress) }
            }
        }
    }

    /// How an attribute of the root is stored, as the file says it. The bytes are read only for a fixed-length string,
    /// never for a variable-length one (that read is the one ADR 021 forbids).
    nonisolated private struct StoredForm: Equatable {
        var isString: Bool
        var isVariableLength: Bool
        var size: Int
        var characterSet: Int32
        var padding: Int32
        var rank: Int32
        var count: Int64
        var bytes: [UInt8]?
    }

    private func storedForm(_ name: String, at url: URL, file: StaticString = #filePath, line: UInt = #line) throws -> StoredForm {
        typealias GetInt = @convention(c) (Int64) -> Int32
        return try TestHDF5Library.withLibrary { h5 in
            let getCset = unsafeBitCast(dlsym(h5.handle, "H5Tget_cset"), to: GetInt.self)
            let getPadding = unsafeBitCast(dlsym(h5.handle, "H5Tget_strpad"), to: GetInt.self)
            let opened = url.path.withCString { h5.h5fopen($0, h5FileReadOnly, h5DefaultProperty) }
            XCTAssertGreaterThanOrEqual(opened, 0, file: file, line: line)
            defer { _ = h5.h5fclose(opened) }
            let root = "/".withCString { h5.h5gopen2(opened, $0, h5DefaultProperty) }
            XCTAssertGreaterThanOrEqual(root, 0, file: file, line: line)
            defer { _ = h5.h5gclose(root) }
            XCTAssertGreaterThan(name.withCString { h5.h5aexists(root, $0) }, 0, "\(name) on /", file: file, line: line)
            let attribute = name.withCString { h5.h5aopen(root, $0, h5DefaultProperty) }
            defer { _ = h5.h5aclose(attribute) }
            let space = h5.h5agetSpace(attribute)
            defer { _ = h5.h5sclose(space) }
            let type = h5.h5agetType(attribute)
            defer { _ = h5.h5tclose(type) }
            let isString = h5.h5tgetClass(type) == h5StringClass
            let variable = isString && h5.h5tisVariableStr(type) > 0
            let size = h5.h5tgetSize(type)
            var bytes: [UInt8]?
            if isString, !variable, size > 0 {
                var storage = [UInt8](repeating: 0, count: size)
                XCTAssertGreaterThanOrEqual(storage.withUnsafeMutableBytes { h5.h5aread(attribute, type, $0.baseAddress) }, 0,
                                            file: file, line: line)
                bytes = storage
            }
            return StoredForm(isString: isString, isVariableLength: variable, size: size, characterSet: getCset(type),
                              padding: getPadding(type), rank: h5.h5sgetSimpleExtentNdims(space),
                              count: h5.h5sgetSimpleExtentNpoints(space), bytes: bytes)
        }
    }

    /// Breaks the signature of every global heap collection in the file ("GCOL" to "GCOX") and says how many it broke. A
    /// variable-length string's characters live in one, and HDF5 fails at once when it meets the broken signature: the safe
    /// stand-in, for a test, for the damaged object SIZE in the same heap that makes `H5Aread` spin forever (ADR 021).
    private func breakGlobalHeaps(in url: URL) throws -> Int {
        var data = try Data(contentsOf: url)
        var broken = 0
        var from = data.startIndex
        while let range = data.range(of: Data("GCOL".utf8), in: from..<data.endIndex) {
            data[range.lowerBound + 3] = UInt8(ascii: "X")
            broken += 1
            from = range.upperBound
        }
        try data.write(to: url)
        return broken
    }

    /// Whether the HDF5 file at `url` holds an attribute `name` on its root.
    private func hasAttribute(_ name: String, at url: URL) throws -> Bool {
        try TestHDF5Library.withLibrary { h5 in
            let file = url.path.withCString { h5.h5fopen($0, h5FileReadOnly, h5DefaultProperty) }
            XCTAssertGreaterThanOrEqual(file, 0)
            defer { _ = h5.h5fclose(file) }
            return name.withCString { h5.h5aexists(file, $0) } > 0
        }
    }

    private func bytes(_ url: URL) throws -> Data { try Data(contentsOf: url) }

    /// A string of at least `count` UTF-8 bytes that looks like what a lineage holds, and carries "Å", "µ" and quotes.
    private func lineageLike(bytes count: Int) -> String {
        let unit = "{\"id\":\"s1\",\"unit\":\"Å\",\"µ\":[1.5,2.25],\"note\":\"a \\\"quoted\\\" word\"}\n"
        var text = ""
        while text.utf8.count < count { text += unit }
        return text
    }

    // MARK: The name (ADR 020 D1)

    /// The source's name as the URL reports it, plus ".mactem.h5", beside the source — never the lower-cased extension the
    /// open dispatches on. Names are compared as Swift compares strings (canonical equivalence): Foundation hands a file
    /// name back decomposed whichever way it came in, and on APFS the two spellings are one name. The ASCII names are
    /// compared byte for byte. Red under: the name lower-cased; the extension replaced by the suffix.
    func testTheSidecarNameIsTheSourceNameOnDiskVerbatim() throws {
        let folder = URL(fileURLWithPath: "/tmp/some folder", isDirectory: true)
        for (name, expected) in [
            ("SCAN.DM4", "SCAN.DM4.mactem.h5"),
            ("scan.tif", "scan.tif.mactem.h5"),
            ("Ceta 4k #1 %41.emd", "Ceta 4k #1 %41.emd.mactem.h5"),
            ("\u{00B5}-scan.mrc", "\u{00B5}-scan.mrc.mactem.h5"),
            ("A\u{030A}.dm4", "\u{00C5}.dm4.mactem.h5"),            // Å decomposed in, composed expected: one name
        ] {
            let sidecar = try Sidecar.sidecarURL(forSource: folder.appendingPathComponent(name))
            XCTAssertEqual(sidecar.lastPathComponent, expected, "the sidecar of \(name)")
            XCTAssertEqual(sidecar.deletingLastPathComponent().path, folder.path, "beside \(name)")
        }
        let ascii = try Sidecar.sidecarURL(forSource: folder.appendingPathComponent("SCAN.DM4"))
        XCTAssertEqual(Array(ascii.lastPathComponent.utf8), Array("SCAN.DM4.mactem.h5".utf8))
        // A composed Å (C3 85), as another tool may have created it and a URL built from percent-encoding reports it.
        let composed = try XCTUnwrap(URL(string: "file:///tmp/%C3%85.dm4"))
        XCTAssertEqual(try Sidecar.sidecarURL(forSource: composed).lastPathComponent, "\u{00C5}.dm4.mactem.h5")

        // The spelling, scalar by scalar, is Foundation's, not the layer's: a composed and a decomposed source name both
        // arrive at the file system as the decomposed name (A, U+030A). Pinned so that a change in Foundation, or a
        // construction of the URL that stops Foundation normalizing the name, is seen. (Mutations that only compose or
        // decompose the name before it is appended are equivalent on this OS for the letters Foundation decomposes: it
        // normalizes the appended name anyway, probed 2026-10-13; three letters it leaves alone are the next test's.)
        let decomposed = Array("A\u{030A}.dm4.mactem.h5".unicodeScalars)
        for source in [folder.appendingPathComponent("A\u{030A}.dm4"), folder.appendingPathComponent("\u{00C5}.dm4"), composed] {
            XCTAssertEqual(Array(try Sidecar.sidecarURL(forSource: source).lastPathComponent.unicodeScalars), decomposed, "\(source)")
        }
    }

    /// Three letters Foundation leaves alone but both normal forms rewrite — the ANGSTROM SIGN U+212B (to Å), the OHM SIGN
    /// U+2126 (to Ω) and the KELVIN SIGN U+212A (to K) — stay in the sidecar's name as the source's name has them, so the
    /// "equivalent" note above holds only for the letters Foundation decomposes. Red under: the name built from the NFC
    /// name; the name built from the NFD name (the re-verifier's K and L, 2026-10-14).
    func testALetterBothNormalFormsRewriteIsKeptInTheNameAsItIs() throws {
        for scalar in [0x212B, 0x2126, 0x212A] as [UInt32] {
            let source = URL(fileURLWithPath: "/tmp/some folder/\(String(UnicodeScalar(scalar)!))x.dm4")
            let sidecar = try Sidecar.sidecarURL(forSource: source)
            XCTAssertEqual(sidecar.lastPathComponent.unicodeScalars.first?.value, scalar, "U+\(String(scalar, radix: 16)) was rewritten")
        }
    }

    /// A sidecar has no sidecar. The file system folds case, so ".MACTEM.H5" is one too. Red under: the check removed;
    /// the check made case-sensitive.
    func testASidecarHasNoSidecarOfItsOwn() throws {
        for name in ["scan.dm4.mactem.h5", "SCAN.DM4.MACTEM.H5", ".mactem.h5"] {
            let refused = refusal { try Sidecar.sidecarURL(forSource: URL(fileURLWithPath: "/tmp/\(name)")) }
            XCTAssertEqual(refused, .sourceIsASidecar(name))
        }
        // Only the ending counts.
        XCTAssertNoThrow(try Sidecar.sidecarURL(forSource: URL(fileURLWithPath: "/tmp/scan.mactem.h5.dm4")))
    }

    /// Over 255 UTF-16 units with the suffix is a named error, counted in the units the file system counts: not bytes, not
    /// characters (ADR 020 D1, amended 2026-10-14 from the registered "255 bytes": the measurement on this Mac, APFS,
    /// 2026-10-13, says UTF-16 units), and this test pins both sides of it for an ASCII, a two-byte ("µ"), a three-byte
    /// ("日") and a two-unit (an emoji) name: the layer takes exactly 255 units, the file system takes that name (the
    /// sidecar is written for real, beside nothing else, and read back), the layer refuses 256, and the file system itself
    /// refuses a 256-unit name. The limit is also on the name Foundation gives the file system, decomposed ("Å" is two
    /// units, not one). Red under: the limit at 256; bytes counted instead of units (the "µ", "日" and emoji names are then
    /// refused at 255 units); characters counted instead of units (the emoji name is then accepted at 256); the units
    /// counted before Foundation decomposes the name; a temporary name built from the target's, or beside the target.
    func testANameOverTheFileSystemLimitIsRefusedAndTheLongestFittingNameIsWritten() throws {
        let folder = URL(fileURLWithPath: "/tmp", isDirectory: true)
        let suffixUnits = Sidecar.suffix.utf16.count
        XCTAssertEqual(Sidecar.maxNameUnits, 255)
        func name(ascii count: Int) -> String { String(repeating: "a", count: count - 4) + ".dm4" }
        let fits = name(ascii: Sidecar.maxNameUnits - suffixUnits)                 // 245 units
        XCTAssertEqual(try Sidecar.sidecarURL(forSource: folder.appendingPathComponent(fits)).lastPathComponent.utf16.count, 255)
        for count in [246, 250, 300] {
            XCTAssertEqual(refusal { try Sidecar.sidecarURL(forSource: folder.appendingPathComponent(name(ascii: count))) },
                           .nameTooLong(units: count + suffixUnits), "\(count) units")
        }

        // Each kind of letter, to exactly 255 units (padded with ASCII where the letter's width does not divide the room),
        // and one unit more.
        let directory = try scratchDirectory()
        for (label, letter) in [("ascii", "a"), ("mu", "\u{00B5}"), ("cjk", "\u{65E5}"), ("emoji", "\u{1F600}")] {
            let room = Sidecar.maxNameUnits - suffixUnits - ".dm4".utf16.count
            let repeats = room / letter.utf16.count
            let longest = String(repeating: letter, count: repeats)
                + String(repeating: "a", count: room - repeats * letter.utf16.count) + ".dm4"
            let sidecar = try Sidecar.sidecarURL(forSource: directory.appendingPathComponent(longest))
            XCTAssertEqual(sidecar.lastPathComponent.utf16.count, 255, label)
            try Sidecar.write(source: "s", lineage: "l", to: sidecar)
            XCTAssertEqual(try Sidecar.read(url: sidecar).lineage, "l", label)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [sidecar.lastPathComponent], label)
            try FileManager.default.removeItem(at: sidecar)

            XCTAssertEqual(refusal { try Sidecar.sidecarURL(forSource: directory.appendingPathComponent("a" + longest)) },
                           .nameTooLong(units: 256), label)
            let tooLong = directory.appendingPathComponent("a" + longest + Sidecar.suffix)
            XCTAssertFalse(FileManager.default.createFile(atPath: tooLong.path, contents: Data()),
                           "\(label): the file system took a 256-unit name; its limit has moved: re-learn it")
        }

        // The limit is on the units the file system is given, and Foundation gives it the decomposed name ("Å" is two
        // units, not one): 150 composed Å fit as the URL arrives (164 units with the suffix) and not as it is created (314).
        let composedName = String(repeating: "%C3%85", count: 150) + ".dm4"
        let composed = try XCTUnwrap(URL(string: "file:///tmp/" + composedName))
        let composedUnits = composed.lastPathComponent.utf16.count + suffixUnits
        let created = composed.deletingLastPathComponent()
            .appendingPathComponent(composed.lastPathComponent + Sidecar.suffix, isDirectory: false).lastPathComponent.utf16.count
        XCTAssertLessThanOrEqual(composedUnits, 255, "Foundation no longer reports the name composed: re-learn this case")
        XCTAssertGreaterThan(created, 255, "Foundation no longer decomposes the name it creates: re-learn this case")
        XCTAssertEqual(refusal { try Sidecar.sidecarURL(forSource: composed) }, .nameTooLong(units: created))
    }

    /// A URL that is not a file, or names no file, has no sidecar. Red under: the file-URL and name check removed.
    func testASourceWithoutAFileNameHasNoSidecar() {
        XCTAssertEqual(refusal { try Sidecar.sidecarURL(forSource: URL(fileURLWithPath: "/")) }, .noSourceName)
        XCTAssertEqual(refusal { try Sidecar.sidecarURL(forSource: URL(string: "https://example.com/scan.dm4")!) }, .noSourceName)
    }

    // MARK: Write, then read (P1 at this layer)

    /// Four attributes written and read back equal: "Å", "µ" and a mebibyte of text. Red under: the strings cut at half a
    /// mebibyte; non-ASCII replaced by "?" on write; the min reader or the schema written as another number.
    func testWhatIsWrittenIsReadBackEqual() throws {
        let url = try scratchDirectory().appendingPathComponent("a.dm4.mactem.h5")
        let source = "{\"file\":\"scan Å µ ✓.dm4\"}"
        let lineage = lineageLike(bytes: 50_000)
        XCTAssertGreaterThanOrEqual(lineage.utf8.count, 50_000)
        try Sidecar.write(source: source, lineage: lineage, to: url)
        let read = try Sidecar.read(url: url)
        XCTAssertEqual(read, Sidecar.Contents(schema: 1, minReader: 1, source: source, lineage: lineage))
        XCTAssertEqual(read.source, source)
        XCTAssertEqual(read.lineage, lineage)       // a mismatch of a mebibyte would print as a wall; the line above is the check
        XCTAssertEqual(Sidecar.schema, 1)
    }

    /// The sidecar finds libhdf5 with no override and no `Frameworks` copy (ADR 026): the app embeds none, FormatoKit's
    /// FormatoLibHDF5 framework carries the one, and FormatoKit's loader (`SharedHDF5.loadStandard`) names it. The record round-trips, and the one
    /// libhdf5 the process holds is the framework's, the path the Velox reader loads too (one image, one lock). Red under: the
    /// `FormatoHDF5Library.bundledLibraryPath` candidate removed (the write throws `.library`).
    func testTheSidecarFindsFormatoKitsBundledLibraryWithNoOverrideAndNoFrameworksCopy() throws {
        XCTAssertNil(getenv("FORMATO_HDF5_PATH"), "the variable overrides the lookup this test is about: run without it")
        let embedded = Bundle.main.privateFrameworksURL?.appendingPathComponent("libhdf5.dylib").path
        XCTAssertFalse(embedded.map { FileManager.default.fileExists(atPath: $0) } ?? false, "the host embeds a libhdf5 of its own")
        let bundled = try XCTUnwrap(FormatoHDF5Library.bundledLibraryPath, "the host does not carry FormatoKit's FormatoLibHDF5 framework")
        let url = try scratchDirectory().appendingPathComponent("b.dm4.mactem.h5")
        try Sidecar.write(source: "{\"file\":\"b.dm4\"}", lineage: "[]", to: url)
        XCTAssertEqual(try Sidecar.read(url: url), Sidecar.Contents(schema: 1, minReader: 1, source: "{\"file\":\"b.dm4\"}", lineage: "[]"))
        let loaded = (0..<_dyld_image_count()).compactMap { index in _dyld_get_image_name(index).map { String(cString: $0) } }
            .filter { $0.hasSuffix("/FormatoLibHDF5") }
            .map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
        XCTAssertEqual(loaded, [URL(fileURLWithPath: bundled).resolvingSymlinksInPath().path])
        let all = (0..<_dyld_image_count()).compactMap { index in _dyld_get_image_name(index).map { String(cString: $0) } }
        XCTAssertFalse(all.contains { $0.hasSuffix("/libhdf5.dylib") }, "a bare libhdf5.dylib is loaded: the lookup did not stop at the framework")
    }

    /// Sidecars written by the app BEFORE the switch to FormatoKit's `HDF5RootAttributes` (macTEM f23fd77, its own HDF5 binding)
    /// still read, attribute by attribute, and can be replaced. The four files are in Fixtures/sidecar (plain, non-ASCII, empty
    /// texts, a lineage of 6 KB), written by that code. Red under: the reader refusing or misreading the old files' strings.
    func testSidecarsWrittenBeforeTheKitSwitchStillRead() throws {
        func fixture(_ name: String) throws -> URL {
            if let url = Bundle(for: SessionSidecarFileTests.self).url(forResource: name, withExtension: "mactem.h5") { return url }
            let beside = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/sidecar/\(name).mactem.h5")
            return try XCTUnwrap(FileManager.default.fileExists(atPath: beside.path) ? beside : nil, "\(name).mactem.h5 is not in Fixtures/sidecar")
        }
        let expected: [(String, String, String)] = [
            ("plain", "{\"file\":\"scan.dm4\"}", "[{\"id\":1}]"),
            ("unicode", "{\"file\":\"scan Å µ ✓ 日本.dm4\"}", "[{\"label\":\"µ — ✓ 😀\"}]"),
            ("empty", "", ""),
            ("long", "{\"file\":\"long.dm4\"}", "[" + String(repeating: "{\"k\":\"v\"},", count: 600) + "{}]"),
        ]
        for (name, source, lineage) in expected {
            let url = try fixture(name)
            XCTAssertEqual(try Sidecar.read(url: url), Sidecar.Contents(schema: 1, minReader: 1, source: source, lineage: lineage), name)
            // A copy is replaceable by the new writer, and the new file reads as the new text.
            let copy = try scratchDirectory().appendingPathComponent("\(name).mactem.h5")
            try FileManager.default.copyItem(at: url, to: copy)
            try Sidecar.write(source: "{}", lineage: "[]", to: copy)
            XCTAssertEqual(try Sidecar.read(url: copy), Sidecar.Contents(schema: 1, minReader: 1, source: "{}", lineage: "[]"), name)
        }
    }

    /// The wording of the two publish refusals is this layer's own, not the kit's (the coordinator's review of fb518bf).
    func testThePublishRaceRefusalsKeepTheAppsWording() {
        XCTAssertEqual(Sidecar.refusal(.cannotWrite(operation: "publishing the file",
                           detail: "the file was replaced or removed after it was checked; it was left as it is")),
                       .cannotWrite(operation: "publishing the file",
                           detail: "the sidecar was replaced or removed after it was checked; it was left as it is"))
        XCTAssertEqual(Sidecar.refusal(.cannotWrite(operation: "publishing the file",
                           detail: "a file appeared at the path after it was checked; it was left as it is")),
                       .cannotWrite(operation: "publishing the file",
                           detail: "a file appeared at the sidecar's path after it was checked; it was left as it is"))
        XCTAssertEqual(Sidecar.refusal(.cannotWrite(operation: "creating the file", detail: "disk full")),
                       .cannotWrite(operation: "creating the file", detail: "disk full"))
    }

    /// Each kit error the app can provoke maps to its own `Refusal`, one to one; a kit error it never provokes becomes `.hdf5`.
    func testEveryKitErrorTheAppCanProvokeMapsToItsRefusal() {
        XCTAssertEqual(Sidecar.refusal(.library("x")), .library("x"))
        XCTAssertEqual(Sidecar.refusal(.cannotOpen("x")), .cannotOpen("x"))
        XCTAssertEqual(Sidecar.refusal(.notPermitted("x")), .notPermitted("x"))
        XCTAssertEqual(Sidecar.refusal(.hdf5(operation: "o", detail: "d")), .hdf5(operation: "o", detail: "d"))
        XCTAssertEqual(Sidecar.refusal(.malformedAttribute("a")), .malformedAttribute("a"))
        XCTAssertEqual(Sidecar.refusal(.variableLengthString("a")), .variableLengthString("a"))
        XCTAssertEqual(Sidecar.refusal(.stringTooLong(attribute: "a", bytes: 5)), .stringTooLong(attribute: "a", bytes: 5))
        XCTAssertEqual(Sidecar.refusal(.invalidUTF8("a")), .invalidUTF8("a"))
        XCTAssertEqual(Sidecar.refusal(.denseAttributeStorage), .denseAttributeStorage)
        XCTAssertEqual(Sidecar.refusal(.embeddedNUL("a")), .embeddedNUL("a"))
        XCTAssertEqual(Sidecar.refusal(.cannotWrite(operation: "o", detail: "d")), .cannotWrite(operation: "o", detail: "d"))
        if case .hdf5(let operation, _) = Sidecar.refusal(.notFound("/x")) { XCTAssertEqual(operation, "using the file") } else {
            XCTFail("a kit error the app never provokes is not .hdf5")
        }
    }

    /// The read cap the app documents is the kit's default (the app reads with it): a kit change of the default is seen here.
    func testTheKitsDefaultStringCapIsTheAppsCap() {
        XCTAssertEqual(HDF5RootAttributes.defaultMaximumStringBytes, Sidecar.maxStringBytes)
    }

    /// A file swapped between the three kit reads of one `read` is refused, not read as a mixture of two files.
    func testAFileSwappedBetweenTheReadsIsRefused() throws {
        let directory = try scratchDirectory()
        let url = directory.appendingPathComponent("s.mactem.h5")
        try Sidecar.write(source: "{\"a\":1}", lineage: "[1]", to: url)
        let other = directory.appendingPathComponent("o.mactem.h5")
        try Sidecar.write(source: "{\"b\":2}", lineage: "[2]", to: other)
        let error = refusal { try Sidecar.read(url: url, betweenReads: { _ = Darwin.rename(other.path, url.path) }) }
        XCTAssertEqual(error, .cannotOpen("the file changed while it was being read"))
        XCTAssertEqual(try Sidecar.read(url: url).source, "{\"b\":2}")      // and an unswapped read is unaffected
    }

    /// Empty strings are strings, present and empty, not absent. Red under: an empty text stored with size 0 (HDF5 refuses
    /// the type, and the write throws); the text taken to the full size ignoring the NUL (an empty text then reads back as
    /// "\u{0}"); the writer back to a variable-length string.
    func testEmptyStringsAreWrittenAndReadBack() throws {
        let url = try scratchDirectory().appendingPathComponent("e.mactem.h5")
        try Sidecar.write(source: "", lineage: "", to: url)
        XCTAssertEqual(try Sidecar.read(url: url), Sidecar.Contents(schema: 1, minReader: 1, source: "", lineage: ""))
    }

    /// An empty text is stored as one NUL: HDF5 has no string type of size 0, so the field is one byte and the reader's
    /// "text up to the first NUL" is the empty string. Checked in the file (size 1, the byte 0, still a fixed-length
    /// NULLPAD UTF-8 string) and by reading it back, in the source and in the lineage; the identity, a letter, is one byte
    /// too. Red under: an empty text stored with size 0 (the write throws); the text taken to the full size ignoring the NUL
    /// (it reads back as "\u{0}", not ""); the writer back to a variable-length string, without `nullPadded` (NULLTERM),
    /// with the ASCII character set, or one byte longer (the identity is then 2 bytes).
    func testAnEmptyTextIsStoredAsOneNULAndReadBackEmpty() throws {
        let url = try scratchDirectory().appendingPathComponent("empty.mactem.h5")
        try Sidecar.write(source: "", lineage: "", to: url)
        for name in [Sidecar.sourceAttribute, Sidecar.lineageAttribute] {
            let form = try storedForm(name, at: url)
            XCTAssertEqual(form, StoredForm(isString: true, isVariableLength: false, size: 1, characterSet: h5UTF8CharacterSet,
                                            padding: SessionSidecarFileTests.nullPadded, rank: 0, count: 1, bytes: [0]), name)
        }
        XCTAssertEqual(try storedForm(Sidecar.identityAttribute, at: url).size, 1)
        let read = try Sidecar.read(url: url)
        XCTAssertEqual(read.source, "")
        XCTAssertEqual(read.lineage, "")
    }

    /// The file holds the four attributes on the root, each a scalar fixed-length string in UTF-8, null-padded, exactly as
    /// long as the text's UTF-8 bytes (ADR 021): the layout h5py and every other reader sees, and the one the reader's
    /// "the whole storage is the text and its padding" relies on. Checked in the file: the class, not variable-length, the
    /// size (the multi-byte text is 8 bytes for 4 characters), the character set and the padding read through
    /// `H5Tget_cset` and `H5Tget_strpad`, scalar, and the bytes themselves, with no terminator after them. Red under: the
    /// writer back to a variable-length string (slice A's); the writer without `nullPadded` (NULLTERM); the writer one byte
    /// longer (a trailing NUL); the writer's character set ASCII.
    func testTheFourAttributesAreScalarFixedLengthNullPaddedUTF8StringsOnTheRoot() throws {
        let url = try scratchDirectory().appendingPathComponent("t.mactem.h5")
        let text = "\u{00C5} \u{00B5}\u{2713}"            // Å, a space, µ, a check mark: 4 characters, 8 UTF-8 bytes
        XCTAssertEqual(Array(text.utf8).count, 8)
        try Sidecar.write(source: text, lineage: "l", to: url)
        let expected: [(String, [UInt8])] = [
            (Sidecar.identityAttribute, Array("1".utf8)), (Sidecar.minReaderAttribute, Array("1".utf8)),
            (Sidecar.sourceAttribute, Array(text.utf8)), (Sidecar.lineageAttribute, Array("l".utf8)),
        ]
        for (name, bytes) in expected {
            XCTAssertEqual(try storedForm(name, at: url),
                           StoredForm(isString: true, isVariableLength: false, size: bytes.count, characterSet: h5UTF8CharacterSet,
                                      padding: SessionSidecarFileTests.nullPadded, rank: 0, count: 1, bytes: bytes), name)
        }
    }

    /// A replace is a new file: nothing of the old one — a value, or an attribute this build does not write — survives.
    /// The old file here is one of ours that a newer build of the same schema extended with one more attribute. Red under:
    /// the replace made in place (the old file copied, its four attributes deleted and rewritten) — the extra attribute
    /// then survives; no publish at all — the old values then remain.
    func testReplacingKeepsNoStaleAttribute() throws {
        let url = try scratchDirectory().appendingPathComponent("r.mactem.h5")
        try plant(url, [
            .text(Sidecar.identityAttribute, "1"), .text(Sidecar.minReaderAttribute, "1"),
            .text(Sidecar.sourceAttribute, "old source"), .text(Sidecar.lineageAttribute, "old lineage"),
            .text("mactem_future_extra", "must not survive"),
        ])
        XCTAssertTrue(try hasAttribute("mactem_future_extra", at: url))
        try Sidecar.write(source: "new source", lineage: "new lineage", to: url)
        XCTAssertEqual(try Sidecar.read(url: url), Sidecar.Contents(schema: 1, minReader: 1, source: "new source", lineage: "new lineage"))
        XCTAssertFalse(try hasAttribute("mactem_future_extra", at: url), "the old file's extra attribute survived the replace")
    }

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
