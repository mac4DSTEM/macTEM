//
//  FFTPreprocessTests.swift
//  The FFT room's window, smoothing, band-pass and "find spots" (`FFTPreprocess`, `FFTSpotFinder`, TEMCore; `FFTAnalysis`, TEMSession) on
//  planted images whose spectra are known: a sinusoid between two bins leaks without a window and hardly with one; smoothing takes the
//  high frequencies out, a band-pass the mean or one end of the spectrum; the finder puts the planted lattice's reflections on the
//  spectrum and the existing estimator measures their spacing.
//
//  WHAT IS PINNED (D12, D17): the filters and the window values are ImagoKit's (parity-tested there); these tests pin that the room hands them
//  the pixels, applies them in the order the inspector lists them, and that what they do to a known spectrum is what the filter is for. The
//  bounds are written where they are used, with their reason.
//

import XCTest
import ImagoCore
import ImagoFFT
import ImagoFilters
import TEMCore
import TEMSession
@testable import macTEM

nonisolated final class FFTPreprocessTests: XCTestCase {

    static let n = 128

    static func micrograph(_ f: (Int, Int) -> Double) throws -> Micrograph {
        var px = [Float](repeating: 0, count: n * n)
        for y in 0..<n { for x in 0..<n { px[y * n + x] = Float(f(x, y)) } }
        return try Micrograph(width: n, height: n, pixels: px, x: AxisCalibration(scale: 0.1, unit: "nm"), y: AxisCalibration(scale: 0.1, unit: "nm"))
    }

    /// The power at the bin `dx`, `dy` from the centre of the (centred) spectrum.
    static func power(_ m: Micrograph, dx: Int, dy: Int) throws -> Double {
        let s = try PowerSpectrum.compute(m)
        return s.power[(s.height / 2 + dy) * s.width + (s.width / 2 + dx)]
    }

    // MARK: The window

    /// A sinusoid of 10.5 cycles (between two bins) leaks along the axis without a window; Hann takes the leakage far from the peak down by
    /// orders of magnitude. Red under: the window not applied; applied after the transform's crop instead of to the pixels.
    func testAHannWindowRemovesTheLeakageFarFromAPeak() throws {
        let m = try Self.micrograph { x, _ in sin(2 * .pi * 10.5 * Double(x) / 128) }
        let peak = try Self.power(m, dx: 10, dy: 0)
        let raw = try Self.power(m, dx: 40, dy: 0) / peak
        let hann = try FFTPreprocess(window: .hann).apply(m)
        let windowed = try Self.power(hann, dx: 40, dy: 0) / (try Self.power(hann, dx: 10, dy: 0))
        XCTAssertGreaterThan(raw, 1e-6, "without a window the sidelobe at 30 bins away is a rectangular window's: \(raw)")
        XCTAssertLessThan(windowed, raw / 1000, "Hann's sidelobes fall far faster: \(windowed) against \(raw)")
        // The pixels are the kit's window times the image: the middle is kept, the edge goes to zero.
        XCTAssertEqual(hann.pixels[64 * 128 + 64], m.pixels[64 * 128 + 64] * Float(try WindowFunction.window2D(.hann, rows: 128, columns: 128)[64 * 128 + 64]))
        XCTAssertEqual(hann.pixels[0], 0, accuracy: 1e-6, "a Hann window is zero on the corner")
    }

    // MARK: Smoothing and band-pass

    /// Gaussian smoothing takes the high-frequency power of a noise image down; a band-pass takes the mean out (difference of Gaussians) or one
    /// end of the spectrum out (Butterworth). Red under: a filter not applied; a filter of the wrong kind.
    func testSmoothingAndBandpassActOnTheSpectrumAsTheirNamesSay() throws {
        var seed: UInt64 = 7
        func noise() -> Double { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Double(seed >> 33) / Double(1 << 31) - 0.5 }
        let grainy = try Self.micrograph { _, _ in noise() }
        let smooth = try FFTPreprocess(smoothing: .gaussian(sigma: 2)).apply(grainy)
        let high = try Self.power(grainy, dx: 50, dy: 0) + (try Self.power(grainy, dx: 0, dy: 50))
        let highAfter = try Self.power(smooth, dx: 50, dy: 0) + (try Self.power(smooth, dx: 0, dy: 50))
        // The smoothed image is no longer periodic, so its wrap-around edge leaves a little (about 1/400) at 50 bins: the bound is 1/100.
        XCTAssertLessThan(highAfter, high / 100, "a Gaussian of 2 px takes the power at 50 bins down: \(highAfter) of \(high)")

        let offset = try Self.micrograph { x, _ in 100 + 5 * sin(2 * .pi * 5 * Double(x) / 128) }
        let dog = try FFTPreprocess(bandpass: .differenceOfGaussians(lowSigma: 3)).apply(offset)
        let dcBefore = try Self.power(offset, dx: 0, dy: 0), dcAfter = try Self.power(dog, dx: 0, dy: 0)
        XCTAssertLessThan(dcAfter, dcBefore / 1e4, "a difference of Gaussians has no mean: \(dcAfter) of \(dcBefore)")
        let kept = try Self.power(dog, dx: 5, dy: 0) / (try Self.power(offset, dx: 5, dy: 0))
        XCTAssertGreaterThan(kept, 0.02, "the 5-cycle line is in the pass band (about 7 % of its power): \(kept)")

        let two = try Self.micrograph { x, _ in 50 * sin(2 * .pi * 2 * Double(x) / 128) + 50 * sin(2 * .pi * 40 * Double(x) / 128) }
        let highPass = try FFTPreprocess(bandpass: .butterworth(cutoff: 0.1, highPass: true)).apply(two)
        let lowPass = try FFTPreprocess(bandpass: .butterworth(cutoff: 0.1, highPass: false)).apply(two)
        let lowBefore = try Self.power(two, dx: 2, dy: 0), highBefore = try Self.power(two, dx: 40, dy: 0)
        XCTAssertLessThan(try Self.power(highPass, dx: 2, dy: 0), lowBefore * 0.05, "the 2-cycle line is below the cutoff of 6.4")
        XCTAssertGreaterThan(try Self.power(highPass, dx: 40, dy: 0), highBefore * 0.9, "the 40-cycle line passes")
        XCTAssertGreaterThan(try Self.power(lowPass, dx: 2, dy: 0), lowBefore * 0.9)
        XCTAssertLessThan(try Self.power(lowPass, dx: 40, dy: 0), highBefore * 0.05)
    }

    /// Nothing chosen is the identity, the words say what was chosen, and the stages run in the listed order (a window last, so the
    /// edge of the filtered image is what tapers).
    func testNoPreprocessIsTheIdentityAndTheSummaryNamesTheStages() throws {
        let m = try Self.micrograph { x, y in Double(x * 3 + y) }
        XCTAssertTrue(FFTPreprocess().isNone)
        XCTAssertEqual(try FFTPreprocess().apply(m), m)
        XCTAssertEqual(FFTPreprocess().summary, "none")
        let all = FFTPreprocess(window: .hann, smoothing: .gaussian(sigma: 2), bandpass: .differenceOfGaussians(lowSigma: 3))
        XCTAssertEqual(all.summary, "Gaussian σ 2 px, difference of Gaussians (low σ 3 px), Hann window")
        XCTAssertFalse(all.isNone)
        let order = try SeparableFilters.gaussianFilter(m.pixels, rows: 128, columns: 128, sigma: (row: 2, column: 2))
        let dog = try BandpassFilters.differenceOfGaussians(order, rows: 128, columns: 128, lowSigma: (row: 3, column: 3))
        let w = try WindowFunction.window2D(.hann, rows: 128, columns: 128)
        let expected = dog.indices.map { dog[$0] * Float(w[$0]) }
        XCTAssertEqual(try all.apply(m).pixels, expected, "smoothing, then band-pass, then window")
        XCTAssertEqual(FFTPreprocess(bandpass: .butterworth(cutoff: 0.1, highPass: false)).summary, "Butterworth low-pass at 0.1")
    }

    // MARK: Find spots

    static func lattice(period: Double = 16, size: Int = 256) throws -> CalibratedImage {
        var px = [Float](repeating: 0, count: size * size)
        for y in 0..<size { for x in 0..<size { px[y * size + x] = Float(1000 + 300 * cos(2 * .pi * Double(x) / period) + 300 * cos(2 * .pi * Double(y) / period)) } }
        let axis = AxisCalibration(scale: 0.1, unit: "nm")
        return CalibratedImage(width: size, height: size, pixels: px, x: axis, y: axis, fileName: "lattice.dm4", source: "test", voltage: nil)
    }

    /// On a planted square lattice (16 px, noise-free) the finder returns the two reflections of the half plane, strongest first, and nothing
    /// else: not the centre, not a mirror. Red under: the centre kept; both of a mirror pair; a threshold that lets sidelobes in.
    func testTheFinderFindsThePlantedReflectionsAndNothingElse() async throws {
        let image = try Self.lattice()
        let product = try await FFTCompute.live.spectrum(image, FFTSpectrumKey(contentVersion: 1, crop: nil))
        let found = try FFTSpotFinder.find(values: product.canvas.normalized, width: product.width, height: product.height, settings: FFTSpotFinder.Settings())
        let cx = product.width / 2, cy = product.height / 2
        XCTAssertEqual(Set(found.map { "\($0.row),\($0.column)" }), ["\(cy),\(cx + 16)", "\(cy + 16),\(cx)"], "\(found)")
        // A flat image has no spot.
        let flat = CalibratedImage(width: 64, height: 64, pixels: [Float](repeating: 5, count: 64 * 64), x: nil, y: nil, fileName: "f", source: "t", voltage: nil)
        let flatProduct = try await FFTCompute.live.spectrum(flat, FFTSpectrumKey(contentVersion: 1, crop: nil))
        XCTAssertTrue(try FFTSpotFinder.find(values: flatProduct.canvas.normalized, width: 64, height: 64, settings: FFTSpotFinder.Settings()).isEmpty)
    }

    /// Through the room's owner: Find Spots puts the reflections on the transform, the existing estimator measures their d (1.6 nm, the planted
    /// period at 0.1 nm/px), and a new preprocess takes the spots away and asks for a new spectrum. Red under: spots measured on the raw pixels
    /// while a window is on; the spots kept across a change of the transform.
    @MainActor func testFindSpotsThroughTheOwnerMeasuresThePlantedSpacingAndAPreprocessResetsThem() async throws {
        let image = try Self.lattice()
        let analysis = FFTAnalysis(compute: .live)
        analysis.show(image, contentVersion: 1)
        for _ in 0..<2000 where !analysis.isSpectrumCurrent { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(analysis.isSpectrumCurrent)
        analysis.findSpots()
        for _ in 0..<2000 where analysis.spots.contains(where: { if case .measuring = $0.outcome { true } else { false } }) || analysis.spots.isEmpty {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(analysis.spots.count, 2)
        for spot in analysis.spots {
            let m = try XCTUnwrap(spot.measured, "spot \(spot.number): \(spot.outcome)")
            XCTAssertEqual(m.d, 1.6, accuracy: 0.05, "the planted period of 16 px at 0.1 nm/px")
        }

        analysis.setPreprocess(FFTPreprocess(window: .hann))
        XCTAssertTrue(analysis.spots.isEmpty, "the spots belong to the old transform")
        for _ in 0..<2000 where !analysis.isSpectrumCurrent { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(analysis.spectrum?.key.preprocess, FFTPreprocess(window: .hann))
        analysis.findSpots()
        for _ in 0..<2000 where analysis.spots.contains(where: { if case .measuring = $0.outcome { true } else { false } }) || analysis.spots.isEmpty {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertGreaterThanOrEqual(analysis.spots.count, 2, "a windowed lattice still has its reflections")
        let first = try XCTUnwrap(analysis.spots.first?.measured)
        XCTAssertEqual(first.d, 1.6, accuracy: 0.05)
        analysis.setPreprocess(FFTPreprocess(window: .hann))     // the same again: nothing to redo
        XCTAssertFalse(analysis.spots.isEmpty)
    }

    /// The finder's settings are kept inside what it accepts, and a count of one puts one spot on the transform.
    /// Red under: a setting outside its range reaching the finder; the count ignored.
    @MainActor func testTheFinderSettingsAreClampedAndTheCountIsHonoured() async throws {
        let analysis = FFTAnalysis(compute: .live)
        analysis.setSpotFinder(thresholdFraction: 5, minDistance: 1000, count: 0)
        XCTAssertEqual(analysis.spotFinder.thresholdFraction, 0.99)
        XCTAssertEqual(analysis.spotFinder.minDistance, 64)
        XCTAssertEqual(analysis.spotFinder.count, 1)
        analysis.setSpotFinder(thresholdFraction: -1, minDistance: 0, count: 500)
        XCTAssertEqual(analysis.spotFinder.thresholdFraction, 0.05)
        XCTAssertEqual(analysis.spotFinder.minDistance, 2)
        XCTAssertEqual(analysis.spotFinder.count, 40)
        analysis.setSpotFinder(thresholdFraction: 0.75, minDistance: 8, count: 1)
        let image = try Self.lattice()
        analysis.show(image, contentVersion: 1)
        for _ in 0..<2000 where !analysis.isSpectrumCurrent { try await Task.sleep(for: .milliseconds(5)) }
        analysis.findSpots()
        for _ in 0..<2000 where analysis.spots.contains(where: { if case .measuring = $0.outcome { true } else { false } }) || analysis.spots.isEmpty {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(analysis.spots.count, 1, "the lattice has two reflections; the count asked for one")
    }
}
