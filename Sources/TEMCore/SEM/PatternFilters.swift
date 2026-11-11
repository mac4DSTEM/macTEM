//
//  PatternFilters.swift
//  FFT filtering of EBSD patterns: kikuchipy 0.13.1's `EBSD.fft_filter` in both of its domains, ported step by step in float64.
//  - "frequency": `pattern._pattern.fft_filter` — the pattern's 2D FFT (`scipy.fft.fft2`), multiplied by a transfer function
//    of the pattern's shape (with `shift`, the function is laid out for the zero frequency at the centre, upstream's
//    `fftshift` / `ifftshift` pair), the real part of the inverse FFT.
//  - "spatial": `filters.fft_barnes._fft_filter` (Barnes et al. 2016) — the pattern padded by edge replication, the kernel
//    flipped into the corner of a zero array of the padded shape, their FFTs multiplied, the inverse cropped: the
//    correlation of the pattern with the kernel under nearest-edge reads. Upstream pads to SciPy's `next_fast_len`; here the
//    padded shape is exactly pattern + kernel − 1 per axis (the extra zeros upstream adds are never read by the crop), and the
//    FFT is ImagoKit's `FFT2DDouble` (any length).
//  Both rescale the filtered pattern per pattern to the data type's range and cast by truncation
//  (`pattern.chunk.fft_filter` → `rescale_intensity`), as `PatternProcessing` does for the backgrounds.
//
//  Numbers: kikuchipy runs the FFTs in float32; ours are float64 (decision D16's reference path). The rescaled values agree
//  within 1e-5 relative or 1e-3 grey levels, the cast patterns within one grey level (measured on all 4125 patterns of
//  nickel_ebsd_large: 0.005 % of the pixels, at most 2 of a pattern). The references are the `m2/fft-filter-*` bundles of
//  `tools/parity/sem/emit.py`; north-star figure F4 is pattern (0, 0) after the guide's lowpass x highpass filter.
//

import Foundation
import ImagoCore

