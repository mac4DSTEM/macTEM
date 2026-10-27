// macTEM's own since DiffractoKit 0.0.3 (ADR 025): ported from mac4DSTEM 7d6fdbd1's EllipseNoisyRingTests (the kit holds the same
// plants in its own EllipseNoisyRingTests); it runs the kit's fit in this app's Debug build, on this repo's 4 KB real-pattern fixture.
import XCTest
import DiffractoGeometry
@testable import macTEM

/// The profile ring fit (`EllipseCalibration.fitAmorphousRing`, behind the Fit
/// button's `fitBestAvailable`) is refined from py4DSTEM's start, both ring sigmas at
/// max(1, ringWidth / 4), 10-17 px for a +-20 px annulus around a 3 px ring. On a noisy
/// ring the 11-parameter LM from there can fall into a basin that carries no ring
/// information, and the residual cap does not refuse it: noise inflates the normalised
/// residual of any model (`archive/v5/ring-fit-two-start-gateD-2026-10-14.md`, and
/// `archive/v5/ring-sigma-start-gateD-2026-10-13.md` for the first step). A second start
/// at the ring's half-maximum width escapes those basins, but alone it ends in a worse
/// one on a 1/r^2 tail with noise. The fit therefore refines from both starts and keeps
/// the lower-cost fit.
///
/// The first two rings are noisy 192 x 192 plants on which py4DSTEM's start was accepted
/// wrong, found by scanning 2568 plants (128-256 px square, R 40-100, ellipticity 0-3 %,
/// a 60 degree gap or none, noise 0.03 and 0.10, a few seeds each; no data file) with
/// this same renderer: it accepted a profile fit off by more than 1 % in (a + b) / 2 on
/// 221 of them, all at noise 0.10 (92 at 192 px, 32 at 224, 97 at 256, none below 192);
/// 87 of the 221 are the dead ring (a ring sigma at its 0.25 px floor, I1 at 0), 130 the
/// drifting kind (ring sigmas of 1-7 px, the centre 10-40 px off), 4 neither. Both
/// outcomes are basins of the optimiser, not rounding accidents: the centre guess
/// moved by 1e-9, 1e-6 and 1e-3 px leaves the dead ring unchanged and moves the
/// drifting one's mean radius by 0.1 % of R.
///
/// The third ring has a 1/r^2 background (0.8 (R / r)^2 around the pattern centre, the
/// central beam's tail) under noise 0.10, and guards the other side: py4DSTEM's start is
/// right on it and a half-maximum start alone is not. Found by scanning 720 plants (192
/// px, R 60/65/70, ellipticity 1 and 3 %, theta 20 and 112.5, no gap, noise 0.05/0.10/0.15,
/// tail 0.4/0.8, seeds 0-9): py4DSTEM's start gave a profile fit within 0.1 % in (a + b) / 2
/// on 626, and the half-maximum start alone ended more than 1 % off on 10 of those 626 (all
/// tail 0.8, noise 0.10 or 0.15, mean radius +2.3 to +2.5 % with the ring's inner sigma
/// blown out to 37-132 px; none at tail 0.4). This plant is one of the ten (the centre
/// guess moved by 1e-9, 1e-6 and 1e-3 px changes neither start's outcome to three figures).
///
/// Neither fit may be refused or fall back to the conic: the profile model finds the
/// ring on all three, and the test asserts the ring's mean radius, its b / a (what the
/// app applies to every Bragg vector) and its centre, against the plant.
nonisolated final class EllipseNoisyRingTests: XCTestCase {
    /// I = exp(-((rho - 1) R)^2 / 2 s^2), rho the conic's elliptical radius in
    /// py4DSTEM's (A, B, C) convention with qx the row, s = 3 px, R = (a + b) / 2,
    /// a / b = 1 + eps, a along theta; optional 60 degree gap starting at (47 seed)
    /// mod 360 degrees; optional background tail * (R / max(r, 1))^2 with r the distance
    /// from the plant's centre (added after the gap); additive Gaussian noise (SplitMix64 seeded seed + 1,
    /// Box-Muller pairs over even and odd linear index), Float pixels.
    private struct Plant {
        let size: Int, radius: Double, eps: Double, thetaDegrees: Double, gap: Double, noise: Double, seed: Int
        /// Amplitude of the 1/r^2 background, 0 for none.
        var tail = 0.0
        var b: Double { 2 * radius / (2 + eps) }
        var a: Double { b * (1 + eps) }
        var centerQX: Double { Double(size) / 2 + 0.37 + 2.5 * sin(1.3 * Double(seed) + 0.2) }
        var centerQY: Double { Double(size) / 2 - 0.41 + 2.5 * cos(1.9 * Double(seed) + 0.7) }

        func render() -> DiffractionPattern {
            let theta = thetaDegrees * .pi / 180
            let sin2 = sin(theta) * sin(theta), cos2 = cos(theta) * cos(theta)
            let A = sin2 / (b * b) + cos2 / (a * a)
            let C = cos2 / (b * b) + sin2 / (a * a)
            let B = 2 * (b * b - a * a) * sin(theta) * cos(theta) / (a * a * b * b)
            let mean = (a + b) / 2
            let gapStart = Double((47 * seed) % 360)
            var state = UInt64(seed) &+ 1
            func uniform() -> Double {
                state &+= 0x9E37_79B9_7F4A_7C15
                var z = state
                z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
                z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
                return (Double((z ^ (z >> 31)) >> 11) + 0.5) / 9_007_199_254_740_992.0
            }
            var pixels = [Float](repeating: 0, count: size * size)
            var spare = 0.0
            for qx in 0..<size {
                for qy in 0..<size {
                    let dx = Double(qx) - centerQX, dy = Double(qy) - centerQY
                    let rho = max(0, A * dx * dx + B * dx * dy + C * dy * dy).squareRoot()
                    let distance = (rho - 1) * mean
                    var value = exp(-(distance * distance) / (2 * 3.0 * 3.0))
                    if gap > 0 {
                        var angle = atan2(dy, dx) * 180 / .pi
                        angle = (angle - gapStart).truncatingRemainder(dividingBy: 360)
                        if angle < 0 { angle += 360 }
                        if angle < gap { value = 0 }
                    }
                    if tail > 0 {
                        let r = max(hypot(dx, dy), 1)
                        value += tail * (radius / r) * (radius / r)
                    }
                    if noise > 0 {
                        if (qx * size + qy) % 2 == 0 {
                            let u1 = uniform(), u2 = uniform()
                            let r = (-2 * log(u1)).squareRoot()
                            value += noise * r * cos(2 * .pi * u2)
                            spare = noise * r * sin(2 * .pi * u2)
                        } else {
                            value += spare
                        }
                    }
                    pixels[qx * size + qy] = Float(value)
                }
            }
            return DiffractionPattern(width: size, height: size, pixels: pixels)
        }
    }

    /// A click's error from the plant (1.3, -0.9 px), the annulus (b - 20, a + 20).
    private func assertRingIsFound(_ plant: Plant, _ name: String) {
        let fit: EllipseCalibrationFit
        do {
            fit = try EllipseCalibration.fitBestAvailable(
                pattern: plant.render(),
                centerQX: plant.centerQX + 1.3, centerQY: plant.centerQY - 0.9,
                innerRadius: plant.b - 20, outerRadius: plant.a + 20)
        } catch {
            XCTFail("\(name) was refused: \(error)")
            return
        }
        XCTAssertEqual(fit.model, .asymmetricGaussian, "\(name): fell back to \(fit.model) (\(fit.profileFallbackReason ?? "no reason"))")
        XCTAssertLessThanOrEqual(abs((fit.a + fit.b) / 2 / plant.radius - 1), 0.01,
                                 "\(name): mean radius \((fit.a + fit.b) / 2) against \(plant.radius)")
        XCTAssertLessThanOrEqual(abs(fit.b / fit.a - plant.b / plant.a), 0.01,
                                 "\(name): b / a \(fit.b / fit.a) against \(plant.b / plant.a)")
        XCTAssertLessThanOrEqual(hypot(fit.centerQX - plant.centerQX, fit.centerQY - plant.centerQY), 1.0,
                                 "\(name): centre (\(fit.centerQX), \(fit.centerQY)) against (\(plant.centerQX), \(plant.centerQY))")
    }

    /// The dead ring: R 70, eps 1 %, theta 0, a 60 degree gap, noise 0.10, seed 3.
    /// From py4DSTEM's start alone it ends at I1 0 with a ring sigma at 0.25 px and a mean radius 16.7 % low.
    func testNoisyGappedRingIsNotDrainedIntoTheBackground() {
        assertRingIsFound(Plant(size: 192, radius: 70, eps: 0.01, thetaDegrees: 0, gap: 60, noise: 0.10, seed: 3),
                          "dead ring n192-R70-e10-t0.0-g60-s100-k3")
    }

    /// The drifting ring: R 70, eps 1 %, theta 112.5, no gap, noise 0.10, seed 2.
    /// From py4DSTEM's start alone it keeps ring sigmas of 2.9 and 3.9 px but ends 39 px off centre and 41 % low.
    func testNoisyRingDoesNotDriftOffCentre() {
        assertRingIsFound(Plant(size: 192, radius: 70, eps: 0.01, thetaDegrees: 112.5, gap: 0, noise: 0.10, seed: 2),
                          "drifting ring n192-R70-e10-t112.5-g0-s100-k2")
    }

    /// The tail ring: R 65, eps 1 %, theta 112.5, no gap, noise 0.10, 1/r^2 tail 0.8, seed 5.
    /// From py4DSTEM's start it ends 0.002 % from the true radius; from the half-maximum start alone
    /// ends 2.3 % high with an inner ring sigma of 132 px.
    func testNoisyRingOnAnInverseSquareTailKeepsItsRadius() {
        assertRingIsFound(Plant(size: 192, radius: 65, eps: 0.01, thetaDegrees: 112.5, gap: 0, noise: 0.10, seed: 5, tail: 0.8),
                          "tail ring n192-R65-e10-t112.5-g0-s100-k5-T80")
    }

    /// A ring-less fit on a real pattern: the mean diffraction pattern of the Ni65Cu35 ROI6 cube
    /// (`COPL_Ni65Cu35_C_ROI6_240911_…_bin_4_20240912.h5`, 200 x 200 positions of 32 x 32 px, the
    /// website's demo cube; float32 mean as the app computes it, `Fixtures/ni65cu35-roi6-mean-32x32.f32`),
    /// annulus [11.125, 14.125] px about the centroid of its brightest 1 % (15.001983, 15.162129). Without
    /// the floor guard the Fit accepts a ring-less profile fit there (I1 0, a ring sigma at the 0.25 px
    /// floor, b/a 0.947, where the conic gives 0.989 and the wider annulus 0.970); with it, the Fit falls
    /// back to the conic and says why (`archive/v5/ring-fit-two-start-gateD-2026-10-14.md`, step (i), S5).
    func testRinglessFitOnARealMeanPatternFallsBackToTheConic() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/ni65cu35-roi6-mean-32x32.f32")
        let data = try Data(contentsOf: url)
        let pixels = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        XCTAssertEqual(pixels.count, 32 * 32)
        let fit = try EllipseCalibration.fitBestAvailable(
            pattern: DiffractionPattern(width: 32, height: 32, pixels: pixels),
            centerQX: 15.001983, centerQY: 15.162129, innerRadius: 11.125, outerRadius: 14.125)
        XCTAssertEqual(fit.model, .conic, "a ring-less profile fit was accepted")
        XCTAssertNil(fit.profile)
        XCTAssertTrue(fit.profileFallbackReason?.contains("0.25 px floor") ?? false,
                      "fallback reason was \(fit.profileFallbackReason ?? "nil")")
        XCTAssertEqual(fit.b / fit.a, 0.989, accuracy: 0.001)
    }
}
