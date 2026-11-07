//
//  IndexingRoom.swift
//  Role: the Indexing room (docs/sem/design/indexing-room.md §3): the indexed map on the left (the result on the layer `Display › Map`
//        picks, one pixel per scan point, over the Patterns room's mean map dimmed until a point is reached; the pinned position's
//        crosshair; the IPF colour key in the footer beside the scale bar) and the pattern pane on the right (the pattern under the
//        pointer while it hovers the map, the pinned one otherwise, as the indexer sees it, with its detected bands: the ones the solution
//        matched solid green and labelled with their family, the others dashed orange). Under them the Results table (one row per
//        point reached; a selected row pins the pattern) beside the Bands table of the pattern on screen (pyEBSDindex's band list:
//        ρ, θ, peak, width, the family and the fit). The phases, the Hough settings and the exports are the inspector's
//        (`IndexingRoomInspector.swift`). Presentation only: every number is `HoughIndexer`'s (TEMCore) through `IndexingSession`
//        (TEMSession).
//
//  KEYS: as the Patterns room (`PatternsKeys`): ← → ↑ ↓ step the pinned position by one (⇧ by ten), Space pins the hovered position; a
//  click on the map pins the point under it. The pinned position is the Patterns room's: the two rooms share one marker.
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
                    PaneSplit(storageKey: "indexing.tablesSplit", resizeLabel: "Resize the results and the bands", leadingName: "Results") {
                        IndexingResultsTable(session: session, dataset: document.dataset)
                    } trailing: {
                        IndexingBandsTable(session: session)
                    }
                }
                .id(document.fileName)
                .modifier(IndexingKeyedRoom(session: session))
                // The map's backdrop is the Patterns room's mean map, which lands after the open; the pattern follows the shared marker
                // and the Patterns room's processing.
                .onChange(of: session.patterns.meanIntensities == nil, initial: true) { session.refreshMap() }
                .onChange(of: session.patterns.pinned) { session.showPattern() }
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
            case .success(let url): appState.statusText = "Exported \(url.lastPathComponent)"
            case .failure(let error): appState.present(error)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("indexing.room")
    }
}

/// A file the save panel writes: the bytes `IndexingRoomState.export` made (the map PNG, the results CSV or the method JSON).
struct IndexingExportFile: FileDocument {
    static var readableContentTypes: [UTType] { [.png, .json, .commaSeparatedText] }
    var data: Data

    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

// MARK: - The keys

/// The arrows step the pinned position (⇧ ten), Space pins the hovered one: the Patterns room's keys (`PatternsKeys`).
private struct IndexingKeyedRoom: ViewModifier {
    let session: IndexingSession

