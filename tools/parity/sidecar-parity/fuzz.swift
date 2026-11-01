// tools/parity/sidecar-parity/fuzz.swift — the harness's child processes and the fuzz of the fixed-length strings.
//
// WHY A CHILD PROCESS. One damaged byte in a variable-length string's global heap makes `H5Aread` spin forever while
// SpectroKit's process-wide `HDF5Serial` lock is held. The reader now refuses a
// variable-length string by name before any read, so it cannot happen; but this harness exists to PROVE that, so every Swift
// read of a file that could be damaged (the variable-length plants, the archived hang file, every mutation of the fuzz) runs
// in its own process with a deadline. A hang is then a failure that names the file, never a stuck gate; a crash by signal is a
// failure that names the signal.
//
//     harness --read <file>          prints one line: `contents schema=1 min=1 source=<bytes>:<sha256|-> lineage=<…>` or
//                                    `refused <case> [key=value]…` (a SessionSidecarFile.Refusal, by name) or `error <text>`
//     harness --write-over <file>    SessionSidecarFile.write("{}", "{}") over <file>: `wrote`, or `refused <case> …`
//     harness --fuzz-selftest <mode> <dir>
//                                    the fuzz driver against a stub reader that misbehaves as asked (hang, crash, silent,
//                                    unnamed) or not (ok): run.sh requires each misbehaviour to fail the driver's named check
//
// THE FUZZ (P3). The files and the schedule are the plan's (reference.py `FUZZ`):
// three sidecars Swift wrote, mutated at the bytes the plan names (xor 0xFF, bit 0, set to 0; a stride; 16 truncations), each
// mutated file read by `harness --read` with a 10 s deadline, at most 6 processes at once. Every read is classified:
//   unchanged   the written contents (a mutation in padding, free space, or a field nothing reads)
//   refused     a named refusal of SessionSidecarFile (counted by name)
//   silent      the read succeeded with other contents
//   hang        no answer by the deadline (the process is killed by its PID)
//   crash       the process died on a signal
//   unnamed     anything else (a nonzero exit, no output, an error that is not a Refusal)
// Pass: no hang, no crash, no unnamed outcome, and no silent change on the files the plan gates (those whose text lies within the
// roughly 65,499 bytes the checksummed object header holds). The other file's silent changes are counted and printed, not gated.

@testable import TEMCore
import CryptoKit
import Darwin
import Foundation
import FormatoHDF5

// MARK: - The child's output

/// One line a child printed, parsed: `<kind> [<name>] [key=value]…`.
struct ChildLine {
    let kind: String
    let name: String?
    let fields: [String: String]

    init?(_ line: String) {
        let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard let first = parts.first, ["contents", "refused", "wrote", "error"].contains(first) else { return nil }
        kind = first
        var rest = parts.dropFirst()
        if first == "refused" {
            guard let named = rest.first, !named.contains("=") else { return nil }
            name = named
            rest = rest.dropFirst()
        } else {
            name = nil
        }
        var fields: [String: String] = [:]
        for part in rest {
            guard let equals = part.firstIndex(of: "=") else { continue }
            fields[String(part[..<equals])] = String(part[part.index(after: equals)...])
        }
        self.fields = fields
    }

    /// Is this the refusal a plant names (the case, and the attribute or numbers where the plan states them)?
    func matches(_ spec: RefusalSpec) -> Bool {
        guard kind == "refused", name == spec.name else { return false }
        if let attribute = spec.attribute, fields["attribute"] != attribute { return false }
        if let found = spec.found, fields["found"] != String(found) { return false }
        if let supported = spec.supported, fields["supported"] != String(supported) { return false }
        if let bytes = spec.bytes, fields["bytes"] != String(bytes) { return false }
        return true
    }
}

func digestToken(_ text: String?) -> String {
    guard let text else { return "-" }
    let data = Data(text.utf8)
    return "\(data.count):\(sha256hex(data))"
}

func contentsLine(_ c: SessionSidecarFile.Contents) -> String {
    "contents schema=\(c.schema) min=\(c.minReader) source=\(digestToken(c.source)) lineage=\(digestToken(c.lineage))"
}

