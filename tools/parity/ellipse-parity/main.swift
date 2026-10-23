// tools/parity/ellipse-parity/main.swift — macTEM's ring/ellipse fit (`EllipseCalibration.fit1D`, DiffractoKit's DiffractoGeometry since ADR 025 (the kit's file is mac4DSTEM 7d6fdbd1's, bit for bit)
// from mac4DSTEM 5b696589, compiled in from tools/lib/sources.manifest group `ellipse`) against the plant of
// make_fixture.py and reference.py's numpy/scipy optimum of the same registered objective (archive: roadmap-registrations-2026-10-15.md V1-7, "S2").
//
//     harness <out-dir-of-reference.py>
//
// Convention: the fit's "qx" is the ROW and "qy" the COLUMN; DiffractionPattern(width: columns, height: rows, pixels:).
//
// Checks, clean tier (P1; every one a FAIL line "  FAIL  <case> <check>: …"):
//   centre    both coordinates within 0.05 px of the plant's          (registered)
//   radius    |(a + b)/2 − R| / R at most 0.05 %                      (registered)
//   axes      |a − a₀|/a₀ and |b − b₀|/b₀ at most 0.05 %              (NOT registered: the radius band applied to the axes)
//   theta     the angle (mod π) within 2° of the plant's, ε > 0 only  (NOT registered: the largest numpy optimum error
//                                                                      measured on the clean tier was 1.2°)
//   coverage  the occupied-bin count and the annulus pixel count equal reference.py's, exactly
// Noisy tier: no check; the distribution of the same quantities is printed (the registration bands it after measuring).
// Refusals (P2): the thrown FitError's name (and, for coverage, its bin count) equals the plant's.
// Printed, never gated: the Swift fit against the scipy optimum of the same objective.
//
// MACTEM_PARITY_MUTATE=<name> breaks the OUTPUT (or emulates a missing input) on purpose; run.sh requires each to exit 1
// with its named check among the failures: xy-swap (centre), ab-swap (axes), theta-sign (theta), mean-radius-major
// (radius). no-weight is an EMULATION: the weight is inside the verbatim copy and cannot be dropped from here, so the
// output becomes what the unweighted objective minimises over the annulus — its centre, the circle R² = Σr⁴/Σr² (centre
// at the start, a = b, θ = 0) — and is caught by centre. Unknown names exit 64.

import Foundation
import DiffractoGeometry

