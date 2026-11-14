//
//  PatternProcessing.swift
//  Background removal, intensity and binning of EBSD patterns: kikuchipy 0.13.1's `pattern._pattern` (`_remove_static_background_subtract`
//  / `_divide`, `_remove_background_subtract` / `_divide`, `_rescale_with_min_max`, `get_dynamic_background`,
//  `_dynamic_background_frequency_space_setup`, `rescale_intensity`, `_normalize_intensity`, `_downsample2d`, `_bin2d`) and `filters.fft_barnes._fft_filter`, ported function by function; the parity
//  references are `tools/parity/sem/background_reference.py` and the rows are in docs/parity.md.
//
//  Numbers: kikuchipy works in float32 (numba, fastmath) and casts the rescaled pattern back to the input dtype by truncation.
//  Everything here is float64 (the reference path, decision D16): the rescaled values agree within 1e-5 relative, and the cast
//  pattern within one grey level where kikuchipy's float32 rounding lands on the other side of an integer (measured on the
//  4125 nickel patterns: at most 0.11 % of the pixels of a whole set, docs/parity.md).
//
//  The frequency-domain background: kikuchipy pads the pattern by edge replication, convolves it with a 2D Gaussian window of
//  `int(truncate * std)` px per side through a padded real FFT and crops. That window is `scipy.signal.windows.gaussian`'s
//  outer product with itself, so the operator is the separable correlation with the 1D window under nearest-edge reads; the
//  taps of output pixel i are i − (M − h − 1) ... i + h with h = (M − 1) / 2 (the window's `origin`), which is i − 15 ... i + 14
//  for the default 30 px window and symmetric for an odd one. This file computes exactly that, in float64, instead of
//  rebuilding the padded FFT (same numbers within float32 rounding, no padding bookkeeping; decision D-SEM-17).
//  The spatial-domain background is SciPy's `gaussian_filter` (mode reflect), ImagoKit's `SeparableFilters.gaussianFilter`.
//

import Foundation
import ImagoFilters