/// The line a read of a planted file must give, from the plan's lengths and digests.
func expectedContentsLine(_ r: ReadSpec) -> String {
    func token(_ bytes: Int?, _ sha: String?) -> String { bytes.flatMap { b in sha.map { "\(b):\($0)" } } ?? "-" }
    return "contents schema=\(r.schema ?? -1) min=\(r.min_reader ?? -1) source=\(token(r.source_bytes, r.source_sha256)) "
        + "lineage=\(token(r.lineage_bytes, r.lineage_sha256))"
}

func refusalLine(_ r: SessionSidecarFile.Refusal) -> String {
    switch r {
    case .noSourceName: return "refused noSourceName"
    case .sourceIsASidecar: return "refused sourceIsASidecar"
    case .nameTooLong(let units): return "refused nameTooLong units=\(units)"
    case .library: return "refused library"
    case .cannotOpen: return "refused cannotOpen"
    case .notPermitted: return "refused notPermitted"
    case .hdf5: return "refused hdf5"
    case .foreign: return "refused foreign"
    case .missingAttribute(let a): return "refused missingAttribute attribute=\(a)"
    case .malformedAttribute(let a): return "refused malformedAttribute attribute=\(a)"
    case .variableLengthString(let a): return "refused variableLengthString attribute=\(a)"
    case .newerMinReader(let found, let supported): return "refused newerMinReader found=\(found) supported=\(supported)"
    case .newerSchema(let found, let supported): return "refused newerSchema found=\(found) supported=\(supported)"
    case .stringTooLong(let a, let bytes): return "refused stringTooLong attribute=\(a) bytes=\(bytes)"
    case .invalidUTF8(let a): return "refused invalidUTF8 attribute=\(a)"
    case .embeddedNUL(let a): return "refused embeddedNUL attribute=\(a)"
    case .cannotWrite: return "refused cannotWrite"
    case .sidecarTooLarge(let bytes): return "refused sidecarTooLarge bytes=\(bytes)"
    case .denseAttributeStorage: return "refused denseAttributeStorage"
    }
}

/// `harness --read <file>`: the child's whole job.
func childRead(path: String) -> Never {
    do {
        print(contentsLine(try SessionSidecarFile.read(url: URL(fileURLWithPath: path))))
        exit(0)
    } catch let refusal as SessionSidecarFile.Refusal {
        print(refusalLine(refusal))
        exit(0)
    } catch {
        print("error \(error)")
        exit(3)
    }
}

/// `harness --write-over <file>`: the writer's replace check on a file that may be damaged.
func childWriteOver(path: String) -> Never {
    do {
        try SessionSidecarFile.write(source: "{}", lineage: "{}", to: URL(fileURLWithPath: path))
        print("wrote")
        exit(0)
    } catch let refusal as SessionSidecarFile.Refusal {
        print(refusalLine(refusal))
        exit(0)
    } catch {
        print("error \(error)")
        exit(3)
    }
}

// MARK: - Running a child with a deadline

enum ChildResult: Equatable, Sendable {
    /// The child exited 0 after printing one line.
    case line(String)
    /// No exit by the deadline: the process was killed by its PID.
    case timedOut
    /// The process died on this signal.
    case signaled(Int32)
    /// A nonzero exit, or output that is not one line.
    case failed(status: Int32, detail: String)
}

/// How a mutated file is read: the executable and the arguments for one file's path.
struct ChildReader: Sendable {
    let executable: URL
    let arguments: @Sendable (_ path: String) -> [String]
}

/// This harness itself, which reads one file when asked (`--read`).
func harnessReader() -> ChildReader {
    let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    return ChildReader(executable: executable, arguments: { ["--read", $0] })
}

