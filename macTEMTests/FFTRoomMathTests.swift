//
//  FFTRoomMathTests.swift
//  The FFT room's own rules (R1 the region, R3 a click, R4 a spot in the mask, R6 the chart's
//  bins, R7 the spectrum's aspect, R8 the units shown; `FFTRoomMath.swift` held the mask's defaults until ImagoFFT 0.3.0 took them), each pinned to exact values — a crop, a
//  bin, a centre — and to the mutation that breaks it, plus the dataset of the registration's P2 (a lattice of d₀ = 0.4
//  nm at an oblique angle on a 300 × 200 image) carried from a click on the spectrum to d without the pane. A
//  package-level file: it imports TEMCore only, so it runs under `swift test` and in the app's test bundle alike. The
//  same chain through the pane's own map (`MarkGeometry`) is `FFTRoomClickTests`.
//

import XCTest
import TEMCore
import ImagoCore
import ImagoFFT

/// The registration's dataset (fixed here before any run): a Float32 image at 0.05 nm/px holding a DC and one lattice of
/// d₀ = 0.4 nm at 33.3° to the columns — oblique, and off the Fourier grid on both axes in every transform the tests
/// take (a whole 300 × 200 image puts the peak at (31.34, 13.73) bins, a 64 px region at (6.69, 4.39)), so the snap
/// window's two largest bins differ by far more than 1 %.
nonisolated struct FFTRoomMathPlanted {
    static let d0 = 0.4
    static let degrees = 33.3

    let width: Int
    let height: Int
    /// The sampling, in nm per pixel, along columns and rows.
    let dx: Double
    let dy: Double
    /// The unit the image is written in: "nm", or "m" (the same pixels, the file's scale and unit in metres).
    let unit: String

    init(width: Int = 300, height: Int = 200, dx: Double = 0.05, dy: Double = 0.05, unit: String = "nm") {
        self.width = width
        self.height = height
        self.dx = dx
        self.dy = dy
        self.unit = unit
    }

    /// The lattice's spatial frequency, in 1/nm.
    var fx: Double { cos(Self.degrees * .pi / 180) / Self.d0 }
    var fy: Double { sin(Self.degrees * .pi / 180) / Self.d0 }

    func image() -> CalibratedImage {
        let pixels = (0..<(width * height)).map { i -> Float in
            let x = Double(i % width) * dx, y = Double(i / width) * dy
            return Float(100 + 10 * cos(2 * .pi * (fx * x + fy * y)))
        }
        let metres = unit == "m"
        let sx = metres ? dx * 1e-9 : dx, sy = metres ? dy * 1e-9 : dy
        return CalibratedImage(width: width, height: height, pixels: pixels,
                               x: AxisCalibration(scale: sx, unit: unit, origin: 0),
                               y: AxisCalibration(scale: sy, unit: unit, origin: 0),
                               fileName: "planted", source: "", voltage: nil)
    }

    /// The bin of the lattice's peak (the one at positive columns) in a `w` × `h` transform of this sampling.
    func peakBin(width w: Int, height h: Int) -> (row: Int, col: Int) {
        (h / 2 + Int((fy * Double(h) * dy).rounded()), w / 2 + Int((fx * Double(w) * dx).rounded()))
    }

    /// The peak bin of `spectrum`, after the registration's premises are checked on it: the peak is at least 5 bins from
    /// the centre, it is the largest power of its 5 × 5 snap window, and the window's two largest bins differ by more than
    /// 1 % (no tie).
    func checkedPeak(of spectrum: PowerSpectrum, file: StaticString = #filePath, line: UInt = #line) -> (row: Int, col: Int) {
        let w = spectrum.width, h = spectrum.height
        let peak = peakBin(width: w, height: h)
        let tag = "\(w) × \(h) of \(unit) \(dx) × \(dy)"
        XCTAssertGreaterThanOrEqual(hypot(Double(peak.col - w / 2), Double(peak.row - h / 2)), 5,
                                    "\(tag): the peak is off the DC", file: file, line: line)
        var window: [Float] = []
        for r in (peak.row - 2)...(peak.row + 2) { for c in (peak.col - 2)...(peak.col + 2) { window.append(spectrum.power.float32Values[r * w + c]) } }
        let top = spectrum.power.float32Values[peak.row * w + peak.col]
        window.sort(by: >)
        XCTAssertEqual(window[0], top, "\(tag): the planted bin is the window's largest", file: file, line: line)
        XCTAssertGreaterThan(window[0], window[1] * 1.01, "\(tag): no tie in the snap window", file: file, line: line)
        return peak
    }
}

