// tools/parity/metadata-parity/main.swift — macTEM's AcquisitionMetadata readers (TEMCore, through
// Package.swift's MetadataParity target) against reference.py's expectations from the pinned references.
//
//     harness <out-dir-of-reference.py>
//
// Slice S-a: the three format readers `AcquisitionMetadata.tiff(data:)`, `.mrc(data:)` and `.dm(numbers:strings:)`.
// Slice S-b (archive: roadmap-registrations-2026-10-15.md V1-4a, "S-b, the DM wiring and tag 65027"): `AcquisitionMetadata.read(path:)`, the entry point that
// describes a FILE, end to end (`reads` in manifest.json; every check name starts `read:`):
//   C1  the object the open shows. `ImageOpening.primaryImageObject(in: DM4Experiment.list(path:))` is the ImageList number
//       the reference expects, and so is the one in `ImageOpening.openNow(path:).source`; where the open shows none (a 3-D
//       stack, a line scan) the first is nil and the open refuses.
//   C2  the maps. The walker's `imageTagNumbers` / `imageTagStrings` of that object equal the manifest's, EXACTLY, keys and
//       values, both ways: for the real files ncempy's `allTags` maps after two named steps (reference.py `c2_maps`), for a
//       planted file the maps the plant declared. The tag stream of a DM-saved TIFF (`DM4Experiment.tagTree`) likewise.
//   C3  `read(path:)` equals the expectation (reference.py's ncempy maps + RosettaSciIO for the real DM files, hand-written
//       truth for the plants, ncempy's reading of the same bytes for tag 65027), every field, note and second copy.
//   C4  the planted DM4 files; C5 tag 65027 of the real DM-saved TIFFs and the planted ones.
//   C6  `read(path:)` on every TIFF and MRC case of slice S-a: the extension dispatch, and a refusal reads empty.
// For every case of manifest.json, for each of the nine fields:
//   * the reference says "not recorded" (kind absent): the reading must be nil -- never 0, never "" (P2);
//   * the reference gives a value: the text equal exactly, a number to 1e-9 relative; the note equal exactly (nil when
//     the reference has none); the second stored copy (otherCopy) the same way, nil when the reference has none.
// A case marked `nilOrThrows` (a file that is not what it claims) passes when the function throws OR returns a record
// with every field nil; it may never invent a value and never trap. A file the harness itself cannot read is a
// failure, never a refusal. The owner's gitignored Ceta TIFFs are ordinary cases where they are provisioned (the
// manifest says how many of the expected six are, and the summary line says it); where they are not, they are absent.
//
// MACTEM_PARITY_MUTATE=<name> breaks the reading on purpose; run.sh requires each to exit 1 with the named check among
// the failures. Per mutation (input = what the real code is given; output = the reading it returns):
//   kv-unscaled           INPUT  planted-velox-diffraction: the twin file whose AccelerationVoltage is 1e3 times larger,
//                                so the real / 1e3 leaves the stored volts as kV (the dropped division's output)
//   mm-unscaled           INPUT  planted-velox-diffraction: the twin whose CameraLength is 1e3 times smaller (the real
//                                x 1e3 leaves the stored metres as mm)
//   nil-as-zero           OUTPUT every numeric field the reader left nil becomes a reading of 0 (the unbroken reader
//                                cannot be made to return 0 by any input)
//   stem-cl-in-tem        OUTPUT a DM case whose cameraLength is nil but whose STEM Camera Length tag is positive gets
//                                that tag as "mm (assumed)" (an input rewrite would also move the mode, so it is not one)
//   dm-date-swapped       INPUT  planted-dm-tem-diffraction: the date text "9/7/2014" for "7/9/2014" (the real month-first
//                                parse of it is the day-first reading of the original)
//   mrc-bitmask-ignored   INPUT  planted-fei2-unset-bits: the twin with all four bitmasks set (every field read, as a
//                                reader that ignored the masks would)
//   mrc-big-endian        INPUT  planted-fei2-stem: the twin whose HT double has its 8 bytes reversed (what reading the
//                                little-endian record big-endian returns for that field)
//   actual-for-indicated  INPUT  planted-dm-actual-ne-indicated: the Indicated Magnification tag holding the Actual
//                                value (the real reader reading Indicated shows what a reader of Actual would)
//   frametime-as-dwell    OUTPUT a case with a stored FrameTime (manifest extra) gets dwellUS = FrameTime x 1e6
//   dm-wrong-object      WIRING (a defect of read(path:) that the harness cannot inject, so it is MIRRORED): the described object
//                                is the first one that is not the thumbnail, not the object rule's -- C1 and the reading
//                                of planted-dm4-two-objects (the decoy's 300 kV) go red
//   dm-prefix-kept       WIRING: the maps keep `ImageList.N.ImageTags.` on every key -- C2, and every rule finds nothing
//   dm-strings-lost      WIRING: the strings map is empty -- C2 strings, and the mode and the date of every real object
//   dm-creation-dropped  WIRING: no key under `source.Tags at creation.` -- C2, the stack builder's reading and its planted twin
//   tiff-65027-skipped   INPUT  rsciio-dm-tiff-65027: the file with the tag renamed 65028 (a reader that never looks at 65027)
//   tiff-dm-before-velox INPUT  planted-tiff-velox-and-dm: the file with its Velox tag removed, so the real reader meets only
//                                the 120 kV DM block (what a reader that tries DM before Velox shows)
// The six SOURCE mutations (the app's open and read(path:)) are run.sh's: it builds the harness again
// against an edited copy of the one file; the four wiring mutations above are their mirrored twins.
// An unknown name exits 64 before any case.
//
// A case with `isolate` set (the tag-65027 plants that overrun their file) runs in a CHILD process of this harness
// (`harness --child <out-dir> <case name>`, which runs that one case and prints `child: F failures in N checks`): a reader
// that traps on it (a slice of the file out of range) kills the child, and the parent reports the check
// `read:<name> survives` as failed, with the signal, and carries on. run.sh counts a mutant as caught only when the harness
// exits 1 with the targeted check among its failures, so a trap in the unisolated harness would be no catch (a signal is not
// an exit 1); in the child it is.

