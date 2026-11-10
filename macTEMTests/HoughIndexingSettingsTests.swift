//
//  HoughIndexingSettingsTests.swift
//  The Hough section's range rules (`HoughIndexingSettings.refusal`), the plan's refusals around them (`IndexingPlan.refusal`) and
//  the projection centre a run takes (`IndexingPlan.meanProjectionCenter`), #291. Each rule is asked at the value just inside its
//  range (no refusal) and just outside (its sentence, word for word as the room shows it under Index); the sigmas, the mask and
//  the tolerance are asked with NaN and both infinities too, which no way of writing a range may let through.
//  Red under: an off-by-one in a range, a `<` for a `<=`, a changed sentence, the rules asked in another order, the isFinite of
//  the projection centres dropped. A setting's own isFinite is not such a case: its comparisons refuse NaN and the infinities
//  already, so dropping it changes nothing.
//

import XCTest
import TEMCore

nonisolated final class HoughIndexingSettingsTests: XCTestCase {

    /// The room's defaults with one edit.
    private func settings(_ edit: (inout HoughIndexingSettings) -> Void) -> HoughIndexingSettings {
        var settings = HoughIndexingSettings.roomDefault
        edit(&settings)
        return settings
    }

    private static let nickel = IndexingPhase(name: "Ni", spaceGroup: 225, lattice: [3.52, 3.52, 3.52, 90, 90, 90], source: .preset)

    private static func detector(_ centres: [SIMD3<Double>]) -> EBSDDetectorGeometry {
        EBSDDetectorGeometry(rows: 60, columns: 60, projectionCenters: centres)
    }

    // MARK: - The settings' ranges

    func testTheRoomDefaultsCanRun() {
        XCTAssertNil(HoughIndexingSettings.roomDefault.refusal)
    }

    func testBandsRunFromThreeToThirty() {
        let sentence = "Bands runs from 3 to 30."
        XCTAssertEqual(settings { $0.bands = 2 }.refusal, sentence)
        XCTAssertNil(settings { $0.bands = 3 }.refusal)
        XCTAssertNil(settings { $0.bands = 30 }.refusal)
        XCTAssertEqual(settings { $0.bands = 31 }.refusal, sentence)
    }

    func testRhoBinsRunFromTenToSevenHundredTwenty() {
        let sentence = "ρ bins runs from 10 to 720."
        XCTAssertEqual(settings { $0.rhoBins = 9 }.refusal, sentence)
        XCTAssertNil(settings { $0.rhoBins = 10 }.refusal)
        XCTAssertNil(settings { $0.rhoBins = 720 }.refusal)
        XCTAssertEqual(settings { $0.rhoBins = 721 }.refusal, sentence)
    }

    func testThetaBinsRunFromEighteenToSevenHundredTwenty() {
        let sentence = "θ bins runs from 18 to 720."
        XCTAssertEqual(settings { $0.thetaBins = 17 }.refusal, sentence)
        XCTAssertNil(settings { $0.thetaBins = 18 }.refusal)
        XCTAssertNil(settings { $0.thetaBins = 720 }.refusal)
        XCTAssertEqual(settings { $0.thetaBins = 721 }.refusal, sentence)
    }

    /// Either sigma alone refuses: 0, a negative, anything above 20, NaN and both infinities.
    func testTheKernelSigmasArePositiveFiniteAndAtMostTwenty() {
        let sentence = "The kernel's σ θ and σ ρ are positive, at most 20 cells."
        let outside: [Double] = [0, -1, 20.0001, .nan, .infinity, -.infinity]
        for value in outside {
            XCTAssertEqual(settings { $0.thetaSigma = value }.refusal, sentence, "σ θ \(value)")
            XCTAssertEqual(settings { $0.rhoSigma = value }.refusal, sentence, "σ ρ \(value)")
        }
        let inside: [Double] = [.leastNonzeroMagnitude, 0.0001, 20]
        for value in inside {
            XCTAssertNil(settings { $0.thetaSigma = value }.refusal, "σ θ \(value)")
            XCTAssertNil(settings { $0.rhoSigma = value }.refusal, "σ ρ \(value)")
        }
    }

    /// 0 masks nothing and is allowed; 0.5 would mask every rho bin.
    func testTheRhoMaskIsAFractionFromZeroToUnderOneHalf() {
        let sentence = "The ρ mask is a fraction from 0 to under 0.5."
        let outside: [Double] = [-0.0001, 0.5, 0.75, .nan, .infinity, -.infinity]
        for value in outside {
            XCTAssertEqual(settings { $0.rhoMaskFraction = value }.refusal, sentence, "ρ mask \(value)")
        }
        let inside: [Double] = [0, 0.15, 0.4999]
        for value in inside {
            XCTAssertNil(settings { $0.rhoMaskFraction = value }.refusal, "ρ mask \(value)")
        }
    }

    func testTheAngleToleranceIsAboveZeroAndAtMostTenDegrees() {
        let sentence = "The tolerance is above 0° and at most 10°."
        let outside: [Double] = [0, -2, 10.01, .nan, .infinity, -.infinity]
        for value in outside {
            XCTAssertEqual(settings { $0.angleTolerance = value }.refusal, sentence, "tolerance \(value)")
        }
        let inside: [Double] = [.leastNonzeroMagnitude, 0.0001, 10]
        for value in inside {
            XCTAssertNil(settings { $0.angleTolerance = value }.refusal, "tolerance \(value)")
        }
    }

    func testEarlyExitRunsFromOneToThirtyBands() {
        let sentence = "Early exit runs from 1 to 30 bands."
        XCTAssertEqual(settings { $0.earlyExitBands = 0 }.refusal, sentence)
        XCTAssertNil(settings { $0.earlyExitBands = 1 }.refusal)
        XCTAssertNil(settings { $0.earlyExitBands = 30 }.refusal)
        XCTAssertEqual(settings { $0.earlyExitBands = 31 }.refusal, sentence)
    }

    /// With every rule broken the first in the section's order is named, and mending one names the next.
    func testTheFirstBrokenRuleIsTheOneNamed() {
        var broken = HoughIndexingSettings.roomDefault
        broken.bands = 0
        broken.rhoBins = 0
        broken.thetaBins = 0
        broken.thetaSigma = 0
        broken.rhoSigma = .nan
        broken.rhoMaskFraction = 0.5
        broken.angleTolerance = 0
        broken.earlyExitBands = 0
        XCTAssertEqual(broken.refusal, "Bands runs from 3 to 30.")
        broken.bands = 10
        XCTAssertEqual(broken.refusal, "ρ bins runs from 10 to 720.")
        broken.rhoBins = 90
        XCTAssertEqual(broken.refusal, "θ bins runs from 18 to 720.")
        broken.thetaBins = 180
        XCTAssertEqual(broken.refusal, "The kernel's σ θ and σ ρ are positive, at most 20 cells.")
        broken.thetaSigma = 2
        XCTAssertEqual(broken.refusal, "The kernel's σ θ and σ ρ are positive, at most 20 cells.", "σ ρ is still NaN")
        broken.rhoSigma = 2
        XCTAssertEqual(broken.refusal, "The ρ mask is a fraction from 0 to under 0.5.")
        broken.rhoMaskFraction = 0.15
        XCTAssertEqual(broken.refusal, "The tolerance is above 0° and at most 10°.")
        broken.angleTolerance = 2
        XCTAssertEqual(broken.refusal, "Early exit runs from 1 to 30 bands.")
        broken.earlyExitBands = 10
        XCTAssertNil(broken.refusal)
        XCTAssertEqual(broken, .roomDefault, "mended back to the defaults")
    }

    // MARK: - The plan

    /// The plan asks for a phase, then one that is on, then each phase on for its own refusal, then the settings, then a projection
    /// centre; a phase that is off is not asked.
    func testThePlanRefusesPhasesThenSettingsThenTheMissingCentre() {
        let detector = Self.detector([SIMD3(0.5, 0.5, 0.5)])
        let none = Self.detector([])
        let nickel = Self.nickel
        var off = nickel
        off.isOn = false
        var outside = nickel
        outside.spaceGroup = 231
        var outsideAndOff = outside
        outsideAndOff.isOn = false
        let twoBands = settings { $0.bands = 2 }

        XCTAssertNil(IndexingPlan.refusal(phases: [nickel], settings: .roomDefault, detector: detector))
        XCTAssertEqual(IndexingPlan.refusal(phases: [], settings: twoBands, detector: none),
                       "Add a phase first: from the file, a preset or a CIF.")
        XCTAssertEqual(IndexingPlan.refusal(phases: [off], settings: twoBands, detector: none), "Turn a phase on to index against it.")
        XCTAssertEqual(IndexingPlan.refusal(phases: [nickel, outside], settings: twoBands, detector: none),
                       "Ni: space group 231 is outside 1 to 230.")
        XCTAssertEqual(IndexingPlan.refusal(phases: [nickel, outsideAndOff], settings: twoBands, detector: none), "Bands runs from 3 to 30.",
                       "a phase that is off is not asked; the settings come before the centre")
        XCTAssertEqual(IndexingPlan.refusal(phases: [nickel], settings: .roomDefault, detector: none),
                       "The file states no projection centre, which Hough indexing needs.")
        XCTAssertEqual(IndexingPlan.refusal(phases: [nickel], settings: .roomDefault,
                                            detector: Self.detector([SIMD3(0.5, 0.5, 0.5), SIMD3(0.5, Double.nan, 0.5)])),
                       "The file states no projection centre, which Hough indexing needs.", "a centre that is not a number is none")
        XCTAssertNil(IndexingPlan.refusal(phases: [off, nickel], settings: .roomDefault, detector: detector), "one phase on is enough")
    }

    /// The run's centre is the mean of the file's (kikuchipy's `pc_average`): none without a centre, none when any component of any
    /// centre is NaN or infinite. The values are binary fractions, so the mean is exact.
    func testTheMeanProjectionCentreIsTheMeanOfTheFilesCentres() {
        XCTAssertNil(IndexingPlan.meanProjectionCenter(Self.detector([])))
        XCTAssertEqual(IndexingPlan.meanProjectionCenter(Self.detector([SIMD3(0.25, 0.5, 0.75)])), SIMD3<Double>(0.25, 0.5, 0.75))
        XCTAssertEqual(IndexingPlan.meanProjectionCenter(Self.detector([SIMD3(0.25, 0.5, 0.75), SIMD3(0.75, 0.25, 0.25)])),
                       SIMD3<Double>(0.5, 0.375, 0.5))
        let notNumbers: [Double] = [.nan, .infinity, -.infinity]
        for value in notNumbers {
            for axis in 0..<3 {
                var centre = SIMD3<Double>(0.5, 0.5, 0.5)
                centre[axis] = value
                XCTAssertNil(IndexingPlan.meanProjectionCenter(Self.detector([SIMD3(0.5, 0.5, 0.5), centre])), "\(value) on axis \(axis)")
                XCTAssertNil(IndexingPlan.meanProjectionCenter(Self.detector([centre])), "\(value) on axis \(axis), alone")
            }
        }
    }
}
