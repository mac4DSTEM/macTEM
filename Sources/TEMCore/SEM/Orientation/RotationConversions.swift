//
//  RotationConversions.swift
//  The rotation representations of Rowenhorst et al. (2015), "Consistent representations of and conversions between 3D
//  rotations", Modelling Simul. Mater. Sci. Eng. 23 083501: orix 0.15.0's `orix.quaternion._conversions` ported function by
//  function (eu2qu, qu2eu, om2qu, qu2om, ax2qu, qu2ax, qu2ho, ho2ax, ax2ro, ro2ax, ho2ro, cu2ho, cu2ro, get_pyramid), one
//  element at a time; orix runs the same kernels per row under numba. GPL-3.0 (orix is GPL-3.0-or-later), see NOTICE.
//
//  Conventions (orix's, P = -1): unit quaternions (a, b, c, d) scalar first, passive, Bunge Euler angles (φ1, Φ, φ2) in radians,
//  lab to crystal; axis-angle and Rodrigues-Frank vectors as four numbers (n_x, n_y, n_z, ω or tan(ω/2)), homochoric and
//  cubochoric vectors as three. Parity: `tools/parity/sem` bundle `m3/rotation-conversions`, atol 1e-7 (docs/parity.md).
//

import Foundation

/// A 3 x 3 rotation (orientation) matrix, rows first: `self[i, j]` is row i, column j, as orix's `qu2om` writes it.
package nonisolated struct RotationMatrix: Sendable, Equatable {
    package var rows: [SIMD3<Double>]

    package init(rows: [SIMD3<Double>]) {
        precondition(rows.count == 3, "RotationMatrix takes three rows")
        self.rows = rows
    }

    package subscript(i: Int, j: Int) -> Double {
        get { rows[i][j] }
        set { rows[i][j] = newValue }
    }

    /// Row-major, nine numbers.
    package var flat: [Double] { rows.flatMap { [$0.x, $0.y, $0.z] } }
}

