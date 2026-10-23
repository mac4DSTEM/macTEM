// tools/parity/indexing-parity/main.swift — macTEM's index of a measured |q| against the kinematic list
// (DiffractoKit's `kinematicReflections(kMax:)` rings and `RingIndexing.index(q:sigma:in:kMax:coverage:)` since
// ADR 025, built by tools/lib/sources.manifest group `indexing`, on DiffractoKit's `CrystalPresets`) against reference.py's
// numpy reading of the same definition. A cell the numpy reading does not cover (not cubic, hexagonal or monoclinic b) is
// only checked to be BUILT ("built"): every crystal system is indexed now, so the old `unsupportedLattice` refusals are gone.
//
//     harness <out-dir-of-reference.py>
//
// The reference writes manifest.json (crystals, their family lists, the cells of T2/T3, the T4 labels) and plants.f64
// (little-endian float64 rows of manifest.W values; reference.py's docstring has the column order). This reads both, builds
// every crystal of the manifest from its cell and sites, builds its list, and runs every plant through `index`.
//
// Checks (archive: roadmap-registrations-2026-10-15.md V1-8 S2, P1-P3). A check is named "<what> <aspect>"; a failure prints
// "  FAIL  <name>: <N of M, the first plants>" once per name, so a mutant that breaks 100 000 plants is one line:
//   <crystal> families, <crystal> orbits, <crystal> multiplicity, <crystal> names
//                    P2, the lists: the same families (member sets, |g| within 1e-12 relative), the same orbit names, the
//                    same multiplicities and the same family name strings ("{2 0 0} + {2 0 -1}"), per crystal (Au, Al, Si, Mg,
//                    Mg-ideal, Weak-cut, and S2c's monoclinic M-P, M-C, M-sq, beta''); beta'' is built from the CIF the
//                    reference read, through CIFImport
//   cif model, cif sites
//                    (cif model also compares the Laue class's crystal system with gemmi's crystal_system_str())
//                    S2c, P3: that CIF through CIFImport: .monoclinic symmetry (.identity before the 7d6fdbd1 re-sync), usable, space group 12, the cell exactly
//                    gemmi's, and 22 sites each equal (z, occupancy, position mod 1 within 1e-9) to one of gemmi's expansion
//   gemmi |g|, gemmi allowed, gemmi orbits
//                    S2c, P1: against gemmi 0.7.5 on beta'': every listed |g| within 1e-12 relative of 1/calculate_d, every
//                    listed member space-group-allowed, the allowed-but-unlisted set exactly the reference's six under S1's
//                    1e-4 cut, and every family equal to the orbit of its first member under gemmi's rotation parts plus Friedel
//   monoclinic anchors
//                    S2c, P1: d(h00) = a sin(beta)/h, d(0k0) = b/k, d(00l) = c sin(beta)/l and the (hkl) closed form on M-P
//                    and beta'', by hand
//   near-cubic list, near-hexagonal list
//                    the cells b = a(1 + 1e-11) and gamma = 120 deg + 1e-10 deg are recognised and listed as the reference's
//   T4 <verdict>     P3, the refusal plants by their own name: the list refusals (crystal-level, k_max 5, 1e6 and 1e19 each
//                    in a child process with a 20 s limit), the first-that-applies pairs, every plant of T4 by its expected
//                    verdict, and the numbers of an accepted or ambiguous T4 plant
//   T<n> verdict     P2, the verdict (and the family accepted) equals the reference's, n = 1, 2, 3, 5
//   T<n> payload     P2, the ambiguous families as a set, in order wherever their z differ by more than 1e-6
//   T<n> z           P2, z and the next's z within 1e-10 max(1, z); and, accepted, the closed forms (P1)
//   T<n> deviation   P2, the signed deviation within 1e-14; and, accepted, the closed forms (P1)
//   T<n> next        P2, the next candidate (index, z, deviation)
//   T<n> margin      P2, the margin within 1e-9 max(1, margin)
//   T<n> reach       P2, the numeric reach q + R of a beyondKMax verdict within 1e-9 max(1, reach) (Gate B; the margin's band)
//   T<n> P1          P1, no plant whose own family lies within k sigma is assigned another family or refused none
//   anchors          Au {111} d = a/sqrt(3), Si {111} d = 5.4309/sqrt(3), Mg {10-10} d = a sqrt(3)/2, by hand
// Printed, not gated: per tier the verdict counts; T2's rate of true families outside k sigma and its wrong-family rate;
// T3's per-cell counts; T5's fractions. (The statistics belong to numpy's generator and the physics, not to the Swift.)
//
// MACTEM_PARITY_MUTATE is not used: run.sh mutates a copy of a DiffractoKit source file (MACTEM_KIT_OVERRIDE) and compiles this file against it.
// Final line: "indexing-parity: N FAILURES in M checks" (exit 1) or "indexing-parity: all passed ..." (exit 0).

