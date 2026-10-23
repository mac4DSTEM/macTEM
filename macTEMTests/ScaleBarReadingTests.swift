//
//  ScaleBarReadingTests.swift
//  Pins what the image pane's scale bar PRINTS, end to end: mac4DSTEM's `ScaleBar` (a copy) reads its bar in the
//  unit its length suits (`ScaleBarMath.ladder`: nm, µm or mm, exact ×1000 steps, the number in [1, 1000)), and macTEM
//  hands it a metre axis through `ImageScaleBar.sampling` / `DisplaySampling`, which bring the axis to nm, µm or mm
//  first. Each of the two steps converts once, so the label names the length the bar draws (`namedMetres` equals
//  `drawnMetres`, the latter from the file's own calibration, not from either step), a metre axis never reads
//  "1e-08 m", and an SEM field zoomed in reads "20 nm", not "0.02 µm".
//  `ScaleBarUnitTests` (a copy of mac4DSTEM's) pins `ladder` and `spokenLabel` alone; `ScaleBarTests` pins
//  `nice125`, `format`, `footerSampling` and the pane's numbers on the planted fixture.
//  Mutations each test must go red under: `ImageScaleBar.sampling` handing the metre axis through unconverted (the
//  unit stays "m"); `DisplaySampling.unit(forMetres:)` with ×1e6 for nm (the label names 1000× the length drawn); the
//  per-pixel scale rescaled but the label left as "m"; `ScaleBarMath.ladder` returning its input (the zoomed SEM bar
//  stays "0.02 µm", a large nm field stays "20000 nm").
//

import ShellControls
import ImagoCore
import XCTest
import TEMCore
@testable import macTEM

