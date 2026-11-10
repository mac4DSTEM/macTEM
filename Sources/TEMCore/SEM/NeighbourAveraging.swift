//
//  NeighbourAveraging.swift
//  Averaging of every EBSD pattern with its neighbours in the scan: kikuchipy 0.13.1's `EBSD.average_neighbour_patterns`
//  (`pattern.chunk._average_neighbour_patterns`, `_rescale_neighbour_averaged_patterns`; Wright et al. 2015, "Improved EBSD
//  indexing by neighbour pattern averaging", Ultramicroscopy 148), ported step by step in float64:
//  - the window is correlated with the scan of patterns across the navigation axes (`scipy.ndimage.correlate`,
//    `mode="constant"`: map borders read zero patterns), the window's origin at `shape // 2`;
//  - each sum is divided by the window's weights that fall inside the map, as an integer (upstream correlates an integer
//    array of ones, which SciPy truncates);
//  - each averaged pattern is rescaled to the pattern type's range on its own and cast by truncation.
//  References: the `m2/average-neighbours-*` bundles of `tools/parity/sem/emit.py`. kikuchipy rescales in float32 numba
//  fastmath arithmetic; the rescaled values here agree within 1e-5 relative or 1e-4 grey levels, the cast patterns within
//  one grey level (measured on all 4125 nickel_ebsd_large patterns: 0.002 % of the pixels for the 3 x 3 Gaussian window,
//  0.14 % for the integer-weight windows, whose exact integer values kikuchipy's fastmath lands just below).
//

import Foundation