import Foundation
import DiffractoCore
import DiffractoScattering
import DiffractoGeometry

typealias Index = RingIndexing

/// The kit's rings of one crystal after the |F| cut, with what the checks read of the structure.
struct FamilyList {
    let families: [ReflectionFamily]
    let kMax: Double
    let laueGroup: PointSymmetry
    /// Names and orbit keys in Miller-Bravais (four-index) form: the Laue class asks for it and the metric is hexagonal.
    let millerBravais: Bool
}

/// The list builder's refusal as the reference names it.
func listErrorName(_ error: KinematicError) -> String {
    switch error {
    case .unsupportedElements: return "unsupportedElement"
    case .reflectionList(.invalidKMax): return "invalidInput"
    case .reflectionList(.cellTooLargeOrInvalid): return "cellTooLargeOrInvalid"
    case .invalidStructure: return "invalidStructure"
    case .invalidCut, .nonFiniteStructureFactor: return "\(error)"
    }
}

// MARK: The reference's files

struct Reference {
    struct Family {
        let g: Double
        let members: [[Int]]
        let orbits: [[Int]]
        let orbitCounts: [Int]
        let multiplicity: Int
        let name: String
    }
    struct CrystalCase {
        let index: Int
        let name: String
        let cell: [Double]
        let sites: [[Double]]
        let kMax: Double
        let expectedRefusal: String?
        let role: String
        let families: [Family]
    }
    struct T4Plant {
        let plant: Int
        let label: String
        let expect: String
    }
    struct Gemmi {
        let cell: [Double]
        let spaceGroup: Int
        let sites: [[Double]]
        let crystalSystem: String
        let rotations: [[[Int]]]
        let allowed: [[Double]]
        let belowCut: [[Int]]
    }
    let w: Int
    let rows: Int
    let k: Double
    let crystals: [CrystalCase]
    let t4: [T4Plant]
    let columns: [String: Int]
    let data: [Double]
    let payload: [Int32]
    let betaCIF: String
    let gemmi: Gemmi
}

func number(_ any: Any?) -> Double {
    if let s = any as? String { return Double(s) ?? .nan }       // "NaN", "Infinity", "-Infinity"
    return (any as? NSNumber)?.doubleValue ?? .nan
}

func loadReference(_ dir: URL) throws -> Reference {
    let manifestData = try Data(contentsOf: dir.appendingPathComponent("manifest.json"))
    guard let m = try JSONSerialization.jsonObject(with: manifestData) as? [String: Any] else {
        throw Failure("manifest.json is not an object")
    }
    func ints(_ any: Any?) -> [Int] { (any as? [NSNumber])?.map(\.intValue) ?? [] }
    let crystalObjects = m["crystals"] as? [[String: Any]] ?? []
    var crystals: [Reference.CrystalCase] = []
    for c in crystalObjects {
        let families = (c["families"] as? [[String: Any]] ?? []).map { f in
            Reference.Family(g: number(f["g"]),
                             members: (f["members"] as? [Any] ?? []).map(ints),
                             orbits: (f["orbits"] as? [Any] ?? []).map(ints),
                             orbitCounts: ints(f["orbit_member_counts"]),
                             multiplicity: (f["multiplicity"] as? NSNumber)?.intValue ?? -1,
                             name: f["name"] as? String ?? "?")
        }
        crystals.append(Reference.CrystalCase(
            index: (c["index"] as? NSNumber)?.intValue ?? -1, name: c["name"] as? String ?? "?",
            cell: (c["cell"] as? [Any] ?? []).map(number),
            sites: (c["sites"] as? [Any] ?? []).map { ($0 as? [Any] ?? []).map(number) },
            kMax: number(c["kmax"]), expectedRefusal: c["expected_list_refusal"] as? String,
            role: c["role"] as? String ?? "?", families: families))
    }
    let t4 = (m["t4"] as? [[String: Any]] ?? []).map {
        Reference.T4Plant(plant: ($0["plant"] as? NSNumber)?.intValue ?? -1, label: $0["label"] as? String ?? "?",
                          expect: $0["expect"] as? String ?? "?")
    }
    let w = (m["W"] as? NSNumber)?.intValue ?? 0
    let names = m["columns"] as? [String] ?? []
    var columns: [String: Int] = [:]
    for (i, n) in names.enumerated() { columns[n] = i }
    let raw = try Data(contentsOf: dir.appendingPathComponent("plants.f64"))
    let data: [Double] = raw.withUnsafeBytes { Array($0.bindMemory(to: Double.self)) }
    let rows = (m["rows"] as? NSNumber)?.intValue ?? 0
    guard w == names.count, data.count == rows * w else {
        throw Failure("plants.f64 holds \(data.count) values, the manifest says \(rows) x \(w)")
    }
    let rawPayload = try Data(contentsOf: dir.appendingPathComponent("payload.i32"))
    let payload: [Int32] = rawPayload.withUnsafeBytes { Array($0.bindMemory(to: Int32.self)) }
    let g = m["gemmi"] as? [String: Any] ?? [:]
    let gemmi = Reference.Gemmi(
        cell: (g["cell"] as? [Any] ?? []).map(number), spaceGroup: (g["space_group"] as? NSNumber)?.intValue ?? -1,
        sites: (g["sites"] as? [Any] ?? []).map { ($0 as? [Any] ?? []).map(number) },
        crystalSystem: g["crystal_system"] as? String ?? "?",
        rotations: (g["rotations"] as? [Any] ?? []).map { ($0 as? [Any] ?? []).map(ints) },
        allowed: (g["allowed"] as? [Any] ?? []).map { ($0 as? [Any] ?? []).map(number) },
        belowCut: (g["below_cut"] as? [Any] ?? []).map(ints))
    let cifPath = m["beta_cif"] as? String ?? ""
    let cifText = (try? String(contentsOfFile: cifPath, encoding: .utf8)) ?? ""
    return Reference(w: w, rows: rows, k: number(m["k"]), crystals: crystals, t4: t4, columns: columns, data: data,
                     payload: payload, betaCIF: cifText, gemmi: gemmi)
}

struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

// MARK: The tally

/// A check is a name; it holds every comparison made under it. One failure line per name, however many plants.
struct Tally {
    private var order: [String] = []
    private var made: [String: Int] = [:]
    private var bad: [String: Int] = [:]
    private var first: [String: [String]] = [:]

    mutating func note(_ name: String, ok: Bool, _ detail: @autoclosure () -> String) {
        if made[name] == nil { order.append(name) }
        made[name, default: 0] += 1
        if ok { return }
        bad[name, default: 0] += 1
        if (first[name] ?? []).count < 3 { first[name, default: []].append(detail()) }
    }

    var checks: Int { order.count }
    var failures: Int { bad.count }

    func printFailures() {
        for name in order where bad[name] != nil {
            print("  FAIL  \(name): \(bad[name]!) of \(made[name]!) comparisons; first: \(first[name]!.joined(separator: " | "))")
        }
    }
    var comparisons: Int { made.values.reduce(0, +) }
}

// MARK: Crystals and lists

/// beta'' comes from the CIF the reference read, through CIFImport (S2c); `cifStructure` is set once, in main, and nil when the
/// import failed (then the manifest's own sites are used, so the remaining checks still run, and "cif model" has failed).
nonisolated(unsafe) var cifStructure: CrystalStructure?

func buildCrystal(_ c: Reference.CrystalCase) -> CrystalStructure {
    if c.name == "beta''", let cifStructure { return cifStructure }
    return CrystalStructure.detectingSymmetry(
        cell: UnitCell(a: c.cell[0], b: c.cell[1], c: c.cell[2], alphaDeg: c.cell[3], betaDeg: c.cell[4], gammaDeg: c.cell[5]),
        sites: c.sites.map { AtomSite(z: Int($0[0]), fractional: [$0[1], $0[2], $0[3]], occupancy: $0[4]) })
}

func millerBravais(_ s: CrystalStructure) -> Bool {
    (s.laueClass?.usesMillerBravais ?? false) && s.cell.metricFamily() == .hexagonal
}

/// The list builder's answer as a name: "built" or the refusal's name.
func listOutcome(_ c: Reference.CrystalCase) -> (list: FamilyList?, name: String) {
    let s = buildCrystal(c)
    do throws(KinematicError) {
        let rings = try s.kinematicReflections(kMax: c.kMax).families.map(\.family)
        return (FamilyList(families: rings, kMax: c.kMax, laueGroup: s.laueGroup, millerBravais: millerBravais(s)), "built")
    } catch {
        return (nil, listErrorName(error))
    }
}

func hklKey(_ a: [Int]) -> String { a.map(String.init).joined(separator: ",") }

/// The Swift orbit's canonical form as the reference writes it: three integers (cubic, monoclinic) or four (H, K, -H-K, |l|).
func orbitKey(_ o: MillerIndex, millerBravais: Bool) -> String {
    millerBravais ? hklKey([o.h, o.k, -(o.h + o.k), o.l]) : hklKey([o.h, o.k, o.l])
}

/// Which list a crystal's list checks are named for.
func listCheckPrefix(_ c: Reference.CrystalCase) -> String {
    switch c.name {
    case "Au-b+1e-11": return "near-cubic list"
    case "Mg-gamma+1e-10": return "near-hexagonal list"
    default: return c.name
    }
}

