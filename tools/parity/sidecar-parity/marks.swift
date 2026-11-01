// tools/parity/sidecar-parity/marks.swift — the marks of the session sidecar (the core): `SessionMarks`,
// `SessionRestore` and `SessionSave`, against h5py 3.16.0 and numpy-free closed forms (marks_reference.py is the truth).
//
//   write step (`harness --write`): Swift writes the planted mark sessions through the whole save path — marks to nodes
//     (`SessionMarks.parameters` / `.results`), the lineage, `SessionSave.request` (every node checked with the restore's own
//     checks), `SessionSave.write` — and records the exact strings (swift-marks-written.json); then runs the save's
//     changed-on-disk scenarios against real files in <out>/marks-save/ and records what each did (swift-marks-save.json).
//     reference.py `readback` then reads every node of those files with h5py.
//   gate (`checkMarks`): Swift reads and restores those files (P1: marks, ids, points bit for bit, widths, the verdict, the
//     lineage text byte for byte, and a restore saved again with no edit is the same bytes) and the sidecars h5py wrote
//     (P2: each refusal by name naming the node, a partial restore never; P3: the verdict and the calibration note through
//     the restore), and the save's own refusals on the same lineages.
//
// A refusal is written as one sentence on both sides, for example `mark.badCoordinate s2 x1 0x1p3`.

@testable import TEMCore
import ImagoCore
import Darwin
import Foundation

// MARK: - The plan

struct MAxis: Decodable {
    let scale: String
    let units: String

    var axis: AxisCalibration { AxisCalibration(scale: Double(bitPattern: UInt64(scale, radix: 16) ?? 0), unit: units, origin: 0) }
}

struct MMark: Decodable {
    let kind: String
    let points: [[String]]
    let width: Int
    let samples: Int?
    let recorded: Int64

    var imagePoints: [ImagePoint] {
        points.map { ImagePoint(x: Double(bitPattern: UInt64($0[0], radix: 16) ?? 0), y: Double(bitPattern: UInt64($0[1], radix: 16) ?? 0)) }
    }

    var sessionMark: SessionMark? {
        guard let kind = SessionMark.Kind(rawValue: kind) else { return nil }
        return SessionMark(kind: kind, points: imagePoints, width: width)
    }
}

struct MSession: Decodable {
    let id: String
    let file_name: String
    let object: String
    let width: Int
    let height: Int
    let byte_size: Int64
    let digest: String
    let x: MAxis?
    let y: MAxis?
    let marks: [MMark]

    var identity: SessionSourceIdentity {
        SessionSourceIdentity(fileName: file_name, byteSize: byte_size, object: object, width: width, height: height, pixelSHA256: digest)
    }
}

struct MOpened: Decodable {
    let file_name: String
    let object: String
    let width: Int
    let height: Int
    let digest: String
    let byte_size: Int64
    let x: MAxis?
    let y: MAxis?

    var identity: SessionSourceIdentity {
        SessionSourceIdentity(fileName: file_name, byteSize: byte_size, object: object, width: width, height: height, pixelSHA256: digest)
    }
}

struct MExpectedMark: Decodable {
    let id: String
    let kind: String
    let points: [[String]]
    let width: Int
}

struct MRestored: Decodable {
    let ids: [String]
    let kept: Int
    let verdict: String
    let calibrationDiffers: Bool
    let readOnly: Bool
    let marks: [MExpectedMark]
}

struct MExpect: Decodable {
    let refused: String?
    let restored: MRestored?
}

struct MPlanted: Decodable {
    let name: String
    let file: String
    let opened: MOpened
    let expect: MExpect
    let save: String?
}

struct MarksPlan: Decodable {
    let sessions: [MSession]
    let planted: [MPlanted]
}

// MARK: - Sentences

func sentence(_ refusal: SessionMarks.Refusal) -> String {
    switch refusal {
    case .missingKey(let node, let key): "mark.missingKey \(node) \(key)"
    case .badCoordinate(let node, let key, let text): "mark.badCoordinate \(node) \(key) \(text)"
    case .outsideImage(let node, let point): "mark.outsideImage \(node) \(point)"
    case .badWidth(let node, let text): "mark.badWidth \(node) \(text)"
    }
}

