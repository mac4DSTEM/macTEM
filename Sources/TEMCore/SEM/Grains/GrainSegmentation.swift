//
//  GrainSegmentation.swift
//  Grain boundaries, grains and the grain neighbour network of an EBSD map, ported from DefDAP 1.3.1 (Apache-2.0, see
//  NOTICE): `ebsd.Map.find_boundaries` (the misorientation of each point with its right and lower neighbour, the smallest
//  over the crystal symmetry, above a threshold, or a change of phase), `ebsd.Map.find_grains` with `_accelerated.flood_fill`
//  (a flood fill from the first unassigned point in map order that crosses no boundary; a grain below the minimum size
//  keeps its points marked −2 and gives its number to the next grain) and `ebsd.Map.build_neighbour_network` (pairs of
//  grains that share boundary points, the map's outer pixels left out). Humphreys 2001, J. Mater. Sci. 36, 3833 (grain
//  reconstruction from EBSD maps by a misorientation threshold). The ASTM E112 grain size number from the mean lineal
//  intercept is ASTM E112-13, eq. (A) of section 16 (Heyn intercept): G = −6.643856 log10(ℓ) − 3.288, ℓ in mm.
//
//  Where DefDAP takes the primary phase's symmetry for every pair (its TODO "grain boundaries should be calculated per
//  crystal structure"), the port takes the phase of the pair; a pair of two phases is a phase boundary either way, so the
//  two agree on every map whose phases share a crystal structure (both parity maps), D-SEM-55. The
//  flood fill keeps DefDAP's stack order, so each grain's points come in DefDAP's order, which the grain average
//  orientation depends on.
//
//  Parity: `tools/parity/sem` bundles `m5/grains-ti` (90 × 120 of orix-data's Ti map, every array), `m5/grains-ti-full`
//  (figure F11, the whole 381 × 507 map) and `m5/grains-sdss` (two phases): boundary images, grain maps, sizes and the
//  network exact, neighbour angles atol 1e-7 rad (docs/parity.md).
//

import Foundation

/// DefDAP's `find_boundaries`: per point the misorientation angle with its right (x) and lower (y) neighbour, and the
/// boundary images (a point is marked when the edge to its right / lower neighbour is a boundary).
package nonisolated struct GrainBoundaries: Sendable, Equatable {
    package let rows: Int
    package let columns: Int
    /// The threshold in radians.
    package let threshold: Double
    /// The smallest misorientation angle (radians) with the right neighbour; NaN on the last column.
    package let angleX: [Double]
    /// The smallest misorientation angle with the neighbour below; NaN on the last row.
    package let angleY: [Double]
    /// Grain boundary images: angle above the threshold or a change of phase (DefDAP's `grain_boundaries`).
    package let grainX: [Bool]
    package let grainY: [Bool]
    /// Phase boundary images (DefDAP's `phase_boundaries`).
    package let phaseX: [Bool]
    package let phaseY: [Bool]

    /// The boundaries at `thresholdDegrees` (DefDAP's default 10°).
    package static func find(in map: GrainMap, thresholdDegrees: Double = 10) -> GrainBoundaries {
        // Never nil: nothing cancels it.
        find(in: map, thresholdDegrees: thresholdDegrees, isCancelled: { false })!
    }

    /// The same, asking `isCancelled` before each row: nil once it says so (the Maps room's Stop, `GrainAnalysis.run`).
    package static func find(in map: GrainMap, thresholdDegrees: Double, isCancelled: () -> Bool) -> GrainBoundaries? {
        let (h, w) = (map.rows, map.columns)
        let tol = thresholdDegrees * .pi / 180
        var ax = [Double](repeating: .nan, count: h * w), ay = ax
        var gx = [Bool](repeating: false, count: h * w), gy = gx, px = gx, py = gx
        let q = map.quaternions, phase = map.phase
        func angle(_ i: Int, _ j: Int) -> Double {
            let p = phase[i] > 0 ? phase[i] : (phase[j] > 0 ? phase[j] : 1)
            let ops = map.symmetries.isEmpty ? [SIMD4<Double>(1, 0, 0, 0)] : map.symmetries[p - 1]
            let a = q[i], b = q[j]
            var best = min(DefDAPQuat.absDot(a, b), 1)
            for s in ops.dropFirst() {
                best = max(best, min(DefDAPQuat.absDot(a, DefDAPQuat.symmetricEquivalent(b, s)), 1))
            }
            return 2 * acos(best)
        }
        for r in 0..<h {
            if isCancelled() { return nil }
            for c in 0..<w {
                let i = r * w + c
                if c + 1 < w {
                    let a = angle(i, i + 1)
                    ax[i] = a
                    px[i] = phase[i] != phase[i + 1]
                    gx[i] = a > tol || px[i]
                }
                if r + 1 < h {
                    let a = angle(i, i + w)
                    ay[i] = a
                    py[i] = phase[i] != phase[i + w]
                    gy[i] = a > tol || py[i]
                }
            }
        }
        return GrainBoundaries(rows: h, columns: w, threshold: tol, angleX: ax, angleY: ay, grainX: gx, grainY: gy, phaseX: px, phaseY: py)
    }
}

