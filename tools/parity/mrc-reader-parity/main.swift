// tools/parity/mrc-reader-parity/main.swift — macTEM's MRC reader (`ImageOpening.openNow` → `MRCImageReader`, TEMCore,
// compiled in from tools/lib/sources.manifest group `mrc`) against reference.py's (mrcfile's) reading of every case.
//
//     harness <out-dir-of-reference.py>
//
// Pass band: EXACT. Every pixel equals the reference's value as float32; each axis's scale and origin are the same
// float64 (the float32 voxel size, widened); units the same string (Å is U+00C5); the notes the same strings in the
// same order. A refused file must throw the named refusal. A case marked `diagnostic` is compared and printed but
// never fails the gate.
//
// MACTEM_PARITY_MUTATE=<name> breaks the reader on purpose; run.sh requires each to exit 1 with the named check among
// its failures: transpose (shape), mode0-unsigned and ignore-nsymbt (pixels), ignore-stamp (the big-endian
// case's read: its header no longer parses), scale-from-my (scale),
// drop-nonpositive (notes) change an image's output, recomputed here from the file's own bytes the way the broken
// reader would; accept-stack reads a stack's first image instead of refusing it (its refusal check). An unknown name
// exits 64 before any case.

import ImagoCore
import Foundation

struct Manifest: Decodable {
    struct Axis: Decodable {
        let scale: Double
        let origin: Double
        let units: String
    }
    struct Case: Decodable {
        let name: String
        let path: String
        let kind: String
        let reference: String
        let width: Int?
        let height: Int?
        let x: Axis?
        let y: Axis?
        let pixels: String?
        let notes: [String]
        let error: String?
        let diagnostic: Bool
    }
    let mrcfile: String
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

let mutations = ["transpose", "mode0-unsigned", "ignore-stamp", "ignore-nsymbt", "scale-from-my", "drop-nonpositive",
                 "accept-stack"]

/// The image a broken reader would return. Pixel mutations rewrite the bytes the reader sees, so the real reader runs
/// on them: mode 0 re-read unsigned (the bytes' sign bit set → +256), the stamp forced little-endian, the extended
/// header length zeroed.
func mutated(_ path: String, _ mutation: String?) throws -> CalibratedImage {
    var data = try Data(contentsOf: URL(fileURLWithPath: path))
    let name = URL(fileURLWithPath: path).lastPathComponent
    switch mutation {
    case "ignore-stamp":
        if data.count >= 216 { data.replaceSubrange(212..<214, with: [0x44, 0x44]) }
        return try MRCImageReader.read(data: data, fileName: name)
    case "ignore-nsymbt":
        if data.count >= 96 { data.replaceSubrange(92..<96, with: [0, 0, 0, 0]) }
        return try MRCImageReader.read(data: data, fileName: name)
    case "accept-stack":
        return try MRCImageReader.read(data: data, fileName: name, acceptStacks: true)
    default: break
    }
    let image = try ImageOpening.openNow(path: path)
    var pixels = image.pixels, x = image.x, y = image.y, width = image.width, height = image.height
    var notes = image.notes
    switch mutation {
    case nil: return image
    case "transpose":
        pixels = (0..<(width * height)).map { i in image.pixels[(i % height) * width + i / height] }
        swap(&width, &height)
    case "mode0-unsigned":
        if image.source.contains("mode 0 ") { pixels = pixels.map { $0 < 0 ? $0 + 256 : $0 } }
    case "scale-from-my":
        x = y.map { AxisCalibration(scale: $0.scale, unit: $0.unit, origin: $0.origin) }
    case "drop-nonpositive":
        notes = []
    default:
        preconditionFailure("unknown mutation '\(mutation!)' passed the check in main")
    }
    return CalibratedImage(width: width, height: height, pixels: pixels, x: x, y: y, fileName: image.fileName,
                           source: image.source, voltage: image.voltage, notes: notes)
}

func compare(_ name: String, _ got: AxisCalibration?, _ want: Manifest.Axis?, _ report: inout Report) {
    guard let want else {
        report.check(got == nil, "\(name) scale", "calibrated \(String(describing: got)); the reference reads none")
        return
    }
    guard let got else {
        report.check(false, "\(name) scale", "no calibration; the reference reads \(want.scale) \(want.units)")
        return
    }
    report.check(got.scale.bitPattern == want.scale.bitPattern, "\(name) scale", "\(got.scale) vs \(want.scale)")
    report.check(got.origin == want.origin, "\(name) origin", "\(got.origin) vs \(want.origin)")
    report.check(got.unit == want.units, "\(name) units", "'\(got.unit)' vs '\(want.units)'")
}

func refusalName(_ refusal: MRCImageReader.Refusal) -> String {
    switch refusal {
    case .notMRC: "notMRC"
    case .byteOrder: "byteOrder"
    case .stack: "stack"
    case .mode: "mode"
    case .axisOrder: "axisOrder"
    case .truncated: "truncated"
    }
}

@main
struct MRCReaderParity {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            print("usage: harness <reference out-dir>")
            exit(64)
        }
        let out = URL(fileURLWithPath: CommandLine.arguments[1])
        let manifest = try JSONDecoder().decode(Manifest.self,
                                                from: Data(contentsOf: out.appendingPathComponent("manifest.json")))
        let mutation = ProcessInfo.processInfo.environment["MACTEM_PARITY_MUTATE"]
        if let mutation, !mutations.contains(mutation) {
            print("unknown MACTEM_PARITY_MUTATE '\(mutation)' (known: \(mutations.joined(separator: ", ")))")
            exit(64)
        }
        var report = Report()
        var diagnostics = 0

