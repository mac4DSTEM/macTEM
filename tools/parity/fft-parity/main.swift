// tools/parity/fft-parity/main.swift — the centred spectrum, radial profile and masked inverse (ImagoKit's `PowerSpectrum`,
// `RadialProfile`, `MaskedInverseFFT` and `Micrograph.cropped`, built from the checkout tools/lib/fetch-imagokit.sh pins;
// macTEM's `CalibratedImage` and its `.micrograph` seam, compiled in from tools/lib/sources.manifest group `fft`) against reference.py's numpy 2.5.4 reading of every case.
//
//     harness <out-dir-of-reference.py>
//
// Pass bands (archive: roadmap-registrations-2026-10-15.md V1-6, slice A): magnitude and power each within 1e-5 of their own maximum; the frequency axes
// bit-equal to numpy's fftshift(fftfreq(n, d)); every bin-centred planted peak a local maximum at numpy's index; a
// crop's pixels and shifted origins equal to the crop numpy made, and its spectrum bit-equal to the spectrum of that
// cropped image. Weak bins (below 1e-3 of the maximum) are measured and printed, never gated: the band is relative to
// the maximum.
//
// MACTEM_PARITY_MUTATE=<name> breaks the result on purpose; run.sh requires each to exit 1 with its named check
// among the failures: no-shift (magnitude), shift-odd (ifftshift's (n + 1)/2 centre: magnitude, on an odd size), x-scale-both (axis_y),
// power-is-magnitude (power), fftfreq-n-minus-1 (axis_x), crop-origin (crop). An unknown name exits 64.

import Foundation
import ImagoCore
import ImagoFFT

