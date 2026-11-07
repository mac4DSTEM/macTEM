//
//  GeometricalKikuchiSimulation.swift
//  Role: the geometrical Kikuchi pattern of one crystal orientation on one detector, kikuchipy 0.13.1's
//        `KikuchiPatternSimulator.on_detector` with `GeometricalKikuchiPatternSimulation.lines_coordinates` and `zone_axes_coordinates`
//        (and the features `KikuchiPatternLine` / `KikuchiPatternZoneAxis`): each reflector's plane trace (the band's centre line) where
//        it crosses the circle of radius r_max about the projection centre on the gnomonic plane, and the zone axes (the reflectors'
//        pairwise cross products, reduced to the smallest integers as orix's `Miller.round`) that fall on the detector, in gnomonic and
//        in detector-pixel coordinates. The frame is kikuchipy's: the reflectors through the lattice's reciprocal basis, the crystal
//        rotation's matrix and the transposed sample-to-detector rotation; a reflector counts only while its detector z is positive
//        (one of ±g draws each band). Ported from kikuchipy (`simulations/kikuchi_pattern_simulator.py`,
//        `_kikuchi_pattern_features.py`, `_kikuchi_pattern_simulation.py`) and orix (`vector/miller.py` `_round_indices`), both
//        GPL-3.0-or-later (see NOTICE); method: Britton et al. (2016) for the gnomonic projection, kikuchipy's geometrical simulation
//        tutorial. Parity bundles `m6/geometrical-simulation-nickel` (figure F14) and `m6/geometrical-simulation-tilted`.
//
//  Pixel coordinates follow kikuchipy's on_detector: x = (x_g + PCx/PCz · aspect) / x_scale, y = (−y_g + PCy/PCz) / y_scale with
//  kikuchipy's x_scale and y_scale (the gnomonic range over N − 1 pixels), so pixel 0 and N − 1 are the detector's gnomonic edges.
//

import Foundation

