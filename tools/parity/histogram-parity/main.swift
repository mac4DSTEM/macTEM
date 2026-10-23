// tools/parity/histogram-parity/main.swift — macTEM's IntensityHistogram (ImagoKit ImagoCore plus the app's default-bins extension, compiled in from tools/lib/sources.manifest
// groups `histogram` and `dm`) against numpy 2.5.4's `np.histogram(f, bins=96, range=(f.min(), f.max()))`,
// f = a[np.isfinite(a)], a float32 (reference.py's manifest).
//
//     harness open <out-dir>    opens every real image of <out>/plan.json through ImageOpening.openNow and writes the
//                               pixels it got to <out>/opened/<name>.f32 (reference.py then histograms the same values)
//     harness <out-dir>         the gate: every case of <out>/manifest.json
//
// Pass band (P1): counts equal bin for bin; numpy's edges equal and min and max equal (both bit for bit today; D12 would allow a
// written tolerance); the finite count equal; the mean within 1e-9 of the larger of |mean| and the mean of |pixel| (numpy sums pairwise, this blockwise;
// the scale keeps a mean near zero from large values of both signs from needing an impossible relative bar). Where numpy
// refuses the range ("Too many bins for data range") the histogram has no counts and no edges, its statistics still
// equal numpy's; with no finite pixel there is no histogram at all.
//
// MACTEM_PARITY_MUTATE=display-canvas feeds every case's NORMALISED pixels — ((p − min)/(max − min), what the display
// canvas holds) — instead of the raw ones; run.sh requires it to exit 1 with its check (`real-planted-2d.dm4 minimum`)
// among the failures. The other six controls edit a copy of the kit's IntensityHistogram.swift (five, via MACTEM_KIT_OVERRIDE) or the app extension (bins-95) (run.sh, `source_mutant`). An
// unknown name exits 64 before any case.

import Foundation
import ImagoCore

struct Plan: Decodable {
    struct Real: Decodable {
        let name: String
        let path: String
        let machine_local: Bool
    }
    let real: [Real]
}

struct Manifest: Decodable {
    struct Case: Decodable {
        let name: String
        let pixels: String
        let finite: Int
        let min_bits: UInt32?
        let max_bits: UInt32?
        let mean: Double?
        let mean_scale: Double?
        let refused: Bool?
        let counts: [Int]?
        let edges_bits: [UInt32]?
        let machine_local: Bool?
    }
    let numpy: String
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

let mutations = ["display-canvas"]

func readFloats(_ url: URL) throws -> [Float] {
    try Data(contentsOf: url).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
}

/// What the display canvas holds: each finite pixel as (p − min)/(max − min) in [0, 1]; a flat image is 0.
func displayCanvas(_ pixels: [Float]) -> [Float] {
    let finite = pixels.filter { $0.isFinite }
    guard let lo = finite.min(), let hi = finite.max(), hi > lo else { return pixels.map { $0.isFinite ? 0 : $0 } }
    return pixels.map { $0.isFinite ? ($0 - lo) / (hi - lo) : $0 }
}

func firstDifference(_ got: [Int], _ want: [Int]) -> String {
    guard got.count == want.count else { return "\(got.count) bins vs numpy \(want.count)" }
    let differing = zip(got, want).enumerated().filter { $0.element.0 != $0.element.1 }
    guard let first = differing.first else { return "equal" }
    return "\(differing.count) of \(want.count) bins differ; first: bin \(first.offset) holds \(first.element.0), numpy \(first.element.1)"
}

func bits(_ values: [Float]) -> [UInt32] { values.map { $0.bitPattern } }

func openReal(_ out: URL) throws -> Int32 {
    let plan = try JSONDecoder().decode(Plan.self, from: Data(contentsOf: out.appendingPathComponent("plan.json")))
    let dir = out.appendingPathComponent("opened")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    var failures = 0
    for r in plan.real {
        do {
            let image = try ImageOpening.openNow(path: r.path)
            let data = image.pixels.withUnsafeBytes { Data($0) }
            try data.write(to: dir.appendingPathComponent("\(r.name).f32"))
            print("  opened \(r.name): \(image.width) × \(image.height)")
        } catch {
            failures += 1
            print("  FAIL  \(r.name) opens: \(error.localizedDescription)")
        }
    }
    if failures > 0 {
        print("histogram-parity: \(failures) of \(plan.real.count) real images did not open")
        return 1
    }
    print("histogram-parity: opened \(plan.real.count) real images")
    return 0
}

@main
struct HistogramParity {
    static func main() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count == 1 || (args.count == 2 && args[0] == "open") else {
            print("usage: harness [open] <reference out-dir>")
            exit(64)
        }
        if args.count == 2 { exit(try openReal(URL(fileURLWithPath: args[1]))) }
        let out = URL(fileURLWithPath: args[0])
        let manifest = try JSONDecoder().decode(Manifest.self,
                                                from: Data(contentsOf: out.appendingPathComponent("manifest.json")))
        let mutation = ProcessInfo.processInfo.environment["MACTEM_PARITY_MUTATE"]
        if let mutation, !mutations.contains(mutation) {
            print("unknown MACTEM_PARITY_MUTATE '\(mutation)' (known: \(mutations.joined(separator: ", ")))")
            exit(64)
        }
        var report = Report()
        report.check(IntensityHistogram.binCount == 96, "bin count", "\(IntensityHistogram.binCount) bins, registered 96")

