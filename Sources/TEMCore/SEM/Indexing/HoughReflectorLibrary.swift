//
//  HoughReflectorLibrary.swift
//  The reflector library of one phase for Hough (Radon) indexing: the pole families {hkl} whose bands the detector shows,
//  every symmetry variant of each family with its unit normal in the crystal frame, the variant-to-variant angle table,
//  the unique angles between families and the table of family triplets with their three interplanar angles, which the
//  triplet vote matches detected band triangles against (Wright & Adams 1992, Metall. Trans. A 23, 759; Krieger Lassen
//  1994, PhD thesis, DTU).
//
//  Ported from pyEBSDindex 0.3.10.1 (D. Rowenhorst, US Naval Research Laboratory; a work of the US Federal Government, in
//  the public domain in the US, with a worldwide non-exclusive licence to derive and redistribute; NOTICE carries the
//  required acknowledgement and modification notice): `tripletvote.addphase`, `BandIndexer.setpolefamilies`,
//  `setspacegroup`, `build_trip_lib`, `_symrotpoles`, `_hkl_unique`, `_calc_pole_dot_int`, `_sortlib_id`;
//  `crystallometry.Crystal` (the metric and structure matrices); `crystal_sym` (the Laue codes and the proper rotations of
//  each Laue group in pyEBSDindex's float32 values, after DREAM.3D's EbsdLib LaueOps). Modified for macTEM in November
//  2026: Swift, float64 throughout, the triplet table ordered by (family key, angles) where pyEBSDindex leaves ties in an
//  unstable sort's order (the vote sums the whole table, so the order changes nothing but rounding).
//  Parity bundle `m4/hough-library` (docs/parity.md, "Hough indexing").
//

import Foundation

