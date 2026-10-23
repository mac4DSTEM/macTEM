// tools/parity/tiff-reader-parity/main.swift — macTEM's TIFF reader (`ImageOpening.openNow` → `TIFFImageReader`, TEMCore,
// compiled in from tools/lib/sources.manifest group `tiff`) against reference.py's reading of every case.
//
//     harness <out-dir-of-reference.py>
//
// Pass band: EXACT. Every pixel equals the reference's value as float32; each axis's scale and origin are the same
// float64; units the same string (µ is U+00B5); the notes the same strings in the same order. A refused file must
// throw the named refusal. A case marked `diagnostic` (the owner's files, an anisotropic FEI file RosettaSciIO
// mis-orders) is compared and printed but never fails the gate.
//
// MACTEM_PARITY_MUTATE=<name> breaks the reader on purpose; run.sh requires each to exit 1 with the named check among
// its failures: transpose (shape), swap-calibration (scale), units (units), pixel (pixels), origin-sign (origin),
// drop-notes (notes) change an image's output; accept-unequal-rgb reads an unequal-channel RGB file instead of
// refusing it (its refusal check). An unknown name exits 64 before any case.

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
    let rsciio: String
    let tifffile: String
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

let mutations = ["transpose", "swap-calibration", "units", "pixel", "origin-sign", "drop-notes", "accept-unequal-rgb"]

func mutated(_ image: CalibratedImage, _ mutation: String?) -> CalibratedImage {
    guard let mutation, mutation != "accept-unequal-rgb" else { return image }
    var pixels = image.pixels, x = image.x, y = image.y, width = image.width, height = image.height
    var notes = image.notes
    switch mutation {
    case "transpose":
        pixels = (0..<(width * height)).map { i in image.pixels[(i % height) * width + i / height] }
        swap(&width, &height)
    case "swap-calibration":
        swap(&x, &y)
    case "units":
        x = x.map { AxisCalibration(scale: $0.scale, unit: $0.unit + "x", origin: $0.origin) }
    case "pixel":
        pixels[pixels.count / 2] += 1
    case "origin-sign":
        x = x.map { AxisCalibration(scale: $0.scale, unit: $0.unit, origin: $0.origin == 0 ? 1 : -$0.origin) }
    case "drop-notes":
        notes = Array(notes.dropLast())
    default:
        preconditionFailure("unknown mutation '\(mutation)' passed the check in main")
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

func refusalName(_ refusal: TIFFImageReader.Refusal) -> String {
    switch refusal {
    case .notTIFF: "notTIFF"
    case .truncated: "truncated"
    case .multiPage: "multiPage"
    case .compressed: "compressed"
    case .tiled: "tiled"
    case .unequalChannels: "unequalChannels"
    case .sampleFormat: "sampleFormat"
    }
}

@main
struct TIFFReaderParity {
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
                    image = mutated(try ImageOpening.openNow(path: c.path), mutation)
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
                    let image: CalibratedImage
                    if mutation == "accept-unequal-rgb" {
                        let data = try Data(contentsOf: URL(fileURLWithPath: c.path))
                        image = try TIFFImageReader.read(data: data, fileName: c.name, acceptUnequalChannels: true)
                    } else {
                        image = try ImageOpening.openNow(path: c.path)
                    }
                    report.check(false, check, "read \(image.source) as \(image.width) × \(image.height); must be refused (\(want))")
                } catch let ImageOpening.Refusal.tiff(_, refusal) {
                    report.check(refusalName(refusal) == want, check, "refused as \(refusal), expected \(want)")
                } catch let refusal as TIFFImageReader.Refusal {
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
            print("tiff-reader-parity: \(report.failures) FAILURES in \(report.checks) checks (RosettaSciIO \(manifest.rsciio), tifffile \(manifest.tifffile))")
            exit(1)
        }
        print("tiff-reader-parity: all passed — \(manifest.cases.count - diagnostics) cases, \(report.checks) checks against RosettaSciIO \(manifest.rsciio) and tifffile \(manifest.tifffile); \(diagnostics) diagnostic")
    }
}