nonisolated final class FFTRoomMathTests: XCTestCase {

    private func pt(_ x: Double, _ y: Double) -> PixelPoint { PixelPoint(x: x, y: y) }
    private func crop(_ row: Int, _ col: Int, _ side: Int) -> PixelCrop {
        PixelCrop(row: row, col: col, height: side, width: side)
    }

    // MARK: R1, the region

    /// S is the largest even number at most the smaller side, and a region needs S ≥ 32. Red under: an odd side (the
    /// smaller side as it is); a minimum of 30 (S = 30 is then a region, on 31 × 500).
    func testMaximumSideIsTheLargestEvenNumberAtMostTheSmallerSideAndNilUnderThirtyTwo() {
        XCTAssertEqual(FFTRegion.minimumSide, 32)
        XCTAssertEqual(FFTRegion.maximumSide(width: 300, height: 200), 200)
        XCTAssertEqual(FFTRegion.maximumSide(width: 301, height: 201), 200, "odd H: the even number below it")
        XCTAssertEqual(FFTRegion.maximumSide(width: 201, height: 301), 200, "odd W")
        XCTAssertEqual(FFTRegion.maximumSide(width: 63, height: 500), 62)
        XCTAssertEqual(FFTRegion.maximumSide(width: 64, height: 64), 64)
        XCTAssertEqual(FFTRegion.maximumSide(width: 32, height: 32), 32)
        XCTAssertEqual(FFTRegion.maximumSide(width: 33, height: 4096), 32, "33 → 32, which is enough")
        XCTAssertNil(FFTRegion.maximumSide(width: 31, height: 500), "S = 30 is under 32: no region")
        XCTAssertNil(FFTRegion.maximumSide(width: 500, height: 31))
        XCTAssertNil(FFTRegion.maximumSide(width: 30, height: 30))
        XCTAssertNil(FFTRegion.maximumSide(width: 0, height: 0))
    }

    /// The corner is the pixel edge nearest the press, ties (the pixel's centre) going away from zero — the edge to the
    /// right and below. Pixel 100's edges are edge indices 100 (x = 99.5) and 101 (x = 100.5). Red under: the corner
    /// by floor (100.0 → 100, 100.4 → 100); banker's rounding (100.0 → 100); the +½ dropped (round(100.0) = 100).
    func testTheDrawnCornerIsTheNearestPixelEdgeRoundedHalfAwayFromZero() {
        func corner(_ x0: Double, _ y0: Double) -> (row: Int, col: Int)? {
            FFTRegion.drawn(from: pt(x0, y0), to: pt(x0 + 64, y0 + 64), width: 300, height: 200).map { ($0.row, $0.col) }
        }
        for (x0, col) in [(99.4, 100), (99.5, 100), (99.99, 100), (100.0, 101), (100.4, 101), (100.5, 101), (100.6, 101),
                          (101.0, 102), (150.25, 151)] {
            XCTAssertEqual(corner(x0, 50)?.col, col, "x₀ = \(x0)")
        }
        for (y0, row) in [(49.4, 50), (49.99, 50), (50.0, 51), (50.4, 51), (51.0, 52), (120.75, 121)] {
            XCTAssertEqual(corner(100, y0)?.row, row, "y₀ = \(y0)")
        }
        // The size is 64 and nothing needed shifting: the whole crop.
        XCTAssertEqual(FFTRegion.drawn(from: pt(100.0, 50.0), to: pt(164, 114), width: 300, height: 200), crop(51, 101, 64))
    }

    /// s = 2⌊max(|Δx|, |Δy|)/2⌋ clamped to 32…S, on the larger axis, S the even number below an odd side. Red under: an
    /// odd side (61.9 → 61 or 62); a minimum of 30 (10 → 30); the smaller axis; no upper clamp.
    func testTheDrawnSideIsTheLargerExtentToEvenClampedToThirtyTwoAndTheLargestSide() {
        func side(_ dx: Double, _ dy: Double, w: Int = 300, h: Int = 200) -> Int? {
            FFTRegion.drawn(from: pt(100.0, 50.0), to: pt(100.0 + dx, 50.0 + dy), width: w, height: h)?.width
        }
        for (extent, s) in [(61.9, 60), (63.9, 62), (64.0, 64), (65.0, 64), (66.0, 66), (31.9, 32), (33.0, 32), (10.0, 32), (0.0, 32),
                            (500.0, 200), (1e9, 200)] {
            XCTAssertEqual(side(extent, extent / 3), s, "extent \(extent) along x")
            XCTAssertEqual(side(extent / 3, extent), s, "extent \(extent) along y")
        }
        XCTAssertEqual(side(10, 80), 80, "the larger of the two extents")
        XCTAssertEqual(side(-80, 10), 80, "by magnitude")
        XCTAssertEqual(side(500, 0, w: 301, h: 201), 200, "S is even on an odd image")
        XCTAssertEqual(side(90, 90, w: 100, h: 40), 40, "S = the smaller side, 40")
        let c = FFTRegion.drawn(from: pt(100.0, 50.0), to: pt(120, 55), width: 300, height: 200)
        XCTAssertEqual(c?.width, c?.height, "a square")
    }

    /// The square extends from the corner toward the pointer on each axis; a zero extent counts as positive. Press
    /// (150, 100) is edge (151, 101). Red under: the drag's direction ignored (every square goes right and down).
    func testTheDrawnSquareExtendsTowardThePointerInAllFourQuadrants() {
        let p0 = pt(150.0, 100.0)
        func drawn(_ x: Double, _ y: Double) -> PixelCrop? { FFTRegion.drawn(from: p0, to: pt(x, y), width: 300, height: 200) }
        XCTAssertEqual(drawn(210, 110), crop(101, 151, 60), "right and down")
        XCTAssertEqual(drawn(90, 110), crop(101, 91, 60), "left and down: the column is 151 − 60")
        XCTAssertEqual(drawn(160, 40), crop(41, 151, 60), "right and up: the row is 101 − 60")
        XCTAssertEqual(drawn(90, 40), crop(41, 91, 60), "left and up")
        XCTAssertEqual(drawn(150, 160), crop(101, 151, 60), "no extent along x: positive")
        XCTAssertEqual(drawn(210, 100), crop(101, 151, 60), "no extent along y: positive")
        XCTAssertEqual(drawn(150, 100), crop(101, 151, 32), "a click: the smallest square, right and down")
        XCTAssertEqual(drawn(149.9, 100.1), crop(101, 151 - 32, 32), "a hair left: left")
    }

    /// A square that would leave the image is shifted in, never shrunk; a press on or beyond the border works.
    /// Red under: shrunk instead of shifted (the side becomes 9 at the right edge); the direction ignored.
    func testTheDrawnSquareIsShiftedIntoTheImageNeverShrunk() {
        func drawn(_ a: (Double, Double), _ b: (Double, Double), w: Int = 300, h: Int = 200) -> PixelCrop? {
            FFTRegion.drawn(from: pt(a.0, a.1), to: pt(b.0, b.1), width: w, height: h)
        }
        XCTAssertEqual(drawn((290.0, 100.0), (350, 110)), crop(101, 240, 60), "right: column 240 = 300 − 60")
        XCTAssertEqual(drawn((100.0, 190.0), (110, 250)), crop(140, 101, 60), "bottom: row 140 = 200 − 60")
        XCTAssertEqual(drawn((5.0, 100.0), (-55, 105)), crop(101, 0, 60), "left, drawn leftwards")
        XCTAssertEqual(drawn((100.0, 5.0), (105, -55)), crop(0, 101, 60), "top, drawn upwards")
        XCTAssertEqual(drawn((-10, -10), (50, 50)), crop(0, 0, 60), "pressed outside the top-left")
        XCTAssertEqual(drawn((320, 230), (380, 290)), crop(140, 240, 60), "pressed outside the bottom-right, going on")
        XCTAssertEqual(drawn((320, 230), (260, 170)), crop(140, 240, 60), "…and drawn back in")
        XCTAssertEqual(drawn((1e9, 1e9), (-1e9, -1e9)), crop(0, 100, 200), "far outside, a huge drag: the largest square")
        XCTAssertEqual(drawn((0.0, 0.0), (500, 500)), crop(0, 1, 200), "S = H = 200: the row shifted to 0, the column to 1")
        XCTAssertEqual(drawn((1e300, -1e300), (-1e300, 1e300)), crop(0, 100, 200), "beyond Int: held to the image before it is an Int")
        XCTAssertEqual(drawn((1.7e308, 0.0), (-1.7e308, 0.0)), crop(0, 100, 200), "an extent that overflows to ∞ is the largest square")
        XCTAssertNil(drawn((.nan, 0), (1, 1)), "a point that is not a number makes no region")
        XCTAssertNil(drawn((0, 0), (1, .infinity)))
        // Odd image: the column is not made even, only the side is.
        XCTAssertEqual(drawn((299.9, 100.0), (400, 110), w: 301, h: 201), crop(101, 201, 100), "301 − 100 = 201")
        // The whole of a square image.
        XCTAssertEqual(drawn((3.0, 9.0), (900, 900), w: 64, h: 64), crop(0, 0, 64))
    }

    /// No region is possible when S < 32, in every entry.
    func testNoRegionIsPossibleOnAnImageUnderThirtyTwo() {
        XCTAssertNil(FFTRegion.drawn(from: pt(5, 5), to: pt(300, 300), width: 31, height: 500))
        XCTAssertNil(FFTRegion.drawn(from: pt(5, 5), to: pt(300, 300), width: 500, height: 31))
        XCTAssertNil(FFTRegion.typed(left: 0, top: 0, size: 64, width: 31, height: 500))
        XCTAssertNil(FFTRegion.centredSquare(width: 31, height: 500))
        XCTAssertNil(FFTRegion.resized(crop(0, 0, 32), corner: .bottomRight, to: pt(60, 60), width: 31, height: 500))
        XCTAssertNotNil(FFTRegion.centredSquare(width: 33, height: 500), "S = 32 is enough")
    }

    /// A move is (round Δx, round Δy) whole pixels, ties away from zero, then shifted in with the size kept. Red
    /// under: truncation or floor instead of rounding; shrunk instead of shifted; the shift left out.
    func testMovedByWholePixelsRoundedHalfAwayFromZeroAndShiftedIn() {
        let c = crop(51, 101, 60)
        func moved(_ dx: Double, _ dy: Double, _ from: PixelCrop? = nil, w: Int = 300, h: Int = 200) -> PixelCrop {
            FFTRegion.moved(from ?? c, dx: dx, dy: dy, width: w, height: h)
        }
        XCTAssertEqual(moved(10.4, -3.5), crop(47, 111, 60), "−3.5 → −4, 10.4 → 10")
        XCTAssertEqual(moved(2.5, 2.5), crop(54, 104, 60), "ties away from zero")
        XCTAssertEqual(moved(-2.5, -2.5), crop(48, 98, 60))
        XCTAssertEqual(moved(0.4, -0.4), c, "under half a pixel: nothing")
        XCTAssertEqual(moved(0.5, -0.5), crop(50, 102, 60))
        XCTAssertEqual(moved(1000, 1000), crop(140, 240, 60), "shifted in at the bottom right")
        XCTAssertEqual(moved(-1000, -1000), crop(0, 0, 60), "…and the top left")
        XCTAssertEqual(moved(1000, 0), crop(51, 240, 60), "one axis only")
        XCTAssertEqual(moved(-5, -5, crop(0, 0, 60)), crop(0, 0, 60), "already in the corner")
        XCTAssertEqual(moved(1000, 1000, crop(0, 0, 200), w: 301, h: 201), crop(1, 101, 200), "odd image")
        XCTAssertEqual(moved(1e300, -1e300), crop(0, 240, 60), "enormous drags do not trap")
        XCTAssertEqual(moved(.nan, .infinity), crop(140, 101, 60), "no move for a NaN, the far edge for ∞")
    }

    /// A corner is drawn at the crop's pixel edge: the top-left is (col − ½, row − ½). Red under: the −½ dropped; a
    /// corner's x or y taken from the wrong side.
    func testCornersAreDrawnAtPixelEdges() {
        let c = crop(51, 101, 60)
        XCTAssertEqual(FFTRegion.point(of: .topLeft, in: c), pt(100.5, 50.5))
        XCTAssertEqual(FFTRegion.point(of: .topRight, in: c), pt(160.5, 50.5))
        XCTAssertEqual(FFTRegion.point(of: .bottomLeft, in: c), pt(100.5, 110.5))
        XCTAssertEqual(FFTRegion.point(of: .bottomRight, in: c), pt(160.5, 110.5))
        XCTAssertEqual(FFTRegion.point(of: .topLeft, in: crop(0, 0, 32)), pt(-0.5, -0.5), "the image's own corner")
        XCTAssertEqual(FFTRegion.Corner.allCases.count, 4)
    }

    /// A resize is drawn from the opposite corner, as if pressed there. Red under: drawn from the dragged corner
    /// itself; the opposite corner taken diagonally wrong (top-right for bottom-left).
    func testResizedFromACornerIsDrawnFromTheOppositeOne() {
        let c = crop(51, 101, 60)
        XCTAssertEqual(FFTRegion.resized(c, corner: .bottomRight, to: pt(200.2, 130.7), width: 300, height: 200),
                       crop(51, 101, 98), "from the top-left edge (101, 51): 2⌊99.7/2⌋ = 98")
        XCTAssertEqual(FFTRegion.resized(c, corner: .topLeft, to: pt(50, 20), width: 300, height: 200),
                       crop(1, 51, 110), "from the bottom-right edge (161, 111), up and left: 2⌊110.5/2⌋ = 110")
        XCTAssertEqual(FFTRegion.resized(c, corner: .topRight, to: pt(190.5, 60.5), width: 300, height: 200),
                       crop(21, 101, 90), "from the bottom-left edge (101, 111): right and up")
        XCTAssertEqual(FFTRegion.resized(c, corner: .bottomLeft, to: pt(110.5, 100.5), width: 300, height: 200),
                       crop(51, 111, 50), "from the top-right edge (161, 51): left and down")
        // Dragging a corner to where it is changes nothing — including a region against the image's border.
        for region in [crop(51, 101, 60), crop(0, 0, 64), crop(136, 236, 64), crop(0, 236, 64), crop(136, 0, 32)] {
            for corner in FFTRegion.Corner.allCases {
                XCTAssertEqual(FFTRegion.resized(region, corner: corner, to: FFTRegion.point(of: corner, in: region),
                                                 width: 300, height: 200), region, "\(corner) of \(region)")
            }
        }
        // A corner dragged past the opposite one flips the square (the drag's direction).
        XCTAssertEqual(FFTRegion.resized(c, corner: .bottomRight, to: pt(40.5, 10.5), width: 300, height: 200),
                       crop(0, 41, 60), "pulled over the top-left: up and left of (101, 51), shifted in at the top")
    }

    /// Typed Left, Top and Size: the size to the even number at or below it, clamped to 32…S; left and top clamped to
    /// 0…W − s and 0…H − s. Red under: an odd side (65); a minimum of 30 (31 → 30); no clamp of left or top.
    func testTypedRegionTakesTheSameClamps() {
        func typed(_ left: Int, _ top: Int, _ size: Int, w: Int = 300, h: Int = 200) -> PixelCrop? {
            FFTRegion.typed(left: left, top: top, size: size, width: w, height: h)
        }
        XCTAssertEqual(typed(10, 20, 64), crop(20, 10, 64))
        XCTAssertEqual(typed(10, 20, 65), crop(20, 10, 64), "odd: the even number below")
        XCTAssertEqual(typed(10, 20, 31), crop(20, 10, 32), "31 → 30 → the minimum 32")
        XCTAssertEqual(typed(10, 20, 33), crop(20, 10, 32))
        XCTAssertEqual(typed(10, 20, 0), crop(20, 10, 32))
        XCTAssertEqual(typed(10, 20, -7), crop(20, 10, 32))
        XCTAssertEqual(typed(10, 20, 300), crop(0, 10, 200), "over: S = 200, and the top 20 is shifted to 0")
        XCTAssertEqual(typed(10, 20, 199), crop(2, 10, 198), "199 → 198, the top shifted to H − s = 2")
        XCTAssertEqual(typed(-5, -9, 64), crop(0, 0, 64), "negative left and top")
        XCTAssertEqual(typed(500, 500, 64), crop(136, 236, 64), "left and top past the end")
        XCTAssertEqual(typed(300, 200, 64, w: 301, h: 201), crop(137, 237, 64), "odd image: 301 − 64, 201 − 64")
        XCTAssertEqual(typed(300, 200, 201, w: 301, h: 201), crop(1, 101, 200), "odd size on an odd image")
        XCTAssertNil(typed(0, 0, 64, w: 31, h: 500))
        XCTAssertEqual(typed(0, 0, Int.max, w: 300, h: 200), crop(0, 0, 200), "no overflow")
        XCTAssertEqual(typed(0, 0, Int.min, w: 300, h: 200), crop(0, 0, 32), "no overflow")
    }

    /// Use Centred Square: s = S at (⌊(H − s)/2⌋, ⌊(W − s)/2⌋). Red under: the margin by ceiling, which differs on an
    /// odd margin (301 × 201 puts the column at 50, not 51).
    func testCentredSquareFloorsTheMargin() {
        XCTAssertEqual(FFTRegion.centredSquare(width: 300, height: 200), crop(0, 50, 200))
        XCTAssertEqual(FFTRegion.centredSquare(width: 301, height: 201), crop(0, 50, 200), "(301 − 200)/2 = 50.5 → 50")
        XCTAssertEqual(FFTRegion.centredSquare(width: 201, height: 301), crop(50, 0, 200))
        XCTAssertEqual(FFTRegion.centredSquare(width: 1000, height: 600), crop(0, 200, 600))
        XCTAssertEqual(FFTRegion.centredSquare(width: 601, height: 1001), crop(200, 0, 600), "(1001 − 600)/2 = 200.5 → 200")
        XCTAssertEqual(FFTRegion.centredSquare(width: 35, height: 100), crop(33, 0, 34), "S = 34 on a 35 px side: column 0")
        XCTAssertEqual(FFTRegion.centredSquare(width: 64, height: 64), crop(0, 0, 64))
        XCTAssertNil(FFTRegion.centredSquare(width: 31, height: 100))
    }

    /// What is a region: square, even, at least 32, inside. Red under: an odd side accepted; a minimum of 30; a crop
    /// that leaves the image accepted; a rectangle accepted.
    func testIsValidTruthTable() {
        func valid(_ c: PixelCrop, w: Int = 300, h: Int = 200) -> Bool { FFTRegion.isValid(c, width: w, height: h) }
        XCTAssertTrue(valid(crop(0, 0, 32)))
        XCTAssertTrue(valid(crop(168, 268, 32)), "flush with the bottom-right corner")
        XCTAssertTrue(valid(crop(0, 50, 200)))
        XCTAssertTrue(valid(crop(0, 101, 200), w: 301, h: 201))
        XCTAssertTrue(valid(crop(1, 101, 200), w: 301, h: 201))
        XCTAssertFalse(valid(PixelCrop(row: 0, col: 0, height: 32, width: 34)), "a rectangle")
        XCTAssertFalse(valid(PixelCrop(row: 0, col: 0, height: 34, width: 32)))
        XCTAssertFalse(valid(crop(0, 0, 33)), "odd")
        XCTAssertFalse(valid(crop(0, 0, 31)))
        XCTAssertFalse(valid(crop(0, 0, 30)), "under the minimum")
        XCTAssertFalse(valid(crop(0, 0, 0)))
        XCTAssertFalse(valid(crop(169, 268, 32)), "one row too low")
        XCTAssertFalse(valid(crop(168, 269, 32)), "one column too far right")
        XCTAssertFalse(valid(crop(-1, 0, 32)))
        XCTAssertFalse(valid(crop(0, -1, 32)))
        XCTAssertFalse(valid(crop(0, 0, 202)), "larger than the image is tall")
        XCTAssertFalse(valid(crop(2, 101, 200), w: 301, h: 201), "2 + 200 > 201")
        XCTAssertFalse(valid(crop(0, 0, 32), w: 31, h: 500), "no region on an image under 32")
        XCTAssertFalse(valid(crop(Int.max - 5, 0, 32)), "no overflow")
    }

    /// The HRTEM filters take square, even pixels of at least 32. Red under: odd accepted; non-square accepted; a
    /// minimum of 30.
    func testFilterableTruthTable() {
        for (w, h, ok) in [(256, 256, true), (32, 32, true), (34, 34, true), (1000, 1000, true), (256, 255, false),
                           (255, 255, false), (33, 33, false), (31, 31, false), (30, 30, false), (300, 200, false),
                           (64, 32, false), (0, 0, false)] {
            XCTAssertEqual(FFTRegion.filterable(width: w, height: h), ok, "\(w) × \(h)")
        }
    }

    /// Every region the rules make is a region: drawn from any press and pointer, moved, resized and typed, on images of
    /// every parity. Red under: any of the mutations above that leaves a region invalid (odd, small, outside).
    func testEveryRegionTheRulesMakeIsValid() {
        let xs: [Double] = [-20, -0.5, 0, 0.4, 31.5, 100, 150.5, 299.6, 330]
        let ys: [Double] = [-20, 0, 0.5, 77, 199.5, 240]
        var made = 0
        for (w, h) in [(300, 200), (301, 201), (64, 64), (35, 100), (100, 33), (4096, 4095)] {
            guard let s = FFTRegion.maximumSide(width: w, height: h) else { continue }
            for x0 in xs { for y0 in ys { for (dx, dy) in [(0.0, 0.0), (45.5, -3.0), (-70.0, 70.0), (-1e4, -1e4), (200.0, 5.0)] {
                guard let c = FFTRegion.drawn(from: pt(x0, y0), to: pt(x0 + dx, y0 + dy), width: w, height: h) else {
                    return XCTFail("no region on \(w) × \(h), S = \(s)")
                }
                made += 1
                XCTAssertTrue(FFTRegion.isValid(c, width: w, height: h), "drawn \(c) on \(w) × \(h)")
                for (mx, my) in [(0.0, 0.0), (7.5, -3.5), (-1e3, 1e3), (123.4, 56.7)] {
                    let m = FFTRegion.moved(c, dx: mx, dy: my, width: w, height: h)
                    XCTAssertTrue(FFTRegion.isValid(m, width: w, height: h), "moved \(m)")
                    XCTAssertEqual(m.width, c.width, "a move keeps the size")
                }
                for corner in FFTRegion.Corner.allCases {
                    let r = FFTRegion.resized(c, corner: corner, to: pt(x0 + dy, y0 - dx), width: w, height: h)
                    XCTAssertTrue(r.map { FFTRegion.isValid($0, width: w, height: h) } ?? false, "resized \(String(describing: r))")
                }
            } } }
            for (l, t, size) in [(0, 0, 0), (-5, 7, 33), (1000, 1000, 70), (3, 4, 5000), (10, 10, 65)] {
                let c = FFTRegion.typed(left: l, top: t, size: size, width: w, height: h)
                XCTAssertTrue(c.map { FFTRegion.isValid($0, width: w, height: h) } ?? false, "typed \(l) \(t) \(size)")
            }
            XCTAssertTrue(FFTRegion.centredSquare(width: w, height: h).map { FFTRegion.isValid($0, width: w, height: h) } ?? false)
        }
        XCTAssertGreaterThan(made, 1000)
    }

    // MARK: R3, a click on the spectrum

    /// The bin under an image point is (round y, round x), half away from zero, clamped to the spectrum. A pixel's centre
    /// is at the integer, so 10.5 is the edge between bins 10 and 11 and belongs to 11. Red under: the bin by floor
    /// (10.5 → 10 and 10.6 → 10); row and column swapped (250, 190 lands outside a 200-row spectrum); no clamp.
    func testABinIsTheRoundedImagePointHalfAwayFromZeroClampedToTheSpectrum() {
        func bin(_ x: Double, _ y: Double) -> [Int] {
            let b = SpectrumBin.at(pt(x, y), width: 300, height: 200)
            return [b.row, b.col]
        }
        XCTAssertEqual(bin(10, 20), [20, 10])
        XCTAssertEqual(bin(10.5, 20.5), [21, 11], "the tie goes up, as round() does")
        XCTAssertEqual(bin(10.49, 20.49), [20, 10])
        XCTAssertEqual(bin(10.6, 20.6), [21, 11], "floor would give 10, 20")
        XCTAssertEqual(bin(9.51, 19.51), [20, 10])
        XCTAssertEqual(bin(7, 3), [3, 7], "(x, y) → (row, col) = (y, x)")
        XCTAssertEqual(bin(250, 190), [190, 250], "a non-square spectrum tells row from column")
        XCTAssertEqual(bin(-0.4, -0.4), [0, 0])
        XCTAssertEqual(bin(-0.5, -0.5), [0, 0], "round(−0.5) = −1, held at 0")
        XCTAssertEqual(bin(-50, 500), [199, 0], "outside: held at the spectrum's edge")
        XCTAssertEqual(bin(299.4, 199.4), [199, 299])
        XCTAssertEqual(bin(299.5, 199.5), [199, 299], "300 and 200 are past the end")
        XCTAssertEqual(bin(1e9, -1e9), [0, 299])
        XCTAssertEqual(bin(.infinity, -.infinity), [0, 299])
        XCTAssertEqual(bin(.nan, .nan), [0, 0], "never a trap")
        let odd = SpectrumBin.at(pt(300.4, 200.4), width: 301, height: 201)
        XCTAssertEqual([odd.row, odd.col], [200, 300], "odd spectrum: the last bin is W − 1")
    }

    /// Measure at… names whole bins from the centre, the bin (h/2 + ky, w/2 + kx), and nothing outside the spectrum.
    /// Red under: kx and ky swapped; the centre at (h − 1)/2; the edges off by one (150 is outside, 149 is not).
    func testMeasureAtNamesTheBinFromTheCentreOrNothing() {
        func at(_ kx: Int, _ ky: Int, w: Int = 300, h: Int = 200) -> [Int]? {
            SpectrumBin.at(kx: kx, ky: ky, width: w, height: h).map { [$0.row, $0.col] }
        }
        XCTAssertEqual(at(0, 0), [100, 150], "the DC")
        XCTAssertEqual(at(10, 5), [105, 160], "kx along the columns, ky along the rows")
        XCTAssertEqual(at(-150, -100), [0, 0], "the first bin")
        XCTAssertEqual(at(149, 99), [199, 299], "the last bin")
        XCTAssertNil(at(150, 0), "col 300")
        XCTAssertNil(at(0, 100), "row 200")
        XCTAssertNil(at(-151, 0))
        XCTAssertNil(at(0, -101))
        XCTAssertEqual(at(0, 0, w: 301, h: 201), [100, 150], "integer division: 201/2 = 100")
        XCTAssertEqual(at(150, 100, w: 301, h: 201), [200, 300], "an odd spectrum has one more positive bin")
        XCTAssertNil(at(151, 0, w: 301, h: 201))
        XCTAssertEqual(at(-150, -100, w: 301, h: 201), [0, 0])
        XCTAssertNil(at(-151, 0, w: 301, h: 201))
        XCTAssertNil(at(Int.max, 0), "no overflow")
        XCTAssertNil(at(0, Int.min))
    }

    // MARK: R4, a measured spot in the mask

    private func lattice(_ w: Int, _ h: Int, fx: Double, fy: Double) -> CalibratedImage {
        // fx and fy in bins of this transform: cycles per image width and height.
        let pixels = (0..<(w * h)).map { i in
            Float(100 + 10 * cos(2 * .pi * (fx * Double(i % w) / Double(w) + fy * Double(i / w) / Double(h))))
        }
        return CalibratedImage(width: w, height: h, pixels: pixels, x: AxisCalibration(scale: 0.5, unit: "nm", origin: 0),
                               y: AxisCalibration(scale: 0.5, unit: "nm", origin: 0), fileName: "l", source: "", voltage: nil)
    }

    /// The mask spot is (centroidCol − w/2, centroidRow − h/2) bit for bit, w/2 and h/2 integer divisions, the core's
    /// index frame, on a non-square and on an odd spectrum — and it lands on the planted fractional frequency (5.3, −3.4
    /// bins). Red under: the centre at the clicked bin (kx = 5, not 5.3); w and h swapped (kx = 11.3); w/2 as a Double
    /// on an odd spectrum (24.5, not 24); the radius and edge not passed on.
    func testAMaskSpotIsTheCentroidOffsetFromTheCentreInTheCoresIndexFrame() throws {
        for (w, h, cw, ch) in [(48, 36, 24, 18), (49, 37, 24, 18)] {
            let image = lattice(w, h, fx: 5.3, fy: -3.4)
            let m = try SpotMeasurement.measure(image.micrograph, clickRow: h / 2 - 3, clickColumn: w / 2 + 5)
            let spot = m.maskSpot(radius: 4.5, edge: 1.5)
            XCTAssertEqual(spot.kx, m.centroidCol - Double(cw), "\(w) × \(h): bit-equal")
            XCTAssertEqual(spot.ky, m.centroidRow - Double(ch))
            XCTAssertEqual(spot.radius, 4.5)
            XCTAssertEqual(spot.edge, 1.5)
            XCTAssertEqual(spot.kx, 5.3, accuracy: 0.1, "\(w) × \(h): the planted frequency, in bins")
            XCTAssertEqual(spot.ky, -3.4, accuracy: 0.1)
            XCTAssertNotEqual(m.centroidCol, Double(m.clickedCol), "the centroid is not the clicked bin")
        }
        XCTAssertEqual(FFTMask.defaultRadius, 3)
        XCTAssertEqual(FFTMask.defaultEdge, 2)
        XCTAssertEqual(FFTMask.radiusRange, 1...32)
        XCTAssertEqual(FFTMask.edgeRange, 0...16)
    }

    /// The spot of a measured on-bin lattice, given to the core, returns that lattice and not the DC: the frame is right
    /// end to end. Red under: w and h swapped, the centre at the clicked bin on an off-bin lattice, the signs flipped.
    func testTheMaskSpotOfAMeasuredLatticeReturnsThatLattice() throws {
        let w = 48, h = 36
        let image = lattice(w, h, fx: 5, fy: 3)
        let m = try SpotMeasurement.measure(image.micrograph, clickRow: h / 2 + 3, clickColumn: w / 2 + 5)
        let spot = m.maskSpot(radius: 0.5, edge: 0)
        let out = try MaskedInverseFFT.compute(image.micrograph, spots: [spot])
        var worst: Float = 0
        for r in 0..<h { for c in 0..<w {
            let truth = Float(10 * cos(2 * .pi * (5 * Double(c) / Double(w) + 3 * Double(r) / Double(h))))
            worst = max(worst, abs(out.image.float32Values[r * w + c] - truth))
        } }
        XCTAssertLessThan(worst, 0.01, "the masked inverse is the lattice alone: no DC (+100), nothing else")
        XCTAssertLessThan(out.imaginaryMax, 1e-3)
    }

    // MARK: R6, the radial chart

    /// The chart draws bin k ≥ 1 at its centre (k + ½)·w with the core's mean and count, and skips empty bins. A 32 × 32
    /// spectrum at 0.5 nm with a bin width of half a frequency step puts the pixel at integer offsets (i, j) in bin
    /// ⌊2√(i² + j²)⌋: bin 0 is the DC alone, bin 1 is empty (no integer pair has 2√n in [1, 2)), bin 2 holds the eight
    /// nearest neighbours (n = 1 and n = 2: 2√2 = 2.83). Red under: a bin drawn at k·w; the DC drawn (a point at bin 0); empty bins drawn.
    func testChartPointsAreBinsFromOneAtTheirCentresSkippingEmptyOnes() throws {
        let image = CalibratedImage(width: 32, height: 32,
                                    pixels: (0..<1024).map { i -> Float in
                                        let value: Double = 5 + 3 * cos(Double(i % 32) * 0.7) + Double(i / 32 % 7)
                                        return Float(value)
                                    },
                                    x: AxisCalibration(scale: 0.5, unit: "nm", origin: 0), y: AxisCalibration(scale: 0.5, unit: "nm", origin: 0),
                                    fileName: "c", source: "", voltage: nil)
        let spectrum = try PowerSpectrum.compute(image.micrograph)
        XCTAssertEqual(spectrum.spacingX, 0.0625)
        let profile = try RadialProfile.compute(spectrum, width: spectrum.spacingX / 2)
        XCTAssertEqual(profile.width, 0.03125)

        // The pixel counts per bin, enumerated from the integer offsets, independently of the core.
        var expected: [Int: Int] = [:]
        for j in -16..<16 { for i in -16..<16 { expected[Int((2 * Double(i * i + j * j).squareRoot()).rounded(.down)), default: 0] += 1 } }
        XCTAssertEqual(expected[0], 1, "bin 0 is the DC alone")
        XCTAssertNil(expected[1], "bin 1 is empty")
        XCTAssertEqual(expected[2], 8)

        let points = profile.points
        XCTAssertEqual(points.map(\.bin), expected.keys.filter { $0 >= 1 }.sorted(), "k ≥ 1 with a pixel, ascending")
        XCTAssertEqual(points.first?.bin, 2)
        XCTAssertEqual(points.first?.q, 0.078125, "(2 + ½) · 0.03125")
        XCTAssertEqual(points.first?.count, 8)
        for p in points {
            XCTAssertEqual(p.q, (Double(p.bin) + 0.5) * 0.03125, "bin \(p.bin) at its centre")
            XCTAssertEqual(p.count, expected[p.bin], "bin \(p.bin)'s pixels")
            XCTAssertEqual(p.count, profile.count[p.bin])
            XCTAssertEqual(p.mean, profile.mean[p.bin], "the core's mean, untouched")
            XCTAssertGreaterThan(p.count, 0)
        }
        XCTAssertEqual(points.map(\.count).reduce(0, +), 1023, "every pixel but the DC")
        // A profile with only the DC bin draws nothing.
        let tiny = try RadialProfile.compute(try PowerSpectrum.compute(lattice(4, 4, fx: 0, fy: 0).micrograph), width: 100)
        XCTAssertEqual(tiny.mean.count, 1)
        XCTAssertEqual(tiny.points, [])
    }

    /// The log axis is labelled on every n-th decade, from ⌊log₁₀ of the smallest mean⌋, n the least that keeps two labels
    /// `minimumSpacing` points apart on a plot `plotHeight` points tall (a decade is plotHeight / span points). At 16 pt on
    /// 48 pt: up to 3 decades one label each, 4 and 6 every second, 7 and 9 every third, 10 every fourth. The spacing is
    /// checked in points at the floor of the plot, and at the 57 pt it measures. Red under: a label on every decade (the
    /// finding's 8 labels in 57 pt: 8.1 pt apart); the step rounded down; the span taken from the smallest mean to the
    /// largest instead of whole decades; the first mark at the data's own smallest value.
    func testTheLogAxisIsLabelledOnEveryNthDecadeSoNoTwoLabelsAreCloserThanTheMinimum() {
        func marks(_ first: Int, _ span: Int, plot: Double = 48, gap: Double = 16) -> [Double] {
            // Smallest mean 1.5 × 10^first, largest 0.5 × 10^(first + span): whole decades first … first + span.
            RadialChartScale.decadeMarks(lowest: 1.5 * pow(10, Double(first)), highest: 0.5 * pow(10, Double(first + span)),
                                    plotHeight: plot, minimumSpacing: gap)
        }
        func exponents(_ m: [Double]) -> [Int] { m.map { Int(log10($0).rounded()) } }
        let expected: [Int: [Int]] = [1: [4, 5], 2: [4, 5, 6], 3: [4, 5, 6, 7], 4: [4, 6, 8], 6: [4, 6, 8, 10], 7: [4, 7, 10],
                                      9: [4, 7, 10, 13], 10: [4, 8, 12]]
        for span in [1, 2, 3, 4, 6, 7, 9, 10] {
            XCTAssertEqual(exponents(marks(4, span)), expected[span], "\(span) decades from 10⁴")
        }
        XCTAssertEqual(marks(4, 9), [1e4, 1e7, 1e10, 1e13])
        XCTAssertEqual(exponents(marks(-3, 4)), [-3, -1, 1], "below one, too")
        for span in 1...14 {
            let m = marks(2, span)
            XCTAssertEqual(m.first, 100, "\(span)")
            let exp = exponents(m)
            XCTAssertEqual(exp, exp.sorted())
            XCTAssertTrue(m.allSatisfy { abs(log10($0) - log10($0).rounded()) < 1e-9 }, "powers of ten")
            for plot in [48.0, 57.0] {
                let decade = plot / Double(span)
                for i in 1..<max(m.count, 1) {
                    let gap = (log10(m[i]) - log10(m[i - 1])) * decade
                    XCTAssertGreaterThanOrEqual(gap, 16 - 1e-9, "\(span) decades on \(plot) pt: labels \(i - 1) and \(i) are \(gap) pt apart")
                }
            }
            XCTAssertLessThanOrEqual(m.count, 4, "\(span) decades: at most four labels on a plot 48 pt tall")
        }
        // A span under one decade is one decade; a series on one decade's edge, too.
        XCTAssertEqual(RadialChartScale.decadeMarks(lowest: 5e3, highest: 5e3, plotHeight: 48, minimumSpacing: 16), [1e3, 1e4])
        XCTAssertEqual(RadialChartScale.decadeMarks(lowest: 1e3, highest: 1e3, plotHeight: 48, minimumSpacing: 16), [1e3, 1e4])
        // Nothing usable draws nothing.
        for (lo, hi, plot, gap) in [(0.0, 1.0, 48.0, 16.0), (-1.0, 1.0, 48, 16), (Double.nan, 1, 48, 16), (1, Double.infinity, 48, 16),
                                    (2, 1, 48, 16), (1, 10, 0, 16), (1, 10, 48, 0), (1, 10, .nan, 16)] {
            XCTAssertEqual(RadialChartScale.decadeMarks(lowest: lo, highest: hi, plotHeight: plot, minimumSpacing: gap), [],
                           "\(lo) … \(hi), plot \(plot), gap \(gap)")
        }
    }

    // MARK: R7, the spectrum drawn

    /// The box is (w·Δq_x) : (h·Δq_y), so that one point is the same frequency along x and y. On a 300 × 200 image at
    /// 0.05 nm the box is square (each axis spans 1/0.05 = 20 nm⁻¹); at 0.05 × 0.04 it is 0.8; an uncalibrated image
    /// gives a square. Red under: the aspect w : h (1.5); the aspect taken with Δq_y for Δq_x.
    func testTheSpectrumBoxIsTheRatioOfItsPhysicalExtentsSoARingIsACircle() throws {
        func aspect(_ s: PowerSpectrum) -> Double {
            SpectrumShape.aspect(width: s.width, height: s.height, spacingX: s.spacingX, unitsX: s.unitsX,
                                    spacingY: s.spacingY, unitsY: s.unitsY)
        }
        let square = try PowerSpectrum.compute(FFTRoomMathPlanted().image().micrograph)
        XCTAssertEqual(aspect(square), 1, accuracy: 1e-12)
        let aniso = try PowerSpectrum.compute(FFTRoomMathPlanted(dy: 0.04).image().micrograph)
        XCTAssertEqual(aspect(aniso), 0.8, accuracy: 1e-12, "(1/0.05) : (1/0.04) = 20 : 25")
        XCTAssertEqual(SpectrumShape.aspect(width: 300, height: 200, spacingX: 1.0 / 15, unitsX: "1/nm",
                                               spacingY: 1.0 / 10, unitsY: "1/nm"), 1, accuracy: 1e-12)
        XCTAssertEqual(SpectrumShape.aspect(width: 64, height: 32, spacingX: 0.25, unitsX: "1/nm",
                                               spacingY: 1, unitsY: "1/nm"), 0.5, accuracy: 1e-12,
                       "16 : 32, however many bins")
        let plain = CalibratedImage(width: 40, height: 24, pixels: [Float](repeating: 1, count: 960), x: nil, y: nil,
                                    fileName: "u", source: "", voltage: nil)
        XCTAssertEqual(aspect(try PowerSpectrum.compute(plain.micrograph)), 1, accuracy: 1e-12, "1/px: each axis spans one cycle per pixel")
        // The point of it: a box of this aspect shows the same frequency per point along x and along y.
        for sp in [square, aniso] {
            let boxHeight = 240.0, boxWidth = boxHeight * aspect(sp)
            XCTAssertEqual(Double(sp.width) * sp.spacingX / boxWidth, Double(sp.height) * sp.spacingY / boxHeight, accuracy: 1e-12)
        }
        // A degenerate spectrum is drawn square rather than as a NaN or infinite box.
        XCTAssertEqual(SpectrumShape.aspect(width: 64, height: 64, spacingX: 0, unitsX: "1/nm", spacingY: 1, unitsY: "1/nm"), 1)
        XCTAssertEqual(SpectrumShape.aspect(width: 64, height: 64, spacingX: 1, unitsX: "1/nm", spacingY: .nan, unitsY: "1/nm"), 1)
    }

    /// The two spacings are compared only in one unit. The same physical pixel written in nm along x and in Å along y
    /// (128 × 128, 0.05 nm and 0.5 Å) has spacings 0.15625 1/nm and 0.015625 1/Å — a raw ratio of 10, a flat strip — and is
    /// square in nm⁻¹ (1.0); a diffraction image's spectrum in "nm" and "Å" likewise; equal units are compared as they are
    /// (whatever the unit); units that do not meet at one label — a length against a reciprocal length, two units the room
    /// does not know, a calibrated axis against an uncalibrated one — are drawn square, never as a ratio of numbers in
    /// different units. Red under: the units ignored (10.0 for the mixed pair, 20 for 1/nm against 1/px); the conversion
    /// applied to one axis only (0.1); the equal-unit case converted twice; a mixed pair left to the raw ratio.
    func testTheSpectrumBoxComparesSpacingsOnlyInOneUnit() throws {
        func aspect(_ w: Int, _ h: Int, _ sx: Double, _ ux: String, _ sy: Double, _ uy: String) -> Double {
            SpectrumShape.aspect(width: w, height: h, spacingX: sx, unitsX: ux, spacingY: sy, unitsY: uy)
        }
        // The finding's image, through the core: x in nm, y in Å.
        let mixed = CalibratedImage(width: 128, height: 128, pixels: (0..<(128 * 128)).map { Float($0 % 17) },
                                    x: AxisCalibration(scale: 0.05, unit: "nm", origin: 0), y: AxisCalibration(scale: 0.5, unit: "\u{00C5}", origin: 0),
                                    fileName: "mixed", source: "", voltage: nil)
        let s = try PowerSpectrum.compute(mixed.micrograph)
        XCTAssertEqual(s.unitsX, "1/nm")
        XCTAssertEqual(s.unitsY, "1/\u{00C5}")
        XCTAssertEqual(s.spacingX, 0.15625, accuracy: 1e-15)
        XCTAssertEqual(s.spacingY, 0.015625, accuracy: 1e-15)
        XCTAssertEqual(aspect(s.width, s.height, s.spacingX, s.unitsX, s.spacingY, s.unitsY), 1, accuracy: 1e-12,
                       "the same physical pixel: 1/0.5 Å = 1/0.05 nm")
        XCTAssertEqual(aspect(128, 128, 0.15625, "1/nm", 0.015625, "1/A"), 1, accuracy: 1e-12, "the plain spelling of Å")
        XCTAssertEqual(aspect(128, 128, 0.15625, "1/nm", 0.0125, "1/\u{00C5}"), 1.25, accuracy: 1e-12,
                       "0.0125 1/Å is 0.125 1/nm: a real 1.25")
        XCTAssertEqual(aspect(128, 64, 20, "nm", 2, "\u{00C5}"), 20.0 * 128 / (0.2 * 64), accuracy: 1e-9,
                       "a diffraction image: lengths meet in nm")
        // Equal units are compared as they are — a unit the room does not know included.
        XCTAssertEqual(aspect(64, 32, 0.25, "1/rad", 1, "1/rad"), 0.5, accuracy: 1e-12)
        XCTAssertEqual(aspect(64, 32, 0.25, "1/foo", 1, "1/Foo"), 0.5, accuracy: 1e-12, "the same unit in two spellings")
        XCTAssertEqual(aspect(64, 32, 0.25, "1/px", 1, "1/px"), 0.5, accuracy: 1e-12)
        // Anything else is square.
        XCTAssertEqual(aspect(128, 128, 0.05, "1/nm", 0.05, "1/px"), 1, "calibrated against uncalibrated")
        XCTAssertEqual(aspect(128, 64, 0.05, "1/nm", 0.05, "nm"), 1, "a reciprocal length against a length")
        XCTAssertEqual(aspect(128, 64, 0.05, "1/rad", 0.5, "1/mrad"), 1, "two units the room cannot compare")
        XCTAssertEqual(aspect(128, 64, 0.05, "1/nm", 0.5, "1/rad"), 1)
    }

    // MARK: R8, the units shown

    private func relative(_ a: Double, _ b: Double) -> Double { abs(a - b) / abs(b) }

    /// Nanometres per unit, in each spelling a file writes: m, mm, µm (the micro sign U+00B5, the Greek mu U+03BC, or
    /// "um"), nm, Å (U+00C5, the angstrom sign U+212B, a decomposed A + ring, or "A"), pm; each within 1e-12 relative.
    /// Red under: a factor wrong by a power of ten; a spelling missing; the inverse factor.
    func testNanometresPerUnitForEveryLengthSpelling() throws {
        let table: [(String, Double)] = [
            ("m", 1e9), ("meter", 1e9), ("metres", 1e9), ("mm", 1e6), ("millimetre", 1e6),
            ("\u{00B5}m", 1e3), ("\u{03BC}m", 1e3), ("um", 1e3), ("micron", 1e3), ("micrometre", 1e3),
            ("nm", 1), ("NM", 1), (" nm ", 1), ("nanometer", 1),
            ("\u{00C5}", 0.1), ("\u{212B}", 0.1), ("A\u{030A}", 0.1), ("A", 0.1), ("angstrom", 0.1), ("Angstrom", 0.1),
            ("pm", 1e-3), ("picometer", 1e-3),
        ]
        for (unit, f) in table {
            let got = try XCTUnwrap(LengthUnit.nanometres(per: unit), "\(unit.debugDescription)")
            XCTAssertLessThan(relative(got, f), 1e-12, "\(unit.debugDescription)")
        }
    }

    /// Anything that is not a length converts to nothing: the unit stays the file's own. Red under: a reciprocal or an
    /// angle taken for a length; "px" taken for one.
    func testNoConversionFactorForANonLength() {
        for unit in ["", "px", "1/nm", "nm\u{207B}\u{00B9}", "\u{00C5}\u{207B}\u{00B9}", "rad", "mrad", "s", "deg", "1/px", "kV", "1/m"] {
            XCTAssertNil(LengthUnit.nanometres(per: unit), "\(unit.debugDescription)")
        }
    }

    /// A length d in nm whenever the unit is a length (within 1e-12 relative), else as written; "px" uncalibrated. Red
    /// under: no conversion (the metre case reads 3.2e-10 "m"); a factor inverted; "px" shown as a length.
    func testLengthIsShownInNanometresOrAsWritten() {
        for (unit, d) in [("m", 3.2e-10), ("mm", 3.2e-7), ("\u{00B5}m", 3.2e-4), ("um", 3.2e-4), ("nm", 0.32), ("\u{00C5}", 3.2), ("pm", 320.0)] {
            let r = FFTUnits.length(d, unit: unit)
            XCTAssertEqual(r.label, "nm", unit)
            XCTAssertLessThan(relative(r.value, 0.32), 1e-12, "\(unit): \(r.value)")
        }
        XCTAssertEqual(FFTUnits.length(0.32, unit: "nm").value, 0.32, "nm to nm is exact")
        var r = FFTUnits.length(7.5, unit: "px")
        XCTAssertEqual(r.value, 7.5)
        XCTAssertEqual(r.label, "px")
        r = FFTUnits.length(7.5, unit: "")
        XCTAssertEqual(r.value, 7.5)
        XCTAssertEqual(r.label, "px", "an uncalibrated image")
        r = FFTUnits.length(7.5, unit: "   ")
        XCTAssertEqual(r.label, "px")
        r = FFTUnits.length(7.5, unit: "rad")
        XCTAssertEqual(r.value, 7.5)
        XCTAssertEqual(r.label, "rad", "the unit as written")
        r = FFTUnits.length(7.5, unit: "1/nm")
        XCTAssertEqual(r.label, "1/nm")
        XCTAssertEqual(r.value, 7.5)
    }

    /// A spatial frequency in nm⁻¹ for a length unit — q per unit divided by the unit's nm: 2.5 nm⁻¹ is 2.5e9 per metre,
    /// 0.25 per Å, 2.5e-3 per pm, 2500 per µm — else "1/<unit>"; "px⁻¹" uncalibrated (R8: "px and px⁻¹"). Red under: q
    /// multiplied by the factor (0.25 per Å → 0.025); no conversion (2.5e9 "1/m"); the label left as the real unit's;
    /// the uncalibrated label spelt "1/px".
    func testReciprocalIsShownPerNanometreOrAsWritten() {
        let nmInv = "nm\u{207B}\u{00B9}"
        for (unit, q) in [("nm", 2.5), ("m", 2.5e9), ("mm", 2.5e6), ("\u{00B5}m", 2500.0), ("um", 2500.0), ("\u{00C5}", 0.25),
                          ("A", 0.25), ("pm", 2.5e-3)] {
            let r = FFTUnits.reciprocal(q, realUnit: unit)
            XCTAssertEqual(r.label, nmInv, unit)
            XCTAssertLessThan(relative(r.value, 2.5), 1e-12, "\(unit): \(r.value)")
        }
        var r = FFTUnits.reciprocal(0.1, realUnit: "px")
        XCTAssertEqual(r.value, 0.1)
        XCTAssertEqual(r.label, "px\u{207B}\u{00B9}", "R8: px⁻¹ beside nm⁻¹, one notation")
        r = FFTUnits.reciprocal(0.1, realUnit: "")
        XCTAssertEqual(r.label, "px\u{207B}\u{00B9}")
        XCTAssertEqual(FFTUnits.reciprocalPixelLabel, "px\u{207B}\u{00B9}")
        XCTAssertEqual(FFTUnits.reciprocalNanometreLabel, nmInv)
        r = FFTUnits.reciprocal(0.1, realUnit: "rad")
        XCTAssertEqual(r.value, 0.1)
        XCTAssertEqual(r.label, "1/rad")
    }

    /// An axis that is already reciprocal (a diffraction pattern in "1/nm" or "1/Å") has frequencies in the unit after the
    /// "1/" — as `PowerSpectrum` names them ("nm", never "1/1/nm") — shown as the Δq row shows the same image: "nm" for
    /// "1/nm" (value kept), a length in another unit converted to nm (|q| 0.625 Å is 0.0625 nm); a reciprocal of a
    /// non-length gives its remainder as written. Red under: the fall-through label "1/1/nm" ("1/1/Å"); the remainder's
    /// Å not converted (0.625 "Å", disagreeing with the Δq row's nm); the unit's spaces or case kept in the match.
    func testAnAxisAlreadyReciprocalShowsTheFrequencyInTheUnitAfterTheSlash() throws {
        for (unit, q, value, label) in [("1/nm", 0.625, 0.625, "nm"), ("1/\u{00C5}", 0.625, 0.0625, "nm"), ("1/A", 0.625, 0.0625, "nm"),
                                        ("1/m", 2e-9, 2.0, "nm"), (" 1/nm ", 0.625, 0.625, "nm"),
                                        ("1/rad", 0.5, 0.5, "rad"), ("1/mrad", 0.5, 0.5, "mrad")] {
            let r = FFTUnits.reciprocal(q, realUnit: unit)
            XCTAssertEqual(r.label, label, unit.debugDescription)
            XCTAssertLessThan(relative(r.value, value), 1e-12, "\(unit.debugDescription): \(r.value)")
            XCTAssertFalse(r.label.hasPrefix("1/1/"), unit)
        }
        // The same image, both ways: the spectrum's own unit says "nm" for the axis "1/nm"; so does the spot's |q|.
        let image = CalibratedImage(width: 64, height: 64, pixels: (0..<4096).map { Float(sin(Double($0 % 64) * 0.9) + 2) },
                                    x: AxisCalibration(scale: 0.05, unit: "1/nm", origin: 0), y: AxisCalibration(scale: 0.05, unit: "1/nm", origin: 0),
                                    fileName: "dp", source: "", voltage: nil)
        let spectrum = try PowerSpectrum.compute(image.micrograph)
        XCTAssertEqual(spectrum.unitsX, "nm")
        XCTAssertEqual(FFTUnits.spectrumUnit(spectrum.unitsX).label, "nm")
        XCTAssertEqual(FFTUnits.reciprocal(1, realUnit: "1/nm").label, FFTUnits.spectrumUnit(spectrum.unitsX).label,
                       "|q| and Δq are labelled alike on one image")
        XCTAssertEqual(FFTUnits.reciprocal(1, realUnit: "1/\u{00C5}").label, FFTUnits.spectrumUnit("\u{00C5}").label)
        XCTAssertEqual(FFTUnits.reciprocal(1, realUnit: "1/\u{00C5}").value, FFTUnits.spectrumUnit("\u{00C5}").factor, accuracy: 1e-15)
    }

    /// A spectrum's own unit ("1/nm", "1/m", "1/Å" …, "1/px", or "nm" … for a diffraction image) is converted to the
    /// label's unit by a factor: the same as `reciprocal` for the real unit it came from. Red under: the factor
    /// inverted for either kind; "1/m" left unconverted (1, not 1e-9); "1/px" spelt as it was written.
    func testSpectrumUnitAgreesWithReciprocalForEveryLengthUnitAndConvertsLengths() throws {
        let nmInv = "nm\u{207B}\u{00B9}"
        for unit in ["nm", "m", "mm", "\u{00B5}m", "\u{03BC}m", "um", "\u{00C5}", "A", "pm"] {
            let s = FFTUnits.spectrumUnit("1/" + unit)
            let r = FFTUnits.reciprocal(1, realUnit: unit)
            XCTAssertEqual(s.label, nmInv, "1/\(unit)")
            XCTAssertLessThan(relative(s.factor, r.value), 1e-12, "1/\(unit)")
        }
        for (units, factor, label) in [("1/nm", 1.0, nmInv), ("1/m", 1e-9, nmInv), ("1/\u{00C5}", 10.0, nmInv), ("1/pm", 1000.0, nmInv),
                                       ("1/\u{00B5}m", 1e-3, nmInv), ("1/px", 1.0, "px\u{207B}\u{00B9}"),
                                       ("nm", 1.0, "nm"), ("m", 1e9, "nm"), ("\u{00C5}", 0.1, "nm"), ("\u{00B5}m", 1e3, "nm"),
                                       ("pm", 1e-3, "nm"), ("1/rad", 1.0, "1/rad"), ("rad", 1.0, "rad")] {
            let s = FFTUnits.spectrumUnit(units)
            XCTAssertEqual(s.label, label, units)
            XCTAssertLessThan(relative(s.factor, factor), 1e-12, "\(units): \(s.factor)")
        }
        XCTAssertEqual(FFTUnits.spectrumUnit("").label, "px\u{207B}\u{00B9}", "no unit: read as uncalibrated")
        // The core's own unit comes through: the spectrum of an image in nm.
        let own = try PowerSpectrum.compute(lattice(16, 16, fx: 2, fy: 1).micrograph).unitsX
        XCTAssertEqual(own, "1/nm")
        XCTAssertEqual(FFTUnits.spectrumUnit(own).label, nmInv)
    }

    // MARK: P2, from a click on the spectrum to d (no pane)

    /// The offsets of a click from the peak bin, in bins: the bin it falls in is within ±2 of the peak; 2.4 rounds to 2
    /// but floors to 2 and −2.4 rounds to −2 but floors to −3, outside the snap window.
    private static let clickOffsets: [Double] = [-2.4, -2, -1, -0.4, 0, 0.4, 1, 2, 2.4]

    /// A click at the planted peak's bin and at every offset within ±2 bins measures d₀ within 0.2 %, on the whole
    /// image and on typed, centred regions of 64, 100, 128 and 200 px; the snap window holds no tie and the peak is at
    /// least 5 bins from the centre. Red under: the bin by floor (a click 2.4 bins below the peak falls outside the snap
    /// window); row and column swapped (a click lands on the wrong bin of a non-square transform); a mapping that
    /// clamps to the wrong size.
    func testAClickAtThePlantedPeakAndWithinTwoBinsMeasuresItsSpacing() throws {
        let planted = FFTRoomMathPlanted()
        let image = planted.image()
        let regions: [PixelCrop?] = [
            nil,
            try XCTUnwrap(FFTRegion.typed(left: 30, top: 10, size: 64, width: 300, height: 200)),
            try XCTUnwrap(FFTRegion.typed(left: 100, top: 20, size: 100, width: 300, height: 200)),
            try XCTUnwrap(FFTRegion.typed(left: 90, top: 40, size: 128, width: 300, height: 200)),
            try XCTUnwrap(FFTRegion.centredSquare(width: 300, height: 200)),
        ]
        for region in regions {
            try checkChain(planted, image: image, crop: region)
        }
    }

    /// The same chain on the anisotropic copy (0.05 × 0.04 nm) for the whole image, and on the copy in metres (the file's
    /// scale 5e-11 m, d read in nm through `FFTUnits`). Red under: the bin mutations above; no unit conversion (d reads
    /// 4e-10 "m"); the anisotropic spacing taken square.
    func testTheAnisotropicAndTheMetreCopiesMeasureTheSameSpacing() throws {
        let aniso = FFTRoomMathPlanted(dy: 0.04)
        try checkChain(aniso, image: aniso.image(), crop: nil)
        try checkChain(aniso, image: aniso.image(), crop: try XCTUnwrap(FFTRegion.typed(left: 10, top: 10, size: 128, width: 300, height: 200)))
        let metres = FFTRoomMathPlanted(unit: "m")
        XCTAssertEqual(metres.image().x?.unit, "m")
        XCTAssertEqual(try XCTUnwrap(metres.image().x?.scale), 5e-11, accuracy: 1e-24)
        try checkChain(metres, image: metres.image(), crop: nil)
        try checkChain(metres, image: metres.image(), crop: try XCTUnwrap(FFTRegion.centredSquare(width: 300, height: 200)))
    }

    private func checkChain(_ planted: FFTRoomMathPlanted, image: CalibratedImage, crop: PixelCrop?,
                            file: StaticString = #filePath, line: UInt = #line) throws {
        let spectrum = try PowerSpectrum.compute(image.micrograph, crop: crop)
        let w = spectrum.width, h = spectrum.height
        let peak = planted.checkedPeak(of: spectrum, file: file, line: line)
        let tag = "\(w) × \(h) of \(planted.unit) \(planted.dx) × \(planted.dy)"
        var worst = 0.0
        for oy in Self.clickOffsets { for ox in Self.clickOffsets {
            let bin = SpectrumBin.at(pt(Double(peak.col) + ox, Double(peak.row) + oy), width: w, height: h)
            let m = try SpotMeasurement.measure(image.micrograph, crop: crop, clickRow: bin.row, clickColumn: bin.col)
            let d = FFTUnits.length(m.d, unit: planted.unit)
            XCTAssertEqual(d.label, "nm", file: file, line: line)
            let error = abs(d.value - FFTRoomMathPlanted.d0) / FFTRoomMathPlanted.d0
            worst = max(worst, error)
            XCTAssertLessThan(error, 0.002, "\(tag): click at offset (\(ox), \(oy)) → bin (\(bin.row), \(bin.col)), d = \(d.value)",
                              file: file, line: line)
        } }
        XCTAssertLessThan(worst, 0.002, file: file, line: line)
    }
}
