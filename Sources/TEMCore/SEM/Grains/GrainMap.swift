//
//  GrainMap.swift
//  The arrays DefDAP 1.3.1's EBSD `Map` keeps for its grain functions, and its crystal symmetry: one quaternion per point
//  from the Bunge angles by DefDAP's `Quat.create_many_quats` (lab to crystal, moved to the northern hemisphere), DefDAP's
//  phase numbers (0 not indexed, 1, 2, ... in phase order), the scan step, and per phase the symmetry operators DefDAP's
//  `crystal.crystalStructures` lists (24 cubic, 12 hexagonal, in DefDAP's order, which decides `argmax` ties and so the
//  grain average orientation). Ported from DefDAP 1.3.1 (`defdap.quat`, `defdap.crystal`), Apache-2.0, see NOTICE.
//
//  DefDAP knows two crystal structures, by the Laue group of a phase (TSL codes 9 = 6/mmm, 11 = m-3m). Any other point
//  group takes the rotations of its Laue group's proper subgroup (orix's elements, moved to the northern hemisphere, the
//  identity first), which is the set DefDAP's tables hold for the two it knows; no DefDAP reference exists for those.
//
//  Parity: `tools/parity/sem` bundles `m5/grains-ti`, `m5/grains-sdss` (quaternions atol 1e-10), docs/parity.md.
//

import Foundation

