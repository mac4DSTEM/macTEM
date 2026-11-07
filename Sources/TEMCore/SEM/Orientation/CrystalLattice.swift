//
//  CrystalLattice.swift
//  Role: the crystal lattice of a phase, one type for orix's Miller vectors, the texture code and the Kikuchi simulations.
//        diffpy.structure 3.5's `Lattice` (`base`, the rows a, b, c in Cartesian coordinates with c along z and b in the yz plane;
//        `recbase`, its inverse, whose columns are a*, b*, c*; `volume`; `rnorm`, |g| of a plane hkl) and the same lattice
//        re-aligned as orix 0.15.0's `Phase` holds it (x along a, z along c*, the matrix rounded to 12 decimals:
//        `new_structure_matrix_from_alignment`), the frame orix's vectors, kikuchipy's simulations and diffsims' reflectors work in.
//        `CrystalLattice(a:b:c:alpha:beta:gamma:)` is that orix frame; `CrystalLattice.diffpy` keeps diffpy's. Exact cosines of the
//        multiples of 60 and 90 degrees as diffpy's `cosd` (a cubic or hexagonal cell has exact zeros and halves). Ported from
//        diffpy.structure (`lattice.py`, BSD-3-Clause) and orix (`crystal_map/_phase.py`, `vector/miller.py`, GPL-3.0-or-later),
//        see NOTICE. Parity bundles `m3/ipf-color-keys` and `m6/kikuchi-lattice` in tools/parity/sem, rows in docs/parity.md.
//

import Foundation

