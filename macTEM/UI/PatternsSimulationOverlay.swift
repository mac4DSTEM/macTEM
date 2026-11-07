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
                Text(label).accessibilityIdentifier("patterns.overlay.line")
            }
            if settings.bandWidth {
                ForEach(Array(pattern.simulation.lines.enumerated()), id: \.offset) { k, line in
                    if !line.edges.isEmpty { Text(pattern.lineLabels[k]).accessibilityIdentifier("patterns.overlay.edge") }
                }
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
        let settings = session.overlaySettings
        InspectorSection("Simulation", startsExpanded: false) {
            SegmentedPicker(label: "Overlay", items: [
                (0, .title("Off", help: "The pattern alone")),
                (1, .title("Geometrical", help: "The Kikuchi bands and zone axes of the orientation at this point (kikuchipy's geometrical simulation)")),
                (2, .title("Kinematical", help: "The kinematical simulation of the pattern at this point under the bands, blended over the experimental one")),
            ], selection: Binding(get: { session.overlayOn ? (settings.kinematical ? 2 : 1) : 0 }, set: { v in
                var s = settings; s.kinematical = v == 2; session.setOverlaySettings(s)
                session.setOverlayOn(v != 0)
            }))
                .disabled(!session.canOverlay)
                .accessibilityIdentifier("patterns.overlay")
            if session.overlayOn && settings.kinematical {
                AdjustmentSlider("Blend", value: Binding(get: { settings.blend }, set: { v in var s = settings; s.blend = v; session.setOverlaySettings(s) }),
                                 in: 0...1, format: .number.precision(.fractionLength(2)), defaultValue: 0.5)
                    .accessibilityIdentifier("patterns.overlay.blend")
                if let picture = session.overlayMasterPicture, let image = Self.greyImage(picture.values, width: picture.side, height: picture.side) {
                    InspectorRow("Master") {
                        Image(decorative: image, scale: 1).resizable().interpolation(.medium).aspectRatio(1, contentMode: .fit)
                            .frame(maxWidth: 180)
                            .help("The kinematical master pattern of \(picture.phase), upper hemisphere, stereographic: every band down to Min d at the file's beam energy, each of intensity 1")
                            .accessibilityLabel("Kinematical master pattern of \(picture.phase)")
                            .accessibilityIdentifier("patterns.overlay.master")
                    }
                } else if !session.canDrawBandWidth {
                    InspectorNote("The file states no beam energy, so the Bragg angles of the kinematical simulation are unknown.")
                }
            }
            InspectorRow("Min d") {
                NumericField("Smallest interplanar spacing", value: Binding(get: { settings.minDSpacing }, set: { v in
                    var s = settings; s.minDSpacing = min(max(v, 0.3), 10); session.setOverlaySettings(s)
                }), format: Self.number, unit: "Å")
                    .disabled(!session.overlayOn)
                    .help("Bands of every family the lattice centring allows down to this spacing, one per direction")
                    .accessibilityIdentifier("patterns.overlay.minD")
            }
            InspectorRow("Band width") {
                Toggle("Draw the band edges", isOn: Binding(get: { settings.bandWidth }, set: { v in var s = settings; s.bandWidth = v; session.setOverlaySettings(s) }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    .disabled(!session.overlayOn || !session.canDrawBandWidth)
                    .help(session.canDrawBandWidth ? "The two edges of each band, at the Bragg angle for the file's beam energy"
                                                   : "The file states no beam energy, so the Bragg angles are unknown")
                    .accessibilityIdentifier("patterns.overlay.bandWidth")
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
