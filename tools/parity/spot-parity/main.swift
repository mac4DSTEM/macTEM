// tools/parity/spot-parity/main.swift — the spot d-spacing (ImagoKit's `SpotMeasurement`, built from the checkout
// tools/lib/fetch-imagokit.sh pins, ADR 027; macTEM's seam compiled from tools/lib/sources.manifest group `spot`) against reference.py's numpy run of the same registered estimator and
// against each plant's d₀ (archive: roadmap-registrations-2026-10-15.md V1-6, "Slice C").
//
//     harness <out-dir-of-reference.py>
//
// Checks per case: snap (the snapped bin equals numpy's), centroid (within 1e-6 px of numpy's), d (|d − d₀|/d₀ below
// 0.2 % on the clean tier, 0.5 % on the noisy tier), flag (the neighbour flag equals numpy's), refusal (a near-DC
// spot is refused as nearDC).
//
// MACTEM_PARITY_MUTATE=<name> breaks the estimator on purpose; run.sh requires each to exit 1 with its named check among
// the failures: no-mean, no-hann, window-3x3, magnitude-weights, no-snap (centroid); one-spacing, qx-only (d). The first
// five break ImagoKit's estimator itself: run.sh compiles the harness against an edited copy of the kit's
// SpotMeasurement.swift (MACTEM_KIT_OVERRIDE, tools/lib/sources.manifest) and this file only accepts the name; the last
// two recompute d from the centroid as the broken code would. Unknown names exit 64.

import Foundation
import ImagoCore
import ImagoFFT

struct Manifest: Decodable {
    struct Case: Decodable {
        let name: String
        let input: String
        let width: Int
        let height: Int
        let scale_x: Double
        let scale_y: Double
        let units: String
        let click_row: Int
        let click_col: Int
        let kind: String
        let snapped_row: Int
        let snapped_col: Int
        let centroid_row: Double?
        let centroid_col: Double?
        let d: Double?
        let d0: Double
        let tier: String
        let neighbour: Bool
        let error: String?
    }
    let numpy: String
    let cases: [Case]
}

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

let mutations = ["no-mean", "no-hann", "window-3x3", "magnitude-weights", "no-snap", "one-spacing", "qx-only"]

@main
struct SpotParity {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else { print("usage: harness <reference out-dir>"); exit(64) }
        let out = URL(fileURLWithPath: CommandLine.arguments[1])
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: out.appendingPathComponent("manifest.json")))
        let mutation = ProcessInfo.processInfo.environment["MACTEM_PARITY_MUTATE"]
        if let mutation, !mutations.contains(mutation) {
            print("unknown MACTEM_PARITY_MUTATE '\(mutation)' (known: \(mutations.joined(separator: ", ")))")
            exit(64)
        }
        var report = Report()
        var errors: [String: [Double]] = [:]
        for c in manifest.cases {
            let before = report.failures
            let pixels = try Data(contentsOf: URL(fileURLWithPath: c.input)).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            let image = CalibratedImage(width: c.width, height: c.height, pixels: pixels,
                                        x: AxisCalibration(scale: c.scale_x, unit: c.units, origin: 0),
                                        y: AxisCalibration(scale: c.scale_y, unit: c.units, origin: 0),
                                        fileName: c.name, source: "spot-parity", voltage: nil)
            do {
                let m = try SpotMeasurement.measure(image.micrograph, clickRow: c.click_row, clickColumn: c.click_col)
                if c.kind == "refusal" {
                    report.check(false, "\(c.name) refusal", "measured d \(m.d); must be refused (\(c.error ?? "?"))")
                    continue
                }
                var d = m.d
                let i = m.centroidCol - Double(c.width / 2), j = m.centroidRow - Double(c.height / 2)
                if mutation == "one-spacing" {        // x's spacing for both axes
                    let qx = i / (Double(c.width) * c.scale_x), qy = j / (Double(c.height) * c.scale_x)
                    d = 1 / (qx * qx + qy * qy).squareRoot()
                }
                if mutation == "qx-only" { d = 1 / abs(i / (Double(c.width) * c.scale_x)) }
                report.check(m.snappedRow == c.snapped_row && m.snappedCol == c.snapped_col, "\(c.name) snap",
                             "(\(m.snappedRow), \(m.snappedCol)) vs (\(c.snapped_row), \(c.snapped_col))")
                let dr = abs(m.centroidRow - (c.centroid_row ?? .nan)), dc = abs(m.centroidCol - (c.centroid_col ?? .nan))
                report.check(dr <= 1e-6 && dc <= 1e-6, "\(c.name) centroid", "Δ (\(dr), \(dc)) px")
                let rel = abs(d - c.d0) / c.d0
                errors[c.tier, default: []].append(rel)
                let band = c.tier == "clean" ? 0.002 : 0.005
                report.check(rel < band, "\(c.name) d", "|d − d₀|/d₀ = \(rel) ≥ \(band)")
                report.check(m.neighbour == c.neighbour, "\(c.name) flag", "neighbour \(m.neighbour) vs \(c.neighbour)")
            } catch let failure as SpotMeasurementError {
                if c.kind == "refusal" {
                    let name = failure == .nearDC ? "nearDC" : failure == .nearEdge ? "nearEdge" : "\(failure)"
                    report.check(name == c.error, "\(c.name) refusal", "refused as \(failure), expected \(c.error ?? "?")")
                } else {
                    report.check(false, "\(c.name) d", "refused as \(failure)")
                }
            }
            if report.failures == before { print("  ok    \(c.name)") }
        }
        for (tier, e) in errors.sorted(by: { $0.key < $1.key }) {
            let s = e.sorted()
            print("  info  \(tier) tier: \(s.count) spots, |d − d₀|/d₀ max \(s.last!), median \(s[s.count / 2])")
        }
        if report.failures > 0 {
            print("spot-parity: \(report.failures) FAILURES in \(report.checks) checks (numpy \(manifest.numpy))")
            exit(1)
        }
        print("spot-parity: all passed — \(manifest.cases.count) cases, \(report.checks) checks against numpy \(manifest.numpy)")
    }
}
