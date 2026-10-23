//
//  NumberFormat.swift
//  Role: the one way macTEM writes a number a person reads: locale-aware (the user's decimal separator, never a grouping separator), by
//        decimals or by significant digits. A screen that mixed "0,12625" and "0.01250" came from `String(format:)` (always a point)
//        beside the locale-aware readers; every displayed number goes through here or through `UnitDisplay.number` (which does the
//        same). Strings a test or a script reads (accessibility values) and CSV keep their fixed point: they are not for reading.
//

import Foundation

nonisolated enum Num {
    /// `value` with exactly `places` decimals ("0,01250" in a comma locale).
    static func fixed(_ value: Double, _ places: Int, locale: Locale = .autoupdatingCurrent) -> String {
        zeroed(value, places).formatted(.number.locale(locale).grouping(.never).precision(.fractionLength(places)))
    }

    /// A value that rounds to zero at `places` decimals is zero: never "-0,00" for a tiny negative (or a negative zero).
    private static func zeroed(_ value: Double, _ places: Int) -> Double {
        let scale = pow(10, Double(max(places, 0)))
        return (value * scale).rounded() == 0 ? 0 : value
    }

    /// `value` with up to `digits` significant digits and no trailing zeros ("%g" in the user's locale).
    static func sig(_ value: Double, _ digits: Int, locale: Locale = .autoupdatingCurrent) -> String {
        value.formatted(.number.locale(locale).grouping(.never).precision(.significantDigits(1...max(digits, 1))))
    }

    /// `fixed` with an explicit sign ("+0,05", "−1,00"); a zero has none.
    static func signed(_ value: Double, _ places: Int, locale: Locale = .autoupdatingCurrent) -> String {
        zeroed(value, places).formatted(.number.locale(locale).grouping(.never).precision(.fractionLength(places)).sign(strategy: .always(includingZero: false)))
    }
}
