//
//  SEMOverlayStyle.swift
//  Role: how the SEM rooms stroke a line they draw over a pattern so it reads on any intensity: mac4DSTEM's overlay recipe
//        (`ApertureOutline` in mac4DSTEM/UI/PaneOverlays.swift: a solid dark under-stroke, then the line in a fixed hue, a dash kept on
//        the line only, so the dashes sit on an unbroken dark track) and its label plate (`PatternFitLegend`: a dark capsule under the
//        text). macTEM draws its overlays in the pane's unzoomed space through `MarkGeometry`, so these widths are on-screen widths at
//        any zoom and need no division by the zoom. Pure values; the views read them.
//

import SwiftUI

nonisolated enum SEMOverlayStyle {
    /// The dark under-stroke beneath every line: its width and opacity (mac4DSTEM `ApertureOutline.haloWidth`, `.haloOpacity`).
    static let haloWidth: CGFloat = 3.5
    static let haloOpacity = 0.6
    /// The line on top: its width and opacity (mac4DSTEM `ApertureOutline.lineWidth`, `.lineOpacity`).
    static let lineWidth: CGFloat = 1.5
    static let lineOpacity = 0.9
    /// The dash of a line drawn dashed; the under-stroke stays solid (mac4DSTEM `ApertureOutline.innerDash`).
    static let dash: [CGFloat] = [4, 3]

    /// The under-stroke: solid, whatever the line's dash.
    static var halo: StrokeStyle { StrokeStyle(lineWidth: haloWidth, lineCap: .round) }
    /// The line: solid, or dashed with `dash`.
    static func line(dashed: Bool) -> StrokeStyle {
        StrokeStyle(lineWidth: lineWidth, lineCap: dashed ? .butt : .round, dash: dashed ? dash : [])
    }

    /// The label plate under a word drawn on a pattern: the capsule's opacity and padding (mac4DSTEM `PatternFitLegend`).
    static let plateOpacity = 0.48
    static let plateHorizontalPadding: CGFloat = 7
    static let plateVerticalPadding: CGFloat = 3
}
