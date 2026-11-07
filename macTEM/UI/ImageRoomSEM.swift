//
//  ImageRoomSEM.swift
//  Role: the Image room's SEM rows (design: docs/sem/design/sem-image-room.md §4 to §6): the rows an SEM TIFF adds to the Info tab's
//        Acquisition section beneath the nine TEM rows, in the design's order (Instrument, Detector, HV, Beam current or Spot,
//        Working distance, Magnification, Dwell, Pixel size, Scan size, Stage tilt, Stage rotation, Vacuum, Date, Databar), the
//        "Vendor fields" disclosure with every raw key, and the Display section's `Databar · Hide · Show` control. `SEMRows` is the
//        wording, pure, so a test pins it (`SEMRowsTests`); the views draw it with the inspector's row kit.
//
//  The wording moves no number: a value prints in the reader's locale at 7 significant digits (the Acquisition section's rule).
//  A field the file does not record is left out, not shown as "Not recorded" (the design: the nine TEM rows above already say
//  what a reading lacks). Units: the pixel size and the scan size in nm, µm or mm (`DisplaySampling`), kV, mm, µs, nA, Pa, degrees
//  as stored. A row RosettaSciIO does not map carries the core's note beneath it; a Tescan file carries the Tescan note once, on
//  its Instrument row. Each row is one accessibility element, "<label>, <value>, <note>", identified `image.sem.<id>`.
//

import ShellControls
import ShellInspector
import SwiftUI
import TEMCore
import TEMSession

/// The SEM rows, in the design's order, as text. Pure.
nonisolated enum SEMRows {
    nonisolated struct Row: Identifiable, Equatable, Sendable {
        let id: String
        let label: String
        let value: String
        let note: String?
    }

    static let significantDigits = 7

    static func rows(_ m: SEMImageMetadata, locale: Locale = .autoupdatingCurrent) -> [Row] {
        var rows: [Row] = []
        func n(_ x: Double) -> String { UnitDisplay.number(x, digits: significantDigits, locale: locale) }
        func add(_ id: String, _ label: String, _ value: String?, note: String? = nil) {
            guard let value else { return }
            rows.append(Row(id: id, label: label, value: value, note: note))
        }
        let unvalidated: String? = m.vendor == .tescan ? nil : SEMImageMetadata.unvalidatedNote
        add("instrument", "Instrument", m.instrument ?? m.vendor.rawValue, note: m.vendor == .tescan ? SEMImageMetadata.tescanNote : nil)
        add("detector", "Detector", m.detector, note: m.vendor == .thermo ? unvalidated : nil)
        add("hv", "HV", m.beamEnergyKV.map { "\(n($0)) kV" })
        if let current = m.beamCurrentNA {
            add("beamCurrent", "Beam current", "\(n(current)) nA")
        } else {
            add("spot", "Spot", m.spotSize.map { m.spotSizeUnit == "m" ? "\(n($0 * 1e9)) nm" : n($0) }, note: unvalidated)
        }
        add("workingDistance", "Working distance", m.workingDistanceMM.map { "\(n($0)) mm" })
        if let mag = m.magnification { add("magnification", "Magnification", "\(n(mag))\u{00D7}") }
        else { add("magnification", "Magnification", m.magnificationText) }
        add("dwell", "Dwell", m.dwellS.map { "\(n($0 * 1e6)) \u{00B5}s" })
        add("pixelSize", "Pixel size", pixelSize(m, locale: locale))
        add("scanSize", "Scan size", scanSize(m, locale: locale))
        add("stageTilt", "Stage tilt", m.stageTiltDeg.map { "\(n($0))°" })
        add("stageRotation", "Stage rotation", m.stageRotationDeg.map { "\(n($0))°" })
        add("vacuum", "Vacuum", m.chamberPressurePa.map { "\(n($0)) Pa" }, note: unvalidated)
        add("date", "Date", acquired(m))
        add("databar", "Databar", databar(m), note: m.vendor == .zeiss ? SEMImageMetadata.zeissDatabarNote : unvalidated)
        return rows
    }

    /// A metre length in the unit it reads in (nm, µm, mm): the number and the unit label.
    private static func length(_ metres: Double, locale: Locale) -> (number: String, unit: String) {
        let unit = DisplaySampling.unit(forMetres: metres)
        return (UnitDisplay.number(metres * unit.perMetre, digits: significantDigits, locale: locale), unit.label)
    }

    /// "2.614514 µm/px", or "25 × 30 nm/px" when the two differ.
    static func pixelSize(_ m: SEMImageMetadata, locale: Locale) -> String? {
        guard let x = m.pixelSizeX else { return nil }
        let ax = length(x, locale: locale)
        guard let y = m.pixelSizeY, y != x else { return "\(ax.number) \(ax.unit)/px" }
        let ay = length(y, locale: locale)
        return "\(ax.number) \u{00D7} \(ay.number) \(ay.unit)/px"
    }

    /// "2.677 × 1.8094 mm": the scan's width and height (the databar excluded) from the pixel size.
    static func scanSize(_ m: SEMImageMetadata, locale: Locale) -> String? {
        guard let x = m.pixelSizeX, let y = m.pixelSizeY ?? m.pixelSizeX, m.imageWidth > 0, m.scanRows > 0 else { return nil }
        let w = length(x * Double(m.imageWidth), locale: locale), h = length(y * Double(m.scanRows), locale: locale)
        return "\(w.number) \u{00D7} \(h.number) \(h.unit)"
    }

    /// "2015-12-23 09:40:32" (local time, zone not stored), either half alone when the other is missing.
    static func acquired(_ m: SEMImageMetadata) -> String? {
        let both = [m.date, m.time].compactMap { $0 }
        return both.isEmpty ? nil : both.joined(separator: " ")
    }

    /// "29 rows under a 442-row scan", or what the file says about having none.
    static func databar(_ m: SEMImageMetadata) -> String? {
        guard let rows = m.databarRows else { return m.vendor == .zeiss ? "Drawn into the scan" : nil }
        return "\(rows) rows under a \(m.scanRows)-row scan"
    }
}

