// tools/parity/ring-calibration-parity/main.swift — macTEM's camera-length closed forms and refusal decision (`RingCalibration`,
// DiffractoKit's DiffractoGeometry since ADR 025 (0.1.0 since the re-pin), built by tools/lib/sources.manifest group `ring`) against reference.py's closed forms with CODATA 2018
// constants, evaluated in 60-digit decimal arithmetic (archive: roadmap-registrations-2026-10-15.md "Diffraction S3, Camera length from one ring of known d",
// slice S3-a: no fit).
//
//     harness <out-dir-of-reference.py>
//
// Checks:
//   constants    the Swift CODATA 2018 constants equal the reference's as written; hc/e and m₀c²/e within 1e-14 relative
//   wavelength   λ(V), Å, at each of the five voltages within 1e-12 relative
//   formula      per case: 2θ from the reference's λ and d, L_px from the reference's R and 2θ, Δq from d and R, L_mm from
//                the reference's p and L_px, each within 1e-12 relative (every function gets the reference's own inputs,
//                so a wrong λ cannot hide a wrong formula nor the reverse)
//   chain        per case: `calibrate` end to end from V, d, R and p (λ, 2θ, L_px, Δq, L_mm within 1e-12), without a
//                pitch (no L_mm) and without V (Δq given, L absent, `.noHighTension`: V is never defaulted)
//   radius       per plant: FitReport.radius = (a + b)/2 equals numpy's mean of the two semi-axes, on axes planted with 3 %
//                ellipticity (a/b − 1 = 0.03), the major axis either way
//   refuse-…     per plant: `refusals` returns exactly the reference's list of names, in order, with the numbers each
//                reports, and withholds Δq exactly as registered; one check name per registered refusal (refuse-conic,
//                refuse-bins, refuse-gap, refuse-bound, refuse-residual, refuse-ellipticity, refuse-noV), plus
//                refuse-several (several at once), refuse-invalid (a number that is not finite and positive) and
//                refuse-bragg (λ/2d at the 2θ = 90° limit, through `calibrate` and `twoTheta`)
//
// MACTEM_PARITY_MUTATE=<name> breaks the code under test on purpose (on the functions' outputs, or on what is passed to
// them); run.sh requires each to exit 1 with its named check among the failures: q-two-over-d, a-for-nm, small-angle,
// pitch-um (formula); non-relativistic, kv-as-v (wavelength); v-default (refuse-noV); radius-a (radius). Unknown names
// exit 64. The manifest's tolerance must be at most the registered 1e-12 (a precondition: a loosened manifest cannot pass).

import Foundation
import DiffractoGeometry

