//
//  PoleFigures.swift
//  Pole figures and inverse pole figure densities of a set of orientations, as orix 0.15.0 draws them (GPL-3.0-or-later,
//  see NOTICE): a {hkl} or {hkil} family made whole by `Miller.symmetrise(unique=True)` under the phase's point group, each
//  pole turned into the sample frame by the inverse orientation (`(~O).outer(m)`, orix's pole figure), the sample direction
//  turned into the crystal frame by the orientation (`O * v`, the inverse pole figure), and the densities of
//  `PoleDensityFunction`. The rasters are what the Maps room's Texture tab draws: values on a square stereographic canvas,
//  NaN outside the hemisphere or the sector, coloured by the shared colormap in the view (D-SEM-68 in
//  docs/decisions.md).
//
//  Parity: `tools/parity/sem` bundles `m5/texture-ti`, `m5/texture-cubic`, `m5/texture-ti-full` (figure F13).
//

import Foundation

package nonisolated enum PoleFigures {
    /// `Miller.symmetrise(unique=True)` of each vector under `group`, then `.unit`: every element applied (an improper one
    /// negates), the images made unique as `Vector3d.unique` makes them (rounded to 10 decimals, first appearances kept),
    /// then unit. The families' poles in the order the vectors were given; within a family orix sorts, which no density
    /// depends on.
    package static func symmetrise(_ vectors: [SIMD3<Double>], group: PointGroup) -> [SIMD3<Double>] {
        vectors.flatMap { v in Vector3.unique(group.elements.map { $0 * v }).map(Vector3.unit) }
    }

    /// The poles of a family given as Miller indices in a lattice (three indices hkl, or four hkil), symmetrised by `group`.
    package static func poles(family: [Double], lattice: CrystalLattice, group: PointGroup) throws -> [SIMD3<Double>] {
        let m: Miller
        switch family.count {
        case 3: m = Miller(hkl: [SIMD3(family[0], family[1], family[2])], lattice: lattice)
        case 4: m = try Miller(hkil: [SIMD4(family[0], family[1], family[2], family[3])], lattice: lattice)
        default: throw Refusal.indices(family.count)
        }
        return symmetrise(m.xyz, group: group)
    }

    package enum Refusal: Swift.Error, Equatable, Sendable, CustomStringConvertible {
        case indices(Int)

        package var description: String {
            switch self {
            case .indices(let n): "A pole family takes three (hkl) or four (hkil) indices, not \(n)."
            }
        }
    }

    /// `(~O).outer(poles)`: per orientation, each pole in the sample frame; orientation-major.
    package static func sampleDirections(_ orientations: Orientations, poles: [SIMD3<Double>]) -> [SIMD3<Double>] {
        var out: [SIMD3<Double>] = []
        out.reserveCapacity(orientations.count * poles.count)
        for q in orientations.quaternions {
            let inverse = Rotation(q).inverse
            for p in poles { out.append(inverse * p) }
        }
        return out
    }

    /// `O * v`: the sample direction in each crystal frame (the inverse pole figure's vectors).
    package static func crystalDirections(_ orientations: Orientations, sampleDirection: SIMD3<Double> = Vector3.z) -> [SIMD3<Double>] {
        orientations.quaternions.map { Rotation($0) * sampleDirection }
    }

    /// The pole figure of one family: orix's `pole_density_function` of the sample directions on a hemisphere.
    package static func poleFigure(_ orientations: Orientations, poles: [SIMD3<Double>], resolution: Double = 1, sigma: Double = 5,
                                   hemisphere: EqualAreaGrid.Hemisphere = .upper) -> PoleDensityMap {
        PoleDensityFunction.compute(sampleDirections(orientations, poles: poles), resolution: resolution, sigma: sigma, hemisphere: hemisphere)
    }

    /// The inverse pole figure density of one sample direction in `laue`'s fundamental sector.
    package static func inversePoleFigure(_ orientations: Orientations, sampleDirection: SIMD3<Double> = Vector3.z, laue: PointGroup,
                                          resolution: Double = 1, sigma: Double = 5) -> PoleDensityMap {
        PoleDensityFunction.compute(crystalDirections(orientations, sampleDirection: sampleDirection), resolution: resolution,
                                    sigma: sigma, symmetry: laue)
    }

    /// The pole figures of several families off the caller's actor (a 1000 x 1000 map is a million orientations times
    /// up to 24 poles per family).
    @concurrent package static func poleFiguresAsync(_ orientations: Orientations, families: [[SIMD3<Double>]], resolution: Double = 1,
                                                     sigma: Double = 5) async -> [PoleDensityMap] {
        families.map { poleFigure(orientations, poles: $0, resolution: resolution, sigma: sigma) }
    }

    /// `inversePoleFigure` off the caller's actor.
    @concurrent package static func inversePoleFigureAsync(_ orientations: Orientations, sampleDirection: SIMD3<Double> = Vector3.z,
                                                           laue: PointGroup, resolution: Double = 1, sigma: Double = 5) async -> PoleDensityMap {
        inversePoleFigure(orientations, sampleDirection: sampleDirection, laue: laue, resolution: resolution, sigma: sigma)
    }
}