@testable import TEMCore
import Foundation
import FormatoCore
import FormatoDM
import FormatoMRC
import FormatoTIFF

struct Manifest: Decodable {
    /// A JSON number or string: the value of a reading.
    enum Scalar: Decodable {
        case number(Double)
        case text(String)

        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let n = try? c.decode(Double.self) { self = .number(n) } else { self = .text(try c.decode(String.self)) }
        }

        var shown: String {
            switch self {
            case .number(let n): "\(n)"
            case .text(let s): "'\(s)'"
            }
        }
    }
    struct Expect: Decodable {
        let field: String
        let kind: String            // absent | value
        let value: Scalar?
        let note: String?
        let otherCopy: Scalar?
    }
    struct Input: Decodable {       // a mutant's replacement input
        let path: String?
        let numbers: [String: Double]?
        let strings: [String: String]?
    }
    struct Extra: Decodable {
        let frameTimeS: Double?
    }
    struct Case: Decodable {
        let name: String
        let format: String          // tiff | mrc | dm
        let path: String?
        let numbers: [String: Double]?
        let strings: [String: String]?
        let reference: String
        let outcome: String         // values | nilOrThrows
        let expected: [Expect]
        let mutants: [String: Input]
        let extra: Extra
        let comment: String
    }
    let ncempy: String
    let rsciio: String
    let tifffile: String
    let mrcfile: String
    struct Owner: Decodable {       // the owner's gitignored Ceta TIFFs: how many of the expected files were provisioned
        let expected: Int
        let present: Int
    }
    let owner: Owner
    let cases: [Case]
    /// Slice S-b: the cases of `AcquisitionMetadata.read(path:)` end to end.
    struct Maps: Decodable {
        let numbers: [String: Double]
        let strings: [String: String]
    }
    struct Block: Decodable {       // a tag-65027 stream written out, and the maps the tag walker has to return for it
        let path: String
        let numbers: [String: Double]
        let strings: [String: String]
    }
    struct Read: Decodable {
        let name: String
        let kind: String            // dm | tiff
        let path: String
        let reference: String
        let expected: [Expect]
        let object: Int?            // DM: the ImageList number whose tags the expectation is read from
        let shown: Int?             // DM: the ImageList number the open shows (nil: it shows none)
        let maps: Maps?             // DM: the maps the walker has to return for `object`
        let mapsFrom: String?
        let block: Block?           // tag 65027: the stream and its maps
        let isolate: Bool?          // run in a child process: the reader could trap on this file
        let mutants: [String: Input]
        let comment: String
    }
    let reads: [Read]
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

    /// The tally of a child process's run (its FAIL lines are relayed by the caller).
    mutating func absorb(failures childFailures: Int, checks childChecks: Int) {
        failures += childFailures
        checks += childChecks
    }
}

