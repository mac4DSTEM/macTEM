//
//  KinematicMasterPattern.swift
//  Role: the kinematical EBSD master pattern of a set of reflectors in the stereographic projection, kikuchipy 0.13.1's
//        `KikuchiPatternSimulator.calculate_master_pattern`: a (2 half + 1)² grid from −1 to 1 on each axis, each point taken back to
//        the unit sphere (orix's `InverseStereographicProjection`, the upper hemisphere from the south pole, the lower from the north),
//        and every band added where the point lies within it: the intensity where the angle to the plane normal is between π/2 − θ
//        and π/2 (one side of the plane, kikuchipy's band), half of it on the plane itself (|cos| ≤ 1e-7). Band intensity |F|
//        ("linear"), |F|² ("square") or 1 (none). The selection rule is EMsoft's, as kikuchipy notes. Ported from kikuchipy
//        (`simulations/kikuchi_pattern_simulator.py` `calculate_master_pattern`, `get_pattern`) and orix (`projections/
//        stereographic.py`), both GPL-3.0-or-later (see NOTICE); method: Winkelmann (2010), the kinematic approximation. Parity
//        bundle `m6/kinematic-master-pattern-ni` (rtol 1e-5).
//

import Foundation

package nonisolated enum KinematicMasterPattern {
    /// How a band's intensity scales with its structure factor (kikuchipy's `scaling`).
    package enum Scaling: String, Sendable, CaseIterable {
        /// |F| (kikuchipy's default "linear").
        case linear
        /// |F|² ("square").
        case square
        /// Every band 1 (None).
        case none
    }

    /// Which hemispheres, as kikuchipy's `poles_from_hemisphere`: the upper is projected from the south pole (−1), the lower from the
    /// north (1).
    package enum Hemisphere: String, Sendable, CaseIterable {
        case upper, lower, both

        var poles: [Double] {
            switch self {
            case .upper: [-1]
            case .lower: [1]
            case .both: [-1, 1]
            }
        }
    }

    /// The master pattern, row-major per hemisphere ([hemisphere][row * size + column], size = 2 halfSize + 1; the upper first for
    /// both). `reflectors` are the bands' plane normals, `theta` their Bragg angles (radians) and `structureFactor` their |F| (ignored
    /// for `.none`). Rows run over y and columns over x, both from −1 to 1 (numpy's `meshgrid` of `linspace(-1, 1, size)`).
    package static func calculate(reflectors: KikuchiReflectors, theta: [Double], structureFactor: [Double], halfSize: Int = 500,
                                  hemisphere: Hemisphere = .upper, scaling: Scaling = .linear) -> [[Double]] {
        precondition(theta.count == reflectors.count, "one Bragg angle per reflector")
        let intensity = intensities(scaling, structureFactor: structureFactor, count: reflectors.count)
        precondition(intensity.count == reflectors.count, "one structure factor per reflector")
        let normals = reflectors.hkl.map { Vector3.unit(reflectors.lattice.cartesian(hkl: $0)) }
        let size = 2 * halfSize + 1
        // numpy's linspace(-1, 1, size): start + i * step, the last point exactly the stop.
        let step = 2 / Double(size - 1)
        let axis = (0..<size).map { $0 == size - 1 ? 1.0 : -1 + Double($0) * step }
        let thetaMin = theta.map { Double.pi / 2 - $0 }
        return hemisphere.poles.map { pole in
            var pattern = [Double](repeating: 0, count: size * size)
            pattern.withUnsafeMutableBufferPointer { out in
                let base = out.baseAddress!
                let shared = SendablePointer(base: base)
                DispatchQueue.concurrentPerform(iterations: size) { row in
                    let y = axis[row]
                    for column in 0..<size {
                        let x = axis[column]
                        let denominator = 1 + x * x + y * y
                        let v = SIMD3(2 * x / denominator, 2 * y / denominator, -pole * (1 - x * x - y * y) / denominator)
                        shared.base[row * size + column] = bandSum(v, normals: normals, thetaMin: thetaMin, intensity: intensity)
                    }
                }
            }
            return pattern
        }
    }

    /// kikuchipy's `get_pattern` at one direction `v` (a unit vector): every band whose plane normal makes an angle with `v`
    /// between π/2 − θ and π/2 adds its intensity, half of it on the plane itself (|cos| ≤ 1e-7); summed in reflector order.
    @inline(__always)
    static func bandSum(_ v: SIMD3<Double>, normals: [SIMD3<Double>], thetaMin: [Double], intensity: [Double]) -> Double {
        var sum = 0.0
        for i in 0..<normals.count {
            let d = Vector3.dot(normals[i], v)
            if abs(d) <= 1e-7 {
                sum += 0.5 * intensity[i]
            } else {
                let angle = acos(d)
                if angle <= Double.pi / 2 && angle >= thetaMin[i] { sum += intensity[i] }
            }
        }
        return sum
    }

    /// The band intensities kikuchipy's `scaling` gives.
    static func intensities(_ scaling: Scaling, structureFactor: [Double], count: Int) -> [Double] {
        switch scaling {
        case .linear: return structureFactor
        case .square: return structureFactor.map { $0 * $0 }
        case .none: return Array(repeating: 1, count: count)
        }
    }

    /// The output buffer handed to the rows (each row writes only its own span).
    struct SendablePointer: @unchecked Sendable {
        let base: UnsafeMutablePointer<Double>
    }
}
