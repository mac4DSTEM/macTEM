//
//  ResultsFormat.swift
//  Role: every sentence and number the Results room shows (V1-10 slice 3, archive: results-room-design-2026-10-15.md): the
//        group names, a row's Value, Source, Record and badge, the header count, the Info fields, the spoken row, the
//        line ⌘C copies, and the export's name and words. Pure, `nonisolated`, so a test pins each as `MarkFormat` does.
//
//        THE ROOM AUTHORS NO CLAIM OF TRUST: a badge is `ResultRow.Product.badge` (the producer's own label) and its tooltip is
//        `ResultRow.Product.validation` (the producer's constant); the only words added here are "Unvalidated · <the file's own
//        note>" when the reader's notes say the file is unvalidated, as `ProfileCSV` does. Values are the owners' Doubles brought
//        to the same text the owner's room shows (a mark as `MarkFormat`, a spot as `FFTRoomFormat`); the file's Doubles are in
//        the CSV.
//

import ImagoCore
import Foundation
import TEMCore

nonisolated enum ResultsFormat {

    // MARK: Groups

    static func title(_ group: ResultRow.Group) -> String {
        switch group {
        case .marks: "Marks"
        case .spots: "FFT Spots"
        case .calibration: "Calibration"
        case .rings: "Rings and spots"
        case .eds: "EDS composition"
        case .eelsThickness: "EELS thickness"
        case .eelsEdges: "EELS edges"
        }
    }

    /// Where a group's rows are made and removed: the row says so, as there is no ⌫ here.
    static func owner(_ group: ResultRow.Group) -> String {
        switch group {
        case .marks: "the Image room"
        case .spots: "the FFT room"
        case .calibration, .rings: "the Diffraction room"
        case .eds: "the EDS room"
        case .eelsThickness, .eelsEdges: "the EELS room"
        }
    }

    // MARK: A row

    private static func number(_ value: Double, _ digits: Int, _ locale: Locale) -> String {
        UnitDisplay.number(value, digits: digits, locale: locale)
    }

    /// The Value column: a mark as the Image room's row reads (`MarkFormat.value`), a spot as the FFT room's (`FFTRoomFormat`),
    /// a refusal its words. `x`, `y`: the FILE's axes, which decide the unit a metre length is shown in.
    static func value(_ row: ResultRow, x: AxisCalibration?, y: AxisCalibration?, locale: Locale = .autoupdatingCurrent) -> String {
        if let refusal = row.refusal { return refusal.prefix(1).uppercased() + refusal.dropFirst() }
        switch row.product {
        case .distance:
            guard let pixels = row.entry("length_px")?.value else { return "—" }
            let px = "\(number(pixels, 4, locale)) px"
            guard let length = row.entry("length"), let physical = length.value else { return px }
            let shown = lengthShown(physical, unit: length.unit, x: x, y: y)
            return "\(number(shown.value, 4, locale)) \(shown.unit) · \(px)"
        case .angle:
            guard let angle = row.entry("angle"), let degrees = angle.value else { return "—" }
            let text = degrees.formatted(.number.locale(locale).grouping(.never).precision(.fractionLength(1)))
            return angle.text.hasSuffix("pixel grid") ? "\(text)° (pixel grid)" : "\(text)°"
        case .profile:
            guard let pixels = row.entry("length_px")?.value else { return "—" }
            guard let length = row.entry("length"), let physical = length.value else {
                return "Profile · \(number(pixels, 3, locale)) px"
            }
            let shown = lengthShown(physical, unit: length.unit, x: x, y: y)
            return "Profile · \(number(shown.value, 3, locale)) \(shown.unit)"
        case .spot:
            guard let d = row.entry("d"), let dv = d.value, let q = row.entry("q")?.value else { return "—" }
            return FFTRoomFormat.spotValue(d: dv, q: q, unit: d.unit, locale: locale)
        case .calibration:
            guard let dq = row.entry("delta_q")?.value else { return "—" }
            return "Δq \(number(dq, 5, locale)) 1/Å per px"
        case .ring:
            guard let d = row.entry("d")?.value else { return "—" }
            let family = row.entry("family")?.text ?? ""
            return "d \(number(d, 5, locale)) Å\(family.isEmpty ? "" : " · \(family)")"
        case .edsComposition:
            return edsValue(row, locale: locale)
        case .eelsThickness:
            return eelsThicknessValue(row, locale: locale)
        case .eelsEdge:
            return eelsEdgeValue(row, locale: locale)
        }
    }

    /// An EELS thickness row as the EELS room's thickness line reads it (`EELSRoomFormat.thicknessLine`): "t/λ 0.523 (IQR 0.481–0.571) · t 62.8 nm"
    /// over the whole map, "t/λ 0.512" for a drawn region's summed spectrum; a t the room cannot give says it needs λ, never a number.
    static func eelsThicknessValue(_ row: ResultRow, locale: Locale = .autoupdatingCurrent) -> String {
        guard let t = row.entry("t_over_lambda")?.value else { return "—" }
        var text = "t/λ \(EELSRoomFormat.fixed(t, 3, locale: locale))"
        if let q1 = row.entry("t_over_lambda_q1")?.value, let q3 = row.entry("t_over_lambda_q3")?.value {
            text += " (IQR \(EELSRoomFormat.fixed(q1, 3, locale: locale))–\(EELSRoomFormat.fixed(q3, 3, locale: locale)))"
        }
        if let thickness = row.entry("thickness") {
            text += " · " + (thickness.value.map { "t \(EELSRoomFormat.sig($0, 3, locale: locale)) nm" } ?? thickness.text)
        }
        return text
    }

    /// An EELS edge row: "34.5 at% · 30.1 wt% · I 4.318e7 ± 2.1e5" when the fit gave a composition (the room's at% and I cells), else I and why
    /// there is no at%; an edge at or under 3σ reads "below detection" in place of its at%, never a bare number.
    static func eelsEdgeValue(_ row: ResultRow, locale: Locale = .autoupdatingCurrent) -> String {
        var intensity: String?
        if let i = row.entry("intensity")?.value {
            intensity = "I " + EELSRoomFormat.scientific(i, 4, locale: locale)
                + (row.entry("intensity_sigma")?.value.map { " ± " + EELSRoomFormat.scientific($0, 2, locale: locale) } ?? "")
        }
        if row.entry("below_detection") != nil { return ([intensity].compactMap { $0 } + ["below detection"]).joined(separator: " · ") }
        var parts: [String] = []
        if let at = row.entry("at")?.value { parts.append("\(EELSRoomFormat.fixed(at, 1, locale: locale)) at%") }
        if let wt = row.entry("wt")?.value { parts.append("\(EELSRoomFormat.fixed(wt, 1, locale: locale)) wt%") }
        if let intensity { parts.append(intensity) }
        if row.entry("at")?.value == nil, let why = row.entry("at")?.text, !why.isEmpty { parts.append("at%: \(why)") }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }

    /// An EDS row: "12.3 ± 0.4 at% · 10.1 ± 0.3 wt%" when the fit gave a composition, else its net counts and why there is no at%,
    /// "net 7242 ± 122 counts · at%: <the fit's reason>"; a row held at the fit's bound says so in the kit's words, never as a number.
    static func edsValue(_ row: ResultRow, locale: Locale = .autoupdatingCurrent) -> String {
        if let net = row.entry("net"), net.text == ResultRow.edsAtBound { return "Not detected: " + net.text }
        func percent(_ name: String) -> String? {
            guard let value = row.entry(name)?.value else { return nil }
            let sigma = row.entry(name + "_sigma")?.value.map { " ± \(number($0, 2, locale))" } ?? ""
            return "\(number(value, 3, locale))\(sigma) \(name)%"
        }
        let parts = [percent("at"), percent("wt")].compactMap { $0 }
        if !parts.isEmpty { return parts.joined(separator: " · ") }
        guard let net = row.entry("net")?.value else { return "—" }
        let sigma = row.entry("net_sigma")?.value.map { " ± \(number($0, 3, locale))" } ?? ""
        let why = row.entry("at")?.text ?? ""
        return "net \(number(net, 4, locale))\(sigma) counts" + (why.isEmpty ? "" : " · at%: \(why)")
    }

    /// A length in the file's unit as the Image room shows it: a metre axis in nm, µm or mm (`MarkFormat.shown`), any other unit
    /// as `UnitDisplay.label` spells it.
    static func lengthShown(_ value: Double, unit: String, x: AxisCalibration?, y: AxisCalibration?) -> (value: Double, unit: String) {
        let axes = MarkFormat.shown(x: x, y: y)
        if let shownUnit = axes.unit { return (value * axes.factor, shownUnit) }
        return (value, UnitDisplay.label(unit))
    }

    /// The Source column: where the measurement was made.
    static func source(_ row: ResultRow, imageWidth: Int, imageHeight: Int) -> String {
        switch row.group {
        case .marks:
            return "Image · mark"
        case .spots:
            guard let width = row.entry("region_width")?.value, let height = row.entry("region_height")?.value,
                  let col = row.entry("region_col")?.value, let top = row.entry("region_row")?.value else { return "FFT" }
            if Int(width) == imageWidth, Int(height) == imageHeight, col == 0, top == 0 { return "FFT · the whole image" }
            return "FFT · region \(Int(width)) × \(Int(height)) px at (\(Int(col)), \(Int(top)))"
        case .calibration, .rings:
            return "Diffraction"
        case .eds:
            return "EDS · \(row.entry("region")?.text ?? "")"
        case .eelsThickness, .eelsEdges:
            return "EELS · \(row.entry("region")?.text ?? "")"
        }
    }

    /// The Record column: the mark's node in the session record, else "not recorded" (spots are not recorded until the
    /// Diffraction design's nodes exist; the room never implies they were saved).
    static func record(_ row: ResultRow) -> String { row.lineage ?? "not recorded" }

    /// The badge: the producer's label; a file whose reader notes say "unvalidated" turns it to "Unvalidated · <that note>".
    static func badge(_ row: ResultRow, notes: [String]) -> String {
        if let note = notes.first(where: { $0.lowercased().contains("unvalidated") }) {
            return "Unvalidated · \(CSVText.headerValue(note))"
        }
        return row.product.badge
    }

    /// The badge's tooltip and the Info field: the producer's own sentence.
    static func validation(_ row: ResultRow) -> String { row.product.validation }

    /// One sentence for VoiceOver: "Distance 1, 12.43 nm, 50.02 pixels, <badge>, recorded as s7".
    static func spoken(_ row: ResultRow, value: String, badge: String) -> String {
        let words = value.replacing(" · ", with: ", ").replacing(" px", with: " pixels")
        return "\(row.label), \(FFTRoomFormat.spoken(words)), \(badge.replacing(" · ", with: " ")), \(row.lineage.map { "recorded as \($0)" } ?? "not recorded")"
    }

    /// What ⌘C copies for a selected row: its five columns, tab-separated, one line.
    static func copyLine(label: String, value: String, source: String, record: String, badge: String) -> String {
        [label, value, source, record, badge].joined(separator: "\t")
    }

    /// What ⌘C copies for the selected rows: one `copyLine` each, in the order given, joined by newlines.
    static func copyText(_ rows: [ResultRow], image: CalibratedImage, locale: Locale = .autoupdatingCurrent) -> String {
        rows.map { row in
            copyLine(label: row.label, value: value(row, x: image.x, y: image.y, locale: locale),
                     source: source(row, imageWidth: image.width, imageHeight: image.height), record: record(row),
                     badge: badge(row, notes: image.notes))
        }.joined(separator: "\n")
    }

    // MARK: Info

    /// One entry of a row as a field: its name as the CSV has it and "value unit", up to 6 significant digits.
    static func field(_ entry: ResultRow.Entry, locale: Locale = .autoupdatingCurrent) -> (name: String, text: String) {
        var text = entry.value.map { number($0, 6, locale) } ?? ""
        if let value = entry.value, value.isFinite, !entry.unit.isEmpty {
            text += entry.unit == "deg" ? "°" : " \(UnitDisplay.label(entry.unit))"
        }
        if !entry.text.isEmpty { text += text.isEmpty ? entry.text : " · \(entry.text)" }
        return (entry.name, text.isEmpty ? "—" : text)
    }

    // MARK: The header and the states

    static func count(_ n: Int) -> String { n == 1 ? "1 result" : "\(n) results" }

    /// "scan.dm4 · 12 results, 3 hidden"; the session sentence follows it in its own run.
    static func summary(fileName: String, shown: Int, hidden: Int) -> String {
        "\(fileName) · \(count(shown))" + (hidden > 0 ? ", \(hidden) hidden" : "")
    }

    /// The Session sentence: the Image room's state line (what is saved), or this when there is no mark to save.
    static func session(firstLine: String?) -> String { firstLine ?? "No marks in this file's session record." }

    static let emptyTitle = "No results yet"
    static let emptyDetail = "Measure in the Image or FFT room; the numbers appear here."
    static let allHiddenTitle = "All results are hidden"
    static let allHiddenDetail = "Switch a group on in the inspector's Show section."
    static let noSelection = "Select a result to see its numbers and how far it is trusted."
    static let severalSelected = "Several results are selected."

    // MARK: Export

    /// The name the save panel starts as: "scan.results" (the panel's content type adds ".csv"). Never an extension.
    static func exportName(fileName: String) -> String { "\(ExportSnapshot.stem(of: fileName)).results" }

    static func exportMessage(rows: Int, groups: [ResultRow.Group]) -> String {
        "\(count(rows)) · \(groups.map(title).joined(separator: " and ")) · numbers exact, one line per quantity"
    }

    static func exportingDoneLine(name: String, rows: Int) -> String { "Exported \(name) — \(count(rows))" }
}
