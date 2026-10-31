// tools/parity/diffraction-room-parity/main.swift — the Diffraction room's core (slice 1a: TEMCore/Diffraction, Package.swift's
// DiffractionRoomParity target over DiffractoKit's three modules) against reference.py's numpy and decimal
// tables and plants.py's planted rings (archive: roadmap-registrations-2026-10-15.md "Diffraction room, slice 1a" and its addendum).
//
//     harness <plants-out> <reference-out> <crystal-structures-dir>
//
// Checks, by kind (each failure a line "  FAIL  <kind> <case>: ..."; run.sh's controls look for the kind):
//   R1  ellipse         RingOverlay.ellipse(of:) equals the kit's fit exactly (x = column = centerQY, y = row = centerQX) and the
//                       centre is within 0.05 px of the plant's; on-fit: the 180-point polyline lies on the fitted ellipse (1e-9 px);
//                       on-truth: it lies within 0.5 px of the planted ring (predicted 0.3 px; the worst is printed);
//                       distance-helper: RingOverlay.distance equals reference.py's exact distances (1e-9 px) on 576 points.
//   R2  pin             RingCalibration.fit == calibrating(fitRing(...)) on every one of the 275 ring_fit_plants.py plants, with and
//                       without V (RingFitCalibration ==; equal error text where thrown).
//   R3  q, radius, roundtrip, cal-ring, linear, invalid   RingScale (the kit's closed forms; Δq·R without a beam energy) on 320 cases
//   R4  radius, ellipse, on-truth   the predicted rings: radius per family, the scaled ellipse, the polyline on the planted ring 2
//   R5  spelling, reject, invalid-value, fit-vs-file       the file's reciprocal scale and the fit-vs-file difference
//   R6  verdict, family, sigma-q, delta, delta-pct, abs-dd, z, odds, margin, d   indexing as displayed: 2646 T1 plants, 25 T4
//   R7  standard, count, family     Au, Al, Si (and Mg, Cu3Au-occ as controls) at k_max 1.2 and 2.0
//   R9  hash, read, refuse, cap, text   CrystalLoading on the kit's CIFs and the planted byte files
// Printed, never gated: the worst figures of each section.
//
// MACTEM_PARITY_SECTIONS=R1,R3,... runs only those (default all); MACTEM_PARITY_ONLY=<plant>[,<plant>...] restricts the fitted
// plants (R1, R2, R4) to those names. MACTEM_PARITY_MUTATE=<name> breaks the code under test on purpose, EMULATED on the outputs
// of the core's functions or on what is passed to them (the core has no option to break); run.sh requires each to exit 1 with its
// named kind among the failures. Unknown names exit 64.
//   R1: xy-swap ab-swap theta-sign theta-deg corner-offset            R2: v-default refusals-noV annulus-sum radius-a accept-sparse sigma-swap
//   R3: small-angle no-half kv-as-v two-pi linear-with-V              R4: g-over-dq offsets-kept image-centre
//   R5: x10 x2pi mrad-no-lambda ratio-inverted                         R6: delta-over-measured pct-x10 tol-fraction odds-margin z-no-tol sigma-pct
//   R7: au-4.0872 no-diamond occupancy-ignored                         R9: fp-reencoded cap-off-by-one

@testable import TEMCore
import Foundation
import DiffractoCore
import DiffractoScattering
import DiffractoGeometry
import ImagoCore

let mutations = [
    "xy-swap", "ab-swap", "theta-sign", "theta-deg", "corner-offset",
    "v-default", "refusals-noV", "annulus-sum", "radius-a", "accept-sparse", "sigma-swap",
    "small-angle", "no-half", "kv-as-v", "two-pi", "linear-with-V",
    "g-over-dq", "offsets-kept", "image-centre",
    "x10", "x2pi", "mrad-no-lambda", "ratio-inverted",
    "delta-over-measured", "pct-x10", "tol-fraction", "odds-margin", "z-no-tol", "sigma-pct",
    "au-4.0872", "no-diamond", "occupancy-ignored",
    "fp-reencoded", "cap-off-by-one",
]

// MARK: Report

struct Report {
    private(set) var failures = 0
    private(set) var checks = 0
    private var printed: [String: Int] = [:]
    private var failedKinds: [String: Int] = [:]
    mutating func check(_ ok: Bool, _ kind: String, _ name: String, _ detail: @autoclosure () -> String) {
        checks += 1
        if ok { return }
        failures += 1
        failedKinds[kind, default: 0] += 1
        if printed[kind, default: 0] < 6 {
            printed[kind, default: 0] += 1
            print("  FAIL  \(kind) \(name): \(detail())")
        }
    }
    func summary() -> String {
        failedKinds.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
    }
}

// MARK: JSON

func num(_ v: Any?) -> Double {
    if let s = v as? String {
        switch s {
        case "NaN": return .nan
        case "Infinity": return .infinity
        case "-Infinity": return -.infinity
        default: return Double(s) ?? .nan
        }
    }
    if let n = v as? NSNumber { return n.doubleValue }
    return .nan
}
func optNum(_ v: Any?) -> Double? { (v == nil || v is NSNull) ? nil : num(v) }
func dict(_ v: Any?) -> [String: Any] { (v as? [String: Any]) ?? [:] }
func list(_ v: Any?) -> [[String: Any]] { (v as? [[String: Any]]) ?? [] }
func str(_ v: Any?) -> String { (v as? String) ?? "" }
func int(_ v: Any?) -> Int { (v as? String).flatMap { Int($0) } ?? -99 }
func ints(_ v: Any?) -> [Int] { ((v as? [Any]) ?? []).compactMap { ($0 as? String).flatMap { Int($0) } } }

/// Reads a JSON file with every number literal turned into a string first, so that `num` parses each with `Double(String)`, which
/// rounds correctly. `JSONSerialization` reads a 17-digit literal through a decimal and returns a double that is one ulp off for
/// some of reference.py's `%.17g` values (the R3 linear products), which a bit-for-bit check cannot tolerate.
func readJSON(_ url: URL) throws -> [String: Any] {
    let bytes = Array(try Data(contentsOf: url))
    var out: [UInt8] = []
    out.reserveCapacity(bytes.count + bytes.count / 4)
    var i = 0, inString = false
    func isNumberByte(_ b: UInt8) -> Bool { (b >= 0x30 && b <= 0x39) || b == 0x2D || b == 0x2B || b == 0x2E || b == 0x65 || b == 0x45 }
    while i < bytes.count {
        let b = bytes[i]
        if inString {
            out.append(b)
            if b == 0x5C, i + 1 < bytes.count { out.append(bytes[i + 1]); i += 2; continue }
            if b == 0x22 { inString = false }
            i += 1
        } else if b == 0x22 {
            inString = true; out.append(b); i += 1
        } else if (b >= 0x30 && b <= 0x39) || b == 0x2D {   // a number starts with a digit or a minus; 'e' alone is true/false/null
            var j = i
            while j < bytes.count, isNumberByte(bytes[j]) { j += 1 }
            out.append(0x22); out.append(contentsOf: bytes[i..<j]); out.append(0x22)
            i = j
        } else {
            out.append(b); i += 1
        }
    }
    return dict(try JSONSerialization.jsonObject(with: Data(out)))
}

