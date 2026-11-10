//
//  Rotation.swift
//  orix 0.15.0's `Quaternion` and `Rotation` (orix.quaternion.quaternion, orix.quaternion.rotation): a unit quaternion with an
//  improper flag, composition, inverse, angle and axis, the vector action, the conversions to and from every representation
//  of Rowenhorst et al. (2015) through `RotationConversions`, outer products and `unique`. GPL-3.0 (orix is
//  GPL-3.0-or-later), see NOTICE.
//
//  Numbers follow orix's own code paths: the product is orix's `qu_multiply` formula, a product is renormalised as orix's
//  `Rotation(...)` constructor does, `angle_with` rounds its dot product to 15 decimals as orix does, `unique` keys on orix's
//  rounded differentiators and keeps first appearances in orix's flattening order. Parity: `tools/parity/sem` bundle
//  `m3/rotation-conversions`, atol 1e-7 (docs/parity.md).
//

import Foundation

/// Rotations as orix's `Rotation`: a unit quaternion (a, b, c, d), scalar first, passive (lab to crystal for an orientation),
/// and a flag for an improper rotation (the quaternion's rotation followed by inversion).
package nonisolated struct Rotation: Sendable, Equatable {
    package var q: SIMD4<Double>
    package var improper: Bool

    /// orix's `Rotation(data)`: the quaternion divided by its norm.
    package init(_ q: SIMD4<Double>, improper: Bool = false) {
        self.q = q / RotationConversions.norm(q)
        self.improper = improper
    }

    /// The quaternion as given (already unit).
    package init(unit q: SIMD4<Double>, improper: Bool = false) {
        self.q = q
        self.improper = improper
    }

    package static let identity = Rotation(unit: SIMD4(1, 0, 0, 0))

    // MARK: - Quaternion algebra

    /// orix's `qu_multiply`: the Hamilton product q1 q2.
    package static func product(_ q1: SIMD4<Double>, _ q2: SIMD4<Double>) -> SIMD4<Double> {
        SIMD4(q1[0] * q2[0] - q1[1] * q2[1] - q1[2] * q2[2] - q1[3] * q2[3],
              q1[1] * q2[0] + q1[0] * q2[1] - q1[3] * q2[2] + q1[2] * q2[3],
              q1[2] * q2[0] + q1[3] * q2[1] + q1[0] * q2[2] - q1[1] * q2[3],
              q1[3] * q2[0] - q1[2] * q2[1] + q1[1] * q2[2] + q1[0] * q2[3])
    }

    /// The conjugate (a, −b, −c, −d).
    package static func conjugate(_ q: SIMD4<Double>) -> SIMD4<Double> { SIMD4(q[0], -q[1], -q[2], -q[3]) }

    /// orix's `qu_rotate_vec`: the vector rotated by the unit quaternion, q v q*.
    package static func rotate(_ q: SIMD4<Double>, _ v: SIMD3<Double>) -> SIMD3<Double> {
        let a = q[0], b = q[1], c = q[2], d = q[3]
        let x = v.x, y = v.y, z = v.z
        let tx = 2 * (c * z - d * y)
        let ty = 2 * (d * x - b * z)
        let tz = 2 * (b * y - c * x)
        return SIMD3(x + a * tx - d * ty + c * tz,
                     y + d * tx + a * ty - b * tz,
                     z - c * tx + b * ty + a * tz)
    }

    /// `Rotation.__mul__` with a rotation: the quaternion product renormalised, improper flags combined by exclusive or.
    package static func * (lhs: Rotation, rhs: Rotation) -> Rotation {
        Rotation(product(lhs.q, rhs.q), improper: lhs.improper != rhs.improper)
    }

    /// `Rotation.__mul__` with a vector: the rotated vector, negated for an improper rotation.
    package static func * (lhs: Rotation, rhs: SIMD3<Double>) -> SIMD3<Double> {
        let v = rotate(lhs.q / RotationConversions.norm(lhs.q), rhs)
        return lhs.improper ? -v : v
    }

    /// `~R`: the conjugate over the squared norm, the improper flag kept.
    package var inverse: Rotation {
        let n = RotationConversions.norm(q)
        return Rotation(Rotation.conjugate(q) / (n * n), improper: improper)
    }

    /// The antipodal quaternion −q (the same rotation).
    package var antipode: Rotation { Rotation(unit: -q, improper: improper) }

    /// `Quaternion.angle`: ω = 2 arccos|a|, in [0, π].
    package var angle: Double {
        let w = 2 * acos(abs(q[0]))
        return w.isNaN ? 0 : w
    }

    /// `Quaternion.axis`: (b, c, d) normalised, flipped where a < −1e-6, the z axis times sign(a) for the identity.
    package var axis: SIMD3<Double> {
        var v = SIMD3(q[1], q[2], q[3])
        if q[0] < -1e-6 { v = -v }
        if RotationConversions.norm(v) == 0 {
            let s: Double = q[0] > 0 ? 1 : (q[0] < 0 ? -1 : 0)
            v = SIMD3(0, 0, s)
        }
        return v / RotationConversions.norm(v)
    }

    /// The quaternion divided by its norm (`Object3d.unit`, a zero quaternion stays zero).
    package var unitQuaternion: SIMD4<Double> {
        let n = RotationConversions.norm(q)
        return n == 0 ? SIMD4(0, 0, 0, 0) : q / n
    }

    // MARK: - Representations

    /// `Quaternion.from_euler`: Bunge angles, lab to crystal by default (the Bunge convention), or crystal to lab (MTEX).
    package enum EulerDirection: String, Sendable {
        case labToCrystal, crystalToLab
    }

    package static func fromEuler(_ eu: SIMD3<Double>, direction: EulerDirection = .labToCrystal, degrees: Bool = false) -> Rotation {
        let e = degrees ? eu * (Double.pi / 180) : eu
        let r = Rotation(RotationConversions.eu2qu(e))
        return direction == .labToCrystal ? r : r.inverse
    }

    /// `Quaternion.to_euler`: Bunge angles of the unit quaternion, radians.
    package var euler: SIMD3<Double> { RotationConversions.qu2eu(unitQuaternion) }

    /// `Quaternion.from_matrix`.
    package static func fromMatrix(_ om: RotationMatrix) -> Rotation { Rotation(RotationConversions.om2qu(om)) }

    /// `Quaternion.to_matrix`.
    package var matrix: RotationMatrix { RotationConversions.qu2om(unitQuaternion) }

    /// `Quaternion.from_axes_angles`: the axis normalised (a zero axis stays zero), then `ax2qu`, then the unit quaternion.
    package static func fromAxisAngle(_ axis: SIMD3<Double>, _ angle: Double, degrees: Bool = false) -> Rotation {
        let n = RotationConversions.norm(axis)
        let u = n == 0 ? SIMD3<Double>(0, 0, 0) : axis / n
        let w = degrees ? angle * Double.pi / 180 : angle
        return Rotation(RotationConversions.ax2qu(SIMD4(u.x, u.y, u.z, w)))
    }

    /// `_conversions.qu2ax` of the unit quaternion: (n_x, n_y, n_z, ω).
    package var axisAngleFour: SIMD4<Double> { RotationConversions.qu2ax(unitQuaternion) }

    /// `Quaternion.to_axes_angles`: the axis-angle vector n ω.
    package var axisAngleVector: SIMD3<Double> {
        let ax = axisAngleFour
        return SIMD3(ax[0], ax[1], ax[2]) * ax[3]
    }

    /// `Quaternion.from_homochoric`: `ho2ax`, then `ax2qu` of that axis and angle as they come, then the unit quaternion.
    package static func fromHomochoric(_ ho: SIMD3<Double>) -> Rotation {
        Rotation(RotationConversions.ax2qu(RotationConversions.ho2ax(ho)))
    }

    /// `Quaternion.to_homochoric`.
    package var homochoric: SIMD3<Double> { RotationConversions.qu2ho(unitQuaternion) }

    /// `Quaternion.from_rodrigues` with three components: ω = 2 arctan|ρ| about ρ.
    package static func fromRodrigues(_ ro: SIMD3<Double>) -> Rotation {
        fromAxisAngle(ro, 2 * atan(RotationConversions.norm(ro)))
    }

    /// `Quaternion.to_rodrigues()`: the axis times tan(ω/2) (infinite at ω = π).
    package var rodrigues: SIMD3<Double> { axis * tan(angle / 2) }

    /// `Quaternion.to_rodrigues(frank=True)`: (n, tan(ω/2)), +∞ within 1e-3 of a two-fold rotation.
    package var rodriguesFrank: SIMD4<Double> { RotationConversions.ax2ro(RotationConversions.qu2ax(unitQuaternion)) }

    // MARK: - Angles and dot products

    /// `Rotation.angle_with`: 2 arccos of the |dot product| of the unit quaternions rounded to 15 decimals, as orix rounds.
    package func angle(with other: Rotation) -> Double {
        let d = Rotation.round(simdDot(unitQuaternion, other.unitQuaternion), decimals: 15)
        let w = acos(2 * d * d - 1)
        return w.isNaN ? 0 : w
    }

    /// `Rotation.dot_outer` for one pair: |q1 · q2|, zero when exactly one of the two is improper.
    package func absDot(_ other: Rotation) -> Double {
        if improper != other.improper { return 0 }
        return abs(simdDot(q, other.q))
    }

    /// `Rotation.angle_with_outer` for one pair: orix takes `.unit` of both first, which drops the improper flags, and does
    /// not round.
    package func angleOuter(with other: Rotation) -> Double {
        let d = abs(simdDot(unitQuaternion, other.unitQuaternion))
        let w = acos(2 * d * d - 1)
        return w.isNaN ? 0 : w
    }

    /// The sum a1 a2 + b1 b2 + c1 c2 + d1 d2, left to right.
    package static func dot(_ q1: SIMD4<Double>, _ q2: SIMD4<Double>) -> Double {
        q1[0] * q2[0] + q1[1] * q2[1] + q1[2] * q2[2] + q1[3] * q2[3]
    }

    private func simdDot(_ q1: SIMD4<Double>, _ q2: SIMD4<Double>) -> Double { Rotation.dot(q1, q2) }

    /// numpy's `round(x, decimals)`: x · 10^decimals rounded half to even, divided back.
    package static func round(_ x: Double, decimals: Int) -> Double {
        let f = pow(10.0, Double(decimals))
        return (x * f).rounded(.toNearestOrEven) / f
    }

    // MARK: - Sets of rotations

    /// `Rotation.outer` flattened as orix's `flatten` orders it (the first operand's index runs fastest): for each element of
    /// `rhs`, every element of `lhs` times it.
    package static func outerFlattened(_ lhs: [Rotation], _ rhs: [Rotation]) -> [Rotation] {
        var out: [Rotation] = []
        out.reserveCapacity(lhs.count * rhs.count)
        for r in rhs {
            for l in lhs { out.append(l * r) }
        }
        return out
    }

    /// `Rotation.outer` in C order (`lhs.count` x `rhs.count`, row-major).
    package static func outer(_ lhs: [Rotation], _ rhs: [Rotation]) -> [Rotation] {
        var out: [Rotation] = []
        out.reserveCapacity(lhs.count * rhs.count)
        for l in lhs {
            for r in rhs { out.append(l * r) }
        }
        return out
    }

    /// `Rotation.outer` with vectors (`rotations.count` x `vectors.count`, row-major), negated for improper rotations.
    package static func outer(_ rotations: [Rotation], _ vectors: [SIMD3<Double>]) -> [SIMD3<Double>] {
        var out: [SIMD3<Double>] = []
        out.reserveCapacity(rotations.count * vectors.count)
        for r in rotations {
            for v in vectors { out.append(r * v) }
        }
        return out
    }

    /// The key orix's `Rotation.unique` compares: (a², b², c², d², ab, ac, ad, bc, bd, cd, improper) rounded to 12 decimals
    /// (`_differentiators`, the same for q and −q).
    package var differentiators: Differentiators {
        let a = q[0], b = q[1], c = q[2], d = q[3]
        let raw = [a * a, b * b, c * c, d * d, a * b, a * c, a * d, b * c, b * d, c * d, improper ? 1 : 0]
        return Differentiators(values: raw.map { Rotation.round($0, decimals: 12) })
    }

    /// The key of `Rotation.unique(antipodal=False)`: (a, b, c, d, improper) rounded to 10 decimals.
    package var signedKey: Differentiators {
        Differentiators(values: [q[0], q[1], q[2], q[3], improper ? 1 : 0].map { Rotation.round($0, decimals: 10) })
    }

    package nonisolated struct Differentiators: Hashable, Sendable, Comparable {
        package var values: [Double]

        /// numpy's lexicographic row order (`np.unique(axis=0)`).
        package static func < (lhs: Differentiators, rhs: Differentiators) -> Bool {
            for (x, y) in zip(lhs.values, rhs.values) where x != y { return x < y }
            return lhs.values.count < rhs.values.count
        }
    }

    /// `Rotation.unique`: first appearances in the given order (orix sorts its first-appearance indices), with the index of
    /// each kept element and, per input, the position of its element in the result. `antipodal` true treats q and −q as one.
    package static func unique(_ rotations: [Rotation], antipodal: Bool = true) -> (rotations: [Rotation], index: [Int], inverse: [Int]) {
        var position: [Differentiators: Int] = [:]
        var kept: [Rotation] = [], index: [Int] = [], inverse: [Int] = []
        inverse.reserveCapacity(rotations.count)
        for (i, r) in rotations.enumerated() {
            let key = antipodal ? r.differentiators : r.signedKey
            if let p = position[key] {
                inverse.append(p)
            } else {
                position[key] = kept.count
                inverse.append(kept.count)
                kept.append(r)
                index.append(i)
            }
        }
        return (kept, index, inverse)
    }

    /// `Rotation.triple_cross`: the quaternion orthogonal to three (Rotation.triple_cross is the 4D cross product), unnormalised.
    package static func tripleCross(_ q1: SIMD4<Double>, _ q2: SIMD4<Double>, _ q3: SIMD4<Double>) -> SIMD4<Double> {
        let (a1, b1, c1, d1) = (q1[0], q1[1], q1[2], q1[3])
        let (a2, b2, c2, d2) = (q2[0], q2[1], q2[2], q2[3])
        let (a3, b3, c3, d3) = (q3[0], q3[1], q3[2], q3[3])
        let a = b1 * c2 * d3 - b1 * c3 * d2 - b2 * c1 * d3 + b2 * c3 * d1 + b3 * c1 * d2 - b3 * c2 * d1
        let b = a1 * c3 * d2 - a1 * c2 * d3 + a2 * c1 * d3 - a2 * c3 * d1 - a3 * c1 * d2 + a3 * c2 * d1
        let c = a1 * b2 * d3 - a1 * b3 * d2 - a2 * b1 * d3 + a2 * b3 * d1 + a3 * b1 * d2 - a3 * b2 * d1
        let d = a1 * b3 * c2 - a1 * b2 * c3 + a2 * b1 * c3 - a2 * b3 * c1 - a3 * b1 * c2 + a3 * b2 * c1
        return SIMD4(a, b, c, d)
    }
}