func compareList(_ c: Reference.CrystalCase, _ list: FamilyList, _ tally: inout Tally) {
    let near = c.name == "Au-b+1e-11" || c.name == "Mg-gamma+1e-10"
    let famName = near ? listCheckPrefix(c) : "\(c.name) families"
    let sw = list.families
    let ok = sw.count == c.families.count
    tally.note(famName, ok: ok, "\(sw.count) families, the reference has \(c.families.count)")
    guard ok else { return }
    for (i, (s, r)) in zip(sw, c.families).enumerated() {
        let swiftMembers = Set(s.members.map { hklKey([$0.h, $0.k, $0.l]) })
        let refMembers = Set(r.members.map(hklKey))
        tally.note(famName, ok: swiftMembers == refMembers && abs(s.g - r.g) <= 1e-12 * r.g,
                   "family \(i) g \(s.g) vs \(r.g), \(swiftMembers.count) members vs \(refMembers.count)")
        let swiftOrbits = s.orbits.map { orbitKey($0, millerBravais: list.millerBravais) }
        let refOrbits = r.orbits.map(hklKey)
        tally.note(near ? famName : "\(c.name) orbits", ok: swiftOrbits == refOrbits,
                   "family \(i) (g \(r.g)) orbits \(swiftOrbits) vs \(refOrbits)")
        tally.note(near ? famName : "\(c.name) multiplicity", ok: s.multiplicity == r.multiplicity,
                   "family \(i) (g \(r.g)) multiplicity \(s.multiplicity) vs \(r.multiplicity)")
        tally.note(near ? famName : "\(c.name) names", ok: s.name == r.name, "family \(i) (g \(r.g)) name '\(s.name)' vs '\(r.name)'")
        // The orbit sizes: how many members each orbit canonical form takes, against the reference's per-orbit counts.
        var counts: [String: Int] = [:]
        for m in s.members { counts[orbitKey(list.laueGroup.canonical(m), millerBravais: list.millerBravais), default: 0] += 1 }
        let swiftCounts = refOrbits.map { counts[$0] ?? 0 }
        tally.note(near ? famName : "\(c.name) multiplicity", ok: swiftCounts == r.orbitCounts,
                   "family \(i) (g \(r.g)) orbit member counts \(swiftCounts) vs \(r.orbitCounts)")
    }
}

// MARK: One child process per huge k_max

/// `harness --child <out-dir> <crystal index>`: build the list of one crystal and print its outcome. A trap kills the child;
/// the parent reports that as the crystal's own failed check.
func childMain(_ ref: Reference, index: Int) -> Never {
    guard let c = ref.crystals.first(where: { $0.index == index }) else {
        print("child: no such crystal")
        exit(64)
    }
    let r = listOutcome(c)
    print("child: \(r.name)")
    exit(0)
}

/// The outcome of a crystal's list in a child with a time limit: its name, "timeout" or "killed by signal N".
func listInChild(_ dir: URL, _ c: Reference.CrystalCase, seconds: Double) -> String {
    let child = Process()
    child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    child.arguments = ["--child", dir.path, String(c.index)]
    let pipe = Pipe()
    child.standardOutput = pipe
    child.standardError = pipe
    let done = DispatchSemaphore(value: 0)
    child.terminationHandler = { _ in done.signal() }
    do { try child.run() } catch { return "cannot start: \(error)" }
    if done.wait(timeout: .now() + seconds) == .timedOut {
        child.terminate()
        if done.wait(timeout: .now() + 2) == .timedOut { kill(child.processIdentifier, SIGKILL); _ = done.wait(timeout: .now() + 2) }
        return "timeout after \(Int(seconds)) s"
    }
    let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    if child.terminationReason == .uncaughtSignal { return "killed by signal \(child.terminationStatus)" }
    guard let line = output.split(separator: "\n").last(where: { $0.hasPrefix("child: ") }) else {
        return "no answer (exit \(child.terminationStatus))"
    }
    return String(line.dropFirst("child: ".count))
}

// MARK: Plants

extension RingIndexing.Refusal {
    var code: Int {
        switch self {
        case .invalidInput: return 1
        case .ambiguous: return 4
        case .beyondKMax: return 5
        case .noneWithinTolerance: return 6
        }
    }
}

extension Error {
    var name: String { (self as? RingIndexing.Refusal)?.name ?? "\(self)" }
}

struct Plant {
    let ref: Reference
    let row: Int
    func value(_ name: String) -> Double { ref.data[row * ref.w + ref.columns[name]!] }
    func integer(_ name: String) -> Int { Int(value(name)) }
    func payload() -> [Int] {
        let start = integer("payload_offset")
        return (0..<integer("payload_count")).map { Int(ref.payload[start + $0]) }
    }
}

func closeTo(_ a: Double, _ b: Double, _ tolerance: Double) -> Bool {
    if a.isNaN || b.isNaN { return a.isNaN && b.isNaN }
    return abs(a - b) <= tolerance
}

func zOK(_ a: Double, _ b: Double) -> Bool { closeTo(a, b, 1e-10 * max(1, abs(b))) }