func rel(_ x: Double, _ truth: Double) -> Double {
    if x.isNaN || truth.isNaN { return x.isNaN && truth.isNaN ? 0 : .infinity }
    if x == truth { return 0 }
    return abs(x - truth) / max(abs(truth), Double.leastNormalMagnitude)
}
func close(_ x: Double, _ truth: Double, _ tol: Double) -> Bool { rel(x, truth) <= tol }
/// Relative `tol` plus an absolute floor: where the reference's quantity is exactly 0 (a plant at s = 0 is built on the reference's own
/// g), the kit's g differs from numpy's by an ulp of g, so g/q - 1 is 2.2e-16 and z is that over the relative tolerance.
func closeFloor(_ x: Double, _ truth: Double, _ tol: Double, floor: Double) -> Bool {
    if x.isNaN || truth.isNaN { return x.isNaN && truth.isNaN }
    return abs(x - truth) <= tol * abs(truth) + floor
}

// MARK: Concurrency (at most 4 workers)

final class Slots<T: Sendable>: @unchecked Sendable {
    private var items: [T?]
    private let lock = NSLock()
    init(_ n: Int) { items = Array(repeating: nil, count: n) }
    func set(_ i: Int, _ v: T) { lock.lock(); items[i] = v; lock.unlock() }
    func get(_ i: Int) -> T? { lock.lock(); defer { lock.unlock() }; return items[i] }
}

func parallel(_ n: Int, _ body: @escaping @Sendable (Int) -> Void) {
    let workers = 4
    DispatchQueue.concurrentPerform(iterations: workers) { w in
        var i = w
        while i < n { body(i); i += workers }
    }
}

func attempt<T>(_ f: () throws -> T) -> Result<T, any Error> {
    do { return .success(try f()) } catch { return .failure(error) }
}

func errorText(_ e: any Error) -> String { "\(type(of: e)): \(e.localizedDescription)" }
func failureText<T>(_ r: Result<T, any Error>) -> String { if case .failure(let e) = r { return errorText(e) }; return "no failure" }

// MARK: Fitted plants (R1, R2, R4)

struct Job: Sendable {
    let name: String
    let rows: Int, cols: Int
    let pixels: [Float]
    let guessRow: Double, guessCol: Double
    let inner: Double, outer: Double
    /// R2 only: nil for a job that is not an R2 plant.
    let d: Double?
    let volts: Double?
    let pitch: Double?
    var pattern: DiffractoGeometry.DiffractionPattern { DiffractoGeometry.DiffractionPattern(width: cols, height: rows, pixels: pixels) }
}

struct JobOut: Sendable {
    var ring: Result<RingRadiusFit, any Error>?
    var fitV: Result<RingFitCalibration, any Error>?
    var fitNoV: Result<RingFitCalibration, any Error>?
    var compV: Result<RingFitCalibration, any Error>?
    var compNoV: Result<RingFitCalibration, any Error>?
}

func loadJob(_ plantsDir: URL, _ c: [String: Any], needD: Bool) throws -> Job {
    let data = try Data(contentsOf: plantsDir.appendingPathComponent(str(c["file"])))
    let pixels = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    let rows = int(c["rows"]), cols = int(c["cols"])
    precondition(pixels.count == rows * cols, "\(str(c["name"])): \(pixels.count) pixels")
    return Job(name: str(c["name"]), rows: rows, cols: cols, pixels: pixels,
               guessRow: num(c["guess_row"]), guessCol: num(c["guess_col"]), inner: num(c["inner"]), outer: num(c["outer"]),
               d: needD ? num(c["d"]) : nil, volts: needD ? optNum(c["volts"]) : nil, pitch: needD ? num(c["pitch_mm"]) : nil)
}

/// The room's calls around the kit with one change (R2's controls). `ring` is the real `fitRing` result.
func composition(_ job: Job, ring: RingRadiusFit, volts: Double?, mutation: String?) throws -> RingFitCalibration {
    let d = job.d!, pitch = job.pitch!
    guard let m = mutation, ["v-default", "refusals-noV", "annulus-sum", "radius-a", "accept-sparse", "sigma-swap"].contains(m) else {
        return try RingCalibration.calibrating(ring, d: d, highTensionVolts: volts, pixelPitchMM: pitch)
    }
    if m == "v-default" {
        return try RingCalibration.calibrating(ring, d: d, highTensionVolts: volts ?? 200_000, pixelPitchMM: pitch)
    }
    var base = ring
    if m == "accept-sparse" {
        let fit: EllipseCalibrationFit
        do {
            fit = try EllipseCalibration.fitBestAvailable(
                pattern: job.pattern, centerQX: job.guessRow, centerQY: job.guessCol, innerRadius: job.inner, outerRadius: job.outer,
                acceptSparseCoverage: true, requireRingEvidence: true)
        } catch EllipseCalibration.FitError.insufficientAngularCoverage(let bins) {
            return try RingCalibration.calibrating(
                RingRadiusFit(fit: nil, report: nil, refusals: [.insufficientAngularCoverage(occupiedBins: bins)]),
                d: d, highTensionVolts: volts, pixelPitchMM: pitch)
        }
        let report = RingCalibration.FitReport(
            model: fit.model, semiAxisA: fit.a, semiAxisB: fit.b, occupiedAngularBins: fit.occupiedAngularBins,
            sparseCoverage: fit.sparseCoverage, normalizedResidual: fit.normalizedResidual,
            innerSigma: fit.profile?.innerSigma, outerSigma: fit.profile?.outerSigma, annulusWidth: job.outer - job.inner,
            annulusInnerRadius: job.inner, annulusOuterRadius: job.outer, ringEvidence: fit.ringEvidence)
        // The kit's own `refusals` adds `.noHighTension` for a missing V; `calibrating` would add it again, so the V it is given is non-nil.
        base = RingRadiusFit(fit: fit, report: report, refusals: RingCalibration.refusals(report, highTensionVolts: volts ?? 200_000))
        return try RingCalibration.calibrating(base, d: d, highTensionVolts: volts, pixelPitchMM: pitch)
    }
    var report = base.report
    if m == "annulus-sum", var r = report { r.annulusWidth = (r.annulusOuterRadius ?? 0) + (r.annulusInnerRadius ?? 0); report = r }
    if m == "sigma-swap", var r = report { swap(&r.innerSigma, &r.outerSigma); report = r }
    var refused = base.refusals
    if m == "refusals-noV" || volts == nil, refused.first?.name != "invalidInput" { refused.append(.noHighTension) }
    guard let rep = report, !refused.contains(where: \.withholdsDeltaQ) else {
        return RingFitCalibration(fit: base.fit, report: report, refusals: refused, calibration: nil)
    }
    let radius = m == "radius-a" ? (base.fit?.a ?? rep.radius) : rep.radius
    let calibration = try RingCalibration.calibrate(radius: radius, d: d, highTensionVolts: volts, pixelPitchMM: pitch)
    return RingFitCalibration(fit: base.fit, report: report, refusals: refused, calibration: calibration)
}