let mutations = ["kv-unscaled", "mm-unscaled", "nil-as-zero", "stem-cl-in-tem", "dm-date-swapped",
                 "mrc-bitmask-ignored", "mrc-big-endian", "actual-for-indicated", "frametime-as-dwell",
                 "dm-wrong-object", "dm-prefix-kept", "dm-strings-lost", "dm-creation-dropped",
                 "tiff-65027-skipped", "tiff-dm-before-velox"]
/// The four mutations of the DM wiring of read(path:), which the harness can only mirror (`describedObject`, `walkerMaps`
/// and the branch of `checkRead` that calls `dm(numbers:strings:)` itself).
let wiringMutations: Set<String> = ["dm-wrong-object", "dm-prefix-kept", "dm-strings-lost", "dm-creation-dropped"]

struct HarnessError: Error, CustomStringConvertible {
    let description: String
}

/// What the function under test returns for a case. Mutations that rewrite the INPUT swap in the case's mutant (a
/// twin file written by make_fixture.py, or replacement tag maps); OUTPUT mutations are applied by `outputMutated`.
func readCase(_ c: Manifest.Case, mutation: String?) throws -> AcquisitionMetadata {
    let input = mutation.flatMap { c.mutants[$0] }
    switch c.format {
    case "tiff", "mrc":
        guard let path = input?.path ?? c.path else { throw HarnessError(description: "no path in the manifest") }
        // A file that cannot be read is the harness's failure: it must never pass as the reader's refusal.
        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
        } catch {
            throw HarnessError(description: "cannot read \(path): \(error)")
        }
        return c.format == "tiff" ? try AcquisitionMetadata.tiff(data: data, convention: .app) : try AcquisitionMetadata.mrc(data: data, convention: .app)
    case "dm":
        return AcquisitionMetadata.dm(numbers: input?.numbers ?? c.numbers ?? [:],
                                      strings: input?.strings ?? c.strings ?? [:], convention: .app)
    default:
        throw HarnessError(description: "unknown format '\(c.format)'")
    }
}

func outputMutated(_ reading: AcquisitionMetadata, _ c: Manifest.Case, _ mutation: String?) -> AcquisitionMetadata {
    var m = reading
    switch mutation {
    case "nil-as-zero":
        if m.highTensionKV == nil { m.highTensionKV = MetadataReading(0.0) }
        if m.magnification == nil { m.magnification = MetadataReading(0.0) }
        if m.cameraLengthMM == nil { m.cameraLengthMM = MetadataReading(0.0) }
        if m.dwellUS == nil { m.dwellUS = MetadataReading(0.0) }
        if m.exposureS == nil { m.exposureS = MetadataReading(0.0) }
    case "stem-cl-in-tem":
        if c.format == "dm", m.cameraLengthMM == nil, let stem = c.numbers?["Microscope Info.STEM Camera Length"],
           stem > 0 {
            m.cameraLengthMM = MetadataReading(stem, note: "mm (assumed)")
        }
    case "frametime-as-dwell":
        if let frameTime = c.extra.frameTimeS { m.dwellUS = MetadataReading(frameTime * 1e6) }
    default:
        break
    }
    return m
}

func numeric(_ m: AcquisitionMetadata, _ field: String) -> MetadataReading<Double>? {
    switch field {
    case "highTensionKV": m.highTensionKV
    case "magnification": m.magnification
    case "cameraLengthMM": m.cameraLengthMM
    case "dwellUS": m.dwellUS
    case "exposureS": m.exposureS
    default: nil
    }
}

func textual(_ m: AcquisitionMetadata, _ field: String) -> MetadataReading<String>? {
    switch field {
    case "detector": m.detector
    case "acquired": m.acquired
    case "instrument": m.instrument
    case "mode": m.mode
    default: nil
    }
}

