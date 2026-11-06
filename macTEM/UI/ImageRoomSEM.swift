//
//  ImageRoomSEM.swift
//  Role: the Image room's SEM rows: the Info tab's "SEM" section (what a Thermo, Zeiss or Tescan TIFF records beyond the
//        Acquisition section: vendor, pixel size, beam energy, magnification, working distance, detector, dwell, beam current,
//        spot, chamber pressure, stage, instrument, date, user, databar) and the Calibration section's databar switch.
//        `SEMRows` is the wording, pure, so a test pins it (`SEMRowsTests`); the views draw it with the inspector's row kit.
//
//  The wording moves no number: a value prints in the reader's locale at 7 significant digits (the Acquisition section's
//  rule). A field the file does not record is left out, not shown as "Not recorded": the section lists what an SEM file
//  states, and the nine Acquisition rows above it already say what a TEM-style reading lacks. Units: the pixel size in nm, µm
//  or mm (`DisplaySampling`), kV, mm, µs, nA, Pa; the stage in the file's own unit converted to mm, degrees as stored. A row
//  RosettaSciIO does not map carries the core's note beneath it; every Tescan row carries the Tescan note once, on the vendor
//  row. Each row is one accessibility element, "<label>, <value>, <note>".
//

import ShellInspector
import SwiftUI
import ImagoCore
import TEMCore
import TEMSession

/// The SEM section's rows, in order, as text. Pure.
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
        let unvalidated = m.vendor == .tescan ? nil : SEMImageMetadata.unvalidatedNote
        add("vendor", "Vendor", m.vendor.rawValue, note: m.vendor == .tescan ? SEMImageMetadata.tescanNote : nil)
        add("instrument", "Instrument", m.instrument)
        add("pixelSize", "Pixel size", pixelSize(m, locale: locale))
        add("beamEnergy", "Beam energy", m.beamEnergyKV.map { "\(n($0)) kV" })
        if let mag = m.magnification { add("magnification", "Magnification", "\(n(mag))\u{00D7}") }
        else { add("magnification", "Magnification", m.magnificationText) }
        add("workingDistance", "Working distance", m.workingDistanceMM.map { "\(n($0)) mm" })
        add("detector", "Detector", m.detector, note: m.vendor == .thermo ? unvalidated : nil)
        add("dwell", "Dwell", m.dwellS.map { "\(n($0 * 1e6)) \u{00B5}s" })
        add("beamCurrent", "Beam current", m.beamCurrentNA.map { "\(n($0)) nA" })
        add("spot", "Spot", m.spotSize.map { m.spotSizeUnit == "m" ? "\(n($0 * 1e9)) nm" : n($0) }, note: unvalidated)
        add("chamberPressure", "Chamber pressure", m.chamberPressurePa.map { "\(n($0)) Pa" }, note: unvalidated)
        add("stage", "Stage", stage(m, locale: locale))
        add("acquired", "Acquired", acquired(m))
        add("user", "User", m.user)
        add("databar", "Databar", databar(m), note: m.vendor == .zeiss ? SEMImageMetadata.zeissDatabarNote : unvalidated)
        return rows
    }

    /// "2.615 µm/px", or "2.615 × 2.6 µm/px" when the two differ.
    static func pixelSize(_ m: SEMImageMetadata, locale: Locale) -> String? {
        guard let x = m.pixelSizeX else { return nil }
        let ax = DisplaySampling.perPixel(AxisCalibration(scale: x, unit: "m")) ?? AxisCalibration(scale: x, unit: "m")
        let unit = UnitDisplay.label(ax.unit)
        guard let y = m.pixelSizeY, y != x else { return "\(UnitDisplay.number(ax.scale, digits: significantDigits, locale: locale)) \(unit)/px" }
        let ay = DisplaySampling.perPixel(AxisCalibration(scale: y, unit: "m")) ?? AxisCalibration(scale: y, unit: "m")
        return "\(UnitDisplay.number(ax.scale, digits: significantDigits, locale: locale)) \u{00D7} "
            + "\(UnitDisplay.number(ay.scale, digits: significantDigits, locale: locale)) \(UnitDisplay.label(ay.unit))/px"
    }

    /// "x 75.6442 · y 60.4901 · z 25.193 mm · R 10.2° · T 0°": the positions in mm, as many as the file states.
    static func stage(_ m: SEMImageMetadata, locale: Locale) -> String? {
        let toMM = m.stageUnit == "m" ? 1e3 : 1
        func n(_ x: Double) -> String { UnitDisplay.number(x, digits: significantDigits, locale: locale) }
        var parts: [String] = []
        let positions = [("x", m.stageX), ("y", m.stageY), ("z", m.stageZ)].compactMap { name, v in v.map { "\(name) \(n($0 * toMM))" } }
        if !positions.isEmpty { parts.append(positions.joined(separator: " · ") + " mm") }
        if let r = m.stageRotationDeg { parts.append("R \(n(r))°") }
        if let t = m.stageTiltDeg { parts.append("T \(n(t))°") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
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

/// The Info tab's SEM section, drawn only for an SEM file.
struct SEMSection: View {
    let sem: SEMImageMetadata

    var body: some View {
        let rows = SEMRows.rows(sem)
        InspectorSection("SEM") {
            ForEach(rows) { row in
                VStack(alignment: .leading, spacing: 2) {
                    InspectorValueRow(row.label, row.value)
                    if let note = row.note { InspectorNote(note) }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(row.label)
                .accessibilityValue(row.note.map { "\(row.value), \($0)" } ?? row.value)
                .accessibilityIdentifier("image.sem.\(row.id)")
            }
        }
    }
}

/// The Calibration section's switch for a file with a databar: on shows the scan alone (the default), off the whole frame.
struct SEMDatabarToggle: View {
    let sem: SEMImageMetadata
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var appState = appState
        InspectorRow("Crop Databar") {
            Toggle("Crop Databar", isOn: $appState.cropsDatabar)
                .labelsHidden()
                .toggleStyle(.switch)
                .accessibilityIdentifier("image.sem.cropDatabar")
        }
        .help("Show the scan without the \(sem.databarRows ?? 0)-row databar the microscope drew under it; off shows the whole frame, for an export with the bar")
        InspectorNote(appState.cropsDatabar
                      ? "The \(sem.databarRows ?? 0)-row databar is cut off; lengths and exports are of the scan."
                      : "The whole frame is shown, databar included.")
    }
}