package nonisolated enum PatternProcessing {
    /// kikuchipy's `operation`: the background is subtracted from or divided into the pattern.
    package enum Operation: String, Sendable, Codable, CaseIterable, Identifiable {
        case subtract, divide
        package var id: String { rawValue }
        package var title: String { rawValue.capitalized }
    }

    /// kikuchipy's `filter_domain`: the dynamic background by the FFT Gaussian filter or by `scipy.ndimage.gaussian_filter`.
    package enum FilterDomain: String, Sendable, Codable, CaseIterable, Identifiable {
        case frequency, spatial
        package var id: String { rawValue }
        package var title: String { rawValue.capitalized }
    }

    package enum Error: Swift.Error, Equatable, Sendable, LocalizedError {
        /// A count does not match `rows * columns`, or a size is below 1.
        case shape
        /// `std` or `truncate` is not positive and finite, or the window they give has no pixel or is wider than `maximumWindow`.
        case parameter(String)
        /// A division made an infinite or undefined value (a zero in the background), so the pattern cannot be rescaled.
        case nonFinite

        package var errorDescription: String? {
            switch self {
            case .shape: "The pattern's values do not match its size, or a size is zero."
            case .parameter(let name): "The \(name) is out of range for this pattern."
            case .nonFinite: "This pattern is flat or holds an undefined value, so it cannot be rescaled."
            }
        }
    }

    // MARK: - Rescaling (`_rescale_with_min_max`)

    /// `_rescale_with_min_max(x, min(x), max(x), omin, omax)`: the values stretched linearly so the minimum lands on `omin`
    /// and the maximum on `omax`. A flat array (max == min) divides by zero as kikuchipy does and throws `.nonFinite`.
    package static func rescale(_ values: [Double], toMin omin: Double, max omax: Double) throws -> [Double] {
        guard let imin = values.min(), let imax = values.max(), imin.isFinite, imax.isFinite else { throw Error.nonFinite }
        let scale = (omax - omin) / (imax - imin)
        guard scale.isFinite else { throw Error.nonFinite }
        return values.map { ($0 - imin) * scale + omin }
    }

    /// The pattern's data-type range (`skimage.util.dtype.dtype_range`): 0 to the type's maximum for an unsigned integer.
    package static func range<P: FixedWidthInteger & UnsignedInteger>(of _: P.Type) -> (min: Double, max: Double) {
        (0, Double(P.max))
    }

    /// Rescaled values cast back to the pattern's type the way `astype` does: truncation toward zero. Every value is already in
    /// the type's range (`rescale` put the minimum and maximum there); the clamp guards the last bit of rounding.
    package static func cast<P: FixedWidthInteger & UnsignedInteger>(_ values: [Double], to _: P.Type) throws -> [P] {
        let top = Double(P.max)
        return try values.map { v -> P in
            guard v.isFinite else { throw Error.nonFinite }
            return P(min(max(v, 0), top))
        }
    }

    // MARK: - Static background

    /// The mean of `count` patterns of `pixels` values each, cast to the pattern type by truncation (`patterns.mean(axis=0)
    /// .astype(dtype)`): the static background of a file that carries none.
    package static func meanBackground<P: FixedWidthInteger & UnsignedInteger>(of patterns: [P], count: Int, pixels: Int) throws -> [P] {
        guard count >= 1, pixels >= 1, patterns.count == count * pixels else { throw Error.shape }
        var sum = [Double](repeating: 0, count: pixels)
        patterns.withUnsafeBufferPointer { p in
            for i in 0..<count {
                let base = i * pixels
                for j in 0..<pixels { sum[j] += Double(p[base + j]) }
            }
        }
        let n = Double(count)
        return sum.map { P(min(max(($0 / n).rounded(.towardZero), 0), Double(P.max))) }
    }

    /// `_remove_static_background_subtract` / `_divide` before the cast: the pattern minus (or over) the background, rescaled to
    /// the pattern type's range. `scaleBackground` is kikuchipy's `scale_bg`: the background first stretched to the pattern's
    /// own minimum and maximum.
    package static func removeStaticBackgroundValues<P: FixedWidthInteger & UnsignedInteger>(
        _ pattern: [P], background: [P], operation: Operation, scaleBackground: Bool = false
    ) throws -> [Double] {
        guard !pattern.isEmpty, pattern.count == background.count else { throw Error.shape }
        let p = pattern.map { Double($0) }
        var b = background.map { Double($0) }
        if scaleBackground, let lo = p.min(), let hi = p.max() { b = try rescale(b, toMin: lo, max: hi) }   // an empty pattern has nothing to scale to
        let (omin, omax) = range(of: P.self)
        return try rescale(combine(p, b, operation), toMin: omin, max: omax)
    }

    /// `_remove_static_background_subtract` / `_divide`: `removeStaticBackgroundValues` cast back to the pattern type.
    package static func removeStaticBackground<P: FixedWidthInteger & UnsignedInteger>(
        _ pattern: [P], background: [P], operation: Operation = .subtract, scaleBackground: Bool = false
    ) throws -> [P] {
        try cast(removeStaticBackgroundValues(pattern, background: background, operation: operation, scaleBackground: scaleBackground), to: P.self)
    }

    // MARK: - Dynamic background

    /// `get_dynamic_background`: the Gaussian-blurred pattern, by the frequency-domain operator (the padded FFT filter's
    /// numbers, see the header) or by `scipy.ndimage.gaussian_filter`. `std` defaults to the pattern width / 8, as kikuchipy;
    /// `truncate` is the window's extent in standard deviations (frequency: a window of `int(truncate * std)` px; spatial:
    /// SciPy's radius `int(truncate * std + 0.5)`).
    package static func dynamicBackground(
        _ pattern: [Double], rows: Int, columns: Int, domain: FilterDomain = .frequency, std: Double? = nil, truncate: Double = 4
    ) throws -> [Double] {
        guard rows >= 1, columns >= 1, pattern.count == rows * columns else { throw Error.shape }
        let sigma = std ?? Double(columns) / 8
        guard sigma.isFinite, sigma > 0 else { throw Error.parameter("std") }
        guard truncate.isFinite, truncate > 0 else { throw Error.parameter("truncate") }
        switch domain {
        case .frequency:
            let window = try gaussianWindow(std: sigma, truncate: truncate)
            let byRows = correlateNearest(pattern, rows: rows, columns: columns, window: window, alongRows: true)
            return correlateNearest(byRows, rows: rows, columns: columns, window: window, alongRows: false)
        case .spatial:
            do {
                return try SeparableFilters.gaussianFilter(pattern, rows: rows, columns: columns, sigma: (row: sigma, column: sigma), truncate: truncate)
            } catch FilterError.parameter(let name) {
                throw Error.parameter(name)
            } catch {
                throw Error.shape
            }
        }
    }

    /// `_remove_dynamic_background` before the cast: the pattern minus (or over) its dynamic background, rescaled to the pattern
    /// type's range.
    package static func removeDynamicBackgroundValues<P: FixedWidthInteger & UnsignedInteger>(
        _ pattern: [P], rows: Int, columns: Int, operation: Operation = .subtract, domain: FilterDomain = .frequency,
        std: Double? = nil, truncate: Double = 4
    ) throws -> [Double] {
        let p = pattern.map { Double($0) }
        let b = try dynamicBackground(p, rows: rows, columns: columns, domain: domain, std: std, truncate: truncate)
        let (omin, omax) = range(of: P.self)
        return try rescale(combine(p, b, operation), toMin: omin, max: omax)
    }

    /// `_remove_dynamic_background`: `removeDynamicBackgroundValues` cast back to the pattern type.
    package static func removeDynamicBackground<P: FixedWidthInteger & UnsignedInteger>(
        _ pattern: [P], rows: Int, columns: Int, operation: Operation = .subtract, domain: FilterDomain = .frequency,
        std: Double? = nil, truncate: Double = 4
    ) throws -> [P] {
        try cast(removeDynamicBackgroundValues(pattern, rows: rows, columns: columns, operation: operation, domain: domain,
                                               std: std, truncate: truncate), to: P.self)
    }

    // MARK: - Intensity (`rescale_intensity`, `normalize_intensity`)

    /// numpy's `nanpercentile(x, q)` with the default `linear` method (no NaN can occur in an integer pattern): the virtual
    /// index `n·q + (1 − q) − 1` on the sorted values (`_compute_virtual_index` with alpha = beta = 1) and numpy's `_lerp`,
    /// which interpolates from the upper neighbour when the fraction is at least one half. `q` is a percentage, 0 to 100.
    package static func percentile(_ values: [Double], _ q: Double) throws -> Double {
        guard !values.isEmpty else { throw Error.shape }
        guard q.isFinite, q >= 0, q <= 100 else { throw Error.parameter("percentile") }
        let sorted = values.sorted()
        let n = sorted.count
        let quantile = q / 100
        let virtual = Double(n) * quantile + (1 + quantile * (1 - 1 - 1)) - 1
        let lower = min(max(Int(virtual.rounded(.down)), 0), n - 1)
        let upper = min(lower + 1, n - 1)
        let gamma = min(max(virtual - Double(lower), 0), 1)
        let a = sorted[lower], b = sorted[upper]
        let diff = b - a
        return gamma >= 0.5 ? b - diff * (1 - gamma) : a + diff * gamma
    }

    /// `kikuchipy.pattern.rescale_intensity(pattern, percentiles=…)` before the cast: the input range is the pattern's own
    /// minimum and maximum, or its `percentiles` (low, high) with the pattern clipped to them; that range is stretched onto
    /// the pattern type's range. A flat pattern (or a flat percentile range) divides by zero as kikuchipy does and throws.
    package static func rescaleIntensityValues<P: FixedWidthInteger & UnsignedInteger>(
        _ pattern: [P], percentiles: (low: Double, high: Double)? = nil
    ) throws -> [Double] {
        guard !pattern.isEmpty else { throw Error.shape }
        var p = pattern.map { Double($0) }
        let imin: Double, imax: Double
        if let percentiles {
            imin = try percentile(p, percentiles.low)
            imax = try percentile(p, percentiles.high)
            p = p.map { Swift.min(Swift.max($0, imin), imax) }
        } else {
            imin = p.min() ?? 0   // not empty (guarded above)
            imax = p.max() ?? 0
        }
        let (omin, omax) = range(of: P.self)
        let span = imax - imin
        guard span != 0, span.isFinite else { throw Error.nonFinite }
        // `_rescale_with_min_max` is compiled with fastmath, which turns the division into a product with the reciprocal:
        // 98 · (1/255) · 255 is 97.99…, truncated to 97, where 98 / 255 · 255 is 98. The reciprocal makes the cast exact.
        let reciprocal = 1 / span
        return p.map { ($0 - imin) * reciprocal * (omax - omin) + omin }
    }

    /// `rescale_intensity`: `rescaleIntensityValues` cast back to the pattern type by truncation.
    package static func rescaleIntensity<P: FixedWidthInteger & UnsignedInteger>(
        _ pattern: [P], percentiles: (low: Double, high: Double)? = nil
    ) throws -> [P] {
        try cast(rescaleIntensityValues(pattern, percentiles: percentiles), to: P.self)
    }

    /// `_normalize_intensity`: zero mean and `numStd` population standard deviations, optionally also divided by the square
    /// root of the pixel count. kikuchipy keeps the input dtype, so the room converts a pattern to float32 first and the result
    /// is float32 (computed in float64 here; within 1e-5 relative of kikuchipy's fastmath float32 numbers).
    package static func normalizeIntensity(_ pattern: [Double], numStd: Double = 1, divideBySquareRoot: Bool = false) throws -> [Float] {
        guard !pattern.isEmpty else { throw Error.shape }
        guard numStd.isFinite, numStd > 0 else { throw Error.parameter("num_std") }
        let n = Double(pattern.count)
        let mean = pattern.reduce(0, +) / n
        let variance = pattern.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / n
        var scale = numStd * variance.squareRoot()
        if divideBySquareRoot { scale *= n.squareRoot() }
        guard scale > 0, scale.isFinite else { throw Error.nonFinite }
        return pattern.map { Float(($0 - mean) / scale) }
    }

    // MARK: - Size (`EBSD.downsample`)

    /// `_downsample2d`: the pattern binned by `factor` (`_bin2d`: each `factor` × `factor` block summed), rescaled to the
    /// pattern type's range from its own minimum and maximum and cast by truncation. `rows` and `columns` must be multiples of
    /// `factor` (kikuchipy refuses the rest and points at `crop`). kikuchipy's kernel casts to float32 first and works in
    /// float32 under fastmath (the division a product with the reciprocal); this does the same, so the cast agrees exactly
    /// (both reference bundles, factors 2 and 3). The sums are exact in float32 for 8 and 16 bit patterns up to a factor of 8.
    package static func downsample<P: FixedWidthInteger & UnsignedInteger>(
        _ pattern: [P], rows: Int, columns: Int, factor: Int
    ) throws -> [P] {
        guard rows >= 1, columns >= 1, pattern.count == rows * columns else { throw Error.shape }
        guard factor >= 1, rows % factor == 0, columns % factor == 0 else { throw Error.parameter("factor") }
        if factor == 1 { return pattern }
        let binned = bin(pattern.map { Float($0) }, rows: rows, columns: columns, factor: factor)
        guard let imin = binned.min(), let imax = binned.max(), imax > imin else { throw Error.nonFinite }
        let reciprocal = Float(1 / Double(imax - imin))
        let top = Float(P.max)
        return binned.map { P(min(max(($0 - imin) * reciprocal * top, 0), top)) }
    }

    /// `_downsample2d` on a float32 pattern (a normalised one): binned, then rescaled to float32's `dtype_range`, [-1, 1].
    package static func downsampleFloat(_ pattern: [Float], rows: Int, columns: Int, factor: Int) throws -> [Float] {
        guard rows >= 1, columns >= 1, pattern.count == rows * columns else { throw Error.shape }
        guard factor >= 1, rows % factor == 0, columns % factor == 0 else { throw Error.parameter("factor") }
        if factor == 1 { return pattern }
        let binned = bin(pattern, rows: rows, columns: columns, factor: factor)
        guard let imin = binned.min(), let imax = binned.max(), imax > imin, imin.isFinite, imax.isFinite else { throw Error.nonFinite }
        let reciprocal = Float(1 / Double(imax - imin))
        return binned.map { ($0 - imin) * reciprocal * 2 - 1 }
    }

    /// `_bin2d`: the sum of each `factor` × `factor` block, row-major, `rows / factor` × `columns / factor` values.
    package static func bin<T: BinaryFloatingPoint>(_ pattern: [T], rows: Int, columns: Int, factor: Int) -> [T] {
        let r = rows / factor, c = columns / factor
        var out = [T](repeating: 0, count: r * c)
        for i in 0..<(r * factor) {
            let base = i * columns, target = (i / factor) * c
            for j in 0..<(c * factor) { out[target + j / factor] += pattern[base + j] }
        }
        return out
    }

    // MARK: - Pieces

    /// `pattern - background` or `pattern / background`, element by element.
    static func combine(_ p: [Double], _ b: [Double], _ operation: Operation) -> [Double] {
        switch operation {
        case .subtract: zip(p, b).map { $0 - $1 }
        case .divide: zip(p, b).map { $0 / $1 }
        }
    }

    /// The widest frequency-domain Gaussian window, 2²⁰ px: far wider than any pattern. A wider `truncate * std` is refused
    /// before the window is allocated or converted to `Int` (a typed truncate of 1e300 would trap there).
    package static let maximumWindow = 1 << 20

    /// kikuchipy's dynamic-background window along one axis: `scipy.signal.windows.gaussian(M, std, sym=True)` with
    /// `M = int(truncate * std)` — exp(−n² / 2σ²) at n = 0 − (M − 1)/2 ... (M − 1)/2 — normalised to a sum of one (the
    /// 1 / 2πσ² factor cancels in that normalisation). A window of one pixel is [1]; one under a pixel or over `maximumWindow`
    /// is refused.
    static func gaussianWindow(std: Double, truncate: Double) throws -> [Double] {
        let extent = truncate * std
        // `int(x) >= 1` is `x >= 1`; a nan fails both comparisons.
        guard extent >= 1, extent <= Double(maximumWindow) else { throw Error.parameter("truncate · std") }
        let m = Int(extent)
        if m == 1 { return [1] }
        let centre = Double(m - 1) / 2
        let w = (0..<m).map { n in exp(-pow(Double(n) - centre, 2) / (2 * std * std)) }
        let sum = w.reduce(0, +)
        return w.map { $0 / sum }
    }

    /// The separable correlation of one axis with `window` under nearest-edge reads, with the padded FFT filter's taps:
    /// output i sums window[j] · x[clamp(i + j − lead)] for j in 0 ..< M, lead = M − (M − 1)/2 − 1 (`_offset_before_fft`).
    static func correlateNearest(_ x: [Double], rows: Int, columns: Int, window: [Double], alongRows: Bool) -> [Double] {
        let m = window.count
        let lead = m - (m - 1) / 2 - 1
        let length = alongRows ? rows : columns   // the axis the window runs along
        let lines = alongRows ? columns : rows    // the other one
        let stride = alongRows ? columns : 1       // step between neighbours along the axis
        let lineStride = alongRows ? 1 : columns   // step between lines
        var out = [Double](repeating: 0, count: rows * columns)
        x.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                window.withUnsafeBufferPointer { w in
                    for line in 0..<lines {
                        let base = line * lineStride
                        for i in 0..<length {
                            var acc = 0.0
                            for j in 0..<m {
                                let k = min(max(i + j - lead, 0), length - 1)
                                acc += w[j] * src[base + k * stride]
                            }
                            dst[base + i * stride] = acc
                        }
                    }
                }
            }
        }
        return out
    }
}
