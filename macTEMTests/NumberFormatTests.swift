//
//  NumberFormatTests.swift
//  The one number format (`Num`): a value that rounds to zero is written as zero, with no sign, whatever the sign of what was rounded.
//

import XCTest
@testable import macTEM

nonisolated final class NumberFormatTests: XCTestCase {
    private let en = Locale(identifier: "en_US")
    private let de = Locale(identifier: "de_DE")

    /// Red before: "-0.00" for a deviation of exactly zero from the kit (negative zero) and for -0.001 at two places.
    func testNoNegativeZero() {
        XCTAssertEqual(Num.signed(-0.0, 2, locale: en), "0.00")
        XCTAssertEqual(Num.signed(-0.001, 2, locale: en), "0.00")
        XCTAssertEqual(Num.fixed(-0.0, 2, locale: en), "0.00")
        XCTAssertEqual(Num.fixed(-0.004, 2, locale: en), "0.00")
        XCTAssertEqual(Num.signed(-0.0, 2, locale: de), "0,00")
    }

    func testSignsAndDecimalsOtherwiseAreUnchanged() {
        XCTAssertEqual(Num.signed(0.5, 1, locale: en), "+0.5")
        XCTAssertEqual(Num.signed(-0.06, 2, locale: en), "-0.06")
        XCTAssertEqual(Num.fixed(2.0366, 3, locale: de), "2,037")
        XCTAssertEqual(Num.fixed(-0.006, 2, locale: en), "-0.01")
        XCTAssertEqual(Num.sig(0.012625, 6, locale: de), "0,012625")
    }
}
