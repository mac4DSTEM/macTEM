// tools/parity/velox-image-parity/main.swift — macTEM's Velox image reader (`ImageOpening.openNow` → `VeloxImageReader`, TEMCore,
// over SpectroKit's `VeloxEMDReader`; both compiled into this one module from tools/lib/sources.manifest groups `velox` and `metadata`)
// against reference.py's reading of every case (its manifest.json).
//
//     harness <out-dir-of-reference.py> <stack.emd>            the gate
//     harness --measure <stack.emd> <small.emd>                 (internal) one read in a fresh process, for the memory check
//     harness --probe <file.emd>                                (internal) one read in a fresh process, for the library check
//
// What is compared, per file the registered rule opens (P1): the pixels of frame 0, and of every other frame the manifest
// names, bit for bit against h5py's frames as float32; each axis's scale — the raw decimal of PixelSize, bit for bit, and
// RosettaSciIO's within 1e-12 relative in the file's own unit; its origin within 1e-9 px of -Offset/PixelSize and of
// RosettaSciIO's, +0.0 where that is 0 (the Info tab prints the origin); its unit string equal to the raw PixelUnitX / PixelUnitY; the voltage equal to the raw field; the opened
// entry equal to the rule's; the notes. Per file (P2): a file the rule refuses throws its named refusal and none the
// rule opens is refused (a), a damaged Metadata column included (`unreadable`, never a raw JSON error); every entry's candidacy equals the rule's, no Analytical or compound entry opens (b);
// "frame 1 of N" is present iff N > 1 (c); one frame of a 1024 x 1024 x 64 stack opens with peak resident growth under
// 25 % of the stack, measured in a child process (d); an image over 2^28 pixels is refused when read, and with no libhdf5
// to load (a child process told of none) the refusal is the named `library`. Then the registered predictions, each printed.
//
// The `.emd` acquisition metadata (V1-4a, "the panel", the `.emd` sentence; `AcquisitionMetadata.read(path:)`): high tension,
// detector, instrument, start date and dwell equal the rule's reading of the raw JSON, the high tension and the date also
// RosettaSciIO's (its Optics.AccelerationVoltage mapping and its General.date and .time), the date shown in a fixed zone
// equals the rule's (whatever this Mac's clock), the four fields macTEM does not read yet (SpectroKit 0.2.0 exposes them) are `unread`, a refused
// file reads empty. Where RosettaSciIO's title is not BinaryResult.Detector the difference is printed (it is not a check).
//
// A case marked `diagnostic` (the owner's Ceta files) is compared and printed but never fails the gate.
// Failures are mutations' evidence: tools/parity/velox-image-parity/run.sh breaks the adapters in scratch copies seventeen ways
// (fourteen of the image reader, three of the `.emd` metadata) and requires each to fail the check named for it.

import ImagoCore
import Darwin
import Foundation
import FormatoCore
import FormatoEMD

struct Manifest: Decodable {
    struct Axis: Decodable {
        let scale: Double
        let units: String
        let origin: Double
    }
    struct RsAxis: Decodable {
        let scale: Double
        let origin: Double
    }
    struct RsAxes: Decodable {
        let x: RsAxis
        let y: RsAxis
    }
    struct Entry: Decodable {
        let id: String
        let detector: String
        let candidate: Bool
        let analytical: Bool
        let dtype: String
    }
    struct Frame: Decodable {
        let index: Int
        let pixels: String
        let notes: [String]
    }
    struct MetaRule: Decodable {
        let highTensionKV: Double?
        let detector: String?
        let instrument: String?
        let acquired: String?
        let acquiredZone: String?
        let dwellUS: Double?
    }
    struct MetaRs: Decodable {
        let beamEnergyKV: Double?
        let title: String?
        let acquired: String?
    }
    struct Meta: Decodable {
        let rule: MetaRule
        let rsciio: MetaRs?
    }
    struct Case: Decodable {
        let name: String
        let path: String
        let group: String
        let tag: String
        let diagnostic: Bool
        let entries: [Entry]
        let kind: String
        let error: String?
        let id: String?
        let source: String?
        let frame_count: Int?
        let width: Int?
        let height: Int?
        let x: Axis?
        let y: Axis?
        let voltage: Double?
        let key_position: Int?
        let key_count: Int?
        let detector: String?
        let frames: [Frame]?
        let rsciio: RsAxes?
        let tiff: String?
        let chunks: [Int]?
        let dtype: String?
        let metadata: Meta?
    }
    let rsciio: String
    let h5py: String
    let numpy: String
    let cases: [Case]
}

