//
//  IndexingComparison.swift
//  Two indexing results of one scan compared point by point (the Indexing room's Compare, #230, D-SEM-97): the disorientation angle
//  between A's and B's orientation at every point both index as paired phases, as orix 0.15.0's `Orientation.angle_with` computes it
//  (the smallest angle over the symmetry elements of both point groups; for one group the same number as `Misorientation.angle` of
//  `A - B`; Grimmer 1974, Morawiec 2004), its histogram on whole-degree bins as `numpy.histogram` bins it, `numpy.median` and the
//  fraction over 2° as `numpy.mean(angle > 2)`. GPL-3.0 (orix is GPL-3.0-or-later), see NOTICE.
//
//  What is compared: a point is left out when A or B did not reach it, did not index it, or indexed it as a phase without a point
//  group, and when A's and B's phases there do not pair. Phases pair when each side lists one phase and their Laue classes agree (as
//  kikuchipy compares two single-phase maps with `angle_with`, naming nothing), else when their names are equal within one Laue
//  class. The phase index is the only mask: a Hough point that is not indexed carries the quaternion (0, 0, 0, 0), which
//  `angle_with` would turn into 0°, so it never reaches the angle. The bins run from 0° to the first whole degree above the largest
//  disorientation of the compared groups' proper subgroups (orix's `OrientationRegion.from_symmetry(G, G)` vertices; 62.80° for 432,
//  Mackenzie 1958), so the edges depend on the crystal, not on the data.
//
//  Parity: `tools/parity/sem` bundles `m4/indexing-compare-planted` (two phases a side, unpaired and groupless phases, Σ3, points
//  not indexed) and `m4/indexing-compare-nickel-large` (Hough, the 4° dictionary and the file's indexing of the demo scan), docs/parity.md.
//

import Foundation

