//
//  FFTRoomExport.swift
//  Role: the FFT room's Export section, the last section of its inspector (control placement standard: plain bordered buttons,
//        two per row at equal widths, a lone one full width, disabled with the reason as help; no pull-down). Its three buttons
//        ("Transform PNG…", "Radial profile CSV…", "Spots CSV…") are the twins of the File menu's Export Transform… ⌥⌘E,
//        Export Radial Profile… and Export Spots…, enabled by the same rule (`ExportSnapshot.fftAvailability`). The buttons repeat
//        no key (the File menu owns ⌥⌘E; a second `.keyboardShortcut` would collide), the panes get no buttons, and nothing here
//        depends on pane focus. The exports share no switch. Presentation only: the panels are `ExportPanels`', the values
//        `FFTExportSnapshot`'s, the words `FFTExportMenu`'s.
//
//  SKILL NOTES (swiftui-macos): observation.md "State Capture at Body Level" — the availability is read once per body and the
//  items get Bools; accessibility.md — a button keeps its text label; a disabled one says why in `.help`.
//

import ShellInspector
import SwiftUI
import TEMCore
import TEMSession

/// The Export menu's words and states, as pure data: the view draws exactly these (pinned by FFTExportMenuTests).
nonisolated enum FFTExportMenu {
    enum Item: CaseIterable, Sendable {
        case transform, profile, spots

        var title: String {
            switch self {
            case .transform: "Transform PNG…"
            case .profile: "Radial profile CSV…"
            case .spots: "Spots CSV…"
            }
        }

        /// The panel this item opens: the same call as the File menu item of the same name. Held by FFTExportMenuTests.
        @MainActor var panel: @MainActor (AppState) -> Void {
            switch self {
            case .transform: ExportPanels.exportTransform
            case .profile: ExportPanels.exportRadialProfile
            case .spots: ExportPanels.exportSpots
            }
        }

        /// What the button saves, its help when it is on.
        var saves: String {
            switch self {
            case .transform: "Save the transform as a PNG: one pixel per bin, with a reciprocal scale bar"
            case .profile: "Save the radial profile as a CSV: |q|, the mean |F|² and the pixel count of each bin"
            case .spots: "Save the measured spots as a CSV: d, |q|, qx, qy and whether each is in the mask"
            }
        }

        var identifier: String {
            switch self {
            case .transform: "fft.export.transform"
            case .profile: "fft.export.profile"
            case .spots: "fft.export.spots"
            }
        }
    }

    /// One button: its title, whether it can be pressed and, when it cannot, the reason (the button's help).
    struct Entry: Equatable, Sendable {
        let item: Item
        let title: String
        let isEnabled: Bool
        let reason: String?

        /// The button's help: why it is off, else what it saves.
        var help: String { reason ?? item.saves }
    }

    /// Why an item is off, by cause (nil when it is on).
    static func reason(_ item: Item, enabled: Bool, hasSpectrum: Bool) -> String? {
        guard !enabled else { return nil }
        guard hasSpectrum else { return "no transform yet" }
        switch item {
        case .transform: return "the transform is updating"
        case .profile: return "no radial profile for this transform"
        case .spots: return "measure a spot first"
        }
    }

    /// The three items in order for what the room has: `ExportSnapshot.fftAvailability` decides `enabled`, the owner's
    /// `isSpectrumCurrent` picks the cause.
    static func entries(_ availability: FFTExportAvailability, hasSpectrum: Bool) -> [Entry] {
        Item.allCases.map { item in
            let enabled: Bool
            switch item {
            case .transform: enabled = availability.transform
            case .profile: enabled = availability.profile
            case .spots: enabled = availability.spots
            }
            let reason = reason(item, enabled: enabled, hasSpectrum: hasSpectrum)
            return Entry(item: item, title: item.title, isEnabled: enabled, reason: reason)
        }
    }

    /// What the three buttons save, in one sentence (the section's spoken hint).
    static let help = "Save the transform as a PNG (one pixel per bin, with a reciprocal scale bar; the panel says when its shape differs from the room's), the radial profile as a CSV (|q|, the mean |F|² and the pixel count of each bin) or the measured spots as a CSV (d, |q|, qx, qy and whether each is in the mask)"
}

/// The room's last section: Transform PNG and Radial profile CSV side by side, Spots CSV full width under them.
struct FFTExportSection: View {
    @Environment(AppState.self) private var appState
    let analysis: FFTAnalysis

    var body: some View {
        let entries = FFTExportMenu.entries(ExportSnapshot.fftAvailability(of: appState), hasSpectrum: analysis.isSpectrumCurrent)
        InspectorSection("Export") {
            ForEach(Array(stride(from: 0, to: entries.count, by: 2)), id: \.self) { start in
                InspectorActionRow {
                    ForEach(entries[start..<min(start + 2, entries.count)], id: \.item) { entry in
                        Button(entry.title) { entry.item.panel(appState) }
                            .disabled(!entry.isEnabled)
                            .help(entry.help)
                            .accessibilityIdentifier(entry.item.identifier)
                    }
                }
            }
        }
        .accessibilityHint(FFTExportMenu.help)
    }
}
