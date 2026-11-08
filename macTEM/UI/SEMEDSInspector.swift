//
//  SEMEDSInspector.swift
//  Role: the EDS room's SEM rows (docs/sem/design/sem-eds-room.md §4) for an SEM spectrum, drawn by macTEM below MacEMUI's own EDS
//        sections: "Line Intensities" (the background-windows switch, the window widths, one value row per line with its windows and
//        counts) and "Window Quantification" (a k-factor per line, Quantify, wt% and at%), and in Info the SEM conditions with the
//        take-off angle. The numbers are `SEMEDSState`'s (exspy's window path, TEMCore `SEMEDSLines`). Nothing shows for a TEM file.
//

import ShellInspector
import SwiftUI
import TEMCore

private let semNumber = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(0...4))

/// The Settings rows for an SEM spectrum. The table is loaded by `WorkspaceView` when the EDS room's file changes, not here: a
/// `.task` on this view never starts while it draws nothing, which is every time before the first load.
struct SEMEDSSettings: View {
    let state: SEMEDSState

    var body: some View {
        if state.isSEMSpectrum {
            SEMEDSLinesSection(state: state)
            SEMEDSQuantSection(state: state)
        }
    }
}

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

/// Line intensities with exspy's background windows (`get_lines_intensity(background_windows=…)`), live as the widths change.
struct SEMEDSLinesSection: View {
    @Bindable var state: SEMEDSState

    var body: some View {
        InspectorSection("Line Intensities") {
            InspectorRow("Background windows") {
                Toggle("Background windows", isOn: $state.backgroundWindows).labelsHidden().toggleStyle(.switch)
                    .help("Subtract the counts of two windows beside each line, scaled to the line's window (exspy's estimate_background_windows).")
                    .accessibilityIdentifier("edx.sem.backgroundWindows")
            }
            InspectorRow("Window width") {
                OptionalNumericField(title: "Window width", value: state.integrationWidth, format: semNumber, unit: "× FWHM") {
                    if $0 > 0 { state.integrationWidth = $0 }
                }
                .accessibilityIdentifier("edx.sem.windowWidth")
            }
            if state.backgroundWindows {
                InspectorRow("Background left") {
                    OptionalNumericField(title: "Background left", value: state.backgroundLeft, format: semNumber, unit: "× FWHM") {
                        if $0 >= 0 { state.backgroundLeft = $0 }
                    }
                }
                InspectorRow("Background right") {
                    OptionalNumericField(title: "Background right", value: state.backgroundRight, format: semNumber, unit: "× FWHM") {
                        if $0 >= 0 { state.backgroundRight = $0 }
                    }
                }
            }
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
                InspectorNote(state.backgroundWindows ? "Counts in each line's window minus the scaled background windows (exspy)."
                                                      : "Counts in each line's window, no background subtracted (exspy).")
            }
        }
    }
}

/// Cliff-Lorimer on the window intensities with typed k-factors (exspy `quantification(method="CL")`); validation: none beyond exspy.
struct SEMEDSQuantSection: View {
    let state: SEMEDSState

    var body: some View {
        InspectorSection("Window Quantification") {
            ForEach(state.rows) { row in
                InspectorRow("k " + SEMEDSFormat.lineTitle(row.line)) {
                    OptionalNumericField(title: "k-factor \(SEMEDSFormat.lineTitle(row.line))", value: state.kFactors[row.line], format: semNumber,
                                         prompt: "Type k") { state.setKFactor($0, for: row.line) }
                        .accessibilityIdentifier("edx.sem.k.\(row.line)")
                }
            }
            InspectorActionRow {
                Button("Quantify") { state.quantify() }
                    .disabled(state.quantifyDisabledReason != nil)
                    .help(state.quantifyDisabledReason ?? "Cliff-Lorimer on the line intensities above with these k-factors.")
                    .accessibilityIdentifier("edx.sem.quantify")
            }
            if let composition = state.composition {
                ForEach(composition) { c in
                    InspectorValueRow(c.element, "\(SEMEDSFormat.percent(c.weightPercent)) wt% · \(SEMEDSFormat.percent(c.atomicPercent)) at%", mono: true)
                        .accessibilityIdentifier("edx.sem.composition.\(c.element)")
                }
                InspectorNote(state.compositionIsStale ? "Stale: a window or a k-factor changed; press Quantify."
                                                       : "Cliff-Lorimer with typed k-factors, no absorption correction (exspy). Not validated against a standard.")
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
        }
    }
}
