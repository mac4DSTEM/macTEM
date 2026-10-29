//
//  FFTSpectrumImagePane.swift
//  Role: the FFT room's right pane (archive: roadmap-registrations-2026-10-15.md V1-6 + 6a + 6b, "The room"; the design in
//        archive: fft-room-design-2026-10-13.md): the centred power spectrum of the region (or the whole image) drawn
//        at its PHYSICAL aspect, the measured spots numbered on it and, while the masked inverse is shown, the mask's
//        circles. Built as `ImagePane` is (single-line header, `GeometryReader` + `LayoutPolicy.fitted`, the shader's
//        `MetalDisplayTransform` with a pane-sized drawable, a `Canvas` over it mapped through `MarkGeometry`, `ZoomPan`,
//        a `PaneFooter` outside the zoomed container). The spectrum, its bins and its values are TEMCore's and the
//        owner's (`FFTAnalysis`); this file maps, draws and takes the click.
//
//  R7, THE SPECTRUM DRAWN: the box's aspect is (w·Δq_x) : (h·Δq_y) (`SpectrumShape.aspect`, with the axes' units: square
//  when they cannot be compared), so a ring is a circle and a
//  frequency is the same number of points along either axis; the scale bar's units per point are Δq_x·w / boxWidth /
//  zoom (`ImageScaleBar.unitsPerPoint`, with the spectrum's own unit converted by `FFTUnits.spectrumUnit`). Grey only: no
//  colormap or gamma for the spectrum (a second curve invites doubt); the window is the owner's, else the product's
//  default (`FFTSpectrumLayout.window`).
//
//  R3, A CLICK: the pane's point goes through `MarkGeometry` with the spectrum's width and height to the bin
//  (`SpectrumBin.at`), and `FFTAnalysis.measureSpot` does the rest. A `SpatialTapGesture` is attached SIMULTANEOUSLY to the
//  `ZoomPan` container: ZoomPan's drag still pans (it starts at 10 pt; a click never pans, a pan never measures). A click
//  within 6 pt of a marker selects that spot instead. ZoomPan's own double-click reset is verbatim and reaches this pane
//  too (design note, "Gestures", amended after Gate B): its first click selects or measures, its second selects the spot
//  just made — the marker is under the pointer, or the click names the same bin, which `FFTAnalysis.measureSpot` selects
//  instead of measuring again — so a double-click never makes two spots (FFTRoomPaneTests pins it).
//
//  WHAT IT SAYS (`FFTPaneFormat`, pure, here because the source pane shares it): the header names the crop of the
//  spectrum SHOWN (never the one asked for) and "Updating…" with a spinner while another is asked for; the picture dims
//  after 0.2 s of that, so a result that lands at once never flickers (Reduce Motion: no fade). Nothing stale is drawn as
//  current: a spot whose spectrum is not the one shown is not marked.
//
//  SKILL NOTES (swiftui-macos): views.md ".task(id:) for Reactive Async Work" — the dim timer restarts on each change of
//  the flag and cancels with the view (concurrency.md "Task Cancellation": a cancelled sleep ends the task before it
//  dims); observation.md "Observation Scope Narrowing" — the markers and the refusal note read the spots in their own
//  views, so a spot landing does not re-evaluate the pane over the Metal view; performance.md "Canvas" — the markers
//  are one Canvas, not a view per ring; accessibility.md — the pane is a container with a label and a value (Reduce
//  Motion respected: no fade), the canvases are hidden, Delete and ⌘C act on the selected spot, and the click's twin is
//  the inspector's "Measure at…".
//

import ShellControls
import ShellLayout
import ShellMetal
import SwiftUI
import TEMCore
import TEMSession
import ImagoCore
import ImagoFFT

// MARK: - What the panes say (pure)

