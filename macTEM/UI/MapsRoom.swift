//
//  MapsRoom.swift
//  Role: the Maps room's first slice (docs/sem/design/orientation-maps-room.md §3, §6; brief P3-04): the map on the left (the layer the
//        inspector's Maps section picks: IPF-Z, IPF-X, IPF-Y, Phase or a property of the file, one pixel per scan point, a crosshair at the
//        pinned point, the scale bar from the step), on the right the live pattern pane when the map came with its patterns (the Patterns
//        room's own pane, following the same point) or the orientation pane when it did not (the point's unit cell in the sample frame, its
//        IPF colour and Euler angles), and the colour key in the bottom pane (each phase's TSL key for an IPF layer, the phase legend for
//        Phase, the colour bar's range for a property). Presentation only: the pictures and words are `OrientationMaps`' (TEMCore), the
//        state `OrientationMapSession`'s (TEMSession).
//
//  P5-04 completes it: Segment (the toolbar's verb) adds the grain analysis' layers (Grains, KAM, GOS, GND, Schmid factor), the boundaries
//  and the selected grain's outline and slip traces over the map, and the bottom pane's Grains, Pole figures and ODF tabs beside the key
//  (`MapsRoomAnalysis.swift`).
//
//  KEYS: the room's root is the one focusable container (as the Patterns room's): ← → ↑ ↓ step the pinned point by one (⇧ by ten), Space
//  pins the hovered one. A click on the map at 1× pins the point under it.
//

import ShellControls
import ShellLayout
import ShellMetal
import ShellSpectroscopy
import SwiftUI
import UniformTypeIdentifiers
import TEMCore
import TEMSession

struct MapsRoom: View {
    @Environment(AppState.self) private var appState
    @State private var showImporter = false

    private var importTypes: [UTType] { EBSDOpening.readableExtensions.compactMap { UTType(filenameExtension: $0) } }

    /// Whether the map is on the open EBSD dataset's scan (its own map, or an Indexing run on it): then the live pattern pane shows its
    /// patterns at the same point.
    private var patternsDataset: EBSDDataset? {
        guard let dataset = appState.ebsd.dataset, appState.maps.isOnScan(of: dataset) else { return nil }
        return dataset
    }

    private func upper(_ document: OrientationMapSession.Document) -> some View {
        PaneSplit(storageKey: "maps.split", resizeLabel: "Resize the map and the pattern", leadingName: "Map") {
            MapPane(session: appState.maps, state: appState.mapsRoom, patterns: patternsDataset.map { _ in appState.ebsd }, map: document.map,
                    staleness: appState.mapsStaleness)
        } trailing: {
            if let dataset = patternsDataset {
                LivePatternPane(session: appState.ebsd, state: appState.patternsRoom, dataset: dataset)
            } else {
                OrientationPane(session: appState.maps)
            }
        }
    }

    var body: some View {
        let session = appState.maps
        let state = appState.mapsRoom
        Group {
            if session.isOpening {
                VStack(spacing: 12) {
                    ProgressView().progressViewStyle(.linear).frame(maxWidth: EDXLayout.openingBarWidth)
                    Text("Opening orientation map").font(.headline)
                    Button("Stop") { session.stop() }
                        .keyboardShortcut(.cancelAction)
                        .accessibilityIdentifier("maps.opening.stop")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("maps.opening")
            } else if let document = session.document {
                VerticalPaneSplit(storageKey: "maps.lowerSplit", defaultFraction: 0.72, resizeLabel: "Resize the map and the colour key",
                                  topName: "Map and pattern", minimumTop: 160, minimumBottom: LayoutPolicy.mapsKeyPaneMinimum) {
                    upper(document)
                } bottom: {
                    MapsBottomPane(session: session, state: state)
                }
                .id(document.id)
                .modifier(MapsKeyedRoom(session: session, patterns: patternsDataset.map { _ in appState.ebsd }))
            } else {
                ContentUnavailableView {
                    Label("No orientation map open", systemImage: "map")
                } description: {
                    Text("Open an indexed map (.ang, .ctf) or an EBSD pattern file that carries one, or try the demo map from the Help menu.")
                } actions: {
                    Button("Open Orientation Map…") { state.requestImport() }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("maps.openMap")
                }
            }
        }
        .onChange(of: state.importRequest) { showImporter = true }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: importTypes, allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls): if let url = urls.first { appState.open(urls: [url]) }
            case .failure(let error): appState.present(error)
            }
        }
        .fileExporter(isPresented: Binding(get: { state.isExporting }, set: { state.isExporting = $0 }),
                      document: MapsExportFile(data: state.exportData), contentType: state.exportType, defaultFilename: state.exportName) { result in
            switch result {
            case .success(let url):
                appState.statusText = "Exported \(url.lastPathComponent)"
                state.didWrite(to: url)
            case .failure(let error): appState.present(error)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("maps.room")
    }
}

