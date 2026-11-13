//
//  OrientationDensity.swift
//  The orientation distribution function (ODF) of a set of orientations by kernel density estimation on SO(3)
//  (Hielscher and Schaeben 2008, J. Appl. Cryst. 41, 1024; MTEX's `calcDensity`) with the de la Vallée Poussin kernel
//  (Schaeben 1997, phys. stat. sol. (b) 200, 367):
//
//      f(g) = 1 / (N |G|) Σ_i Σ_{s ∈ G} C(κ) |⟨g_i g⁻¹, s⟩|^(2κ),   κ = ln(1/2) / (2 ln cos(h / 2)),
//      C(κ) = B(3/2, 1/2) / B(3/2, κ + 1/2),
//
//  over the N orientations and the |G| proper elements of their symmetry, h the kernel's half-width; the kernel integrates
//  to 1 over SO(3), so a uniform texture is 1 mrd. orix 0.15.0 has no ODF: the reference is this closed form written on
//  orix's rotations in `tools/parity/sem/texture_cases.py` (D-SEM-68 in docs/decisions.md), with two checks that do not
//  rest on it (the mean over orix's uniform sample of SO(3) is 1, the identity's ODF at the identity is C(κ) / |G|, the
//  other elements' terms being below 1e-27). Sections are φ2 = const in Bunge angles, φ1 across and Φ down, as orix's `from_euler` builds
//  the grid rotations.
//
//  Every orientation contributes to every grid point (no cut-off), so the sum is exact to rounding; N x nodes x |G| powers,
//  split over the cores in bands of nodes.
//
//  Parity: `tools/parity/sem` bundles `m5/texture-ti`, `m5/texture-cubic`, `m5/texture-ti-full` (figure F13), ODF values
//  rtol 1e-4 (docs/parity.md).
//

import Foundation
import Synchronization

/// One φ2 section of the ODF: values (mrd) at the nodes φ1 x Φ, φ1-major (node (i, j) at i * Φ.count + j).
package nonisolated struct ODFSection: Sendable, Equatable {
    package let phi2Degrees: Double
    package let phi1Degrees: [Double]
    package let PhiDegrees: [Double]
    package let values: [Double]
    package let halfWidthDegrees: Double

    package var maximum: Double { values.max() ?? 0 }
}