nonisolated enum FFTPaneFormat {
    static let updating = "Updating…"
    /// How long a spectrum is asked for before the picture shown dims.
    static let dimDelay = Duration.milliseconds(200)

    /// "Updating…" belongs to a spectrum on screen while another is asked for; with none on screen the pane is computing.
    static func isUpdating(hasSpectrum: Bool, isCurrent: Bool) -> Bool { hasSpectrum && !isCurrent }

    // MARK: What a transform is of

    /// "region 256 × 256 px at (812, 404)" — size as width × height, the corner as (column, row) — or "whole image
    /// 2048 × 1024 px".
    static func subject(crop: PixelCrop?, width: Int, height: Int) -> String {
        guard let crop else { return "whole image \(width) × \(height) px" }
        return "region \(crop.width) × \(crop.height) px at (\(crop.col), \(crop.row))"
    }

    /// The same for VoiceOver: "Region 256 by 256 pixels at column 812, row 404".
    static func spokenSubject(crop: PixelCrop?, width: Int, height: Int) -> String {
        guard let crop else { return "Whole image \(width) by \(height) pixels" }
        return "Region \(crop.width) by \(crop.height) pixels at column \(crop.col), row \(crop.row)"
    }

    // MARK: The source pane's views

    static func title(of view: FFTAnalysis.SourceView) -> String {
        switch view {
        case .original: "Original"
        case .region: "Region"
        case .maskedInverse: "Masked Inverse"
        case .absf: "ABSF"
        case .wiener: "Wiener"
        }
    }

    /// Why `view` cannot be chosen yet, by cause; nil when it can. The Masked Inverse says which of its two causes holds:
    /// no spot measured at all, or measured spots but none In Mask.
    static func unavailableReason(_ view: FFTAnalysis.SourceView, hasSpectrum: Bool, hasMeasuredSpot: Bool,
                                  hasMaskSpot: Bool, hasFilterResult: Bool) -> String? {
        switch view {
        case .original: nil
        case .region: hasSpectrum ? nil : "no transform yet"
        case .maskedInverse: hasMaskSpot ? nil : (hasMeasuredSpot ? "none in mask" : "no spot")
        case .absf, .wiener: hasFilterResult ? nil : "filter first"
        }
    }

    /// The menu entry: the name, and (when it cannot be chosen) why — "ABSF (filter first)". The view the pane shows is the
    /// control's face and keeps to its plain name whatever its state: the face must fit the narrowest header
    /// (`maximumFaceWidth`), and the longest reason, "Masked Inverse (none in mask)", is 187 pt of text; the pane says why
    /// in words under it (`missing`).
    static func menuTitle(_ view: FFTAnalysis.SourceView, reason: String?, isSelected: Bool) -> String {
        guard let reason, !isSelected else { return title(of: view) }
        return "\(title(of: view)) (\(reason))"
    }

    /// One item of the View menu: the view, its words (`menuTitle`) and whether it can be chosen (it has no reason not to be).
    nonisolated struct MenuEntry: Equatable, Sendable {
        let view: FFTAnalysis.SourceView
        let title: String
        let isEnabled: Bool
    }

    /// The View menu, every view in order, for the view the pane shows and what exists: the control draws exactly these.
    static func menuEntries(selected: FFTAnalysis.SourceView, hasSpectrum: Bool, hasMeasuredSpot: Bool, hasMaskSpot: Bool,
                            hasFilterResult: Bool) -> [MenuEntry] {
        FFTAnalysis.SourceView.allCases.map { view in
            let reason = unavailableReason(view, hasSpectrum: hasSpectrum, hasMeasuredSpot: hasMeasuredSpot, hasMaskSpot: hasMaskSpot,
                                           hasFilterResult: hasFilterResult)
            return MenuEntry(view: view, title: menuTitle(view, reason: reason, isSelected: view == selected), isEnabled: reason == nil)
        }
    }

    /// The most the View menu's face may be across in the narrowest header, in points: `LayoutPolicy.imagePaneMinimum` (180)
    /// less the pane's padding on both sides (8 pt each) and the gap and the spacer the header keeps beside the file name
    /// (8 pt each) — the file name, which truncates, has what is left. (A literal: `LayoutPolicy` is main-actor isolated and
    /// this type is not; FFTRoomPaneTests holds the two together.)
    static let maximumFaceWidth: Double = 148

    // MARK: The plates (a product names itself and its inputs)

    static func regionPlate(crop: PixelCrop?, width: Int, height: Int) -> String {
        guard let crop else { return "Whole image · transformed pixels · \(width) × \(height) px" }
        return "Region · transformed pixels · \(width) × \(height) px at (\(crop.col), \(crop.row))"
    }

    static func maskedInversePlate(spots: Int, radius: Double, edge: Double, width: Int, height: Int,
                                   locale: Locale = .autoupdatingCurrent) -> String {
        let who = spots == 1 ? "1 spot and its Friedel partner" : "\(spots) spots and their Friedel partners"
        let r = UnitDisplay.number(radius, digits: 4, locale: locale)
        let e = UnitDisplay.number(edge, digits: 4, locale: locale)
        return "Masked inverse · \(who) · radius \(r), edge \(e) bins · \(width) × \(height) px"
    }

    /// The filters' plate begins with the warning, every time they are shown (design note, "The badge and the notes").
    static func filterPlate(_ name: String, size: Int) -> String {
        "Unvalidated · not compared with Digital Micrograph · \(name) · \(size) × \(size) px"
    }

    // MARK: What is not there

    /// A product that does not exist: what it waits for, or why it failed in the core's words. The Masked Inverse waits by
    /// the menu's two causes: no spot measured, or measured spots none of which is In Mask.
    static func missing(_ view: FFTAnalysis.SourceView, isWorking: Bool, failure: String?, hasMeasuredSpot: Bool,
                        hasMaskSpot: Bool) -> (title: String, detail: String) {
        switch view {
        case .original:
            return ("No image", "")
        case .region:
            return failure.map { ("No transform", $0) } ?? ("Transforming…", "")
        case .maskedInverse:
            if let failure { return ("No masked inverse", failure) }
            if hasMaskSpot { return ("Computing the masked inverse…", "") }
            return ("No masked inverse yet", hasMeasuredSpot ? "Tick a spot's checkbox in the Spots section to put it in the mask."
                        : "Click a spot in the transform, then keep it in the mask.")
        case .absf, .wiener:
            if isWorking { return ("Filtering…", "") }
            if let failure { return ("No filtered image", failure) }
            return ("No filtered image yet", "Press Filter in the HRTEM Filters section.")
        }
    }

    static func missingSpectrum(failure: String?) -> (title: String, detail: String) {
        failure.map { ("No spectrum", $0) } ?? ("Computing the spectrum…", "")
    }

    // MARK: Spots

    /// Why a spot was not measured: the inspector's own sentence (`FFTRoomFormat.refusal`, the design note's words), so the
    /// footer and the Spots section can never disagree.
    static func refusal(_ failure: SpotMeasurementError) -> String { FFTRoomFormat.refusal(failure) }

    /// What ⌘C copies for a spot: its number, the inspector row's own text (`FFTRoomFormat.spotValue`: d and |q| in the unit
    /// the room shows them in, nm and nm⁻¹ for a length unit, or the refusal) and, for a measured one, what was transformed.
    static func copyLine(_ spot: FFTSpot, subject: String, locale: Locale = .autoupdatingCurrent) -> String {
        let line = "Spot \(spot.number) · \(FFTRoomFormat.spotValue(spot, locale: locale))"
        return spot.measured == nil ? line : "\(line) · \(subject)"
    }
}

