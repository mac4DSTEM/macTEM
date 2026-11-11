//
//  IndexingRoom.swift
//  Role: the Indexing room (docs/sem/design/indexing-room.md §3): the indexed map on the left (the result on the layer `Display › Map`
//        picks, one pixel per scan point: an orientation or phase layer over the Patterns room's mean map dimmed until a point is
//        reached, a scalar layer through the Map Display's colormap, window and gamma; the picked position's marker; the layer's
//        legend in the footer beside the scale bar: the IPF key, the Euler key's ranges, the phases or the colour bar, D-SEM-96) and the
//        pattern pane on the right (the pattern at the picked position as the indexer sees it, with its detected bands: the ones the
//        solution matched solid green and labelled with their family, the others dashed orange). Under them the Results table (one row per point reached; a single row selected picks the pattern, ⌘C copies the
//        selected rows as TSV) beside, for a Hough result, the Bands table of the pattern on screen (pyEBSDindex's band list: ρ, θ,
//        peak, width, the family and the fit) or, for a dictionary result, the Best match pane (the point's best orientation simulated
//        from the master pattern, its score). While `Display › Compare` is on, Compare takes the tables' place: two results side by
//        side on one zoom and their disorientation histogram (`IndexingCompare.swift`, D-SEM-97). The map shows the run in flight, else
//        the last run of the method picked, and its title names the method. The phases, the method's settings and the exports are
//        the inspector's (`IndexingRoomInspector.swift`). Presentation only: every number is `HoughIndexer`'s, `DictionaryIndexing`'s or
//        `IndexingComparison`'s (TEMCore) through `IndexingSession` (TEMSession).
//
//  PICK AND KEYS: as the Patterns room (`SEMMapPick.swift`, D-SEM-110): a click or a drag on the map, or on a compared map, picks the
//  point under it and the pattern pane follows (zoomed in, the marker's handle); the pointer over a map only writes the status line;
//  ← → ↑ ↓ step the pick by one (⇧ by ten, `PatternsKeys`), and a press on a map takes the keyboard back from the Results table. The
//  picked position is the Patterns room's: the two rooms share one marker. In the Results and Bands tables, ⌘A selects every row and ⌘C
//  copies the selected ones (Copy is off with none selected); the tables' symbol headers are said in words (`SEMColumnSpeech`).
//

import CoreGraphics
import ShellControls
import ShellLayout
import ShellMetal
import ShellSpectroscopy
import SwiftUI
import UniformTypeIdentifiers
import TEMCore
import TEMSession

struct IndexingRoom: View {
    @Environment(AppState.self) private var appState
    @State private var showImporter = false

    private var importTypes: [UTType] { EBSDOpening.readableExtensions.compactMap { UTType(filenameExtension: $0) } }