/// One grain: its points (row × columns + column) in DefDAP's flood order and its phase.
package nonisolated struct Grain: Sendable, Equatable, Identifiable {
    /// The grain's index from 0 (its number in the grain map is id + 1).
    package let id: Int
    package let points: [Int]
    /// DefDAP's `phase_id`: the phase index from 0; nil when the points do not share one phase or are not indexed.
    package let phaseIndex: Int?
    package var size: Int { points.count }
}

/// A pair of neighbouring grains (`a` < `b`, ids from 0) and how many boundary points of each kind they share.
package nonisolated struct GrainNeighbour: Sendable, Equatable, Hashable {
    package let a: Int
    package let b: Int
    /// Boundary points on a horizontal step (right neighbour) and on a vertical step (neighbour below).
    package let pointsX: Int
    package let pointsY: Int
}

/// DefDAP's `find_grains` result: the grain map and the grains.
package nonisolated struct GrainSegmentation: Sendable, Equatable {
    package let rows: Int
    package let columns: Int
    package let step: Double
    /// DefDAP's grain map: 1, 2, ... a grain's number; −2 a point of a region below the minimum size; 0 a point never
    /// filled (not indexed).
    package let grainMap: [Int]
    package let grains: [Grain]
    package let minimumSize: Int

    /// `find_grains(min_grain_size)` on boundaries found in `map`.
    package static func find(in map: GrainMap, boundaries: GrainBoundaries, minimumSize: Int = 10) -> GrainSegmentation {
        // Never nil: nothing cancels it.
        find(in: map, boundaries: boundaries, minimumSize: minimumSize, isCancelled: { false })!
    }

    /// The same, asking `isCancelled` before each flood fill: nil once it says so (the Maps room's Stop, `GrainAnalysis.run`).
    package static func find(in map: GrainMap, boundaries: GrainBoundaries, minimumSize: Int, isCancelled: () -> Bool) -> GrainSegmentation? {
        let (h, w) = (map.rows, map.columns)
        var grains = [Int](repeating: 0, count: h * w)
        var left = map.phase.map { $0 != 0 }
        var list: [Grain] = []
        var index = 1
        var buffer: [Int] = []
        var stack: [(Int, Int)] = []
        var next = left.firstIndex(of: true) ?? -1
        while next >= 0 {
            if isCancelled() { return nil }
            // `flood_fill((x, y), index, ...)` from the seed.
            buffer.removeAll(keepingCapacity: true)
            let (sy, sx) = (next / w, next % w)
            grains[next] = index
            left[next] = false
            buffer.append(next)
            stack.append((sx, sy))
            while let top = stack.popLast() {
                let (x, y) = top
                var moves = [(x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)]
                if x <= 0 { moves.remove(at: 1) } else if x > w - 2 { moves.remove(at: 0) }
                if y <= 0 { moves.removeLast() } else if y > h - 2 { moves.remove(at: moves.count - 2) }
                for (s, t) in moves {
                    guard s >= 0, s < w, t >= 0, t < h else { continue }
                    let j = t * w + s
                    if grains[j] > 0 { continue }
                    let add: Bool
                    if t == y {
                        add = s > x ? !boundaries.grainX[y * w + x] : !boundaries.grainX[j]
                    } else {
                        add = t > y ? !boundaries.grainY[y * w + x] : !boundaries.grainY[j]
                    }
                    if add {
                        buffer.append(j)
                        grains[j] = index
                        left[j] = false
                        stack.append((s, t))
                    }
                }
            }
            if buffer.count < minimumSize {
                for j in buffer { grains[j] = -2 }
            } else {
                let phases = buffer.map { map.phase[$0] }
                let lo = phases.min() ?? 0, hi = phases.max() ?? 0
                let p = (lo == hi && lo >= 1 && lo <= map.symmetries.count) ? lo - 1 : nil
                list.append(Grain(id: index - 1, points: buffer, phaseIndex: p))
                index += 1
            }
            var found = -1
            var k = next + 1
            while k < left.count { if left[k] { found = k; break }; k += 1 }
            next = found
        }
        return GrainSegmentation(rows: h, columns: w, step: map.step, grainMap: grains, grains: list, minimumSize: minimumSize)
    }

    // MARK: Sizes

    /// Points per grain.
    package var sizes: [Int] { grains.map(\.size) }
    /// Area per grain: points × step² (square grid), in the scan unit squared.
    package var areas: [Double] { grains.map { Double($0.size) * step * step } }
    /// The diameter of the circle of the grain's area.
    package var equivalentCircleDiameters: [Double] { areas.map { 2 * ($0 / .pi).squareRoot() } }

    // MARK: Neighbour network

    /// DefDAP's `build_neighbour_network`: for every grain boundary point not on the map's outer pixels, the grain of the
    /// point and of its right (x) or lower (y) neighbour; pairs of two different grains (no −2, no 0) with their point
    /// counts, sorted by (a, b).
    package func neighbourNetwork(boundaries: GrainBoundaries) -> [GrainNeighbour] {
        let (h, w) = (rows, columns)
        var counts: [Int: (x: Int, y: Int)] = [:]
        for kind in 0..<2 {
            let image = kind == 0 ? boundaries.grainX : boundaries.grainY
            for i in image.indices where image[i] {
                let (y, x) = (i / w, i % w)
                if x == 0 || y == 0 || x == w - 1 || y == h - 1 { continue }
                let g = grainMap[i] - 1
                let n = grainMap[(y + kind) * w + (x - kind + 1)] - 1
                if g == n || g < 0 || n < 0 { continue }
                let key = min(g, n) * (grains.count + 1) + max(g, n)
                var c = counts[key] ?? (0, 0)
                if kind == 0 { c.x += 1 } else { c.y += 1 }
                counts[key] = c
            }
        }
        return counts.map { key, c in
            GrainNeighbour(a: key / (grains.count + 1), b: key % (grains.count + 1), pointsX: c.x, pointsY: c.y)
        }.sorted { ($0.a, $0.b) < ($1.a, $1.b) }
    }

    // MARK: ASTM E112

    /// The mean lineal intercept (Heyn): the length of every row and column as test lines over the number of grain
    /// boundary crossings on them, in the scan unit; nil without a crossing.
    package static func meanLinealIntercept(boundaries: GrainBoundaries, step: Double) -> Double? {
        let crossings = boundaries.grainX.reduce(0) { $0 + ($1 ? 1 : 0) } + boundaries.grainY.reduce(0) { $0 + ($1 ? 1 : 0) }
        guard crossings > 0 else { return nil }
        let (h, w) = (Double(boundaries.rows), Double(boundaries.columns))
        let length = h * (w - 1) * step + w * (h - 1) * step
        return length / Double(crossings)
    }

    /// ASTM E112-13's grain size number from the mean lineal intercept in millimetres: G = −6.643856 log10(ℓ) − 3.288.
    package static func astmGrainSizeNumber(meanLinealInterceptMillimetres l: Double) -> Double {
        -6.643856 * log10(l) - 3.288
    }
}
