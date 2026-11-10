//
//  ProjectionCentreWordsTests.swift
//  The projection centre's three numbers read as three in every locale (`UnitDisplay.triple`): parted by commas where the decimal mark is
//  a point, by semicolons where it is a comma. Red before: "(0,4215, 0,2163, 0,5323)" in German, the decimal comma and the list's one mark.
//  The session report's locale (`ExportSnapshot.labelLocale`) writes the same text as before.
//

import Foundation
import TEMCore
import TEMSession
import XCTest
@testable import macTEM

nonisolated final class ProjectionCentreWordsTests: XCTestCase {
    private let pc = SIMD3<Double>(0.4215, 0.2163, 0.5323)
    private let de = Locale(identifier: "de_DE")
    private let en = Locale(identifier: "en_US")

    /// The helper, the Indexing room's PC row (also the session report's) and the Patterns room's Calibration row.
    func testThePCReadsAsThreeNumbersInACommaLocale() throws {
        XCTAssertEqual(UnitDisplay.triple(pc, digits: 4, locale: de), "(0,4215; 0,2163; 0,5323)")
        XCTAssertEqual(UnitDisplay.triple(pc, digits: 4, locale: en), "(0.4215, 0.2163, 0.5323)")
        XCTAssertEqual(UnitDisplay.triple(pc, digits: 4, locale: ExportSnapshot.labelLocale), "(0.4215, 0.2163, 0.5323)")
        XCTAssertEqual(IndexingInfoFormat.projectionCentre(pc, locale: de), "(0,4215; 0,2163; 0,5323) · mean of the file's")
        XCTAssertEqual(IndexingInfoFormat.projectionCentre(pc, locale: en), "(0.4215, 0.2163, 0.5323) · mean of the file's")

        var dataset = try DemoDocuments.ebsd().dataset
        dataset.detector.projectionCenters = [pc]
        func row(_ locale: Locale) -> String? {
            EBSDBrowsing.calibrationRows(dataset, locale: locale).first { $0.label == "Projection centre" }?.value
        }
        XCTAssertEqual(row(de), "(0,4215; 0,2163; 0,5323)")
        XCTAssertEqual(row(ExportSnapshot.labelLocale), "(0.4215, 0.2163, 0.5323)")
    }
}
