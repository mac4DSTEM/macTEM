//
//  FixtureReadTests.swift
//  Pins the committed planted fixture end to end through the app's one entry point: `ImageOpening.openNow` on
//  Fixtures/planted-2d.dm4 equals Fixtures/planted-2d.truth.json exactly (shape, every pixel in row-major order,
//  both axes' origin, float32 scale bits and units, voltage, the object named, the file name), and the fixture's
//  bytes are the ones the truth was written from (sha256), so a silently regenerated fixture is caught here.
//  The truth's own key numbers are pinned as literals too, so a regenerated PAIR is caught as well.
//

import ImagoCore
import CryptoKit
import XCTest
import TEMCore
import FormatoDM

nonisolated final class FixtureReadTests: XCTestCase {

    nonisolated struct Truth: Decodable {
        nonisolated struct Axis: Decodable {
            let origin: Double
            let scale: Double
            let scaleF32Bits: String
            let units: String
            enum CodingKeys: String, CodingKey {
                case origin, scale, units
                case scaleF32Bits = "scale_f32_bits"
            }
        }
        let fileSHA256: String
        let objectIndex: Int
        let objectName: String
        let width: Int
        let height: Int
        let voltageV: Double
        let x: Axis
        let y: Axis
        let pixelsRowMajor: [Int]
        enum CodingKeys: String, CodingKey {
            case width, height, x, y
            case fileSHA256 = "file_sha256"
            case objectIndex = "object_index"
            case objectName = "object_name"
            case voltageV = "voltage_v"
            case pixelsRowMajor = "pixels_row_major"
        }
    }

    private func fixtureURL() throws -> URL {
        // Fixtures/ is copied flat into the test bundle's Resources: this works signed and sandboxed too.
        try XCTUnwrap(Bundle(for: FixtureReadTests.self).url(forResource: "planted-2d", withExtension: "dm4"),
                      "planted-2d.dm4 is not in the test bundle")
    }

    private func truth() throws -> Truth {
        let url = try XCTUnwrap(
            Bundle(for: FixtureReadTests.self).url(forResource: "planted-2d.truth", withExtension: "json"),
            "planted-2d.truth.json is not in the test bundle")
        return try JSONDecoder().decode(Truth.self, from: Data(contentsOf: url))
    }

    private static func f32Bits(_ hex: String) throws -> UInt32 {
        try XCTUnwrap(hex.hasPrefix("0x") ? UInt32(hex.dropFirst(2), radix: 16) : nil, "bad bits \(hex)")
    }

    func testThePlantedFixtureOpensExactlyAsItsTruth() throws {
        let truth = try truth()
        let image = try ImageOpening.openNow(path: try fixtureURL().path)

        XCTAssertEqual(image.width, truth.width)
        XCTAssertEqual(image.height, truth.height)
        XCTAssertEqual(truth.pixelsRowMajor.count, truth.width * truth.height)
        XCTAssertEqual(image.pixels, truth.pixelsRowMajor.map(Float.init), "every pixel, row-major, x fastest")

        let x = try XCTUnwrap(image.x), y = try XCTUnwrap(image.y)
        for (axis, want, name) in [(x, truth.x, "x"), (y, truth.y, "y")] {
            XCTAssertEqual(axis.origin, want.origin, "\(name) origin")
            XCTAssertEqual(axis.scale, want.scale, "\(name) scale")
            // The file stores float32: the Double is that float32 widened, bit for bit, never a rounded decimal.
            XCTAssertEqual(Float(axis.scale).bitPattern, try Self.f32Bits(want.scaleF32Bits), "\(name) scale bits")
            XCTAssertEqual(axis.scale, Double(Float(bitPattern: try Self.f32Bits(want.scaleF32Bits))), "\(name)")
            XCTAssertEqual(axis.unit, want.units, "\(name) units")
        }
        XCTAssertEqual(image.voltage, truth.voltageV)
        XCTAssertEqual(image.source, "ImageList.\(truth.objectIndex) · \(truth.objectName)")
        XCTAssertEqual(image.fileName, "planted-2d.dm4")
    }

    /// The truth file's own numbers, as make_fixture.py plants them: a regenerated fixture AND truth pair that
    /// moved any of them fails here even though the two still agree with each other.
    func testTheTruthIsThePlantedOne() throws {
        let truth = try truth()
        XCTAssertEqual([truth.width, truth.height], [40, 24])
        XCTAssertEqual(truth.objectIndex, 2, "ImageList.1 is the thumbnail")
        XCTAssertEqual(truth.objectName, "planted")
        XCTAssertEqual(truth.voltageV, 200_000)
        XCTAssertEqual([truth.x.origin, truth.y.origin], [12, -4.5])
        XCTAssertEqual([truth.x.scaleF32Bits, truth.y.scaleF32Bits], ["0x3c4985f0", "0x3cc985f0"])
        XCTAssertEqual([truth.x.units, truth.y.units], ["nm", "nm"])
        // Pixel (row, col) = row * 1000 + col - 12000.
        XCTAssertEqual(truth.pixelsRowMajor, (0..<24).flatMap { r in (0..<40).map { c in r * 1000 + c - 12000 } })
        let image = try ImageOpening.openNow(path: try fixtureURL().path)
        XCTAssertEqual(image.source, "ImageList.2 · planted")
        XCTAssertEqual(image.voltage, 200_000)
    }

    func testTheFixtureBytesAreTheOnesTheTruthWasWrittenFrom() throws {
        let truth = try truth()
        let bytes = try Data(contentsOf: try fixtureURL())
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(digest, truth.fileSHA256, "planted-2d.dm4 changed without its truth being regenerated")
    }

    /// The fixture's first object is an RGBA thumbnail of two dimensions over one: the object rule must skip it.
    func testTheObjectRuleSkipsTheFixturesThumbnail() throws {
        let objects = try DM4Experiment.list(path: try fixtureURL().path)
        XCTAssertEqual(objects.map(\.index), [1, 2])
        XCTAssertEqual(objects[0].role, .thumbnail)
        XCTAssertEqual(objects[0].dimensions.filter { $0 > 1 }.count, 2, "the thumbnail is itself 2D")
        XCTAssertEqual(ImageOpening.primaryImageObject(in: objects)?.index, 2)
    }
}