// MARK: - The spectrum's box, bar and window

enum FFTSpectrumLayout {
    /// The spectrum's box in a pane of `size` — the largest with its physical aspect, (w·Δq_x) : (h·Δq_y), so a ring is a
    /// circle (R7) — and the map from its bins to that box's points at `zoom` and `offset`, through the spectrum's own
    /// width and height.
    static func place(_ spectrum: FFTSpectrumProduct, in size: CGSize, zoom: CGFloat,
                      offset: CGSize) -> (box: CGSize, geometry: MarkGeometry) {
        let box = LayoutPolicy.fitted(in: size, aspect: CGFloat(SpectrumShape.aspect(
            width: spectrum.width, height: spectrum.height, spacingX: spectrum.spacingX, unitsX: spectrum.unitsX,
            spacingY: spectrum.spacingY, unitsY: spectrum.unitsY)))
        return (box, FFTPaneGeometry.make(box: box, width: spectrum.width, height: spectrum.height, zoom: zoom, offset: offset))
    }

    /// The reciprocal scale bar: units per point Δq_x·w / boxWidth / zoom, in the unit `FFTUnits.spectrumUnit` converts the
    /// spectrum's own to, and that unit's label.
    static func bar(for spectrum: FFTSpectrumProduct, box: CGSize, zoom: CGFloat) -> (unitsPerPoint: Double, label: String) {
        let unit = FFTUnits.spectrumUnit(spectrum.unitsX)
        return (ImageScaleBar.unitsPerPoint(perPixel: spectrum.spacingX * unit.factor, imageWidth: spectrum.width,
                                            boxWidth: box.width, zoom: zoom), unit.label)
    }

