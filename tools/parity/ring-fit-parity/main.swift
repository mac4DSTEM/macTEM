// tools/parity/ring-fit-parity/main.swift — macTEM's fit-driven ring calibration (`RingCalibration.fit`, DiffractoKit's DiffractoGeometry since
// ADR 025, built by tools/lib/sources.manifest group `ring`) on the rings plants.py planted, against their truth (archive: roadmap-registrations-2026-10-15.md
// "Diffraction S3, Camera length from one ring of known d", slice S3-b).
//
//     harness <out-dir-of-plants.py>
//
// Convention: the fit's "qx" is the ROW and "qy" the COLUMN; DiffractionPattern(width: columns, height: rows, pixels:).
//
// Checks (each failure a line "  FAIL  <case> <check>: …"):
//   P1, the clean tier, on every ACCEPTED ring (nothing refused that withholds Δq):
//     dq      |Δq / Δq₀ − 1| ≤ 1e-3                          (registered: 0.1 %)
//     length  |L_px / L_px₀ − 1| ≤ 1e-3, and L_mm the same   (registered: 0.1 %)
//     centre  both coordinates within 0.05 px of the plant's (registered)
//   P2, the refusal plants: `refuse` — the refusal the plant was made for is among the result's refusals (the coverage
//     plants: it is the first and the result has no fit; `refuse-noV`: the only one, with Δq still given within 0.1 %);
//     `throws` — the fit's error of that name reaches the caller.
// Printed, never gated: per tier n, accepted, refused by name, thrown errors, then median / p90 / max of |ΔΔq/Δq| and of
// the centre error over the accepted rings, and the same radius error over the refused-but-fitted ones ("had it been
// accepted"); on the clean tier, the Swift fit against scipy's optimum of the same model (plants.py).
//
// MACTEM_PARITY_ONLY=<name>[,<name>…] runs only those cases (run.sh's controls). MACTEM_PARITY_MUTATE=<name> breaks the
// path on purpose — EMULATED here, since `RingCalibration.fit` has no option to break: the harness re-runs the wrapper's
// steps (`fitBestAvailable`, `FitReport`, `refusals`, `calibrate`) with the one change:
//   recover        the d of the next family down (d / 1.1547, {111} → {200}) passed for the ring's own   → dq
//   radius-a       the radius handed to `calibrate` is the fit's a, not (a + b)/2                      → dq (ε 3 %)
//   centre         the fit's row and column swapped                                                    → centre
//   refuse-conic   `modelNotAsymmetricGaussian` dropped from the decision                              → refuse
//   refuse-gap     the coverage check dropped: the fit run with acceptSparseCoverage: true AND the
//                  coverage refusal dropped from the decision                                          → refuse
//   accept-sparse  acceptSparseCoverage: true alone (the registered mutation): Δq is still withheld, by
//                  `refusals`' own bin bound, so it is caught only by the check that a coverage-refused
//                  ring comes back with no fit                                                         → refuse
//   (refuse-bound, `sigmaAtAnnulusWidth` dropped, left on DiffractoKit 0.1.0: its plant is accepted, `accept-bound`)
//   refuse-noV     a missing V taken as 200 kV                                                         → refuse
// Unknown names exit 64.

import Foundation
import DiffractoGeometry

