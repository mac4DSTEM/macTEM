//
//  MapsRoomAnalysis.swift
//  Role: what the Maps room shows of its grain analysis and texture (docs/sem/design/orientation-maps-room.md §3-§4, brief P5-04): the
//        boundaries, the selected grain's outline and its slip traces over the map; the bottom pane's tabs (Key, Grains, Pole figures,
//        ODF); and the inspector's Misorientation, Grains, Slip and Texture sections. Presentation only: the numbers are `MapAnalysis` and
//        `MapTexture`'s (TEMCore), the state `OrientationMapSession`'s (TEMSession), the words `MapsRoomFormat`'s.
//

import ShellControls
import ShellInspector
import ShellLayout
import ShellMetal
import SwiftUI
import TEMCore
import TEMSession

// MARK: - The overlay on the map

/// Grain boundaries (white), phase boundaries (black), the selected grain's outline (the accent colour) and its slip traces through its
/// centroid (each plane in DefDAP's trace colour), drawn in the map's own pixel coordinates through the pane's zoom.
struct MapsAnalysisOverlay: View {
    let session: OrientationMapSession
    let geometry: MarkGeometry

    var body: some View {
        Canvas { context, _ in
            if session.showsBoundaries {
                context.stroke(path(session.grainBoundaryEdges), with: .color(.white.opacity(0.9)), lineWidth: LayoutPolicy.mapsBoundaryLineWidth)
                context.stroke(path(session.phaseBoundaryEdges), with: .color(.black), lineWidth: LayoutPolicy.mapsBoundaryLineWidth)
            }
            if !session.selectedOutline.isEmpty {
                context.stroke(path(session.selectedOutline), with: .color(.accentColor), lineWidth: LayoutPolicy.mapsOutlineLineWidth)
            }
            if session.showsSlipTraces, let row = session.selectedRow, let slip = session.selectedSlip {
                let half = max(3, (Double(row.points)).squareRoot() / 2)
                for plane in slip.planes where plane.traceAngle.isFinite {
                    let d = MapsRoomFormat.traceDirection(plane.traceAngle) * half
                    var p = Path()
                    p.move(to: geometry.panePoint(of: ImagePoint(x: row.centroid.x - d.x, y: row.centroid.y - d.y)))
                    p.addLine(to: geometry.panePoint(of: ImagePoint(x: row.centroid.x + d.x, y: row.centroid.y + d.y)))
                    context.stroke(p, with: .color(Self.traceColour(plane.colour)), lineWidth: LayoutPolicy.mapsTraceLineWidth)
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel(spokenLabel)
    }

    /// "Grain 12 outlined, boundaries shown", "3 grains outlined, …", or the boundaries alone.
    private var spokenLabel: String {
        let boundaries = "boundaries " + (session.showsBoundaries ? "shown" : "hidden")
        let count = session.selectedGrains.count
        if count > 1 { return "\(count) grains outlined, " + boundaries }
        if let grain = session.selectedGrain { return "Grain \(grain) outlined, " + boundaries }
        return "Grain " + boundaries
    }

    /// DefDAP's matplotlib trace colour names as colours.
    static func traceColour(_ name: String) -> Color {
        switch name.lowercased() {
        case "blue": .blue
        case "green": .green
        case "red": .red
        case "purple": .purple
        case "orange": .orange
        case "yellow": .yellow
        case "cyan": .cyan
        case "magenta", "m": .pink
        case "white", "w": .white
        case "gray", "grey": .gray
        case "brown": .brown
        default: .black
        }
    }

    private func path(_ edges: [(SIMD2<Double>, SIMD2<Double>)]) -> Path {
        var p = Path()
        for (a, b) in edges {
            p.move(to: geometry.panePoint(of: ImagePoint(x: a.x, y: a.y)))
            p.addLine(to: geometry.panePoint(of: ImagePoint(x: b.x, y: b.y)))
        }
        return p
    }
}

// MARK: - The bottom pane

/// The bottom pane's tabs (design §3): the colour key, the grain table, the pole figures with the IPF density, the ODF sections.
enum MapsBottomTab: String, CaseIterable, Identifiable {
    case key = "Key"
    case grains = "Grains"
    case poleFigures = "Pole figures"
    case odf = "ODF"
    case histogram = "Histogram"
    var id: String { rawValue }
}

struct MapsBottomPane: View {
    let session: OrientationMapSession
    @Bindable var state: MapsRoomState

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Bottom pane", selection: $state.bottomTab) {
                    ForEach(MapsBottomTab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .accessibilityIdentifier("maps.bottom.tabs")
                Spacer(minLength: 8)
                if state.bottomTab == .poleFigures || state.bottomTab == .odf {
                    MapsTexturePhasePicker(session: session)
                }
                if state.bottomTab == .histogram {
                    Picker("Histogram of", selection: $state.histogramKind) {
                        ForEach(MapAnalysis.HistogramKind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .fixedSize()
                    .help("KAM of every point, or GOS or the equivalent circle diameter of every grain")
                    .accessibilityIdentifier("maps.histogram.kind")
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 6)
            .fixedSize(horizontal: false, vertical: true)
            Group {
                switch state.bottomTab {
                case .key: MapsKeyPane(session: session)
                case .grains: MapsGrainsTable(session: session)
                case .poleFigures: MapsTextureFigures(session: session, odf: false)
                case .odf: MapsTextureFigures(session: session, odf: true)
                case .histogram: MapsHistogramPane(session: session, state: state)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)   // science: the figures may be cut
        }
        // The tabs stay at the top of the pane whatever its height: centred, they moved with each tab's content and, with the Output pane
        // open, a figure taller than the pane pushed them out of view (drive 2026-11-08). The minimum height of 0 keeps a tall figure from
        // moving the split; it is cut at its foot instead.
        .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)   // science: no minimum, never a size
        .clipped()
    }
}

struct MapsTexturePhasePicker: View {
    let session: OrientationMapSession

    var body: some View {
        let phases = session.texturePhases
        if phases.count > 1 {
            Picker("Phase", selection: Binding(get: { session.texturePhaseID ?? phases[0].id }, set: { _ = session.showTexture(phaseID: $0) })) {
                ForEach(phases, id: \.id) { Text(MapsRoomFormat.phaseName($0.phase, id: $0.id)).tag($0.id) }
            }
            .fixedSize()
            .help("The phase whose texture the figures show")
            .accessibilityIdentifier("maps.texture.phase")
        }
    }
}

// MARK: The grain table

/// One row per grain (design §3, Grains tab): number, phase, size, equivalent diameter, mean orientation, GOS, neighbours. Selecting a row
/// outlines the grain and pins its point nearest its centroid; pinning a point selects its grain. ⌘C copies the selected rows (⌘A: all) as
/// TSV in the table's order (`GrainTableFormat`, #353); the symbol headers are said in words (`SEMColumnSpeech`, #320).
struct MapsGrainsTable: View {
    let session: OrientationMapSession
    @State private var sortOrder = [KeyPathComparator(\GrainRow.id)]
    @State private var rows: [GrainRow] = []
    @FocusState private var tableFocused: Bool
    @State private var personPicked = false

    var body: some View {
        Group {
            if let analysis = session.analysis {
                let unit = EBSDBrowsing.unitLabel(analysis.scanUnit)
                let places = MapsRoomFormat.lengthPlaces(analysis)
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: MapsRoomFormat.grainSummary(analysis))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        .accessibilityIdentifier("maps.grains.summary")
                    // The person's selection takes the keyboard for the table (#353); a ⌘-click on the map selects grains through the
                    // session and leaves the keys with the map.
                    Table(rows, selection: Binding(get: { session.selectedGrains }, set: { picked in
                        personPicked = true
                        session.selectGrains(picked)
                    }), sortOrder: $sortOrder) {
                        TableColumn("Grain", value: \.id) { Text(verbatim: "\($0.id)").monospacedDigit() }
                        TableColumn("Phase", value: \.phaseName)
                        TableColumn("Points", value: \.points) { Text(verbatim: "\($0.points)").monospacedDigit() }
                        TableColumn(SEMColumnSpeech.header("ECD \(unit)"), value: \.diameter) {
                            Text(MapsRoomFormat.length($0.diameter, places: places)).monospacedDigit()
                        }
                        TableColumn(SEMColumnSpeech.header("φ₁ °"), value: \.phi1) { Text(MapsRoomFormat.angle($0.phi1)).monospacedDigit() }
                        TableColumn(SEMColumnSpeech.header("Φ °"), value: \.capitalPhi) { Text(MapsRoomFormat.angle($0.capitalPhi)).monospacedDigit() }
                        TableColumn(SEMColumnSpeech.header("φ₂ °"), value: \.phi2) { Text(MapsRoomFormat.angle($0.phi2)).monospacedDigit() }
                        TableColumn(SEMColumnSpeech.header("GOS °"), value: \.gosDegrees) {
                            Text(MapsRoomFormat.angle($0.gosDegrees, digits: 2)).monospacedDigit()
                        }
                        TableColumn("Schmid") { row in Text(GrainTableFormat.schmid(row, slip: session.slip)).monospacedDigit() }
                        TableColumn("Neighbours", value: \.neighbours) { Text(verbatim: "\($0.neighbours)").monospacedDigit() }
                    }
                    .focused($tableFocused)
                    .onCopyCommand(perform: session.selectedGrains.isEmpty ? nil : { copied(unit: unit, places: places) })
                    .onChange(of: session.selectedGrains) { _, picked in
                        // As the EELS edges table (294de6a), after the pick a selected grain moves has run its course (`selectGrain` pins
                        // the grain, and the panes follow): set in this turn, the keys went back to the map (drive, 2026-11-11).
                        if personPicked, !picked.isEmpty { Task { @MainActor in tableFocused = true } }
                        personPicked = false
                    }
                    .accessibilityIdentifier("maps.grains.table")
                }
                .padding(10)
            } else {
                Text(session.isSegmenting ? "Segmenting…" : "Segment the map to list its grains.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("maps.grains.empty")
            }
        }
        .onAppear { refresh() }
        .onChange(of: session.analysis?.table.count) { refresh() }
        .onChange(of: session.analysis?.settings) { refresh() }
        .onChange(of: sortOrder) { rows.sort(using: sortOrder) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("maps.grains")
    }

    private func refresh() { rows = (session.analysis?.table ?? []).sorted(using: sortOrder) }

    /// ⌘C: the selected grains as TSV, in the table's order (the sort on screen), under the column titles.
    private func copied(unit: String, places: Int) -> [NSItemProvider] {
        let picked = rows.filter { session.selectedGrains.contains($0.id) }
        guard !picked.isEmpty else { return [] }
        return [NSItemProvider(object: GrainTableFormat.copyText(picked, unit: unit, slip: session.slip, places: places) as NSString)]
    }
}

extension GrainRow {
    var phi1: Double { euler.x }
    var capitalPhi: Double { euler.y }
    var phi2: Double { euler.z }
}

// MARK: The texture figures

/// The pole figures and the IPF-Z density (Pole figures tab), or the ODF's φ₂ sections (ODF tab), of one phase, each in the inferno
/// colormap from 0 to its largest density (multiples of a random distribution), with that maximum under it.
struct MapsTextureFigures: View {
    let session: OrientationMapSession
    let odf: Bool

    var body: some View {
        Group {
            if let texture = session.texture {
                let figures = odf ? texture.odfSections : texture.poleFigures + (texture.inversePoleFigure.map { [$0] } ?? [])
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 16) {
                        let selected = session.selectedRows.filter { $0.phaseID == texture.phaseID }.map(\.orientation)
                        ForEach(Array(figures.enumerated()), id: \.offset) { index, figure in
                            MapsTextureFigureCell(figure: figure, odf: odf, markers: MapTexture.poleMarkers(figure, orientations: selected))
                                .accessibilityIdentifier("maps.\(odf ? "odf" : "pole").\(index)")
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(verbatim: MapsRoomFormat.textureCaption(texture, odf: odf))
                                .font(.caption).foregroundStyle(.secondary)
                                .frame(width: LayoutPolicy.mapsTextureFigureSide, alignment: .leading)
                        }
                    }
                    .padding(10)
                }
            } else if session.isTexturing {
                ProgressView("Computing the texture…").controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Never blank: no phase to make it for, refused and why, or stopped, with the inspector's Compute Texture (macTEM#410).
                let words = MapsRoomFormat.textureUnavailable(stopped: session.textureStopped, failure: session.textureFailure,
                                                              hasPhases: !session.texturePhases.isEmpty)
                ContentUnavailableView {
                    Label(words.title, systemImage: words.systemImage)
                } description: {
                    Text(words.detail)
                }
                .accessibilityIdentifier("maps.texture.empty")
            }
        }
        .task(id: session.fileName) { _ = session.showTexture() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(odf ? "maps.odf" : "maps.poleFigures")
    }
}

struct MapsTextureFigureCell: View {
    let figure: MapTexture.Figure
    let odf: Bool
    /// The selected grains' poles in the figure's unit square (macTEM#239), drawn as rings over the density.
    var markers: [SIMD2<Double>] = []

    var body: some View {
        let side = odf ? LayoutPolicy.mapsODFSectionWidth : LayoutPolicy.mapsTextureFigureSide
        let aspect = CGFloat(figure.raster.height) / CGFloat(max(figure.raster.width, 1))
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: figure.title).font(.caption).lineLimit(1)
            if let image = MapsFigure.textureImage(figure.raster) {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(odf ? .none : .medium)
                    .frame(width: side, height: side * aspect)
                    .overlay(alignment: .topLeading) {
                        if odf {
                            Text(verbatim: "φ₁ →  Φ ↓").font(.caption2).foregroundStyle(.white).padding(2)
                        }
                    }
                    .overlay {
                        if !markers.isEmpty {
                            Canvas { context, size in
                                let r = LayoutPolicy.mapsPoleMarkerRadius
                                for m in markers {
                                    let rect = CGRect(x: m.x * size.width - r, y: m.y * size.height - r, width: 2 * r, height: 2 * r)
                                    context.stroke(Path(ellipseIn: rect), with: .color(.white), lineWidth: 2.5)
                                    context.stroke(Path(ellipseIn: rect), with: .color(.accentColor), lineWidth: 1.5)
                                }
                            }
                            .allowsHitTesting(false)
                        }
                    }
            }
            MapsColourBar()
                .frame(width: side, height: LayoutPolicy.mapsColourBarHeight)
            Text(verbatim: "0 to \(MapsRoomFormat.number(figure.maximum)) MRD").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(figure.title), maximum \(MapsRoomFormat.number(figure.maximum)) multiples of random"
                            + (markers.isEmpty ? "" : ", \(markers.count) poles of the selected grains marked"))
    }
}

// MARK: The histogram

/// The Histogram tab (design §3): KAM per point, GOS or equivalent circle diameter per grain, in 40 bins (`MapAnalysis.histogram`),
/// with each selected grain's value ticked under the bars. Bars in the accent colour, counts on the left, the range under them.
struct MapsHistogramPane: View {
    let session: OrientationMapSession
    let state: MapsRoomState