package nonisolated struct HoughReflectorLibrary: Sendable {
    package enum Error: Swift.Error, Equatable, Sendable, LocalizedError {
        /// The space group is outside 1...230 or its Laue group has no rotations in pyEBSDindex.
        case spaceGroup(Int)
        /// No non-zero reflector, or a reflector with neither 3 nor 4 indices.
        case reflectors
        /// The lattice parameters do not describe a cell (non-positive lengths or a degenerate angle set).
        case lattice

        package var errorDescription: String? {
            switch self {
            case .spaceGroup(let n): "Space group \(n) is outside 1 to 230, or Hough indexing has no rotations for its Laue group."
            case .reflectors: "The reflector list needs a non-zero reflector, each with three or four indices."
            case .lattice: "The lattice parameters do not describe a unit cell."
            }
        }
    }

    package let name: String
    package let spaceGroup: Int
    /// The Laue group in EDAX's integer code (`crystal_sym.spacegroup2lauenumber`): 1, 2, 22, 4, 42, 3, 32, 6, 62, 23, 43.
    package let laueCode: Int
    /// a, b, c (any length unit) and alpha, beta, gamma in degrees.
    package let lattice: [Double]
    /// The tolerance of the angle matching, degrees (pyEBSDindex's `angTol`, 2).
    package let angleTolerance: Double
    /// Matched bands after which the band assignment stops looking (`nband_earlyexit`).
    package let earlyExitBands: Int
    /// The pole families after de-duplication, as given (4 indices for hexagonal input).
    package let poleFamilies: [[Int]]
    /// Every symmetry variant of every family, family after family, (h, k, l) (3-index).
    package let poles: [SIMD3<Double>]
    /// The variants' unit normals in the Cartesian crystal frame.
    package let polesCartesian: [SIMD3<Double>]
    /// The family of each variant.
    package let familyID: [Int]
    /// The number of variants of each family and the index of its first variant in `poles`.
    package let familySize: [Int]
    package let familyStart: [Int]
    /// The angle (degrees) between every pair of variants, row-major `poles.count` x `poles.count`.
    package let angleTable: [Double]
    /// Unique angles (degrees, 0.01 steps, over 1 degree) between a family's first variant and each variant of a family
    /// with the same or a higher index, with the family pair.
    package let pairAngles: [Double]
    package let pairFamilies: [(Int, Int)]
    /// The triplet table: each row's three angles sorted ascending, with the family of each of the triangle's corners.
    package let tripletAngles: [SIMD3<Double>]
    package let tripletFamilies: [SIMD3<Int>]

    package var familyCount: Int { familySize.count }

    /// pyEBSDindex's RADEG.
    static let degrees = 180.0 / Double.pi

    /// pyEBSDindex's default reflectors: FCC {002} {111} {022} {113}; BCC {011} {002} {112} {013}; HCP (4-index) the eight
    /// of `addphase(libtype="HCP")`.
    package static let fccReflectors: [[Int]] = [[0, 0, 2], [1, 1, 1], [0, 2, 2], [1, 1, 3]]
    package static let bccReflectors: [[Int]] = [[0, 1, 1], [0, 0, 2], [1, 1, 2], [0, 1, 3]]
    package static let hcpReflectors: [[Int]] = [[1, 0, -1, 0], [0, 0, 0, 2], [1, 0, -1, 1], [1, 0, -1, 2], [1, 1, -2, 0],
                                                  [1, 0, -1, 3], [1, 1, -2, 2], [2, 0, -2, 1]]

    /// `addphase(phasename, spacegroup, latticeparameter, polefamilies, nband_earlyexit)`; `reflectors` nil takes the FCC
    /// default as pyEBSDindex does when no library type is named.
    package init(name: String, spaceGroup: Int, lattice: [Double], reflectors: [[Int]]? = nil,
                 earlyExitBands: Int = 10, angleTolerance: Double = 2.0) throws {
        guard (1...230).contains(spaceGroup) else { throw Error.spaceGroup(spaceGroup) }
        guard lattice.count == 6, lattice.allSatisfy(\.isFinite), lattice[0] > 0, lattice[1] > 0, lattice[2] > 0 else { throw Error.lattice }
        let laue = Self.laueCode(spaceGroup: spaceGroup)
        let symmetry = Self.laueRotations(laue)
        guard !symmetry.isEmpty else { throw Error.spaceGroup(spaceGroup) }
        let cell = try Cell(lattice)
        self.name = name
        self.spaceGroup = spaceGroup
        self.laueCode = laue
        self.lattice = lattice
        self.angleTolerance = angleTolerance
        self.earlyExitBands = earlyExitBands

        // setpolefamilies: drop zero rows, then any row parallel or antiparallel (|cos| > 0.99999) to an earlier one.
        let given = reflectors ?? Self.fccReflectors
        let width = given.first?.count ?? 0
        guard width == 3 || width == 4, given.allSatisfy({ $0.count == width }) else { throw Error.reflectors }
        guard width == 3 || laue == 62 || laue == 6 else { throw Error.reflectors }
        let nonzero = given.filter { $0.contains { $0 != 0 } }
        guard !nonzero.isEmpty else { throw Error.reflectors }
        let unit = nonzero.map { row -> [Double] in
            let n = row.reduce(0.0) { $0 + Double($1 * $1) }.squareRoot()
            return row.map { Double($0) / n }
        }
        var keep = [Bool](repeating: true, count: nonzero.count)
        for i in 0..<nonzero.count {
            for j in (i + 1)..<nonzero.count where abs(zip(unit[i], unit[j]).reduce(0) { $0 + $1.0 * $1.1 }) > 0.99999 {
                keep[j] = false
            }
        }
        let families = nonzero.indices.filter { keep[$0] }.map { nonzero[$0] }
        poleFamilies = families
        // build_trip_lib: hexagonal 4-index (hkil) -> (hkl) for the Laue groups 6/m and 6/mmm.
        let three: [SIMD3<Double>] = families.map { f in
            if width == 4 && (laue == 62 || laue == 6) { return SIMD3(Double(f[0]), Double(f[1]), Double(f[3])) }
            return SIMD3(Double(f[0]), Double(f[1]), Double(f[2]))
        }
        let familyCount = three.count

        // Every variant of each family: rotate the plane normal by each proper rotation, back to hkl, unique (sorted by
        // the integer key as np.unique sorts), reversed.
        var complete: [SIMD3<Double>] = []
        var sizes: [Int] = []
        for f in three {
            let cart = cell.reciprocalStructure * f
            let family = symmetry.map { cell.inverseReciprocalStructure * Self.rotate($0, cart) }
            let unique = Array(Self.uniqueHKL(family).reversed())
            complete.append(contentsOf: unique)
            sizes.append(unique.count)
        }
        var starts: [Int] = [0]
        for s in sizes.dropLast() { starts.append(starts.last! + s) }
        poles = complete
        familySize = sizes
        familyStart = starts
        familyID = sizes.enumerated().flatMap { [Int](repeating: $0.offset, count: $0.element) }

        // Unique angles from each family's given pole to the variants of every family at or after it.
        var pAngles: [Double] = []
        var pFamilies: [(Int, Int)] = []
        let metric = cell.reciprocalMetric
        for i in 0..<familyCount {
            for j in i..<familyCount {
                var seen = Set<Int>()
                for v in complete[starts[j]..<(starts[j] + sizes[j])] {
                    let c = min(max(Self.poleCosine(three[i], v, metric), -1), 1)
                    seen.insert(Int((acos(abs(c)) * Self.degrees * 100).rounded(.toNearestOrEven)))
                }
                for a in seen.sorted() where Double(a) / 100 > 1 {
                    pAngles.append(Double(a) / 100)
                    pFamilies.append((i, j))
                }
            }
        }
        pairAngles = pAngles
        pairFamilies = pFamilies

        // Triplets: two pairs from family i to families id1 <= id2 (by table position), closed by every pair angle
        // between id1 and id2.
        var tAngles: [SIMD3<Double>] = []
        var tFamilies: [SIMD3<Int>] = []
        var firstOfFamily = [Int](repeating: 0, count: familyCount)
        var countOfFamily = [Int](repeating: 0, count: familyCount)
        for (k, p) in pFamilies.enumerated() {
            if countOfFamily[p.0] == 0 { firstOfFamily[p.0] = k }
            countOfFamily[p.0] += 1
        }
        for i in 0..<familyCount where countOfFamily[i] > 0 {
            let base = firstOfFamily[i]
            for j in 0..<countOfFamily[i] {
                let a0 = pAngles[base + j], id1 = pFamilies[base + j].1
                for k in j..<countOfFamily[i] {
                    let a1 = pAngles[base + k], id2 = pFamilies[base + k].1
                    for q in pFamilies.indices where pFamilies[q].0 == id1 && pFamilies[q].1 == id2 {
                        let (angles, ids) = Self.sortTriplet(SIMD3(a0, a1, pAngles[q]), SIMD3(i, id1, id2))
                        tAngles.append(angles)
                        tFamilies.append(ids)
                    }
                }
            }
        }
        // _sortlib_id(findDups=True): drop rows with the same summed angles (0.01 degrees) and family triple; then order
        // by the family key (and the angles, see the header).
        let basis = (tFamilies.map { max($0[0], $0[1], $0[2]) }.max() ?? 0) + 1
        func key(_ f: SIMD3<Int>) -> Int { f[0] + basis * f[1] + basis * basis * f[2] }
        let maxKey = tFamilies.map(key).max() ?? 1
        let digits = maxKey > 0 ? max(Int(log10(Double(maxKey)).rounded(.up)), 2) : 2
        var scale = 1
        for _ in 0..<digits { scale *= 10 }
        var seenRows = Set<Int>()
        var rows: [(angles: SIMD3<Double>, families: SIMD3<Int>)] = []
        for (a, f) in zip(tAngles, tFamilies) {
            let angleKey = Int((a[0] * 100).rounded(.toNearestOrEven) + (a[1] * 100).rounded(.toNearestOrEven)
                               + (a[2] * 100).rounded(.toNearestOrEven))
            if seenRows.insert(angleKey * scale + key(f)).inserted { rows.append((a, f)) }
        }
        rows.sort { l, r in
            let kl = key(l.families), kr = key(r.families)
            if kl != kr { return kl < kr }
            for c in 0..<3 where l.angles[c] != r.angles[c] { return l.angles[c] < r.angles[c] }
            return false
        }
        tripletAngles = rows.map { $0.angles }
        tripletFamilies = rows.map { $0.families }

        // The angle table and the Cartesian unit normals of the variants.
        let n = complete.count
        var table = [Double](repeating: 0, count: n * n)
        for i in 0..<n {
            for j in 0..<n { table[i * n + j] = acos(Self.poleCosine(complete[i], complete[j], metric)) * Self.degrees }
        }
        angleTable = table
        polesCartesian = complete.map { v in
            let c = cell.reciprocalStructure * v
            let len = (c * c).sum().squareRoot()
            return c / len
        }
    }

    // MARK: - Pieces of pyEBSDindex

    /// `_sortlib_id` on one row: the angles sorted ascending (a stable sort, as numpy's for three values) and the families
    /// permuted by pyEBSDindex's look-up table, which maps the permutation of the triangle's edges to that of its corners.
    package static func sortTriplet(_ angles: SIMD3<Double>, _ families: SIMD3<Int>) -> (SIMD3<Double>, SIMD3<Int>) {
        let order = [0, 1, 2].sorted { angles[$0] < angles[$1] || (angles[$0] == angles[$1] && $0 < $1) }
        let p = cornerPermutation(order)
        return (SIMD3(angles[order[0]], angles[order[1]], angles[order[2]]), SIMD3(families[p[0]], families[p[1]], families[p[2]]))
    }

    /// pyEBSDindex's `lut`: edge order (ang(0,1), ang(0,2), ang(1,2)) -> corner order.
    package static func cornerPermutation(_ edges: [Int]) -> [Int] {
        switch edges {
        case [0, 1, 2]: return [0, 1, 2]
        case [0, 2, 1]: return [1, 0, 2]
        case [1, 0, 2]: return [0, 2, 1]
        case [1, 2, 0]: return [2, 0, 1]
        case [2, 0, 1]: return [1, 2, 0]
        default: return [2, 1, 0]
        }
    }

    /// `_hkl_unique(reduceInversion=False)`: round to integers, keep the first of each (h, k, l), ordered by the key
    /// (h - m) + B (k - m) + B² (l - m) with m the smallest index and B the largest shifted index + 1.
    static func uniqueHKL(_ poles: [SIMD3<Double>]) -> [SIMD3<Double>] {
        guard poles.count > 1 else { return poles }
        let ints = poles.map { p in (0..<3).map { Int(p[$0].rounded(.toNearestOrEven)) } }
        let mn = ints.flatMap { $0 }.min()!
        let shifted = ints.map { $0.map { $0 - mn } }
        let basis = shifted.flatMap { $0 }.max()! + 1
        var first: [Int: Int] = [:]
        for (i, s) in shifted.enumerated() {
            let k = s[0] + basis * s[1] + basis * basis * s[2]
            if first[k] == nil { first[k] = i }
        }
        return first.keys.sorted().map { poles[first[$0]!] }
    }

    /// `_calc_pole_dot_int`: the cosine between two plane normals given in hkl, through the reciprocal metric tensor.
    static func poleCosine(_ p1: SIMD3<Double>, _ p2: SIMD3<Double>, _ m: Matrix3) -> Double {
        let t1 = m.transposed * p1   // p1 · M as a row
        let dot = (t1 * p2).sum()
        let n1 = (t1 * p1).sum().squareRoot()
        let n2 = (p2 * (m * p2)).sum().squareRoot()
        return min(max(dot / (n1 * n2), -1), 1)
    }

    /// `rotlib.quat_vector` (passive convention P = 1): v' = v + 2 r × (r × v + w v).
    static func rotate(_ q: SIMD4<Double>, _ v: SIMD3<Double>) -> SIMD3<Double> {
        let w = q[0], r = SIMD3(q[1], q[2], q[3])
        let t = Vector3.cross(r, v) + w * v
        return 2 * Vector3.cross(r, t) + v
    }

    /// `crystal_sym.spacegroup2lauenumber` (its loop as written: space groups 221 to 230 fall through to m-3m).
    package static func laueCode(spaceGroup: Int) -> Int {
        let firstOfPointGroup = [1, 2, 3, 6, 10, 16, 25, 47, 75, 81, 83, 89, 99, 111, 123, 143, 147, 149, 156, 162, 168, 174, 175,
                                 177, 183, 187, 191, 195, 200, 207, 215, 221]
        let laue = [1, 1, 2, 2, 2, 22, 22, 22, 4, 4, 4, 42, 42, 42, 42, 3, 3, 32, 32, 32, 6, 6, 6, 62, 62, 62, 62, 23, 23, 43, 43, 43]
        var k = firstOfPointGroup.count - 1
        for i in firstOfPointGroup.indices where firstOfPointGroup[i] > spaceGroup {
            k = i
            break
        }
        return laue[k - 1]
    }

    /// `crystal_sym.laueid2symops`: the proper rotations of a Laue group as pyEBSDindex stores them (float32 values).
    package static func laueRotations(_ laue: Int) -> [SIMD4<Double>] {
        func f(_ x: Double) -> Double { Double(Float(x)) }
        func q(_ a: Double, _ b: Double, _ c: Double, _ d: Double) -> SIMD4<Double> { SIMD4(f(a), f(b), f(c), f(d)) }
        let pi = Double.pi
        switch laue {
        case 43, 23:
            var ops: [SIMD4<Double>] = [q(1, 0, 0, 0)]
            let (C1, S1, C2, S2) = (cos(0.25 * pi), sin(0.25 * pi), cos(0.75 * pi), sin(0.75 * pi))
            ops += [q(C1, 0, 0, S1), q(C2, 0, 0, S2), q(C1, 0, S1, 0), q(C2, 0, S2, 0), q(C1, S1, 0, 0), q(C2, S2, 0, 0)]
            // float64 values, rounded to float32 where stored (q).
            let h1 = cos(pi * 0.5), hs = sin(pi * 0.5)
            ops += [q(h1, 0, 0, hs), q(h1, 0, hs, 0), q(h1, hs, 0, 0)]
            let t = hs * (1 / 2.0.squareRoot())
            ops += [q(h1, -t, 0, t), q(h1, 0, -t, t), q(h1, t, 0, t), q(h1, 0, t, t), q(h1, -t, t, 0), q(h1, t, t, 0)]
            let r3 = 1 / 3.0.squareRoot()
            let a1 = cos(pi / 3), b1 = sin(pi / 3) * r3, a2 = cos(2 * pi / 3), b2 = sin(2 * pi / 3) * r3
            ops += [q(a1, b1, b1, b1), q(a2, b2, b2, b2), q(a1, -b1, b1, b1), q(a2, -b2, b2, b2),
                    q(a1, -b1, -b1, b1), q(a2, -b2, -b2, b2), q(a1, b1, -b1, b1), q(a2, b2, -b2, b2)]
            return laue == 43 ? ops : [0, 7, 8, 9, 16, 17, 18, 19, 20, 21, 22, 23].map { ops[$0] }
        case 62, 6:
            let ops = [q(1, 0, 0, 0), q(cos(pi / 6), 0, 0, sin(pi / 6)), q(cos(pi / 3), 0, 0, sin(pi / 3)), q(0, 0, 0, 1),
                       q(cos(2 * pi / 3), 0, 0, sin(2 * pi / 3)), q(cos(5 * pi / 6), 0, 0, sin(5 * pi / 6)), q(0, 1, 0, 0),
                       q(0, 0.8660254, 0.5, 0), q(0, 0.5, 0.8660254, 0), q(0, 0, 1, 0), q(0, -0.5, 0.8660254, 0),
                       q(0, -0.8660254, 0.5, 0)]
            return laue == 62 ? ops : Array(ops.prefix(6))
        case 32, 3:
            let ops = [q(1, 0, 0, 0), q(cos(pi / 3), 0, 0, sin(pi / 3)), q(cos(2 * pi / 3), 0, 0, sin(2 * pi / 3)),
                       q(0, 1, 0, 0), q(0, -0.5, 0.8660254, 0), q(0, -0.5, -0.8660254, 0)]
            return laue == 32 ? ops : Array(ops.prefix(3))
        case 42, 4:
            let h = 0.5 * 2.0.squareRoot()
            let ops = [q(1, 0, 0, 0), q(cos(pi / 4), 0, 0, sin(pi / 4)), q(0, 0, 0, 1), q(cos(0.75 * pi), 0, 0, sin(0.75 * pi)),
                       q(0, h, h, 0), q(0, -h, h, 0), q(0, 1, 0, 0), q(0, 0, 1, 0)]
            return laue == 42 ? ops : Array(ops.prefix(4))
        case 22: return [q(1, 0, 0, 0), q(0, 1, 0, 0), q(0, 0, 1, 0), q(0, 0, 0, 1)]
        case 2: return [q(1, 0, 0, 0), q(0, 0, 1, 0)]
        case 1: return [q(1, 0, 0, 0)]
        default: return []
        }
    }

    // MARK: - The cell (crystallometry.Crystal)

    package struct Matrix3: Sendable, Equatable {
        /// Row-major.
        package var m: [Double]
        package init(_ m: [Double]) { self.m = m }
        package subscript(_ i: Int, _ j: Int) -> Double {
            get { m[i * 3 + j] }
            set { m[i * 3 + j] = newValue }
        }
        package var transposed: Matrix3 { Matrix3([m[0], m[3], m[6], m[1], m[4], m[7], m[2], m[5], m[8]]) }
        package static func * (a: Matrix3, v: SIMD3<Double>) -> SIMD3<Double> {
            SIMD3(a.m[0] * v[0] + a.m[1] * v[1] + a.m[2] * v[2],
                  a.m[3] * v[0] + a.m[4] * v[1] + a.m[5] * v[2],
                  a.m[6] * v[0] + a.m[7] * v[1] + a.m[8] * v[2])
        }
        /// Entries under 1e-6 in magnitude set to 0, as `Crystal` does to each matrix.
        func cleaned() -> Matrix3 { Matrix3(m.map { abs($0) < 1e-6 ? 0 : $0 }) }
    }

    struct Cell {
        let reciprocalMetric: Matrix3
        let reciprocalStructure: Matrix3
        let inverseReciprocalStructure: Matrix3

        init(_ p: [Double]) throws {
            let (a, b, c) = (p[0], p[1], p[2])
            let r = Double.pi / 180
            let ca = cos(p[3] * r), cb = cos(p[4] * r), cg = cos(p[5] * r)
            let sa = sin(p[3] * r), sb = sin(p[4] * r), sg = sin(p[5] * r), tg = tan(p[5] * r)
            let det = (a * b * c) * (a * b * c) * (1 - ca * ca - cb * cb - cg * cg + 2 * ca * cb * cg)
            guard det > 0, det.isFinite, sg != 0 else { throw Error.lattice }
            let volume = det.squareRoot()
            // Symmetric, so the transpose pyEBSDindex takes changes nothing.
            var rmt = Matrix3([(b * c * sa) * (b * c * sa), a * b * c * c * (ca * cb - cg), a * b * b * c * (cg * ca - cb),
                               a * b * c * c * (ca * cb - cg), (a * c * sb) * (a * c * sb), a * a * b * c * (cb * cg - ca),
                               a * b * b * c * (cg * ca - cb), a * a * b * c * (cb * cg - ca), (a * b * sg) * (a * b * sg)])
            rmt = Matrix3(rmt.m.map { $0 / det }).cleaned()
            reciprocalMetric = rmt
            // directStructureMatrix as built (column-wise), then transposed and cleaned; its transpose is the inverse of the
            // reciprocal structure matrix.
            var direct = Matrix3([Double](repeating: 0, count: 9))
            direct[0, 0] = a; direct[1, 0] = b * cg; direct[2, 0] = c * cb
            direct[1, 1] = b * sg; direct[2, 1] = -c * (cb * cg - ca) / sg
            direct[2, 2] = volume / (a * b * sg)
            direct = direct.transposed.cleaned()
            inverseReciprocalStructure = direct.transposed
            var rs = Matrix3([Double](repeating: 0, count: 9))
            rs[0, 0] = 1 / a
            rs[0, 1] = -1 / (a * tg); rs[1, 1] = 1 / (b * sg)
            rs[0, 2] = b * c * (cg * ca - cb) / (volume * sg); rs[1, 2] = a * c * (cb * cg - ca) / (volume * sg)
            rs[2, 2] = (a * b * sg) / volume
            reciprocalStructure = rs.transposed.cleaned()
        }
    }
}