    /// The length `ScaleBar` aims its bar at, in points (`ScaleBar.targetPoints`; the bar's number is the 1-2-5 value
    /// nearest `unitsPerPoint` × this). FFTRoomPaneTests reads PaneOverlays.swift to hold the two together.
    static let barTargetPoints = 70.0

    /// What VoiceOver says for the bar: the number the bar prints and its unit in words — "per nanometre", "per pixel" —
    /// where the shared `ScaleBar` would say "px⁻¹" raw; any other unit as the bar says it. nil when no bar is drawn.
    static func spokenBar(unitsPerPoint: Double, label: String, locale: Locale = .autoupdatingCurrent) -> String? {
        guard unitsPerPoint > 0, unitsPerPoint.isFinite else { return nil }
        let shown = ScaleBarMath.ladder(ScaleBarMath.nice125(unitsPerPoint * barTargetPoints), unit: label)
        let words: String
        switch shown.unit {
        case FFTUnits.reciprocalNanometreLabel: words = "per nanometre"
        case FFTUnits.reciprocalPixelLabel: words = "per pixel"
        default: return ScaleBar.spokenLabel(value: shown.value, unit: shown.unit, locale: locale)
        }
        return "Scale bar, \(ScaleBar.format(shown.value, locale: locale)) \(words)"
    }

    /// The display window as the shader takes it: the owner's edges, else the product's default, as fractions of the
    /// canvas's range; with neither, the full range.
    static func window(low: Float?, high: Float?, spectrum: FFTSpectrumProduct) -> (low: Float, high: Float) {
        DisplayWindow.fractions(low: low ?? spectrum.defaultWindow?.low, high: high ?? spectrum.defaultWindow?.high,
                                rawRange: spectrum.canvas.rawRange)
    }
}

// MARK: - Spots and the mask on the transform (pure)

