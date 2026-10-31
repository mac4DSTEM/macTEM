//
//  FFTRoomClickTests.swift
//  P2 of the FFT room ("The room"), end to end through the panes' own map: a region drawn between two PANE
//  points, a click at the pane position of the planted peak, and d. The maps are built exactly as `ImagePane` builds
//  them — `MarkGeometry` over `MetalDisplayTransform(paneSize: box, imageBox: box, zoom:, offset:)`, the box from
//  `LayoutPolicy.fitted` — at two pane sizes, zoom 1 and 3, and an offset; the spectrum's box from
//  `SpectrumShape.aspect`. The dataset is `FFTRoomMathPlanted` (FFTRoomMathTests.swift): a 300 × 200 image at 0.05
//  nm/px, a DC and a lattice of d₀ = 0.4 nm at 33.3°, and its copy at 0.05 × 0.04 nm. The same chain without the pane is
//  `FFTRoomMathTests`. App-hosted: `@testable import macTEM`.
//

import ShellLayout
import ShellMetal
import XCTest
import TEMCore
import ImagoCore
import ImagoFFT
@testable import macTEM

nonisolated final class FFTRoomClickTests: XCTestCase {

    /// A pane as the user has it: the size of the area the image is fitted in, the zoom, and the pan — a fixed offset
    /// (zoom 1), or the one that puts the point of interest at a fraction of the box (zoom 3).
    private struct Setting {
        let pane: CGSize
        let zoom: CGFloat
        let offset: CGSize
        let pinAt: CGPoint?
    }

    private static let settings: [Setting] = [
        Setting(pane: CGSize(width: 900, height: 600), zoom: 1, offset: .zero, pinAt: nil),
        Setting(pane: CGSize(width: 610, height: 420), zoom: 1, offset: CGSize(width: 12, height: -7), pinAt: nil),
        Setting(pane: CGSize(width: 900, height: 600), zoom: 3, offset: .zero, pinAt: CGPoint(x: 0.31, y: 0.62)),
        Setting(pane: CGSize(width: 610, height: 420), zoom: 3, offset: .zero, pinAt: CGPoint(x: 0.7, y: 0.4)),
    ]

    /// The map of a pane showing a `width` × `height` picture in `box` at this setting, with `interest` (an image point)
    /// pinned where the setting says, if it pins.
    @MainActor private func geometry(_ s: Setting, box: CGSize, width: Int, height: Int, interest: ImagePoint) -> MarkGeometry {
        func make(_ offset: CGSize) -> MarkGeometry {
            MarkGeometry(transform: MetalDisplayTransform(paneSize: box, imageBox: box, zoom: s.zoom, offset: offset),
                         imageWidth: width, imageHeight: height)
        }
        guard let pin = s.pinAt else { return make(s.offset) }
        let at = make(.zero).panePoint(of: interest)
        return make(CGSize(width: pin.x * box.width - at.x, height: pin.y * box.height - at.y))
    }

    private func pt(_ x: Double, _ y: Double) -> ImagePoint { ImagePoint(x: x, y: y) }

    /// The registration's drags, as image points (the press, the pointer) and the crop each must give: all three are
    /// ≥ 64 px, the last two drawn leftwards or upwards, none on a tie of the corner rule.
    private static let drags: [(a: ImagePoint, b: ImagePoint, crop: PixelCrop)] = [
        (ImagePoint(x: 70.3, y: 40.6), ImagePoint(x: 161.0, y: 128.8), PixelCrop(row: 41, col: 71, height: 90, width: 90)),
        (ImagePoint(x: 190.2, y: 30.4), ImagePoint(x: 120.1, y: 114.9), PixelCrop(row: 31, col: 107, height: 84, width: 84)),
        (ImagePoint(x: 250.6, y: 160.2), ImagePoint(x: 150.3, y: 70.9), PixelCrop(row: 61, col: 151, height: 100, width: 100)),
    ]

    // MARK: The region

    /// A region pressed and dragged between two pane points is the crop the pane's map names, at both pane sizes, both
    /// zooms and a pan: the pane points go back through `imagePoint(atPanePoint:)` to `FFTRegion.drawn`. The press is on
    /// screen in every setting. Red under: the corner by floor, the drag's direction ignored, an odd side, a minimum of
    /// 30, shrunk instead of shifted (FFTRoomMathTests holds them to their exact values); the map's zoom or offset left
    /// out (the crop moves).
    @MainActor func testARegionDrawnBetweenTwoPanePointsIsTheCropThePaneMapsItTo() throws {
        for s in Self.settings { for d in Self.drags {
            let box = LayoutPolicy.fitted(in: s.pane, aspect: 300.0 / 200.0)
            let g = geometry(s, box: box, width: 300, height: 200, interest: d.a)
            let pressed = g.panePoint(of: d.a), dragged = g.panePoint(of: d.b)
            XCTAssertTrue(CGRect(origin: .zero, size: box).contains(pressed), "the press is on screen: \(pressed) in \(box)")
            let crop = FFTRegion.drawn(from: g.imagePoint(atPanePoint: pressed).pixelPoint, to: g.imagePoint(atPanePoint: dragged).pixelPoint,
                                       width: 300, height: 200)
            XCTAssertEqual(crop, d.crop, "pane \(s.pane), zoom \(s.zoom), drag \(d.a) → \(d.b)")
            XCTAssertTrue(crop.map { FFTRegion.isValid($0, width: 300, height: 200) } ?? false)
        } }
    }

    /// The same from pane points a person would press: at zoom 1 in a 900 × 600 pane the 300 × 200 image is 3 points per
    /// pixel, so pane (214, 125) is image (70.83, 41.17), pane (487, 391) is (161.83, 129.83); the corner is the edge
    /// (71, 42) and the side 2⌊91/2⌋ = 90. Red under: the pane's size for the image's in the map; the corner by floor
    /// ((71, 41)).
    @MainActor func testARegionDrawnFromWholePanePointsIsTheCropArithmeticGives() throws {
        let box = LayoutPolicy.fitted(in: CGSize(width: 900, height: 600), aspect: 300.0 / 200.0)
        XCTAssertEqual(box, CGSize(width: 900, height: 600))
        let g = MarkGeometry(transform: MetalDisplayTransform(paneSize: box, imageBox: box, zoom: 1, offset: .zero),
                             imageWidth: 300, imageHeight: 200)
        let p0 = g.imagePoint(atPanePoint: CGPoint(x: 214, y: 125)), p1 = g.imagePoint(atPanePoint: CGPoint(x: 487, y: 391))
        XCTAssertEqual(p0.x, 214.0 / 3 - 0.5, accuracy: 1e-9)
        XCTAssertEqual(p0.y, 125.0 / 3 - 0.5, accuracy: 1e-9)
        XCTAssertEqual(p1.x, 487.0 / 3 - 0.5, accuracy: 1e-9)
        XCTAssertEqual(FFTRegion.drawn(from: p0.pixelPoint, to: p1.pixelPoint, width: 300, height: 200),
                       PixelCrop(row: 42, col: 71, height: 90, width: 90))
        // The outline is drawn on the crop's pixel edges: the top-left corner, image (70.5, 41.5), is at pane (71, 42) · 3 = (213, 126).
        let outline = g.panePoint(of: ImagePoint(FFTRegion.point(of: .topLeft, in: PixelCrop(row: 42, col: 71, height: 90, width: 90))))
        XCTAssertEqual(outline.x, 213, accuracy: 1e-9)
        XCTAssertEqual(outline.y, 126, accuracy: 1e-9)
    }

    // MARK: The click

    /// A click at the pane position of the planted peak, and of every bin within ±2 of it (with a wobble inside the
    /// bin), goes back through `imagePoint(atPanePoint:)` to the bin it was made on and measures d₀ within 0.2 % — on
    /// the three drawn regions and on the whole image, in all four pane settings. The spectrum's box is the aspect of
    /// its physical extents, so the 300 × 200 spectrum of square pixels is drawn square (2 points per column, 3 per
    /// row at 600 pt). Red under: the bin by floor or row and column swapped (FFTRoomMathTests), the aspect w : h (the
    /// box is 1.5 and a bin's pane position moves off its click).
    @MainActor func testAClickAtThePlantedPeakInThePaneMeasuresItsSpacing() throws {
        let planted = FFTRoomMathPlanted()
        let image = planted.image()
        var regions: [PixelCrop?] = Self.drags.map { Optional($0.crop) }
        regions.append(nil)
        for crop in regions {
            try chain(planted, image: image, crop: crop)
        }
    }

    /// The same on the anisotropic copy (0.05 × 0.04 nm) for the whole image — its spectrum box is 0.8 : 1 although it has
    /// 1.5 as many columns as rows — and for a drawn region of it. Red under: the aspect w : h; the pixel size taken
    /// square (the spacing along y).
    @MainActor func testTheAnisotropicCopyMeasuresItsSpacingThroughThePane() throws {
        let aniso = FFTRoomMathPlanted(dy: 0.04)
        let image = aniso.image()
        let spectrum = try PowerSpectrum.compute(image.micrograph)
        XCTAssertEqual(SpectrumShape.aspect(width: spectrum.width, height: spectrum.height, spacingX: spectrum.spacingX,
                                               unitsX: spectrum.unitsX, spacingY: spectrum.spacingY, unitsY: spectrum.unitsY),
                       0.8, accuracy: 1e-12)
        try chain(aniso, image: image, crop: nil)
        try chain(aniso, image: image, crop: Self.drags[0].crop)
    }

    /// From the pane, through the room's map, to d. `crop` is what was drawn on the source (nil: the whole image).
    @MainActor private func chain(_ planted: FFTRoomMathPlanted, image: CalibratedImage, crop: PixelCrop?,
                                  file: StaticString = #filePath, line: UInt = #line) throws {
        let spectrum = try PowerSpectrum.compute(image.micrograph, crop: crop)
        let w = spectrum.width, h = spectrum.height
        let peak = planted.checkedPeak(of: spectrum, file: file, line: line)
        let aspect = SpectrumShape.aspect(width: w, height: h, spacingX: spectrum.spacingX, unitsX: spectrum.unitsX,
                                             spacingY: spectrum.spacingY, unitsY: spectrum.unitsY)
        var measured: [Int: Double] = [:]      // d per bin: the same bin is the same answer in every setting
        let tag = "\(w) × \(h) of \(planted.dx) × \(planted.dy)"
        for s in Self.settings {
            let box = LayoutPolicy.fitted(in: s.pane, aspect: CGFloat(aspect))
            let g = geometry(s, box: box, width: w, height: h, interest: pt(Double(peak.col), Double(peak.row)))
            let pointsPerColumn = g.pointsPerPixel
            let pointsPerRow = box.height / CGFloat(h) * s.zoom
            for dy in -2...2 { for dx in -2...2 {
                let centre = g.panePoint(of: pt(Double(peak.col + dx), Double(peak.row + dy)))
                // The peak is on screen at zoom 1 and where it was pinned at zoom 3; its neighbours are within ±2 bins.
                if dx == 0 && dy == 0 {
                    XCTAssertTrue(CGRect(origin: .zero, size: box).contains(centre), "\(tag): the peak is on screen, \(centre) in \(box)",
                                  file: file, line: line)
                }
                for (wx, wy) in [(0.0, 0.0), (0.3, -0.3), (-0.45, 0.45)] {
                    let p = CGPoint(x: centre.x + wx * pointsPerColumn, y: centre.y + wy * pointsPerRow)
                    let bin = SpectrumBin.at(g.imagePoint(atPanePoint: p).pixelPoint, width: w, height: h)
                    XCTAssertEqual(bin.row, peak.row + dy, "\(tag): pane \(s.pane) zoom \(s.zoom): row of the click", file: file, line: line)
                    XCTAssertEqual(bin.col, peak.col + dx, "\(tag): pane \(s.pane) zoom \(s.zoom): column of the click", file: file, line: line)
                    let key = bin.row * w + bin.col
                    if measured[key] == nil {
                        measured[key] = try SpotMeasurement.measure(image.micrograph, crop: crop, clickRow: bin.row, clickColumn: bin.col).d
                    }
                    let d = FFTUnits.length(try XCTUnwrap(measured[key]), unit: planted.unit).value
                    XCTAssertLessThan(abs(d - FFTRoomMathPlanted.d0) / FFTRoomMathPlanted.d0, 0.002,
                                      "\(tag): click at bin offset (\(dx), \(dy)) → d = \(d)", file: file, line: line)
                }
            } }
        }
    }

    // MARK: The box

    /// A ring is a circle: in the box the aspect gives, one point is the same frequency along x and along y (the scale
    /// bar's units per point, Δq · n / box / zoom, from either axis), at every pane size and zoom — for the square-pixel
    /// image, whose 300 × 200 spectrum is drawn square, and for the anisotropic one. Red under: the aspect w : h (the
    /// two differ by 1.5); Δq_y for Δq_x in the bar (the anisotropic pair differs by 1.25).
    @MainActor func testTheSpectrumBoxShowsTheSameFrequencyPerPointAlongBothAxes() throws {
        for planted in [FFTRoomMathPlanted(), FFTRoomMathPlanted(dy: 0.04)] {
            let spectrum = try PowerSpectrum.compute(planted.image().micrograph)
            let aspect = SpectrumShape.aspect(width: spectrum.width, height: spectrum.height, spacingX: spectrum.spacingX,
                                                 unitsX: spectrum.unitsX, spacingY: spectrum.spacingY, unitsY: spectrum.unitsY)
            for s in Self.settings {
                let box = LayoutPolicy.fitted(in: s.pane, aspect: CGFloat(aspect))
                XCTAssertEqual(Double(box.width / box.height), aspect, accuracy: 1e-9, "the box is the aspect")
                let alongX = ImageScaleBar.unitsPerPoint(perPixel: spectrum.spacingX, imageWidth: spectrum.width,
                                                         boxWidth: box.width, zoom: s.zoom)
                let alongY = ImageScaleBar.unitsPerPoint(perPixel: spectrum.spacingY, imageWidth: spectrum.height,
                                                         boxWidth: box.height, zoom: s.zoom)
                XCTAssertEqual(alongX, alongY, accuracy: alongX * 1e-9, "\(planted.dy) nm rows, pane \(s.pane), zoom \(s.zoom)")
                XCTAssertEqual(alongX, Double(spectrum.width) * spectrum.spacingX / Double(box.width) / Double(s.zoom),
                               accuracy: alongX * 1e-12, "Δq_x · w / boxWidth / zoom")
            }
        }
    }
}