/// Runs `executable` and waits `deadline` seconds. Its output goes to files in `scratch` (never a pipe: a pipe's write end
/// can be inherited by another child started at the same moment, and then never reaches end of file). A child still running
/// at the deadline is killed by its exact PID.
func runChild(executable: URL, arguments: [String], deadline: Double, scratch: URL, slot: String) -> ChildResult {
    let outURL = scratch.appendingPathComponent("child-\(slot).out"), errURL = scratch.appendingPathComponent("child-\(slot).err")
    FileManager.default.createFile(atPath: outURL.path, contents: nil)
    FileManager.default.createFile(atPath: errURL.path, contents: nil)
    guard let out = try? FileHandle(forWritingTo: outURL), let err = try? FileHandle(forWritingTo: errURL) else {
        return .failed(status: -1, detail: "the harness could not open its child's output files in \(scratch.path)")
    }
    defer { try? out.close(); try? err.close() }
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = out
    process.standardError = err
    let finished = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in finished.signal() }
    do {
        try process.run()
    } catch {
        return .failed(status: -1, detail: "could not start \(executable.path): \(error)")
    }
    let pid = process.processIdentifier
    if finished.wait(timeout: .now() + deadline) == .timedOut {
        kill(pid, SIGKILL)
        finished.wait()
        return .timedOut
    }
    let output = String(decoding: (try? Data(contentsOf: outURL)) ?? Data(), as: UTF8.self)
    let errors = String(decoding: (try? Data(contentsOf: errURL)) ?? Data(), as: UTF8.self)
    if process.terminationReason == .uncaughtSignal { return .signaled(process.terminationStatus) }
    let lines = output.split(separator: "\n", omittingEmptySubsequences: true)
    guard process.terminationStatus == 0, lines.count == 1 else {
        let said = (errors.isEmpty ? output : errors).trimmingCharacters(in: .whitespacesAndNewlines)
        return .failed(status: process.terminationStatus, detail: String(said.prefix(200)))
    }
    return .line(String(lines[0]))
}

func describe(_ result: ChildResult, deadline: Double) -> String {
    switch result {
    case .line(let line): return line
    case .timedOut: return "no answer in \(Int(deadline)) s (the process was killed)"
    case .signaled(let signal): return "the process died on signal \(signal)"
    case .failed(let status, let detail): return "exit \(status): \(detail)"
    }
}

// MARK: - A pool of at most N workers

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value - 1 }
}

final class Slots<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [T?]
    init(_ count: Int) { items = Array(repeating: nil, count: count) }
    func set(_ index: Int, _ value: T) { lock.lock(); items[index] = value; lock.unlock() }
    func all() -> [T?] { lock.lock(); defer { lock.unlock() }; return items }
}

/// Runs `body(index, worker)` for every index below `count` on `workers` threads at once.
func parallelFor(_ count: Int, workers: Int, _ body: @Sendable (_ index: Int, _ worker: Int) -> Void) {
    let counter = Counter()
    DispatchQueue.concurrentPerform(iterations: max(1, workers)) { worker in
        while true {
            let index = counter.next()
            if index >= count { return }
            body(index, worker)
        }
    }
}

// MARK: - The plan (reference.py `FUZZ`)

struct FuzzFilePlan: Decodable {
    let session: String
    let modes: [String]
    let stride: Int
    let gated: Bool
    /// A file h5py wrote (dense storage, which the writer refuses since the text cap), with the strings it holds.
    let planted: Bool?
    /// The file is in dense attribute storage: the reader refuses it by name, so the unmutated read is that refusal
    /// and a mutated read that succeeds is a silent change.
    let dense: Bool?
    let file: String?
    let source_json: String?
    let lineage_json: String?
}

/// One edit of a dense file: `bytes` replace the file's bytes from `offset` (a block's checksum recomputed is a second patch).
struct Patch: Decodable {
    let offset: Int
    let bytes: [UInt8]

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        offset = try container.decode(Int.self)
        let hex = try container.decode(String.self)
        var out: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "hex") }
            out.append(byte)
            index = next
        }
        bytes = out
    }
}

struct PatchedMutation: Decodable {
    let label: String
    let patches: [Patch]
    /// One of the second opinion's 648 (an 8-byte window of the fractal heap header at five values): the quick fuzz of a control.
    let second_opinion: Bool?
}