struct Manifest: Decodable {
    struct Ref: Decodable {
        let row: Double
        let col: Double
        let radius: Double
        let samples: Int
        let status: Int
    }
    struct Case: Decodable {
        let name: String
        let file: String
        let tier: String
        let kind: String
        let error: String?
        let gated: Bool
        let rows: Int
        let cols: Int
        let r0: Double
        let c0: Double
        let R: Double
        let a: Double
        let b: Double
        let eps: Double
        let gap_deg: Double
        let inner: Double
        let outer: Double
        let guess_row: Double
        let guess_col: Double
        let empty: Bool
        let d: Double
        let volts: Double?
        let pitch_mm: Double
        let dq: Double
        let length_px: Double?
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

let mutations = ["recover", "radius-a", "centre", "refuse-conic", "refuse-gap", "accept-sparse", "refuse-noV"]

enum Outcome {
    case fitted(RingFitCalibration)
    case threw(String)
}

func errorName(_ error: Error) -> String {
    if let e = error as? EllipseCalibration.FitError {
        switch e {
        case .invalidInput: return "invalidInput"
        case .insufficientSignal: return "insufficientSignal"
        case .insufficientAngularCoverage: return "insufficientAngularCoverage"
        case .moreThanOneRing: return "moreThanOneRing"
        case .didNotConverge: return "didNotConverge"
        case .invalidEllipse: return "invalidEllipse"
        case .excessiveResidual: return "excessiveResidual"
        case .ringWidthAtFloor: return "ringWidthAtFloor"
        }
    }
    if let r = error as? RingCalibration.Refusal { return r.name }
    return "\(error)"
}

/// The wrapper's steps with one mutation (the header lists them). Only called when a mutation is set.
func mutatedFit(_ pattern: DiffractionPattern, _ c: Manifest.Case, _ mutation: String) throws -> RingFitCalibration {
    let d = mutation == "recover" ? c.d / (2 / 3.0.squareRoot()) : c.d
    let volts = mutation == "refuse-noV" ? (c.volts ?? 200_000) : c.volts
    let sparse = mutation == "refuse-gap" || mutation == "accept-sparse"
    let fit: EllipseCalibrationFit
    do {
        fit = try EllipseCalibration.fitBestAvailable(
            pattern: pattern, centerQX: c.guess_row, centerQY: c.guess_col,
            innerRadius: c.inner, outerRadius: c.outer, acceptSparseCoverage: sparse, requireRingEvidence: true)
    } catch EllipseCalibration.FitError.insufficientAngularCoverage(let bins) {
        var refused: [RingCalibration.Refusal] = [.insufficientAngularCoverage(occupiedBins: bins)]
        if volts == nil { refused.append(.noHighTension) }
        return RingFitCalibration(fit: nil, report: nil, refusals: refused, calibration: nil)
    }
    let report = RingCalibration.FitReport(
        model: fit.model, semiAxisA: fit.a, semiAxisB: fit.b,
        occupiedAngularBins: fit.occupiedAngularBins, sparseCoverage: fit.sparseCoverage,
        normalizedResidual: fit.normalizedResidual,
        innerSigma: fit.profile?.innerSigma, outerSigma: fit.profile?.outerSigma,
        annulusWidth: c.outer - c.inner, annulusInnerRadius: c.inner, annulusOuterRadius: c.outer,
        ringEvidence: fit.ringEvidence)
    var refused = RingCalibration.refusals(report, highTensionVolts: volts)
    let dropped: String? = switch mutation {
    case "refuse-conic": "modelNotAsymmetricGaussian"
    case "refuse-gap": "insufficientAngularCoverage"
    default: nil
    }
    if let dropped { refused.removeAll { $0.name == dropped } }
    guard !refused.contains(where: \.withholdsDeltaQ) else {
        return RingFitCalibration(fit: fit, report: report, refusals: refused, calibration: nil)
    }
    let radius = mutation == "radius-a" ? fit.a : report.radius
    var shown = fit
    if mutation == "centre" {
        shown = EllipseCalibrationFit(
            centerQX: fit.centerQY, centerQY: fit.centerQX, a: fit.a, b: fit.b, theta: fit.theta,
            normalizedResidual: fit.normalizedResidual, conicResidual: fit.conicResidual, sampleCount: fit.sampleCount,
            occupiedAngularBins: fit.occupiedAngularBins, model: fit.model, profile: fit.profile,
            profileFallbackReason: fit.profileFallbackReason, sparseCoverage: fit.sparseCoverage)
    }
    let calibration = try RingCalibration.calibrate(radius: radius, d: d, highTensionVolts: volts,
                                                    pixelPitchMM: c.pitch_mm)
    return RingFitCalibration(fit: shown, report: report, refusals: refused, calibration: calibration)
}

func quantiles(_ values: [Double]) -> String {
    guard !values.isEmpty else { return "—" }
    let s = values.sorted()
    // Nearest rank: the smallest value with at least a fraction q of the values at or below it.
    func at(_ q: Double) -> Double { s[max(0, Int((q * Double(s.count)).rounded(.up)) - 1)] }
    return String(format: "median %.4g  p90 %.4g  max %.4g", at(0.5), at(0.9), s.last!)
}

@main
struct Harness {
    static func main() throws {
        let arguments = CommandLine.arguments
        guard arguments.count == 2 else {
            print("usage: harness <out-dir-of-plants.py>")
            exit(64)
        }
        let dir = URL(fileURLWithPath: arguments[1])
        let environment = ProcessInfo.processInfo.environment
        let mutation = environment["MACTEM_PARITY_MUTATE"]
        if let mutation, !mutations.contains(mutation) {
            print("ring-fit-parity: unknown mutation '\(mutation)'")
            exit(64)
        }
        let only = environment["MACTEM_PARITY_ONLY"].map { Set($0.split(separator: ",").map(String.init)) }
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: dir.appendingPathComponent("planted.json")))
        var report = Report()
        let cases = manifest.cases.filter { only?.contains($0.name) ?? true }
        guard !cases.isEmpty else {
            print("ring-fit-parity: no case selected")
            exit(64)
        }
        if let only, cases.count != only.count {
            print("ring-fit-parity: MACTEM_PARITY_ONLY names a case that does not exist")
            exit(64)
        }
        print("ring-fit-parity: \(cases.count) cases; reference numpy \(manifest.numpy), scipy \(manifest.scipy)\(mutation.map { "; MUTATION \($0)" } ?? "")")

