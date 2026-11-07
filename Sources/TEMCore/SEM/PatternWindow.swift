//
//  PatternWindow.swift
//  The windows and transfer functions of EBSD pattern filtering: kikuchipy 0.13.1's `filters.window.Window` (its
//  `lowpass_fft_filter`, `highpass_fft_filter`, `modified_hann`, `distance_to_origin` and `make_circular`) and the SciPy
//  windows it takes by name (`scipy.signal.windows.gaussian` and `boxcar` with `fftbins=False`, i.e. symmetric), ported
//  formula by formula in float64. The parity references are `tools/parity/sem/emit.py`'s `m2/fft-filter-*` and
//  `m2/average-neighbours-*` bundles; the rows are in docs/parity.md.
//
//  A window is a row-major grid of `rows` x `columns` weights. kikuchipy's 1D window of length n (shape `(n,)`) is the
//  n x 1 grid here; a 2D window built from a 1D SciPy window is the outer product of the rows' and the columns' 1D windows,
//  as upstream builds it. The origin is `(rows / 2, columns / 2)` (upstream's `shape // 2`).
//

import Foundation

package nonisolated struct PatternWindow: Sendable, Equatable {
    package enum Error: Swift.Error, Equatable, Sendable {
        /// A size below 1, or a weight count that is not `rows * columns`.
        case shape
        /// A parameter is not finite or not positive where it must be (cutoff, cutoff width, std).
        case parameter(String)
    }

    /// The window's kind, as kikuchipy names it (`Window.name`).
    package enum Kind: String, Sendable, Equatable {
        case custom, lowpass, highpass, modifiedHann = "modified_hann", gaussian, rectangular, circular
    }

    package let kind: Kind
    package let rows: Int
    package let columns: Int
    /// Row-major weights, `rows * columns` of them.
    package let values: [Double]

    /// A custom window or kernel (upstream: an `np.ndarray` passed as `window`).
    package init(rows: Int, columns: Int, values: [Double]) throws {
        try self.init(kind: .custom, rows: rows, columns: columns, values: values)
    }

    private init(kind: Kind, rows: Int, columns: Int, values: [Double]) throws {
        guard rows >= 1, columns >= 1, values.count == rows * columns else { throw Error.shape }
        self.kind = kind
        self.rows = rows
        self.columns = columns
        self.values = values
    }

    /// `Window.origin`: the centre pixel, `shape // 2`.
    package var origin: (row: Int, column: Int) { (rows / 2, columns / 2) }

    /// The weight at `(row, column)`.
    package subscript(row: Int, column: Int) -> Double { values[row * columns + column] }

    /// Element-wise product, upstream's `w_low * w_high` (a combined transfer function). Same shape required.
    package static func * (lhs: PatternWindow, rhs: PatternWindow) throws -> PatternWindow {
        guard lhs.rows == rhs.rows, lhs.columns == rhs.columns else { throw Error.shape }
        return try PatternWindow(kind: .custom, rows: lhs.rows, columns: lhs.columns,
                                 values: zip(lhs.values, rhs.values).map { $0 * $1 })
    }

    // MARK: - Distance to the origin

    /// `distance_to_origin(shape)`: the Euclidean distance of every pixel to `shape // 2`, row-major.
    package static func distanceToOrigin(rows: Int, columns: Int) -> [Double] {
        let oy = rows / 2, ox = columns / 2
        var d = [Double](repeating: 0, count: rows * columns)
        for i in 0..<rows {
            for j in 0..<columns {
                let dy = i - oy, dx = j - ox
                d[i * columns + j] = Double(dy * dy + dx * dx).squareRoot()
            }
        }
        return d
    }

    // MARK: - FFT transfer functions

    /// `lowpass_fft_filter(shape, cutoff, cutoff_width)`: one inside `cutoff` (pixels from the centre of the shifted
    /// spectrum), a Gaussian roll-off exp(−((r − cutoff) / (√2 · w / 2))²) outside, zero beyond `cutoff + 2w`.
    /// `cutoffWidth` defaults to `cutoff / 2`.
    package static func lowpass(rows: Int, columns: Int, cutoff: Double, cutoffWidth: Double? = nil) throws -> PatternWindow {
        let width = try transferParameters(rows: rows, columns: columns, cutoff: cutoff, cutoffWidth: cutoffWidth)
        let s = 2.0.squareRoot() * width / 2
        let values = distanceToOrigin(rows: rows, columns: columns).map { r -> Double in
            if r < cutoff { return 1 }
            if r > cutoff + 2 * width { return 0 }
            let x = (r - cutoff) / s
            return exp(-(x * x))
        }
        return try PatternWindow(kind: .lowpass, rows: rows, columns: columns, values: values)
    }

    /// `highpass_fft_filter(shape, cutoff, cutoff_width)`: one beyond `cutoff`, exp(−((cutoff − r) / (√2 · w / 2))²) inside,
    /// zero below `cutoff − 2w`. `cutoffWidth` defaults to `cutoff / 2`.
    package static func highpass(rows: Int, columns: Int, cutoff: Double, cutoffWidth: Double? = nil) throws -> PatternWindow {
        let width = try transferParameters(rows: rows, columns: columns, cutoff: cutoff, cutoffWidth: cutoffWidth)
        let s = 2.0.squareRoot() * width / 2
        let values = distanceToOrigin(rows: rows, columns: columns).map { r -> Double in
            if r > cutoff { return 1 }
            if r < cutoff - 2 * width { return 0 }
            let x = (cutoff - r) / s
            return exp(-(x * x))
        }
        return try PatternWindow(kind: .highpass, rows: rows, columns: columns, values: values)
    }

    private static func transferParameters(rows: Int, columns: Int, cutoff: Double, cutoffWidth: Double?) throws -> Double {
        guard rows >= 1, columns >= 1 else { throw Error.shape }
        guard cutoff.isFinite, cutoff > 0 else { throw Error.parameter("cutoff") }
        let width = cutoffWidth ?? cutoff / 2
        guard width.isFinite, width > 0 else { throw Error.parameter("cutoff width") }
        return width
    }

    // MARK: - Windows by name

    /// `modified_hann(Nx)`: cos(π (n − Nx/2 + 1/2) / Nx), an apodisation window; with `columns` it is the outer product of
    /// the `rows`- and `columns`-long windows, upstream's 2D form.
    package static func modifiedHann(rows: Int, columns: Int = 1) throws -> PatternWindow {
        guard rows >= 1, columns >= 1 else { throw Error.shape }
        func line(_ n: Int) -> [Double] {
            (0..<n).map { cos(Double.pi * (Double($0) - Double(n) / 2 + 0.5) / Double(n)) }
        }
        return try PatternWindow(kind: .modifiedHann, rows: rows, columns: columns, values: outer(line(rows), columns == 1 ? [1] : line(columns)))
    }

    /// `scipy.signal.windows.gaussian(M, std, sym=True)` per axis, outer product for two axes: exp(−n² / 2σ²) at
    /// n = k − (M − 1)/2. Not normalised (upstream does not).
    package static func gaussian(rows: Int, columns: Int = 1, std: Double) throws -> PatternWindow {
        guard rows >= 1, columns >= 1 else { throw Error.shape }
        guard std.isFinite, std > 0 else { throw Error.parameter("std") }
        func line(_ m: Int) -> [Double] {
            let centre = (Double(m) - 1) / 2
            let sig2 = 2 * std * std
            return (0..<m).map { k in
                let n = Double(k) - centre
                return exp(-(n * n) / sig2)
            }
        }
        return try PatternWindow(kind: .gaussian, rows: rows, columns: columns, values: outer(line(rows), columns == 1 ? [1] : line(columns)))
    }

    /// `boxcar` / `rectangular`: all ones.
    package static func rectangular(rows: Int, columns: Int = 1) throws -> PatternWindow {
        guard rows >= 1, columns >= 1 else { throw Error.shape }
        return try PatternWindow(kind: .rectangular, rows: rows, columns: columns, values: .init(repeating: 1, count: rows * columns))
    }

    /// kikuchipy's `"circular"` window (its default for neighbour averaging): ones, with every weight farther from the
    /// origin than the longer half-axis (`max(origin)`) set to zero (`make_circular`). A 1D window stays all ones.
    package static func circular(rows: Int, columns: Int) throws -> PatternWindow {
        guard rows >= 1, columns >= 1 else { throw Error.shape }
        guard rows > 1, columns > 1 else {
            return try PatternWindow(kind: .circular, rows: rows, columns: columns, values: .init(repeating: 1, count: rows * columns))
        }
        let radius = Double(max(rows / 2, columns / 2))
        let values = distanceToOrigin(rows: rows, columns: columns).map { $0 > radius ? 0.0 : 1.0 }
        return try PatternWindow(kind: .circular, rows: rows, columns: columns, values: values)
    }

    private static func outer(_ a: [Double], _ b: [Double]) -> [Double] {
        var out = [Double]()
        out.reserveCapacity(a.count * b.count)
        for x in a { for y in b { out.append(x * y) } }
        return out
    }
}