/// A dense-storage sidecar h5py wrote and the structure-aware mutations of its FRHP, BTHD and BTLF blocks, checksums recomputed
/// (dense_fuzz.py; P3).
struct StructureBase: Decodable {
    let label: String
    let file: String
    let patches: String
    let count: Int
    let regions: [String]
    let second_opinion: Int
}

/// A compact sidecar whose attribute-info message was pointed at a heap: its outcome is recorded, not gated.
struct ForgedFile: Decodable {
    let label: String
    let file: String
}

struct FuzzPlan: Decodable {
    let deadline: Double
    let workers: Int
    let truncations: Int
    let text_limit: Int
    let files: [FuzzFilePlan]
    let structure: [StructureBase]
    let forged: [ForgedFile]
}

// MARK: - The mutations

struct Mutation: Sendable {
    /// `xor` (every bit), `bit0`, `zero`, or `trunc` (the file cut to `offset` bytes).
    let mode: String
    let offset: Int

    /// The mutated bytes, or nil when the mutation would leave the file as it is (a byte already 0 set to 0).
    func apply(to base: [UInt8]) -> [UInt8]? {
        var bytes = base
        switch mode {
        case "xor": bytes[offset] ^= 0xFF
        case "bit0": bytes[offset] ^= 0x01
        case "zero":
            if bytes[offset] == 0 { return nil }
            bytes[offset] = 0
        case "trunc": bytes.removeSubrange(offset...)
        default: return nil
        }
        return bytes
    }

    var label: String { mode == "trunc" ? "truncated to \(offset) bytes" : "\(mode) at byte \(offset)" }
}

/// Every byte (every `stride`-th, from byte 0) of the file under each mode, then `truncations` cuts at size * k / truncations.
func schedule(size: Int, modes: [String], stride step: Int, truncations: Int) -> [Mutation] {
    var out: [Mutation] = []
    for mode in modes {
        for offset in Swift.stride(from: 0, to: size, by: step) { out.append(Mutation(mode: mode, offset: offset)) }
    }
    for k in 0..<truncations { out.append(Mutation(mode: "trunc", offset: size * k / max(truncations, 1))) }
    return out
}

// MARK: - The outcomes

enum FuzzOutcome: Sendable {
    case skipped
    case unchanged
    case refused(String)
    case silent(String)
    case hang
    case crash(Int32)
    case unnamed(String)
}

func classify(_ result: ChildResult, expected: String) -> FuzzOutcome {
    switch result {
    case .timedOut: return .hang
    case .signaled(let signal): return .crash(signal)
    case .failed(let status, let detail): return .unnamed("exit \(status): \(detail)")
    case .line(let line):
        guard let parsed = ChildLine(line) else { return .unnamed("unreadable output: \(line.prefix(120))") }
        switch parsed.kind {
        case "contents": return line == expected ? .unchanged : .silent(String(line.prefix(200)))
        case "refused": return .refused(parsed.name ?? "?")
        default: return .unnamed(String(line.prefix(120)))
        }
    }
}

struct FuzzTally {
    var reads = 0
    var skipped = 0
    var unchanged = 0
    var refusals: [String: Int] = [:]
    var silent: [String] = []
    var hangs: [String] = []
    var crashes: [String] = []
    var unnamed: [String] = []
    var seconds = 0.0
}

/// One file to fuzz: where it is, what it must read as, and the plan's schedule for it.
struct FuzzTarget: Sendable {
    let label: String
    let file: URL
    let modes: [String]
    let stride: Int
    let gated: Bool
    /// The line an unmutated read prints.
    let expected: String
}

