//
//  SessionSidecarFileTests.swift
//  The session sidecar's HDF5 file layer: the name rule, the four root attributes written
//  and read back, and every refusal by name — a foreign HDF5 file, a newer minimum reader (P2), a file that cannot be
//  opened (P3), an attribute of the wrong kind, a string over 4 MiB, invalid UTF-8. The parity against h5py 3.16.0, which
//  writes and reads the same files independently, is tools/parity/sidecar-parity; these pin the layer's own rules without Python.
//  Files the layer would never write (a foreign file, a newer minimum reader, a wrong-kind attribute) are planted with the
//  same HDF5 binding, through `TestHDF5Library.withLibrary` (TestHDF5Binding.swift: the same libhdf5 image and the same `HDF5Serial` lock as FormatoKit's).
//  Each test names the mutation of SessionSidecarFile.swift it was broken by.
//  The review tests of 2026-10-13 pin what the first set could not see: a file that appears (or is swapped) between the
//  check and the publish, a failed close, nothing left in the system's replacement directory, the path never missing
//  during a replace, and the file handles closed (the test of the freed string buffers went with the variable-length read
//  it measured). Failure injection is the layer's own
//  `WriteSeams` (a file appearing at the one moment it can) and, for a disk that cannot take the file, a file size limit
//  set around one write. The re-verifier's three (2026-10-14) pin a letter both normal forms rewrite, a schema two
//  newer, and the refusal's wording when a file appears.
//  Since 2026-10-14 the variable-length string is retired: the four attributes are fixed-length, null-padded UTF-8, and a
//  variable-length one is refused by name from its type, before any `H5Aread`. The fixtures follow: what `Planted.text`,
//  `.bytes` and `.asciiText` plant is what the writer writes; `.variableText` is slice A's old form, planted to be refused.
//  The tests it adds pin one rule each: the refusal by name for each
//  of the four attributes, a variable-length sidecar never overwritten, the cap on the declared size, text then NUL then
//  text, h5py's padding, the empty text as one NUL, and the layout the writer produces.
//

import XCTest
import Darwin
import FormatoHDF5
import TEMCore

nonisolated final class SessionSidecarFileTests: XCTestCase {
    typealias Sidecar = SessionSidecarFile

    // MARK: Fixtures

    func scratchDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionSidecarFileTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    /// The refusal `body` throws, or nil (and a failure) if it returns or throws anything else.
    func refusal<T>(_ body: () throws -> T, file: StaticString = #filePath, line: UInt = #line) -> Sidecar.Refusal? {
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

    func isCannotOpen(_ refusal: Sidecar.Refusal?) -> Bool {
        if case .cannotOpen = refusal { return true }
        return false
    }

    /// An attribute a sidecar never holds, or holds in a form this layer never writes: planted with the binding. `text`,
    /// `bytes` and `asciiText` are the form the writer writes: a scalar fixed-length string, null-padded, as long
    /// as its bytes (one NUL when there are none, HDF5 having no size 0). The others are forms the reader meets from
    /// elsewhere, or must refuse.
    nonisolated enum Planted {
        case text(String, String)                   // fixed-length UTF-8, NULLPAD, size = the UTF-8 bytes: the writer's form
        case bytes(String, [UInt8])                 // the same, from raw bytes (not necessarily UTF-8)
        case asciiText(String, String)              // the same with the ASCII character set (h5py's np.bytes_)
        case paddedText(String, String, size: Int)  // the same in a field of `size` bytes, NULs after the text (h5py's string_dtype(length:))
        case terminatedText(String, String)         // NULLTERM, size = bytes + 1, a trailing NUL: what a C writer's H5T_C_S1 gives
        case spacePaddedText(String, String, size: Int)  // SPACEPAD: the text, then spaces up to `size` (what a Fortran or fixed-width writer gives)
        case integer(String, Int32)                 // a scalar 32-bit integer
        case textArray(String, [String])            // a rank-1 array of fixed-length strings
        case variableText(String, String)           // a scalar variable-length UTF-8 string: slice A's form, refused since 2026-10-14
        case variableTextArray(String, [String])    // a rank-1 array of variable-length strings
    }

    static let nullTerminated: Int32 = 0    // H5T_STR_NULLTERM
    static let nullPadded: Int32 = 1        // H5T_STR_NULLPAD
    static let spacePadded: Int32 = 2       // H5T_STR_SPACEPAD

    /// `H5Tset_strpad`, looked up on the binding's own handle as the source does (the binding's symbol list has none).
    func setPadding(_ type: Int64, _ padding: Int32, _ h5: TestHDF5Library) -> Int32 {
        typealias SetStrpad = @convention(c) (Int64, Int32) -> Int32
        guard let symbol = dlsym(h5.handle, "H5Tset_strpad") else { return -1 }
        return unsafeBitCast(symbol, to: SetStrpad.self)(type, padding)
    }

    /// Creates an HDF5 file at `url` holding exactly `attributes` on its root.
    func plant(_ url: URL, _ attributes: [Planted], file: StaticString = #filePath, line: UInt = #line) throws {
        try TestHDF5Library.withLibrary { h5 in
            let id = url.path.withCString { h5.h5fcreate($0, h5FileTruncate, h5DefaultProperty, h5DefaultProperty) }
            XCTAssertGreaterThanOrEqual(id, 0, "creating \(url.lastPathComponent)", file: file, line: line)
            defer { _ = h5.h5fclose(id) }
            for attribute in attributes { put(attribute, on: id, h5, file: file, line: line) }
        }
    }

    func put(_ attribute: Planted, on id: Int64, _ h5: TestHDF5Library, file: StaticString, line: UInt) {
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
    /// never for a variable-length one (that read is the one the fixed-length rule forbids).
    nonisolated struct StoredForm: Equatable {
        var isString: Bool
        var isVariableLength: Bool
        var size: Int
        var characterSet: Int32
        var padding: Int32
        var rank: Int32
        var count: Int64
        var bytes: [UInt8]?
    }

    func storedForm(_ name: String, at url: URL, file: StaticString = #filePath, line: UInt = #line) throws -> StoredForm {
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
    /// stand-in, for a test, for the damaged object SIZE in the same heap that makes `H5Aread` spin forever.
    func breakGlobalHeaps(in url: URL) throws -> Int {
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
    func hasAttribute(_ name: String, at url: URL) throws -> Bool {
        try TestHDF5Library.withLibrary { h5 in
            let file = url.path.withCString { h5.h5fopen($0, h5FileReadOnly, h5DefaultProperty) }
            XCTAssertGreaterThanOrEqual(file, 0)
            defer { _ = h5.h5fclose(file) }
            return name.withCString { h5.h5aexists(file, $0) } > 0
        }
    }

    func bytes(_ url: URL) throws -> Data { try Data(contentsOf: url) }

    /// A string of at least `count` UTF-8 bytes that looks like what a lineage holds, and carries "Å", "µ" and quotes.
    func lineageLike(bytes count: Int) -> String {
        let unit = "{\"id\":\"s1\",\"unit\":\"Å\",\"µ\":[1.5,2.25],\"note\":\"a \\\"quoted\\\" word\"}\n"
        var text = ""
        while text.utf8.count < count { text += unit }
        return text
    }

    // MARK: The name

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
    /// characters (amended 2026-10-14 from the earlier "255 bytes": the measurement on this Mac, APFS,
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

    /// The sidecar finds libhdf5 with no override and no `Frameworks` copy: the app embeds none, FormatoKit's
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
    /// long as the text's UTF-8 bytes: the layout h5py and every other reader sees, and the one the reader's
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
}
