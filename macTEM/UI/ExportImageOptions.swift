//
//  ExportImageOptions.swift
//  Role: the accessory of the Export Image save panel: two
//        checkboxes, Scale bar and Marks, in one row. SwiftUI, hosted by `ExportPanels` (App/), which owns the AppKit
//        panel: the macOS 27 SDK's `fileExporter` and `fileDialog*` modifiers offer no accessory, and the options belong
//        in the save panel, as Preview's export does. Presentation only: what the options start as is
//        `ExportSnapshot`'s (`ExportImageDefaults`), what they become when the panel is confirmed is read from
//        `ExportImageChoices` by the code that presents it.
//
//        Marks is omitted, never dimmed, when the file has none. The hosting view takes its size once, from
//        `fittingSize`, so the panel never changes height after it is up.
//

import SwiftUI

/// What the panel's checkboxes are now. Lives as long as the panel does (`ExportPanels` holds it across the await).
@Observable
final class ExportImageChoices {
    var scaleBar: Bool
    var marks: Bool
    /// Whether the panel offers Marks at all: fixed when it opens.
    let offersMarks: Bool
    /// What the second checkbox draws: the Image room's marks, or the FFT room's measured spots.
    let kind: Kind

    enum Kind: Sendable {
        case marks, spots

        var title: String { self == .marks ? "Marks" : "Spots" }
        var help: String {
            self == .marks ? "Draw this file's distances, angles and profiles on the image"
                           : "Draw a ring and the number of each measured spot on the transform"
        }
        var identifier: String { self == .marks ? "export.marksToggle" : "export.spotsToggle" }
    }

    init(scaleBar: Bool, marks: Bool, offersMarks: Bool, kind: Kind = .marks) {
        self.scaleBar = scaleBar
        self.marks = marks
        self.offersMarks = offersMarks
        self.kind = kind
    }

    convenience init(_ defaults: ExportImageDefaults, kind: Kind = .marks) {
        self.init(scaleBar: defaults.scaleBar, marks: defaults.marks, offersMarks: defaults.offersMarks, kind: kind)
    }
}

/// Scale bar, and Marks when the file has some.
struct ExportImageOptions: View {
    @Bindable var choices: ExportImageChoices

    /// Between the two checkboxes, and around them: the accessory is a strip under the panel's name field, and
    /// without padding the checkboxes' focus rings would touch its edge. A panel's own gutter, not a science number.
    private static let spacing: CGFloat = 16
    private static let padding: CGFloat = 8

    var body: some View {
        HStack(spacing: Self.spacing) {
            Toggle("Scale bar", isOn: $choices.scaleBar)
                .help(choices.kind == .marks ? "Draw the scale bar at the bottom left of the image"
                                             : "Draw the scale bar at the bottom left of the transform")
                .accessibilityIdentifier("export.scaleBarToggle")
            if choices.offersMarks {
                Toggle(choices.kind.title, isOn: $choices.marks)
                    .help(choices.kind.help)
                    .accessibilityIdentifier(choices.kind.identifier)
            }
        }
        .toggleStyle(.checkbox)
        .padding(Self.padding)
        // One group for VoiceOver, so the two checkboxes are read as the panel's drawing options.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(choices.kind == .marks ? "Drawn on the image" : "Drawn on the transform")
    }
}
