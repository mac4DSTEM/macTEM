//
//  SessionSidecarFile.swift
//  Role: the session sidecar's HDF5 file layer (archive: roadmap-registrations-2026-10-15.md V1-2 slice A; ADR 020): where the sidecar lives, and how four
//        strings are written to and read back from it. It moves strings; what they mean (the source identity, the
//        lineage's nodes, the restore verdict) is SessionLineage's. Checked by tools/parity/sidecar-parity against h5py 3.16.0.
//
//  THE FILE: `<source name on disk>.mactem.h5` beside the source (ADR 020 D1). Four root attributes, each a scalar
//  fixed-length, null-padded UTF-8 string as long as its text (ADR 021): `mactem_session_schema` (the identity marker,
//  whose value is the schema, "1"),
//  `mactem_min_reader_schema` ("1": the oldest reader that can read the file without misreading it),
//  `mactem_source` and `mactem_lineage` (JSON). A `.mactem.h5` without the identity marker is foreign.
//
//  WRITE: create or replace, atomically. The file is built under a scratch name and renamed over the target, so a failed
//  write leaves the old sidecar untouched and never leaves half of a new one. An existing file is replaced only if it is
//  one of ours that this build can read AND write without losing anything: a foreign HDF5 file, one that cannot be opened
//  (we cannot say it is ours, and a dangling link is one), one whose minimum reader is newer than this build's, or one
//  written by a newer schema (a replace would drop what this build cannot parse, and mark the file as the older schema) is
//  refused and left as it was. The writer holds itself to the reader's limits: no string over 4 MiB, and none holding a NUL
//  (a C string would end there and silently lose the rest) and, tighter (ADR 023 a),
//  the four attributes' text together at most `maxTotalTextBytes` (60,000), so every file macTEM writes keeps its attributes in
//  HDF5's checksummed object header and never in dense storage, which a crafted file can make the library hang or crash on.
//  A write over that is refused by name (`.sidecarTooLarge`) before the library is touched. The reader still takes up to 4 MiB
//  a string: a file from elsewhere may hold more than macTEM writes.
//
//  PUBLISH, and the race between the check and the rename (Gate B, 2026-10-13): the existing file is checked by opening
//  it, the rename comes later, and a plain `rename` replaces whatever is at the path by then. So the target's (device,
//  inode) is taken BEFORE it is opened, and the new file is published only over that very file. When nothing was there,
//  `renamex_np(RENAME_EXCL)` refuses to replace anything that has appeared since. When a file was there, its identity is
//  looked at once more immediately before a plain `rename`: a window of microseconds, not the length of a build (no
//  rename call replaces "this inode only"), and the identity does not see an in-place rewrite of the same inode. A file
//  system without RENAME_EXCL (exFAT answers ENOTSUP, measured on this Mac 2026-10-13; APFS and FAT32 take it) gets the
//  same look at the path before a plain `rename`: the same microseconds. A write that finds the target changed is
//  refused as `.cannotWrite` and leaves what is there. A replace is a new file: the old one's mode, extended
//  attributes and link-ness are not carried over (a known limit, not a promise).
//
//  READ: opening never writes. The refusals, each by name: it cannot be opened (not HDF5, truncated, unreadable, absent:
//  see below), it is foreign, its minimum reader is newer than ours — checked BEFORE the source and the lineage are read,
//  and before the identity marker's own spelling is parsed (P2: a "v2" identity beside a minimum reader of 2 is a newer
//  file, not a garbled one) — a root whose attributes are in dense storage (below), a variable-length string (below), an
//  attribute that is not a scalar fixed-length string,
//  a string over 4 MiB, invalid UTF-8, a NUL followed by anything but padding. An ASCII-charset string is read as it is
//  (h5py writes UTF-8, but ASCII is a subset).
//
//  NO VARIABLE-LENGTH STRING IS READ (ADR 021). A variable-length string lives in the file's global heap, which has no
//  checksum, and `H5Aread` of one whose heap holds a damaged object size spins forever while SpectroKit's process-wide
//  `HDF5Serial` lock is held: every later HDF5 call, and Quit, waits on it. So each attribute's type is asked first and a
//  variable-length one is refused by name before any `H5Aread`; the global heap is never parsed. A fixed-length string
//  sits in the attribute's own message: in the checksummed object header while it stays in compact storage (a text up to
//  about 65,499 bytes, measured by Gate B 2026-10-14; the switch to dense storage is not at exactly 64 KiB), in dense
//  storage above, which a crafted file with repaired checksums can still make HDF5 hang or crash on (docs/open-items.md,
//  archive: sidecar-dense-hang-2026-10-14/sheet.md: the owner's decision). A variable-length sidecar from slice A's
//  build is therefore refused, and a save cannot replace it (the replace check reads the file as the reader does): the
//  refusal tells the user to delete it.
//
//  NO DENSE ATTRIBUTE STORAGE IS OPENED (ADR 023 d'). Before any attribute is opened or asked for, the root object is opened and its
//  header alone is read (`H5Oget_native_info` with `H5O_NATIVE_INFO_HDR`, which reads the checksummed object header and walks no heap):
//  a root that has attributes but no attribute message in its header keeps them in dense storage, a fractal heap and a B-tree, a form
//  macTEM never writes (the writer's cap keeps every file it writes in the header) and the library has crashed or spun on when a crafted
//  file's heap blocks carry recomputed checksums. It is refused by name, `.denseAttributeStorage`, on a read and on the replace check of a
//  save. A filter, not a guarantee: a forger can recompute the header's own checksum, and a header that keeps its attribute messages and
//  also points at a heap is not caught (tools/parity/sidecar-parity records what the library does with one). The refusal comes before the
//  4 MiB cap below can: a text of that size is always in dense storage, so the cap is a second guard no file reaches.
//
//  P3, a missing file: `read` of a path that holds no file throws `.cannotOpen` like any file it cannot open, never a
//  result that looks like "no sidecar". Whether a sidecar exists is the CALLER's question (`FileManager.fileExists`), asked
//  before the read. Under the app sandbox that question can answer "no" for a file the app may not see (only the chosen
//  file, or a folder the user granted, is visible), and a denied open is `.cannotOpen` too — which is why the two are
//  separate and `read` never answers "none" itself.
//
//  THE 4 MiB CAP is on a string's storage, the size its fixed-length type declares: checked before THIS layer allocates its
//  buffer or calls `H5Aread`, so an oversized string is never copied out, let alone passed on. It does not stop libhdf5,
//  which has already read the attribute's message when the type is asked (Gate B measured a 256 MiB attribute at about
//  twice its size in resident memory): the cap bounds what this layer holds, not what HDF5 reads. The writer stores no
//  more than the text.
//
//  THE FORMAT BOUNDS: the writer sets the file-access property list's library-version bounds to (V18, LATEST) itself, by
//  `H5Pset_libver_bounds` (Gate B 2026-10-14). With an 'earliest' bound a text over about 65,499 bytes cannot be written (the
//  old object header cannot hold it); the bundled library's default is already (V18, V200), but a sidecar's format should
//  not depend on a default. A file so written has superblock version 2 or later and version-2 object headers ("OHDR").
//
//  THE LIBRARY: this file has no HDF5 binding of its own (since FormatoKit 0.5.0). The root-attribute file layer (the
//  fixed-length null-padded strings, the (V18, LATEST) bounds, the dense-storage and variable-length refusals, the 4 MiB cap,
//  the NUL check, the device-and-inode publish with the exclusive rename, the item-replacement scratch directory) is
//  FormatoHDF5's `HDF5RootAttributes`, moved there from this app's cb6e164; its `HDF5FileError` is mapped to `Refusal` in
//  one place below. The process holds one libhdf5, the kit's loader's (FORMATO_HDF5_PATH, the host's Frameworks, the
//  FormatoLibHDF5 framework), and every call runs under the kit's `HDF5Serial` lock (the library is built Threadsafety: OFF).
//  What stays here: the schema, the markers and their order of judgement, the replaceability decision, the 60,000-byte cap,
//  the name rule and the seams. One read is several kit reads (a marker each, then the source and the lineage), because the
//  order of the refusals is part of the contract; a file changed between them is read as the later one finds it.
//