package nonisolated enum PatternFilters {
    package enum Error: Swift.Error, Equatable, Sendable, LocalizedError {
        /// A count does not match `rows * columns`, a transfer function is not the pattern's shape, or a size is below 1.
        case shape
        /// The FFT for this shape could not be set up.
        case fft
        /// The filtered pattern is flat or not finite, so it cannot be rescaled.
        case nonFinite

        package var errorDescription: String? {
            switch self {
            case .shape: "The pattern's values or the filter do not match the pattern's size."
            case .fft: "The FFT for this pattern size could not be set up."
            case .nonFinite: "The filtered pattern is flat or not finite, so it cannot be rescaled."
            }
        }
    }

    /// kikuchipy's `function_domain`.
    package enum Domain: String, Sendable, CaseIterable, Identifiable {
        case frequency, spatial
        package var id: String { rawValue }
    }

    // MARK: - Frequency domain

    /// `fft_filter(pattern, transfer_function, shift)`: Re(IFFT(FFT(pattern) · H)), H laid out as upstream lays it: with
    /// `shift`, the transfer function's centre (`shape // 2`) multiplies the zero frequency.
    package static func frequencyFiltered(_ pattern: [Double], rows: Int, columns: Int, transferFunction h: PatternWindow,
                                          shift: Bool) throws -> [Double] {
        guard rows >= 1, columns >= 1, pattern.count == rows * columns, h.rows == rows, h.columns == columns else { throw Error.shape }
        guard let fft = FFT2DDouble(nx: columns, ny: rows) else { throw Error.fft }
        var re = pattern
        var im = [Double](repeating: 0, count: pattern.count)
        fft.transform(re: &re, im: &im, forward: true)
        // fftshift moves frequency u to (u + n/2) mod n; the product there is undone by ifftshift, so frequency u is
        // multiplied by H[(u + n/2) mod n] (H[u] without the shift).
        let sy = shift ? rows / 2 : 0, sx = shift ? columns / 2 : 0
        for u in 0..<rows {
            let hu = (u + sy) % rows
            for v in 0..<columns {
                let g = h.values[hu * columns + (v + sx) % columns]
                re[u * columns + v] *= g
                im[u * columns + v] *= g
            }
        }
        fft.transform(re: &re, im: &im, forward: false, scaleInverse: true)
        return re
    }

    // MARK: - Spatial domain (Barnes)

    /// `_fft_filter(image, …)` with `_fft_filter_setup(image.shape, window)`: the pattern correlated with `kernel` under
    /// nearest-edge reads, through the padded FFT. Output pixel (i, j) sums kernel[a, b] · pattern[clamp(i + a − ly),
    /// clamp(j + b − lx)] with l = k − (k − 1)/2 − 1 per axis (`_offset_before_fft`).
    package static func spatialFiltered(_ pattern: [Double], rows: Int, columns: Int, kernel: PatternWindow) throws -> [Double] {
        guard rows >= 1, columns >= 1, pattern.count == rows * columns else { throw Error.shape }
        let wy = kernel.rows, wx = kernel.columns
        let fy = rows + wy - 1, fx = columns + wx - 1
        let ay = (wy - 1) / 2, ax = (wx - 1) / 2      // `_offset_after_ifft`, and the replicated rows/columns after the image
        guard let fft = FFT2DDouble(nx: fx, ny: fy) else { throw Error.fft }
        // `_pad_image`: the image at the origin, its last row/column replicated (k − 1)/2 times after it, its first row/column
        // in the remaining `_offset_before_fft` rows/columns at the far end (they wrap around to just before the image).
        func source(_ p: Int, _ n: Int, _ after: Int) -> Int { p < n ? p : (p < n + after ? n - 1 : 0) }
        var re = [Double](repeating: 0, count: fy * fx)
        for p in 0..<fy {
            let r = source(p, rows, ay)
            for q in 0..<fx { re[p * fx + q] = pattern[r * columns + source(q, columns, ax)] }
        }
        var im = [Double](repeating: 0, count: fy * fx)
        // `_pad_window`: the kernel flipped in both axes, in the top-left corner.
        var kre = [Double](repeating: 0, count: fy * fx)
        for a in 0..<wy { for b in 0..<wx { kre[a * fx + b] = kernel.values[(wy - 1 - a) * wx + (wx - 1 - b)] } }
        var kim = [Double](repeating: 0, count: fy * fx)
        fft.transform(re: &re, im: &im, forward: true)
        fft.transform(re: &kre, im: &kim, forward: true)
        for k in 0..<(fy * fx) {
            let (a, b, c, d) = (re[k], im[k], kre[k], kim[k])
            re[k] = a * c - b * d
            im[k] = a * d + b * c
        }
        fft.transform(re: &re, im: &im, forward: false, scaleInverse: true)
        var out = [Double](repeating: 0, count: rows * columns)
        for i in 0..<rows { for j in 0..<columns { out[i * columns + j] = re[(ay + i) * fx + ax + j] } }
        return out
    }

    // MARK: - EBSD.fft_filter

    /// `EBSD.fft_filter` for one pattern before the cast: filtered in `domain` (`filter` is the transfer function for
    /// `.frequency`, the kernel for `.spatial`; `shift` is used by `.frequency` only), rescaled to the type's range.
    package static func fftFilterValues<P: FixedWidthInteger & UnsignedInteger>(
        _ pattern: [P], rows: Int, columns: Int, domain: Domain, filter: PatternWindow, shift: Bool = false
    ) throws -> [Double] {
        let p = pattern.map { Double($0) }
        let filtered: [Double]
        switch domain {
        case .frequency: filtered = try frequencyFiltered(p, rows: rows, columns: columns, transferFunction: filter, shift: shift)
        case .spatial: filtered = try spatialFiltered(p, rows: rows, columns: columns, kernel: filter)
        }
        let (omin, omax) = PatternProcessing.range(of: P.self)
        do {
            return try PatternProcessing.rescale(filtered, toMin: omin, max: omax)
        } catch {
            throw Error.nonFinite
        }
    }

    /// `EBSD.fft_filter` for one pattern: `fftFilterValues` cast back to the pattern type by truncation.
    package static func fftFilter<P: FixedWidthInteger & UnsignedInteger>(
        _ pattern: [P], rows: Int, columns: Int, domain: Domain, filter: PatternWindow, shift: Bool = false
    ) throws -> [P] {
        let values = try fftFilterValues(pattern, rows: rows, columns: columns, domain: domain, filter: filter, shift: shift)
        do {
            return try PatternProcessing.cast(values, to: P.self)
        } catch {
            throw Error.nonFinite
        }
    }
}