/// A density drawn on a square canvas: `values` row-major from the top row, Float, NaN where nothing is drawn; `low` and
/// `high` the range of the finite values (the colour bar).
package nonisolated struct TextureRaster: Sendable, Equatable {
    package let width: Int
    package let height: Int
    package let values: [Float]
    package let low: Float
    package let high: Float

    package init(width: Int, height: Int, values: [Float]) {
        precondition(values.count == width * height, "one value per pixel")
        self.width = width
        self.height = height
        self.values = values
        let finite = values.filter(\.isFinite)
        low = finite.min() ?? 0
        high = finite.max() ?? 0
    }

    /// The stereographic projection of a pole density map: pixel (column c, row r) of a size x size canvas centred at
    /// x = x0 + (c + 0.5) w / size, y = y1 − (r + 0.5) h / size over `extent` (the unit disk by default; an inverse pole
    /// figure passes its sector's stereographic extent), the vector of that point in the map's hemisphere, the value of the
    /// bin it falls in; NaN outside the disk, the hemisphere, or a masked bin.
    package static func stereographic(_ map: PoleDensityMap, size: Int,
                                      extent: (x: ClosedRange<Double>, y: ClosedRange<Double>) = (-1...1, -1...1)) -> TextureRaster {
        precondition(size > 0, "a raster has at least one pixel")
        let projection = StereographicProjection(pole: map.grid.hemisphere.pole)
        let w = extent.x.upperBound - extent.x.lowerBound, h = extent.y.upperBound - extent.y.lowerBound
        let side = max(w, h)
        var out = [Float](repeating: .nan, count: size * size)
        for r in 0..<size {
            let y = extent.y.upperBound - (Double(r) + 0.5) * side / Double(size)
            for c in 0..<size {
                let x = extent.x.lowerBound + (Double(c) + 0.5) * side / Double(size)
                guard x * x + y * y <= 1 else { continue }
                if let v = map.value(at: projection.xyToVector(SIMD2(x, y))) { out[r * size + c] = Float(v) }
            }
        }
        return TextureRaster(width: size, height: size, values: out)
    }

    /// An ODF section as an image: φ1 across (columns), Φ down (rows), one pixel per node.
    package static func section(_ s: ODFSection) -> TextureRaster {
        var out = [Float](repeating: .nan, count: s.phi1Degrees.count * s.PhiDegrees.count)
        for (i, _) in s.phi1Degrees.enumerated() {
            for (j, _) in s.PhiDegrees.enumerated() { out[j * s.phi1Degrees.count + i] = Float(s.values[i * s.PhiDegrees.count + j]) }
        }
        return TextureRaster(width: s.phi1Degrees.count, height: s.PhiDegrees.count, values: out)
    }
}
