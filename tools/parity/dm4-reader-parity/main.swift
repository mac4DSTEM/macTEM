// tools/parity/dm4-reader-parity/main.swift — macTEM's DM reader (`ImageOpening.openNow`, TEMCore, compiled in from
// tools/lib/sources.manifest group `dm`) against ncempy's reading of every case (reference.py's manifest).
//
//     harness <out-dir-of-reference.py>
//
// Pass band: EXACT. Every pixel equals ncempy's value cast to float32 (both sides round the same way, so a large
// uint32 rounds identically); each axis's scale has the same float32 bit pattern; origins are equal (−0 == 0);
// units are the same string (µ is U+00B5). A refused file must throw the named error, never read as something else.
//
// MACTEM_PARITY_MUTATE=<name> breaks the reader on purpose; run.sh requires each to exit 1 with the named check
// below among its failures: transpose (shape), swap-calibration (scale), units (units), pixel (pixels), origin-sign
// (origin) change an image's output; accept-mixed-units opens every REFUSED file by the object rule without its
// mixed-units clause, so the spectrum image reads (its refusal check); ignore-format opens every REFUSED file by the
// object rule without its Format clause, so the planted-si file (both axes nm) reads (its refusal check). An unknown name exits 64 before any case.

import ImagoCore
import Foundation
import FormatoCore
import FormatoDM

struct Manifest: Decodable {
    struct Axis: Decodable {
        let scale: Double
        let scale_bits: UInt32
        let origin: Double
        let units: String
    }
    struct Case: Decodable {
        let name: String
        let path: String
        let kind: String
        let width: Int?
        let height: Int?
        let x: Axis?
        let y: Axis?
        let pixels: String?
        let error: String?
        let source: String?
    }
    let ncempy: String
    let cases: [Case]
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

let mutations = ["transpose", "swap-calibration", "units", "pixel", "origin-sign", "accept-mixed-units", "ignore-format"]

func mutated(_ image: CalibratedImage, _ mutation: String?) -> CalibratedImage {
    guard let mutation, mutation != "accept-mixed-units", mutation != "ignore-format" else { return image }
    var pixels = image.pixels, x = image.x, y = image.y, width = image.width, height = image.height
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
        x = x.map { AxisCalibration(scale: $0.scale, unit: $0.unit, origin: -$0.origin) }
        y = y.map { AxisCalibration(scale: $0.scale, unit: $0.unit, origin: -$0.origin) }
    default:
        preconditionFailure("unknown mutation '\(mutation)' passed the check in main")
    }
    return CalibratedImage(width: width, height: height, pixels: pixels, x: x, y: y,
                           fileName: image.fileName, source: image.source, voltage: image.voltage)
}

/// The `accept-mixed-units` mutation: the object rule (`ImageOpening.primaryImageObject`) without its mixed-units
/// clause — the first object that is not the thumbnail and has exactly two dimensions larger than one, read as is.
/// A file with no such object goes through `openNow`, so only a refusal for mixed units can change.
func openIgnoringMixedUnits(path: String) throws -> CalibratedImage {
    try openByRule(path: path) { _ in true }
}

/// The `ignore-format` mutation: the object rule with its mixed-units clause but without its Format clause.
func openIgnoringFormat(path: String) throws -> CalibratedImage {
    try openByRule(path: path) { o in
        let big = o.dimensions.indices.filter { o.dimensions[$0] > 1 }
        guard big.count == 2, big.allSatisfy({ o.axes.indices.contains($0) }),
              let ux = o.axes[big[0]]?.units, let uy = o.axes[big[1]]?.units, !ux.isEmpty, !uy.isEmpty else { return true }
        return ux == uy
    }
}