func fuzz(_ target: FuzzTarget, truncations: Int, workers: Int, deadline: Double, reader: ChildReader, scratch: URL) throws -> FuzzTally {
    let base = [UInt8](try Data(contentsOf: target.file))
    let plan = schedule(size: base.count, modes: target.modes, stride: target.stride, truncations: truncations)
    let work = scratch.appendingPathComponent("fuzz-\(target.label)", isDirectory: true)
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    let outcomes = Slots<FuzzOutcome>(plan.count)
    let started = Date()
    parallelFor(plan.count, workers: workers) { index, worker in
        let mutation = plan[index]
        guard let bytes = mutation.apply(to: base) else { outcomes.set(index, .skipped); return }
        let path = work.appendingPathComponent("w\(worker).mactem.h5")
        do {
            try Data(bytes).write(to: path)
        } catch {
            outcomes.set(index, .unnamed("the harness could not write the mutated file: \(error)"))
            return
        }
        let result = runChild(executable: reader.executable, arguments: reader.arguments(path.path), deadline: deadline,
                              scratch: work, slot: "w\(worker)")
        outcomes.set(index, classify(result, expected: target.expected))
    }
    var tally = FuzzTally()
    tally.seconds = Date().timeIntervalSince(started)
    for (index, slot) in outcomes.all().enumerated() {
        let where_ = "\(target.file.lastPathComponent): \(plan[index].label)"
        switch slot ?? .unnamed("no outcome recorded") {
        case .skipped: tally.skipped += 1; continue
        case .unchanged: tally.unchanged += 1
        case .refused(let name): tally.refusals[name, default: 0] += 1
        case .silent(let line): tally.silent.append("\(where_) read as \(line)")
        case .hang: tally.hangs.append("\(where_) did not answer in \(Int(deadline)) s")
        case .crash(let signal): tally.crashes.append("\(where_) died on signal \(signal)")
        case .unnamed(let what): tally.unnamed.append("\(where_): \(what)")
        }
        tally.reads += 1
    }
    return tally
}

func listed(_ items: [String]) -> String {
    items.prefix(3).joined(separator: "; ") + (items.count > 3 ? " … (\(items.count) in all)" : "")
}

func refusalSummary(_ refusals: [String: Int]) -> String {
    refusals.isEmpty ? "none" : refusals.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
}

/// Fuzzes the targets and reports: the gated checks, and one summary line per file.
func fuzzAll(_ targets: [FuzzTarget], truncations: Int, workers: Int, deadline: Double, reader: ChildReader, scratch: URL,
             _ report: inout Report) {
    var total = 0, hangs = 0, crashes = 0, unnamed = 0, silentGated = 0
    for target in targets {
        let tally: FuzzTally
        do {
            tally = try fuzz(target, truncations: truncations, workers: workers, deadline: deadline, reader: reader, scratch: scratch)
        } catch {
            report.check(false, "fuzz \(target.label) runs", "the harness could not fuzz \(target.file.path): \(error)")
            continue
        }
        report.check(tally.hangs.isEmpty, "fuzz \(target.label) hangs", listed(tally.hangs))
        report.check(tally.crashes.isEmpty, "fuzz \(target.label) crashes", listed(tally.crashes))
        report.check(tally.unnamed.isEmpty, "fuzz \(target.label) unnamed outcomes", listed(tally.unnamed))
        if target.gated { report.check(tally.silent.isEmpty, "fuzz \(target.label) silent changes", listed(tally.silent)) }
        total += tally.reads
        hangs += tally.hangs.count
        crashes += tally.crashes.count
        unnamed += tally.unnamed.count
        if target.gated { silentGated += tally.silent.count }
        let size = (try? FileManager.default.attributesOfItem(atPath: target.file.path)[.size] as? Int) ?? 0
        print("sidecar-parity: fuzz \(target.label) (\(target.file.lastPathComponent), \(size) bytes; "
              + "\(target.modes.joined(separator: ", ")) every \(target.stride)\(target.stride == 1 ? " byte" : " bytes"), "
              + "\(truncations) truncations): \(tally.reads) reads in \(Int(tally.seconds)) s, \(tally.skipped) mutations skipped (no change); "
              + "\(tally.hangs.count) hangs, \(tally.crashes.count) crashes, \(tally.unnamed.count) unnamed; "
              + "unchanged \(tally.unchanged); refused by name: \(refusalSummary(tally.refusals)); "
              + "silent changes \(tally.silent.count) (\(target.gated ? "gated" : "counted, not gated"))")
    }
    print("sidecar-parity: fuzz total: \(targets.count) files, \(total) reads, \(hangs) hangs, \(crashes) crashes, "
          + "\(unnamed) unnamed outcomes, \(silentGated) silent changes on the gated files")
}