/// The bytes the Maps room's save panel writes: a PNG figure or the grain table's CSV.
struct MapsExportFile: FileDocument {
    static var readableContentTypes: [UTType] { [.png, .commaSeparatedText] }
    var data: Data

    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

// MARK: - The keys

/// The arrows step the pinned point (⇧ ten), Space pins the hovered one; the pattern pane follows when the map has patterns.
private struct MapsKeyedRoom: ViewModifier {
    let session: OrientationMapSession
    let patterns: EBSDSession?

    func body(content: Content) -> some View {
        content
            .focusable()
            .focusEffectDisabled()   // DEVIATION as `FFTKeyedRoom`'s, named there
            .onKeyPress(phases: .down) { press in
                if let step = PatternsKeys.step(key: press.key, modifiers: press.modifiers) {
                    session.step(step.direction, by: step.count)
                    patterns?.pin(session.pinned)
                    return .handled
                }
                if press.key == .space, press.modifiers.isEmpty {
                    session.pinHovered()
                    patterns?.pin(session.pinned)
                    return .handled
                }
                return .ignored
            }
    }
}

// MARK: - The map

/// The shown layer, one pixel per scan point, with the pinned point's crosshair: hovering puts the point's phase, Euler angles and properties
/// in the status line (and the pattern under the pointer in the pattern pane); a click at 1× pins the point.
struct MapPane: View {
    let session: OrientationMapSession
    let state: MapsRoomState
    /// The Patterns room's session when the map came with its patterns: hover and pin follow there too.
    let patterns: EBSDSession?
    let map: CrystalMap
    /// Why the map is stale, when it is an Indexing run the room has moved on from (D-SEM-99).
    var staleness: String? = nil
    @State var zoomModel = PaneZoomModel()
    private var zp: ZoomPan { zoomModel.state }