func openByRule(path: String, _ extraClause: (DM4ImageObject) -> Bool) throws -> CalibratedImage {
    let objects = try DM4Experiment.list(path: path)
    guard let object = objects.first(where: {
        $0.role != .thumbnail && $0.dimensions.filter { $0 > 1 }.count == 2 && extraClause($0)
    }) else { return try ImageOpening.openNow(path: path) }
    return ImageOpening.calibratedImage(try DM4Experiment.readImage(path: path, index: object.index),
                                        fileName: formatoDisplayFileName(path))
}

func compare(_ name: String, _ got: AxisCalibration?, _ want: Manifest.Axis, _ report: inout Report) {
    guard let got else {
        report.check(false, name, "no calibration, ncempy reads scale \(want.scale) \(want.units)")
        return
    }
    report.check(Float(got.scale).bitPattern == want.scale_bits, "\(name) scale",
                 "\(Float(got.scale)) vs ncempy \(want.scale)")
    report.check(Float(got.origin) == Float(want.origin), "\(name) origin", "\(got.origin) vs ncempy \(want.origin)")
    report.check(got.unit == want.units, "\(name) units", "'\(got.unit)' vs ncempy '\(want.units)'")
}

@main
struct DM4ReaderParity {
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

        for c in manifest.cases {
            let before = report.failures
            switch c.kind {
            case "image":
                guard let width = c.width, let height = c.height, let x = c.x, let y = c.y, let file = c.pixels else {
                    report.check(false, c.name, "malformed manifest entry")
                    continue
                }
                let image: CalibratedImage
                do {
                    image = mutated(try ImageOpening.openNow(path: c.path), mutation)
                } catch {
                    report.check(false, c.name, "refused: \(error.localizedDescription)")
                    continue
                }
                report.check(image.width == width && image.height == height, "\(c.name) shape",
                             "\(image.width) × \(image.height) vs ncempy \(width) × \(height)")
                let want = try Data(contentsOf: out.appendingPathComponent(file)).withUnsafeBytes {
                    Array($0.bindMemory(to: Float.self))
                }
                let differing = zip(image.pixels, want).enumerated().filter { $0.element.0 != $0.element.1 }
                report.check(image.pixels.count == want.count && differing.isEmpty, "\(c.name) pixels",
                             "\(differing.count) of \(want.count) differ, first at index \(differing.first?.offset ?? -1)")
                if let source = c.source {
                    report.check(image.source == source, "\(c.name) object", "\(image.source) vs expected \(source)")
                }
                compare("\(c.name) x", image.x, x, &report)
                compare("\(c.name) y", image.y, y, &report)
            case "refused":
                let check = "\(c.name) refusal", want = c.error ?? "?"
                do {
                    let image: CalibratedImage
                    switch mutation {
                    case "accept-mixed-units": image = try openIgnoringMixedUnits(path: c.path)
                    case "ignore-format": image = try openIgnoringFormat(path: c.path)
                    default: image = try ImageOpening.openNow(path: c.path)
                    }
                    report.check(false, check, "read \(image.source) as \(image.width) × \(image.height); must be refused (\(want))")
                } catch let refusal as ImageOpening.Refusal {
                    if case .noImage = refusal {
                        report.check(want == "noImage", check, "refused as no image, expected \(want)")
                    } else {
                        report.check(false, check, "refused as \(refusal), expected \(want)")
                    }
                } catch DM4Error.unsupportedDataType(let type) {
                    report.check(want == "unsupportedDataType", check, "refused data type \(type), expected \(want)")
                } catch {
                    report.check(false, check, "refused with \(error), expected \(want)")
                }
            default:
                report.check(false, c.name, "unknown case kind '\(c.kind)'")
            }
            if report.failures == before { print("  ok    \(c.name)") }
        }

        if report.failures > 0 {
            print("dm4-reader-parity: \(report.failures) FAILURES in \(report.checks) checks (ncempy \(manifest.ncempy))")
            exit(1)
        }
        print("dm4-reader-parity: all passed — \(manifest.cases.count) cases, \(report.checks) checks against ncempy \(manifest.ncempy)")
    }
}