    var body: some View {
        let session = appState.indexing
        let state = appState.indexingRoom
        Group {
            if session.patterns.isOpening {
                VStack(spacing: 12) {
                    ProgressView().progressViewStyle(.linear).frame(maxWidth: EDXLayout.openingBarWidth)
                        .accessibilityLabel("Opening dataset")
                    Text("Opening dataset").font(.headline)
                    Button("Stop") { session.patterns.stop() }
                        .keyboardShortcut(.cancelAction)
                        .accessibilityIdentifier("indexing.opening.stop")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("indexing.opening")
            } else if let document = session.patterns.document {
                VerticalPaneSplit(storageKey: "indexing.lowerSplit", defaultFraction: 0.66, resizeLabel: "Resize the panes and the tables",
                                  topName: "Indexed map and pattern", minimumTop: 160, minimumBottom: 120) {
                    PaneSplit(storageKey: "indexing.split", resizeLabel: "Resize the indexed map and the pattern", leadingName: "Indexed map") {
                        IndexingMapPane(session: session, state: state, dataset: document.dataset)
                    } trailing: {
                        IndexedPatternPane(session: session, dataset: document.dataset)
                    }
                } bottom: {
                    if session.showsCompare {
                        IndexingComparePane(session: session, state: state, dataset: document.dataset)
                    } else {
                        PaneSplit(storageKey: "indexing.tablesSplit", resizeLabel: "Resize the results and the bands", leadingName: "Results") {
                            IndexingResultsTable(session: session, dataset: document.dataset)
                        } trailing: {
                            if (session.result?.method ?? session.method) == .dictionary {
                                IndexingBestMatchPane(session: session)
                            } else {
                                IndexingBandsTable(session: session)
                            }
                        }
                    }
                }
                .id(document.fileName)
                .modifier(IndexingKeyedRoom(session: session))
                // The map's backdrop is the Patterns room's mean map, which lands after the open; the pattern follows the Patterns
                // room's processing (and the shared marker, in `IndexingKeyedRoom`).
                .onChange(of: session.patterns.meanIntensities == nil, initial: true) {
                    session.refreshMap()
                    session.refreshComparison()
                }
                .onChange(of: session.patterns.pipeline) { session.showPattern() }
                .onChange(of: session.patterns.processedWith) { session.showPattern() }
                .onAppear { session.showPattern() }
            } else {
                ContentUnavailableView {
                    Label("No EBSD dataset open", systemImage: "scope")
                } description: {
                    Text("Open an h5ebsd pattern file to index its scan, or try the nickel scan from the Help menu's demo data.")
                } actions: {
                    Button("Open EBSD Dataset…") { showImporter = true }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("indexing.openDataset")
                }
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: importTypes, allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls): if let url = urls.first { appState.open(urls: [url]) }
            case .failure(let error): appState.present(error)
            }
        }
        .fileExporter(isPresented: Binding(get: { state.exporting != nil }, set: { if !$0 { state.exporting = nil } }),
                      document: IndexingExportFile(data: state.exportData),
                      contentType: state.exporting?.contentType ?? .json,
                      defaultFilename: (session.patterns.fileName as NSString).deletingPathExtension + (state.exporting?.suffix(layer: state.exportLayer) ?? "")) { result in
            switch result {
            case .success(let url):
                appState.statusText = "Exported \(url.lastPathComponent)"
                state.didWrite(to: url)
            case .failure(let error): appState.present(error)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("indexing.room")
    }
}

/// A file the save panel writes: the bytes `IndexingRoomState.export` made (the map PNG, the results CSV or the method JSON).
struct IndexingExportFile: FileDocument {
    static var readableContentTypes: [UTType] { [.png, .json, .commaSeparatedText] + [IndexingExportKind.ang, .ctf].map { $0.contentType } }
    var data: Data

    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

// MARK: - The keys

/// The arrows step the picked position (⇧ ten): the Patterns room's keys (`PatternsKeys`), on the room's one focusable container (`SEMRoomFocus`).
/// The pattern pane follows the pick however it moved (`IndexingSession.pin` and `step` show it already; `showPattern` asks again only for
/// a point it does not show): here, not on the room's root, so a drag's stream of picks does not run the room's body.
private struct IndexingKeyedRoom: ViewModifier {
    let session: IndexingSession

    func body(content: Content) -> some View {
        content
            .modifier(SEMRoomFocus())
            .onKeyPress(phases: .down) { press in
                guard let step = PatternsKeys.step(key: press.key, modifiers: press.modifiers) else { return .ignored }
                session.step(step.direction, by: step.count)
                return .handled
            }
            .onChange(of: session.patterns.pinned) { session.showPattern() }
    }
}

// MARK: - The indexed map

/// The result on its layer, one pixel per scan point, growing row by row while Index runs; before a run the mean map dimmed, with the
/// one sentence that says what fills it. A click or a drag picks the point and the pattern pane follows; hovering it only puts the point's
/// solution in the status line.
struct IndexingMapPane: View {
    let session: IndexingSession
    let state: IndexingRoomState
    let dataset: EBSDDataset
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
        // Any press on the pane gives the room the keyboard (from the Results table too); an ancestor of the map's gestures, so it takes none.
        .modifier(SEMMapPress())
    }

    /// "Indexed map · Hough · IPF-Z" ("Dictionary · Refined" for a refinement, D-SEM-109), with "· stale" once the inputs changed
    /// since the run (design §6).
    private var title: String {
        guard let result = session.result else { return "Scan map · mean intensity, not indexed" }
        return "Indexed map · \(session.shownRun?.title ?? result.method.title) · \(session.layer.title)" + (session.isStale ? " · stale" : "")
    }

    /// "4120 of 4125 indexed", "1875 of 4125 reached" while it runs (a dictionary run's chunk first, and the phase matching when it
    /// runs against several, D-SEM-98; "450 of 4125 refined" while Refine runs), "stopped at row 12 of 55"; the counts never grouped
    /// (`IndexingInfoFormat.count`).
    private var count: String? {
        guard let result = session.result else { return nil }
        let n = { (v: Int) in IndexingInfoFormat.count(v) }
        if session.isRefining { return "\(n(result.reachedCount)) of \(n(result.pointCount)) refined" }
        if session.isIndexing, result.method == .dictionary {
            let phase = session.chunkPhase.map { " · \($0)" } ?? ""
            return "chunk \(session.chunksDone) of \(session.chunksTotal)\(phase) · \(n(result.reachedCount)) of \(n(result.pointCount)) reached"
        }
        if session.isIndexing { return "\(n(result.reachedCount)) of \(n(result.pointCount)) reached" }
        if session.wasStopped { return "stopped at row \(result.rowsDone) of \(result.scanRows) · \(n(result.indexedCount)) indexed" }
        return "\(IndexingInfoFormat.indexed(result)) indexed"
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.headline).lineLimit(1)
                .accessibilityIdentifier("indexing.map.title")
            Spacer(minLength: 8)
            if session.isIndexing {
                ProgressView(value: session.progress).progressViewStyle(.linear).frame(width: LayoutPolicy.paneHeaderProgressWidth)
                    .accessibilityLabel("Indexing the scan")
                    .accessibilityIdentifier("indexing.map.progress")
            }
            if let count {
                Text(count)
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
                    .accessibilityIdentifier("indexing.map.count")
            }
            Text(verbatim: "\(dataset.scanColumns) × \(dataset.scanRows)")
                .help("Scan columns × rows")
                .font(.caption.monospaced()).foregroundStyle(.secondary).fixedSize()
        }
        .frame(height: LayoutPolicy.paneHeaderHeight)
    }

