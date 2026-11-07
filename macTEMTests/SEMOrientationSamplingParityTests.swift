//
//  SEMOrientationSamplingParityTests.swift
//  TEMCore's `OrientationSampling` (Sources/TEMCore/SEM/Orientation/OrientationSampling.swift) against orix 0.15.0's
//  cubochoric sampling through the committed bundle `m3/orientation-sampling` (tools/parity/sem/emit.py, inputs
//  tools/parity/sem/fixtures/sampling_inputs.json). Counts and semi-edge steps exact; rotations within atol 1e-7 in orix's
//  order (every stride-th row and the last of each sample, the bundle's `stride`). Red before the port: the type does not
//  exist. Red after a changed loop order, a missed normalisation, a zone boundary taken strictly or a local width taken
//  inclusively: the counts or the rows move.
//

import TEMCore
import XCTest

nonisolated final class SEMOrientationSamplingParityTests: XCTestCase {

    private func flat(_ rotations: [Rotation]) -> [Double] { rotations.flatMap { [$0.q[0], $0.q[1], $0.q[2], $0.q[3]] } }

    /// The rows the bundle keeps of a sample: indices 0, stride, 2·stride, ... and the last one.
    private func strided(_ rotations: [Rotation], stride step: Int) -> [Rotation] {
        var idx = Array(Swift.stride(from: 0, to: rotations.count, by: step))
        if let last = idx.last, last != rotations.count - 1 { idx.append(rotations.count - 1) }
        return idx.map { rotations[$0] }
    }

    func testSemiEdgeStepsMatchOrix() throws {
        let ref = try SEMParityReference.load("m3/orientation-sampling")
        let resolutions = try XCTUnwrap(ref.values["semi_edge_resolutions"] as? [Double])
        let steps = try XCTUnwrap(ref.values["semi_edge_steps"] as? [Int])
        XCTAssertEqual(try resolutions.map { try OrientationSampling.semiEdgeSteps(resolution: $0) }, steps)
    }

    func testFullCubochoricGridMatchesOrix() throws {
        let ref = try SEMParityReference.load("m3/orientation-sampling")
        let grid = OrientationSampling.cubochoricGrid(semiEdgeSteps: 3)
        XCTAssertEqual(grid.count, 216)   // (2N)³: the loop runs −N+1 ... N
        SEMAssertParity(flat(grid), try ref.array("full_grid"))
    }

    func testFundamentalSamplesMatchOrix() throws {
        let ref = try SEMParityReference.load("m3/orientation-sampling")
        let cases = try XCTUnwrap(ref.values["fundamental"] as? [[String: Any]])
        XCTAssertEqual(cases.count, 7)
        for (i, c) in cases.enumerated() {
            let name = try XCTUnwrap(c["point_group"] as? String)
            let group = try XCTUnwrap(PointGroup.named(name), name)
            let resolution = try XCTUnwrap(c["resolution"] as? Double)
            let sample = try OrientationSampling.fundamental(resolution: resolution, pointGroup: group)
            XCTAssertEqual(sample.count, try XCTUnwrap(c["count"] as? Int), "\(name) at \(resolution)°")
            let rows = strided(sample, stride: try XCTUnwrap(c["stride"] as? Int))
            SEMAssertParity(flat(rows), try ref.array(String(format: "fundamental_%02d", i)))
        }
    }

    func testLocalSamplesMatchOrix() throws {
        let ref = try SEMParityReference.load("m3/orientation-sampling")
        let cases = try XCTUnwrap(ref.values["local"] as? [[String: Any]])
        let url = SEMParityReference.fixturesRoot.appendingPathComponent("sampling_inputs.json")
        let inputs = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let local = try XCTUnwrap(inputs["local"] as? [[String: Any]])
        XCTAssertEqual(cases.count, local.count)
        for (i, c) in cases.enumerated() {
            let center = (local[i]["center_euler_degrees"] as? [Double]).map {
                Rotation.fromEuler(SIMD3($0[0], $0[1], $0[2]), degrees: true)
            }
            let sample = try OrientationSampling.local(resolution: try XCTUnwrap(c["resolution"] as? Double), center: center,
                                                       gridWidth: try XCTUnwrap(c["grid_width"] as? Double))
            XCTAssertEqual(sample.count, try XCTUnwrap(c["count"] as? Int), "local \(i)")
            let rows = strided(sample, stride: try XCTUnwrap(c["stride"] as? Int))
            SEMAssertParity(flat(rows), try ref.array(String(format: "local_%02d", i)))
        }
    }

    func testResolutionAndWidthOutsideTheRuleAreRefused() {
        XCTAssertThrowsError(try OrientationSampling.semiEdgeSteps(resolution: 0.03)) {
            XCTAssertEqual($0 as? OrientationSampling.Error, .resolutionOutOfRange(0.03))
        }
        XCTAssertThrowsError(try OrientationSampling.semiEdgeSteps(resolution: .nan))
        XCTAssertThrowsError(try OrientationSampling.semiEdgeSteps(resolution: 1000))   // N rounds to 0
        XCTAssertThrowsError(try OrientationSampling.local(resolution: 2, gridWidth: 0)) {
            XCTAssertEqual($0 as? OrientationSampling.Error, .gridWidthOutOfRange(0))
        }
    }

    func testConcurrentSampleEqualsTheSerialOne() async throws {
        let serial = try OrientationSampling.fundamental(resolution: 10, pointGroup: PointGroup.oh)
        let concurrent = try await OrientationSampling.fundamentalSample(resolution: 10, pointGroup: PointGroup.oh)
        XCTAssertEqual(serial, concurrent)
    }
}
