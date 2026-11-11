//
//  PatternsRoom.swift
//  Role: the Patterns room (docs/sem/design/ebsd-patterns-room.md §3, §6): the scan map on the left (the mean intensity of every pattern,
//        one pixel per scan point, a crosshair at the pinned position, the scale bar from the step) and the live pattern pane on the right
//        (the pattern under the pointer while it hovers the map, the pinned one otherwise, with the simulation overlay when it is on), split by
//        MacEMUI's `PaneSplit`. Each picture is
//        a `MetalImageView` under the shell's `zoomPan` modifiers, drawn as the Image room draws its canvas (`ImagePane`): the Metal view stays pane-sized
//        and the shader applies the zoom. The room has its own document, the dataset, held by `EBSDSession` (TEMSession); the
//        Calibration, Display and Export sections are the inspector's (`PatternsRoomInspector.swift`). Presentation only: every number on
//        screen is the file's or `EBSDBrowsing`'s (TEMCore).
//
//  KEYS: the room's root is the one focusable container (the arrangement of `PaneKeys.swift`): ← → ↑ ↓ step the pinned position by one
//  (⇧ by ten), Space pins the hovered position. A click on the map at 1× pins the position under it (design §6, the scrub).
//

import ShellControls
import ShellLayout
import ShellMetal
import ShellSpectroscopy
import SwiftUI
import UniformTypeIdentifiers
import TEMCore
import TEMSession

struct PatternsRoom: View {
    @Environment(AppState.self) private var appState
    @State private var showImporter = false

    private var importTypes: [UTType] { EBSDOpening.readableExtensions.compactMap { UTType(filenameExtension: $0) } }

    /// The scan map beside the live pattern pane.
    private func upper(_ dataset: EBSDDataset) -> some View {
        PaneSplit(storageKey: "patterns.split", resizeLabel: "Resize the scan map and the pattern", leadingName: "Scan map") {
            ScanMapPane(session: appState.ebsd, state: appState.patternsRoom, dataset: dataset)
        } trailing: {
            LivePatternPane(session: appState.ebsd, state: appState.patternsRoom, dataset: dataset)
        }
    }