struct Manifest: Decodable {
    struct Ref: Decodable {
        let row: Double
        let col: Double
        let a: Double
        let b: Double
        let theta: Double
        let residual: Double
    }
    struct Case: Decodable {
        let name: String
        let input: String
        let tier: String
        let kind: String
        let error: String?
        let rows: Int
        let cols: Int
        let r0: Double
        let c0: Double
        let R: Double
        let a: Double
        let b: Double
        let theta: Double?
        let eps: Double
        let noise: Double
        let gap_deg: Double
        let inner: Double
        let outer: Double
        let guess_row: Double
        let guess_col: Double
        let samples: Int
        let occupied: Int
        let ref: Ref?
    }
    let numpy: String
    let scipy: String
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

let mutations = ["xy-swap", "ab-swap", "theta-sign", "mean-radius-major", "no-weight"]

func angleError(_ x: Double, _ y: Double) -> Double {
    let d = abs(x - y).truncatingRemainder(dividingBy: .pi)
    return min(d, .pi - d)
}

func errorName(_ e: EllipseCalibration.FitError) -> String {
    let text = String(describing: e)
    return String(text.prefix { $0 != "(" })
}

func quantile(_ sorted: [Double], _ q: Double) -> Double {
    guard !sorted.isEmpty else { return .nan }
    return sorted[min(sorted.count - 1, Int(q * Double(sorted.count - 1) + 0.5))]
}

func fmt(_ x: Double) -> String { String(format: "%.4f", x) }

/// A fit's numbers after the deliberate mistake, if any.
struct Numbers {
    var row: Double, col: Double, a: Double, b: Double, theta: Double
    var radius: Double
}

func mutated(_ fit: EllipseCalibrationFit, _ c: Manifest.Case, _ pixels: [Float], _ mutation: String?) -> Numbers {
    var n = Numbers(row: fit.centerQX, col: fit.centerQY, a: fit.a, b: fit.b, theta: fit.theta, radius: (fit.a + fit.b) / 2)
    switch mutation {
    case "xy-swap": swap(&n.row, &n.col)
    case "ab-swap": swap(&n.a, &n.b)
    case "theta-sign":
        n.theta = (.pi - n.theta).truncatingRemainder(dividingBy: .pi)
    case "mean-radius-major": n.radius = n.a
    case "no-weight":
        var r4 = 0.0, r2 = 0.0
        for row in 0..<c.rows {
            let dx = Double(row) - c.guess_row
            for col in 0..<c.cols {
                let dy = Double(col) - c.guess_col
                let r = hypot(dx, dy)
                guard r > c.inner, r <= c.outer, pixels[row * c.cols + col].isFinite else { continue }
                r4 += r * r * r * r
                r2 += r * r
            }
        }
        let radius = (r4 / r2).squareRoot()
        n = Numbers(row: c.guess_row, col: c.guess_col, a: radius, b: radius, theta: 0, radius: radius)
    default: break
    }
    return n
}

@main
struct EllipseParity {
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
        // Per-case measured errors: (tier, noise, gap, eps, R, centre, signed radius %, axes, theta°)
        struct Row { let tier: String; let noise: Double; let gap: Double; let eps: Double; let R: Double
                     let centre: Double; let radiusPct: Double; let axesPct: Double; let thetaDeg: Double? }
        var rows: [Row] = []
        var refused: [String: [String]] = [:]       // noisy-tier refusals by group
        var agreement: [(Double, Double, Double)] = []
        for c in manifest.cases {
            let before = report.failures
            let pixels = try Data(contentsOf: URL(fileURLWithPath: c.input)).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            let pattern = DiffractionPattern(width: c.cols, height: c.rows, pixels: pixels)
            do {
                let fit = try EllipseCalibration.fit1D(pattern: pattern, centerQX: c.guess_row, centerQY: c.guess_col,
                                                       innerRadius: c.inner, outerRadius: c.outer)
                if c.kind == "refusal" {
                    report.check(false, "\(c.name) refusal", "fitted (a \(fit.a), b \(fit.b)); must be refused as \(c.error ?? "?")")
                    continue
                }
                let n = mutated(fit, c, pixels, mutation)
                let centre = max(abs(n.row - c.r0), abs(n.col - c.c0))
                let radiusErr = (n.radius - c.R) / c.R
                let axesErr = max(abs(n.a - c.a) / c.a, abs(n.b - c.b) / c.b)
                let thetaErr = c.theta.map { angleError(n.theta, $0) * 180 / .pi }
                rows.append(Row(tier: c.tier, noise: c.noise, gap: c.gap_deg, eps: c.eps, R: c.R, centre: centre,
                                radiusPct: 100 * radiusErr, axesPct: 100 * axesErr, thetaDeg: thetaErr))
                if let ref = c.ref {
                    agreement.append((max(abs(fit.centerQX - ref.row), abs(fit.centerQY - ref.col)),
                                      max(abs(fit.a - ref.a) / ref.a, abs(fit.b - ref.b) / ref.b),
                                      c.theta == nil ? 0 : angleError(fit.theta, ref.theta) * 180 / .pi))
                }
                report.check(fit.occupiedAngularBins == c.occupied && fit.sampleCount == c.samples, "\(c.name) coverage",
                             "bins \(fit.occupiedAngularBins) vs \(c.occupied), samples \(fit.sampleCount) vs \(c.samples)")
                guard c.tier == "clean" else { continue }
                report.check(centre <= 0.05, "\(c.name) centre", "max |Δ| \(centre) px (row \(n.row - c.r0), col \(n.col - c.c0))")
                report.check(abs(radiusErr) <= 5e-4, "\(c.name) radius", "(a + b)/2 = \(n.radius) vs \(c.R): \(100 * radiusErr) %")
                report.check(axesErr <= 5e-4, "\(c.name) axes", "a \(n.a) vs \(c.a), b \(n.b) vs \(c.b): \(100 * axesErr) %")
                if let t = thetaErr { report.check(t <= 2.0, "\(c.name) theta", "θ \(n.theta * 180 / .pi)° vs \(c.theta! * 180 / .pi)°: Δ \(t)°") }
            } catch let failure as EllipseCalibration.FitError {
                if c.kind == "refusal" {
                    var ok = errorName(failure) == c.error
                    if case .insufficientAngularCoverage(let bins) = failure { ok = ok && bins == c.occupied }
                    report.check(ok, "\(c.name) refusal", "refused as \(failure), expected \(c.error ?? "?") (\(c.occupied) bins)")
                } else if c.tier == "noisy" {
                    refused["noise \(Int(100 * c.noise + 0.5)) % gap \(Int(c.gap_deg))", default: []].append("\(c.name): \(errorName(failure))")
                } else {
                    report.check(false, "\(c.name) fit", "refused as \(failure)")
                }
            }
            if report.failures == before, c.tier != "noisy" { print("  ok    \(c.name)") }
        }

