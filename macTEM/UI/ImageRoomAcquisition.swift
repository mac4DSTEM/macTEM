//
//  ImageRoomAcquisition.swift
//  Role: the Image room's Info tab, "Acquisition" section (the panel): how the open image was
//        acquired — high tension, magnification, camera length, detector, dwell, exposure, date, instrument, mode —
//        each as the core's `AcquisitionMetadata` holds it. `AcquisitionRows` is the wording, pure, so a test pins
//        it (`AcquisitionRowsTests`); `AcquisitionSection` draws it with the inspector's row kit and nothing else.
//
//  The wording moves no number (P1): a value prints in the reader's locale at 7 significant digits, which reads
//  back within 5e-7 relative of the core's value in the core's unit (half a unit in the 7th digit, a leading digit of
//  at least 1; 6 digits would allow 5e-6: 1.23456789e5 would read 123457). A field the file does not record reads
//  "Not recorded", never 0 (P2); a field this format's reader cannot read yet reads "Not read from .emd files yet",
//  never "Not recorded" (`AcquisitionMetadata.unread`: the file may well record it). A note the core gives
//  ("mm (assumed)", "local time, zone not stored") shows beneath its row, and a second stored copy that differs
//  shows as its own row, "<label> (second copy)", with the same note. Units: kV, × after the number with no space
//  ("28500×", as the upsampling stepper writes "16×"), mm, µs (U+00B5), s.
//
//  The view takes the values (`metadata`, the file's extension) and reads no observable state: its parent reads
//  `AppState` and passes them, as `ImageInfoSection` takes `image`. Each row and its note are ONE accessibility
//  element read "<label>, <value in words>, <note>" — units spelled out, since "kV", "mm" and "µs" are read letter
//  by letter. Nothing here sets a width, so no value or note can move the inspector's minimum (InspectorRows.swift,
//  the constraint-loop rule).
//

import ShellInspector
import SwiftUI
#if canImport(TEMCore)
import FormatoCore
import TEMCore
#endif

// MARK: The formatter

