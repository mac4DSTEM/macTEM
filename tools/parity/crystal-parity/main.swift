// tools/parity/crystal-parity/main.swift — macTEM's kinematic reflection list (`CrystalStructure.kinematicReflections(kMax:)` of
// DiffractoKit since ADR 025, on DiffractoKit's `CrystalPresets`; built by tools/lib/sources.manifest group `crystal`)
// against reference.py's numpy reading of the same crystals, built from the definitions and from py4DSTEM's
// scattering_factors.txt (not from the kit's ElectronScatteringFactors).
//
//     harness <out-dir-of-reference.py>
//
// Checks per case (archive: roadmap-registrations-2026-10-15.md V1-8 S1), named "<case> <check>":
//   cell          the crystal's a, b, c, angles equal the reference's; its volume within 1e-12 relative
//   order         the list is sorted by increasing |g|, to the kit's tie band: |g| may fall by at most 1e-12 relative between
//                 neighbours (DiffractoCore orders reflections whose |g| agree to 1e-12 by descending (h, k, l), so the list
//                 is not non-decreasing by an ulp: registered in archive: roadmap-registrations-2026-10-15.md "DiffractoKit 0.0.3", prediction 5); and inside
//                 such a run, where |g| falls, the (h, k, l) descend
//   set           the same (h, k, l) set, |F| > 1e-4 and |g| <= kMax, after excluding the edge band (below)
//   d             P1: d = 1/|g| within 1e-12 relative on every common reflection
//   F, Fphase     P2: |F| within 1e-9 relative; the complex F within 1e-9 of |F| (the sign/phase convention)
//   intensity     P2: |F|^2 within 1e-9 relative
//   absences      P3: no fcc mixed-parity (Au, Al) and no diamond mixed-parity or 4n+2 (Si) reflection is returned
//   emulation     the controls' own recomputation of F from the sites equals the Swift list (so the mutants below are
//                 built on faithful code, not on a different formula)
// Edge band: a reflection whose REFERENCE |F| lies within a relative 1e-6 of the 1e-4 cut-off (both are float64), or
// whose |g| is within 1e-9 relative of kMax, is excluded from the set comparison and listed ("note"). Weak-cut
// (reference.py solves its second-site occupancy from the table) has 38 reflections kept in (1e-4, 1e-3) and 24
// dropped in (1e-5, 1e-4), so a wrong cut-off moves its set; the closest one is 0.75 % from the cut.
//
// MACTEM_PARITY_MUTATE=<name> breaks the result on purpose; run.sh requires each to exit 1 with its named check among
// the failures: table-row (Au F: Z shifted by one), fe-of-g (Al F: f_e of |g| instead of |g|^2), no-inverse-volume
// (Mg F: 1/V dropped), no-diamond-basis (Si absences: the 4 shifted atoms missing), occupancy-ignored (Cu3Au-occ F),
// d-offset (Au d: d scaled by 1 + 1e-10), drop-reflection (Al set). An unknown name exits 64.

import Foundation
import simd
import DiffractoCore
import DiffractoScattering

// The harness's flat view of the kit's list, so the checks below read as they did on the copied `Crystal`: a `Reflection` is
// one kept `KinematicReflection`, a `Crystal` one `CrystalStructure` built from a cell and sites (symmetry detected).
struct Reflection {
    let h: Int, k: Int, l: Int
    let g: SIMD3<Double>
    let gLength: Double
    let structureFactorRe: Double
    let structureFactorIm: Double
    var intensity: Double
}

struct Crystal {
    let structure: CrystalStructure
    var a: Double { structure.cell.a }
    var b: Double { structure.cell.b }
    var c: Double { structure.cell.c }
    var alphaDeg: Double { structure.cell.alphaDeg }
    var betaDeg: Double { structure.cell.betaDeg }
    var gammaDeg: Double { structure.cell.gammaDeg }
    var volume: Double { structure.cell.volume }
    var sites: [AtomSite] { structure.sites }

    init(structure: CrystalStructure) { self.structure = structure }
    init(a: Double, b: Double, c: Double, alphaDeg: Double = 90, betaDeg: Double = 90, gammaDeg: Double = 90, sites: [AtomSite]) {
        structure = CrystalStructure.detectingSymmetry(
            cell: UnitCell(a: a, b: b, c: c, alphaDeg: alphaDeg, betaDeg: betaDeg, gammaDeg: gammaDeg), sites: sites)
    }

