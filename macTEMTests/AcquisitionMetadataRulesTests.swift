//
//  AcquisitionMetadataRulesTests.swift
//  The rule helpers every metadata reader shares (`AcquisitionMetadata.swift`): rule (a) text and numbers — absent,
//  blank and unparseable are nil, and only decimal text is a number (Swift's `Double(String)` alone reads "0x10" as
//  16, the integration's probe of 2026-10-12); rule (b) a strictly positive quantity; rule (f) a second stored copy
//  kept only when it differs by more than 1e-6 relative. Mutations each test must go red under: the decimal filter
//  dropped; `positive` accepting zero; the rule-(f) band as an absolute 1e-6 or as `!=`.
//

import XCTest
import FormatoCore
import TEMCore
@testable import macTEM

nonisolated final class AcquisitionMetadataRulesTests: XCTestCase {

    func testOnlyDecimalTextIsANumber() {
        XCTAssertEqual(AcquisitionMetadata.number("5000"), 5000)
        XCTAssertEqual(AcquisitionMetadata.number(" 1e-005 "), 1e-5)
        XCTAssertEqual(AcquisitionMetadata.number("-2.5E3"), -2500)
        XCTAssertEqual(AcquisitionMetadata.number("+0.844"), 0.844)
        for junk in [nil, "", "   ", "notafloat", "0x10", "0x1p3", "nan", "inf", "5,000", "1,5", "12 kV"] {
            XCTAssertNil(AcquisitionMetadata.number(junk), String(describing: junk))
        }
    }

    func testTextIsTrimmedAndBlankIsNotRecorded() {
        XCTAssertEqual(AcquisitionMetadata.text("  BM-Ceta \n"), "BM-Ceta")
        XCTAssertNil(AcquisitionMetadata.text(" \t\n"))
        XCTAssertNil(AcquisitionMetadata.text(nil))
    }

    func testAStrictlyPositiveQuantityOrNothing() {
        XCTAssertEqual(AcquisitionMetadata.positive(300_000), 300_000)
        XCTAssertEqual(AcquisitionMetadata.positive(1e-12), 1e-12)
        for bad in [0.0, -0.0, -1, .nan, .infinity, -.infinity] {
            XCTAssertNil(AcquisitionMetadata.positive(bad), "\(bad)")
        }
        XCTAssertNil(AcquisitionMetadata.positive(nil))
    }

    func testASecondCopyIsKeptOnlyBeyondOnePartPerMillion() {
        XCTAssertNil(AcquisitionMetadata.differingCopy(0.2, 0.2))
        XCTAssertNil(AcquisitionMetadata.differingCopy(0.2, 0.2 * (1 + 5e-7)), "inside 1e-6 relative")
        XCTAssertEqual(AcquisitionMetadata.differingCopy(0.2, 0.2 * (1 + 2e-6)), 0.2 * (1 + 2e-6))
        XCTAssertEqual(AcquisitionMetadata.differingCopy(0.5, 0.25), 0.25)
        XCTAssertNil(AcquisitionMetadata.differingCopy(2e6, 2e6 + 1), "relative, not absolute: 5e-7")
        XCTAssertNil(AcquisitionMetadata.differingCopy(0.5, nil))
        XCTAssertNil(AcquisitionMetadata.differingCopy(0.5, .nan))
    }
}