package nonisolated struct IndexingComparison: Sendable {
    package enum Refusal: Error, Equatable, Sendable, LocalizedError {
        /// A and B are not of one scan: their point counts differ.
        case differentScans

        package var errorDescription: String? { "The two results are not of one scan." }
    }

    /// Why a point is compared or left out, in the order the rule asks.
    package enum Outcome: UInt8, Sendable, CaseIterable {
        case compared = 0
        /// A did not reach or index the point, or its phase has no point group.
        case noneInA = 1
        /// B likewise.
        case noneInB = 2
        /// A's and B's phases at the point do not pair.
        case unpairedPhases = 3
    }

    /// One result on the scan's grid: its phases, and per point (row-major) the phase index and the rotation.
    package struct Side: Sendable, Equatable {
        package struct Phase: Sendable, Equatable {
            package var name: String
            package var pointGroupName: String?

            package init(name: String, pointGroupName: String?) {
                self.name = name
                self.pointGroupName = pointGroupName
            }

            package var pointGroup: PointGroup? { pointGroupName.flatMap(PointGroup.named) }
            /// orix's Laue group name of the point group; nil without one.
            package var laueName: String? { pointGroup == nil ? nil : PointGroup.laueName(pointGroupName) }
        }

        package var phases: [Phase]
        /// Per scan point, row-major: the index into `phases`, −1 where the point is not reached, not in data or not indexed.
        package var phaseIndices: [Int]
        /// Per scan point: the unit quaternion (lab to crystal, orix's), the identity where the phase index is −1.
        package var rotations: [SIMD4<Double>]

        package init(phases: [Phase], phaseIndices: [Int], rotations: [SIMD4<Double>]) {
            precondition(phaseIndices.count == rotations.count, "one rotation per point")
            self.phases = phases
            self.phaseIndices = phaseIndices
            self.rotations = rotations
        }

        /// An Indexing room run: its phases (the ones it indexed against), each landed solution's phase and quaternion; a point not
        /// reached, not indexed, or with a quaternion that is not a finite, non-zero rotation is −1.
        package init(_ result: IndexingResult) {
            let phases = result.phases.map { Phase(name: $0.name, pointGroupName: $0.pointGroupName) }
            var indices = [Int](repeating: -1, count: result.pointCount)
            var rotations = [SIMD4<Double>](repeating: Self.identity, count: result.pointCount)
            for (i, solution) in result.solutions.enumerated() {
                guard let solution, phases.indices.contains(solution.phase), Self.isRotation(solution.quaternion) else { continue }
                indices[i] = solution.phase
                rotations[i] = solution.quaternion
            }
            self.init(phases: phases, phaseIndices: indices, rotations: rotations)
        }

        /// A crystal map laid on a scan of `scanRows` × `scanColumns` (the file's indexing): each grid cell takes the point the map
        /// puts there (`OrientationMaps.pointIndexGrid`); a cell with no point in data, a `not_indexed` point or a rotation that is
        /// not a finite, non-zero quaternion is −1. The phases are the map's indexed phases in id order. nil when the map's grid is
        /// not the scan's.
        package init?(_ map: CrystalMap, scanRows: Int, scanColumns: Int) {
            let shape = OrientationMaps.gridShape(map)
            guard shape.rows == scanRows, shape.columns == scanColumns else { return nil }
            let entries = map.phases.entries.filter { $0.id != PhaseList.notIndexedID && $0.phase.name != PhaseList.notIndexedName }
            var indexOfID: [Int: Int] = [:]
            for (index, entry) in entries.enumerated() { indexOfID[entry.id] = index }
            let grid = OrientationMaps.pointIndexGrid(map)
            var indices = [Int](repeating: -1, count: grid.count)
            var rotations = [SIMD4<Double>](repeating: Self.identity, count: grid.count)
            for (k, g) in grid.enumerated() where g >= 0 {
                guard let index = indexOfID[map.allPhaseIDs[g]], Self.isRotation(map.rotations[g]) else { continue }
                indices[k] = index
                rotations[k] = map.rotations[g]
            }
            self.init(phases: entries.map { Phase(name: $0.phase.name, pointGroupName: $0.phase.pointGroupName) },
                      phaseIndices: indices, rotations: rotations)
        }

        package var pointCount: Int { phaseIndices.count }

        /// Bunge Euler angles (φ₁, Φ, φ₂) in degrees of the point's orientation; nil where the side has none.
        package func eulerDegrees(at i: Int) -> SIMD3<Double>? {
            guard phaseIndices.indices.contains(i), phaseIndices[i] >= 0 else { return nil }
            return Rotation(unit: rotations[i]).euler * (180 / Double.pi)
        }

        /// The name of the point's phase; nil where the side has none.
        package func phaseName(at i: Int) -> String? {
            guard phaseIndices.indices.contains(i), phaseIndices[i] >= 0 else { return nil }
            return phases[phaseIndices[i]].name
        }

        static let identity = SIMD4<Double>(1, 0, 0, 0)

        static func isRotation(_ q: SIMD4<Double>) -> Bool {
            q.x.isFinite && q.y.isFinite && q.z.isFinite && q.w.isFinite && (q * q).sum() > 0
        }
    }

    /// The fraction's threshold and the bins' width, degrees.
    package static let thresholdDegrees = 2.0
    package static let binWidthDegrees = 1.0

    package let a: Side
    package let b: Side
    /// A's phase index → B's phase index of the phases that pair.
    package let pairs: [Int: Int]
    /// Per scan point.
    package let outcomes: [Outcome]
    /// Per scan point, radians; NaN where the point is not compared.
    package let angles: [Double]
    package let comparedCount: Int
    /// The compared angles in degrees on `edges(top:)`; nil when nothing is compared.
    package let histogram: AngleHistogram?
    package let medianDegrees: Double?
    package let fractionOverThreshold: Double?

    /// Compares `a` with `b`; throws `differentScans` when their point counts differ.
    package init(_ a: Side, _ b: Side) throws {
        guard a.pointCount == b.pointCount else { throw Refusal.differentScans }
        self.a = a
        self.b = b
        let pairs = Self.pairing(a.phases, b.phases)
        self.pairs = pairs
        let groupsA = a.phases.map(\.pointGroup), groupsB = b.phases.map(\.pointGroup)
        var outcomes = [Outcome](repeating: .compared, count: a.pointCount)
        // The compared points by their pair of phases, each pair's orientations compared in one call.
        var byPair: [PhasePair: [Int]] = [:]
        for i in 0..<a.pointCount {
            let pa = a.phaseIndices[i], pb = b.phaseIndices[i]
            if pa < 0 || groupsA[pa] == nil {
                outcomes[i] = .noneInA
            } else if pb < 0 || groupsB[pb] == nil {
                outcomes[i] = .noneInB
            } else if pairs[pa] == pb {
                byPair[PhasePair(a: pa, b: pb), default: []].append(i)
            } else {
                outcomes[i] = .unpairedPhases
            }
        }
        var angles = [Double](repeating: .nan, count: a.pointCount)
        var top = 0
        for (pair, points) in byPair {
            guard let ga = groupsA[pair.a], let gb = groupsB[pair.b] else { continue }
            let found = Orientations(quaternions: points.map { a.rotations[$0] }, symmetry: ga)
                .angles(with: Orientations(quaternions: points.map { b.rotations[$0] }, symmetry: gb))
            for (point, angle) in zip(points, found) { angles[point] = angle }
            top = max(top, ga.disorientationBinsTop, gb.disorientationBinsTop)
        }
        self.outcomes = outcomes
        self.angles = angles
        let compared = angles.filter(\.isFinite).map { Self.degrees($0) }
        comparedCount = compared.count
        histogram = compared.isEmpty ? nil : AngleHistogram(values: compared, edges: Self.edges(top: top))
        medianDegrees = Self.median(compared)
        fractionOverThreshold = Self.fraction(over: Self.thresholdDegrees, of: compared)
    }

    /// The points with `outcome`.
    package func count(_ outcome: Outcome) -> Int { outcomes.reduce(0) { $0 + ($1 == outcome ? 1 : 0) } }

    /// The point's disorientation in degrees; nil where it is not compared.
    package func degrees(at i: Int) -> Double? {
        guard angles.indices.contains(i), angles[i].isFinite else { return nil }
        return Self.degrees(angles[i])
    }

    // MARK: - The rule and numpy's statistics

    /// Which of A's phases pair with which of B's (D-SEM-97): one phase a side pairs when the Laue classes agree; else by equal
    /// name within one Laue class, each of A's phases with the first such phase of B. A phase without a point group pairs with none.
    package static func pairing(_ a: [Side.Phase], _ b: [Side.Phase]) -> [Int: Int] {
        if a.count == 1, b.count == 1 {
            guard let laue = a[0].laueName, laue == b[0].laueName else { return [:] }
            return [0: 0]
        }
        var out: [Int: Int] = [:]
        for (i, phase) in a.enumerated() {
            guard let laue = phase.laueName else { continue }
            if let j = b.firstIndex(where: { $0.name == phase.name && $0.laueName == laue }) { out[i] = j }
        }
        return out
    }

    /// numpy's `rad2deg`: `x * (180 / π)`.
    package static func degrees(_ radians: Double) -> Double { radians * (180 / Double.pi) }

    /// numpy's `median`: the middle value of the sorted values, the mean of the two middle ones for an even count; nil for none.
    package static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let n = sorted.count
        return n % 2 == 1 ? sorted[n / 2] : (sorted[n / 2 - 1] + sorted[n / 2]) / 2
    }

    /// numpy's `mean(values > threshold)`: the share strictly over `threshold`; nil for none.
    package static func fraction(over threshold: Double, of values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return Double(values.reduce(0) { $0 + ($1 > threshold ? 1 : 0) }) / Double(values.count)
    }

    /// `numpy.arange(0., top + 1)`: whole degrees from 0 to `top`.
    package static func edges(top: Int) -> [Double] { (0...max(top, 1)).map(Double.init) }

    private struct PhasePair: Hashable {
        var a: Int
        var b: Int
    }
}

extension PointGroup {
    /// The first whole degree above the largest disorientation angle of the group's proper subgroup, the top of the Compare
    /// histogram (orix 0.15.0: the largest angle of `OrientationRegion.from_symmetry(G, G).vertices()`; 62.80° for 432, Mackenzie
    /// 1958; 93.84° for 622, 98.42° for 422, 104.48° for 32, 90° for 23, 120° for 222, 180° for a cyclic group).
    package var disorientationBinsTop: Int {
        switch properSubgroup.name ?? "" {
        case "432": 63
        case "23": 91
        case "622": 94
        case "422": 99
        case "32", "321", "312": 105
        case "222": 121
        default: 181
        }
    }
}