// MARK: - The fuzz clause of the gate

/// The three sidecars the plan names, from what the write step recorded, fuzzed and reported. The unmutated file must first
/// read as the strings Swift handed the writer (so "the written contents" is the writer's, not the reader's own opinion), and
/// the text sizes must be what the plan claims of the file (within the checksummed object header, about 65,499 bytes, for the gated ones).
func checkFuzz(_ manifest: Manifest, written: Written?, ref: URL, out: URL, _ report: inout Report) {
    let reader = harnessReader()
    let scratch = out.appendingPathComponent("fuzz", isDirectory: true)
    try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    var targets: [FuzzTarget] = []
    for entry in manifest.fuzz.files {
        let source: String, lineage: String, file: URL
        if entry.planted == true, let planted = entry.file, let s = entry.source_json, let l = entry.lineage_json {
            (source, lineage, file) = (s, l, ref.appendingPathComponent(planted))
        } else if let record = written?.sessions.first(where: { $0.id == entry.session }), let name = record.file,
                  let s = record.source_json, let l = record.lineage_json {
            (source, lineage, file) = (s, l, out.appendingPathComponent("swift", isDirectory: true).appendingPathComponent(name))
        } else {
            report.check(false, "fuzz \(entry.session) file", "the write step recorded no sidecar for the session \(entry.session)")
            continue
        }
        let dense = entry.dense == true
        let expected = dense ? "refused denseAttributeStorage"
            : "contents schema=1 min=1 source=\(digestToken(source)) lineage=\(digestToken(lineage))"
        let limit = manifest.fuzz.text_limit
        let within = source.utf8.count < limit && lineage.utf8.count < limit
        report.check(within == !dense, "fuzz \(entry.session) text size",
                     "source \(source.utf8.count) and lineage \(lineage.utf8.count) bytes; the plan says the text is "
                     + "\(dense ? "over" : "within") \(limit) bytes")
        let baseline = runChild(executable: reader.executable, arguments: reader.arguments(file.path),
                                deadline: manifest.fuzz.deadline, scratch: scratch, slot: "baseline-\(entry.session)")
        report.check(baseline == .line(expected), "fuzz \(entry.session) unmutated read",
                     "\(describe(baseline, deadline: manifest.fuzz.deadline)); want \(expected)")
        targets.append(FuzzTarget(label: entry.session, file: file, modes: entry.modes, stride: entry.stride, gated: entry.gated,
                                  expected: expected))
    }
    fuzzAll(targets, truncations: manifest.fuzz.truncations, workers: manifest.fuzz.workers, deadline: manifest.fuzz.deadline,
            reader: reader, scratch: scratch, &report)
}

// MARK: - The structure-aware fuzz of dense-storage sidecars (P3)

/// The mutated bytes of `base` with `patches` applied, or nil when a patch would fall outside the file.
func applying(_ patches: [Patch], to base: [UInt8]) -> [UInt8]? {
    var bytes = base
    for patch in patches {
        guard patch.offset >= 0, patch.offset + patch.bytes.count <= bytes.count else { return nil }
        bytes.replaceSubrange(patch.offset..<(patch.offset + patch.bytes.count), with: patch.bytes)
    }
    return bytes
}

