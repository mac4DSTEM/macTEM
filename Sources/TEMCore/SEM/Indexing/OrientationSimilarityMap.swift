//
//  OrientationSimilarityMap.swift
//  kikuchipy 0.13.1's `orientation_similarity_map` (Marquardt, Lenthe, Paul and Kosc 2017, Microsc. Microanal. 23, 1144):
//  for each point of a dictionary-indexed map, the mean over its neighbours of how many of its n best simulation indices
//  each neighbour shares (`np.intersect1d`, so a set count). The neighbourhood is scipy's `generic_filter` with a boolean
//  footprint (the four nearest neighbours by default), its origin at `size // 2` on each axis, points outside the map taking
//  the value −1; the values under the footprint are read in row-major order, the one at `centerIndex` is the point, the
//  others that are neither −1 nor the point are its neighbours. The mean is float64 (`np.nanmean`, NaN for a point without
//  neighbours), divided by n when normalised, stored as float32. With `fromNBest` there is one map for each n from
//  `nBest` down to `fromNBest`.
//  kikuchipy is GPL-3.0 (NOTICE). Parity: `m4/orientation-similarity-map` (exact, five settings and figure F9's whole scan).
//  D-SEM-88: a line scan or a map with points left out by a navigation mask is refused (kikuchipy fails on both, unless the
//  points left form a rectangle).
//

import Foundation

package nonisolated enum OrientationSimilarityMap {
    package enum Error: Swift.Error, Equatable, Sendable, LocalizedError {
        case notAMap(shape: [Int])
        case pointsNotInData
        case indicesCount(expected: Int, got: Int)
        case nBest(Int, keepN: Int)
        case fromNBest(Int, nBest: Int)
        case footprint
        case centerIndex(Int, footprintPoints: Int)

        package var errorDescription: String? {
            switch self {
            case .notAMap(let shape): "An orientation similarity map needs a map of rows and columns, not \(shape)."
            case .pointsNotInData: "An orientation similarity map needs every point of the map indexed."
            case .indicesCount(let e, let g): "There are \(g) simulation indices for \(e) expected."
            case .nBest(let n, let k): "n_best \(n) cannot be greater than keep_n \(k)."
            case .fromNBest(let f, let n): "from_n_best \(f) must lie between 1 and n_best \(n)."
            case .footprint: "The footprint must be a non-empty rectangle of true and false."
            case .centerIndex(let c, let n): "The centre index \(c) is outside the footprint's \(n) points."
            }
        }
    }

    /// One map per n, from `nBest` down to `fromNBest` (kikuchipy's `osm[:, :, i]`), each rows × columns, row-major.
    package struct Result: Sendable, Equatable {
        package var rows: Int
        package var columns: Int
        /// The n of each map, `nBest` first.
        package var n: [Int]
        package var maps: [[Float]]
    }

    /// The default footprint: the point and its four nearest neighbours.
    package static let crossFootprint: [[Bool]] = [[false, true, false], [true, true, true], [false, true, false]]

    /// `orientation_similarity_map(xmap, n_best, normalize=..., from_n_best, footprint, center_index)` on the simulation indices
    /// of a rows × columns map, point × keepN, best first.
    package static func compute(simulationIndices: [Int], keepN: Int, rows: Int, columns: Int, nBest: Int? = nil,
                                normalize: Bool = false, fromNBest: Int? = nil, footprint: [[Bool]] = crossFootprint,
                                centerIndex: Int = 2) throws -> Result {
        guard rows > 0, columns > 0 else { throw Error.notAMap(shape: [rows, columns]) }
        guard simulationIndices.count == rows * columns * keepN else {
            throw Error.indicesCount(expected: rows * columns * keepN, got: simulationIndices.count)
        }
        let top = nBest ?? keepN
        guard top <= keepN else { throw Error.nBest(top, keepN: keepN) }
        let bottom = fromNBest ?? top
        guard bottom >= 1, bottom <= top else { throw Error.fromNBest(bottom, nBest: top) }
        let fr = footprint.count, fc = footprint.first?.count ?? 0
        guard fr > 0, fc > 0, footprint.allSatisfy({ $0.count == fc }) else { throw Error.footprint }
        // The footprint's true positions relative to the point (scipy's origin 0 sits at size // 2).
        var offsets: [(dr: Int, dc: Int)] = []
        for r in 0 ..< fr { for c in 0 ..< fc where footprint[r][c] { offsets.append((r - fr / 2, c - fc / 2)) } }
        guard centerIndex >= 0, centerIndex < offsets.count else { throw Error.centerIndex(centerIndex, footprintPoints: offsets.count) }

        let count = rows * columns
        var result = Result(rows: rows, columns: columns, n: [], maps: [])
        for n in stride(from: top, through: bottom, by: -1) {
            let sets = (0 ..< count).map { Set(simulationIndices[($0 * keepN) ..< ($0 * keepN + n)]) }
            var map = [Float](repeating: 0, count: count)
            for r in 0 ..< rows {
                for c in 0 ..< columns {
                    let values = offsets.map { o -> Int in
                        let rr = r + o.dr, cc = c + o.dc
                        return rr >= 0 && rr < rows && cc >= 0 && cc < columns ? rr * columns + cc : -1
                    }
                    let center = values[centerIndex]
                    var sum = 0.0, neighbours = 0
                    if center >= 0 {
                        for v in values where v != -1 && v != center {
                            sum += Double(sets[center].intersection(sets[v]).count)
                            neighbours += 1
                        }
                    }
                    // np.nanmean of an empty list (and kikuchipy's lookup of −1, the last point, for a centre outside the map).
                    var value = center >= 0 ? (neighbours > 0 ? sum / Double(neighbours) : .nan) : lastPoint(values, sets: sets, count: count)
                    if normalize { value /= Double(n) }
                    map[r * columns + c] = Float(value)
                }
            }
            result.n.append(n)
            result.maps.append(map)
        }
        return result
    }

    /// A centre value of −1 indexes the last point in numpy (`match_indices[-1]`); its neighbours are the values that are
    /// neither −1 nor −1, so every in-map value under the footprint.
    private static func lastPoint(_ values: [Int], sets: [Set<Int>], count: Int) -> Double {
        let center = sets[count - 1]
        let neighbours = values.filter { $0 != -1 }
        guard !neighbours.isEmpty else { return .nan }
        return neighbours.reduce(0.0) { $0 + Double(center.intersection(sets[$1]).count) } / Double(neighbours.count)
    }
}

extension DictionaryIndexing.Result {
    /// kikuchipy's `orientation_similarity_map` of this result (D-SEM-88: a map of rows and columns with every point in data).
    package func orientationSimilarityMap(nBest: Int? = nil, normalize: Bool = false, fromNBest: Int? = nil,
                                          footprint: [[Bool]] = OrientationSimilarityMap.crossFootprint,
                                          centerIndex: Int = 2) throws -> OrientationSimilarityMap.Result {
        guard navigationShape.count == 2 else { throw OrientationSimilarityMap.Error.notAMap(shape: navigationShape) }
        guard isInData.allSatisfy({ $0 }) else { throw OrientationSimilarityMap.Error.pointsNotInData }
        return try OrientationSimilarityMap.compute(simulationIndices: simulationIndices, keepN: keepN, rows: navigationShape[0],
                                                    columns: navigationShape[1], nBest: nBest, normalize: normalize,
                                                    fromNBest: fromNBest, footprint: footprint, centerIndex: centerIndex)
    }
}
