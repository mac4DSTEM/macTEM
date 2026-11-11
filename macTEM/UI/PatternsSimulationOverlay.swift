//
//  PatternsSimulationOverlay.swift
//  Role: the geometrical Kikuchi simulation over the Patterns room's pattern (docs/sem/design/simulation-overlay.md §2, §4) and its
//        inspector section (§3): the bands' centre lines in the accent colour, each family's {hkl} where the line leaves the pattern,
//        the zone axes as small rings with [uvw]. Drawn through the pane's `MarkGeometry`, so the lines keep their place on the bands
//        at any zoom; with `Band width`, each band's two edges at ±θ (the Bragg angle for the file's beam energy) as thinner arcs;
//        redrawn with the solution (the shown position), not with the pattern's pixels. The design puts the layer in the
//        Indexing room's pattern pane and, once a solution exists, the Patterns room's: a dataset whose file carries its orientations
//        (the demo nickel's crystal map) has one already. Presentation only: the numbers are `KikuchiOverlay`'s (TEMCore), the state
//        `EBSDSession`'s (TEMSession).
//

import ShellControls
import ShellInspector
import ShellLayout
import SwiftUI
import TEMCore
import TEMSession

/// The overlay layer, the pattern pane's size, over the pattern.
struct KikuchiOverlayLayer: View {
    let pattern: KikuchiOverlay.Pattern
    let settings: KikuchiOverlay.Settings
    let geometry: MarkGeometry
    let size: CGSize
    /// The room's accessibility identifiers.
    var ids = OverlayIdentifiers.patterns

    /// A line's ends in pane points.
    private func ends(_ line: GeometricalKikuchiSimulation.Line) -> (CGPoint, CGPoint) {
        (geometry.panePoint(of: ImagePoint(x: line.pixel[0], y: line.pixel[1])),
         geometry.panePoint(of: ImagePoint(x: line.pixel[2], y: line.pixel[3])))
    }

    /// The kinematical simulation as an 8-bit grey image, its band counts stretched from their least to their most; nil without one.
    static func simulatedImage(_ pattern: KikuchiOverlay.Pattern) -> CGImage? {
        guard let values = pattern.simulated else { return nil }
        return PatternsSimulationSection.greyImage(values.map(Double.init), width: pattern.simulatedColumns, height: pattern.simulatedRows)
    }

    var body: some View {
        let rect = CGRect(origin: .zero, size: size)
        let accent = Color.accentColor
        Canvas { context, _ in
            if settings.kinematical, let simulated = Self.simulatedImage(pattern) {
                // The kinematical simulation under the lines, over the experimental pattern, at the Blend opacity: the detector's
                // pixel corners mapped as the pane maps them, one image pixel per detector pixel without smoothing.
                let a = geometry.panePoint(of: ImagePoint(x: -0.5, y: -0.5))
                let b = geometry.panePoint(of: ImagePoint(x: Double(pattern.simulatedColumns) - 0.5, y: Double(pattern.simulatedRows) - 0.5))
                var layer = context
                layer.opacity = settings.blend
                layer.draw(Image(decorative: simulated, scale: 1).interpolation(.none),
                           in: CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y))
            }
            var halo = Path(), lines = Path()
            for line in pattern.simulation.lines {
                let (a, b) = ends(line)
                guard let (p, q) = KikuchiOverlayExport.clipped(a, b, to: rect) else { continue }
                halo.move(to: p); halo.addLine(to: q)
                lines.move(to: p); lines.addLine(to: q)
            }
            context.stroke(halo, with: .color(.black.opacity(0.55)), lineWidth: 2.5)
            context.stroke(lines, with: .color(accent), lineWidth: 1.2)
            if settings.bandWidth {
                // The band edges: each visible arc of the two small circles at π/2 ∓ θ, thinner than the centre line.
                var edges = Path()
                for line in pattern.simulation.lines {
                    for edge in line.edges {
                        for run in edge.pixelRuns {
                            edges.addLines(run.map { geometry.panePoint(of: ImagePoint(x: $0.x, y: $0.y)) })
                        }
                    }
                }
                var clipped = context
                clipped.clip(to: Path(rect))
                clipped.stroke(edges, with: .color(.black.opacity(0.45)), lineWidth: 1.8)
                clipped.stroke(edges, with: .color(accent.opacity(0.85)), lineWidth: 0.8)
            }
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
                    guard let (_, q) = KikuchiOverlayExport.clipped(a, b, to: rect) else { continue }
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
                Text(label).accessibilityIdentifier(ids.line)
            }
            if settings.bandWidth {
                ForEach(Array(pattern.simulation.lines.enumerated()), id: \.offset) { k, line in
                    if !line.edges.isEmpty { Text(pattern.lineLabels[k]).accessibilityIdentifier(ids.edge) }
                }
            }
            if settings.zoneAxes {
                ForEach(Array(pattern.simulation.zoneAxes.enumerated()), id: \.offset) { _, axis in
                    Text(KikuchiOverlay.millerText(axis.uvw, brackets: "[]")).accessibilityIdentifier(ids.zoneAxis)
                }
            }
        }
        .accessibilityIdentifier(ids.layer)
    }
}