/// The SEM rows of the Acquisition section and the "Vendor fields" disclosure, drawn beneath the nine TEM rows for an SEM file.
struct SEMAcquisitionRows: View {
    let sem: SEMImageMetadata
    @State private var vendorFieldsShown = false

    var body: some View {
        ForEach(SEMRows.rows(sem)) { row in
            VStack(alignment: .leading, spacing: 2) {
                InspectorValueRow(row.label, row.value)
                if let note = row.note { InspectorNote(note) }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(row.label)
            .accessibilityValue(row.note.map { "\(row.value), \($0)" } ?? row.value)
            .accessibilityIdentifier("image.sem.\(row.id)")
        }
        if !sem.rawFields.isEmpty {
            DisclosureGroup("Vendor fields (\(sem.rawFields.count))", isExpanded: $vendorFieldsShown) {
                ForEach(Array(sem.rawFields.enumerated()), id: \.offset) { _, field in
                    InspectorValueRow(field.key, field.value, mono: true)
                }
            }
            .accessibilityIdentifier("image.sem.vendorFields")
        }
    }
}

/// The Display section's `Databar · Hide · Show` for a file with a databar: Hide (the default) shows the scan alone, Show the whole
/// frame, bar included (for an export with the bar). Full width, no leading label (control placement standard).
struct SEMDatabarPicker: View {
    let sem: SEMImageMetadata
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var appState = appState
        SegmentedPicker(label: "Databar", items: [(true, .title("Hide")), (false, .title("Show"))], selection: $appState.cropsDatabar)
            .accessibilityIdentifier("image.sem.databar")
            .help("Hide the \(sem.databarRows ?? 0)-row databar the microscope drew under the scan, or show it as a strip under the picture")
        InspectorNote(appState.cropsDatabar
                      ? "Databar hidden: the \(sem.databarRows ?? 0) rows under the scan are cut; lengths and exports are of the scan."
                      : "Databar shown under the picture: its \(sem.databarRows ?? 0) rows are not part of the image; lengths and exports are of the scan.")
    }
}
