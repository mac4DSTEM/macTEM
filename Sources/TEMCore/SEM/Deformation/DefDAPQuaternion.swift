//
//  DefDAPQuaternion.swift
//  DefDAP 1.3.1's quaternion conventions (defdap.quat.Quat) and crystal symmetries (defdap.crystal.crystalStructures), the
//  arithmetic its slip-trace, Schmid-factor, grain-average and Nye-tensor code runs on. Apache-2.0 (DefDAP, Copyright 2025
//  Mechanics of Microstructures Group at The University of Manchester), see NOTICE.
//
//  DefDAP's quaternions are passive (sample to crystal), scalar first, and moved to the northern hemisphere (a ≥ 0) whenever a
//  `Quat` is constructed without `allow_southern`. They are orix's convention (D-SEM-35) for the same Bunge angles, but
//  DefDAP's averaging and symmetry loops depend on its own element order and on where it flips signs, so this file carries
//  DefDAP's formulas and lists as written rather than orix's `Rotation` and `PointGroup`. Parity: `tools/parity/sem` bundles
//  `m5/slip-ti` and `m5/slip-sdss` (quaternions within 1e-12, grain averages within 1e-10; docs/parity.md).
//

import Foundation

/// DefDAP's `Quat` arithmetic on (a, b, c, d) quaternions, scalar first.
package nonisolated enum DefDAPQuat {
    /// `Quat.__init__` without `allow_southern`: −q when a < 0.
    package static func northern(_ q: SIMD4<Double>) -> SIMD4<Double> { q[0] < 0 ? -q : q }

    /// `Quat.from_euler_angles` (and `create_many_quats`): Bunge angles in radians, northern hemisphere.
    package static func fromEuler(_ eu: SIMD3<Double>) -> SIMD4<Double> {
        let ph1 = eu[0], phi = eu[1], ph2 = eu[2]
        return northern(SIMD4(cos(phi / 2.0) * cos((ph1 + ph2) / 2.0),
                               -sin(phi / 2.0) * cos((ph1 - ph2) / 2.0),
                               -sin(phi / 2.0) * sin((ph1 - ph2) / 2.0),
                               -cos(phi / 2.0) * sin((ph1 + ph2) / 2.0)))
    }

    /// `Quat.__mul__`: the Hamilton product l r, as DefDAP writes it (scalar l₀r₀ − l·r, vector l₀r + r₀l + l × r), without the
    /// hemisphere flip (callers flip where DefDAP's constructor does).
    package static func product(_ l: SIMD4<Double>, _ r: SIMD4<Double>) -> SIMD4<Double> {
        let w = l[0] * r[0] - (l[1] * r[1] + l[2] * r[2] + l[3] * r[3])
        let x = l[0] * r[1] + r[0] * l[1] + (l[2] * r[3] - l[3] * r[2])
        let y = l[0] * r[2] + r[0] * l[2] + (l[3] * r[1] - l[1] * r[3])
        let z = l[0] * r[3] + r[0] * l[3] + (l[1] * r[2] - l[2] * r[1])
        return SIMD4(w, x, y, z)
    }

    /// `Quat.conjugate` (a, −b, −c, −d), then the constructor's flip.
    package static func conjugate(_ q: SIMD4<Double>) -> SIMD4<Double> { northern(SIMD4(q[0], -q[1], -q[2], -q[3])) }

    /// `Quat.transform_vector`: q (v q̄) with v as a pure quaternion. For a passive (sample to crystal) quaternion this gives
    /// the sample vector's crystal coordinates; the conjugate goes back.
    package static func transform(_ q: SIMD4<Double>, _ v: SIMD3<Double>) -> SIMD3<Double> {
        let inner = product(SIMD4(0, v.x, v.y, v.z), conjugate(q))
        let out = product(q, inner)
        return SIMD3(out[1], out[2], out[3])
    }

    /// `Quat.rot_matrix`, row-major.
    package static func rotationMatrix(_ q: SIMD4<Double>) -> [Double] {
        let qbar = q[0] * q[0] - q[1] * q[1] - q[2] * q[2] - q[3] * q[3]
        return [qbar + 2 * q[1] * q[1], 2 * (q[1] * q[2] - q[0] * q[3]), 2 * (q[1] * q[3] + q[0] * q[2]),
                2 * (q[1] * q[2] + q[0] * q[3]), qbar + 2 * q[2] * q[2], 2 * (q[2] * q[3] - q[0] * q[1]),
                2 * (q[1] * q[3] - q[0] * q[2]), 2 * (q[2] * q[3] + q[0] * q[1]), qbar + 2 * q[3] * q[3]]
    }

    /// `quat_comps[i] = sym * quat` as `Quat.calc_sym_eqvs` and `Map.calc_nye` expand it, then the positive-hemisphere swap.
    package static func symmetricEquivalent(_ q: SIMD4<Double>, _ s: SIMD4<Double>) -> SIMD4<Double> {
        let a = q[0] * s[0] - q[1] * s[1] - q[2] * s[2] - q[3] * s[3]
        let b = q[0] * s[1] + q[1] * s[0] - q[2] * s[3] + q[3] * s[2]
        let c = q[0] * s[2] + q[2] * s[0] - q[3] * s[1] + q[1] * s[3]
        let d = q[0] * s[3] + q[3] * s[0] - q[1] * s[2] + q[2] * s[1]
        let e = SIMD4(a, b, c, d)
        return a < 0 ? -e : e
    }

    /// `Quat.calc_sym_eqvs`: for every symmetry (identity first, the quaternion as given), the equivalents of every quaternion.
    package static func symmetricEquivalents(_ quats: [SIMD4<Double>], structure: DefDAPCrystalStructure) -> [[SIMD4<Double>]] {
        let syms = structure.symmetries
        var out: [[SIMD4<Double>]] = [quats]
        for s in syms.dropFirst() { out.append(quats.map { symmetricEquivalent($0, s) }) }
        return out
    }

    /// `Quat.calc_average_ori` of `calc_sym_eqvs`: a running sum that adds, for each quaternion after the first, the symmetric
    /// equivalent closest to the current sum (largest |dot|, the first on a tie), then northern hemisphere and unit norm.
    /// Order-dependent as DefDAP's is: a grain's points go in in DefDAP's order.
    package static func averageOrientation(_ quats: [SIMD4<Double>], structure: DefDAPCrystalStructure) -> SIMD4<Double> {
        guard let first = quats.first else { return SIMD4(1, 0, 0, 0) }
        let eqv = symmetricEquivalents(quats, structure: structure)
        var av = first
        for i in 1..<quats.count {
            var best = 0
            var bestValue = -Double.infinity
            for k in eqv.indices {
                let e = eqv[k][i]
                let v = abs(e[0] * av[0] + e[1] * av[1] + e[2] * av[2] + e[3] * av[3])
                if v > bestValue { bestValue = v; best = k }
            }
            av += eqv[best][i]
        }
        let n = northern(av)
        return n / (n * n).sum().squareRoot()
    }
}

