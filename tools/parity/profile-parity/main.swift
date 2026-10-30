// tools/parity/profile-parity/main.swift — macTEM's distance, angle and line profile (`ImageMeasurement`, `LineProfile`; TEMCore,
// through Package.swift's ProfileParity target) against reference.py's manifest: scikit-image 0.26.0's
// `profile_line` (order 1, mode "reflect", mean) with scipy 1.18.1, and the closed forms.
//
//     harness <out-dir of reference.py>
//
// Pass bands (archive: roadmap-registrations-2026-10-15.md V1-5):
//   P1  distance (px and physical) and angle equal their closed forms to 1e-12 relative; the unit is the file's own string
//       and the plane (physical or pixel) is the one the rule gives; a zero arm gives no angle.
//   P2  every profile sample equals scikit-image's (the float32 image, float32 output) to 1e-5 relative, with the floor
//       1e-5 x 0.1 x the image's largest magnitude near zero (the registered floor is 1e-5 x the maximum; this is tighter);
//       the same sample count; every sample also equals scikit-image's float64 run to 1e-12 of the image maximum (the
//       port is Double: this is what separates it from skimage's float32 rounding); positions i/(n-1) of the length in the
//       axes' unit (px when not calibrated in one unit) to 1e-12 relative; on a planted bilinear ramp the samples also equal
//       the analytic value at the sample points to the same 1e-5 band.
//
// The negative controls are SOURCE mutants of ImageMeasurement.swift and LineProfile.swift, built and run by run.sh;
// this file does not know them. A check is named by the text before ": " on its "  FAIL  " line.

@testable import TEMCore
import ImagoCore
import Foundation

