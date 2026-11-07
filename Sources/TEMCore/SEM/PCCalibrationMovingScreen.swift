//
//  PCCalibrationMovingScreen.swift
//  Role: the projection centre from two patterns taken with a stationary beam at two detector distances a known Δz apart,
//        the "moving screen" technique of Hjelen et al. (1991), Electron diffraction in the SEM, Micron Microsc. Acta 22, 137.
//        The same features (zone axes) are marked in both patterns; the line through each pair of marks (out → in) passes
//        through the point that does not move, (PCx, PCy), so every two such lines give one estimate where they cross. The
//        detector distance follows from how much the distance between two features grows: DD = Δz / (L_out / L_in − 1).
//        Ported from kikuchipy 0.13.1 (`detectors/_calibration.py`, `PCCalibrationMovingScreen`; GPL-3.0-or-later): the
//        estimates, the on-detector filter, the averages, and the spread of the estimates as the uncertainty (the tutorial's).
//        Parity bundle `m2/pc-moving-screen-si` (figure F5); row in docs/parity.md.
//

import Foundation

package nonisolated struct PCCalibrationMovingScreen: Sendable, Equatable {
    /// Detector rows and columns (the patterns' shape).
    package var rows: Int
    package var columns: Int
    /// Feature positions (x, y) in pixels in the pattern at the short distance ("in") and the long one ("out"), same order.
    package var pointsIn: [SIMD2<Double>]
    package var pointsOut: [SIMD2<Double>]
    /// The camera travel between the two patterns. PCz comes out in this unit unless `pixelSize` is given.
    package var deltaZ: Double
    /// The unbinned detector pixel size in the unit of `deltaZ`; with it PCz is a fraction of the detector height.
    package var pixelSize: Double?
    package var binning: Int
    /// `.tsl` gives PCy from the bottom (kikuchipy's default); any other convention gives it from the top, as Bruker.
    package var convention: EBSDDetectorGeometry.Convention

    package init(rows: Int, columns: Int, pointsIn: [SIMD2<Double>], pointsOut: [SIMD2<Double>], deltaZ: Double = 1,
                 pixelSize: Double? = nil, binning: Int = 1, convention: EBSDDetectorGeometry.Convention = .tsl) {
        precondition(pointsIn.count == pointsOut.count, "the same features in both patterns")
        self.rows = rows; self.columns = columns; self.pointsIn = pointsIn; self.pointsOut = pointsOut
        self.deltaZ = deltaZ; self.pixelSize = pixelSize; self.binning = binning; self.convention = convention
    }

    /// Every pair (i, j), i < j, in `itertools.combinations` order: the lines within each pattern and the pairs of out → in
    /// lines that are intersected.
    package var pairs: [(Int, Int)] {
        var out: [(Int, Int)] = []
        for i in 0..<pointsIn.count { for j in (i + 1)..<pointsIn.count { out.append((i, j)) } }
        return out
    }

    /// Length of the line between features i and j of each pair, in the in and the out pattern (`line_lengths`).
    package var lineLengths: (inner: [Double], outer: [Double]) {
        let p = pairs
        return (p.map { Self.length(pointsIn[$0.0], pointsIn[$0.1]) }, p.map { Self.length(pointsOut[$0.0], pointsOut[$0.1]) })
    }

    /// Where the out → in lines of each pair cross, in pixels (x, y), for every pair (`_pxy_all`).
    package var intersectionsOfAllPairs: [SIMD2<Double>] {
        pairs.map { Self.intersection(pointsOut[$0.0], pointsIn[$0.0], pointsOut[$0.1], pointsIn[$0.1]) }
    }

    /// Whether each pair's crossing lies strictly inside the detector (`pxy_within_detector`).
    package var withinDetector: [Bool] {
        intersectionsOfAllPairs.map { $0.x > 0 && $0.x < Double(columns) && $0.y > 0 && $0.y < Double(rows) }
    }

    /// The crossings inside the detector (`pxy_all`), and their mean (`pxy`).
    package var pixelEstimates: [SIMD2<Double>] { zip(intersectionsOfAllPairs, withinDetector).filter { $0.1 }.map { $0.0 } }
    package var pixelCenter: SIMD2<Double> {
        let e = pixelEstimates
        return SIMD2(Self.nanMean(e.map(\.x)), Self.nanMean(e.map(\.y)))
    }

    /// One PC estimate per pair whose crossing is inside the detector (`pc_all`): x over the width, y over the height (from
    /// the bottom in TSL), z the detector distance in the unit of Δz, or over the detector height when the pixel size is known.
    package var estimates: [SIMD3<Double>] {
        let crossings = intersectionsOfAllPairs, inside = withinDetector, lengths = lineLengths
        var out: [SIMD3<Double>] = []
        for k in crossings.indices where inside[k] {
            let x = crossings[k].x / Double(columns)
            var y = crossings[k].y / Double(rows)
            if convention == .tsl { y = 1 - y }
            var z = deltaZ / ((lengths.outer[k] / lengths.inner[k]) - 1)
            if let pixelSize { z /= Double(rows) * pixelSize * Double(binning) }
            out.append(SIMD3(x, y, z))
        }
        return out
    }

    /// The average of the estimates (`pc`), NaN-skipping as numpy's `nanmean`.
    package var center: SIMD3<Double> {
        let e = estimates
        return SIMD3(Self.nanMean(e.map(\.x)), Self.nanMean(e.map(\.y)), Self.nanMean(e.map(\.z)))
    }

    /// The population standard deviation of the estimates per coordinate (numpy's `std`, ddof 0): the uncertainty the
    /// kikuchipy tutorial draws as ± 2 σ around the centre.
    package var standardDeviation: SIMD3<Double> {
        let e = estimates
        return SIMD3(Self.std(e.map(\.x)), Self.std(e.map(\.y)), Self.std(e.map(\.z)))
    }

    // MARK: Geometry

    static func length(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double {
        let d = a - b
        return (d.x * d.x + d.y * d.y).squareRoot()
    }

    /// The crossing of the line through p1, p2 with the line through p3, p4 (kikuchipy's `_get_intersection_from_lines`,
    /// the determinant form of two-point lines).
    static func intersection(_ p1: SIMD2<Double>, _ p2: SIMD2<Double>, _ p3: SIMD2<Double>, _ p4: SIMD2<Double>) -> SIMD2<Double> {
        func det(_ a: Double, _ b: Double, _ c: Double, _ d: Double) -> Double { a * d - b * c }
        let d1 = det(p1.x, p1.y, p2.x, p2.y), d2 = det(p3.x, p3.y, p4.x, p4.y)
        let d3 = det(p1.x, 1, p2.x, 1), d4 = det(p3.x, 1, p4.x, 1)
        let d5 = det(p1.y, 1, p2.y, 1), d6 = det(p3.y, 1, p4.y, 1)
        let denominator = det(d3, d5, d4, d6)
        return SIMD2(det(d1, d3, d2, d4) / denominator, det(d1, d5, d2, d6) / denominator)
    }

    static func nanMean(_ values: [Double]) -> Double {
        let finite = values.filter { !$0.isNaN }
        return finite.isEmpty ? .nan : finite.reduce(0, +) / Double(finite.count)
    }

    static func std(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return .nan }
        let mean = values.reduce(0, +) / Double(values.count)
        return (values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(values.count)).squareRoot()
    }
}
