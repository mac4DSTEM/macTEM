//
//  NLPAR.swift
//  Non-local pattern averaging and re-indexing (NLPAR) of EBSD patterns: Brewick, Wright and Rowenhorst, Ultramicroscopy 200
//  (2019) 50–61. Derived from PyEBSDIndex 0.3.10.1 (`pyebsdindex/nlpar_cpu.py`: `NLPAR.makeautomask`, `_calcchunks`,
//  `sigma_numba`, `calcsigma_cpu`, `opt_lambda_cpu`, `nlpar_nb`, `calcnlpar_cpu`), developed by employees of the US Naval Research
//  Laboratory and in the public domain in the United States (17 U.S.C. § 105), https://github.com/USNavalResearchLaboratory/PyEBSDIndex.
//  Modified 2026-11-06 for macTEM: ported to Swift function by function, in memory instead of through pattern files, with the
//  tile budget fixed at pyebsdindex's 32e9-byte cap and the search window refused where the map is smaller than it. NRL is
//  acknowledged as the original source in NOTICE. The Nelder–Mead minimiser is SciPy 1.18.1's `_minimize_neldermead`
//  (BSD-3-Clause) in one dimension with bounds.
//
//  Numbers: pyebsdindex computes in float32 (numba, fastmath off) with a few float64 steps where numba promotes a Python float
//  literal; this file keeps exactly those types and the same order of every sum, so the noise estimate and the distances are
//  bit-identical and the denoised patterns differ only where float64 `exp` rounds differently. A float64 path would not be
//  closer to the reference: the normalised distance subtracts n · (σ₀² + σ₁²) from a float32 sum of about 2700 squares, which
//  cancels most of its digits, so float64 lands further from pyebsdindex than its own float32 rounding (decision in
//  docs/decisions.md). The parity references are `tools/parity/sem/emit.py` (m2/nlpar-*), the rows are in docs/parity.md.
//
//  The tiling: pyebsdindex splits the scan into tiles (at least two along the longer side, overlapping by the window) and its
//  per-tile saturation level and per-tile neighbour lists show in the result at the seam; the port runs the same tiles so the
//  numbers are the reference's.
//

import Foundation