let numericFields: Set<String> = ["highTensionKV", "magnification", "cameraLengthMM", "dwellUS", "exposureS"]
let textFields: Set<String> = ["detector", "acquired", "instrument", "mode"]

/// 1e-9 relative (exactly equal values, zero included, pass).
func close(_ a: Double, _ b: Double) -> Bool {
    if a == b { return true }
    let scale = max(abs(a), abs(b))
    return scale > 0 && abs(a - b) <= 1e-9 * scale
}

func show<V: Sendable & Equatable>(_ r: MetadataReading<V>?) -> String {
    guard let r else { return "not recorded" }
    var s = "\(r.value)"
    if let note = r.note { s += " [\(note)]" }
    if let other = r.otherCopy { s += " other copy \(other)" }
    return s
}

func quoted(_ s: String?) -> String { s.map { "'\($0)'" } ?? "none" }

func compare(_ c: Manifest.Case, _ m: AcquisitionMetadata, _ report: inout Report) {
    compare(c.name, c.expected, m, &report)
}

/// The nine fields of `m` against the manifest's expectation, check names `<name> <field>`.
func compare(_ name: String, _ expected: [Manifest.Expect], _ m: AcquisitionMetadata, _ report: inout Report) {
    var seen = Set<String>()
    for e in expected {
        seen.insert(e.field)
        let check = "\(name) \(e.field)"
        if numericFields.contains(e.field) {
            let got = numeric(m, e.field)
            switch e.kind {
            case "absent":
                report.check(got == nil, check, "expected not recorded, got \(show(got))")
            case "value":
                guard case .number(let want)? = e.value else {
                    report.check(false, check, "malformed manifest entry (a number was expected)")
                    continue
                }
                guard let got else {
                    report.check(false, check, "expected \(want), got not recorded")
                    continue
                }
                report.check(close(got.value, want), check, "\(got.value) vs \(want)")
                report.check(got.note == e.note, "\(check) note", "\(quoted(got.note)) vs \(quoted(e.note))")
                switch (got.otherCopy, e.otherCopy) {
                case (nil, nil):
                    report.check(true, "\(check) otherCopy", "")
                case (let g?, .number(let w)?):
                    report.check(close(g, w), "\(check) otherCopy", "\(g) vs \(w)")
                default:
                    report.check(false, "\(check) otherCopy",
                                 "\(got.otherCopy.map { "\($0)" } ?? "none") vs \(e.otherCopy?.shown ?? "none")")
                }
            default:
                report.check(false, check, "unknown kind '\(e.kind)' in the manifest")
            }
        } else if textFields.contains(e.field) {
            let got = textual(m, e.field)
            switch e.kind {
            case "absent":
                report.check(got == nil, check, "expected not recorded, got \(show(got))")
            case "value":
                guard case .text(let want)? = e.value else {
                    report.check(false, check, "malformed manifest entry (a string was expected)")
                    continue
                }
                guard let got else {
                    report.check(false, check, "expected '\(want)', got not recorded")
                    continue
                }
                report.check(got.value == want, check, "'\(got.value)' vs '\(want)'")
                report.check(got.note == e.note, "\(check) note", "\(quoted(got.note)) vs \(quoted(e.note))")
                switch (got.otherCopy, e.otherCopy) {
                case (nil, nil):
                    report.check(true, "\(check) otherCopy", "")
                case (let g?, .text(let w)?):
                    report.check(g == w, "\(check) otherCopy", "'\(g)' vs '\(w)'")
                default:
                    report.check(false, "\(check) otherCopy",
                                 "\(quoted(got.otherCopy)) vs \(e.otherCopy?.shown ?? "none")")
                }
            default:
                report.check(false, check, "unknown kind '\(e.kind)' in the manifest")
            }
        } else {
            report.check(false, check, "unknown field in the manifest")
        }
    }
    report.check(seen == numericFields.union(textFields), "\(name) fields",
                 "the manifest lists \(seen.sorted()), not the nine fields")
}

// MARK: - Slice S-b: read(path:) end to end