/// Failures are counted here, not in a global: Swift 6 refuses a mutable global in a nonisolated module.
struct Report {
    private(set) var failures = 0
    private(set) var checks = 0
    var diagnostic = false

    mutating func check(_ ok: Bool, _ name: String, _ detail: @autoclosure () -> String) {
        if diagnostic {
            if !ok { print("  diag  \(name): \(detail())") }
            return
        }
        checks += 1
        if ok { return }
        failures += 1
        print("  FAIL  \(name): \(detail())")
    }
}

/// The largest differences measured against RosettaSciIO, over the gated cases.
struct Measured {
    var scaleRelative = 0.0
    var origin = 0.0
}

func bits(_ pixels: [Float]) -> [UInt32] { pixels.map(\.bitPattern) }

func readFloats(_ path: String) throws -> [Float] {
    try Data(contentsOf: URL(fileURLWithPath: path)).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
}

func refusalName(_ refusal: VeloxImageReader.Refusal) -> String {
    switch refusal {
    case .notVelox: "notVelox"
    case .library: "library"
    case .noImage: "noImage"
    case .unreadable: "unreadable"
    }
}

func compare(_ name: String, _ got: AxisCalibration?, _ want: Manifest.Axis?, _ rs: Manifest.RsAxis?, _ report: inout Report,
             _ measured: inout Measured) {
    guard let want else {
        report.check(got == nil, "\(name) scale", "calibrated \(String(describing: got)); the rule reads the axis uncalibrated")
        return
    }
    guard let got else {
        report.check(false, "\(name) scale", "no calibration; the rule reads \(want.scale) \(want.units)")
        return
    }
    var scaleOK = got.scale.bitPattern == want.scale.bitPattern
    var scaleDetail = "\(got.scale) vs the stored \(want.scale)"
    var originOK = abs(got.origin - want.origin) <= 1e-9
    var originDetail = "\(got.origin) vs the rule's \(want.origin)"
    if let rs {
        let relative = abs(got.scale - rs.scale) / abs(rs.scale)
        let distance = abs(got.origin - rs.origin)
        if !report.diagnostic {
            measured.scaleRelative = max(measured.scaleRelative, relative)
            measured.origin = max(measured.origin, distance)
        }
        scaleOK = scaleOK && relative <= 1e-12
        if relative > 1e-12 { scaleDetail += "; RosettaSciIO \(rs.scale) (relative \(relative))" }
        originOK = originOK && distance <= 1e-9
        if distance > 1e-9 { originDetail += "; RosettaSciIO \(rs.origin)" }
    }
    report.check(scaleOK, "\(name) scale", scaleDetail)
    report.check(originOK, "\(name) origin", originDetail)
    report.check(want.origin == 0 || (got.origin < 0) == (want.origin < 0), "\(name) origin sign", originDetail)
    report.check(got.unit == want.units, "\(name) units", "'\(got.unit)' vs the stored '\(want.units)'")
    // a zero origin is +0.0: the Info tab prints the origin (ImageInfoFormat.axis), and -0.0 formats as "-0"
    report.check(want.origin != 0 || got.origin.sign == .plus, "\(name) origin zero", "origin \(got.origin) where the rule's is 0")
}

func maxResidentBytes() -> Int {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return Int(usage.ru_maxrss)    // bytes on macOS
}

/// The memory plant's pixel: (7919 f + 31 r + 17 c) mod 65536 (make_fixture.py --stack).
func stackPixel(frame: Int, row: Int, column: Int) -> Float {
    Float((7919 * frame + 31 * row + 17 * column) & 0xFFFF)
}

/// One read in this fresh process, the app's own entry point: the library is loaded and the process warmed on a small file
/// first, so the growth is the read's.
func measure(stack: String, small: String) -> Never {
    _ = try? ImageOpening.openNow(path: small)
    let before = maxResidentBytes()
    guard let image = try? ImageOpening.openNow(path: stack) else {
        print("measure refused")
        exit(2)
    }
    let after = maxResidentBytes()
    let probes = [(0, 0), (1, 1), (511, 300), (1023, 1023), (700, 5)].filter { $0.0 < image.height && $0.1 < image.width }
    let values = probes.map { Int(image.pixels[$0.0 * image.width + $0.1]) }
    print("measure \(image.width) \(image.height) \(before) \(after) \(values.map(String.init).joined(separator: ",")) \(image.notes.joined(separator: "|"))")
    exit(0)
}