nonisolated enum FFTSpotMarkers {
    /// A click within this many points of a marker selects that spot instead of measuring.
    static let hitRadius: CGFloat = 6

    struct Marker: Equatable {
        let id: FFTSpot.ID
        let number: Int
        let point: CGPoint
        /// A measured spot is marked at its centroid; a refused, pending or peakless one at the bin that was clicked.
        let isMeasured: Bool
        let isSelected: Bool
    }

    /// One circle of the mask, an ellipse in points when the box is not square-binned.
    struct MaskCircle: Equatable {
        let centre: CGPoint
        let radii: CGSize
        let isPartner: Bool
    }

    enum Click: Equatable {
        case select(FFTSpot.ID)
        case measure(row: Int, col: Int)
    }

    /// The markers of the spots measured on `key`'s spectrum — a spot of another spectrum belongs to a transform no longer
    /// shown and is not marked.
    static func markers(_ spots: [FFTSpot], spectrum key: FFTSpectrumKey, selection: FFTSpot.ID?,
                        in geometry: MarkGeometry) -> [Marker] {
        spots.filter { $0.spectrumKey == key }.map { spot in
            let at: ImagePoint
            switch spot.outcome {
            case .measured(let m): at = ImagePoint(x: m.centroidCol, y: m.centroidRow)
            case .measuring, .refused: at = ImagePoint(x: Double(spot.col), y: Double(spot.row))
            }
            return Marker(id: spot.id, number: spot.number, point: geometry.panePoint(of: at),
                          isMeasured: spot.measured != nil, isSelected: spot.id == selection)
        }
    }

    /// The bin under a pane point, through the spectrum's own width and height.
    static func clickedBin(at point: CGPoint, width: Int, height: Int, in geometry: MarkGeometry) -> (row: Int, col: Int) {
        SpectrumBin.at(geometry.imagePoint(atPanePoint: point).pixelPoint, width: width, height: height)
    }

    /// The nearest marker within `hitRadius`.
    static func nearest(to point: CGPoint, in markers: [Marker]) -> FFTSpot.ID? {
        var best: (id: FFTSpot.ID, distance: CGFloat)?
        for m in markers {
            let d = hypot(m.point.x - point.x, m.point.y - point.y)
            if d <= hitRadius, d < (best?.distance ?? .infinity) { best = (m.id, d) }
        }
        return best?.id
    }

    /// What a click does: select the marker in reach, else measure the bin under the pointer (R3).
    static func click(at point: CGPoint, spots: [FFTSpot], selection: FFTSpot.ID?, spectrum: FFTSpectrumProduct,
                      in geometry: MarkGeometry) -> Click {
        let markers = markers(spots, spectrum: spectrum.key, selection: selection, in: geometry)
        if let id = nearest(to: point, in: markers) { return .select(id) }
        let bin = clickedBin(at: point, width: spectrum.width, height: spectrum.height, in: geometry)
        return .measure(row: bin.row, col: bin.col)
    }

    /// The ring's radius, in points.
    static let ringRadius: CGFloat = 7

    /// Where a marker's number is drawn: a plate `textSize` plus 6 × 2 pt of padding, above and to the right of the ring,
    /// flipped below and/or to the left of it where that would leave a pane of `size`, then held inside the pane — the number
    /// of a ring that is on the pane is never dropped. nil when the ring is wholly off the pane (nothing to number).
    ///
    /// With `awayFrom` (the transform's centre, where the bright core and most of the spots crowd), the plate goes OUTWARD along the ray from
    /// it through the ring instead, so neighbouring numbers fan out and do not print over each other; and `avoiding` lists the plates already
    /// placed: a plate that would overlap one is moved further out, a row at a time, until it clears (six tries).
    static func labelBox(at point: CGPoint, textSize: CGSize, in size: CGSize, awayFrom centre: CGPoint? = nil, avoiding placed: [CGRect] = []) -> CGRect? {
        guard point.x.isFinite, point.y.isFinite,
              point.x > -ringRadius, point.y > -ringRadius,
              point.x < size.width + ringRadius, point.y < size.height + ringRadius else { return nil }
        let box = CGSize(width: textSize.width + 6, height: textSize.height + 2)
        if let centre {
            let dx = point.x - centre.x, dy = point.y - centre.y
            let length = max(hypot(dx, dy), 0.001)
            let ux = dx / length, uy = dy / length
            for step in 0..<6 {
                let reach = 10 + CGFloat(step) * (box.height + 1)
                let ox = point.x + ux * reach, oy = point.y + uy * reach
                // The plate's near corner sits on the ray; its centre is a half plate further out.
                var rect = CGRect(x: ox - (ux < 0 ? box.width : 0) - (abs(ux) < 0.3 ? box.width / 2 : 0),
                                  y: oy - (uy < 0 ? box.height : 0) - (abs(uy) < 0.3 ? box.height / 2 : 0), width: box.width, height: box.height)
                rect.origin.x = max(0, min(rect.origin.x, size.width - box.width))
                rect.origin.y = max(0, min(rect.origin.y, size.height - box.height))
                if !placed.contains(where: { $0.intersects(rect) }) || step == 5 { return rect }
            }
        }
        var x = point.x + 8
        if x + box.width > size.width { x = point.x - 8 - box.width }
        var y = point.y - 8 - textSize.height
        if y < 0 { y = point.y + 8 }
        // Whatever still sticks out (a pane smaller than the plate and the ring side by side) is pulled in.
        x = max(0, min(x, size.width - box.width))
        y = max(0, min(y, size.height - box.height))
        return CGRect(origin: CGPoint(x: x, y: y), size: box)
    }

    /// The mask drawn: for each measured spot IN the mask on this spectrum, a circle at its centroid and one at its
    /// Friedel partner, mirrored through the zero frequency (R4), the radius converted from bins to points on each axis.
    static func maskCircles(_ spots: [FFTSpot], spectrum: FFTSpectrumProduct, radius: Double, edge: Double,
                            in geometry: MarkGeometry) -> [MaskCircle] {
        let radii = CGSize(width: radius * Double(geometry.pointsPerPixel), height: radius * Double(geometry.pointsPerPixelY))
        let cx = Double(spectrum.width / 2), cy = Double(spectrum.height / 2)
        return spots.filter { $0.spectrumKey == spectrum.key && $0.inMask }.compactMap(\.measured).flatMap { m -> [MaskCircle] in
            let s = m.maskSpot(radius: radius, edge: edge)
            return [MaskCircle(centre: geometry.panePoint(of: ImagePoint(x: cx + s.kx, y: cy + s.ky)), radii: radii, isPartner: false),
                    MaskCircle(centre: geometry.panePoint(of: ImagePoint(x: cx - s.kx, y: cy - s.ky)), radii: radii, isPartner: true)]
        }
    }
}