    func body(content: Content) -> some View {
        content
            .focusable()
            .focusEffectDisabled()   // DEVIATION as `FFTKeyedRoom`'s, named there
            .onKeyPress(phases: .down) { press in
                if let step = PatternsKeys.step(key: press.key, modifiers: press.modifiers) {
                    session.step(step.direction, by: step.count)
                    return .handled
                }
                if press.key == .space, press.modifiers.isEmpty { session.pinHovered(); return .handled }
                return .ignored
            }
    }
}

// MARK: - The indexed map

/// The result on its layer, one pixel per scan point, growing row by row while Index runs; before a run the mean map dimmed, with the
/// one sentence that says what fills it. Hovering it puts the point's solution in the status line and its pattern in the pattern pane;
/// a click pins the point.
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
    }

    /// "Indexed map · IPF-Z", with "· stale" once the inputs changed since the run (design §6).
    private var title: String {
        guard session.result != nil else { return "Scan map · mean intensity, not indexed" }
        return "Indexed map · \(session.layer.title)" + (session.isStale ? " · stale" : "")
    }

    /// "4 120 of 4 125 indexed", "1 875 of 4 125 reached" while it runs, "stopped at row 12 of 55".
    private var count: String? {
        guard let result = session.result else { return nil }
        if session.isIndexing { return "\(result.reachedCount.formatted()) of \(result.pointCount.formatted()) reached" }
        if session.wasStopped { return "stopped at row \(result.rowsDone) of \(result.scanRows) · \(result.indexedCount.formatted()) indexed" }
        return "\(result.indexedCount.formatted()) of \(result.pointCount.formatted()) indexed"
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
        let points = dataset.scanRows * dataset.scanColumns
        return ZStack {
            ZStack {
                if let rgba = session.mapRGBA, rgba.count == points * 4 {
                    // The map as packed RGBA (orix's colours, `IndexingRaster`) through the view's RGBA pipeline.
                    MetalImageView(pixels: [Float](repeating: 0, count: points), width: dataset.scanColumns, height: dataset.scanRows,
                                   contentVersion: session.mapVersion, rgba: rgba)
                        .displayTransform(transform)
                        .frame(width: box.width, height: box.height)
                        .allowsHitTesting(false)
                } else {
                    Rectangle().fill(.quaternary).frame(width: box.width, height: box.height)
                }
                ScanMarker(center: geometry.panePoint(of: ImagePoint(x: Double(session.patterns.pinned.column), y: Double(session.patterns.pinned.row))),
                           pointsPerPixel: geometry.pointsPerPixel)
                    .allowsHitTesting(false)
            }
            .frame(width: box.width, height: box.height)
            .clipped()
            .contentShape(Rectangle())
            .onTapGesture { location in
                let q = geometry.imagePoint(atPanePoint: location)
                let position = EBSDPosition(row: Int(q.y.rounded()), column: Int(q.x.rounded()))
                if position.isInside(rows: dataset.scanRows, columns: dataset.scanColumns) { session.pin(position) }
            }
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
                ScaleBar(unitsPerPoint: ImageScaleBar.unitsPerPoint(perPixel: dataset.stepX, imageWidth: dataset.scanColumns, boxWidth: box.width, zoom: zp.drawZoom),
                         unitLabel: EBSDBrowsing.unitLabel(dataset.scanUnit))
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

    /// The status line's readout (the point's solution) and the hovered position (the pattern pane follows it).
    private func hovered(_ phase: HoverPhase, geometry: MarkGeometry) {
        switch phase {
        case .active(let p):
            let q = geometry.imagePoint(atPanePoint: p)
            let position = EBSDPosition(row: Int(q.y.rounded()), column: Int(q.x.rounded()))
            guard position.isInside(rows: dataset.scanRows, columns: dataset.scanColumns) else {
                session.hover(nil); state.readout = nil; return
            }
            session.hover(position)
            state.readout = session.readout(at: position)
        case .ended:
            session.hover(nil)
            state.readout = nil
        }
    }
}

// MARK: - The legend

/// The map's key in the footer (design §3): the IPF colour key of each point group for an IPF layer, the phases' colours for the Phase
/// layer, the grey ramp's two ends for a scalar layer.
private struct IndexingLegend: View {
    let session: IndexingSession

    var body: some View {
        let phases = session.result?.phases ?? []
        Group {
            if session.layer.direction != nil {
                let groups = phases.compactMap(\.pointGroupName).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
                HStack(alignment: .bottom, spacing: 6) {
                    ForEach(groups, id: \.self) { name in
                        if let key = session.keyImages[name], let image = IPFKeyPicture.cgImage(key) {
                            VStack(spacing: 2) {
                                Image(decorative: image, scale: 1).resizable().interpolation(.medium).aspectRatio(contentMode: .fit)
                                    .frame(height: LayoutPolicy.indexingKeyHeight)
                                Text(groups.count > 1 ? "\(session.layer.title) · \(name)" : session.layer.title)
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(session.layer.title) colour key of point group \(groups.joined(separator: ", "))")
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
            } else if let result = session.result, let range = IndexingRaster.scalarRange(result, layer: session.layer) {
                Text("\(session.layer.title): black \(Self.number(range.lowerBound)) · white \(Self.number(range.upperBound))")
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .padding(4)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
        .accessibilityIdentifier("indexing.map.legend")
    }

    private static func number(_ v: Double) -> String { v.formatted(.number.precision(.significantDigits(1...3))) }
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

/// The pattern at the shown position (hovered, else pinned) as the indexer reads it, with its detected bands drawn over it.
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
        return EBSDBrowsing.patternTitle(position, hovering: session.hovered != nil) + " · as indexed"
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
                if session.showsDetectedBands, !session.detectedBands.isEmpty {
                    DetectedBandsOverlay(bands: session.detectedBands, geometry: geometry)
                        .allowsHitTesting(false)
                }
            }
            .frame(width: box.width, height: box.height)
            .clipped()
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
/// green with its family, one it did not dashed orange; each over a dark halo so it reads on any pattern.
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
            path(true).stroke(Color.black.opacity(0.55), lineWidth: 3.5)
            path(true).stroke(Color.green, lineWidth: 1.5)
            path(false).stroke(Color.black.opacity(0.45), style: StrokeStyle(lineWidth: 3, dash: [5, 4]))
            path(false).stroke(Color.orange, style: StrokeStyle(lineWidth: 1.25, dash: [5, 4]))
            ForEach(bands.filter(\.isMatched)) { band in
                if let start = band.start, let end = band.end, let family = band.family {
                    Text(family)
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .foregroundStyle(Color.green)
                        .shadow(color: .black, radius: 1.5)
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

/// One row per point reached (design §3, the Results tab): sortable by any column; the selected row pins its pattern. The rows are
/// rebuilt as the run lands them, every twentieth of the scan and once at its end.
struct IndexingResultsTable: View {
    let session: IndexingSession
    let dataset: EBSDDataset
    @State private var rows: [IndexingResult.Row] = []
    @State private var selection: IndexingResult.Row.ID?
    @State private var sortOrder = [KeyPathComparator(\IndexingResult.Row.id)]

    /// What the rows are of: the run (its rows done, and whether it still runs).
    private struct Key: Equatable {
        var rowsDone: Int
        var points: Int
        var running: Bool
        var phases: [String]
    }

    private var key: Key? {
        guard let result = session.result else { return nil }
        let stride = max(result.scanRows / 20, 1)
        let landed = session.isIndexing ? result.rowsDone - result.rowsDone % stride : result.rowsDone
        return Key(rowsDone: landed, points: result.pointCount, running: session.isIndexing, phases: result.phases.map(\.name))
    }

    private var header: String {
        guard let result = session.result else { return "Results" }
        let phases = result.phases.map(\.name).joined(separator: ", ")
        var words = "Results · Hough · \(phases) · \(result.indexedCount.formatted()) of \(result.reachedCount.formatted()) indexed"
        if let pc = session.resultProjectionCenter {
            words += " · PC (\(UnitDisplay.number(pc.x, digits: 4)), \(UnitDisplay.number(pc.y, digits: 4)), \(UnitDisplay.number(pc.z, digits: 4)))"
        }
        return words
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(header)
                .font(.headline).lineLimit(1)
                .frame(height: LayoutPolicy.paneHeaderHeight)
                .accessibilityIdentifier("indexing.results.title")
            Table(rows, selection: $selection, sortOrder: $sortOrder) {
                TableColumn("Row", value: \.row) { Text(verbatim: "\($0.row)").monospacedDigit() }
                TableColumn("Col", value: \.column) { Text(verbatim: "\($0.column)").monospacedDigit() }
                TableColumn("Phase", value: \.phase)
                TableColumn("φ₁ °", value: \.phi1) { Text(Self.angle($0.phi1)).monospacedDigit() }
                TableColumn("Φ °", value: \.capitalPhi) { Text(Self.angle($0.capitalPhi)).monospacedDigit() }
                TableColumn("φ₂ °", value: \.phi2) { Text(Self.angle($0.phi2)).monospacedDigit() }
                TableColumn("CI", value: \.confidence) { Text(Self.fraction($0.confidence)).monospacedDigit() }
                TableColumn("Fit °", value: \.fit) { Text(Self.angle($0.fit, digits: 2)).monospacedDigit() }
                TableColumn("Bands", value: \.bands) { Text(verbatim: "\($0.bands)").monospacedDigit() }
                TableColumn("PQ", value: \.patternQuality) { Text(Self.number($0.patternQuality)).monospacedDigit() }
            }
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
        .onChange(of: selection) {
            guard let id = selection, let row = rows.first(where: { $0.id == id }), row.position != session.patterns.pinned else { return }
            session.pin(row.position)
        }
        .onChange(of: session.patterns.pinned) {
            let id = session.patterns.pinned.row * dataset.scanColumns + session.patterns.pinned.column
            if selection != id, rows.contains(where: { $0.id == id }) { selection = id }
        }
    }

    private func refresh() {
        rows = (session.result?.rows ?? []).sorted(using: sortOrder)
    }

    static func angle(_ v: Double, digits: Int = 1) -> String {
        v.isFinite ? v.formatted(.number.precision(.fractionLength(digits))) : "–"
    }

    static func fraction(_ v: Double) -> String { v.isFinite ? v.formatted(.number.precision(.fractionLength(3))) : "–" }

    static func number(_ v: Double) -> String { v.isFinite ? v.formatted(.number.precision(.significantDigits(1...4))) : "–" }
}

/// The detected bands of the pattern on screen (design §3, the Log tab: pyEBSDindex's band list), strongest first, with the family the
/// solution matched each to and its fit.
struct IndexingBandsTable: View {
    let session: IndexingSession

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
            Table(session.detectedBands) {
                TableColumn("#") { Text(verbatim: "\($0.id)").monospacedDigit() }
                TableColumn("ρ px") { Text(IndexingResultsTable.angle($0.rho, digits: 2)).monospacedDigit() }
                TableColumn("θ °") { Text(IndexingResultsTable.angle($0.thetaDegrees, digits: 2)).monospacedDigit() }
                TableColumn("Peak") { Text(IndexingResultsTable.number($0.peak)).monospacedDigit() }
                TableColumn("Width") { Text(IndexingResultsTable.number($0.width)).monospacedDigit() }
                TableColumn("Family") { Text($0.family ?? ($0.isValid ? "–" : "invalid")) }
                TableColumn("Fit °") { Text($0.fitDegrees.map { IndexingResultsTable.angle($0, digits: 2) } ?? "–").monospacedDigit() }
            }
            .accessibilityIdentifier("indexing.bands")
        }
        .padding(8)
    }
}
