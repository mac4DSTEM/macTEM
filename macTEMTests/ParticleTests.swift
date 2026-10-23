//
//  ParticleTests.swift
//  The Particles view's compute (`ParticleCompute`, TEMCore) and owner (`ParticleAnalysis`, TEMSession) on a planted image of
//  three bright ellipses of known length, width and angle on a dark background, one single-pixel object, and one object cut by the
//  image edge.
//
//  WHAT IS PINNED (D12, D17): the labels and every length, width, angle and centroid are ImagoKit's `Segmentation`; the room's own
//  parts are the threshold compare, the counted / edge / small classes, and the summary (a median and a mean of the kit's numbers).
//  The planted ellipses are recovered within the bounds written where they are used (a rasterised ellipse is not an exact one: the
//  moments of its pixel centres differ from the closed form by the sampling, a few percent at these sizes).
//

import XCTest
import ImagoCore
#if canImport(TEMCore)
import TEMCore
import TEMSession
#endif
@testable import macTEM

nonisolated final class ParticleTests: XCTestCase {

    struct Ellipse { var cx: Double, cy: Double, a: Double, b: Double, degrees: Double }
    static let ellipses = [Ellipse(cx: 30, cy: 30, a: 16, b: 6, degrees: 30),
                           Ellipse(cx: 75, cy: 25, a: 10, b: 10, degrees: 0),
                           Ellipse(cx: 60, cy: 55, a: 18, b: 5, degrees: -60)]
    static let width = 100, height = 80

    /// 100 on the ellipses, 10 elsewhere (plus a little ramp so smoothing has something to do), a 1-px object at (5, 5) and a block
    /// cut by the right edge.
    static func planted() -> [Float] {
        var px = [Float](repeating: 10, count: width * height)
        for e in ellipses {
            let t = e.degrees * .pi / 180
            for y in 0..<height { for x in 0..<width {
                let dx = Double(x) - e.cx, dy = Double(y) - e.cy
                let u = dx * cos(t) + dy * sin(t), v = -dx * sin(t) + dy * cos(t)
                if (u / e.a) * (u / e.a) + (v / e.b) * (v / e.b) <= 1 { px[y * width + x] = 100 }
            } }
        }
        px[5 * width + 5] = 100
        for y in 40..<46 { for x in 96..<100 { px[y * width + x] = 100 } }
        return px
    }

    // MARK: Recovery

    /// Three ellipses of known axes and angles are recovered through the compute, the 1-px object is listed and not counted, the
    /// edge block is listed and not counted, and the summary adds up. Red under: the grid transposed (angles negate); the edge object
    /// counted; the small object dropped from the list.
    func testPlantedEllipsesAreRecoveredWithinTheMomentsTolerance() throws {
        let report = try ParticleCompute.analyse(pixels: Self.planted(), width: Self.width, height: Self.height, settings: ParticleSettings())
        XCTAssertEqual(report.objects.count, 5)
        XCTAssertEqual(report.summary.total, 5)
        XCTAssertEqual(report.summary.counted, 3)
        XCTAssertEqual(report.summary.edge, 1)
        XCTAssertEqual(report.summary.small, 1)
        XCTAssertEqual(report.summary.counted + report.summary.edge + report.summary.small, report.summary.total)
        XCTAssertEqual(report.thresholdValue, 55, accuracy: 1e-4, "half of the range 10 to 100")

        let small = try XCTUnwrap(report.objects.first { $0.moments.area == 1 })
        XCTAssertTrue(small.isSmall); XCTAssertFalse(small.isCounted)
        let edge = try XCTUnwrap(report.objects.first { $0.touchesEdge })
        XCTAssertEqual(edge.moments.area, 24); XCTAssertFalse(edge.isCounted)

        let counted = report.objects.filter(\.isCounted)
        for e in Self.ellipses {
            let o = try XCTUnwrap(counted.min { hypot($0.moments.centroidCol - e.cx, $0.moments.centroidRow - e.cy) < hypot($1.moments.centroidCol - e.cx, $1.moments.centroidRow - e.cy) })
            let m = o.moments
            XCTAssertEqual(m.centroidCol, e.cx, accuracy: 0.3, "centroid x")
            XCTAssertEqual(m.centroidRow, e.cy, accuracy: 0.3, "centroid y")
            XCTAssertEqual(m.axisMajorLength, 2 * e.a, accuracy: 0.03 * 2 * e.a, "major axis of \(e)")
            XCTAssertEqual(m.axisMinorLength, 2 * e.b, accuracy: 0.05 * 2 * e.b, "minor axis of \(e)")
            if e.a != e.b {
                var d = m.orientationDegrees - e.degrees
                while d > 90 { d -= 180 }; while d <= -90 { d += 180 }
                XCTAssertEqual(d, 0, accuracy: 2, "angle of \(e)")
            }
        }
    }

    /// The summary's median length and mean width are those of the counted objects' kit values, in pixels and in a calibrated unit.
    /// Red under: edge or small objects in the statistics.
    func testTheSummaryIsOverTheCountedObjectsOnly() throws {
        let report = try ParticleCompute.analyse(pixels: Self.planted(), width: Self.width, height: Self.height, settings: ParticleSettings())
        let counted = report.objects.filter(\.isCounted).map(\.moments)
        XCTAssertEqual(counted.count, 3)
        XCTAssertEqual(try XCTUnwrap(report.summary.medianLengthPx), counted.map(\.lengthPx).sorted()[1], accuracy: 1e-12, "the middle of three")
        XCTAssertEqual(try XCTUnwrap(report.summary.meanWidthPx), counted.map(\.widthPx).reduce(0, +) / 3, accuracy: 1e-12)
        let text = ParticleFormat.sizes(report.summary, scale: ParticleScale(perPixel: 0.5, unit: "nm"))
        XCTAssertTrue(text.hasPrefix("median length ") && text.contains(" nm · mean width "), text)
        XCTAssertEqual(ParticleFormat.counts(report.summary), "5 objects · 3 counted · 1 edge · 1 small")
        XCTAssertEqual(ParticleFormat.sizes(ParticleSummary(), scale: ParticleScale(perPixel: 1, unit: "px")), "No objects above the threshold.")
    }

    // MARK: Settings

    /// Dark objects invert the compare; the threshold fraction moves the cut; the minimum area changes what is counted. Red under: the
    /// polarity ignored; the fraction applied to the wrong range.
    func testPolarityThresholdAndMinimumAreaChangeTheObjects() throws {
        let px = Self.planted()
        var dark = ParticleSettings(); dark.polarity = .dark
        let inverse = try ParticleCompute.analyse(pixels: px, width: Self.width, height: Self.height, settings: dark)
        XCTAssertEqual(inverse.objects.count, 1, "the background is one connected object")
        XCTAssertTrue(inverse.objects[0].touchesEdge)
        var high = ParticleSettings(); high.thresholdFraction = 0.99
        XCTAssertEqual(try ParticleCompute.analyse(pixels: px, width: Self.width, height: Self.height, settings: high).objects.count, 5, "100 is above 0.99 of the range")
        high.thresholdFraction = 1
        let none = try ParticleCompute.analyse(pixels: px, width: Self.width, height: Self.height, settings: high)
        XCTAssertTrue(none.objects.isEmpty, "nothing exceeds the maximum")
        var strict = ParticleSettings(); strict.minimumArea = 30
        XCTAssertEqual(try ParticleCompute.analyse(pixels: px, width: Self.width, height: Self.height, settings: strict).summary.small, 1, "the 24-pixel block is on the edge; only the 1-px object is small")
        XCTAssertEqual(ParticleFormat.sizes(none.summary, scale: ParticleScale(perPixel: 1, unit: "px")), "No objects above the threshold.")
    }

    /// Smoothing is ImagoKit's Gaussian: a one-pixel speck below the threshold after smoothing disappears; the ellipses stay.
    /// Red under: sigma ignored.
    func testSmoothingRemovesASpeck() throws {
        var s = ParticleSettings(); s.sigma = 1.5
        let report = try ParticleCompute.analyse(pixels: Self.planted(), width: Self.width, height: Self.height, settings: s)
        XCTAssertFalse(report.objects.contains { $0.moments.area == 1 })
        XCTAssertEqual(report.objects.filter(\.isCounted).count, 3)
    }

    func testAnImageWithNoFiniteValueIsRefusedInWords() {
        XCTAssertThrowsError(try ParticleCompute.analyse(pixels: [.nan, .nan], width: 2, height: 1, settings: ParticleSettings())) {
            XCTAssertEqual(($0 as? LocalizedError)?.errorDescription, "The image holds no finite value to threshold.")
        }
    }

    /// Lengths are shown in the file's unit only when the pixels are square and calibrated; otherwise pixels.
    func testTheScaleIsTheFilesOrPixels() {
        func image(x: AxisCalibration?, y: AxisCalibration?) -> CalibratedImage {
            CalibratedImage(width: 2, height: 2, pixels: [0, 1, 2, 3], x: x, y: y, fileName: "a.dm4", source: "", voltage: nil)
        }
        let nm = AxisCalibration(scale: 0.25, unit: "nm")
        XCTAssertEqual(ParticleCompute.scale(of: image(x: nm, y: nm)), ParticleScale(perPixel: 0.25, unit: "nm"))
        XCTAssertEqual(ParticleCompute.scale(of: image(x: nm, y: AxisCalibration(scale: 0.5, unit: "nm"))), ParticleScale(perPixel: 1, unit: "px"), "unequal pixels")
        XCTAssertEqual(ParticleCompute.scale(of: image(x: nil, y: nil)), ParticleScale(perPixel: 1, unit: "px"))
    }

    // MARK: CSV

    /// The CSV has the provenance lines, the badge and a row per object with the kit's numbers.
    func testTheCSVCarriesProvenanceAndEveryObject() throws {
        let report = try ParticleCompute.analyse(pixels: Self.planted(), width: Self.width, height: Self.height, settings: ParticleSettings())
        let csv = ParticleFormat.csv(report, scale: ParticleScale(perPixel: 0.5, unit: "nm"), fileName: "p.dm4")
        let lines = csv.split(separator: "\n").map(String.init)
        XCTAssertTrue(lines[0].hasSuffix("validation: none"), lines[0])
        XCTAssertTrue(lines[1].contains("fraction 0.5 of the raw range = 55"), lines[1])
        XCTAssertTrue(lines.contains("label,counted,touches_edge,small,area_px,centroid_x_px,centroid_y_px,length_px,width_px,angle_deg,length_nm,width_nm,area_nm2"))
        XCTAssertEqual(lines.filter { !$0.hasPrefix("#") && !$0.hasPrefix("label,") }.count, 5)
    }

    // MARK: The owner

    /// Show Objects lands a report for the current settings; an edit makes it stale but keeps it; a newer run replaces it; the mask
    /// preview is the same compare. Red under: a stale report claimed current; the preview not following the settings.
    @MainActor func testTheOwnerLandsAReportAndKnowsWhenItIsStale() async throws {
        let image = CalibratedImage(width: Self.width, height: Self.height, pixels: Self.planted(), x: nil, y: nil, fileName: "p.dm4", source: "", voltage: nil)
        let analysis = ParticleAnalysis()
        XCTAssertFalse(analysis.isCurrent)
        await analysis.analyse(image: image).value
        XCTAssertEqual(analysis.report?.summary.total, 5)
        XCTAssertTrue(analysis.isCurrent); XCTAssertTrue(analysis.showsObjects)
        analysis.setSettings { $0.minimumArea = 400 }
        XCTAssertFalse(analysis.isCurrent, "the settings moved on")
        XCTAssertEqual(analysis.report?.summary.total, 5, "the old report stays on screen")
        await analysis.analyse(image: image).value
        XCTAssertTrue(analysis.isCurrent)
        XCTAssertEqual(analysis.report?.summary.counted, 0, "no ellipse reaches 400 pixels (they hold 280 to 320)")
        analysis.setSettings { $0.thresholdFraction = 7; $0.sigma = -1; $0.minimumArea = 0 }
        XCTAssertEqual(analysis.settings.thresholdFraction, 1); XCTAssertEqual(analysis.settings.sigma, 0); XCTAssertEqual(analysis.settings.minimumArea, 1)

        analysis.setPreviewsMask(true)
        analysis.setSettings { $0.thresholdFraction = 0.5 }
        await analysis.updatePreview(image: image)?.value
        let preview = try XCTUnwrap(analysis.maskPreview)
        XCTAssertEqual(preview.mask, try ParticleCompute.mask(pixels: image.pixels, width: Self.width, height: Self.height, range: 10...100, settings: analysis.settings).mask)
        analysis.setPreviewsMask(false)
        XCTAssertNil(analysis.maskPreview)
        analysis.reset()
        XCTAssertNil(analysis.report); XCTAssertFalse(analysis.showsObjects)
    }

    @MainActor func testAnImageWithNothingFiniteSetsTheFailure() async {
        let image = CalibratedImage(width: 2, height: 1, pixels: [.nan, .nan], x: nil, y: nil, fileName: "n.dm4", source: "", voltage: nil)
        let analysis = ParticleAnalysis()
        await analysis.analyse(image: image).value
        XCTAssertEqual(analysis.failure, "The image holds no finite value to threshold.")
        XCTAssertNil(analysis.report); XCTAssertFalse(analysis.isComputing)
    }
}
