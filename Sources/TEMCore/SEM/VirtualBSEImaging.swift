//
//  VirtualBSEImaging.swift
//  Role: virtual backscatter electron images of an EBSD scan (north star F1, docs/sem/north-star.md): a detector grid cut into
//        tiles, the sum of every tile's pixels per pattern as one image of the scan, the same for an explicit detector rectangle, and
//        the RGB image of three tiles with kikuchipy's per-channel normalisation. Ported from kikuchipy 0.13.1
//        (`kikuchipy/imaging/vbse.py`, `kikuchipy/pattern/_pattern.py::rescale_intensity`; GPL-3.0-or-later) over HyperSpy's
//        rectangular ROI slicing (`UniformDataAxis.value2index`: the grid's float edges rounded to the nearest pixel, half to even).
//        Sums are float64 over the stored counts (exact for integer patterns); the RGB channels follow the reference's float32
//        arithmetic so a count lands where kikuchipy's lands (docs/parity.md: atol 1). One pass over the scan in rows through
//        `EBSDPatternAccess`, which can also sum the patterns for the scan's mean on the way; nothing here touches a view.
//

import Foundation
import FormatoCore

/// A rectangle on the detector in pixels, half-open on the right and bottom (`hs.roi.RectangularROI` as the signal is sliced).
package nonisolated struct DetectorRect: Sendable, Hashable {
    package var top: Int
    package var bottom: Int
    package var left: Int
    package var right: Int

    package init(top: Int, bottom: Int, left: Int, right: Int) {
        self.top = top; self.bottom = bottom; self.left = left; self.right = right
    }

    /// Held inside a `rows` x `columns` pattern.
    package func clamped(rows: Int, columns: Int) -> DetectorRect {
        DetectorRect(top: min(max(top, 0), rows), bottom: min(max(bottom, 0), rows), left: min(max(left, 0), columns), right: min(max(right, 0), columns))
    }

    package var pixelCount: Int { max(bottom - top, 0) * max(right - left, 0) }
}

/// One tile of the detector grid, by its row and column in the grid: kikuchipy's `(row, col)` index.
package nonisolated struct VirtualBSETile: Sendable, Hashable, Identifiable {
    package var row: Int
    package var column: Int

    package init(row: Int, column: Int) {
        self.row = row; self.column = column
    }

    package var id: String { "\(row),\(column)" }
    /// "r2 c1", as the inspector lists it.
    package var label: String { "r\(row) c\(column)" }
}

/// The detector grid (`VirtualBSEImager.grid_shape`): `rows` x `columns` tiles whose edges are numpy's `linspace(0, side, n + 1)` rounded to
/// pixels as HyperSpy slices a float ROI (nearest, half to even), so a 60 px side cut in 7 gives tiles of 9, 8, 9, 8, 9, 8, 9 px.
package nonisolated struct VirtualBSEGrid: Sendable, Hashable {
    package var rows: Int
    package var columns: Int

    package init(rows: Int, columns: Int) {
        self.rows = max(rows, 1); self.columns = max(columns, 1)
    }

    /// `n` x `n`.
    package init(_ n: Int) { self.init(rows: n, columns: n) }

    package static let whole = VirtualBSEGrid(1)

    package var tileCount: Int { rows * columns }

    /// The `count + 1` edges of `side` pixels cut in `count`.
    package static func edges(_ count: Int, side: Int) -> [Int] {
        (0...count).map { Int((Double($0) * Double(side) / Double(count)).rounded(.toNearestOrEven)) }
    }

    /// The tiles in row-major order (kikuchipy's `np.ndindex(grid_shape)`).
    package var tiles: [VirtualBSETile] {
        (0..<rows).flatMap { r in (0..<columns).map { VirtualBSETile(row: r, column: $0) } }
    }

    package func index(of tile: VirtualBSETile) -> Int { tile.row * columns + tile.column }

    /// The detector rectangle of `tile` on a `patternRows` x `patternColumns` pattern (`VirtualBSEImager.roi_from_grid`).
    package func rect(of tile: VirtualBSETile, patternRows: Int, patternColumns: Int) -> DetectorRect {
        let ys = Self.edges(rows, side: patternRows), xs = Self.edges(columns, side: patternColumns)
        let r = min(max(tile.row, 0), rows - 1), c = min(max(tile.column, 0), columns - 1)
        return DetectorRect(top: ys[r], bottom: ys[r + 1], left: xs[c], right: xs[c + 1])
    }

    /// Every tile's rectangle, in `tiles` order.
    package func rects(patternRows: Int, patternColumns: Int) -> [DetectorRect] {
        tiles.map { rect(of: $0, patternRows: patternRows, patternColumns: patternColumns) }
    }
}