package nonisolated enum NLPAR {
    package enum Error: Swift.Error, Equatable, Sendable, LocalizedError {
        /// A count does not match the scan and pattern sizes, or a size is below 1.
        case shape
        /// A parameter is out of range (named).
        case parameter(String)

        package var errorDescription: String? {
            switch self {
            case .shape: "NLPAR's patterns do not match the scan and pattern sizes."
            case .parameter(let name): "NLPAR's \(name) is out of range for this scan."
            }
        }
    }

    /// The defaults of `pyebsdindex.nlpar.NLPAR` and `opt_lambda`.
    package static let defaultSearchRadius = 3
    package static let defaultTargetWeights: [Double] = [0.5, 0.34, 0.25]
    /// `_calcchunks`' budget: `min(32e9, RAM / 4)` in pyebsdindex; fixed at the cap so the tiling does not depend on the machine.
    package static let tileBytes = 32e9

    /// A scan of patterns as float32 in map order: `values[(row * columns + column) * pixels + pixel]`.
    package struct Scan: Sendable {
        package var rows: Int
        package var columns: Int
        package var patternRows: Int
        package var patternColumns: Int
        package var values: [Float]

        package init(rows: Int, columns: Int, patternRows: Int, patternColumns: Int, values: [Float]) throws {
            guard rows >= 1, columns >= 1, patternRows >= 1, patternColumns >= 1,
                  values.count == rows * columns * patternRows * patternColumns else { throw Error.shape }
            self.rows = rows; self.columns = columns; self.patternRows = patternRows; self.patternColumns = patternColumns
            self.values = values
        }

        package var pixels: Int { patternRows * patternColumns }
    }

    /// The noise estimate (`calcsigma_cpu` with nn = 1): σ per pattern, and per pattern the normalised squared distances to its
    /// 3 x 3 neighbours (self included, zero where a neighbour is missing at an edge), the input of the λ optimisation.
    package struct NoiseEstimate: Sendable, Equatable {
        package var rows: Int
        package var columns: Int
        package var sigma: [Float]
        /// `rows * columns * 9` values.
        package var distances: [Float]
    }

    /// One run of `opt_lambda` then `calcnlpar`.
    package struct Result: Sendable {
        /// λ for each target weight, and the one used (their median, as `opt_lambda(autoupdate=True)`).
        package var lambdas: [Double]
        package var lambda: Double
        package var estimate: NoiseEstimate
        package var denoised: Scan
    }

    // MARK: - Mask (`makeautomask`)

    /// The automatic mask: 1 inside the circle of radius 0.98 · min(h, w) / 2 about the pattern centre (float32 distances as
    /// pyebsdindex computes them), 0 outside.
    package static func autoMask(patternRows h: Int, patternColumns w: Int) -> [UInt8] {
        let r = Double(min(h, w)) * 0.98 * 0.5
        var mask = [UInt8](repeating: 0, count: h * w)
        let rollY = h / 2, rollX = w / 2
        for y in 0..<h {
            let fy = min(Float(y), Float(h) - Float(y))
            for x in 0..<w {
                let fx = min(Float(x), Float(w) - Float(x))
                let d = (fy * fy + fx * fx).squareRoot()
                mask[((y + rollY) % h) * w + (x + rollX) % w] = d < Float(r) ? 1 : 0   // numpy compares a float32 array in float32
            }
        }
        return mask
    }

    static func maskIndices(_ mask: [UInt8]) -> [Int] {
        mask.indices.filter { mask[$0] != 0 }
    }

    // MARK: - Tiles (`_calcchunks`)

    /// The half-open column and row ranges of pyebsdindex's tiles for a scan, each overlapping its neighbours by `overlap`.
    package static func tiles(rows nrow: Int, columns ncol: Int, patternRows h: Int, patternColumns w: Int, overlap: Int,
                              targetBytes: Double = tileBytes) -> (columns: [Range<Int>], rows: [Range<Int>]) {
        let colOverlap = min(overlap, ncol - 1)
        let rowOverlap = min(overlap, nrow - 1)
        let minColChunks = ncol >= nrow ? 2 : 1
        let minRowChunks = nrow > ncol ? 2 : 1
        let bytesPerDataset = Double(w * h * 4 * 2) * Double(ncol) * Double(nrow)
        let nchunks = Int((bytesPerDataset / targetBytes).rounded(.up))

        var ncolf = max((Double(nchunks) * Double(ncol) / Double(nrow)).squareRoot().rounded(.toNearestOrEven), Double(minColChunks))
        var colStepF = max(Double(ncol) / ncolf, 1)
        ncolf = max(Double(ncol) / colStepF, 1)
        let ncolChunks = max(Int(ncolf.rounded(.up)), 1)
        colStepF = colStepF.rounded(.toNearestOrEven)
        let colStep = max(Int(colStepF), 1)
        let colStepOv = min(colStep + 2 * colOverlap, ncol)

        var nrowf = max((Double(nchunks) / Double(ncolChunks)).rounded(.up), Double(minRowChunks))
        var rowStepF = max(Double(nrow) / nrowf, 1)
        nrowf = max(Double(nrow) / rowStepF, 1)
        let nrowChunks = max(Int(nrowf.rounded(.up)), 1)
        rowStepF = rowStepF.rounded(.toNearestOrEven)
        let rowStep = max(Int(rowStepF), 1)
        let rowStepOv = min(rowStep + 2 * rowOverlap, nrow)

        func split(count: Int, step: Int, stepOv: Int, overlap ov: Int, total: Int) -> [Range<Int>] {
            var bounds: [(Int, Int)] = []
            for c in 0..<count {
                let b = (c * step - ov, c * step + stepOv - ov)
                bounds.append(b)
                if b.1 > total { break }
            }
            bounds[0].0 = 0
            bounds[bounds.count - 1].1 = total
            if bounds.count > 1 { bounds[bounds.count - 1].0 = max(0, bounds[bounds.count - 2].1 - 2 * ov - 1) }
            return bounds.map { $0.0..<$0.1 }
        }
        return (split(count: ncolChunks, step: colStep, stepOv: colStepOv, overlap: colOverlap, total: ncol),
                split(count: nrowChunks, step: rowStep, stepOv: rowStepOv, overlap: rowOverlap, total: nrow))
    }

    /// The tile's patterns, copied out in map order (`read_data` of a slab).
    static func tile(_ scan: Scan, rows: Range<Int>, columns: Range<Int>) -> [Float] {
        let px = scan.pixels
        var out = [Float](repeating: 0, count: rows.count * columns.count * px)
        out.withUnsafeMutableBufferPointer { dst in
            scan.values.withUnsafeBufferPointer { src in
                var k = 0
                for r in rows {
                    let start = (r * scan.columns + columns.lowerBound) * px
                    let n = columns.count * px
                    for i in 0..<n { dst[k + i] = src[start + i] }
                    k += n
                }
            }
        }
        return out
    }

    /// The tile's buffers handed to the parallel columns; each column writes only its own patterns of `out` (the scan's result).
    private struct Shared: @unchecked Sendable {
        let data: UnsafePointer<Float>
        let indices: UnsafePointer<Int>
        let sigma: UnsafePointer<Float>
        let out: UnsafeMutablePointer<Float>
    }

    // MARK: - Noise estimate (`sigma_numba`, `calcsigma_cpu`)

    /// `sigma_numba` with nn = 1 on one tile of `rows` x `columns` patterns: σ per pattern (the square root of the smallest
    /// d² / 2n over its neighbours), the normalised distances and the neighbour counts (9 per pattern). `isCancelled` is asked
    /// before each row; a yes ends the tile with `CancellationError`.
    static func tileSigma(_ data: [Float], rows: Int, columns: Int, pixels: Int, indices: [Int], saturationProtect: Bool,
                          isCancelled: () -> Bool) throws -> (sigma: [Float], distances: [Float], counts: [Float]) {
        let nn = 1, slots = 9
        let n = rows * columns
        var sigma = [Float](repeating: 0, count: n)
        var dout = [Float](repeating: 0, count: n * slots)
        var nout = [Float](repeating: 0, count: n * slots)
        var dij = [Int](repeating: 0, count: n * slots)   // neighbour's flat index in the tile
        let n0 = Float(pixels)
        let top = Double(data.max() ?? 0)
        let mxval = saturationProtect ? top * 0.9961 : top + 1.0
        var stopped = false
        data.withUnsafeBufferPointer { d in
            indices.withUnsafeBufferPointer { idx in
                sigma.withUnsafeMutableBufferPointer { sg in
                    dout.withUnsafeMutableBufferPointer { dOut in
                        nout.withUnsafeMutableBufferPointer { nOut in
                            dij.withUnsafeMutableBufferPointer { dIJ in
                                for j in 0..<rows {
                                    if isCancelled() {
                                        stopped = true
                                        return
                                    }
                                    let r0 = max(j - nn, 0), r1 = min(j + nn, rows - 1) + 1
                                    for i in 0..<columns {
                                        let c0 = max(i - nn, 0), c1 = min(i + nn, columns - 1) + 1
                                        let a = i + columns * j
                                        var mind = Float(Double(1e24))
                                        var count = 0
                                        for jn in r0..<r1 {
                                            for inn in c0..<c1 {
                                                let b = inn + columns * jn
                                                let slot = a * slots + count
                                                dIJ[slot] = b
                                                var d2: Float = 0
                                                nOut[slot] = n0
                                                if b != a {
                                                    var n2 = Double(Float(Double(1e-12)))
                                                    let pa = a * pixels, pb = b * pixels
                                                    for q in idx {
                                                        let d0 = d[pa + q], d1 = d[pb + q]
                                                        if Double(d1) < mxval && Double(d0) < mxval {
                                                            n2 += 1.0
                                                            let df = d0 - d1
                                                            d2 += df * df
                                                        }
                                                    }
                                                    nOut[slot] = Float(n2)
                                                    if Double(d2) >= 1e-3 {
                                                        let s0 = d2 / Float(n2 * 2.0)
                                                        if s0 < mind { mind = s0 }
                                                    }
                                                }
                                                dOut[slot] = d2
                                                count += 1
                                            }
                                        }
                                        sg[a] = mind.squareRoot()
                                    }
                                }
                                for a in 0..<n {
                                    for q in 0..<slots where nOut[a * slots + q] > 0 {
                                        let slot = a * slots + q
                                        let b = dIJ[slot]
                                        let s12 = sg[a] * sg[a] + sg[b] * sg[b]
                                        let v = dOut[slot] - nOut[slot] * s12
                                        dOut[slot] = Float(Double(v) / (Double(s12) * (2.0 * Double(nOut[slot])).squareRoot()))
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        if stopped { throw CancellationError() }
        return (sigma, dout, nout)
    }

    /// `calcsigma_cpu(nn=1)`: the tile estimates merged as pyebsdindex merges them (σ the smaller one where tiles overlap, the
    /// distances of the later tile wherever it has a neighbour). `isCancelled` is asked before each tile and each of its rows; a yes
    /// ends the estimate with `CancellationError`.
    package static func estimateNoise(_ scan: Scan, mask: [UInt8]? = nil, saturationProtect: Bool = true,
                                      isCancelled: () -> Bool = { false }) throws -> NoiseEstimate {
        let px = scan.pixels
        let m = mask ?? autoMask(patternRows: scan.patternRows, patternColumns: scan.patternColumns)
        guard m.count == px else { throw Error.shape }
        let indices = maskIndices(m)
        let (rows, columns) = (scan.rows, scan.columns)
        var sigma = [Float](repeating: 1e18, count: rows * columns)
        var distances = [Float](repeating: 0, count: rows * columns * 9)
        let t = tiles(rows: rows, columns: columns, patternRows: scan.patternRows, patternColumns: scan.patternColumns, overlap: 1)
        for rr in t.rows {
            for cc in t.columns {
                if isCancelled() { throw CancellationError() }
                let data = tile(scan, rows: rr, columns: cc)
                let est = try tileSigma(data, rows: rr.count, columns: cc.count, pixels: px, indices: indices, saturationProtect: saturationProtect,
                                        isCancelled: isCancelled)
                for (lj, j) in rr.enumerated() {
                    for (li, i) in cc.enumerated() {
                        let l = lj * cc.count + li, g = j * columns + i
                        sigma[g] = min(sigma[g], est.sigma[l])
                        for q in 0..<9 where est.counts[l * 9 + q] > 0 {
                            distances[g * 9 + q] = est.distances[l * 9 + q]
                        }
                    }
                }
            }
        }
        return NoiseEstimate(rows: rows, columns: columns, sigma: sigma, distances: distances)
    }

    // MARK: - λ (`opt_lambda_cpu`)

    /// `loptfunc`: mean over the patterns of |target − 1 / Σ exp(−max(d², dthresh) / λ²)|, numpy's pairwise sums.
    static func lambdaObjective(_ lambda: Double, distances: [Float], count: Int, target: Double, dthresh: Float) -> Double {
        let l2 = lambda * lambda
        var terms = [Double](repeating: 0, count: count)
        var w = [Double](repeating: 0, count: 9)
        for p in 0..<count {
            for q in 0..<9 {
                let temp = max(distances[p * 9 + q], dthresh)
                w[q] = exp(Double(-temp) / l2)
            }
            terms[p] = abs(target - 1.0 / (pairwiseSum(w) + 1e-12))
        }
        return pairwiseSum(terms) / Double(count)
    }

    /// numpy's `pairwise_sum` (blocks of 128, eight accumulators below that), the order `np.sum` and `np.mean` add in.
    static func pairwiseSum(_ a: [Double]) -> Double {
        guard !a.isEmpty else { return 0 }
        return a.withUnsafeBufferPointer { pairwiseSum($0.baseAddress!, a.count) }
    }

    private static func pairwiseSum(_ a: UnsafePointer<Double>, _ n: Int) -> Double {
        if n < 8 {
            var res = 0.0
            for i in 0..<n { res += a[i] }
            return res
        } else if n <= 128 {
            var r = (0..<8).map { a[$0] }
            var i = 8
            while i < n - (n % 8) {
                for k in 0..<8 { r[k] += a[i + k] }
                i += 8
            }
            var res = ((r[0] + r[1]) + (r[2] + r[3])) + ((r[4] + r[5]) + (r[6] + r[7]))
            while i < n {
                res += a[i]
                i += 1
            }
            return res
        } else {
            var n2 = n / 2
            n2 -= n2 % 8
            return pairwiseSum(a, n2) + pairwiseSum(a + n2, n - n2)
        }
    }

    /// `opt_lambda_cpu`: for each target weight, the λ that brings the mean weight of a pattern's 3 x 3 neighbourhood to it
    /// (SciPy's Nelder–Mead from λ = 1 in [0.001, 10], fatol 1e-4); every other row and column of a scan of 10⁶ patterns or more.
    package static func optimiseLambda(_ estimate: NoiseEstimate, targetWeights: [Double] = defaultTargetWeights, dthresh: Float = 0) -> [Double] {
        let stride = estimate.sigma.count < 1_000_000 ? 1 : 2
        var d: [Float] = []
        var count = 0
        if stride == 1 {
            d = estimate.distances
            count = estimate.rows * estimate.columns
        } else {
            for j in Swift.stride(from: 0, to: estimate.rows, by: stride) {
                for i in Swift.stride(from: 0, to: estimate.columns, by: stride) {
                    d.append(contentsOf: estimate.distances[((j * estimate.columns + i) * 9)..<((j * estimate.columns + i) * 9 + 9)])
                    count += 1
                }
            }
        }
        let distances = d
        return targetWeights.map { tw in
            nelderMead1D(x0: 1.0, lower: 0.001, upper: 10.0, xatol: 1e-4, fatol: 1e-4) {
                lambdaObjective($0, distances: distances, count: count, target: tw, dthresh: dthresh)
            }
        }
    }

    /// SciPy's `_minimize_neldermead` in one dimension with bounds (non-adaptive: ρ 1, χ 2, ψ 0.5, σ 0.5), at most 200 iterations
    /// and 200 evaluations; returns the best vertex.
    static func nelderMead1D(x0: Double, lower: Double, upper: Double, xatol: Double, fatol: Double, maxIterations: Int = 200,
                             maxEvaluations: Int = 200, _ f: @escaping (Double) -> Double) -> Double {
        func clip(_ x: Double) -> Double { min(max(x, lower), upper) }
        var calls = 0
        func eval(_ x: Double) -> Double? {
            guard calls < maxEvaluations else { return nil }
            calls += 1
            return f(x)
        }
        let start = clip(x0)
        var second = start != 0 ? (1 + 0.05) * start : 0.00025
        if second > upper { second = 2 * upper - second }
        var sim = [start, clip(second)]
        var fsim = [Double.infinity, Double.infinity]
        for k in 0..<2 {
            guard let v = eval(sim[k]) else { break }
            fsim[k] = v
        }
        func order() {
            if fsim[1] < fsim[0] {
                sim.swapAt(0, 1)
                fsim.swapAt(0, 1)
            }
        }
        order()
        var iterations = 1
        loop: while calls < maxEvaluations && iterations < maxIterations {
            if abs(sim[1] - sim[0]) <= xatol && abs(fsim[0] - fsim[1]) <= fatol { break }
            let xbar = sim[0]
            let xr = clip((1 + 1.0) * xbar - 1.0 * sim[1])
            guard let fxr = eval(xr) else { break loop }
            if fxr < fsim[0] {
                let xe = clip((1 + 1.0 * 2.0) * xbar - 1.0 * 2.0 * sim[1])
                guard let fxe = eval(xe) else { break loop }
                if fxe < fxr { sim[1] = xe; fsim[1] = fxe } else { sim[1] = xr; fsim[1] = fxr }
            } else {
                // with one dimension, fsim[-2] is fsim[0], so a reflection that is not better than the best contracts
                var shrink = false
                if fxr < fsim[1] {
                    let xc = clip((1 + 0.5 * 1.0) * xbar - 0.5 * 1.0 * sim[1])
                    guard let fxc = eval(xc) else { break loop }
                    if fxc <= fxr { sim[1] = xc; fsim[1] = fxc } else { shrink = true }
                } else {
                    let xcc = clip((1 - 0.5) * xbar + 0.5 * sim[1])
                    guard let fxcc = eval(xcc) else { break loop }
                    if fxcc < fsim[1] { sim[1] = xcc; fsim[1] = fxcc } else { shrink = true }
                }
                if shrink {
                    sim[1] = clip(sim[0] + 0.5 * (sim[1] - sim[0]))
                    guard let v = eval(sim[1]) else { break loop }
                    fsim[1] = v
                }
            }
            iterations += 1
            order()
        }
        order()
        return sim[0]
    }

    // MARK: - Averaging (`nlpar_nb`, `calcnlpar_cpu`)

    /// `nlpar_nb` on one tile: each pattern of the calculation region replaced by the weighted average of the (2r + 1)² patterns
    /// of its search window (shifted inward at the tile's edges), weights exp(−max(d̃² − dthresh, 0) / λ²) normalised to one,
    /// d̃² the noise-normalised distance and the pattern itself weighted 1. Each average is summed straight into its place in `out`,
    /// the scan's result (`scanColumns` patterns wide, the tile's first pattern at `origin`), from zero in the same order as
    /// pyebsdindex's tile buffer, so the values are the same and no tile-sized output is held. Each column asks `isCancelled` before
    /// each row and stops at a yes, leaving the tile unfinished (the caller asks again and throws).
    static func tileAverage(_ data: [Float], rows: Int, columns: Int, pixels: Int, sigma: [Float], lambda: Float, searchRadius sr: Int,
                            dthresh: Float, indices: [Int], saturationProtect: Bool, calcColumns: Range<Int>, calcRows: Range<Int>,
                            into out: UnsafeMutablePointer<Float>, origin: (row: Int, column: Int), scanColumns: Int,
                            isCancelled: @Sendable () -> Bool) {
        let lam2 = 1.0 / Double(lambda * lambda)
        let (row0, column0) = origin
        let top = data.max() ?? 0
        let mxval: Float = saturationProtect ? top * Float(Double(0.999)) : top + Float(1.0)
        let winsz = (2 * sr + 1) * (2 * sr + 1)
        data.withUnsafeBufferPointer { d in
            indices.withUnsafeBufferPointer { idx in
                sigma.withUnsafeBufferPointer { sg in
                    let shared = Shared(data: d.baseAddress!, indices: idx.baseAddress!, sigma: sg.baseAddress!, out: out)
                    let nIdx = idx.count
                    DispatchQueue.concurrentPerform(iterations: calcColumns.count) { ii in
                        let dp = shared.data, ip = shared.indices, sp = shared.sigma, op = shared.out
                        let i = calcColumns.lowerBound + ii
                        let wx0 = max(i - sr, 0) - max(i + sr - (columns - 1), 0)
                        let wx1 = min(i + sr, columns - 1) + max(sr - i, 0) + 1
                        var weights = [Float](repeating: 0, count: winsz)
                        var neighbour = [Int](repeating: 0, count: winsz)
                        for j in calcRows {
                            if isCancelled() { return }
                            let wy0 = max(j - sr, 0) - max(j + sr - (rows - 1), 0)
                            let wy1 = min(j + sr, rows - 1) + max(sr - j, 0) + 1
                            let a = i + columns * j
                            let s0 = sp[a] * sp[a]
                            var c = 0
                            for jn in wy0..<wy1 {
                                for inn in wx0..<wx1 {
                                    let b = inn + columns * jn
                                    neighbour[c] = b
                                    if b == a {
                                        weights[c] = -1.0e6
                                    } else {
                                        let s1 = sp[b] * sp[b]
                                        var d2: Float = 0, n2: Float = 0
                                        let pa = a * pixels, pb = b * pixels
                                        for k in 0..<nIdx {
                                            let q = ip[k]
                                            let d0 = dp[pa + q], d1 = dp[pb + q]
                                            if d1 < mxval && d0 < mxval {
                                                n2 += 1
                                                let df = d0 - d1
                                                d2 += df * df
                                            }
                                        }
                                        d2 -= n2 * (s0 + s1)
                                        let dnorm = (s1 + s0) * (Float(2) * n2).squareRoot()
                                        if dnorm > Float(Double(1e-8)) { d2 /= dnorm } else { d2 = Float(Double(1e6)) * n2 }
                                        weights[c] = d2
                                    }
                                    c += 1
                                }
                            }
                            var sum: Float = 0
                            for k in 0..<winsz {
                                let v = max(weights[k] - dthresh, Float(0))
                                let w = Float(exp(-1.0 * Double(v) * lam2))
                                weights[k] = w
                                sum += w
                            }
                            // The pattern's place in the scan's result, summed from zero as the tile buffer was.
                            let g = ((row0 + j) * scanColumns + column0 + i) * pixels
                            for q in 0..<pixels { op[g + q] = 0 }
                            for k in 0..<winsz {
                                let w = weights[k] / sum
                                let pb = neighbour[k] * pixels
                                for q in 0..<pixels { op[g + q] += dp[pb + q] * w }
                            }
                        }
                    }
                }
            }
        }
    }

    /// `calcnlpar_cpu`: every pattern replaced by its NLPAR average, tile by tile as pyebsdindex runs it (each tile computes its
    /// interior, the later tile's values standing where interiors overlap). `sigma` is the noise estimate's σ. `isCancelled` is asked
    /// before and after each tile and, on the worker threads, before each row; a yes ends the run with `CancellationError`. It is
    /// read on threads that run no task, so it reads a flag (`CancellationFlag`), not `Task.isCancelled`, and once it has said yes
    /// it keeps saying yes.
    package static func denoise(_ scan: Scan, lambda: Double, sigma: [Float], searchRadius: Int = defaultSearchRadius, dthresh: Float = 0,
                                mask: [UInt8]? = nil, saturationProtect: Bool = true,
                                isCancelled: @Sendable () -> Bool = { false }) throws -> Scan {
        let (rows, columns, px) = (scan.rows, scan.columns, scan.pixels)
        guard sigma.count == rows * columns else { throw Error.shape }
        guard searchRadius >= 0, 2 * searchRadius + 1 <= rows, 2 * searchRadius + 1 <= columns else { throw Error.parameter("search radius") }
        guard lambda.isFinite, lambda > 0 else { throw Error.parameter("lambda") }
        guard dthresh.isFinite else { throw Error.parameter("dthresh") }
        let m = mask ?? autoMask(patternRows: scan.patternRows, patternColumns: scan.patternColumns)
        guard m.count == px else { throw Error.shape }
        let indices = maskIndices(m)
        let sr = searchRadius
        var t = tiles(rows: rows, columns: columns, patternRows: scan.patternRows, patternColumns: scan.patternColumns, overlap: sr)
        // A tile narrower than the window makes pyebsdindex read outside the tile (its window index wraps into the next row and
        // past the slab's end); that axis then runs as one tile, which is the result pyebsdindex means.
        if t.columns.contains(where: { $0.count < 2 * sr + 1 }) { t.columns = [0..<columns] }
        if t.rows.contains(where: { $0.count < 2 * sr + 1 }) { t.rows = [0..<rows] }
        var result = scan
        for (ri, rr) in t.rows.enumerated() {
            let rStart = ri > 0 ? sr : 0
            let rEnd = ri < t.rows.count - 1 ? rr.count - sr : rr.count
            for (ci, cc) in t.columns.enumerated() {
                if isCancelled() { throw CancellationError() }
                let cStart = ci > 0 ? sr : 0
                let cEnd = ci < t.columns.count - 1 ? cc.count - sr : cc.count
                let data = tile(scan, rows: rr, columns: cc)
                var tileSigma = [Float](repeating: 0, count: rr.count * cc.count)
                for (lj, j) in rr.enumerated() {
                    for (li, i) in cc.enumerated() { tileSigma[lj * cc.count + li] = sigma[j * columns + i] }
                }
                result.values.withUnsafeMutableBufferPointer { dst in
                    tileAverage(data, rows: rr.count, columns: cc.count, pixels: px, sigma: tileSigma, lambda: Float(lambda),
                                searchRadius: sr, dthresh: dthresh, indices: indices, saturationProtect: saturationProtect,
                                calcColumns: cStart..<cEnd, calcRows: rStart..<rEnd, into: dst.baseAddress!,
                                origin: (row: rr.lowerBound, column: cc.lowerBound), scanColumns: columns, isCancelled: isCancelled)
                }
                if isCancelled() { throw CancellationError() }
            }
        }
        return result
    }

    /// pyebsdindex's documented run: `opt_lambda()` (λ the median of the three), then `calcnlpar()` with that λ and the estimate.
    /// `isCancelled` (Stop) is asked between the tiles and rows of both and before λ; a yes ends the run with `CancellationError`.
    package static func run(_ scan: Scan, searchRadius: Int = defaultSearchRadius, targetWeights: [Double] = defaultTargetWeights,
                            dthresh: Float = 0, saturationProtect: Bool = true, isCancelled: @Sendable () -> Bool = { false }) throws -> Result {
        let mask = autoMask(patternRows: scan.patternRows, patternColumns: scan.patternColumns)
        let estimate = try estimateNoise(scan, mask: mask, saturationProtect: saturationProtect, isCancelled: isCancelled)
        if isCancelled() { throw CancellationError() }
        let lambdas = optimiseLambda(estimate, targetWeights: targetWeights, dthresh: dthresh)
        let sorted = lambdas.sorted()
        let lambda = sorted.count % 2 == 1 ? sorted[sorted.count / 2] : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
        let denoised = try denoise(scan, lambda: lambda, sigma: estimate.sigma, searchRadius: searchRadius, dthresh: dthresh, mask: mask,
                                   saturationProtect: saturationProtect, isCancelled: isCancelled)
        return Result(lambdas: lambdas, lambda: lambda, estimate: estimate, denoised: denoised)
    }
}