package nonisolated enum NeighbourAveraging {
    package enum Error: Swift.Error, Equatable, Sendable, LocalizedError {
        /// A count does not match the scan and pattern sizes, or a size is below 1.
        case shape
        /// An averaged pattern is flat or not finite (e.g. a window whose weights inside the map sum to zero).
        case nonFinite

        package var errorDescription: String? {
            switch self {
            case .shape: "The patterns to average do not match the scan and pattern sizes."
            case .nonFinite: "An averaged pattern is flat, so it cannot be rescaled."
            }
        }
    }

    /// The integer sum of the window's weights inside the map at every scan position (`correlate(ones(int), window,
    /// mode="constant")`, truncated to an integer as SciPy writes it into the integer array). Row-major over the scan.
    package static func windowSums(scanRows: Int, scanColumns: Int, window: PatternWindow) -> [Int] {
        let (oy, ox) = window.origin
        var sums = [Int](repeating: 0, count: scanRows * scanColumns)
        for r in 0..<scanRows {
            for c in 0..<scanColumns {
                var s = 0.0
                for a in 0..<window.rows {
                    let y = r + a - oy
                    guard y >= 0, y < scanRows else { continue }
                    for b in 0..<window.columns {
                        let x = c + b - ox
                        guard x >= 0, x < scanColumns else { continue }
                        s += window[a, b]
                    }
                }
                sums[r * scanColumns + c] = Int(s.rounded(.towardZero))
            }
        }
        return sums
    }

    /// `average_neighbour_patterns` before the cast: every pattern of the scan (row-major scan of row-major patterns,
    /// `scanRows * scanColumns * pixels` values) averaged with `window` and rescaled to the type's range.
    package static func averageValues<P: FixedWidthInteger & UnsignedInteger>(
        _ patterns: [P], scanRows: Int, scanColumns: Int, pixels: Int, window: PatternWindow
    ) throws -> [Double] {
        var out = [Double](repeating: 0, count: patterns.count)
        try forEachAveraged(patterns, scanRows: scanRows, scanColumns: scanColumns, pixels: pixels, window: window,
                            isCancelled: { false }) { base, rescaled in
            for k in 0..<rescaled.count { out[base + k] = rescaled[k] }
        }
        return out
    }

    /// The steps of `averageValues`, one pattern at a time in map order: `body` gets the index of the pattern's first value in the
    /// scan and its `pixels` averaged, rescaled values, so a caller that casts them at once needs no whole-scan float64 buffer.
    /// `isCancelled` is asked before each scan row; a yes ends the pass with `CancellationError`.
    private static func forEachAveraged<P: FixedWidthInteger & UnsignedInteger>(
        _ patterns: [P], scanRows: Int, scanColumns: Int, pixels: Int, window: PatternWindow, isCancelled: () -> Bool,
        _ body: (Int, [Double]) throws -> Void
    ) throws {
        guard scanRows >= 1, scanColumns >= 1, pixels >= 1, patterns.count == scanRows * scanColumns * pixels else { throw Error.shape }
        let sums = windowSums(scanRows: scanRows, scanColumns: scanColumns, window: window)
        let (oy, ox) = window.origin
        let (omin, omax) = PatternProcessing.range(of: P.self)
        var acc = [Double](repeating: 0, count: pixels)
        for r in 0..<scanRows {
            if isCancelled() { throw CancellationError() }
            for c in 0..<scanColumns {
                for k in 0..<pixels { acc[k] = 0 }
                for a in 0..<window.rows {
                    let y = r + a - oy
                    guard y >= 0, y < scanRows else { continue }
                    for b in 0..<window.columns {
                        let x = c + b - ox
                        let w = window[a, b]
                        guard x >= 0, x < scanColumns, w != 0 else { continue }
                        let base = (y * scanColumns + x) * pixels
                        patterns.withUnsafeBufferPointer { p in
                            for k in 0..<pixels { acc[k] += w * Double(p[base + k]) }
                        }
                    }
                }
                let n = Double(sums[r * scanColumns + c])
                let averaged = acc.map { $0 / n }
                let rescaled: [Double]
                do {
                    rescaled = try PatternProcessing.rescale(averaged, toMin: omin, max: omax)
                } catch {
                    throw Error.nonFinite
                }
                try body((r * scanColumns + c) * pixels, rescaled)
            }
        }
    }

    /// `average_neighbour_patterns`: `averageValues` cast back to the pattern type by truncation. A 1 x 1 window returns the
    /// patterns unchanged, as upstream does (it warns and averages nothing).
    package static func average<P: FixedWidthInteger & UnsignedInteger>(
        _ patterns: [P], scanRows: Int, scanColumns: Int, pixels: Int, window: PatternWindow
    ) throws -> [P] {
        var out = [P](repeating: 0, count: patterns.count)
        try average(patterns, scanRows: scanRows, scanColumns: scanColumns, pixels: pixels, window: window, into: &out)
        return out
    }

    /// `average` written into `out`, the caller's buffer of `patterns.count` values: each pattern is averaged, rescaled and cast
    /// on its own, so no whole-scan float64 buffer is made. The values are `average`'s, as the cast is value by value. `isCancelled`
    /// (Stop) is asked before each scan row; a yes ends the pass with `CancellationError`, `out` part written.
    package static func average<P: FixedWidthInteger & UnsignedInteger>(
        _ patterns: [P], scanRows: Int, scanColumns: Int, pixels: Int, window: PatternWindow, into out: inout [P],
        isCancelled: () -> Bool = { false }
    ) throws {
        guard out.count == patterns.count else { throw Error.shape }
        if window.rows == 1, window.columns == 1 {
            guard patterns.count == scanRows * scanColumns * pixels else { throw Error.shape }
            out = patterns
            return
        }
        try forEachAveraged(patterns, scanRows: scanRows, scanColumns: scanColumns, pixels: pixels, window: window,
                            isCancelled: isCancelled) { base, rescaled in
            let cast: [P]
            do {
                cast = try PatternProcessing.cast(rescaled, to: P.self)
            } catch {
                throw Error.nonFinite
            }
            for k in 0..<cast.count { out[base + k] = cast[k] }
        }
    }
}