func runJob(_ job: Job, wantR2: Bool, mutation: String?) -> JobOut {
    var out = JobOut()
    let pattern = job.pattern
    let ring = attempt {
        try RingCalibration.fitRing(pattern: pattern, centerQX: job.guessRow, centerQY: job.guessCol,
                                    innerRadius: job.inner, outerRadius: job.outer)
    }
    out.ring = ring
    guard wantR2, let d = job.d, let pitch = job.pitch else { return out }
    for (volts, isV) in [(job.volts, true), (nil, false)] as [(Double?, Bool)] {
        let fitted = attempt {
            try RingCalibration.fit(pattern: pattern, centerQX: job.guessRow, centerQY: job.guessCol, innerRadius: job.inner,
                                    outerRadius: job.outer, d: d, highTensionVolts: volts, pixelPitchMM: pitch)
        }
        let composed: Result<RingFitCalibration, any Error>
        switch ring {
        case .success(let r): composed = attempt { try composition(job, ring: r, volts: volts, mutation: mutation) }
        case .failure(let e): composed = .failure(e)
        }
        if isV { out.fitV = fitted; out.compV = composed } else { out.fitNoV = fitted; out.compNoV = composed }
    }
    return out
}

func sameOutcome(_ a: Result<RingFitCalibration, any Error>?, _ b: Result<RingFitCalibration, any Error>?) -> (Bool, String) {
    switch (a, b) {
    case (.success(let x)?, .success(let y)?): return (x == y, x == y ? "" : "fit and composition differ: refusals \(x.refusals.map(\.name)) vs \(y.refusals.map(\.name)); dq \(x.calibration?.deltaQ ?? .nan) vs \(y.calibration?.deltaQ ?? .nan); report equal \(x.report == y.report)")
    case (.failure(let x)?, .failure(let y)?): return (errorText(x) == errorText(y), "error text \(errorText(x)) vs \(errorText(y))")
    default: return (false, "one threw and the other did not")
    }
}

// MARK: R1 and R4 helpers

func mutated(_ e: RingEllipse, _ m: String?) -> RingEllipse {
    var r = e
    switch m {
    case "xy-swap": r.x = e.y; r.y = e.x
    case "ab-swap": r.a = e.b; r.b = e.a
    case "theta-sign": r.theta = -e.theta
    case "theta-deg": r.theta = e.theta * 180 / .pi
    case "corner-offset": r.x += 0.5; r.y += 0.5
    default: break
    }
    return r
}

func worstDistance(_ points: [SIMD2<Double>], to e: RingEllipse) -> Double {
    points.map { RingOverlay.distance(fromX: $0.x, y: $0.y, to: e) }.max() ?? .nan
}

// MARK: R7 structures

let cu3auOcc: CrystalStructure = {
    let fcc: [SIMD3<Double>] = [[0.5, 0.5, 0], [0.5, 0, 0.5], [0, 0.5, 0.5]]
    var sites = [AtomSite(z: 79, fractional: [0, 0, 0], occupancy: 0.6), AtomSite(z: 29, fractional: [0, 0, 0], occupancy: 0.4)]
    sites += fcc.map { AtomSite(z: 29, fractional: $0) }
    return CrystalStructure.detectingSymmetry(cell: .cubic(a: 3.75), sites: sites)
}()

func structure(named name: String, _ m: String?) -> CrystalStructure? {
    switch name {
    case "Au": return m == "au-4.0872" ? CrystalPresets.fcc(a: 4.0872, z: 79) : StandardCrystals.named("Au")?.structure
    case "Al": return StandardCrystals.named("Al")?.structure
    case "Si": return m == "no-diamond" ? CrystalPresets.fcc(a: 5.4309, z: 14) : StandardCrystals.named("Si")?.structure
    case "Mg": return CrystalPresets.magnesium
    case "Cu3Au-occ":
        guard m == "occupancy-ignored" else { return cu3auOcc }
        return CrystalStructure.detectingSymmetry(cell: .cubic(a: 3.75), sites: cu3auOcc.sites.map { AtomSite(z: $0.z, fractional: $0.fractional) })
    default: return nil
    }
}

// MARK: R9

/// What the harness reads of a load: the kit's `LoadedCrystal` has no public initialiser, so the mutated fingerprint travels in this.
struct LoadedFingerprint { let sha256: String; let byteCount: Int; let structure: CrystalStructure; let displayName: String }

func mutatedLoad(_ bytes: Data, fileName: String, _ m: String?) throws -> LoadedFingerprint {
    if m == "cap-off-by-one", bytes.count >= CrystalLoading.maximumBytes { throw CrystalLoading.Refusal.tooLarge(bytes: bytes.count) }
    let real = try CrystalLoading.load(bytes: bytes, fileName: fileName)
    guard m == "fp-reencoded", let text = String(data: bytes, encoding: .utf8) else { return LoadedFingerprint(sha256: real.sha256, byteCount: real.byteCount, structure: real.structure, displayName: real.displayName) }
    // The fingerprint of the decoded text re-encoded, not of the file's bytes.
    let reencoded = Data(text.precomposedStringWithCanonicalMapping.replacingOccurrences(of: "\r\n", with: "\n").utf8)
    return LoadedFingerprint(sha256: CrystalLoading.fingerprint(of: reencoded), byteCount: real.byteCount, structure: real.structure, displayName: real.displayName)
}

// MARK: Main