package nonisolated struct CrystalLattice: Sendable, Equatable {
    /// a, b, c (any length unit; the simulations take Å or nm alike) and α, β, γ in degrees.
    package let a: Double, b: Double, c: Double
    package let alpha: Double, beta: Double, gamma: Double
    /// Rows a, b, c in Cartesian coordinates (orix's re-aligned base, or diffpy's for `diffpy`).
    package let base: [SIMD3<Double>]
    /// The inverse of `base` by rows (diffpy's `recbase`): its columns are a*, b*, c*.
    package let recbase: [SIMD3<Double>]

    /// The lattice as orix's `Phase.structure.lattice` holds it: diffpy's lattice re-aligned to x ∥ a, z ∥ c*, in closed form,
    /// rows (a, 0, 0), (b cos γ, b sin γ, 0), (c cos β, c (cos α − cos β cos γ) / sin γ, c V′ / sin γ) rounded to 12 decimals
    /// (V′ the unit-cell volume factor). Equal to `diffpy(...).orixAligned` after the rounding (the `m6/kikuchi-lattice` test).
    package init(a: Double, b: Double, c: Double, alpha: Double, beta: Double, gamma: Double) {
        let ca = Self.cosd(alpha), cb = Self.cosd(beta), cg = Self.cosd(gamma)
        let sg = Self.sind(gamma)
        let volumeFactor = (1 - ca * ca - cb * cb - cg * cg + 2 * ca * cb * cg).squareRoot()
        let rows = [SIMD3(a, 0, 0),
                    SIMD3(b * cg, b * sg, 0),
                    SIMD3(c * cb, c * (ca - cb * cg) / sg, c * volumeFactor / sg)]
        self.init(a: a, b: b, c: c, alpha: alpha, beta: beta, gamma: gamma,
                  base: rows.map { SIMD3(Self.round12($0.x), Self.round12($0.y), Self.round12($0.z)) })
    }

    /// The orix-frame lattice from (a, b, c, α, β, γ), the order of a phase's `lattice` row; nil for a row of another length.
    package init?(parameters p: [Double]) {
        guard p.count == 6 else { return nil }
        self.init(a: p[0], b: p[1], c: p[2], alpha: p[3], beta: p[4], gamma: p[5])
    }

    private init(a: Double, b: Double, c: Double, alpha: Double, beta: Double, gamma: Double, base: [SIMD3<Double>]) {
        self.a = a; self.b = b; self.c = c; self.alpha = alpha; self.beta = beta; self.gamma = gamma
        self.base = base
        self.recbase = Self.inverse(base)
    }

    /// diffpy's `Lattice(a, b, c, alpha, beta, gamma)`: c along z, b in the yz plane (`stdbase`, no base rotation).
    package static func diffpy(a: Double, b: Double, c: Double, alpha: Double, beta: Double, gamma: Double) -> CrystalLattice {
        CrystalLattice(a: a, b: b, c: c, alpha: alpha, beta: beta, gamma: gamma,
                       base: standardBase(a: a, b: b, c: c, alpha: alpha, beta: beta, gamma: gamma))
    }

    /// diffpy's lattice from a six-parameter row; nil for a row of another length.
    package static func diffpy(parameters p: [Double]) -> CrystalLattice? {
        p.count == 6 ? diffpy(a: p[0], b: p[1], c: p[2], alpha: p[3], beta: p[4], gamma: p[5]) : nil
    }

    /// orix's default lattice of a crystal system: 1, 1, 1 with 90° angles, γ 120° for trigonal and hexagonal.
    package static func defaultLattice(system: String?) -> CrystalLattice {
        let hexagonal = system == "trigonal" || system == "hexagonal"
        return CrystalLattice(a: 1, b: 1, c: 1, alpha: 90, beta: 90, gamma: hexagonal ? 120 : 90)
    }

    /// The same lattice as orix's `Phase` stores it: x along a, z along c*, y = z × x; the rows of `base` expressed in that frame and
    /// rounded to 12 decimals (`new_structure_matrix_from_alignment(base, x="a", z="c*")`).
    package var orixAligned: CrystalLattice {
        let ad = Vector3.unit(base[0]), bd = Vector3.unit(base[1])
        let cr = Vector3.unit(Vector3.cross(ad, bd))
        let y = Vector3.cross(cr, ad)
        let frame = [ad, y, cr]
        let rows = base.map { row in
            SIMD3(Self.round12(Vector3.dot(frame[0], row)), Self.round12(Vector3.dot(frame[1], row)), Self.round12(Vector3.dot(frame[2], row)))
        }
        return CrystalLattice(a: a, b: b, c: c, alpha: alpha, beta: beta, gamma: gamma, base: rows)
    }

    /// The cell volume, a b c √(1 + 2 cos α cos β cos γ − cos²α − cos²β − cos²γ) (diffpy's `volume`).
    package var volume: Double {
        let ca = Self.cosd(alpha), cb = Self.cosd(beta), cg = Self.cosd(gamma)
        return a * b * c * (1 + 2 * ca * cb * cg - ca * ca - cb * cb - cg * cg).squareRoot()
    }

    // MARK: Frames (orix's `_transform_space`)

    /// "d" → "c": xyz = uvw · A (u a + v b + w c).
    package func cartesian(uvw: SIMD3<Double>) -> SIMD3<Double> { Self.times(uvw, base) }
    /// "r" → "c": xyz = hkl · (A⁻¹)ᵀ (h a* + k b* + l c*).
    package func cartesian(hkl: SIMD3<Double>) -> SIMD3<Double> { Self.timesTransposed(hkl, recbase) }
    /// "c" → "d": uvw = xyz · A⁻¹.
    package func uvw(cartesian xyz: SIMD3<Double>) -> SIMD3<Double> { Self.times(xyz, recbase) }
    /// "c" → "r": hkl = xyz · Aᵀ.
    package func hkl(cartesian xyz: SIMD3<Double>) -> SIMD3<Double> { Self.timesTransposed(xyz, base) }

    /// |g| of the plane hkl in the inverse of the lattice's length unit (diffpy's `rnorm`).
    package func rnorm(_ hkl: SIMD3<Double>) -> Double {
        let g = cartesian(hkl: hkl)
        return (g.x * g.x + g.y * g.y + g.z * g.z).squareRoot()
    }

    /// The interplanar spacing 1 / |g|.
    package func dSpacing(_ hkl: SIMD3<Double>) -> Double { 1 / rnorm(hkl) }

    // MARK: diffpy's arithmetic

    /// diffpy's `cosd`: the exact cosine at 0, 60, 90, 120, 180, 240, 270 and 300 degrees (the angle modulo 360), else cos.
    package static func cosd(_ x: Double) -> Double {
        var m = x.truncatingRemainder(dividingBy: 360)
        if m < 0 { m += 360 }
        switch m {
        case 0: return 1
        case 60, 300: return 0.5
        case 90, 270: return 0
        case 120, 240: return -0.5
        case 180: return -1
        default: return cos(x * .pi / 180)
        }
    }

    /// diffpy's `sind`, cosd(90 − x).
    package static func sind(_ x: Double) -> Double { cosd(90 - x) }

    /// diffpy's `stdbase`: rows (1/a*, −cos γ* / sin γ* / a*, a cos β), (0, b sin α, b cos α), (0, 0, c).
    static func standardBase(a: Double, b: Double, c: Double, alpha: Double, beta: Double, gamma: Double) -> [SIMD3<Double>] {
        let ca = cosd(alpha), cb = cosd(beta), cg = cosd(gamma)
        let sa = sind(alpha), sb = sind(beta)
        let unitVolume = (1 + 2 * ca * cb * cg - ca * ca - cb * cb - cg * cg).squareRoot()
        let ar = sa / (a * unitVolume)
        let cgr = (ca * cb - cg) / (sa * sb)
        let sgr = (1 - cgr * cgr).squareRoot()
        return [SIMD3(1 / ar, -cgr / sgr / ar, cb * a), SIMD3(0, b * sa, b * ca), SIMD3(0, 0, c)]
    }

    /// numpy's `round(x, 12)`: half to even at the twelfth decimal.
    static func round12(_ x: Double) -> Double {
        let scale = 1e12
        return (x * scale).rounded(.toNearestOrEven) / scale
    }

    /// The inverse of a 3 × 3 matrix given by rows (the adjugate over the determinant).
    static func inverse(_ m: [SIMD3<Double>]) -> [SIMD3<Double>] {
        let r0 = m[0], r1 = m[1], r2 = m[2]
        let c0 = Vector3.cross(r1, r2), c1 = Vector3.cross(r2, r0), c2 = Vector3.cross(r0, r1)
        let det = Vector3.dot(r0, c0)
        // The inverse's columns are the cofactor rows over the determinant.
        return [SIMD3(c0.x, c1.x, c2.x) / det, SIMD3(c0.y, c1.y, c2.y) / det, SIMD3(c0.z, c1.z, c2.z) / det]
    }

    /// v · M (row vector times matrix given by rows).
    static func times(_ v: SIMD3<Double>, _ m: [SIMD3<Double>]) -> SIMD3<Double> {
        v.x * m[0] + v.y * m[1] + v.z * m[2]
    }

    /// v · Mᵀ.
    static func timesTransposed(_ v: SIMD3<Double>, _ m: [SIMD3<Double>]) -> SIMD3<Double> {
        SIMD3(Vector3.dot(v, m[0]), Vector3.dot(v, m[1]), Vector3.dot(v, m[2]))
    }
}
