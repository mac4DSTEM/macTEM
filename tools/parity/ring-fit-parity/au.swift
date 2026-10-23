// tools/parity/ring-fit-parity/au.swift — a FIRST LOOK, printed and never gated, at the public Au 200 kV ring pattern
// (Zenodo 8354219, the mean of 100 000 ARINA frames; tools/parity/au-ring-pattern/ derives it) through `RingCalibration.fit`.
// Not S3-c: S3 closed with S3-b's failure (archive: roadmap-registrations-2026-10-15.md "Result S3-b"); this measures what the next registration must face.
//
//     au <pattern.tif>
//
// The direct beam's centre is the intensity-weighted centroid of the pixels above half the maximum; each ring is fitted
// in an annulus of ±3 px about the radius the reference search measured (tools/parity/au-ring-pattern/README.md), narrow because
// fcc Au's neighbours sit close (311 at 1.17 × the 220 radius; 331 and 420 2.6 % apart). V = 200 kV and p = 0.1 mm are the
// record's. Each ring is calibrated with its own assigned hkl; the four Δq are printed side by side — they agree only if
// the assignments, the fit and the detector's geometry all hold. The authors' 0.022013 Å⁻¹/px is THEIR assignment of 220,
// printed for comparison, not truth.

import Foundation
import DiffractoGeometry

@main
struct AuFirstLook {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            print("usage: au <pattern.tif>")
            exit(64)
        }
        let image = try ImageOpening.openNow(path: CommandLine.arguments[1])
        let rows = image.height, cols = image.width
        let peak = image.pixels.max() ?? 0
        var sw = 0.0, sr = 0.0, sc = 0.0
        for r in 0..<rows {
            for c in 0..<cols {
                let v = Double(image.pixels[r * cols + c])
                guard v >= Double(peak) / 2 else { continue }
                sw += v; sr += v * Double(r); sc += v * Double(c)
            }
        }
        let row0 = sr / sw, col0 = sc / sw
        print(String(format: "au: %d × %d (rows × columns); direct-beam centroid (row %.3f, column %.3f); peak %.1f counts", rows, cols, row0, col0, peak))
        let pattern = DiffractionPattern(width: cols, height: rows, pixels: image.pixels)
        let a = 4.0782
        let rings: [(String, Double, Double)] = [   // hkl, h² + k² + l², the reference search's radius (px)
            ("220", 8, 32.00), ("331", 19, 48.75), ("422", 24, 55.65), ("440", 32, 65.3),
        ]
        var first: Double?
        for (hkl, n, radius) in rings {
            let d = a / n.squareRoot()
            do {
                let result = try RingCalibration.fit(pattern: pattern, centerQX: row0, centerQY: col0,
                                                     innerRadius: radius - 3, outerRadius: radius + 3,
                                                     d: d, highTensionVolts: 200_000, pixelPitchMM: 0.1)
                let refused = result.refusals.map(\.name)
                if let fit = result.fit {
                    let R = (fit.a + fit.b) / 2
                    let dq = (1 / d) / R
                    if first == nil { first = dq }
                    print(String(format: "  %@  d %.4f Å  %@  R %.3f px  a/b−1 %.4f  centre (%.3f, %.3f)  residual %.3f  σ in/out %@  Δq %.6f Å⁻¹/px (%+.2f %% vs 220)  L %@  refusals %@",
                                 hkl, d, fit.model == .asymmetricGaussian ? "profile" : "conic", R, max(fit.a, fit.b) / min(fit.a, fit.b) - 1,
                                 fit.centerQX, fit.centerQY, fit.normalizedResidual,
                                 fit.profile.map { String(format: "%.2f/%.2f", $0.innerSigma, $0.outerSigma) } ?? "—",
                                 dq, (dq / first! - 1) * 100,
                                 result.calibration?.lengthMillimetres.map { String(format: "%.2f mm", $0) } ?? "withheld",
                                 refused.isEmpty ? "none" : refused.joined(separator: ", ")))
                } else {
                    print("  \(hkl)  no fit; refusals \(result.refusals.map(\.reason))")
                }
            } catch {
                print("  \(hkl)  the fit threw: \(error)")
            }
        }
        print("  the authors' own assignment of 220 (record notebook, cell 57): 0.022013 Å⁻¹/px — not truth")
    }
}
