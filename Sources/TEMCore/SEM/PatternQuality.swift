//
//  PatternQuality.swift
//  Pattern quality maps of an EBSD scan: the image quality of each pattern (Krieger Lassen 1994, "Automated determination
//  of crystal orientations from electron backscattering patterns", PhD thesis, DTU: the inertia of the pattern's FFT
//  power spectrum against the largest inertia the pattern shape allows) and the average neighbour dot product of each
//  pattern with its neighbours in the map (Brewick, Wright & Rowenhorst 2019, Ultramicroscopy 200, 50-61). Ported
//  function by function from kikuchipy 0.13.1 (GPL-3.0): `pattern._pattern.get_image_quality`, `_get_image_quality`,
//  `_get_image_quality_numba`, `fft_frequency_vectors`, `fft_spectrum`, `_normalize_intensity`, and
//  `signals.util._map_helper._get_average_dot_product_map`, `_neighbour_dot_products`, `_setup_window_indices` with
//  `filters.window.Window` (rectangular and circular). The parity bundles are `m2/quality-kikuchipy-h5ebsd` and
//  `m2/quality-nickel-ebsd-large` (north-star figure F3); the rows are in docs/parity.md.
//
//  Numbers: kikuchipy computes in float32 (the FFT of the float32 pattern, numba fastmath sums; the dot products in the
//  float32 output type). Everything here is float64 (the reference path, decision D16) and agrees within the float32
//  bound rtol 1e-5 (measured on the same patterns: 1e-7 for the image quality, 6e-7 for the dot products).
//
//  The edge rule of the dot-product map is SciPy's `generic_filter` with `mode="constant", cval=-1` as kikuchipy calls it:
//  window cells outside the map are not neighbours, so an edge pattern averages over fewer of them (a corner over two of
//  the default four); the centre is never its own neighbour. A pattern that is all one value has no direction (zero
//  norm): its dot products are NaN, which the average skips as `np.nanmean` does, and a pattern with no finite dot product
//  at all gets NaN.
//

import Foundation
import FormatoCore
import ImagoCore