struct Manifest: Decodable {
    struct Constants: Decodable {
        let h_Js: Double
        let c_ms: Double
        let e_C: Double
        let m0_kg: Double
        let hc_over_e_eV_A: Double
        let m0c2_over_e_eV: Double
    }
    struct Wavelength: Decodable {
        let kv: Int
        let volts: Double
        let lambda_A: Double
    }
    struct Case: Decodable {
        let name: String
        let d_A: Double
        let kv: Int
        let volts: Double
        let r_px: Double
        let pitch_mm: Double
        let lambda_A: Double
        let two_theta_rad: Double
        let l_px: Double
        let dq_per_A_per_px: Double
        let l_mm: Double
    }
    struct Refusal: Decodable {
        let name: String
        let check: String
        let model: String
        let a_px: Double
        let b_px: Double
        let occupied_bins: Int
        let sparse_coverage: Bool
        let residual: Double
        let inner_sigma: Double?
        let outer_sigma: Double?
        let annulus_width_px: Double
        let volts: Double?
        let expect_names: [String]
        let expect_values: [Double?]
        let withholds_dq: Bool
    }
    struct Axes: Decodable {
        let name: String
        let a_px: Double
        let b_px: Double
        let radius_px: Double
    }
    struct Domain: Decodable {
        let name: String
        let volts: Double
        let d_A: Double
        let r_px: Double
        let pitch_mm: Double
        let inside: Bool
        let lambda_over_2d: Double
    }
    let numpy: String
    let tolerance: Double
    let constants: Constants
    let wavelengths: [Wavelength]
    let cases: [Case]
    let refusals: [Refusal]
    let radius: [Axes]
    let domain: [Domain]
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

let mutations = ["q-two-over-d", "a-for-nm", "small-angle", "pitch-um", "non-relativistic", "kv-as-v", "v-default", "radius-a"]

func relative(_ x: Double, _ truth: Double) -> Double { abs(x - truth) / abs(truth) }

/// Equal, or within `relative` tolerance (a reported 0 must equal 0, where the relative error is 0/0).
func agrees(_ x: Double, _ truth: Double, _ tol: Double) -> Bool { x == truth || relative(x, truth) <= tol }

/// The number a refusal reports, the same one reference.py's `decide` lists (nil where it reports none).
func reported(_ refusal: RingCalibration.Refusal) -> Double? {
    switch refusal {
    case .insufficientAngularCoverage(let bins): return Double(bins)
    case .sigmaAtAnnulusWidth(let sigma, _): return sigma
    case .excessiveResidual(let residual): return residual
    case .excessiveEllipticity(let ellipticity): return ellipticity
    case .braggLimit(let ratio): return ratio
    case .modelNotAsymmetricGaussian, .noHighTension, .invalidInput: return nil
    // DiffractoKit 0.1.0's ring-evidence refusals exist only on the evidence path (`requireRingEvidence`); reference.py's
    // `decide` lists none of them, so no number is compared (archive: roadmap-registrations-2026-10-15.md "DiffractoKit 0.1.0: the re-pin").
    case .ringOutsideAnnulus, .notARingPeak, .ringGeometryInconsistent, .secondRingInAnnulus: return nil
    }
}

@main
struct RingCalibrationParity {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else { print("usage: harness <reference out-dir>"); exit(64) }
        let out = URL(fileURLWithPath: CommandLine.arguments[1])
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        let manifest = try decoder.decode(Manifest.self, from: Data(contentsOf: out.appendingPathComponent("manifest.json")))
        let mutation = ProcessInfo.processInfo.environment["MACTEM_PARITY_MUTATE"]
        if let mutation, !mutations.contains(mutation) {
            print("unknown MACTEM_PARITY_MUTATE '\(mutation)' (known: \(mutations.joined(separator: ", ")))")
            exit(64)
        }
        // The band is the registration's 1e-12; a manifest that loosened it would pass what it should fail.
        precondition(manifest.tolerance <= 1e-12, "the manifest's tolerance \(manifest.tolerance) is looser than the registered 1e-12")
        let tol = manifest.tolerance
        let k = manifest.constants
        var report = Report()

        // constants: as stated in the reference, exactly; the two derived energies within 1e-14.
        let constantsOK = RingCalibration.planckConstant == k.h_Js && RingCalibration.speedOfLight == k.c_ms
            && RingCalibration.elementaryCharge == k.e_C && RingCalibration.electronMass == k.m0_kg
        report.check(constantsOK, "CODATA-2018 constants",
                     "h \(RingCalibration.planckConstant) c \(RingCalibration.speedOfLight) e \(RingCalibration.elementaryCharge) m0 \(RingCalibration.electronMass) vs h \(k.h_Js) c \(k.c_ms) e \(k.e_C) m0 \(k.m0_kg)")
        let hce = relative(RingCalibration.planckTimesLightEVAngstroms, k.hc_over_e_eV_A)
        let mc2 = relative(RingCalibration.electronRestEnergyEV, k.m0c2_over_e_eV)
        report.check(hce <= 1e-14 && mc2 <= 1e-14, "CODATA-2018 derived constants",
                     "hc/e \(RingCalibration.planckTimesLightEVAngstroms) vs \(k.hc_over_e_eV_A) (\(hce)), m0c2/e \(RingCalibration.electronRestEnergyEV) vs \(k.m0c2_over_e_eV) (\(mc2))")

        // wavelength: λ(V), Å.
        var worstLambda = 0.0
        for w in manifest.wavelengths {
            var lambda = RingCalibration.wavelengthAngstroms(volts: mutation == "kv-as-v" ? w.volts / 1000 : w.volts)
            if mutation == "non-relativistic" { lambda = k.h_Js / (2 * k.m0_kg * k.e_C * w.volts).squareRoot() * 1e10 }
            let err = relative(lambda, w.lambda_A)
            worstLambda = max(worstLambda, err)
            report.check(err <= tol, "lambda-\(w.kv)kV wavelength", "λ \(lambda) Å vs \(w.lambda_A), relative \(err)")
        }

