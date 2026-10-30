//
//  RingCalibrationTests.swift
//   "Diffraction S3, Camera length from one ring of known d", slice S3-a: the closed forms (λ, 2θ, L_px, Δq,
//  L_mm) against hand arithmetic, and every registered refusal by its own name. No fit, no Python at run time: the
//  expected numbers below were worked once, by hand, in 60-digit decimal arithmetic from the CODATA 2018 constants
//  stated in DiffractoKit's RingCalibration.swift (h and c and e exact, m₀ = 9.1093837015e-31 kg) and are typed here as literals. The
//  parity with a numpy script over many cases is tools/parity/ring-calibration-parity.
//
//  Every test names under "RED UNDER" the production mutation that turns it red:'s list for this item where a
//  mutation reaches a closed form or a refusal (the ones that need a fit or a harness, `recover` and `centre`, are
//  S3-b's), plus the ones the refusals and guards here add.
//

import XCTest
import DiffractoGeometry

nonisolated final class RingCalibrationTests: XCTestCase {

    // MARK: The worked numbers

    // Constants (CODATA 2018): hc/e = 6.62607015e-34 × 299792458 / 1.602176634e-19 = 1.2398419843320026e-6 V·m
    //   = 12398.419843320026 eV·Å; m₀c²/e = 9.1093837015e-31 × 299792458² / 1.602176634e-19 = 510998.94999616415 eV,
    //   so 2m₀c² = 1021997.8999923283 eV.
    private let hcEVAngstroms = 12398.419843320026
    private let restEnergyEV = 510998.94999616415

    // λ = hc / √(eV (2m₀c² + eV)), eV = 1000 × kV:
    //    80 kV:  2m₀c² + eV = 1101997.8999923283;  × 80000  = 88159831999.386265;  √ = 296917.21405029090;
    //            λ = 12398.419843320026 / 296917.21405029090 = 0.041757160772834212 Å
    //   120 kV:  1141997.8999923283 × 120000 = 137039747999.07940;  √ = 370188.80047764735;  λ = 0.033492152726723738 Å
    //   200 kV:  1221997.8999923283 × 200000 = 244399579998.46566;  √ = 494367.85898606481;  λ = 0.025079340450548003 Å
    //   300 kV:  1321997.8999923283 × 300000 = 396599369997.69849;  √ = 629761.35956225394;  λ = 0.019687489006848796 Å
    private let lambda80 = 0.041757160772834212
    private let lambda120 = 0.033492152726723738
    private let lambda200 = 0.025079340450548003
    private let lambda300 = 0.019687489006848796

    // Au {111}: d = 2.3546 Å, at 200 kV, R = 150 px:
    //   λ/2d = 0.025079340450548003 / 4.7092 = 0.0053256052940091742;  2θ = 2 arcsin(.) = 0.010651260937060768 rad;
    //   tan 2θ = 0.010651663748250814;  L_px = 150 / tan 2θ = 14082.307097295722;
    //   Δq = (1/d)/R = 0.4247005860868088 / 150 = 0.0028313372405787253 Å⁻¹ per pixel;
    //   p = 0.014 mm (a 14 µm pixel): L = 0.014 × 14082.307097295722 = 197.15229936214011 mm.
    private let dAu111 = 2.3546
    private let twoThetaAu111At200 = 0.010651260937060768
    private let tanTwoThetaAu111At200 = 0.010651663748250814
    private let lengthPixelsAu111At200 = 14082.307097295722
    private let deltaQAu111R150 = 0.0028313372405787253
    private let lengthMMAu111At200P14 = 197.15229936214011

    // Au {422} at 80 kV, d = 0.8325 Å (a/√24 with a = 4.0782 Å is 0.83246), R = 150 px:
    //   λ/2d = 0.041757160772834212 / 1.665 = 0.025079375839540067;  2θ = 0.050164011268796932 rad;
    //   tan 2θ = 0.050206131707820426;  L_px = 150 / tan 2θ = 2987.6828765247223.
    private let dAu422 = 0.8325
    private let twoThetaAu422At80 = 0.050164011268796932
    private let lengthPixelsAu422At80R150 = 2987.6828765247223

    // The small-angle form L = R d / λ, divided by the exact L, minus 1 (= tan 2θ · d/λ − 1):
    //   200 kV Au {111}, R = 150:  14082.906234971683 / 14082.307097295722 − 1 = 4.2545420422e-5
    //    80 kV Au {422}, R = 150:  2990.5050460528300 / 2987.6828765247223 − 1 = 9.4460143353e-4  (: "9.5e-4";
    //    to two figures it is 9.4e-4: the registered figure is rounded up by 0.6 %)
    private let smallAngleExcessAu111At200 = 4.2545420422e-5
    private let smallAngleExcessAu422At80 = 9.4460143353e-4

    private func assertClose(_ got: Double, _ want: Double, relative: Double = 1e-12, _ message: @autoclosure () -> String = "",
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(got, want, accuracy: abs(want) * relative, "\(message()) got \(got), want \(want)", file: file, line: line)
    }

    // MARK: The constants and λ

    /// RED UNDER: any constant mistyped or changed (hc/e or m₀c²/e off by more than 1e-12; a 2m₀c² written as m₀c²).
    func testTheConstantsAreCODATA2018AndTheDerivedOnesFollowFromThem() {
        XCTAssertEqual(RingCalibration.planckConstant, 6.62607015e-34)
        XCTAssertEqual(RingCalibration.speedOfLight, 299_792_458)
        XCTAssertEqual(RingCalibration.elementaryCharge, 1.602176634e-19)
        XCTAssertEqual(RingCalibration.electronMass, 9.1093837015e-31)
        assertClose(RingCalibration.planckTimesLightEVAngstroms, hcEVAngstroms, "hc/e in eV·Å")
        assertClose(RingCalibration.electronRestEnergyEV, restEnergyEV, "m₀c²/e in eV")
        // CODATA 2018's own published electron rest energy, 0.510 998 950 00(15) MeV, is an independent anchor for
        // m₀c²/e (the stated uncertainty is 1.5e-4 eV; the value here is 3.8e-6 eV from it).
        XCTAssertEqual(RingCalibration.electronRestEnergyEV, 510_998.950_00, accuracy: 1.5e-4)
        // and m₀c² = 8.1871057769(25)e-14 J, CODATA 2018's published value in joules.
        XCTAssertEqual(RingCalibration.electronMass * RingCalibration.speedOfLight * RingCalibration.speedOfLight,
                       8.1871057769e-14, accuracy: 2.5e-23)
    }

    /// RED UNDER: non-relativistic λ (the radicand without + eV, i.e. h/√(2m₀eV): +9.3 % at 200 kV); kV as V (the
    /// ×1000 dropped: λ × 32.8 at 80 kV, 34.6 at 200 kV); a wrong hc.
    func testWavelengthAt80And120And200And300kVEqualsTheHandArithmetic() {
        assertClose(RingCalibration.wavelengthAngstroms(volts: 80_000), lambda80, "80 kV")
        assertClose(RingCalibration.wavelengthAngstroms(volts: 120_000), lambda120, "120 kV")
        assertClose(RingCalibration.wavelengthAngstroms(volts: 200_000), lambda200, "200 kV")
        assertClose(RingCalibration.wavelengthAngstroms(volts: 300_000), lambda300, "300 kV")
    }

    /// A second source for the same four wavelengths: the study's script (
    /// §2.1, "[calc]"), 80 kV 4.17572 pm, 120 kV 3.34922, 200 kV 2.50793, 300 kV 1.96875, given to six figures (so to
    /// 3e-6 relative here). It was written before this file and does not share its arithmetic.
    /// RED UNDER: kV as V; non-relativistic λ; a wrong constant.
    func testWavelengthAgreesWithTheStudiesSixFigureValues() {
        for (volts, picometres) in [(80_000.0, 4.17572), (120_000.0, 3.34922), (200_000.0, 2.50793), (300_000.0, 1.96875)] {
            assertClose(RingCalibration.wavelengthAngstroms(volts: volts) * 100, picometres, relative: 3e-6, "\(volts) V")
        }
    }

    /// The classical λ is h/√(2m₀eV), and the relativistic one is smaller by √(1 + eV/2m₀c²) (the textbook identity;
    /// 200 kV: √(1 + 200000/1021997.9) = 1.0934784, so the classical value is 9.3 % high). This is a different route
    /// from the hand arithmetic above: it checks the (2m₀c² + eV) structure without trusting hc.
    /// RED UNDER: non-relativistic λ; 2m₀c² replaced by m₀c² in the radicand.
    func testWavelengthIsTheClassicalOneDividedByTheRelativisticFactor() {
        for kv in [80.0, 120.0, 200.0, 300.0] {
            let volts = kv * 1000
            let classical = hcEVAngstroms / (2 * restEnergyEV * volts).squareRoot()
            let factor = (1 + volts / (2 * restEnergyEV)).squareRoot()
            assertClose(RingCalibration.wavelengthAngstroms(volts: volts) * factor, classical, relative: 1e-12, "\(kv) kV")
        }
        // The classical value at 200 kV, worked: 12398.419843320026 / √(2 × 510998.94999616415 × 200000) =
        // 12398.419843320026 / 452105.71772370416 = 0.027423718297004785 Å, 1.0934784489679654 times the relativistic one.
        assertClose(0.027423718297004785 / RingCalibration.wavelengthAngstroms(volts: 200_000), 1.0934784489679654, "classical / relativistic at 200 kV")
    }

    // MARK: 2θ, L_px, Δq, L_mm

    /// RED UNDER: θ for 2θ (a factor 2); the small-angle 2θ = λ/d (5e-6 off at 200 kV Au {111}); arctan for arcsin.
    func testTwoThetaIsTwiceArcsinOfLambdaOverTwoD() {
        assertClose(RingCalibration.twoTheta(wavelengthAngstroms: lambda200, d: dAu111), twoThetaAu111At200, "Au {111}, 200 kV")
        assertClose(RingCalibration.twoTheta(wavelengthAngstroms: lambda80, d: dAu422), twoThetaAu422At80, "Au {422}, 80 kV")
    }

    /// RED UNDER: small-angle L (tan 2θ replaced by 2θ, or R·d/λ), at 200 kV Au {111} (3e-5 against a 1e-12 band) and
    /// at 80 kV Au {422} (9.4e-4); tan for sin.
    func testCameraLengthInPixelsIsTheRadiusOverTanTwoTheta() {
        assertClose(RingCalibration.cameraLengthPixels(radius: 150, twoTheta: twoThetaAu111At200), lengthPixelsAu111At200, "Au {111}, 200 kV")
        assertClose(RingCalibration.cameraLengthPixels(radius: 150, twoTheta: twoThetaAu422At80), lengthPixelsAu422At80R150, "Au {422}, 80 kV")
        // Linear in R.
        assertClose(RingCalibration.cameraLengthPixels(radius: 75, twoTheta: twoThetaAu111At200), lengthPixelsAu111At200 / 2, "R halved")
    }

    /// A planted camera length of 15000 px: the ring it makes at Au {111}, 200 kV is R = L·tan 2θ =
    /// 15000 × 0.010651663748250814 = 159.77495622376222 px; L from that R is 15000 again, and R from that L is R
    /// again (the round trip R → L_px → R, with the inverse written here, not in the production file).
    /// RED UNDER: small-angle L (4.3e-5 off); θ for 2θ; R/tan 2θ replaced by R·tan 2θ.
    func testPlantedCameraLengthIsRecoveredFromItsRingAndTheRadiusFromTheLength() throws {
        let plantedLength = 15000.0, ring = 159.77495622376222
        assertClose(plantedLength * tanTwoThetaAu111At200, ring, relative: 1e-14, "the plant's own arithmetic")
        let length = try XCTUnwrap(RingCalibration.calibrate(radius: ring, d: dAu111, highTensionVolts: 200_000).lengthPixels)
        assertClose(length, plantedLength, "L_px from R")
        assertClose(length * tanTwoThetaAu111At200, ring, "R from L_px")
    }

    /// The small-angle camera constant λL = Rd is not used: the exact L differs from it by tan 2θ·d/λ − 1, which is
    /// 4.3e-5 at 200 kV Au {111} and 9.4e-4 at 80 kV Au {422}.
    /// RED UNDER: small-angle L (the difference is then 0); `radius / tan(twoTheta)` written `radius / twoTheta` (the
    /// difference is then 4.7e-6 at 200 kV Au {111}, against the registered 4e-5).
    func testTheExactLengthDiffersFromTheSmallAngleOneByTheRegisteredAmount() throws {
        let exactA = try XCTUnwrap(RingCalibration.calibrate(radius: 150, d: dAu111, highTensionVolts: 200_000).lengthPixels)
        XCTAssertEqual(150 * dAu111 / lambda200 / exactA - 1, smallAngleExcessAu111At200, accuracy: 1e-11)
        let exactB = try XCTUnwrap(RingCalibration.calibrate(radius: 150, d: dAu422, highTensionVolts: 80_000).lengthPixels)
        XCTAssertEqual(150 * dAu422 / lambda80 / exactB - 1, smallAngleExcessAu422At80, accuracy: 1e-11)
        // The registration's own figures, quoted, against what production gives (not against the literals above): 4e-5
        // to one figure, and 9.5e-4 within 1 % of the worked 9.446e-4.
        XCTAssertEqual(150 * dAu111 / lambda200 / exactA - 1, 4e-5, accuracy: 5e-6, "archive: roadmap-registrations-2026-10-15.md: 4e-5 at 200 kV Au {111}")
        XCTAssertEqual(150 * dAu422 / lambda80 / exactB - 1, 9.5e-4, accuracy: 1e-5, "archive: roadmap-registrations-2026-10-15.md: 9.5e-4 at 80 kV Au {422}")
    }

    /// Δq = (1/d)/R for Au {111} (d = 2.3546 Å) at R = 150 px: 1/2.3546 = 0.4247005860868088 Å⁻¹, over 150 =
    /// 0.0028313372405787253 Å⁻¹ per pixel; the same at every voltage, because it needs no wavelength.
    /// RED UNDER: q = 2/d (× 2); Å for nm (d taken as nm, × 0.1); R in the numerator.
    func testDeltaQOfAuIIIAtAStatedRadiusIsOneOverDOverR() throws {
        assertClose(RingCalibration.qPerPixel(d: dAu111, radius: 150), deltaQAu111R150, "the closed form")
        for volts in [nil, 80_000, 200_000, 300_000] as [Double?] {
            let result = try RingCalibration.calibrate(radius: 150, d: dAu111, highTensionVolts: volts)
            assertClose(result.deltaQ, deltaQAu111R150, "calibrate at \(String(describing: volts)) V")
        }
        // 1 Å⁻¹ per pixel × the 150 px of the ring = 1/d = 0.4247 Å⁻¹, the ring's own q (not 2/d = 0.849).
        assertClose(RingCalibration.qPerPixel(d: dAu111, radius: 150) * 150, 1 / dAu111, "q at the ring is 1/d")
    }

    /// L_mm = p × L_px for p in MILLIMETRES: 0.014 × 14082.307097295722 = 197.15229936214011 mm. Without p there is no
    /// L in mm, only L_px.
    /// RED UNDER: p in µm used as mm (× 1000: 197152 mm); p ignored; p divided instead of multiplied.
    func testCameraLengthInMillimetresIsThePitchTimesThePixelLength() throws {
        assertClose(RingCalibration.cameraLengthMillimetres(pixelPitchMM: 0.014, cameraLengthPixels: lengthPixelsAu111At200),
                    lengthMMAu111At200P14, "the closed form")
        let withPitch = try RingCalibration.calibrate(radius: 150, d: dAu111, highTensionVolts: 200_000, pixelPitchMM: 0.014)
        assertClose(try XCTUnwrap(withPitch.lengthMillimetres), lengthMMAu111At200P14, "calibrate")
        let without = try RingCalibration.calibrate(radius: 150, d: dAu111, highTensionVolts: 200_000)
        XCTAssertNil(without.lengthMillimetres)
        assertClose(try XCTUnwrap(without.lengthPixels), lengthPixelsAu111At200, "L_px is given without a pitch")
    }

    /// The whole chain on Au {111}, 200 kV, R = 150 px, p = 0.014 mm, and what it carries beside L.
    /// RED UNDER: every closed-form mutation above; the high tension not carried; V defaulted.
    func testCalibrateReturnsEveryQuantityWithTheHighTensionItUsed() throws {
        let r = try RingCalibration.calibrate(radius: 150, d: dAu111, highTensionVolts: 200_000, pixelPitchMM: 0.014)
        XCTAssertEqual(r.d, dAu111)
        XCTAssertEqual(r.radius, 150)
        assertClose(r.deltaQ, deltaQAu111R150, "Δq")
        XCTAssertEqual(r.highTensionVolts, 200_000, "V is returned beside L")
        assertClose(try XCTUnwrap(r.wavelengthAngstroms), lambda200, "λ")
        assertClose(try XCTUnwrap(r.twoTheta), twoThetaAu111At200, "2θ")
        assertClose(try XCTUnwrap(r.lengthPixels), lengthPixelsAu111At200, "L_px")
        assertClose(try XCTUnwrap(r.lengthMillimetres), lengthMMAu111At200P14, "L_mm")
        XCTAssertNil(r.lengthRefusal)
    }

    // MARK: Refusals of the calibration itself

    /// No high tension: Δq is given exactly, L is not, and the reason is `.noHighTension`. A stated V is never
    /// guessed.
    /// RED UNDER: V defaulted to 200 kV (L would then be given).
    func testAMissingHighTensionGivesDeltaQAndNoLength() throws {
        let r = try RingCalibration.calibrate(radius: 150, d: dAu111, highTensionVolts: nil, pixelPitchMM: 0.014)
        assertClose(r.deltaQ, deltaQAu111R150, "Δq is still given")
        XCTAssertNil(r.highTensionVolts)
        XCTAssertNil(r.wavelengthAngstroms)
        XCTAssertNil(r.twoTheta)
        XCTAssertNil(r.lengthPixels, "no V, no L: it is not defaulted to 200 kV")
        XCTAssertNil(r.lengthMillimetres)
        XCTAssertEqual(r.lengthRefusal, .noHighTension)
    }

    /// A ring whose d the wavelength cannot reach. This refusal is an addition beyond the registration, which lists no
    /// Bragg bound (2θ ≥ 90° makes tan 2θ negative): λ/2d = 1 exactly (0.05 / 0.05) and 1.003 are refused, and so is 0.72,
    /// between 1/√2 = 0.7071 and 1, where tan 2θ is negative; 0.70 (2θ = 88.85°) is not. Δq is still given.
    /// RED UNDER: the bound removed (asin of 1.003 is NaN, of 1 is π/2); the bound at λ/2d ≥ 1 (0.72 would pass
    /// with a negative L); the bound at > rather than ≥ (λ/2d = 1/√2 itself).
    func testARingBeyondTheBraggLimitIsRefusedByNameWithDeltaQGiven() throws {
        XCTAssertTrue(RingCalibration.twoTheta(wavelengthAngstroms: 0.05, d: 0.025).isNaN, "λ/2d = 1 exactly")
        XCTAssertTrue(RingCalibration.twoTheta(wavelengthAngstroms: 0.72, d: 0.5).isNaN, "λ/2d = 0.72")
        XCTAssertTrue(RingCalibration.twoTheta(wavelengthAngstroms: 0.5.squareRoot() * 2, d: 1).isNaN, "λ/2d = 1/√2: 2θ = 90°")
        // λ/2d = 0.70: 2θ = 2 arcsin(0.7) = 1.5507949932215061 rad (88.85°), tan 2θ = 49.98999899979995.
        assertClose(RingCalibration.twoTheta(wavelengthAngstroms: 0.7, d: 0.5), 1.5507949932215061, "λ/2d = 0.70")
        assertClose(RingCalibration.cameraLengthPixels(radius: 4999, twoTheta: 1.5507949932215061), 4999 / 49.98999899979995, "L at λ/2d = 0.70")
        // The wavelength at 200 kV is 0.025079 Å: a ring of 0.0125 Å (λ/2d = 1.003) is impossible at it.
        let r = try RingCalibration.calibrate(radius: 150, d: 0.0125, highTensionVolts: 200_000, pixelPitchMM: 0.014)
        guard case .braggLimit(let ratio)? = r.lengthRefusal else { return XCTFail("refusal \(String(describing: r.lengthRefusal))") }
        assertClose(ratio, lambda200 / 0.025, "the ratio reported")
        XCTAssertNil(r.lengthPixels)
        XCTAssertNil(r.twoTheta)
        XCTAssertEqual(r.highTensionVolts, 200_000)
        assertClose(r.deltaQ, (1 / 0.0125) / 150, "Δq is still given")
    }

    /// Numbers that are not finite and positive are the caller's mistake and are refused, not computed on.
    /// RED UNDER: a guard removed in `calibrate` (a zero radius gives an infinite Δq, a NaN V gives a NaN λ that nothing
    /// flags; a spacing, V or pitch guard removed gives a number the guard exists to refuse).
    func testNonPhysicalInputsToCalibrateAreRefusedAsInvalidInput() {
        XCTAssertThrowsError(try RingCalibration.calibrate(radius: 0, d: dAu111, highTensionVolts: 200_000)) { XCTAssertEqual($0 as? RingCalibration.Refusal, .invalidInput("the ring radius must be a positive number of pixels")) }
        XCTAssertThrowsError(try RingCalibration.calibrate(radius: .nan, d: dAu111, highTensionVolts: 200_000)) { XCTAssertEqual($0 as? RingCalibration.Refusal, .invalidInput("the ring radius must be a positive number of pixels")) }
        XCTAssertThrowsError(try RingCalibration.calibrate(radius: 150, d: -2.3546, highTensionVolts: 200_000)) { XCTAssertEqual($0 as? RingCalibration.Refusal, .invalidInput("the ring spacing must be a positive number of Å")) }
        XCTAssertThrowsError(try RingCalibration.calibrate(radius: 150, d: dAu111, highTensionVolts: 0)) { XCTAssertEqual($0 as? RingCalibration.Refusal, .invalidInput("the high tension must be a positive number of volts")) }
        XCTAssertThrowsError(try RingCalibration.calibrate(radius: 150, d: dAu111, highTensionVolts: .nan)) { XCTAssertEqual($0 as? RingCalibration.Refusal, .invalidInput("the high tension must be a positive number of volts")) }
        XCTAssertThrowsError(try RingCalibration.calibrate(radius: 150, d: dAu111, highTensionVolts: 200_000, pixelPitchMM: 0)) { XCTAssertEqual($0 as? RingCalibration.Refusal, .invalidInput("the pixel pitch must be a positive number of millimetres")) }
    }

    /// The header's promise: outside its domain a closed form returns NaN, never a plausible number. Every input below
    /// would otherwise give a finite, infinite or negative number, called directly (not through `calibrate`'s guards).
    /// RED UNDER, each line by the one guard it catches:
    ///   wavelengthAngstroms: `volts.isFinite` removed (∞: λ = 0), `volts > 0` removed (−2 MV: V(2m₀c² + V) is positive
    ///     again, so λ = 0.0089 Å) or weakened to `>= 0` (0 V: λ = ∞);
    ///   twoTheta: `d > 0` removed (d < 0: a negative 2θ), `wavelengthAngstroms > 0` removed (λ < 0: a negative 2θ) or
    ///     weakened to `>= 0` (λ = 0: 2θ = 0);
    ///   cameraLengthPixels: `radius > 0` removed (R < 0: a negative L) or weakened to `>= 0` (R = 0: L = 0),
    ///     `twoTheta > 0` removed or weakened (2θ = 0: L = ∞), `twoTheta < .pi / 2` removed (2θ = π/2: a huge finite tan);
    ///   qPerPixel: `d > 0` removed (d < 0: a negative Δq) or weakened (d = 0: ∞), `radius > 0` removed (R < 0) or
    ///     weakened (R = 0: ∞);
    ///   cameraLengthMillimetres: `pixelPitchMM > 0` removed (p < 0) or weakened (p = 0: L = 0).
    func testTheClosedFormsGiveNaNOutsideTheirDomain() {
        XCTAssertTrue(RingCalibration.wavelengthAngstroms(volts: -200_000).isNaN, "V < 0")
        XCTAssertTrue(RingCalibration.wavelengthAngstroms(volts: -2_000_000).isNaN, "V < −2m₀c²/e: the radicand is positive again")
        XCTAssertTrue(RingCalibration.wavelengthAngstroms(volts: 0).isNaN, "V = 0")
        XCTAssertTrue(RingCalibration.wavelengthAngstroms(volts: .infinity).isNaN, "V = ∞")

        XCTAssertTrue(RingCalibration.twoTheta(wavelengthAngstroms: 0.025, d: -2.3546).isNaN, "d < 0")
        XCTAssertTrue(RingCalibration.twoTheta(wavelengthAngstroms: -0.025, d: 2.3546).isNaN, "λ < 0")
        XCTAssertTrue(RingCalibration.twoTheta(wavelengthAngstroms: 0, d: 2.3546).isNaN, "λ = 0")

        XCTAssertTrue(RingCalibration.cameraLengthPixels(radius: 0, twoTheta: twoThetaAu111At200).isNaN, "R = 0")
        XCTAssertTrue(RingCalibration.cameraLengthPixels(radius: -150, twoTheta: twoThetaAu111At200).isNaN, "R < 0")
        XCTAssertTrue(RingCalibration.cameraLengthPixels(radius: 150, twoTheta: 0).isNaN, "2θ = 0")
        XCTAssertTrue(RingCalibration.cameraLengthPixels(radius: 150, twoTheta: .pi / 2).isNaN, "2θ = π/2")

        XCTAssertTrue(RingCalibration.qPerPixel(d: 0, radius: 150).isNaN, "d = 0")
        XCTAssertTrue(RingCalibration.qPerPixel(d: -2.3546, radius: 150).isNaN, "d < 0")
        XCTAssertTrue(RingCalibration.qPerPixel(d: 2.3546, radius: 0).isNaN, "R = 0")
        XCTAssertTrue(RingCalibration.qPerPixel(d: 2.3546, radius: -150).isNaN, "R < 0")

        XCTAssertTrue(RingCalibration.cameraLengthMillimetres(pixelPitchMM: -0.014, cameraLengthPixels: 14000).isNaN, "p < 0")
        XCTAssertTrue(RingCalibration.cameraLengthMillimetres(pixelPitchMM: 0, cameraLengthPixels: 14000).isNaN, "p = 0")
    }

    // MARK: The fit's refusals, each by its own name

    /// A clean profile fit: both ring sigmas well inside a 40 px annulus, 36 of 36 bins, residual 0.05, a/b − 1 = 3.05 %.
    private func cleanFit() -> RingCalibration.FitReport {
        RingCalibration.FitReport(model: .asymmetricGaussian, semiAxisA: 101.5, semiAxisB: 98.5, occupiedAngularBins: 36,
                                  sparseCoverage: false, normalizedResidual: 0.05, innerSigma: 3.0, outerSigma: 3.5, annulusWidth: 40)
    }

    /// RED UNDER: a bound moved so far that the clean fit is refused (36 bins out of range, a residual cap below 0.05, a
    /// sigma bound below 3.5 px).
    func testACleanProfileFitWithAHighTensionIsNotRefused() {
        XCTAssertEqual(RingCalibration.refusals(cleanFit(), highTensionVolts: 200_000), [])
    }

    /// R is (a + b)/2 and a/b − 1 uses the larger axis over the smaller, in either order.
    /// RED UNDER: radius = a (1.5 %); radius = b; the axes taken as given
    /// when b > a (the ellipticity negative, never refused).
    func testTheRadiusIsTheMeanOfTheSemiAxesAndTheEllipticityIsTheirRatioMinusOne() {
        var fit = cleanFit()
        fit.semiAxisA = 103; fit.semiAxisB = 97
        XCTAssertEqual(fit.radius, 100, accuracy: 1e-13)
        XCTAssertEqual(fit.ellipticity, 103.0 / 97.0 - 1, accuracy: 1e-15)
        fit.semiAxisA = 97; fit.semiAxisB = 103
        XCTAssertEqual(fit.radius, 100, accuracy: 1e-13)
        XCTAssertEqual(fit.ellipticity, 103.0 / 97.0 - 1, accuracy: 1e-15, "b larger than a")
    }

    /// Model ≠ asymmetricGaussian: the conic's radius is not offered. The conic has no ring sigmas (nil).
    /// RED UNDER: the conic accepted.
    func testAConicFitIsRefusedAsModelNotAsymmetricGaussian() {
        var fit = cleanFit()
        fit.model = .conic; fit.innerSigma = nil; fit.outerSigma = nil
        XCTAssertEqual(RingCalibration.refusals(fit, highTensionVolts: 200_000), [.modelNotAsymmetricGaussian])
    }

    /// Fewer than 30 of 36 bins: 29 is refused (with its count), 30 is not.
    /// RED UNDER: the bound at ≤ 30 (30 refused) or ≥ 30 off by one (29 accepted); the bound removed ('s
    /// `refuse-gap`: a 120° gap ring has 24 of 36).
    func testFewerThanThirtyOfThirtySixBinsIsRefusedByCount() {
        var fit = cleanFit()
        fit.occupiedAngularBins = 30
        XCTAssertEqual(RingCalibration.refusals(fit, highTensionVolts: 200_000), [], "30 of 36")
        fit.occupiedAngularBins = 29
        XCTAssertEqual(RingCalibration.refusals(fit, highTensionVolts: 200_000), [.insufficientAngularCoverage(occupiedBins: 29)])
        fit.occupiedAngularBins = 24
        XCTAssertEqual(RingCalibration.refusals(fit, highTensionVolts: 200_000), [.insufficientAngularCoverage(occupiedBins: 24)], "a 120° gap")
        XCTAssertTrue(RingCalibration.Refusal.insufficientAngularCoverage(occupiedBins: 24).reason.contains("24 of 36"))
    }

    /// A fit accepted only because the caller asserted one ring in a sparse annulus is refused, even at full coverage.
    /// RED UNDER: `sparseCoverage` ignored.
    func testASparseCoverageFitIsRefusedEvenWhenAllBinsAreOccupied() {
        var fit = cleanFit()
        fit.sparseCoverage = true
        XCTAssertEqual(RingCalibration.refusals(fit, highTensionVolts: 200_000), [.insufficientAngularCoverage(occupiedBins: 36)])
        XCTAssertTrue(RingCalibration.Refusal.insufficientAngularCoverage(occupiedBins: 36).reason.contains("asserted"))
    }

    /// A ring sigma at or above the annulus width is refused (the larger of the two is reported); just below is not.
    /// RED UNDER: the sigma bound unchecked ('s `refuse-bound`: the 1/r³ background plant's σ is the fit's bound
    /// of 243 px at a 40 px annulus); the bound at > rather than ≥; only the inner or only the outer sigma tested.
    func testARingSigmaAtOrAboveTheAnnulusWidthIsRefusedAndTheLargerIsReported() {
        var fit = cleanFit()                      // annulus width 40
        fit.innerSigma = 39.9; fit.outerSigma = 3.5
        XCTAssertEqual(RingCalibration.refusals(fit, highTensionVolts: 200_000), [], "inner just inside")
        fit.innerSigma = 3.0; fit.outerSigma = 39.9
        XCTAssertEqual(RingCalibration.refusals(fit, highTensionVolts: 200_000), [], "outer just inside")
        fit.innerSigma = 40; fit.outerSigma = 3.5
        XCTAssertEqual(RingCalibration.refusals(fit, highTensionVolts: 200_000), [.sigmaAtAnnulusWidth(sigma: 40, annulusWidth: 40)], "inner at the width")
        fit.innerSigma = 3.0; fit.outerSigma = 40
        XCTAssertEqual(RingCalibration.refusals(fit, highTensionVolts: 200_000), [.sigmaAtAnnulusWidth(sigma: 40, annulusWidth: 40)], "outer at the width")
        fit.innerSigma = 243; fit.outerSigma = 50
        XCTAssertEqual(RingCalibration.refusals(fit, highTensionVolts: 200_000), [.sigmaAtAnnulusWidth(sigma: 243, annulusWidth: 40)], "the larger one")
    }

    /// The residual cap is 0.22 (mac4DSTEM's): 0.22 passes, 0.2201 is refused.
    /// RED UNDER: the cap raised (0.23: 0.2201 would pass) or lowered below 0.22; ≥ for > (0.22 itself refused).
    func testAResidualAboveTwentyTwoHundredthsIsRefused() {
        var fit = cleanFit()
        fit.normalizedResidual = 0.22
        XCTAssertEqual(RingCalibration.refusals(fit, highTensionVolts: 200_000), [], "exactly the cap")
        fit.normalizedResidual = 0.2201
        XCTAssertEqual(RingCalibration.refusals(fit, highTensionVolts: 200_000), [.excessiveResidual(0.2201)])
    }

    /// a/b − 1 above 0.093 is refused (the derived bound at which (a + b)/2 and √(ab) differ by 0.1 %), in either axis
    /// order: 109.4/100 − 1 = 0.094 is refused, 109.2/100 − 1 = 0.092 is not.
    /// RED UNDER: the bound raised to 0.10 (0.094 would pass); the ellipticity taken as a/b − 1 with a, b as given
    /// (b > a is then never refused); the check removed.
    func testAnEllipticityAboveNinetyThreeThousandthsIsRefusedInEitherAxisOrder() {
        var fit = cleanFit()
        fit.semiAxisA = 109.2; fit.semiAxisB = 100
        XCTAssertEqual(RingCalibration.refusals(fit, highTensionVolts: 200_000), [], "0.092")
        fit.semiAxisA = 100; fit.semiAxisB = 109.2
        XCTAssertEqual(RingCalibration.refusals(fit, highTensionVolts: 200_000), [], "0.092, swapped")
        fit.semiAxisA = 109.4; fit.semiAxisB = 100
        XCTAssertEqual(RingCalibration.refusals(fit, highTensionVolts: 200_000), [.excessiveEllipticity(109.4 / 100 - 1)], "0.094")
        fit.semiAxisA = 100; fit.semiAxisB = 109.4
        XCTAssertEqual(RingCalibration.refusals(fit, highTensionVolts: 200_000), [.excessiveEllipticity(109.4 / 100 - 1)], "0.094, swapped")
    }

    /// No high tension: refused by name (the refusal that leaves Δq given), and the same fit with V is not.
    /// RED UNDER: V defaulted to 200 kV.
    func testAMissingHighTensionIsRefusedByName() {
        XCTAssertEqual(RingCalibration.refusals(cleanFit(), highTensionVolts: nil), [.noHighTension])
        XCTAssertEqual(RingCalibration.refusals(cleanFit(), highTensionVolts: 80_000), [])
    }

    /// A NaN would pass every `>` comparison; the numbers are checked first, and the answer is `.invalidInput` alone.
    /// RED UNDER: the validity guard removed (a NaN residual, a NaN axis, a zero annulus width or a 40-bin count
    /// then pass every refusal).
    func testNumbersThatAreNotFiniteAndPositiveAreInvalidInputNotAcceptedFits() {
        func only(_ change: (inout RingCalibration.FitReport) -> Void, volts: Double? = 200_000, _ what: String,
                  file: StaticString = #filePath, line: UInt = #line) {
            var fit = cleanFit()
            change(&fit)
            let got = RingCalibration.refusals(fit, highTensionVolts: volts)
            XCTAssertEqual(got.map(\.name), ["invalidInput"], what, file: file, line: line)
        }
        only({ $0.normalizedResidual = .nan }, "residual NaN")
        only({ $0.normalizedResidual = -0.1 }, "residual negative")
        only({ $0.semiAxisA = .nan }, "axis NaN")
        only({ $0.semiAxisB = 0 }, "axis zero")
        only({ $0.annulusWidth = 0 }, "annulus width zero")
        only({ $0.innerSigma = .infinity }, "sigma infinite")
        only({ $0.outerSigma = -1 }, "sigma negative")
        only({ $0.occupiedAngularBins = 40 }, "more bins than there are")
        only({ $0.occupiedAngularBins = -1 }, "negative bins")
        only({ _ in }, volts: -200_000, "negative high tension")
        only({ _ in }, volts: .nan, "NaN high tension")
    }

    /// Several refusals at once are all listed, in the registered order: model, coverage, sigma, residual, ellipticity,
    /// high tension. Here all six, from a conic fit that carries sigmas (as a careless caller might pass).
    /// RED UNDER: the order changed; a refusal dropped from the list once an earlier one has fired (a first-match
    /// return).
    func testEveryRefusalThatAppliesIsListedInTheRegisteredOrder() {
        let fit = RingCalibration.FitReport(model: .conic, semiAxisA: 120, semiAxisB: 100, occupiedAngularBins: 20,
                                            sparseCoverage: true, normalizedResidual: 0.3, innerSigma: 50, outerSigma: 60,
                                            annulusWidth: 40)
        let got = RingCalibration.refusals(fit, highTensionVolts: nil)
        XCTAssertEqual(got.map(\.name), ["modelNotAsymmetricGaussian", "insufficientAngularCoverage", "sigmaAtAnnulusWidth",
                                         "excessiveResidual", "excessiveEllipticity", "noHighTension"])
        XCTAssertEqual(got.dropFirst(2).first, .sigmaAtAnnulusWidth(sigma: 60, annulusWidth: 40), "the larger sigma is the one reported")
    }

    /// Only a missing high tension and a ring beyond the Bragg limit leave Δq given; every other refusal withholds it.
    /// RED UNDER: `.noHighTension` or `.braggLimit` withholding Δq; any fit refusal not withholding it.
    func testOnlyTheWavelengthRefusalsLeaveDeltaQGiven() {
        let all: [RingCalibration.Refusal] = [
            .modelNotAsymmetricGaussian, .insufficientAngularCoverage(occupiedBins: 20), .sigmaAtAnnulusWidth(sigma: 50, annulusWidth: 40),
            .excessiveResidual(0.3), .excessiveEllipticity(0.12), .noHighTension, .braggLimit(lambdaOver2d: 1.003),
            .invalidInput("x"),
        ]
        XCTAssertEqual(all.filter { !$0.withholdsDeltaQ }.map(\.name), ["noHighTension", "braggLimit"])
    }

    /// Every refusal carries a one-sentence reason (no line break, one full stop at the end and none inside, apart
    /// from decimal points) and its own distinct name.
    /// RED UNDER: a case without a reason, or two cases sharing a name.
    func testEveryRefusalHasAOneSentenceReasonAndItsOwnName() {
        let all: [RingCalibration.Refusal] = [
            .modelNotAsymmetricGaussian, .insufficientAngularCoverage(occupiedBins: 20), .insufficientAngularCoverage(occupiedBins: 36),
            .sigmaAtAnnulusWidth(sigma: 243, annulusWidth: 40), .excessiveResidual(0.231), .excessiveEllipticity(0.12),
            .noHighTension, .braggLimit(lambdaOver2d: 1.003), .invalidInput("the ring radius must be a positive number of pixels"),
        ]
        for refusal in all {
            let reason = refusal.reason
            XCTAssertFalse(reason.isEmpty, refusal.name)
            XCTAssertTrue(reason.hasSuffix("."), "\(refusal.name): \(reason)")
            XCTAssertFalse(reason.contains("\n"), "\(refusal.name): one line")
            XCTAssertFalse(reason.dropLast().contains(". "), "\(refusal.name): one sentence: \(reason)")
            XCTAssertEqual(refusal.errorDescription, reason)
        }
        XCTAssertEqual(Set(all.map(\.name)).count, 8, "eight cases, eight names")
    }

    /// The bin bounds this file registers equal the fit's own constants (if a re-sync of the copied fit moves one, this
    /// goes red and the registration is re-read), and the residual and ellipticity caps are the registered 0.22 and 0.093.
    /// RED UNDER: either bin constant changed here, or in EllipseCalibration.swift by a re-sync; either cap moved.
    func testTheBoundsAreTheRegisteredOnesAndTheBinsTheFitsOwn() {
        XCTAssertEqual(RingCalibration.angularBinCount, EllipseCalibration.angularBinCount)
        XCTAssertEqual(RingCalibration.minimumOccupiedAngularBins, EllipseCalibration.degeneracyBoundBins)
        XCTAssertEqual(RingCalibration.maximumResidual, 0.22)
        XCTAssertEqual(RingCalibration.maximumEllipticity, 0.093)
    }

    /// The ellipticity bound is the derived one: at a/b − 1 = 0.093, (a + b)/2 over √(ab) − 1 is 9.886e-4 (< 1e-3), at
    /// 0.0936 it is 1.0009e-3, and at 0.1 it is 1.136e-3 (worked in 60-digit arithmetic: (2 + ε)/(2√(1 + ε)) − 1).
    /// RED UNDER: the bound moved without re-deriving it (0.10: 1.14e-3).
    func testTheEllipticityBoundIsWhereTheTwoMeansDifferByAThousandth() {
        func meanOverGeometric(_ epsilon: Double) -> Double { (2 + epsilon) / (2 * (1 + epsilon).squareRoot()) - 1 }
        XCTAssertEqual(meanOverGeometric(0.093), 9.8864669599e-4, accuracy: 1e-12)
        XCTAssertEqual(meanOverGeometric(0.0936), 1.0008890155e-3, accuracy: 1e-12)
        XCTAssertLessThan(meanOverGeometric(RingCalibration.maximumEllipticity), 1e-3)
        XCTAssertGreaterThan(meanOverGeometric(0.0936), 1e-3)
        XCTAssertGreaterThan(meanOverGeometric(0.1), 1.1e-3)
    }
}
