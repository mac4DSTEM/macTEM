//
//  GrainMap.swift
//  The arrays DefDAP 1.3.1's EBSD `Map` keeps for its grain functions: one quaternion per point
//  from the Bunge angles by DefDAP's `Quat.create_many_quats` (lab to crystal, moved to the northern hemisphere), DefDAP's
//  phase numbers (0 not indexed, 1, 2, ... in phase order), the scan step, and per phase the symmetry operators DefDAP's
//  `crystal.crystalStructures` lists (24 cubic, 12 hexagonal, in DefDAP's order, which decides `argmax` ties and so the
//  grain average orientation). Ported from DefDAP 1.3.1 (`defdap.quat`, `defdap.crystal`), Apache-2.0, see NOTICE.
//
//  The quaternion arithmetic and the symmetry tables are `DefDAPQuat` and `DefDAPCrystalStructure` (SEM/Deformation),
//  which the slip analysis shares. DefDAP knows two crystal structures, by the Laue group of a phase (TSL codes 9 =
//  6/mmm, 11 = m-3m). Any other point group takes the rotations of its Laue group's proper subgroup (orix's elements,
//  moved to the northern hemisphere, the identity first), which is the set DefDAP's tables hold for the two it knows;
//  no DefDAP reference exists for those.
//
//  Parity: `tools/parity/sem` bundles `m5/grains-ti`, `m5/grains-sdss` (quaternions atol 1e-10), docs/parity.md.
//

import Foundation

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
        try self.init(rows: rows, columns: columns, quaternions: euler.map(DefDAPQuat.fromEuler), phase: phase,
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
                      symmetries: indexed.map { DefDAPCrystalStructure.operators(for: $0.phase.pointGroup) },
                      phaseNames: indexed.map { $0.phase.name }, step: map.dx != 0 ? map.dx : 1)
    }
}
