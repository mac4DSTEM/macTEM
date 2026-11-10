//
//  UnitDisplay.swift
//  Role: how a stored unit, a number and a count are SHOWN. The conversions (Å, nm, pm per pixel, the canonical spellings) are
//        ImagoKit's `LengthUnit` (ImagoCore 0.5.0); the kit formats nothing for display, so the display rules live here: the
//        unit's label, and a number in printf's digits with the reader's decimal mark (the app's `Num` writes through these).
//        Display boundary only: nothing stored changes.
//

import Foundation
import ImagoCore

package nonisolated enum UnitDisplay {
    /// The label a stored unit is SHOWN with. A file or a restored session keeps the spelling it was written with ("A^-1",
    /// "1/nm"); live calibration writes the canonical one ("Å⁻¹"), so the same scale read two ways on screen (drives 2A/2B,
    /// 2026-09-30). A spelling nobody recognises is shown as it is rather than guessed.
    package static func label(_ unit: String?) -> String {
        if ["px", "pix", "[pix]", "[px]", "pixel", "pixels"].contains(LengthUnit.normalized(unit)) { return "px" }
        return LengthUnit.canonicalReciprocalUnit(unit) ?? LengthUnit.canonicalRealUnit(unit) ?? unit ?? ""
    }

    /// A reciprocal-space sampling in the one unit the app shows for a pattern: Å⁻¹ per pixel (the Diffraction room's unit; a 1/nm axis is
    /// converted by ImagoKit's `LengthUnit`, 0.1 Å⁻¹ per nm⁻¹). nil for an axis that is not a reciprocal length (mrad included: it needs a wavelength).
    package static func reciprocalAngstromsPerPixel(_ axis: AxisCalibration?) -> Double? {
        guard let axis, let canonical = LengthUnit.canonicalReciprocalUnit(axis.unit), canonical != "mrad" else { return nil }
        return LengthUnit.reciprocalAngstromsPerPixel(scale: axis.scale, unit: axis.unit)
    }

    /// A number as the reader's locale writes it, at most `digits` significant digits, no grouping, no exponent ("0,25" in de_DE,
    /// where `%g` always printed "0.25"). The digits are printf's, so the screen shows the last digit the CSV writes: FormatStyle
    /// rounded the shortest decimal spelling instead of the binary value (2.675 read "2.68" there, "2.67" in `%.3g`). DISPLAY ONLY:
    /// provenance, sidecar and export strings keep their own locale-free spelling.
    package static func number(_ value: Double, digits: Int = 6, locale: Locale = .autoupdatingCurrent) -> String {
        guard value.isFinite else { return "—" }
        return marked(significant(value, digits: max(digits, 1)), locale: locale)
    }

    /// `value` with exactly `places` decimals as `%.<places>f` rounds it, in the reader's decimal mark, no grouping; a value that
    /// rounds to zero has no sign ("0,00", never "-0,00"). A value that is not finite is "—" (`Num.fixed` keeps its own words for it).
    package static func fixed(_ value: Double, places: Int, locale: Locale = .autoupdatingCurrent) -> String {
        guard value.isFinite else { return "—" }
        var text = String(format: "%.\(max(places, 0))f", value)
        if text.hasPrefix("-"), !text.contains(where: { $0 >= "1" && $0 <= "9" }) { text.removeFirst() }
        return marked(text, locale: locale)
    }

    /// `%.<digits − 1>e`'s digits (the binary value rounded, ties to even) written out in full, as FormatStyle spelled a number: no
    /// exponent, no trailing zeros, a point ("0.0000123", "1230000"). A finite `value` only.
    private static func significant(_ value: Double, digits: Int) -> String {
        let scientific = String(format: "%.\(digits - 1)e", value)
        guard let e = scientific.firstIndex(of: "e"), let exponent = Int(scientific[scientific.index(after: e)...]) else { return scientific }
        let figures: [Character] = scientific[..<e].filter { $0 >= "0" && $0 <= "9" }
        let point = exponent + 1   // the figures before the decimal point
        let whole: String
        var fraction: String
        if point <= 0 {
            whole = "0"
            fraction = String(repeating: "0", count: -point) + String(figures)
        } else if point >= figures.count {
            whole = String(figures) + String(repeating: "0", count: point - figures.count)
            fraction = ""
        } else {
            whole = String(figures[..<point])
            fraction = String(figures[point...])
        }
        while fraction.last == "0" { fraction.removeLast() }
        return (scientific.hasPrefix("-") ? "-" : "") + whole + (fraction.isEmpty ? "" : "." + fraction)
    }

    /// printf's text with `locale`'s decimal mark in place of its point.
    private static func marked(_ text: String, locale: Locale) -> String {
        guard let mark = locale.decimalSeparator, mark != "." else { return text }
        return text.replacingOccurrences(of: ".", with: mark)
    }

    /// Three numbers as one value, each as `number` writes it: "(0.4215, 0.2163, 0.5323)". Where the locale's decimal mark is a comma
    /// the three are parted by semicolons, "(0,4215; 0,2163; 0,5323)", so a decimal comma is never read as the list's.
    package static func triple(_ v: SIMD3<Double>, digits: Int = 6, locale: Locale = .autoupdatingCurrent) -> String {
        let separator = locale.decimalSeparator == "," ? "; " : ", "
        let parts: [String] = [v.x, v.y, v.z].map { number($0, digits: digits, locale: locale) }
        return "(" + parts.joined(separator: separator) + ")"
    }

    /// A count with its noun, the noun in the singular for one: "1 grain", "0 grains", "102 grains" (English, as the app is). The
    /// number as Swift writes an Int, no grouping; where the caller writes the number its own way ("3,812 points"), `noun` alone.
    package static func count(_ n: Int, _ singular: String, _ plural: String) -> String {
        "\(n) \(noun(n, singular, plural))"
    }

    /// The noun for `n` things: `singular` for one, `plural` for any other count.
    package static func noun(_ n: Int, _ singular: String, _ plural: String) -> String { n == 1 ? singular : plural }
}