@main
struct Harness {
    static func main() throws {
        let args = CommandLine.arguments
        guard args.count == 4 else {
            print("usage: harness <plants-out> <reference-out> <crystal-structures-dir>")
            exit(64)
        }
        let plantsDir = URL(fileURLWithPath: args[1]), refDir = URL(fileURLWithPath: args[2])
        let environment = ProcessInfo.processInfo.environment
        let mutation = environment["MACTEM_PARITY_MUTATE"]
        if let mutation, !mutations.contains(mutation) {
            print("diffraction-room-parity: unknown mutation '\(mutation)'")
            exit(64)
        }
        let sections = environment["MACTEM_PARITY_SECTIONS"].map { Set($0.split(separator: ",").map(String.init)) }
            ?? ["R1", "R2", "R3", "R4", "R5", "R6", "R7", "R9"]
        let only = environment["MACTEM_PARITY_ONLY"].map { Set($0.split(separator: ",").map(String.init)) }
        func wants(_ s: String) -> Bool { sections.contains(s) }
        func plantWanted(_ name: String) -> Bool { only?.contains(name) ?? true }

        let ref = try readJSON(refDir.appendingPathComponent("reference.json"))
        let manifest = try readJSON(plantsDir.appendingPathComponent("manifest.json"))
        let rfp = try readJSON(plantsDir.appendingPathComponent("rfp/planted.json"))
        var report = Report()
        print("diffraction-room-parity: reference numpy \(str(ref["numpy"]))\(mutation.map { "; MUTATION \($0)" } ?? "")")
        // The manifest's tolerance must be the registered 1e-12 at most (a loosened manifest cannot pass).
        report.check(num(ref["tolerance"]) <= 1e-12, "R0 tolerance", "manifest", "tolerance \(num(ref["tolerance"])) > 1e-12")
        let tol = 1e-12

        // ---- the fits, in parallel
        var jobs: [Job] = []
        var jobIndex: [String: Int] = [:]
        var wantsR2: [Bool] = []
        func add(_ job: Job, r2: Bool) {
            if let i = jobIndex[job.name] { wantsR2[i] = wantsR2[i] || r2; return }
            jobIndex[job.name] = jobs.count
            jobs.append(job)
            wantsR2.append(r2)
        }
        let r1Plants = list(manifest["r1"]).filter { plantWanted(str($0["name"])) }
        let r4Plants = list(manifest["r4"]).filter { plantWanted(str($0["name"])) }
        let r2Plants = list(rfp["cases"]).filter { plantWanted(str($0["name"])) }
        if wants("R2") {
            for c in r2Plants {
                var plant = c
                plant["file"] = "rfp/" + str(c["file"])
                add(try loadJob(plantsDir, plant, needD: true), r2: true)
            }
        }
        if wants("R1") { for c in r1Plants { add(try loadJob(plantsDir, c, needD: false), r2: false) } }
        if wants("R4") {
            // Ring 1 is fitted in the annulus the room's click rule gives (half-width 10 px about the clicked radius), which keeps ring 2 out of it.
            for c in r4Plants {
                var plant = c
                plant["inner"] = c["rule_inner"]; plant["outer"] = c["rule_outer"]
                add(try loadJob(plantsDir, plant, needD: false), r2: false)
            }
        }
        // R1's clean plants are R2's plants: added after them, so the shared job keeps its d, V and pitch.
        let outs = Slots<JobOut>(jobs.count)
        let started = Date()
        if !jobs.isEmpty {
            let jobsCopy = jobs, wantsCopy = wantsR2
            parallel(jobsCopy.count) { i in outs.set(i, runJob(jobsCopy[i], wantR2: wantsCopy[i], mutation: mutation)) }
            print("  fits: \(jobs.count) plants (\(wantsR2.filter { $0 }.count) with the R2 pin) in \(Int(Date().timeIntervalSince(started))) s on 4 workers")
        }
        func out(_ name: String) -> JobOut? { jobIndex[name].flatMap { outs.get($0) } }

        // ---- R1
        if wants("R1") {
            var worstTruth = 0.0, worstCentre = 0.0, worstFit = 0.0
            for c in r1Plants {
                let name = str(c["name"])
                guard case .success(let ring)? = out(name)?.ring, let fit = ring.fit else {
                    report.check(false, "R1 ellipse", name, "no fit"); continue
                }
                let e0 = RingOverlay.ellipse(of: fit)
                let e = mutated(e0, mutation)
                report.check(e == RingEllipse(x: fit.centerQY, y: fit.centerQX, a: fit.a, b: fit.b, theta: fit.theta), "R1 ellipse", name,
                             "x \(e.x) y \(e.y) a \(e.a) b \(e.b) theta \(e.theta); the kit's (row \(fit.centerQX), column \(fit.centerQY), a \(fit.a), b \(fit.b), theta \(fit.theta))")
                let xt = num(c["x_truth"]), yt = num(c["y_truth"])
                let centre = max(abs(e.x - xt), abs(e.y - yt))
                // The 0.05 px centre band is the retired ring-fit harness's, gated there on whole rings; a plant with a 60 degree gap is held to the 0.5 px polyline band only.
                let whole = (optNum(c["gap_deg"]) ?? 0) == 0
                if whole { worstCentre = max(worstCentre, centre) }
                report.check(centre <= 0.05 || !whole, "R1 ellipse", name, String(format: "centre (x %.4f, y %.4f), planted (%.4f, %.4f): %.4f px", e.x, e.y, xt, yt, centre))
                let points = RingOverlay.polyline(e)
                report.check(points.count == RingOverlay.polylinePoints, "R1 on-fit", name, "\(points.count) points")
                let onFit = worstDistance(points, to: RingEllipse(x: fit.centerQY, y: fit.centerQX, a: fit.a, b: fit.b, theta: fit.theta))
                worstFit = max(worstFit, onFit)
                report.check(onFit <= 1e-9, "R1 on-fit", name, "worst \(onFit) px from the fitted ellipse")
                let truth = RingEllipse(x: xt, y: yt, a: num(c["a"]), b: num(c["b"]), theta: optNum(c["theta"]) ?? 0)
                let onTruth = worstDistance(points, to: truth)
                worstTruth = max(worstTruth, onTruth)
                report.check(onTruth <= 0.5, "R1 on-truth", name, String(format: "worst %.4f px from the planted ring", onTruth))
            }
            var worstHelper = 0.0
            var helperPoints = 0
            for v in list(ref["ellipse_distance_vectors"]) {
                let e = RingEllipse(x: num(v["cx"]), y: num(v["cy"]), a: num(v["a"]), b: num(v["b"]), theta: num(v["theta"]))
                let pts = (v["points"] as? [[Any]]) ?? [], want = (v["distance"] as? [Any]) ?? []
                for (p, w) in zip(pts, want) {
                    let got = RingOverlay.distance(fromX: num(p[0]), y: num(p[1]), to: e)
                    worstHelper = max(worstHelper, abs(got - num(w)))
                    helperPoints += 1
                    report.check(abs(got - num(w)) <= 1e-9, "R1 distance-helper", "ellipse", "distance \(got), exact \(num(w))")
                }
            }
            print("  R1: \(r1Plants.count) plants; worst centre error \(String(format: "%.4f", worstCentre)) px on whole rings, polyline off the fit \(String(format: "%.1e", worstFit)) px, off the planted ring \(String(format: "%.4f", worstTruth)) px (predicted 0.3, band 0.5); distance helper \(helperPoints) points worst \(String(format: "%.1e", worstHelper)) px")
        }

        // ---- R2
        if wants("R2") {
            var equal = 0, thrown = 0, total = 0
            for c in r2Plants {
                let name = str(c["name"])
                guard let o = out(name) else { continue }
                for (a, b, label) in [(o.fitV, o.compV, "V"), (o.fitNoV, o.compNoV, "no V")] {
                    let (ok, why) = sameOutcome(a, b)
                    total += 1
                    if ok { equal += 1 }
                    if case .failure? = a { thrown += 1 }
                    report.check(ok, "R2 pin", name, "(\(label)) \(why)")
                }
            }
            print("  R2: \(equal) of \(total) fit == calibrating(fitRing) comparisons equal over \(r2Plants.count) plants, with and without V (\(thrown) thrown, equal text)")
        }

        // ---- R3
        let r3 = dict(ref["r3"])
        let cases = list(r3["cases"])
        func calibration(_ c: [String: Any], volts: Double?) -> RingCalibration? {
            try? RingCalibration.calibrate(radius: num(c["r_cal_px"]), d: num(c["d_A"]), highTensionVolts: volts, pixelPitchMM: num(c["pitch_mm"]))
        }
        func qOf(_ r: Double, _ cal: RingCalibration) -> Double {
            let q = RingScale.q(radius: r, calibration: cal)
            guard let L = cal.lengthPixels, let lam = cal.wavelengthAngstroms else { return q }
            switch mutation {
            case "small-angle": return r / L / lam
            case "no-half": return 2 * sin(atan2(r, L)) / lam
            case "two-pi": return q * 2 * .pi
            case "linear-with-V": return RingScale.linear(radius: r, deltaQ: cal.deltaQ)
            default: return q
            }
        }
        if wants("R3") {
            var worstQ = 0.0, worstR = 0.0, worstTrip = 0.0, worstCal = 0.0
            for c in cases {
                let name = str(c["name"])
                let kv = num(c["kv"])
                let volts = mutation == "kv-as-v" ? kv : num(c["volts"])
                guard let cal = calibration(c, volts: volts), let L = cal.lengthPixels, let lam = cal.wavelengthAngstroms,
                      let calNoV = calibration(c, volts: nil) else {
                    report.check(false, "R3 q", name, "no calibration"); continue
                }
                report.check(close(L, num(c["l_px"]), tol) && close(lam, num(c["lambda_A"]), tol), "R3 q", name,
                             "calibrate gives L \(L), lambda \(lam); reference \(num(c["l_px"])), \(num(c["lambda_A"]))")
                for query in list(c["queries"]) {
                    let r = num(query["r_px"])
                    let want = num(query["q"])
                    let got = qOf(r, cal)
                    let direct = RingCalibration.q(radius: r, cameraLengthPixels: num(c["l_px"]), wavelengthAngstroms: num(c["lambda_A"]))
                    worstQ = max(worstQ, rel(got, want), rel(direct, want))
                    report.check(close(got, want, tol) && close(direct, want, tol), "R3 q", name, "R \(r): q \(got) (kit direct \(direct)), reference \(want)")
                    let rBack = RingScale.radius(q: want, calibration: cal)
                    let wantR = num(query["r_from_q"])
                    worstR = max(worstR, rel(rBack, wantR))
                    report.check(close(rBack, wantR, tol), "R3 radius", name, "q \(want): R \(rBack), reference \(wantR)")
                    let trip = RingScale.radius(q: got, calibration: cal)
                    worstTrip = max(worstTrip, abs(trip - r))
                    report.check(abs(trip - r) <= 1e-9 || r > 2000, "R3 roundtrip", name, "R \(r) -> q \(got) -> R \(trip)")
                    let linearRef = num(query["linear"])
                    report.check(RingScale.linear(radius: r, deltaQ: num(c["dq"])) == linearRef, "R3 linear", name,
                                 "R \(r): \(RingScale.linear(radius: r, deltaQ: num(c["dq"]))) vs \(linearRef)")
                    let noV = RingScale.q(radius: r, calibration: calNoV)
                    report.check(noV == calNoV.deltaQ * r && close(noV, linearRef, tol), "R3 linear", name,
                                 "no beam energy, R \(r): q \(noV), deltaQ * R \(calNoV.deltaQ * r), reference \(linearRef)")
                }
                let ring = qOf(num(c["r_cal_px"]), cal)
                worstCal = max(worstCal, rel(ring, num(c["inv_d"])))
                report.check(close(ring, num(c["inv_d"]), tol), "R3 cal-ring", name, "q at the calibrating ring \(ring), 1/d \(num(c["inv_d"]))")
            }
            for (i, v) in list(r3["invalid"]).enumerated() {
                let got: Double
                if str(v["fn"]) == "q" {
                    got = RingCalibration.q(radius: num(v["r"]), cameraLengthPixels: num(v["l"]), wavelengthAngstroms: num(v["lam"]))
                } else {
                    got = RingCalibration.radius(q: num(v["q"]), cameraLengthPixels: num(v["l"]), wavelengthAngstroms: num(v["lam"]))
                }
                report.check(got.isNaN, "R3 invalid", "#\(i) \(str(v["fn"]))", "\(v) gives \(got), expected NaN")
            }
            print("  R3: \(cases.count) cases x \((r3["query_radii"] as? [Any])?.count ?? 0) radii: worst q \(String(format: "%.1e", worstQ)), R(q) \(String(format: "%.1e", worstR)), round trip \(String(format: "%.1e", worstTrip)) px, calibrating ring \(String(format: "%.1e", worstCal)) relative; \(list(r3["invalid"]).count) invalid inputs NaN")
        }

        // ---- R4
        let r4 = dict(ref["r4"])
        if wants("R4") {
            var worstRadius = 0.0
            for rec in list(r4["radii"]) {
                guard let c = cases.first(where: { str($0["name"]) == str(rec["case"]) }), let cal = calibration(c, volts: num(c["volts"])) else {
                    report.check(false, "R4 radius", str(rec["case"]), "no calibration"); continue
                }
                var got = RingScale.radius(q: num(rec["g"]), calibration: cal)
                if mutation == "g-over-dq" { got = num(rec["g"]) / cal.deltaQ }
                let direct = RingCalibration.radius(q: num(rec["g"]), cameraLengthPixels: num(rec["l_px"]), wavelengthAngstroms: num(rec["lambda_A"]))
                worstRadius = max(worstRadius, rel(got, num(rec["r_px"])), rel(direct, num(rec["r_px"])))
                report.check(close(got, num(rec["r_px"]), tol) && close(direct, num(rec["r_px"]), tol), "R4 radius", "\(str(rec["case"])) \(str(rec["family"]))",
                             "R(g) \(got) (kit direct \(direct)), reference \(num(rec["r_px"]))")
            }
            var worstEllipse = 0.0, worstOnTruth = 0.0, noCal = 0
            let reference = list(r4["ellipses"])
            for c in r4Plants {
                let name = str(c["name"])
                guard let want = reference.first(where: { str($0["name"]) == name }) else {
                    report.check(false, "R4 ellipse", name, "no reference ellipse"); continue
                }
                // The closed form from the PLANTED ring 1: both axes times R(g2) / R1, b/a and theta kept.
                let planted1 = RingEllipse(x: num(c["x_truth"]), y: num(c["y_truth"]), a: num(c["a"]), b: num(c["b"]), theta: num(c["theta"]))
                if let p = RingOverlay.predicted(from: planted1, radius: num(want["r_px"])) {
                    worstEllipse = max(worstEllipse, rel(p.a, num(want["a"])), rel(p.b, num(want["b"])))
                    report.check(close(p.a, num(want["a"]), tol) && close(p.b, num(want["b"]), tol) && p.x == planted1.x && p.y == planted1.y
                                 && p.theta == planted1.theta && close(p.b / p.a, num(want["b_over_a"]), tol), "R4 ellipse", name,
                                 "a \(p.a) b \(p.b); reference a \(num(want["a"])) b \(num(want["b"]))")
                } else {
                    report.check(false, "R4 ellipse", name, "no predicted ellipse")
                }
                // The end-to-end route: fit ring 1, calibrate with its d, predict ring 2 from |q| = 1/d2.
                guard case .success(let ring)? = out(name)?.ring, let fit = ring.fit else {
                    noCal += 1
                    report.check(false, "R4 on-truth", name, "ring 1 was not fitted: \(failureText(out(name)?.ring ?? .failure(CrystalLoading.Refusal.notUTF8))) \((try? out(name)?.ring?.get())?.refusals.map(\.name) ?? [])")
                    continue
                }
                let calibrated = try RingCalibration.calibrating(ring, d: num(c["d1"]), highTensionVolts: num(c["volts"]), pixelPitchMM: num(c["pitch_mm"]))
                guard let cal = calibrated.calibration else {
                    noCal += 1
                    report.check(false, "R4 on-truth", name, "ring 1 was not calibrated: refusals \(calibrated.refusals.map(\.name))")
                    continue
                }
                let ring1 = RingOverlay.ellipse(of: fit)
                var r2 = RingScale.radius(q: 1 / num(c["d2"]), calibration: cal)
                if mutation == "g-over-dq" { r2 = (1 / num(c["d2"])) / cal.deltaQ }
                guard var predicted = RingOverlay.predicted(from: ring1, radius: r2) else {
                    report.check(false, "R4 on-truth", name, "no predicted ellipse for R \(r2)"); continue
                }
                if mutation == "offsets-kept" { predicted.a = ring1.a + (r2 - ring1.radius); predicted.b = ring1.b + (r2 - ring1.radius) }
                if mutation == "image-centre" { predicted.x = Double(int(c["cols"])) / 2; predicted.y = Double(int(c["rows"])) / 2 }
                let truth2 = RingEllipse(x: num(c["ring2_c0"]), y: num(c["ring2_r0"]), a: num(c["ring2_a"]), b: num(c["ring2_b"]), theta: num(c["ring2_theta"]))
                let off = worstDistance(RingOverlay.polyline(predicted), to: truth2)
                worstOnTruth = max(worstOnTruth, off)
                report.check(off <= 0.5, "R4 on-truth", name, String(format: "predicted ring 2 worst %.4f px from the planted ring (R %.3f, planted %.3f)", off, r2, num(c["ring2_R"])))
            }
            print("  R4: \(list(r4["radii"]).count) radii worst \(String(format: "%.1e", worstRadius)) relative; \(r4Plants.count) plants: scaled ellipse worst \(String(format: "%.1e", worstEllipse)), predicted polyline worst \(String(format: "%.4f", worstOnTruth)) px from the planted ring 2 (band 0.5), \(noCal) not calibrated")
        }

        // ---- R5
        let r5 = dict(ref["r5"])
        if wants("R5") {
            func scale(_ rec: [String: Any]) -> Double? {
                let units = rec["unit"] is NSNull ? nil : str(rec["unit"])
                let lam = optNum(rec["lambda_A"])
                var s = LengthUnit.reciprocalAngstromsPerPixel(scale: num(rec["value"]), unit: units, wavelengthAngstrom: lam)
                switch mutation {
                case "x10": s = s.map { $0 * 10 }
                case "x2pi": s = s.map { $0 * 2 * .pi }
                case "mrad-no-lambda":
                    if s == nil, LengthUnit.normalized(units) == "mrad", lam == nil, num(rec["value"]).isFinite, num(rec["value"]) > 0 {
                        s = num(rec["value"]) / (1000 * 0.0251)
                    }
                default: break
                }
                return s
            }
            func agree(_ got: Double?, _ want: Double?) -> Bool {
                switch (got, want) {
                case (nil, nil): return true
                case (let g?, let w?): return close(g, w, tol)
                default: return false
                }
            }
            for (i, rec) in list(r5["spellings"]).enumerated() {
                let want = optNum(rec["expect"]), got = scale(rec)
                report.check(agree(got, want), "R5 spelling", "#\(i) \(rec["unit"] ?? "nil") \(rec["family"] ?? "")", "\(String(describing: got)) vs \(String(describing: want))")
            }
            for (i, rec) in list(r5["rejects"]).enumerated() {
                let got = scale(rec)
                report.check(got == nil, "R5 reject", "#\(i) \(rec["unit"] ?? "nil")", "\(String(describing: got)), expected none")
            }
            for (i, rec) in list(r5["invalid_values"]).enumerated() {
                let got = scale(rec)
                report.check(got == nil, "R5 invalid-value", "#\(i) \(rec["unit"] ?? "nil") \(rec["value"] ?? "")", "\(String(describing: got)), expected none")
            }
            var worst = 0.0
            for (i, rec) in list(r5["fit_vs_file"]).enumerated() {
                var got = RingScale.fitVersusFile(fitDeltaQ: num(rec["fit_dq"]), fileDeltaQ: num(rec["file_dq"]))
                if mutation == "ratio-inverted" { got = num(rec["file_dq"]) / num(rec["fit_dq"]) - 1 }
                worst = max(worst, rel(got, num(rec["diff"])))
                report.check(close(got, num(rec["diff"]), tol), "R5 fit-vs-file", "#\(i)", "\(got) vs \(num(rec["diff"]))")
            }
            print("  R5: \(list(r5["spellings"]).count) spellings, \(list(r5["rejects"]).count) rejects, \(list(r5["invalid_values"]).count) invalid values, \(list(r5["fit_vs_file"]).count) fit-vs-file pairs (worst \(String(format: "%.1e", worst)) relative)")
        }

        // ---- R7 (before R6: R6 reads the same lists)
        let standards = list(dict(ref["r7"])["standards"])
        func kinematic(_ name: String, _ kmax: Double) -> KinematicReflectionList? {
            guard let s = structure(named: name, mutation) else { return nil }
            return try? s.kinematicReflections(kMax: kmax)
        }
        if wants("R7") {
            for (name, a) in [("Au", 4.0782), ("Al", 4.0495), ("Si", 5.4309)] {
                let got = StandardCrystals.named(name)?.latticeConstant
                report.check(got == a, "R7 standard", name, "lattice constant \(String(describing: got)), named reference \(a)")
            }
            report.check(StandardCrystals.all.map(\.name) == ["Au", "Al", "Si"], "R7 standard", "list", "\(StandardCrystals.all.map(\.name))")
            var worstD = 0.0, worstInt = 0.0
            for std in standards {
                let name = str(std["name"]), kmax = num(std["kmax"])
                let label = "\(name) k_max \(kmax)"
                guard let l = kinematic(name, kmax) else { report.check(false, "R7 count", label, "no list"); continue }
                // The room's own list for a standard is the same call (StandardCrystals.list), unmutated.
                if mutation == nil, let s = StandardCrystals.named(name), let own = try? StandardCrystals.list(of: s, kMax: kmax) {
                    report.check(own == l, "R7 count", label, "StandardCrystals.list differs from kinematicReflections")
                }
                let rows = list(std["rows"])
                report.check(l.families.count == int(std["families"]) && l.kept.count == int(std["reflections"]), "R7 count", label,
                             "\(l.families.count) families / \(l.kept.count) reflections; reference \(int(std["families"])) / \(int(std["reflections"]))")
                for (row, fam) in zip(rows, l.families) {
                    let f = fam.family
                    worstD = max(worstD, rel(f.d, num(row["d_closed"])))
                    worstInt = max(worstInt, rel(fam.intensity, num(row["intensity"])))
                    report.check(close(f.g, num(row["g"]), tol) && close(f.d, num(row["d_closed"]), tol) && close(f.d, num(row["d"]), tol), "R7 family", "\(label) #\(int(row["index"]))",
                                 "g \(f.g) d \(f.d); reference g \(num(row["g"])) d \(num(row["d_closed"]))")
                    report.check(f.multiplicity == int(row["multiplicity"]) && f.name == str(row["name"]), "R7 family", "\(label) #\(int(row["index"])) name",
                                 "\(f.name) x\(f.multiplicity); reference \(str(row["name"])) x\(int(row["multiplicity"]))")
                    report.check(close(fam.intensity, num(row["intensity"]), 1e-9), "R7 family", "\(label) #\(int(row["index"])) intensity", "\(fam.intensity) vs \(num(row["intensity"]))")
                }
            }
            let au = kinematic("Au", 2.0), si12 = kinematic("Si", 1.2), au12 = kinematic("Au", 1.2)
            print("  R7: Au {111} d \(au12?.families.first.map { String($0.family.d) } ?? "?") (a/sqrt(3) = \(4.0782 / 3.0.squareRoot())); family counts Au 1.2 \(au12?.families.count ?? -1), Au 2.0 \(au?.families.count ?? -1), Si 1.2 \(si12?.families.count ?? -1); worst d \(String(format: "%.1e", worstD)), intensity \(String(format: "%.1e", worstInt)) relative over \(standards.count) lists")
        }

        // ---- R6
        let r6 = dict(ref["r6"])
        if wants("R6") {
            var lists: [String: KinematicReflectionList] = [:]
            for crystal in ["Au", "Al", "Si"] { for kmax in [1.2, 2.0] { lists["\(crystal) \(kmax)"] = try? StandardCrystals.list(of: StandardCrystals.named(crystal)!, kMax: kmax) } }
            func indexOf(_ g: Double, in l: KinematicReflectionList) -> Int { l.families.firstIndex { $0.family.g == g } ?? -2 }
            func familyIndex(_ f: ReflectionFamily?, in l: KinematicReflectionList) -> Int { f.map { indexOf($0.g, in: l) } ?? -1 }
            func candidates(_ r: RingIndexing.Refusal?, in l: KinematicReflectionList) -> [Int] {
                guard case .ambiguous(let c)? = r else { return [] }
                return c.map { indexOf($0.family.g, in: l) }
            }
            func compare(_ record: [String: Any], _ l: KinematicReflectionList, _ label: String, families: [ReflectionFamily]? = nil) {
                // Read only, on this one thread: Swift 6.3 otherwise reports `rec` as sent into each check's message closure.
                nonisolated(unsafe) let rec = record
                let q = num(rec["q"])
                var tolPct = num(rec["tol_pct"])
                if mutation == "tol-fraction" { tolPct /= 100 }
                let k = num(rec["k"])
                let shown = families.map { IndexingDisplay.index(q: q, tolerancePercent: tolPct, families: $0, kMax: num(rec["kmax"]), coverage: k) }
                    ?? IndexingDisplay.index(q: q, tolerancePercent: tolPct, in: l, coverage: k)
                report.check(shown.verdict == str(rec["verdict"]), "R6 verdict", label, "\(shown.verdict) vs \(str(rec["verdict"]))")
                var sigma = shown.sigmaQ
                if mutation == "sigma-pct" { sigma = num(rec["tol_pct"]) }
                if q.isFinite, tolPct.isFinite, num(rec["tol_pct"]).isFinite {
                    report.check(close(sigma, num(rec["sigma_q"]), tol), "R6 sigma-q", label, "\(sigma) vs \(num(rec["sigma_q"]))")
                }
                // A custom list (one family, none) is compared by verdict and sigma only.
                guard families == nil else { return }
                if case .noneWithinTolerance(let nearest)? = shown.refusal {
                    report.check(familyIndex(nearest?.family, in: l) == int(rec["nearest"]), "R6 family", label, "nearest \(familyIndex(nearest?.family, in: l)) vs \(int(rec["nearest"]))")
                }
                if shown.verdict == "ambiguous" {
                    report.check(candidates(shown.refusal, in: l) == (ints(rec["payload"])), "R6 family", label,
                                 "candidates \(candidates(shown.refusal, in: l)) vs \(String(describing: rec["payload"]))")
                }
                guard let a = shown.assignment, shown.verdict == "accepted", str(rec["verdict"]) == "accepted" else { return }
                report.check(familyIndex(a.best.family, in: l) == int(rec["best"]) && (a.next.map { indexOf($0.family.g, in: l) } ?? -1) == int(rec["next"]), "R6 family", label,
                             "best \(familyIndex(a.best.family, in: l)) next \(a.next.map { indexOf($0.family.g, in: l) } ?? -1); reference \(int(rec["best"])), \(int(rec["next"]))")
                var delta = shown.deltaPercent! / 100
                if mutation == "delta-over-measured" { delta = (shown.dListed! - shown.dMeasured!) / shown.dMeasured! }
                var pct = shown.deltaPercent!
                if mutation == "pct-x10" { pct *= 10 }
                report.check(closeFloor(delta, num(rec["delta"]), tol, floor: 1e-15), "R6 delta", label, "\(delta) vs \(num(rec["delta"]))")
                report.check(closeFloor(pct, num(rec["delta_pct"]), tol, floor: 1e-13), "R6 delta-pct", label, "\(pct) vs \(num(rec["delta_pct"]))")
                report.check(closeFloor(shown.relativeDeltaD!, num(rec["abs_dd_over_d"]), tol, floor: 1e-15), "R6 abs-dd", label, "\(shown.relativeDeltaD!) vs \(num(rec["abs_dd_over_d"]))")
                report.check(close(shown.dListed!, num(rec["d_listed"]), tol) && close(shown.dMeasured!, num(rec["d_measured"]), tol), "R6 d", label,
                             "d \(shown.dListed!) / \(shown.dMeasured!) vs \(num(rec["d_listed"])) / \(num(rec["d_measured"]))")
                var z = shown.z!
                if mutation == "z-no-tol" { z *= shown.sigmaQ }
                report.check(closeFloor(z, num(rec["z"]), tol, floor: 1e-12), "R6 z", label, "\(z) vs \(num(rec["z"]))")
                if let margin = shown.margin {
                    report.check(close(margin, num(rec["margin"]), tol), "R6 margin", label, "\(margin) vs \(num(rec["margin"]))")
                    let beyond = (rec["odds_beyond_1e6"] as? Bool) ?? false
                    report.check(shown.oddsBeyondCap == beyond, "R6 odds", label, "beyond the cap \(shown.oddsBeyondCap) vs \(beyond)")
                    var odds = shown.odds!
                    if mutation == "odds-margin" { odds = margin }
                    if !beyond { report.check(close(odds, num(rec["odds"]), tol), "R6 odds", label, "\(odds) vs \(num(rec["odds"]))") }
                }
            }
            var n1 = 0
            for (i, rec) in list(r6["t1"]).enumerated() {
                guard let l = lists["\(str(rec["crystal"])) \(num(rec["kmax"]))"] else { report.check(false, "R6 verdict", "T1 #\(i)", "no list"); continue }
                compare(rec, l, "T1 #\(i) \(str(rec["crystal"])) \(str(rec["family_name"])) u \(num(rec["u"])) s \(num(rec["s"]))")
                n1 += 1
            }
            let auList = lists["Au 1.2"]!
            for (i, rec) in list(r6["t4"]).enumerated() {
                let gs = (rec["g"] as? [Any])?.map { num($0) } ?? []
                // The reference's custom lists are subsets of Au's 1.2 list (one family, none): match by g.
                let fams: [ReflectionFamily] = gs.compactMap { g in auList.families.first { close($0.family.g, g, 1e-9) }?.family }
                compare(rec, auList, "T4 #\(i) \(str(rec["label"]))", families: fams.count == auList.families.count ? nil : fams)
            }
            print("  R6: \(n1) T1 plants and \(list(r6["t4"]).count) T4 plants; Au {111} d \(auList.families[0].family.d); validation label \"\(RingIndexing.validation)\"")
            report.check(IndexingDisplay.index(q: 1, tolerancePercent: 1, in: auList).validation.hasPrefix("none"), "R6 verdict", "validation", "the product must report validation none")
        }

        // ---- R9
        if wants("R9") {
            let r9 = dict(ref["r9"])
            report.check(int(r9["max_bytes"]) == CrystalLoading.maximumBytes, "R9 cap", "constant", "\(CrystalLoading.maximumBytes) vs \(int(r9["max_bytes"]))")
            var separated: [String] = []
            for f in list(r9["files"]) {
                let name = str(f["name"])
                let url = (f["planted"] as? Bool ?? false) ? refDir.appendingPathComponent("r9").appendingPathComponent(name)
                    : URL(fileURLWithPath: str(f["dir"])).appendingPathComponent(name)
                let bytes = try Data(contentsOf: url)
                let expect = str(f["expect"])
                let outcome = attempt { try mutatedLoad(bytes, fileName: name, mutation) }
                if expect == "read" || expect == "read-at-cap" {
                    guard case .success(let loaded) = outcome else {
                        report.check(false, expect == "read-at-cap" ? "R9 cap" : "R9 read", name, "refused: \(failureText(outcome))")
                        continue
                    }
                    report.check(loaded.sha256 == str(f["sha256"]), "R9 hash", name, "\(loaded.sha256) vs \(str(f["sha256"]))")
                    if loaded.sha256 != str(f["sha256"]) { separated.append(name) }
                    report.check(loaded.byteCount == int(f["bytes"]), "R9 hash", "\(name) bytes", "\(loaded.byteCount) vs \(int(f["bytes"]))")
                    // The structure equals the kit's reading of the same text.
                    let base = URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent
                    if let text = String(validating: bytes, as: UTF8.self), let kit = try? CIFImport.read(text, fileBaseName: base) {
                        report.check(loaded.structure == kit.structure && loaded.displayName == kit.displayName, "R9 read", name, "structure or name differs from CIFImport.read")
                    } else {
                        report.check(false, "R9 read", name, "the kit does not read the text")
                    }
                } else if expect == "refuse-size" {
                    if case .failure(let e) = outcome, let r = e as? CrystalLoading.Refusal { report.check(r.name == "tooLarge", "R9 refuse", name, r.name) }
                    else { report.check(false, "R9 refuse", name, "not refused by name tooLarge") }
                    if case .failure(let e) = outcome { report.check(!e.localizedDescription.isEmpty, "R9 text", name, "empty text") }
                } else if expect == "refuse-utf8" {
                    if case .failure(let e) = outcome, let r = e as? CrystalLoading.Refusal { report.check(r.name == "notUTF8", "R9 refuse", name, r.name) }
                    else { report.check(false, "R9 refuse", name, "not refused by name notUTF8") }
                } else if expect == "refuse-any" {
                    if case .failure(let e) = outcome {
                        let kit = e as? CIFImportError
                        report.check(kit == nil || e.localizedDescription == kit!.description, "R9 text", name, "localizedDescription \(e.localizedDescription) vs the kit's \(kit?.description ?? "")")
                        report.check(!e.localizedDescription.isEmpty, "R9 text", name, "empty text")
                    } else { report.check(false, "R9 refuse", name, "was read") }
                }
            }
            // Every case of the kit's three error types: the localized text is the kit's description, with no app name in it.
            let cif: [CIFImportError] = [
                .missingTag("_cell_length_a"), .unparsableNumber(tag: "_cell_length_a", value: "x"), .noAtomSites,
                .unknownElementSymbol("Xx", atomSiteLabel: "X1"), .unsupportedSymmetryOperation("x,y"),
                .missingSymmetryOperations(spaceGroup: "F m -3 m"), .truncatedLoop(firstTag: "_atom_site_label", columns: 4, values: 7),
                .invalidStructure(["a close contact"]), .multipleStructures(blockNames: ["a", "b"]),
                .incompleteSymmetryOperations(spaceGroupNumber: 225, declaredName: "F m -3 m", listed: 4, required: 192),
                .symmetryOperationsOutsideStructure(blockNames: ["b"]),
            ]
            let kinematicErrors: [KinematicError] = [
                .unsupportedElements([118]), .reflectionList(.invalidKMax(-1)), .invalidCut(-1), .invalidStructure(["x"]), .nonFiniteStructureFactor(MillerIndex(1, 1, 1)),
            ]
            let listErrors: [ReflectionListError] = [.invalidKMax(0), .cellTooLargeOrInvalid(estimatedReflections: 1e12), .cellTooLargeOrInvalid(estimatedReflections: .nan)]
            var texts: [(String, String, String)] = []
            texts += cif.map { ("CIFImportError.\($0)", $0.localizedDescription, $0.description) }
            texts += kinematicErrors.map { ("KinematicError.\($0)", $0.localizedDescription, $0.description) }
            texts += listErrors.map { ("ReflectionListError.\($0)", $0.localizedDescription, $0.description) }
            texts += [CrystalLoading.Refusal.tooLarge(bytes: 6_000_000), .notUTF8].map { ("CrystalLoading.Refusal.\($0.name)", $0.localizedDescription, $0.errorDescription ?? "") }
            for (label, localized, description) in texts {
                report.check(localized == description && !localized.isEmpty && !localized.contains("mac4DSTEM") && !localized.contains("ACOM"), "R9 text", label,
                             "localizedDescription \(localized); description \(description)")
            }
            print("  R9: \(list(r9["files"]).count) files, \(texts.count) error texts; fingerprint mismatches \(separated.isEmpty ? "none" : separated.joined(separator: ", "))")
        }

        if report.failures > 0 {
            print("diffraction-room-parity: \(report.failures) FAILURES in \(report.checks) checks (\(report.summary()))")
            exit(1)
        }
        print("diffraction-room-parity: all passed — \(report.checks) checks")
    }
}