        // formula and chain, per case.
        var worst = (twoTheta: 0.0, length: 0.0, q: 0.0, mm: 0.0, chain: 0.0)
        for c in manifest.cases {
            let twoTheta = RingCalibration.twoTheta(wavelengthAngstroms: c.lambda_A, d: c.d_A)
            var length = RingCalibration.cameraLengthPixels(radius: c.r_px, twoTheta: c.two_theta_rad)
            var q = RingCalibration.qPerPixel(d: c.d_A, radius: c.r_px)
            var mm = RingCalibration.cameraLengthMillimetres(pixelPitchMM: c.pitch_mm, cameraLengthPixels: c.l_px)
            switch mutation {
            case "q-two-over-d": q = (2 / c.d_A) / c.r_px
            case "a-for-nm": q = (1 / (c.d_A / 10)) / c.r_px          // d in Å read as nm
            case "small-angle": length = c.r_px * c.d_A / c.lambda_A    // λL = Rd
            case "pitch-um": mm = (c.pitch_mm * 1000) * c.l_px          // the pitch in µm used as mm
            default: break
            }
            let e = (twoTheta: relative(twoTheta, c.two_theta_rad), length: relative(length, c.l_px),
                     q: relative(q, c.dq_per_A_per_px), mm: relative(mm, c.l_mm))
            let bad = [("2θ", e.twoTheta), ("L_px", e.length), ("Δq", e.q), ("L_mm", e.mm)].filter { !($0.1 <= tol) }
            report.check(bad.isEmpty, "\(c.name) formula", bad.map { "\($0.0) relative \($0.1)" }.joined(separator: ", "))

            var problems: [String] = []
            var chainWorst = 0.0
            func compare(_ what: String, _ x: Double?, _ truth: Double) {
                guard let x else { problems.append("\(what) absent"); return }
                let err = relative(x, truth)
                chainWorst = max(chainWorst, err)
                if !(err <= tol) { problems.append("\(what) relative \(err)") }
            }
            do {
                let full = try RingCalibration.calibrate(radius: c.r_px, d: c.d_A, highTensionVolts: c.volts, pixelPitchMM: c.pitch_mm)
                compare("λ", full.wavelengthAngstroms, c.lambda_A)
                compare("2θ", full.twoTheta, c.two_theta_rad)
                compare("L_px", full.lengthPixels, c.l_px)
                compare("Δq", full.deltaQ, c.dq_per_A_per_px)
                compare("L_mm", full.lengthMillimetres, c.l_mm)
                if full.highTensionVolts != c.volts { problems.append("V \(String(describing: full.highTensionVolts)) is not the stated \(c.volts)") }
                if full.lengthRefusal != nil { problems.append("L refused: \(String(describing: full.lengthRefusal))") }
                if full.d != c.d_A || full.radius != c.r_px { problems.append("d, R not echoed") }
                let noPitch = try RingCalibration.calibrate(radius: c.r_px, d: c.d_A, highTensionVolts: c.volts, pixelPitchMM: nil)
                compare("L_px without a pitch", noPitch.lengthPixels, c.l_px)
                if noPitch.lengthMillimetres != nil { problems.append("L_mm given without a pixel pitch") }
                let noV = try RingCalibration.calibrate(radius: c.r_px, d: c.d_A, highTensionVolts: mutation == "v-default" ? 200_000 : nil,
                                                        pixelPitchMM: c.pitch_mm)
                compare("Δq without V", noV.deltaQ, c.dq_per_A_per_px)
                if noV.lengthRefusal != .noHighTension || noV.lengthPixels != nil || noV.lengthMillimetres != nil
                    || noV.wavelengthAngstroms != nil || noV.twoTheta != nil || noV.highTensionVolts != nil {
                    problems.append("without V: refusal \(String(describing: noV.lengthRefusal)), L_px \(String(describing: noV.lengthPixels)); V is never defaulted")
                }
            } catch {
                problems.append("threw \(error)")
            }
            worst = (max(worst.twoTheta, e.twoTheta), max(worst.length, e.length), max(worst.q, e.q), max(worst.mm, e.mm),
                     max(worst.chain, chainWorst))
            report.check(problems.isEmpty, "\(c.name) chain", problems.joined(separator: "; "))
        }

        // refusals: the list from plain numbers, both sides of each boundary.
        for r in manifest.refusals {
            var volts = r.volts
            if mutation == "v-default", volts == nil { volts = 200_000 }    // a missing V taken as 200 kV
            let fit = RingCalibration.FitReport(
                model: r.model == "asymmetricGaussian" ? .asymmetricGaussian : .conic, semiAxisA: r.a_px, semiAxisB: r.b_px,
                occupiedAngularBins: r.occupied_bins, sparseCoverage: r.sparse_coverage, normalizedResidual: r.residual,
                innerSigma: r.inner_sigma, outerSigma: r.outer_sigma, annulusWidth: r.annulus_width_px)
            let got = RingCalibration.refusals(fit, highTensionVolts: volts)
            var problems: [String] = []
            if got.map(\.name) != r.expect_names {
                problems.append("refused as [\(got.map(\.name).joined(separator: ", "))], the registered thresholds say [\(r.expect_names.joined(separator: ", "))]")
            } else {
                for (refusal, want) in zip(got, r.expect_values) {
                    let have = reported(refusal)
                    if (have == nil) != (want == nil) || (have != nil && !agrees(have!, want!, 1e-12)) {
                        problems.append("\(refusal.name) reports \(String(describing: have)), expected \(String(describing: want))")
                    }
                    if case .sigmaAtAnnulusWidth(_, let width) = refusal, width != r.annulus_width_px {
                        problems.append("sigmaAtAnnulusWidth reports the width \(width), the annulus is \(r.annulus_width_px)")
                    }
                }
            }
            if got.contains(where: \.withholdsDeltaQ) != r.withholds_dq {
                problems.append("withholdsDeltaQ \(got.contains(where: \.withholdsDeltaQ)), registered \(r.withholds_dq)")
            }
            report.check(problems.isEmpty, "\(r.name) \(r.check)", problems.joined(separator: "; "))
        }