package nonisolated enum PatternQuality {
    package enum Error: Swift.Error, Equatable, Sendable, LocalizedError {
        /// A count does not match the shape it claims, or a size is below 1.
        case shape
        /// The FFT plan for the pattern shape could not be made.
        case plan

        package var errorDescription: String? {
            switch self {
            case .shape: "The patterns do not match the scan and pattern sizes, or a size is zero."
            case .plan: "The FFT for this pattern size could not be set up."
            }
        }
    }

    // MARK: - Image quality

    /// `fft_frequency_vectors((rows, columns))`: each (unshifted) FFT bin's weight, (ky + 1)² + (kx + 1)² − 1 for the first
    /// half of each axis and (k − n)² + … for the second (kikuchipy's integer lines `arange(n) + 1`, `[n // 2:] -= n + 1`),
    /// row-major.
    package static func frequencyVectors(rows: Int, columns: Int) -> [Double] {
        func line(_ n: Int) -> [Double] {
            (0..<n).map { k in Double(k < n / 2 ? k + 1 : k - n) }
        }
        let ly = line(rows), lx = line(columns)
        var out = [Double](repeating: 0, count: rows * columns)
        for i in 0..<rows {
            for j in 0..<columns { out[i * columns + j] = ly[i] * ly[i] + lx[j] * lx[j] - 1 }
        }
        return out
    }

    /// The image quality of patterns of one shape: the FFT plan, the frequency vectors and the largest inertia
    /// (`sum(frequency_vectors) / (rows * columns)`), made once and used for every pattern of a map.
    package final class ImageQuality: @unchecked Sendable {
        package let rows: Int
        package let columns: Int
        package let frequencyVectors: [Double]
        package let inertiaMax: Double
        // FFT2DDouble keeps per-call scratch caller-owned, so one plan serves concurrent callers.
        private let fft: FFT2DDouble

        package init(rows: Int, columns: Int) throws {
            guard rows >= 1, columns >= 1 else { throw Error.shape }
            guard let plan = FFT2DDouble(nx: columns, ny: rows) else { throw Error.plan }
            self.rows = rows
            self.columns = columns
            fft = plan
            frequencyVectors = PatternQuality.frequencyVectors(rows: rows, columns: columns)
            inertiaMax = frequencyVectors.reduce(0, +) / Double(rows * columns)
        }

        /// `_get_image_quality`: the pattern normalised to mean 0 and standard deviation 1 (`normalize`, numpy's population
        /// standard deviation), its FFT spectrum |F|, the inertia Σ|F|·w / Σ|F|, and 1 − inertia / inertiaMax.
        package func callAsFunction(_ pattern: [Double], normalize: Bool = true) throws -> Double {
            let n = rows * columns
            guard pattern.count == n else { throw Error.shape }
            var re = pattern
            if normalize {
                let mean = re.reduce(0, +) / Double(n)
                var ss = 0.0
                for v in re { ss += (v - mean) * (v - mean) }
                let std = (ss / Double(n)).squareRoot()
                for i in 0..<n { re[i] = (re[i] - mean) / std }
            }
            var im = [Double](repeating: 0, count: n)
            fft.transform(re: &re, im: &im, forward: true)
            var weighted = 0.0, total = 0.0
            for i in 0..<n {
                let magnitude = (re[i] * re[i] + im[i] * im[i]).squareRoot()
                weighted += magnitude * frequencyVectors[i]
                total += magnitude
            }
            return 1 - (weighted / total) / inertiaMax
        }
    }

    /// `EBSD.get_image_quality(normalize)`: one value per map point, row-major over the scan. `pattern(row, column)` hands
    /// each pattern (detector row-major, `patternRows * patternColumns` values) and is asked row by row, in map order on the
    /// calling task (it need not be thread safe); each row's image qualities are computed on every core (`ScanRowWork`), each
    /// in its column's place. `progress` gets the finished fraction after each scan row; the task's cancellation stops the
    /// map between rows.
    @concurrent package static func imageQualityMap(
        scanRows: Int, scanColumns: Int, patternRows: Int, patternColumns: Int, normalize: Bool = true,
        progress: (@Sendable (Double) -> Void)? = nil,
        pattern: @Sendable (_ row: Int, _ column: Int) throws -> [Double]
    ) async throws -> [Double] {
        guard scanRows >= 1, scanColumns >= 1 else { throw Error.shape }
        let iq = try ImageQuality(rows: patternRows, columns: patternColumns)
        var out = [Double](repeating: 0, count: scanRows * scanColumns)
        for r in 0..<scanRows {
            try Task.checkCancellation()
            var read: [[Double]] = []
            read.reserveCapacity(scanColumns)
            for c in 0..<scanColumns { read.append(try pattern(r, c)) }
            let patterns = read
            let values = try ScanRowWork.map(columns: scanColumns) { (c: Int) throws -> Double in try iq(patterns[c], normalize: normalize) }
            for c in 0..<scanColumns { out[r * scanColumns + c] = values[c] }
            progress?(Double(r + 1) / Double(scanRows))
        }
        return out
    }

    // MARK: - Average neighbour dot product

    /// kikuchipy's `Window` for the neighbours: a `rows` x `columns` grid of ones with its origin at (rows // 2, columns // 2);
    /// `circular` zeroes the cells farther from the origin than the half width of the longest axis (`make_circular`; a
    /// single row or column loses no cell).
    package struct NeighbourWindow: Sendable, Equatable {
        package var rows: Int
        package var columns: Int
        package var circular: Bool

        package init(rows: Int = 3, columns: Int = 3, circular: Bool = true) {
            self.rows = rows
            self.columns = columns
            self.circular = circular
        }

        /// kikuchipy's default: 3 x 3 circular, the four nearest neighbours.
        package static let nearest = NeighbourWindow()

        package var origin: (row: Int, column: Int) { (rows / 2, columns / 2) }

        /// The window's cells, row-major: true where the coefficient is non-zero.
        package var mask: [Bool] {
            let (oy, ox) = origin
            let reach = Double(max(oy, ox))
            var out = [Bool](repeating: true, count: rows * columns)
            guard circular else { return out }
            for i in 0..<rows {
                for j in 0..<columns {
                    let d = (Double((i - oy) * (i - oy) + (j - ox) * (j - ox))).squareRoot()
                    if d > reach { out[i * columns + j] = false }
                }
            }
            return out
        }

        /// The neighbour offsets (row, column) relative to the origin, in the window's row-major order, origin excluded.
        package var offsets: [(row: Int, column: Int)] {
            let (oy, ox) = origin
            let m = mask
            var out: [(row: Int, column: Int)] = []
            for i in 0..<rows {
                for j in 0..<columns where m[i * columns + j] && !(i == oy && j == ox) { out.append((i - oy, j - ox)) }
            }
            return out
        }
    }

    /// The pattern as `_neighbour_dot_products` prepares it: minus its mean (`zeroMean`), then divided by its L2 norm
    /// (`normalize`, kikuchipy's `_normalize`: unit length, so the dot product of two prepared patterns is their
    /// normalised cross-correlation).
    package static func prepared(_ pattern: [Double], zeroMean: Bool = true, normalize: Bool = true) -> [Double] {
        var p = pattern
        if zeroMean {
            let mean = p.reduce(0, +) / Double(p.count)
            for i in p.indices { p[i] -= mean }
        }
        if normalize {
            var ss = 0.0
            for v in p { ss += v * v }
            let norm = ss.squareRoot()
            for i in p.indices { p[i] /= norm }
        }
        return p
    }

    private static func dot(_ a: [Double], _ b: [Double]) -> Double {
        var s = 0.0
        a.withUnsafeBufferPointer { x in
            b.withUnsafeBufferPointer { y in
                for i in 0..<x.count { s += x[i] * y[i] }
            }
        }
        return s
    }

    /// `EBSD.get_average_neighbour_dot_product_map(window, zero_mean, normalize)`: for every map point, the mean of the dot
    /// products of its prepared pattern with the prepared patterns of its neighbours inside the map (edge rule in the file
    /// header). Patterns are asked row by row, each once: a band of `window.rows` prepared scan rows is kept and slides
    /// down the map. `progress` and cancellation as `imageQualityMap`.
    @concurrent package static func averageNeighbourDotProductMap(
        scanRows: Int, scanColumns: Int, patternPixels: Int, window: NeighbourWindow = .nearest,
        zeroMean: Bool = true, normalize: Bool = true, progress: (@Sendable (Double) -> Void)? = nil,
        pattern: @Sendable (_ row: Int, _ column: Int) throws -> [Double]
    ) async throws -> [Double] {
        guard scanRows >= 1, scanColumns >= 1, patternPixels >= 1, window.rows >= 1, window.columns >= 1 else { throw Error.shape }
        let offsets = window.offsets
        let below = window.rows - 1 - window.origin.row   // rows of the window under the origin
        var band: [Int: [[Double]]] = [:]
        func load(_ r: Int) throws {
            guard r < scanRows, band[r] == nil else { return }
            var row: [[Double]] = []
            row.reserveCapacity(scanColumns)
            for c in 0..<scanColumns {
                let p = try pattern(r, c)
                guard p.count == patternPixels else { throw Error.shape }
                row.append(prepared(p, zeroMean: zeroMean, normalize: normalize))
            }
            band[r] = row
        }
        var out = [Double](repeating: .nan, count: scanRows * scanColumns)
        for r in 0..<scanRows {
            try Task.checkCancellation()
            for rr in r...min(r + below, scanRows - 1) { try load(rr) }
            for key in band.keys where key < r - window.origin.row { band[key] = nil }
            let centreRow = band[r]!
            for c in 0..<scanColumns {
                var sum = 0.0, n = 0
                for (dr, dc) in offsets {
                    let rr = r + dr, cc = c + dc
                    guard rr >= 0, rr < scanRows, cc >= 0, cc < scanColumns, let neighbours = band[rr] else { continue }
                    let d = dot(neighbours[cc], centreRow[c])
                    if d.isNaN { continue }
                    sum += d
                    n += 1
                }
                if n > 0 { out[r * scanColumns + c] = sum / Double(n) }
            }
            progress?(Double(r + 1) / Double(scanRows))
        }
        return out
    }
}