    var body: some View {
        Group {
            if let analysis = session.analysis {
                let kind = state.histogramKind
                let histogram = analysis.histogram(kind)
                let ticks = session.selectedRows.compactMap { analysis.histogramValue(kind, of: $0) }
                let unit = kind == .grainSize ? EBSDBrowsing.unitLabel(analysis.scanUnit) : "°"
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: MapsRoomFormat.histogramCaption(kind, histogram: histogram, unit: unit))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        .accessibilityIdentifier("maps.histogram.caption")
                    Canvas { context, size in
                        let counts = histogram.counts
                        guard let top = counts.max(), top > 0, let low = histogram.edges.first, let high = histogram.edges.last, high > low else { return }
                        let barArea = CGRect(x: 0, y: 0, width: size.width, height: size.height - LayoutPolicy.mapsHistogramTickHeight)
                        let w = barArea.width / CGFloat(counts.count)
                        for (k, n) in counts.enumerated() where n > 0 {
                            let h = barArea.height * CGFloat(n) / CGFloat(top)
                            context.fill(Path(CGRect(x: CGFloat(k) * w + 0.5, y: barArea.maxY - h, width: max(w - 1, 1), height: h)),
                                         with: .color(.accentColor.opacity(0.8)))
                        }
                        for v in ticks where v.isFinite {
                            let x = CGFloat((min(max(v, low), high) - low) / (high - low)) * barArea.width
                            var p = Path()
                            p.move(to: CGPoint(x: x, y: barArea.maxY))
                            p.addLine(to: CGPoint(x: x, y: size.height))
                            context.stroke(p, with: .color(.primary), lineWidth: 2)
                        }
                    }
                    .accessibilityElement()
                    .accessibilityLabel(MapsRoomFormat.histogramSpoken(kind, histogram: histogram))
                    .accessibilityIdentifier("maps.histogram.bars")
                    HStack {
                        Text(verbatim: "\(MapsRoomFormat.number(histogram.edges.first ?? 0)) \(unit)")
                        Spacer()
                        Text(verbatim: "\(MapsRoomFormat.number(histogram.edges.last ?? 0)) \(unit)")
                    }
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                }
                .padding(10)
            } else {
                Text(session.isSegmenting ? "Segmenting…" : "Segment the map for its KAM, GOS and grain-size histograms.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("maps.histogram")
    }
}

/// The inferno colour bar the texture figures use.
struct MapsColourBar: View {
    var body: some View {
        if let image = MapsFigure.colourBarImage() {
            Image(decorative: image, scale: 1).resizable().interpolation(.medium)
        }
    }
}

// MARK: - Inspector sections

/// Misorientation (design §4): the KAM's neighbour cut-off. The next Segment uses it.
struct MapsMisorientationSection: View {
    let session: OrientationMapSession