/// Reads every mutation of one dense base (an h5py file; the mutations are dense_fuzz.py's: every byte, and every 2-, 4- and 8-byte
/// window, of its FRHP, BTHD and BTLF blocks, with the block's checksum recomputed so that the library's integrity test passes), each in a
/// child process with a deadline. The reader refuses a dense root from the object header alone; the registered outcome is a named refusal
/// for every read: 0 hangs, 0 crashes, 0 reads that give contents, 0 unnamed outcomes. `quick` keeps the second opinion's 648 windows.
func fuzzStructure(_ base: StructureBase, ref: URL, quick: Bool, workers: Int, deadline: Double, reader: ChildReader, scratch: URL,
                   _ report: inout Report) {
    let file = ref.appendingPathComponent(base.file)
    let label = base.label
    let all: [PatchedMutation]
    let bytes: [UInt8]
    do {
        all = try JSONDecoder().decode([PatchedMutation].self, from: Data(contentsOf: ref.appendingPathComponent(base.patches)))
        bytes = [UInt8](try Data(contentsOf: file))
    } catch {
        report.check(false, "fuzz \(label) runs", "the harness could not load \(base.file) and its mutations: \(error)")
        return
    }
    report.check(all.count == base.count, "fuzz \(label) mutations", "\(all.count) mutations loaded; the plan says \(base.count)")
    let baseline = runChild(executable: reader.executable, arguments: reader.arguments(file.path), deadline: deadline, scratch: scratch,
                            slot: "baseline-\(label)")
    report.check(baseline == .line("refused denseAttributeStorage"), "fuzz \(label) unmutated read",
                 "\(describe(baseline, deadline: deadline)); want refused denseAttributeStorage")
    let plan = quick ? all.filter { $0.second_opinion == true } : all
    if quick { report.check(plan.count == base.second_opinion, "fuzz \(label) second opinion's windows", "\(plan.count) of \(base.second_opinion)") }
    let work = scratch.appendingPathComponent("fuzz-\(label)", isDirectory: true)
    do { try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true) } catch {
        report.check(false, "fuzz \(label) runs", "\(error)")
        return
    }
    let outcomes = Slots<FuzzOutcome>(plan.count)
    let started = Date()
    parallelFor(plan.count, workers: workers) { index, worker in
        guard let mutated = applying(plan[index].patches, to: bytes) else { outcomes.set(index, .unnamed("a patch outside the file")); return }
        let path = work.appendingPathComponent("w\(worker).mactem.h5")
        do { try Data(mutated).write(to: path) } catch {
            outcomes.set(index, .unnamed("the harness could not write the mutated file: \(error)"))
            return
        }
        let result = runChild(executable: reader.executable, arguments: reader.arguments(path.path), deadline: deadline, scratch: work,
                              slot: "w\(worker)")
        outcomes.set(index, classify(result, expected: "refused denseAttributeStorage"))
    }
    var refusals: [String: Int] = [:]
    var hangs: [String] = [], crashes: [String] = [], unnamed: [String] = [], contents: [String] = []
    for (index, slot) in outcomes.all().enumerated() {
        let where_ = "\(label): \(plan[index].label)"
        switch slot ?? .unnamed("no outcome recorded") {
        case .skipped: continue
        case .unchanged, .silent: contents.append("\(where_) was read")
        case .refused(let name): refusals[name, default: 0] += 1
        case .hang: hangs.append("\(where_) did not answer in \(Int(deadline)) s")
        case .crash(let signal): crashes.append("\(where_) died on signal \(signal)")
        case .unnamed(let what): unnamed.append("\(where_): \(what)")
        }
    }
    report.check(hangs.isEmpty, "fuzz \(label) hangs", listed(hangs))
    report.check(crashes.isEmpty, "fuzz \(label) crashes", listed(crashes))
    report.check(unnamed.isEmpty, "fuzz \(label) unnamed outcomes", listed(unnamed))
    report.check(contents.isEmpty, "fuzz \(label) reads that succeed", listed(contents))
    print("sidecar-parity: fuzz \(label) (\(base.file), \(bytes.count) bytes; blocks \(base.regions.joined(separator: " ")); "
          + "\(quick ? "the second opinion's \(plan.count) windows" : "\(plan.count) mutations, checksums recomputed")): "
          + "\(Int(Date().timeIntervalSince(started))) s; \(hangs.count) hangs, \(crashes.count) crashes, \(unnamed.count) unnamed, "
          + "\(contents.count) read; refused by name: \(refusalSummary(refusals))")
}

