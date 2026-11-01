// tools/parity/sidecar-parity/main.swift — macTEM's session sidecar (the file layer; the fixed-length strings:
// SessionSidecarFile (over FormatoHDF5's HDF5RootAttributes) and SessionLineage, through Package.swift's
// SidecarParity target, with fuzz.swift) against h5py 3.16.0, through reference.py's plan and truth (manifest.json) and its reading of what
// Swift wrote (readback.json).
//
//     harness --write <ref-dir> <out-dir>      Swift writes the planted sessions to <out-dir>/swift/ and records what it passed
//                                              to the writer (<out-dir>/swift-written.json); reference.py then reads them
//     harness <ref-dir> <out-dir> [--fuzz]     the gate: every check below, then the summary; --fuzz adds clause (e) and the dense-storage fuzz
//     harness <ref-dir> <out-dir> --fuzz-dense   the gate and only the second opinion's 648 windows of the first dense base (a control's run)
//     harness --read <file> | --write-over <file> | --fuzz-selftest <mode> <dir>     the child processes (fuzz.swift)
//
// (a) Swift writes, h5py reads (reference.py `readback`, merged here by name): each of the four root attributes is a SCALAR
//     FIXED-LENGTH string (h5py's low-level type: not variable-length), null-padded, UTF-8, as many bytes as the text, its
//     storage byte-equal to the string Swift handed the writer; the JSON parsed
//     by Python equals the plan; every coordinate and measurement, as `float(text)`, bit-equal to the planted double; every
//     recorded date the planted integer; the lineage and the identity in Python's canonical form. Here: Swift writes the file
//     without error, reads its own file back equal, names it as the registered rule says, and meets the recorder's rules while
//     it builds the lineage (`rules`: an add citing a removed or a missing node, and a replace of a removed node, are refused
//     by name and change nothing; a refused add burns no id). The writer is also offered strings directly (`raw_writes`): a NUL,
//     over 4 MiB, exactly 4 MiB, and a replace over a sidecar h5py wrote, which h5py then reads.
// (b) h5py writes, Swift reads or refuses (the planted sidecars): a valid one read byte for byte, decoded equal and re-encoded
//     byte-equal to Python's text; a newer minimum reader refused by name, BEFORE the source and the lineage are read; a foreign
//     file (no identity) refused by name, and Swift's write over it refused with the file byte-unchanged; a lineage over 4 MiB, an
//     attribute that is invalid UTF-8, an array, a null dataspace or an integer, each refused by name; a NUL followed by more text
//     refused, and NUL padding of any length read as the text before it; a cycle, a missing input,
//     repeated ids, a next_id out of bounds, too many nodes, each refused by SessionLineage.decode with its named refusal; an
//     unknown version read-only, not refused; a file that is not HDF5, empty, truncated, unreadable, absent or a link to nothing:
//     cannotOpen, never "no file", and never overwritten; a sidecar of a newer schema read, and a write over it refused
//     (newerSchema) with the bytes unchanged; a "v2" identity beside a minimum reader of 2 refused as the minimum-reader refusal.
// (c) the name rule: SCAN.DM4 -> SCAN.DM4.mactem.h5 verbatim; a source that is already a sidecar refused; a result over 255
//     UTF-16 code units refused (255 units of any letter accepted).
// (d) the restore verdict (P4) on planted identities, and the fingerprint of the pixels against hashlib.sha256 over numpy's
//     float32 little-endian bytes of the same pixels.
// (e) The fixed-length-string rule, P2 and P3. Each of the four attributes variable-length in an otherwise valid sidecar (planted by h5py), and the
//     archived hang file, are refused by name (`variableLengthString`) by the reader, and the replace check refuses the
//     identity's and the minimum reader's; every one of those reads runs in its own process with a deadline, so that a
//     reader that parsed the damaged heap would fail "swift reads hangcase-flip" and not stall the gate. With --fuzz (the one
//     unmutated run), the fuzz of fuzz.swift: three Swift-written sidecars, mutated and read, no hang, no crash, no silent
//     change where the text is within about 65,499 bytes.
//
// And one check that is about the harness, not the sources: the HDF5 library loaded is the copy run.sh named.
//
// Failures are the mutations' evidence: tools/parity/sidecar-parity/run.sh breaks the sources under test in scratch copies and requires
// each mutant to fail the check named for it.

@testable import TEMCore
import CryptoKit
import Darwin
import Foundation

// MARK: - The plan (reference.py's manifest.json)

struct Param: Decodable {
    let k: String
    let s: String?
    let d: String?
}

struct EdgeSpec: Decodable {
    let step: String
    let role: String
}

struct OpSpec: Decodable {
    let op: String
    let id: String?
    let kind: String?
    let parameters: [Param]?
    let results: [Param]?
    let inputs: [EdgeSpec]?
    let ms: Int64
    /// A date with a fraction of a millisecond, in milliseconds since 1970; `ms` is then the recorded value it must give.
    let at: Double?
    /// A date no millisecond count can hold: "+inf", "-inf" or "nan" (a JSON number can be none of them); `ms` is then the
    /// value the registered clamp gives (±9e15; 0 for NaN).
    let at_special: String?
    /// What an `add_refused` operation must be refused with.
    let refusal: RefusalSpec?
}

struct RawWriteSpec: Decodable {
    let id: String
    let source: String?
    let lineage: String?
    let fill_attribute: String?
    let fill_bytes: Int?
    let from: String?
    let outcome: String
    let refusal: RefusalSpec?
}

struct IdentitySpec: Decodable {
    let file_name: String
    let byte_size: Int64
    let object: String
    let pixels: String
}

struct NodeSpec: Decodable {
    let id: String
    let kind: String
    let inputs: [EdgeSpec]
    let recorded: Int64
    let removed: Int64?
    let stored_parameters: [String: String]
    let stored_results: [String: String]
    let coords: [String: String]
}

struct SessionSpec: Decodable {
    let id: String
    let source_name: String
    let sidecar_name: String
    let identity: IdentitySpec
    let ops: [OpSpec]
}

