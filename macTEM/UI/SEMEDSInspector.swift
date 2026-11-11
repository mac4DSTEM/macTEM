//
//  SEMEDSInspector.swift
//  Role: the EDS room's Info rows for an SEM spectrum (docs/sem/design/sem-eds-room.md §4, D-SEM-107): "SEM Conditions" (the take-off angle
//        exspy computes) and "Line Windows", exspy's background-window line table read-only, to check the room's fit against exspy. The
//        spectrum is quantified by the shared EDS room's own Quantify, with the file's elements picked on open (`SEMEDSState`). Nothing shows
//        for a TEM file.
//

import ShellInspector
import SwiftUI
import TEMCore

nonisolated enum SEMEDSFormat {
    /// `places` decimals in `locale`, never grouped (the SEM rows' rule, #272): "12345 counts", "1,486 keV" in de_DE, as
    /// `UnitDisplay.fixed` writes them: printf's digits, so a tie reads as the CSV beside it (0.35 at one place is "0.3"), UnitDisplay's
    /// dash for a non-finite value, and no sign on a value that rounds to zero ("0,000", never "-0,000").
    static func fixed(_ v: Double, _ places: Int, locale: Locale = .autoupdatingCurrent) -> String {
        UnitDisplay.fixed(v, places: places, locale: locale)
    }

    static func keV(_ v: Double, locale: Locale = .autoupdatingCurrent) -> String { fixed(v, 3, locale: locale) }
    static func counts(_ v: Double, locale: Locale = .autoupdatingCurrent) -> String { fixed(v, 0, locale: locale) }
    static func lineTitle(_ line: String) -> String {
        let parts = line.split(separator: "_").map(String.init)
        guard parts.count == 2 else { return line }
        let greek = parts[1].replacingOccurrences(of: "a", with: "α").replacingOccurrences(of: "b", with: "β")
        return "\(parts[0]) \(greek)"
    }

    static func windows(_ row: SEMEDSLines.LineRow, locale: Locale = .autoupdatingCurrent) -> String {
        let k = { keV($0, locale: locale) }
        var text = "\(k(row.integrationWindow[0]))–\(k(row.integrationWindow[1]))"
        if let bw = row.backgroundWindows {
            text += " · bg \(k(bw[0]))–\(k(bw[1])), \(k(bw[2]))–\(k(bw[3])) keV"
        } else {
            text += " keV"
        }
        return text
    }

    /// The take-off row's label: the one row of "SEM Conditions" with help and an identifier of its own.
    static let takeOff = "Take-off"

    /// The "SEM Conditions" rows in `locale`, never grouped: the angles, the beam and the resolution as `UnitDisplay.number` writes them,
    /// the take-off angle and the live time at one place (`fixed`): "Live time 1234,5 s" in de_DE, where FormatStyle grouped "1.234,5 s".
    /// A row the file does not state (the beam, the live time) is left out.
    static func conditionRows(_ c: SEMEDSLines.Conditions, microscope: String?,
                              locale: Locale = .autoupdatingCurrent) -> [EBSDBrowsing.Row] {
        let n = { (v: Double) in UnitDisplay.number(v, locale: locale) }
        var rows = [EBSDBrowsing.Row("Microscope", "SEM" + (microscope.map { " · \($0)" } ?? ""))]
        if let kV = c.beamEnergyKeV { rows.append(EBSDBrowsing.Row("Beam", "\(n(kV)) kV")) }
        rows.append(EBSDBrowsing.Row(takeOff, "\(fixed(c.takeOffAngleDeg, 1, locale: locale))°"))
        rows.append(EBSDBrowsing.Row("Elevation", "\(n(c.elevationAngleDeg))°"))
        rows.append(EBSDBrowsing.Row("Stage tilt", "\(n(c.tiltAlphaDeg))°"))
        rows.append(EBSDBrowsing.Row("Resolution", "\(n(c.energyResolutionMnKaEV)) eV at Mn Kα"))
        if let live = c.liveTimeS { rows.append(EBSDBrowsing.Row("Live time", "\(fixed(live, 1, locale: locale)) s")) }
        return rows
    }
}

/// exspy's line table for an SEM spectrum, read-only in Info: each line's integration window and background windows and its counts
/// (`get_lines_intensity(background_windows=…)` with the tutorial's widths), to check the shared room's fitted net counts against exspy.
/// The room's own Quantify (the toolbar) quantifies the spectrum, as for a TEM one (Paul, 2026-11-10: the SEM spectrum goes through the
/// shared EDS room).
struct SEMEDSLineWindowsSection: View {
    let state: SEMEDSState

    var body: some View {
        InspectorSection("Line Windows", startsExpanded: false) {
            ForEach(state.rows) { row in
                VStack(alignment: .leading, spacing: 2) {
                    InspectorValueRow(SEMEDSFormat.lineTitle(row.line), SEMEDSFormat.counts(row.intensity) + " counts", mono: true)
                    Text(SEMEDSFormat.windows(row))
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("edx.sem.line.\(row.line)")
            }
            if let failure = state.failure {
                InspectorWarning(failure)
            } else if state.rows.isEmpty {
                InspectorNote("The file names no element with a line below the beam energy.")
            } else {
                InspectorNote("Counts in each line's window minus the scaled background windows, as exspy's tutorial reads them; the results beside the spectrum are the room's fit.")
            }
        }
    }
}

/// Info: the SEM conditions the file states and the take-off angle exspy computes from them.
struct SEMEDSInfo: View {
    let state: SEMEDSState

    var body: some View {
        if state.isSEMSpectrum, let c = state.spectrum?.conditions {
            InspectorSection("SEM Conditions") {
                ForEach(SEMEDSFormat.conditionRows(c, microscope: state.spectrum?.microscope)) { row in
                    if row.label == SEMEDSFormat.takeOff {
                        InspectorValueRow(row.label, row.value)
                            .help("90° − acos(sin α cos β cos φ cos θ − sin β sin φ cos θ − cos α cos β sin θ): α stage tilt, β = −tilt β, φ azimuth, θ = −elevation (exspy take_off_angle).")
                            .accessibilityIdentifier("edx.sem.takeOff")
                    } else {
                        InspectorValueRow(row.label, row.value)
                    }
                }
            }
            SEMEDSLineWindowsSection(state: state)
        }
    }
}