struct Manifest: Decodable {
    struct Axis: Decodable {
        let scale: Double
        let units: String
        let origin: Double
    }
    struct Image: Decodable {
        let width: Int
        let height: Int
        let x: Axis?
        let y: Axis?
        let pixels: String
        let maxabs: Double
    }
    struct Profile: Decodable {
        let name: String
        let image: String
        let r0: Double, c0: Double, r1: Double, c1: Double
        let width: Int
        let count: Int
        let f32: [Double]
        let f64: [Double]
        let positions: [Double]
        let unit: String
        let physical: Bool
        let analytic: [Double]?
    }
    struct Distance: Decodable {
        let name: String
        let a: [Double], b: [Double]
        let x: Axis?, y: Axis?
        let px: Double
        let physical: Double?
        let unit: String?
    }
    struct Angle: Decodable {
        let name: String
        let a: [Double], b: [Double], c: [Double]
        let x: Axis?, y: Axis?
        let degrees: Double?
        let plane: String?
    }
    let reference: String
    let images: [String: Image]
    let profiles: [Profile]
    let distances: [Distance]
    let angles: [Angle]
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

func axis(_ a: Manifest.Axis?) -> AxisCalibration? { a.map { AxisCalibration(scale: $0.scale, unit: $0.units, origin: $0.origin) } }
func point(_ rowCol: [Double]) -> ImagePoint { ImagePoint(x: rowCol[1], y: rowCol[0]) }

/// The first index where |got - want| exceeds `tolerance(index)`, with the two values; nil when none does.
func firstOutside(_ got: [Double], _ want: [Double], tolerance: (Int) -> Double) -> String? {
    for i in 0..<min(got.count, want.count) where !(abs(got[i] - want[i]) <= tolerance(i)) {
        return "sample \(i) of \(want.count): \(got[i]) vs \(want[i]), difference \(abs(got[i] - want[i])) > \(tolerance(i))"
    }
    return nil
}

func loadPixels(_ file: URL) throws -> [Float] {
    try Data(contentsOf: file).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
}

@main
struct ProfileParity {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            print("usage: harness <reference out-dir>")
            exit(64)
        }
        let out = URL(fileURLWithPath: CommandLine.arguments[1])
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: out.appendingPathComponent("manifest.json")))
        var report = Report()

        var images: [String: CalibratedImage] = [:]
        for (name, m) in manifest.images {
            let pixels = try loadPixels(out.appendingPathComponent(m.pixels))
            report.check(pixels.count == m.width * m.height, "image \(name) shape", "\(pixels.count) pixels for \(m.width) x \(m.height)")
            images[name] = CalibratedImage(width: m.width, height: m.height, pixels: pixels, x: axis(m.x), y: axis(m.y),
                                           fileName: name, source: "", voltage: nil)
        }

        // P1: distance and angle.
        func close(_ got: Double, _ want: Double) -> Bool { abs(got - want) <= 1e-12 * abs(want) }
        for c in manifest.distances {
            let d = ImageMeasurement.distance(point(c.a), point(c.b), x: axis(c.x), y: axis(c.y))
            report.check(close(d.pixels, c.px), "distance \(c.name) pixels", "\(d.pixels) vs \(c.px)")
            if let want = c.physical {
                report.check(d.physical.map { close($0, want) } ?? false, "distance \(c.name) physical",
                             "\(d.physical.map { "\($0)" } ?? "nil") vs \(want)")
                report.check(d.unit == c.unit, "distance \(c.name) unit", "\(d.unit ?? "nil") vs \(c.unit ?? "nil")")
            } else {
                report.check(d.physical == nil && d.unit == nil, "distance \(c.name) physical",
                             "\(d.physical.map { "\($0)" } ?? "nil") \(d.unit ?? "nil"), expected pixels only")
            }
        }
        for c in manifest.angles {
            let a = ImageMeasurement.angle(point(c.a), vertex: point(c.b), point(c.c), x: axis(c.x), y: axis(c.y))
            if let want = c.degrees, let plane = c.plane {
                report.check(a.map { abs($0.degrees - want) <= max(1e-12 * want, 1e-14) } ?? false, "angle \(c.name) degrees",
                             "\(a.map { "\($0.degrees)" } ?? "nil") vs \(want)")
                let got = a.map { $0.plane == .physical ? "physical" : "pixel" } ?? "nil"
                report.check(got == plane, "angle \(c.name) plane", "\(got) vs \(plane)")
            } else {
                report.check(a == nil, "angle \(c.name) degrees", "\(a.map { "\($0.degrees)" } ?? "nil"), expected no angle")
            }
        }
        if report.failures == 0 { print("  ok    \(manifest.distances.count) distances and \(manifest.angles.count) angles against their closed forms") }

        // P2: profiles.
        var perImage: [String: (profiles: Int, failures: Int)] = [:]
        var maxVs32 = 0.0, maxVs64 = 0.0
        for p in manifest.profiles {
            guard let m = manifest.images[p.image], let image = images[p.image] else {
                report.check(false, "profile \(p.name) image", "no image '\(p.image)' in the manifest")
                continue
            }
            let before = report.failures
            let got = LineProfile.sample(image, from: ImagePoint(x: p.c0, y: p.r0), to: ImagePoint(x: p.c1, y: p.r1), width: p.width)
            let name = "profile \(p.name)"
            let floor = 0.1 * m.maxabs
            report.check(got.samples.count == p.count && got.positions.count == p.count, "\(name) count",
                         "\(got.samples.count) samples and \(got.positions.count) positions, scikit-image has \(p.count)")
            let band32: (Int) -> Double = { 1e-5 * max(abs(p.f32[$0]), floor) }
            report.check(got.samples.count == p.count && firstOutside(got.samples, p.f32, tolerance: band32) == nil, "\(name) samples",
                         got.samples.count == p.count ? firstOutside(got.samples, p.f32, tolerance: band32) ?? ""
                                                      : "\(got.samples.count) samples, scikit-image has \(p.count)")
            let band64: (Int) -> Double = { _ in 1e-12 * m.maxabs }
            report.check(got.samples.count == p.count && firstOutside(got.samples, p.f64, tolerance: band64) == nil, "\(name) samples f64",
                         got.samples.count == p.count ? firstOutside(got.samples, p.f64, tolerance: band64) ?? ""
                                                      : "\(got.samples.count) samples, scikit-image has \(p.count)")
            if got.samples.count == p.count {
                for i in 0..<p.count {
                    maxVs32 = max(maxVs32, abs(got.samples[i] - p.f32[i]) / m.maxabs)
                    maxVs64 = max(maxVs64, abs(got.samples[i] - p.f64[i]) / m.maxabs)
                }
            }
            let posBand: (Int) -> Double = { 1e-12 * abs(p.positions[$0]) }
            report.check(got.positions.count == p.count && firstOutside(got.positions, p.positions, tolerance: posBand) == nil,
                         "\(name) positions",
                         got.positions.count == p.count ? firstOutside(got.positions, p.positions, tolerance: posBand) ?? ""
                                                        : "\(got.positions.count) positions, expected \(p.count)")
            report.check(got.unit == p.unit && got.isPhysical == p.physical && got.width == p.width, "\(name) unit",
                         "'\(got.unit)' physical \(got.isPhysical) width \(got.width) vs '\(p.unit)' physical \(p.physical) width \(p.width)")
            if let analytic = p.analytic {
                let bandA: (Int) -> Double = { 1e-5 * max(abs(analytic[$0]), floor) }
                report.check(got.samples.count == analytic.count && firstOutside(got.samples, analytic, tolerance: bandA) == nil,
                             "\(name) analytic",
                             got.samples.count == analytic.count ? firstOutside(got.samples, analytic, tolerance: bandA) ?? ""
                                                                 : "\(got.samples.count) samples, the ramp has \(analytic.count)")
            }
            perImage[p.image, default: (0, 0)].profiles += 1
            perImage[p.image, default: (0, 0)].failures += report.failures - before
        }
        for (name, r) in perImage.sorted(by: { $0.key < $1.key }) where r.failures == 0 {
            print("  ok    \(name) (\(r.profiles) profiles)")
        }
        print(String(format: "  measured: samples vs scikit-image float32, max %.2e of the image maximum; vs its float64 run, max %.2e",
                     maxVs32, maxVs64))

        // Speed (reported, not gated): a 3000-pixel line at width 25 on a 2200 x 2200 image.
        let big = CalibratedImage(width: 2200, height: 2200, pixels: (0..<(2200 * 2200)).map { Float($0 % 977) }, x: nil, y: nil,
                                  fileName: "big", source: "", voltage: nil)
        let clock = ContinuousClock()
        var times: [Double] = []
        var samples = 0
        for _ in 0..<21 {
            let t = clock.measure {
                let p = LineProfile.sample(big, from: ImagePoint(x: 10, y: 10), to: ImagePoint(x: 2131.3, y: 2131.3), width: 25)
                samples = p.samples.count
            }
            times.append(Double(t.components.seconds) * 1e3 + Double(t.components.attoseconds) / 1e15)
        }
        print(String(format: "  timing: %d samples at width 25, median %.3f ms of 21 (not gated)", samples, times.sorted()[10]))

        if report.failures > 0 {
            print("profile-parity: \(report.failures) FAILURES in \(report.checks) checks (\(manifest.reference))")
            exit(1)
        }
        print("profile-parity: all passed — \(manifest.profiles.count) profiles, \(manifest.distances.count) distances, "
              + "\(manifest.angles.count) angles, \(report.checks) checks against \(manifest.reference)")
    }
}