/// Runs one plant through `index` and compares it with the reference's row. Returns the Swift verdict code (0 accepted).
func runPlant(_ p: Plant, list: FamilyList, refFamilies: [Reference.Family], t4Expect: String?,
              _ tally: inout Tally) -> (code: Int, own: Bool) {
    let tier = p.integer("tier")
    func name(_ aspect: String) -> String { t4Expect.map { "T4 \($0)" } ?? "T\(tier) \(aspect)" }
    let q = p.value("q"), sigma = p.value("sigma"), k = p.value("k")
    let id = "plant \(p.row) (q \(q), sigma \(sigma), k \(k))"
    // A mutated kit may give two families one g (grouping at 0 splits at the ulp): the first keeps the key, the checks then fail by name
    // instead of the harness trapping on a duplicate key.
    let gIndex = Dictionary(list.families.enumerated().map { ($1.g, $0) }, uniquingKeysWith: { first, _ in first })
    func index(of c: RingIndexing.Candidate) -> Int { gIndex[c.family.g] ?? -2 }

    var code = 0
    var assignment: RingIndexing.Assignment?
    var refusal: RingIndexing.Refusal?
    do {
        assignment = try RingIndexing.index(q: q, sigma: sigma, in: list.families, kMax: list.kMax, coverage: k)
    } catch {
        refusal = error
        code = error.code
    }
    let refCode = p.integer("verdict")
    tally.note(name("verdict"), ok: code == refCode, "\(id): Swift verdict \(code), reference \(refCode)")

    let truth = p.integer("truth_family")
    var own = false
    if code == refCode {
        switch refCode {
        case 0:
            let a = assignment!
            own = index(of: a.best) == truth
            tally.note(name("verdict"), ok: index(of: a.best) == p.integer("best"),
                       "\(id): accepted family \(index(of: a.best)), reference \(p.integer("best"))")
            tally.note(name("z"), ok: zOK(a.best.z, p.value("z")), "\(id): z \(a.best.z), reference \(p.value("z"))")
            tally.note(name("deviation"), ok: closeTo(a.best.deviation, p.value("delta"), 1e-14),
                       "\(id): delta \(a.best.deviation), reference \(p.value("delta"))")
            let refNext = p.integer("next")
            let swiftNext = a.next.map(index(of:)) ?? -1
            tally.note(name("next"), ok: swiftNext == refNext, "\(id): next \(swiftNext), reference \(refNext)")
            if let n = a.next, swiftNext == refNext {
                tally.note(name("next"), ok: zOK(n.z, p.value("z_next")), "\(id): z_next \(n.z), reference \(p.value("z_next"))")
                tally.note(name("deviation"), ok: closeTo(n.deviation, p.value("delta_next"), 1e-14),
                           "\(id): delta_next \(n.deviation), reference \(p.value("delta_next"))")
            }
            let refMargin = p.value("margin")
            let margin = a.margin ?? .nan
            tally.note(name("margin"), ok: closeTo(margin, refMargin, 1e-9 * max(1, abs(refMargin.isNaN ? 0 : refMargin))),
                       "\(id): margin \(margin), reference \(refMargin)")
            // Closed forms (P1): T1 from s and u, T2 and T3 from the draws; both need the own family.
            if own && truth >= 0 {
                let g = refFamilies[truth].g
                switch tier {
                case 1:
                    let s = p.value("s"), u = p.value("u")
                    tally.note(name("z"), ok: zOK(a.best.z, abs(s) / (1 + s * u)), "\(id): z \(a.best.z) vs |s|/(1+su) = \(abs(s) / (1 + s * u))")
                    tally.note(name("deviation"), ok: closeTo(a.best.deviation, -s * u / (1 + s * u), 1e-14),
                               "\(id): delta \(a.best.deviation) vs -su/(1+su) = \(-s * u / (1 + s * u))")
                case 2, 3:
                    let expected = abs(g * p.value("eps") + p.value("n")) / sigma
                    tally.note(name("z"), ok: zOK(a.best.z, expected), "\(id): z \(a.best.z) vs |g eps + n|/sigma = \(expected)")
                default: break
                }
            }
        case 4:
            if case .ambiguous(let candidates)? = refusal {
                let swiftPayload = candidates.map(index(of:))
                let refPayload = p.payload()
                tally.note(name("payload"), ok: Set(swiftPayload) == Set(refPayload) && swiftPayload.count == refPayload.count,
                           "\(id): payload \(swiftPayload), reference \(refPayload)")
                if Set(swiftPayload) == Set(refPayload) {
                    for (s, r) in zip(swiftPayload, refPayload) where s != r {
                        let zs = abs(q - list.families[s].g) / sigma
                        let zr = abs(q - refFamilies[r].g) / sigma
                        tally.note(name("payload"), ok: abs(zs - zr) <= 1e-6, "\(id): order \(swiftPayload), reference \(refPayload)")
                    }
                }
                if let first = candidates.first {
                    tally.note(name("z"), ok: zOK(first.z, p.value("z_nearest")), "\(id): z \(first.z), reference \(p.value("z_nearest"))")
                    tally.note(name("deviation"), ok: closeTo(first.deviation, p.value("delta_nearest"), 1e-14),
                               "\(id): delta \(first.deviation), reference \(p.value("delta_nearest"))")
                }
            }
        case 5:
            // The numeric reach q + R of a beyondKMax verdict, in the registration's margin band (1e-9 max(1, reach)).
            if case .beyondKMax(let reach, _)? = refusal {
                tally.note(name("reach"), ok: closeTo(reach, p.value("reach"), 1e-9 * max(1, abs(p.value("reach")))),
                           "\(id): reach \(reach), reference \(p.value("reach"))")
            }
        case 6:
            if case .noneWithinTolerance(let nearest)? = refusal {
                let refNearest = p.integer("nearest")
                tally.note(name("verdict"), ok: (nearest.map(index(of:)) ?? -1) == refNearest,
                           "\(id): nearest \(nearest.map(index(of:)) ?? -1), reference \(refNearest)")
                if let nearest {
                    tally.note(name("z"), ok: zOK(nearest.z, p.value("z_nearest")), "\(id): nearest z \(nearest.z), reference \(p.value("z_nearest"))")
                    tally.note(name("deviation"), ok: closeTo(nearest.deviation, p.value("delta_nearest"), 1e-14),
                               "\(id): nearest delta \(nearest.deviation), reference \(p.value("delta_nearest"))")
                }
            }
        default:
            break
        }
    }

    // P1: a plant whose own family lies within k sigma is neither assigned another family nor refused `none`.
    if (tier == 1 || tier == 2) && truth >= 0 && p.value("truth_z") <= k {
        let wrong: Bool
        if code == 0 { wrong = index(of: assignment!.best) != truth } else { wrong = code == 6 }
        tally.note("T\(tier) P1", ok: !wrong, "\(id): own family \(truth) at z \(p.value("truth_z")) but Swift verdict \(code)")
    }
    return (code, own)
}

