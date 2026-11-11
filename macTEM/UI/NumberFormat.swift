//
//  NumberFormat.swift
//  Role: the one way macTEM writes a number a person reads: locale-aware (the user's decimal separator, never a grouping separator), by
//        decimals or by significant digits. A screen that mixed "0,12625" and "0.01250" came from `String(format:)` (always a point)
//        beside the locale-aware readers; every displayed number goes through here or through `UnitDisplay.number` (which does the
//        same). The digits are printf's with the locale's mark (`UnitDisplay`), as mac4DSTEM writes them: FormatStyle rounded the
//        shortest decimal spelling, so a tie read one digit off the CSV beside it (0.35 read "0.4" on screen, "0.3" in `%.1f`).
//        A file the app writes keeps its decimal point (`en_US_POSIX`, docs/architecture.md). An accessibility value is read aloud, so it
//        takes the reader's mark like the text beside it, and a UI journey parses it with `Journey.number`.
//

import Foundation
import TEMCore

nonisolated enum Num {
    /// `value` with exactly `places` decimals ("0,01250" in a comma locale), as `%.<places>f` rounds it; a value that rounds to zero
    /// is zero, never "-0,00" for a tiny negative (or a negative zero).
    static func fixed(_ value: Double, _ places: Int, locale: Locale = .autoupdatingCurrent) -> String {
        guard value.isFinite else { return value.formatted(.number.locale(locale).grouping(.never).precision(.fractionLength(places))) }
        return UnitDisplay.fixed(value, places: places, locale: locale)
    }

    /// `value` with up to `digits` significant digits and no trailing zeros, as `%.<digits>g` rounds it, never with an exponent.
    static func sig(_ value: Double, _ digits: Int, locale: Locale = .autoupdatingCurrent) -> String {
        guard value.isFinite else { return value.formatted(.number.locale(locale).grouping(.never).precision(.significantDigits(1...max(digits, 1)))) }
        return UnitDisplay.number(value, digits: max(digits, 1), locale: locale)
    }

    /// `fixed` with an explicit sign ("+0,05", "−1,00"); a zero has none.
    static func signed(_ value: Double, _ places: Int, locale: Locale = .autoupdatingCurrent) -> String {
        guard value.isFinite else {
            return value.formatted(.number.locale(locale).grouping(.never).precision(.fractionLength(places)).sign(strategy: .always(includingZero: false)))
        }
        let text = fixed(value, places, locale: locale)
        return value > 0 && text.contains(where: { $0 >= "1" && $0 <= "9" }) ? "+" + text : text
    }

    /// The typed fields' styles the rooms share, never grouped (a "1.000" in a comma locale reads as one): a whole number (a size in
    /// points or pixels, a radius), a decimal of up to four significant digits (an angle, a threshold), and `significantField` for a
    /// field that keeps more (the Patterns room's filter widths, six).
    static let wholeField = FloatingPointFormatStyle<Double>.number.grouping(.never).precision(.fractionLength(0))
    static let decimalField = significantField(4)

    /// A typed field's style of up to `digits` significant digits, never grouped.
    static func significantField(_ digits: Int) -> FloatingPointFormatStyle<Double> {
        FloatingPointFormatStyle<Double>.number.grouping(.never).precision(.significantDigits(1...max(digits, 1)))
    }
}