/// `defdap.crystal.crystalStructures`: the cubic (24) and hexagonal (12) rotations DefDAP's symmetry loops run over, in its order.
package nonisolated enum DefDAPCrystalStructure: String, Sendable, CaseIterable {
    case cubic, hexagonal

    package var symmetries: [SIMD4<Double>] {
        switch self {
        case .cubic: return Self.cubicSymmetries
        case .hexagonal: return Self.hexagonalSymmetries
        }
    }

    private static let overRoot2 = 2.0.squareRoot() / 2
    private static let sqrt3Over2 = 3.0.squareRoot() / 2

    private static let cubicSymmetries: [SIMD4<Double>] = {
        let h = DefDAPCrystalStructure.overRoot2
        let raw: [SIMD4<Double>] = [
            SIMD4(1, 0, 0, 0),
            // tetrads <100>
            SIMD4(h, h, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(h, -h, 0, 0),
            SIMD4(h, 0, h, 0), SIMD4(0, 0, 1, 0), SIMD4(h, 0, -h, 0),
            SIMD4(h, 0, 0, h), SIMD4(0, 0, 0, 1), SIMD4(h, 0, 0, -h),
            // dyads <110>
            SIMD4(0, h, h, 0), SIMD4(0, -h, h, 0), SIMD4(0, h, 0, h),
            SIMD4(0, -h, 0, h), SIMD4(0, 0, h, h), SIMD4(0, 0, -h, h),
            // triads <111>
            SIMD4(0.5, 0.5, 0.5, 0.5), SIMD4(0.5, -0.5, -0.5, -0.5), SIMD4(0.5, -0.5, 0.5, 0.5), SIMD4(0.5, 0.5, -0.5, -0.5),
            SIMD4(0.5, 0.5, -0.5, 0.5), SIMD4(0.5, -0.5, 0.5, -0.5), SIMD4(0.5, 0.5, 0.5, -0.5), SIMD4(0.5, -0.5, -0.5, 0.5),
        ]
        return raw.map(DefDAPQuat.northern)
    }()

    private static let hexagonalSymmetries: [SIMD4<Double>] = {
        let s = DefDAPCrystalStructure.sqrt3Over2
        let raw: [SIMD4<Double>] = [
            SIMD4(1, 0, 0, 0),
            SIMD4(0, 1, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(0, 0, 0, 1),
            // hexads
            SIMD4(s, 0, 0, 0.5), SIMD4(0.5, 0, 0, s), SIMD4(0.5, 0, 0, -s), SIMD4(s, 0, 0, -0.5),
            // diads
            SIMD4(0, -0.5, -s, 0), SIMD4(0, 0.5, -s, 0), SIMD4(0, s, -0.5, 0), SIMD4(0, -s, -0.5, 0),
        ]
        return raw.map(DefDAPQuat.northern)
    }()
}