        var planted = 0, real = 0, owner = 0, refused = 0
        for c in manifest.cases {
            let before = report.failures
            if c.name.hasPrefix("real-") { real += 1 } else { planted += 1 }
            if c.machine_local == true { owner += 1 }
            var pixels = try readFloats(out.appendingPathComponent(c.pixels))
            if mutation == "display-canvas" { pixels = displayCanvas(pixels) }
            let start = ContinuousClock.now
            let h = IntensityHistogram.compute(pixels)
            let elapsed = start.duration(to: .now)

            guard c.finite > 0 else {
                report.check(h == nil, "\(c.name) no histogram",
                             "a histogram of \(h?.finiteCount ?? 0) pixels, numpy has no finite pixel")
                if report.failures == before { print("  ok    \(c.name)") }
                continue
            }
            guard let h, let minBits = c.min_bits, let maxBits = c.max_bits, let mean = c.mean,
                  let scale = c.mean_scale, let numpyRefused = c.refused else {
                report.check(false, "\(c.name) histogram", h == nil ? "nil, numpy has \(c.finite) finite pixels" : "malformed manifest entry")
                continue
            }
            report.check(h.finiteCount == c.finite, "\(c.name) finite count", "\(h.finiteCount) vs numpy \(c.finite)")
            report.check(h.minimum.bitPattern == minBits, "\(c.name) minimum",
                         "\(h.minimum) (0x\(String(h.minimum.bitPattern, radix: 16))) vs numpy \(Float(bitPattern: minBits)) (0x\(String(minBits, radix: 16)))")
            report.check(h.maximum.bitPattern == maxBits, "\(c.name) maximum",
                         "\(h.maximum) (0x\(String(h.maximum.bitPattern, radix: 16))) vs numpy \(Float(bitPattern: maxBits)) (0x\(String(maxBits, radix: 16)))")
            report.check(abs(h.mean - mean) <= 1e-9 * scale, "\(c.name) mean",
                         "\(h.mean) vs numpy \(mean): off by \(abs(h.mean - mean) / scale) of the mean magnitude")
            report.check(h.counts.isEmpty == numpyRefused, "\(c.name) refusal",
                         h.counts.isEmpty ? "no bins, numpy bins this range" : "binned, numpy refuses this range (Too many bins for data range)")
            if numpyRefused {
                refused += 1
                report.check(h.edges.isEmpty, "\(c.name) edges", "\(h.edges.count) edges for a refused range")
            } else if let counts = c.counts, let edgeBits = c.edges_bits {
                report.check(h.counts == counts, "\(c.name) counts", firstDifference(h.counts, counts))
                report.check(bits(h.edges) == edgeBits, "\(c.name) edges",
                             h.edges.count == edgeBits.count
                                ? "edge \(zip(bits(h.edges), edgeBits).enumerated().first { $0.element.0 != $0.element.1 }?.offset ?? -1) differs from numpy's bit pattern"
                                : "\(h.edges.count) edges vs numpy \(edgeBits.count)")
                report.check(h.counts.reduce(0, +) == h.finiteCount, "\(c.name) total", "\(h.counts.reduce(0, +)) counted of \(h.finiteCount)")
            } else {
                report.check(false, "\(c.name) histogram", "malformed manifest entry")
            }
            if report.failures == before {
                let ms = Double(elapsed.components.seconds) * 1e3 + Double(elapsed.components.attoseconds) * 1e-15
                print("  ok    \(c.name)" + (pixels.count >= 1 << 20 ? "  (\(pixels.count) pixels, compute \(String(format: "%.1f", ms)) ms)" : ""))
            }
        }

        if report.failures > 0 {
            print("histogram-parity: \(report.failures) FAILURES in \(report.checks) checks (numpy \(manifest.numpy))")
            exit(1)
        }
        print("histogram-parity: all passed — \(manifest.cases.count) cases (\(planted) planted, \(real) real of which \(owner) the owner's machine-local files; numpy refuses \(refused)), \(report.checks) checks against numpy \(manifest.numpy)")
    }
}
