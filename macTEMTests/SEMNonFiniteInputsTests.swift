//
//  SEMNonFiniteInputsTests.swift
//  A NaN, a zero or a degenerate value reaching the SEM maths gives a not-indexed point, an empty result or a refusal in
//  words, never a trap or a loop that does not end (macEM 2.1.0 bundle B: #605 NaN and zero-length results, #608 loops
//  that never end). One test per site the audit named.
//  Red before: `UInt8(NaN)` and `Int(NaN)` trapped in the colour, vote, projection and writer casts; the QUEST quaternion
//  was normalised by a NaN or zero norm; `best!` trapped on a pattern with no start; the reflector walk never ended on a zero spacing bound;
//  `nodes(below:step:)` trapped on a NaN step; `stride(by: 0)` trapped on a result with keepN 0.
//

import Foundation
import FormatoCore
import TEMCore
import XCTest

nonisolated final class SEMNonFiniteInputsTests: XCTestCase {

    // MARK: - The conversions every site now goes through

    func testAByteFromNaNIsZeroAndTheEndsClamp() {
        XCTAssertEqual(CheckedConversion.unitByte(Double.nan), 0)
        XCTAssertEqual(CheckedConversion.unitByte(Float.nan), 0)
        XCTAssertEqual(CheckedConversion.unitByte(Double.infinity), 255)
        XCTAssertEqual(CheckedConversion.unitByte(-Double.infinity), 0)
        XCTAssertEqual(CheckedConversion.unitByte(0.5), 128)
        XCTAssertEqual(CheckedConversion.unitByte(1.0), 255)
    }

    func testAnIntFromNaNInfinityOrOutOfRangeIsNilAndOtherwiseTruncates() {
        XCTAssertNil(CheckedConversion.int(.nan))
        XCTAssertNil(CheckedConversion.int(.infinity))
        XCTAssertNil(CheckedConversion.int(1e300))
        XCTAssertEqual(CheckedConversion.int(-2.7), -2)
        XCTAssertEqual(CheckedConversion.int(2.7), 2)
    }

    // MARK: - #605

    /// `IPFKeyImage.premultipliedRGBA8` and the key image itself: a step that is not a number draws an empty key.
    func testAKeyImageWithANaNOrZeroStepIsEmpty() {
        let key = DirectionColorKeyTSL(.oh)
        for step in [Double.nan, 0, -1, 1e-12] {
            let image = key.keyImage(step: step)
            XCTAssertEqual(image.width * image.height, 0, "step \(step)")
            XCTAssertTrue(image.premultipliedRGBA8.isEmpty, "step \(step)")
        }
        let drawn = key.keyImage(step: 0.05)
        XCTAssertGreaterThan(drawn.width * drawn.height, 0)
        XCTAssertEqual(drawn.premultipliedRGBA8.count, drawn.width * drawn.height * 4)
    }

    func testVirtualBSERGBWithANaNTileIsDrawnNotTrapped() {
        let red: [Float] = [1, .nan, 3, 4], green: [Float] = [4, 3, 2, 1], blue: [Float] = [1, 2, 3, 4]
        XCTAssertEqual(VirtualBSEImaging.rgb(red: red, green: green, blue: blue).count, 12)
    }

    func testTheANGColumnWidthOfANaNOrInfiniteColumnIsThatOfNaN() {
        XCTAssertEqual(ANGWriter.width(.nan), 10)
        XCTAssertEqual(ANGWriter.width(.infinity), 10)
        XCTAssertEqual(ANGWriter.width(123.4), 10)
        XCTAssertEqual(ANGWriter.width(0.5), 8)
    }

    func testQUESTOnNaNBandNormalsIsNotIndexed() {
        // Three weighted bands whose normals are not numbers: the quaternion's norm is NaN, so there is no rotation.
        let nan = SIMD3<Double>(.nan, .nan, .nan), pole = SIMD3<Double>(0, 0, 1)
        let result = HoughIndexer.quest(poles: [pole, pole, pole], normals: [nan, nan, nan], weights: [1, 1, 1])
        XCTAssertEqual(result.meanDot, -1)
        XCTAssertEqual(result.quaternion, SIMD4(1, 0, 0, 0))
    }

    func testAMasterPatternSampleOfANaNDirectionIsNaN() {
        let side = 5
        let plane = [Float](repeating: 1, count: side * side)
        plane.withUnsafeBufferPointer { up in
            let value = MasterPatternProjection.sample(SIMD4(1, 0, 0, 0), SIMD3(.nan, .nan, .nan), upper: up, lower: up,
                                                       side: side, scale: 2)
            XCTAssertTrue(value.isNaN)
            let nanRotation = MasterPatternProjection.sample(SIMD4(.nan, 0, 0, 0), SIMD3(0, 0, 1), upper: up, lower: up,
                                                             side: side, scale: 2)
            XCTAssertTrue(nanRotation.isNaN)
        }
    }

    func testAPatternWithNoStartingOrientationIsRefusedByNameAndAPCAtZRunsToTheEnd() throws {
        let b = try Self.oneNickelPattern()
        XCTAssertThrowsError(try EBSDRefinement.refineOrientations(b.patterns, starts: [[]], detector: b.detector, master: b.master)) {
            XCTAssertEqual($0 as? EBSDRefinement.Error, .noStart(0))
        }
        XCTAssertThrowsError(try EBSDRefinement.refineOrientationsAndProjectionCenters(b.patterns, starts: [[]], detector: b.detector,
                                                                                         master: b.master)) {
            XCTAssertEqual($0 as? EBSDRefinement.Error, .noStart(0))
        }
        // The refinement bounds reach PC z = 0, where every direction is NaN: the objective scores that as the worst match.
        let dc = [SIMD3<Double>](repeating: SIMD3(.nan, .nan, .nan), count: b.patterns.pixels)
        let experiment = [Float](repeating: 0, count: b.patterns.pixels)
        XCTAssertEqual(EBSDRefinement.objective(SIMD4(1, 0, 0, 0), dc, experiment: experiment, squaredNorm: 1, master: b.master), 2)
        var atZero = b.detector
        atZero.projectionCenters = [SIMD3(0.5, 0.5, 0)]
        let refined = try EBSDRefinement.refineProjectionCenters(b.patterns, rotations: [RotationConversions.eu2qu(b.start)],
                                                                 detector: atZero, master: b.master)
        XCTAssertEqual(refined.count, 1)
    }

    // MARK: - #608

    func testAReflectorWalkOnAZeroOrNaNBoundOrADegenerateLatticeEndsWithNoPlane() throws {
        let nickel = try XCTUnwrap(CrystalLattice(parameters: [3.52, 3.52, 3.52, 90, 90, 90]))
        for bound in [0, -1, Double.nan, 1e-9] {
            let started = Date()
            XCTAssertEqual(KikuchiReflectors.minDSpacing(bound, lattice: nickel).count, 0, "bound \(bound)")
            XCTAssertLessThan(Date().timeIntervalSince(started), 5, "bound \(bound)")
        }
        XCTAssertGreaterThan(KikuchiReflectors.minDSpacing(1, lattice: nickel).count, 0)
    }

    func testAReflectorLibraryOnAnInfiniteOrOverflowingLatticeIsRefused() {
        for lattice in [[Double.infinity, 1, 1, 90, 90, 90], [1e300, 1e300, 1e300, 90, 90, 90], [1, 1, 1, .nan, 90, 90]] {
            XCTAssertThrowsError(try HoughReflectorLibrary(name: "x", spaceGroup: 225, lattice: lattice)) {
                XCTAssertEqual($0 as? HoughReflectorLibrary.Error, .lattice, "\(lattice)")
            }
        }
    }

    func testODFNodesOnANaNZeroOrTooFineStepAreNone() {
        XCTAssertEqual(OrientationDensity.nodes(below: 360, step: .nan), [])
        XCTAssertEqual(OrientationDensity.nodes(below: 360, step: 0), [])
        XCTAssertEqual(OrientationDensity.nodes(below: 360, step: -5), [])
        XCTAssertEqual(OrientationDensity.nodes(below: 360, step: 1e-9), [])
        XCTAssertEqual(OrientationDensity.nodes(below: 360, step: .infinity), [])
        XCTAssertEqual(OrientationDensity.nodes(below: 20, step: 5), [0, 5, 10, 15])
    }

    func testADictionaryResultWithKeepNZeroGivesItsBestWithoutATrap() {
        let result = DictionaryIndexing.Result(navigationShape: [1, 2], keepN: 0, isInData: [true, true], scores: [0.5, 0.25],
                                               simulationIndices: [3, 4], rotations: [SIMD4(1, 0, 0, 0), SIMD4(1, 0, 0, 0)])
        XCTAssertEqual(result.bestScores, [0.5, 0.25])
        XCTAssertEqual(result.bestSimulationIndices, [3, 4])
        XCTAssertEqual(result.bestRotations.count, 2)
    }

    // MARK: - Fixture

    private struct OnePattern {
        let patterns: EBSDRefinement.Patterns
        let detector: EBSDDetectorGeometry
        let master: EBSDRefinement.Master
        let start: SIMD3<Double>
    }

    /// The first pattern of the refinement parity block (`m4/refine-nickel-block`), its detector and master pattern.
    private static func oneNickelPattern() throws -> OnePattern {
        let ref = try SEMParityReference.load("m4/refine-nickel-block")
        let mpURL = try XCTUnwrap(ref.inputURL(1))
        let mp = try EMsoftMasterPatternReader.read(url: mpURL, type: .ebsd, projection: .lambert, hemisphere: .both)
        let master = try EBSDRefinement.Master(mp, energy: try XCTUnwrap(ref.values["energy"] as? Double))
        let d = try XCTUnwrap(ref.values["detector"] as? [String: Any])
        let shape = try XCTUnwrap(d["shape"] as? [Int])
        let pc = try XCTUnwrap(d["pc"] as? [Double])
        let detector = EBSDDetectorGeometry(rows: shape[0], columns: shape[1], pixelSize: try XCTUnwrap(d["px_size"] as? Double),
                                            binning: try XCTUnwrap(d["binning"] as? Int), tilt: try XCTUnwrap(d["tilt"] as? Double),
                                            azimuthal: try XCTUnwrap(d["azimuthal"] as? Double),
                                            twist: try XCTUnwrap(d["twist"] as? Double),
                                            sampleTilt: try XCTUnwrap(d["sample_tilt"] as? Double),
                                            projectionCenters: [SIMD3(pc[0], pc[1], pc[2])])
        let pixels = shape[0] * shape[1]
        let values = try ref.array("patterns").values.prefix(pixels).map { Float($0) }
        let start = try ref.array("start_euler").values
        return OnePattern(patterns: EBSDRefinement.Patterns(count: 1, pixels: pixels, values: values, isFloat32: false),
                          detector: detector, master: master, start: SIMD3(start[0], start[1], start[2]))
    }
}