    private func content(in size: CGSize) -> some View {
        let box = LayoutPolicy.fitted(in: size, aspect: CGFloat(dataset.scanColumns) / CGFloat(dataset.scanRows))
        let transform = MetalDisplayTransform(paneSize: box, imageBox: box, zoom: zp.drawZoom, offset: zp.effectiveOffset)
        let geometry = MarkGeometry(transform: transform, imageWidth: dataset.scanColumns, imageHeight: dataset.scanRows)
        let mode = SEMMapPointer.mode(zoom: zp.effectiveZoom)
        let points = dataset.scanRows * dataset.scanColumns
        let presentation = session.mapPresentation
        return ZStack {
            ZStack {
                if session.showsScalarMap, let canvas = presentation.canvas, canvas.width == dataset.scanColumns, canvas.height == dataset.scanRows {
                    // A scalar layer's values through the Map Display (colormap, window, gamma), as the Patterns room's map.
                    MetalImageView(pixels: canvas.normalized, width: canvas.width, height: canvas.height, contentVersion: canvas.contentVersion,
                                   colormap: presentation.colormap, displayLo: presentation.displayFractions.low,
                                   displayHi: presentation.displayFractions.high, gamma: Float(presentation.gamma))
                        .displayTransform(transform)
                        .frame(width: box.width, height: box.height)
                        .allowsHitTesting(false)
                } else if let rgba = session.mapRGBA, rgba.count == points * 4 {
                    // The map as packed RGBA (orix's colours, `IndexingRaster`) through the view's RGBA pipeline.
                    MetalImageView(pixels: [Float](repeating: 0, count: points), width: dataset.scanColumns, height: dataset.scanRows,
                                   contentVersion: session.mapVersion, rgba: rgba)
                        .displayTransform(transform)
                        .frame(width: box.width, height: box.height)
                        .allowsHitTesting(false)
                } else {
                    Rectangle().fill(.quaternary).frame(width: box.width, height: box.height)
                }
                // At 1× and below a click or a drag anywhere picks; zoomed in the drag is the pane's pan.
                if mode == .scrub {
                    SEMMapScrubLayer(geometry: geometry, zoomModel: zoomModel) { session.pin($0) }
                }
                SEMScanMarker(position: session.patterns.pinned, geometry: geometry, isHandle: mode == .panAndGrab, identifier: "indexing.map.marker",
                              pick: { session.pin($0) }, step: { session.step($0) })
            }
            .frame(width: box.width, height: box.height)
            .coordinateSpace(.named(SEMMapPointer.space))
            .clipped()
            .contentShape(Rectangle())
            .border(Color.white.opacity(0.08))
            .zoomPan(zoomModel, box: box, onHover: { phase in hovered(phase, geometry: geometry) })
            .zoomPanWheel(zoomModel, box: box)
            .zoomCommandTarget(zoomModel, isTarget: true)

            if session.result == nil {
                // The empty state: the one verb that fills the map (design §3).
                Text("Index to see the orientations")
                    .font(.title3).foregroundStyle(.secondary)
                    .allowsHitTesting(false)
                    .accessibilityIdentifier("indexing.map.empty")
            }

            PaneFooter {
                // The Map Display's switch hides the bar on a scalar layer; the orientation layers always carry it.
                let hidden = session.showsScalarMap && !presentation.showsScaleBar
                ScaleBar(unitsPerPoint: ImageScaleBar.unitsPerPoint(perPixel: dataset.stepX, imageWidth: dataset.scanColumns, boxWidth: box.width, zoom: zp.drawZoom),
                         unitLabel: EBSDBrowsing.unitLabel(dataset.scanUnit))
                    .opacity(hidden ? 0 : 1)
                    .accessibilityHidden(hidden)
            } trailing: {
                HStack(alignment: .bottom, spacing: 8) {
                    if session.result != nil { IndexingLegend(session: session) }
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
        .accessibilityIdentifier("indexing.map")
        .accessibilityLabel("Indexed map")
        .accessibilityValue(title + (count.map { ", " + $0 } ?? ""))
        .accessibilityHint(ZoomPan.accessibilityHint)
    }

    /// The status line's readout of the point under the pointer (its solution): hovering reads, it never moves the pattern (D-SEM-110).
    private func hovered(_ phase: HoverPhase, geometry: MarkGeometry) {
        switch phase {
        case .active(let p) where SEMMapPointer.isOnImage(p, geometry: geometry):
            state.readout = session.readout(at: SEMMapPointer.position(at: p, geometry: geometry))
        case .active, .ended:
            state.readout = nil
        }
    }
}

// MARK: - The legend

/// The map's key in the footer (design §3, D-SEM-96): the IPF colour key of each point group for an IPF layer, the Euler key's angle
/// ranges for Euler, the phases' colours for the Phase layer, the colour bar of the Map Display's colormap and window for a scalar
/// layer, with what its grey stands for.
private struct IndexingLegend: View {
    let session: IndexingSession

    var body: some View {
        if session.showsScalarMap, let result = session.result {
            scalarKey(result)
        } else {
            pointwiseKey
                .padding(4)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
                .accessibilityIdentifier("indexing.map.legend")
        }
    }

    /// The colour bar (ShellControls', on its own plate) over the window's two ends in the layer's raw values, and the masked grey's
    /// words.
    @ViewBuilder private func scalarKey(_ result: IndexingResult) -> some View {
        let presentation = session.mapPresentation
        if let range = presentation.canvas?.rawRange {
            let span = Double(range.upperBound - range.lowerBound)
            let fractions = presentation.displayFractions
            let masked = IndexingRaster.maskedWords(result, layer: session.layer)
            VStack(alignment: .trailing, spacing: 3) {
                Colorbar(colormap: presentation.colormap, low: Double(range.lowerBound) + Double(fractions.low) * span,
                         high: Double(range.lowerBound) + Double(fractions.high) * span, unitLabel: result.scalarTitle(session.layer),
                         gamma: Float(presentation.gamma))
                    .allowsHitTesting(false)
                if let masked {
                    Text(masked)
                        .font(.caption2).foregroundStyle(.secondary)
                        .padding(4)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
                        .accessibilityLabel(masked.replacingOccurrences(of: "grey:", with: "grey marks points"))
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("indexing.map.legend")
        } else {
            Text("\(result.scalarTitle(session.layer)): no point has a value")
                .font(.caption2).foregroundStyle(.secondary)
                .padding(4)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
                .accessibilityIdentifier("indexing.map.legend")
        }
    }

    @ViewBuilder private var pointwiseKey: some View {
        let phases = session.result?.phases ?? []
        let groups = phases.compactMap(\.pointGroupName).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        Group {
            if session.layer.direction != nil {
                IndexingIPFKey(session: session, layer: session.layer, groups: groups)
            } else if session.layer == .euler {
                // orix's Euler key has no picture: each angle's range in its channel, per point group.
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(groups, id: \.self) { name in
                        if let group = PointGroup.named(name) {
                            let words = IndexingColorKey.eulerWords(group)
                            Text(verbatim: groups.count > 1 ? "Euler · \(name) · \(words)" : "Euler · \(words)")
                                .font(.caption2.monospacedDigit())
                        }
                    }
                }
                .accessibilityElement(children: .combine)
            } else if session.layer == .phase {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(phases) { phase in
                        HStack(spacing: 4) {
                            Circle().fill(Color(red: phase.colorRGB.x, green: phase.colorRGB.y, blue: phase.colorRGB.z))
                                .frame(width: LayoutPolicy.regionSwatchSize, height: LayoutPolicy.regionSwatchSize)
                            Text(phase.name).font(.caption2)
                        }
                    }
                    HStack(spacing: 4) {
                        Circle().fill(Color.black).overlay(Circle().stroke(Color.secondary, lineWidth: 0.5))
                            .frame(width: LayoutPolicy.regionSwatchSize, height: LayoutPolicy.regionSwatchSize)
                        Text("not indexed").font(.caption2)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

/// The IPF colour key of each of `groups` (orix point group names) on IPF layer `layer`, side by side, each named when there are
/// several: the indexed map's legend and Compare's.
struct IndexingIPFKey: View {
    let session: IndexingSession
    let layer: IndexingLayer
    let groups: [String]

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            ForEach(groups, id: \.self) { name in
                if let key = session.keyImages[name], let image = IPFKeyPicture.cgImage(key) {
                    VStack(spacing: 2) {
                        Image(decorative: image, scale: 1).resizable().interpolation(.medium).aspectRatio(contentMode: .fit)
                            .frame(height: LayoutPolicy.indexingKeyHeight)
                        Text(groups.count > 1 ? "\(layer.title) · \(name)" : layer.title)
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(layer.title) colour key of point group \(groups.joined(separator: ", "))")
    }
}

/// The IPF key as a picture: its premultiplied RGBA (transparent outside the sector) as a `CGImage`.
nonisolated enum IPFKeyPicture {
    static func cgImage(_ key: IPFKeyImage) -> CGImage? {
        guard key.width > 0, key.height > 0, let provider = CGDataProvider(data: Data(key.premultipliedRGBA8) as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(width: key.width, height: key.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: key.width * 4, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider, decode: nil,
                       shouldInterpolate: true, intent: .defaultIntent)
    }
}

// MARK: - The pattern pane

/// The pattern at the picked position as the indexer reads it, with its detected bands drawn over it.
struct IndexedPatternPane: View {
    let session: IndexingSession
    let dataset: EBSDDataset
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

    private var title: String {
        guard let position = session.patternPosition else { return "Pattern" }
        return EBSDBrowsing.patternTitle(position) + " · as indexed"
    }

    private var rows: Int { session.patternShape.rows > 0 ? session.patternShape.rows : dataset.patternRows }
    private var columns: Int { session.patternShape.columns > 0 ? session.patternShape.columns : dataset.patternColumns }

    private var header: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.headline).lineLimit(1)
                .accessibilityIdentifier("indexing.pattern.title")
            Spacer(minLength: 8)
            if let why = session.patternFailure {
                Text(why).font(.caption).foregroundStyle(.secondary).lineLimit(1).help(why)
            }
            Text(verbatim: "\(columns) × \(rows)")
                .help("Pattern columns × rows as indexed, in detector pixels")
                .font(.caption.monospaced()).foregroundStyle(.secondary).fixedSize()
        }
        .frame(height: LayoutPolicy.paneHeaderHeight)
    }

    private func content(in size: CGSize) -> some View {
        let box = LayoutPolicy.fitted(in: size, aspect: CGFloat(columns) / CGFloat(rows))
        let presentation = session.patternPresentation
        let transform = MetalDisplayTransform(paneSize: box, imageBox: box, zoom: zp.drawZoom, offset: zp.effectiveOffset)
        let geometry = MarkGeometry(transform: transform, imageWidth: columns, imageHeight: rows)
        return ZStack {
            Group {
                if let canvas = presentation.canvas {
                    MetalImageView(pixels: canvas.normalized, width: canvas.width, height: canvas.height, contentVersion: canvas.contentVersion,
                                   colormap: presentation.colormap, displayLo: presentation.displayFractions.low,
                                   displayHi: presentation.displayFractions.high, gamma: Float(presentation.gamma))
                        .displayTransform(transform)
                        .allowsHitTesting(false)
                } else {
                    Rectangle().fill(.quaternary)
                }
                // The Kikuchi simulation of the run's solution here, under the detected bands (IndexingSimulationOverlay.swift).
                if case .success(let overlay)? = session.simulationOverlay {
                    KikuchiOverlayLayer(pattern: overlay, settings: session.patterns.overlaySettings, geometry: geometry, size: box, ids: .indexing)
                }
                if session.showsDetectedBands, !session.detectedBands.isEmpty {
                    DetectedBandsOverlay(bands: session.detectedBands, geometry: geometry)
                        .allowsHitTesting(false)
                }
            }
            .frame(width: box.width, height: box.height)
            .clipped()
            .contentShape(Rectangle())   // the image and the overlay take no hits: the pane itself pans, zooms and fits
            .border(Color.white.opacity(0.08))
            .zoomPan(zoomModel, box: box)
            .zoomPanWheel(zoomModel, box: box)

            PaneFooter {
                ScaleBar(unitsPerPoint: ImageScaleBar.unitsPerPoint(perPixel: 1, imageWidth: columns, boxWidth: box.width, zoom: zp.drawZoom),
                         unitLabel: "px")
                    .opacity(presentation.showsScaleBar ? 1 : 0)
                    .accessibilityHidden(!presentation.showsScaleBar)
            } trailing: {
                if let text = ZoomPan.badgeText(zoom: zp.drawZoom), let spoken = ZoomPan.badgeSpoken(zoom: zp.drawZoom) {
                    Text(text).font(.caption.weight(.semibold).monospacedDigit()).foregroundStyle(Color.accentColor).fixedSize()
                        .accessibilityLabel(spoken)
                }
            }
        }
        .frame(width: box.width, height: box.height)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("indexing.pattern")
        .accessibilityLabel("Pattern as indexed")
        .accessibilityValue(title)
        .accessibilityHint(ZoomPan.accessibilityHint)
    }
}

/// The detected bands' centre lines through the pane's geometry (they keep their place at any zoom): a band the solution matched solid
/// green with its family on a dark plate, one it did not dashed orange. Stroked as mac4DSTEM strokes its overlays (`SEMOverlayStyle`):
/// every band's solid dark track first, then the lines on top, so a dashed line reads on an unbroken track and no track cuts a line
/// where two bands cross.
private struct DetectedBandsOverlay: View {
    let bands: [IndexedBand]
    let geometry: MarkGeometry

    private func point(_ p: SIMD2<Double>) -> CGPoint { geometry.panePoint(of: ImagePoint(x: p.x, y: p.y)) }

    private func path(_ matched: Bool) -> Path {
        Path { path in
            for band in bands where band.isMatched == matched {
                guard let start = band.start, let end = band.end else { continue }
                path.move(to: point(start))
                path.addLine(to: point(end))
            }
        }
    }

    var body: some View {
        ZStack {
            path(false).stroke(Color.black.opacity(SEMOverlayStyle.haloOpacity), style: SEMOverlayStyle.halo)
            path(true).stroke(Color.black.opacity(SEMOverlayStyle.haloOpacity), style: SEMOverlayStyle.halo)
            path(false).stroke(Color.orange.opacity(SEMOverlayStyle.lineOpacity), style: SEMOverlayStyle.line(dashed: true))
            path(true).stroke(Color.green.opacity(SEMOverlayStyle.lineOpacity), style: SEMOverlayStyle.line(dashed: false))
            ForEach(bands.filter(\.isMatched)) { band in
                if let start = band.start, let end = band.end, let family = band.family {
                    Text(family)
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .foregroundStyle(Color.green)
                        .padding(.horizontal, SEMOverlayStyle.plateHorizontalPadding)
                        .padding(.vertical, SEMOverlayStyle.plateVerticalPadding)
                        .background(Color.black.opacity(SEMOverlayStyle.plateOpacity), in: Capsule()) // science: a label plate on the pattern
                        .position(point((start + end) / 2))
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Detected bands")
        .accessibilityValue("\(bands.filter(\.isMatched).count) of \(bands.count) matched")
        .accessibilityIdentifier("indexing.pattern.overlay")
    }
}

// MARK: - The tables

/// One row per point reached (design §3, the Results tab): sortable by any column; a row clicked picks its pattern, and the picked
/// point's row is selected; ⌘C copies the selected rows (⌘A: all) as TSV in the table's order (`IndexingTableFormat`, D-SEM-96). The
/// rows are rebuilt as the run lands them, every twentieth of the scan and once at its end.
struct IndexingResultsTable: View {
    let session: IndexingSession
    let dataset: EBSDDataset
    @State private var rows: [IndexingResult.Row] = []
    @State private var selection: Set<IndexingResult.Row.ID> = []
    @State private var sortOrder = [KeyPathComparator(\IndexingResult.Row.id)]

    /// What the rows are of: the run (its id, so the Refine switch's swap of a Dictionary run and its refinement, alike in every other
    /// field, rebuilds them; its rows done, and whether it still runs).
    private struct Key: Equatable {
        var run: Int?
        var rowsDone: Int
        var points: Int
        var running: Bool
        var phases: [String]
        var method: IndexingMethod
    }

    private var key: Key? {
        guard let result = session.result else { return nil }
        let stride = max(result.scanRows / 20, 1)
        let landed = session.isIndexing ? result.rowsDone - result.rowsDone % stride : result.rowsDone
        return Key(run: session.shownRun?.id, rowsDone: landed, points: result.pointCount, running: session.isIndexing,
                   phases: result.phases.map(\.name), method: result.method)
    }

    /// "Results · Dictionary · Refined · ni · 4125 of 4125 indexed · PC (…)": the run on screen named as the map's title names it
    /// (`IndexingInfoFormat.resultsHeader`).
    private var header: String {
        guard let result = session.result else { return "Results" }
        return IndexingInfoFormat.resultsHeader(result, run: session.shownRun?.title ?? result.method.title,
                                                projectionCentre: session.resultProjectionCenter)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(header)
                .font(.headline).lineLimit(1)
                .frame(height: LayoutPolicy.paneHeaderHeight)
                .accessibilityIdentifier("indexing.results.title")
            table
            .onCopyCommand(perform: selection.isEmpty ? nil : { copied() })
            .overlay {
                if session.result == nil {
                    Text("Index fills this table, one row per scan point").foregroundStyle(.secondary).allowsHitTesting(false)
                }
            }
            .accessibilityIdentifier("indexing.results")
        }
        .padding(8)
        .onChange(of: key, initial: true) { refresh() }
        .onChange(of: sortOrder) { rows.sort(using: sortOrder) }
        .onChange(of: selection) { old, new in
            guard let id = IndexingTableFormat.pinTarget(old: old, new: new), let row = rows.first(where: { $0.id == id }),
                  row.position != session.patterns.pinned else { return }
            session.pin(row.position)
        }
        .modifier(SelectsThePickedRow(patterns: session.patterns, columns: dataset.scanColumns, rows: rows, selection: $selection))
    }

    /// A Hough result's columns (CI, fit, matched bands, pattern quality) or a dictionary result's (the score, the simulation index, the
    /// orientation similarity).
    @ViewBuilder private var table: some View {
        if let result = session.result, result.method == .dictionary {
            Table(rows, selection: $selection, sortOrder: $sortOrder) {
                TableColumn("Row", value: \.row) { Text(verbatim: "\($0.row)").monospacedDigit() }
                TableColumn(SEMColumnSpeech.header("Col"), value: \.column) { Text(verbatim: "\($0.column)").monospacedDigit() }
                TableColumn("Phase", value: \.phase)
                TableColumn(SEMColumnSpeech.header("φ₁ °"), value: \.phi1Key) { Text(IndexingTableFormat.angle($0.phi1)).monospacedDigit() }
                TableColumn(SEMColumnSpeech.header("Φ °"), value: \.capitalPhiKey) {
                    Text(IndexingTableFormat.angle($0.capitalPhi)).monospacedDigit()
                }
                TableColumn(SEMColumnSpeech.header("φ₂ °"), value: \.phi2Key) { Text(IndexingTableFormat.angle($0.phi2)).monospacedDigit() }
                TableColumn(SEMColumnSpeech.header(result.scoreTitle), value: \.confidence) {
                    Text(IndexingTableFormat.fraction($0.confidence)).monospacedDigit()
                }
                TableColumn("Simulation", value: \.simulationIndex) {
                    Text(IndexingTableFormat.simulation($0.simulationIndex)).monospacedDigit()
                }
                TableColumn(SEMColumnSpeech.header("OSM"), value: \.similarityKey) {
                    Text(IndexingTableFormat.angle($0.similarity, digits: 2)).monospacedDigit()
                }
            }
        } else {
            Table(rows, selection: $selection, sortOrder: $sortOrder) {
                TableColumn("Row", value: \.row) { Text(verbatim: "\($0.row)").monospacedDigit() }
                TableColumn(SEMColumnSpeech.header("Col"), value: \.column) { Text(verbatim: "\($0.column)").monospacedDigit() }
                TableColumn("Phase", value: \.phase)
                TableColumn(SEMColumnSpeech.header("φ₁ °"), value: \.phi1Key) { Text(IndexingTableFormat.angle($0.phi1)).monospacedDigit() }
                TableColumn(SEMColumnSpeech.header("Φ °"), value: \.capitalPhiKey) {
                    Text(IndexingTableFormat.angle($0.capitalPhi)).monospacedDigit()
                }
                TableColumn(SEMColumnSpeech.header("φ₂ °"), value: \.phi2Key) { Text(IndexingTableFormat.angle($0.phi2)).monospacedDigit() }
                TableColumn(SEMColumnSpeech.header("CI"), value: \.confidence) { Text(IndexingTableFormat.fraction($0.confidence)).monospacedDigit() }
                TableColumn(SEMColumnSpeech.header("Fit °"), value: \.fitKey) {
                    Text(IndexingTableFormat.angle($0.fit, digits: 2)).monospacedDigit()
                }
                TableColumn("Bands", value: \.bands) { Text(verbatim: "\($0.bands)").monospacedDigit() }
                TableColumn(SEMColumnSpeech.header("PQ"), value: \.patternQualityKey) {
                    Text(IndexingTableFormat.number($0.patternQuality)).monospacedDigit()
                }
            }
        }
    }

    private func refresh() {
        rows = (session.result?.rows ?? []).sorted(using: sortOrder)
    }

    /// ⌘C: the selected rows as TSV, in the table's order (the sort on screen), under the column titles.
    private func copied() -> [NSItemProvider] {
        guard let result = session.result else { return [] }
        let picked = rows.filter { selection.contains($0.id) }
        guard !picked.isEmpty else { return [] }
        let text = IndexingTableFormat.copyText(picked, method: result.method, scoreTitle: result.scoreTitle)
        return [NSItemProvider(object: text as NSString)]
    }
}

/// A point picked elsewhere (the map, a compared map, the arrows) selects its Results row alone, once the pick rests; one already in the
/// selection leaves it. A drag streams picks, and each would walk the rows and redraw the table: this modifier alone reads the pick, so
/// the table's body does not run at the drag's rate, and the walk waits until the pick has rested for `rest`.
private struct SelectsThePickedRow: ViewModifier {
    let patterns: EBSDSession
    let columns: Int
    let rows: [IndexingResult.Row]
    @Binding var selection: Set<IndexingResult.Row.ID>

    static let rest = Duration.milliseconds(120)

    func body(content: Content) -> some View {
        content.task(id: patterns.pinned) {
            guard (try? await Task.sleep(for: Self.rest)) != nil else { return }   // cancelled: the pick moved on
            let pinned = patterns.pinned
            let id = pinned.row * columns + pinned.column
            if !selection.contains(id), rows.contains(where: { $0.id == id }) { selection = [id] }
        }
    }
}

/// A dictionary run's best match at the pattern pane's point (design §3, the Dictionary tab): the simulated pattern of the point's best
/// orientation on the run's detector, from its master pattern, to set beside the experimental pattern; the score and the simulation index
/// in the header. The bottom pane holds no controls: the pattern follows the picked point.
struct IndexingBestMatchPane: View {
    let session: IndexingSession
    @State var zoomModel = PaneZoomModel()
    private var zp: ZoomPan { zoomModel.state }

    private var header: String {
        guard let position = session.bestMatchPosition, let result = session.result, let solution = result.solution(at: position) else {
            return "Best match"
        }
        var words = "Best match · row \(position.row) · col \(position.column)"
        // Against several phases the point's phase, whose dictionary the simulation index counts in (D-SEM-98).
        if result.phases.count > 1, let phase = result.phase(of: solution) { words += " · \(phase.name)" }
        words += " · \(result.scoreTitle) \(IndexingTableFormat.fraction(solution.confidence))"
        if let index = result.simulationIndex(at: position) {
            words += " · simulation \(index)"
            let plans = session.dictionaryPlans
            if plans.indices.contains(solution.phase) { words += " of \(IndexingInfoFormat.count(plans[solution.phase].rotations.count))" }
        }
        return words
    }

    /// What the pane says while it has no pattern to show.
    private var emptyWords: String {
        if let why = session.bestMatchFailure { return why }
        guard let result = session.result, result.method == .dictionary else { return "Index with Dictionary to see each point's best match" }
        if session.isIndexing, result.rowsDone == 0 { return "The best matches land when the dictionary has run" }
        return "This point has no match"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(header)
                .font(.headline).lineLimit(1)
                .frame(height: LayoutPolicy.paneHeaderHeight)
                .accessibilityIdentifier("indexing.bestMatch.title")
            GeometryReader { geometry in
                content(in: geometry.size)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(8)
        .clipped()
    }

    private func content(in size: CGSize) -> some View {
        let presentation = session.bestMatchPresentation
        let canvas = session.bestMatchPosition == nil ? nil : presentation.canvas
        let aspect = canvas.map { CGFloat($0.width) / CGFloat(max($0.height, 1)) } ?? 1
        let box = LayoutPolicy.fitted(in: size, aspect: aspect)
        let transform = MetalDisplayTransform(paneSize: box, imageBox: box, zoom: zp.drawZoom, offset: zp.effectiveOffset)
        return ZStack {
            Group {
                if let canvas {
                    MetalImageView(pixels: canvas.normalized, width: canvas.width, height: canvas.height, contentVersion: canvas.contentVersion,
                                   colormap: presentation.colormap, displayLo: presentation.displayFractions.low,
                                   displayHi: presentation.displayFractions.high, gamma: Float(presentation.gamma))
                        .displayTransform(transform)
                        .allowsHitTesting(false)
                } else {
                    Rectangle().fill(.quaternary)
                    Text(emptyWords).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(8)
                        .allowsHitTesting(false)
                }
            }
            .frame(width: box.width, height: box.height)
            .clipped()
            .contentShape(Rectangle())
            .border(Color.white.opacity(0.08))
            .zoomPan(zoomModel, box: box)
            .zoomPanWheel(zoomModel, box: box)
        }
        .frame(width: box.width, height: box.height)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("indexing.bestMatch")
        .accessibilityLabel("Best match")
        .accessibilityValue(canvas == nil ? emptyWords : header)
        .accessibilityHint(ZoomPan.accessibilityHint)
    }
}

/// The detected bands of the pattern on screen (design §3, the Log tab: pyEBSDindex's band list), strongest first, with the family the
/// solution matched each to and its fit. ⌘C copies the selected bands (⌘A: all) as TSV in the table's order (`IndexingTableFormat`,
/// #353); another pattern clears the selection, so a rank picked on one pattern is not copied from the next. The symbol headers are said
/// in words (`SEMColumnSpeech`, #320).
struct IndexingBandsTable: View {
    let session: IndexingSession
    @State private var selection: Set<IndexedBand.ID> = []

    private var header: String {
        guard let position = session.patternPosition else { return "Bands" }
        let matched = session.detectedBands.filter(\.isMatched).count
        let words = "Bands · row \(position.row) · col \(position.column)"
        return session.detectedBands.isEmpty ? words : words + " · \(matched) of \(session.detectedBands.count) matched"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(header)
                .font(.headline).lineLimit(1)
                .frame(height: LayoutPolicy.paneHeaderHeight)
                .accessibilityIdentifier("indexing.bands.title")
            Table(session.detectedBands, selection: $selection) {
                TableColumn(SEMColumnSpeech.header("#")) { Text(verbatim: "\($0.id)").monospacedDigit() }
                TableColumn(SEMColumnSpeech.header("ρ px")) { Text(IndexingTableFormat.angle($0.rho, digits: 2)).monospacedDigit() }
                TableColumn(SEMColumnSpeech.header("θ °")) { Text(IndexingTableFormat.angle($0.thetaDegrees, digits: 2)).monospacedDigit() }
                TableColumn("Peak") { Text(IndexingTableFormat.number($0.peak)).monospacedDigit() }
                TableColumn("Width") { Text(IndexingTableFormat.number($0.width)).monospacedDigit() }
                TableColumn("Family") { Text(IndexingTableFormat.bandFamily($0.family, isValid: $0.isValid)) }
                TableColumn(SEMColumnSpeech.header("Fit °")) { Text(IndexingTableFormat.bandFit($0.fitDegrees)).monospacedDigit() }
            }
            .onCopyCommand(perform: selection.isEmpty ? nil : { copiedBands() })
            .accessibilityIdentifier("indexing.bands")
        }
        .padding(8)
        .onChange(of: session.patternPosition) { selection = [] }
    }

    /// ⌘C: the selected bands as TSV, in the table's order (strongest first), under the column titles.
    private func copiedBands() -> [NSItemProvider] {
        let picked = session.detectedBands.filter { selection.contains($0.id) }
        guard !picked.isEmpty else { return [] }
        return [NSItemProvider(object: IndexingTableFormat.bandsCopyText(picked) as NSString)]
    }
}
