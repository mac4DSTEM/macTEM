//
//  ImageExportTwinTests.swift
//  Pins what the export takes from ImagoKit against the app's own functions (the kit's `ScaleBarMath` and `DisplayMapping` do
//  the export's arithmetic; the screen's `ScaleBar`, `ImageScaleBar` and `Colormaps` are the app's): `ScaleBarMath.format` equals
//  `ScaleBar.format` in `en_US_POSIX`, `ScaleBarMath.sampling` with the app's unit spelling equals `ImageScaleBar.sampling` for a
//  grid of images, and `ImageExport.rgb` equals `Colormaps.sampleRGB` of the shader's mapped value, for every `ColormapKind`.
//  Equality is EXACT (bit patterns for numbers, `==` for text). `rgb` against the real display pipeline on this Mac's GPU is
//  `ImageExportGPUTests`.
//

import ShellControls
import ShellMetal
import ImagoCore
import XCTest
import TEMCore
@testable import macTEM

nonisolated final class ImageExportTwinTests: XCTestCase {

    private static let posix = Locale(identifier: "en_US_POSIX")
    private static let micro = "\u{00B5}m"

    /// The mismatches a grid walk found; one failure for the walk, naming the first few, not one per comparison.
    private struct Mismatches {
        private(set) var count = 0
        private(set) var compared = 0
        private var first: [String] = []
        mutating func check(_ ok: Bool, _ detail: @autoclosure () -> String) {
            compared += 1
            guard !ok else { return }
            count += 1
            if first.count < 8 { first.append(detail()) }
        }
        var summary: String { "\(count) of \(compared) differ; first: \(first)" }
    }

    // MARK: grids

    /// Decimal values of the form m × 10^e, parsed from text so that each is the correctly rounded double a person would
    /// type (3.5e-3 is not 3.5 × 10⁻³ computed in binary), with the neighbours one ulp either side of each boundary.
    private static func decade(_ mantissas: [Double], exponents: ClosedRange<Int>) -> [Double] {
        var out: [Double] = []
        for e in exponents {
            for m in mantissas {
                if let v = Double("\(m)e\(e)") { out += [v.nextDown, v, v.nextUp] }
                out.append(m * pow(10, Double(e)))
            }
        }
        return out
    }

    // MARK: format

    @MainActor func testFormatEqualsTheScaleBarsInEnUSPosix() {
        var values = Self.decade([1, 2, 5, 10, 20, 50, 100, 200, 500], exponents: -9...9)
        values += Self.decade(Array(stride(from: 0.1, through: 100.0, by: 0.173)), exponents: -3...3)
        // The regime edges (%.3g below 1, %g from 1, %.0f from 10) and the rounding ties inside them.
        values += [0.9999999, 0.9995, 0.99949, 0.12345, 0.0005, 9.5, 9.99, 9.9999999, 10, 10.4, 10.5, 99.5, 999.5, 1000, 20_000,
                   1e-5, 1e15, 0, -1, .nan, .infinity, -.infinity, 5e-324]
        var m = Mismatches()
        for v in values {
            let mine = ScaleBarMath.format(v), theirs = ScaleBar.format(v, locale: Self.posix)
            m.check(mine == theirs, "format(\(v)): twin \"\(mine)\", app \"\(theirs)\"")
        }
        XCTAssertGreaterThan(m.compared, 3_000)
        XCTAssertEqual(m.count, 0, m.summary)
        for (v, text) in [(10.0, "10"), (20, "20"), (1000, "1000"), (20_000, "20000"), (1, "1"), (2.5, "2.5"), (0.5, "0.5"),
                          (0.05, "0.05"), (0.0001, "0.0001"), (0.123456, "0.123")] {
            XCTAssertEqual(ScaleBarMath.format(v), text, "format(\(v))")
        }
        // The deliberate difference from the screen: the app follows the reader's locale, the file never does.
        XCTAssertEqual(ScaleBar.format(2.5, locale: Locale(identifier: "de_DE")), "2,5")
        XCTAssertEqual(ScaleBarMath.format(2.5), "2.5")
    }

    // MARK: sampling

    /// The sampling the bar measures from: `ImageScaleBar.sampling(image)` (the pane's own function, with
    /// `ScaleBarMath.sampling`) against the twin, over metre, nm, µm, Å, reciprocal and
    /// unit-less axes at many scales and sizes, x only, y only, both, and mixed. A metre axis moves between nm, µm and mm
    /// at the image's width, so the grid brackets 1 µm and 1 mm at several widths.
    @MainActor func testSamplingEqualsImageScaleBarSamplingOverAGridOfImages() {
        let scales: [Double] = [4.46179e-11, 1e-10, 1e-9, 5e-9, 1e-8, 3e-8, 4e-8, 1e-7, 1e-6, 1e-5, 1e-4, 1e-3, 2e-3, 0.0123, 0.5, 1,
                                56.79, 1e3, 1e6, 0.9999e-9, 1.0001e-9, 0.9999e-6, 1.0001e-6, 0, -1e-9, .nan, .infinity, -.infinity]
        let units = ["m", "meter", "Metres", " m ", "M", "nm", Self.micro, "\u{03BC}m", "mm", "\u{00C5}", "pm", "1/nm", "1/\u{00C5}",
                     "mrad", "px", "", "furlong"]
        let sizes: [(w: Int, h: Int)] = [(1, 1), (7, 3), (100, 5), (1000, 64), (1000, 1), (2048, 5), (5000, 3), (3, 5000), (64, 1000)]
        var pixels: [String: [Float]] = [:]
        func image(_ w: Int, _ h: Int, x: AxisCalibration?, y: AxisCalibration?) -> CalibratedImage {
            let zeros = pixels["\(w)x\(h)"] ?? [Float](repeating: 0, count: w * h)
            pixels["\(w)x\(h)"] = zeros
            return CalibratedImage(width: w, height: h, pixels: zeros, x: x, y: y, fileName: "a", source: "", voltage: nil)
        }
        let others: [AxisCalibration] = [AxisCalibration(scale: 0.8, unit: "nm", origin: 0), AxisCalibration(scale: 2e-9, unit: "m", origin: 0),
                                   AxisCalibration(scale: 1e-3, unit: Self.micro, origin: 0), AxisCalibration(scale: 1, unit: "", origin: 0),
                                   AxisCalibration(scale: 0, unit: "nm", origin: 0)]
        var m = Mismatches()
        func compare(_ w: Int, _ h: Int, _ x: AxisCalibration?, _ y: AxisCalibration?) {
            let mine = ScaleBarMath.sampling(x: x, y: y, width: w, height: h, unitLabel: UnitDisplay.label)
            let theirs = ImageScaleBar.sampling(image(w, h, x: x, y: y))
            m.check(mine.perPixel.bitPattern == theirs.perPixel.bitPattern && mine.unit == theirs.label,
                    "\(w)x\(h) x=\(String(describing: x)) y=\(String(describing: y)): twin \(mine), app \(theirs)")
        }
        for unit in units {
            for scale in scales {
                let axis = AxisCalibration(scale: scale, unit: unit, origin: 3)
                for size in sizes {
                    compare(size.w, size.h, axis, axis)
                    compare(size.w, size.h, axis, nil)
                    compare(size.w, size.h, nil, axis)
                    for other in others { compare(size.w, size.h, axis, other); compare(size.w, size.h, other, axis) }
                }
            }
        }
        for size in sizes { compare(size.w, size.h, nil, nil) }
        XCTAssertGreaterThan(m.compared, 40_000)
        XCTAssertEqual(m.count, 0, m.summary)
    }

    /// The hand-worked cases behind the grid (the same numbers `ScaleBarTests` and `ScaleBarReadingTests` pin on the
    /// app's side): a Ceta bar measures in nm and an SEM field's in µm, x's scale is the bar's and y's only stands in for
    /// it when x has one, and the bar counts pixels whenever x is not a physical sampling.
    func testSamplingByHand() {
        let ceta = AxisCalibration(scale: 4.46179e-11, unit: "m", origin: 0)
        let a = ScaleBarMath.sampling(x: ceta, y: ceta, width: 2048, height: 2048, unitLabel: UnitDisplay.label)
        XCTAssertEqual(a.unit, "nm")
        XCTAssertEqual(a.perPixel, 0.0446179, accuracy: 0.0446179 * 1e-12)
        let sem = AxisCalibration(scale: 1e-8, unit: "m", origin: 0)
        let b = ScaleBarMath.sampling(x: sem, y: sem, width: 1536, height: 1024)
        XCTAssertEqual(b.unit, Self.micro)
        XCTAssertEqual(b.perPixel, 0.01, accuracy: 0.01 * 1e-12)
        let nm = AxisCalibration(scale: 0.0123, unit: "nm", origin: 0), nmY = AxisCalibration(scale: 0.0246, unit: "nm", origin: 0)
        XCTAssertEqual(ScaleBarMath.sampling(x: nm, y: nmY, width: 40, height: 24).perPixel, 0.0123, "x's, not y's")
        let yOnly = ScaleBarMath.sampling(x: nil, y: nmY, width: 40, height: 24)
        XCTAssertEqual(yOnly.perPixel, 1)
        XCTAssertEqual(yOnly.unit, "px", "the unit is x's: with no x the bar counts pixels, y or not")
        XCTAssertEqual(ScaleBarMath.sampling(x: nm, y: nil, width: 40, height: 24).perPixel, 0.0123)
        let none = ScaleBarMath.sampling(x: AxisCalibration(scale: -1, unit: "nm", origin: 0), y: nmY, width: 40, height: 24)
        XCTAssertEqual(none.perPixel, 1)
        XCTAssertEqual(none.unit, "px", "an x that is not a physical sampling counts pixels, whatever y says")
    }

    // MARK: rgb

    /// The shader's mapping for one canvas value, restated in the test from Colormaps.metal, then the LUT step of
    /// `Colormaps.sampleRGB` (the app's own, which the pane's export-by-hand used): the reference for `rgb`.
    private static func mapped(_ n: Float, low: Float, high: Float, gamma: Double, lut: [UInt8]) -> (UInt8, UInt8, UInt8) {
        if n < 0 { return (82, 82, 87) }
        var v = min(max(Double(n), 0), 1)
        v = min(max((v - Double(low)) / max(Double(high) - Double(low), 1e-6), 0), 1)
        v = pow(v, 1 / max(gamma, 0.05))
        return Colormaps.sampleRGB(lut, v)
    }

    @MainActor func testRGBEqualsSampleRGBOfTheShaderMappedValueForEveryColormap() {
        var ns: [Float] = [0, 1, 0.5, 0.25, 0.75, 1.0 / 255, 2.0 / 255, 0.001, 0.999, 1e-7, 1 - 1e-7, 0.3333333, 1.5, 100,
                           .leastNonzeroMagnitude, .greatestFiniteMagnitude, -1, -0.0001, -1e30, -.infinity, .infinity]
        // Texel centres and midpoints between them (the LUT's weights are 0 and ½ there), and a golden-ratio spread.
        for k in 0...256 { ns += [(Float(k) + 0.5) / 256, Float(k) / 256] }
        for k in 1...300 { ns.append(Float((Double(k) * 0.6180339887498949).truncatingRemainder(dividingBy: 1))) }
        let windows: [(Float, Float)] = [(0, 1), (0.1, 0.9), (0.25, 0.75), (0.4, 0.45), (0, 1e-7), (0.5, 0.5), (0.9, 0.1), (-0.2, 1.3),
                                         (0.05, 0.2)]
        let gammas: [Double] = [0.04, 0.05, 0.5, 1, 1.7, 2.2, 5]
        var m = Mismatches()
        for kind in ColormapKind.allCases {
            let lut = Colormaps.lutRGBA(kind)
            XCTAssertEqual(lut.count, 1024)
            for (low, high) in windows {
                for gamma in gammas {
                    for n in ns {
                        let mine = ImageExport.rgb(n, low: low, high: high, gamma: gamma, lut: lut)
                        let theirs = Self.mapped(n, low: low, high: high, gamma: gamma, lut: lut)
                        m.check(mine == theirs, "\(kind) n=\(n) window \(low)–\(high) gamma \(gamma): twin \(mine), reference \(theirs)")
                    }
                }
            }
        }
        XCTAssertGreaterThan(m.compared, 200_000)
        XCTAssertEqual(m.count, 0, m.summary)
    }

    /// Values worked out by hand on the gray LUT (entry i is (i, i, i)), so the formula is checked against arithmetic and
    /// not only against its own restatement: v = 0.5, gamma 1 → position 127.5 → ½(127 + 128) → 128 (halves round away
    /// from zero); gamma 2 on n = 0.25 is v = 0.5 again; a window (0.25, 0.75) maps n = 0.5 to ½; n = 0 and 1 are the ends.
    @MainActor func testRGBByHandOnTheGrayLUT() {
        let lut = Colormaps.lutRGBA(.gray)
        func code(_ n: Float, _ low: Float = 0, _ high: Float = 1, gamma: Double = 1) -> UInt8 {
            let c = ImageExport.rgb(n, low: low, high: high, gamma: gamma, lut: lut)
            XCTAssertTrue(c.0 == c.1 && c.1 == c.2, "gray LUT: \(c)")
            return c.0
        }
        XCTAssertEqual(code(0), 0)
        XCTAssertEqual(code(1), 255)
        XCTAssertEqual(code(0.5), 128)
        XCTAssertEqual(code(0.25, gamma: 2), 128, "0.25^(1/2) = 0.5")
        XCTAssertEqual(code(0.5, 0.25, 0.75), 128, "the window's middle")
        XCTAssertEqual(code(0.1, 0.25, 0.75), 0, "below the window")
        XCTAssertEqual(code(0.9, 0.25, 0.75), 255, "above the window")
        XCTAssertEqual(code((127 + 0.5) / 256), 127, "a texel centre is that entry exactly")
        XCTAssertEqual(code(0.0001), 0, "the first half texel is clamped to entry 0")
        XCTAssertEqual(code(0.9, gamma: 0.01), code(0.9, gamma: 0.05), "gamma is floored at 0.05, as the shader does")
        XCTAssertGreaterThan(code(0.9, gamma: 0.01), 10, "0.9^20 is 0.12: not black, so the floor is what the line pins")
        XCTAssertEqual(code(0.5, 0.9, 0.1), 0, "a window with high below low has the span 1e-6: everything under it is black")
    }

    /// A negative canvas value is the masked sentinel (`FloatImage.invalidDisplayValue`, −1): the shader's neutral grey
    /// (0.32, 0.32, 0.34), never a colormap entry, whatever the window, the gamma or the colormap. The twin's constant is
    /// (0.32, 0.32, 0.34) × 255 rounded, written out here.
    @MainActor func testTheMaskedSentinelIsTheShadersGreyForEveryColormap() {
        let expected = (UInt8((0.32 * 255).rounded()), UInt8((0.32 * 255).rounded()), UInt8((0.34 * 255).rounded()))
        XCTAssertEqual(expected.0, 82)
        XCTAssertEqual(expected.2, 87)
        for kind in ColormapKind.allCases {
            let lut = Colormaps.lutRGBA(kind)
            for n in [FloatImage.invalidDisplayValue, -0.5, -1e-9, -Float.infinity, -Float.greatestFiniteMagnitude] {
                for (low, high, gamma) in [(Float(0), Float(1), 1.0), (0.3, 0.6, 2.2), (0.9, 0.1, 0.04)] {
                    let c = ImageExport.rgb(n, low: low, high: high, gamma: gamma, lut: lut)
                    XCTAssertTrue(c == expected, "\(kind) n=\(n): \(c)")
                }
            }
            // Zero is data, not the sentinel.
            let zero = ImageExport.rgb(0, low: 0, high: 1, gamma: 1, lut: lut)
            XCTAssertTrue(zero == (lut[0], lut[1], lut[2]), "\(kind): 0 is the LUT's first entry, \(zero)")
        }
    }
}
