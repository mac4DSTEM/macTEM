//
//  SessionMarksTests.swift
//  The marks of the session sidecar (the core; "A mark's node"): a mark to its lineage
//  node and back (the points as pixel coordinates, x the column and y the row, a pixel's centre at integers; an angle's
//  vertex is point 2; a profile's width; the results in the file's own units at full precision), the checks a node passes
//  (the coordinate grammar, the inclusive image bounds, the width, the keys) with the refusal naming the node, the
//  calibration note, the restore (a read sidecar to marks, whole or one named refusal, never partial) and the save (the
//  request's checks; the write's changed-on-disk rule against a real sidecar written with HDF5). Planted axes are
//  anisotropic and, where units matter, mixed, on a 40 × 24 image (not square, so an x checked against the height shows).
//  No Python here: tools/parity/sidecar-parity reads the same nodes with h5py. Each test names the mutation of SessionMarks.swift
//  it was broken by ("Red under: ..."); the sweep is in the session's log, not here.
//

import ImagoCore
import XCTest
import Foundation
import TEMCore

nonisolated final class SessionMarksTests: XCTestCase {
    private let t0: Int64 = 1_791_900_000_123
    private let object = "ImageList.2 \u{00B7} HAADF"
    private let width = 40, height = 24
    private let digest = String(repeating: "ab", count: 32)
    private let micro = "\u{00B5}m"

    // The axes: 0.5 nm per column, 2.0 nm per row (anisotropic, one unit); the same columns with a row in µm (mixed units).
    private var nmWide: AxisCalibration { AxisCalibration(scale: 0.5, unit: "nm", origin: 0) }
    private var nmTall: AxisCalibration { AxisCalibration(scale: 2.0, unit: "nm", origin: 0) }
    private var microTall: AxisCalibration { AxisCalibration(scale: 0.002, unit: micro, origin: 0) }

    // MARK: - Builders

    private func identity(name: String = "scan.dm4", bytes: Int64 = 4096, object: String? = nil, width: Int? = nil,
                          height: Int? = nil, digest: String? = nil) -> SessionSourceIdentity {
        SessionSourceIdentity(fileName: name, byteSize: bytes, object: object ?? self.object, width: width ?? self.width,
                              height: height ?? self.height, pixelSHA256: digest ?? self.digest)
    }

    /// A mark node's parameters written out by hand, as the format states them.
    private var distanceParameters: [String: String] {
        ["x1": "2.5", "y1": "1.25", "x2": "30.75", "y2": "17.5", "object": object, "frame": "0"]
    }
    private var angleParameters: [String: String] {
        ["x1": "10.5", "y1": "3.25", "x2": "4.0", "y2": "12.75", "x3": "34.25", "y3": "20.5", "object": object, "frame": "0"]
    }
    private var profileParameters: [String: String] { distanceParameters.merging(["width": "7"]) { _, new in new } }

    private func node(_ id: String = "s1", _ kind: String = "distance", _ parameters: [String: String],
                      results: [String: String] = [:], removed: Int64? = nil) -> SessionLineage.Node {
        SessionLineage.Node(id: id, kind: kind, parameters: parameters, results: results, recorded: t0, removed: removed)
    }

    private func with(_ parameters: [String: String], _ key: String, _ value: String?) -> [String: String] {
        var copy = parameters
        copy[key] = value
        return copy
    }

    /// A lineage of `nodes` in order (ids s1, s2, …), added as the owner adds them.
    private func lineage(_ nodes: [(kind: String, parameters: [String: String])]) throws -> SessionLineage {
        var lineage = SessionLineage()
        for (offset, entry) in nodes.enumerated() {
            try lineage.add(kind: entry.kind, parameters: entry.parameters, recorded: t0 + Int64(offset))
        }
        return lineage
    }

    private func contents(_ lineage: SessionLineage, stored: SessionSourceIdentity? = nil) throws -> SessionSidecarFile.Contents {
        SessionSidecarFile.Contents(schema: 1, minReader: 1, source: try (stored ?? identity()).jsonString(),
                                    lineage: try lineage.jsonString())
    }

    private func markRefusal(_ node: SessionLineage.Node, width: Int? = nil, height: Int? = nil) -> SessionMarks.Refusal? {
        do throws(SessionMarks.Refusal) {
            _ = try SessionMarks.mark(of: node, width: width ?? self.width, height: height ?? self.height, object: object)
            return nil
        } catch { return error }
    }

    private func mark(of node: SessionLineage.Node, width: Int? = nil, height: Int? = nil, object: String? = nil,
                      file: StaticString = #filePath, line: UInt = #line) -> SessionMark? {
        do throws(SessionMarks.Refusal) {
            return try SessionMarks.mark(of: node, width: width ?? self.width, height: height ?? self.height,
                                         object: object ?? self.object)
        } catch {
            XCTFail("refused: \(error)", file: file, line: line)
            return nil
        }
    }

    private func restoreRefusal(_ contents: SessionSidecarFile.Contents, opened: SessionSourceIdentity? = nil,
                                x: AxisCalibration? = nil, y: AxisCalibration? = nil) -> SessionRestore.Refusal? {
        do throws(SessionRestore.Refusal) {
            _ = try SessionRestore.restore(contents, opened: opened ?? identity(), x: x, y: y)
            return nil
        } catch { return error }
    }

    private func restored(_ contents: SessionSidecarFile.Contents, opened: SessionSourceIdentity? = nil, x: AxisCalibration? = nil,
                          y: AxisCalibration? = nil, file: StaticString = #filePath, line: UInt = #line) -> SessionRestore.Restored? {
        do throws(SessionRestore.Refusal) {
            return try SessionRestore.restore(contents, opened: opened ?? identity(), x: x, y: y)
        } catch {
            XCTFail("refused: \(error)", file: file, line: line)
            return nil
        }
    }

    private func saveRequestRefusal(_ lineage: SessionLineage, identity: SessionSourceIdentity? = nil) -> SessionSave.Refusal? {
        do throws(SessionSave.Refusal) {
            _ = try SessionSave.request(identity: identity ?? self.identity(), lineage: lineage, revision: 1,
                                        expectedOnDisk: nil, replacing: false)
            return nil
        } catch { return error }
    }

    private func saveRequest(_ lineage: SessionLineage, expected: String? = nil, replacing: Bool = false, revision: Int = 3,
                             file: StaticString = #filePath, line: UInt = #line) -> SessionSave.Request? {
        do throws(SessionSave.Refusal) {
            return try SessionSave.request(identity: identity(), lineage: lineage, revision: revision,
                                           expectedOnDisk: expected, replacing: replacing)
        } catch {
            XCTFail("refused: \(error)", file: file, line: line)
            return nil
        }
    }

    private func assertBitEqual(_ a: [ImagePoint], _ b: [ImagePoint], _ message: String = "",
                                file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.map(\.x.bitPattern), b.map(\.x.bitPattern), "x \(message)", file: file, line: line)
        XCTAssertEqual(a.map(\.y.bitPattern), b.map(\.y.bitPattern), "y \(message)", file: file, line: line)
    }

    private func number(_ results: [String: String], _ key: String, file: StaticString = #filePath, line: UInt = #line) -> Double {
        guard let text = results[key], let value = Double(text) else {
            XCTFail("no number at \(key) in \(results)", file: file, line: line)
            return .nan
        }
        return value
    }

    private struct SplitMix64 {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    // MARK: - A mark to its node

    func testTheKindsAreTheLineagesVocabularyAndTakeTheirPoints() {
        XCTAssertEqual(SessionMark.Kind.allCases.map(\.rawValue), [SessionLineage.Kind.distance, SessionLineage.Kind.angle,
                                                                   SessionLineage.Kind.profile])
        XCTAssertEqual(SessionMark.Kind.allCases.map(\.pointCount), [2, 3, 2])
        XCTAssertEqual(SessionMarks.maximumWidth, 25)
        XCTAssertEqual(SessionMarks.openedFrame, "0")
        // Red under: a raw value renamed ("line"), or the angle's third point lost.
    }

    func testADistanceNodeHoldsItsPointsAsColumnThenRowInPixelCoordinates() {
        let mark = SessionMark(kind: .distance, points: [ImagePoint(x: 2.5, y: 1.25), ImagePoint(x: 30.75, y: 17.5)])
        XCTAssertEqual(SessionMarks.parameters(of: mark, object: object), distanceParameters)
        XCTAssertEqual(SessionMarks.parameters(of: mark, object: "other", frame: "3")["object"], "other")
        XCTAssertEqual(SessionMarks.parameters(of: mark, object: "other", frame: "3")["frame"], "3")
        // Red under: x and y swapped (the writer alone, or the writer with the reader: a round trip would still pass).
    }

    func testAnAngleNodeHoldsItsVertexAsPoint2() {
        let mark = SessionMark(kind: .angle, points: [ImagePoint(x: 10.5, y: 3.25), ImagePoint(x: 4.0, y: 12.75),
                                                      ImagePoint(x: 34.25, y: 20.5)])
        XCTAssertEqual(SessionMarks.parameters(of: mark, object: object), angleParameters)
        // The angle is measured at point 2 (closed form below, numpy-checked): the pixel plane gives 69.98965679133444.
        let results = SessionMarks.results(of: mark, x: nil, y: nil, samples: nil)
        XCTAssertEqual(number(results, "degrees"), 69.98965679133444, accuracy: 69.98965679133444e-12)
        // Red under: the vertex taken as point 1 or point 3; the keys of points 2 and 3 exchanged.
    }

    func testOnlyAProfileHoldsAWidth() {
        let points = [ImagePoint(x: 2.5, y: 1.25), ImagePoint(x: 30.75, y: 17.5)]
        XCTAssertEqual(SessionMarks.parameters(of: SessionMark(kind: .profile, points: points, width: 7), object: object),
                       profileParameters)
        XCTAssertEqual(SessionMarks.parameters(of: SessionMark(kind: .profile, points: points, width: 25), object: object)["width"], "25")
        for kind in [SessionMark.Kind.distance, .angle] {
            let mark = SessionMark(kind: kind, points: kind == .angle ? points + [ImagePoint(x: 1, y: 1)] : points, width: 9)
            XCTAssertEqual(mark.width, 1, "\(kind)")
            XCTAssertNil(SessionMarks.parameters(of: mark, object: object)["width"], "\(kind)")
        }
        // Red under: the width written as 1; a width kept on a distance.
    }

    func testTheResultsOfADistanceAreFullPrecisionPixelsAndLengthInTheAxesUnit() {
        let mark = SessionMark(kind: .distance, points: [ImagePoint(x: 2.5, y: 1.25), ImagePoint(x: 30.75, y: 17.5)])
        let results = SessionMarks.results(of: mark, x: nmWide, y: nmTall, samples: nil)
        // Δ = (28.25, 16.25) pixels; √((28.25·0.5)² + (16.25·2)²) with each axis's own scale (closed form, Python float64).
        XCTAssertEqual(number(results, "pixels"), 32.59025928095694, accuracy: 32.59025928095694e-12)
        XCTAssertEqual(number(results, "length"), 35.436783502456876, accuracy: 35.436783502456876e-12)
        XCTAssertGreaterThan(try XCTUnwrap(results["length"]).count, 15, "the full shortest round-trip text, not a display rounding")
        XCTAssertEqual(results["unit"], "nm")
        XCTAssertEqual(results["scale_x"], "0.5")
        XCTAssertEqual(results["scale_y"], "2.0")
        XCTAssertEqual(results["unit_x"], "nm")
        XCTAssertEqual(results["unit_y"], "nm")
        XCTAssertEqual(Set(results.keys), ["pixels", "length", "unit", "scale_x", "scale_y", "unit_x", "unit_y"])
        // Red under: scale_x and scale_y swapped (the isotropic 0.5/0.5 would hide it; these axes do not); unit_x and unit_y swapped.
    }

    func testMixedUnitsKeepNoLengthAndNoUnitButTheScalesOfBothAxes() {
        let mark = SessionMark(kind: .distance, points: [ImagePoint(x: 2.5, y: 1.25), ImagePoint(x: 30.75, y: 17.5)])
        let mixed = SessionMarks.results(of: mark, x: nmWide, y: microTall, samples: nil)
        XCTAssertEqual(Set(mixed.keys), ["pixels", "scale_x", "unit_x", "scale_y", "unit_y"])
        XCTAssertEqual(mixed["scale_y"], "0.002")
        XCTAssertEqual(mixed["unit_y"], micro)
        XCTAssertEqual(mixed["unit_x"], "nm")
        // One axis uncalibrated: pixels, and the other axis's scale; nothing for the one the file does not state.
        let half = SessionMarks.results(of: mark, x: nmWide, y: nil, samples: nil)
        XCTAssertEqual(Set(half.keys), ["pixels", "scale_x", "unit_x"])
        XCTAssertEqual(Set(SessionMarks.results(of: mark, x: nil, y: nmTall, samples: nil).keys), ["pixels", "scale_y", "unit_y"])
        XCTAssertEqual(Set(SessionMarks.results(of: mark, x: nil, y: nil, samples: nil).keys), ["pixels"])
        // An axis the file writes as scale 1, no unit (GMS's uncalibrated) is uncalibrated, and so is a scale of zero.
        let plain = AxisCalibration(scale: 1, unit: "", origin: 0)
        XCTAssertEqual(Set(SessionMarks.results(of: mark, x: plain, y: plain, samples: nil).keys), ["pixels"])
        XCTAssertEqual(Set(SessionMarks.results(of: mark, x: nmWide, y: AxisCalibration(scale: 0, unit: "nm", origin: 0), samples: nil).keys),
                        ["pixels", "scale_x", "unit_x"])
        // Red under: unit kept for mixed units (a unit written whenever an axis has one; or the units-equal test of
        // ImageMeasurement.physicalScales dropped, which would also give a length).
    }

    func testAnAnglesPlaneIsPhysicalOnlyForOneSharedUnit() {
        let mark = SessionMark(kind: .angle, points: [ImagePoint(x: 10.5, y: 3.25), ImagePoint(x: 4.0, y: 12.75),
                                                      ImagePoint(x: 34.25, y: 20.5)])
        let physical = SessionMarks.results(of: mark, x: nmWide, y: nmTall, samples: nil)
        XCTAssertEqual(physical["plane"], "physical")
        XCTAssertEqual(number(physical, "degrees"), 125.99489350300551, accuracy: 125.99489350300551e-12)
        // Mixed units and no calibration measure in the pixel grid, the same angle.
        for (x, y) in [(nmWide, microTall), (nil, nil), (nmWide, nil)] as [(AxisCalibration?, AxisCalibration?)] {
            let results = SessionMarks.results(of: mark, x: x, y: y, samples: nil)
            XCTAssertEqual(results["plane"], "pixel", "\(String(describing: x)) \(String(describing: y))")
            XCTAssertEqual(number(results, "degrees"), 69.98965679133444, accuracy: 69.98965679133444e-12)
        }
        XCTAssertNil(physical["length"])
        XCTAssertNil(physical["pixels"])
        // Red under: the plane swapped; the physical angle taken in the pixel plane.
    }

    func testAZeroLengthArmHasNoAngle() {
        let flat = SessionMark(kind: .angle, points: [ImagePoint(x: 4, y: 4), ImagePoint(x: 4, y: 4), ImagePoint(x: 9, y: 2)])
        let results = SessionMarks.results(of: flat, x: nmWide, y: nmTall, samples: nil)
        XCTAssertNil(results["degrees"])
        XCTAssertEqual(results["scale_x"], "0.5", "the scales are recorded all the same")
        // Red under: an angle of 0 or NaN written for a zero-length arm.
    }

    func testAProfileRecordsItsSampleCountAndTheOtherKindsNone() {
        let points = [ImagePoint(x: 1.5, y: 2.0), ImagePoint(x: 25.25, y: 9.75)]
        let profile = SessionMarks.results(of: SessionMark(kind: .profile, points: points, width: 3), x: nmWide, y: nmTall, samples: 26)
        XCTAssertEqual(profile["samples"], "26")
        XCTAssertEqual(number(profile, "pixels"), 24.982493870708744, accuracy: 24.982493870708744e-12)
        XCTAssertEqual(number(profile, "length"), 19.52602430091697, accuracy: 19.52602430091697e-12)
        XCTAssertEqual(profile["unit"], "nm")
        XCTAssertNil(SessionMarks.results(of: SessionMark(kind: .profile, points: points, width: 3), x: nil, y: nil, samples: nil)["samples"])
        XCTAssertNil(SessionMarks.results(of: SessionMark(kind: .distance, points: points), x: nil, y: nil, samples: 26)["samples"])
        // Red under: samples written for every kind, or never.
    }

    func testAMarkSurvivesItsNodeAndTheLineageTextBitForBit() throws {
        // Doubles with no short decimal, an exponent form, a negative zero and the edges of the image.
        let awkward: [Double] = [0.1 + 0.2, 1e-7, 5e-324, -0.0, -0.5, 39.5.nextDown, 23.5, 0.1, 12.345678901234567, 1.0 / 3.0]
        var rng = SplitMix64(state: 7)
        var lineage = SessionLineage()
        var marks: [SessionMark] = []
        for round in 0..<24 {
            func point() -> ImagePoint {
                ImagePoint(x: awkward[Int(rng.next() % 10)], y: awkward[Int(rng.next() % 10)].magnitude.truncatingRemainder(dividingBy: 23))
            }
            let kind = SessionMark.Kind.allCases[round % 3]
            let mark = SessionMark(kind: kind, points: (0..<kind.pointCount).map { _ in point() }, width: [1, 2, 13, 24, 25][round % 5])
            marks.append(mark)
            try lineage.add(kind: kind.rawValue, parameters: SessionMarks.parameters(of: mark, object: object),
                            results: SessionMarks.results(of: mark, x: nmWide, y: nmTall, samples: nil), recorded: t0)
        }
        let reread = try SessionLineage.decode(try lineage.jsonString())
        for (mark, node) in zip(marks, reread.nodes) {
            let back = try XCTUnwrap(self.mark(of: node), node.id)
            XCTAssertEqual(back.kind, mark.kind, node.id)
            assertBitEqual(back.points, mark.points, node.id)
            XCTAssertEqual(back.width, mark.width, node.id)
        }
        // Red under: the width not restored (always 1); x and y swapped in the reader; a coordinate rounded for display.
    }

    // MARK: - A node to its mark: what a reader takes from it

    func testAPlantedNodeIsReadColumnThenRowAndTheVertexIsPoint2() throws {
        let distance = try XCTUnwrap(mark(of: node("s1", "distance", distanceParameters)))
        XCTAssertEqual(distance.kind, .distance)
        assertBitEqual(distance.points, [ImagePoint(x: 2.5, y: 1.25), ImagePoint(x: 30.75, y: 17.5)])
        let angle = try XCTUnwrap(mark(of: node("s2", "angle", angleParameters)))
        assertBitEqual(angle.points, [ImagePoint(x: 10.5, y: 3.25), ImagePoint(x: 4.0, y: 12.75), ImagePoint(x: 34.25, y: 20.5)])
        XCTAssertEqual(angle.points[1], ImagePoint(x: 4.0, y: 12.75), "x2, y2 is the vertex")
        // Red under: x and y swapped in the reader, or in both the reader and the writer; the vertex not point 2.
    }

    func testAProfilesWidthIsReadAndAnotherKindsWidthIsNotLookedAt() throws {
        for width in [1, 2, 9, 10, 13, 24, 25] {
            let profile = try XCTUnwrap(mark(of: node("s1", "profile", with(profileParameters, "width", String(width)))))
            XCTAssertEqual(profile.width, width)
        }
        // A width on a distance is an extra key: not read, not checked.
        let distance = try XCTUnwrap(mark(of: node("s1", "distance", with(distanceParameters, "width", "garbage"))))
        XCTAssertEqual(distance.width, 1)
        // Red under: the width not restored (always 1).
    }

    func testPointsExactlyOnTheImageEdgesAreInsideOnEachAxis() throws {
        // −0.5 and W − 0.5 (39.5 across, 23.5 down) are the pixel edges; the bounds are inclusive.
        for (x, y) in [(-0.5, 0.0), (39.5, 0.0), (0.0, -0.5), (0.0, 23.5), (-0.5, -0.5), (39.5, 23.5), (30.0, 5.0)] {
            for index in 1...3 {
                var parameters = angleParameters
                parameters["x\(index)"] = SessionLineage.coordinateString(x)
                parameters["y\(index)"] = SessionLineage.coordinateString(y)
                let restored = try XCTUnwrap(mark(of: node("s1", "angle", parameters)), "\(x), \(y) as point \(index)")
                XCTAssertEqual(restored.points[index - 1], ImagePoint(x: x, y: y))
            }
        }
        // Red under: the bounds at 0 (−0.5 refused) or at W − 0.5 exclusive; x checked against the height (30.0 is inside 40, not 24).
    }

    func testAPointJustPastAnEdgeIsRefusedNamingTheNodeAndThePoint() {
        let past: [(x: Double, y: Double, side: String)] = [
            ((-0.5).nextDown, 5.0, "left"), (-1.0, 5.0, "left by one"), (39.5.nextUp, 5.0, "right"), (40.0, 5.0, "right at W"),
            (5.0, (-0.5).nextDown, "top"), (5.0, -1.0, "top by one"), (5.0, 23.5.nextUp, "bottom"), (5.0, 24.0, "bottom at H"),
            (5.0, 30.0, "below the height but inside the width"), (1e300, 5.0, "far right"),
        ]
        for (x, y, side) in past {
            for index in 1...3 {
                var parameters = angleParameters
                parameters["x\(index)"] = SessionLineage.coordinateString(x)
                parameters["y\(index)"] = SessionLineage.coordinateString(y)
                XCTAssertEqual(markRefusal(node("s4", "angle", parameters)), .outsideImage(node: "s4", point: index),
                               "\(side): point \(index) at \(x), \(y)")
            }
        }
        // Red under: the bounds at 0 or at W or at H (each side, each axis); the point counted from 0; the wrong node named.
    }

    func testZeroLengthMarksAreMarks() throws {
        let corner = ["x1": "-0.5", "y1": "23.5", "x2": "-0.5", "y2": "23.5"]
        for kind in ["distance", "profile"] {
            let flat = try XCTUnwrap(mark(of: node("s1", kind, distanceParameters.merging(corner) { _, new in new }
                .merging(["width": "4"]) { _, new in new })))
            XCTAssertEqual(flat.points[0], flat.points[1])
        }
        var angle = angleParameters
        for key in ["x1", "x2", "x3"] { angle[key] = "12.5" }
        for key in ["y1", "y2", "y3"] { angle[key] = "7.0" }
        XCTAssertEqual(try XCTUnwrap(mark(of: node("s1", "angle", angle))).points, Array(repeating: ImagePoint(x: 12.5, y: 7.0), count: 3))
        // Red under: the bounds or the width exclusive; a zero-length mark refused.
    }

    func testACoordinateOutsideTheGrammarIsRefusedNamingTheKeyAndTheText() {
        let refused = ["0x1p3", ".5", "+1", "1.", "1e", "1e+", "", "-", "--1", "nan", "NaN", "inf", "-inf", "infinity", "1e999",
                       "-1e999", "1,5", "1_0", " 1", "1 ", "1.5.2", "0x10", "\u{0663}", "1E3", "1e5.5", "1e+-5", "1 e5", "- 1",
                       "1.5\u{0}", String(repeating: "9", count: 400)]
        for text in refused {
            XCTAssertNil(SessionMarks.coordinate(text), "[\(text)]")
            XCTAssertEqual(markRefusal(node("s3", "distance", with(distanceParameters, "x2", text))),
                           .badCoordinate(node: "s3", key: "x2", text: text), "[\(text)]")
        }
        // Each key of each point is read and named.
        for key in ["x1", "y1", "x2", "y2"] {
            XCTAssertEqual(markRefusal(node("s3", "distance", with(distanceParameters, key, "+1"))),
                           .badCoordinate(node: "s3", key: key, text: "+1"))
        }
        for key in ["x1", "y1", "x2", "y2", "x3", "y3"] {
            XCTAssertEqual(markRefusal(node("s8", "profile", with(profileParameters, key, "nan"))) == nil, key.hasSuffix("3"), key)
            XCTAssertEqual(markRefusal(node("s8", "angle", with(angleParameters, key, "nan"))),
                           .badCoordinate(node: "s8", key: key, text: "nan"))
        }
        // Red under: the grammar accepting "0x1p3" (the closing check dropped), ".5" (the integer part optional), "+1" (a plus
        // sign taken), "1." (the fraction optional); the text or the key named wrongly.
    }

    func testTheGrammarAcceptsWhatSwiftAndPythonWrite() {
        let accepted: [(String, Double)] = [("0", 0), ("10.5", 10.5), ("-3.25", -3.25), ("0.1", 0.1), ("0.30000000000000004", 0.1 + 0.2),
                                            ("1.2345e-07", 1.2345e-7), ("1e+16", 1e16), ("1e16", 1e16), ("-2.5e-3", -0.0025),
                                            ("5e-324", 5e-324), ("1.7976931348623157e+308", .greatestFiniteMagnitude), ("2e0", 2)]
        for (text, value) in accepted { XCTAssertEqual(SessionMarks.coordinate(text)?.bitPattern, value.bitPattern, text) }
        XCTAssertEqual(SessionMarks.coordinate("-0.0")?.bitPattern, (-0.0).bitPattern, "the sign of a negative zero is kept")
        // Everything Swift's shortest round-trip description writes, for random bit patterns, reads back bit for bit.
        var rng = SplitMix64(state: 20261014)
        var checked = 0
        while checked < 20_000 {
            let value = Double(bitPattern: rng.next())
            guard value.isFinite else { continue }
            let text = SessionLineage.coordinateString(value)
            XCTAssertEqual(SessionMarks.coordinate(text)?.bitPattern, value.bitPattern, text)
            checked += 1
        }
        // Red under: the grammar narrower than the writer ("e+16", "e-07", "5e-324", a negative zero refused).
    }

    func testAWidthIsPlainDigitsFromOneToTwentyFive() {
        for width in 1...25 { XCTAssertEqual(SessionMarks.width(String(width)), width) }
        for text in ["0", "00", "01", "03", "05", "025", "26", "27", "30", "99", "100", "+5", "-3", "", " 5", "5 ", "1.0", "2e1", "0x5",
                     "\u{0663}", "\u{0662}\u{0665}", "25.0", "\u{FF15}"] {
            XCTAssertNil(SessionMarks.width(text), "[\(text)]")
            XCTAssertEqual(markRefusal(node("s6", "profile", with(profileParameters, "width", text))), .badWidth(node: "s6", text: text),
                           "[\(text)]")
        }
        // Red under: the width accepting "03" (and "0": the leading-zero check is the only floor), "26", or refusing "25".
    }

    func testEachRequiredKeyMissingIsRefusedByName() {
        let required: [(kind: String, parameters: [String: String], keys: [String])] = [
            ("distance", distanceParameters, ["x1", "y1", "x2", "y2", "object", "frame"]),
            ("angle", angleParameters, ["x1", "y1", "x2", "y2", "x3", "y3", "object", "frame"]),
            ("profile", profileParameters, ["x1", "y1", "x2", "y2", "width", "object", "frame"]),
        ]
        for entry in required {
            XCTAssertNil(markRefusal(node("s2", entry.kind, entry.parameters)), entry.kind)
            for key in entry.keys {
                XCTAssertEqual(markRefusal(node("s5", entry.kind, with(entry.parameters, key, nil))), .missingKey(node: "s5", key: key),
                               "\(entry.kind) without \(key)")
            }
        }
        // Keys the kind does not take are not required: no third point on a segment, no width on a distance or an angle.
        XCTAssertNil(markRefusal(node("s2", "distance", distanceParameters)))
        XCTAssertNil(markRefusal(node("s2", "angle", angleParameters)))
        // Red under: a missing key defaulted instead of refused, or the key named wrongly.
    }

    func testANodeOfAnotherObjectOrFrameOrKindOrOneRemovedIsKeptNotDrawnAndNotJudged() {
        var elsewhere = distanceParameters
        elsewhere["object"] = "ImageList.1 \u{00B7} BF"
        XCTAssertNil(mark(of: node("s1", "distance", elsewhere)))
        // Not judged: its coordinates are another image's.
        XCTAssertNil(mark(of: node("s1", "distance", ["object": "ImageList.1 \u{00B7} BF", "x1": "junk"])))
        XCTAssertNil(mark(of: node("s1", "distance", with(distanceParameters, "frame", "1"))))
        XCTAssertNil(mark(of: node("s1", "distance", ["object": object, "frame": "7", "x1": "junk"])))
        XCTAssertNil(mark(of: node("s1", "distance", with(distanceParameters, "object", object.uppercased()))), "the object is compared as written")
        for kind in ["calibration", "fft", "hrtem_filter", "export", "zzz", "Distance", "", "distance "] {
            XCTAssertNil(mark(of: node("s1", kind, distanceParameters)), kind)
        }
        // A removed node (kept dated for the node that cites it) is not a mark, whatever it holds.
        XCTAssertNil(mark(of: node("s1", "distance", distanceParameters, removed: t0)))
        XCTAssertNil(mark(of: node("s1", "angle", ["junk": "1"], removed: t0)))
        // The frame is a parameter of the call: a node of frame "1" is this image's when frame "1" is asked for.
        let frame1 = try? SessionMarks.mark(of: node("s1", "distance", with(distanceParameters, "frame", "1")), width: width,
                                            height: height, object: object, frame: "1")
        XCTAssertNotNil(frame1 ?? nil)
        // Red under: a removed node drawn; another object or frame drawn; the object or frame compared after the points are
        // parsed (a node of another image judged by this one's bounds).
    }

    func testExtraKeysAreTolerated() throws {
        var extra = distanceParameters
        extra["note"] = "drawn by hand"
        extra["x3"] = "not a number"
        extra["width"] = "-"
        extra["x4"] = "1e999"
        let distance = try XCTUnwrap(mark(of: node("s1", "distance", extra, results: ["length": "garbage", "future": "1"])))
        XCTAssertEqual(distance.points.count, 2)
        var profile = profileParameters
        profile["y3"] = "?"
        XCTAssertEqual(try XCTUnwrap(mark(of: node("s1", "profile", profile))).width, 7)
        // Red under: an unknown key refused; a key of another kind (x3 on a segment) read.
    }

    // MARK: - The calibration note

    private func recordedNode(x: AxisCalibration?, y: AxisCalibration?) -> SessionLineage.Node {
        let mark = SessionMark(kind: .distance, points: [ImagePoint(x: 2.5, y: 1.25), ImagePoint(x: 30.75, y: 17.5)])
        return node("s1", "distance", distanceParameters, results: SessionMarks.results(of: mark, x: x, y: y, samples: nil))
    }

    func testTheCalibrationNoteIsRaisedByAnyChangedScaleOrUnit() {
        let plain = AxisCalibration(scale: 1, unit: "", origin: 0)
        let recorded = recordedNode(x: nmWide, y: nmTall)
        XCTAssertFalse(SessionMarks.calibrationDiffers(recorded, x: nmWide, y: nmTall))
        // The origin is not part of a measurement: a shifted origin is the same calibration.
        XCTAssertFalse(SessionMarks.calibrationDiffers(recorded, x: AxisCalibration(scale: 0.5, unit: "nm", origin: 9), y: nmTall))
        let changes: [(String, AxisCalibration?, AxisCalibration?)] = [
            ("x scale", AxisCalibration(scale: 0.25, unit: "nm", origin: 0), nmTall),
            ("y scale", nmWide, AxisCalibration(scale: 4.0, unit: "nm", origin: 0)),
            ("x unit", AxisCalibration(scale: 0.5, unit: "\u{00C5}", origin: 0), nmTall),
            ("y unit", nmWide, AxisCalibration(scale: 2.0, unit: "\u{00C5}", origin: 0)),
            ("x gone", nil, nmTall), ("y gone", nmWide, nil), ("both gone", nil, nil), ("x unstated", plain, nmTall),
            ("y unstated", nmWide, plain), ("a scale of zero", AxisCalibration(scale: 0, unit: "nm", origin: 0), nmTall),
        ]
        for (what, x, y) in changes { XCTAssertTrue(SessionMarks.calibrationDiffers(recorded, x: x, y: y), what) }
        // Red under: the note never raised; raised only when both axes differ (|| as &&); the unit not compared; the scale not compared.
    }

    func testTheCalibrationNoteComparesEachAxisToItsOwnRecord() {
        // Same scales and units, exchanged between the axes: not the calibration the mark was measured with.
        let recorded = recordedNode(x: nmWide, y: nmTall)
        XCTAssertTrue(SessionMarks.calibrationDiffers(recorded, x: nmTall, y: nmWide))
        // Mixed units, anisotropic: the same pair reads equal, the exchanged pair does not.
        let mixed = recordedNode(x: nmWide, y: microTall)
        XCTAssertFalse(SessionMarks.calibrationDiffers(mixed, x: nmWide, y: microTall))
        XCTAssertTrue(SessionMarks.calibrationDiffers(mixed, x: microTall, y: nmWide))
        // Units exchanged with the scales equal.
        let squareNm = AxisCalibration(scale: 1.5, unit: "nm", origin: 0), squareMicro = AxisCalibration(scale: 1.5, unit: micro, origin: 0)
        XCTAssertFalse(SessionMarks.calibrationDiffers(recordedNode(x: squareNm, y: squareMicro), x: squareNm, y: squareMicro))
        XCTAssertTrue(SessionMarks.calibrationDiffers(recordedNode(x: squareNm, y: squareMicro), x: squareMicro, y: squareNm))
        // Red under: scale_x and scale_y (or unit_x and unit_y) exchanged when read.
    }

    func testAnUncalibratedAxisMatchesOnlyAnUncalibratedRecord() {
        let plain = AxisCalibration(scale: 1, unit: "", origin: 0), negative = AxisCalibration(scale: -2, unit: "nm", origin: 0)
        let none = recordedNode(x: nil, y: nil)
        XCTAssertFalse(SessionMarks.calibrationDiffers(none, x: nil, y: nil))
        XCTAssertFalse(SessionMarks.calibrationDiffers(none, x: plain, y: plain))
        XCTAssertFalse(SessionMarks.calibrationDiffers(none, x: negative, y: nil), "a negative scale is not a calibration")
        XCTAssertTrue(SessionMarks.calibrationDiffers(none, x: nmWide, y: nil))
        XCTAssertTrue(SessionMarks.calibrationDiffers(none, x: nil, y: nmTall))
        let half = recordedNode(x: nmWide, y: nil)
        XCTAssertFalse(SessionMarks.calibrationDiffers(half, x: nmWide, y: nil))
        XCTAssertFalse(SessionMarks.calibrationDiffers(half, x: nmWide, y: plain))
        XCTAssertTrue(SessionMarks.calibrationDiffers(half, x: nmWide, y: nmTall))
        // A scale the node records in a form that is not a number is no record at all.
        var garbled = recordedNode(x: nmWide, y: nmTall)
        garbled.results["scale_x"] = "0x1p-1"
        XCTAssertTrue(SessionMarks.calibrationDiffers(garbled, x: nmWide, y: nmTall))
        // Red under: an uncalibrated axis compared as scale 1; the "axis absent" branch returning false.
    }

    // MARK: - The restore

    func testARestoreEqualsTheSaveForALineageBuiltByAdd() throws {
        var lineage = SessionLineage()
        var drawn: [(id: String, mark: SessionMark)] = []
        func add(_ id: String, _ mark: SessionMark, object: String? = nil, frame: String = "0", draws: Bool = true) throws {
            let added = try lineage.add(kind: mark.kind.rawValue,
                                        parameters: SessionMarks.parameters(of: mark, object: object ?? self.object, frame: frame),
                                        results: SessionMarks.results(of: mark, x: nmWide, y: nmTall,
                                                                      samples: mark.kind == .profile ? 31 : nil),
                                        recorded: t0 + Int64(lineage.nodes.count) * 17)
            XCTAssertEqual(added, id)
            if draws { drawn.append((id, mark)) }
        }
        let a = ImagePoint(x: 0.1 + 0.2, y: -0.5), b = ImagePoint(x: 39.5, y: 23.5), c = ImagePoint(x: 1e-7, y: 12.345678901234567)
        try add("s1", SessionMark(kind: .distance, points: [a, b]), draws: false)
        try add("s2", SessionMark(kind: .angle, points: [a, b, c]), draws: false)
        try add("s3", SessionMark(kind: .profile, points: [c, b], width: 7))
        try add("s4", SessionMark(kind: .distance, points: [a, a]), draws: false)
        try lineage.add(kind: "export", parameters: ["format": "png"], inputs: [.init(step: "s2", role: "mark")], recorded: t0 + 5)   // s5
        try lineage.add(kind: "calibration", parameters: ["note": "x"], recorded: t0 + 6)                                                // s6
        try add("s7", SessionMark(kind: .distance, points: [b.self, c]))
        try add("s8", SessionMark(kind: .angle, points: [c, ImagePoint(x: 20, y: 0.1), b]))
        try add("s9", SessionMark(kind: .distance, points: [a, c]), draws: false)
        try add("s10", SessionMark(kind: .distance, points: [a, c]), frame: "1", draws: false)
        try add("s11", SessionMark(kind: .distance, points: [a, c]), object: "Elsewhere", draws: false)
        try add("s12", SessionMark(kind: .profile, points: [a, c], width: 25), draws: false)
        try lineage.add(kind: "zzz", parameters: [:], recorded: t0 + 7)                                                                   // s13
        try lineage.add(kind: "distance", parameters: [:], recorded: t0 + 8)                                                              // s14
        for id in ["s1", "s4", "s9", "s12", "s14"] { XCTAssertEqual(lineage.remove(id: id, at: t0 + 99), .deleted, id) }
        XCTAssertEqual(lineage.remove(id: "s2", at: t0 + 100), .kept, "cited by the export")
        XCTAssertEqual(lineage.nextID, 15)
        let text = try lineage.jsonString()

        let restored = try XCTUnwrap(restored(try contents(lineage), x: nmWide, y: nmTall))
        XCTAssertEqual(restored.verdict, .adopt)
        XCTAssertEqual(restored.marks.map(\.nodeID), ["s3", "s7", "s8"], "node order")
        XCTAssertEqual(restored.marks.map(\.nodeID), drawn.map(\.id))
        for (entry, was) in zip(restored.marks, drawn) {
            XCTAssertEqual(entry.mark.kind, was.mark.kind, entry.nodeID)
            assertBitEqual(entry.mark.points, was.mark.points, entry.nodeID)
            XCTAssertEqual(entry.mark.width, was.mark.width, entry.nodeID)
        }
        XCTAssertEqual(restored.kept, 6, "s2 removed, the export, the calibration, frame 1, another object, the unknown kind")
        XCTAssertFalse(restored.calibrationDiffers)
        // The lineage is the one read: every id, next_id (not re-derived from the highest id), every date and every kind.
        XCTAssertEqual(restored.lineage, lineage)
        XCTAssertEqual(restored.lineage.nextID, 15)
        XCTAssertEqual(restored.lineage.nodes.map(\.id), ["s2", "s3", "s5", "s6", "s7", "s8", "s10", "s11", "s13"])
        XCTAssertEqual(restored.lineage.nodes.map(\.recorded), lineage.nodes.map(\.recorded), "no date re-stamped")
        XCTAssertEqual(restored.lineage.node(id: "s2")?.removed, t0 + 100)
        XCTAssertEqual(restored.lineage.node(id: "s3")?.results, lineage.node(id: "s3")?.results, "nodes are a verbatim record")
        // And saved again with no edit, the lineage attribute is byte for byte the same.
        XCTAssertEqual(restored.lineageText, text)
        XCTAssertEqual(try restored.lineage.jsonString(), text)
        let again = try XCTUnwrap(saveRequest(restored.lineage, expected: restored.lineageText))
        XCTAssertEqual(again.lineage, text)
        XCTAssertEqual(again.source, try identity().jsonString())
        // Red under: restore replacing or re-stamping a node; ids re-minted or next_id re-derived; another kind dropped; a removed
        // node drawn; the node order lost.
    }

    func testTheLineageTextIsKeptAsReadSoTheChangedOnDiskCheckCanMatchIt() throws {
        let original = try lineage([("distance", distanceParameters), ("profile", profileParameters)])
        // The same lineage as another writer lays it out: indented, keys in another order.
        let canonical = try original.jsonString()
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(canonical.utf8)))
        let pretty = try XCTUnwrap(String(data: JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted]), encoding: .utf8))
        XCTAssertNotEqual(pretty, canonical)
        let restored = try XCTUnwrap(restored(SessionSidecarFile.Contents(schema: 1, minReader: 1, source: try identity().jsonString(),
                                                                          lineage: pretty)))
        XCTAssertEqual(restored.lineageText, pretty)
        XCTAssertEqual(restored.lineage, original)
        XCTAssertEqual(restored.marks.count, 2)
        // Red under: lineageText re-encoded from the lineage (the check against the file would then never match).
    }

    func testTheThreeAdoptVerdictsPassThrough() throws {
        let lineage = try lineage([("distance", distanceParameters)])
        let other = String(repeating: "cd", count: 32)
        // The same image.
        XCTAssertEqual(restored(try contents(lineage))?.verdict, .adopt)
        // The byte size never decides.
        XCTAssertEqual(restored(try contents(lineage, stored: identity(bytes: 1)), opened: identity(bytes: 999_999))?.verdict, .adopt)
        // Only the name differs: restored, the stored name noted.
        let renamed = restored(try contents(lineage, stored: identity(name: "old name.dm4")), opened: identity(name: "scan.dm4"))
        XCTAssertEqual(renamed?.verdict, .adoptRenamed(from: "old name.dm4"))
        XCTAssertEqual(renamed?.marks.count, 1)
        // The same shape with other pixels: restored, flagged; the louder fact when the name differs too.
        let differs = restored(try contents(lineage, stored: identity(digest: other)), opened: identity())
        XCTAssertEqual(differs?.verdict, .adoptPixelsDiffer)
        XCTAssertEqual(differs?.marks.count, 1)
        XCTAssertEqual(restored(try contents(lineage, stored: identity(name: "old.dm4", digest: other)))?.verdict, .adoptPixelsDiffer)
        // Red under: the verdict forced to .adopt, or passed through wrongly.
    }

    func testAnotherObjectOrShapeIsRefusedWholeBeforeAnyNodeIsRead() throws {
        // The marks are inside both images and the nodes are valid for both: only the verdict can tell them apart.
        let marks = try lineage([("distance", distanceParameters), ("angle", angleParameters)])
        let stored = identity()
        let opened: [(String, SessionSourceIdentity)] = [
            ("another object", identity(object: "ImageList.1 \u{00B7} BF")),
            ("a wider image", identity(width: 64)),
            ("a taller image", identity(height: 48)),
            ("both", identity(width: 64, height: 48)),
            ("transposed", identity(width: 24, height: 40)),
        ]
        for (what, image) in opened {
            guard case .refuse(let sentence) = SessionRestoreVerdict.decide(stored: stored, opened: image) else {
                XCTFail("the verdict should refuse \(what)")
                continue
            }
            XCTAssertEqual(restoreRefusal(try contents(marks, stored: stored), opened: image), .otherImage(sentence), what)
            // Before the lineage is looked at: a lineage that is not one does not change the answer.
            let broken = SessionSidecarFile.Contents(schema: 1, minReader: 1, source: try stored.jsonString(), lineage: "not json")
            XCTAssertEqual(restoreRefusal(broken, opened: image), .otherImage(sentence), what)
            XCTAssertTrue(sentence.contains("\(stored.width) \u{00D7} \(stored.height)"), sentence)
        }
        // Red under: the verdict skipped (the marks would have been drawn on another image) or decided after the lineage.
    }

    func testTheOrderOfRefusalsIsIdentityThenVerdictThenLineageThenNodes() throws {
        let good = try lineage([("distance", distanceParameters)])
        let otherImage = identity(object: "Elsewhere")
        let goodSource = try identity().jsonString(), otherSource = try otherImage.jsonString()
        func contents(source: String?, lineage: String?) -> SessionSidecarFile.Contents {
            SessionSidecarFile.Contents(schema: 1, minReader: 1, source: source, lineage: lineage)
        }
        guard case .refuse(let sentence) = SessionRestoreVerdict.decide(stored: otherImage, opened: identity()) else {
            return XCTFail("expected a refusal")
        }
        let badNode = try lineage([("distance", with(distanceParameters, "x1", "oops"))]).jsonString()
        XCTAssertEqual(restoreRefusal(contents(source: "{", lineage: "{")), .identity(.malformed))
        XCTAssertEqual(restoreRefusal(contents(source: otherSource, lineage: "{")), .otherImage(sentence))
        XCTAssertEqual(restoreRefusal(contents(source: otherSource, lineage: nil)), .otherImage(sentence))
        XCTAssertEqual(restoreRefusal(contents(source: goodSource, lineage: "{")), .lineage(.malformed))
        XCTAssertEqual(restoreRefusal(contents(source: goodSource, lineage: badNode)),
                       .mark(.badCoordinate(node: "s1", key: "x1", text: "oops")))
        XCTAssertEqual(restoreRefusal(contents(source: nil, lineage: nil)), .missingSource)
        XCTAssertEqual(restoreRefusal(contents(source: nil, lineage: try good.jsonString())), .missingSource)
        XCTAssertEqual(restoreRefusal(contents(source: goodSource, lineage: nil)), .missingLineage)
        XCTAssertNil(restoreRefusal(contents(source: goodSource, lineage: try good.jsonString())))
        XCTAssertTrue(SessionRestore.Refusal.missingSource.reason.contains(SessionSidecarFile.sourceAttribute))
        XCTAssertTrue(SessionRestore.Refusal.missingLineage.reason.contains(SessionSidecarFile.lineageAttribute))
        // Red under: the missing source or lineage skipped (a sidecar without either restored as empty), the identity refusal
        // or the lineage refusal replaced by another.
    }

    func testEveryIdentityRefusalIsPassedThroughByName() throws {
        let lineage = try lineage([("distance", distanceParameters)])
        let lineageText = try lineage.jsonString()
        func refusal(_ source: String) -> SessionRestore.Refusal? {
            restoreRefusal(SessionSidecarFile.Contents(schema: 1, minReader: 1, source: source, lineage: lineageText))
        }
        XCTAssertEqual(refusal("not json"), .identity(.malformed))
        XCTAssertEqual(refusal(#"{"file_name":"a"}"#), .identity(.malformed))
        XCTAssertEqual(refusal(String(repeating: " ", count: 64 * 1024 + 1)), .identity(.tooLarge(bytes: 64 * 1024 + 1)))
        let zeroWide = #"{"byte_size":1,"file_name":"a","height":4,"object":"o","pixel_sha256":"\#(digest)","width":0}"#
        XCTAssertEqual(refusal(zeroWide), .identity(.invalid(field: "width")))
        let badDigest = #"{"byte_size":1,"file_name":"a","height":4,"object":"o","pixel_sha256":"ABC","width":4}"#
        XCTAssertEqual(refusal(badDigest), .identity(.invalid(field: "pixel_sha256")))
        // Red under: an identity refusal swallowed or reported as another.
    }

    func testEveryLineageRefusalIsPassedThroughByName() {
        func node(_ id: String, inputs: [String] = []) -> String {
            let edges = inputs.map { #"{"role":"input","step":"\#($0)"}"# }.joined(separator: ",")
            return #"{"external":[],"id":"\#(id)","inputs":[\#(edges)],"kind":"distance","parameters":{},"recorded":1,"results":{}}"#
        }
        func text(next: Int, _ nodes: [String]) -> String { #"{"next_id":\#(next),"nodes":[\#(nodes.joined(separator: ","))],"version":1}"# }
        let cases: [(String, SessionLineage.Refusal)] = [
            (String(repeating: " ", count: SessionLineage.maximumJSONBytes + 1), .tooLarge(bytes: SessionLineage.maximumJSONBytes + 1)),
            ("[]", .malformed), (#"{"version":1}"#, .malformed), ("", .malformed),
            (text(next: 2002, (1...2001).map { node("s\($0)") }), .tooManyNodes(2001)),
            (text(next: 0, []), .badNextID(0)), (text(next: 1_000_001, []), .badNextID(1_000_001)),
            (text(next: 3, [node("x1")]), .badID("x1")), (text(next: 3, [node("s01")]), .badID("s01")),
            (text(next: 3, [node("s1"), node("s1")]), .duplicateID("s1")),
            (text(next: 5, [node("s5")]), .idNotBelowNextID(id: "s5", nextID: 5)),
            (text(next: 3, [node("s1"), node("s2", inputs: ["s9"])]), .danglingInput(step: "s9", from: "s2")),
            (text(next: 3, [node("s1", inputs: ["s2"]), node("s2", inputs: ["s1"])]), .cycle),
        ]
        for (lineage, expected) in cases {
            let contents = SessionSidecarFile.Contents(schema: 1, minReader: 1, source: try? identity().jsonString(), lineage: lineage)
            XCTAssertEqual(restoreRefusal(contents), .lineage(expected), String(lineage.prefix(60)))
        }
        // Red under: a lineage refusal skipped (the lineage decoded with try?) or reported as another.
    }

    func testABadMarkNodeRefusesTheWholeRestoreNamingThatNode() throws {
        let bad: [(String, [String: String], SessionMarks.Refusal)] = [
            ("a missing key", with(distanceParameters, "y2", nil), .missingKey(node: "s2", key: "y2")),
            ("a coordinate outside the grammar", with(distanceParameters, "x1", ".5"), .badCoordinate(node: "s2", key: "x1", text: ".5")),
            ("a coordinate not finite", with(distanceParameters, "y1", "1e999"), .badCoordinate(node: "s2", key: "y1", text: "1e999")),
            ("a point outside the image", with(distanceParameters, "x2", "40.0"), .outsideImage(node: "s2", point: 2)),
            ("a point above the image", with(distanceParameters, "y1", "-0.51"), .outsideImage(node: "s2", point: 1)),
        ]
        let good = ("distance", distanceParameters)
        for (what, parameters, expected) in bad {
            // The bad node in the middle, first and last: one refusal each time, never a restore of the others.
            XCTAssertEqual(restoreRefusal(try contents(try lineage([good, ("distance", parameters), good]))), .mark(expected), what)
        }
        let badWidth: [String: String] = with(profileParameters, "width", "03")
        for (position, nodes) in [("first", [("profile", badWidth), good, good]), ("middle", [good, ("profile", badWidth), good]),
                                  ("last", [good, good, ("profile", badWidth)])] {
            let id = "s\(nodes.firstIndex { $0.0 == "profile" }! + 1)"
            XCTAssertEqual(restoreRefusal(try contents(try lineage(nodes))), .mark(.badWidth(node: id, text: "03")), position)
        }
        // Two bad nodes: the first, in node order, is named.
        let two = try lineage([good, ("distance", with(distanceParameters, "x1", "+1")), ("profile", with(profileParameters, "width", "0"))])
        XCTAssertEqual(restoreRefusal(try contents(two)), .mark(.badCoordinate(node: "s2", key: "x1", text: "+1")))
        // A bad node of another kind's shape is not a bad mark: an export with no points restores.
        XCTAssertNil(restoreRefusal(try contents(try lineage([good, ("export", [:]), ("calibration", ["x1": "junk"])]))))
        // Red under: a bad node skipped, kept or defaulted instead of refused (a partial restore); each refusal skipped; the first
        // node or the last named instead of the bad one.
    }

    func testAReadOnlyLineageRestoresNoMarksAndItsSaveIsRefusedByName() throws {
        let future = #"{"nodes":{"s1":[1,2,3]},"version":2,"next_id":4}"#
        let sidecar = SessionSidecarFile.Contents(schema: 1, minReader: 1, source: try identity().jsonString(), lineage: future)
        let restored = try XCTUnwrap(restored(sidecar))
        XCTAssertTrue(restored.marks.isEmpty)
        XCTAssertEqual(restored.kept, 0)
        XCTAssertTrue(restored.lineage.isReadOnly)
        XCTAssertEqual(restored.lineage.fileVersion, 2)
        XCTAssertEqual(restored.lineageText, future)
        XCTAssertEqual(restored.verdict, .adopt)
        // Its saving is refused by name, before anything else is looked at (a broken identity does not change the answer).
        XCTAssertEqual(saveRequestRefusal(restored.lineage), .readOnly(2))
        XCTAssertEqual(saveRequestRefusal(restored.lineage, identity: identity(width: 0)), .readOnly(2))
        // Red under: the read-only check skipped (the lineage's own writer would then refuse, as .lineage); the lineage's nodes invented.
    }

    func testMarksAtTheEdgesAndOfZeroLengthRestoreThroughTheWholePipeline() throws {
        let corner = ["x1": "-0.5", "y1": "-0.5", "x2": "39.5", "y2": "23.5"]
        let flat = ["x1": "39.5", "y1": "-0.5", "x2": "39.5", "y2": "-0.5"]
        let nodes: [(kind: String, parameters: [String: String])] = [
            ("distance", distanceParameters.merging(corner) { _, new in new }),
            ("profile", profileParameters.merging(flat) { _, new in new }),
            ("angle", angleParameters.merging(["x1": "-0.5", "y1": "23.5", "x2": "-0.5", "y2": "23.5", "x3": "-0.5", "y3": "23.5"]) { _, new in new }),
        ]
        let restored = try XCTUnwrap(restored(try contents(try lineage(nodes))))
        XCTAssertEqual(restored.marks.map(\.nodeID), ["s1", "s2", "s3"])
        assertBitEqual(restored.marks[0].mark.points, [ImagePoint(x: -0.5, y: -0.5), ImagePoint(x: 39.5, y: 23.5)])
        assertBitEqual(restored.marks[1].mark.points, [ImagePoint(x: 39.5, y: -0.5), ImagePoint(x: 39.5, y: -0.5)])
        XCTAssertEqual(restored.marks[1].mark.width, 7)
        XCTAssertEqual(restored.marks[2].mark.points, Array(repeating: ImagePoint(x: -0.5, y: 23.5), count: 3))
        // On a smaller image the same sidecar's corner is outside: the bounds are the opened image's, not the stored one's.
        XCTAssertEqual(restoreRefusal(try contents(try lineage(nodes)), opened: identity(width: 39)), .otherImage(
            { if case .refuse(let sentence) = SessionRestoreVerdict.decide(stored: identity(), opened: identity(width: 39)) { return sentence }; return "" }()))
        // Red under: the bounds at 0 or at W (each side, each axis); a zero-length mark refused.
    }

    func testACalibrationDifferenceIsFlaggedOnlyForADrawnMarkAndRefusesNothing() throws {
        let mark = SessionMark(kind: .distance, points: [ImagePoint(x: 2.5, y: 1.25), ImagePoint(x: 30.75, y: 17.5)])
        func lineage(x: AxisCalibration?, y: AxisCalibration?, parameters: [String: String]? = nil, removeFirst: Bool = false) throws -> SessionLineage {
            var lineage = SessionLineage()
            try lineage.add(kind: "distance", parameters: parameters ?? SessionMarks.parameters(of: mark, object: object),
                            results: SessionMarks.results(of: mark, x: x, y: y, samples: nil), recorded: t0)
            return lineage
        }
        let measured = try lineage(x: nmWide, y: microTall)
        // The opened axes are the recorded ones: no note.
        XCTAssertEqual(restored(try contents(measured), x: nmWide, y: microTall)?.calibrationDiffers, false)
        // Each way the opened axes can differ: a note, the verdict untouched, the mark still drawn.
        for (x, y) in [(nmTall, microTall), (nmWide, nmTall), (microTall, nmWide), (nil, microTall), (nmWide, nil), (nil, nil)] as [(AxisCalibration?, AxisCalibration?)] {
            let result = restored(try contents(measured), x: x, y: y)
            XCTAssertEqual(result?.calibrationDiffers, true, "\(String(describing: x)) \(String(describing: y))")
            XCTAssertEqual(result?.verdict, .adopt)
            XCTAssertEqual(result?.marks.count, 1)
        }
        // A node that is not drawn does not raise it: another frame, another object, another kind, a removed node.
        var nodes = SessionLineage()
        let recordedHere = SessionMarks.results(of: mark, x: nmWide, y: microTall, samples: nil)
        try nodes.add(kind: "distance", parameters: with(SessionMarks.parameters(of: mark, object: object), "frame", "1"), results: recordedHere, recorded: t0)
        try nodes.add(kind: "distance", parameters: SessionMarks.parameters(of: mark, object: "Elsewhere"), results: recordedHere, recorded: t0)
        try nodes.add(kind: "export", parameters: [:], results: recordedHere, recorded: t0)
        try nodes.add(kind: "distance", parameters: SessionMarks.parameters(of: mark, object: object), results: recordedHere, recorded: t0)   // s4
        try nodes.add(kind: "export", parameters: [:], inputs: [.init(step: "s4", role: "mark")], recorded: t0)
        XCTAssertEqual(nodes.remove(id: "s4", at: t0), .kept)
        let undrawn = restored(try contents(nodes), x: nmTall, y: nmTall)
        XCTAssertEqual(undrawn?.calibrationDiffers, false)
        XCTAssertEqual(undrawn?.marks.count, 0)
        XCTAssertEqual(undrawn?.kept, 5)
        // Red under: the calibration note skipped; raised for a node that is kept; the verdict changed by it.
    }

    // MARK: - The save's request

    func testASaveRequestCarriesTheIdentityTheLineageAndItsStateAsCanonicalText() throws {
        let lineage = try lineage([("distance", distanceParameters), ("angle", angleParameters), ("profile", profileParameters)])
        let request = try XCTUnwrap(saveRequest(lineage, expected: "what the file held", replacing: true, revision: 42))
        XCTAssertEqual(request, SessionSave.Request(source: try identity().jsonString(), lineage: try lineage.jsonString(), revision: 42,
                                                    expectedOnDisk: "what the file held", replacing: true))
        XCTAssertEqual(try SessionSourceIdentity.decode(request.source), identity())
        XCTAssertEqual(try SessionLineage.decode(request.lineage), lineage)
        let plain = try XCTUnwrap(saveRequest(lineage))
        XCTAssertNil(plain.expectedOnDisk)
        XCTAssertFalse(plain.replacing)
        XCTAssertEqual(plain.revision, 3)
        // An empty lineage saves (a session whose marks were all removed).
        XCTAssertEqual(try XCTUnwrap(saveRequest(SessionLineage())).lineage, try SessionLineage().jsonString())
        // Red under: a field of the request exchanged or dropped.
    }

    func testASaveIsRefusedByNameForAMarkTheReaderWouldRefuse() throws {
        let good = ("distance", distanceParameters)
        let bad: [(String, [String: String], SessionMarks.Refusal)] = [
            ("missing key", with(distanceParameters, "x2", nil), .missingKey(node: "s2", key: "x2")),
            ("a plus sign", with(distanceParameters, "y1", "+1"), .badCoordinate(node: "s2", key: "y1", text: "+1")),
            ("not finite", with(distanceParameters, "x1", Double.nan.description), .badCoordinate(node: "s2", key: "x1", text: "nan")),
            ("past the width", with(distanceParameters, "x2", "40"), .outsideImage(node: "s2", point: 2)),
            ("past the height", with(distanceParameters, "y1", "24"), .outsideImage(node: "s2", point: 1)),
        ]
        for (what, parameters, expected) in bad {
            // The bad node second, so a check of the first node alone passes it.
            XCTAssertEqual(saveRequestRefusal(try lineage([good, ("distance", parameters)])), .mark(expected), what)
        }
        XCTAssertEqual(saveRequestRefusal(try lineage([good, ("profile", with(profileParameters, "width", "26"))])), .mark(.badWidth(node: "s2", text: "26")))
        // The shape checked is the one the save describes: the same lineage saves on a bigger image and not on a smaller.
        let atEdge = try lineage([("distance", with(distanceParameters, "x2", "39.5"))])
        XCTAssertNil(saveRequestRefusal(atEdge))
        XCTAssertEqual(saveRequestRefusal(atEdge, identity: identity(width: 39)), .mark(.outsideImage(node: "s1", point: 2)))
        XCTAssertNil(saveRequestRefusal(atEdge, identity: identity(width: 64, height: 48)))
        XCTAssertEqual(saveRequestRefusal(try lineage([("distance", with(distanceParameters, "y2", "23.5"))]), identity: identity(height: 23)),
                       .mark(.outsideImage(node: "s1", point: 2)))
        // Red under: the save skipping its checks; only the first node checked; the checks made against another shape.
    }

    func testASaveWritesNothingTheReaderWouldRefuseAndSkipsWhatItDoesNotDraw() throws {
        // A save agrees with the restore, node for node: it refuses exactly what the restore refuses.
        let variants: [(String, [String: String])] = [
            ("ok", distanceParameters), ("hex", with(distanceParameters, "x1", "0x1p3")), ("dot", with(distanceParameters, "y2", "1.")),
            ("edge", with(distanceParameters, "x1", "-0.5")), ("past", with(distanceParameters, "x1", "-0.5000000001")),
            ("no object", with(distanceParameters, "object", nil)), ("no frame", with(distanceParameters, "frame", nil)),
            ("elsewhere", with(with(distanceParameters, "object", "Elsewhere"), "x1", "junk")),
            ("frame 2", with(with(distanceParameters, "frame", "2"), "x1", "junk")),
        ]
        for (what, parameters) in variants {
            let lineage = try lineage([("distance", parameters)])
            let restoreSays = restoreRefusal(try SessionSidecarFile.Contents(schema: 1, minReader: 1, source: identity().jsonString(),
                                                                             lineage: lineage.jsonString()))
            switch (restoreSays, saveRequestRefusal(lineage)) {
            case (nil, nil): break
            case (.mark(let read)?, .mark(let write)?): XCTAssertEqual(read, write, what)
            default: XCTFail("\(what): restore \(String(describing: restoreSays)), save \(String(describing: saveRequestRefusal(lineage)))")
            }
        }
        // Nodes the restore keeps are saved as they are: a removed mark, another kind, another image's mark.
        var kept = SessionLineage()
        try kept.add(kind: "distance", parameters: ["junk": "1", "object": object, "frame": "0", "x1": "oops"], recorded: t0)   // removed below
        try kept.add(kind: "export", parameters: [:], inputs: [.init(step: "s1", role: "mark")], recorded: t0)
        XCTAssertEqual(kept.remove(id: "s1", at: t0), .kept)
        try kept.add(kind: "zzz", parameters: ["x1": "junk"], recorded: t0)
        try kept.add(kind: "angle", parameters: ["object": "Elsewhere", "frame": "0"], recorded: t0)
        XCTAssertNil(saveRequestRefusal(kept))
        // Red under: the save's checks looser or stricter than the restore's (a different function, a different bound).
    }

    func testASaveOfALineageOverTheCapIsRefusedAsTooLarge() throws {
        var lineage = SessionLineage()
        var parameters = distanceParameters
        parameters["note"] = String(repeating: "x", count: SessionLineage.maximumJSONBytes + 10)   // an extra key: the mark is valid
        try lineage.add(kind: "distance", parameters: parameters, recorded: t0)
        guard case .lineage(.tooLarge(let bytes))? = saveRequestRefusal(lineage) else {
            return XCTFail("expected the lineage's size refusal, got \(String(describing: saveRequestRefusal(lineage)))")
        }
        XCTAssertGreaterThan(bytes, SessionLineage.maximumJSONBytes)
        XCTAssertEqual(saveRequestRefusal(SessionLineage(), identity: identity(width: 0)), .identity(.invalid(field: "width")))
        XCTAssertEqual(saveRequestRefusal(SessionLineage(), identity: identity(digest: "short")), .identity(.invalid(field: "pixel_sha256")))
        // Red under: the identity's or the lineage's refusal swallowed or reported as another.
    }

    /// ADR 023 a at the request: the text of a save — the identity marker and the minimum reader (one byte each), the source
    /// and the lineage — is at most 60,000 bytes, else the request is refused by name as the file layer's `.sidecarTooLarge`
    /// carrying the total, so a save never reaches the writer to be refused there. Padded by an extra key (tolerated, kept)
    /// to exactly 60,000 bytes it is made; one byte more is refused; the other kinds' and removed nodes' bytes count. Red under:
    /// the request's budget check removed (the writer would refuse it later, as another case); `>=` for `>`; the lineage alone
    /// counted.
    func testASaveRequestOverSixtyThousandBytesOfTextIsRefusedByName() throws {
        func lineage(padding: Int) throws -> SessionLineage {
            var parameters = distanceParameters
            parameters["note"] = String(repeating: "n", count: padding)
            return try self.lineage([("distance", parameters)])
        }
        let sourceBytes = try identity().jsonString().utf8.count
        func total(_ padding: Int) throws -> Int { 2 + sourceBytes + (try lineage(padding: padding).jsonString().utf8.count) }
        let exact = 60_000 - (try total(0))
        XCTAssertGreaterThan(exact, 0)
        XCTAssertEqual(try total(exact), 60_000)
        XCTAssertNil(saveRequestRefusal(try lineage(padding: exact)))
        XCTAssertEqual(saveRequestRefusal(try lineage(padding: exact + 1)), .file(.sidecarTooLarge(bytes: 60_001)))
        XCTAssertEqual(saveRequestRefusal(try lineage(padding: exact + 5_000)), .file(.sidecarTooLarge(bytes: 65_000)))
        // the source's bytes count too: a long file name takes room from the lineage
        let longName = identity(name: String(repeating: "n", count: 200) + ".dm4")
        let longBytes = try longName.jsonString().utf8.count
        XCTAssertEqual(saveRequestRefusal(try lineage(padding: exact), identity: longName),
                       .file(.sidecarTooLarge(bytes: 60_000 + longBytes - sourceBytes)))
        // other kinds and removed nodes are in the text
        var other = try lineage(padding: 0)
        try other.add(kind: "export", parameters: ["pad": String(repeating: "e", count: 60_000)], recorded: t0)
        XCTAssertEqual(saveRequestRefusal(other).map { if case .file(.sidecarTooLarge) = $0 { true } else { false } }, true)
    }

    func testEveryRefusalReadsAsASentenceNamingWhatIsWrong() {
        XCTAssertEqual(SessionMarks.Refusal.missingKey(node: "s4", key: "x2").reason, "the mark s4 has no x2")
        XCTAssertEqual(SessionMarks.Refusal.badCoordinate(node: "s4", key: "x2", text: "+1").reason,
                       "the mark s4\u{2019}s x2 (\u{201C}+1\u{201D}) is not a finite number")
        XCTAssertEqual(SessionMarks.Refusal.outsideImage(node: "s4", point: 2).reason, "the mark s4\u{2019}s point 2 lies outside the image")
        XCTAssertEqual(SessionMarks.Refusal.badWidth(node: "s4", text: "03").reason,
                       "the mark s4\u{2019}s width (\u{201C}03\u{201D}) is not a whole number of pixels from 1 to 25")
        XCTAssertEqual(SessionMarks.Refusal.missingKey(node: "s4", key: "x2").description, "the mark s4 has no x2")
        // The wrappers say what they wrap.
        let inner = SessionMarks.Refusal.outsideImage(node: "s9", point: 3)
        XCTAssertEqual(SessionRestore.Refusal.mark(inner).reason, inner.reason)
        XCTAssertEqual(SessionSave.Refusal.mark(inner).reason, inner.reason)
        XCTAssertEqual(SessionRestore.Refusal.otherImage("The marks were drawn on another image.").reason, "The marks were drawn on another image.")
        XCTAssertEqual(SessionRestore.Refusal.lineage(.cycle).reason, SessionLineage.Refusal.cycle.reason)
        XCTAssertEqual(SessionRestore.Refusal.identity(.malformed).reason, SessionSourceIdentity.Refusal.malformed.reason)
        XCTAssertTrue(SessionSave.Refusal.readOnly(7).reason.contains("version 7"))
        XCTAssertTrue(SessionSave.Refusal.sidecarRefused("it is foreign").reason.contains("it is foreign"))
        XCTAssertTrue(SessionSave.Refusal.changedOnDisk.reason.contains("changed"))
        XCTAssertEqual(SessionSave.Refusal.file(.foreign).reason, SessionSidecarFile.Refusal.foreign.reason)
        XCTAssertEqual(SessionSave.Refusal.changedOnDisk.description, SessionSave.Refusal.changedOnDisk.reason)
        // Red under: a refusal's wording changed or its node, key, text or point left out.
    }

    // MARK: - The save's write, against a real sidecar

    private func scratchDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionMarksTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func writeRefusal(_ request: SessionSave.Request, to url: URL) -> SessionSave.Refusal? {
        do throws(SessionSave.Refusal) { try SessionSave.write(request, to: url); return nil } catch { return error }
    }

    private func isCannotOpen(_ refusal: SessionSave.Refusal?) -> Bool {
        if case .file(.cannotOpen)? = refusal { return true }
        return false
    }

    private func twoLineages() throws -> (first: SessionLineage, second: SessionLineage) {
        let first = try lineage([("distance", distanceParameters)])
        let second = try lineage([("distance", distanceParameters), ("angle", angleParameters), ("profile", profileParameters)])
        return (first, second)
    }

    func testAFirstSaveCreatesASidecarThatReadsBackAndRestoresTheSameMarks() throws {
        let directory = try scratchDirectory()
        let url = directory.appendingPathComponent("scan.dm4.mactem.h5")
        let lineage = try lineage([("distance", distanceParameters), ("angle", angleParameters), ("profile", profileParameters)])
        let request = try XCTUnwrap(saveRequest(lineage, expected: nil))
        XCTAssertNil(writeRefusal(request, to: url))
        let onDisk = try SessionSidecarFile.read(url: url)
        XCTAssertEqual(onDisk, SessionSidecarFile.Contents(schema: 1, minReader: 1, source: request.source, lineage: request.lineage))
        let restored = try XCTUnwrap(restored(onDisk))
        XCTAssertEqual(restored.verdict, .adopt)
        XCTAssertEqual(restored.marks.map(\.nodeID), ["s1", "s2", "s3"])
        XCTAssertEqual(restored.lineage, lineage)
        XCTAssertEqual(restored.lineageText, request.lineage)
        // A restore saved again with no edit writes the same attribute, byte for byte.
        let again = try XCTUnwrap(saveRequest(restored.lineage, expected: restored.lineageText))
        XCTAssertNil(writeRefusal(again, to: url))
        XCTAssertEqual(try SessionSidecarFile.read(url: url), onDisk)
        // Red under: the write skipping the file layer, or writing the source and lineage the wrong way round.
    }

    func testASaveReplacesTheFileItReadAndSaysSoWhenItIsStale() throws {
        let url = try scratchDirectory().appendingPathComponent("scan.dm4.mactem.h5")
        let (first, second) = try twoLineages()
        XCTAssertNil(writeRefusal(try XCTUnwrap(saveRequest(first)), to: url))
        // The file holds `first`; a save that read it replaces it.
        let firstText = try first.jsonString()
        let secondRequest = try XCTUnwrap(saveRequest(second, expected: firstText))
        XCTAssertNil(writeRefusal(secondRequest, to: url))
        XCTAssertEqual(try SessionSidecarFile.read(url: url).lineage, secondRequest.lineage)
        // The same request again is now stale: the file holds `second`, not what that save read.
        let before = try Data(contentsOf: url)
        XCTAssertEqual(writeRefusal(secondRequest, to: url), .changedOnDisk)
        XCTAssertEqual(try Data(contentsOf: url), before, "refused, so untouched")
        // Red under: the changed-on-disk check skipped, or made against anything but the lineage text.
    }

    func testASaveRefusesAFileThatChangedSinceItWasRead() throws {
        let url = try scratchDirectory().appendingPathComponent("scan.dm4.mactem.h5")
        let (first, second) = try twoLineages()
        XCTAssertNil(writeRefusal(try XCTUnwrap(saveRequest(first)), to: url))
        // Another app or machine wrote `second`; this session last read `first`.
        let theirs = try XCTUnwrap(saveRequest(second, expected: try first.jsonString()))
        XCTAssertNil(writeRefusal(theirs, to: url))
        let before = try Data(contentsOf: url)
        let mine = try XCTUnwrap(saveRequest(try lineage([("profile", profileParameters)]), expected: try first.jsonString()))
        XCTAssertEqual(writeRefusal(mine, to: url), .changedOnDisk)
        XCTAssertEqual(try Data(contentsOf: url), before)
        XCTAssertEqual(try SessionSidecarFile.read(url: url).lineage, theirs.lineage)
        // Red under: the changed-on-disk check skipped (the other writer's marks lost without a word).
    }

    func testASaveRefusesAFileThisSessionNeverRead() throws {
        let url = try scratchDirectory().appendingPathComponent("scan.dm4.mactem.h5")
        let (first, second) = try twoLineages()
        XCTAssertNil(writeRefusal(try XCTUnwrap(saveRequest(first)), to: url))
        let before = try Data(contentsOf: url)
        // Nothing was restored or saved by this window (expectedOnDisk is nil), yet a sidecar is there.
        XCTAssertEqual(writeRefusal(try XCTUnwrap(saveRequest(second, expected: nil)), to: url), .changedOnDisk)
        XCTAssertEqual(try Data(contentsOf: url), before)
        // A sidecar that was deleted since is written anew: there is nothing of anyone's to lose.
        try FileManager.default.removeItem(at: url)
        XCTAssertNil(writeRefusal(try XCTUnwrap(saveRequest(second, expected: try first.jsonString())), to: url))
        XCTAssertEqual(try SessionSidecarFile.read(url: url).lineage, try second.jsonString())
        // Red under: an unread file treated as matching (expected nil skipping the check); the check made against an absent file.
    }

    func testChoosingToReplaceWritesOverAFileThatChangedOrWasNeverRead() throws {
        let url = try scratchDirectory().appendingPathComponent("scan.dm4.mactem.h5")
        let (first, second) = try twoLineages()
        XCTAssertNil(writeRefusal(try XCTUnwrap(saveRequest(first)), to: url))
        // Changed since read: refused, then replaced when the user chose to.
        let stale = try XCTUnwrap(saveRequest(second, expected: "something else"))
        XCTAssertEqual(writeRefusal(stale, to: url), .changedOnDisk)
        let replacing = try XCTUnwrap(saveRequest(second, expected: "something else", replacing: true))
        XCTAssertNil(writeRefusal(replacing, to: url))
        XCTAssertEqual(try SessionSidecarFile.read(url: url).lineage, replacing.lineage)
        // Never read: the same.
        let never = try XCTUnwrap(saveRequest(first, expected: nil, replacing: true))
        XCTAssertNil(writeRefusal(never, to: url))
        XCTAssertEqual(try SessionSidecarFile.read(url: url).lineage, never.lineage)
        // Red under: the replacing flag ignored (the check made regardless); the check skipped when it is not set.
    }

    func testASaveNamesAFileThatIsNotASidecarAndLeavesItAlone() throws {
        let directory = try scratchDirectory()
        let (first, _) = try twoLineages()
        // Not HDF5 at all.
        let text = directory.appendingPathComponent("text.mactem.h5")
        try Data("not hdf5".utf8).write(to: text)
        XCTAssertTrue(isCannotOpen(writeRefusal(try XCTUnwrap(saveRequest(first, expected: nil)), to: text)))
        XCTAssertEqual(try Data(contentsOf: text), Data("not hdf5".utf8))
        // An HDF5 file with no identity marker: foreign.
        let foreign = directory.appendingPathComponent("foreign.mactem.h5")
        try TestHDF5Library.withLibrary { h5 in
            let id = foreign.path.withCString { h5.h5fcreate($0, h5FileTruncate, h5DefaultProperty, h5DefaultProperty) }
            XCTAssertGreaterThanOrEqual(id, 0)
            _ = h5.h5fclose(id)
        }
        let foreignBytes = try Data(contentsOf: foreign)
        XCTAssertEqual(writeRefusal(try XCTUnwrap(saveRequest(first, expected: nil)), to: foreign), .file(.foreign))
        XCTAssertEqual(try Data(contentsOf: foreign), foreignBytes)
        // Red under: a file the layer refuses reported as changed, or overwritten.
    }

    func testChoosingToReplaceDoesNotOverwriteAFileMacTEMCannotReadBack() throws {
        // REPORTED, not approved: says a save after an unreadable or refused sidecar waits "until the user chooses to
        // replace it", and SessionSave.Request.replacing says "whatever it holds". The file layer still refuses a file that is not
        // HDF5, one with no identity marker, and (by its header) a newer minimum reader or schema, so for those the choice
        // reaches the same named refusal as not choosing. Replacing works over a readable sidecar whose marks were refused
        // (another image, a bad node) or that changed. This pins what happens today so a change is deliberate.
        let directory = try scratchDirectory()
        let (first, _) = try twoLineages()
        let text = directory.appendingPathComponent("text.mactem.h5")
        try Data("not hdf5".utf8).write(to: text)
        let request = try XCTUnwrap(saveRequest(first, expected: nil, replacing: true))
        XCTAssertTrue(isCannotOpen(writeRefusal(request, to: text)))
        XCTAssertEqual(try Data(contentsOf: text), Data("not hdf5".utf8))
        // A readable sidecar whose marks the restore refused (a bad node) is replaced when the user chooses to.
        let url = directory.appendingPathComponent("scan.dm4.mactem.h5")
        let broken = try lineage([("distance", with(distanceParameters, "x1", "oops"))])
        try SessionSidecarFile.write(source: try identity().jsonString(), lineage: try broken.jsonString(), to: url)
        XCTAssertNotNil(restoreRefusal(try SessionSidecarFile.read(url: url)))
        XCTAssertEqual(writeRefusal(try XCTUnwrap(saveRequest(first, expected: nil)), to: url), .changedOnDisk)
        XCTAssertNil(writeRefusal(request, to: url))
        XCTAssertEqual(try SessionSidecarFile.read(url: url).lineage, request.lineage)
    }

    func testAWriteToAnURLThatIsNotAFileIsRefusedByName() throws {
        let (first, _) = try twoLineages()
        let request = try XCTUnwrap(saveRequest(first))
        guard case .file(.cannotWrite(let operation, _))? = writeRefusal(request, to: try XCTUnwrap(URL(string: "https://example.com/scan.mactem.h5"))) else {
            return XCTFail("expected the file layer's refusal")
        }
        XCTAssertEqual(operation, "locating the file")
    }
}
