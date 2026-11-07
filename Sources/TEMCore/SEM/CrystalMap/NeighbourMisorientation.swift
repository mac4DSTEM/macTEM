//
//  NeighbourMisorientation.swift
//  The misorientation between neighbouring points of a crystal map and the histogram of its angles (figure F7), as orix's
//  orientation tutorials compute it: on the map's grid, every horizontal pair (r, c)–(r, c + 1) and every vertical pair
//  (r, c)–(r + 1, c), `O[:, 1:] - O[:, :-1]` and `O[1:, :] - O[:-1, :]` (orix's `Orientation.__sub__`: the misorientation
//  right · left⁻¹ reduced into the fundamental zone of the two point groups), its angle the disorientation angle; the angles
//  binned as `numpy.histogram` bins them. GPL-3.0 (orix is GPL-3.0-or-later), see NOTICE.
//
//  Parity: `tools/parity/sem` bundles `m3/ti-neighbour-misorientations` (a committed 3 × 507 map: angles atol 1e-7 rad,
//  counts exact) and `m3/ti-neighbour-misorientations-full` (orix-data's 381 × 507 Ti map: counts and edges exact), docs/parity.md.
//

import Foundation

package nonisolated enum NeighbourMisorientation {
    /// The misorientations of horizontal then vertical neighbours, each flattened row-major as numpy flattens `O[:, 1:] -
    /// O[:, :-1]` and `O[1:, :] - O[:-1, :]`. The points in data must fill their rectangle and hold one phase; a 1D map has
    /// only horizontal pairs.
    package static func misorientations(of map: CrystalMap) throws -> (horizontal: Misorientations, vertical: Misorientations) {
        let orientations = try map.orientations()
        let shape = map.shape
        let (rows, columns) = shape.count == 2 ? (shape[0], shape[1]) : (1, shape.first ?? orientations.count)
        guard rows * columns == orientations.count else { throw CrystalMap.Refusal.notARectangle(shape: shape, points: orientations.count) }
        let q = orientations.quaternions
        var hRight: [SIMD4<Double>] = [], hLeft: [SIMD4<Double>] = []
        hRight.reserveCapacity(rows * max(columns - 1, 0)); hLeft.reserveCapacity(rows * max(columns - 1, 0))
        for r in 0..<rows where columns > 1 {
            for c in 0..<(columns - 1) {
                hRight.append(q[r * columns + c + 1])
                hLeft.append(q[r * columns + c])
            }
        }
        var vBelow: [SIMD4<Double>] = [], vAbove: [SIMD4<Double>] = []
        vBelow.reserveCapacity(max(rows - 1, 0) * columns); vAbove.reserveCapacity(max(rows - 1, 0) * columns)
        for r in 0..<max(rows - 1, 0) {
            for c in 0..<columns {
                vBelow.append(q[(r + 1) * columns + c])
                vAbove.append(q[r * columns + c])
            }
        }
        let g = orientations.symmetry
        let horizontal = try Orientations(quaternions: hRight, symmetry: g).misorientations(from: Orientations(quaternions: hLeft, symmetry: g))
        let vertical = try Orientations(quaternions: vBelow, symmetry: g).misorientations(from: Orientations(quaternions: vAbove, symmetry: g))
        return (horizontal, vertical)
    }

    /// The disorientation angles in degrees, horizontal pairs then vertical pairs.
    package static func anglesDegrees(of map: CrystalMap) throws -> [Double] {
        let (h, v) = try misorientations(of: map)
        return (h.angles + v.angles).map { $0 * 180 / .pi }
    }

    /// F7's bins: 1° wide from 0° to 94°, the first whole degree above the largest disorientation of 622 (93.84°).
    package static let f7Edges: [Double] = (0...94).map(Double.init)
}

/// `numpy.histogram(values, bins=edges)`: counts in [e_i, e_i+1), the last bin closed; values outside the edges (and NaN) are
/// not counted.
package nonisolated struct AngleHistogram: Sendable, Equatable {
    package var edges: [Double]
    package var counts: [Int]

    package init(values: [Double], edges: [Double]) {
        precondition(edges.count >= 2, "a histogram needs two edges")
        self.edges = edges
        var counts = Array(repeating: 0, count: edges.count - 1)
        let first = edges[0], last = edges[edges.count - 1]
        for v in values where v >= first && v <= last {
            // The last edge not above v (binary search), the closed last bin taking v == last.
            var lo = 0, hi = edges.count - 1
            while hi - lo > 1 {
                let mid = (lo + hi) / 2
                if edges[mid] <= v { lo = mid } else { hi = mid }
            }
            counts[lo] += 1
        }
        self.counts = counts
    }
}