struct RefusalSpec: Decodable {
    let name: String
    let found: Int?
    let supported: Int?
    let attribute: String?
    let bytes: Int?
    let id: String?
    let next_id: Int?
    let step: String?
    let from: String?
    let count: Int?
    let field: String?
    let source: String?
    /// `nameTooLong`: the sidecar's name in UTF-16 code units (the file system's measure).
    let units: Int?
}

extension RefusalSpec {
    init(named name: String) {
        self.init(name: name, found: nil, supported: nil, attribute: nil, bytes: nil, id: nil, next_id: nil, step: nil, from: nil,
                  count: nil, field: nil, source: nil, units: nil)
    }
}

struct ReadSpec: Decodable {
    let outcome: String
    let schema: Int?
    let min_reader: Int?
    let source_bytes: Int?
    let source_sha256: String?
    let lineage_bytes: Int?
    let lineage_sha256: String?
    let refusal: RefusalSpec?
}

struct LineageSpec: Decodable {
    let outcome: String
    let next_id: Int?
    let nodes: [NodeSpec]?
    let canonical: String?
    let count: Int?
    let exhausted: Bool?
    let version: Int?
    let refusal: RefusalSpec?
}

struct SourceSpec: Decodable {
    let outcome: String
    let file_name: String?
    let byte_size: Int64?
    let object: String?
    let width: Int?
    let height: Int?
    let pixel_sha256: String?
    let canonical: String?
    let refusal: RefusalSpec?
}

struct PlantedSpec: Decodable {
    let name: String
    let file: String
    let read: ReadSpec
    let lineage: LineageSpec?
    let source: SourceSpec?
    let write_over: RefusalSpec?
    let absent: Bool
    /// A symbolic link to nothing, planted at the sidecar's path.
    let dangling: Bool
    /// Read in a child process with a deadline (a variable-length attribute, the hang file), never in this process.
    let child: Bool
    /// A write over it succeeds (its header is readable and the write never reads the rest), and reads back as `{}` and `{}`.
    let replaces: Bool
    /// h5py says the root's attributes are in dense storage: the read is refused by name, and the lineage or the
    /// identity text the decode is checked on is kept beside the sidecar.
    let dense: Bool
    let lineage_text_file: String?
    let source_text_file: String?
}

struct URLCase: Decodable {
    let label: String
    let path: String?
    let url: String?
    let absolute: String?
    let outcome: String
    let name: String?
    let refusal: RefusalSpec?
}

struct VerdictExpect: Decodable {
    let kind: String
    let from: String?
}

struct VerdictCase: Decodable {
    let name: String
    let stored: IdentitySpec
    let opened: IdentitySpec
    let expect: VerdictExpect
    let names: [String]?
    let shapes: [String]?
}

struct PixelSet: Decodable {
    let name: String
    let width: Int
    let height: Int
    let file: String
    let sha256: String
}

struct Manifest: Decodable {
    let h5py: String
    let numpy: String
    let pixels: [PixelSet]
    let sessions: [SessionSpec]
    let planted: [PlantedSpec]
    let urls: [URLCase]
    let verdicts: [VerdictCase]
    let raw_writes: [RawWriteSpec]
    let fuzz: FuzzPlan
    let marks: MarksPlan
}

/// What reference.py's `readback` found, one entry per check.
struct Readback: Decodable {
    struct Item: Decodable {
        let name: String
        let ok: Bool
        let detail: String
    }
    let checks: [Item]
}

/// What the write step did, for reference.py to compare h5py's reading with: the exact strings handed to the writer.
struct WrittenSession: Codable {
    let id: String
    var file: String?
    var source_json: String?
    var lineage_json: String?
    var error: String?
    var roundtrip: String?
    /// Where a rule of the recorder (a refused add, a refused replace) did not hold, one sentence each.
    var rules: [String] = []
}

struct WrittenRaw: Codable {
    let id: String
    var problem: String?
}

struct Written: Codable {
    var sessions: [WrittenSession]
    var raw: [WrittenRaw] = []
}

struct HarnessError: Error, CustomStringConvertible {
    let description: String
}

/// Failures are counted here, not in a global: Swift 6 refuses a mutable global in a nonisolated module.
struct Report {
    private(set) var failures = 0
    private(set) var checks = 0

    mutating func check(_ ok: Bool, _ name: String, _ detail: @autoclosure () -> String) {
        checks += 1
        if ok { return }
        failures += 1
        print("  FAIL  \(name): \(detail())")
    }
}

// MARK: - Helpers

func sha256hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

func utf8Equal(_ a: String, _ b: String) -> Bool { Array(a.utf8) == Array(b.utf8) }

func nfc(_ text: String) -> String { text.precomposedStringWithCanonicalMapping }

func readFloats(_ path: String) throws -> [Float] {
    try Data(contentsOf: URL(fileURLWithPath: path)).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
}

/// A planted number: its text is Swift's own `coordinateString` of the double the plan names by its IEEE-754 bit pattern;
/// a planted string is itself.
func text(_ p: Param) throws -> String {
    if let s = p.s { return s }
    guard let hex = p.d, let bits = UInt64(hex, radix: 16) else { throw HarnessError(description: "bad planted number \(p.k)") }
    return SessionLineage.coordinateString(Double(bitPattern: bits))
}

func dictionary(_ params: [Param]?) throws -> [String: String] {
    var out: [String: String] = [:]
    for p in params ?? [] { out[p.k] = try text(p) }
    return out
}

func loadPixels(_ ref: URL, _ manifest: Manifest) throws -> [String: (width: Int, height: Int, pixels: [Float])] {
    var out: [String: (width: Int, height: Int, pixels: [Float])] = [:]
    for set in manifest.pixels {
        out[set.name] = (set.width, set.height, try readFloats(ref.appendingPathComponent(set.file).path))
    }
    return out
}

func image(_ pixels: (width: Int, height: Int, pixels: [Float]), fileName: String, source: String) -> CalibratedImage {
    CalibratedImage(width: pixels.width, height: pixels.height, pixels: pixels.pixels, x: nil, y: nil, fileName: fileName,
                    source: source, voltage: nil)
}