/// Simulation (simulation-overlay.md §3, closed by default): the overlay on or off, the bands by smallest spacing, zone axes and labels.
struct PatternsSimulationSection: View {
    let session: EBSDSession

    /// Row-major values as an 8-bit grey image, stretched from their least to their most; nil for a size that does not match.
    static func greyImage(_ values: [Double], width: Int, height: Int) -> CGImage? {
        guard width > 0, height > 0, values.count == width * height else { return nil }
        let low = values.min() ?? 0, high = values.max() ?? 0
        let span = high > low ? high - low : 1
        let bytes = values.map { UInt8(min(max((($0 - low) / span * 255).rounded(), 0), 255)) }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                       bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    var body: some View {
        let summary: String? = {
            guard session.overlayOn, case .success(let p)? = session.overlay else { return nil }
            return "\(p.phase): \(p.drawnWords) on this pattern, from the orientation and projection centre the file stores here."
        }()
        SimulationOverlayControls(ids: .patterns, isOn: session.overlayOn, setOn: { session.setOverlayOn($0) },
                                  settings: session.overlaySettings, setSettings: { session.setOverlaySettings($0) },
                                  canOverlay: session.canOverlay, canDrawBandWidth: session.canDrawBandWidth,
                                  masterPicture: session.overlayMasterPicture,
                                  unavailable: "This dataset carries no orientations. The overlay draws the solution the file stores at each point.",
                                  summary: summary)
    }
}

/// The Simulation section's controls (simulation-overlay.md §3) for a room's overlay: its own on or off, and the settings both rooms share
/// (Min d, Band width, Zone axes, Labels, Kinematical and Blend). `ids` are the room's accessibility identifiers.
struct SimulationOverlayControls: View {
    let ids: OverlayIdentifiers
    let isOn: Bool
    let setOn: (Bool) -> Void
    let settings: KikuchiOverlay.Settings
    let setSettings: (KikuchiOverlay.Settings) -> Void
    let canOverlay: Bool
    let canDrawBandWidth: Bool
    let masterPicture: (side: Int, values: [Double], phase: String)?
    /// The note while there is nothing to draw on.
    let unavailable: String
    /// The note under the controls while the overlay is drawn.
    let summary: String?
    private static let number = Num.decimalField

