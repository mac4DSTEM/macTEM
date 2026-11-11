//
//  SEMColumnSpeech.swift
//  Role: the words VoiceOver says for a symbol the SEM rooms draw in a column header or a line of values (#320): "φ₁ °" was read sign
//        by sign, "ECD µm" and "GOS °" letter by letter. One table of symbols and one rule for the unit after them, as `EELSColumnSpeech`
//        is for the EELS room. The Maps room's Grains table and its orientation pane's Euler line say them, and so do the Indexing room's
//        Results and Bands tables' headers. What is drawn stays as it was. Pure, but for `header`, which makes the drawn header with its
//        words.
//

import SwiftUI

nonisolated enum SEMColumnSpeech {
    /// A symbol or an abbreviation drawn on screen, and its words.
    static let symbols: [String: String] = [
        "φ₁": "phi one", "Φ": "capital phi", "φ₂": "phi two", "ρ": "rho", "θ": "theta", "#": "number", "Col": "column",
        "CI": "confidence index", "PQ": "pattern quality", "OSM": "orientation similarity",
        "NCC": "normalised cross-correlation", "NDP": "normalised dot product",
        "ECD": "equivalent circle diameter", "GOS": "grain orientation spread",
    ]

    /// A unit drawn after a header's name, in words: degrees and pixels, a length as the open files' rows say it
    /// (`OpenItemRowFormat.spokenUnit`); a unit with no words is said as it is drawn.
    static func spokenUnit(_ unit: String) -> String {
        switch unit {
        case "°": "degrees"
        case "px": "pixels"
        default: OpenItemRowFormat.spokenUnit(unit)
        }
    }

    /// The words for a header drawn as `drawn`: a symbol alone ("CI": "confidence index"), or a name and the unit after its last space
    /// ("φ₁ °": "phi one, degrees", "ECD µm": "equivalent circle diameter, micrometres", "Fit °": "Fit, degrees"). A header that is a
    /// word already ("Grain", "Neighbours") is said as it is drawn.
    static func spoken(_ drawn: String) -> String {
        if let words = symbols[drawn] { return words }
        guard let space = drawn.lastIndex(of: " ") else { return drawn }
        let name = String(drawn[..<space]), unit = String(drawn[drawn.index(after: space)...])
        let unitWords = spokenUnit(unit)
        guard symbols[name] != nil || unitWords != unit else { return drawn }
        return "\(symbols[name] ?? name), \(unitWords)"
    }

    /// Bunge's three Euler angles, each value as the line draws it, in words: "phi one 203.3 degrees, capital phi 38.8 degrees, phi two
    /// 171.2 degrees" for "φ₁ 203.3°  Φ 38.8°  φ₂ 171.2°".
    static func spokenEuler(_ values: [String]) -> String {
        zip(["φ₁", "Φ", "φ₂"], values).map { "\(spoken($0)) \($1) \(spokenUnit("°"))" }.joined(separator: ", ")
    }

    /// The header as the table draws it, said in words.
    @MainActor static func header(_ drawn: String) -> Text { Text(drawn).accessibilityLabel(spoken(drawn)) }
}
