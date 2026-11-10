//
//  HoughBandDetection.swift
//  Kikuchi band detection on an EBSD pattern for Hough indexing: the discrete Radon transform of the pattern (the mean
//  intensity along every line at angle theta and distance rho from the centre), a Laplacian-of-Gaussian filter in Radon
//  space that turns each band into a peak, the strongest local maxima as bands with sub-pixel positions, and each band's
//  plane normal in the detector frame from the projection centre (Krieger Lassen 1994, PhD thesis, DTU, eq. 3.1.6).
//
//  Ported from pyEBSDindex 0.3.10.1 (D. Rowenhorst, US Naval Research Laboratory; public domain in the US, NOTICE carries
//  the acknowledgement and modification notice): `radon_fast.Radon.radon_plan_setup`, `radon_faster` / `rdn_loops`,
//  `radon2pole`; `band_detect.BandDetect.band_detect_setup`, `find_bands`, `rdn_conv`, `rdn_local_max`, `_grey_dilation`,
//  `band_label_numba` (the CPU path; pyEBSDindex runs the same steps in OpenCL when pyopencl is installed). Modified for
//  macTEM in November 2026: Swift; the Radon sums, the convolution and the peak fit in float64 (pyEBSDindex: float32
//  under numba fastmath and an FFT convolution); the line plan in pyEBSDindex's float32 angles so every line holds the
//  same pixels; the convolution direct and separable (the kernel is the outer product of two 1-D filters); peak ties
//  ordered by a stable sort where numpy's quicksort leaves them unordered. Parity bundle `m4/hough-nickel-block`.
//
//  Conventions: patterns are row-major (row 0 at the top), PCs in the Bruker convention (as EBSDDetectorGeometry stores
//  them), band normals in pyEBSDindex's detector frame for its vendor "KIKUCHIPY" (x right, y up from the bottom-left
//  corner, z out of the screen towards the sample).
//

import Foundation

