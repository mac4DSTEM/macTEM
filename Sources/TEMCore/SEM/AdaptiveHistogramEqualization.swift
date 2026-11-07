//
//  AdaptiveHistogramEqualization.swift
//  Contrast-limited adaptive histogram equalisation (CLAHE) of EBSD patterns: kikuchipy 0.13.1's
//  `EBSD.adaptive_histogram_equalization` (`pattern._pattern._adaptive_histogram_equalization`), which is scikit-image 0.26.0's
//  `exposure.equalize_adapthist` (`_adapthist._clahe`, `clip_histogram`, `map_histogram`; Zuiderveld 1994, "Contrast limited
//  adaptive histogram equalization", Graphics Gems IV) followed by `rescale_intensity` to the pattern's type, ported step by
//  step: the 2¹⁴-level quantisation with NumPy's round-half-even, the reflect padding, the binning look-up, the per-region
//  histograms with the clip-limit redistribution, the integer mapping, and the bilinear interpolation of the four
//  neighbouring mappings accumulated in float32 in scikit-image's order (that accumulation is what upstream computes, so it
//  is kept: the uint8 patterns are then exact). References: the `m2/clahe-*` bundles of `tools/parity/sem/emit.py`.
//
//  scikit-image is BSD-3-Clause, kikuchipy GPL-3.0-or-later (NOTICE).
//

import Foundation

