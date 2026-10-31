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
import ImagoFilters
import TEMCore
import TEMSession
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
        XCTAssertEqual(report.objects.count, 4, "the 1-px object is below the minimum area and removed")
        XCTAssertEqual(report.summary.total, 5)
        XCTAssertEqual(report.summary.counted, 3)
        XCTAssertEqual(report.summary.edge, 1)
        XCTAssertEqual(report.summary.small, 1)
        XCTAssertEqual(report.summary.counted + report.summary.edge + report.summary.small, report.summary.total)
        XCTAssertEqual(report.thresholdValue, 55, accuracy: 1e-4, "half of the range 10 to 100")

        XCTAssertFalse(report.objects.contains { $0.moments.area == 1 })
        XCTAssertFalse(report.labels.labels[5 * Self.width + 5] > 0, "removed from the labels too")
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
        XCTAssertEqual(try ParticleCompute.analyse(pixels: px, width: Self.width, height: Self.height, settings: high).summary.total, 5, "100 is above 0.99 of the range")
        high.thresholdFraction = 1
        let none = try ParticleCompute.analyse(pixels: px, width: Self.width, height: Self.height, settings: high)
        XCTAssertTrue(none.objects.isEmpty, "nothing exceeds the maximum")
        var strict = ParticleSettings(); strict.minimumArea = 30
        let removed = try ParticleCompute.analyse(pixels: px, width: Self.width, height: Self.height, settings: strict).summary
        XCTAssertEqual(removed.small, 2, "the 1-px object and the 24-px edge block are below 30 px and removed")
        XCTAssertEqual(removed.edge, 0)
        XCTAssertEqual(removed.counted, 3)
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
        XCTAssertEqual(lines.filter { !$0.hasPrefix("#") && !$0.hasPrefix("label,") }.count, 4)
        XCTAssertTrue(lines.contains("# areal density: none (the image is not calibrated)"), "no pixel size was given")
    }

    /// The CSV keeps its `small` column in fourth place, so a script that reads the columns by position still works: every listed object is 0 there
    /// (objects below the minimum area are removed before labelling; the summary line counts them). Red under: the column dropped.
    func testTheCSVKeepsTheSmallColumn() throws {
        let report = try ParticleCompute.analyse(pixels: Self.planted(), width: Self.width, height: Self.height, settings: ParticleSettings())
        let lines = ParticleFormat.csv(report, scale: ParticleScale(perPixel: 0.5, unit: "nm"), fileName: "p.dm4").split(separator: "\n").map(String.init)
        let header = try XCTUnwrap(lines.first { $0.hasPrefix("label,") }).split(separator: ",").map(String.init)
        XCTAssertEqual(Array(header.prefix(5)), ["label", "counted", "touches_edge", "small", "area_px"])
        let rows = lines.filter { !$0.hasPrefix("#") && !$0.hasPrefix("label,") }.map { $0.split(separator: ",").map(String.init) }
        XCTAssertEqual(rows.count, 4)
        for row in rows {
            XCTAssertEqual(row.count, header.count, row.joined(separator: ","))
            XCTAssertEqual(row[3], "0", "a listed object is never small")
        }
        XCTAssertTrue(lines.contains { $0.hasPrefix("# ") && $0.contains("1 small") }, "the removed object is counted in the summary line")
    }

    /// The CSV a script reads writes its numbers with a point whatever the shown numbers do (`ParticleFormat.csvNumber`, printf's `%.3g`): the
    /// threshold, smoothing and pixel-size lines go through it, never through the shown `number`, which follows the locale once the Particles
    /// view does. Red under: a CSV line written with `number(`.
    func testTheCSVNumbersArePointDecimal() throws {
        XCTAssertEqual(ParticleFormat.csvNumber(0.873), "0.873")
        XCTAssertEqual(ParticleFormat.csvNumber(10 + 90.0 / 512), "10.2")
        var s = ParticleSettings(); s.method = .otsu; s.sigma = 1.5
        let report = try ParticleCompute.analyse(pixels: Self.planted(), width: Self.width, height: Self.height, settings: s)
        let csv = ParticleFormat.csv(report, scale: ParticleScale(perPixel: 0.25, unit: "nm"), fileName: "p.dm4")
        XCTAssertTrue(csv.contains("smoothing sigma 1.5 px"), csv)
        XCTAssertTrue(csv.contains("pixel size 0.25 nm/px"), csv)
        // The CSV's own functions call no shown-number formatter.
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/TEMCore/Particles/ParticleCompute.swift"), encoding: .utf8)
        let csvPart = try XCTUnwrap(source.range(of: "package static func threshold(_ r: ParticleReport)").map { String(source[$0.lowerBound...]) })
        XCTAssertNil(csvPart.range(of: #"(?<![A-Za-z])number\("#, options: .regularExpression), "a CSV line uses the shown number formatter")
    }

    // MARK: Otsu, minimum area and density (ImagoKit 0.8.0)

    /// Otsu's level is ImagoKit's on the pixels the mask is cut from: on the two-level planted image the first bin past the background
    /// (10 + half a bin of 90/256) separates the ellipses exactly; the CSV says which threshold. Red under: the method ignored (55).
    func testOtsuChoosesTheLevelFromThePixels() throws {
        var s = ParticleSettings(); s.method = .otsu
        let report = try ParticleCompute.analyse(pixels: Self.planted(), width: Self.width, height: Self.height, settings: s)
        XCTAssertEqual(report.thresholdValue, 10 + 90.0 / 512, accuracy: 1e-4)
        XCTAssertEqual(report.thresholdValue, Float(try Thresholding.otsu(.float32(Self.planted()))), "the kit's number")
        XCTAssertEqual(report.summary.counted, 3)
        let csv = ParticleFormat.csv(report, scale: ParticleScale(perPixel: 1, unit: "px"), fileName: "p.dm4")
        XCTAssertTrue(csv.contains("Otsu (ImagoKit Thresholding.otsu, 256 bins) = 10.2"), csv)
        // Smoothed, Otsu reads the smoothed pixels (a level inside their narrower range).
        s.sigma = 2
        let smoothed = try ParticleCompute.analyse(pixels: Self.planted(), width: Self.width, height: Self.height, settings: s)
        let data = try ParticleCompute.smoothed(Self.planted(), width: Self.width, height: Self.height, sigma: 2, low: 10)
        XCTAssertEqual(smoothed.thresholdValue, Float(try Thresholding.otsu(.float32(data))))
    }

    /// The areal density is ImagoKit's Miles–Lantuéjoul density of the counted objects, per the scale's unit squared, and nil without a
    /// pixel size. Three counted ellipses in 100 × 80 px at 0.5 nm/px: 3 / 2000 nm² before the edge weights, which only raise it.
    /// Red under: the pixel size not passed (nil); the edge block counted; the density over the found labels before the small removal.
    func testTheArealDensityIsTheKitsOverTheCountedObjects() throws {
        let report = try ParticleCompute.analyse(pixels: Self.planted(), width: Self.width, height: Self.height,
                                                 settings: ParticleSettings(), pixelSize: 0.5)
        let kit = try ObjectStatistics.arealDensity(labels: report.labels, pixelSize: 0.5)
        let density = try XCTUnwrap(report.summary.arealDensity)
        XCTAssertEqual(density, try XCTUnwrap(kit.arealDensity))
        XCTAssertGreaterThan(density, 3.0 / 2000)
        // Σ of the three counted objects' edge weights over the frame of 100 × 80 px at 0.25 nm² each.
        let weights = try report.objects.filter(\.isCounted).map { try ObjectStatistics.edgeWeight($0.moments, frameWidth: Self.width, frameHeight: Self.height) }
        XCTAssertEqual(weights.count, 3)
        XCTAssertEqual(density, weights.reduce(0, +) / (Double(Self.width * Self.height) * 0.25), accuracy: 1e-15)
        XCTAssertEqual(ParticleFormat.density(report.summary, scale: ParticleScale(perPixel: 0.5, unit: "nm")),
                       "areal density \(ParticleFormat.number(density)) /nm² (edge-corrected)")
        let csv = ParticleFormat.csv(report, scale: ParticleScale(perPixel: 0.5, unit: "nm"), fileName: "p.dm4")
        XCTAssertTrue(csv.contains("# areal density: \(String(format: "%.6g", density)) per nm^2"), csv)
        let uncalibrated = try ParticleCompute.analyse(pixels: Self.planted(), width: Self.width, height: Self.height, settings: ParticleSettings())
        XCTAssertNil(uncalibrated.summary.arealDensity)
        XCTAssertEqual(ParticleFormat.density(uncalibrated.summary, scale: ParticleScale(perPixel: 1, unit: "px")),
                       "No areal density: the image is not calibrated.")
    }

    /// The owner passes the image's pixel size: a calibrated image's report has a density, an uncalibrated one's none.
    /// Red under: `ParticleAnalysis.analyse` not passing the scale.
    @MainActor func testTheOwnersReportHasADensityForACalibratedImage() async throws {
        let axis = AxisCalibration(scale: 0.5, unit: "nm")
        let image = CalibratedImage(width: Self.width, height: Self.height, pixels: Self.planted(), x: axis, y: axis, fileName: "p.dm4", source: "", voltage: nil)
        let analysis = ParticleAnalysis()
        await analysis.analyse(image: image).value
        XCTAssertNotNil(try XCTUnwrap(analysis.report).summary.arealDensity)
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