/// Opens `path` in a fresh process that is told of no libhdf5 and given no place to find one: the refusal it names.
func libraryProbe(path: String) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    process.arguments = ["--probe", path]
    var environment = ProcessInfo.processInfo.environment
    environment["FORMATO_HDF5_PATH"] = "/nonexistent/libhdf5.dylib"
    environment["DYLD_FALLBACK_LIBRARY_PATH"] = "/nonexistent"
    environment.removeValue(forKey: "DYLD_LIBRARY_PATH")
    process.environment = environment
    let empty = FileManager.default.temporaryDirectory.appendingPathComponent("velox-image-parity-empty-\(getpid())")
    try? FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: empty) }
    process.currentDirectoryURL = empty
    let pipe = Pipe()
    process.standardOutput = pipe
    guard (try? process.run()) != nil else { return nil }
    let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { return nil }
    return output.split(separator: "\n").last(where: { $0.hasPrefix("probe ") }).map { String($0.dropFirst("probe ".count)) }
}

func probe(path: String) -> Never {
    do {
        let image = try VeloxImageReader.read(path: path)
        print("probe opened \(image.width) × \(image.height) x \(String(describing: image.x)) y \(String(describing: image.y)) notes \(image.notes)")
    } catch let refusal as VeloxImageReader.Refusal {
        print("probe \(refusalName(refusal))")
    } catch {
        print("probe error \(error)")
    }
    exit(0)
}

struct Measurement {
    let width: Int, height: Int, before: Int, after: Int, probes: [Int], notes: String
    var growth: Int { after - before }
}

func runChild(stack: String, small: String) -> Measurement? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    process.arguments = ["--measure", stack, small]
    let pipe = Pipe()
    process.standardOutput = pipe
    guard (try? process.run()) != nil else { return nil }
    let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    guard process.terminationStatus == 0, let line = output.split(separator: "\n").last(where: { $0.hasPrefix("measure ") }) else {
        return nil
    }
    let parts = line.split(separator: " ", maxSplits: 6, omittingEmptySubsequences: false)
    guard parts.count >= 6, let w = Int(parts[1]), let h = Int(parts[2]), let b = Int(parts[3]), let a = Int(parts[4]) else { return nil }
    return Measurement(width: w, height: h, before: b, after: a, probes: parts[5].split(separator: ",").compactMap { Int($0) },
                       notes: parts.count > 6 ? String(parts[6]) : "")
}

func mib(_ bytes: Int) -> String { String(format: "%.1f MiB", Double(bytes) / 1_048_576) }

/// What each field of an `.emd`'s metadata the harness compares reads as text, for the diagnostic against a paired TIFF.
let metadataFields: [(String, @Sendable (AcquisitionMetadata) -> String?)] = [
    ("high tension", { $0.highTensionKV.map { "\($0.value)" } }),
    ("magnification", { $0.magnification.map { "\($0.value)" } }),
    ("camera length", { $0.cameraLengthMM.map { "\($0.value)" } }),
    ("detector", { $0.detector?.value }),
    ("dwell", { $0.dwellUS.map { "\($0.value)" } }),
    ("exposure", { $0.exposureS.map { "\($0.value)" } }),
    ("acquired", { $0.acquired?.value }),
    ("instrument", { $0.instrument?.value }),
    ("mode", { $0.mode?.value }),
]

func sameNumber(_ got: Double?, _ want: Double?) -> Bool {
    guard let got, let want else { return got == nil && want == nil }
    return abs(got - want) <= 1e-12 * abs(want)
}