package nonisolated enum AdaptiveHistogramEqualization {
    package enum Error: Swift.Error, Equatable, Sendable {
        /// A count does not match `rows * columns`, a size or kernel axis is below 1, or the type is not 8 or 16 bit.
        case shape
        /// `clipLimit` is negative or not finite, or `bins` is below 1.
        case parameter(String)
        /// The equalised pattern is flat, so it cannot be rescaled (upstream divides by zero).
        case nonFinite
    }

    /// scikit-image's `NR_OF_GRAY`: the grey levels the image is quantised to before binning.
    static let grayLevels = 1 << 14

    /// kikuchipy's default contextual region: `(signal_shape[0] // 4, signal_shape[1] // 4)` with HyperSpy's signal shape in
    /// (columns, rows) order, passed on as the (rows, columns) kernel — so (columns / 4, rows / 4) as (rows, columns), the same
    /// for a square pattern.
    package static func defaultKernel(rows: Int, columns: Int) -> (rows: Int, columns: Int) {
        (columns / 4, rows / 4)
    }

    /// `EBSD.adaptive_histogram_equalization` for one pattern. `kernel` defaults to `defaultKernel`; `clipLimit` is
    /// upstream's normalised limit (0 = no clipping); `bins` the histogram bins (default 128, kikuchipy's).
    package static func equalize<P: FixedWidthInteger & UnsignedInteger>(
        _ pattern: [P], rows: Int, columns: Int, kernel: (rows: Int, columns: Int)? = nil, clipLimit: Double = 0, bins: Int = 128
    ) throws -> [P] {
        let unit = try equalizedUnit(pattern, rows: rows, columns: columns, kernel: kernel, clipLimit: clipLimit, bins: bins)
        // kikuchipy's `rescale_intensity(image_eq, dtype_out)`: min 0, max 1 to the type's range, cast by truncation.
        let top = Double(P.max)
        return unit.map { P(min(max($0 * top, 0), top)) }
    }

    /// `equalize_adapthist(image, kernel_size, clip_limit, nbins)`: the equalised pattern in [0, 1] (float64).
    package static func equalizedUnit<P: FixedWidthInteger & UnsignedInteger>(
        _ pattern: [P], rows: Int, columns: Int, kernel: (rows: Int, columns: Int)? = nil, clipLimit: Double = 0, bins: Int = 128
    ) throws -> [Double] {
        guard rows >= 1, columns >= 1, pattern.count == rows * columns else { throw Error.shape }
        let k = kernel ?? defaultKernel(rows: rows, columns: columns)
        guard k.rows >= 1, k.columns >= 1 else { throw Error.shape }
        guard clipLimit.isFinite, clipLimit >= 0 else { throw Error.parameter("clip limit") }
        guard bins >= 1 else { throw Error.parameter("bins") }
        // `img_as_uint`: 8-bit values scaled by 65535 / 255 = 257, 16-bit kept.
        let scale: Int
        switch P.bitWidth {
        case 8: scale = 257
        case 16: scale = 1
        default: throw Error.shape
        }
        let u = pattern.map { Int($0) * scale }
        // `rescale_intensity(image, out_range=(0, NR_OF_GRAY - 1))`, rounded half to even.
        let quantised = quantise(u)
        let equalised = clahe(quantised, rows: rows, columns: columns, kernel: k, clipLimit: clipLimit, bins: bins)
        // `rescale_intensity(image)` of the float64 image: its own minimum and maximum to [0, 1].
        let values = equalised.map { Double($0) }
        guard let lo = values.min(), let hi = values.max(), hi > lo else { throw Error.nonFinite }
        return values.map { ($0 - lo) / (hi - lo) }
    }

    /// The 16-bit image to 0 ... 2¹⁴ − 1: (x − min) / (max − min) · (2¹⁴ − 1), `np.round` (half to even). A flat image is
    /// clipped into the range instead (upstream's `imin == imax` branch).
    static func quantise(_ u: [Int]) -> [Int] {
        let top = Double(grayLevels - 1)
        guard let imin = u.min(), let imax = u.max() else { return [] }
        guard imax != imin else { return u.map { min(max($0, 0), grayLevels - 1) } }
        let lo = Double(imin), span = Double(imax) - Double(imin)
        return u.map { Int(((Double($0) - lo) / span * top + 0).rounded(.toNearestOrEven)) }
    }

    /// NumPy's `mode="reflect"` index (the edge pixel not repeated), for any distance outside `0 ..< n`.
    static func reflect(_ i: Int, _ n: Int) -> Int {
        guard n > 1 else { return 0 }
        let period = 2 * (n - 1)
        var m = i % period
        if m < 0 { m += period }
        return m < n ? m : period - m
    }

    /// `_clahe(image, kernel_size, clip_limit, nbins)` on the quantised image: the equalised 2¹⁴-level image (upstream's uint16).
    static func clahe(_ image: [Int], rows: Int, columns: Int, kernel: (rows: Int, columns: Int), clipLimit: Double, bins: Int) -> [Int] {
        let ky = kernel.rows, kx = kernel.columns
        // Padding: k // 2 before, (k − s % k) % k + ceil(k / 2) after, by reflection.
        let py = ky / 2, px = kx / 2
        let paddedRows = rows + py + (ky - rows % ky) % ky + (ky + 1) / 2
        let paddedColumns = columns + px + (kx - columns % kx) % kx + (kx + 1) / 2
        // The binning look-up: grey level // (1 + NR_OF_GRAY // nbins).
        let binSize = 1 + grayLevels / bins
        var padded = [Int](repeating: 0, count: paddedRows * paddedColumns)
        for i in 0..<paddedRows {
            let r = reflect(i - py, rows)
            for j in 0..<paddedColumns {
                padded[i * paddedColumns + j] = image[r * columns + reflect(j - px, columns)] / binSize
            }
        }
        // One histogram per contextual region of the hist grid, which starts k // 2 into the padded image.
        let hy = paddedRows / ky - 1, hx = paddedColumns / kx - 1
        let elements = ky * kx
        let limit = clipLimit > 0 ? max(Int(clipLimit * Double(elements)), 1) : elements
        let levelScale = Double(grayLevels - 1 - 0) / Double(elements)
        var maps = [[Int]](repeating: [], count: hy * hx)
        for by in 0..<hy {
            for bx in 0..<hx {
                var hist = [Int](repeating: 0, count: bins)
                for i in 0..<ky {
                    let rowBase = (py + by * ky + i) * paddedColumns + px + bx * kx
                    for j in 0..<kx { hist[padded[rowBase + j]] += 1 }
                }
                clipHistogram(&hist, limit: limit)
                // `map_histogram(hist, 0, NR_OF_GRAY - 1, kernel_elements)`: cumulative counts scaled, clipped, truncated.
                var sum = 0
                maps[by * hx + bx] = hist.map { count -> Int in
                    sum += count
                    let x = Double(sum) * levelScale + 0
                    return Int(min(x, Double(grayLevels - 1)))
                }
            }
        }
        // Interpolation over the k-sized blocks of the padded image: each pixel blends the mappings of the four regions around
        // its block (the region grid padded by one at every edge, `mode="edge"`), weights from the pixel's place in the block.
        let ny = paddedRows / ky, nx = paddedColumns / kx
        var out = [Int](repeating: 0, count: rows * columns)
        for by in 0..<ny {
            for bx in 0..<nx {
                func region(_ dy: Int, _ dx: Int) -> [Int] {
                    maps[min(max(by + dy - 1, 0), hy - 1) * hx + min(max(bx + dx - 1, 0), hx - 1)]
                }
                let m00 = region(0, 0), m01 = region(0, 1), m10 = region(1, 0), m11 = region(1, 1)
                for i in 0..<ky {
                    let pi = by * ky + i
                    guard pi >= py, pi < py + rows else { continue }
                    let rowFraction = Double(i) / Double(ky)
                    for j in 0..<kx {
                        let pj = bx * kx + j
                        guard pj >= px, pj < px + columns else { continue }
                        let columnFraction = Double(j) / Double(kx)
                        let bin = padded[pi * paddedColumns + pj]
                        // scikit-image's order: regions (0, 0), (0, 1), (1, 0), (1, 1) as (row, column) offsets; each term
                        // mapping · (column weight · row weight) in float64, rounded to float32, summed in float32.
                        let c1 = columnFraction, c0 = 1 - columnFraction
                        let r1 = rowFraction, r0 = 1 - rowFraction
                        var acc: Float = 0
                        acc += Float(Double(m00[bin]) * (c0 * r0))
                        acc += Float(Double(m01[bin]) * (c1 * r0))
                        acc += Float(Double(m10[bin]) * (c0 * r1))
                        acc += Float(Double(m11[bin]) * (c1 * r1))
                        out[(pi - py) * columns + (pj - px)] = Int(acc)
                    }
                }
            }
        }
        return out
    }

    /// `clip_histogram(hist, clip_limit)`: the counts above the limit cut off and handed back evenly, then one by one in
    /// strides over the bins still below the limit, exactly as scikit-image redistributes them.
    package static func clipHistogram(_ hist: inout [Int], limit: Int) {
        let n = hist.count
        var excess = 0
        for i in 0..<n where hist[i] > limit {
            excess += hist[i] - limit
            hist[i] = limit
        }
        let increment = excess / n
        let upper = limit - increment
        for i in 0..<n where hist[i] < upper {
            hist[i] += increment
            excess -= increment
        }
        for i in 0..<n where hist[i] >= upper && hist[i] < limit {
            excess += hist[i] - limit
            hist[i] = limit
        }
        while excess > 0 {
            let previous = excess
            for index in 0..<n {
                let under = hist.reduce(0) { $0 + ($1 < limit ? 1 : 0) }
                let step = max(1, under / excess)
                var added = 0
                var j = index
                while j < n {
                    if hist[j] < limit {
                        hist[j] += 1
                        added += 1
                    }
                    j += step
                }
                excess -= added
                if excess <= 0 { break }
            }
            if previous == excess { break }
        }
    }
}
