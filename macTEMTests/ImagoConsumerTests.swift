//
//  ImagoConsumerTests.swift
//  Three plants macTEM's own tests held before ImagoKit 0.1.0 replaced the FFT, spot and HRTEM-filter copies, and
//  whose cases the kit's committed pins do not contain: the filters' scaling invariance, a weak wave under a large DC on
//  a non-power-of-two size (the mean removed in Double), and a spot whose two bins either side tie. They run the kit on
//  images built here, through the seam (`CalibratedImage.micrograph`). The other plants of the deleted tests (a click two
//  bins off, a strong DC beside a low-frequency spot) are in the kit's pins (`x128-k5-*-c*`, `dc1000-*`).
//

import XCTest
import TEMCore
import ImagoCore
import ImagoFFT
import ImagoFilters

nonisolated final class ImagoConsumerTests: XCTestCase {

    /// DC 1000 + two bin-centred waves + a seeded white noise of sigma 5 (a fixed linear congruential sequence, Box-Muller).
    private static func lattice(_ n: Int, seed: UInt64 = 20261013) -> [Float] {
        var state = seed
        func uniform() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return (Double(state >> 11) + 0.5) / Double(1 << 53)
        }
        var image = [Float](repeating: 0, count: n * n)
        for row in 0..<n {
            for col in 0..<n {
                let x = Double(col), y = Double(row), N = Double(n)
                let wave = 60 * cos(2 * .pi * (7 * x + 3 * y) / N + 0.4) + 40 * cos(2 * .pi * (-2 * x + 9 * y) / N + 1.1)
                let gauss = (-2 * log(uniform())).squareRoot() * cos(2 * .pi * uniform())
                image[row * n + col] = Float(1000 + wave + 5 * gauss)
            }
        }
        return image
    }

    /// The masks are ratios, so scaling the input scales both outputs and leaves the masks unchanged.
    func testScalingTheInputScalesTheOutputs() throws {
        let n = 64
        let image = Self.lattice(n)
        let one = try HRTEMFilter.filter(pixels: image, width: n, height: n, parameters: .defaults)
        let scaled = try HRTEMFilter.filter(pixels: image.map { $0 * 4 }, width: n, height: n, parameters: .defaults)
        XCTAssertEqual(one.passes, scaled.passes)
        let oneABSF = one.absf.float32Values, scaledABSF = scaled.absf.float32Values
        let oneWiener = one.wiener.float32Values, scaledWiener = scaled.wiener.float32Values
        let peak = oneABSF.map { abs(Double($0)) }.max()!
        for i in stride(from: 0, to: n * n, by: 7) {
            XCTAssertEqual(Double(scaledABSF[i]) / 4, Double(oneABSF[i]), accuracy: 1e-5 * peak)
            XCTAssertEqual(Double(scaledWiener[i]) / 4, Double(oneWiener[i]), accuracy: 1e-5 * peak)
            XCTAssertEqual(scaled.absfMask[i], one.absfMask[i], accuracy: 1e-5)
        }
    }

    /// At n = 50 under a DC of 10^4, one cosine of amplitude 10 at bin (3, 5) has W = 10 n^2 / 2 = 12 500 at its bins;
    /// off them the largest W is 0.29 with the mean removed and 1.08 without (measured 2026-10-13 on the copy this replaced).
    func testUnderALargeDCAWeakWaveKeepsAClearSpectrum() throws {
        let n = 50
        var pixels = [Float](repeating: 0, count: n * n)
        var sum = 0.0
        for row in 0..<n {
            for col in 0..<n {
                pixels[row * n + col] = Float(10_000 + 10 * cos(2 * Double.pi * (5 * Double(col) + 3 * Double(row)) / Double(n)))
                sum += Double(pixels[row * n + col])
            }
        }
        let result = try HRTEMFilter.filter(pixels: pixels, width: n, height: n, parameters: .defaults)
        let centre = (n / 2) * n + n / 2
        let peaks = [(n / 2 + 3) * n + n / 2 + 5, (n / 2 - 3) * n + n / 2 - 5]
        XCTAssertEqual(result.spectrum[centre], abs(sum), accuracy: 1e-9 * abs(sum))
        for p in peaks { XCTAssertEqual(result.spectrum[p], 12_500, accuracy: 1) }
        var offPeak = 0.0
        for i in 0..<(n * n) where i != centre && !peaks.contains(i) { offPeak = max(offPeak, result.spectrum[i]) }
        XCTAssertLessThan(offPeak, 0.6)
    }

    /// At 200.5 bins on 512 px the two bins either side carry equal power to about 1e-8: a tie. The first in row-major order
    /// is taken, whatever float noise does, and the twin is not a second peak.
    func testAnExactHalfBinTieSnapsToTheFirstBinAndIsNoNeighbour() throws {
        let w = 512, h = 64, dx = 0.02
        let f = 200.5 / (Double(w) * dx)
        let pixels = (0..<(w * h)).map { i in Float(100 + 10 * cos(2 * .pi * f * Double(i % w) * dx)) }
        let image = try Micrograph(width: w, height: h, pixels: pixels, x: AxisCalibration(scale: dx, unit: "nm"),
                                   y: AxisCalibration(scale: dx, unit: "nm"))
        let m = try SpotMeasurement.measure(image, clickRow: h / 2, clickColumn: w / 2 + 201)
        XCTAssertEqual(m.snappedCol, w / 2 + 200, "the first of the tied pair")
        XCTAssertFalse(m.neighbour)
        XCTAssertLessThan(abs(m.d * f - 1), 0.002)
    }
}
