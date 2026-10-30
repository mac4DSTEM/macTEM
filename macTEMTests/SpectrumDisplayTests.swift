//
//  SpectrumDisplayTests.swift
//  How the FFT room DRAWS a power spectrum ("The room"; the display; `SpectrumDisplay.make`): v =
//  log₁₀(|F|² / (W·H)²), NaN at the DC and wherever the power is zero or not finite, and the default window — black at
//  the median of the finite v (a 2048-bin histogram, interpolated), white at the largest finite v more than 3 bins from
//  the centre. Planted spectra (an integer-frequency cosine of amplitude A has |F|² = (A·W·H/2)² at its two bins, so v =
//  2·log₁₀(A/2) whatever the size) and random ones read against their sorted values. A package-level file: TEMCore only.
//

import XCTest
import TEMCore
import ImagoCore
import ImagoFFT

/// A deterministic stream in [0, 1) (an LCG; the test's data are fixed before any run).
nonisolated private struct SpectrumTestStream {
    var state: UInt64
    mutating func next() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double(state >> 11) / Double(1 << 53)
    }
}

nonisolated final class SpectrumDisplayTests: XCTestCase {

    private func image(_ w: Int, _ h: Int, _ f: (Int, Int) -> Double) -> CalibratedImage {
        CalibratedImage(width: w, height: h, pixels: (0..<(w * h)).map { Float(f($0 / w, $0 % w)) },
                        x: AxisCalibration(scale: 0.5, unit: "nm", origin: 0), y: AxisCalibration(scale: 0.25, unit: "nm", origin: 0),
                        fileName: "s", source: "", voltage: nil)
    }

    /// A DC and cosines at integer frequencies (kx, ky) of amplitude A, in cycles per image width and height.
    private func cosines(_ w: Int, _ h: Int, dc: Double, _ terms: [(kx: Int, ky: Int, a: Double)]) -> CalibratedImage {
        image(w, h) { r, c in
            terms.reduce(dc) { $0 + $1.a * cos(2 * .pi * (Double($1.kx * c) / Double(w) + Double($1.ky * r) / Double(h))) }
        }
    }

    private func random(_ w: Int, _ h: Int, seed: UInt64) -> CalibratedImage {
        var stream = SpectrumTestStream(state: seed)
        let pixels = (0..<(w * h)).map { _ in Float(stream.next()) }
        return CalibratedImage(width: w, height: h, pixels: pixels, x: nil, y: nil, fileName: "r", source: "", voltage: nil)
    }

    private func finite(_ d: SpectrumDisplay) -> [Float] { d.values.filter { !$0.isNaN } }

    // MARK: The values

    /// v is log₁₀(|F|² / (W·H)²) at every bin, in Float, and a planted cosine of amplitude 8 reads 2·log₁₀(4) = 1.2041 at
    /// both its bins. Red under: no divisor (the plant reads 1.2041 + 4.57); the divisor W·H instead of its square; the
    /// natural log; |F| for |F|².
    func testValuesAreTheLogOfPowerOverTheTransformedAreaSquared() throws {
        let w = 16, h = 12
        let spectrum = try PowerSpectrum.compute(cosines(w, h, dc: 50, [(3, 2, 8)]).micrograph)
        let d = SpectrumDisplay.make(spectrum)
        XCTAssertEqual(d.width, w)
        XCTAssertEqual(d.height, h)
        XCTAssertEqual(d.values.count, w * h)
        let area = Double(w * h)
        var checked = 0
        for r in 0..<h { for c in 0..<w where !(r == h / 2 && c == w / 2) && spectrum.power.float32Values[r * w + c] > 0 {
            let expected = Float(log10(Double(spectrum.power.float32Values[r * w + c]) / (area * area)))
            XCTAssertEqual(d.values[r * w + c], expected, accuracy: 1e-5, "bin (\(r), \(c))")
            checked += 1
        } }
        XCTAssertGreaterThan(checked, 100)
        let truth = Float(2 * log10(4.0))
        XCTAssertEqual(d.values[(h / 2 + 2) * w + (w / 2 + 3)], truth, accuracy: 1e-4, "the planted peak, (+3, +2)")
        XCTAssertEqual(d.values[(h / 2 - 2) * w + (w / 2 - 3)], truth, accuracy: 1e-4, "and its Friedel partner")
    }

    /// The divisor makes a lattice read the same in a region of any size: the same cosine (3, 2 cycles per width) on 32²
    /// and 64² reads 2·log₁₀(A/2) on both. Red under: no divisor (the two differ by log₁₀(4²) = 1.2); W·H not squared.
    func testALatticeReadsTheSameInARegionOfAnySize() throws {
        let truth = Float(2 * log10(2.5))
        for n in [32, 64, 40] {
            let spectrum = try PowerSpectrum.compute(cosines(n, n, dc: 20, [(3, 2, 5)]).micrograph)
            let d = SpectrumDisplay.make(spectrum)
            XCTAssertEqual(d.values[(n / 2 + 2) * n + (n / 2 + 3)], truth, accuracy: 1e-4, "\(n) × \(n)")
            XCTAssertEqual(d.defaultWindow?.high ?? .nan, truth, accuracy: 1e-4, "\(n) × \(n): it is the largest beyond the disc")
        }
    }

    /// The DC bin (h/2, w/2) — on an odd size too — and every bin whose power is exactly zero are NaN, never −∞; their
    /// neighbours are numbers. A 16 × 8 image of identical rows has power only on the centre row. Red under: the DC drawn
    /// (it is the brightest bin); zero power left to the log (−∞ is not NaN).
    func testTheDCAndZeroPowerBinsAreNaN() throws {
        // Identical rows: the transform is zero off the centre row — checked, not assumed.
        let w = 16, h = 8
        let rows = image(w, h) { _, c in 100 + 10 * cos(2 * .pi * Double(3 * c) / Double(w)) }
        let spectrum = try PowerSpectrum.compute(rows.micrograph)
        for r in 0..<h where r != h / 2 { for c in 0..<w {
            XCTAssertEqual(spectrum.power.float32Values[r * w + c], 0, "premise: bin (\(r), \(c)) has no power")
        } }
        XCTAssertGreaterThan(spectrum.power.float32Values[(h / 2) * w + w / 2], 0, "premise: the DC has power")
        let d = SpectrumDisplay.make(spectrum)
        for r in 0..<h { for c in 0..<w where r != h / 2 {
            XCTAssertTrue(d.values[r * w + c].isNaN, "zero power at (\(r), \(c)) is NaN, not \(d.values[r * w + c])")
        } }
        XCTAssertTrue(d.values[(h / 2) * w + w / 2].isNaN, "the DC")
        XCTAssertEqual(d.values[(h / 2) * w + w / 2 + 3], Float(2 * log10(5.0)), accuracy: 1e-4, "the peak is a number")
        XCTAssertEqual(d.values[(h / 2) * w + w / 2 - 3], Float(2 * log10(5.0)), accuracy: 1e-4)

        // An odd size: the DC is at (4, 7) of 9 × 15, by integer division as the core's axes are.
        let odd = try PowerSpectrum.compute(cosines(15, 9, dc: 30, [(3, 2, 8)]).micrograph)
        XCTAssertGreaterThan(odd.power.float32Values[4 * 15 + 7], 0, "premise: the DC has power")
        let o = SpectrumDisplay.make(odd)
        XCTAssertTrue(o.values[4 * 15 + 7].isNaN)
        XCTAssertEqual(o.values.filter(\.isNaN).count, 1, "only the DC: every other bin of this plant has power")
        XCTAssertEqual(o.values[(4 + 2) * 15 + 7 + 3], Float(2 * log10(4.0)), accuracy: 1e-4)
    }

    /// A power that overflows Float (a 10³⁰ pixel makes every bin ±10³⁰, whose square is +∞) or is NaN is not drawn:
    /// NaN, and no window. Red under: the finite check dropped (+∞ is not NaN, and it becomes the window).
    func testBinsWithAPowerThatIsNotFiniteAreNaN() throws {
        let hot = image(16, 16) { r, c in r == 0 && c == 0 ? 1e30 : 0 }
        let spectrum = try PowerSpectrum.compute(hot.micrograph)
        XCTAssertTrue(spectrum.power.float32Values.contains { $0.isInfinite }, "premise: an infinite power")
        let d = SpectrumDisplay.make(spectrum)
        XCTAssertTrue(d.values.allSatisfy(\.isNaN), "nothing finite to draw")
        XCTAssertNil(d.defaultWindow)
    }

    // MARK: The default window

    /// The window's low is the median of the finite v — without the DC — read from a 2048-bin histogram: within one bin
    /// (range/2048) of the sorted median, and the stated rule exactly (linear interpolation inside the bin that crosses
    /// half). On 7 × 7 there are 48 finite bins, the 24th and 25th smallest far apart; the DC is not one of them. Red
    /// under: the median taken with the DC (rank 25); the minimum or the mean for the median; a coarser histogram; the
    /// bin's lower edge for the interpolated value.
    func testTheDefaultWindowsLowIsTheMedianOfTheFiniteValuesWithoutTheDC() throws {
        for (w, h, seed) in [(7, 7, UInt64(7)), (9, 7, UInt64(21)), (7, 7, UInt64(1234)), (128, 96, UInt64(99))] {
            let spectrum = try PowerSpectrum.compute(random(w, h, seed: seed).micrograph)
            let d = SpectrumDisplay.make(spectrum)
            XCTAssertTrue(d.values[(h / 2) * w + w / 2].isNaN, "premise: the DC is NaN")
            let v = finite(d)
            XCTAssertEqual(v.count, w * h - 1, "\(w) × \(h): every bin but the DC has power")
            let sorted = v.sorted()
            let window = try XCTUnwrap(d.defaultWindow, "\(w) × \(h)")
            let binWidth = (Double(sorted.last!) - Double(sorted.first!)) / 2048
            // The (n/2)-th smallest, 1-based: the histogram's cumulative count reaches half in its bin.
            let rank = Int((Double(v.count) / 2).rounded(.up)) - 1
            XCTAssertEqual(Double(window.low), Double(sorted[rank]), accuracy: binWidth * 1.0001 + 1e-6, "\(w) × \(h): within a bin of the median")
            XCTAssertGreaterThanOrEqual(window.low, sorted.first!)
            XCTAssertLessThanOrEqual(window.low, sorted.last!)
            XCTAssertEqual(window.low, referenceLow(v), accuracy: 1e-5, "\(w) × \(h): the stated rule")
            if w * h == 49 {
                XCTAssertGreaterThan(sorted[24] - sorted[23], Float(10 * binWidth), "premise: the median with the DC would be rank 25, far from rank 24")
            }
        }
    }

    /// A constant v gives that value for the low and the high. A single bright pixel has the same |F| at every bin, so
    /// every non-DC bin reads log₁₀(49/256²). Red under: a constant range dividing by zero (NaN, or a window off the value).
    func testTheDefaultWindowsLowOfAConstantIsThatConstant() throws {
        let delta = image(16, 16) { r, c in r == 0 && c == 0 ? 7 : 0 }
        let d = SpectrumDisplay.make(try PowerSpectrum.compute(delta.micrograph))
        let truth = Float(log10(49.0 / (256.0 * 256.0)))
        let window = try XCTUnwrap(d.defaultWindow)
        XCTAssertEqual(window.low, truth, accuracy: 1e-5)
        XCTAssertEqual(window.high, truth, accuracy: 1e-5)
        XCTAssertTrue(d.values[8 * 16 + 8].isNaN, "the DC is not part of it")
        XCTAssertEqual(finite(d).count, 255)
    }

    /// The window's white is the largest finite v at INDEX distance greater than 3 from the centre: a bin at (2, 0) or
    /// at exactly (3, 0) never sets it, one at (3, 1) — distance 3.16, Chebyshev 3 — does. The plant: amplitudes 50 at
    /// (2, 0), 40 at (3, 0), 6 at (3, 1), 2 at (6, 5): high is 2·log₁₀(3), not 2·log₁₀(25) or 2·log₁₀(20). Red under: no
    /// disc; the disc at ≥ 3; the disc in Chebyshev distance; a disc of 2; the DC's skirt setting the white.
    func testTheDefaultWindowsHighIgnoresTheCentresThreeBinDisc() throws {
        let n = 32
        let spectrum = try PowerSpectrum.compute(cosines(n, n, dc: 100, [(2, 0, 50), (3, 0, 40), (3, 1, 6), (6, 5, 2)]).micrograph)
        let d = SpectrumDisplay.make(spectrum)
        let window = try XCTUnwrap(d.defaultWindow)
        XCTAssertEqual(window.high, Float(2 * log10(3.0)), accuracy: 1e-3, "the (3, 1) bin, 0.954")
        let c = n / 2
        XCTAssertEqual(d.values[c * n + c + 2], Float(2 * log10(25.0)), accuracy: 1e-3, "premise: (2, 0) is drawn, and brighter")
        XCTAssertEqual(d.values[c * n + c + 3], Float(2 * log10(20.0)), accuracy: 1e-3, "premise: so is (3, 0)")
        XCTAssertEqual(d.values[(c + 1) * n + c + 3], Float(2 * log10(3.0)), accuracy: 1e-3)
        XCTAssertTrue(d.values[c * n + c].isNaN)
        XCTAssertLessThan(window.low, window.high, "black below white")
        XCTAssertEqual(SpectrumDisplay.medianBins, 2048)
        XCTAssertEqual(SpectrumDisplay.centreRadius, 3)
    }

    /// No window when nothing lies beyond 3 bins of the centre: the farthest bin of a 4 × 4 or a 5 × 5 spectrum is its
    /// corner, 2√2 = 2.83 away, so every finite bin is inside the disc; a 6 × 6 reaches 3√2 = 4.24. (Nothing finite at all
    /// is the infinite-power test above.) Red under: a white made of the bins inside the disc; the disc left out.
    func testNoWindowWhenNothingLiesBeyondTheDisc() throws {
        for n in [4, 5] {
            let d = SpectrumDisplay.make(try PowerSpectrum.compute(random(n, n, seed: 5).micrograph))
            XCTAssertEqual(finite(d).count, n * n - 1, "premise: every bin but the DC is finite, \(n) × \(n)")
            XCTAssertNil(d.defaultWindow, "\(n) × \(n): all within 3 bins")
        }
        let six = SpectrumDisplay.make(try PowerSpectrum.compute(random(6, 6, seed: 5).micrograph))
        XCTAssertNotNil(six.defaultWindow, "6 × 6: the corners are 4.24 away")
    }

    /// The same on a large random spectrum: the low within a bin of the sorted median and equal to the stated rule, the
    /// high the largest finite v beyond the disc by brute force, the values the formula's. Red under: any of the above
    /// at scale; the histogram's last bin (the maximum itself) lost.
    func testTheDefaultWindowOfALargeSpectrumIsTheStatedRule() throws {
        let w = 160, h = 90
        let spectrum = try PowerSpectrum.compute(random(w, h, seed: 2026).micrograph)
        let d = SpectrumDisplay.make(spectrum)
        let window = try XCTUnwrap(d.defaultWindow)
        var best: Float = -.infinity
        for r in 0..<h { for c in 0..<w {
            let dy = r - h / 2, dx = c - w / 2
            if dx * dx + dy * dy > 9, !d.values[r * w + c].isNaN { best = max(best, d.values[r * w + c]) }
        } }
        XCTAssertEqual(window.high, best, "the brute-force maximum beyond the disc, exactly")
        let v = finite(d)
        XCTAssertEqual(window.low, referenceLow(v), accuracy: 1e-5)
        let sorted = v.sorted()
        let rank = Int((Double(v.count) / 2).rounded(.up)) - 1
        XCTAssertEqual(Double(window.low), Double(sorted[rank]), accuracy: (Double(sorted.last!) - Double(sorted.first!)) / 2048 * 1.0001)
        XCTAssertLessThan(window.low, window.high)
        // A bin's value is its formula's, also at the extremes of the range.
        let area = Double(w * h)
        let i = spectrum.power.float32Values.indices.filter { $0 != (h / 2) * w + w / 2 }.max { spectrum.power.float32Values[$0] < spectrum.power.float32Values[$1] }!
        XCTAssertEqual(d.values[i], Float(log10(Double(spectrum.power.float32Values[i]) / (area * area))), accuracy: 1e-6)
        XCTAssertEqual(d.values[i], sorted.last!, "the brightest bin outside the DC is the maximum")
    }

    /// The rule as the file states it, written again: a 2048-bin histogram of `v` over [min, max] (the maximum in the
    /// last bin), then the bin where the cumulative count first reaches half, interpolated linearly inside it.
    private func referenceLow(_ v: [Float]) -> Float {
        let lo = Double(v.min()!), hi = Double(v.max()!)
        if lo == hi { return Float(lo) }
        let bins = 2048
        let width = (hi - lo) / Double(bins)
        var counts = [Int](repeating: 0, count: bins)
        for x in v { counts[min(Int((Double(x) - lo) / width), bins - 1)] += 1 }
        let half = Double(v.count) / 2
        var below = 0
        for b in 0..<bins {
            if Double(below + counts[b]) >= half {
                return Float(lo + (Double(b) + (half - Double(below)) / Double(counts[b])) * width)
            }
            below += counts[b]
        }
        return Float(hi)
    }
}