// MARK: Main

@main
struct IndexingParity {
    static func main() throws {
        let args = CommandLine.arguments
        let isChild = args.count == 4 && args[1] == "--child"
        guard args.count == 2 || isChild else {
            print("usage: harness <reference out-dir>")
            exit(64)
        }
        let dir = URL(fileURLWithPath: args[isChild ? 2 : 1])
        let ref = try loadReference(dir)
        if isChild { childMain(ref, index: Int(args[3]) ?? -1) }
        var tally = Tally()

        // S2c, P3: beta'' through CIFImport, the CIF the reference read with gemmi. A failed import leaves cifStructure nil and
        // the manifest's own sites are used for the remaining checks.
        func wrapped(_ a: Double, _ b: Double) -> Double { let d = abs(a - b); return abs(d - d.rounded()) }
        if ref.betaCIF.isEmpty {
            tally.note("cif model", ok: false, "the reference's CIF \(ref.betaCIF.count) characters: not readable")
        } else {
            do {
                let s = try CIFImport.read(ref.betaCIF, fileBaseName: "beta_double_prime_Mg5Si6").structure
                cifStructure = s
                let c = s.cell
                tally.note("cif model", ok: s.laueClass == .twoOverM && s.cell.metricFamily() == .monoclinic(uniqueAxis: .b)
                           && s.isUsable && s.spaceGroupNumber == ref.gemmi.spaceGroup,
                           "Laue class \(s.laueClass?.symbol ?? "nil"), family \(s.cell.metricFamily()), usable \(s.isUsable), space group \(s.spaceGroupNumber ?? -1) vs gemmi \(ref.gemmi.spaceGroup)")
                tally.note("cif model", ok: s.laueClass?.crystalSystem.rawValue == ref.gemmi.crystalSystem,
                           "crystal system \(s.laueClass?.crystalSystem.rawValue ?? "nil") vs gemmi's crystal_system_str() \(ref.gemmi.crystalSystem)")
                tally.note("cif model", ok: [c.a, c.b, c.c, c.alphaDeg, c.betaDeg, c.gammaDeg] == ref.gemmi.cell,
                           "cell \([c.a, c.b, c.c, c.alphaDeg, c.betaDeg, c.gammaDeg]) vs gemmi \(ref.gemmi.cell)")
                tally.note("cif sites", ok: s.sites.count == ref.gemmi.sites.count, "\(s.sites.count) sites, gemmi expands to \(ref.gemmi.sites.count)")
                var taken = Set<Int>()
                for (i, site) in s.sites.enumerated() {
                    let hit = ref.gemmi.sites.indices.first { j in
                        let g = ref.gemmi.sites[j]
                        return !taken.contains(j) && Int(g[0]) == site.z && abs(g[4] - site.occupancy) <= 1e-12
                            && wrapped(g[1], site.fractional.x) <= 1e-9 && wrapped(g[2], site.fractional.y) <= 1e-9
                            && wrapped(g[3], site.fractional.z) <= 1e-9
                    }
                    if let hit { taken.insert(hit) }
                    tally.note("cif sites", ok: hit != nil, "site \(i) Z \(site.z) at \(site.fractional) has no gemmi site left")
                }
            } catch {
                tally.note("cif model", ok: false, "CIFImport refused the CIF: \(error)")
            }
        }

        // The lists, per crystal: expected refusals by name, expected lists compared to the reference's.
        var lists: [Int: FamilyList] = [:]
        for c in ref.crystals {
            let expected = c.expectedRefusal
            let huge = c.kMax.isFinite && c.kMax > ReflectionList.maximumKMax
            let outcomeName: String
            var list: FamilyList?
            if huge {
                outcomeName = listInChild(dir, c, seconds: 20)      // may trap or run for minutes under a mutant
            } else {
                let r = listOutcome(c)
                list = r.list
                outcomeName = r.name
            }
            if let expected {
                tally.note("T4 \(expected)", ok: outcomeName == expected, "\(c.name): the list builder answered '\(outcomeName)', expected \(expected)")
                continue
            }
            if outcomeName != "built" {
                tally.note(c.role == "base" || !(c.name.hasPrefix("Au-b") || c.name.hasPrefix("Mg-gamma"))
                           ? "\(c.name) families" : listCheckPrefix(c),
                           ok: false, "\(c.name): the list builder answered '\(outcomeName)', expected a list")
                continue
            }
            if let list {
                lists[c.index] = list
                compareList(c, list, &tally)
            }
        }

        // Hand anchors.
        func anchor(_ crystal: String, _ member: [Int], _ d: Double, _ label: String) {
            guard let c = ref.crystals.first(where: { $0.name == crystal }), let list = lists[c.index] else {
                tally.note("anchors", ok: false, "\(label): no list for \(crystal)")
                return
            }
            let hit = list.families.first { f in f.members.contains { $0.h == member[0] && $0.k == member[1] && $0.l == member[2] } }
            tally.note("anchors", ok: hit.map { abs($0.d - d) <= 1e-12 * d } ?? false,
                       "\(label): d = \(hit.map { String($0.d) } ?? "no family"), by hand \(d)")
        }
        anchor("Au", [1, 1, 1], 4.0782 / 3.0.squareRoot(), "Au {111} = a/sqrt(3)")
        anchor("Si", [1, 1, 1], 5.4309 / 3.0.squareRoot(), "Si {111} = 5.4309/sqrt(3)")
        anchor("Mg", [1, 0, 0], 3.2094 * 3.0.squareRoot() / 2, "Mg {10-10} = a sqrt(3)/2")

        // S2c: the monoclinic closed forms, by hand: d(h00) = a sin(beta)/h, d(0k0) = b/k, d(00l) = c sin(beta)/l, and
        // 1/d^2 = (h^2/a^2 + l^2/c^2 - 2 h l cos(beta)/(a c))/sin^2(beta) + k^2/b^2.
        for name in ["M-P", "beta''"] {
            guard let c = ref.crystals.first(where: { $0.name == name }), let list = lists[c.index] else {
                tally.note("monoclinic anchors", ok: false, "\(name): no list")
                continue
            }
            let (a, b, cc) = (c.cell[0], c.cell[1], c.cell[2]), be = c.cell[4] * Double.pi / 180
            let (sb, cb) = (sin(be), cos(be))
            func closed(_ h: Double, _ k: Double, _ l: Double) -> Double {
                1 / (((h * h / (a * a) + l * l / (cc * cc) - 2 * h * l * cb / (a * cc)) / (sb * sb) + k * k / (b * b)).squareRoot())
            }
            let cases: [([Int], Double, String)] = [([1, 0, 0], a * sb, "d(100) = a sin beta"), ([2, 0, 0], a * sb / 2, "d(200) = a sin beta/2"),
                ([0, 1, 0], b, "d(010) = b"), ([0, 2, 0], b / 2, "d(020) = b/2"), ([0, 0, 1], cc * sb, "d(001) = c sin beta"),
                ([1, 0, 1], closed(1, 0, 1), "d(101)"), ([1, 0, -1], closed(1, 0, -1), "d(10-1)"),
                ([2, 0, 1], closed(2, 0, 1), "d(201)"), ([2, 0, -1], closed(2, 0, -1), "d(20-1)"), ([1, 1, 0], closed(1, 1, 0), "d(110)"),
                ([1, 1, -1], closed(1, 1, -1), "d(11-1)")]
            for (m, d, label) in cases {
                // beta'' is C-centred: (100), (010), (101), (10-1) and (001)-type h + k odd are absent; the cases kept are allowed there
                let present = list.families.first { f in f.members.contains { ($0.h == m[0] && $0.k == m[1] && $0.l == m[2]) } }
                if name == "beta''" && (m[0] + m[1]) % 2 != 0 { continue }
                tally.note("monoclinic anchors", ok: present.map { abs($0.d - d) <= 1e-12 * d } ?? false,
                           "\(name) \(label): d = \(present.map { String($0.d) } ?? "no family"), by hand \(d)")
            }
        }

        // S2c: gemmi on beta'': |g| of every listed reflection, what is space-group-allowed, the orbits.
        if let bc = ref.crystals.first(where: { $0.name == "beta''" }), let list = lists[bc.index] {
            var allowed: [String: Double] = [:]
            for a in ref.gemmi.allowed { allowed[hklKey([Int(a[0]), Int(a[1]), Int(a[2])])] = a[3] }
            var listed = Set<String>()
            for kr in try buildCrystal(bc).kinematicReflections(kMax: bc.kMax).kept {
                let r = kr.reflection
                let key = hklKey([r.hkl.h, r.hkl.k, r.hkl.l])
                listed.insert(key)
                guard let g = allowed[key] else {
                    tally.note("gemmi allowed", ok: false, "(\(key)) is listed but gemmi finds it systematically absent or beyond k_max")
                    continue
                }
                tally.note("gemmi |g|", ok: abs(r.gLength - g) <= 1e-12 * g, "(\(key)) |g| \(r.gLength) vs gemmi \(g)")
            }
            let under = Set(ref.gemmi.belowCut.map(hklKey))
            let missing = Set(allowed.keys).subtracting(listed)
            tally.note("gemmi allowed", ok: missing == under, "gemmi-allowed but not listed: \(missing.sorted().prefix(8)), the reference's under-the-cut set is \(under.sorted())")
            tally.note("gemmi allowed", ok: allowed.count == listed.count + under.count, "gemmi allows \(allowed.count), the list has \(listed.count) + \(under.count) under the cut")
            for (i, f) in list.families.enumerated() {
                guard let first = f.members.first else { continue }
                var orbit = Set<String>()
                for R in ref.gemmi.rotations {
                    let v = (0..<3).map { j in first.h * R[0][j] + first.k * R[1][j] + first.l * R[2][j] }
                    orbit.insert(hklKey(v))
                    orbit.insert(hklKey(v.map { -$0 }))
                }
                tally.note("gemmi orbits", ok: orbit == Set(f.members.map { hklKey([$0.h, $0.k, $0.l]) }),
                           "family \(i) (g \(f.g)): the gemmi orbit of \(first) has \(orbit.count) members, the family \(f.members.count)")
            }
        }

        // The plants.
        var t4Expect: [Int: String] = [:]
        for t in ref.t4 { t4Expect[t.plant] = t.expect }
        var verdicts: [Int: [Int: Int]] = [:]            // tier -> code -> count
        var outside = 0, wrongT2 = 0, t2Rings = 0
        for row in 0..<ref.rows {
            let p = Plant(ref: ref, row: row)
            let tier = p.integer("tier")
            let refCode = p.integer("verdict")
            let crystalIndex = p.integer("crystal")
            let c = ref.crystals[crystalIndex]
            if refCode == -1 {          // the first-that-applies pairs: the list builder refuses before the plant is looked at
                let expected = c.expectedRefusal ?? "?"
                let got = lists[crystalIndex] != nil ? "built" : listOutcome(c).name
                tally.note("T4 \(expected)", ok: got == expected, "pair \(t4Expect[row] ?? "?") on \(c.name): the list builder answered '\(got)'")
                continue
            }
            guard let list = lists[crystalIndex] else { continue }       // already a failed list check
            let r = runPlant(p, list: list, refFamilies: c.families, t4Expect: tier == 4 ? (t4Expect[row] ?? "?") : nil, &tally)
            verdicts[tier, default: [:]][r.code, default: 0] += 1
            if tier == 2 {
                t2Rings += 1
                if p.integer("truth_family") >= 0 && p.value("truth_z") > ref.k { outside += 1 }
                if r.code == 0 && !r.own { wrongT2 += 1 }
            }
        }

        let codeNames = [0: "accepted", 1: "invalid", 4: "ambiguous", 5: "beyond", 6: "none"]
        for tier in verdicts.keys.sorted() {
            let counts = verdicts[tier]!.keys.sorted().map { "\(codeNames[$0] ?? String($0)) \(verdicts[tier]![$0]!)" }
            print("  T\(tier) (Swift): \(counts.joined(separator: ", "))")
        }
        if t2Rings > 0 {
            print(String(format: "  T2 (Swift): true family outside k sigma %.3f %% of %d rings (nominal 0.27 %%, clustered by pattern); wrong-family accepts %d",
                         100 * Double(outside) / Double(t2Rings), t2Rings, wrongT2))
        }

        tally.printFailures()
        if tally.failures > 0 {
            print("indexing-parity: \(tally.failures) FAILURES in \(tally.checks) checks")
            exit(1)
        }
        print("indexing-parity: all passed — \(ref.crystals.count) crystals, \(ref.rows) plants, \(tally.checks) checks "
              + "(\(tally.comparisons) comparisons) against numpy")
    }
}