// MARK: - Markers and the mask, drawn

/// One `Canvas` over the spectrum: the numbered rings of the spots and, while the masked inverse is shown, the mask's
/// circles. No hit testing — the pane's tap resolves the click through `FFTSpotMarkers`.
struct FFTSpectrumMarks: View {
    let analysis: FFTAnalysis
    let spectrum: FFTSpectrumProduct
    let geometry: MarkGeometry

    var body: some View {
        // Read here, so the overlay is told when a spot, the selection, the view or the mask changes.
        let markers = FFTSpotMarkers.markers(analysis.spots, spectrum: spectrum.key, selection: analysis.selection, in: geometry)
        let circles = analysis.sourceView == .maskedInverse
            ? FFTSpotMarkers.maskCircles(analysis.spots, spectrum: spectrum, radius: analysis.maskRadius,
                                         edge: analysis.maskEdge, in: geometry)
            : []
        Canvas { context, size in
            for circle in circles { draw(circle, in: &context) }
            // The rings themselves are taken space: a number never lands on another spot's ring.
            var placed: [CGRect] = markers.map { CGRect(x: $0.point.x - FFTSpotMarkers.ringRadius, y: $0.point.y - FFTSpotMarkers.ringRadius, width: 2 * FFTSpotMarkers.ringRadius, height: 2 * FFTSpotMarkers.ringRadius) }
            for marker in markers.sorted(by: { $0.number < $1.number }) { draw(marker, in: &context, size: size, placed: &placed) }
        }
        .allowsHitTesting(false)
    }

    private func draw(_ circle: FFTSpotMarkers.MaskCircle, in context: inout GraphicsContext) {
        let path = Path(ellipseIn: CGRect(x: circle.centre.x - circle.radii.width, y: circle.centre.y - circle.radii.height,
                                          width: 2 * circle.radii.width, height: 2 * circle.radii.height))
        // The partner dashed, the spot itself solid: the dash carries the difference, the colour never alone.
        let dash: [CGFloat] = circle.isPartner ? [4, 3] : []
        context.stroke(path, with: .color(.black.opacity(0.6)), style: StrokeStyle(lineWidth: 3, dash: dash))
        context.stroke(path, with: .color(.cyan), style: StrokeStyle(lineWidth: 1.25, dash: dash))
    }

    private func draw(_ marker: FFTSpotMarkers.Marker, in context: inout GraphicsContext, size: CGSize, placed: inout [CGRect]) {
        let colour: Color = marker.isSelected ? .accentColor : .yellow
        let line: CGFloat = marker.isSelected ? 2.25 : 1.5
        let r = FFTSpotMarkers.ringRadius
        let ring = Path(ellipseIn: CGRect(x: marker.point.x - r, y: marker.point.y - r, width: 2 * r, height: 2 * r))
        // A refused or pending spot is a dashed ring at the bin clicked; a measured one is solid at its centroid.
        let dash: [CGFloat] = marker.isMeasured ? [] : [3, 2]
        context.stroke(ring, with: .color(.black.opacity(0.6)), style: StrokeStyle(lineWidth: line + 2, dash: dash))
        context.stroke(ring, with: .color(colour), style: StrokeStyle(lineWidth: line, dash: dash))
        let label = context.resolve(Text(verbatim: "\(marker.number)").font(.caption.monospacedDigit().bold()).foregroundStyle(.white))
        let textSize = label.measure(in: CGSize(width: 60, height: 30))
        // The number is placed inside the pane whenever the ring is on it (`labelBox`).
        guard let box = FFTSpotMarkers.labelBox(at: marker.point, textSize: textSize, in: size,
                                                awayFrom: CGPoint(x: size.width / 2, y: size.height / 2), avoiding: placed) else { return }
        placed.append(box)
        context.fill(Path(roundedRect: box, cornerRadius: 3), with: .color(.black.opacity(0.65)))
        context.draw(label, at: CGPoint(x: box.midX, y: box.midY))
    }
}

