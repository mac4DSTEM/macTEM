//
//  AssumedDetectorValuesTests.swift
//  macEM#612: a detector value the file does not state (projection centre, detector pixel size, sample tilt) is taken as kikuchipy's
//  default, as before, and now says so: the opener flags it, the Patterns and Indexing rooms write "assumed" beside it, and the
//  indexing method record lists it. A value the file states carries no flag.
//  Red before: every opener returned the default with nothing to tell it from a calibrated value.
//

import Foundation
import TEMCore
import TEMSession
import XCTest
@testable import macTEM

nonisolated final class AssumedDetectorValuesTests: XCTestCase {
    private static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
    private let en = Locale(identifier: "en_US")

    /// Each HDF5 opener flags exactly what its file leaves out. The Bruker fixture states PCX/PCY/DD and the detector heights but no
    /// 'Sample Tilt' (the key kikuchipy reads); EDAX never states a pixel size; the H5OINA states its PC and 'Tilt Angle'.
    func testEachOpenerFlagsTheValuesItsFileLeavesOut() throws {
        let cases: [(String, Set<EBSDDetectorGeometry.Assumed>)] = [
            ("ebsd-bruker-h5ebsd.h5", [.sampleTilt]),
            ("ebsd-edax-h5ebsd.h5", [.pixelSize]),
            ("ebsd-oxford.h5oina", [.pixelSize]),
        ]
        for (name, expected) in cases {
            let dataset = try EBSDH5Reader.read(url: Self.fixtures.appendingPathComponent(name))
            XCTAssertEqual(dataset.detector.assumed, expected, name)
        }
    }

    /// The words, in a fixed order, and nil when the file stated everything.
    func testTheAssumedValuesReadInAFixedOrder() {
        var detector = EBSDDetectorGeometry(rows: 4, columns: 5, projectionCenters: [SIMD3(0.5, 0.5, 0.5)])
        XCTAssertNil(detector.assumedText)
        detector.assumed = [.sampleTilt, .projectionCenter, .pixelSize]
        XCTAssertEqual(detector.assumedText, "projection centre, detector pixel size, sample tilt")
    }

    /// The Patterns room's Calibration rows and the Indexing room's PC and tilt rows say "assumed" beside an assumed value only.
    func testTheRoomsSayAssumedBesideAnAssumedValue() throws {
        var dataset = try DemoDocuments.ebsd().dataset
        dataset.detector.projectionCenters = [SIMD3(0.4215, 0.2163, 0.5323)]
        dataset.detector.assumed = []
        func value(_ label: String) -> String? { EBSDBrowsing.calibrationRows(dataset, locale: en).first { $0.label == label }?.value }
        XCTAssertEqual(value("Projection centre"), "(0.4215, 0.2163, 0.5323)")
        XCTAssertFalse(value("Sample tilt")?.contains("assumed") ?? true)
        XCTAssertNil(value("Detector pixel"))

        dataset.detector.assumed = [.projectionCenter, .pixelSize, .sampleTilt]
        XCTAssertEqual(value("Projection centre"), "(0.4215, 0.2163, 0.5323) · assumed")
        XCTAssertTrue(value("Sample tilt")?.hasSuffix("° · assumed") ?? false)
        XCTAssertTrue(value("Detector pixel")?.hasSuffix("µm · assumed") ?? false)

        let pc = SIMD3<Double>(0.4215, 0.2163, 0.5323)
        XCTAssertEqual(IndexingInfoFormat.projectionCentre(pc, assumed: true, locale: en), "(0.4215, 0.2163, 0.5323) · assumed (the file states none)")
        XCTAssertEqual(IndexingInfoFormat.projectionCentre(pc, locale: en), "(0.4215, 0.2163, 0.5323) · mean of the file's")
        XCTAssertTrue(IndexingInfoFormat.tiltRows(dataset.detector, locale: en)[0].value.hasSuffix("° · assumed"))
        dataset.detector.assumed = []
        XCTAssertFalse(IndexingInfoFormat.tiltRows(dataset.detector, locale: en)[0].value.contains("assumed"))
    }
}
