//
//  Orientation.swift
//  orix 0.15.0's `OrientationRegion` (orix.quaternion.orientation_region), `Misorientation` (orix.quaternion.misorientation)
//  and `Orientation` (orix.quaternion.orientation): the fundamental zone of one or two point groups as the normals of its
//  bounding planes in quaternion space, the reduction of orientations and misorientations into it (`reduce`, which replaced
//  `map_into_symmetry_reduced_zone` in orix 0.14), orientation subtraction (the disorientation), the symmetry-reduced angle
//  between orientations and the distance matrices of orix's numba kernels. GPL-3.0 (orix is GPL-3.0-or-later), see NOTICE.
//
//  As orix: `reduce` takes `end * M * start` for the pairs of `start` x `end` in order and stops at the first that lies in
//  `OrientationRegion.fromSymmetry(start, end)`; for two different groups that is not always the smallest angle (the
//  DiffractoKit pins document it), and the port keeps orix's loop because parity is the claim. Parity: `tools/parity/sem`
//  bundles `m3/orientation-regions` (normals within 1e-10) and `m3/ti-disorientations` (atol 1e-7), docs/parity.md.
//

import Foundation

/// orix's `OrientationRegion`: the region of rotations closer to the identity than to any symmetrically equivalent
/// rotation, bounded by planes through the origin of quaternion space with these unit normals.
package nonisolated struct OrientationRegion: Sendable {
    package let normals: [SIMD4<Double>]

    package enum Error: Swift.Error, Equatable, Sendable {
        /// orix's `NotImplementedError`: both groups are improper and neither contains the inversion.
        case bothImproperWithoutInversion
    }

    /// `__gt__`: inside when every normal's dot product with q is ≥ −1e-9, or every one is ≤ 1e-9 (q or −q inside).
    package func contains(_ q: SIMD4<Double>) -> Bool {
        var allNonNegative = true, allNonPositive = true
        for n in normals {
            let c = Rotation.dot(n, q)
            if !(c >= -RotationConversions.eps9) { allNonNegative = false }
            if !(c <= RotationConversions.eps9) { allNonPositive = false }
            if !allNonNegative, !allNonPositive { return false }
        }
        return true
    }

    /// `get_proper_groups`: the proper groups whose region the pair of (possibly improper) groups shares.
    package static func properGroups(_ gl: PointGroup, _ gr: PointGroup) throws -> (PointGroup, PointGroup) {
        switch (gl.isProper, gr.isProper) {
        case (true, true): return (gl, gr)
        case (true, false): return (gl, gr.properSubgroup)
        case (false, true): return (gl.properSubgroup, gr)
        case (false, false):
            switch (gl.containsInversion, gr.containsInversion) {
            case (true, true): return (gl.properSubgroup, gr.properSubgroup)
            case (true, false): return (gl.properSubgroup, gr.laueProperSubgroup)
            case (false, true): return (gl.laueProperSubgroup, gr.properSubgroup)
            case (false, false): throw Error.bothImproperWithoutInversion
            }
        }
    }

    /// `get_distinguished_points(s1, s2)`: the distinct rotations of s1 · s2 and their antipodes (signs kept), without the
    /// identity, in orix's flattening order.
    package static func distinguishedPoints(_ s1: PointGroup, _ s2: PointGroup) -> [Rotation] {
        var all: [Rotation] = []
        all.reserveCapacity(2 * s1.order * s2.order)
        for r in s2.elements {
            for l in s1.elements {
                let p = l * r
                all.append(p)
                all.append(p.antipode)
            }
        }
        return Rotation.unique(all, antipodal: false).rotations.filter { $0.angle > 0 }
    }

    /// `_get_large_cell_normals`: for each distinguished point, the two planes at a quarter of its angle (Rodrigues vectors
    /// n tan(ω/4) and −n / tan(ω/4)), one normal per distinct axis with the largest angle among them.
    package static func largeCellNormals(_ s1: PointGroup, _ s2: PointGroup) -> [Rotation] {
        let dp = distinguishedPoints(s1, s2)
        guard !dp.isEmpty else { return [] }
        func zeroNaN(_ v: SIMD3<Double>) -> SIMD3<Double> { SIMD3(v.x.isNaN ? 0 : v.x, v.y.isNaN ? 0 : v.y, v.z.isNaN ? 0 : v.z) }
        let planes1 = dp.map { $0.axis * tan($0.angle / 4) }
        let planes2 = dp.map { zeroNaN(-$0.axis * (1 / tan($0.angle / 4))) }
        let normals = Rotation.unique((planes1 + planes2).map { Rotation.fromRodrigues($0) }, antipodal: false).rotations
        // `normals.axis.unique(return_inverse=True)`, then one entry per distinct axis in numpy's sorted order.
        var groups: [Rotation.Differentiators: (axis: SIMD3<Double>, angle: Double)] = [:]
        for n in normals {
            let a = n.axis
            let k = Vector3.key(a)
            if let g = groups[k] { groups[k] = (g.axis, max(g.angle, n.angle)) } else { groups[k] = (a, n.angle) }
        }
        return groups.keys.sorted().map { k in Rotation.fromAxisAngle(groups[k]!.axis, groups[k]!.angle) }
    }

    /// `OrientationRegion.from_symmetry(s1, s2)`: the region of an orientation (s2 = 1) or of a misorientation between
    /// crystals of `s1` and `s2`.
    package static func fromSymmetry(_ s1: PointGroup, _ s2: PointGroup = PointGroup.c1) throws -> OrientationRegion {
        let (p1, p2) = try properGroups(s1, s2)
        let large = largeCellNormals(p1, p2)
        let fz = (p1 & p2).fundamentalZoneNormals()
        let fzNormals = fz.map { Rotation.fromAxisAngle($0, Double.pi) }
        let normals = (large + fzNormals).map { RotationConversions.norm($0.q) == 0 ? $0.q : $0.q / RotationConversions.norm($0.q) }
        let vertices = OrientationRegion.vertices(of: normals)
        guard !vertices.isEmpty else { return OrientationRegion(normals: normals) }
        let kept = normals.filter { n in vertices.contains { abs(Rotation.dot($0, n)) <= 1e-8 } }
        return OrientationRegion(normals: kept)
    }

    /// `vertices`: the 4D cross products of every three normals that lie in the region and on one of its planes.
    package static func vertices(of normals: [SIMD4<Double>]) -> [SIMD4<Double>] {
        let n = normals.count
        guard n >= 3 else { return [] }
        let region = OrientationRegion(normals: normals)
        var out: [SIMD4<Double>] = []
        for i in 0..<(n - 2) {
            for j in (i + 1)..<(n - 1) {
                for k in (j + 1)..<n {
                    let raw = Rotation.tripleCross(normals[i], normals[j], normals[k])
                    let r = raw / RotationConversions.norm(raw)
                    guard !(r[0].isNaN || r[1].isNaN || r[2].isNaN || r[3].isNaN) else { continue }
                    guard region.contains(r) else { continue }
                    if normals.contains(where: { abs(Rotation.dot(r, $0)) <= 1e-8 }) { out.append(r) }
                }
            }
        }
        return out
    }
}

