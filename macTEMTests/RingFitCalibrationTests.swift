//
//  RingFitCalibrationTests.swift
//  archive: roadmap-registrations-2026-10-15.md "Diffraction S3, Camera length from one ring of known d", slice S3-b: the fit-driven calibration
//  (`RingCalibration.fit`) on rings planted here, in Swift, with their truth known. No Python at run time; the many-plant
//  tiers and their distributions are tools/parity/ring-calibration-parity's fit stage.
//
//  The plant is the one tools/parity/ring-fit-parity's plants.py draws (and tools/parity/ellipse-parity's before it): a
//  Gaussian ring on an elliptical coordinate, I = exp(−((ρ − 1) R)² / 2s²), ρ² = u²/a² + v²/b² in the frame rotated by
//  θ, R = (a + b)/2 — inside the asymmetric-Gaussian model's family (σ_in = σ_out = s, no central disc, no background).
//  Rows are the fit's "qx", columns its "qy"; the centre is off the grid and its row differs from its column.
//
//  Every test names under "RED UNDER" the production mutation that turns it red.
//

import XCTest
import DiffractoGeometry
// swiftformat:disable:next duplicateImports
import struct DiffractoGeometry.DiffractionPattern
nonisolated final class RingFitCalibrationTests: XCTestCase {

    // MARK: The plant

    private struct Plant {
        let rows: Int, cols: Int
        let row0: Double, col0: Double
        let a: Double, b: Double, theta: Double
        let sigma: Double
        var radius: Double { (a + b) / 2 }
    }

    /// The ring, float32, rows × columns with columns fastest; `gapDegrees` cuts the signal over that azimuth (measured
    /// from the row axis towards the column axis) starting at `gapStart`.
    private static func render(_ p: Plant, gapDegrees: Double = 0, gapStart: Double = 0) -> DiffractionPattern {
        var pixels = [Float](repeating: 0, count: p.rows * p.cols)
        let s = sin(p.theta), c = cos(p.theta)
        for r in 0..<p.rows {
            for col in 0..<p.cols {
                let dr = Double(r) - p.row0, dc = Double(col) - p.col0
                if gapDegrees > 0 {
                    var angle = atan2(dc, dr) * 180 / .pi
                    if angle < 0 { angle += 360 }
                    var offset = (angle - gapStart).truncatingRemainder(dividingBy: 360)
                    if offset < 0 { offset += 360 }
                    if offset < gapDegrees { continue }
                }
                let u = dr * c + dc * s, v = -dr * s + dc * c
                let rho = ((u / p.a) * (u / p.a) + (v / p.b) * (v / p.b)).squareRoot()
                let x = (rho - 1) * p.radius
                pixels[r * p.cols + col] = Float(exp(-x * x / (2 * p.sigma * p.sigma)))
            }
        }
        return DiffractionPattern(width: p.cols, height: p.rows, pixels: pixels)
    }

    /// 2 % ellipticity (a/b = 1.02), the major axis at 35° from the rows, R = 60 px, s = 2.5 px; centre (81.31, 77.73).
    private static let plant: Plant = {
        let radius = 60.0, epsilon = 0.02
        let b = 2 * radius / (2 + epsilon)
        return Plant(rows: 160, cols: 156, row0: 81.31, col0: 77.73, a: b * (1 + epsilon), b: b,
                     theta: 35 * .pi / 180, sigma: 2.5)
    }()

    /// The annulus (b − 15, a + 15) about a start centre a click away from the plant's, (+1.3, −0.9) px.
    private static func fit(_ pattern: DiffractionPattern, _ p: Plant = plant, d: Double = auD220,
                            volts: Double? = 200_000, pitchMM: Double? = 0.1) throws -> RingFitCalibration {
        try RingCalibration.fit(pattern: pattern, centerQX: p.row0 + 1.3, centerQY: p.col0 - 0.9,
                                innerRadius: p.b - 15, outerRadius: p.a + 15,
                                d: d, highTensionVolts: volts, pixelPitchMM: pitchMM)
    }

    /// Au {220}: a/√8 with a = 4.0782 Å (Diffraction S1's lattice constant).
    private static let auD220 = 4.0782 / 8.0.squareRoot()

    // MARK: A clean ring

    /// The planted ring calibrates to its own Δq and L within the registered 0.1 %, its centre within 0.05 px, and the
    /// whole chain is the closed forms of S3-a applied to the fitted radius.
    /// RED UNDER: the radius handed to `calibrate` taken as `fit.a` (1.0 % off at 2 % ellipticity); the d argument
    /// ignored for a fixed one. (Swapping the START centre's row and column is not caught: the fit converges from that
    /// 5 px-off start to the same ring; measured 2026-10-13.)
    func testAPlantedRingCalibratesToItsTruth() throws {
        let p = Self.plant
        let result = try Self.fit(Self.render(p))
        XCTAssertEqual(result.refusals, [])
        let fit = try XCTUnwrap(result.fit)
        XCTAssertEqual(fit.model, .asymmetricGaussian)
        XCTAssertEqual(fit.centerQX, p.row0, accuracy: 0.05, "the row")
        XCTAssertEqual(fit.centerQY, p.col0, accuracy: 0.05, "the column")
        let calibration = try XCTUnwrap(result.calibration)
        let truth = try RingCalibration.calibrate(radius: p.radius, d: Self.auD220, highTensionVolts: 200_000,
                                                  pixelPitchMM: 0.1)
        XCTAssertEqual(calibration.deltaQ / truth.deltaQ - 1, 0, accuracy: 1e-3, "Δq")
        XCTAssertEqual(try XCTUnwrap(calibration.lengthPixels) / XCTUnwrap(truth.lengthPixels) - 1, 0, accuracy: 1e-3)
        XCTAssertEqual(try XCTUnwrap(calibration.lengthMillimetres) / XCTUnwrap(truth.lengthMillimetres) - 1, 0,
                       accuracy: 1e-3)
        XCTAssertEqual(calibration.d, Self.auD220)
        XCTAssertEqual(calibration.highTensionVolts, 200_000)
    }

    /// The report the refusals are decided on carries the fit's own numbers and the annulus it was given, and the
    /// calibration's radius is the report's (a + b)/2 to the last bit.
    /// RED UNDER: the annulus width taken as the outer radius; the sigmas not copied from the profile (nil); the radius
    /// taken as one axis.
    func testTheReportCarriesTheFitAndTheAnnulus() throws {
        let p = Self.plant
        let result = try Self.fit(Self.render(p))
        let fit = try XCTUnwrap(result.fit)
        let report = try XCTUnwrap(result.report)
        XCTAssertEqual(report.model, fit.model)
        XCTAssertEqual(report.semiAxisA, fit.a)
        XCTAssertEqual(report.semiAxisB, fit.b)
        XCTAssertEqual(report.occupiedAngularBins, fit.occupiedAngularBins)
        XCTAssertEqual(report.sparseCoverage, fit.sparseCoverage)
        XCTAssertEqual(report.normalizedResidual, fit.normalizedResidual)
        XCTAssertEqual(report.innerSigma, fit.profile?.innerSigma)
        XCTAssertEqual(report.outerSigma, fit.profile?.outerSigma)
        XCTAssertNotNil(report.innerSigma)
        XCTAssertEqual(report.annulusWidth, (p.a + 15) - (p.b - 15))
        XCTAssertEqual(try XCTUnwrap(result.calibration).radius, (fit.a + fit.b) / 2)
    }

    // MARK: Refusals through the fit

    /// No high tension: Δq is given, L is not, and the one refusal is `noHighTension`.
    /// RED UNDER: a missing V defaulted to 200 kV.
    func testWithoutAHighTensionOnlyDeltaQIsGiven() throws {
        let result = try Self.fit(Self.render(Self.plant), volts: nil)
        XCTAssertEqual(result.refusals.map(\.name), ["noHighTension"])
        let calibration = try XCTUnwrap(result.calibration)
        XCTAssertNil(calibration.highTensionVolts)
        XCTAssertNil(calibration.lengthPixels)
        XCTAssertNil(calibration.lengthMillimetres)
        XCTAssertEqual(calibration.lengthRefusal, .noHighTension)
        XCTAssertEqual(calibration.deltaQ * Self.plant.radius * Self.auD220, 1, accuracy: 1e-3)
    }

    /// A ring with a 120° gap (24 of 36 bins) is refused by its coverage, by name and with its bin count, and nothing is
    /// calibrated from it; the fit's own refusal is not thrown at the caller as an error.
    /// RED UNDER: the coverage error rethrown instead of reported; the fit run with `acceptSparseCoverage: true` (Δq is
    /// still withheld, by `refusals`' own bin bound, but a fit comes back).
    func testAGappedRingIsRefusedByItsCoverage() throws {
        let result = try Self.fit(Self.render(Self.plant, gapDegrees: 120, gapStart: 10))
        XCTAssertEqual(result.refusals.map(\.name), ["insufficientAngularCoverage"])
        guard case .insufficientAngularCoverage(let bins) = try XCTUnwrap(result.refusals.first) else {
            return XCTFail("not a coverage refusal")
        }
        XCTAssertLessThan(bins, RingCalibration.minimumOccupiedAngularBins)
        XCTAssertGreaterThanOrEqual(bins, 22)
        XCTAssertNil(result.fit)
        XCTAssertNil(result.report)
        XCTAssertNil(result.calibration)
    }

    /// The refusals are listed whole on the coverage path too: a gapped ring with no high tension is refused for both,
    /// coverage first.
    /// RED UNDER: `noHighTension` not appended when the fit refuses the coverage.
    func testTheCoveragePathListsEveryRefusal() throws {
        let result = try Self.fit(Self.render(Self.plant, gapDegrees: 120, gapStart: 10), volts: nil)
        XCTAssertEqual(result.refusals.map(\.name), ["insufficientAngularCoverage", "noHighTension"])
        XCTAssertNil(result.calibration)
    }

    /// A ring the fit finds but whose a/b − 1 is past 0.093 (12 % planted) is refused by name and nothing is calibrated
    /// from it, though Δq could be computed.
    /// RED UNDER: the calibration computed whatever the refusals say (the guard on `withholdsDeltaQ` removed).
    func testAnEllipticRingIsRefusedAndNotCalibrated() throws {
        let radius = 60.0, epsilon = 0.12
        let b = 2 * radius / (2 + epsilon)
        let p = Plant(rows: 172, cols: 168, row0: 86.41, col0: 83.62, a: b * (1 + epsilon), b: b,
                      theta: 70 * .pi / 180, sigma: 2.5)
        let result = try Self.fit(Self.render(p), p)
        XCTAssertNotNil(result.fit)
        XCTAssertTrue(result.refusals.map(\.name).contains("excessiveEllipticity"), "\(result.refusals.map(\.name))")
        XCTAssertNil(result.calibration)
    }

    /// An empty pattern is not a refusal of a ring but no ring at all: the fit's error reaches the caller.
    /// RED UNDER: every fit error swallowed into an empty result.
    func testAnEmptyPatternThrowsTheFitsError() {
        let p = Self.plant
        let empty = DiffractionPattern(width: p.cols, height: p.rows, pixels: [Float](repeating: 0, count: p.rows * p.cols))
        XCTAssertThrowsError(try Self.fit(empty)) { error in
            XCTAssertEqual(error as? EllipseCalibration.FitError, .insufficientSignal)
        }
    }

    /// The d, V and pitch are checked before any fit runs: an impossible one is the caller's mistake, by name.
    /// RED UNDER: the inputs checked only after the fit (an empty pattern would then throw the fit's error instead).
    func testAnInvalidInputIsRefusedBeforeTheFit() {
        let p = Self.plant
        let empty = DiffractionPattern(width: p.cols, height: p.rows, pixels: [Float](repeating: 0, count: p.rows * p.cols))
        for (d, volts, pitch) in [(-1.0, 200_000.0, 0.1), (1.44, -5.0, 0.1), (1.44, 200_000.0, .nan)] as [(Double, Double?, Double?)] {
            XCTAssertThrowsError(try Self.fit(empty, d: d, volts: volts, pitchMM: pitch)) { error in
                XCTAssertEqual((error as? RingCalibration.Refusal)?.name, "invalidInput", "d \(d) V \(String(describing: volts))")
            }
        }
    }
}
