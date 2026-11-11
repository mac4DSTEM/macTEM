//
//  PoleDensityFunction.swift
//  orix 0.15.0's `orix.measure.pole_density_function` (GPL-3.0-or-later, see NOTICE) and the equal-area grid it bins on,
//  `orix.sampling.S2_sampling._sample_S2_equal_area_coordinates` (Rohrer, Saylor, El-Dasher, Adams, Rollett and
//  Wynblatt 2004, Z. Metallkd. 95, 197): the vectors' azimuth and polar angles counted on the grid (numpy's
//  `histogram2d`), smoothed by scipy's `ndimage.gaussian_filter` (sigma / resolution bins, truncate 4, `wrap` in azimuth and
//  `reflect` in polar), folded into a point group's fundamental sector when one is given (counted at half the resolution,
//  the bin centres moved into the sector and summed onto the full-resolution grid, the bins outside the sector masked), and
//  given in multiples of a random distribution (the mean unmasked bin is 1). A sigma not above 1e-15 bins smooths nothing, as
//  scipy skips such an axis; the kernel is capped (`maximumKernelRadius`), where scipy raises on +∞ and on a sigma whose
//  kernel it cannot allocate (docs/parity.md).
//
//  A vector within about 1e-12 rad of a bin edge goes to either neighbour depending on the last bit of atan2 and arccos,
//  which differ between libms; the parity bundles count those vectors and the tests allow each one bin (D-SEM-68).
//
//  Parity: `tools/parity/sem` bundles `m5/texture-ti`, `m5/texture-cubic`, `m5/texture-ti-full` (figure F13): counts exact up
//  to those edge vectors, densities atol 1e-7 (docs/parity.md).
//

import Foundation