    var body: some View {
        InspectorSection("Simulation", startsExpanded: false) {
            SegmentedPicker(label: "Overlay", items: [
                (0, .title("Off", help: "The pattern alone")),
                (1, .title("Geometrical", help: "The Kikuchi bands and zone axes of the orientation at this point (kikuchipy's geometrical simulation)")),
                (2, .title("Kinematical", help: "The kinematical simulation of the pattern at this point under the bands, blended over the experimental one")),
            ], selection: Binding(get: { isOn ? (settings.kinematical ? 2 : 1) : 0 }, set: { v in
                var s = settings; s.kinematical = v == 2; setSettings(s)
                setOn(v != 0)
            }))
                .disabled(!canOverlay)
                .accessibilityIdentifier(ids.picker)
            if isOn && settings.kinematical {
                AdjustmentSlider("Blend", value: Binding(get: { settings.blend }, set: { v in var s = settings; s.blend = v; setSettings(s) }),
                                 in: 0...1, format: .number.precision(.fractionLength(2)), defaultValue: 0.5)
                    .accessibilityIdentifier(ids.blend)
                if let picture = masterPicture, let image = PatternsSimulationSection.greyImage(picture.values, width: picture.side, height: picture.side) {
                    InspectorRow("Master") {
                        Image(decorative: image, scale: 1).resizable().interpolation(.medium).aspectRatio(1, contentMode: .fit)
                            .frame(maxWidth: LayoutPolicy.overlayMasterPictureWidth)
                            .help("The kinematical master pattern of \(picture.phase), upper hemisphere, stereographic: every band down to Min d at the file's beam energy, each of intensity 1")
                            .accessibilityLabel("Kinematical master pattern of \(picture.phase)")
                            .accessibilityIdentifier(ids.master)
                    }
                } else if !canDrawBandWidth {
                    InspectorNote("The file states no beam energy, so the Bragg angles of the kinematical simulation are unknown.")
                }
            }
            InspectorRow("Min d") {
                NumericField("Smallest interplanar spacing", value: Binding(get: { settings.minDSpacing }, set: { v in
                    var s = settings; s.minDSpacing = min(max(v, 0.3), 10); setSettings(s)
                }), format: Self.number, unit: "Å")
                    .disabled(!isOn)
                    .help("Bands of every family the lattice centring allows down to this spacing, one per direction")
                    .accessibilityIdentifier(ids.minD)
            }
            InspectorRow("Band width") {
                Toggle("Draw the band edges", isOn: Binding(get: { settings.bandWidth }, set: { v in var s = settings; s.bandWidth = v; setSettings(s) }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    .disabled(!isOn || !canDrawBandWidth)
                    .help(canDrawBandWidth ? "The two edges of each band, at the Bragg angle for the file's beam energy"
                                           : "The file states no beam energy, so the Bragg angles are unknown")
                    .accessibilityIdentifier(ids.bandWidth)
            }
            InspectorRow("Zone axes") {
                Toggle("Draw the zone axes", isOn: Binding(get: { settings.zoneAxes }, set: { v in var s = settings; s.zoneAxes = v; setSettings(s) }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    .disabled(!isOn)
                    .accessibilityIdentifier(ids.zoneAxes)
            }
            InspectorRow("Labels") {
                Toggle("Label the bands and zone axes", isOn: Binding(get: { settings.labels }, set: { v in var s = settings; s.labels = v; setSettings(s) }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    .disabled(!isOn)
                    .accessibilityIdentifier(ids.labels)
            }
            if !canOverlay {
                InspectorNote(unavailable)
            } else if let summary {
                InspectorNote(summary)
                    .accessibilityIdentifier(ids.summary)
            }
        }
    }
}

/// The overlay's accessibility identifiers in one room, written out so the journeys' identifier check finds each one.
struct OverlayIdentifiers {
    let picker, blend, master, minD, bandWidth, zoneAxes, labels, summary, layer, line, edge, zoneAxis: String
    static let patterns = OverlayIdentifiers(
        picker: "patterns.overlay",
        blend: "patterns.overlay.blend",
        master: "patterns.overlay.master",
        minD: "patterns.overlay.minD",
        bandWidth: "patterns.overlay.bandWidth",
        zoneAxes: "patterns.overlay.zoneAxes",
        labels: "patterns.overlay.labels",
        summary: "patterns.overlay.summary",
        layer: "patterns.pattern.overlay",
        line: "patterns.overlay.line",
        edge: "patterns.overlay.edge",
        zoneAxis: "patterns.overlay.zoneAxis")
    static let indexing = OverlayIdentifiers(
        picker: "indexing.overlay",
        blend: "indexing.overlay.blend",
        master: "indexing.overlay.master",
        minD: "indexing.overlay.minD",
        bandWidth: "indexing.overlay.bandWidth",
        zoneAxes: "indexing.overlay.zoneAxes",
        labels: "indexing.overlay.labels",
        summary: "indexing.overlay.summary",
        layer: "indexing.pattern.overlay",
        line: "indexing.overlay.line",
        edge: "indexing.overlay.edge",
        zoneAxis: "indexing.overlay.zoneAxis")
}