// MARK: - Both maps of a dataset

extension PatternQuality {
    /// The two maps of one dataset as the Patterns room asks for them: the image quality (normalised) and the average dot product with the
    /// four nearest neighbours (kikuchipy's defaults), of the patterns as stored, read through `access` one scan row at a time (each map
    /// reads every row once; a row is kept only while the dot-product band needs it). `progress` runs 0 ... 0.5 over the image quality
    /// and 0.5 ... 1 over the dot products; the task's cancellation stops between rows.
    @concurrent package static func maps(of access: any EBSDPatternAccess, progress: (@Sendable (Double) -> Void)? = nil) async throws
        -> (imageQuality: [Double], dotProduct: [Double]) {
        let dataset = access.dataset
        let rows = dataset.scanRows, columns = dataset.scanColumns
        let iqSource = RowPatterns(access)
        let iq = try await imageQualityMap(scanRows: rows, scanColumns: columns, patternRows: dataset.patternRows,
                                           patternColumns: dataset.patternColumns, progress: { progress?($0 / 2) },
                                           pattern: { r, c in try iqSource.pattern(row: r, column: c) })
        let adpSource = RowPatterns(access)
        let adp = try await averageNeighbourDotProductMap(scanRows: rows, scanColumns: columns, patternPixels: dataset.patternPixels,
                                                          progress: { progress?(0.5 + $0 / 2) },
                                                          pattern: { r, c in try adpSource.pattern(row: r, column: c) })
        return (iq, adp)
    }
}

/// One scan row of patterns at a time from an `EBSDPatternAccess` (one slab read per row), as doubles; the map functions ask in row
/// order, so the last few rows are all that is kept.
private nonisolated final class RowPatterns: @unchecked Sendable {
    private let access: any EBSDPatternAccess
    private let pixels: Int
    private let lock = NSLock()
    private var rows: [Int: [Double]] = [:]

    init(_ access: any EBSDPatternAccess) {
        self.access = access
        pixels = access.dataset.patternPixels
    }

    func pattern(row: Int, column: Int) throws -> [Double] {
        try lock.withLock {
            if rows[row] == nil {
                rows[row] = try access.row(row).doubles()
                for key in rows.keys where key < row - 2 { rows[key] = nil }
            }
            let values = rows[row]!
            return Array(values[(column * pixels)..<((column + 1) * pixels)])
        }
    }
}
