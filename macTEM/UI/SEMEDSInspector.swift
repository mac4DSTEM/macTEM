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
    static func keV(_ v: Double) -> String { v.formatted(.number.precision(.fractionLength(3))) }
    static func counts(_ v: Double) -> String { v.formatted(.number.precision(.fractionLength(0))) }
    static func percent(_ v: Double) -> String { v.formatted(.number.precision(.fractionLength(2))) }
    static func lineTitle(_ line: String) -> String {
        let parts = line.split(separator: "_").map(String.init)
        guard parts.count == 2 else { return line }
        let greek = parts[1].replacingOccurrences(of: "a", with: "α").replacingOccurrences(of: "b", with: "β")
        return "\(parts[0]) \(greek)"
    }

    static func windows(_ row: SEMEDSLines.LineRow) -> String {
        var text = "\(keV(row.integrationWindow[0]))–\(keV(row.integrationWindow[1]))"
        if let bw = row.backgroundWindows {
            text += " · bg \(keV(bw[0]))–\(keV(bw[1])), \(keV(bw[2]))–\(keV(bw[3])) keV"
        } else {
            text += " keV"
        }
        return text
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
                InspectorValueRow("Microscope", "SEM" + (state.spectrum?.microscope.map { " · \($0)" } ?? ""))
                if let kV = c.beamEnergyKeV { InspectorValueRow("Beam", "\(kV.formatted()) kV") }
                InspectorValueRow("Take-off", "\(c.takeOffAngleDeg.formatted(.number.precision(.fractionLength(1))))°")
                    .help("90° − acos(sin α cos β cos φ cos θ − sin β sin φ cos θ − cos α cos β sin θ): α stage tilt, β = −tilt β, φ azimuth, θ = −elevation (exspy take_off_angle).")
                    .accessibilityIdentifier("edx.sem.takeOff")
                InspectorValueRow("Elevation", "\(c.elevationAngleDeg.formatted())°")
                InspectorValueRow("Stage tilt", "\(c.tiltAlphaDeg.formatted())°")
                InspectorValueRow("Resolution", "\(c.energyResolutionMnKaEV.formatted()) eV at Mn Kα")
                if let live = c.liveTimeS { InspectorValueRow("Live time", "\(live.formatted(.number.precision(.fractionLength(1)))) s") }
            }
            SEMEDSLineWindowsSection(state: state)
        }
    }
}