    var body: some View {
        InspectorSection("Misorientation") {
            InspectorRow("KAM maximum") {
                OptionalNumericField(title: "KAM maximum", value: session.analysisSettings.kamMaxDegrees, format: MapsRoomFormat.decimal, unit: "°",
                                     prompt: "5") { v in
                    var s = session.analysisSettings; s.kamMaxDegrees = v; session.setAnalysisSettings(s)
                }
                .help("Kernel average misorientation over the first neighbours of the same phase; a neighbour more misoriented than this is left out")
                .accessibilityIdentifier("maps.kamMax")
            }
            InspectorNote("KAM, GOS and GND appear in the Map picker after Segment. GND is DefDAP's Nye-tensor density from the primary phase's structure.")
        }
    }
}

/// Grains (design §4): the boundary angle and the smallest grain, whether the boundaries show, and the summary of the last Segment.
struct MapsGrainsSection: View {
    let session: OrientationMapSession

    var body: some View {
        InspectorSection("Grains") {
            InspectorRow("Boundary") {
                OptionalNumericField(title: "Boundary angle", value: session.analysisSettings.boundaryDegrees, format: MapsRoomFormat.decimal,
                                     unit: "°", prompt: "5") { v in
                    var s = session.analysisSettings; s.boundaryDegrees = v; session.setAnalysisSettings(s)
                }
                .help("Neighbours more misoriented than this are on different grains (DefDAP's find_grains)")
                .accessibilityIdentifier("maps.boundaryAngle")
            }
            InspectorRow("Smallest") {
                OptionalNumericField(title: "Smallest grain", value: Double(session.analysisSettings.minimumSize), format: MapsRoomFormat.whole,
                                     unit: "points", prompt: "10") { v in
                    var s = session.analysisSettings
                    s.minimumSize = v.isFinite ? Int(min(max(v.rounded(), 1), 1e9)) : 10
                    session.setAnalysisSettings(s)
                }
                .help("Regions of fewer points are not grains: they show grey and leave the table")
                .accessibilityIdentifier("maps.minimumSize")
            }
            InspectorRow("Boundaries") {
                Toggle("Show the boundaries", isOn: Binding(get: { session.showsBoundaries }, set: { session.showsBoundaries = $0 }))
                    .toggleStyle(.switch).labelsHidden()
                    .help("Grain boundaries white, phase boundaries black, over the map")
                    .accessibilityIdentifier("maps.showBoundaries")
            }
            if let analysis = session.analysis {
                ForEach(MapsRoomFormat.grainRows(analysis)) { row in
                    InspectorValueRow(row.label, row.value)
                }
                if session.analysisIsStale {
                    InspectorWarning("The settings changed: Segment again to apply them.")
                }
            } else {
                InspectorNote("Segment (the toolbar's verb) finds the grains with these settings.")
            }
        }
    }
}

/// Slip: the load axis and each phase's slip systems; the selected grain's Schmid factors and trace angles.
struct MapsSlipSection: View {
    let session: OrientationMapSession