package nonisolated enum DefDAPSymmetry {
    private static let r2 = 2.0.squareRoot() / 2
    private static let r3 = 3.0.squareRoot() / 2

    /// DefDAP's `crystalStructures["cubic"].symmetries`: identity, the 100 tetrads, the 110 dyads, the 111 triads.
    package static let cubic: [SIMD4<Double>] = [
        SIMD4(1, 0, 0, 0),
        SIMD4(r2, r2, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(r2, -r2, 0, 0),
        SIMD4(r2, 0, r2, 0), SIMD4(0, 0, 1, 0), SIMD4(r2, 0, -r2, 0),
        SIMD4(r2, 0, 0, r2), SIMD4(0, 0, 0, 1), SIMD4(r2, 0, 0, -r2),
        SIMD4(0, r2, r2, 0), SIMD4(0, -r2, r2, 0), SIMD4(0, r2, 0, r2),
        SIMD4(0, -r2, 0, r2), SIMD4(0, 0, r2, r2), SIMD4(0, 0, -r2, r2),
        SIMD4(0.5, 0.5, 0.5, 0.5), SIMD4(0.5, -0.5, -0.5, -0.5), SIMD4(0.5, -0.5, 0.5, 0.5), SIMD4(0.5, 0.5, -0.5, -0.5),
        SIMD4(0.5, 0.5, -0.5, 0.5), SIMD4(0.5, -0.5, 0.5, -0.5), SIMD4(0.5, 0.5, 0.5, -0.5), SIMD4(0.5, -0.5, -0.5, 0.5),
    ]

    /// DefDAP's `crystalStructures["hexagonal"].symmetries`: identity, three dyads on the axes, the hexads, the other dyads.
    package static let hexagonal: [SIMD4<Double>] = [
        SIMD4(1, 0, 0, 0),
        SIMD4(0, 1, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(0, 0, 0, 1),
        SIMD4(r3, 0, 0, 0.5), SIMD4(0.5, 0, 0, r3), SIMD4(0.5, 0, 0, -r3), SIMD4(r3, 0, 0, -0.5),
        SIMD4(0, -0.5, -r3, 0), SIMD4(0, 0.5, -r3, 0), SIMD4(0, r3, -0.5, 0), SIMD4(0, -r3, -0.5, 0),
    ]

    /// The operators of a phase's point group: DefDAP's tables for m-3m and 6/mmm Laue groups, the Laue group's proper
    /// rotations otherwise, the identity alone without a point group.
    package static func operators(for group: PointGroup?) -> [SIMD4<Double>] {
        guard let group else { return [SIMD4(1, 0, 0, 0)] }
        switch PointGroup.laueName(group.name) {
        case "m-3m": return cubic
        case "6/mmm": return hexagonal
        default:
            var ops = group.laue.properSubgroup.elements.map { $0.q[0] < 0 ? -$0.q : $0.q }
            if let i = ops.firstIndex(where: { $0 == SIMD4(1, 0, 0, 0) }), i != 0 { ops.swapAt(0, i) }
            return ops
        }
    }

    /// DefDAP's `Quat.from_euler_angles` / `create_many_quats`: Bunge angles in radians, northern hemisphere.
    package static func quaternion(euler e: SIMD3<Double>) -> SIMD4<Double> {
        let (ph1, phi, ph2) = (e.x, e.y, e.z)
        var q = SIMD4(cos(phi / 2.0) * cos((ph1 + ph2) / 2.0),
                      -sin(phi / 2.0) * cos((ph1 - ph2) / 2.0),
                      -sin(phi / 2.0) * sin((ph1 - ph2) / 2.0),
                      -cos(phi / 2.0) * sin((ph1 + ph2) / 2.0))
        if q[0] < 0 { q = -q }
        return q
    }

    /// One symmetric equivalent as DefDAP's `calc_sym_eqvs` writes it (sym * q), moved to the northern hemisphere.
    @inline(__always)
    package static func equivalent(_ q: SIMD4<Double>, _ s: SIMD4<Double>) -> SIMD4<Double> {
        var e = SIMD4(q[0] * s[0] - q[1] * s[1] - q[2] * s[2] - q[3] * s[3],
                      q[0] * s[1] + q[1] * s[0] - q[2] * s[3] + q[3] * s[2],
                      q[0] * s[2] + q[2] * s[0] - q[3] * s[1] + q[1] * s[3],
                      q[0] * s[3] + q[3] * s[0] - q[1] * s[2] + q[2] * s[1])
        if e[0] < 0 { e = -e }
        return e
    }

    /// DefDAP's `calc_sym_eqvs` for one quaternion: the quaternion itself first, then sym * q for every other operator.
    package static func equivalents(_ q: SIMD4<Double>, _ ops: [SIMD4<Double>]) -> [SIMD4<Double>] {
        var out = [q]
        out.reserveCapacity(ops.count)
        for s in ops.dropFirst() { out.append(equivalent(q, s)) }
        return out
    }

    /// The |dot product| of two quaternions, summed in component order.
    @inline(__always)
    package static func absDot(_ a: SIMD4<Double>, _ b: SIMD4<Double>) -> Double {
        abs(a[0] * b[0] + a[1] * b[1] + a[2] * b[2] + a[3] * b[3])
    }
}

/// An EBSD map as DefDAP's grain functions read it: rows × columns points, row-major.
package nonisolated struct GrainMap: Sendable, Equatable {
    package enum Refusal: Error, Equatable, Sendable, LocalizedError {
        /// The arrays do not hold rows × columns points.
        case shape(rows: Int, columns: Int, points: Int)
        /// A phase number outside 0 ... the number of phases.
        case phase(Int)
        /// A neighbour kernel needs at least two rows and two columns.
        case tooSmall

        package var errorDescription: String? {
            switch self {
            case .shape(let r, let c, let n): "The map holds \(n) points, not \(r) × \(c)."
            case .phase(let p): "The phase number \(p) names no phase of the map."
            case .tooSmall: "The map needs at least two rows and two columns."
            }
        }
    }

    package let rows: Int
    package let columns: Int
    /// DefDAP's quaternion per point (lab to crystal, northern hemisphere).
    package let quaternions: [SIMD4<Double>]
    /// DefDAP's phase number per point: 0 not indexed, 1 the first phase, ...
    package let phase: [Int]
    /// The symmetry operators of each phase, phase 1 first.
    package let symmetries: [[SIMD4<Double>]]
    package let phaseNames: [String]
    /// The scan step (both directions, DefDAP's `step_size`), in the scan unit.
    package let step: Double

    package var count: Int { rows * columns }

    package init(rows: Int, columns: Int, quaternions: [SIMD4<Double>], phase: [Int], symmetries: [[SIMD4<Double>]],
                 phaseNames: [String]? = nil, step: Double) throws {
        guard rows >= 1, columns >= 1, quaternions.count == rows * columns, phase.count == rows * columns else {
            throw Refusal.shape(rows: rows, columns: columns, points: quaternions.count)
        }
        if let bad = phase.first(where: { $0 < 0 || $0 > symmetries.count }) { throw Refusal.phase(bad) }
        self.rows = rows
        self.columns = columns
        self.quaternions = quaternions
        self.phase = phase
        self.symmetries = symmetries
        self.phaseNames = phaseNames ?? symmetries.indices.map { "phase \($0 + 1)" }
        self.step = step
    }

    /// From Bunge angles in radians, through DefDAP's quaternion formula.
    package init(rows: Int, columns: Int, euler: [SIMD3<Double>], phase: [Int], symmetries: [[SIMD4<Double>]],
                 phaseNames: [String]? = nil, step: Double) throws {
        try self.init(rows: rows, columns: columns, quaternions: euler.map(DefDAPSymmetry.quaternion(euler:)), phase: phase,
                      symmetries: symmetries, phaseNames: phaseNames, step: step)
    }

    /// A crystal map's points in data, which must fill their rectangle: the indexed phases in id order become DefDAP's
    /// phase numbers 1, 2, ..., `not_indexed` (−1) becomes 0; the Euler angles go through DefDAP's formula; the step is x's.
    package init(map: CrystalMap) throws {
        let shape = map.shape
        let (r, c) = shape.count == 2 ? (shape[0], shape[1]) : (1, shape.first ?? map.size)
        guard r * c == map.size else { throw CrystalMap.Refusal.notARectangle(shape: shape, points: map.size) }
        let indexed = map.phases.entries.filter { $0.id != PhaseList.notIndexedID }
        var number: [Int: Int] = [:]
        for (k, entry) in indexed.enumerated() { number[entry.id] = k + 1 }
        let phase = map.phaseIDs.map { number[$0] ?? 0 }
        try self.init(rows: r, columns: c, euler: map.eulerInData, phase: phase,
                      symmetries: indexed.map { DefDAPSymmetry.operators(for: $0.phase.pointGroup) },
                      phaseNames: indexed.map { $0.phase.name }, step: map.dx != 0 ? map.dx : 1)
    }
}