        for c in manifest.cases {
            report.diagnostic = c.diagnostic
            if c.diagnostic { diagnostics += 1 }
            let before = report.failures
            switch c.kind {
            case "image":
                guard let width = c.width, let height = c.height, let file = c.pixels else {
                    report.check(false, c.name, "malformed manifest entry")
                    continue
                }
                let image: CalibratedImage
                do {
                    image = try mutated(c.path, mutation)
                } catch {
                    report.check(false, "\(c.name) read", "refused: \(error.localizedDescription)")
                    continue
                }
                report.check(image.width == width && image.height == height, "\(c.name) shape",
                             "\(image.width) × \(image.height) vs \(width) × \(height)")
                let want = try Data(contentsOf: URL(fileURLWithPath: file)).withUnsafeBytes {
                    Array($0.bindMemory(to: Float.self))
                }
                let differing = zip(image.pixels, want).enumerated().filter { $0.element.0.bitPattern != $0.element.1.bitPattern }
                report.check(image.pixels.count == want.count && differing.isEmpty, "\(c.name) pixels",
                             "\(differing.count) of \(want.count) differ, first at index \(differing.first?.offset ?? -1)")
                compare("\(c.name) x", image.x, c.x, &report)
                compare("\(c.name) y", image.y, c.y, &report)
                report.check(image.notes == c.notes, "\(c.name) notes", "\(image.notes) vs \(c.notes)")
            case "refusal":
                let check = "\(c.name) refusal", want = c.error ?? "?"
                do {
                    let image = try mutated(c.path, mutation)
                    report.check(false, check, "read \(image.source) as \(image.width) × \(image.height); must be refused (\(want))")
                } catch let ImageOpening.Refusal.mrc(_, refusal) {
                    report.check(refusalName(refusal) == want, check, "refused as \(refusal), expected \(want)")
                } catch let refusal as MRCImageReader.Refusal {
                    report.check(refusalName(refusal) == want, check, "refused as \(refusal), expected \(want)")
                } catch {
                    report.check(false, check, "refused with \(error), expected \(want)")
                }
            default:
                report.check(false, c.name, "unknown case kind '\(c.kind)'")
            }
            if report.failures == before { print("  \(c.diagnostic ? "diag" : "ok  ")  \(c.name)") }
        }

        if report.failures > 0 {
            print("mrc-reader-parity: \(report.failures) FAILURES in \(report.checks) checks (mrcfile \(manifest.mrcfile))")
            exit(1)
        }
        print("mrc-reader-parity: all passed — \(manifest.cases.count - diagnostics) cases, \(report.checks) checks against mrcfile \(manifest.mrcfile); \(diagnostics) diagnostic")
    }
}
