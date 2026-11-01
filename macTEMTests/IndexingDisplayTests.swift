import XCTest
import DiffractoCore
import DiffractoScattering
import DiffractoGeometry
import TEMCore

/// A ring's indexing as the Diffraction room displays it (R6): the kit's `RingIndexing` decision over Au's kinematic list
/// at k_max 1.2 with the derived numbers, pinned to tools/parity/diffraction-room-parity's decimal values (Au {111} 2.35454986780913 A,
/// {311} 1.2296235654570355 A). The 2646 plants are the harness (R6); its controls (delta-over-measured, pct-x10, tol-fraction,
/// odds-margin, z-no-tol, sigma-pct) are the emulated forms of the mutations named in each test.
/// Every pinned constant below is copied from the T1 plant records of reference.json written by tools/parity/diffraction-room-parity/reference.py (numpy 2.5.4, 60-digit decimal chain; no Swift output), not from the Swift run.
nonisolated final class IndexingDisplayTests: XCTestCase {

    private static let au: KinematicReflectionList = {
        guard let list = try? StandardCrystals.list(of: StandardCrystals.named("Au")!, kMax: 1.2) else { fatalError("no Au list") }
        return list
    }()

    private func relative(_ x: Double, _ truth: Double) -> Double { abs(x - truth) / abs(truth) }

    /// Au {111} read 2.9 sigma off at a 0.1 % tolerance: the first T1 plant, every displayed number against the decimal reference.
    /// Red under: delta over the measured d, percent x10, z without the tolerance, sigma_q in percent.
    func testAcceptedRingDisplaysTheReferenceNumbers() throws {
        let q = 0.42347797072898036
        let shown = IndexingDisplay.index(q: q, tolerancePercent: 0.1, in: Self.au)
        XCTAssertEqual(shown.verdict, "accepted")
        XCTAssertTrue(shown.isAccepted)
        XCTAssertEqual(try XCTUnwrap(shown.family).name, "{1 1 1}")
        XCTAssertLessThan(relative(shown.sigmaQ, 0.0004234779707289804), 1e-12)
        XCTAssertLessThan(relative(try XCTUnwrap(shown.deltaPercent), 0.2908434459933767), 1e-12)
        XCTAssertLessThan(relative(try XCTUnwrap(shown.relativeDeltaD), 0.002908434459933767), 1e-12)
        XCTAssertLessThan(relative(try XCTUnwrap(shown.z), 2.908434459933767), 1e-12)
        XCTAssertLessThan(relative(try XCTUnwrap(shown.dListed), 2.3545498678091317), 1e-12)
        XCTAssertLessThan(relative(try XCTUnwrap(shown.dMeasured), 2.3613979217823005), 1e-12)
        XCTAssertLessThan(relative(try XCTUnwrap(shown.margin), 12487.079895768495), 1e-12)
    }

    /// δ is signed: a ring read larger in q (smaller in d) than its family has δ > 0 ... g/q - 1 < 0 when q > g. Pinned on the {311} plant
    /// at s = +0.5, u = 1 %, whose delta is -0.4975124378109339 %. Red under: the sign flipped (delta over the measured d changes the value).
    func testDeltaIsSignedAndRelativeDeltaIsItsMagnitude() throws {
        let shown = IndexingDisplay.index(q: 0.8173233079072082, tolerancePercent: 1, in: Self.au)
        XCTAssertEqual(shown.verdict, "accepted")
        XCTAssertLessThan(relative(try XCTUnwrap(shown.deltaPercent), -0.4975124378109339), 1e-12)
        XCTAssertLessThan(relative(try XCTUnwrap(shown.relativeDeltaD), 0.004975124378109339), 1e-12)
    }

    /// Odds are exp(margin): finite below 10^6 : 1 and shown as a number. Red under: odds = margin.
    func testOddsAreExpMarginBelowTheCap() throws {
        let shown = IndexingDisplay.index(q: 0.8091907376792759, tolerancePercent: 1, in: Self.au)      // {311}, s = -0.5, u = 1 %
        let odds = try XCTUnwrap(shown.odds)
        XCTAssertLessThan(relative(odds, 205130.62032162675), 1e-12)
        XCTAssertLessThan(relative(try XCTUnwrap(shown.margin), 12.23140222751308), 1e-12)
        XCTAssertFalse(shown.oddsBeyondCap)
        XCTAssertEqual(shown.oddsText, "2.05e+05 : 1")
    }

    /// Beyond 10^6 : 1 the room shows the cap, and exp overflow (margin past 709) is infinity, still the cap.
    func testOddsBeyondAMillionShowTheCap() throws {
        let shown = IndexingDisplay.index(q: 0.42347797072898036, tolerancePercent: 0.1, in: Self.au)      // margin 12487
        XCTAssertEqual(try XCTUnwrap(shown.odds), .infinity)
        XCTAssertTrue(shown.oddsBeyondCap)
        XCTAssertEqual(shown.oddsText, "> 10⁶ : 1")
        XCTAssertEqual(DisplayedIndexing.oddsCapLabel, "> 10⁶ : 1")
    }

    /// The tolerance is a percent of q as typed: sigma = q tol / 100. Red under: the tolerance taken as a fraction.
    func testToleranceIsPercentOfQ() {
        let q = 0.5
        XCTAssertEqual(IndexingDisplay.index(q: q, tolerancePercent: 0.3, in: Self.au).sigmaQ, q * 0.3 / 100)
        XCTAssertEqual(IndexingDisplay.index(q: q, tolerancePercent: 2, in: Self.au).sigmaQ, q * 2 / 100)
        XCTAssertTrue(IndexingDisplay.index(q: .nan, tolerancePercent: 2, in: Self.au).sigmaQ.isNaN)
    }

    /// Every refusal by its kit name, with the kit's own sentence, and nothing displayed as a number.
    func testRefusalsCarryTheKitsNameAndText() {
        let g311 = Self.au.families[3].family.g
        let g331 = Self.au.families[6].family.g
        let cases: [(Double, Double, String)] = [
            (g331, 1.0, "ambiguous"),                    // {331} and {420} both within 3 sigma at 1 %
            (1 / 4.0782, 0.1, "noneWithinTolerance"),    // Au {100} is forbidden
            (1.25, 0.1, "beyondKMax"),                   // the list ends at 1.2
            (0, 0.1, "invalidInput"),
            (g311, -1, "invalidInput"),
        ]
        for (q, tolerance, name) in cases {
            let shown = IndexingDisplay.index(q: q, tolerancePercent: tolerance, in: Self.au)
            XCTAssertEqual(shown.verdict, name, "q \(q) tolerance \(tolerance)")
            XCTAssertFalse(shown.isAccepted)
            XCTAssertNil(shown.family)
            XCTAssertNil(shown.deltaPercent)
            XCTAssertNil(shown.odds)
            XCTAssertEqual(shown.oddsText, "—")
            XCTAssertEqual(shown.refusalText, shown.refusal?.reason)
            XCTAssertEqual(shown.refusal?.name, name)
        }
    }

    /// The product reports the kit's label: validation none, never called validated.
    func testIndexingReportsValidationNone() {
        let shown = IndexingDisplay.index(q: 0.42470962865207135, tolerancePercent: 0.1, in: Self.au)
        XCTAssertTrue(shown.validation.hasPrefix("none"))
        XCTAssertEqual(shown.validation, RingIndexing.validation)
        XCTAssertFalse(shown.validation.lowercased().contains("validated"))
    }
}