package nonisolated enum OrientationDensity {
    /// MTEX's default half-width of `calcDensity`, degrees.
    package static let defaultHalfWidthDegrees = 10.0

    /// κ of the de la Vallée Poussin kernel whose value at `halfWidthDegrees` is half its peak.
    package static func kappa(halfWidthDegrees: Double) -> Double {
        0.5 * log(0.5) / log(cos(halfWidthDegrees * Double.pi / 180 / 2))
    }

    /// C(κ) = B(3/2, 1/2) / B(3/2, κ + 1/2), the kernel's value at the identity.
    package static func kernelConstant(kappa: Double) -> Double {
        func beta(_ a: Double, _ b: Double) -> Double { exp(lgamma(a) + lgamma(b) - lgamma(a + b)) }
        return beta(1.5, 0.5) / beta(1.5, kappa + 0.5)
    }

    /// f at each grid quaternion, mrd.
    package static func values(_ orientations: Orientations, at grid: [SIMD4<Double>],
                               halfWidthDegrees: Double = defaultHalfWidthDegrees) -> [Double] {
        let sym = orientations.symmetry.properSubgroup.elements.map(\.q)
        let q = orientations.quaternions.map { Rotation($0).q }
        let exponent = 2 * kappa(halfWidthDegrees: halfWidthDegrees)
        let scale = kernelConstant(kappa: exponent / 2) / Double(q.count * sym.count)
        let out = ValueBands(count: grid.count)
        let bands = max(1, min(grid.count, ProcessInfo.processInfo.activeProcessorCount * 4))
        let per = (grid.count + bands - 1) / bands
        DispatchQueue.concurrentPerform(iterations: bands) { band in
            let lo = band * per, hi = min(grid.count, lo + per)
            guard lo < hi else { return }
            var local = [Double](repeating: 0, count: hi - lo)
            for k in lo..<hi {
                let (a1, b1, c1, d1) = (grid[k][0], grid[k][1], grid[k][2], grid[k][3])
                var sum = 0.0
                for qi in q {
                    let (a2, b2, c2, d2) = (qi[0], qi[1], qi[2], qi[3])
                    let mw = a2 * a1 + b2 * b1 + c2 * c1 + d2 * d1
                    let mx = b2 * a1 - a2 * b1 + d2 * c1 - c2 * d1
                    let my = c2 * a1 - d2 * b1 - a2 * c1 + b2 * d1
                    let mz = d2 * a1 + c2 * b1 - b2 * c1 - a2 * d1
                    for s in sym {
                        let d = Swift.min(abs(mw * s[0] + mx * s[1] + my * s[2] + mz * s[3]), 1)
                        sum += pow(d, exponent)
                    }
                }
                local[k - lo] = scale * sum
            }
            out.set(lo, local)
        }
        return out.values
    }

    /// The Bunge (φ1, Φ) nodes of one φ2 section as quaternions (`Rotation.from_euler`, lab to crystal), φ1-major.
    package static func sectionGrid(phi2Degrees: Double, phi1Degrees: [Double], PhiDegrees: [Double]) -> [SIMD4<Double>] {
        phi1Degrees.flatMap { p1 in PhiDegrees.map { p in Rotation.fromEuler(SIMD3(p1, p, phi2Degrees), degrees: true).q } }
    }

    /// numpy's `arange(0, stop, step)` in degrees: 0, step, 2 step, ... below `stop`.
    /// A step that is not a positive number, or one that would make more than `maximumNodes` nodes, gives none.
    package static func nodes(below stop: Double, step: Double) -> [Double] {
        guard step > 0, step.isFinite, let n = CheckedConversion.int(((stop - 0) / step).rounded(.up)), n <= maximumNodes else { return [] }
        return (0..<max(n, 0)).map { Double($0) * step }
    }

    /// The most nodes `nodes(below:step:)` gives along one Euler angle: a 0.01° step over 360°.
    package static let maximumNodes = 36_000

    /// The Bunge ranges of a section plot for a crystal symmetry with a triclinic sample (MTEX's default section ranges):
    /// φ2 over 360° divided by the order of the rotation about z (90° cubic and tetragonal, 60° hexagonal, 120° trigonal,
    /// 180° orthorhombic and monoclinic, 360° triclinic); Φ over 90° when a two-fold axis lies perpendicular to z, else
    /// 180°; φ1 over 360° (sample symmetry triclinic). Cubic groups (a three-fold axis off z) keep φ2 at 90°.
    package static func bungeRanges(for symmetry: PointGroup) -> (phi1: Double, Phi: Double, phi2: Double) {
        var fold = 1
        var twoFoldPerpendicular = false
        for e in symmetry.properSubgroup.elements {
            let angle = e.angle
            guard angle > 1e-9 else { continue }
            let axis = Vector3.unit(e.axis)
            if abs(abs(axis.z) - 1) < 1e-9 { fold = max(fold, Int((2 * Double.pi / angle).rounded())) }
            if abs(angle - Double.pi) < 1e-9, abs(axis.z) < 1e-9 { twoFoldPerpendicular = true }
        }
        return (360, twoFoldPerpendicular ? 90 : 180, 360 / Double(fold))
    }

    /// One φ2 section on `stepDegrees` nodes over the symmetry's Bunge ranges: φ1 0, step, ... below 360°, Φ 0, step, ...
    /// up to and including the end of its range.
    package static func section(_ orientations: Orientations, phi2Degrees: Double, stepDegrees: Double = 5,
                                halfWidthDegrees: Double = defaultHalfWidthDegrees) -> ODFSection {
        let r = bungeRanges(for: orientations.symmetry)
        let phi1 = nodes(below: r.phi1, step: stepDegrees)
        let Phi = nodes(below: r.Phi + stepDegrees / 2, step: stepDegrees)
        return section(orientations, phi2Degrees: phi2Degrees, phi1Degrees: phi1, PhiDegrees: Phi, halfWidthDegrees: halfWidthDegrees)
    }

    /// One φ2 section on the given nodes.
    package static func section(_ orientations: Orientations, phi2Degrees: Double, phi1Degrees: [Double], PhiDegrees: [Double],
                                halfWidthDegrees: Double = defaultHalfWidthDegrees) -> ODFSection {
        let grid = sectionGrid(phi2Degrees: phi2Degrees, phi1Degrees: phi1Degrees, PhiDegrees: PhiDegrees)
        return ODFSection(phi2Degrees: phi2Degrees, phi1Degrees: phi1Degrees, PhiDegrees: PhiDegrees,
                          values: values(orientations, at: grid, halfWidthDegrees: halfWidthDegrees), halfWidthDegrees: halfWidthDegrees)
    }

    private nonisolated final class ValueBands: Sendable {
        private let storage: Mutex<[Double]>

        init(count: Int) { storage = Mutex([Double](repeating: 0, count: count)) }

        func set(_ start: Int, _ values: [Double]) {
            storage.withLock { $0.replaceSubrange(start..<(start + values.count), with: values) }
        }

        var values: [Double] { storage.withLock { $0 } }
    }
}