/// Two maps compared EXACTLY, both ways: a key only one side has, and a value that differs. -> a line per difference.
func mapDifferences<V>(got: [String: V], want: [String: V], same: (V, V) -> Bool) -> [String] {
    var lines: [String] = []
    for key in want.keys.sorted() where got[key] == nil { lines.append("missing \(key.debugDescription)") }
    for key in got.keys.sorted() where want[key] == nil { lines.append("extra \(key.debugDescription)") }
    for key in want.keys.sorted() {
        if let g = got[key], let w = want[key], !same(g, w) { lines.append("\(key.debugDescription): \(g) vs \(w)") }
    }
    return lines
}

func checkMaps(_ name: String, got: (numbers: [String: Double], strings: [String: String]),
               want: (numbers: [String: Double], strings: [String: String]), source: String, _ report: inout Report) {
    func detail(_ lines: [String], _ got: Int, _ want: Int) -> String {
        "\(got) keys against \(want) (\(source)): " + lines.prefix(4).joined(separator: "; ")
            + (lines.count > 4 ? "; and \(lines.count - 4) more" : "")
    }
    let n = mapDifferences(got: got.numbers, want: want.numbers) { $0.bitPattern == $1.bitPattern }
    report.check(n.isEmpty, "\(name) numbers", detail(n, got.numbers.count, want.numbers.count))
    let t = mapDifferences(got: got.strings, want: want.strings) { $0 == $1 }
    report.check(t.isEmpty, "\(name) strings", detail(t, got.strings.count, want.strings.count))
}

/// The object `read(path:)` describes. Unbroken it is the open's own rule; `dm-wrong-object` mirrors a reader that took the
/// first object that is not the thumbnail.
func describedObject(_ objects: [DM4ImageObject], mutation: String?) -> DM4ImageObject? {
    if mutation == "dm-wrong-object" { return objects.first { $0.role != .thumbnail } }
    return ImageOpening.primaryImageObject(in: objects)
}

/// The tag walker's two maps for an object, as `read(path:)` hands them to the DM rules. The other three wiring mutations
/// are defects of those maps: the object's prefix kept on every key, every string lost, no key of the stack builder's copy.
func walkerMaps(_ o: DM4ImageObject, mutation: String?) -> (numbers: [String: Double], strings: [String: String]) {
    var numbers = o.imageTagNumbers, strings = o.imageTagStrings
    switch mutation {
    case "dm-prefix-kept":
        let prefix = "ImageList.\(o.index).ImageTags."
        numbers = Dictionary(uniqueKeysWithValues: numbers.map { (prefix + $0.key, $0.value) })
        strings = Dictionary(uniqueKeysWithValues: strings.map { (prefix + $0.key, $0.value) })
    case "dm-strings-lost":
        strings = [:]
    case "dm-creation-dropped":
        numbers = numbers.filter { !$0.key.hasPrefix("source.Tags at creation.") }
        strings = strings.filter { !$0.key.hasPrefix("source.Tags at creation.") }
    default:
        break
    }
    return (numbers, strings)
}

/// "ImageList.3 · shown" -> 3.
func shownIndex(_ source: String) -> Int? {
    guard source.hasPrefix("ImageList.") else { return nil }
    return Int(source.dropFirst("ImageList.".count).prefix { $0.isNumber })
}

