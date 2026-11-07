//
//  NyeTensor.swift
//  The Nye tensor and geometrically necessary dislocation (GND) density of an orientation map, DefDAP 1.3.1's
//  `defdap.ebsd.Map.calc_nye` ported line by line. Apache-2.0 (DefDAP, Copyright 2025 Mechanics of Microstructures Group at The
//  University of Manchester), see NOTICE. Method: the Nye tensor from lattice curvature, Pantleon (2008), Scripta Mater. 58,
//  994; the L1 norm of its nine components as the GND content, Ruggles and Fullwood (2013), Ultramicroscopy 133, 8, and
//  Wilkinson and Randman (2010), Phil. Mag. 90, 1159.
//
//  Per point: the misorientation to the next point along x and along y, taking the symmetric equivalent of the neighbour
//  closest to the point (DefDAP's symmetries, largest |q₀·qₖ| clamped to 1, the first on a tie); the elastic distortion
//  derivative β = (R(q̄ₖ q₀) − I) / step, with the step in metres; the Nye tensor α from the two derivatives with DefDAP's
//  Burgers vector of 1.4 Å; the GND content 30/20 Σ|αᵢⱼ| in m⁻². Points on the last row or the last column get zero
//  derivatives, as in DefDAP's loop.
//
//  DefDAP 1.3.1 writes `betadery = betaderx`, so both derivative arrays are one object and the y derivative overwrites the x
//  derivative before α is formed (the line is unchanged on DefDAP's master and develop branches). `.separate`, the default,
//  keeps the two derivatives apart as Pantleon's construction needs; `.defdap131` reproduces DefDAP's numbers. Both are held
//  to references: `m5/slip-*` `gnd` and `nye_window` (DefDAP's own source with that one line corrected) and
//  `gnd_defdap_1_3_1`, `nye_defdap_1_3_1_window`, rtol 1e-5 (decision in docs/decisions.md, rows in docs/parity.md).
//

import Foundation

package nonisolated enum NyeTensor {
    /// How the x and y lattice-curvature derivatives enter the Nye tensor.
    package enum Derivatives: String, Sendable, CaseIterable {
        /// Each from its own neighbour (Pantleon 2008).
        case separate
        /// Both from the y neighbour, as DefDAP 1.3.1 computes them.
        case defdap131
    }

    /// DefDAP's Burgers vector for the GND conversion, metres.
    package static let defaultBurgersVector = 1.4e-10

    package struct Result: Sendable, Equatable {
        package let rows: Int
        package let columns: Int
        /// GND content per point, m⁻², row-major.
        package let gnd: [Double]
        /// α[i][j] per point, m⁻¹ / b, laid out [i][j][row][column] (DefDAP's `Nye_tensor`, shape 3 x 3 x rows x columns).
        package let alpha: [Double]

        package func alpha(_ i: Int, _ j: Int, row: Int, column: Int) -> Double {
            alpha[(i * 3 + j) * rows * columns + row * columns + column]
        }
    }

    /// The Nye tensor and GND content of a map of DefDAP quaternions (`DefDAPQuat.fromEuler`, row-major) with a square step in
    /// micrometres, under one crystal structure's symmetries (DefDAP takes the primary phase's for the whole map).
    package static func compute(quaternions q: [SIMD4<Double>], rows: Int, columns: Int, stepMicrons: Double,
                                structure: DefDAPCrystalStructure, derivatives: Derivatives = .separate,
                                burgersVector: Double = defaultBurgersVector) -> Result {
        precondition(q.count == rows * columns, "NyeTensor: \(q.count) quaternions for a \(rows) x \(columns) map")
        let n = rows * columns
        let syms = structure.symmetries
        var bx = [Double](repeating: 0, count: 9 * n)
        var by = [Double](repeating: 0, count: 9 * n)

        /// The symmetric equivalent of `neighbour` closest to `q0`, as DefDAP picks it.
        func closest(_ q0: SIMD4<Double>, _ neighbour: SIMD4<Double>) -> SIMD4<Double> {
            var best = neighbour
            var bestValue = -Double.infinity
            for (k, s) in syms.enumerated() {
                let e = k == 0 ? neighbour : DefDAPQuat.symmetricEquivalent(neighbour, s)
                var v = abs(q0[0] * e[0] + q0[1] * e[1] + q0[2] * e[2] + q0[3] * e[3])
                if v > 1 { v = 1 }
                if v > bestValue { bestValue = v; best = e }
            }
            return best
        }

        /// (R(q̄ₖ q₀) − I) / step / 1e-6, row-major.
        func derivative(_ q0: SIMD4<Double>, _ qk: SIMD4<Double>) -> [Double] {
            let m = DefDAPQuat.rotationMatrix(DefDAPQuat.product(DefDAPQuat.conjugate(qk), q0))
            return (0..<9).map { k in (m[k] - ((k % 4 == 0) ? 1 : 0)) / stepMicrons / 1e-6 }
        }

        if rows > 1, columns > 1 {
            for i in 0..<(columns - 1) {
                for j in 0..<(rows - 1) {
                    let p = j * columns + i
                    let q0 = q[p]
                    let dx = derivative(q0, closest(q0, q[p + 1]))
                    let dy = derivative(q0, closest(q0, q[p + columns]))
                    for k in 0..<9 {
                        by[k * n + p] = dy[k]
                        bx[k * n + p] = derivatives == .separate ? dx[k] : dy[k]
                    }
                }
            }
        }

        var alpha = [Double](repeating: 0, count: 9 * n)
        var gnd = [Double](repeating: 0, count: n)
        let b = burgersVector
        @inline(__always) func at(_ a: [Double], _ i: Int, _ j: Int, _ p: Int) -> Double { a[(i * 3 + j) * n + p] }
        for p in 0..<n {
            var t = [Double](repeating: 0, count: 9)
            t[0 * 3 + 2] = (at(by, 0, 0, p) - at(bx, 0, 1, p)) / b
            t[1 * 3 + 2] = (at(by, 1, 0, p) - at(bx, 1, 1, p)) / b
            t[2 * 3 + 2] = (at(by, 2, 0, p) - at(bx, 2, 1, p)) / b
            for i in 0..<3 {
                t[i * 3 + 1] = at(bx, i, 2, p) / b
                t[i * 3 + 0] = -1 * at(by, i, 2, p) / b
            }
            for k in 0..<9 { alpha[k * n + p] = t[k] }
            let sum = abs(t[2]) + abs(t[5]) + abs(t[8]) + abs(t[0]) + abs(t[3]) + abs(t[6]) + abs(t[1]) + abs(t[4]) + abs(t[7])
            gnd[p] = 30 / 20.0 * sum
        }
        return Result(rows: rows, columns: columns, gnd: gnd, alpha: alpha)
    }

    /// `compute` off the caller's actor: a 1000 x 1000 map runs 48 million symmetry products.
    @concurrent package static func computing(quaternions: [SIMD4<Double>], rows: Int, columns: Int, stepMicrons: Double,
                                              structure: DefDAPCrystalStructure, derivatives: Derivatives = .separate,
                                              burgersVector: Double = defaultBurgersVector) async -> Result {
        compute(quaternions: quaternions, rows: rows, columns: columns, stepMicrons: stepMicrons, structure: structure,
                derivatives: derivatives, burgersVector: burgersVector)
    }
}