func lineageName(_ refusal: SessionLineage.Refusal) -> String {
    switch refusal {
    case .tooLarge: "tooLarge"
    case .malformed: "malformed"
    case .tooManyNodes: "tooManyNodes"
    case .badNextID: "badNextID"
    case .badID: "badID"
    case .duplicateID: "duplicateID"
    case .idNotBelowNextID: "idNotBelowNextID"
    case .danglingInput: "danglingInput"
    case .cycle: "cycle"
    case .unsupportedVersion: "unsupportedVersion"
    case .idsExhausted: "idsExhausted"
    case .tooLargeToSave: "tooLargeToSave"
    case .notFinite: "notFinite"
    }
}

func sentence(_ refusal: SessionSourceIdentity.Refusal) -> String {
    switch refusal {
    case .tooLarge: return "identity.tooLarge"
    case .malformed: return "identity.malformed"
    case .invalid(let field): return "identity.invalid \(field)"
    }
}

func sentence(_ refusal: SessionRestore.Refusal) -> String {
    switch refusal {
    case .missingSource: "missingSource"
    case .missingLineage: "missingLineage"
    case .identity(let inner): sentence(inner)
    case .otherImage: "otherImage"
    case .lineage(let inner): "lineage.\(lineageName(inner))"
    case .mark(let inner): sentence(inner)
    }
}

func sentence(_ refusal: SessionSave.Refusal) -> String {
    switch refusal {
    case .readOnly: "readOnly"
    case .sidecarRefused: "sidecarRefused"
    case .mark(let inner): sentence(inner)
    case .identity(let inner): sentence(inner)
    case .lineage(let inner): "lineage.\(lineageName(inner))"
    case .changedOnDisk: "changedOnDisk"
    case .pixelsChanged: "pixelsChanged"
    case .file(let inner): "file." + (refusalLine(inner).split(separator: " ").dropFirst().first.map(String.init) ?? "?")
    }
}

func sentence(_ verdict: SessionRestoreVerdict) -> String {
    switch verdict {
    case .adopt: "adopt"
    case .adoptPixelsDiffer: "adoptPixelsDiffer"
    case .adoptRenamed(let name): "adoptRenamed:\(name)"
    case .refuse: "refuse"
    }
}

func bitsOf(_ value: Double) -> String { String(value.bitPattern, radix: 16) }

func bitsEqual(_ a: String, _ b: String) -> Bool {
    (UInt64(a, radix: 16) ?? 1) == (UInt64(b, radix: 16) ?? 2)
}

// MARK: - The write step

struct WrittenMarkSession: Codable {
    let id: String
    var file: String?
    var source_json: String?
    var lineage_json: String?
    var error: String?
}

struct WrittenMarks: Codable {
    var sessions: [WrittenMarkSession]
}

struct SaveFile: Codable {
    let name: String
    let file: String
    let lineage: String
}

struct SaveOutcome: Codable {
    let name: String
    let problem: String?
}

struct SaveRecord: Codable {
    var files: [SaveFile]
    var outcomes: [SaveOutcome]
}

func lineageOf(_ session: MSession) throws -> SessionLineage {
    var lineage = SessionLineage()
    for mark in session.marks {
        guard let sessionMark = mark.sessionMark else { throw HarnessError(description: "unknown mark kind \(mark.kind)") }
        try lineage.add(kind: sessionMark.kind.rawValue,
                        parameters: SessionMarks.parameters(of: sessionMark, object: session.object),
                        results: SessionMarks.results(of: sessionMark, x: session.x?.axis, y: session.y?.axis, samples: mark.samples),
                        recorded: mark.recorded)
    }
    return lineage
}

