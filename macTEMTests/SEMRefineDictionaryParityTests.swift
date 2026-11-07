//
//  SEMRefineDictionaryParityTests.swift
//  The refinement of a dictionary-indexed map (macTEM#213) against kikuchipy 0.13.1 in
//  tools/parity/sem/references/m4/refine-dictionary-nickel-block: figure F9's 6 x 6 corrected block indexed against the Ni
//  dictionary (keep_n 5, two points left out by a navigation mask), then `refine_orientation` from each point's best match on
//  the dictionary's F15 detector, trust region 1°. The test hands the stored best matches over as a `DictionaryIndexing.Result`,
//  turns it into the app's `CrystalMap` (`Result.crystalMap`) and refines that map (`EBSDRefinement.refineOrientations(map:)`):
//  the points out of the data stay out, the others match kikuchipy under 0.1° (symmetry-reduced) with scores at rtol 1e-4,
//  as the Hough-started runs of `m4/refine-nickel-block` (D-SEM-87).
//  Red before: a dictionary map's masked points refined (they hold the identity) or its phase refused by the master's.
//

import Foundation
import FormatoCore
import TEMCore
import XCTest

nonisolated final class SEMRefineDictionaryParityTests: XCTestCase {

    func testRefiningADictionaryIndexedMapMatchesKikuchipy() throws {
        let ref = try SEMParityReference.load("m4/refine-dictionary-nickel-block")
        let mp = try EMsoftMasterPatternReader.read(url: try XCTUnwrap(ref.inputURL(1)), type: .ebsd, projection: .lambert, hemisphere: .both)
        let master = try EBSDRefinement.Master(mp, energy: try XCTUnwrap(ref.values["energy"] as? Double))
        let d = try XCTUnwrap(ref.values["detector"] as? [String: Any])
        let shape = try XCTUnwrap(d["shape"] as? [Int])
        let pc = try XCTUnwrap(d["pc"] as? [Double])
        let detector = EBSDDetectorGeometry(rows: shape[0], columns: shape[1], pixelSize: 1, binning: d["binning"] as? Int ?? 1,
                                            sampleTilt: try XCTUnwrap(d["sample_tilt"] as? Double),
                                            projectionCenters: [SIMD3(pc[0], pc[1], pc[2])])
        let pixels = shape[0] * shape[1]
        let p = try ref.array("patterns")
        let count = p.values.count / pixels
        XCTAssertEqual(count, 36)
        let patterns = EBSDRefinement.Patterns(count: count, pixels: pixels, values: p.values.map { Float($0) }, isFloat32: false)

        // The dictionary result: the best match of each point in the data, the identity and index -1 where the mask left it out.
        let inData = try ref.array("navigation_mask").values.map { $0 == 0 }
        let q = try ref.array("start_quaternions").values
        let starts = stride(from: 0, to: q.count, by: 4).map { SIMD4(q[$0], q[$0 + 1], q[$0 + 2], q[$0 + 3]) }
        let simIndices = try ref.array("start_simulation_indices").values.map { Int($0) }
        var rotations = [SIMD4<Double>](repeating: SIMD4(1, 0, 0, 0), count: count)
        var indices = [Int](repeating: -1, count: count), scores = [Double](repeating: .nan, count: count)
        var j = 0
        for i in 0 ..< count where inData[i] {
            rotations[i] = starts[j]; indices[i] = simIndices[j]; scores[i] = 0.5
            j += 1
        }
        XCTAssertEqual(j, starts.count)
        let result = DictionaryIndexing.Result(navigationShape: [6, 6], keepN: 1, isInData: inData, scores: scores,
                                               simulationIndices: indices, rotations: rotations)
        let phase = CrystalPhase(name: master.phase.name, spaceGroup: master.phase.spaceGroup, pointGroup: master.phase.pointGroup)
        let map = try result.crystalMap(phase: phase, stepSizes: [1.5, 1.5], scanUnit: "um")

        let refined = try EBSDRefinement.refineOrientations(map: map, patterns: patterns, detector: detector, master: master,
                                                           settings: .init(trustRegion: [1, 1, 1]))
        XCTAssertEqual(refined.isInData.map { $0 ? 1.0 : 0.0 }, try ref.array("refined_is_in_data").values)
        XCTAssertEqual(refined.scanUnit, "um")
        SEMAssertParity(refined.phaseIDs.map(Double.init), try ref.array("refined_phase_id"))

        let e = try ref.array("refined_euler").values
        let reference = stride(from: 0, to: e.count, by: 3).map { SIMD3(e[$0], e[$0 + 1], e[$0 + 2]) }
        let ours = Orientations(quaternions: refined.rotationsInData, symmetry: PointGroup.oh)
        let theirs = Orientations(quaternions: reference.map(RotationConversions.eu2qu), symmetry: PointGroup.oh)
        let angles = ours.angles(with: theirs).map { $0 * 180 / .pi }
        XCTAssertEqual(angles.count, 34)
        XCTAssertLessThan(angles.max()!, 0.1, "largest misorientation \(angles.max()!) degrees")
        SEMAssertParity(try XCTUnwrap(refined.property("scores")), try ref.array("refined_scores"))
    }
}