package nonisolated enum VirtualBSEImaging {
    /// The sum of each rectangle's pixels in every pattern, one image of the scan per rectangle (`EBSD.get_virtual_bse_intensity`, a
    /// float64 sum over the stored counts). `images[k]` is the image of `rects[k]`, `scanRows * scanColumns` long in map order. One
    /// pass over the scan in rows; `progress` after every row (0...1); `isCancelled` stops the pass with nil.
    package static func images(_ access: any EBSDPatternAccess, rects: [DetectorRect], progress: (Double) -> Void = { _ in },
                               isCancelled: () -> Bool = { false }) throws -> [[Double]]? {
        try imagesAndPatternSum(access, rects: rects, sumsPatterns: false, progress: progress, isCancelled: isCancelled)?.images
    }

    /// `images`, and with `sumsPatterns` each detector pixel's sum over every pattern of the scan beside them (`patternPixels` long; nil
    /// without), added in the same pass in `PatternPipeline.meanBackground`'s order (row by row, each row's patterns in map order), so
    /// `PatternPipeline.meanBackground(sum:of:)` of it is the scan's mean exactly: a file without a static background is read once for
    /// its map and its mean. nil when cancelled.
    package static func imagesAndPatternSum(_ access: any EBSDPatternAccess, rects: [DetectorRect], sumsPatterns: Bool,
                                            progress: (Double) -> Void = { _ in },
                                            isCancelled: () -> Bool = { false }) throws -> (images: [[Double]], patternSum: [Double]?)? {
        let dataset = access.dataset
        let rows = dataset.scanRows, columns = dataset.scanColumns
        let pr = dataset.patternRows, pc = dataset.patternColumns, pixels = dataset.patternPixels
        let clamped = rects.map { $0.clamped(rows: pr, columns: pc) }
        var out = [[Double]](repeating: [Double](repeating: 0, count: rows * columns), count: rects.count)
        var patternSum = [Double](repeating: 0, count: sumsPatterns ? max(pixels, 0) : 0)
        guard pixels > 0 else { return (images: out, patternSum: sumsPatterns ? patternSum : nil) }
        for row in 0..<rows {
            if isCancelled() { return nil }
            let values = try access.row(row).doubles()
            for column in 0..<columns {
                let base = column * pixels
                for (k, rect) in clamped.enumerated() where rect.pixelCount > 0 {
                    var sum = 0.0
                    for y in rect.top..<rect.bottom {
                        let line = base + y * pc
                        for x in rect.left..<rect.right { sum += values[line + x] }
                    }
                    out[k][row * columns + column] = sum
                }
                if sumsPatterns {
                    for j in 0..<pixels { patternSum[j] += values[base + j] }
                }
            }
            progress(Double(row + 1) / Double(rows))
        }
        return (images: out, patternSum: sumsPatterns ? patternSum : nil)
    }

    /// The RGB image of three channel images (`VirtualBSEImager.get_rgb_image` with its defaults: `normalize=True`, no percentiles, no
    /// alpha, uint8): each channel normalised to median 127 and 0.3125 x 255 per standard deviation in float32 and clipped to 0...255, the
    /// three stacked and rescaled together from their common minimum and maximum to 0...255, truncated to uint8 as numpy's `astype` does.
    /// The channels are the tile images as `Float` (the reference's `astype(float32)` of its float64 sums). Returns the pixels interleaved
    /// (R, G, B per scan point), `3 * n` long; empty when the channels differ in length.
    package static func rgb(red: [Float], green: [Float], blue: [Float]) -> [UInt8] {
        let n = red.count
        guard green.count == n, blue.count == n, n > 0 else { return [] }
        let channels = [red, green, blue].map(normalizedChannel)
        var lo = Float.greatestFiniteMagnitude, hi = -Float.greatestFiniteMagnitude
        for channel in channels { for v in channel { lo = min(lo, v); hi = max(hi, v) } }
        let span = Double(hi - lo)
        var out = [UInt8](repeating: 0, count: 3 * n)
        guard span > 0 else { return out }
        for i in 0..<n {
            for c in 0..<3 {
                let scaled = Double(channels[c][i] - lo) / span * 255
                out[3 * i + c] = UInt8(min(max(scaled, 0), 255))   // `astype(uint8)`: toward zero
            }
        }
        return out
    }

    /// kikuchipy's `_normalize_image` for uint8: `127 + 79.6875 * (x - median) / std`, clipped to 0...255, in float32 as the reference
    /// computes it (the channel, a float64 sum there, is cast to float32 first: a `Float` sum image is that cast).
    package static func normalizedChannel(_ values: [Float]) -> [Float] {
        let median = Self.median(values)
        let std = Self.standardDeviation(values)
        let contrast: Float = 255 * 0.3125
        return values.map { v -> Float in
            let scaled = std > 0 ? Float(127) + (contrast * (v - median)) / std : Float(127)
            return min(max(scaled, 0), 255)
        }
    }

    /// numpy's median: the middle value, or the mean of the two middle values.
    package static func median(_ values: [Float]) -> Float {
        guard !values.isEmpty else { return .nan }
        let sorted = values.sorted()
        let n = sorted.count
        return n % 2 == 1 ? sorted[n / 2] : (sorted[n / 2 - 1] + sorted[n / 2]) / 2
    }

    /// numpy's population standard deviation (`ddof=0`), summed in float64 and returned as float32.
    package static func standardDeviation(_ values: [Float]) -> Float {
        guard !values.isEmpty else { return .nan }
        let n = Double(values.count)
        let mean = values.reduce(0.0) { $0 + Double($1) } / n
        let variance = values.reduce(0.0) { $0 + (Double($1) - mean) * (Double($1) - mean) } / n
        return Float(variance.squareRoot())
    }
}