/// orix's equal-area sampling of the sphere in (azimuth, polar) bin edges: `4D` azimuth steps over 2π and `D` steps of
/// equal cos(polar) over a hemisphere, D = ceil(90 / resolution).
package nonisolated struct EqualAreaGrid: Sendable, Equatable {
    package enum Hemisphere: String, Sendable {
        case upper, lower

        /// The stereographic pole that draws this hemisphere (orix's `{"upper": -1, "lower": 1}`).
        package var pole: Int { self == .upper ? -1 : 1 }
    }

    /// Bin edges in radians, increasing; azimuth from 0 to 2π (endpoint included), polar from the hemisphere's pole side.
    package let azimuthEdges: [Double]
    package let polarEdges: [Double]
    package let hemisphere: Hemisphere
    package let resolution: Double

    package var azimuthBins: Int { azimuthEdges.count - 1 }
    package var polarBins: Int { polarEdges.count - 1 }
    package var binCount: Int { azimuthBins * polarBins }

    /// `_sample_S2_equal_area_coordinates(resolution, hemisphere, azimuth_endpoint=True)`, resolution in degrees.
    package init(resolution: Double, hemisphere: Hemisphere = .upper) {
        precondition(resolution > 0 && resolution.isFinite, "the grid's resolution is a positive number of degrees")
        self.resolution = resolution
        self.hemisphere = hemisphere
        let steps = Int((90 / resolution).rounded(.up))
        let azimuthNum = Int((2 * Double.pi / (Double.pi / 2) * Double(steps)).rounded(.up)) + 1
        let (polarMin, polarMax): (Double, Double) = hemisphere == .upper ? (1, 0) : (0, -1)
        let polarNum = Int(((polarMin - polarMax) * Double(steps)).rounded(.up)) + 1
        azimuthEdges = Vector3.linspace(0, 2 * Double.pi, azimuthNum)
        polarEdges = Vector3.linspace(polarMin, polarMax, polarNum).map { acos($0) }
    }

    /// `Vector3d.to_polar`'s azimuth and polar angle of a vector.
    package static func angles(_ v: SIMD3<Double>) -> (azimuth: Double, polar: Double) {
        (Vector3.azimuth(v), Vector3.polar(v))
    }

    /// numpy's `histogramdd` bin of one coordinate: `searchsorted(edges, x, side="right")`, a value on the last edge put in
    /// the last bin, nil outside [first edge, last edge] (and for NaN).
    package static func bin(_ x: Double, edges: [Double]) -> Int? {
        guard let last = edges.last, x >= edges[0], x <= last else { return nil }
        if x == last { return edges.count - 2 }
        var lo = 0, hi = edges.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if edges[mid] <= x { lo = mid + 1 } else { hi = mid }
        }
        return lo - 1
    }

    /// The flat bin (azimuth-major) of a vector, nil when it is not on this grid's hemisphere.
    package func bin(of v: SIMD3<Double>) -> Int? {
        let (a, p) = EqualAreaGrid.angles(v)
        guard let i = EqualAreaGrid.bin(a, edges: azimuthEdges), let j = EqualAreaGrid.bin(p, edges: polarEdges) else { return nil }
        return i * polarBins + j
    }

    /// The bin centres as vectors (azimuth and polar each halfway between edges, `Vector3d.from_polar(...).unit`),
    /// azimuth-major.
    package var centerVectors: [SIMD3<Double>] {
        var out: [SIMD3<Double>] = []
        out.reserveCapacity(binCount)
        for i in 0..<azimuthBins {
            let a = azimuthEdges[i] + (azimuthEdges[i + 1] - azimuthEdges[i]) / 2
            for j in 0..<polarBins {
                let p = polarEdges[j] + (polarEdges[j + 1] - polarEdges[j]) / 2
                out.append(Vector3.unit(Vector3.fromPolar(azimuth: a, polar: p)))
            }
        }
        return out
    }

    /// The bin-edge nodes in the stereographic plane of this hemisphere, (azimuthBins + 1) x (polarBins + 1), azimuth-major
    /// (the x and y orix returns beside the histogram for `pcolormesh`).
    package var stereographicNodes: (x: [Double], y: [Double]) {
        var x: [Double] = [], y: [Double] = []
        x.reserveCapacity(azimuthEdges.count * polarEdges.count)
        y.reserveCapacity(azimuthEdges.count * polarEdges.count)
        for a in azimuthEdges {
            for p in polarEdges {
                let xy = StereographicProjection.project(Vector3.fromPolar(azimuth: a, polar: p), pole: hemisphere.pole)
                x.append(xy.x)
                y.append(xy.y)
            }
        }
        return (x, y)
    }
}

/// A pole density on an equal-area grid: azimuth-major values (bin (i, j) at i * polarBins + j), the bins outside the
/// fundamental sector masked (an inverse pole figure), and the stereographic nodes of the bin edges.
package nonisolated struct PoleDensityMap: Sendable {
    package let grid: EqualAreaGrid
    /// Multiples of random distribution (or counts with `mrd: false`, or log(value + 1) with `log: true`).
    package var values: [Double]
    /// true where orix masks the bin (outside the sector); all false without a symmetry.
    package let mask: [Bool]
    /// The symmetry whose sector the map was folded into, nil for a pole figure on a hemisphere.
    package let symmetry: PointGroup?

    /// The largest unmasked value (the top of the colour bar).
    package var maximum: Double { zip(values, mask).filter { !$0.1 }.map(\.0).max() ?? 0 }

    /// The value of the bin a vector falls in, nil outside the hemisphere or in a masked bin.
    package func value(at v: SIMD3<Double>) -> Double? {
        guard let k = grid.bin(of: v), !mask[k] else { return nil }
        return values[k]
    }
}