/// V1-4a, the `.emd` sentence, for a file the reader opened: what `AcquisitionMetadata.read(path:)` says.
func checkMetadata(_ c: Manifest.Case, _ meta: Manifest.Meta, _ report: inout Report, _ titles: inout [String],
                   _ dates: inout [String]) {
    let m = AcquisitionMetadata.read(path: c.path)
    let r = meta.rule
    let rs = meta.rsciio
    report.check(m.highTensionKV?.value.bitPattern == r.highTensionKV?.bitPattern
                 && (rs == nil || m.highTensionKV?.value.bitPattern == rs?.beamEnergyKV?.bitPattern),
                 "\(c.name) metadata highTension",
                 "\(String(describing: m.highTensionKV?.value)) kV vs the stored \(String(describing: r.highTensionKV)) and RosettaSciIO's \(String(describing: rs?.beamEnergyKV))")
    report.check(m.detector?.value == r.detector, "\(c.name) metadata detector",
                 "\(String(describing: m.detector?.value)) vs BinaryResult.Detector \(String(describing: r.detector))")
    if let rs, rs.title != m.detector?.value {
        titles.append("\(c.name): '\(m.detector?.value ?? "nil")' against RosettaSciIO's title '\(rs.title ?? "nil")'")
    }
    report.check(m.instrument?.value == r.instrument, "\(c.name) metadata instrument",
                 "\(String(describing: m.instrument?.value)) vs the stored \(String(describing: r.instrument))")
    // RosettaSciIO dates a file whose AcquisitionStartDatetime is absent from CustomProperties["Detectors[BM-Ceta].TimeStamp"]
    // (its `_get_metadata_dict` workaround); the reader has no such fallback, so that difference is printed, not checked.
    let fallback = rs?.acquired != nil && r.acquired == nil
    if fallback { dates.append("\(c.name): none against RosettaSciIO's \(rs?.acquired ?? "")") }
    report.check(m.acquired?.value == r.acquired && (rs == nil || fallback || m.acquired?.value == rs?.acquired),
                 "\(c.name) metadata acquired",
                 "\(String(describing: m.acquired?.value)) vs the stored instant \(String(describing: r.acquired)) and RosettaSciIO's \(String(describing: rs?.acquired))")
    if let entry = VeloxImageReader.openedEntry(path: c.path), let zone = TimeZone(identifier: "Pacific/Auckland") {
        let shown = AcquisitionMetadata.velox(entry, timeZone: zone, convention: .app).acquired?.value
        report.check(shown == r.acquiredZone, "\(c.name) metadata zone",
                     "the date in Pacific/Auckland is \(String(describing: shown)); the stored instant there is \(String(describing: r.acquiredZone))")
    }
    report.check(sameNumber(m.dwellUS?.value, r.dwellUS), "\(c.name) metadata dwell",
                 "\(String(describing: m.dwellUS?.value)) µs vs the stored \(String(describing: r.dwellUS))")
    report.check(m.unread == [.magnification, .cameraLength, .exposure, .mode] && m.magnification == nil
                 && m.cameraLengthMM == nil && m.exposureS == nil && m.mode == nil,
                 "\(c.name) metadata unread", "unread \(m.unread.map(\.rawValue).sorted()); the four fields macTEM does not read yet (SpectroKit 0.2.0 exposes them) must read unread, never recorded")
}

enum Outcome {
    case opened(CalibratedImage)
    case refused(String)
}

