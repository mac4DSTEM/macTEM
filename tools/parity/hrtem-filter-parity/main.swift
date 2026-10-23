// tools/parity/hrtem-filter-parity/main.swift — the HRTEM filters (ImagoKit's `HRTEMFilter`, built from the checkout
// tools/lib/fetch-imagokit.sh pins, ADR 027; macTEM's seam compiled from tools/lib/sources.manifest group `hrtem`) against reference.py's float64 reading of the same steps A1–A6 and the plants'
// truth, as archive: roadmap-registrations-2026-10-15.md "V1-6d HRTEM filters, third registration: the products gated" registers (the owner's choice, ADR 016).
// V1-6b's and V1-6c's checks are in git history (7c3cc89, 0d506f5).
//
//     harness <out-dir-of-reference.py>
//
// Checks (each failure "  FAIL  <case> <check>: …"), every case:
//   absf, wiener  within 1e-5 of the float64 output's maximum
//   W M a w       W-weighted, Σ|Δ|·W / Σ|x|·W over r > 0, within 1e-4 (W the float64 spectrum); undefined, and reported,
//                 where W off the DC is roundoff (Σ W over r > 0 below 1e-9 of the DC bin: the constant image)
//   dc            the ABSF output's mean over the input's within 1e-6 of the float64 reading's mask at the DC
//   flags         per bin and per pass: δ = 3 × the case's largest |Δc| over the disk on pass 1 (Swift against float64);
//                 at the first pass where any bin's state differs, every differing bin must have a float64 margin
//                 |c − (100 − t)| at or below δ on that pass; later passes are reported, not gated
//   energy        (the noisy tiers at the default parameters) the energy of each output inside the passband and outside
//                 ± 2 bins of every planted peak and its mirror (reference.py's region) below the input's
// Printed, never gated: pass 1's c deviation, the passes, the flag differences, every quantity's error, the energy ratios.
// The off-bin kept amplitudes and the Nyquist cut are printed by reference.py (the float64 reading).
//
// MACTEM_PARITY_ONLY=<name>[,…] runs only those cases. MACTEM_PARITY_MUTATE=<name> breaks the Swift OUTPUT on purpose (the
// filter's stages are held by the kit's own tests under real mutants):
//   absf-sign   the ABSF output negated                                                    → absf
//   dc-removed  the ABSF output's mean removed                                             → dc
//   flag-moved  one bin with no float64 margin under 5 points marked flagged on pass 1     → flags
//   a-scaled    the ABSF mask × 1.001                                                      → a
// Unknown names exit 64.

import Foundation
import ImagoCore
import ImagoFFT
import ImagoFilters