/// orix's `Vector3d` operations the symmetry code needs, on `SIMD3<Double>`.
package nonisolated enum Vector3 {
    package static let x = SIMD3<Double>(1, 0, 0)
    package static let y = SIMD3<Double>(0, 1, 0)
    package static let z = SIMD3<Double>(0, 0, 1)

    package static func dot(_ u: SIMD3<Double>, _ v: SIMD3<Double>) -> Double { u.x * v.x + u.y * v.y + u.z * v.z }

    package static func cross(_ u: SIMD3<Double>, _ v: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3(u.y * v.z - u.z * v.y, u.z * v.x - u.x * v.z, u.x * v.y - u.y * v.x)
    }

    /// `Vector3d.unit` (a zero vector stays zero).
    package static func unit(_ v: SIMD3<Double>) -> SIMD3<Double> {
        let n = RotationConversions.norm(v)
        return n == 0 ? SIMD3(0, 0, 0) : v / n
    }

    /// `Vector3d.angle_with`: arccos of the cosine rounded to 10 decimals.
    package static func angle(_ u: SIMD3<Double>, _ v: SIMD3<Double>) -> Double {
        acos(Rotation.round(dot(u, v) / RotationConversions.norm(u) / RotationConversions.norm(v), decimals: 10))
    }

    /// `Vector3d.from_polar` (radians).
    package static func fromPolar(azimuth: Double, polar: Double) -> SIMD3<Double> {
        let s = sin(polar)
        return SIMD3(cos(azimuth) * s, sin(azimuth) * s, cos(polar))
    }

    /// `Vector3d.rotate`: about `axis` (z by default) by `angle`.
    package static func rotate(_ v: SIMD3<Double>, axis: SIMD3<Double> = z, angle: Double) -> SIMD3<Double> {
        Rotation.fromAxisAngle(axis, angle) * v
    }

    /// `Vector3d.perpendicular` for one vector: z gives x, otherwise (−y, x, 0).
    package static func perpendicular(_ v: SIMD3<Double>) -> SIMD3<Double> {
        if abs(v.x) < RotationConversions.eps12, abs(v.y) < RotationConversions.eps12 { return x }
        return SIMD3(-v.y, v.x, 0)
    }

    /// The key of `Object3d.unique`: the components rounded to 10 decimals.
    package static func key(_ v: SIMD3<Double>) -> Rotation.Differentiators {
        Rotation.Differentiators(values: [v.x, v.y, v.z].map { Rotation.round($0, decimals: 10) })
    }

    /// `Object3d.unique` on vectors: rows rounded to 10 decimals, all-zero rows (|x| ≤ 1e-8 each) dropped, first appearances
    /// kept in order. orix returns the ROUNDED rows, so this does too.
    package static func unique(_ vectors: [SIMD3<Double>]) -> [SIMD3<Double>] {
        var seen = Set<Rotation.Differentiators>()
        var out: [SIMD3<Double>] = []
        for v in vectors {
            let k = key(v)
            if k.values.allSatisfy({ abs($0) <= 1e-8 }) { continue }
            if seen.insert(k).inserted { out.append(SIMD3(k.values[0], k.values[1], k.values[2])) }
        }
        return out
    }

    /// `Vector3d.get_nearest` of one vector among `candidates`: the largest cosine with `self` among those strictly inside
    /// (−1 − eps, 1 + eps) (eps 1e-9 when inclusive, else 0), ties broken by the larger z component (`tiebreak`), then the
    /// last such candidate (numpy's `lexsort` keeps equal keys in order and orix takes the last).
    package static func nearest(to v: SIMD3<Double>, among candidates: [SIMD3<Double>], inclusive: Bool, tiebreak: SIMD3<Double> = z) -> SIMD3<Double>? {
        let eps = inclusive ? 1e-9 : 0
        var best: (vertical: Double, cosine: Double, vector: SIMD3<Double>)?
        for c in candidates {
            let cosine = dot(c, v)
            guard -1 - eps < cosine, cosine < 1 + eps else { continue }
            let vertical = dot(c, tiebreak)
            if let b = best {
                if vertical > b.vertical || (vertical == b.vertical && cosine >= b.cosine) { best = (vertical, cosine, c) }
            } else {
                best = (vertical, cosine, c)
            }
        }
        return best?.vector
    }
}