/// orix's `Misorientation`: rotations from crystals of `start` symmetry to crystals of `end` symmetry (orix's
/// `symmetry = (start, end)`; an orientation is the misorientation from the sample, symmetry 1, to the crystal).
package nonisolated struct Misorientations: Sendable {
    /// Unit quaternions.
    package var quaternions: [SIMD4<Double>]
    package var start: PointGroup
    package var end: PointGroup

    package init(quaternions: [SIMD4<Double>], start: PointGroup, end: PointGroup) {
        self.quaternions = quaternions.map { Rotation($0).q }
        self.start = start
        self.end = end
    }

    /// `Quaternion.angle` of each.
    package var angles: [Double] { quaternions.map { Rotation(unit: $0).angle } }

    /// `reduce`: each misorientation as the first `end · M · start` (pairs in `start` x `end` order) inside the fundamental
    /// zone of (start, end).
    package func reduced() throws -> Misorientations {
        Misorientations(reducedQuaternions: try Misorientations.reduce(quaternions, start: start, end: end), start: start, end: end)
    }

    private init(reducedQuaternions: [SIMD4<Double>], start: PointGroup, end: PointGroup) {
        self.quaternions = reducedQuaternions
        self.start = start
        self.end = end
    }

    package static func reduce(_ quaternions: [SIMD4<Double>], start: PointGroup, end: PointGroup) throws -> [SIMD4<Double>] {
        let fz = try OrientationRegion.fromSymmetry(start, end)
        var reduced = Array(repeating: SIMD4<Double>(1, 0, 0, 0), count: quaternions.count)
        var outside = Array(repeating: true, count: quaternions.count)
        var remaining = quaternions.count
        pairs: for s in start.elements {
            for e in end.elements {
                guard remaining > 0 else { break pairs }
                for i in quaternions.indices where outside[i] {
                    let m = Rotation(unit: quaternions[i])
                    let q = ((e * m) * s).q
                    reduced[i] = q
                    if fz.contains(q) {
                        outside[i] = false
                        remaining -= 1
                    }
                }
            }
        }
        return reduced
    }

    /// `get_distance_matrix(lazy=False)` (orix's `_mori_distance_matrix`): the angle between every pair under the symmetry
    /// of both crystals, max over l, r of |⟨M_i s_l M_j⁻¹, s_r⟩|, rounded to 12 decimals; row-major n x n, radians.
    package func distanceMatrix() -> [Double] {
        let sym = PointGroup.uniqueElements(start, end).map(\.q)
        let qu = quaternions.map { Rotation(unit: $0).unitQuaternion }
        let n = qu.count
        var out = Array(repeating: 0.0, count: n * n)
        for i in 0..<n {
            let (ai, bi, ci, di) = (qu[i][0], qu[i][1], qu[i][2], qu[i][3])
            for j in 0..<n {
                let (jw, jx, jy, jz) = (qu[j][0], -qu[j][1], -qu[j][2], -qu[j][3])
                var maxDP = 0.0
                for sl in sym {
                    let t0 = ai * sl[0] - bi * sl[1] - ci * sl[2] - di * sl[3]
                    let t1 = ai * sl[1] + bi * sl[0] + ci * sl[3] - di * sl[2]
                    let t2 = ai * sl[2] - bi * sl[3] + ci * sl[0] + di * sl[1]
                    let t3 = ai * sl[3] + bi * sl[2] - ci * sl[1] + di * sl[0]
                    let u0 = t0 * jw - t1 * jx - t2 * jy - t3 * jz
                    let u1 = t0 * jx + t1 * jw + t2 * jz - t3 * jy
                    let u2 = t0 * jy - t1 * jz + t2 * jw + t3 * jx
                    let u3 = t0 * jz + t1 * jy - t2 * jx + t3 * jw
                    for sr in sym {
                        let dp = abs(u0 * sr[0] + u1 * sr[1] + u2 * sr[2] + u3 * sr[3])
                        if dp > maxDP { maxDP = dp }
                    }
                }
                maxDP = min(maxDP, 1)
                maxDP = min(Rotation.round(maxDP, decimals: 12), 1)
                out[i * n + j] = acos(2 * maxDP * maxDP - 1)
            }
        }
        return out
    }
}