/// The forged headers (measured, not gated): what the reader and the library do with a compact sidecar whose attribute-info message
/// points at a heap, the attribute messages kept. Printed, never failed on, except that the harness itself must run.
func measureForged(_ forged: [ForgedFile], ref: URL, deadline: Double, reader: ChildReader, scratch: URL) {
    for item in forged {
        let result = runChild(executable: reader.executable, arguments: reader.arguments(ref.appendingPathComponent(item.file).path),
                              deadline: deadline, scratch: scratch, slot: "forged")
        print("sidecar-parity: forged header (measured, not gated) \(item.label): \(describe(result, deadline: deadline))")
    }
}

/// The dense clauses of the gate: `quick` is a control's run (the second opinion's windows of the first base only).
func checkDenseFuzz(_ manifest: Manifest, ref: URL, out: URL, quick: Bool, _ report: inout Report) {
    let reader = harnessReader()
    let scratch = out.appendingPathComponent("fuzz-dense", isDirectory: true)
    try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    for base in (quick ? Array(manifest.fuzz.structure.prefix(1)) : manifest.fuzz.structure) {
        fuzzStructure(base, ref: ref, quick: quick, workers: manifest.fuzz.workers, deadline: manifest.fuzz.deadline, reader: reader,
                      scratch: scratch, &report)
    }
    if !quick { measureForged(manifest.fuzz.forged, ref: ref, deadline: manifest.fuzz.deadline, reader: reader, scratch: scratch) }
}

// MARK: - The fuzz driver against a stub reader that misbehaves (run.sh's controls of the fuzz itself)

/// `harness --fuzz-selftest <mode> <dir>`: the driver on a 16-byte file whose reader is a shell stub. The stub answers the
/// unmutated file with the baseline line and misbehaves on every mutation as `mode` says: `hang` (sleeps past the deadline),
/// `crash` (kills itself with SIGSEGV), `silent` (another contents), `unnamed` (exits 3), `ok` (a named refusal). Prints the
/// driver's report like the gate and exits 1 on any failure, so run.sh can require the right check to fail for each.
func fuzzSelfTest(mode: String, directory: String) -> Never {
    let scratch = URL(fileURLWithPath: directory, isDirectory: true)
    let baselineLine = "contents schema=1 min=1 source=2:aa lineage=2:bb"
    let misbehaviour: String
    switch mode {
    case "hang": misbehaviour = "exec sleep 30"
    case "crash": misbehaviour = "kill -SEGV $$"
    case "silent": misbehaviour = "echo 'contents schema=1 min=1 source=2:aa lineage=3:cc'"
    case "unnamed": misbehaviour = "echo broken >&2; exit 3"
    case "ok": misbehaviour = "echo 'refused hdf5'"
    default:
        print("usage: harness --fuzz-selftest hang|crash|silent|unnamed|ok <dir>")
        exit(64)
    }
    var report = Report()
    do {
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let file = scratch.appendingPathComponent("stub-baseline.mactem.h5")
        try Data((0..<16).map { UInt8($0) }).write(to: file)
        let script = "if cmp -s \"$1\" \"$2\"; then echo '\(baselineLine)'; else \(misbehaviour); fi"
        let reader = ChildReader(executable: URL(fileURLWithPath: "/bin/sh"), arguments: { ["-c", script, "sh", $0, file.path] })
        let target = FuzzTarget(label: "selftest", file: file, modes: ["xor"], stride: 8, gated: true, expected: baselineLine)
        fuzzAll([target], truncations: 2, workers: 2, deadline: 1, reader: reader, scratch: scratch, &report)
    } catch {
        report.check(false, "fuzz selftest runs", "\(error)")
    }
    if report.failures > 0 {
        print("sidecar-parity: \(report.failures) FAILURES in \(report.checks) checks (the fuzz driver, stub reader: \(mode))")
        exit(1)
    }
    print("sidecar-parity: the fuzz driver found nothing to report against a stub reader that \(mode == "ok" ? "behaves" : mode) (\(report.checks) checks)")
    exit(0)
}
