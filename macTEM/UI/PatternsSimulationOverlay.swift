//
//  PatternsSimulationOverlay.swift
//  Role: the geometrical Kikuchi simulation over the Patterns room's pattern (docs/sem/design/simulation-overlay.md §2, §4) and its
//        inspector section (§3): the bands' centre lines in the accent colour, each family's {hkl} where the line leaves the pattern,
//        the zone axes as small rings with [uvw]. Drawn through the pane's `MarkGeometry`, so the lines keep their place on the bands
//        at any zoom; redrawn with the solution (the shown position), not with the pattern's pixels. The design puts the layer in the
//        Indexing room's pattern pane and, once a solution exists, the Patterns room's: a dataset whose file carries its orientations
//        (the demo nickel's crystal map) has one already. Presentation only: the numbers are `KikuchiOverlay`'s (TEMCore), the state
//        `EBSDSession`'s (TEMSession).
//

import ShellControls
import ShellInspector
import SwiftUI
import TEMCore
import TEMSession

/// The overlay layer, the pattern pane's size, over the pattern.
struct KikuchiOverlayLayer: View {
    let pattern: KikuchiOverlay.Pattern
    let settings: KikuchiOverlay.Settings
    let geometry: MarkGeometry
    let size: CGSize

    /// A line's ends in pane points.
    private func ends(_ line: GeometricalKikuchiSimulation.Line) -> (CGPoint, CGPoint) {
        (geometry.panePoint(of: ImagePoint(x: line.pixel[0], y: line.pixel[1])),
         geometry.panePoint(of: ImagePoint(x: line.pixel[2], y: line.pixel[3])))
    }

    /// The part of a line inside `rect` (Liang–Barsky), nil when it misses.
    static func clipped(_ a: CGPoint, _ b: CGPoint, to rect: CGRect) -> (CGPoint, CGPoint)? {
        var t0: CGFloat = 0, t1: CGFloat = 1
        let dx = b.x - a.x, dy = b.y - a.y
        for (p, q) in [(-dx, a.x - rect.minX), (dx, rect.maxX - a.x), (-dy, a.y - rect.minY), (dy, rect.maxY - a.y)] {
            if p == 0 {
                if q < 0 { return nil }
            } else {
                let r = q / p
                if p < 0 { t0 = max(t0, r) } else { t1 = min(t1, r) }
                if t0 > t1 { return nil }
            }
        }
        return (CGPoint(x: a.x + t0 * dx, y: a.y + t0 * dy), CGPoint(x: a.x + t1 * dx, y: a.y + t1 * dy))
    }