        // radius: FitReport.radius = (a + b)/2 against numpy's mean, on axes planted with 3 % ellipticity (below the cap, so
        // the mean differs from the larger and from the smaller axis by 1.5 %).
        var worstRadius = 0.0
        for p in manifest.radius {
            let fit = RingCalibration.FitReport(model: .asymmetricGaussian, semiAxisA: p.a_px, semiAxisB: p.b_px, occupiedAngularBins: 36,
                                                sparseCoverage: false, normalizedResidual: 0.05, innerSigma: 3, outerSigma: 3, annulusWidth: 40)
            var radius = fit.radius
            if mutation == "radius-a" { radius = fit.semiAxisA }        // R taken as the first axis, not the mean
            let err = relative(radius, p.radius_px)
            worstRadius = max(worstRadius, err)
            report.check(err <= tol, "\(p.name) radius", "R \(radius) vs numpy's mean \(p.radius_px), relative \(err)")
        }

        // the Bragg limit: no ring at 2θ ≥ 90° on a flat detector.
        for b in manifest.domain {
            var problems: [String] = []
            let lambda = RingCalibration.wavelengthAngstroms(volts: b.volts)
            let angle = RingCalibration.twoTheta(wavelengthAngstroms: lambda, d: b.d_A)
            if angle.isFinite != b.inside { problems.append("twoTheta \(angle), the ring is \(b.inside ? "inside" : "outside") the limit") }
            do {
                let result = try RingCalibration.calibrate(radius: b.r_px, d: b.d_A, highTensionVolts: b.volts, pixelPitchMM: b.pitch_mm)
                if result.deltaQ != RingCalibration.qPerPixel(d: b.d_A, radius: b.r_px) || !result.deltaQ.isFinite {
                    problems.append("Δq \(result.deltaQ) is not given beside a Bragg refusal")
                }
                if b.inside {
                    if result.lengthRefusal != nil { problems.append("refused: \(String(describing: result.lengthRefusal))") }
                    if !(result.lengthPixels.map { $0.isFinite && $0 > 0 } ?? false) { problems.append("L_px \(String(describing: result.lengthPixels))") }
                } else if case .braggLimit(let ratio)? = result.lengthRefusal {
                    if !(relative(ratio, b.lambda_over_2d) <= 1e-12) { problems.append("reports λ/2d \(ratio), expected \(b.lambda_over_2d)") }
                    if result.lengthPixels != nil || result.lengthMillimetres != nil || result.twoTheta != nil { problems.append("L or 2θ given beside the refusal") }
                    if result.highTensionVolts != b.volts || result.wavelengthAngstroms == nil { problems.append("V and λ not shown beside the refusal") }
                } else {
                    problems.append("not refused as braggLimit: \(String(describing: result.lengthRefusal))")
                }
            } catch {
                problems.append("threw \(error)")
            }
            report.check(problems.isEmpty, "\(b.name) refuse-bragg", problems.joined(separator: "; "))
        }

        print("  info  worst relative error over \(manifest.cases.count) cases: λ \(worstLambda), 2θ \(worst.twoTheta), L_px \(worst.length), Δq \(worst.q), L_mm \(worst.mm), calibrate \(worst.chain), over \(manifest.radius.count) radius plants: R \(worstRadius) (band \(tol))")
        if report.failures > 0 {
            print("ring-calibration-parity: \(report.failures) FAILURES in \(report.checks) checks (numpy \(manifest.numpy))")
            exit(1)
        }
        print("ring-calibration-parity: all passed — \(manifest.cases.count) cases, \(manifest.wavelengths.count) wavelengths, \(manifest.refusals.count) refusal plants, \(manifest.radius.count) radius plants, \(manifest.domain.count) Bragg-limit plants, \(report.checks) checks against numpy \(manifest.numpy)")
    }
}