@main
struct VeloxImageParity {
    static func main() throws {
        let args = CommandLine.arguments
        if args.count == 4, args[1] == "--measure" { measure(stack: args[2], small: args[3]) }
        if args.count == 3, args[1] == "--probe" { probe(path: args[2]) }
        guard args.count == 3 else {
            print("usage: harness <reference out-dir> <memory-plant.emd>")
            exit(64)
        }
        let out = URL(fileURLWithPath: args[1])
        let stackPath = args[2]
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: out.appendingPathComponent("manifest.json")))
        var report = Report()
        var measured = Measured()
        var outcomes: [String: Outcome] = [:]
        var diagnostics = 0
        var titleDifferences: [String] = []
        var dateDifferences: [String] = []

        for c in manifest.cases {
            let before = report.failures
            report.diagnostic = c.diagnostic
            if c.diagnostic { diagnostics += 1 }
            let isEMD = (c.path as NSString).pathExtension.lowercased() == "emd"

            // (b) every entry's candidacy, stored type and the Analytical / compound exclusions, against the rule's
            do {
                let listing = try VeloxEMDReader(path: c.path).images()
                report.check(listing.map(\.id) == c.entries.map(\.id), "\(c.name) entries",
                             "the file's image stacks \(listing.map(\.id)) vs the rule's \(c.entries.map(\.id))")
                for (entry, want) in zip(listing, c.entries) {
                    let candidate = VeloxImageSelection.choose([entry]) != nil
                    report.check(candidate == want.candidate, "\(c.name) entries",
                                 "\(want.id) (\(want.detector)): candidate \(candidate), the rule says \(want.candidate)")
                    report.check(!(candidate && want.analytical), "\(c.name) entries", "\(want.id) is an Analytical entry and opens")
                    report.check(!(candidate && want.dtype == "compound"), "\(c.name) entries", "\(want.id) is a compound image and opens")
                    let stored = entry.elementType?.rawValue ?? "compound"
                    report.check(stored == want.dtype || (entry.elementType == nil && want.dtype == "other"), "\(c.name) entries",
                                 "\(want.id) stored type \(stored), h5py reads \(want.dtype)")
                }
            } catch {
                report.check((c.error == "notVelox" || c.error == "unreadable") && c.entries.isEmpty, "\(c.name) entries",
                             "listing the entries failed: \(error)")
            }

            switch c.kind {
            case "image":
                guard let width = c.width, let height = c.height, let count = c.frame_count, let frames = c.frames,
                      let id = c.id, let source = c.source else {
                    report.check(false, c.name, "malformed manifest entry")
                    continue
                }
                let image: CalibratedImage
                do {
                    image = try ImageOpening.openNow(path: c.path)
                } catch {
                    report.check(false, "\(c.name) opens", "refused: \(error.localizedDescription)")
                    outcomes[c.name] = .refused("\(error)")
                    continue
                }
                outcomes[c.name] = .opened(image)
                report.check(image.width == width && image.height == height, "\(c.name) shape",
                             "\(image.width) × \(image.height) vs the file's \(width) × \(height)")
                report.check(image.fileName == (c.path as NSString).lastPathComponent, "\(c.name) file name", image.fileName)
                report.check(image.source == source, "\(c.name) object", "\(image.source) vs the rule's \(source)")
                report.check(VeloxImageReader.openedEntry(path: c.path)?.id == id, "\(c.name) object",
                             "openedEntry names \(String(describing: VeloxImageReader.openedEntry(path: c.path)?.id)), the rule \(id)")
                compare("\(c.name) x", image.x, c.x, c.rsciio?.x, &report, &measured)
                compare("\(c.name) y", image.y, c.y, c.rsciio?.y, &report, &measured)
                report.check(image.voltage?.bitPattern == c.voltage?.bitPattern, "\(c.name) voltage",
                             "\(String(describing: image.voltage)) vs the stored \(String(describing: c.voltage))")
                if let meta = c.metadata { checkMetadata(c, meta, &report, &titleDifferences, &dateDifferences) }
                // (c) the frame label is present iff the stack has more than one frame
                let labelled = image.notes.contains("frame 1 of \(count)")
                let anyLabel = image.notes.contains { $0.hasPrefix("frame ") }
                report.check(labelled == (count > 1) && (count > 1 || !anyLabel), "\(c.name) frame label",
                             "notes \(image.notes) for a stack of \(count) frame\(count == 1 ? "" : "s")")
                if let first = frames.first {
                    report.check(image.notes == first.notes, "\(c.name) notes", "\(image.notes) vs \(first.notes)")
                }
                // the opening through the app's entry point and the adapter's own are one and the same
                if let direct = try? VeloxImageReader.read(path: c.path) {
                    let same = direct.width == image.width && direct.height == image.height && direct.x == image.x
                        && direct.y == image.y && direct.source == image.source && direct.voltage == image.voltage
                        && direct.notes == image.notes && bits(direct.pixels) == bits(image.pixels)
                    report.check(same, "\(c.name) wiring", "ImageOpening.openNow and VeloxImageReader.read differ")
                } else {
                    report.check(false, "\(c.name) wiring", "VeloxImageReader.read refused a file ImageOpening opens")
                }
                // P1: every frame the manifest names, from h5py, bit for bit; frame 0 through the app's entry point
                for f in frames {
                    let want = try readFloats(f.pixels)
                    let label = f.index == 0 ? "\(c.name) pixels" : "\(c.name) frame \(f.index + 1) pixels"
                    let got: [Float]
                    if f.index == 0 {
                        got = image.pixels
                    } else {
                        do {
                            let frame = try VeloxImageReader.read(path: c.path, frame: f.index)
                            got = frame.pixels
                            report.check(frame.notes == f.notes, "\(c.name) frame \(f.index + 1) notes", "\(frame.notes) vs \(f.notes)")
                            report.check(frame.x == image.x && frame.y == image.y && frame.voltage == image.voltage,
                                         "\(c.name) frame \(f.index + 1) calibration", "a frame carries the stack's calibration")
                        } catch {
                            report.check(false, label, "frame \(f.index) refused: \(error)")
                            continue
                        }
                    }
                    let differing = zip(got, want).enumerated().filter { $0.element.0.bitPattern != $0.element.1.bitPattern }
                    report.check(got.count == want.count && differing.isEmpty, label,
                                 "\(differing.count) of \(want.count) differ, first at index \(differing.first?.offset ?? -1)")
                }
                // the seam's bounds: a frame outside the stack is refused by name, never read
                for beyond in [count, -1] {
                    do {
                        _ = try VeloxImageReader.read(path: c.path, frame: beyond)
                        report.check(false, "\(c.name) frame range", "frame \(beyond) of \(count) was read")
                    } catch let refusal as VeloxImageReader.Refusal {
                        if case .unreadable = refusal { continue }
                        report.check(false, "\(c.name) frame range", "frame \(beyond) of \(count) refused as \(refusalName(refusal))")
                    } catch {
                        report.check(false, "\(c.name) frame range", "frame \(beyond) of \(count) refused with \(error)")
                    }
                }
            case "refusal":
                let want = c.error ?? "?"
                let check = "\(c.name) refusal"
                do {
                    let image = try ImageOpening.openNow(path: c.path)
                    outcomes[c.name] = .opened(image)
                    report.check(false, check, "read \(image.source) as \(image.width) × \(image.height); must be refused (\(want))")
                } catch let refusal as ImageOpening.Refusal {
                    if case .velox(_, let inner) = refusal {
                        outcomes[c.name] = .refused(refusalName(inner))
                        report.check(refusalName(inner) == want, check, "refused as \(refusalName(inner)), expected \(want)")
                    } else if case .unreadableFormat = refusal, !isEMD {
                        outcomes[c.name] = .refused("unreadableFormat")
                        // a .h5 file never reaches the Velox reader through the app; the reader itself must still name it
                        do {
                            let image = try VeloxImageReader.read(path: c.path)
                            report.check(false, check, "the reader read \(image.source) as \(image.width) × \(image.height); must be refused (\(want))")
                        } catch let inner as VeloxImageReader.Refusal {
                            outcomes[c.name] = .refused(refusalName(inner))
                            report.check(refusalName(inner) == want, check, "the reader refused as \(refusalName(inner)), expected \(want)")
                        } catch {
                            report.check(false, check, "the reader refused with \(error), expected \(want)")
                        }
                    } else {
                        outcomes[c.name] = .refused("\(refusal)")
                        report.check(false, check, "refused as \(refusal), expected \(want)")
                    }
                } catch {
                    outcomes[c.name] = .refused("\(error)")
                    report.check(false, check, "refused with \(error), expected \(want)")
                }
                // openedEntry is the object rule alone: it names an entry exactly when the file has a candidate, even one the
                // read then refuses (the image over 2^28 pixels), and is nil for every other refused file.
                let hasCandidate = c.entries.contains(where: \.candidate)
                report.check((VeloxImageReader.openedEntry(path: c.path) != nil) == hasCandidate, "\(c.name) object",
                             "openedEntry \(VeloxImageReader.openedEntry(path: c.path) == nil ? "is nil" : "names an entry") for a refused file whose rule candidates are \(hasCandidate)")
                if !hasCandidate {
                    report.check(AcquisitionMetadata.read(path: c.path).isEmpty, "\(c.name) metadata empty", "a refused file reads metadata")
                }
                if isEMD, want == "noImage" {
                    var message = ""
                    do { _ = try ImageOpening.openNow(path: c.path) } catch { message = error.localizedDescription }
                    print("  note  \(c.name): \(message)")
                }
            default:
                report.check(false, c.name, "unknown case kind '\(c.kind)'")
            }
            if report.failures == before { print("  \(c.diagnostic ? "diag" : "ok  ")  \(c.name)") }
        }
        report.diagnostic = false

        let small = manifest.cases.first { $0.name == "planted-haadf-last" }?.path ?? ""
        // the library: a fresh process told of no libhdf5 names its refusal `library`, never crashes
        let named = libraryProbe(path: small)
        report.check(named == "library", "library missing refusal", "a process with no libhdf5 to load answered '\(named ?? "no answer")'")
        // (d) memory: one frame of a 1024 x 1024 x 64 uint16 stack, one frame per chunk (a frame is 2 MiB of the 134 MB)
        let stackBytes = 1024 * 1024 * 64 * 2
        if let m = runChild(stack: stackPath, small: small) {
            let limit = stackBytes / 4
            report.check(m.growth < limit, "memory stack growth",
                         "peak resident growth \(mib(m.growth)) is not under 25 % of the stack (\(mib(limit)) of \(mib(stackBytes)))")
            let want = [(0, 0), (1, 1), (511, 300), (1023, 1023), (700, 5)].map { Int(stackPixel(frame: 0, row: $0.0, column: $0.1)) }
            report.check(m.width == 1024 && m.height == 1024 && m.probes == want && m.notes == "frame 1 of 64", "memory stack read",
                         "\(m.width) × \(m.height), probes \(m.probes) vs \(want), notes '\(m.notes)'")
            print("  memory  1024 × 1024 × 64 uint16 (\(mib(stackBytes))), frame-chunked: peak resident growth \(mib(m.growth)) = "
                  + String(format: "%.1f %%", 100 * Double(m.growth) / Double(stackBytes)) + " of the stack (limit 25 %)")
        } else {
            report.check(false, "memory stack growth", "the measuring process failed (stack \(stackPath))")
        }
        if let temStack = manifest.cases.first(where: { $0.name == "rsciio-fei_example_tem_stack" }),
           let m = runChild(stack: temStack.path, small: small) {
            let size = (temStack.width ?? 0) * (temStack.height ?? 0) * (temStack.frame_count ?? 0) * 2
            print("  memory  fei_example_tem_stack (\(temStack.width ?? 0) × \(temStack.height ?? 0) × \(temStack.frame_count ?? 0) "
                  + "\(temStack.dtype ?? "?"), chunks \(temStack.chunks ?? []) across frames): peak resident growth \(m.growth) bytes of a "
                  + "\(size)-byte stack: reported, not claimed")
        }

        // The registered predictions, each stated and checked against what the reader did.
        func opened(_ c: Manifest.Case) -> CalibratedImage? {
            if case .opened(let image)? = outcomes[c.name] { return image }
            return nil
        }
        func prediction(_ n: Int, _ text: String, _ held: Bool, _ detail: String, diagnostic: Bool = false) {
            print("  prediction \(n): \(text): \(held ? "HELD" : "REFUTED") — \(detail)")
            if !diagnostic { report.check(held, "prediction \(n)", detail) }
        }
        let zip13 = manifest.cases.filter { $0.tag == "zip13" }
        let zipOpened = zip13.filter { opened($0) != nil }
        let zipRefused = zip13.filter { opened($0) == nil }.map(\.name)
        prediction(1, "12 of the 13 zip files open (fei_emd_spectrum holds no image)",
                   zip13.count == 13 && zipOpened.count == 12 && zipRefused == ["rsciio-fei_emd_spectrum"],
                   "\(zipOpened.count) of \(zip13.count) open; refused: \(zipRefused)")
        let labelled = zipOpened.compactMap { c -> (String, Int)? in
            guard let image = opened(c), let note = image.notes.first(where: { $0.hasPrefix("frame 1 of ") }),
                  let n = Int(note.dropFirst("frame 1 of ".count)) else { return nil }
            return (c.name, n)
        }
        prediction(2, "6 of them open as \"frame 1 of N\" (N = 2, 10, 20, 20, 5, 2)",
                   labelled.count == 6 && labelled.map(\.1).sorted() == [2, 2, 5, 10, 20, 20],
                   "\(labelled.count) are labelled: \(labelled.map { "\($0.0) = \($0.1)" })")
        let testSI = manifest.cases.filter { $0.name.hasPrefix("rsciio-Test_SI_16x16") }
        prediction(3, "Test SI 16x16 opens its HAADF though it is last in key order",
                   testSI.count == 2 && testSI.allSatisfy { c in
                       (c.key_position ?? -1) == (c.key_count ?? 0) - 1 && (c.key_count ?? 0) > 1
                           && opened(c)?.source.hasSuffix("· HAADF") == true },
                   testSI.map { "\($0.name): \(opened($0)?.source ?? "refused") (key \($0.key_position ?? -1) of \($0.key_count ?? -1))" }.joined(separator: "; "))
        let eels = manifest.cases.first { $0.name == "rsciio-example_velox_EELS_EDS" }
        prediction(4, "example_velox_EELS_EDS opens its 16 × 20 DF-S image",
                   eels.flatMap(opened).map { $0.height == 16 && $0.width == 20 && $0.source.hasSuffix("· DF-S") } ?? false,
                   eels.flatMap(opened).map { "\($0.height) × \($0.width), \($0.source)" } ?? "refused")
        let ffts = manifest.cases.filter { $0.name == "rsciio-FFTComplexEven" || $0.name == "rsciio-FFTComplexOdd" }
        prediction(5, "FFTComplexEven and FFTComplexOdd open the 128 × 128 HAADF",
                   ffts.count == 2 && ffts.allSatisfy { c in opened(c).map { $0.width == 128 && $0.height == 128 && $0.source.hasSuffix("· HAADF") } ?? false },
                   ffts.map { "\($0.name): " + (opened($0).map { "\($0.height) × \($0.width), \($0.source)" } ?? "refused") }.joined(separator: "; "))
        let nonVelox = manifest.cases.filter { $0.tag == "non-velox" }
        let complexFFT = manifest.cases.first { $0.name == "rsciio-fei_example_complex_fft" }
        let stillOpen = nonVelox.filter { opened($0) != nil }.map(\.name) + (complexFFT.flatMap(opened) != nil ? ["fei_example_complex_fft"] : [])
        prediction(6, "fei_example_complex_fft and the 14 non-Velox files are refused",
                   nonVelox.count == 14 && complexFFT != nil && stillOpen.isEmpty,
                   "\(nonVelox.count) non-Velox files and fei_example_complex_fft; opened: \(stillOpen)")
        let ceta = manifest.cases.filter { $0.tag == "ceta" }
        if ceta.isEmpty {
            print("  prediction 7: the owner's Ceta trio opens at its TIFF's scale and origin 1024.0 on both axes: not run (diagnostic; the files are not in References/example_files/)")
        } else {
            var detail: [String] = []
            var held = ceta.count == 3
            for c in ceta {
                guard let image = opened(c), let x = image.x, let y = image.y else { held = false; detail.append("\(c.name): refused"); continue }
                var line = "\(c.name): origin (\(x.origin), \(y.origin))"
                held = held && abs(x.origin - 1024) <= 1e-9 && abs(y.origin - 1024) <= 1e-9
                if let tiff = c.tiff, let t = try? ImageOpening.openNow(path: tiff), let tx = t.x, let ty = t.y {
                    let same = tx.scale.bitPattern == x.scale.bitPattern && ty.scale.bitPattern == y.scale.bitPattern
                    held = held && same
                    line += ", scale \(x.scale) \(x.unit) \(same ? "= its TIFF's" : "≠ its TIFF's \(tx.scale)"); the TIFF reader's origin (\(tx.origin), \(ty.origin))"
                } else {
                    held = false
                    line += ", no TIFF to compare"
                }
                detail.append(line)
            }
            prediction(7, "the owner's Ceta trio opens at its TIFF's scale and origin 1024.0 on both axes (diagnostic)", held,
                       detail.joined(separator: "; "), diagnostic: true)
        }

        print("  metadata  the detector the reader names equals RosettaSciIO's General.title on "
              + "\(manifest.cases.filter { $0.kind == "image" && $0.metadata?.rsciio != nil }.count - titleDifferences.count) of "
              + "\(manifest.cases.filter { $0.kind == "image" && $0.metadata?.rsciio != nil }.count) opened files"
              + (titleDifferences.isEmpty ? "" : "; it differs on \(titleDifferences.count) (not a check: the title is RosettaSciIO's own derivation, "
                 + "the Operations group's camera or DPC name, not BinaryResult.Detector):"))
        for line in titleDifferences { print("            \(line)") }
        print("  metadata  the date the reader shows equals RosettaSciIO's General.date and .time on every opened file it dates by AcquisitionStartDatetime"
              + (dateDifferences.isEmpty ? "" : "; RosettaSciIO also dates \(dateDifferences.count) file the stamp is absent from, from a CustomProperties timestamp (not a check):"))
        for line in dateDifferences { print("            \(line)") }
        for c in ceta {
            guard let tiff = c.tiff else { continue }
            let emd = AcquisitionMetadata.read(path: c.path), tif = AcquisitionMetadata.read(path: tiff)
            var equal: [String] = [], differ: [String] = [], oneSided: [String] = []
            for (field, text) in metadataFields {
                switch (text(emd), text(tif)) {
                case (let a?, let b?): if a == b { equal.append(field) } else { differ.append("\(field): .emd \(a), TIFF \(b)") }
                case (nil, nil): break
                default: oneSided.append(field)
                }
            }
            print("  diag  \(c.name) metadata against its paired TIFF's: equal [\(equal.joined(separator: ", "))]"
                  + (differ.isEmpty ? "" : "; DIFFER \(differ)") + (oneSided.isEmpty ? "" : "; read by one only [\(oneSided.joined(separator: ", "))]"))
        }

        let gated = manifest.cases.count - diagnostics
        let opens = manifest.cases.filter { $0.kind == "image" && !$0.diagnostic }.count
        if report.failures > 0 {
            print("velox-image-parity: \(report.failures) FAILURES in \(report.checks) checks (RosettaSciIO \(manifest.rsciio), h5py \(manifest.h5py))")
            exit(1)
        }
        print("velox-image-parity: all passed — \(gated) cases (\(opens) open, \(gated - opens) refused), \(report.checks) checks against the registered rule, "
              + "RosettaSciIO \(manifest.rsciio) and h5py \(manifest.h5py); \(diagnostics) diagnostic")
        print("velox-image-parity: largest differences from RosettaSciIO — scale \(measured.scaleRelative) relative, origin \(measured.origin) px")
    }
}