struct Manifest: Decodable {
    struct Params: Decodable, Equatable {
        let delta: Double
        let step: Double
        let cycles: Int
        let smoothing: Bool
        let order: Int
        let ro: Double
        let pct: Double
    }
    struct P2: Decodable {
        let energy_ratio_absf: Double?
        let energy_ratio_wiener: Double?
    }
    struct Case: Decodable {
        let name: String
        let tier: String
        let n: Int
        let params: Params
        let input: String
        let passes: Int
        let files: [String: String]
        let p2: P2?
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

let mutations = ["absf-sign", "dc-removed", "flag-moved", "a-scaled"]
let defaults = Manifest.Params(delta: 5, step: 2, cycles: 99, smoothing: true, order: 4, ro: 0.3, pct: 0)
let noisyTiers: Set<String> = ["bin", "offbin", "noise", "ramp", "nyquist", "offbin0", "offbin25", "offbin50"]

func readF64(_ url: URL) throws -> [Double] {
    let data = try Data(contentsOf: url)
    return data.withUnsafeBytes { Array($0.bindMemory(to: Double.self)) }
}

/// The energy Σ|FFT(x)|² over the bins `region` marks (numpy's unshifted frame: rows the y frequency, columns the x).
func energy(_ x: [Float], n: Int, region: [Double], fft: FFT2D) -> Double {
    var re = x
    var im = [Float](repeating: 0, count: n * n)
    fft.transform(re: &re, im: &im, forward: true)
    var e = 0.0
    for i in 0..<(n * n) where region[i] != 0 { e += Double(re[i]) * Double(re[i]) + Double(im[i]) * Double(im[i]) }
    return e
}

@main
struct Harness {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            print("usage: harness <out-dir-of-reference.py>")
            exit(64)
        }
        let dir = URL(fileURLWithPath: CommandLine.arguments[1])
        let environment = ProcessInfo.processInfo.environment
        let mutation = environment["MACTEM_PARITY_MUTATE"]
        if let mutation, !mutations.contains(mutation) {
            print("hrtem-filter-parity: unknown mutation '\(mutation)'")
            exit(64)
        }
        let only = environment["MACTEM_PARITY_ONLY"].map { Set($0.split(separator: ",").map(String.init)) }
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: dir.appendingPathComponent("manifest.json")))
        let cases = manifest.cases.filter { only?.contains($0.name) ?? true }
        guard !cases.isEmpty, only == nil || cases.count == only!.count else {
            print("hrtem-filter-parity: MACTEM_PARITY_ONLY names a case that does not exist")
            exit(64)
        }
        print("hrtem-filter-parity: \(cases.count) cases; reference numpy \(manifest.numpy), scipy \(manifest.scipy)\(mutation.map { "; MUTATION \($0)" } ?? "")")
        var report = Report()
        var energyRatios: [Double] = []

        for c in cases {
            let n = c.n, count = n * n, half = n / 2
            func ref(_ key: String) throws -> [Double] { try readF64(dir.appendingPathComponent(c.files[key]!)) }
            let input = try Data(contentsOf: dir.appendingPathComponent(c.input)).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            var p = HRTEMFilter.Parameters()
            p.delta = c.params.delta; p.step = c.params.step; p.cycles = c.params.cycles; p.smoothing = c.params.smoothing
            p.order = c.params.order; p.ro = c.params.ro; p.lowFrequencyPercent = c.params.pct
            let result = try HRTEMFilter.filter(pixels: input, width: n, height: n, parameters: p)
            func radius(_ i: Int) -> Double { let dr = Double(i / n - half), dc = Double(i % n - half); return (dr * dr + dc * dc).squareRoot() }

            var absf = result.absf.float32Values
            if mutation == "absf-sign" { absf = absf.map { -$0 } }
            if mutation == "dc-removed" { let m = absf.reduce(0.0) { $0 + Double($1) } / Double(count); absf = absf.map { Float(Double($0) - m) } }
            var absfMask = result.absfMask
            if mutation == "a-scaled" { absfMask = absfMask.map { $0 * 1.001 } }

            // Outputs.
            var outputText: [String] = []
            for (key, swift) in [("absf", absf), ("wiener", result.wiener.float32Values)] {
                let r = try ref(key)
                let peak = r.map(abs).max() ?? 0
                let worst = zip(swift, r).map { abs(Double($0) - $1) }.max() ?? 0
                report.check(worst <= 1e-5 * peak, "\(c.name) \(key)", String(format: "%.3e of the maximum", worst / peak))
                outputText.append(String(format: "%@ %.1e", key, worst / peak))
            }
            // Stages, W-weighted.
            let refW = try ref("W")
            let dcW = refW[half * n + half]
            let offDC = (0..<count).filter { radius($0) > 0 }
            let sumW = offDC.reduce(0.0) { $0 + refW[$1] }
            var stageText: [String] = []
            for (key, swift) in [("W", result.spectrum), ("M", result.background), ("a", absfMask), ("w", result.wienerMask)] {
                let r = try ref(key)
                if sumW < 1e-9 * dcW {
                    stageText.append("\(key) undefined (W off the DC is roundoff)")
                    continue
                }
                var num = 0.0, den = 0.0
                for i in offDC { num += abs(swift[i] - r[i]) * refW[i]; den += abs(r[i]) * refW[i] }
                let e = den > 0 ? num / den : 0
                stageText.append(String(format: "%@ %.1e", key, e))
                report.check(e <= 1e-4, "\(c.name) \(key)", String(format: "W-weighted %.3e", e))
            }
            // The DC.
            let refA = try ref("a")
            let meanIn = input.reduce(0.0) { $0 + Double($1) } / Double(count)
            let ratio = absf.reduce(0.0) { $0 + Double($1) } / Double(count) / meanIn
            let dcError = abs(ratio - refA[half * n + half])
            report.check(dcError <= 1e-6, "\(c.name) dc", String(format: "ABSF mean / input mean %.9f, float64 a(0) %.9f", ratio, refA[half * n + half]))

            // Flags, per bin and per pass.
            let refC1 = try ref("c1"), refS = try ref("S")
            var deltaC = 0.0
            if !result.firstPassC.isEmpty {
                for i in 0..<count where radius(i) < Double(half) && refS[i] > 0 { deltaC = max(deltaC, abs(result.firstPassC[i] - refC1[i])) }
            }
            let tolerance = 3 * deltaC
            var swiftFirst = result.firstFlaggedPass
            let refFirst = try ref("firstpass").map { Int($0) }
            let near = try ref("nearmargins")
            var margin: [Int: [Int: Double]] = [:]                    // pass → bin → float64 margin (< 5 points)
            for k in stride(from: 0, to: near.count, by: 3) { margin[Int(near[k]), default: [:]][Int(near[k + 1])] = near[k + 2] }
            if mutation == "flag-moved",
               let i = (0..<count).first(where: { refFirst[$0] == 0 && swiftFirst[$0] == 0 && radius($0) < Double(half) && refS[$0] > 0 && margin[1]?[$0] == nil }) {
                swiftFirst[i] = 1
            }
            var flagText = "no bin differs"
            for j in 1...max(1, min(result.passes, c.passes)) where result.passes > 0 && c.passes > 0 {
                let differing = (0..<count).filter { (1...j).contains(swiftFirst[$0]) != (1...j).contains(refFirst[$0]) }
                guard !differing.isEmpty else { continue }
                let unexplained = differing.filter { (margin[j]?[$0] ?? 5) > tolerance }
                report.check(unexplained.isEmpty, "\(c.name) flags",
                             String(format: "pass %d: %d bins differ, %d with a float64 margin above δ = %.3g points", j, differing.count, unexplained.count, tolerance))
                flagText = String(format: "first difference on pass %d: %d bins, all within δ = %.2g: %@", j, differing.count, tolerance, unexplained.isEmpty ? "yes" : "NO")
                break
            }

            // Energy outside the lattice bins (P2).
            var energyText = ""
            if noisyTiers.contains(c.tier), c.params == defaults, let regionFile = c.files["p2region"], let fft = FFT2D(nx: n, ny: n) {
                let region = try readF64(dir.appendingPathComponent(regionFile))
                let eIn = energy(input, n: n, region: region, fft: fft)
                let eA = energy(absf, n: n, region: region, fft: fft), eW = energy(result.wiener.float32Values, n: n, region: region, fft: fft)
                report.check(eA < eIn && eW < eIn, "\(c.name) energy", String(format: "ABSF %.3f, Wiener %.3f of the input's", eA / eIn, eW / eIn))
                energyRatios += [eA / eIn, eW / eIn]
                energyText = String(format: "; energy outside the lattice: ABSF %.3f, Wiener %.3f of the input's", eA / eIn, eW / eIn)
            }
            print(String(format: "  case  %@: passes %d/%d, c1 Δ %.2e points; %@; %@; %@%@",
                         c.name, result.passes, c.passes, deltaC, outputText.joined(separator: ", "),
                         stageText.joined(separator: ", "), flagText, energyText))
        }
        if !energyRatios.isEmpty {
            print(String(format: "  info  energy outside the lattice bins, both outputs, the noisy tiers at the defaults: %.3f to %.3f of the input's",
                         energyRatios.min()!, energyRatios.max()!))
        }
        if report.failures > 0 {
            print("hrtem-filter-parity: \(report.failures) FAILURES in \(report.checks) checks")
            exit(1)
        }
        print("hrtem-filter-parity: all passed — \(report.checks) checks over \(cases.count) cases")
    }
}