import Foundation
import FormatoHDF5

package nonisolated enum SessionSidecarFile {
    package static let identityAttribute = "mactem_session_schema"
    package static let minReaderAttribute = "mactem_min_reader_schema"
    package static let sourceAttribute = "mactem_source"
    package static let lineageAttribute = "mactem_lineage"

    /// The schema this build writes, and the newest minimum reader it can honour. The one place the number moves.
    package static let schema = 1
    /// A sidecar's name is its source's name on disk plus this.
    package static let suffix = ".mactem.h5"
    /// The longest string, in UTF-8 bytes, that is READ (a file from elsewhere may hold up to this; the writer holds itself to
    /// `maxTotalTextBytes` below, which is far under it).
    package static let maxStringBytes = 4 << 20
    /// The most text, in UTF-8 bytes, the four root attributes may hold together when macTEM WRITES a sidecar (ADR 023 a): below
    /// the measured switch of HDF5 to dense attribute storage (a lineage of about 65,499 bytes) with margin, so every file macTEM
    /// writes keeps its attributes in the checksummed object header. A harness clause holds every file at the cap compact.
    package static let maxTotalTextBytes = 60_000
    /// The bytes the four attributes' texts come to: the identity marker and the minimum reader (the schema's digits each),
    /// the source and the lineage.
    package static func totalTextBytes(sourceBytes: Int, lineageBytes: Int) -> Int {
        2 * String(schema).utf8.count + sourceBytes + lineageBytes
    }
    /// A file name, in UTF-16 code units, that the file system takes (ADR 020 D1, amended 2026-10-14 from the registered
    /// "255 bytes", NAME_MAX): measured on this Mac (APFS, 2026-10-13), 255 × "µ" (510 bytes) and 255 × "日" (765 bytes)
    /// are created, 256 of either, or of an ASCII letter or an emoji, is "File name too long" (the unit test pins both
    /// sides). An emoji is two units, an ASCII letter one.
    package static let maxNameUnits = 255

    /// What a sidecar holds. `source` and `lineage` are nil when the attribute is absent; present, they are valid UTF-8.
    package struct Contents: Equatable, Sendable {
        package var schema: Int
        package var minReader: Int
        package var source: String?
        package var lineage: String?

        package init(schema: Int, minReader: Int, source: String?, lineage: String?) {
            self.schema = schema
            self.minReader = minReader
            self.source = source
            self.lineage = lineage
        }
    }

    package enum Refusal: Error, Equatable {
        /// The source URL is not a file URL, or names no file.
        case noSourceName
        /// The source is itself a sidecar; its sidecar would be `….mactem.h5.mactem.h5`.
        case sourceIsASidecar(String)
        /// The sidecar's name would be longer than the file system takes (UTF-16 units, suffix included).
        case nameTooLong(units: Int)
        /// The bundled HDF5 library could not be loaded.
        case library(String)
        /// The file cannot be opened as HDF5: it is not HDF5, is truncated, or does not exist.
        case cannotOpen(String)
        /// The file is there and the system does not let this process read it (a permission, or the app sandbox, which
        /// grants only what the user chose): named apart from `cannotOpen`, so the app can ask for the file.
        case notPermitted(String)
        /// An HDF5 call failed after the file opened (a damaged file, a full disk): the operation, and why.
        case hdf5(operation: String, detail: String)
        /// An HDF5 file without the identity marker: not a macTEM session sidecar.
        case foreign
        /// The identity marker is there and the minimum-reader marker is not.
        case missingAttribute(String)
        /// An attribute that is not a scalar fixed-length string, text followed by anything but NUL padding, or a marker
        /// that is not a whole number from 1.
        case malformedAttribute(String)
        /// A variable-length string: refused from its type, never read (ADR 021: a damaged one can hang HDF5).
        case variableLengthString(String)
        /// The file demands a newer reader than this build.
        case newerMinReader(found: Int, supported: Int)
        /// A file this build can read, but written by a newer schema: a write over it would downgrade it, so it is refused.
        case newerSchema(found: Int, supported: Int)
        /// A string over the 4 MiB cap (read, or about to be written).
        case stringTooLong(attribute: String, bytes: Int)
        /// A stored string that is not UTF-8.
        case invalidUTF8(String)
        /// A string to write holds a NUL byte.
        case embeddedNUL(String)
        /// The root has attributes and no attribute message in its object header: they are in dense storage (a fractal heap
        /// and a B-tree), a form macTEM never writes and refuses to open (ADR 023 d'): a crafted one can crash or hang libhdf5.
        case denseAttributeStorage
        /// The four attributes' text together is over `maxTotalTextBytes` (ADR 023 a): not written, so that no file macTEM
        /// writes outgrows HDF5's checksummed object header.
        case sidecarTooLarge(bytes: Int)
        /// The write failed; the target was left as it was.
        case cannotWrite(operation: String, detail: String)

        package var reason: String {
            switch self {
            case .noSourceName: "the source is not a file with a name."
            case .sourceIsASidecar(let name): "\(name) is itself a session sidecar, which has no sidecar of its own."
            case .nameTooLong(let units):
                "its name, with \(SessionSidecarFile.suffix), would be \(units) UTF-16 units long; the file system takes \(SessionSidecarFile.maxNameUnits)."
            case .library(let detail): "the bundled HDF5 library could not be loaded (\(detail))."
            case .cannotOpen(let detail): "it is not an HDF5 file, or it cannot be opened (\(detail))."
            case .notPermitted(let detail): "macOS does not let macTEM read it (\(detail))."
            case .hdf5(let operation, let detail): "HDF5 failed while \(operation) (\(detail))."
            case .foreign: "it is an HDF5 file, but not a macTEM session sidecar (no \(SessionSidecarFile.identityAttribute))."
            case .missingAttribute(let name): "its \(name) attribute is missing."
            case .malformedAttribute(let name): "its \(name) attribute is not a single UTF-8 text value of the expected kind."
            case .variableLengthString(let name):
                "its \(name) attribute is variable-length text, which macTEM does not read (a damaged one can hang the HDF5 library). This sidecar is from an early build and a save cannot replace it: delete the file and save again."
            case .newerMinReader(let found, let supported):
                "it needs a macTEM that reads session schema \(found) or newer; this one reads up to \(supported)."
            case .newerSchema(let found, let supported):
                "it was written by session schema \(found), newer than the \(supported) this macTEM writes; replacing it would drop what this one cannot read."
            case .stringTooLong(let attribute, let bytes):
                "its \(attribute) attribute is \(bytes) bytes; the limit is \(SessionSidecarFile.maxStringBytes)."
            case .invalidUTF8(let name): "its \(name) attribute is not valid UTF-8."
            case .embeddedNUL(let name): "the \(name) text holds a NUL byte, which a stored string cannot."
            case .denseAttributeStorage:
                "its attributes are stored in a form macTEM does not write (HDF5 dense attribute storage), which macTEM does not read. A sidecar macTEM saved never is; delete the file and save again."
            case .sidecarTooLarge(let bytes):
                "the session record would be \(bytes) bytes of text; the limit is \(SessionSidecarFile.maxTotalTextBytes). Remove some marks."
            case .cannotWrite(let operation, let detail): "the write failed while \(operation) (\(detail)); nothing was changed."
            }
        }
    }

    // MARK: The name

    /// Where `source`'s sidecar lives: the source's name as it stands on disk (never the lower-cased extension the open
    /// dispatches on: "SCAN.DM4" gives "SCAN.DM4.mactem.h5"), plus `.mactem.h5`, beside it. Refuses a source that is
    /// already a sidecar (case-insensitively: the file system is) and a result over 255 UTF-16 units (`maxNameUnits`). The
    /// units counted are the result URL's own: Foundation hands a file name to the file system decomposed ("Å" is
    /// two units, A and a combining ring, not one), so the name that fits as the URL arrives can be too long as it is
    /// created. For the same reason the spelling of the name is Foundation's, not this function's: a composed or a
    /// decomposed source name gives the same decomposed sidecar name (checked in the unit test).
    package static func sidecarURL(forSource source: URL) throws -> URL {
        let name = source.lastPathComponent
        guard source.isFileURL, !name.isEmpty, name != "/" else { throw Refusal.noSourceName }
        guard !name.lowercased().hasSuffix(suffix) else { throw Refusal.sourceIsASidecar(name) }
        let sidecar = source.deletingLastPathComponent().appendingPathComponent(name + suffix, isDirectory: false)
        let units = sidecar.lastPathComponent.utf16.count
        guard units <= maxNameUnits else { throw Refusal.nameTooLong(units: units) }
        return sidecar
    }

    // MARK: Read

    /// The sidecar at `url`. Throws a `Refusal` for everything it cannot hand back whole (see the file header). Blocks on
    /// the HDF5 lock and the disk: call it off the main actor.
    package static func read(url: URL, betweenReads: (() -> Void)? = nil) throws -> Contents {
        try mapped {
            // The three kit reads under one hold of the HDF5 lock (recursive), and the file's identity looked at before the first
            // and after the last: a file swapped or replaced in between is refused, not read as a mixture of two files. A window
            // of microseconds remains inside each kit read, and an in-place rewrite of the same inode is not seen.
            try HDF5Serial.run {
                let before = HDF5FileIdentity(ofItemAt: url.path)
                let header = try readHeader(of: url)
                betweenReads?()
                let rest = try HDF5RootAttributes.read([sourceAttribute, lineageAttribute], from: url)
                guard HDF5FileIdentity(ofItemAt: url.path) == before else {
                    throw Refusal.cannotOpen("the file changed while it was being read")
                }
                return Contents(schema: header.schema, minReader: header.minReader,
                                source: rest[sourceAttribute], lineage: rest[lineageAttribute])
            }
        }
    }

    /// The kit's file errors as this layer's `Refusal`s, in this one place. A kit error this layer never provokes (a path or
    /// type refusal of the kit's wider API) becomes `.hdf5`, with the kit's wording.
    package static func refusal(_ error: HDF5FileError) -> Refusal {
        switch error {
        case .library(let detail): .library(detail)
        case .cannotOpen(let detail): .cannotOpen(detail)
        case .notPermitted(let detail): .notPermitted(detail)
        case .hdf5(let operation, let detail): .hdf5(operation: operation, detail: detail)
        case .malformedAttribute(let name): .malformedAttribute(name)
        case .variableLengthString(let name): .variableLengthString(name)
        case .stringTooLong(let attribute, let bytes): .stringTooLong(attribute: attribute, bytes: bytes)
        case .invalidUTF8(let name): .invalidUTF8(name)
        case .denseAttributeStorage: .denseAttributeStorage
        case .embeddedNUL(let name): .embeddedNUL(name)
        case .cannotWrite(let operation, let detail): .cannotWrite(operation: operation, detail: publishWording(detail))
        default: .hdf5(operation: "using the file", detail: error.errorDescription ?? "\(error)")
        }
    }

    /// The kit's two publish-race details in this layer's own words ("the sidecar", and what was done): pinned by the unit tests.
    private static func publishWording(_ detail: String) -> String {
        switch detail {
        case "the file was replaced or removed after it was checked; it was left as it is":
            "the sidecar was replaced or removed after it was checked; it was left as it is"
        case "a file appeared at the path after it was checked; it was left as it is":
            "a file appeared at the sidecar's path after it was checked; it was left as it is"
        default: detail
        }
    }

    /// Runs `body`, turning the kit's `HDF5FileError` into a `Refusal`; every other error passes unchanged.
    private static func mapped<T>(_ body: () throws -> T) throws -> T {
        do { return try body() } catch let error as HDF5FileError { throw refusal(error) }
    }

    /// The identity and the minimum reader, in the order that makes P2 true: nothing else is read, and nothing is
    /// returned, for a file that demands a newer reader — and that includes a file whose identity marker is spelled in a
    /// way this build does not know ("v2"): the minimum reader decides before the identity's own form is judged
    /// (Gate B, 2026-10-13; the identity must still be present, or the file is foreign). One kit read per marker, in the
    /// order of the checks: a file without the identity is foreign whatever its other attributes are.
    private static func readHeader(of url: URL) throws -> (schema: Int, minReader: Int) {
        guard let identity = try HDF5RootAttributes.read([identityAttribute], from: url)[identityAttribute] else {
            throw Refusal.foreign
        }
        guard let minimum = try HDF5RootAttributes.read([minReaderAttribute], from: url)[minReaderAttribute] else {
            throw Refusal.missingAttribute(minReaderAttribute)
        }
        guard let minReader = wholeNumber(minimum) else { throw Refusal.malformedAttribute(minReaderAttribute) }
        guard minReader <= schema else { throw Refusal.newerMinReader(found: minReader, supported: schema) }
        guard let found = wholeNumber(identity) else { throw Refusal.malformedAttribute(identityAttribute) }
        return (found, minReader)
    }

    /// A file this build may replace: one of ours that it can read (the header read is the reader's: the markers, and P2), and
    /// not written by a newer schema, whose attributes and groups a replace would drop while marking the file as the older one.
    private static func requireReplaceable(_ url: URL) throws {
        let header = try readHeader(of: url)
        guard header.schema <= schema else { throw Refusal.newerSchema(found: header.schema, supported: schema) }
    }

    /// "1", "2", … — the canonical spelling only, so a garbled marker is garbled, not "readable by luck".
    private static func wholeNumber(_ text: String) -> Int? {
        guard let value = Int(text), value >= 1, String(value) == text else { return nil }
        return value
    }

    // MARK: Write

    /// Test seams of `write`, each called under the HDF5 lock; production passes none. They put a test where the races
    /// are: after the checks and before the publish, which is where a file can appear or be swapped.
    package struct WriteSeams {
        /// The scratch file (the HDF5 file is built there) and the scratch directory holding it (nil: a sibling of the target).
        package var scratchMade: ((_ file: URL, _ directory: URL?) -> Void)?
        /// After the file is built, immediately before it is published.
        package var beforePublish: (() -> Void)?
        /// Publish as on a file system without `RENAME_EXCL` (exFAT answers ENOTSUP), where the fallback runs: the kit's
        /// `HDF5RootAttributes.publish(exclusiveRenameUnavailable:)`.
        package var exclusiveRenameUnavailable: Bool

        package init(scratchMade: ((URL, URL?) -> Void)? = nil, beforePublish: (() -> Void)? = nil,
                     exclusiveRenameUnavailable: Bool = false) {
            self.scratchMade = scratchMade
            self.beforePublish = beforePublish
            self.exclusiveRenameUnavailable = exclusiveRenameUnavailable
        }
    }

    /// Creates the sidecar at `url`, or replaces the one there, holding `source` and `lineage`. Atomic: on any throw the
    /// file at `url` is as it was (absent, or the old sidecar), and only the file that was checked is ever replaced (see
    /// the file header: PUBLISH). Refuses to replace a file that is not a sidecar this build can read and rewrite whole
    /// (`.foreign`, `.cannotOpen`, `.newerMinReader`, `.newerSchema`, `.malformedAttribute`, `.missingAttribute`). Blocks
    /// on the HDF5 lock and the disk: call it off the main actor.
    package static func write(source: String, lineage: String, to url: URL, seams: WriteSeams = WriteSeams()) throws {
        let values = [(sourceAttribute, source), (lineageAttribute, lineage)]
        for (name, value) in values {
            guard !value.utf8.contains(0) else { throw Refusal.embeddedNUL(name) }
            let bytes = value.utf8.count
            guard bytes <= maxStringBytes else { throw Refusal.stringTooLong(attribute: name, bytes: bytes) }
        }
        let total = totalTextBytes(sourceBytes: source.utf8.count, lineageBytes: lineage.utf8.count)
        guard total <= maxTotalTextBytes else { throw Refusal.sidecarTooLarge(bytes: total) }
        let attributes = [(identityAttribute, String(schema)), (minReaderAttribute, String(schema))] + values
        guard url.isFileURL else { throw Refusal.cannotWrite(operation: "locating the file", detail: "not a file URL") }
        // The whole check-build-publish under the one HDF5 lock (it is recursive: the kit's calls take it again), so no other
        // HDF5 user in the process runs between the check and the rename, and the seams are called under it.
        try mapped {
            try HDF5Serial.run {
                // What is at the path, itself and not what a link points to: a dangling link is something, and it cannot be opened.
                let existing = HDF5FileIdentity(ofItemAt: url.path)
                if existing != nil { try requireReplaceable(url) }
                let (temporary, scratchDirectory) = HDF5RootAttributes.temporaryURL(for: url, namePrefix: ".mactem-")
                seams.scratchMade?(temporary, scratchDirectory)
                var published = false
                defer {
                    // try? OK: best-effort cleanup on the way out. On the failure path the real error is already in flight,
                    // and a leftover scratch file in the system's own replacement directory harms nothing it did not report.
                    if !published { try? FileManager.default.removeItem(at: temporary) }
                    if let scratchDirectory { try? FileManager.default.removeItem(at: scratchDirectory) }
                }
                try HDF5RootAttributes.write(attributes.map { (name: $0.0, value: $0.1) }, to: temporary)
                seams.beforePublish?()
                try HDF5RootAttributes.publish(temporary, onto: url, replacing: existing,
                                               exclusiveRenameUnavailable: seams.exclusiveRenameUnavailable)
                published = true
            }
        }
    }
}