func matches(_ r: SessionSidecarFile.Refusal, _ s: RefusalSpec) -> Bool {
    switch r {
    case .noSourceName: return s.name == "noSourceName"
    case .sourceIsASidecar(let n): return s.name == "sourceIsASidecar" && (s.source.map { utf8Equal($0, n) } ?? true)
    case .nameTooLong(let units): return s.name == "nameTooLong" && s.units == units
    case .library: return s.name == "library"
    case .cannotOpen: return s.name == "cannotOpen"
    case .notPermitted: return s.name == "notPermitted"
    case .hdf5: return s.name == "hdf5"
    case .foreign: return s.name == "foreign"
    case .missingAttribute(let a): return s.name == "missingAttribute" && s.attribute == a
    case .malformedAttribute(let a): return s.name == "malformedAttribute" && s.attribute == a
    case .variableLengthString(let a): return s.name == "variableLengthString" && s.attribute == a
    case .newerMinReader(let found, let supported): return s.name == "newerMinReader" && s.found == found && s.supported == supported
    case .newerSchema(let found, let supported): return s.name == "newerSchema" && s.found == found && s.supported == supported
    case .stringTooLong(let a, let bytes): return s.name == "stringTooLong" && s.attribute == a && s.bytes == bytes
    case .invalidUTF8(let a): return s.name == "invalidUTF8" && s.attribute == a
    case .embeddedNUL(let a): return s.name == "embeddedNUL" && s.attribute == a
    case .cannotWrite: return s.name == "cannotWrite"
    case .sidecarTooLarge(let bytes): return s.name == "sidecarTooLarge" && s.bytes == bytes
    case .denseAttributeStorage: return s.name == "denseAttributeStorage"
    }
}

func matches(_ r: SessionLineage.Refusal, _ s: RefusalSpec) -> Bool {
    switch r {
    case .tooLarge(let bytes): return s.name == "tooLarge" && s.bytes == bytes
    case .malformed: return s.name == "malformed"
    case .tooManyNodes(let n): return s.name == "tooManyNodes" && s.count == n
    case .badNextID(let n): return s.name == "badNextID" && s.next_id == n
    case .badID(let id): return s.name == "badID" && s.id == id
    case .duplicateID(let id): return s.name == "duplicateID" && s.id == id
    case .idNotBelowNextID(let id, let next): return s.name == "idNotBelowNextID" && s.id == id && s.next_id == next
    case .danglingInput(let step, let from): return s.name == "danglingInput" && s.step == step && s.from == from
    case .cycle: return s.name == "cycle"
    case .unsupportedVersion(let v): return s.name == "unsupportedVersion" && s.count == v
    case .idsExhausted: return s.name == "idsExhausted"
    case .tooLargeToSave, .notFinite: return false      // the owner's refusals: a decode never produces them
    }
}

func matches(_ r: SessionSourceIdentity.Refusal, _ s: RefusalSpec) -> Bool {
    switch r {
    case .tooLarge(let bytes): return s.name == "tooLarge" && s.bytes == bytes
    case .malformed: return s.name == "malformed"
    case .invalid(let field): return s.name == "invalid" && s.field == field
    }
}

func describe(_ spec: RefusalSpec) -> String {
    var parts = [spec.name]
    if let v = spec.found { parts.append("found \(v)") }
    if let v = spec.supported { parts.append("supported \(v)") }
    if let v = spec.attribute { parts.append("attribute \(v)") }
    if let v = spec.bytes { parts.append("bytes \(v)") }
    if let v = spec.units { parts.append("units \(v)") }
    if let v = spec.id { parts.append("id \(v)") }
    if let v = spec.next_id { parts.append("next_id \(v)") }
    if let v = spec.step { parts.append("step \(v)") }
    if let v = spec.from { parts.append("from \(v)") }
    if let v = spec.count { parts.append("count \(v)") }
    if let v = spec.field { parts.append("field \(v)") }
    return parts.joined(separator: ", ")
}

func textProblem(_ label: String, _ value: String?, bytes: Int?, sha: String?) -> [String] {
    guard let value else { return bytes == nil ? [] : ["\(label) is absent; the file holds \(bytes ?? 0) bytes"] }
    guard let bytes, let sha else { return ["\(label) is present (\(value.utf8.count) bytes); the file holds none"] }
    let data = Data(value.utf8)
    if data.count != bytes { return ["\(label) is \(data.count) bytes; the file holds \(bytes)"] }
    if sha256hex(data) != sha { return ["\(label) differs from the stored bytes (same length \(bytes))"] }
    return []
}

func contentsProblems(_ c: SessionSidecarFile.Contents, _ r: ReadSpec) -> [String] {
    var problems: [String] = []
    if c.schema != r.schema { problems.append("schema \(c.schema), want \(r.schema ?? -1)") }
    if c.minReader != r.min_reader { problems.append("minReader \(c.minReader), want \(r.min_reader ?? -1)") }
    problems += textProblem("source", c.source, bytes: r.source_bytes, sha: r.source_sha256)
    problems += textProblem("lineage", c.lineage, bytes: r.lineage_bytes, sha: r.lineage_sha256)
    return problems
}

func nodeProblems(_ got: SessionLineage.Node, _ want: NodeSpec) -> [String] {
    var problems: [String] = []
    let id = want.id
    if got.id != id { problems.append("id \(got.id) vs \(id)") }
    if got.kind != want.kind { problems.append("\(id) kind \(got.kind) vs \(want.kind)") }
    if got.parameters != want.stored_parameters { problems.append("\(id) parameters \(got.parameters) vs \(want.stored_parameters)") }
    if got.results != want.stored_results { problems.append("\(id) results \(got.results) vs \(want.stored_results)") }
    if got.inputs.map({ [$0.step, $0.role] }) != want.inputs.map({ [$0.step, $0.role] }) { problems.append("\(id) inputs") }
    if !got.external.isEmpty { problems.append("\(id) external is not empty") }
    if got.recorded != want.recorded { problems.append("\(id) recorded \(got.recorded) vs \(want.recorded)") }
    if got.removed != want.removed { problems.append("\(id) removed \(String(describing: got.removed)) vs \(String(describing: want.removed))") }
    for (path, hex) in want.coords {
        let parts = path.split(separator: ".", maxSplits: 1).map(String.init)
        let stored = parts[0] == "parameters" ? got.parameters[parts[1]] : got.results[parts[1]]
        let bits = stored.flatMap { SessionLineage.coordinate(from: $0) }.map { String($0.bitPattern, radix: 16) }
        let want = UInt64(hex, radix: 16).map { String($0, radix: 16) }
        if bits != want { problems.append("\(id) \(path) reads as \(bits ?? "nil"), planted bits \(want ?? "nil")") }
    }
    return problems
}