package nonisolated enum RotationConversions {
    /// orix's `constants.eps9` and `eps12`.
    package static let eps9 = 1e-9
    package static let eps12 = 1e-12

    // MARK: - Euler angles (Bunge)

    /// `eu2qu_single` (eqs. A.5-6): Bunge Euler angles in radians to a unit quaternion with a non-negative scalar part.
    package static func eu2qu(_ eu: SIMD3<Double>) -> SIMD4<Double> {
        let sigma = 0.5 * (eu.x + eu.z)
        let delta = 0.5 * (eu.x - eu.z)
        let c = cos(eu.y / 2), s = sin(eu.y / 2)
        var q = SIMD4(c * cos(sigma), -s * cos(delta), -s * sin(delta), -c * sin(sigma))
        if q.x < 0 { q = -q }
        return q
    }

    /// `qu2eu_single` (eq. A.14): unit quaternion to Bunge Euler angles in [0, 2π) x [0, π] x [0, 2π).
    package static func qu2eu(_ qu: SIMD4<Double>) -> SIMD3<Double> {
        var eu = SIMD3<Double>(0, 0, 0)
        let qAD = qu[0] * qu[0] + qu[3] * qu[3]
        let qBC = qu[1] * qu[1] + qu[2] * qu[2]
        let chi = (qAD * qBC).squareRoot()
        if chi < eps9 {
            let a: Double, b: Double
            if qBC < eps9 {
                a = -2 * qu[0] * qu[3]
                b = qu[0] * qu[0] - qu[3] * qu[3]
            } else {
                a = -2 * qu[1] * qu[2]
                b = qu[1] * qu[1] - qu[2] * qu[2]
                eu.y = Double.pi
            }
            eu.x = atan2(a, b)
            return SIMD3(numpyMod(eu.x, 2 * Double.pi), numpyMod(eu.y, 2 * Double.pi), numpyMod(eu.z, 2 * Double.pi))
        }
        let eu0a = (qu[1] * qu[3] - qu[0] * qu[2]) / chi
        let eu0b = (-qu[0] * qu[1] - qu[2] * qu[3]) / chi
        let eu2a = (qu[0] * qu[2] + qu[1] * qu[3]) / chi
        let eu2b = (qu[2] * qu[3] - qu[0] * qu[1]) / chi
        eu.x = atan2(eu0a, eu0b)
        eu.y = atan2(2 * chi, qAD - qBC)
        eu.z = atan2(eu2a, eu2b)
        for i in 0..<3 where abs(eu[i]) < eps9 { eu[i] = 0 }
        return SIMD3(numpyMod(eu.x, 2 * Double.pi), numpyMod(eu.y, 2 * Double.pi), numpyMod(eu.z, 2 * Double.pi))
    }

    /// `numpy.mod` for a positive divisor: the result has the divisor's sign (Python's `%`), never `fmod`'s.
    package static func numpyMod(_ x: Double, _ m: Double) -> Double {
        let r = x.truncatingRemainder(dividingBy: m)
        if r != 0, (r < 0) != (m < 0) { return r + m }
        return r
    }

    // MARK: - Matrices

    /// `om2qu_single` (eq. A.11 with the sign rule of the erratum): rotation matrix to a unit quaternion.
    package static func om2qu(_ om: RotationMatrix) -> SIMD4<Double> {
        let aAlmost = 1 + om[0, 0] + om[1, 1] + om[2, 2]
        let bAlmost = 1 + om[0, 0] - om[1, 1] - om[2, 2]
        let cAlmost = 1 - om[0, 0] + om[1, 1] - om[2, 2]
        let dAlmost = 1 - om[0, 0] - om[1, 1] + om[2, 2]
        var qu = SIMD4<Double>(0, 0, 0, 0)
        qu[0] = aAlmost < eps9 ? 0 : 0.5 * aAlmost.squareRoot()
        if bAlmost < eps9 { qu[1] = 0 } else if om[2, 1] < om[1, 2] { qu[1] = -0.5 * bAlmost.squareRoot() } else { qu[1] = 0.5 * bAlmost.squareRoot() }
        if cAlmost < eps9 { qu[2] = 0 } else if om[0, 2] < om[2, 0] { qu[2] = -0.5 * cAlmost.squareRoot() } else { qu[2] = 0.5 * cAlmost.squareRoot() }
        if dAlmost < eps9 { qu[3] = 0 } else if om[1, 0] < om[0, 1] { qu[3] = -0.5 * dAlmost.squareRoot() } else { qu[3] = 0.5 * dAlmost.squareRoot() }
        return qu / norm(qu)
    }

    /// `qu2om_single` (eq. A.15): unit quaternion to the rotation matrix.
    package static func qu2om(_ qu: SIMD4<Double>) -> RotationMatrix {
        let bb = qu[1] * qu[1], cc = qu[2] * qu[2], dd = qu[3] * qu[3]
        let qq = qu[0] * qu[0] - (bb + cc + dd)
        let bc = qu[1] * qu[2], ad = qu[0] * qu[3], bd = qu[1] * qu[3]
        let ac = qu[0] * qu[2], cd = qu[2] * qu[3], ab = qu[0] * qu[1]
        return RotationMatrix(rows: [
            SIMD3(qq + 2 * bb, 2 * (bc - ad), 2 * (bd + ac)),
            SIMD3(2 * (bc + ad), qq + 2 * cc, 2 * (cd - ab)),
            SIMD3(2 * (bd - ac), 2 * (cd + ab), qq + 2 * dd),
        ])
    }

    // MARK: - Axis-angle

    /// `ax2qu_single` (eq. A.2.4): (n_x, n_y, n_z, ω) to a unit quaternion; the axis is taken as given (orix normalises it
    /// before this call where its API asks for an axis).
    package static func ax2qu(_ ax: SIMD4<Double>) -> SIMD4<Double> {
        if ax[3] > -1e-8, ax[3] < 1e-8 { return SIMD4(1, 0, 0, 0) }
        let c = cos(ax[3] * 0.5), s = sin(ax[3] * 0.5)
        let qu = SIMD4(c, ax[0] * s, ax[1] * s, ax[2] * s)
        return qu / norm(qu)
    }

    /// `qu2ax_single` (eq. A.2.2): unit quaternion to (n_x, n_y, n_z, ω), ω = 2 arccos(a) in [0, 2π].
    package static func qu2ax(_ qu: SIMD4<Double>) -> SIMD4<Double> {
        let omega = 2 * acos(qu[0])
        if omega < eps9 { return SIMD4(0, 0, 1, 0) }
        if abs(qu[0]) < eps9 { return SIMD4(qu[1], qu[2], qu[3], Double.pi) }
        var s = (qu[1] * qu[1] + qu[2] * qu[2] + qu[3] * qu[3]).squareRoot()
        if qu[0] <= 0 { s = -s }
        return SIMD4(qu[1] / s, qu[2] / s, qu[3] / s, omega)
    }

    // MARK: - Homochoric

    /// `qu2ho_single` (eq. A.2.6): unit quaternion to the homochoric vector n [3/4 (ω − sin ω)]^(1/3).
    package static func qu2ho(_ qu: SIMD4<Double>) -> SIMD3<Double> {
        let omega = 2 * acos(qu[0])
        if omega < eps9 { return SIMD3(0, 0, 0) }
        let s = (qu[1] * qu[1] + qu[2] * qu[2] + qu[3] * qu[3]).squareRoot()
        let n = SIMD3(qu[1], qu[2], qu[3]) / s
        let f = 3 * (omega - sin(omega)) / 4
        return n * pow(f, 1.0 / 3.0)
    }

    /// The 21 coefficients of `ho2ax_single`'s polynomial fit (Rowenhorst et al. 2015, table 3).
    private static let ho2axFit: [Double] = [
        0.9999999999999968, -0.49999999999986866, -0.025000000000632055,
        -0.003928571496460683, -0.0008164666077062752, -0.00019411896443261646,
        -0.00004985822229871769, -0.000014164962366386031, -1.9000248160936107e-6,
        -5.72184549898506e-6, 7.772149920658778e-6, -0.00001053483452909705,
        9.528014229335313e-6, -5.660288876265125e-6, 1.2844901692764126e-6,
        1.1255185726258763e-6, -1.3834391419956455e-6, 7.513691751164847e-7,
        -2.401996891720091e-7, 4.386887017466388e-8, -3.5917775353564864e-9,
    ]

    /// `ho2ax_single` (eq. A.2.8 with the polynomial fit): homochoric vector to (n_x, n_y, n_z, ω).
    package static func ho2ax(_ ho: SIMD3<Double>) -> SIMD4<Double> {
        let hoMagnitude = ho.x * ho.x + ho.y * ho.y + ho.z * ho.z
        if hoMagnitude > -1e-8, hoMagnitude < 1e-8 { return SIMD4(0, 0, 1, 0) }
        var hom = hoMagnitude
        var s = ho2axFit[0] + ho2axFit[1] * hom
        for i in 2..<21 {
            hom *= hoMagnitude
            s += ho2axFit[i] * hom
        }
        let hon = ho / hoMagnitude.squareRoot()
        s = 2 * acos(s)
        if abs(s - Double.pi) < 1e-8 { return SIMD4(hon.x, hon.y, hon.z, Double.pi) }
        return SIMD4(hon.x, hon.y, hon.z, s)
    }

    // MARK: - Rodrigues-Frank

    /// `ax2ro_single` (eq. A.3.3): (n, ω) to (n, tan(ω/2)); a two-fold rotation (within 1e-3 of π) gives +∞.
    package static func ax2ro(_ ax: SIMD4<Double>) -> SIMD4<Double> {
        let angle = ax[3]
        if angle > -1e-8, angle < 1e-8 { return SIMD4(0, 0, 1, 0) }
        let last = abs(angle - Double.pi) < 1e-3 ? Double.infinity : tan(angle * 0.5)
        return SIMD4(ax[0], ax[1], ax[2], last)
    }

    /// `ro2ax_single` (eq. A.3.4): (n, tan(ω/2)) to (n, ω).
    package static func ro2ax(_ ro: SIMD4<Double>) -> SIMD4<Double> {
        if ro[3] > -1e-8, ro[3] < 1e-8 { return SIMD4(0, 0, 1, 0) }
        if ro[3].isInfinite { return SIMD4(ro[0], ro[1], ro[2], Double.pi) }
        let n = (ro[0] * ro[0] + ro[1] * ro[1] + ro[2] * ro[2]).squareRoot()
        return SIMD4(ro[0] / n, ro[1] / n, ro[2] / n, 2 * atan(ro[3]))
    }

    /// `ho2ro_single`.
    package static func ho2ro(_ ho: SIMD3<Double>) -> SIMD4<Double> { ax2ro(ho2ax(ho)) }

    // MARK: - Cubochoric

    /// `get_pyramid_single`: which of the cube's six pyramids holds the point (1 top, 2 bottom, 3 front, 4 back, 5 right, 6 left).
    package static func pyramid(_ xyz: SIMD3<Double>) -> Int {
        let x = xyz.x, y = xyz.y, z = xyz.z
        let xa = abs(x), ya = abs(y), za = abs(z)
        if xa <= z, ya <= z { return 1 }
        if xa <= -z, ya <= -z { return 2 }
        if za <= x, ya <= x { return 3 }
        if za <= -x, ya <= -x { return 4 }
        if xa <= y, za <= y { return 5 }
        return 6
    }

    /// `cu2ho_single` (Roşca et al. 2014, the cube-to-ball map): cubochoric to homochoric; a point outside the cube of
    /// semi-edge π^(2/3)/2 (+1e-8) gives the zero vector, as orix returns.
    package static func cu2ho(_ cuIn: SIMD3<Double>) -> SIMD3<Double> {
        if max(abs(cuIn.x), abs(cuIn.y), abs(cuIn.z)) > pow(Double.pi, 2.0 / 3.0) / 2 + 1e-8 { return SIMD3(0, 0, 0) }
        let p = pyramid(cuIn)
        var cu = cuIn
        if p == 3 || p == 4 {
            cu = SIMD3(cuIn.y, cuIn.z, cuIn.x)          // np.roll(cu, -1)
        } else if p == 5 || p == 6 {
            cu = SIMD3(cuIn.z, cuIn.x, cuIn.y)          // np.roll(cu, 1)
        }
        cu = cu * (pow(Double.pi, 1.0 / 6.0) / pow(6.0, 1.0 / 6.0))
        let cuAbs = SIMD3(abs(cu.x), abs(cu.y), abs(cu.z))
        var ho: SIMD3<Double>
        if max(cuAbs.x, cuAbs.y, cuAbs.z) == 0 {
            ho = SIMD3(0, 0, 0)
        } else if max(cuAbs.x, cuAbs.y) == 0 {
            ho = SIMD3(0, 0, (6 / Double.pi).squareRoot() * cu.z)
        } else {
            let x = cu.x, y = cu.y, z = cu.z
            let prefactor = pow(3 * Double.pi / 4, 1.0 / 3.0) * pow(2.0, 1.0 / 4.0)
                / (pow(Double.pi, 5.0 / 6.0) / pow(6.0, 1.0 / 6.0) / 2)
            let sqrt2 = 2.0.squareRoot()
            var t1: Double, t2: Double
            if abs(y) <= abs(x) {
                let q0 = (Double.pi / 12) * y / x
                let cosq = cos(q0), sinq = sin(q0)
                let q = prefactor * x / (sqrt2 - cosq).squareRoot()
                t1 = (sqrt2 * cosq - 1) * q
                t2 = sqrt2 * sinq * q
            } else {
                let q0 = (Double.pi / 12) * x / y
                let cosq = cos(q0), sinq = sin(q0)
                let q = prefactor * y / (sqrt2 - cosq).squareRoot()
                t1 = sqrt2 * sinq * q
                t2 = (sqrt2 * cosq - 1) * q
            }
            let c0 = t1 * t1 + t2 * t2
            let s = Double.pi * c0 / (24 * z * z)
            let c = Double.pi.squareRoot() * c0 / 24.0.squareRoot() / z
            let q = (1 - s).squareRoot()
            ho = SIMD3(t1 * q, t2 * q, (6 / Double.pi).squareRoot() * z - c)
        }
        if p == 3 || p == 4 { return SIMD3(ho.z, ho.x, ho.y) }   // np.roll(ho, 1)
        if p == 5 || p == 6 { return SIMD3(ho.y, ho.z, ho.x) }   // np.roll(ho, -1)
        return ho
    }

    /// `cu2ro_single`.
    package static func cu2ro(_ cu: SIMD3<Double>) -> SIMD4<Double> {
        if max(abs(cu.x), abs(cu.y), abs(cu.z)) == 0 { return SIMD4(0, 0, 1, 0) }
        return ho2ro(cu2ho(cu))
    }

    // MARK: - Helpers

    /// numpy's `sqrt(sum(square(q)))`, summed left to right.
    package static func norm(_ q: SIMD4<Double>) -> Double {
        (q[0] * q[0] + q[1] * q[1] + q[2] * q[2] + q[3] * q[3]).squareRoot()
    }

    package static func norm(_ v: SIMD3<Double>) -> Double {
        (v.x * v.x + v.y * v.y + v.z * v.z).squareRoot()
    }
}
