//
//  Miller.swift
//  orix 0.15.0's `orix.vector.Miller` (crystal directions [uvw] and [UVTW], plane normals (hkl) and (hkil), their
//  Cartesian vectors in the crystal frame, lengths and MTEX's index rounding) on a `CrystalLattice` (CrystalLattice.swift),
//  aligned as orix's `Phase` aligns it (x ∥ a, z ∥ c*, diffpy.structure's base rounded to 12 decimals). GPL-3.0 (orix is GPL-3.0-or-later), see
//  NOTICE. Parity: `tools/parity/sem` bundle `m3/ipf-color-keys`, bases within 1e-10, vectors within 1e-7, rounded
//  indices exact.
//

import Foundation

/// Crystal directions or plane normals in a lattice: Cartesian vectors in the crystal frame with the index notation they
/// were given in (orix's `coordinate_format`).
package nonisolated struct Miller: Sendable {
    package enum Format: String, Sendable {
        case xyz, uvw, UVTW, hkl, hkil
    }

    package var xyz: [SIMD3<Double>]
    package var lattice: CrystalLattice
    package var format: Format

    package init(xyz: [SIMD3<Double>], lattice: CrystalLattice, format: Format = .xyz) {
        self.xyz = xyz
        self.lattice = lattice
        self.format = format
    }

    package init(uvw: [SIMD3<Double>], lattice: CrystalLattice) {
        self.init(xyz: uvw.map(lattice.cartesian(uvw:)), lattice: lattice, format: .uvw)
    }

    package init(hkl: [SIMD3<Double>], lattice: CrystalLattice) {
        self.init(xyz: hkl.map(lattice.cartesian(hkl:)), lattice: lattice, format: .hkl)
    }

    /// Miller-Bravais (hkil); h + k + i must be 0 within 1e-4.
    package init(hkil: [SIMD4<Double>], lattice: CrystalLattice) throws {
        for x in hkil where abs(x[0] + x[1] + x[2]) > 1e-4 { throw IndexError.hkilSum }
        self.init(xyz: hkil.map { lattice.cartesian(hkl: Miller.hkl(fromHKIL: $0)) }, lattice: lattice, format: .hkil)
    }

    /// Weber [UVTW]; U + V + T must be 0 within 1e-4.
    package init(UVTW: [SIMD4<Double>], lattice: CrystalLattice) throws {
        for x in UVTW where abs(x[0] + x[1] + x[2]) > 1e-4 { throw IndexError.uvtwSum }
        self.init(xyz: UVTW.map { lattice.cartesian(uvw: Miller.uvw(fromUVTW: $0)) }, lattice: lattice, format: .UVTW)
    }

    package enum IndexError: Swift.Error, Equatable, Sendable, CustomStringConvertible {
        case hkilSum, uvtwSum

        package var description: String {
            switch self {
            case .hkilSum: "The Miller-Bravais indices convention h + k + i = 0 is not satisfied."
            case .uvtwSum: "The Miller-Bravais indices convention U + V + T = 0 is not satisfied."
            }
        }
    }

    package var count: Int { xyz.count }

    /// Reciprocal-space indices (hkl).
    package var hkl: [SIMD3<Double>] { xyz.map(lattice.hkl(cartesian:)) }
    /// Direct-space indices [uvw].
    package var uvw: [SIMD3<Double>] { xyz.map(lattice.uvw(cartesian:)) }
    /// (hkil) = (h, k, −(h + k), l).
    package var hkil: [SIMD4<Double>] { hkl.map(Miller.hkil(fromHKL:)) }
    /// [UVTW] = ((2u − v)/3, (2v − u)/3, −(u + v)/3, w), De Graef's convention.
    package var UVTW: [SIMD4<Double>] { uvw.map(Miller.UVTW(fromUVW:)) }

    /// `length`: in lattice units for directions, inverse lattice units for planes, the norm of the vector for xyz (the
    /// lattice norms equal the Cartesian ones).
    package var length: [Double] { xyz.map { RotationConversions.norm($0) } }

    /// The indices in the format the vectors were given in, three or four per vector (xyz gives the Cartesian vector).
    package var coordinates: [[Double]] {
        switch format {
        case .xyz: xyz.map { [$0.x, $0.y, $0.z] }
        case .uvw: uvw.map { [$0.x, $0.y, $0.z] }
        case .hkl: hkl.map { [$0.x, $0.y, $0.z] }
        case .hkil: hkil.map { [$0[0], $0[1], $0[2], $0[3]] }
        case .UVTW: UVTW.map { [$0[0], $0[1], $0[2], $0[3]] }
        }
    }

    /// `round(max_index)`: each set of indices replaced by the closest set of smallest integers (MTEX's `Miller.round`),
    /// the vectors rebuilt from them; xyz is returned as it is.
    package func rounded(maxIndex: Int = 20) -> Miller {
        let rows = coordinates.map { Miller.roundIndices($0, maxIndex: maxIndex) }
        let l = lattice
        func v3(_ r: [Double]) -> SIMD3<Double> { SIMD3(r[0], r[1], r[2]) }
        func v4(_ r: [Double]) -> SIMD4<Double> { SIMD4(r[0], r[1], r[2], r[3]) }
        switch format {
        case .xyz: return self
        case .uvw: return Miller(xyz: rows.map { l.cartesian(uvw: v3($0)) }, lattice: l, format: .uvw)
        case .hkl: return Miller(xyz: rows.map { l.cartesian(hkl: v3($0)) }, lattice: l, format: .hkl)
        case .hkil: return Miller(xyz: rows.map { l.cartesian(hkl: Miller.hkl(fromHKIL: v4($0))) }, lattice: l, format: .hkil)
        case .UVTW: return Miller(xyz: rows.map { l.cartesian(uvw: Miller.uvw(fromUVTW: v4($0))) }, lattice: l, format: .UVTW)
        }
    }

    // MARK: - Index conversions

    package static func hkil(fromHKL x: SIMD3<Double>) -> SIMD4<Double> { SIMD4(x.x, x.y, -(x.x + x.y), x.z) }
    package static func hkl(fromHKIL x: SIMD4<Double>) -> SIMD3<Double> { SIMD3(x[0], x[1], x[3]) }
    package static func UVTW(fromUVW x: SIMD3<Double>) -> SIMD4<Double> {
        SIMD4((2 * x.x - x.y) / 3, (2 * x.y - x.x) / 3, -(x.x + x.y) / 3, x.z)
    }
    package static func uvw(fromUVTW x: SIMD4<Double>) -> SIMD3<Double> { SIMD3(2 * x[0] + x[1], x[0] + 2 * x[1], x[3]) }

    /// `_round_indices` for one set (three indices, or four of which the third is dropped for the search): the
    /// multiplier 1...maxIndex (over the largest index) whose scaled set is closest to integers, relative squared error
    /// rounded to 1e-7, the first of equals; the set times it, rounded half to even.
    package static func roundIndices(_ indices: [Double], maxIndex: Int = 12) -> [Double] {
        let search = indices.count == 4 ? [indices[0], indices[1], indices[3]] : indices
        let largest = search.map(abs).max() ?? 0
        var bestK = 0
        var bestError = Double.infinity
        for k in 0..<maxIndex {
            let m = Double(k + 1)
            var num = 0.0, den = 0.0
            for x in search {
                let s = x / largest * m
                let d = s - s.rounded(.toNearestOrEven)
                num += d * d
                den += s * s
            }
            let error = 1e-7 * (1e7 * num / den).rounded(.toNearestOrEven)
            if error < bestError { bestError = error; bestK = k }
        }
        let multiplier = Double(bestK + 1) / largest
        return indices.map { (multiplier * $0).rounded(.toNearestOrEven) }
    }
}