        struct Row {
            let tier: String
            let accepted: Bool
            let refused: [String]
            let thrown: String?
            let dqError: Double?
            let centreError: Double?
        }
        var rows: [Row] = []
        var swiftVsScipyRadius: [Double] = []
        var swiftVsScipyCentre: [Double] = []

        for c in cases {
            let data = try Data(contentsOf: dir.appendingPathComponent(c.file))
            let pixels = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            precondition(pixels.count == c.rows * c.cols, "\(c.name): \(pixels.count) pixels")
            let pattern = DiffractionPattern(width: c.cols, height: c.rows, pixels: pixels)
            let outcome: Outcome
            do {
                let result = try mutation.map { try mutatedFit(pattern, c, $0) }
                    ?? RingCalibration.fit(pattern: pattern, centerQX: c.guess_row, centerQY: c.guess_col,
                                           innerRadius: c.inner, outerRadius: c.outer, d: c.d,
                                           highTensionVolts: c.volts, pixelPitchMM: c.pitch_mm)
                outcome = .fitted(result)
            } catch {
                outcome = .threw(errorName(error))
            }

            var dqError: Double?, centreError: Double?, accepted = false, refusedNames: [String] = [], thrown: String?
            switch outcome {
            case .threw(let name):
                thrown = name
            case .fitted(let result):
                refusedNames = result.refusals.map(\.name)
                if let fit = result.fit {
                    centreError = max(abs(fit.centerQX - c.r0), abs(fit.centerQY - c.c0))
                    dqError = abs(((1 / c.d) / ((fit.a + fit.b) / 2)) / c.dq - 1)
                    if let ref = c.ref, fit.model == .asymmetricGaussian {
                        swiftVsScipyRadius.append(abs((fit.a + fit.b) / 2 / ref.radius - 1))
                        swiftVsScipyCentre.append(max(abs(fit.centerQX - ref.row), abs(fit.centerQY - ref.col)))
                    }
                }
                if let calibration = result.calibration {
                    accepted = true
                    dqError = abs(calibration.deltaQ / c.dq - 1)
                    if c.gated {
                        report.check(dqError! <= 1e-3, "\(c.name) dq",
                                     String(format: "Δq %.9g, planted %.9g: %.4f %%", calibration.deltaQ, c.dq, dqError! * 100))
                        if let truth = c.length_px {
                            let length = calibration.lengthPixels ?? .nan
                            let error = abs(length / truth - 1)
                            let mm = (calibration.lengthMillimetres ?? .nan) / (c.pitch_mm * truth) - 1
                            report.check(error <= 1e-3 && abs(mm) <= 1e-3, "\(c.name) length",
                                         String(format: "L_px %.9g, planted %.9g: %.4f %%; L_mm %.4f %%", length, truth, error * 100, mm * 100))
                        }
                        if let fit = result.fit {
                            report.check(abs(fit.centerQX - c.r0) <= 0.05 && abs(fit.centerQY - c.c0) <= 0.05, "\(c.name) centre",
                                         String(format: "(%.4f, %.4f), planted (%.4f, %.4f): %.4f px", fit.centerQX, fit.centerQY, c.r0, c.c0, centreError!))
                        }
                    }
                }
            }
            if c.kind == "refusal", let want = c.error {
                switch outcome {
                case .threw(let name):
                    report.check(false, "\(c.name) refuse", "threw \(name), wanted the refusal \(want)")
                case .fitted(let result):
                    var ok = refusedNames.contains(want)
                    var detail = "refusals \(refusedNames), wanted \(want)"
                    if want == "insufficientAngularCoverage" {
                        ok = ok && refusedNames.first == want && result.fit == nil && result.calibration == nil
                    }
                    if want == "noHighTension" {
                        let dq = result.calibration?.deltaQ ?? .nan
                        ok = ok && refusedNames == [want] && abs(dq / c.dq - 1) <= 1e-3 && result.calibration?.lengthPixels == nil
                        detail += String(format: "; Δq %.9g, planted %.9g", dq, c.dq)
                    } else {
                        ok = ok && result.calibration == nil
                    }
                    report.check(ok, "\(c.name) refuse", detail)
                }
            }
            if c.kind == "accepts" {
                // DiffractoKit 0.1.0: the 1/r^3 plant the 0.0.3-era registration expected to be refused for its sigma is calibrated
                // (archive: roadmap-registrations-2026-10-15.md "DiffractoKit 0.1.0: the re-pin", (e)); Δq, L and the centre are gated by `gated` above.
                report.check(accepted && refusedNames.isEmpty, "\(c.name) accepts", "accepted \(accepted), refusals \(refusedNames)")
            }
            if c.kind == "throws", let want = c.error {
                report.check(thrown == want, "\(c.name) throws", "outcome \(thrown ?? "fitted, refusals \(refusedNames)"), wanted \(want)")
            }
            rows.append(Row(tier: c.tier, accepted: accepted, refused: refusedNames, thrown: thrown,
                            dqError: dqError, centreError: centreError))
        }

