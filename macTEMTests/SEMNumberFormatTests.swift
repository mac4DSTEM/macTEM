//
//  SEMNumberFormatTests.swift
//  The SEM rooms' number words go through `UnitDisplay`, as every other room's: the Maps room's angles, numbers and fractions and the
//  Indexing table's cells take printf's digits in the reader's decimal mark, never a negative zero, and one dash where there is no
//  value. The EDS room's SEM rows follow with that room's rework.
//

import XCTest
import TEMCore
@testable import macTEM

nonisolated final class SEMNumberFormatTests: XCTestCase {
    private let en = Locale(identifier: "en_US")
    private let de = Locale(identifier: "de_DE")

    /// A value that is not there reads as UnitDisplay's one dash in the Maps and Indexing tables and lines. Red before: both wrote an
    /// en dash ("–").
    func testNoValueIsUnitDisplaysDash() {
        XCTAssertEqual(UnitDisplay.noValue, "\u{2014}")
        for v in [Double.nan, Double.infinity, -Double.infinity] {
            XCTAssertEqual(MapsRoomFormat.number(v), UnitDisplay.number(v), "\(v)")
            XCTAssertEqual(MapsRoomFormat.angle(v), UnitDisplay.noValue, "\(v)")
            XCTAssertEqual(MapsRoomFormat.fraction(v), UnitDisplay.noValue, "\(v)")
            XCTAssertEqual(IndexingTableFormat.number(v), UnitDisplay.number(v), "\(v)")
            XCTAssertEqual(IndexingTableFormat.angle(v), UnitDisplay.noValue, "\(v)")
        }
    }

    /// The routed formatters keep their digits and the reader's mark, and a value that rounds to zero has no sign. Red before: the Maps
    /// angle of -0.04° read "-0.0".
    func testTheRoutedFormattersKeepTheirDigits() {
        XCTAssertEqual(MapsRoomFormat.angle(12.34, locale: de), "12,3")
        XCTAssertEqual(MapsRoomFormat.angle(132.4, digits: 0, locale: en), "132")
        XCTAssertEqual(MapsRoomFormat.angle(-0.04, locale: en), "0.0")
        XCTAssertEqual(MapsRoomFormat.number(0.0123456, locale: de), "0,01235")
        XCTAssertEqual(MapsRoomFormat.number(12_345.6, locale: en), "12350", "four significant digits, never grouped")
        XCTAssertEqual(MapsRoomFormat.fraction(0.4712, locale: de), "0,471")
        XCTAssertEqual(IndexingTableFormat.fraction(0.8234, locale: de), "0,823")
    }
}
