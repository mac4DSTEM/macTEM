//
//  SphericalVectors.swift
//  orix 0.15.0's `orix.vector.Vector3d` spherical coordinates and `orix.projections` (the stereographic projection and its
//  inverse, upper and lower hemisphere) on `SIMD3<Double>`, the vector type of the orientation core. GPL-3.0 (orix is
//  GPL-3.0-or-later), see NOTICE. Parity: `tools/parity/sem` bundle `m3/ipf-color-keys`, coordinates within 1e-7.
//

import Foundation

extension Vector3 {
    /// `Vector3d.azimuth`: atan2(y, x) in [0, 2π), each of x and y set to 0 first where it is within numpy's `isclose`
    /// of 0 (1e-8), as orix does against rounding.
    package static func azimuth(_ v: SIMD3<Double>) -> Double {
        let x = abs(v.x) <= 1e-8 ? 0 : v.x
        let y = abs(v.y) <= 1e-8 ? 0 : v.y
        let a = atan2(y, x)
        return a < 0 ? a + 2 * Double.pi : a
    }

    /// `Vector3d.polar`: arccos(z / |v|) in [0, π].
    package static func polar(_ v: SIMD3<Double>) -> Double {
        acos(v.z / RotationConversions.norm(v))
    }

    /// `Vector3d.get_circle`: `steps` vectors on the circle at `openingAngle` about `v` (a great circle by default), from
    /// rotating `v` by `openingAngle` about its perpendicular and then by numpy's `linspace(0, 2π, steps)` about itself.
    package static func circle(about v: SIMD3<Double>, openingAngle: Double = Double.pi / 2, steps: Int = 100) -> [SIMD3<Double>] {
        let r1 = Rotation.fromAxisAngle(perpendicular(v), openingAngle)
        return linspace(0, 2 * Double.pi, steps).map { w in (Rotation.fromAxisAngle(v, w) * r1) * v }
    }

    /// numpy's `linspace(start, stop, num)` (endpoint included): start + i · step, the last value exactly `stop`.
    package static func linspace(_ start: Double, _ stop: Double, _ num: Int) -> [Double] {
        guard num > 1 else { return num == 1 ? [start] : [] }
        let step = (stop - start) / Double(num - 1)
        var out = (0..<num).map { start + Double($0) * step }
        out[num - 1] = stop
        return out
    }

    /// numpy's `mod` on floats: the remainder with the sign of the divisor (a zero remainder is +0, NaN stays NaN).
    package static func pythonMod(_ a: Double, _ b: Double) -> Double {
        var m = fmod(a, b)
        if m != 0 {
            if (b < 0) != (m < 0) { m += b }
        } else if !m.isNaN {
            m = 0
        }
        return m
    }
}

/// orix's `StereographicProjection` (`pole` −1 projects the upper hemisphere from the south pole, +1 the lower one from the
/// north pole) and `InverseStereographicProjection`.
package nonisolated struct StereographicProjection: Sendable, Equatable {
    package var pole: Int

    package init(pole: Int = -1) {
        precondition(pole == -1 || pole == 1, "the stereographic pole is -1 (upper hemisphere) or 1 (lower hemisphere)")
        self.pole = pole
    }

    /// The hemisphere this projection draws, orix's `SphericalRegion([0, 0, -pole])`: a vector is in it when its dot product
    /// with the region's normal is above −1e-9 (`v <= region`).
    package func isInHemisphere(_ v: SIMD3<Double>) -> Bool {
        Vector3.dot(SIMD3(0, 0, Double(-pole)), v) > -1e-9
    }

    /// `vector2xy`: the vectors of this hemisphere (the others are dropped, as orix drops them), each made unit, to
    /// (x, y) = −pole · (vx, vy) / (vz − pole); a zero denominator gives (0, 0).
    package func vectorToXY(_ vectors: [SIMD3<Double>]) -> [SIMD2<Double>] {
        vectors.filter(isInHemisphere).map { StereographicProjection.project($0, pole: pole) }
    }

    /// `_vector2xy` of one vector, whatever its hemisphere.
    package static func project(_ v: SIMD3<Double>, pole: Int) -> SIMD2<Double> {
        let u = Vector3.unit(v)
        let p = Double(pole)
        let denom = u.z - p
        guard denom != 0 else { return SIMD2(0, 0) }
        return SIMD2(-p * u.x / denom, -p * u.y / denom)
    }

    /// `vector2xy_split`: the upper hemisphere's vectors projected with pole −1 and the lower one's with pole 1 (a vector on
    /// the equator is in both).
    package static func vectorToXYSplit(_ vectors: [SIMD3<Double>]) -> (upper: [SIMD2<Double>], lower: [SIMD2<Double>]) {
        (StereographicProjection(pole: -1).vectorToXY(vectors), StereographicProjection(pole: 1).vectorToXY(vectors))
    }

    /// `InverseStereographicProjection.xy2vector`: the unit vector of (x, y) in this projection's hemisphere.
    package func xyToVector(_ xy: SIMD2<Double>) -> SIMD3<Double> {
        let x = xy.x, y = xy.y
        let denom = 1 + x * x + y * y
        return SIMD3(2 * x / denom, 2 * y / denom, -Double(pole) * (1 - x * x - y * y) / denom)
    }
}