    var body: some View {
        VStack(spacing: 6) {
            header
            GeometryReader { geometry in
                content(in: geometry.size)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(8)
        .clipped()
    }

    private var header: some View {
        let shape = session.gridShape
        return HStack(spacing: 8) {
            Text(MapsRoomFormat.mapTitle(session.layer, stale: staleness != nil))
                .font(.headline).lineLimit(1)
                .help(staleness ?? "")
                .accessibilityIdentifier("maps.map.title")
            Spacer(minLength: 8)
            if session.isDrawing {
                ProgressView().controlSize(.small).accessibilityLabel("Drawing the map")
            }
            Text(verbatim: "\(shape.columns) × \(shape.rows)")
                .help("Map columns × rows")
                .font(.caption.monospaced()).foregroundStyle(.secondary).fixedSize()
        }
        .frame(height: LayoutPolicy.paneHeaderHeight)
    }

    private func content(in size: CGSize) -> some View {
        let shape = session.gridShape
        let box = LayoutPolicy.fitted(in: size, aspect: CGFloat(max(shape.columns, 1)) / CGFloat(max(shape.rows, 1)))
        let transform = MetalDisplayTransform(paneSize: box, imageBox: box, zoom: zp.drawZoom, offset: zp.effectiveOffset)
        let geometry = MarkGeometry(transform: transform, imageWidth: shape.columns, imageHeight: shape.rows)
        let presentation = session.propertyPresentation
        let notIndexed = session.notIndexedCount
        return ZStack {
            ZStack {
                if let raster = session.raster, raster.rows == shape.rows, raster.columns == shape.columns {
                    if let rgba = session.rasterRGBA {
                        // An IPF or phase map: packed RGBA through the view's RGBA pipeline.
                        MetalImageView(pixels: session.rasterPlane, width: raster.columns, height: raster.rows, contentVersion: session.rasterVersion, rgba: rgba)
                            .displayTransform(transform)
                            .frame(width: box.width, height: box.height)
                            .allowsHitTesting(false)
                    } else if let canvas = presentation.canvas {
                        // A property: the values through the Display section's colormap, window and gamma.
                        MetalImageView(pixels: canvas.normalized, width: canvas.width, height: canvas.height, contentVersion: canvas.contentVersion,
                                       colormap: presentation.colormap, displayLo: presentation.displayFractions.low,
                                       displayHi: presentation.displayFractions.high, gamma: Float(presentation.gamma))
                            .displayTransform(transform)
                            .frame(width: box.width, height: box.height)
                            .allowsHitTesting(false)
                    }
                } else {
                    Rectangle().fill(.quaternary).frame(width: box.width, height: box.height)
                }
                if session.analysis != nil {
                    MapsAnalysisOverlay(session: session, geometry: geometry)
                        .frame(width: box.width, height: box.height)
                        .allowsHitTesting(false)
                        .accessibilityIdentifier("maps.grain.outline")
                }
                ScanMarker(center: geometry.panePoint(of: ImagePoint(x: Double(session.pinned.column), y: Double(session.pinned.row))),
                           pointsPerPixel: geometry.pointsPerPixel)
                    .allowsHitTesting(false)
            }
            .frame(width: box.width, height: box.height)
            .clipped()
            .contentShape(Rectangle())
            .onTapGesture { location in
                let q = geometry.imagePoint(atPanePoint: location)
                let point = EBSDPosition(row: Int(q.y.rounded()), column: Int(q.x.rounded()))
                session.pin(point)
                patterns?.pin(session.pinned)
            }
            .border(Color.white.opacity(0.08))
            .zoomPan(zoomModel, box: box, onHover: { phase in hovered(phase, geometry: geometry) })
            .zoomPanWheel(zoomModel, box: box)
            .zoomCommandTarget(zoomModel, isTarget: true)

            PaneFooter {
                if map.dx > 0 {
                    ScaleBar(unitsPerPoint: ImageScaleBar.unitsPerPoint(perPixel: map.dx, imageWidth: shape.columns, boxWidth: box.width, zoom: zp.drawZoom),
                             unitLabel: EBSDBrowsing.unitLabel(map.scanUnit))
                }
            } trailing: {
                HStack(spacing: 8) {
                    if notIndexed > 0 {
                        Text(verbatim: "\(notIndexed) not indexed").font(.caption.monospacedDigit()).foregroundStyle(.secondary).fixedSize()
                            .accessibilityIdentifier("maps.map.notIndexed")
                    }
                    if let text = ZoomPan.badgeText(zoom: zp.drawZoom), let spoken = ZoomPan.badgeSpoken(zoom: zp.drawZoom) {
                        Text(text).font(.caption.weight(.semibold).monospacedDigit()).foregroundStyle(Color.accentColor).fixedSize()
                            .accessibilityLabel(spoken)
                    }
                }
            }
        }
        .frame(width: box.width, height: box.height)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("maps.map")
        .accessibilityLabel("Orientation map, \(session.layer.title)")
        .accessibilityValue("\(shape.rows) rows by \(shape.columns) columns, pinned at row \(session.pinned.row) column \(session.pinned.column)")
        .accessibilityHint(ZoomPan.accessibilityHint)
    }

    private func hovered(_ phase: HoverPhase, geometry: MarkGeometry) {
        switch phase {
        case .active(let p):
            let q = geometry.imagePoint(atPanePoint: p)
            let point = EBSDPosition(row: Int(q.y.rounded()), column: Int(q.x.rounded()))
            let shape = session.gridShape
            guard point.isInside(rows: shape.rows, columns: shape.columns) else {
                session.hover(nil); patterns?.hover(nil); state.readout = nil; return
            }
            session.hover(point)
            patterns?.hover(point)
            state.readout = session.readout(at: point)
        case .ended:
            session.hover(nil)
            patterns?.hover(nil)
            state.readout = nil
        }
    }
}

// MARK: - The orientation pane

/// For a map without patterns (design §3): the shown point's unit cell in the sample frame seen down z (x to the right, y down, as the
/// map), its IPF colour, phase and Euler angles.
struct OrientationPane: View {
    let session: OrientationMapSession

    var body: some View {
        let point = session.shown
        let found = session.orientation(at: point)
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Text(verbatim: "Orientation · row \(point.row) col \(point.column)" + (session.hovered == nil ? " · pinned" : ""))
                    .font(.headline).lineLimit(1)
                    .accessibilityIdentifier("maps.orientation.title")
                Spacer(minLength: 8)
            }
            .frame(height: LayoutPolicy.paneHeaderHeight)
            if let found {
                let edges = OrientationMaps.unitCellEdges(phase: found.phase, rotation: found.rotation)
                Canvas { context, size in
                    let side = min(size.width, size.height) * 0.42
                    let centre = CGPoint(x: size.width / 2, y: size.height / 2)
                    // Far edges first and fainter, so the cell reads in depth (z into the sample is away from the viewer).
                    for (a, b) in edges.sorted(by: { $0.0.z + $0.1.z > $1.0.z + $1.1.z }) {
                        var path = Path()
                        path.move(to: CGPoint(x: centre.x + a.x * side, y: centre.y + a.y * side))
                        path.addLine(to: CGPoint(x: centre.x + b.x * side, y: centre.y + b.y * side))
                        let depth = (a.z + b.z) / 2
                        context.stroke(path, with: .color(.primary.opacity(depth > 0 ? 0.35 : 0.9)), lineWidth: depth > 0 ? 1 : 2)
                    }
                }
                .accessibilityLabel("Unit cell of \(found.phase.name) in the sample frame")
                .accessibilityIdentifier("maps.orientation.cell")
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color(red: found.rgb.x, green: found.rgb.y, blue: found.rgb.z))
                        .frame(width: LayoutPolicy.mapsColourSwatchSize, height: LayoutPolicy.mapsColourSwatchSize)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: "\(found.phase.name) · \(found.phase.pointGroupName ?? "no point group") · IPF-\(found.direction.rawValue.uppercased())")
                            .font(.callout)
                        Text(verbatim: eulerText(found.euler)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("maps.orientation.values")
            } else {
                Text("No indexed point here").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("maps.orientation")
    }

    private func eulerText(_ e: SIMD3<Double>) -> String {
        let d = e * (180 / Double.pi)
        func f(_ v: Double) -> String { v.formatted(.number.grouping(.never).precision(.fractionLength(1))) + "°" }
        return "φ₁ \(f(d.x))  Φ \(f(d.y))  φ₂ \(f(d.z))"
    }
}

// MARK: - The colour key

/// The bottom pane: what the colours mean. An IPF layer: each indexed phase's TSL key in the stereographic projection with its corners
/// labelled; Phase: each phase's colour, name and point count; a property: its name and range.
struct MapsKeyPane: View {
    let session: OrientationMapSession

