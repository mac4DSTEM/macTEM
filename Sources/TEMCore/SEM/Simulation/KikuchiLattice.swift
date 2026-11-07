//
//  KikuchiLattice.swift
//  Role: the crystal lattice as the Kikuchi simulations see it: diffpy.structure 3.3's `Lattice` (`base`, the rows a, b, c in
//        Cartesian coordinates with c along z and b in the yz plane; `recbase`, its inverse, whose columns are a*, b*, c*; `volume`;
//        `rnorm`, |g| of a plane hkl), and the same lattice re-aligned as orix 0.15.0's `Phase` holds it (x along a, z along c*, the
//        matrix rounded to 12 decimals: `new_structure_matrix_from_alignment`), which is the frame kikuchipy's simulations and diffsims'
//        reflectors work in. Exact cosines of the multiples of 60 and 90 degrees as diffpy's `cosd` (so a cubic or hexagonal cell
//        has exact zeros). Ported from diffpy.structure (`lattice.py`, BSD-3-Clause) and orix (`crystal_map/_phase.py`,
//        GPL-3.0-or-later); parity bundle `m6/kikuchi-lattice` in tools/parity/sem, rows in docs/parity.md.
//

import Foundation

package nonisolated struct KikuchiLattice: Sendable, Equatable {
    /// a, b, c (any length unit; the simulations take Å or nm alike) and α, β, γ in degrees.
    package let a: Double, b: Double, c: Double
    package let alpha: Double, beta: Double, gamma: Double
    /// Rows a, b, c in Cartesian coordinates (diffpy's `base`, or orix's re-aligned one).
    package let base: [SIMD3<Double>]
    /// The inverse of `base` by rows (diffpy's `recbase`): its columns are a*, b*, c*.
    package let recbase: [SIMD3<Double>]

    /// diffpy's `Lattice(a, b, c, alpha, beta, gamma)`: c along z, b in the yz plane (`stdbase`, no base rotation).
    package init(a: Double, b: Double, c: Double, alpha: Double, beta: Double, gamma: Double) {
        self.init(a: a, b: b, c: c, alpha: alpha, beta: beta, gamma: gamma,
                  base: Self.standardBase(a: a, b: b, c: c, alpha: alpha, beta: beta, gamma: gamma))
    }

    private init(a: Double, b: Double, c: Double, alpha: Double, beta: Double, gamma: Double, base: [SIMD3<Double>]) {
        self.a = a; self.b = b; self.c = c; self.alpha = alpha; self.beta = beta; self.gamma = gamma
        self.base = base
        self.recbase = Self.inverse(base)
    }

    /// The lattice from (a, b, c, α, β, γ), the order of a phase's `lattice` row; nil for a row of another length.
    package init?(parameters p: [Double]) {
        guard p.count == 6 else { return nil }
        self.init(a: p[0], b: p[1], c: p[2], alpha: p[3], beta: p[4], gamma: p[5])
    }

    /// The same lattice as orix's `Phase` stores it: x along a, z along c*, y = z × x; the rows of `base` expressed in that frame and
    /// rounded to 12 decimals (`new_structure_matrix_from_alignment(base, x="a", z="c*")`).
    package var orixAligned: KikuchiLattice {
        let ad = Vector3.unit(base[0]), bd = Vector3.unit(base[1])
        let cr = Vector3.unit(Vector3.cross(ad, bd))
        let y = Vector3.cross(cr, ad)
        let frame = [ad, y, cr]
        let rows = base.map { row in
            SIMD3(Self.round12(Vector3.dot(frame[0], row)), Self.round12(Vector3.dot(frame[1], row)), Self.round12(Vector3.dot(frame[2], row)))
        }
        return KikuchiLattice(a: a, b: b, c: c, alpha: alpha, beta: beta, gamma: gamma, base: rows)
    }

    /// The cell volume, a b c √(1 + 2 cos α cos β cos γ − cos²α − cos²β − cos²γ) (diffpy's `volume`).
    package var volume: Double {
        let ca = Self.cosd(alpha), cb = Self.cosd(beta), cg = Self.cosd(gamma)
        return a * b * c * (1 + 2 * ca * cb * cg - ca * ca - cb * cb - cg * cg).squareRoot()
    }

    /// The Cartesian reciprocal vector of the plane hkl, hkl · recbaseᵀ (h a* + k b* + l c*).
    package func reciprocal(_ hkl: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3(Vector3.dot(hkl, recbase[0]), Vector3.dot(hkl, recbase[1]), Vector3.dot(hkl, recbase[2]))
    }

    /// The Cartesian direction of uvw, uvw · base (u a + v b + w c).
    package func direct(_ uvw: SIMD3<Double>) -> SIMD3<Double> {
        base[0] * uvw.x + base[1] * uvw.y + base[2] * uvw.z
    }

    /// The direct-lattice indices of a Cartesian vector, xyz · base⁻¹ (orix's `Miller(xyz=...).uvw`).
    package func directIndices(_ xyz: SIMD3<Double>) -> SIMD3<Double> {
        recbase[0] * xyz.x + recbase[1] * xyz.y + recbase[2] * xyz.z
    }

    /// The reciprocal-lattice indices of a Cartesian vector, xyz · baseᵀ (orix's `Miller(xyz=...).hkl`).
    package func reciprocalIndices(_ xyz: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3(Vector3.dot(xyz, base[0]), Vector3.dot(xyz, base[1]), Vector3.dot(xyz, base[2]))
    }

    /// |g| of the plane hkl in the inverse of the lattice's length unit (diffpy's `rnorm`).
    package func rnorm(_ hkl: SIMD3<Double>) -> Double {
        let g = reciprocal(hkl)
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
}
