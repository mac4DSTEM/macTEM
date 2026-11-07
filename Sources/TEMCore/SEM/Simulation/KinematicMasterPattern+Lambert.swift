//
//  KinematicMasterPattern+Lambert.swift
//  Role: the kinematical master pattern in the square Lambert projection, both hemispheres, so `MasterPatternProjection` (kikuchipy's
//        `get_patterns`) can put it on a detector: the Kinematical overlay of the pattern pane (#201, decision D-SEM-95). kikuchipy
//        computes its kinematical master pattern only in the stereographic projection and turns it into Lambert by a cubic spline
//        (`as_lambert`, scipy's `splinef2d`), which rings at the band edges; here kikuchipy's own band rule (`get_pattern`) is evaluated
//        directly at each Lambert pixel's direction (`_lambert2vector`, normalised; the lower hemisphere the same grid with z negated,
//        as `_vector2lambert` reads it). Ported from kikuchipy (`simulations/kikuchi_pattern_simulator.py` `get_pattern`,
//        `signals/util/_master_pattern.py` `_lambert2vector`), GPL-3.0-or-later (see NOTICE); the square Lambert projection of Roşca
//        (2010) as EMsoft uses it (Callahan and De Graef 2013). Parity bundle `m6/kinematic-overlay-nickel`.
//

import Foundation
import FormatoCore

extension KinematicMasterPattern {
    /// `_lambert2vector`: the direction of square Lambert point (X, Y) in [-1, 1]², on the upper hemisphere, not normalised
    /// ((0, 0, 1) at the centre).
    package static func lambertVector(x: Double, y: Double) -> SIMD3<Double> {
        let root = (Double.pi / 2).squareRoot()
        let xi = x * root, yi = y * root
        let xa = abs(xi), ya = abs(yi)
        if max(xa, ya) == 0 { return SIMD3(0, 0, 1) }
        if xa <= ya {
            let q = 2 * yi * (Double.pi - yi * yi).squareRoot() / Double.pi
            let qq = xi * Double.pi * 0.25 / yi
            return SIMD3(q * sin(qq), q * cos(qq), 1 - 2 * yi * yi / Double.pi)
        }
        let q = 2 * xi * (Double.pi - xi * xi).squareRoot() / Double.pi
        let qq = yi * Double.pi * 0.25 / xi
        return SIMD3(q * cos(qq), q * sin(qq), 1 - 2 * xi * xi / Double.pi)
    }

    /// The kinematical master pattern of `reflectors` (Bragg angles `theta`, |F| `structureFactor` for the scalings that use it) on
    /// the (2 halfSize + 1)² square Lambert grid from −1 to 1, upper then lower hemisphere, row-major with rows over Y and columns over
    /// X (numpy's `meshgrid`), as a master pattern `MasterPatternProjection` projects: float32 values, both hemispheres, `energyKeV`
    /// its one energy and `phase` its phase.
    package static func lambert(reflectors: KikuchiReflectors, theta: [Double], structureFactor: [Double] = [], halfSize: Int = 200,
                                scaling: Scaling = .none, energyKeV: Double, phase: CrystalPhase) -> EBSDMasterPattern {
        precondition(theta.count == reflectors.count, "one Bragg angle per reflector")
        let intensity = intensities(scaling, structureFactor: structureFactor, count: reflectors.count)
        precondition(intensity.count == reflectors.count, "one structure factor per reflector")
        let normals = reflectors.hkl.map { Vector3.unit(reflectors.lattice.cartesian(hkl: $0)) }
        let thetaMin = theta.map { Double.pi / 2 - $0 }
        let size = 2 * halfSize + 1
        let axis = Vector3.linspace(-1, 1, size)
        var values = [Float](repeating: 0, count: 2 * size * size)
        values.withUnsafeMutableBufferPointer { out in
            let shared = FloatPointer(base: out.baseAddress!)
            DispatchQueue.concurrentPerform(iterations: size) { row in
                let y = axis[row]
                for column in 0..<size {
                    let v = Vector3.unit(lambertVector(x: axis[column], y: y))
                    let upper = bandSum(v, normals: normals, thetaMin: thetaMin, intensity: intensity)
                    let lower = bandSum(SIMD3(v.x, v.y, -v.z), normals: normals, thetaMin: thetaMin, intensity: intensity)
                    shared.base[row * size + column] = Float(upper)
                    shared.base[size * size + row * size + column] = Float(lower)
                }
            }
        }
        return EBSDMasterPattern(diffractionType: .ebsd, projection: .lambert, hemisphere: .both, dataType: .float32, hemisphereCount: 2,
                                 energies: [energyKeV], side: size, values: values,
                                 phase: EBSDMasterPattern.Phase(name: phase.name, spaceGroup: phase.spaceGroup ?? 1, pointGroup: phase.pointGroupName ?? "1",
                                                                containsInversion: phase.pointGroup?.containsInversion ?? false,
                                                                lattice: phase.lattice ?? [], atomCount: 0),
                                 energyAxis: EBSDMasterPattern.EnergyAxis(offset: energyKeV, scale: 1, size: 1))
    }

    /// The output buffer the rows share (each row writes only its own spans).
    private struct FloatPointer: @unchecked Sendable {
        let base: UnsafeMutablePointer<Float>
    }
}