package nonisolated struct HoughBandDetector: Sendable {
    package enum Error: Swift.Error, Equatable, Sendable, LocalizedError {
        /// A pattern or setting does not fit the plan (sizes, sigmas, the rho-mask fraction outside [0, 1)).
        case settings
        case shape

        package var errorDescription: String? {
            switch self {
            case .settings: "The Hough settings do not fit a pattern of this size."
            case .shape: "The pattern does not have the size the band detector was set up for."
            }
        }
    }

    /// pyEBSDindex's `EBSDIndexer` defaults: 90 rho and 180 theta bins, Gaussian sigmas of 1.2 rho bins and 1 theta bin,
    /// 15 % of the rho range masked at each end, 9 bands.
    package struct Settings: Sendable, Equatable {
        package var rhoBins = 90
        package var thetaBins = 180
        package var thetaSigma = 1.0
        package var rhoSigma = 1.2
        package var rhoMaskFraction = 0.15
        package var bands = 9

        package init(rhoBins: Int = 90, thetaBins: Int = 180, thetaSigma: Double = 1.0, rhoSigma: Double = 1.2,
                     rhoMaskFraction: Double = 0.15, bands: Int = 9) {
            self.rhoBins = rhoBins
            self.thetaBins = thetaBins
            self.thetaSigma = thetaSigma
            self.rhoSigma = rhoSigma
            self.rhoMaskFraction = rhoMaskFraction
            self.bands = bands
        }

        /// kikuchipy's Hough indexing tutorial: 10 bands, both sigmas 2.
        package static let kikuchipyTutorial = Settings(thetaSigma: 2, rhoSigma: 2, bands: 10)
    }

    /// One detected band (pyEBSDindex's band record; positions in Radon cells of the unpadded transform).
    package struct Band: Sendable, Equatable {
        /// The convolved Radon value at the peak.
        package var max: Double = -2.0e6
        /// (max - min) / (mean - min) of the convolved transform (the "normmax" behind pyEBSDindex's IQ).
        package var normalizedMax: Double = -2.0e6
        /// The mean of the 3 x 3 neighbourhood.
        package var averageMax: Double = -2.0e6
        /// The peak cell (rho, theta).
        package var peakRho: Double = 0
        package var peakTheta: Double = 0
        /// The sub-pixel peak (rho, theta).
        package var rhoIndex: Double = 0
        package var thetaIndex: Double = 0
        /// The width metric (FWHM of a Gaussian through the peak along rho), 0 where undefined.
        package var width: Double = 0
        /// The band's angle (radians) and distance from the pattern centre (pixels), pyEBSDindex's lower-left origin.
        package var theta: Double = 0
        package var rho: Double = 0
        package var valid = false
    }

    package let settings: Settings
    package let rows: Int
    package let columns: Int
    /// The largest |rho| (pixels): half the shorter side when a rho mask is set, else half the diagonal.
    package let rhoMax: Float
    /// The bins: theta in degrees, rho in pixels (float32, as pyEBSDindex's plan).
    package let thetaDegrees: [Float]
    package let rhoValues: [Float]
    /// The padding of the transform on each side (rho, theta) and the local-maximum window.
    package let padding: (rho: Int, theta: Int)
    package let peakWindow: (rho: Int, theta: Int)
    /// The Laplacian-of-Gaussian kernel as two 1-D filters, kernel = scale · rowFilter ⊗ columnFilter.
    package let rowFilter: [Double]
    package let columnFilter: [Double]
    package let kernelScale: Double
    /// Where peaks may sit: Radon cells with at least one pixel, rho bins away from both ends.
    package let radonMask: [Bool]
    // The pixels of every line, flattened: line (rho j, theta i) owns lineIndex[lineStart[j * nT + i] ..< lineStart[... + 1]].
    private let lineStart: [Int]
    private let lineIndex: [Int32]

    package init(rows: Int, columns: Int, settings: Settings = Settings()) throws {
        guard rows >= 3, columns >= 3, settings.rhoBins >= 3, settings.thetaBins >= 3, settings.bands >= 1,
              settings.thetaSigma > 0, settings.rhoSigma > 0,
              settings.rhoMaskFraction >= 0, settings.rhoMaskFraction < 1 else { throw Error.settings }
        self.settings = settings
        self.rows = rows
        self.columns = columns
        let nR = settings.rhoBins, nT = settings.thetaBins

        // band_detect_setup: rhoMax, the plan's bins.
        let rhoMax: Float = settings.rhoMaskFraction > 0
            ? Float(0.5) * Float(min(rows, columns))
            : Float(0.5) * (Float(rows) * Float(rows) + Float(columns) * Float(columns)).squareRoot()
        self.rhoMax = rhoMax
        let deltaRho = 2 * Double(rhoMax) / Double(nR)
        let theta = (0..<nT).map { Float($0) * Float(180) / Float(nT) }
        let rho = (0..<nR).map { Float($0) * Float(deltaRho) - (rhoMax - Float(deltaRho)) }
        thetaDegrees = theta
        rhoValues = rho

        // radon_plan_setup: for each theta, the pixel each line crosses in each column (steep lines) or row.
        let xmin = -1.0 * Double(columns - 1) * 0.5, ymin = -1.0 * Double(rows - 1) * 0.5
        let toRadians = Float(Double.pi / 180)
        var starts: [Int] = [0]
        var index: [Int32] = []
        starts.reserveCapacity(nR * nT + 1)
        var plan = [[Int32]](repeating: [], count: nR * nT)
        for i in 0..<nT {
            let s = sin(theta[i] * toRadians), c = cos(theta[i] * toRadians)
            let steep = Double(abs(s)) >= 2.0.squareRoot() * 0.5
            let a = Double((Float(-1.0) * (steep ? c : s)) / (steep ? s : c))
            let b = xmin * Double(c) + ymin * Double(s)
            for j in 0..<nR {
                var b1 = Double(rho[j]) - b
                var line: [Int32] = []
                if steep {
                    b1 /= Double(s)
                    for m in 0..<columns {
                        let y = (a * Double(m) + b1).rounded(.toNearestOrEven)
                        if y >= 0, y < Double(rows) { line.append(Int32(m + columns * Int(y))) }
                    }
                } else {
                    b1 /= Double(c)
                    for n in 0..<rows {
                        let x = (a * Double(n) + b1).rounded(.toNearestOrEven)
                        if x >= 0, x < Double(columns) { line.append(Int32(Int(x) + columns * n)) }
                    }
                }
                line.sort()
                plan[j * nT + i] = line
            }
        }
        for line in plan {
            index.append(contentsOf: line)
            starts.append(index.count)
        }
        lineStart = starts
        lineIndex = index

        // The Radon mask: cells with pixels, minus int(nRho * fraction) rho bins (at least 1) at each end.
        var mask = plan.map { !$0.isEmpty }
        if settings.rhoMaskFraction > 0 {
            let cut = max(Int(Double(nR) * settings.rhoMaskFraction), 1)
            for j in 0..<nR where j < cut || j >= nR - cut {
                for i in 0..<nT { mask[j * nT + i] = false }
            }
        }
        radonMask = mask

        // The kernel: -d²/drho² of a Gaussian (sigma rSigma, scipy's gaussian_filter order 2 on a centred delta, mode
        // "reflect") times a Gaussian along theta, normalised to a maximum of 1.
        func size(_ sigma: Double) -> Int {
            let k = max(Int(4 * sigma), 5)
            return k % 2 == 0 ? k + 1 : k
        }
        let kr = size(settings.rhoSigma), kt = size(settings.thetaSigma)
        let u = Self.filteredDelta(length: kr, sigma: settings.rhoSigma, order: 2).map { -$0 }
        let v = Self.filteredDelta(length: kt, sigma: settings.thetaSigma, order: 0)
        var peak = -Double.infinity
        for x in u { for y in v { peak = Swift.max(peak, x * y) } }
        rowFilter = u
        columnFilter = v
        kernelScale = 1 / peak
        var pr = 2 * kr, pt = 2 * kt
        if pr % 2 == 0 { pr += 1 }
        if pt % 2 == 0 { pt += 1 }
        peakWindow = (pr, pt)
        padding = (Swift.max(pr, 11), Swift.max(pt, 11))
    }

    /// The kernel as pyEBSDindex stores it (row-major kr x kt).
    package var kernel: [Double] {
        rowFilter.flatMap { x in columnFilter.map { x * $0 * kernelScale } }
    }

    /// scipy's `gaussian_filter1d(delta, sigma, order, mode="reflect", truncate=4)` of a centred delta of `length`.
    static func filteredDelta(length: Int, sigma: Double, order: Int) -> [Double] {
        let radius = Int(4.0 * sigma + 0.5)
        var w = (-radius...radius).map { x in exp(-0.5 / (sigma * sigma) * Double(x * x)) }
        let total = w.reduce(0, +)
        w = w.map { $0 / total }
        if order == 2 {
            for (k, x) in (-radius...radius).enumerated() { w[k] *= (Double(x * x) - sigma * sigma) / (sigma * sigma * sigma * sigma) }
        }
        // correlate1d with the reversed weights (symmetric for orders 0 and 2), half-sample reflection at the ends.
        var out = [Double](repeating: 0, count: length)
        let centre = length / 2
        for i in 0..<length {
            var acc = 0.0
            for k in 0..<w.count {
                var j = i + k - radius
                while j < 0 || j >= length { j = j < 0 ? -j - 1 : 2 * length - j - 1 }
                if j == centre { acc += w[w.count - 1 - k] }
            }
            out[i] = acc
        }
        return out
    }

    // MARK: - Radon transform

    /// The Radon transform of one pattern (row-major `rows` x `columns`), padded by `padding` on each side and filled with
    /// -1 where a line holds no pixel: the mean intensity along each line (`normalize`) or the sum.
    package func radon(_ pattern: [Double], normalize: Bool = true) throws -> [Double] {
        guard pattern.count == rows * columns else { throw Error.shape }
        let nR = settings.rhoBins, nT = settings.thetaBins
        let width = nT + 2 * padding.theta
        var out = [Double](repeating: -1, count: (nR + 2 * padding.rho) * width)
        lineIndex.withUnsafeBufferPointer { idx in
            pattern.withUnsafeBufferPointer { px in
                for j in 0..<nR {
                    for i in 0..<nT {
                        let lo = lineStart[j * nT + i], hi = lineStart[j * nT + i + 1]
                        guard hi > lo else { continue }
                        var sum = 0.0
                        for k in lo..<hi { sum += px[Int(idx[k])] }
                        out[(j + padding.rho) * width + i + padding.theta] = normalize ? sum / Double(hi - lo) : sum
                    }
                }
            }
        }
        return out
    }

    /// The number of pixels on each line (rho-major nRho x nTheta).
    package var lineCounts: [Int] { (0..<(lineStart.count - 1)).map { lineStart[$0 + 1] - lineStart[$0] } }

    /// `rdn_conv`: the padded transform's edges filled (theta padding from the opposite theta end with rho reversed, rho
    /// padding repeating the first and last rows), convolved with the kernel ("same" size, zero outside), and the min,
    /// mean and max over pyEBSDindex's window (rows from the padding to the end, as its slice reads, columns inside the
    /// padding).
    package func convolve(_ padded: [Double]) -> (convolved: [Double], minimum: Double, mean: Double, maximum: Double) {
        let pR = padding.rho, pT = padding.theta
        let R = settings.rhoBins + 2 * pR, T = settings.thetaBins + 2 * pT
        var x = padded
        // radon[:, 0:pT] = flip_rho(radon[:, T-2pT : T-pT]); radon[:, T-pT:] = flip_rho(radon[:, pT : 2pT])
        for r in 0..<R {
            let src = R - 1 - r
            for k in 0..<pT {
                x[r * T + k] = padded[src * T + (T - 2 * pT + k)]
                x[r * T + (T - pT + k)] = padded[src * T + (pT + k)]
            }
        }
        for r in 0..<pR {
            for c in 0..<T {
                x[r * T + c] = x[pR * T + c]
                x[(R - 1 - r) * T + c] = x[(R - pR - 1) * T + c]
            }
        }
        // Separable "same" convolution: out[i, j] = Σ_a Σ_b K[a, b] x[i + ca - a, j + cb - b].
        let u = rowFilter, v = columnFilter
        let cu = (u.count - 1) / 2, cv = (v.count - 1) / 2
        var tmp = [Double](repeating: 0, count: R * T)
        for i in 0..<R {
            for j in 0..<T {
                var acc = 0.0
                for b in 0..<v.count {
                    let jj = j + cv - b
                    if jj >= 0, jj < T { acc += v[b] * x[i * T + jj] }
                }
                tmp[i * T + j] = acc
            }
        }
        var out = [Double](repeating: 0, count: R * T)
        for i in 0..<R {
            for j in 0..<T {
                var acc = 0.0
                for a in 0..<u.count {
                    let ii = i + cu - a
                    if ii >= 0, ii < R { acc += u[a] * tmp[ii * T + j] }
                }
                out[i * T + j] = acc * kernelScale
            }
        }
        // np: rdnConv[pR : T - pR, pT : T - pT] (its row bound is the theta size, so the rows run to the end).
        let rowEnd = Swift.min(T - pR, R)
        var mn = Double.infinity, mx = -Double.infinity, sum = 0.0, count = 0
        if pR < rowEnd {
            for i in pR..<rowEnd {
                for j in pT..<(T - pT) {
                    let value = out[i * T + j]
                    mn = Swift.min(mn, value)
                    mx = Swift.max(mx, value)
                    sum += value
                    count += 1
                }
            }
        }
        return (out, mn, count > 0 ? sum / Double(count) : .nan, mx)
    }

    /// `rdn_local_max`: cells equal to the maximum of the peak window around them (clipped at the edges), inside the mask.
    package func localMaxima(_ convolved: [Double]) -> [Bool] {
        let pR = padding.rho, pT = padding.theta
        let R = settings.rhoBins + 2 * pR, T = settings.thetaBins + 2 * pT
        let ht = peakWindow.theta / 2, hr = peakWindow.rho / 2
        var along = [Double](repeating: 0, count: R * T)
        for i in 0..<R {
            for j in 0..<T {
                var m = -Double.infinity
                for jj in Swift.max(j - ht, 0)...Swift.min(j + ht, T - 1) { m = Swift.max(m, convolved[i * T + jj]) }
                along[i * T + j] = m
            }
        }
        var out = [Bool](repeating: false, count: R * T)
        let nT = settings.thetaBins
        for i in 0..<R {
            for j in 0..<T {
                let mi = i - pR, mj = j - pT
                guard mi >= 0, mi < settings.rhoBins, mj >= 0, mj < nT, radonMask[mi * nT + mj] else { continue }
                var m = -Double.infinity
                for ii in Swift.max(i - hr, 0)...Swift.min(i + hr, R - 1) { m = Swift.max(m, along[ii * T + j]) }
                out[i * T + j] = m == convolved[i * T + j]
            }
        }
        return out
    }

    /// `band_label`: the `bands` strongest maxima (by convolved value), each with its 3 x 3 quadratic sub-pixel fit,
    /// width and neighbourhood mean; a maximum at or below zero leaves its slot invalid. Then theta and rho of each band
    /// (`find_bands`) and the normalised maximum.
    package func detect(_ pattern: [Double]) throws -> [Band] {
        let padded = try radon(pattern)
        let (conv, mn, mean, _) = convolve(padded)
        let peaks = localMaxima(conv)
        let T = settings.thetaBins + 2 * padding.theta
        var cells: [(index: Int, value: Double)] = []
        for (k, isPeak) in peaks.enumerated() where isPeak { cells.append((k, conv[k])) }
        // np.argsort ascending, read from the end; ties in a stable order.
        let order = cells.indices.sorted { cells[$0].value < cells[$1].value || (cells[$0].value == cells[$1].value && $0 < $1) }
        var bands = [Band](repeating: Band(), count: settings.bands)
        let pR = Double(padding.rho), pT = Double(padding.theta)
        for slot in 0..<Swift.min(settings.bands, order.count) {
            let k = cells[order[order.count - 1 - slot]].index
            let r = k / T, c = k % T
            var band = Band()
            if conv[k] > 0 {
                band.peakRho = Double(r)
                band.peakTheta = Double(c)
                band.max = conv[k]
                let up = conv[(r - 1) * T + c], down = conv[(r + 1) * T + c]
                if Swift.min(up, conv[k], down) > 0 {
                    let a = (log(down) - log(up)) * 0.5 - log(conv[k])
                    if a < -1e-8 { band.width = 2 * (log(2.0) / (-a)).squareRoot() }
                }
                var nn = [Double](repeating: 0, count: 9)
                for dr in -1...1 { for dc in -1...1 { nn[(dr + 1) * 3 + dc + 1] = conv[(r + dr) * T + c + dc] } }
                var total = nn.reduce(0, +)
                total = total > 1e-12 ? total : 1e-12
                nn = nn.map { $0 / total }
                band.averageMax = total / 9
                let dx = 0.5 * (nn[5] - nn[3]), dy = 0.5 * (nn[7] - nn[1])
                let dxx = nn[5] + nn[3] - 2 * nn[4], dyy = nn[7] + nn[1] - 2 * nn[4]
                let dxy = 0.25 * (nn[8] - nn[2] - nn[6] + nn[0])
                var det = dxx * dyy - dxy * dxy
                det = abs(det) > 1e-12 ? det : 1e-12
                det = 1 / det
                var dc = (dyy * dx - dxy * dy) * det, rc = (dxx * dy - dxy * dx) * det
                if abs(dc) > 0.875 || abs(rc) > 0.875 {
                    var det2 = dxx * dyy
                    det2 = abs(det2) > 1e-12 ? det2 : 1e-12
                    det2 = 1 / det2
                    dc = dyy * dx * det2
                    rc = dxx * dy * det2
                    if abs(dc) > 0.875 || abs(rc) > 0.875 { dc = 0; rc = 0 }
                }
                band.rhoIndex = Double(r) - rc
                band.thetaIndex = Double(c) - dc
                band.valid = true
            }
            bands[slot] = band
        }
        for s in 0..<bands.count {
            bands[s].peakRho -= pR
            bands[s].peakTheta -= pT
            bands[s].rhoIndex -= pR
            bands[s].thetaIndex -= pT
            bands[s].normalizedMax = (bands[s].max - mn) / Swift.max(mean - mn, 1e-7)
            bands[s].theta = Double.pi - Self.interpolate(bands[s].thetaIndex, thetaDegrees) / HoughReflectorLibrary.degrees
            bands[s].rho = -Self.interpolate(bands[s].rhoIndex, rhoValues)
        }
        return bands
    }

    /// `np.interp(x, arange(n), values)`: linear, clamped to the end values.
    static func interpolate(_ x: Double, _ values: [Float]) -> Double {
        guard x > 0 else { return Double(values[0]) }
        let last = values.count - 1
        guard x < Double(last) else { return Double(values[last]) }
        let i = Int(x)
        let f = x - Double(i)
        return Double(values[i]) + f * (Double(values[i + 1]) - Double(values[i]))
    }

    // MARK: - Band normals

    /// `radon2pole` with vendor "KIKUCHIPY" (Bruker PC: x from the left in pattern widths, y from the top in pattern
    /// heights, z in pattern heights): each band's unit plane normal in the detector frame.
    package func normals(_ bands: [Band], pc: SIMD3<Double>) -> [SIMD3<Double>] {
        let w = Double(columns), h = Double(rows)
        let t = SIMD3(pc.x * w, h - pc.y * h, -pc.z * h)
        return bands.map { b in
            let s = sin(b.theta), c = cos(b.theta)
            let r = SIMD3(-s, c, 0)
            let p = SIMD3(b.rho * c + w * 0.5, b.rho * s + h * 0.5, 0)
            let n = Vector3.cross(r, p - t)
            let len = Swift.max((n * n).sum().squareRoot(), 1e-12)
            return n / len
        }
    }
}