    /// The kept reflections at the |F| cut 1e-4. `validated: false` is for the one control whose mutation builds a structure
    /// the kit refuses on purpose (two fully occupied atoms on one site): the list and F are then computed by the kit's own
    /// `reflections` and `StructureFactors.compute`, without the validation step.
    func reflections(kMax: Double, validated: Bool = true) -> [Reflection] {
        func flat(_ r: DiffractoCore.Reflection, _ f: StructureFactor) -> Reflection {
            Reflection(h: r.hkl.h, k: r.hkl.k, l: r.hkl.l, g: r.g, gLength: r.gLength,
                       structureFactorRe: f.real, structureFactorIm: f.imaginary, intensity: f.intensity)
        }
        if validated {
            return try! structure.kinematicReflections(kMax: kMax).kept.map { flat($0.reflection, $0.structureFactor) }
        }
        let list = try! structure.reflections(kMax: kMax)
        return list.reflections.compactMap { r in
            guard let f = StructureFactors.compute(r.hkl, in: structure), f.magnitude > StructureFactors.defaultCut else { return nil }
            return flat(r, f)
        }
    }
}

struct Manifest: Decodable {
    struct Case: Decodable {
        let name: String
        let file: String
        let rows: Int
        let kept: Int
        let cell: [Double]
        let volume: Double
        let extinction: String?
        let sites: [[Double]]
    }
    let numpy: String
    let table_sha256: String
    let kmax: Double
    let cut: Double
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

struct RefRow {
    let h: Int, k: Int, l: Int
    let g: Double, d: Double, re: Double, im: Double, absF: Double, intensity: Double
    var key: [Int] { [h, k, l] }
}

let mutations = ["table-row", "fe-of-g", "no-inverse-volume", "no-diamond-basis", "occupancy-ignored", "d-offset",
                 "drop-reflection", "tolerance-1e-3", "table-perturb", "phase-conjugate", "sort-order"]

func doubles(_ path: String) throws -> [Double] {
    try Data(contentsOf: URL(fileURLWithPath: path)).withUnsafeBytes { Array($0.bindMemory(to: Double.self)) }
}

func rel(_ a: Double, _ b: Double) -> Double { abs(a - b) / abs(b) }

/// F recomputed from the sites with the Swift scattering factors, as the controls' own copy of the sum
/// (archive: roadmap-registrations-2026-10-15.md S1's mutations that cannot be built from a different `Crystal` are applied here).
func structureFactor(_ c: Crystal, h: Int, k: Int, l: Int, gLength: Double, gPower: Int, divideByVolume: Bool) -> (re: Double, im: Double) {
    var re = 0.0, im = 0.0
    let gArg = gPower == 2 ? gLength * gLength : gLength
    for site in c.sites {
        let fe = ElectronScatteringFactors.f(z: site.z, gSquared: gArg) ?? 0
        let phase = 2 * Double.pi * (Double(h) * site.fractional.x + Double(k) * site.fractional.y + Double(l) * site.fractional.z)
        re += fe * site.occupancy * cos(phase)
        im += fe * site.occupancy * sin(phase)
    }
    return divideByVolume ? (re / c.volume, im / c.volume) : (re, im)
}

func recomputed(_ c: Crystal, _ list: [Reflection], gPower: Int, divideByVolume: Bool, cut: Double) -> [Reflection] {
    list.compactMap { r in
        let f = structureFactor(c, h: r.h, k: r.k, l: r.l, gLength: r.gLength, gPower: gPower, divideByVolume: divideByVolume)
        let intensity = f.re * f.re + f.im * f.im
        if intensity.squareRoot() <= cut { return nil }
        return Reflection(h: r.h, k: r.k, l: r.l, g: r.g, gLength: r.gLength,
                          structureFactorRe: f.re, structureFactorIm: f.im, intensity: intensity)
    }
}

func withSites(_ c: Crystal, _ sites: [AtomSite]) -> Crystal {
    Crystal(a: c.a, b: c.b, c: c.c, alphaDeg: c.alphaDeg, betaDeg: c.betaDeg, gammaDeg: c.gammaDeg, sites: sites)
}

/// The registered cases: the Swift presets, plus one built here for occupancy (mirrors reference.py's "Cu3Au-occ").
func crystal(named name: String, manifestCase c: Manifest.Case) -> Crystal {
    switch name {
    case "Au": return Crystal(structure: CrystalPresets.gold)
    case "Al": return Crystal(structure: CrystalPresets.aluminum)
    case "Si": return Crystal(structure: CrystalPresets.silicon)
    case "Mg": return Crystal(structure: CrystalPresets.magnesium)
    case "Cu3Au-occ":
        let faces: [SIMD3<Double>] = [[0.5, 0.5, 0], [0.5, 0, 0.5], [0, 0.5, 0.5]]
        return Crystal(a: 3.75, b: 3.75, c: 3.75,
                       sites: [AtomSite(z: 79, fractional: [0, 0, 0], occupancy: 0.6),
                               AtomSite(z: 29, fractional: [0, 0, 0], occupancy: 0.4)]
                              + faces.map { AtomSite(z: 29, fractional: $0) })
    case "Weak-cut":    // a CsCl-like cell whose second-site occupancy reference.py solved from the table (in the manifest)
        return Crystal(a: c.cell[0], b: c.cell[1], c: c.cell[2],
                       sites: c.sites.map { AtomSite(z: Int($0[0]), fractional: [$0[1], $0[2], $0[3]], occupancy: $0[4]) })
    default: fatalError("no crystal named \(name)")
    }
}

/// The reflection a mutated pipeline would return for `name`, or the unmutated one.
func mutated(_ name: String, _ crystal: Crystal, kMax: Double, cut: Double, mutation: String?) -> [Reflection] {
    let base = crystal.reflections(kMax: kMax)
    switch (mutation, name) {
    case ("table-row"?, "Au"):
        return withSites(crystal, crystal.sites.map { AtomSite(z: $0.z - 1, fractional: $0.fractional, occupancy: $0.occupancy) })
            .reflections(kMax: kMax)
    case ("fe-of-g"?, "Al"):
        return recomputed(crystal, base, gPower: 1, divideByVolume: true, cut: cut)
    case ("no-inverse-volume"?, "Mg"):
        return recomputed(crystal, base, gPower: 2, divideByVolume: false, cut: cut)
    case ("no-diamond-basis"?, "Si"):
        return withSites(crystal, Array(crystal.sites.prefix(4))).reflections(kMax: kMax)   // the first 4 sites are the fcc cell
    case ("occupancy-ignored"?, "Cu3Au-occ"):
        return withSites(crystal, crystal.sites.map { AtomSite(z: $0.z, fractional: $0.fractional) }).reflections(kMax: kMax, validated: false)
    case ("d-offset"?, "Au"):
        return base.map { Reflection(h: $0.h, k: $0.k, l: $0.l, g: $0.g, gLength: $0.gLength / (1 + 1e-10),
                                     structureFactorRe: $0.structureFactorRe, structureFactorIm: $0.structureFactorIm,
                                     intensity: $0.intensity) }
    case ("drop-reflection"?, "Al"):
        var out = base; out.remove(at: 3); return out
    case ("tolerance-1e-3"?, _):
        return base.filter { $0.intensity.squareRoot() > 1e-3 }
    case ("phase-conjugate"?, "Mg"):     // exp(-2 pi i h.x): F -> conj(F); |F| is unchanged, Im(F) changes sign
        return base.map { Reflection(h: $0.h, k: $0.k, l: $0.l, g: $0.g, gLength: $0.gLength,
                                     structureFactorRe: $0.structureFactorRe, structureFactorIm: -$0.structureFactorIm,
                                     intensity: $0.intensity) }
    case ("sort-order"?, "Al"):
        return base.reversed()
    default:
        return base
    }
}

@main
struct CrystalParity {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else { print("usage: harness <reference out-dir>"); exit(64) }
        let out = URL(fileURLWithPath: CommandLine.arguments[1])
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: out.appendingPathComponent("manifest.json")))
        let mutation = ProcessInfo.processInfo.environment["MACTEM_PARITY_MUTATE"]
        if let mutation, !mutations.contains(mutation) {
            print("unknown MACTEM_PARITY_MUTATE '\(mutation)' (known: \(mutations.joined(separator: ", ")))")
            exit(64)
        }
        let kMax = manifest.kmax, cut = manifest.cut
        var report = Report()

        // The whole scattering table: every Z the Swift file holds against py4DSTEM's 103 x 10 rows, the parameters to
        // 1e-12 relative, and f_e(Z, g^2) from the library against the sum evaluated here from py4DSTEM's rows.
        let t = try doubles(out.appendingPathComponent("table.f64").path)
        precondition(t.count == 103 * 10)
        var swiftTable: [Int: [Double]] = [:]
        for (i, row) in ElectronScatteringFactors.parameters.enumerated() { swiftTable[i + 1] = row }
        if mutation == "table-perturb" { swiftTable[79]![0] *= 1 + 1e-6 }
        var tableBad: [String] = []
        for z in swiftTable.keys.sorted() {
            guard (1...103).contains(z), let p = swiftTable[z], p.count == 10 else { tableBad.append("Z=\(z) outside py4DSTEM's 1...103 or not 10 numbers"); continue }
            let row = Array(t[((z - 1) * 10)..<(z * 10)])
            for i in 0..<10 where abs(p[i] - row[i]) > 1e-12 * abs(row[i]) { tableBad.append("Z=\(z) param \(i): \(p[i]) vs \(row[i])") }
            for g2 in [0.0, 0.05, 0.3, 1.44] {
                var want = 0.0
                for i in 0..<5 { let d = 1 + row[2 * i + 1] * g2; want += row[2 * i] * (2 + row[2 * i + 1] * g2) / (d * d) }
                let got = ElectronScatteringFactors.f(z: z, gSquared: g2)
                if mutation == "table-perturb" { continue }          // the library function is not what this control perturbs
                if got == nil || abs(got! - want) > 1e-12 * max(abs(want), 1e-300) { tableBad.append("Z=\(z) f_e(g^2 = \(g2)): \(String(describing: got)) vs \(want)") }
            }
        }
        report.check(tableBad.isEmpty && swiftTable.count >= 100, "table",
                     "\(swiftTable.count) rows held; \(tableBad.count) differences, first \(tableBad.prefix(3))")
        print("  table: \(swiftTable.count) elements (Z = \(swiftTable.keys.min()!)...\(swiftTable.keys.max()!)) compared with py4DSTEM's table, \(tableBad.count) differences")

        for c in manifest.cases {
            let before = report.failures
            let model = crystal(named: c.name, manifestCase: c)
            let cell = [model.a, model.b, model.c, model.alphaDeg, model.betaDeg, model.gammaDeg]
            report.check(cell == c.cell && rel(model.volume, c.volume) <= 1e-12, "\(c.name) cell",
                         "cell \(cell) volume \(model.volume) vs \(c.cell) \(c.volume)")

            // Faithfulness of the controls' own sum (never mutated): it must reproduce the library's list.
            let plain = model.reflections(kMax: kMax)
            let replay = recomputed(model, plain, gPower: 2, divideByVolume: true, cut: cut)
            let replayWorst = zip(plain, replay).map { hypot($0.structureFactorRe - $1.structureFactorRe, $0.structureFactorIm - $1.structureFactorIm) / $0.intensity.squareRoot() }.max() ?? 0
            report.check(plain.count == replay.count && replayWorst <= 1e-12, "\(c.name) emulation",
                         "\(plain.count) vs \(replay.count) reflections, worst relative |ΔF| \(replayWorst)")

            let got = mutated(c.name, model, kMax: kMax, cut: cut, mutation: mutation)
            // Increasing |g| to the kit's tie band (1e-12 relative); within a tie run, descending (h, k, l).
            let orderBad = zip(got, got.dropFirst()).filter { x, y in
                if x.gLength <= y.gLength { return false }
                return !(x.gLength - y.gLength <= 1e-12 * max(x.gLength, y.gLength) && [x.h, x.k, x.l].lexicographicallyPrecedes([y.h, y.k, y.l]) == false)
            }
            report.check(orderBad.isEmpty, "\(c.name) order",
                         "\(orderBad.count) neighbours not sorted by increasing |g| to 1e-12 with descending (h, k, l) in a tie")

            let raw = try doubles(out.appendingPathComponent(c.file).path)
            precondition(raw.count == c.rows * 9, "\(c.file): \(raw.count) doubles, expected \(c.rows * 9)")
            let rows = (0..<c.rows).map { i -> RefRow in
                let r = Array(raw[(i * 9)..<(i * 9 + 9)])
                return RefRow(h: Int(r[0]), k: Int(r[1]), l: Int(r[2]), g: r[3], d: r[4], re: r[5], im: r[6], absF: r[7], intensity: r[8])
            }
            var refByKey: [[Int]: RefRow] = [:]
            for r in rows { refByKey[r.key] = r }
            func isEdge(_ r: RefRow) -> Bool {
                abs(r.absF - cut) <= 1e-6 * cut || abs(r.g / kMax - 1) <= 1e-9
            }
            let edges = rows.filter(isEdge)
            if !edges.isEmpty {
                print("  note  \(c.name): \(edges.count) edge reflections excluded: "
                      + edges.map { "(\($0.h) \($0.k) \($0.l) |F| \($0.absF), |g| \($0.g))" }.joined(separator: " "))
            }
            let refSet = Set(rows.filter { $0.absF > cut && $0.g <= kMax && !isEdge($0) }.map(\.key))
            var swiftByKey: [[Int]: Reflection] = [:]
            for r in got where !(refByKey[[r.h, r.k, r.l]].map(isEdge) ?? false) { swiftByKey[[r.h, r.k, r.l]] = r }
            let swiftSet = Set(swiftByKey.keys)
            let missing = refSet.subtracting(swiftSet).sorted { $0.lexicographicallyPrecedes($1) }
            let extra = swiftSet.subtracting(refSet).sorted { $0.lexicographicallyPrecedes($1) }
            report.check(missing.isEmpty && extra.isEmpty && swiftSet.count == swiftByKey.count, "\(c.name) set",
                         "reference \(refSet.count), library \(swiftSet.count); missing \(missing.prefix(6)), extra \(extra.prefix(6))")
            let weakest = rows.filter { $0.absF > cut && !isEdge($0) }.map(\.absF).min() ?? 0

            var worstD = 0.0, worstF = 0.0, worstPhase = 0.0, worstI = 0.0
            var atD = [Int](), atF = [Int](), atI = [Int]()
            for key in refSet.intersection(swiftSet) {
                let r = refByKey[key]!, s = swiftByKey[key]!
                let dd = rel(1 / s.gLength, r.d)
                let fF = rel(hypot(s.structureFactorRe, s.structureFactorIm), r.absF)
                let fP = hypot(s.structureFactorRe - r.re, s.structureFactorIm - r.im) / r.absF
                let fI = rel(s.intensity, r.intensity)
                if dd > worstD { worstD = dd; atD = key }
                if fF > worstF { worstF = fF; atF = key }
                if fP > worstPhase { worstPhase = fP }
                if fI > worstI { worstI = fI; atI = key }
            }
            report.check(worstD <= 1e-12, "\(c.name) d", "worst relative |Δd| \(worstD) at \(atD) > 1e-12")
            report.check(worstF <= 1e-9, "\(c.name) F", "worst relative |Δ|F|| \(worstF) at \(atF) > 1e-9")
            report.check(worstPhase <= 1e-9, "\(c.name) Fphase", "worst |ΔF|/|F| \(worstPhase) > 1e-9")
            report.check(worstI <= 1e-9, "\(c.name) intensity", "worst relative |ΔI| \(worstI) at \(atI) > 1e-9")

            if let rule = c.extinction {
                let bad = got.filter { r in
                    let p = (r.h & 1) + (r.k & 1) + (r.l & 1)          // parity bits of h, k, l (Swift & on negative Int is two's complement)
                    if p != 0 && p != 3 { return true }                // fcc and diamond: mixed parity absent
                    return rule == "diamond" && p == 0 && ((r.h + r.k + r.l) % 4 + 4) % 4 == 2
                }
                report.check(bad.isEmpty, "\(c.name) absences",
                             "\(bad.count) forbidden reflections returned, first \(bad.prefix(4).map { "(\($0.h) \($0.k) \($0.l)) |F| \($0.intensity.squareRoot())" })")
            }
            if c.name == "Mg" {      // the hcp setting, independent of the sites: 000l (l odd) and h-k = 3n with l odd are absent
                let bad = got.filter { ($0.l & 1) == 1 && ((($0.h - $0.k) % 3) + 3) % 3 == 0 }
                report.check(bad.isEmpty, "\(c.name) hcp-absences",
                             "\(bad.count) forbidden reflections returned, first \(bad.prefix(4).map { "(\($0.h) \($0.k) \($0.l))" })")
            }
            if report.failures == before {
                print("  ok    \(c.name): \(got.count) reflections; worst d \(worstD), |F| \(worstF), phase \(worstPhase), I \(worstI); weakest kept |F| \(weakest)")
            }
        }
        if report.failures > 0 {
            print("crystal-parity: \(report.failures) FAILURES in \(report.checks) checks (numpy \(manifest.numpy))")
            exit(1)
        }
        print("crystal-parity: all passed — \(manifest.cases.count) cases, \(report.checks) checks against numpy \(manifest.numpy), table sha256 \(manifest.table_sha256.prefix(12))")
    }
}