    var body: some View {
        InspectorSection("Slip") {
            InspectorRow("Load") {
                Picker("Load axis", selection: Binding(get: { session.loadDirection }, set: { session.setLoadDirection($0) })) {
                    ForEach(SampleDirection.allCases, id: \.self) { Text("Sample \($0.rawValue.uppercased())").tag($0) }
                }
                .labelsHidden()
                .help("The uniaxial load the Schmid factors are for, along a sample axis")
                .accessibilityIdentifier("maps.slip.load")
            }
            if let map = session.map {
                ForEach(MapsRoomFormat.indexedPhases(map), id: \.id) { entry in
                    InspectorRow(MapsRoomFormat.phaseName(entry.phase, id: entry.id)) {
                        Picker("Slip systems of \(entry.phase.name)",
                               selection: Binding(get: { session.slipFiles[entry.id] }, set: { session.setSlipFile($0, phaseID: entry.id) })) {
                            Text("None").tag(SlipSystemFile?.none)
                            ForEach(MapsRoomFormat.slipChoices(entry.phase), id: \.self) { Text(MapsRoomFormat.slipTitle($0)).tag(Optional($0)) }
                        }
                        .labelsHidden()
                        .help("DefDAP's slip-system file for this phase")
                        .accessibilityIdentifier("maps.slip.phase.\(entry.id)")
                    }
                }
            }
            InspectorRow("Traces") {
                Toggle("Show the slip traces", isOn: Binding(get: { session.showsSlipTraces }, set: { session.showsSlipTraces = $0 }))
                    .toggleStyle(.switch).labelsHidden()
                    .help("The selected grain's slip-plane traces through its centroid, in DefDAP's colours")
                    .accessibilityIdentifier("maps.slip.traces")
            }
            if let row = session.selectedRow, let slip = session.selectedSlip {
                InspectorValueRow("Grain", "\(row.id) · \(row.phaseName)")
                ForEach(Array(slip.planes.enumerated()), id: \.offset) { _, plane in
                    InspectorValueRow(plane.label, MapsRoomFormat.planeText(plane))
                }
            } else if session.analysis != nil {
                InspectorNote("Pin a point in a grain, or pick a row of the Grains tab, for its Schmid factors and traces.")
            }
        }
    }
}

/// Texture: which phase the Pole figures and ODF tabs show, Compute Texture to make it, and how it is made.
struct MapsTextureSection: View {
    let session: OrientationMapSession