/// One case of `read(path:)`. C1 and C2 are the DM object and its maps; C3 the reading; the tag stream of a DM-saved TIFF is
/// the walker's `tagTree` against the manifest's maps.
func checkRead(_ c: Manifest.Read, mutation: String?, _ report: inout Report) {
    let label = "read:\(c.name)"
    let path = mutation.flatMap { c.mutants[$0] }?.path ?? c.path
    var objects: [DM4ImageObject] = []
    if c.kind == "dm" {
        do {
            objects = try DM4Experiment.list(path: path)
        } catch {
            report.check(false, "\(label) list", "the walker refused the file: \(error)")
            return
        }
        // C1
        let described = describedObject(objects, mutation: mutation)
        report.check(described?.index == c.shown, "\(label) C1 primary object",
                     "the object rule picks ImageList.\(described.map { "\($0.index)" } ?? "none"), expected "
                     + "ImageList.\(c.shown.map { "\($0)" } ?? "none")")
        if let shown = c.shown {
            do {
                let image = try ImageOpening.openNow(path: path)
                report.check(shownIndex(image.source) == shown, "\(label) C1 openNow",
                             "the open shows '\(image.source)', expected ImageList.\(shown)")
            } catch {
                report.check(false, "\(label) C1 openNow", "the open refused the file: \(error)")
            }
        } else {
            report.check((try? ImageOpening.openNow(path: path)) == nil, "\(label) C1 openNow refuses",
                         "the open showed an image although the reference describes none")
        }
        // C2
        if let want = c.maps, let index = c.object {
            if let object = objects.first(where: { $0.index == index }) {
                checkMaps("\(label) C2", got: walkerMaps(object, mutation: mutation),
                          want: (want.numbers, want.strings), source: c.mapsFrom ?? "the manifest", &report)
            } else {
                report.check(false, "\(label) C2 numbers", "the file has no ImageList.\(index)")
            }
        }
    }
    // The stream of tag 65027 on its own: the walker's `tagTree` is ncempy's parse of the same bytes.
    if let block = c.block {
        do {
            let tree = try DM4Experiment.tagTree(data: Data(contentsOf: URL(fileURLWithPath: block.path)))
            checkMaps("\(label) C2 tag stream", got: tree, want: (block.numbers, block.strings),
                      source: "ncempy allTags, steps (i) and (ii), or the plant's declaration", &report)
        } catch {
            report.check(false, "\(label) C2 tag stream numbers", "the walker refused the stream: \(error)")
        }
    }
    // C3
    let reading: AcquisitionMetadata
    if c.kind == "dm", let index = c.object, c.shown == nil, let object = objects.first(where: { $0.index == index }) {
        // The open shows no image (the stack builder's 3-D object): nothing is described, and the object's own tags go
        // through the walker's list and the DM rules.
        report.check(AcquisitionMetadata.read(path: path).isEmpty, "\(label) nothing described",
                     "read(path:) describes a file the open shows no image of")
        let maps = walkerMaps(object, mutation: mutation)
        reading = AcquisitionMetadata.dm(numbers: maps.numbers, strings: maps.strings, convention: .app)
    } else if c.kind == "dm", let mutation, wiringMutations.contains(mutation) {
        reading = describedObject(objects, mutation: mutation).map {
            let maps = walkerMaps($0, mutation: mutation)
            return AcquisitionMetadata.dm(numbers: maps.numbers, strings: maps.strings, convention: .app)
        } ?? AcquisitionMetadata()
    } else {
        reading = AcquisitionMetadata.read(path: path)
    }
    compare(label, c.expected, reading, &report)
}

/// A case on which the reader could trap runs in a child process: the trap kills the child, and this reports it as the failed
/// check `<label> survives`. The child's own FAIL lines are relayed, its tally added.
func checkReadInChild(_ c: Manifest.Read, reference: URL, _ report: inout Report) {
    let label = "read:\(c.name)"
    let child = Process()
    child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    child.arguments = ["--child", reference.path, c.name]
    let pipe = Pipe()
    child.standardOutput = pipe
    child.standardError = pipe
    do {
        try child.run()
    } catch {
        report.check(false, "\(label) survives", "the child process cannot start: \(error)")
        return
    }
    let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    child.waitUntilExit()
    if child.terminationReason == .uncaughtSignal {
        report.check(false, "\(label) survives",
                     "the reader was killed by signal \(child.terminationStatus) (a trap) on a file it must read as empty")
        return
    }
    let lines = output.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    let summary = lines.last { $0.hasPrefix("child: ") }.flatMap { line -> (failures: Int, checks: Int)? in
        let words = line.split(separator: " ")       // child: F failures in N checks
        guard words.count == 6, let failures = Int(words[1]), let checks = Int(words[4]) else { return nil }
        return (failures, checks)
    }
    guard let summary, child.terminationStatus == (summary.failures > 0 ? 1 : 0) else {
        report.check(false, "\(label) survives",
                     "the child exited \(child.terminationStatus) without a tally: \(output.prefix(300))")
        return
    }
    for line in lines where line.hasPrefix("  FAIL  ") { print(line) }
    report.absorb(failures: summary.failures, checks: summary.checks)
    report.check(true, "\(label) survives", "")
}

