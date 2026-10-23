//
//  LineProfileTests.swift
//  The line profile (archive: roadmap-registrations-2026-10-15.md V1-5): a ramp's samples are exact under bilinear interpolation, the sample count is
//  skimage's ⌈hypot + 1⌉, a width averages perpendicular samples one pixel apart, the border reflects (half-sample
//  symmetric: d c b a | a b c d | d c b a), and a zero-length line is one sample. The parity against scikit-image 0.26.0
//  at every sample is tools/parity/profile-parity; the constants below were produced by that reference (script in the test).
//

import ImagoCore
import XCTest
import TEMCore

nonisolated final class LineProfileTests: XCTestCase {
    private func image(_ w: Int, _ h: Int, x: AxisCalibration? = nil, y: AxisCalibration? = nil,
                       _ f: (Int, Int) -> Double) -> CalibratedImage {
        CalibratedImage(width: w, height: h, pixels: (0..<(w * h)).map { Float(f($0 / w, $0 % w)) },
                        x: x, y: y, fileName: "p", source: "", voltage: nil)
    }

    private func line(_ image: CalibratedImage, _ r0: Double, _ c0: Double, _ r1: Double, _ c1: Double,
                      width: Int = 1) -> LineProfile {
        LineProfile.sample(image, from: ImagePoint(x: c0, y: r0), to: ImagePoint(x: c1, y: r1), width: width)
    }

    func testARampsSamplesAreItsValueAtEverySamplePoint() {
        // v = 100 + 3r + 2c is linear, so bilinear interpolation reproduces it between pixels (float32 holds every pixel exactly).
        let img = image(20, 15) { r, c in 100 + 3 * Double(r) + 2 * Double(c) }
        let horizontal = line(img, 5, 2, 5, 12)
        XCTAssertEqual(horizontal.samples, (0...10).map { 115 + 2 * (2 + Double($0)) })
        // A sub-pixel diagonal: 8 columns and 6 rows, length 10, n = 11, sample i at (2.25 + 0.6 i, 1.5 + 0.8 i).
        let diagonal = line(img, 2.25, 1.5, 8.25, 9.5)
        XCTAssertEqual(diagonal.samples.count, 11)
        for (i, v) in diagonal.samples.enumerated() {
            let t = Double(i) / 10
            XCTAssertEqual(v, 100 + 3 * (2.25 + 6 * t) + 2 * (1.5 + 8 * t), accuracy: 1e-10, "sample \(i)")
        }
    }

    func testTheSampleCountIsTheCeilingOfTheLengthPlusOne() {
        let img = image(30, 30) { _, _ in 1 }
        XCTAssertEqual(line(img, 0, 0, 0, 10).samples.count, 11, "length 10: the end point is included")
        XCTAssertEqual(line(img, 0, 0, 3, 4).samples.count, 6, "hypot(3, 4) = 5 exactly")
        XCTAssertEqual(line(img, 0, 0, 0, 10.5).samples.count, 12, "⌈11.5⌉")
        XCTAssertEqual(line(img, 0, 0, 0, 10.0000001).samples.count, 12, "a hair over 10 gains a sample")
        XCTAssertEqual(line(img, 0, 0, 0, 1e-7).samples.count, 2, "any non-zero length is at least two samples")
        let p = line(img, 0, 0, 0, 10.5)
        XCTAssertEqual(p.positions.first, 0)
        XCTAssertEqual(p.positions.last, 10.5, "the last sample is the end of the line")
        XCTAssertEqual(p.positions[1], 10.5 / 11, accuracy: 1e-15, "sample i sits at i/(n − 1) of the length")
    }

    func testWidthThreeAveragesThreePerpendicularRows() {
        // v = r², a horizontal line along row 5: the rows 4, 5, 6 give mean (16 + 25 + 36) / 3 = 25 + 2/3.
        let img = image(12, 12) { r, _ in Double(r * r) }
        XCTAssertEqual(line(img, 5, 1, 5, 9, width: 1).samples, Array(repeating: 25, count: 9))
        for v in line(img, 5, 1, 5, 9, width: 3).samples { XCTAssertEqual(v, 25 + 2.0 / 3.0, accuracy: 1e-12) }
        // Width 4: offsets ±0.5, ±1.5 — rows 3.5, 4.5, 5.5, 6.5, each interpolated linearly between its two rows:
        // (12.5 + 20.5 + 30.5 + 42.5) / 4.
        for v in line(img, 5, 1, 5, 9, width: 4).samples { XCTAssertEqual(v, 26.5, accuracy: 1e-12) }
        // Down a column the perpendicular runs along the row, which v does not change: width 3 equals width 1.
        XCTAssertEqual(line(img, 2, 5, 9, 5, width: 3).samples, (2...9).map { Double($0 * $0) }, accuracy: 1e-12)
    }

    func testAnObliqueLineOffsetsPerpendicularlyAsScikitImageDoes() {
        // v = (7r + 13c + r·c) mod 11 on 8 × 6 pixels; expected from scikit-image 0.26.0 (scipy 1.18.1, numpy 2.5.4), the image cast to
        // float64, `profile_line(img, (1, 1), (4, 6), linewidth=3, order=1, mode="reflect", reduce_func=np.mean)` and
        // `profile_line(img, (1.5, 0.5), (4.5, 6.5), linewidth=4, ...)`; the float32 run differs by ≤ 3.3e-7.
        let img = image(8, 6) { r, c in Double((r * 7 + c * 13 + r * c) % 11) }
        let w3 = line(img, 1, 1, 4, 6, width: 3).samples
        let want3 = [6.292904247584446, 3.6491903330907056, 5.038242987635592, 5.455882352941175,
                     5.0416201385958, 4.39792234506433, 5.292904247584445]
        XCTAssertEqual(w3.count, want3.count)
        for (g, w) in zip(w3, want3) { XCTAssertEqual(g, w, accuracy: 1e-9) }
        let w4 = line(img, 1.5, 0.5, 4.5, 6.5, width: 4).samples
        let want4 = [6.382372542187894, 4.40367178984098, 4.686382926913726, 5.122940081372219,
                     5.060733388015537, 4.571919673208952, 5.223521995731952, 2.4395898033750294]
        XCTAssertEqual(w4.count, want4.count)
        for (g, w) in zip(w4, want4) { XCTAssertEqual(g, w, accuracy: 1e-9) }
    }

    func testTheBorderReflectsHalfASampleOut() {
        // One row a b c d e = 10 … 50, and the extension  e d c b a | a b c d e | e d c b a  (half-sample symmetric).
        let img = image(5, 3) { _, c in 10 * Double(c + 1) }
        let across = line(img, 1, -7, 1, 11).samples            // columns −7 … 11
        XCTAssertEqual(Array(across.prefix(9)), [40, 50, 50, 40, 30, 20, 10, 10, 20])
        XCTAssertEqual(Array(across.suffix(8)), [50, 50, 40, 30, 20, 10, 10, 20])      // columns 4 … 11
        // Between samples: −1.5 sits between the reflected b (20) and a (10); −0.5 is on the seam between the two a's.
        XCTAssertEqual(line(img, 1, -1.5, 1, 0.5).samples, [15, 10, 15])
        // The same down a column, and at the last row.
        let tall = image(3, 5) { r, _ in 10 * Double(r + 1) }
        XCTAssertEqual(line(tall, -2, 1, 6, 1).samples, [20, 10, 10, 20, 30, 40, 50, 50, 40])
        // A width at the border folds too: rows −1, 0, 1 are a, a, b.
        XCTAssertEqual(line(img, 0, 0, 0, 4, width: 3).samples, [10, 20, 30, 40, 50], accuracy: 1e-12)
        let rows = image(5, 5) { r, _ in 10 * Double(r + 1) }
        XCTAssertEqual(line(rows, 0, 2, 0, 2, width: 3).samples, [(10 + 10 + 20) / 3.0], accuracy: 1e-12)
    }

    func testAZeroLengthLineIsOneSampleAtItsStart() {
        let img = image(6, 6) { r, c in Double(r * 10 + c) }
        let p = line(img, 2, 3, 2, 3)
        XCTAssertEqual(p.samples, [23])
        XCTAssertEqual(p.positions, [0])
        XCTAssertEqual(line(img, 1.5, 2.5, 1.5, 2.5).samples, [(12 + 13 + 22 + 23) / 4.0], "bilinear at a pixel corner")
        XCTAssertEqual(line(img, 2, 3, 2, 3, width: 3).samples, [23], accuracy: 1e-12)
    }

    func testPositionsAreInTheAxesUnitWhenBothAreCalibratedInOne() {
        let nmX = AxisCalibration(scale: 0.5, unit: "nm", origin: 0), nmY = AxisCalibration(scale: 0.8, unit: "nm", origin: 0)
        let img = image(20, 20, x: nmX, y: nmY) { _, _ in 1 }
        let p = line(img, 0, 0, 5, 6)                            // 6 columns × 0.5 = 3 nm, 5 rows × 0.8 = 4 nm: 5 nm, √61 px
        XCTAssertEqual(p.unit, "nm")
        XCTAssertTrue(p.isPhysical)
        XCTAssertEqual(p.samples.count, 9, "⌈√61 + 1⌉: the count is a pixel count, whatever the calibration")
        XCTAssertEqual(try XCTUnwrap(p.positions.last), 5, accuracy: 5e-12)
        XCTAssertEqual(p.positions[4], 2.5, accuracy: 5e-12)
        let raw = line(image(20, 20) { _, _ in 1 }, 0, 0, 5, 6)
        XCTAssertEqual(raw.unit, "px")
        XCTAssertFalse(raw.isPhysical)
        XCTAssertEqual(try XCTUnwrap(raw.positions.last), 61.0.squareRoot(), accuracy: 1e-12)
        let mixed = line(image(20, 20, x: nmX, y: AxisCalibration(scale: 0.8, unit: "µm", origin: 0)) { _, _ in 1 }, 0, 0, 5, 6)
        XCTAssertEqual(mixed.unit, "px", "nm and µm cannot be mixed")
        XCTAssertEqual(try XCTUnwrap(mixed.positions.last), 61.0.squareRoot(), accuracy: 1e-12)
    }

    func testDegenerateInputsGiveAnEmptyProfileOrAWidthOfOne() {
        let img = image(6, 6) { r, c in Double(r + c) }
        XCTAssertTrue(line(img, 0, 0, .nan, 3).samples.isEmpty)
        XCTAssertTrue(line(img, 0, 0, .infinity, 3).samples.isEmpty)
        XCTAssertTrue(line(img, 0, 0, 0, 2e7).samples.isEmpty, "more than 2²⁴ samples is not a line on an image")
        XCTAssertTrue(line(img, 0, 0, 0, 1e12).samples.isEmpty)
        let zeroWidth = line(img, 1, 1, 1, 4, width: 0)
        XCTAssertEqual(zeroWidth.width, 1)
        XCTAssertEqual(zeroWidth.samples, line(img, 1, 1, 1, 4, width: 1).samples)
        XCTAssertEqual(line(img, 1, 1, 1, 4, width: 3).width, 3)
    }

    // MARK: Gate B (2026-10-13), adopted from the refuter

    private func nanImage() -> CalibratedImage {
        var px = (0..<60).map { Float($0) }
        px[2 * 10 + 3] = .nan
        return CalibratedImage(width: 10, height: 6, pixels: px, x: nil, y: nil, fileName: "n", source: "", voltage: nil)
    }

    private func nanLine(_ image: CalibratedImage, _ r0: Double, _ c0: Double, _ r1: Double, _ c1: Double,
                         width: Int = 1) -> LineProfile {
        LineProfile.sample(image, from: ImagePoint(x: c0, y: r0), to: ImagePoint(x: c1, y: r1), width: width)
    }

    /// The NaN mask is scikit-image's (its float64 run, scratchpad gateB-prof/nan/py.txt): a NaN pixel poisons every
    /// bilinear sample that has it among its four neighbours, even at weight 0. Red under: a NaN pixel read as 0.
    func testANaNPixelPoisonsExactlyTheSamplesScikitImagePoisons() {
        let img = nanImage()
        let mask = { (p: LineProfile) in p.samples.map { $0.isNaN } }
        XCTAssertEqual(mask(nanLine(img, 2, 0, 2, 9)), [false, false, true, true, false, false, false, false, false, false])
        XCTAssertEqual(mask(nanLine(img, 1, 0, 1, 9)), [false, false, true, true, false, false, false, false, false, false])
        XCTAssertEqual(mask(nanLine(img, 4, 0, 4, 9, width: 3)), Array(repeating: false, count: 10))
        XCTAssertEqual(mask(nanLine(img, 3, 0, 3, 9, width: 3)), [false, false, true, true, false, false, false, false, false, false])
    }

    /// A finite coordinate far beyond any image gives an empty profile, not a trap. Red under: the 1e15 bound removed
    /// (the fold loses every digit and the Int conversion traps).
    func testAHugeFiniteCoordinateGivesAnEmptyProfile() {
        let far = 1.4470556594146113e35
        XCTAssertTrue(nanLine(nanImage(), far, far, far, far, width: 3).samples.isEmpty)
    }
}

/// `XCTAssertEqual` on arrays with an accuracy, element by element.
private nonisolated func XCTAssertEqual(_ a: [Double], _ b: [Double], accuracy: Double,
                                        file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(a.count, b.count, "count", file: file, line: line)
    for (x, y) in zip(a, b) { XCTAssertEqual(x, y, accuracy: accuracy, file: file, line: line) }
}
