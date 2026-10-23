//
//  ImageMeasurementTests.swift
//  Distance and angle (archive: roadmap-registrations-2026-10-15.md V1-5) on planted points with closed-form truth: a 3-4-5 triangle in anisotropic pixels,
//  an angle that is right in the physical plane and not in pixel space, and the refusals (no calibration, two units,
//  a zero arm). The parity at 1e-12 on generated cases is tools/parity/profile-parity.
//

import ImagoCore
import XCTest
import TEMCore

nonisolated final class ImageMeasurementTests: XCTestCase {
    // Pixels 0.5 nm wide (x, columns) and 0.8 nm high (y, rows).
    private let nmX = AxisCalibration(scale: 0.5, unit: "nm", origin: 0)
    private let nmY = AxisCalibration(scale: 0.8, unit: "nm", origin: 0)

    private func point(row: Double, col: Double) -> ImagePoint { ImagePoint(x: col, y: row) }

    func testAThreeFourFiveInAnisotropicPixelsIsFiveNanometres() {
        // 6 columns at 0.5 nm = 3 nm, 5 rows at 0.8 nm = 4 nm: the hypotenuse is 5 nm and √61 px.
        let d = ImageMeasurement.distance(point(row: 0, col: 0), point(row: 5, col: 6), x: nmX, y: nmY)
        XCTAssertEqual(try XCTUnwrap(d.physical), 5, accuracy: 5e-12)
        XCTAssertEqual(d.unit, "nm")
        XCTAssertEqual(d.pixels, 61.0.squareRoot(), accuracy: 1e-12)
        // From the other end, off the origin: a distance has no direction.
        let back = ImageMeasurement.distance(point(row: 12.5, col: 30), point(row: 7.5, col: 24), x: nmX, y: nmY)
        XCTAssertEqual(try XCTUnwrap(back.physical), 5, accuracy: 5e-12)
    }

    func testWithoutACalibrationTheLengthIsPixelsOnly() {
        let a = point(row: 0, col: 0), b = point(row: 5, col: 6)
        for (x, y) in [(nil, nil), (nmX, nil), (nil, nmY),
                       (AxisCalibration(scale: 0.5, unit: "", origin: 0), nmY),       // a scale without a unit
                       (AxisCalibration(scale: 0, unit: "nm", origin: 0), nmY)] as [(AxisCalibration?, AxisCalibration?)] {
            let d = ImageMeasurement.distance(a, b, x: x, y: y)
            XCTAssertNil(d.physical)
            XCTAssertNil(d.unit)
            XCTAssertEqual(d.pixels, 61.0.squareRoot(), accuracy: 1e-12)
        }
    }

    func testAxesInDifferentUnitsGivePixelsOnly() {
        let d = ImageMeasurement.distance(point(row: 0, col: 0), point(row: 5, col: 6), x: nmX,
                                          y: AxisCalibration(scale: 0.8, unit: "µm", origin: 0))
        XCTAssertNil(d.physical, "nm and µm cannot be added")
        XCTAssertNil(d.unit)
        XCTAssertEqual(d.pixels, 61.0.squareRoot(), accuracy: 1e-12)
    }

    func testAnAngleRightInThePhysicalPlaneIsNotRightInPixels() throws {
        // B = (row 20, col 18). A is 4 columns and 5 rows from B: (2, 4) nm. C is 16 columns back and 5 rows on: (−8, 4) nm.
        // (2, 4)·(−8, 4) = 0, so the angle is 90° in nanometres; in pixels (4, 5)·(−16, 5) = −39 and it is 111.3°.
        let b = point(row: 20, col: 18), a = point(row: 25, col: 22), c = point(row: 25, col: 2)
        let physical = try XCTUnwrap(ImageMeasurement.angle(a, vertex: b, c, x: nmX, y: nmY))
        XCTAssertEqual(physical.degrees, 90, accuracy: 1e-12 * 90)
        XCTAssertEqual(physical.plane, .physical)
        let inPixels = try XCTUnwrap(ImageMeasurement.angle(a, vertex: b, c, x: nil, y: nil))
        XCTAssertEqual(inPixels.degrees, acos(-39 / (41.0.squareRoot() * 281.0.squareRoot())) * 180 / .pi, accuracy: 1e-9)
        XCTAssertEqual(inPixels.plane, .pixel, "uncalibrated: the pixel grid, and it says so")
        XCTAssertGreaterThan(inPixels.degrees, 111)
        let mixed = try XCTUnwrap(ImageMeasurement.angle(a, vertex: b, c, x: nmX,
                                                         y: AxisCalibration(scale: 0.8, unit: "µm", origin: 0)))
        XCTAssertEqual(mixed.plane, .pixel, "two units: no physical plane")
        XCTAssertEqual(mixed.degrees, inPixels.degrees, accuracy: 1e-12)
    }

    func testTheAnglesOfTheThreeFourFiveTriangle() throws {
        // Vertices B = (0, 0), A = 6 columns along (3 nm), C = 5 rows down (4 nm): right angle at B, atan(4/3) at A, atan(3/4) at C.
        let b = point(row: 0, col: 0), a = point(row: 0, col: 6), c = point(row: 5, col: 0)
        let atB = try XCTUnwrap(ImageMeasurement.angle(a, vertex: b, c, x: nmX, y: nmY)).degrees
        let atA = try XCTUnwrap(ImageMeasurement.angle(b, vertex: a, c, x: nmX, y: nmY)).degrees
        let atC = try XCTUnwrap(ImageMeasurement.angle(a, vertex: c, b, x: nmX, y: nmY)).degrees
        XCTAssertEqual(atB, 90, accuracy: 1e-12 * 90)
        XCTAssertEqual(atA, atan(4.0 / 3.0) * 180 / .pi, accuracy: 1e-12 * 53.13)
        XCTAssertEqual(atC, atan(3.0 / 4.0) * 180 / .pi, accuracy: 1e-12 * 36.87)
        XCTAssertEqual(atA + atB + atC, 180, accuracy: 1e-12 * 180)
    }

    func testStraightAndFoldedBackArmsAreZeroAndOneEightyDegrees() throws {
        let b = point(row: 4, col: 4)
        let same = try XCTUnwrap(ImageMeasurement.angle(point(row: 4, col: 9), vertex: b, point(row: 4, col: 6), x: nmX, y: nmY))
        let straight = try XCTUnwrap(ImageMeasurement.angle(point(row: 4, col: 9), vertex: b, point(row: 4, col: 1), x: nmX, y: nmY))
        XCTAssertEqual(same.degrees, 0)
        XCTAssertEqual(straight.degrees, 180)
    }

    func testTwoAlmostParallelArmsKeepTheirTinyAngle() throws {
        // An angle of 1e-9 rad: acos(dot / (|u||v|)) rounds the ratio to 1 and says 0 (or 1e-8); atan2(|cross|, dot) is exact.
        let delta = 1e-9
        let b = point(row: 0, col: 0)
        let a = point(row: 0, col: 1000)
        let c = point(row: 1000 * sin(delta), col: 1000 * cos(delta))
        let angle = try XCTUnwrap(ImageMeasurement.angle(a, vertex: b, c, x: nil, y: nil)).degrees
        XCTAssertEqual(angle, delta * 180 / .pi, accuracy: 1e-12 * delta * 180 / .pi)
    }

    func testTwoLongNearlyParallelArmsDoNotLoseTheirDigitsToCancellation() throws {
        // u = (123456789, 987654321), v = 2u + (1, 0): cross = -u_y exactly, dot = 2|u|² + u_x, an angle of 4e-9 rad. Each
        // product of the plain cross u_x·v_y − u_y·v_x is about 2.4e17, beyond 2^53, so the plain difference is off by tens
        // against 1e9 (3e-8 relative); the fused form keeps it to 1e-16.
        let ux = 123456789.0, uy = 987654321.0
        let a = ImagePoint(x: ux, y: uy), c = ImagePoint(x: 2 * ux + 1, y: 2 * uy)
        let angle = try XCTUnwrap(ImageMeasurement.angle(a, vertex: ImagePoint(x: 0, y: 0), c, x: nil, y: nil)).degrees
        let want = atan2(uy, 2 * (ux * ux + uy * uy) + ux) * 180 / .pi
        XCTAssertEqual(angle, want, accuracy: 1e-12 * want)
    }

    func testAnArmOfZeroLengthHasNoAngle() {
        let b = point(row: 3, col: 3), c = point(row: 8, col: 1)
        XCTAssertNil(ImageMeasurement.angle(b, vertex: b, c, x: nmX, y: nmY), "A on B")
        XCTAssertNil(ImageMeasurement.angle(c, vertex: b, b, x: nmX, y: nmY), "C on B")
        XCTAssertNil(ImageMeasurement.angle(b, vertex: b, b, x: nil, y: nil))
        let zero = ImageMeasurement.distance(b, b, x: nmX, y: nmY)
        XCTAssertEqual(zero.pixels, 0)
        XCTAssertEqual(zero.physical, 0)
    }

    func testAnImagePointIsColumnThenRowAndRoundTripsThroughJSON() throws {
        let p = ImagePoint(x: 3.5, y: -2.25)
        XCTAssertEqual(p.x, 3.5, "x is the column")
        XCTAssertEqual(p.y, -2.25, "y is the row")
        let decoded = try JSONDecoder().decode(ImagePoint.self, from: JSONEncoder().encode(p))
        XCTAssertEqual(decoded, p)
        XCTAssertEqual(Set([p, decoded]).count, 1)
    }

    /// An axis with no usable scale is uncalibrated whichever axis it is (Gate B 2026-10-13: only x's were tested). Red
    /// under: `y.isCalibrated` dropped from `physicalScales`.
    func testAnAxisWithNoUsableScaleIsNotCalibratedWhicheverAxisItIs() {
        let nm = AxisCalibration(scale: 0.5, unit: "nm", origin: 0)
        let a = ImagePoint(x: 0, y: 0), b = ImagePoint(x: 6, y: 5)
        for bad in [0.0, -0.8, .nan, .infinity] {
            let axis = AxisCalibration(scale: bad, unit: "nm", origin: 0)
            XCTAssertNil(ImageMeasurement.distance(a, b, x: nm, y: axis).physical, "y \(bad)")
            XCTAssertNil(ImageMeasurement.distance(a, b, x: axis, y: nm).physical, "x \(bad)")
        }
    }
}