// MARK: - The write step: Swift writes the planted sessions

/// The date an operation happens at: planted integer milliseconds, a planted fraction of a millisecond, or a date no
/// millisecond count can hold.
func plannedDate(_ op: OpSpec) throws -> Date {
    switch op.at_special {
    case nil: return Date(timeIntervalSince1970: (op.at ?? Double(op.ms)) / 1000)
    case "+inf"?: return Date(timeIntervalSince1970: .infinity)
    case "-inf"?: return Date(timeIntervalSince1970: -.infinity)
    case "nan"?: return Date(timeIntervalSince1970: .nan)
    default: throw HarnessError(description: "unknown special date \(op.at_special ?? "?")")
    }
}

func writeSessions(manifest: Manifest, ref: URL, out: URL) throws {
    let directory = out.appendingPathComponent("swift", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let pixels = try loadPixels(ref, manifest)
    var written = Written(sessions: [])
    for session in manifest.sessions {
        var record = WrittenSession(id: session.id)
        do {
            var lineage = SessionLineage()
            for (index, op) in session.ops.enumerated() {
                // A date goes through the one place a date becomes a number.
                let ms = SessionLineage.milliseconds(try plannedDate(op))
                let edges = (op.inputs ?? []).map { SessionLineage.Edge(step: $0.step, role: $0.role) }
                switch op.op {
                case "add":
                    try lineage.add(kind: op.kind ?? "", parameters: dictionary(op.parameters), results: dictionary(op.results),
                                    inputs: edges, recorded: ms)
                case "add_refused":
                    // An input naming a removed (or a missing) node: refused, by name, and nothing is minted or changed.
                    let before = lineage
                    let want = op.refusal ?? RefusalSpec(named: "?")
                    do {
                        let id = try lineage.add(kind: op.kind ?? "", parameters: dictionary(op.parameters),
                                                 results: dictionary(op.results), inputs: edges, recorded: ms)
                        record.rules.append("operation \(index): the add citing \(edges.map(\.step)) succeeded as \(id); want the refusal \(describe(want))")
                    } catch let refusal as SessionLineage.Refusal {
                        if !matches(refusal, want) { record.rules.append("operation \(index): the add was refused as \(refusal); want \(describe(want))") }
                    }
                    if lineage != before { record.rules.append("operation \(index): an add that was refused changed the lineage") }
                case "replace":
                    guard lineage.replace(id: op.id ?? "", parameters: try dictionary(op.parameters),
                                          results: try dictionary(op.results), recorded: ms) else {
                        throw HarnessError(description: "replace \(op.id ?? "?") found no node")
                    }
                case "replace_refused":
                    // A removed node (kept for a citer) is never edited.
                    let before = lineage
                    if lineage.replace(id: op.id ?? "", parameters: try dictionary(op.parameters),
                                       results: try dictionary(op.results), recorded: ms) {
                        record.rules.append("operation \(index): the replace of the removed node \(op.id ?? "?") succeeded")
                    }
                    if lineage != before { record.rules.append("operation \(index): a replace that was refused changed the lineage") }
                case "remove":
                    _ = lineage.remove(id: op.id ?? "", at: ms)
                default:
                    throw HarnessError(description: "unknown operation \(op.op)")
                }
            }
            guard let set = pixels[session.identity.pixels] else { throw HarnessError(description: "no pixel set \(session.identity.pixels)") }
            let identity = SessionSourceIdentity.of(
                image(set, fileName: session.identity.file_name, source: session.identity.object),
                fileByteSize: session.identity.byte_size)
            let lineageJSON = try lineage.jsonString()
            let sourceJSON = try identity.jsonString()
            let url = try SessionSidecarFile.sidecarURL(forSource: directory.appendingPathComponent(session.source_name))
            try SessionSidecarFile.write(source: sourceJSON, lineage: lineageJSON, to: url)
            record.file = url.lastPathComponent
            record.source_json = sourceJSON
            record.lineage_json = lineageJSON

            // Swift reads its own file back: equal strings, an equal lineage, an equal identity.
            var problems: [String] = []
            let contents = try SessionSidecarFile.read(url: url)
            if contents.schema != 1 || contents.minReader != 1 { problems.append("markers \(contents.schema)/\(contents.minReader)") }
            if !(contents.source.map { utf8Equal($0, sourceJSON) } ?? false) { problems.append("source text differs") }
            if !(contents.lineage.map { utf8Equal($0, lineageJSON) } ?? false) { problems.append("lineage text differs") }
            if (try? SessionLineage.decode(contents.lineage ?? "")) != lineage { problems.append("decoded lineage differs") }
            if (try? SessionSourceIdentity.decode(contents.source ?? "")) != identity { problems.append("decoded identity differs") }
            record.roundtrip = problems.isEmpty ? nil : problems.joined(separator: "; ")
        } catch {
            record.error = "\(error)"
        }
        written.sessions.append(record)
    }
    // The writer offered strings directly: its own limits (a NUL, 4 MiB), and a replace over a sidecar h5py wrote.
    let rawDirectory = out.appendingPathComponent("swift-raw", isDirectory: true)
    try FileManager.default.createDirectory(at: rawDirectory, withIntermediateDirectories: true)
    for raw in manifest.raw_writes {
        var record = WrittenRaw(id: raw.id)
        let url = rawDirectory.appendingPathComponent(raw.id + SessionSidecarFile.suffix)
        if let from = raw.from { try FileManager.default.copyItem(at: ref.appendingPathComponent(from), to: url) }
        func text(_ attribute: String, _ given: String?) -> String {
            raw.fill_attribute == attribute ? String(repeating: "y", count: raw.fill_bytes ?? 0) : (given ?? "{}")
        }
        do {
            try SessionSidecarFile.write(source: text("source", raw.source), lineage: text("lineage", raw.lineage), to: url)
            if raw.outcome != "written" { record.problem = "the write succeeded; want the refusal \(describe(raw.refusal ?? RefusalSpec(named: "?")))" }
        } catch let r as SessionSidecarFile.Refusal {
            if raw.outcome == "written" {
                record.problem = "refused: \(r)"
            } else if !matches(r, raw.refusal ?? RefusalSpec(named: "?")) {
                record.problem = "refused as \(r); want \(describe(raw.refusal ?? RefusalSpec(named: "?")))"
            }
        } catch {
            record.problem = "threw \(error)"
        }
        if raw.outcome == "refusal", FileManager.default.fileExists(atPath: url.path) {
            record.problem = (record.problem.map { $0 + "; " } ?? "") + "a file was left behind"
        }
        written.raw.append(record)
    }
    try JSONEncoder().encode(written).write(to: out.appendingPathComponent("swift-written.json"))
    print("write: \(written.sessions.count) sessions, \(written.sessions.filter { $0.error != nil }.count) with an error")
}

// MARK: - The gate

/// Planted sidecars: Swift reads or refuses each as registered; a refused file is never overwritten.
func checkPlanted(_ manifest: Manifest, ref: URL, out: URL, _ report: inout Report) throws {
    let scratch = out.appendingPathComponent("overwrite", isDirectory: true)
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    let childScratch = out.appendingPathComponent("child", isDirectory: true)
    try FileManager.default.createDirectory(at: childScratch, withIntermediateDirectories: true)
    let deadline = manifest.fuzz.deadline
    for p in manifest.planted {
        let url = ref.appendingPathComponent(p.file)
        if p.child {
            checkPlantedInChild(p, url: url, scratch: scratch, childScratch: childScratch, deadline: deadline, &report)
            checkReplaces(p, url: url, scratch: scratch, childScratch: childScratch, deadline: deadline, &report)
            continue
        }
        var contents: SessionSidecarFile.Contents?
        var refusal: SessionSidecarFile.Refusal?
        var other: String?
        do {
            contents = try SessionSidecarFile.read(url: url)
        } catch let r as SessionSidecarFile.Refusal {
            refusal = r
        } catch {
            other = "\(error)"
        }
        let got = contents.map { "read, schema \($0.schema), minReader \($0.minReader), source \($0.source?.utf8.count ?? -1) bytes, lineage \($0.lineage?.utf8.count ?? -1) bytes" }
            ?? refusal.map { "refused: \($0)" } ?? other.map { "error: \($0)" } ?? "nothing"
        switch p.read.outcome {
        case "contents":
            if let contents {
                let problems = contentsProblems(contents, p.read)
                report.check(problems.isEmpty, "swift reads \(p.name)", problems.joined(separator: "; "))
            } else {
                report.check(false, "swift reads \(p.name)", "\(got), want a read")
            }
        default:
            let want = p.read.refusal ?? RefusalSpec(named: "?")
            report.check(refusal.map { matches($0, want) } ?? false, "swift reads \(p.name)", "\(got), want the refusal \(describe(want))")
        }

        // What SessionLineage.decode does with the lineage text of a file the file layer read.
        if let spec = p.lineage, let lineageText = contents.map({ $0.lineage ?? "" }) ?? p.lineage_text_file.flatMap({ try? String(contentsOf: ref.appendingPathComponent($0), encoding: .utf8) }) {
            var problems: [String] = []
            switch spec.outcome {
            case "decoded":
                do {
                    let lineage = try SessionLineage.decode(lineageText)
                    if lineage.isReadOnly { problems.append("read-only") }
                    if let n = spec.next_id, lineage.nextID != n { problems.append("next_id \(lineage.nextID) vs \(n)") }
                    if let count = spec.count, lineage.nodes.count != count { problems.append("\(lineage.nodes.count) nodes vs \(count)") }
                    if let nodes = spec.nodes, !nodes.isEmpty {
                        if lineage.nodes.count != nodes.count {
                            problems.append("\(lineage.nodes.count) nodes vs \(nodes.count)")
                        } else {
                            for (got, want) in zip(lineage.nodes, nodes) { problems += nodeProblems(got, want) }
                        }
                    }
                    if let canonical = spec.canonical {
                        let again = try lineage.jsonString()
                        if !utf8Equal(again, canonical) { problems.append("re-encoded text differs from Python's canonical text") }
                        if try SessionLineage.decode(again) != lineage { problems.append("a re-read of the re-encoded text differs") }
                    }
                    if spec.exhausted == true {
                        var copy = lineage
                        do {
                            try copy.add(kind: "distance", parameters: [:])
                            problems.append("a lineage at the id bound minted another id")
                        } catch where matches(error, RefusalSpec(named: "idsExhausted")) {
                        } catch {
                            problems.append("add at the id bound threw \(error)")
                        }
                    }
                } catch {
                    problems.append("refused: \(error)")
                }
            case "readOnly":
                do {
                    let lineage = try SessionLineage.decode(lineageText)
                    if !lineage.isReadOnly { problems.append("not read-only") }
                    if lineage.fileVersion != spec.version { problems.append("fileVersion \(lineage.fileVersion) vs \(spec.version ?? -1)") }
                    if !lineage.nodes.isEmpty { problems.append("an unknown version carries \(lineage.nodes.count) nodes") }
                    do {
                        _ = try lineage.jsonString()
                        problems.append("a read-only lineage was written")
                    } catch {
                        if error != .unsupportedVersion(spec.version ?? -1) { problems.append("jsonString threw \(error)") }
                    }
                    var copy = lineage
                    do {
                        try copy.add(kind: "distance", parameters: [:])
                        problems.append("a read-only lineage was extended")
                    } catch {
                        if error != .unsupportedVersion(spec.version ?? -1) { problems.append("add threw \(error)") }
                    }
                } catch {
                    problems.append("refused (an unknown version is read, not refused): \(error)")
                }
            default:
                let want = spec.refusal ?? RefusalSpec(named: "?")
                do {
                    let lineage = try SessionLineage.decode(lineageText)
                    problems.append("accepted (\(lineage.nodes.count) nodes), want the refusal \(describe(want))")
                } catch {
                    if !matches(error, want) { problems.append("refused as \(error); want \(describe(want))") }
                }
            }
            report.check(problems.isEmpty, "swift decodes \(p.name)", problems.joined(separator: "; "))
        }

        // The identity text.
        if let spec = p.source, let sourceText = contents.map({ $0.source ?? "" }) ?? p.source_text_file.flatMap({ try? String(contentsOf: ref.appendingPathComponent($0), encoding: .utf8) }) {
            var problems: [String] = []
            if spec.outcome == "decoded" {
                do {
                    let identity = try SessionSourceIdentity.decode(sourceText)
                    if !utf8Equal(identity.fileName, spec.file_name ?? "") { problems.append("file name \(identity.fileName) vs \(spec.file_name ?? "")") }
                    if identity.byteSize != spec.byte_size { problems.append("byte size \(identity.byteSize)") }
                    if identity.object != spec.object { problems.append("object \(identity.object)") }
                    if identity.width != spec.width || identity.height != spec.height { problems.append("shape \(identity.width) x \(identity.height)") }
                    if identity.pixelSHA256 != spec.pixel_sha256 { problems.append("fingerprint \(identity.pixelSHA256)") }
                    if let canonical = spec.canonical, !utf8Equal(try identity.jsonString(), canonical) {
                        problems.append("re-encoded text differs from Python's canonical text")
                    }
                } catch {
                    problems.append("refused: \(error)")
                }
            } else {
                let want = spec.refusal ?? RefusalSpec(named: "?")
                do {
                    _ = try SessionSourceIdentity.decode(sourceText)
                    problems.append("accepted, want the refusal \(describe(want))")
                } catch {
                    if !matches(error, want) { problems.append("refused as \(error); want \(describe(want))") }
                }
            }
            report.check(problems.isEmpty, "swift identity \(p.name)", problems.joined(separator: "; "))
        }

        // A file the reader refuses, or one this build could not rewrite whole (a newer schema), is never replaced: the write is
        // refused and the bytes are as they were. A link to nothing is such a file: it cannot be opened, so it is not ours to
        // replace; the link stays, and nothing is created where it points.
        if let want = p.write_over, !p.absent {
            let target = scratch.appendingPathComponent(p.name + SessionSidecarFile.suffix)
            try? FileManager.default.removeItem(at: target)
            var linkDestination: String?
            if p.dangling {
                linkDestination = try FileManager.default.destinationOfSymbolicLink(atPath: url.path)
                try FileManager.default.createSymbolicLink(atPath: target.path, withDestinationPath: linkDestination ?? "")
            } else {
                try FileManager.default.copyItem(at: url, to: target)
            }
            let before = p.dangling ? Data() : try Data(contentsOf: target)
            let listing = try FileManager.default.contentsOfDirectory(atPath: scratch.path).sorted()
            var problem = ""
            do {
                try SessionSidecarFile.write(source: "{}", lineage: "{}", to: target)
                problem = "the write replaced it"
            } catch let r as SessionSidecarFile.Refusal {
                if !matches(r, want) { problem = "refused as \(r); want \(describe(want))" }
            } catch {
                problem = "threw \(error)"
            }
            if p.dangling {
                if (try? FileManager.default.destinationOfSymbolicLink(atPath: target.path)) != linkDestination {
                    problem += (problem.isEmpty ? "" : "; ") + "the link is no longer a link to \(linkDestination ?? "?")"
                }
            } else {
                let after = try Data(contentsOf: target)
                if after != before { problem += (problem.isEmpty ? "" : "; ") + "the file changed (\(before.count) bytes before, \(after.count) after)" }
            }
            if try FileManager.default.contentsOfDirectory(atPath: scratch.path).sorted() != listing {
                problem += (problem.isEmpty ? "" : "; ") + "the directory changed"
            }
            report.check(problem.isEmpty, "swift refuses to overwrite \(p.name)", problem)
        }
        checkReplaces(p, url: url, scratch: scratch, childScratch: childScratch, deadline: deadline, &report)
    }
}

/// Planted sidecars that could hang a reader that parsed them (a variable-length attribute; the archived hang file) are read,
/// and written over, in a child process with a deadline: a reader that did parse the damaged heap fails its check here by
/// timing out, and the gate goes on.
func checkPlantedInChild(_ p: PlantedSpec, url: URL, scratch: URL, childScratch: URL, deadline: Double, _ report: inout Report) {
    let reader = harnessReader()
    let result = runChild(executable: reader.executable, arguments: reader.arguments(url.path), deadline: deadline,
                          scratch: childScratch, slot: "plant")
    let wanted = p.read.outcome == "contents" ? "a read" : "the refusal " + describe(p.read.refusal ?? RefusalSpec(named: "?"))
    var problem = ""
    if case .line(let line) = result {
        if p.read.outcome == "contents" {
            if line != expectedContentsLine(p.read) { problem = "\(line); want \(expectedContentsLine(p.read))" }
        } else if !(ChildLine(line)?.matches(p.read.refusal ?? RefusalSpec(named: "?")) ?? false) {
            problem = "\(line); want \(wanted)"
        }
    } else {
        problem = "\(describe(result, deadline: deadline)); want \(wanted)"
    }
    report.check(problem.isEmpty, "swift reads \(p.name)", problem)

    // The replace check reads the identity and the minimum reader: a variable-length one is refused there too, unread.
    guard let want = p.write_over, !p.absent else { return }
    let target = scratch.appendingPathComponent(p.name + SessionSidecarFile.suffix)
    try? FileManager.default.removeItem(at: target)
    do {
        try FileManager.default.copyItem(at: url, to: target)
    } catch {
        report.check(false, "swift refuses to overwrite \(p.name)", "the harness could not copy the plant: \(error)")
        return
    }
    let before = (try? Data(contentsOf: target)) ?? Data()
    let listing = ((try? FileManager.default.contentsOfDirectory(atPath: scratch.path)) ?? []).sorted()
    let attempt = runChild(executable: reader.executable, arguments: ["--write-over", target.path], deadline: deadline,
                           scratch: childScratch, slot: "plant")
    problem = ""
    if case .line(let line) = attempt {
        if !(ChildLine(line)?.matches(want) ?? false) { problem = "\(line); want the refusal \(describe(want))" }
    } else {
        problem = "\(describe(attempt, deadline: deadline)); want the refusal \(describe(want))"
    }
    let after = (try? Data(contentsOf: target)) ?? Data()
    if after != before { problem += (problem.isEmpty ? "" : "; ") + "the file changed (\(before.count) bytes before, \(after.count) after)" }
    if ((try? FileManager.default.contentsOfDirectory(atPath: scratch.path)) ?? []).sorted() != listing {
        problem += (problem.isEmpty ? "" : "; ") + "the directory changed"
    }
    report.check(problem.isEmpty, "swift refuses to overwrite \(p.name)", problem)
}

/// A sidecar whose identity and minimum reader are readable is replaced by a write, which never reads the rest (a
/// variable-length source or lineage, whatever its heap holds): the file then reads as the `{}` and `{}` written.
func checkReplaces(_ p: PlantedSpec, url: URL, scratch: URL, childScratch: URL, deadline: Double, _ report: inout Report) {
    guard p.replaces, !p.absent else { return }
    let reader = harnessReader()
    let target = scratch.appendingPathComponent("replaces-" + p.name + SessionSidecarFile.suffix)
    try? FileManager.default.removeItem(at: target)
    do {
        try FileManager.default.copyItem(at: url, to: target)
    } catch {
        report.check(false, "swift replaces \(p.name)", "the harness could not copy the plant: \(error)")
        return
    }
    var problem = ""
    let wrote = runChild(executable: reader.executable, arguments: ["--write-over", target.path], deadline: deadline,
                         scratch: childScratch, slot: "plant")
    if wrote != .line("wrote") {
        problem = "the write over it: \(describe(wrote, deadline: deadline)); want it to replace the file"
    } else {
        let want = "contents schema=1 min=1 source=\(digestToken("{}")) lineage=\(digestToken("{}"))"
        let read = runChild(executable: reader.executable, arguments: reader.arguments(target.path), deadline: deadline,
                            scratch: childScratch, slot: "plant")
        if read != .line(want) { problem = "after the replace it reads as \(describe(read, deadline: deadline)); want \(want)" }
    }
    report.check(problem.isEmpty, "swift replaces \(p.name)", problem)
}

/// The name rule.
func checkURLs(_ manifest: Manifest, ref: URL, _ report: inout Report) {
    let names = ref.appendingPathComponent("names", isDirectory: true)
    for c in manifest.urls {
        let source: URL
        if let u = c.url, let url = URL(string: u) {
            source = url
        } else if let a = c.absolute {
            source = URL(fileURLWithPath: a)
        } else {
            source = names.appendingPathComponent(c.path ?? "")
        }
        let name = "url \(c.label)"
        do {
            let sidecar = try SessionSidecarFile.sidecarURL(forSource: source)
            if c.outcome == "name" {
                let want = c.name ?? ""
                var problems: [String] = []
                if !utf8Equal(nfc(sidecar.lastPathComponent), nfc(want)) { problems.append("named \(sidecar.lastPathComponent), want \(want)") }
                if sidecar.deletingLastPathComponent().standardizedFileURL.path != source.deletingLastPathComponent().standardizedFileURL.path {
                    problems.append("placed in \(sidecar.deletingLastPathComponent().path), not beside the source")
                }
                report.check(problems.isEmpty, name, problems.joined(separator: "; "))
            } else {
                report.check(false, name, "gave \(sidecar.lastPathComponent), want the refusal \(c.refusal.map(describe) ?? "?")")
            }
        } catch let r as SessionSidecarFile.Refusal {
            if let want = c.refusal {
                report.check(matches(r, want), name, "refused as \(r); want \(describe(want))")
            } else {
                report.check(false, name, "refused as \(r); want the name \(c.name ?? "?")")
            }
        } catch {
            report.check(false, name, "threw \(error)")
        }
    }
}

/// The fingerprint against hashlib, and the verdict on planted identities.
func checkIdentity(_ manifest: Manifest, ref: URL, _ report: inout Report) throws {
    let pixels = try loadPixels(ref, manifest)
    for set in manifest.pixels {
        guard let p = pixels[set.name] else { continue }
        let direct = SessionSourceIdentity.fingerprint(of: p.pixels)
        let identity = SessionSourceIdentity.of(image(p, fileName: "f.dm4", source: "o"), fileByteSize: 1)
        report.check(direct == set.sha256 && identity.pixelSHA256 == set.sha256, "fingerprint \(set.name)",
                     "fingerprint(of:) \(direct), the identity's \(identity.pixelSHA256); hashlib.sha256 over numpy's float32 little-endian bytes \(set.sha256)")
        report.check(identity.width == set.width && identity.height == set.height, "identity shape \(set.name)",
                     "\(identity.width) x \(identity.height) vs \(set.width) x \(set.height)")
    }
    func identity(_ spec: IdentitySpec) -> SessionSourceIdentity? {
        pixels[spec.pixels].map { SessionSourceIdentity.of(image($0, fileName: spec.file_name, source: spec.object), fileByteSize: spec.byte_size) }
    }
    for v in manifest.verdicts {
        guard let stored = identity(v.stored), let opened = identity(v.opened) else {
            report.check(false, "verdict \(v.name)", "the plan names a pixel set that is not planted")
            continue
        }
        let verdict = SessionRestoreVerdict.decide(stored: stored, opened: opened)
        var problem = ""
        switch (v.expect.kind, verdict) {
        case ("adopt", .adopt), ("adoptPixelsDiffer", .adoptPixelsDiffer): break
        case ("adoptRenamed", .adoptRenamed(let from)):
            if !utf8Equal(from, nfc(v.expect.from ?? "")) { problem = "adopted as renamed from \(from), want \(v.expect.from ?? "?")" }
        case ("refuse", .refuse(let sentence)):
            for name in (v.names ?? []) + (v.shapes ?? []) where !sentence.contains(name) {
                problem = "the refusal \"\(sentence)\" does not name \(name)"
            }
        default:
            problem = "\(verdict), want \(v.expect.kind)"
        }
        report.check(problem.isEmpty, "verdict \(v.name)", problem)
    }
}

/// The library the sidecar code loaded is the copy run.sh named in FORMATO_HDF5_PATH (FormatoKit's libhdf5, re-signed): the kit's
/// loader falls back to the host's Frameworks, its bundled framework and a bare `libhdf5.dylib` when the named copy does not
/// load, so without this a failed load would pass on whatever HDF5 the machine has. A sidecar is written and read first, so the
/// kit has loaded the library the question is about; the images dyld holds are then the answer, and there must be exactly one.
func checkLibrary(_ report: inout Report) {
    let named = ProcessInfo.processInfo.environment["FORMATO_HDF5_PATH"] ?? ""
    func real(_ path: String) -> String { URL(fileURLWithPath: path).resolvingSymlinksInPath().path }
    var loaded: [String] = []
    do {
        let probe = FileManager.default.temporaryDirectory.appendingPathComponent("sidecar-parity-library-\(UUID().uuidString).h5")
        defer { try? FileManager.default.removeItem(at: probe) }
        try SessionSidecarFile.write(source: "{}", lineage: "[]", to: probe)
        _ = try SessionSidecarFile.read(url: probe)
        loaded = (0..<_dyld_image_count()).compactMap { index in _dyld_get_image_name(index).map { String(cString: $0) } }
            .filter { URL(fileURLWithPath: $0).lastPathComponent.lowercased().contains("libhdf5") }
    } catch {
        report.check(false, "libhdf5 is the named copy", "the library did not load: \(error)")
        return
    }
    report.check(!named.isEmpty && loaded.count == 1 && real(loaded[0]) == real(named), "libhdf5 is the named copy",
                 "loaded \(loaded.isEmpty ? "(none)" : loaded.joined(separator: ", ")); FORMATO_HDF5_PATH names \(named.isEmpty ? "(unset)" : named)")
}

@main
struct SidecarParity {
    static func main() throws {
        let args = CommandLine.arguments
        if args.count == 4, args[1] == "--write" {
            let ref = URL(fileURLWithPath: args[2]), out = URL(fileURLWithPath: args[3])
            let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: ref.appendingPathComponent("manifest.json")))
            try writeSessions(manifest: manifest, ref: ref, out: out)
            try writeMarkSessions(manifest.marks, ref: ref, out: out)
            return
        }
        // The child processes (fuzz.swift): one read, one replace check, the fuzz driver against a stub.
        if args.count == 3, args[1] == "--read" { childRead(path: args[2]) }
        if args.count == 3, args[1] == "--write-over" { childWriteOver(path: args[2]) }
        if args.count == 4, args[1] == "--fuzz-selftest" { fuzzSelfTest(mode: args[2], directory: args[3]) }
        let fuzzRequested = args.count == 4 && args[3] == "--fuzz"
        let denseQuickRequested = args.count == 4 && args[3] == "--fuzz-dense"
        guard args.count == 3 || fuzzRequested || denseQuickRequested else {
            print("usage: harness --write <reference dir> <out dir>   |   harness <reference dir> <out dir> [--fuzz | --fuzz-dense]")
            exit(64)
        }
        let ref = URL(fileURLWithPath: args[1]), out = URL(fileURLWithPath: args[2])
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: ref.appendingPathComponent("manifest.json")))
        var report = Report()

        // (a) what Swift wrote
        let written: Written?
        do {
            written = try JSONDecoder().decode(Written.self, from: Data(contentsOf: out.appendingPathComponent("swift-written.json")))
        } catch {
            written = nil
            report.check(false, "swift writes the planted sessions", "no record of the write step: \(error)")
        }
        for session in manifest.sessions {
            guard let record = written?.sessions.first(where: { $0.id == session.id }) else { continue }
            report.check(record.rules.isEmpty, "swift rules \(session.id)", record.rules.joined(separator: "; "))
            report.check(record.error == nil, "swift writes \(session.id)", record.error ?? "")
            guard record.error == nil else { continue }
            report.check(record.roundtrip == nil, "swift reads its own \(session.id)", record.roundtrip ?? "")
            report.check(record.file.map { utf8Equal(nfc($0), nfc(session.sidecar_name)) } ?? false, "swift names \(session.id)",
                         "\(record.file ?? "nil") vs the source name plus \(SessionSidecarFile.suffix): \(session.sidecar_name)")
        }
        for raw in written?.raw ?? [] { report.check(raw.problem == nil, "swift writer \(raw.id)", raw.problem ?? "") }
        var h5pyChecks = 0
        do {
            let readback = try JSONDecoder().decode(Readback.self, from: Data(contentsOf: out.appendingPathComponent("readback.json")))
            for item in readback.checks { report.check(item.ok, item.name, item.detail) }
            h5pyChecks = readback.checks.count
        } catch {
            report.check(false, "h5py reads what Swift wrote", "no readback.json: \(error)")
        }

        // (b) (c) (d)
        checkLibrary(&report)
        try checkPlanted(manifest, ref: ref, out: out, &report)
        checkMarks(manifest.marks, ref: ref, out: out, &report)
        checkURLs(manifest, ref: ref, &report)
        try checkIdentity(manifest, ref: ref, &report)
        if fuzzRequested {
            checkFuzz(manifest, written: written, ref: ref, out: out, &report)
            checkDenseFuzz(manifest, ref: ref, out: out, quick: false, &report)
        }
        if denseQuickRequested { checkDenseFuzz(manifest, ref: ref, out: out, quick: true, &report) }

        let cases = manifest.sessions.count + manifest.planted.count + manifest.raw_writes.count + manifest.urls.count
            + manifest.verdicts.count + manifest.marks.sessions.count + manifest.marks.planted.count
        if report.failures > 0 {
            print("sidecar-parity: \(report.failures) FAILURES in \(report.checks) checks (h5py \(manifest.h5py))")
            exit(1)
        }
        print("sidecar-parity: \(cases) cases = \(manifest.sessions.count) sessions written by Swift and read by h5py, "
              + "\(manifest.planted.count) sidecars written by h5py, \(manifest.raw_writes.count) writes of strings offered directly, "
              + "\(manifest.urls.count) names, \(manifest.verdicts.count) verdicts, \(manifest.marks.sessions.count) mark sessions and \(manifest.marks.planted.count) mark sidecars; "
              + "\(h5pyChecks) of the checks are h5py's reading of Swift's files")
        print("sidecar-parity: all passed — \(cases) cases, \(report.checks) checks against h5py \(manifest.h5py)")
    }
}
