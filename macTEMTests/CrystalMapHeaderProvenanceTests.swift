//
//  CrystalMapHeaderProvenanceTests.swift
//  macEM#616 (bundle C of #603): the .ang and .ctf headers carry the pattern centre, working distance, magnification, beam energy and
//  tilt the session knows, and every SEM export names the app and kit versions. Red before: both writers wrote zeros whatever the
//  session knew, and the method JSON and the PNGs said only "macEM". Without an acquisition the bytes are the reference writers'
//  (CrystalMapWriterParityTests).
//

import Foundation
import TEMCore
import XCTest
@testable import macTEM

nonisolated final class CrystalMapHeaderProvenanceTests: XCTestCase {

    private static let sdss = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/ebsd-sdss-ferrite-austenite.ang")
    private static let info: [String: Any] = ["CFBundleShortVersionString": "2.1.0", "CFBundleVersion": "42"]

    private static let acquisition = CrystalMapAcquisition(patternCentreTSL: SIMD3(0.4512, 0.6271, 0.5983), workingDistanceMM: 15.2,
                                                           magnification: 2000, beamEnergyKeV: 20, sampleTiltDegrees: 70,
                                                           software: ExportSnapshot.provenance(info: info))

    func testTheANGHeaderStatesTheKnownValuesAndOrixsReaderReadsThemBack() throws {
        let map = try ANGReader.read(url: Self.sdss).map
        let text = try ANGWriter.text(of: map, options: .init(acquisition: Self.acquisition))
        let back = try ANGReader.read(text: text, url: URL(fileURLWithPath: "/sdss.ang"))
        let pc = try XCTUnwrap(back.header.projectionCenter)
        XCTAssertEqual(pc.x, 0.4512, accuracy: 1e-6); XCTAssertEqual(pc.y, 0.6271, accuracy: 1e-6); XCTAssertEqual(pc.z, 0.5983, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(back.header.workingDistance), 15.2, accuracy: 1e-6)
        XCTAssertTrue(text.contains("# NOTES: Written by macEM 2.1.0 (42) with FormatoKit"), "the build and the kits")
        XCTAssertTrue(text.contains("# NOTES: Beam energy 20 kV"))
        XCTAssertEqual(back.map.size, map.size)
        // Without an acquisition: orix's zeros, no notes.
        let plain = try ANGWriter.text(of: map)
        XCTAssertTrue(plain.contains("# x-star                 0.000000\n"))
        XCTAssertFalse(plain.contains("NOTES"))
    }

    func testTheCTFHeaderStatesMagnificationBeamEnergyAndTilt() throws {
        let map = try ANGReader.read(url: Self.sdss).map
        let text = try CTFWriter.text(of: map, project: "sdss", author: ExportSnapshot.softwareName(info: Self.info), acquisition: Self.acquisition)
        XCTAssertTrue(text.contains("\tMag\t2000\tCoverage\t100\tDevice\t0\tKV\t20\tTiltAngle\t70\tTiltAxis\t0\n"), "the CS0 line")
        XCTAssertTrue(text.contains("Author\tmacEM 2.1.0 (42)\n"))
        let back = try CTFReader.read(text: text).map
        XCTAssertEqual(back.size, map.size)
        // Unknown stays the format's 0.
        let unknown = try CTFWriter.text(of: map, acquisition: CrystalMapAcquisition(magnification: nil, beamEnergyKeV: 15.5))
        XCTAssertTrue(unknown.contains("\tMag\t0\tCoverage\t100\tDevice\t0\tKV\t15.5\tTiltAngle\t0\t"))
    }

    func testTheAcquisitionComesFromTheDatasetAndTheRunsCentre() {
        let detector = EBSDDetectorGeometry(rows: 60, columns: 60, sampleTilt: 70, projectionCenters: [SIMD3(0.5, 0.4, 0.6)])
        let dataset = EBSDDataset(format: .generated, manufacturer: "t", version: "", scanGroup: "s", scanGroups: ["s"], scanRows: 1,
                                  scanColumns: 1, patternRows: 60, patternColumns: 60, dataType: .uint8, stepY: 1, stepX: 1, detector: detector,
                                  sem: EBSDSEMHeader(beamEnergyKeV: 20, magnification: nil, workingDistanceMM: .nan),
                                  patterns: EBSDPatternSource(url: URL(fileURLWithPath: "/p"), datasetPath: "", fileShape: [1, 1, 60, 60],
                                                              dataType: .uint8))
        let a = CrystalMapAcquisition(dataset: dataset, projectionCenterBruker: SIMD3(0.5, 0.4, 0.6), software: "x")
        // kikuchipy's Bruker to TSL: x*, 1 − y*, z* on a square detector.
        XCTAssertEqual(a.patternCentreTSL, SIMD3(0.5, 0.6, 0.6))
        XCTAssertEqual(a.beamEnergyKeV, 20)
        XCTAssertNil(a.magnification)
        XCTAssertNil(a.workingDistanceMM, "a NaN working distance is unknown")
        XCTAssertEqual(a.sampleTiltDegrees, 70)
    }

    func testTheMethodRecordAndThePNGsNameTheAppAndTheKits() throws {
        let provenance = ExportSnapshot.provenance(info: Self.info)
        XCTAssertTrue(provenance.hasPrefix("macEM 2.1.0 (42) with "))
        for kit in SEMMethod.builtWith { XCTAssertTrue(provenance.contains("\(kit.name) \(kit.value)"), kit.name) }
        let json = try ExportSnapshot.stampingProvenance(Data(#"{"software": "macEM", "points": 4}"#.utf8), info: Self.info)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: json) as? [String: Any])
        XCTAssertEqual(object["software"] as? String, "macEM 2.1.0 (42)")
        XCTAssertEqual(object["points"] as? Int, 4)
        let kits = try XCTUnwrap(object["builtWith"] as? [String: String])
        XCTAssertEqual(kits.count, SEMMethod.builtWith.count)
    }
}