/// orix's `Orientation`: rotations from the sample to crystals of `symmetry`.
package nonisolated struct Orientations: Sendable {
    /// Unit quaternions (lab to crystal).
    package var quaternions: [SIMD4<Double>]
    package var symmetry: PointGroup

    package init(quaternions: [SIMD4<Double>], symmetry: PointGroup) {
        self.quaternions = quaternions.map { Rotation($0).q }
        self.symmetry = symmetry
    }

    /// `Orientation.from_euler`: Bunge angles, lab to crystal by default.
    package static func fromEuler(_ euler: [SIMD3<Double>], symmetry: PointGroup, direction: Rotation.EulerDirection = .labToCrystal,
                                  degrees: Bool = false) -> Orientations {
        Orientations(quaternions: euler.map { Rotation.fromEuler($0, direction: direction, degrees: degrees).q }, symmetry: symmetry)
    }

    package var count: Int { quaternions.count }

    /// `reduce`: each orientation as its first symmetrically equivalent `s · O` inside the fundamental zone.
    package func reduced() -> Orientations {
        // (1, symmetry) never takes the both-improper branch of `get_proper_groups`, so this cannot throw.
        let q = (try? Misorientations.reduce(quaternions, start: PointGroup.c1, end: symmetry)) ?? quaternions
        return Orientations(quaternions: q, symmetry: symmetry)
    }

    /// `self - other` (orix's `Orientation.__sub__`): the misorientations self_i · other_i⁻¹ between equal-length sets,
    /// symmetry (self, other), reduced into their fundamental zone; their `angles` are the disorientation angles.
    package func misorientations(from other: Orientations) throws -> Misorientations {
        precondition(count == other.count, "misorientations(from:) takes two sets of the same length")
        let m = zip(quaternions, other.quaternions).map { (Rotation(unit: $0.0) * Rotation(unit: $0.1).inverse).q }
        return try Misorientations(quaternions: m, start: symmetry, end: other.symmetry).reduced()
    }

    /// `angle_with`: per pair, the smallest angle between self_i and other_i over the proper symmetry elements of both.
    package func angles(with other: Orientations) -> [Double] {
        precondition(count == other.count, "angles(with:) takes two sets of the same length")
        let sym = PointGroup.uniqueElements(symmetry, other.symmetry)
        return zip(quaternions, other.quaternions).map { s, o in
            let m = Rotation(unit: Rotation(unit: o).unitQuaternion) * Rotation(unit: Rotation(unit: s).unitQuaternion).inverse
            var best = -Double.infinity
            for e in sym { best = max(best, m.absDot(e)) }
            let w = acos(2 * best * best - 1)
            return w.isNaN ? 0 : w
        }
    }

    /// `angle_with_outer(lazy=False)` (orix's `_ori_angle_with_outer_sym`): every pair, max over the proper symmetry elements of
    /// |⟨other_j · self_i⁻¹, s⟩| rounded to 12 decimals; row-major `count` x `other.count`, radians.
    package func anglesOuter(with other: Orientations) -> [Double] {
        let sym = PointGroup.uniqueElements(symmetry, other.symmetry).filter { !$0.improper }.map(\.q)
        let q1 = quaternions.map { Rotation(unit: $0).unitQuaternion }
        let q2 = other.quaternions.map { Rotation(unit: $0).unitQuaternion }
        var out = Array(repeating: 0.0, count: q1.count * q2.count)
        for i in q1.indices {
            let (ai, bi, ci, di) = (q1[i][0], q1[i][1], q1[i][2], q1[i][3])
            for j in q2.indices {
                let (aj, bj, cj, dj) = (q2[j][0], q2[j][1], q2[j][2], q2[j][3])
                let mw = aj * ai + bj * bi + cj * ci + dj * di
                let mx = bj * ai - aj * bi + dj * ci - cj * di
                let my = cj * ai - dj * bi - aj * ci + bj * di
                let mz = dj * ai + cj * bi - bj * ci - aj * di
                var maxDP = 0.0
                for s in sym {
                    let dp = abs(mw * s[0] + mx * s[1] + my * s[2] + mz * s[3])
                    if dp > maxDP { maxDP = dp }
                }
                maxDP = min(Rotation.round(maxDP, decimals: 12), 1)
                out[i * q2.count + j] = acos(2 * maxDP * maxDP - 1)
            }
        }
        return out
    }

    /// `get_distance_matrix()`: `anglesOuter(with: self)`.
    package func distanceMatrix() -> [Double] { anglesOuter(with: self) }
}