package nonisolated struct GeometricalKikuchiSimulation: Sendable, Equatable {
    /// One band's centre line, ending on the r_max circle (it runs past the detector; a drawing clips it).
    package struct Line: Sendable, Equatable {
        /// The reflector, as its index into the reflectors given and its hkl.
        package var reflector: Int
        package var hkl: SIMD3<Double>
        /// (x1, y1, x2, y2) on the gnomonic plane and in detector pixels.
        package var gnomonic: SIMD4<Double>
        package var pixel: SIMD4<Double>
    }

    /// One zone axis on the detector.
    package struct ZoneAxis: Sendable, Equatable {
        /// The direction's smallest integer indices [uvw].
        package var uvw: SIMD3<Int>
        /// (x, y) on the gnomonic plane and in detector pixels.
        package var gnomonic: SIMD2<Double>
        package var pixel: SIMD2<Double>

        /// kikuchipy's label, the indices run together with their signs ("1-21").
        package var label: String { "\(uvw.x)\(uvw.y)\(uvw.z)" }
    }

    package var lines: [Line]
    /// Sorted by u, then v, then w.
    package var zoneAxes: [ZoneAxis]
    /// The radius the lines end on (r_max of the projection centre, or the one given).
    package var maxRGnomonic: Double

    /// The simulation for the crystal orientation `rotation` (orix's (a, b, c, d) as a crystal map holds it, Bunge from the EDAX TSL
    /// sample frame) on `detector` (its shape and angles) seen from the Bruker projection centre `pc`. `maxRGnomonic` is the circle the
    /// lines end on: kikuchipy's is the largest r_max over the detector's centres, so a whole scan passes its own; nil takes `pc`'s.
    package static func simulate(reflectors: KikuchiReflectors, rotation: SIMD4<Double>, detector: EBSDDetectorGeometry, pc: SIMD3<Double>,
                                 maxRGnomonic: Double? = nil) -> GeometricalKikuchiSimulation {
        let lattice = reflectors.lattice
        // u_os = U_o · U_sᵀ with U_s the sample-to-detector matrix (kikuchipy transposes `sample_to_detector.to_matrix()`).
        let uo = Rotation(rotation).matrix.rows
        let us = detector.sampleToDetector.rows
        let uos: [SIMD3<Double>] = uo.map { row in SIMD3(Vector3.dot(row, us[0]), Vector3.dot(row, us[1]), Vector3.dot(row, us[2])) }
        /// A crystal Cartesian vector (row) through u_os: v · u_os.
        func toDetector(_ v: SIMD3<Double>) -> SIMD3<Double> { uos[0] * v.x + uos[1] * v.y + uos[2] * v.z }

        let bounds = detector.gnomonicBounds(pc)
        let scale = detector.gnomonicScale(pc)
        let rMax = maxRGnomonic ?? detector.rMax(pc)
        let aspect = detector.aspectRatio
        func pixelX(_ xg: Double) -> Double { (xg + pc.x / pc.z * aspect) / scale.x }
        func pixelY(_ yg: Double) -> Double { (-yg + pc.y / pc.z) / scale.y }

        // The reflectors in the detector frame; those pointing away from the screen (z ≤ 0) are not in the pattern.
        var visible: [(index: Int, hkl: SIMD3<Double>, d: SIMD3<Double>)] = []
        for (i, h) in reflectors.hkl.enumerated() {
            let d = toDetector(lattice.reciprocal(h))
            if d.z > 0 { visible.append((i, h, d)) }
        }

        // Lines: the Hesse distance tan(π/2 − polar), kept while |distance| < r_max (and z > −1e-5), the plane trace's ends on the circle.
        var lines: [Line] = []
        for v in visible {
            let d = v.d
            let norm = (d.x * d.x + d.y * d.y + d.z * d.z).squareRoot()
            let polar = acos(d.z / norm)
            let hesse = tan(0.5 * Double.pi - polar)
            guard abs(hesse) < rMax, d.z > -1e-5 else { continue }
            let alpha = acos(hesse / rMax)
            let azimuth = Self.azimuth(d)
            let a1 = azimuth - Double.pi + alpha, a2 = azimuth - Double.pi - alpha
            let g = SIMD4(cos(a1), sin(a1), cos(a2), sin(a2)) * rMax
            lines.append(Line(reflector: v.index, hkl: v.hkl, gnomonic: g,
                              pixel: SIMD4(pixelX(g[0]), pixelY(g[1]), pixelX(g[2]), pixelY(g[3]))))
        }

        // Zone axes: every ordered pair's cross product (orix `Miller.cross`, the direct indices of g1 × g2), zero ones dropped,
        // rounded to the smallest integers (max index 20), unique in order of appearance, then those pointing at the screen and
        // within one pixel of the detector's gnomonic bounds and inside the r_max circle.
        var candidates: [SIMD3<Double>] = []
        let cartesian = visible.map { lattice.reciprocal($0.hkl) }
        for g1 in cartesian {
            for g2 in cartesian {
                let xyz = Vector3.cross(g1, g2)
                if abs(xyz.x) <= 1e-8 && abs(xyz.y) <= 1e-8 && abs(xyz.z) <= 1e-8 { continue }
                candidates.append(Self.roundIndices(lattice.directIndices(xyz), maxIndex: 20))
            }
        }
        var seen = Set<Rotation.Differentiators>()
        var zoneAxes: [ZoneAxis] = []
        let xLow = bounds.xMin - scale.x, xHigh = bounds.xMax + scale.x
        let yLow = bounds.yMin - scale.y, yHigh = bounds.yMax + scale.y
        for uvw in candidates {
            guard seen.insert(Vector3.key(lattice.direct(uvw))).inserted else { continue }
            let d = toDetector(lattice.direct(uvw))
            guard d.z > 0 else { continue }
            let xg = d.x / d.z, yg = d.y / d.z
            guard xg >= xLow, xg <= xHigh, yg >= yLow, yg <= yHigh else { continue }
            guard (xg * xg + yg * yg).squareRoot() < rMax else { continue }
            zoneAxes.append(ZoneAxis(uvw: SIMD3(Int(uvw.x), Int(uvw.y), Int(uvw.z)), gnomonic: SIMD2(xg, yg),
                                     pixel: SIMD2(pixelX(xg), pixelY(yg))))
        }
        zoneAxes.sort { ($0.uvw.x, $0.uvw.y, $0.uvw.z) < ($1.uvw.x, $1.uvw.y, $1.uvw.z) }
        return GeometricalKikuchiSimulation(lines: lines, zoneAxes: zoneAxes, maxRGnomonic: rMax)
    }

    /// orix's `Vector3d.azimuth`: arctan2(y, x) in [0, 2π), with x and y that are close to zero (numpy's `isclose`) set to zero.
    static func azimuth(_ v: SIMD3<Double>) -> Double {
        let x = abs(v.x) <= 1e-8 ? 0 : v.x
        let y = abs(v.y) <= 1e-8 ? 0 : v.y
        var a = atan2(y, x)
        if a < 0 { a += 2 * Double.pi }
        return a
    }

    /// orix's `_round_indices` (after MTEX's `Miller.round`): scale the indices so the largest is 1, try the multipliers 1 to `maxIndex`,
    /// and take the first with the smallest squared rounding error relative to the squared length (the error itself rounded to 7
    /// decimals); the indices times that multiplier over the largest, rounded.
    package static func roundIndices(_ idx: SIMD3<Double>, maxIndex: Int) -> SIMD3<Double> {
        let largest = max(abs(idx.x), abs(idx.y), abs(idx.z))
        var best = 0, bestError = Double.infinity
        for m in 1...maxIndex {
            let s = idx / largest * Double(m)
            let r = SIMD3(s.x.rounded(.toNearestOrEven), s.y.rounded(.toNearestOrEven), s.z.rounded(.toNearestOrEven))
            let diff = s - r
            let ratio = (diff * diff).sum() / (s * s).sum()
            let error = 1e-7 * (1e7 * ratio).rounded(.toNearestOrEven)
            if error < bestError { bestError = error; best = m }
        }
        let multiplier = Double(best) / largest
        let v = idx * multiplier
        return SIMD3(v.x.rounded(.toNearestOrEven), v.y.rounded(.toNearestOrEven), v.z.rounded(.toNearestOrEven))
    }
}