package nonisolated enum PoleDensityFunction {
    /// The histogram `pole_density_function` smooths, at its working resolution (half the requested one with a symmetry),
    /// of the vectors (moved into the symmetry's sector first when one is given). Counts as Double (weights may be
    /// fractional), azimuth-major.
    package static func counts(_ vectors: [SIMD3<Double>], resolution: Double = 1, weights: [Double]? = nil,
                               hemisphere: EqualAreaGrid.Hemisphere = .upper,
                               symmetry: PointGroup? = nil) -> (counts: [Double], grid: EqualAreaGrid) {
        precondition(weights == nil || weights?.count == vectors.count, "one weight per vector")
        let v = symmetry.map { $0.projectToFundamentalSector(vectors) } ?? vectors
        let grid = EqualAreaGrid(resolution: symmetry == nil ? resolution : resolution / 2, hemisphere: hemisphere)
        var h = [Double](repeating: 0, count: grid.binCount)
        for (n, x) in v.enumerated() {
            if let k = grid.bin(of: x) { h[k] += weights?[n] ?? 1 }
        }
        return (h, grid)
    }

    /// `pole_density_function(vectors, resolution, sigma, weights, hemisphere, symmetry, log, mrd)`; degrees.
    package static func compute(_ vectors: [SIMD3<Double>], resolution: Double = 1, sigma: Double = 5, weights: [Double]? = nil,
                                hemisphere: EqualAreaGrid.Hemisphere = .upper, symmetry: PointGroup? = nil,
                                log takeLog: Bool = false, mrd: Bool = true) -> PoleDensityMap {
        let (h, _) = counts(vectors, resolution: resolution, weights: weights, hemisphere: hemisphere, symmetry: symmetry)
        return density(counts: h, resolution: resolution, sigma: sigma, hemisphere: hemisphere, symmetry: symmetry, log: takeLog, mrd: mrd)
    }

    /// The rest of `pole_density_function` from the histogram `counts` returns (same resolution, hemisphere and symmetry).
    package static func density(counts h: [Double], resolution: Double = 1, sigma: Double = 5,
                                hemisphere: EqualAreaGrid.Hemisphere = .upper, symmetry: PointGroup? = nil,
                                log takeLog: Bool = false, mrd: Bool = true) -> PoleDensityMap {
        let working = EqualAreaGrid(resolution: symmetry == nil ? resolution : resolution / 2, hemisphere: hemisphere)
        precondition(h.count == working.binCount, "the counts are on the working grid of this resolution")
        let smoothed = gaussianFilter(h, rows: working.azimuthBins, columns: working.polarBins, sigma: sigma / working.resolution)
        var values: [Double], mask: [Bool], grid: EqualAreaGrid
        if let symmetry {
            grid = EqualAreaGrid(resolution: resolution, hemisphere: hemisphere)
            let sector = symmetry.fundamentalSector
            let centers = symmetry.projectToFundamentalSector(working.centerVectors, sector: sector)
            let inner = (Array(grid.azimuthEdges.dropFirst().dropLast()), Array(grid.polarEdges.dropFirst().dropLast()))
            values = [Double](repeating: 0, count: grid.binCount)
            for (k, c) in centers.enumerated() {
                let (a, p) = EqualAreaGrid.angles(c)
                values[digitize(a, inner.0) * grid.polarBins + digitize(p, inner.1)] += smoothed[k]
            }
            mask = grid.centerVectors.map { !sector.contains($0) }
        } else {
            grid = working
            values = smoothed
            mask = [Bool](repeating: false, count: smoothed.count)
        }
        if mrd {
            var sum = 0.0, n = 0
            for (x, m) in zip(values, mask) where !m {
                sum += x
                n += 1
            }
            let mean = sum / Double(n)
            values = values.map { $0 / mean }
        }
        if takeLog { values = values.map { log($0 + 1) } }
        return PoleDensityMap(grid: grid, values: values, mask: mask, symmetry: symmetry)
    }

    /// numpy's `digitize(x, bins)` on increasing bins (right=False): the number of bins at or below x.
    static func digitize(_ x: Double, _ bins: [Double]) -> Int {
        var lo = 0, hi = bins.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if bins[mid] <= x { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    // MARK: - scipy.ndimage.gaussian_filter

    /// scipy's `gaussian_filter` smooths an axis only when its sigma (in bins) is above this: 0, a negative sigma and NaN leave the
    /// counts as they are.
    static let smallestSigma = 1e-15

    /// The widest smoothing kernel, 2¹² bins on each side of its centre: wider than a whole turn of any grid a texture is binned on
    /// (720 bins at the inverse pole figure's 0.5°), so every sigma a texture can mean passes (up to 512° at 0.5°, 1024° at a pole
    /// figure's 1°). `MapTexture.compute` refuses a wider one before any figure is made; here it is a precondition, as a sigma of
    /// 1e19 bins would trap in the conversion of its radius to `Int` and a smaller huge one would ask for a kernel of 8 sigma values.
    package static let maximumKernelRadius = 1 << 12

    /// Whether `density` smooths at `sigma` degrees on the working grid of `resolution` (half of it with a symmetry) within
    /// `maximumKernelRadius`: true for a sigma that smooths nothing (scipy's rule, `smallestSigma`) and for one whose kernel fits;
    /// false for a sigma of +∞ and for one past the cap (−∞ smooths nothing).
    package static func smoothingFits(sigma: Double, resolution: Double = 1, symmetry: PointGroup? = nil) -> Bool {
        let bins = sigma / (symmetry == nil ? resolution : resolution / 2)
        return !(bins > smallestSigma) || kernelRadius(sigma: bins) != nil
    }

    /// scipy's kernel radius int(truncate σ + 0.5) for a sigma in bins that smooths (above `smallestSigma`) and whose radius is at
    /// most `maximumKernelRadius`; nil for any other sigma (NaN, infinite, past the cap, or one that smooths nothing).
    static func kernelRadius(sigma: Double, truncate: Double = 4) -> Int? {
        let extent = truncate * sigma + 0.5
        guard sigma > smallestSigma, extent < Double(maximumKernelRadius + 1) else { return nil }
        return Int(extent)
    }

    /// scipy's `_gaussian_kernel1d(sigma, 0, radius)`: exp(−x² / 2σ²) for x in −radius...radius, normalised to sum 1,
    /// radius = int(4 σ + 0.5). The sigma smooths and its radius is at most `maximumKernelRadius` (`kernelRadius`).
    static func gaussianKernel(sigma: Double, truncate: Double = 4) -> [Double] {
        guard let radius = kernelRadius(sigma: sigma, truncate: truncate) else {
            preconditionFailure("a kernel sigma above 1e-15 bins whose radius is at most maximumKernelRadius bins")
        }
        let factor = -0.5 / (sigma * sigma)
        var w = (-radius...radius).map { exp(factor * Double($0 * $0)) }
        let s = w.reduce(0, +)
        w = w.map { $0 / s }
        return w
    }

    /// `gaussian_filter(h, sigma, mode=("wrap", "reflect"))` on a rows x columns array (rows = azimuth bins, wrapped;
    /// columns = polar bins, reflected about the outer edges as scipy's half-sample "reflect": d c b a | a b c d | d c b a).
    /// A sigma that is not above `smallestSigma` (0, negative, NaN) returns `h` as it is, as scipy skips such an axis.
    static func gaussianFilter(_ h: [Double], rows: Int, columns: Int, sigma: Double) -> [Double] {
        guard sigma > smallestSigma else { return h }
        let w = gaussianKernel(sigma: sigma)
        let r = w.count / 2
        var pass = [Double](repeating: 0, count: h.count)
        for i in 0..<rows {
            for j in 0..<columns {
                var s = 0.0
                for k in -r...r {
                    var m = (i + k) % rows
                    if m < 0 { m += rows }
                    s += w[k + r] * h[m * columns + j]
                }
                pass[i * columns + j] = s
            }
        }
        var out = [Double](repeating: 0, count: h.count)
        let period = 2 * columns
        for i in 0..<rows {
            for j in 0..<columns {
                var s = 0.0
                for k in -r...r {
                    var m = (j + k) % period
                    if m < 0 { m += period }
                    if m >= columns { m = period - 1 - m }
                    s += w[k + r] * pass[i * columns + m]
                }
                out[i * columns + j] = s
            }
        }
        return out
    }
}
