//
//  UnitDisplay.swift
//  Role: how a stored unit, a number and a count are SHOWN. The conversions (Å, nm, pm per pixel, the canonical spellings) are
//        ImagoKit's `LengthUnit` (ImagoCore 0.5.0); the kit formats nothing for display, so the display rules live here.
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

    /// A number as the reader's locale writes it, at most `digits` significant digits, no grouping ("0,25" in de_DE, where
    /// `%g` always printed "0.25"). DISPLAY ONLY: provenance, sidecar and export strings keep their own locale-free spelling.
    package static func number(_ value: Double, digits: Int = 6, locale: Locale = .autoupdatingCurrent) -> String {
        guard value.isFinite else { return "—" }
        return value.formatted(.number.locale(locale).grouping(.never).precision(.significantDigits(1...digits)))
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