/// The transform's scale bar. `ScaleBar` is a shared copy that speaks its own unit; the label is set from here so the
/// reciprocal units are said in words (`FFTSpectrumLayout.spokenBar`).
struct FFTSpectrumBar: View {
    let unitsPerPoint: Double
    let label: String

    var body: some View {
        if let spoken = FFTSpectrumLayout.spokenBar(unitsPerPoint: unitsPerPoint, label: label) {
            ScaleBar(unitsPerPoint: unitsPerPoint, unitLabel: label)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(spoken)
        } else {
            ScaleBar(unitsPerPoint: unitsPerPoint, unitLabel: label)
        }
    }
}

/// The footer's trailing slot: why the last click was not measured (refused, or no peak), when it was.
private struct FFTRefusalNote: View {
    let analysis: FFTAnalysis

    var body: some View {
        if let outcome = analysis.spots.last?.outcome, let why = FFTRoomFormat.notMeasured(outcome) {
            Text(why)
                .font(.caption)
                .lineLimit(2)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 4))
                .allowsHitTesting(false)
        }
    }
}

// MARK: - The pane

struct FFTSpectrumImagePane: View {
    let analysis: FFTAnalysis
    /// The room's keys are for the pane pressed last; any press in this pane says it is this one (`FFTPanePress`).
    @Binding var keyPane: FFTKeyPane?
    @State private var zoomModel = PaneZoomModel()
    private var zp: ZoomPan { zoomModel.state }
    /// The picture shown dims once the spectrum asked for has taken longer than `FFTPaneFormat.dimDelay`.
    @State private var isDimmed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let spectrum = analysis.spectrum
        let failure = analysis.spectrumFailure
        let isUpdating = FFTPaneFormat.isUpdating(hasSpectrum: spectrum != nil, isCurrent: analysis.isSpectrumCurrent)
        VStack(spacing: 6) {
            header(spectrum, isUpdating: isUpdating)
            GeometryReader { geometry in
                Group {
                    if let spectrum, failure == nil {
                        content(spectrum, isUpdating: isUpdating, in: geometry.size)
                    } else {
                        unavailable(failure)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(8)
        .clipped()
        .modifier(FFTPanePress(pane: .spectrum, keyPane: $keyPane))
        // Restarts on every change of the flag and cancels with the view; a result that lands within the delay never dims.
        .task(id: isUpdating) { await dim(isUpdating) }
    }

    private func dim(_ updating: Bool) async {
        if updating {
            try? await Task.sleep(for: FFTPaneFormat.dimDelay)
            guard !Task.isCancelled else { return }
        }
        if reduceMotion { isDimmed = updating } else { withAnimation(.easeInOut(duration: 0.15)) { isDimmed = updating } }
    }

    private func resetZoom() {
        if reduceMotion { zoomModel.fit() } else { withAnimation(.snappy) { zoomModel.fit() } }
    }

    // MARK: Header

    /// Single-line on purpose. Three layouts, the first that fits wins: "FFT", what it is of and "Updating…" with its
    /// spinner; the same with the spinner alone; the title and the subject (which truncates). The indicator keeps its
    /// place when it is not shown (opacity, not `if`), so the header never reflows as a result lands.
    private func header(_ spectrum: FFTSpectrumProduct?, isUpdating: Bool) -> some View {
        let subject = spectrum.map { FFTPaneFormat.subject(crop: $0.key.crop, width: $0.width, height: $0.height) }
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                title
                subjectText(subject).fixedSize()
                Spacer(minLength: 8)
                indicator(isUpdating, withWords: true)
            }
            HStack(spacing: 8) {
                title
                subjectText(subject).fixedSize()
                Spacer(minLength: 8)
                indicator(isUpdating, withWords: false)
            }
            HStack(spacing: 8) {
                title
                subjectText(subject).layoutPriority(-1)
                Spacer(minLength: 0)
                indicator(isUpdating, withWords: false)
            }
        }
        .frame(height: LayoutPolicy.paneHeaderHeight)
    }

    private var title: some View {
        Text("FFT").font(.headline).lineLimit(1)
    }

    @ViewBuilder
    private func subjectText(_ subject: String?) -> some View {
        if let subject {
            Text(subject)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    private func indicator(_ isUpdating: Bool, withWords: Bool) -> some View {
        HStack(spacing: 4) {
            if withWords {
                Text(FFTPaneFormat.updating).font(.caption).foregroundStyle(.secondary)
            }
            ProgressView().controlSize(.small)
        }
        .fixedSize()
        .opacity(isUpdating ? 1 : 0)
        .accessibilityHidden(!isUpdating)
    }

    // MARK: Body

    private func unavailable(_ failure: String?) -> some View {
        let words = FFTPaneFormat.missingSpectrum(failure: failure)
        return ContentUnavailableView {
            Label(words.title, systemImage: failure == nil ? "waveform" : "exclamationmark.triangle")
        } description: {
            Text(words.detail)
        } actions: {
            if failure == nil { ProgressView().controlSize(.small) }
        }
        .fftPaneAccessibility(label: "Fourier transform", value: words.title, identifier: "fft.spectrumPane")
    }

    private func content(_ spectrum: FFTSpectrumProduct, isUpdating: Bool, in size: CGSize) -> some View {
        let (box, geometry) = FFTSpectrumLayout.place(spectrum, in: size, zoom: zp.drawZoom, offset: zp.effectiveOffset)
        let window = FFTSpectrumLayout.window(low: analysis.spectrumWindowLow, high: analysis.spectrumWindowHigh,
                                              spectrum: spectrum)
        let bar = FFTSpectrumLayout.bar(for: spectrum, box: box, zoom: zp.drawZoom)
        let canvas = spectrum.canvas
        return ZStack {
            // The picture is drawn BEHIND this layer by the shader (pane-sized and untransformed, as `ImagePane`); the
            // markers are drawn over it through `MarkGeometry`.
            Color.clear
                .frame(width: box.width, height: box.height)
                .background {
                    MetalImageView(
                        pixels: canvas.normalized, width: canvas.width, height: canvas.height,
                        contentVersion: canvas.contentVersion, colormap: .gray,
                        displayLo: window.low, displayHi: window.high, gamma: 1
                    )
                    .displayTransform(geometry.transform)
                    .frame(width: box.width, height: box.height)
                    .opacity(isDimmed ? 0.45 : 1)
                    .allowsHitTesting(false)
                }
                .overlay { FFTSpectrumMarks(analysis: analysis, spectrum: spectrum, geometry: geometry) }
                .clipped()
                .contentShape(Rectangle())
                .border(Color.white.opacity(0.08))
                .zoomPan(zoomModel, box: box)
                .zoomPanWheel(zoomModel, box: box)
                // Simultaneous, so ZoomPan's drag (its 10 pt threshold) still pans.
                .simultaneousGesture(SpatialTapGesture().onEnded { click(at: $0.location, spectrum: spectrum, geometry: geometry) })
                .contextMenu { Button("Reset Zoom") { resetZoom() } }

            PaneFooter {
                FFTSpectrumBar(unitsPerPoint: bar.unitsPerPoint, label: bar.label)
            } trailing: {
                FFTRefusalNote(analysis: analysis)
            }
        }
        .frame(width: box.width, height: box.height)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .fftPaneAccessibility(
            label: "Fourier transform",
            value: FFTPaneFormat.spokenSubject(crop: spectrum.key.crop, width: spectrum.width, height: spectrum.height)
                + (isUpdating ? ", updating" : ""),
            identifier: "fft.spectrumPane")
        .accessibilityHint(ZoomPan.accessibilityHint)
        .zoomPanAccessibilityActions(zoomModel, box: box)
    }

    // MARK: Click and keys

    private func click(at point: CGPoint, spectrum: FFTSpectrumProduct, geometry: MarkGeometry) {
        switch FFTSpotMarkers.click(at: point, spots: analysis.spots, selection: analysis.selection, spectrum: spectrum,
                                    in: geometry) {
        case .select(let id): analysis.selection = id
        case .measure(let row, let col): analysis.measureSpot(row: row, col: col)
        }
    }
}