nonisolated final class ScaleBarReadingTests: XCTestCase {

    private static let posix = Locale(identifier: "en_US_POSIX")
    private static let micro = "\u{00B5}m"

    /// The metres in one of the units a bar is read in.
    private static func metres(per unit: String) -> Double? {
        ["nm": 1e-9, micro: 1e-6, "mm": 1e-3, "\u{00C5}": 1e-10][unit]
    }

    private nonisolated struct Bar {
        let label: String
        let value: Double
        let unit: String
        /// The length the label names (NaN for a unit a bar is not read in) and the length the bar draws, in metres.
        let namedMetres: Double
        let drawnMetres: Double
    }

    /// The bar `ImagePane` draws for `fixture` at `zoom` in a `boxWidth`-point box: the same `ImageScaleBar`
    /// functions, `ScaleBarMath.nice125` of 70 points, `ScaleBarMath.ladder`, and the label as the view builds it. The
    /// length drawn comes from the fixture's own metres per pixel, not from any step under test.
    @MainActor private static func bar(_ fixture: Fixture, boxWidth: CGFloat = 800, zoom: CGFloat) -> Bar {
        let image = fixture.image
        let sampling = ImageScaleBar.sampling(image)
        let perPoint = ImageScaleBar.unitsPerPoint(perPixel: sampling.perPixel, imageWidth: image.width,
                                                   boxWidth: boxWidth, zoom: zoom)
        let nice = ScaleBarMath.nice125(perPoint * 70)
        let shown = ScaleBarMath.ladder(nice, unit: sampling.label)
        let metresPerPoint = fixture.metresPerPixel * Double(image.width) / Double(boxWidth) / Double(zoom)
        return Bar(label: "\(ScaleBar.format(shown.value, locale: posix)) \(shown.unit)", value: shown.value,
                   unit: shown.unit, namedMetres: shown.value * (metres(per: shown.unit) ?? .nan),
                   drawnMetres: nice / perPoint * metresPerPoint)
    }

    /// An image `width` pixels wide whose x (and y) calibration is `scale` `units` per pixel, and that same pixel
    /// in metres, written out by the test.
    private nonisolated struct Fixture {
        let image: CalibratedImage
        let metresPerPixel: Double

        init(scale: Double, units: String, width: Int, metresPerPixel: Double) {
            let axis = AxisCalibration(scale: scale, unit: units, origin: 0)
            image = CalibratedImage(width: width, height: 2, pixels: [Float](repeating: 0, count: width * 2),
                                    x: axis, y: axis, fileName: "a.tif", source: "TIFF", voltage: nil)
            self.metresPerPixel = metresPerPixel
        }
    }

    private static let ceta = Fixture(scale: 4.46179e-11, units: "m", width: 2048, metresPerPixel: 4.46179e-11)
    private static let sem = Fixture(scale: 1e-8, units: "m", width: 1536, metresPerPixel: 1e-8)
    private static let wide = Fixture(scale: 1e-5, units: "m", width: 1000, metresPerPixel: 1e-5)
    private static let largeNm = Fixture(scale: 100, units: "nm", width: 2048, metresPerPixel: 1e-7)
    private static let angstrom = Fixture(scale: 0.5, units: "\u{00C5}", width: 1000, metresPerPixel: 0.5e-10)

    /// By hand, in an 800-pt box. SEM, 1536 px × 1e-8 m (a 15.4 µm field, so the pixel reaches the bar in µm):
    /// 0.0192 µm/pt at zoom 1, 70 pt ≈ 1.34 µm → "1 µm"; at zoom 64, 70 pt ≈ 0.021 µm → 0.02 µm → "20 nm".
    /// 1000 px × 1e-5 m (a 1 cm field, mm): 0.0125 mm/pt, 70 pt ≈ 0.875 mm → "1 mm"; at zoom 8, 0.1 mm → "100 µm".
    /// Ceta, 2048 px × 4.46179e-11 m: 0.114 nm/pt, 70 pt ≈ 8.0 nm → "10 nm"; at zoom 2, 4.0 nm → "5 nm".
    /// 2048 px × 100 nm: 256 nm/pt, 70 pt ≈ 17920 nm → 20000 nm → "20 µm" (an nm axis climbs the ladder too).
    @MainActor func testABarReadsInTheUnitItsLengthSuits() {
        let cases: [(name: String, fixture: Fixture, zoom: CGFloat, label: String)] = [
            ("SEM x1", Self.sem, 1, "1 \(Self.micro)"),
            ("SEM x64", Self.sem, 64, "20 nm"),
            ("1 cm field x1", Self.wide, 1, "1 mm"),
            ("1 cm field x8", Self.wide, 8, "100 \(Self.micro)"),
            ("Ceta x1", Self.ceta, 1, "10 nm"),
            ("Ceta x2", Self.ceta, 2, "5 nm"),
            ("large nm field", Self.largeNm, 1, "20 \(Self.micro)"),
            ("Å field", Self.angstrom, 1, "50 \u{00C5}"),
        ]
        for c in cases {
            XCTAssertEqual(Self.bar(c.fixture, zoom: c.zoom).label, c.label, c.name)
        }
    }

    /// Whatever the field and the zoom, the label names the length the bar draws (one conversion per step, none
    /// twice, none dropped), never prints a metre as such or in scientific notation, and keeps its number in
    /// [1, 1000) except on the bottom rung (nm below 1, no unit under it) and for the Å, which the ladder leaves.
    @MainActor func testTheLabelNamesTheLengthTheBarDraws() {
        let images = [("Ceta", Self.ceta), ("SEM", Self.sem), ("1 cm", Self.wide), ("large nm", Self.largeNm),
                      ("Å", Self.angstrom)]
        for (name, fixture) in images {
            for zoom in [1.0, 2, 4, 8, 16, 32, 64, 128, 256, 512] {
                let id = "\(name) x\(zoom)"
                let bar = Self.bar(fixture, zoom: CGFloat(zoom))
                XCTAssertEqual(bar.namedMetres, bar.drawnMetres, accuracy: bar.drawnMetres * 1e-12,
                               "\(id): \(bar.label) is not the length drawn")
                XCTAssertFalse(bar.label.contains("e-") || bar.label.contains("e+"), "\(id): \(bar.label)")
                XCTAssertTrue(["nm", Self.micro, "mm", "\u{00C5}"].contains(bar.unit), "\(id): \(bar.label)")
                if bar.unit != "\u{00C5}" {
                    XCTAssertLessThan(bar.value, 1000, "\(id): \(bar.label)")
                    XCTAssertTrue(bar.value >= 1 || bar.unit == "nm", "\(id): \(bar.label)")
                }
            }
        }
    }
}
