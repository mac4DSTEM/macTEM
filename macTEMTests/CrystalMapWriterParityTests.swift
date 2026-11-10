//
//  CrystalMapWriterParityTests.swift
//  TEMCore's crystal map writers (Sources/TEMCore/SEM/Export: `ANGWriter`, `CTFWriter`) against the bundles `m8/write-ang-*`
//  (orix 0.15.0's `.ang` `file_writer`) and `m8/write-ctf-*` (tools/parity/sem/ctf_writer.py, the Oxford layout orix's reader
//  reads; orix writes no .ctf), figure F18: the written file's bytes equal the reference's (sha256 of the whole file, its line
//  count, every header line and every 50th data line), and `emit.py` asserts that orix reads each reference back to the
//  written precision, so orix reads ours back the same. Maps: orix-data's two-phase sdss map (committed reader fixture), its
//  ferrite points (a masked map: austenite written as not indexed), its rows 10-19 × columns 5-14, and the 3 × 507 Ti head.
//  Red before the port: neither writer exists. Red after a column width, a rounding, a phase order or a not-indexed value
//  that differs from orix.
//

import CryptoKit
import Foundation
import TEMCore
import XCTest

nonisolated final class CrystalMapWriterParityTests: XCTestCase {

    private static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")

    /// orix-data's sdss map as `orix.io.load` gives it (the reader's phases, Euler angles, coordinates and properties).
    private func sdssMap() throws -> CrystalMap {
        try ANGReader.read(url: Self.fixtures.appendingPathComponent("ebsd-sdss-ferrite-austenite.ang")).map
    }

    /// The Ti head as `writer_cases._ti` builds it: Bunge angles in degrees from the committed bundle, a 0.25 µm grid, phase 1
    /// Ti with space group 194 (point group 6/mmm) and its lattice.
    private func tiMap() throws -> CrystalMap {
        let ref = try SEMParityReference.load("m3/ti-neighbour-misorientations")
        let d = try ref.array("euler_degrees").values
        let degrees = stride(from: 0, to: d.count, by: 3).map { SIMD3(d[$0], d[$0 + 1], d[$0 + 2]) }
        let grid = CrystalMap.coordinates(shape: (3, 507), steps: (0.25, 0.25))
        let ti = CrystalPhase(name: "Ti", spaceGroup: 194, pointGroup: "6/mmm", lattice: [2.95, 2.95, 4.68, 90, 90, 120])
        return try CrystalMap(euler: degrees.map { $0 * (.pi / 180) }, phaseIDs: Array(repeating: 1, count: degrees.count), x: grid.x,
                              y: grid.y, phaseList: PhaseList([(1, ti)]), scanUnit: "um")
    }

    private func map(_ key: String) throws -> CrystalMap {
        switch key {
        case "ti": return try tiMap()
        case "sdss-ferrite":
            let sdss = try sdssMap()
            return sdss[phase: sdss.phases.names[1]]
        case "sdss-window": return try sdssMap().sliced(rows: 10..<20, columns: 5..<15)
        default: return try sdssMap()
        }
    }

    /// The written text against the bundle: line count, header lines, the sampled data lines (first difference reported), then
    /// the sha256 of the whole file.
    private func assertMatches(_ text: String, _ caseName: String, ang: Bool, file: StaticString = #filePath, line: UInt = #line) throws {
        let ref = try SEMParityReference.load(caseName)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).dropLast().map(String.init)
        XCTAssertTrue(text.hasSuffix("\n"), "\(caseName): the file ends with a newline", file: file, line: line)
        XCTAssertEqual(lines.count, ref.values["line_count"] as? Int, "\(caseName): line count", file: file, line: line)
        let header = try XCTUnwrap(ref.values["header_lines"] as? [String], file: file, line: line)
        let ours = ang ? lines.filter { $0.hasPrefix("#") } : Array(lines.prefix(header.count))
        XCTAssertEqual(ours, header, "\(caseName): header", file: file, line: line)
        let sample = try XCTUnwrap(ref.values["data_line_sample"] as? [String: String], file: file, line: line)
        for (index, expected) in sample.sorted(by: { Int($0.key)! < Int($1.key)! }) {
            let i = Int(index)!
            guard i < lines.count else { XCTFail("\(caseName): no line \(i)", file: file, line: line); return }
            if lines[i] != expected {
                XCTFail("\(caseName): line \(i)\n  ours   \(lines[i].debugDescription)\n  orix's \(expected.debugDescription)", file: file, line: line)
                return
            }
        }
        let bytes = Data(text.utf8)
        XCTAssertEqual(bytes.count, ref.values["byte_count"] as? Int, "\(caseName): byte count", file: file, line: line)
        let fingerprint = try XCTUnwrap(ref.values["file_bytes"] as? [String: Any], file: file, line: line)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(digest, fingerprint["sha256"] as? String, "\(caseName): the file's sha256", file: file, line: line)
    }

    private static let keys = ["sdss", "sdss-ferrite", "sdss-window", "ti"]

    // MARK: - .ang (orix's writer)

    func testANGFilesMatchOrixByteForByte() throws {
        for key in Self.keys {
            let text = try ANGWriter.text(of: try map(key), options: .init(operatorName: "orix_v0.15.0"))
            try assertMatches(text, "m8/write-ang-\(key)", ang: true)
        }
    }

    // MARK: - .ctf (the Oxford layout, read back by orix)

    func testCTFFilesMatchTheReferenceWriterByteForByte() throws {
        for key in Self.keys {
            let text = try CTFWriter.text(of: try map(key), project: key, author: "macTEM")
            try assertMatches(text, "m8/write-ctf-\(key)", ang: false)
        }
    }

    // MARK: - Round trips through TEMCore's own readers (the ports of orix's)

    /// Figure F18 in Swift: every written map read back by `ANGReader` and `CTFReader` has the original's shape, steps, phase
    /// ids, indexed points and rotations to the written precision (three angles at 5 decimals of radians: under 2e-5 rad; at 4 decimals of
    /// degrees: under 3e-6 rad).
    func testWrittenMapsReadBackAsTheOriginals() throws {
        for key in Self.keys {
            let original = try map(key)
            let ang = try ANGReader.read(text: try ANGWriter.text(of: original), url: URL(fileURLWithPath: "/\(key).ang")).map
            let ctf = try CTFReader.read(text: try CTFWriter.text(of: original, project: key)).map
            for (format, back, bound) in [("ang", ang, 2.0e-5), ("ctf", ctf, 3.0e-6)] {
                let label = "\(key).\(format)"
                let extent = try CrystalMapExtent(original)
                XCTAssertEqual(back.shape, [extent.rows, extent.columns], label)
                XCTAssertEqual(back.dx, original.dx, label)
                XCTAssertEqual(back.dy, original.dy, label)
                XCTAssertEqual(back.isIndexed, extent.indexed, label)
                let originalIDs = original.mapData(original.phaseIDs.map(Double.init), fill: -1)
                let names = Dictionary(uniqueKeysWithValues: original.phases.entries.map { ($0.id, $0.phase.name) })
                let backNames = Dictionary(uniqueKeysWithValues: back.phases.entries.map { ($0.id, $0.phase.name) })
                for (i, id) in back.phaseIDs.enumerated() where extent.indexed[i] {
                    XCTAssertEqual(backNames[id], names[Int(originalIDs[i])], "\(label) point \(i)")
                }
                var worst = 0.0
                let rotations = original.rotationsInData
                var k = 0
                let expected = (0..<4).map { c in original.mapData(rotations.map { $0[c] }, fill: 0) }
                for (i, q) in back.rotationsInData.enumerated() where extent.indexed[i] {
                    let o = Rotation(SIMD4(expected[0][i], expected[1][i], expected[2][i], expected[3][i]))
                    worst = max(worst, Rotation(q).angle(with: o))
                    k += 1
                }
                XCTAssertGreaterThan(k, 0, label)
                XCTAssertLessThan(worst, bound, "\(label): largest rotation difference \(worst) rad")
            }
        }
    }

    // MARK: - Files and refusals

    /// `write` puts the text on disk unchanged, and the .ctf's project defaults to the file's name.
    func testWritersPutTheTextOnDisk() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let ti = try tiMap()
        let angURL = folder.appendingPathComponent("ti.ang"), ctfURL = folder.appendingPathComponent("ti.ctf")
        try ANGWriter.write(ti, to: angURL)
        try CTFWriter.write(ti, to: ctfURL)
        XCTAssertEqual(try String(contentsOf: angURL, encoding: .utf8), try ANGWriter.text(of: ti))
        XCTAssertEqual(try String(contentsOf: ctfURL, encoding: .utf8), try CTFWriter.text(of: ti, project: "ti"))
        XCTAssertTrue(try ANGWriter.text(of: ti).contains("# OPERATOR: macTEM\n"))
    }

    /// A property asked for by name that the map lacks is refused; a one-point map has no grid to write.
    func testRefusals() throws {
        XCTAssertThrowsError(try ANGWriter.text(of: try tiMap(), options: .init(imageQuality: "band_contrast"))) {
            XCTAssertEqual($0 as? CrystalMapExtent.Refusal, .noProperty("band_contrast"))
        }
        let one = try CrystalMap(rotations: [SIMD4(1, 0, 0, 0)])
        XCTAssertThrowsError(try CTFWriter.text(of: one)) { XCTAssertEqual($0 as? CrystalMapExtent.Refusal, .noGrid) }
    }

    /// Five points of a 2 × 3 scan stopped one point short, with Bands, Error, BC and BS: the cell past the last point holds no
    /// value (NaN in the map's data) and writes what a point not indexed writes, Bands 0, Error 3, BC 0, BS 0; the points keep
    /// their own. Red before: the writer converted the NaN with Int(_:), which traps.
    func testACTFCellPastTheLastPointWritesTheFallback() throws {
        let properties: [String: [Double]] = ["Bands": [8, 9, 10, 11, 12], "Error": [0, 0, 0, 0, 0],
                                              "BC": [100, 101, 102, 103, 104], "BS": [50, 51, 52, 53, 54]]
        let map = try CrystalMap(rotations: Array(repeating: SIMD4<Double>(1, 0, 0, 0), count: 5), x: [0, 1, 2, 0, 1],
                                 y: [0, 0, 0, 1, 1], properties: properties)
        let lines = try CTFWriter.text(of: map).split(separator: "\n").map(String.init)
        let header = try XCTUnwrap(lines.firstIndex(of: "Phase\tX\tY\tBands\tError\tEuler1\tEuler2\tEuler3\tMAD\tBC\tBS"))
        let cells = lines[(header + 1)...].map { $0.split(separator: "\t").map(String.init) }
        XCTAssertEqual(cells.count, 6, "2 rows of 3 cells")
        // Bands, Error, BC and BS: columns 3, 4, 9 and 10.
        XCTAssertEqual(cells.prefix(5).map { [$0[3], $0[4], $0[9], $0[10]] },
                       (0..<5).map { ["\(8 + $0)", "0", "\(100 + $0)", "\(50 + $0)"] })
        let past = try XCTUnwrap(cells.last)
        XCTAssertEqual([past[0], past[3], past[4], past[9], past[10]], ["0", "0", "3", "0", "0"])
    }

    /// An extra column follows orix's `extra_prop`: named in the header, written with its own width, 0 where not indexed.
    func testExtraPropertyColumnFollowsOrix() throws {
        let sdss = try sdssMap()
        let text = try ANGWriter.text(of: sdss, options: .init(extraProperties: ["dp"]))
        let lines = text.split(separator: "\n").map(String.init)
        XCTAssertTrue(lines.contains("# Column names: phi1, Phi, phi2, x, y, image_quality, confidence_index, phase_id, detector_signal, pattern_fit, dp"))
        let first = try XCTUnwrap(lines.first { !$0.hasPrefix("#") })
        let fields = first.split(separator: " ")
        XCTAssertEqual(fields.count, 11)
        let dp = try XCTUnwrap(sdss.property("dp")?.first)
        XCTAssertEqual(Double(fields[10])!, Double(Float((dp * 100_000).rounded(.toNearestOrEven) / 100_000)), accuracy: 5e-6)
    }
}