func writeMarkSessions(_ plan: MarksPlan, ref: URL, out: URL) throws {
    let directory = out.appendingPathComponent("marks", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    var written = WrittenMarks(sessions: [])
    for session in plan.sessions {
        var record = WrittenMarkSession(id: session.id)
        do {
            let lineage = try lineageOf(session)
            let request = try SessionSave.request(identity: session.identity, lineage: lineage, revision: 1, expectedOnDisk: nil,
                                                  replacing: false)
            let url = try SessionSidecarFile.sidecarURL(forSource: directory.appendingPathComponent(session.file_name))
            try SessionSave.write(request, to: url)
            record.file = url.lastPathComponent
            record.source_json = request.source
            record.lineage_json = request.lineage
        } catch {
            record.error = "\(error)"
        }
        written.sessions.append(record)
    }
    try JSONEncoder().encode(written).write(to: out.appendingPathComponent("swift-marks-written.json"))
    try writeSaveScenarios(plan, ref: ref, out: out)
    print("write: \(written.sessions.count) mark sessions, \(written.sessions.filter { $0.error != nil }.count) with an error")
}

/// The save's changed-on-disk rule against real files: what each scenario did, as a problem sentence or nil.
func writeSaveScenarios(_ plan: MarksPlan, ref: URL, out: URL) throws {
    let directory = out.appendingPathComponent("marks-save", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    guard let base = plan.sessions.first else { throw HarnessError(description: "no mark session to save") }
    let identity = base.identity
    let first = try lineageOf(base)
    var second = first
    try second.add(kind: "distance", parameters: SessionMarks.parameters(of: SessionMark(kind: .distance, points: [ImagePoint(x: 1, y: 1), ImagePoint(x: 9, y: 9)]),
                                                                          object: base.object), recorded: 1_791_999_000_000)
    let firstText = try first.jsonString(), secondText = try second.jsonString()
    var record = SaveRecord(files: [], outcomes: [])

    func request(_ lineage: SessionLineage, expected: String?, replacing: Bool = false) throws -> SessionSave.Request {
        try SessionSave.request(identity: identity, lineage: lineage, revision: 1, expectedOnDisk: expected, replacing: replacing)
    }
    func outcome(_ name: String, expect: String?, _ body: () throws -> Void) {
        var got: String?
        do { try body() } catch let refusal as SessionSave.Refusal { got = sentence(refusal) } catch { got = "error \(error)" }
        record.outcomes.append(SaveOutcome(name: name, problem: got == expect ? nil : "got \(got ?? "a successful write"); want \(expect ?? "a successful write")"))
    }
    func bytes(_ url: URL) -> Data? { try? Data(contentsOf: url) }

    let url = directory.appendingPathComponent("disk.mactem.h5")
    /// A copy of what a successful save left, for h5py to read.
    func snapshot(_ name: String, _ lineage: String) {
        let copy = directory.appendingPathComponent("\(name).mactem.h5")
        try? FileManager.default.removeItem(at: copy)
        try? FileManager.default.copyItem(at: url, to: copy)
        record.files.append(SaveFile(name: name, file: copy.lastPathComponent, lineage: lineage))
    }
    outcome("fresh", expect: nil) { try SessionSave.write(try request(first, expected: nil), to: url) }
    snapshot("fresh", firstText)
    outcome("rewrite-as-read", expect: nil) { try SessionSave.write(try request(second, expected: firstText), to: url) }
    snapshot("rewrite-as-read", secondText)
    let kept = bytes(url)
    outcome("stale-expectation", expect: "changedOnDisk") { try SessionSave.write(try request(first, expected: firstText), to: url) }
    outcome("never-read", expect: "changedOnDisk") { try SessionSave.write(try request(first, expected: nil), to: url) }
    record.outcomes.append(SaveOutcome(name: "refused-leaves-the-file", problem: bytes(url) == kept ? nil : "a refused save changed the file"))
    outcome("replace-chosen", expect: nil) { try SessionSave.write(try request(first, expected: nil, replacing: true), to: url) }
    snapshot("replace-chosen", firstText)

    // A foreign HDF5 file (planted by h5py) is not overwritten even when the user chose to replace what was there.
    let foreignSource = ref.appendingPathComponent("planted/foreign-bare.mactem.h5")
    let foreign = directory.appendingPathComponent("foreign.mactem.h5")
    if FileManager.default.fileExists(atPath: foreignSource.path) {
        try? FileManager.default.removeItem(at: foreign)
        try FileManager.default.copyItem(at: foreignSource, to: foreign)
        let before = bytes(foreign)
        outcome("foreign-replace-chosen", expect: "file.foreign") { try SessionSave.write(try request(first, expected: nil, replacing: true), to: foreign) }
        outcome("foreign-not-chosen", expect: "file.foreign") { try SessionSave.write(try request(first, expected: firstText), to: foreign) }
        record.outcomes.append(SaveOutcome(name: "foreign-left-alone", problem: bytes(foreign) == before ? nil : "the foreign file was changed"))
    } else {
        record.outcomes.append(SaveOutcome(name: "foreign-left-alone", problem: "the planted foreign file is missing"))
    }

    // The request's own refusals.
    let future = try SessionLineage.decode(#"{"next_id":4,"nodes":{"s1":[1]},"version":2}"#)
    outcome("read-only", expect: "readOnly") { _ = try request(future, expected: nil) }
    var bad = SessionLineage()
    try bad.add(kind: "distance", parameters: ["x1": "0", "y1": "0", "x2": "99999", "y2": "0", "object": base.object, "frame": "0"], recorded: 1)
    outcome("bad-mark", expect: "mark.outsideImage s1 2") { _ = try request(bad, expected: nil) }
    outcome("empty-lineage", expect: nil) { _ = try request(SessionLineage(), expected: nil) }
    // The text cap: the text of a save is at most 60,000 bytes; a record of exactly that is made, one byte more is refused by name
    func padded(_ pad: Int) throws -> SessionLineage {
        var lineage = first
        try lineage.add(kind: "export", parameters: ["pad": String(repeating: "p", count: pad)], recorded: 1_791_999_000_001)
        return lineage
    }
    let emptyTotal = 2 + (try identity.jsonString().utf8.count) + (try padded(0).jsonString().utf8.count)
    let room = SessionSidecarFile.maxTotalTextBytes - emptyTotal
    outcome("at-budget", expect: nil) { _ = try request(try padded(room), expected: nil) }
    outcome("over-budget", expect: "file.sidecarTooLarge") { _ = try request(try padded(room + 1), expected: nil) }
    try JSONEncoder().encode(record).write(to: out.appendingPathComponent("swift-marks-save.json"))
}

// MARK: - The gate

func marksProblems(_ restored: SessionRestore.Restored, want: MRestored) -> [String: [String]] {
    var problems: [String: [String]] = [:]
    func note(_ key: String, _ text: String) { problems[key, default: []].append(text) }
    if restored.marks.map(\.nodeID) != want.ids { note("nodes", "\(restored.marks.map(\.nodeID)) vs \(want.ids)") }
    if restored.kept != want.kept { note("kept", "\(restored.kept) nodes kept, want \(want.kept)") }
    if sentence(restored.verdict) != want.verdict { note("verdict", "\(sentence(restored.verdict)) vs \(want.verdict)") }
    if restored.calibrationDiffers != want.calibrationDiffers {
        note("note", "calibrationDiffers \(restored.calibrationDiffers), want \(want.calibrationDiffers)")
    }
    if restored.lineage.isReadOnly != want.readOnly { note("readonly", "isReadOnly \(restored.lineage.isReadOnly), want \(want.readOnly)") }
    for (entry, mark) in zip(restored.marks, want.marks) {
        if entry.nodeID != mark.id { note("nodes", "\(entry.nodeID) vs \(mark.id)") }
        if entry.mark.kind.rawValue != mark.kind { note("kinds", "\(entry.nodeID): \(entry.mark.kind) vs \(mark.kind)") }
        if entry.mark.width != mark.width { note("widths", "\(entry.nodeID): width \(entry.mark.width) vs \(mark.width)") }
        let got = entry.mark.points.map { [bitsOf($0.x), bitsOf($0.y)] }
        let same = got.count == mark.points.count && zip(got, mark.points).allSatisfy { bitsEqual($0[0], $1[0]) && bitsEqual($0[1], $1[1]) }
        if !same { note("points", "\(entry.nodeID): \(entry.mark.points) vs the planted bit patterns \(mark.points)") }
    }
    return problems
}

func checkMarks(_ plan: MarksPlan, ref: URL, out: URL, _ report: inout Report) {
    // 1. what Swift wrote: restored (P1) and saved again with no edit
    let written = (try? JSONDecoder().decode(WrittenMarks.self, from: Data(contentsOf: out.appendingPathComponent("swift-marks-written.json"))))
    report.check(written != nil, "swift marks write", "no record of the write step")
    for session in plan.sessions {
        guard let record = written?.sessions.first(where: { $0.id == session.id }) else { continue }
        report.check(record.error == nil, "swift marks writes \(session.id)", record.error ?? "")
        guard record.error == nil, let file = record.file else { continue }
        let url = out.appendingPathComponent("marks").appendingPathComponent(file)
        let contents: SessionSidecarFile.Contents
        do { contents = try SessionSidecarFile.read(url: url) } catch {
            report.check(false, "swift marks reads \(session.id)", "\(error)")
            continue
        }
        report.check(utf8Equal(contents.source ?? "", record.source_json ?? "-") && utf8Equal(contents.lineage ?? "", record.lineage_json ?? "-"),
                     "swift marks reads \(session.id)", "the file does not hold the strings the writer was handed")
        let axisX = session.x?.axis, axisY = session.y?.axis
        let restored: SessionRestore.Restored
        do throws(SessionRestore.Refusal) {
            restored = try SessionRestore.restore(contents, opened: session.identity, x: axisX, y: axisY)
        } catch {
            report.check(false, "swift marks restore \(session.id)", sentence(error))
            continue
        }
        let expected = MRestored(ids: session.marks.indices.map { "s\($0 + 1)" }, kept: 0, verdict: "adopt", calibrationDiffers: false,
                                 readOnly: false, marks: session.marks.indices.map {
                                     MExpectedMark(id: "s\($0 + 1)", kind: session.marks[$0].kind, points: session.marks[$0].points,
                                                   width: session.marks[$0].kind == "profile" ? session.marks[$0].width : 1)
                                 })
        let problems = marksProblems(restored, want: expected)
        for key in ["nodes", "kept", "verdict", "note", "readonly", "kinds", "widths", "points"] {
            report.check(problems[key] == nil, "swift marks \(key) \(session.id)", (problems[key] ?? []).joined(separator: "; "))
        }
        report.check(utf8Equal(restored.lineageText, record.lineage_json ?? "-"), "swift marks lineage text \(session.id)",
                     "the restored lineage text is not the one written")
        do throws(SessionSave.Refusal) {
            let request = try SessionSave.request(identity: session.identity, lineage: restored.lineage, revision: 1,
                                                  expectedOnDisk: restored.lineageText, replacing: false)
            report.check(utf8Equal(request.lineage, record.lineage_json ?? "-") && utf8Equal(request.source, record.source_json ?? "-"),
                         "swift marks resave \(session.id)", "a restore saved again with no edit is not the same bytes")
        } catch {
            report.check(false, "swift marks resave \(session.id)", sentence(error))
        }
    }
    // 2. what h5py wrote: restored or refused by name (P2, P3), and the save's checks on the same lineage
    for planted in plan.planted {
        let url = ref.appendingPathComponent(planted.file)
        let contents: SessionSidecarFile.Contents
        do { contents = try SessionSidecarFile.read(url: url) } catch {
            report.check(false, "swift marks reads \(planted.name)", "\(error)")
            continue
        }
        let identity = planted.opened.identity
        var result: Result<SessionRestore.Restored, SessionRestore.Refusal>
        do throws(SessionRestore.Refusal) {
            result = .success(try SessionRestore.restore(contents, opened: identity, x: planted.opened.x?.axis, y: planted.opened.y?.axis))
        } catch { result = .failure(error) }
        switch (result, planted.expect.refused, planted.expect.restored) {
        case (.failure(let refusal), let want?, _):
            report.check(sentence(refusal) == want, "swift marks refuses \(planted.name)", "\(sentence(refusal)) vs the planted \(want)")
        case (.success, let want?, _):
            report.check(false, "swift marks refuses \(planted.name)", "restored; the plan refuses it as \(want)")
        case (.failure(let refusal), nil, _):
            report.check(false, "swift marks restores \(planted.name)", "refused: \(sentence(refusal))")
        case (.success(let restored), nil, let want?):
            let problems = marksProblems(restored, want: want)
            for key in ["nodes", "kept", "verdict", "note", "readonly", "kinds", "widths", "points"] {
                report.check(problems[key] == nil, "swift marks \(key) \(planted.name)", (problems[key] ?? []).joined(separator: "; "))
            }
        case (.success, nil, nil):
            report.check(false, "swift marks restores \(planted.name)", "the plan states no outcome")
        }
        guard let save = planted.save, let lineageText = contents.lineage, let lineage = try? SessionLineage.decode(lineageText) else { continue }
        do throws(SessionSave.Refusal) {
            let request = try SessionSave.request(identity: identity, lineage: lineage, revision: 1, expectedOnDisk: lineageText, replacing: false)
            report.check(save == "same" && utf8Equal(request.lineage, lineageText), "swift marks save \(planted.name)",
                         save == "same" ? "a restore saved again with no edit is not the same bytes" : "the save went through; the plan refuses it as \(save)")
        } catch {
            let got = sentence(error)
            report.check(got == save, "swift marks save \(planted.name)", "\(got) vs the planted \(save)")
        }
    }
    // 3. the save's changed-on-disk rule on real files
    if let record = try? JSONDecoder().decode(SaveRecord.self, from: Data(contentsOf: out.appendingPathComponent("swift-marks-save.json"))) {
        for outcome in record.outcomes { report.check(outcome.problem == nil, "swift marks save-disk \(outcome.name)", outcome.problem ?? "") }
    } else {
        report.check(false, "swift marks save-disk", "no record of the save scenarios")
    }
}