    var body: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 20) {
                switch session.layer {
                case .ipf(let direction):
                    if session.keys.isEmpty {
                        Text(session.hasMap ? "No indexed phase with a point group: no colour key" : "")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(session.keys) { key in
                        keyCell(key, direction: direction)
                    }
                case .phase:
                    phaseLegend
                case .property(let name):
                    VStack(alignment: .leading, spacing: 4) {
                        Text(name).font(.headline)
                        if let range = session.raster?.valueRange {
                            Text(verbatim: "\(UnitDisplay.number(range.lowerBound, digits: 4)) to \(UnitDisplay.number(range.upperBound, digits: 4))")
                                .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        Text("Its colormap and window are the Display section's.").font(.caption).foregroundStyle(.secondary)
                    }
                case .derived(.grains):
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Grains").font(.headline)
                        Text(verbatim: session.analysis.map { MapsRoomFormat.grainSummary($0) } ?? "")
                            .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                        Text("Each grain its own colour; grey: regions below the smallest grain; black: not indexed.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                case .derived(let derived):
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: derived.unit.isEmpty ? derived.title : "\(derived.title) (\(derived.unit))").font(.headline)
                        if let range = session.raster?.valueRange {
                            Text(verbatim: "\(UnitDisplay.number(range.lowerBound, digits: 4)) to \(UnitDisplay.number(range.upperBound, digits: 4))")
                                .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        Text(MapsRoomFormat.derivedNote(derived, load: session.loadDirection)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(10)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("maps.key.pane")
    }

    private func keyCell(_ key: OrientationMapSession.PhaseKey, direction: SampleDirection) -> some View {
        let height = LayoutPolicy.mapsKeyWidth * CGFloat(key.image.height) / CGFloat(max(key.image.width, 1))
        return VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: "\(key.name) · \(key.pointGroup) · IPF-\(direction.rawValue.uppercased())").font(.caption).lineLimit(1)
            ZStack(alignment: .topLeading) {
                if let image = MapsFigure.cgImage(premultipliedRGBA: key.image.premultipliedRGBA8, width: key.image.width, height: key.image.height) {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: LayoutPolicy.mapsKeyWidth, height: height)
                }
                ForEach(Array(key.labels.enumerated()), id: \.offset) { _, label in
                    Text(verbatim: label.text)
                        .font(.caption2.monospacedDigit())
                        .fixedSize()
                        .position(x: CGFloat(label.column) * LayoutPolicy.mapsKeyWidth / CGFloat(key.image.width),
                                  y: CGFloat(label.row) * height / CGFloat(key.image.height) + 8)
                }
            }
            .frame(width: LayoutPolicy.mapsKeyWidth, height: height + 16, alignment: .topLeading)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Colour key of \(key.name), IPF-\(direction.rawValue.uppercased())")
        .accessibilityIdentifier("maps.key.\(key.phaseID)")
    }

    private var phaseLegend: some View {
        let map = session.map
        let ids = map?.phaseIDs ?? []
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(map?.phasesInData.entries ?? [], id: \.id) { entry in
                let rgb = entry.phase.colorRGB ?? .zero
                HStack(spacing: 8) {
                    Rectangle().fill(Color(red: rgb.x, green: rgb.y, blue: rgb.z))
                        .frame(width: LayoutPolicy.mapsPhaseSwatchSize, height: LayoutPolicy.mapsPhaseSwatchSize)
                        .overlay(Rectangle().stroke(Color.secondary.opacity(0.5), lineWidth: 0.5))
                    Text(verbatim: "\(MapsRoomFormat.phaseName(entry.phase, id: entry.id)) · \(entry.phase.pointGroupName ?? "—") · \(ids.filter { $0 == entry.id }.count) points")
                        .font(.callout.monospacedDigit())
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("maps.legend.\(entry.id)")
            }
        }
    }
}