struct Manifest: Decodable {
    struct Crop: Decodable { let row: Int; let col: Int; let height: Int; let width: Int }
    struct Spot: Decodable { let kx: Double; let ky: Double; let r: Double; let e: Double }
    struct Case: Decodable {
        let kind: String?
        let bin_width: Double?
        let bin_width_given: Double?
        let ring_bin: Int?
        let spots: [Spot]?
        let imag_max: Double?
        let real_max: Double?
        let name: String
        let input: String
        let width: Int
        let height: Int
        let scale_x: Double
        let scale_y: Double
        let units: String
        let crop: Crop?
        let out_width: Int
        let out_height: Int
        let magnitude: String?
        let power: String?
        let axis_x: String?
        let axis_y: String?
        let axis_units: String?
        let peaks: [[Int]]?
        let crop_of: String?
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

let mutations = ["no-shift", "shift-odd", "x-scale-both", "power-is-magnitude", "fftfreq-n-minus-1", "crop-origin",
                 "profile-pixel-bins", "profile-dqx-both", "profile-round", "profile-drop-dc", "profile-sum", "profile-ring-scale",
                 "ifft-no-friedel", "ifft-hard-edge", "ifft-partner-off", "ifft-unscaled"]

func int64s(_ path: String) throws -> [Int] {
    try Data(contentsOf: URL(fileURLWithPath: path)).withUnsafeBytes { Array($0.bindMemory(to: Int64.self)).map(Int.init) }
}

/// The profile a broken implementation would give, recomputed here from the same spectrum (the controls only).
func brokenProfile(_ s: PowerSpectrum, width: Double?, _ mutation: String) -> (mean: [Double], count: [Int]) {
    var dqx = s.spacingX, dqy = s.spacingY
    if mutation == "profile-pixel-bins" { dqx = 1; dqy = 1 }
    if mutation == "profile-dqx-both" { dqy = dqx }
    let wb = mutation == "profile-pixel-bins" ? 1 : (width ?? max(dqx, dqy))
    var sums: [Double] = [], counts: [Int] = []
    for r in 0..<s.height { for c in 0..<s.width {
        if mutation == "profile-drop-dc", r == s.height / 2, c == s.width / 2 { continue }
        let qx = Double(c - s.width / 2) * dqx, qy = Double(r - s.height / 2) * dqy
        let q = (qx * qx + qy * qy).squareRoot() / wb
        let k = Int(mutation == "profile-round" ? q.rounded() : q)
        while sums.count <= k { sums.append(0); counts.append(0) }
        sums[k] += s.power[r * s.width + c]; counts[k] += 1
    } }
    let mean = mutation == "profile-sum" ? sums : zip(sums, counts).map { $1 > 0 ? $0 / Double($1) : 0 }
    return (mean, counts)
}

func floats(_ path: String) throws -> [Float] {
    try Data(contentsOf: URL(fileURLWithPath: path)).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
}
func doubles(_ path: String) throws -> [Double] {
    try Data(contentsOf: URL(fileURLWithPath: path)).withUnsafeBytes { Array($0.bindMemory(to: Double.self)) }
}

/// Rolls a row-major w × h array by (dr, dc), wrapping: out[r][c] = in[(r − dr) mod h][(c − dc) mod w].
func roll(_ a: [Float], _ w: Int, _ h: Int, rows dr: Int, cols dc: Int) -> [Float] {
    var out = a
    for r in 0..<h { for c in 0..<w { out[r * w + c] = a[((r - dr) % h + h) % h * w + ((c - dc) % w + w) % w] } }
    return out
}

func image(_ c: Manifest.Case, pixels: [Float], width: Int, height: Int, origin: (Double, Double) = (0, 0)) -> CalibratedImage {
    let x = c.units.isEmpty ? nil : AxisCalibration(scale: c.scale_x, unit: c.units, origin: origin.0)
    let y = c.units.isEmpty ? nil : AxisCalibration(scale: c.scale_y, unit: c.units, origin: origin.1)
    return CalibratedImage(width: width, height: height, pixels: pixels, x: x, y: y,
                           fileName: c.name, source: "fft-parity", voltage: nil)
}

@main
struct FFTParity {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else { print("usage: harness <reference out-dir>"); exit(64) }
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
            let input = image(c, pixels: try floats(c.input), width: c.width, height: c.height)
            if c.kind == "profile" {
                let s = try PowerSpectrum.compute(input.micrograph)
                guard let got = try? RadialProfile.compute(s, width: c.bin_width_given) else {
                    report.check(false, "\(c.name) profile", "no profile (width or units refused)"); continue
                }
                var mean = got.mean, count = got.count
                if mutation == "profile-ring-scale" {
                    mean = mean.enumerated().map { $0.offset == 0 ? $0.element : $0.element * 1.001 }
                } else if let mutation, mutation.hasPrefix("profile-") {
                    (mean, count) = brokenProfile(s, width: c.bin_width_given, mutation)
                }
                let want = try doubles(out.appendingPathComponent("\(c.name).pmean.f64").path)
                let wantCount = try int64s(out.appendingPathComponent("\(c.name).pcount.i64").path)
                let peak = want.max() ?? 0
                let worst = mean.count == want.count ? zip(mean, want).map { abs($0 - $1) }.max() ?? 0 : .infinity
                report.check(worst <= 1e-5 * peak, "\(c.name) profile", "\(mean.count) vs \(want.count) bins, max |Δ| \(worst) > 1e-5 × \(peak)")
                // The registered band is relative to the maximum, the DC bin, up to ~10⁶ × a ring; this second band is
                // relative to the largest NON-DC bin, which a ring sets (added after the Gate B review; measured first:
                // 4e-8 to 3.7e-7 on these cases, 2026-10-12).
                let ringTop = want.dropFirst().max() ?? 0
                let worstAway = mean.count == want.count ? zip(mean, want).dropFirst().map { abs($0 - $1) }.max() ?? 0 : .infinity
                report.check(worstAway <= 1e-5 * ringTop, "\(c.name) profile-away",
                             "max |Δ| over bins ≥ 1 is \(worstAway / ringTop) of the largest of them, > 1e-5")
                report.check(count == wantCount, "\(c.name) counts", "\(count.prefix(4)) vs \(wantCount.prefix(4))")
                report.check(got.width.bitPattern == (c.bin_width ?? .nan).bitPattern, "\(c.name) width", "\(got.width) vs \(String(describing: c.bin_width))")
                let ring = mean.indices.dropFirst().max { mean[$0] < mean[$1] }
                report.check(ring == c.ring_bin, "\(c.name) ring", "peak bin \(String(describing: ring)) vs \(String(describing: c.ring_bin))")
                let rel = zip(mean, want).filter { $0.1 > 0 }.map { abs($0.0 - $0.1) / $0.1 }.sorted()
                if let last = rel.last { print("  info  \(c.name) per-bin relative error: max \(last), median \(rel[rel.count / 2])") }
                if report.failures == before { print("  ok    \(c.name)") }
                continue
            }
            if c.kind == "ifft" {
                var spots = (c.spots ?? []).map { MaskedInverseFFT.Spot(kx: $0.kx, ky: $0.ky, radius: $0.r, edge: mutation == "ifft-hard-edge" ? 0 : $0.e) }
                var partners = mutation != "ifft-no-friedel"
                if mutation == "ifft-partner-off" {      // the partner one index off on an even axis: n − k − 1 → −k − 1
                    spots += spots.map { .init(kx: -$0.kx - Double(1 - c.width % 2), ky: -$0.ky - Double(1 - c.height % 2), radius: $0.radius, edge: $0.edge) }
                    partners = false
                }
                let result = try MaskedInverseFFT.compute(input.micrograph, spots: spots, includeFriedelPartners: partners)
                var real = result.image.float32Values
                if mutation == "ifft-unscaled" { real = real.map { $0 * Float(c.width * c.height) } }
                let want = try doubles(out.appendingPathComponent("\(c.name).ifft.f64").path)
                let top = c.real_max ?? 0
                let worst = zip(real, want).map { abs(Double($0) - $1) }.max() ?? .infinity
                report.check(real.count == want.count && worst <= 1e-5 * top, "\(c.name) ifft", "max |Δ| \(worst) > 1e-5 × \(top)")
                report.check(result.imaginaryMax <= 1e-5 * top, "\(c.name) imag",
                             "imaginary \(result.imaginaryMax) > 1e-5 × \(top) (numpy: \(c.imag_max ?? .nan))")
                if report.failures == before { print("  ok    \(c.name)") }
                continue
            }
            let crop = c.crop.map { PixelCrop(row: $0.row, col: $0.col, height: $0.height, width: $0.width) }
            let s = try PowerSpectrum.compute(input.micrograph, crop: crop)
            let w = s.width, h = s.height
            var magnitude = s.magnitude.float32Values, power = s.power.float32Values, axisX = s.axisX, axisY = s.axisY
            switch mutation {
            case "no-shift": magnitude = roll(magnitude, w, h, rows: -(h / 2), cols: -(w / 2))
            // ifftshift's centre, (n + 1)/2, instead of fftshift's n/2: the same on even n, one bin off on odd n.
            case "shift-odd": magnitude = roll(magnitude, w, h, rows: (h + 1) / 2 - h / 2, cols: (w + 1) / 2 - w / 2)
            case "x-scale-both": axisY = PowerSpectrum.frequencies(h, d: c.units.isEmpty ? 1 : c.scale_x)
            case "power-is-magnitude": power = magnitude
            case "fftfreq-n-minus-1":
                let d = c.units.isEmpty ? 1 : c.scale_x, val = 1.0 / (Double(w - 1) * d)
                axisX = (0..<w).map { Double($0 - w / 2) * val }
            default: break
            }