        // The distributions. Printed, never gated, on the noisy tier.
        func line(_ label: String, _ r: [Row]) {
            guard !r.isEmpty else { return }
            let centre = r.map(\.centre).sorted()
            let signed = r.map(\.radiusPct)
            let absRadius = signed.map(abs).sorted()
            let axes = r.map(\.axesPct).sorted()
            let theta = r.compactMap(\.thetaDeg).sorted()
            let thetaText = theta.isEmpty ? "θ n/a" : "θ° med \(fmt(quantile(theta, 0.5))) max \(fmt(theta.last!))"
            print("  info  \(label): n \(r.count)  centre px med \(fmt(quantile(centre, 0.5))) p90 \(fmt(quantile(centre, 0.9))) max \(fmt(centre.last!))"
                  + "  radius % mean \(fmt(signed.reduce(0, +) / Double(signed.count))) max|·| \(fmt(absRadius.last!))"
                  + "  axes % max \(fmt(axes.last!))  \(thetaText)")
        }
        let clean = rows.filter { $0.tier == "clean" }
        for R in Set(clean.map(\.R)).sorted() { line("clean R \(Int(R))", clean.filter { $0.R == R }) }
        line("clean all", clean)
        let noisy = rows.filter { $0.tier == "noisy" }
        for noise in [0.03, 0.10] {
            for gap in [0.0, 60.0] {
                for eps in [0.0, 0.01, 0.03] {
                    line("noisy \(Int(noise * 100 + 0.5)) % gap \(Int(gap)) ε \(Int(eps * 100 + 0.5)) %",
                         noisy.filter { $0.noise == noise && $0.gap == gap && $0.eps == eps })
                }
            }
            line("noisy \(Int(noise * 100 + 0.5)) % all", noisy.filter { $0.noise == noise })
        }
        for R in Set(noisy.map(\.R)).sorted() { line("noisy R \(Int(R))", noisy.filter { $0.R == R }) }
        let noisyCount = manifest.cases.filter { $0.tier == "noisy" }.count
        print("  info  noisy tier: \(noisyCount - noisy.count) of \(noisyCount) refused")
        for (k, v) in refused.sorted(by: { $0.key < $1.key }) { print("  info    \(k): \(v.count) refused, e.g. \(v[0])") }
        if !agreement.isEmpty {
            print("  info  Swift vs scipy optimum of the same objective, \(agreement.count) fits: centre max \(agreement.map { $0.0 }.max()!) px,"
                  + " axes max \(agreement.map { $0.1 }.max()!) (relative), θ max \(agreement.map { $0.2 }.max()!)°")
        }
        if report.failures > 0 {
            print("ellipse-parity: \(report.failures) FAILURES in \(report.checks) checks (numpy \(manifest.numpy), scipy \(manifest.scipy))")
            exit(1)
        }
        print("ellipse-parity: all passed — \(manifest.cases.count) cases, \(report.checks) checks against the plant, numpy \(manifest.numpy), scipy \(manifest.scipy)")
    }
}