    var body: some View {
        let rect = CGRect(origin: .zero, size: size)
        let accent = Color.accentColor
        Canvas { context, _ in
            var halo = Path(), lines = Path()
            for line in pattern.simulation.lines {
                let (a, b) = ends(line)
                guard let (p, q) = Self.clipped(a, b, to: rect) else { continue }
                halo.move(to: p); halo.addLine(to: q)
                lines.move(to: p); lines.addLine(to: q)
            }
            context.stroke(halo, with: .color(.black.opacity(0.55)), lineWidth: 2.5)
            context.stroke(lines, with: .color(accent), lineWidth: 1.2)
            if settings.zoneAxes {
                for axis in pattern.simulation.zoneAxes {
                    let c = geometry.panePoint(of: ImagePoint(x: axis.pixel.x, y: axis.pixel.y))
                    guard rect.contains(c) else { continue }
                    let ring = Path(ellipseIn: CGRect(x: c.x - 3, y: c.y - 3, width: 6, height: 6))
                    context.fill(ring, with: .color(.white))
                    context.stroke(ring, with: .color(.black.opacity(0.7)), lineWidth: 1)
                    if settings.labels {
                        context.draw(Text(KikuchiOverlay.millerText(axis.uvw, brackets: "[]")).font(.caption2).foregroundStyle(.white),
                                     at: CGPoint(x: c.x, y: c.y - 5), anchor: .bottom)
                    }
                }
            }
            if settings.labels {
                // Each line's family where it leaves the pattern, held a little inside the edge.
                let inner = rect.insetBy(dx: 14, dy: 8)
                for (line, label) in zip(pattern.simulation.lines, pattern.lineLabels) {
                    let (a, b) = ends(line)
                    guard let (_, q) = Self.clipped(a, b, to: rect) else { continue }
                    let at = CGPoint(x: min(max(q.x, inner.minX), inner.maxX), y: min(max(q.y, inner.minY), inner.maxY))
                    context.draw(Text(label).font(.caption2.weight(.semibold)).foregroundStyle(accent), at: at)
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Kikuchi simulation of \(pattern.phase)")
        .accessibilityChildren {
            ForEach(Array(pattern.lineLabels.enumerated()), id: \.offset) { _, label in
                Text(label).accessibilityIdentifier("patterns.overlay.line")
            }
            if settings.zoneAxes {
                ForEach(Array(pattern.simulation.zoneAxes.enumerated()), id: \.offset) { _, axis in
                    Text(KikuchiOverlay.millerText(axis.uvw, brackets: "[]")).accessibilityIdentifier("patterns.overlay.zoneAxis")
                }
            }
        }
        .accessibilityIdentifier("patterns.pattern.overlay")
    }
}

/// Simulation (simulation-overlay.md §3, closed by default): the overlay on or off, the bands by smallest spacing, zone axes and labels.
struct PatternsSimulationSection: View {
    let session: EBSDSession
    private static let number = FloatingPointFormatStyle<Double>.number.precision(.significantDigits(1...4))

    var body: some View {
        let settings = session.overlaySettings
        InspectorSection("Simulation", startsExpanded: false) {
            SegmentedPicker(label: "Overlay", items: [
                (false, .title("Off", help: "The pattern alone")),
                (true, .title("Geometrical", help: "The Kikuchi bands and zone axes of the orientation at this point (kikuchipy's geometrical simulation)")),
            ], selection: Binding(get: { session.overlayOn }, set: { session.setOverlayOn($0) }))
                .disabled(!session.canOverlay)
                .accessibilityIdentifier("patterns.overlay")
            InspectorRow("Min d") {
                NumericField("Smallest interplanar spacing", value: Binding(get: { settings.minDSpacing }, set: { v in
                    var s = settings; s.minDSpacing = min(max(v, 0.3), 10); session.setOverlaySettings(s)
                }), format: Self.number, unit: "Å")
                    .disabled(!session.overlayOn)
                    .help("Bands of every family the lattice centring allows down to this spacing, one per direction")
                    .accessibilityIdentifier("patterns.overlay.minD")
            }
            InspectorRow("Zone axes") {
                Toggle("Draw the zone axes", isOn: Binding(get: { settings.zoneAxes }, set: { v in var s = settings; s.zoneAxes = v; session.setOverlaySettings(s) }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    .disabled(!session.overlayOn)
                    .accessibilityIdentifier("patterns.overlay.zoneAxes")
            }
            InspectorRow("Labels") {
                Toggle("Label the bands and zone axes", isOn: Binding(get: { settings.labels }, set: { v in var s = settings; s.labels = v; session.setOverlaySettings(s) }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    .disabled(!session.overlayOn)
                    .accessibilityIdentifier("patterns.overlay.labels")
            }
            if !session.canOverlay {
                InspectorNote("This dataset carries no orientations. The overlay draws the solution the file stores at each point.")
            } else if session.overlayOn, case .success(let p)? = session.overlay {
                InspectorNote("\(p.phase): \(p.simulation.lines.count) bands, \(p.simulation.zoneAxes.count) zone axes on this pattern, from the orientation and projection centre the file stores here.")
                    .accessibilityIdentifier("patterns.overlay.summary")
            }
        }
    }
}
