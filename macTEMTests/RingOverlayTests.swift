import XCTest
import DiffractoGeometry
import TEMCore

/// The Diffraction room's ring geometry (slice 1a, R1 and R4): a fitted ring in image coordinates (x = column, y = row), the polyline
/// the room draws, the ring predicted for another family, and the point-to-ellipse distance. Hand values; the planted-ring
/// comparison against the kit's fits is tools/parity/diffraction-room-parity (R1, R4), whose controls (xy-swap, ab-swap, theta-sign,
/// theta-deg, corner-offset, offsets-kept, image-centre) are the emulated forms of the mutations named in each test.
nonisolated final class RingOverlayTests: XCTestCase {

    private func fit(row: Double, column: Double, a: Double, b: Double, theta: Double) -> EllipseCalibrationFit {
        EllipseCalibrationFit(centerQX: row, centerQY: column, a: a, b: b, theta: theta, normalizedResidual: 0, conicResidual: 0,
                              sampleCount: 100, occupiedAngularBins: 36, model: .asymmetricGaussian, profile: nil, profileFallbackReason: nil)
    }

    /// The kit's centre is (qx = ROW, qy = COLUMN): x is the column. Red under: x and y swapped, a and b swapped, theta's sign, theta in degrees.
    func testEllipseOfFitTakesXFromTheColumnAndYFromTheRow() {
        let e = RingOverlay.ellipse(of: fit(row: 191.5, column: 260.25, a: 81.0, b: 79.0, theta: 0.5))
        XCTAssertEqual(e.x, 260.25)
        XCTAssertEqual(e.y, 191.5)
        XCTAssertEqual(e.a, 81.0)
        XCTAssertEqual(e.b, 79.0)
        XCTAssertEqual(e.theta, 0.5)
        XCTAssertEqual(e.radius, 80.0)
    }

    /// With theta 0 the first semi-axis runs along the ROW axis: the first point is (cx, cy + a), the quarter point (cx + b, cy).
    /// Red under: the polyline built with x and y swapped, a and b swapped.
    func testPolylineFirstSemiAxisRunsAlongTheRowAtThetaZero() {
        let points = RingOverlay.polyline(RingEllipse(x: 300, y: 200, a: 100, b: 60, theta: 0))
        XCTAssertEqual(points.count, 180)
        XCTAssertEqual(points[0].x, 300, accuracy: 1e-12)
        XCTAssertEqual(points[0].y, 300, accuracy: 1e-12)
        XCTAssertEqual(points[45].x, 360, accuracy: 1e-12)
        XCTAssertEqual(points[45].y, 200, accuracy: 1e-12)
        XCTAssertEqual(points[90].y, 100, accuracy: 1e-12)
    }

    /// Theta is measured from the row axis towards the column axis: at 90 degrees the first semi-axis lies along the column axis.
    /// Red under: theta's sign, theta in degrees.
    func testThetaTurnsTheMajorAxisFromTheRowTowardsTheColumn() {
        let points = RingOverlay.polyline(RingEllipse(x: 300, y: 200, a: 100, b: 60, theta: .pi / 2))
        XCTAssertEqual(points[0].x, 400, accuracy: 1e-12)
        XCTAssertEqual(points[0].y, 200, accuracy: 1e-12)
        let turned = RingOverlay.polyline(RingEllipse(x: 300, y: 200, a: 100, b: 60, theta: .pi / 6))
        XCTAssertEqual(turned[0].x, 350, accuracy: 1e-12)                       // 300 + 100 sin 30
        XCTAssertEqual(turned[0].y, 200 + 100 * 3.0.squareRoot() / 2, accuracy: 1e-12)
    }

    /// Every drawn point lies on the ellipse: the nearest-point distance is below 1e-9 px for a rotated, off-centre ellipse.
    /// Red under: a +0.5 px offset of the centre, a and b swapped inside the polyline.
    func testPolylinePointsLieOnTheEllipse() {
        let e = RingEllipse(x: 333.3, y: 222.2, a: 199, b: 193.2, theta: 0.75)
        for p in RingOverlay.polyline(e) {
            XCTAssertLessThan(RingOverlay.distance(fromX: p.x, y: p.y, to: e), 1e-9)
        }
    }

    /// Pinned distances: 0.5 px off the end of the first axis, the centre of a circle, a point on the ellipse.
    func testDistanceToEllipseHandValues() {
        let e = RingEllipse(x: 300, y: 200, a: 100, b: 60, theta: 0)
        XCTAssertEqual(RingOverlay.distance(fromX: 300, y: 300.5, to: e), 0.5, accuracy: 1e-12)
        XCTAssertEqual(RingOverlay.distance(fromX: 300, y: 299.5, to: e), 0.5, accuracy: 1e-12)
        let circle = RingEllipse(x: 50, y: 60, a: 40, b: 40, theta: 0.3)
        XCTAssertEqual(RingOverlay.distance(fromX: 50, y: 60, to: circle), 40, accuracy: 1e-9)
        XCTAssertTrue(RingOverlay.distance(fromX: .nan, y: 0, to: e).isNaN)
        XCTAssertTrue(RingOverlay.distance(fromX: 0, y: 0, to: RingEllipse(x: 0, y: 0, a: 0, b: 1, theta: 0)).isNaN)
    }

    /// The predicted ring keeps the centre, b/a and angle and scales both semi-axes by R2 / R1 (R1 = (a + b)/2). Red under: the offsets
    /// kept instead of scaled (a + (R2 - R1)), the image centre for the centre.
    func testPredictedRingScalesBothAxesAndKeepsCentreShapeAndAngle() throws {
        let ring = RingEllipse(x: 254.5, y: 196.75, a: 82, b: 78, theta: 0.75)
        let predicted = try XCTUnwrap(RingOverlay.predicted(from: ring, radius: 160))
        XCTAssertEqual(predicted.a, 164, accuracy: 1e-12)
        XCTAssertEqual(predicted.b, 156, accuracy: 1e-12)
        XCTAssertEqual(predicted.x, 254.5)
        XCTAssertEqual(predicted.y, 196.75)
        XCTAssertEqual(predicted.theta, 0.75)
        XCTAssertEqual(predicted.b / predicted.a, ring.b / ring.a, accuracy: 1e-15)
        for bad in [0.0, -5.0, .nan, .infinity] { XCTAssertNil(RingOverlay.predicted(from: ring, radius: bad)) }
        XCTAssertNil(RingOverlay.predicted(from: RingEllipse(x: 0, y: 0, a: 0, b: 0, theta: 0), radius: 10))
    }
}