        // The distributions, per tier, in the order the tiers first appear.
        var order: [String] = []
        for row in rows where !order.contains(row.tier) { order.append(row.tier) }
        for tier in order {
            let these = rows.filter { $0.tier == tier }
            let accepted = these.filter(\.accepted)
            var refusedCounts: [String: Int] = [:]
            for row in these where !row.accepted {
                for name in row.refused where name != "noHighTension" || row.refused.count > 1 { refusedCounts[name, default: 0] += 1 }
            }
            var thrownCounts: [String: Int] = [:]
            for row in these { if let t = row.thrown { thrownCounts[t, default: 0] += 1 } }
            let refusedText = refusedCounts.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
            let thrownText = thrownCounts.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
            print("  tier  \(tier): n \(these.count), accepted \(accepted.count)"
                  + (refusedText.isEmpty ? "" : "; refused: \(refusedText)")
                  + (thrownText.isEmpty ? "" : "; thrown: \(thrownText)"))
            if !accepted.isEmpty {
                print("          accepted |ΔΔq/Δq| (%): \(quantiles(accepted.compactMap(\.dqError).map { $0 * 100 }))")
                print("          accepted centre (px):  \(quantiles(accepted.compactMap(\.centreError)))")
            }
            let refusedFitted = these.filter { !$0.accepted && $0.dqError != nil }
            if !refusedFitted.isEmpty {
                print("          refused, had it been accepted, |ΔΔq/Δq| (%): \(quantiles(refusedFitted.compactMap(\.dqError).map { $0 * 100 }))")
            }
        }
        if !swiftVsScipyRadius.isEmpty {
            print("  info  Swift against scipy's optimum of the same model, clean tier, profile fits only (\(swiftVsScipyRadius.count); scipy has no MAD refit): radius "
                  + quantiles(swiftVsScipyRadius.map { $0 * 100 }) + " %; centre " + quantiles(swiftVsScipyCentre) + " px")
        }

        if report.failures > 0 {
            print("ring-fit-parity: \(report.failures) FAILURES in \(report.checks) checks")
            exit(1)
        }
        print("ring-fit-parity: all passed — \(report.checks) checks over \(cases.count) cases")
    }
}