            report.check(w == c.out_width && h == c.out_height, "\(c.name) shape", "\(w) × \(h) vs \(c.out_width) × \(c.out_height)")
            for (label, got, path) in [("magnitude", magnitude, c.magnitude!), ("power", power, c.power!)] {
                let want = try doubles(path)
                let peak = want.max() ?? 0
                let worst = zip(got, want).map { abs(Double($0) - $1) }.max() ?? .infinity
                report.check(got.count == want.count && worst <= 1e-5 * peak, "\(c.name) \(label)",
                             "max |Δ| \(worst) > 1e-5 × \(peak)")
                if label == "magnitude" {
                    let weak = zip(got, want).filter { $0.1 > 0 && $0.1 < 1e-3 * peak }
                        .map { abs(Double($0.0) - $0.1) / $0.1 }.sorted()
                    if !weak.isEmpty {
                        print("  info  \(c.name) weak bins (< 1e-3 of max): \(weak.count), relative error max \(weak.last!), 99th percentile \(weak[Int(Double(weak.count - 1) * 0.99)])")
                    }
                }
            }
            let wantX = try doubles(c.axis_x!), wantY = try doubles(c.axis_y!)
            report.check(axisX.map(\.bitPattern) == wantX.map(\.bitPattern), "\(c.name) axis_x", "first \(axisX.prefix(3)) vs \(wantX.prefix(3))")
            report.check(axisY.map(\.bitPattern) == wantY.map(\.bitPattern), "\(c.name) axis_y", "first \(axisY.prefix(3)) vs \(wantY.prefix(3))")
            report.check(s.unitsX == c.axis_units! && s.unitsY == c.axis_units!, "\(c.name) units", "\(s.unitsX), \(s.unitsY) vs \(c.axis_units ?? "?")")
            for p in c.peaks ?? [] {
                let (r, col) = (p[0], p[1])
                let v = magnitude[r * w + col]
                let neighbours = [(-1, 0), (1, 0), (0, -1), (0, 1)].compactMap { d -> Float? in
                    let rr = r + d.0, cc = col + d.1
                    return (0..<h).contains(rr) && (0..<w).contains(cc) ? magnitude[rr * w + cc] : nil
                }
                report.check(neighbours.allSatisfy { $0 < v }, "\(c.name) peaks", "no local maximum at [\(r), \(col)]")
            }
            if let cr = c.crop {
                let path = out.appendingPathComponent("\(c.name).cropped.in.f32").path   // numpy's crop, written by reference.py
                let theirs = try floats(path)
                var mine = input.micrograph.cropped(PixelCrop(row: cr.row, col: cr.col, height: cr.height, width: cr.width))!
                if mutation == "crop-origin" {
                    mine = try Micrograph(width: mine.width, height: mine.height, pixels: mine.pixels,
                                          x: input.x, y: input.y)
                }
                let expectedX = input.x.map { $0.origin - Double(cr.col) }, expectedY = input.y.map { $0.origin - Double(cr.row) }
                report.check(mine.pixels == theirs && mine.x?.origin == expectedX && mine.y?.origin == expectedY,
                             "\(c.name) crop", "pixels equal: \(mine.pixels == theirs); origins \(String(describing: mine.x?.origin)), \(String(describing: mine.y?.origin)) vs \(String(describing: expectedX)), \(String(describing: expectedY))")
                let direct = try PowerSpectrum.compute(image(c, pixels: theirs, width: cr.width, height: cr.height).micrograph)
                report.check(direct.magnitude == s.magnitude && direct.power == s.power, "\(c.name) crop",
                             "the crop's spectrum differs from the cropped image's")
            }
            if report.failures == before { print("  ok    \(c.name)") }
        }
        if report.failures > 0 {
            print("fft-parity: \(report.failures) FAILURES in \(report.checks) checks (numpy \(manifest.numpy))")
            exit(1)
        }
        print("fft-parity: all passed — \(manifest.cases.count) cases, \(report.checks) checks against numpy \(manifest.numpy)")
    }
}