    var body: some View {
        let session = appState.ebsd
        let state = appState.patternsRoom
        Group {
            if session.isOpening {
                VStack(spacing: 12) {
                    ProgressView().progressViewStyle(.linear).frame(maxWidth: EDXLayout.openingBarWidth)
                        .accessibilityLabel("Opening dataset")
                    Text("Opening dataset").font(.headline)
                    Button("Stop") { session.stop() }
                        .keyboardShortcut(.cancelAction)
                        .accessibilityIdentifier("patterns.opening.stop")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("patterns.opening")
            } else if let document = session.document {
                Group {
                    if session.showsTiles {
                        VerticalPaneSplit(storageKey: "patterns.lowerSplit", defaultFraction: 0.65, resizeLabel: "Resize the panes and the tiles", topName: "Scan map and pattern",
                                          minimumTop: 160, minimumBottom: 120) {
                            upper(document.dataset)
                        } bottom: {
                            VirtualTilesPane(session: session, dataset: document.dataset)
                        }
                    } else {
                        upper(document.dataset)
                    }
                }
                .id(document.fileName)
                .modifier(PatternsKeyedRoom(session: session))
            } else {
                ContentUnavailableView {
                    Label("No EBSD dataset open", systemImage: "square.grid.3x3.square")
                } description: {
                    Text("Open an h5ebsd pattern file (kikuchipy, Bruker, EDAX or Oxford H5OINA), or try the demo dataset from the Help menu.")
                } actions: {
                    Button("Open EBSD Dataset…") { state.requestImport() }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("patterns.openDataset")
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
        .fileExporter(isPresented: Binding(get: { state.exporting != nil }, set: { if !$0 { state.exporting = nil } }),
                      document: PatternsExportFile(data: state.exportData),
                      contentType: state.exporting?.contentType ?? .json,
                      defaultFilename: (session.fileName as NSString).deletingPathExtension + (state.exporting?.suffix(position: state.exportPosition, map: state.exportMap) ?? "")) { result in
            switch result {
            case .success(let url):
                appState.statusText = "Exported \(url.lastPathComponent)"
                state.didWrite(to: url)
            case .failure(let error): appState.present(error)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("patterns.room")
    }
}

/// A file the save panel writes: the bytes `PatternsRoomState.export` made (the pattern PNG or the metadata JSON).
struct PatternsExportFile: FileDocument {
    static var readableContentTypes: [UTType] { [.png, .json, .commaSeparatedText] }
    var data: Data

    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

// MARK: - The keys

/// The arrows step the pinned position (⇧ ten), Space pins the hovered one. One focusable container for the room, as `ImageKeyedRoom`.
private struct PatternsKeyedRoom: ViewModifier {
    let session: EBSDSession

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

/// The arrow keys' reading, pure so a test pins it: an arrow with no modifier steps one, with ⇧ ten; anything else is not ours.
nonisolated enum PatternsKeys {
    static func step(key: KeyEquivalent, modifiers: EventModifiers) -> (direction: EBSDPosition.Direction, count: Int)? {
        let held = modifiers.intersection([.shift, .control, .option, .command])
        guard held.isSubset(of: .shift) else { return nil }
        let count = held.contains(.shift) ? 10 : 1
        switch key {
        case .leftArrow: return (.left, count)
        case .rightArrow: return (.right, count)
        case .upArrow: return (.up, count)
        case .downArrow: return (.down, count)
        default: return nil
        }
    }
}

// MARK: - The scan map

/// The mean-intensity map, one pixel per scan point, with the pinned position's crosshair: hovering it puts the position and its mean in the
/// status line and the pattern under the pointer in the pattern pane; a click at 1× pins the position (the scrub of design §6).
struct ScanMapPane: View {
    let session: EBSDSession
    let state: PatternsRoomState
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

    private var header: some View {
        HStack(spacing: 8) {
            Text(mapTitle)
                .font(.headline).lineLimit(1)
                .accessibilityIdentifier("patterns.map.title")
            Spacer(minLength: 8)
            if session.isMapping {
                ProgressView(value: session.mapProgress).progressViewStyle(.linear).frame(width: LayoutPolicy.paneHeaderProgressWidth)
                    .accessibilityLabel("Reading the scan")
                    .accessibilityIdentifier("patterns.map.progress")
            } else if session.isQualityMapping {
                ProgressView(value: session.qualityProgress).progressViewStyle(.linear).frame(width: LayoutPolicy.paneHeaderProgressWidth)
                    .accessibilityLabel("Computing the quality maps")
                    .accessibilityIdentifier("patterns.map.progress")
            } else if let why = session.mapFailure {
                Text(why).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Text(verbatim: "\(dataset.scanColumns) × \(dataset.scanRows)")
                .help("Scan columns × rows")
                .font(.caption.monospaced()).foregroundStyle(.secondary).fixedSize()
        }
        .frame(height: LayoutPolicy.paneHeaderHeight)
    }

    /// "Scan map · mean intensity", "· BSE", "· tile r2 c1", "· colour mix r2 c1 + r2 c2 + r2 c3".
    private var mapTitle: String {
        switch session.mapChoice {
        case .mean: "Scan map · mean intensity"
        case .bse: "Scan map · BSE (whole detector)"
        case .tile(let tile): "Scan map · tile \(tile.label)"
        case .mix: "Scan map · colour mix " + session.mixTiles.compactMap { $0?.label }.joined(separator: " + ")
        case .imageQuality: "Scan map · image quality (raw patterns)"
        case .dotProduct: "Scan map · average dot product (raw patterns)"
        }
    }

    private func content(in size: CGSize) -> some View {
        let box = LayoutPolicy.fitted(in: size, aspect: CGFloat(dataset.scanColumns) / CGFloat(dataset.scanRows))
        let presentation = session.mapPresentation
        let transform = MetalDisplayTransform(paneSize: box, imageBox: box, zoom: zp.drawZoom, offset: zp.effectiveOffset)
        let geometry = MarkGeometry(transform: transform, imageWidth: dataset.scanColumns, imageHeight: dataset.scanRows)
        let unit = EBSDBrowsing.unitLabel(dataset.scanUnit)
        return ZStack {
            ZStack {
                if session.mapChoice == .mix, let rgba = session.mixRGBA {
                    // The colour mix: packed RGBA through the view's RGBA pipeline (the Display section's colormap and window do not apply).
                    MetalImageView(pixels: [Float](repeating: 0, count: dataset.scanRows * dataset.scanColumns), width: dataset.scanColumns, height: dataset.scanRows,
                                   contentVersion: session.mixVersion, rgba: rgba)
                        .displayTransform(transform)
                        .frame(width: box.width, height: box.height)
                        .allowsHitTesting(false)
                } else if let canvas = presentation.canvas {
                    MetalImageView(pixels: canvas.normalized, width: canvas.width, height: canvas.height, contentVersion: canvas.contentVersion,
                                   colormap: presentation.colormap, displayLo: presentation.displayFractions.low,
                                   displayHi: presentation.displayFractions.high, gamma: Float(presentation.gamma))
                        .displayTransform(transform)
                        .frame(width: box.width, height: box.height)
                        .allowsHitTesting(false)
                } else {
                    // The pass has not landed yet: the map's area, with the progress in the header.
                    Rectangle().fill(.quaternary).frame(width: box.width, height: box.height)
                }
                // The pinned position: a crosshair through the shader's own map, so it cannot slip from its scan point at any zoom.
                ScanMarker(center: geometry.panePoint(of: ImagePoint(x: Double(session.pinned.column), y: Double(session.pinned.row))),
                           pointsPerPixel: geometry.pointsPerPixel)
                    .allowsHitTesting(false)
            }
            .frame(width: box.width, height: box.height)
            .clipped()
            .contentShape(Rectangle())
            // A click pins the position under it (the drag is the pane's pan).
            .onTapGesture { location in
                let q = geometry.imagePoint(atPanePoint: location)
                session.pin(EBSDPosition(row: Int(q.y.rounded()), column: Int(q.x.rounded())))
            }
            .border(Color.white.opacity(0.08))
            .zoomPan(zoomModel, box: box, onHover: { phase in hovered(phase, geometry: geometry) })
            .zoomPanWheel(zoomModel, box: box)
            .zoomCommandTarget(zoomModel, isTarget: true)

            PaneFooter {
                ScaleBar(unitsPerPoint: ImageScaleBar.unitsPerPoint(perPixel: dataset.stepX, imageWidth: dataset.scanColumns, boxWidth: box.width, zoom: zp.drawZoom),
                         unitLabel: unit)
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
        .accessibilityIdentifier("patterns.map")
        .accessibilityLabel("Scan map")
        .accessibilityValue("\(dataset.scanRows) rows by \(dataset.scanColumns) columns, pinned at row \(session.pinned.row) column \(session.pinned.column)")
        .accessibilityHint(ZoomPan.accessibilityHint)
    }

    /// The status line's readout and the hovered position (the pattern pane follows it).
    private func hovered(_ phase: HoverPhase, geometry: MarkGeometry) {
        switch phase {
        case .active(let p):
            let q = geometry.imagePoint(atPanePoint: p)
            let position = EBSDPosition(row: Int(q.y.rounded()), column: Int(q.x.rounded()))
            guard position.isInside(rows: dataset.scanRows, columns: dataset.scanColumns) else {
                session.hover(nil); state.readout = nil; return
            }
            session.hover(position)
            state.readout = EBSDBrowsing.mapReadout(position, mean: session.meanIntensity(at: position), map: session.mapValue(at: position))
        case .ended:
            session.hover(nil)
            state.readout = nil
        }
    }
}

/// The crosshair at the pinned scan point: a box one scan pixel wide and two arms, in the accent colour with a dark halo so it reads on any map.
/// The Indexing and Maps rooms draw it too.
struct ScanMarker: View {
    let center: CGPoint
    let pointsPerPixel: CGFloat

    var body: some View {
        let side = max(pointsPerPixel, 6), arm: CGFloat = 10
        ZStack {
            Rectangle().stroke(Color.black.opacity(0.6), lineWidth: 3).frame(width: side, height: side)
            Rectangle().stroke(Color.accentColor, lineWidth: 1.5).frame(width: side, height: side)
            Path { p in
                for (dx, dy) in [(1.0, 0.0), (-1.0, 0.0), (0.0, 1.0), (0.0, -1.0)] {
                    p.move(to: CGPoint(x: center.x + dx * side / 2, y: center.y + dy * side / 2))
                    p.addLine(to: CGPoint(x: center.x + dx * (side / 2 + arm), y: center.y + dy * (side / 2 + arm)))
                }
            }
            .stroke(Color.black.opacity(0.6), lineWidth: 3)
            Path { p in
                for (dx, dy) in [(1.0, 0.0), (-1.0, 0.0), (0.0, 1.0), (0.0, -1.0)] {
                    p.move(to: CGPoint(x: center.x + dx * side / 2, y: center.y + dy * side / 2))
                    p.addLine(to: CGPoint(x: center.x + dx * (side / 2 + arm), y: center.y + dy * (side / 2 + arm)))
                }
            }
            .stroke(Color.accentColor, lineWidth: 1.5)
        }
        .position(center)
        .accessibilityHidden(true)
    }
}

// MARK: - The live pattern pane

/// The pattern at the shown position (hovered, else pinned), drawn with its own contrast; hovering it puts the detector pixel and its stored value
/// in the status line, and VoiceOver reads the same words as the pane's value (`ReadoutAccessibilityValue`, #345).
struct LivePatternPane: View {
    let session: EBSDSession
    let state: PatternsRoomState
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
        return EBSDBrowsing.patternTitle(position, hovering: session.hovered != nil) + (session.patternIsProcessed ? " · processed" : "")
    }

    /// The tile on the map, outlined on the pattern.
    private var shownTile: VirtualBSETile? {
        if case .tile(let tile) = session.mapChoice { return tile }
        return nil
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.headline).lineLimit(1)
                .accessibilityIdentifier("patterns.pattern.title")
            Spacer(minLength: 8)
            if case .failure(let absence)? = session.overlay {
                Text(absence.sentence).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    .accessibilityIdentifier("patterns.overlay.absence")
            }
            Text(verbatim: "\(dataset.patternColumns) × \(dataset.patternRows)")
                .help("Pattern columns × rows, in detector pixels")
                .font(.caption.monospaced()).foregroundStyle(.secondary).fixedSize()
        }
        .frame(height: LayoutPolicy.paneHeaderHeight)
    }

    private func content(in size: CGSize) -> some View {
        let box = LayoutPolicy.fitted(in: size, aspect: CGFloat(dataset.patternColumns) / CGFloat(dataset.patternRows))
        let presentation = session.patternPresentation
        let transform = MetalDisplayTransform(paneSize: box, imageBox: box, zoom: zp.drawZoom, offset: zp.effectiveOffset)
        let geometry = MarkGeometry(transform: transform, imageWidth: dataset.patternColumns, imageHeight: dataset.patternRows)
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
                if session.virtualGrid.tileCount > 1 {
                    DetectorGridOverlay(grid: session.virtualGrid, dataset: dataset, geometry: geometry, mixTiles: session.mixTiles, shown: shownTile)
                        .allowsHitTesting(false)
                }
                // The geometrical Kikuchi simulation of the shown position's orientation (PatternsSimulationOverlay.swift).
                if case .success(let overlay)? = session.overlay {
                    KikuchiOverlayLayer(pattern: overlay, settings: session.overlaySettings, geometry: geometry, size: box)
                }
            }
            .frame(width: box.width, height: box.height)
            .clipped()
            .contentShape(Rectangle())
            // A click on a grid cell shows that tile on the map (design §4: the tile is picked on the pattern it sits on).
            .onTapGesture { location in
                guard session.virtualGrid.tileCount > 1 else { return }
                let q = geometry.imagePoint(atPanePoint: location)
                if let tile = DetectorGridOverlay.tile(at: q, grid: session.virtualGrid, dataset: dataset) { session.showMap(.tile(tile)) }
            }
            .border(Color.white.opacity(0.08))
            .zoomPan(zoomModel, box: box, onHover: { phase in hovered(phase, geometry: geometry, canvas: presentation.canvas) })
            .zoomPanWheel(zoomModel, box: box)

            PaneFooter {
                ScaleBar(unitsPerPoint: ImageScaleBar.unitsPerPoint(perPixel: 1, imageWidth: dataset.patternColumns, boxWidth: box.width, zoom: zp.drawZoom),
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
        .accessibilityIdentifier("patterns.pattern")
        .accessibilityLabel("Pattern")
        // The detector pixel under the pointer while it is over the pattern (the status line's words), else which pattern is shown.
        .modifier(ReadoutAccessibilityValue(readout: { state.patternReadout }, fallback: title))
        .accessibilityHint(ZoomPan.accessibilityHint)
    }

    /// The detector pixel under the pointer and its stored value (the raw range maps the normalised copy back to counts), marked as the
    /// pattern pane's readout so the pane speaks it.
    private func hovered(_ phase: HoverPhase, geometry: MarkGeometry, canvas: CanvasPixels?) {
        switch phase {
        case .active(let p):
            guard let canvas, let range = canvas.rawRange else { state.setPatternReadout(nil); return }
            let q = geometry.imagePoint(atPanePoint: p)
            let x = Int(q.x.rounded()), y = Int(q.y.rounded())
            guard x >= 0, x < canvas.width, y >= 0, y < canvas.height else { state.setPatternReadout(nil); return }
            let value = range.lowerBound + canvas.normalized[y * canvas.width + x] * (range.upperBound - range.lowerBound)
            state.setPatternReadout(EBSDBrowsing.patternReadout(x: x, y: y, value: value))
        case .ended:
            state.setPatternReadout(nil)
        }
    }
}

// MARK: - The detector grid

/// The grid's lines over the pattern, through the pane's geometry (they keep their place at any zoom); the mix's tiles outlined in red, green
/// and blue, the tile on the map in the accent colour.
private struct DetectorGridOverlay: View {
    let grid: VirtualBSEGrid
    let dataset: EBSDDataset
    let geometry: MarkGeometry
    let mixTiles: [VirtualBSETile?]
    let shown: VirtualBSETile?

    /// The tile whose rectangle holds detector pixel `q`, nil off the pattern.
    static func tile(at q: ImagePoint, grid: VirtualBSEGrid, dataset: EBSDDataset) -> VirtualBSETile? {
        let x = Int(q.x.rounded()), y = Int(q.y.rounded())
        guard x >= 0, x < dataset.patternColumns, y >= 0, y < dataset.patternRows else { return nil }
        for tile in grid.tiles {
            let r = grid.rect(of: tile, patternRows: dataset.patternRows, patternColumns: dataset.patternColumns)
            if y >= r.top, y < r.bottom, x >= r.left, x < r.right { return tile }
        }
        return nil
    }

    /// The pane rectangle of a detector rectangle: pixel edges are at image coordinate −0.5 and side − 0.5.
    private func paneRect(_ r: DetectorRect) -> CGRect {
        let a = geometry.panePoint(of: ImagePoint(x: Double(r.left) - 0.5, y: Double(r.top) - 0.5))
        let b = geometry.panePoint(of: ImagePoint(x: Double(r.right) - 0.5, y: Double(r.bottom) - 0.5))
        return CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y)
    }

    var body: some View {
        let colors: [Color] = [.red, .green, .blue]
        ZStack {
            Path { p in
                for tile in grid.tiles { p.addRect(paneRect(grid.rect(of: tile, patternRows: dataset.patternRows, patternColumns: dataset.patternColumns))) }
            }
            .stroke(Color.white.opacity(0.55), lineWidth: 1)
            ForEach(Array(mixTiles.enumerated()), id: \.offset) { channel, tile in
                if let tile {
                    Path { p in p.addRect(paneRect(grid.rect(of: tile, patternRows: dataset.patternRows, patternColumns: dataset.patternColumns)).insetBy(dx: 1, dy: 1)) }
                        .stroke(colors[channel], lineWidth: 2)
                }
            }
            if let shown {
                Path { p in p.addRect(paneRect(grid.rect(of: shown, patternRows: dataset.patternRows, patternColumns: dataset.patternColumns)).insetBy(dx: 2.5, dy: 2.5)) }
                    .stroke(Color.accentColor, lineWidth: 1.5)
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - The tiles pane

/// Every tile's image (design §3, the bottom pane's Virtual images tab): the BSE first, then the grid in rows; a click makes a tile the map.
struct VirtualTilesPane: View {
    let session: EBSDSession
    let dataset: EBSDDataset

    var body: some View {
        let columns = session.virtualGrid.columns
        ScrollView {
            if let images = session.virtualImages {
                let tiles = session.virtualGrid.tiles
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 60), spacing: 8), count: max(columns, 1) + 1), spacing: 8) {
                    tileCell(title: "BSE", image: images[0], choice: .bse)
                    ForEach(tiles) { tile in
                        if let image = session.tileImage(tile) { tileCell(title: tile.label, image: image, choice: .tile(tile)) }
                    }
                }
                .padding(8)
            } else {
                Text(session.isMapping ? "Reading the scan…" : "No tiles yet").foregroundStyle(.secondary).padding()
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("patterns.tiles.pane")
    }

    private func tileCell(title: String, image: [Float], choice: EBSDSession.MapChoice) -> some View {
        let canvas = CanvasPixels.make(width: dataset.scanColumns, height: dataset.scanRows, pixels: image)
        let selected = session.mapChoice == choice
        return VStack(spacing: 3) {
            MetalImageView(pixels: canvas.normalized, width: canvas.width, height: canvas.height, contentVersion: canvas.contentVersion, colormap: .gray)
                .aspectRatio(CGFloat(dataset.scanColumns) / CGFloat(dataset.scanRows), contentMode: .fit)
                .overlay(Rectangle().stroke(selected ? Color.accentColor : Color.white.opacity(0.15), lineWidth: selected ? 2 : 1))
            Text(title).font(.caption.monospacedDigit()).foregroundStyle(selected ? Color.accentColor : .secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture { session.showMap(choice) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Tile \(title)")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("patterns.tile.\(title.replacingOccurrences(of: " ", with: "-"))")
    }
}