    var body: some View {
        InspectorSection("Texture", startsExpanded: false) {
            let phases = session.texturePhases
            if phases.isEmpty {
                InspectorNote("No indexed phase with a point group.")
            } else {
                InspectorRow("Phase") {
                    Picker("Texture phase", selection: Binding(get: { session.texturePhaseID ?? phases[0].id }, set: { _ = session.showTexture(phaseID: $0) })) {
                        ForEach(phases, id: \.id) { Text(MapsRoomFormat.phaseName($0.phase, id: $0.id)).tag($0.id) }
                    }
                    .labelsHidden()
                    .accessibilityIdentifier("maps.texture.phaseInspector")
                }
                // The in-pane picker exists only with more than one phase, and this one never fires for the phase already picked:
                // after ⌘. the texture is made again here (macTEM#410). One action alone is full width.
                InspectorActionRow {
                    let canCompute = session.canComputeTexture
                    Button("Compute Texture") { _ = session.showTexture() }
                        .disabled(!canCompute)
                        .help(MapsRoomFormat.computeTextureHelp(isTexturing: session.isTexturing, failure: session.textureFailure,
                                                                canCompute: canCompute))
                        .accessibilityIdentifier("maps.texture.compute")
                }
                InspectorNote("Pole figures and the IPF-Z density: orix's pole density function, 1° bins smoothed 5°, upper hemisphere. ODF sections: a de la Vallée Poussin kernel of 10° half-width at 5° nodes.")
            }
        }
    }
}