/// The Acquisition section's rows, in the panel's order, as text. Pure: the same metadata, extension and locale give
/// the same rows.
nonisolated enum AcquisitionRows {
    /// One row of the section.
    nonisolated struct Row: Identifiable, Equatable, Sendable {
        /// Stable for a field and its second copy: the field's name, then the same with ".second".
        let id: String
        let label: String
        /// What the row shows: the number with its unit, the file's own text, or a placeholder.
        let value: String
        /// What the file does not settle about the value; nil when nothing needs saying.
        let note: String?
        /// True when `value` says there is no reading ("Not recorded", "Not read from .emd files yet").
        let isPlaceholder: Bool
        /// What VoiceOver says after the label: the value with its unit in words, then the note.
        let spokenValue: String
    }

    /// Significant digits of a number: 7 keeps every printed number within 5e-7 relative of the core's.
    static let significantDigits = 7

    static let notRecorded = "Not recorded"

    /// The placeholder of a field this format's reader cannot read yet ("emd", ".EMD" → "Not read from .emd files
    /// yet"; no extension → "Not read from this format yet").
    static func notRead(formatExtension: String) -> String {
        let ext = formatExtension.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let name = ext.hasPrefix(".") ? String(ext.dropFirst()) : ext
        return name.isEmpty ? "Not read from this format yet" : "Not read from .\(name) files yet"
    }

    /// The rows for `metadata`, one per field (nine), a differing second copy right after its field.
    static func rows(_ metadata: AcquisitionMetadata, formatExtension: String,
                     locale: Locale = .autoupdatingCurrent) -> [Row] {
        var rows: [Row] = []
        for field in AcquisitionMetadata.Field.allCases {
            let label = label(of: field)
            // A reading the core holds is shown even if the field is also listed unread: the list says what the
            // reader cannot read, and a value that came through is the file's.
            guard let shown = shown(field, in: metadata, locale: locale) else {
                let placeholder = metadata.unread.contains(field) ? notRead(formatExtension: formatExtension) : notRecorded
                rows.append(Row(id: field.rawValue, label: label, value: placeholder, note: nil,
                                isPlaceholder: true, spokenValue: placeholder))
                continue
            }
            rows.append(Row(id: field.rawValue, label: label, value: shown.value, note: shown.note,
                            isPlaceholder: false, spokenValue: spoken(shown.spoken, note: shown.note)))
            if let second = shown.second {
                rows.append(Row(id: field.rawValue + ".second", label: label + " (second copy)", value: second.value,
                                note: shown.note, isPlaceholder: false, spokenValue: spoken(second.spoken, note: shown.note)))
            }
        }
        return rows
    }

    // MARK: Fields

    static func label(of field: AcquisitionMetadata.Field) -> String {
        switch field {
        case .highTension: "High tension"
        case .magnification: "Magnification"
        case .cameraLength: "Camera length"
        case .detector: "Detector"
        case .dwell: "Dwell"
        case .exposure: "Exposure"
        case .acquired: "Acquired"
        case .instrument: "Instrument"
        case .mode: "Mode"
        }
    }

    /// A unit as written after a number and as spoken. The magnification's × follows the number directly.
    private nonisolated struct Unit: Sendable {
        let symbol: String
        let spacedFromNumber: Bool
        let singular: String
        let plural: String
    }

    private static let kilovolts = Unit(symbol: "kV", spacedFromNumber: true, singular: "kilovolt", plural: "kilovolts")
    private static let times = Unit(symbol: "\u{00D7}", spacedFromNumber: false, singular: "times", plural: "times")
    private static let millimetres = Unit(symbol: "mm", spacedFromNumber: true, singular: "millimeter", plural: "millimeters")
    private static let microseconds = Unit(symbol: "\u{00B5}s", spacedFromNumber: true, singular: "microsecond", plural: "microseconds")
    private static let seconds = Unit(symbol: "s", spacedFromNumber: true, singular: "second", plural: "seconds")

    /// A value as shown and as spoken, the reading's note, and its differing second copy.
    private nonisolated struct Shown {
        var value: String
        var spoken: String
        var note: String?
        var second: (value: String, spoken: String)?
    }

    private static func shown(_ field: AcquisitionMetadata.Field, in m: AcquisitionMetadata, locale: Locale) -> Shown? {
        switch field {
        case .highTension: number(m.highTensionKV, kilovolts, locale)
        case .magnification: number(m.magnification, times, locale)
        case .cameraLength: number(m.cameraLengthMM, millimetres, locale)
        case .detector: text(m.detector)
        case .dwell: number(m.dwellUS, microseconds, locale)
        case .exposure: number(m.exposureS, seconds, locale)
        case .acquired: text(m.acquired)
        case .instrument: text(m.instrument)
        case .mode: text(m.mode)
        }
    }

    /// A number in `unit`. A value that is not finite is not shown ("—" would be printed for it): the core's rule (b)
    /// already makes it nil, and this keeps the panel from showing a number nobody read.
    private static func number(_ reading: MetadataReading<Double>?, _ unit: Unit, _ locale: Locale) -> Shown? {
        guard let reading, reading.value.isFinite else { return nil }
        func both(_ x: Double) -> (value: String, spoken: String) {
            let n = UnitDisplay.number(x, digits: significantDigits, locale: locale)
            return (unit.spacedFromNumber ? "\(n) \(unit.symbol)" : "\(n)\(unit.symbol)",
                    "\(n) \(n == "1" ? unit.singular : unit.plural)")
        }
        let first = both(reading.value)
        let second = reading.otherCopy.flatMap { $0.isFinite ? both($0) : nil }
        return Shown(value: first.value, spoken: first.spoken, note: reading.note, second: second)
    }

    /// The file's own text, as the core holds it.
    private static func text(_ reading: MetadataReading<String>?) -> Shown? {
        guard let reading else { return nil }
        return Shown(value: reading.value, spoken: reading.value, note: reading.note,
                     second: reading.otherCopy.map { ($0, $0) })
    }

    private static func spoken(_ value: String, note: String?) -> String {
        note.map { "\(value), \($0)" } ?? value
    }
}

// MARK: The section

/// The Info tab's Acquisition section: nine rows (a second copy adds one), a note beneath its row.
struct AcquisitionSection: View {
    let metadata: AcquisitionMetadata
    /// The open file's extension ("emd"), for the placeholder of a field its format's reader cannot read yet.
    let formatExtension: String

    var body: some View {
        let rows = AcquisitionRows.rows(metadata, formatExtension: formatExtension)
        InspectorSection("Acquisition") {
            ForEach(rows) { row in
                AcquisitionRowView(row: row)
            }
        }
    }
}

/// One row with its note, one accessibility element: "<label>, <value in words>, <note>".
private struct AcquisitionRowView: View {
    let row: AcquisitionRows.Row

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            InspectorValueRow(row.label, row.value)
            if let note = row.note {
                InspectorNote(note)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.label)
        .accessibilityValue(row.spokenValue)
    }
}
