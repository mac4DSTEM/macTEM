import ImagoCore
import XCTest
import DiffractoGeometry
import TEMCore

/// The Diffraction room's reciprocal scale (R3; R4's radius; R5), pinned to tools/parity/diffraction-room-parity's 60-digit
/// decimal values for Au {111} at 200 kV, calibrated on a ring of radius 80 px at a 0.014 mm pixel (L_px 7510.403862920632,
/// lambda 0.025079340450548004 A, dq 0.005308870358150892 per px). The 320-case sweep is the harness (R3, R4, R5).
/// Every pinned constant (L_px, lambda, dq, q, linear products) is the case 'Au111-200kV-R80-p0.014' of reference.json written by tools/parity/diffraction-room-parity/reference.py (numpy 2.5.4, 60-digit decimal chain; no Swift output), not Swift output.
nonisolated final class RingScaleTests: XCTestCase {

    private static let d = 2.3545498678091317

    private static func calibration(volts: Double?) throws -> RingCalibration {
        try RingCalibration.calibrate(radius: 80, d: d, highTensionVolts: volts, pixelPitchMM: 0.014)
    }

    private func relative(_ x: Double, _ truth: Double) -> Double { abs(x - truth) / abs(truth) }

    /// q(R) from the calibration, 1e-12 relative against the decimal values. Red under: small-angle R/L, no half, V in kV, 2 pi.
    func testQOfRadiusMatchesPinnedClosedForm() throws {
        let cal = try Self.calibration(volts: 200_000)
        XCTAssertEqual(try XCTUnwrap(cal.lengthPixels), 7510.403862920632, accuracy: 1e-8)
        for (r, q) in [(40.0, 0.212361590534106), (250.0, 1.3267229535638139), (1000.0, 5.274199055260843), (2000.0, 10.348102771875826)] {
            XCTAssertLessThan(relative(RingScale.q(radius: r, calibration: cal), q), 1e-12, "R \(r)")
        }
    }

    /// The calibrating ring returns 1/d. Red under: 2 pi, no half.
    func testCalibratingRingReturnsInverseD() throws {
        let cal = try Self.calibration(volts: 200_000)
        XCTAssertLessThan(relative(RingScale.q(radius: 80, calibration: cal), 1 / Self.d), 1e-12)
    }

    /// R -> q -> R returns the radius within 1e-9 px up to R 2000, and the pinned radii come back from the pinned |q|.
    func testRadiusOfQRoundTripsAndMatchesPinned() throws {
        let cal = try Self.calibration(volts: 200_000)
        for r in [40.0, 100, 250, 500, 1000, 2000] {
            XCTAssertEqual(RingScale.radius(q: RingScale.q(radius: r, calibration: cal), calibration: cal), r, accuracy: 1e-9)
        }
        XCTAssertLessThan(relative(RingScale.radius(q: 1.3267229535638139, calibration: cal), 250), 1e-12)
    }

    /// With no beam energy the calibration has only dq and q = dq R, one multiplication, bit for bit. Red under: the linear form used
    /// though V is known (differs from the exact form by 3.7e-4 at R 250 here).
    func testWithoutBeamEnergyQIsDeltaQTimesR() throws {
        let cal = try Self.calibration(volts: nil)
        XCTAssertNil(cal.lengthPixels)
        XCTAssertEqual(cal.deltaQ, 0.005308870358150892)
        XCTAssertEqual(RingScale.q(radius: 250, calibration: cal), cal.deltaQ * 250)
        XCTAssertEqual(RingScale.q(radius: 250, calibration: cal), 1.327217589537723)
        XCTAssertEqual(RingScale.radius(q: 1.327217589537723, calibration: cal), 250, accuracy: 1e-9)
        let withV = try Self.calibration(volts: 200_000)
        XCTAssertGreaterThan(relative(RingScale.q(radius: 250, calibration: cal), RingScale.q(radius: 250, calibration: withV)), 3e-4)
    }

    /// Not a finite positive number is NaN, never 0 or infinity; past the detector's Bragg limit the radius is NaN.
    func testInvalidInputsAndTheBraggLimitAreNaN() throws {
        let cal = try Self.calibration(volts: 200_000)
        for bad in [0.0, -1, .nan, .infinity, -.infinity] {
            XCTAssertTrue(RingScale.q(radius: bad, calibration: cal).isNaN, "R \(bad)")
            XCTAssertTrue(RingScale.radius(q: bad, calibration: cal).isNaN, "q \(bad)")
        }
        let lambda = try XCTUnwrap(cal.wavelengthAngstroms)
        XCTAssertTrue(RingScale.radius(q: 1.5 / lambda, calibration: cal).isNaN)                           // lambda q / 2 = 0.75: 2 theta past 90 degrees
        XCTAssertTrue(RingScale.radius(q: 1.4 / lambda, calibration: cal).isFinite)                        // 0.70 < 1/sqrt 2: still on the detector
        XCTAssertTrue(RingScale.linear(radius: 5, deltaQ: 0).isNaN)
    }

    /// The file's scale in A^-1 per px: 1/nm x 0.1, A^-1 x 1, mrad needs the wavelength. Red under: x10, x2 pi, mrad accepted without lambda.
    func testFileScaleSpellingsAndUnits() {
        XCTAssertEqual(LengthUnit.reciprocalAngstromsPerPixel(scale: 0.25, unit: "1/nm", wavelengthAngstrom: nil), 0.025)
        XCTAssertEqual(LengthUnit.reciprocalAngstromsPerPixel(scale: 0.25, unit: " NM^-1 ", wavelengthAngstrom: nil), 0.025)
        XCTAssertEqual(LengthUnit.reciprocalAngstromsPerPixel(scale: 0.25, unit: "Å⁻¹", wavelengthAngstrom: nil), 0.25)
        XCTAssertEqual(LengthUnit.reciprocalAngstromsPerPixel(scale: 0.25, unit: "A^-1", wavelengthAngstrom: nil), 0.25)
        XCTAssertEqual(try XCTUnwrap(LengthUnit.reciprocalAngstromsPerPixel(scale: 1, unit: "mrad", wavelengthAngstrom: 0.0251)), 1 / (1000 * 0.0251), accuracy: 1e-15)
        XCTAssertNil(LengthUnit.reciprocalAngstromsPerPixel(scale: 1, unit: "mrad", wavelengthAngstrom: nil))
        XCTAssertNil(LengthUnit.reciprocalAngstromsPerPixel(scale: 0.25, unit: "px", wavelengthAngstrom: 0.0251))
        XCTAssertNil(LengthUnit.reciprocalAngstromsPerPixel(scale: 0.25, unit: nil, wavelengthAngstrom: 0.0251))
        XCTAssertNil(LengthUnit.reciprocalAngstromsPerPixel(scale: 0, unit: "1/nm", wavelengthAngstrom: nil))
        XCTAssertNil(LengthUnit.reciprocalAngstromsPerPixel(scale: .nan, unit: "1/nm", wavelengthAngstrom: nil))
    }

    /// dq_fit / dq_file - 1: 0.05 means the fit's scale is 5 % larger. Red under: the ratio inverted.
    func testFitVersusFileDifference() {
        XCTAssertEqual(RingScale.fitVersusFile(fitDeltaQ: 0.0105, fileDeltaQ: 0.01), 0.05, accuracy: 1e-15)
        XCTAssertEqual(RingScale.fitVersusFile(fitDeltaQ: 0.007, fileDeltaQ: 0.01), -0.3, accuracy: 1e-15)
        XCTAssertTrue(RingScale.fitVersusFile(fitDeltaQ: 0, fileDeltaQ: 0.01).isNaN)
        XCTAssertTrue(RingScale.fitVersusFile(fitDeltaQ: 0.01, fileDeltaQ: .nan).isNaN)
    }
}