@main
struct MetadataParity {
    static func main() throws {
        let arguments = CommandLine.arguments
        let isChild = arguments.count == 4 && arguments[1] == "--child"
        guard arguments.count == 2 || isChild else {
            print("usage: harness <reference out-dir>")
            exit(64)
        }
        let out = URL(fileURLWithPath: arguments[isChild ? 2 : 1])
        let manifest = try JSONDecoder().decode(Manifest.self,
                                                from: Data(contentsOf: out.appendingPathComponent("manifest.json")))
        let mutation = ProcessInfo.processInfo.environment["MACTEM_PARITY_MUTATE"]
        if let mutation, !mutations.contains(mutation) {
            print("unknown MACTEM_PARITY_MUTATE '\(mutation)' (known: \(mutations.joined(separator: ", ")))")
            exit(64)
        }
        var report = Report()

        if isChild {            // one isolated case of `reads`, the parent's checkReadInChild reads the tally
            guard let c = manifest.reads.first(where: { $0.name == arguments[3] }) else {
                print("no read(path:) case '\(arguments[3])' in the manifest")
                exit(64)
            }
            checkRead(c, mutation: mutation, &report)
            print("child: \(report.failures) failures in \(report.checks) checks")
            exit(report.failures > 0 ? 1 : 0)
        }

        for c in manifest.cases {
            let failuresBefore = report.failures
            switch c.outcome {
            case "values":
                do {
                    compare(c, outputMutated(try readCase(c, mutation: mutation), c, mutation), &report)
                } catch {
                    report.check(false, "\(c.name) read", "refused: \(error)")
                }
            case "nilOrThrows":
                do {
                    let m = outputMutated(try readCase(c, mutation: mutation), c, mutation)
                    report.check(m.isEmpty, "\(c.name) nothing invented", "returned a reading with values: \(m)")
                } catch let error as HarnessError {
                    report.check(false, "\(c.name) read", "\(error)")
                } catch {
                    report.check(true, "\(c.name) refused", "")
                }
            default:
                report.check(false, c.name, "unknown outcome '\(c.outcome)'")
            }
            if report.failures == failuresBefore { print("  ok    \(c.name)") }
        }

        // Slice S-b. A check name is `<case> <field>`; the two sets of cases must not share a name.
        let names = manifest.cases.filter { $0.format != "dm" }.map(\.name) + manifest.reads.map(\.name)
        if Set(names).count != names.count {
            print("duplicate case names between the S-a file cases and the read(path:) cases")
            exit(64)
        }
        for c in manifest.reads {
            let failuresBefore = report.failures
            if c.isolate == true {
                checkReadInChild(c, reference: out, &report)
            } else {
                checkRead(c, mutation: mutation, &report)
            }
            if report.failures == failuresBefore { print("  ok    read:\(c.name)") }
        }
        // C6: every TIFF and MRC case of slice S-a again, through the path entry point: the extension dispatch, and a file
        // the format reader refuses reads empty (it never throws). Unmutated whatever the mutation: S-a's mutations rewrite
        // the format readers' inputs and outputs, not the dispatch.
        var dispatched = 0
        let failuresBeforeDispatch = report.failures
        for c in manifest.cases where c.format != "dm" {
            guard let path = c.path else { continue }
            dispatched += 1
            let label = "read:\(c.name)"
            let reading = AcquisitionMetadata.read(path: path)
            if c.outcome == "nilOrThrows" {
                report.check(reading.isEmpty, "\(label) nothing invented", "read(path:) returned values: \(reading)")
            } else {
                compare(label, c.expected, reading, &report)
            }
        }
        if report.failures == failuresBeforeDispatch {
            print("  ok    read(path:) on the \(dispatched) TIFF and MRC cases of slice S-a (C6)")
        }

        let versions = "ncempy \(manifest.ncempy), RosettaSciIO \(manifest.rsciio), tifffile \(manifest.tifffile), "
            + "mrcfile \(manifest.mrcfile)"
        if report.failures > 0 {
            print("metadata-parity: \(report.failures) FAILURES in \(report.checks) checks (\(versions))")
            exit(1)
        }
        print("metadata-parity: all passed — \(manifest.cases.count) cases and \(manifest.reads.count) read(path:) cases "
              + "(+ \(dispatched) dispatched), \(report.checks) checks against \(versions); "
              + "owner Ceta TIFFs gated: \(manifest.owner.present) of \(manifest.owner.expected) "
              + "(machine-local, gitignored)")
    }
}
