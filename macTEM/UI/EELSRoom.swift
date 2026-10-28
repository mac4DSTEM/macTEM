//
//  EELSRoom.swift
//  Role: the EELS room on the EDS room's chassis. Centre: the maps block on top (the t/λ map is the anchor tile where regions are
//        drawn and edited, the ZLP shift after Align and one tile per fitted edge on the right, one shared zoom, one cursor into the status line), the spectrum
//        below (the region's low loss and core loss on one energy axis with a marked gap) with the results beside it. The tools, the Maps control, the edges,
//        the processing and fitting choices and the exports are the inspector's (`EELSRoomInspector.swift`). The room has its own document, the spectrum image,
//        opened from here and held by `EELSSession` (TEMSession). Presentation only: every number is SpectroKit's through the session, badged `validation: none`;
//        the pure parts (which tile goes where, the axis, the thickness line) are `TEMCore/EELS/EELSRoomChassis.swift`.
//        The maps block, the spectrum and the results panel live in this file because the room's file list is fixed for slice 1; they move out with slice 2.
//

import ShellControls
import ShellInspector
import ShellLayout
import ShellMetal
import ShellSpectroscopy
import SwiftUI
import UniformTypeIdentifiers
import SpectroCore
import SpectroEDX
import SpectroEELS
#if canImport(TEMCore)
import TEMCore
import TEMSession
#endif

/// What the EELS room's Export section writes, as the EDS room's (the owner's drive, 2026-10-23): the results, the spectrum, the regions, the maps as one PNG, the
/// per-pixel thickness and the method.
nonisolated enum EELSExportKind: String, CaseIterable, Identifiable {
    case results, spectrum, regions, mapsPNG, diagnostics, method
    var id: String { rawValue }
    var title: String {
        switch self {
        case .results: "Results CSV…"
        case .spectrum: "Spectrum CSV…"
        case .regions: "Regions CSV…"
        case .mapsPNG: "Maps…"
        case .diagnostics: "Per-pixel CSV…"
        case .method: "Method JSON…"
        }
    }
    var contentType: UTType {
        switch self {
        case .method: .json
        case .mapsPNG: .png
        default: .commaSeparatedText
        }
    }
    /// The file name's tail after the file's own name: "143_STEM SI results".
    var suffix: String {
        switch self {
        case .results: " results"
        case .spectrum: " spectrum"
        case .regions: " regions"
        case .mapsPNG: " maps"
        case .diagnostics: " thickness"
        case .method: " thickness method"
        }
    }
}

extension EELSSession {
    /// What "Maps…" draws: the colour mix first, then the maps the block shows, each on its own scale in its colour, the selected region over them, and the
    /// scale bar from the file's scan pixel size.
    @MainActor func figureContent(maps: [EELSMapTile], mix: [EELSMapTile], appearance: MapAppearance, scaleBar: Bool, regions: Bool) -> EDXFigureContent? {
        guard let image = source?.image, !maps.isEmpty else { return nil }
        var cells: [EDXFigureCell] = []
        if !mix.isEmpty {
            cells.append(EDXFigureCell(id: "colourMix", title: "Colour mix", detail: mix.map(\.title).joined(separator: " + "),
                                       rgba: MapRaster.mix(EELSMixComposition.layers(mix, appearance: appearance), count: image.nx * image.ny),
                                       width: image.nx, height: image.ny, footer: nil))
        }
        for tile in maps {
            let flat = EELSMapScale.isFlat(tile.values)
            let values = flat ? EELSMapScale.flatValues(tile.values) : EELSMapScale.scaled(tile.values, mode: EELSMapScale.mode(forTileID: tile.id)).values
            let coloring = flat ? MapColoring.colormap(.gray) : appearance.coloring(for: tile.id, default: EELSTileStyle.defaultColoring(tile.id))
            cells.append(EDXFigureCell(id: tile.id, title: tile.title, detail: tile.detailText ?? "",
                                       rgba: MapRaster.rgba(values: values, coloring: coloring, upper: 1, adjustment: flat ? MapAdjustment() : appearance.adjustment(for: tile.id)),
                                       width: tile.width, height: tile.height, footer: tile.footer))
        }
        let region = selectedPin?.region ?? .wholeMap
        return EDXFigureContent(title: fileName, subtitle: (selectedPin?.name ?? "Whole map") + " \u{00B7} EELS, validation: none", tiles: [], region: region,
                                nx: image.nx, ny: image.ny, bar: EDXExports.scaleBar(pixelSize: scanPixel?.size, unit: scanPixel?.unit, nx: image.nx, ny: image.ny),
                                showsScaleBar: scaleBar, showsRegion: regions, cells: cells)
    }
}

struct EELSRoom: View {
    @Environment(AppState.self) private var appState
    @State private var showImporter = false

    private var importTypes: [UTType] { EELSOpening.readableExtensions.compactMap { UTType(filenameExtension: $0) } }

    var body: some View {
        let session = appState.eels
        let state = appState.eelsRoom
        Group {
            if session.isOpening {
                // Opening: a bar in the centre and Stop (the toolbar's Stop and ⌘. do the same).
                VStack(spacing: 12) {
                    ProgressView().progressViewStyle(.linear).frame(maxWidth: EDXLayout.openingBarWidth)
                    Text("Opening spectrum image").font(.headline)
                    Button("Stop") { session.stop() }
                        .keyboardShortcut(.cancelAction)
                        .accessibilityIdentifier("eels.opening.stop")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("eels.opening")
            } else if session.hasImage {
                // No strip above the maps: the file and the stage are the toolbar's display; the tools and the Maps control are the inspector's.
                VerticalPaneSplit(storageKey: "eels.lowerSplit", defaultFraction: 0.6, resizeLabel: "Resize the maps and the spectrum", topName: "Maps",
                                  minimumTop: EDXLayout.lowerPaneMinimumHeight, minimumBottom: EDXLayout.lowerPaneMinimumHeight) {
                    EELSMapsBlock(session: session, state: state)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } bottom: {
                    EELSLowerPane(session: session, state: state)
                }
            } else {
                ContentUnavailableView {
                    Label("No EELS spectrum image open", systemImage: "chart.xyaxis.line")
                } description: {
                    Text("Open a GMS .dm4 or Velox .emd spectrum image that holds an EELS signal.")
                } actions: {
                    Button("Open EELS Spectrum Image…") { state.requestImport() }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("eels.openImage")
                }
            }
        }
        .onChange(of: state.importRequest) { showImporter = true }
        .onChange(of: session.fileName) { state.reset() }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: importTypes, allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls): if let url = urls.first { session.open(url: url) }
            case .failure(let error): appState.present(error)
            }
        }
        .fileExporter(isPresented: Binding(get: { state.exporting != nil }, set: { if !$0 { state.exporting = nil } }),
                      document: EDXExportFile(data: state.exportData),
                      contentType: state.exporting?.contentType ?? .commaSeparatedText,
                      defaultFilename: (session.fileName as NSString).deletingPathExtension + (state.exporting?.suffix ?? "")) { result in
            switch result {
            case .success(let url): appState.statusText = "Exported \(url.lastPathComponent)"
            case .failure(let error): appState.present(error)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("eels.room")
    }
}

// MARK: - The maps

/// A tile's colours until the person changes them: t/λ, t and I total on viridis, the zero-loss shift diverging (centred on 0), an edge or an at% map black to its
/// element's colour. The scale of each is `EELSMapScale`.
nonisolated enum EELSTileStyle {
    static func hue(forID id: String) -> Double {
        let symbol = id.hasPrefix("edge-") ? String(id.dropFirst(5).prefix { $0 != "-" }) : (id.hasPrefix("at-") ? String(id.dropFirst(3)) : "")
        return symbol.isEmpty ? 0.5 : EDXRoomFormat.hue(symbol: symbol)
    }

    static func defaultColoring(_ id: String) -> MapColoring {
        switch EELSMapScale.mode(forTileID: id) {
        case .diverging: return .colormap(.rdbu)
        case .minToMax: return .colormap(.viridis)
        case .zeroToMax:
            let rgb = EDXRoomFormat.rgb(hue: hue(forID: id))
            return .color(RegionColor(red: rgb.0, green: rgb.1, blue: rgb.2))
        }
    }
}

/// One tile of the maps block: a map, or the colour mix (the anchor, as in the EDS room).
struct EELSGridItem: Identifiable {
    enum Kind { case map(EELSMapTile), mix([EELSMapTile]) }
    let id: String
    let kind: Kind

    static let mixID = "colourMix"
}

/// The colour mix of the EELS maps, as the EDS room's (`EDXMapsComposition`; the owner, 2026-10-23: "i can't overlay maps in a colormix on the left"): the mix is the
/// anchor on the left, where regions are drawn; every map the Maps control shows is a tile on the right, and a click on one puts it in the mix or takes it out.
nonisolated enum EELSMixComposition {
    static let placeholder = "Select maps on the right to build the colour mix"

    /// The maps on the right: the Maps control's quantity first (t/λ, t or the ZLP shift), then the rest.
    static func maps(anchor: EELSMapTile?, rest: [EELSMapTile]) -> [EELSMapTile] { (anchor.map { [$0] } ?? []) + rest }

    /// The ids in the mix: the person's choice among the maps shown, else the fitted edges (or their at%) once there are any, else the first map (t/λ).
    static func selection(_ mix: ColorMix, maps: [EELSMapTile]) -> [String] {
        let ids = maps.map(\.id)
        if mix.isCustom { return ids.filter(mix.members.contains) }
        let edges = maps.filter { $0.id.hasPrefix("edge-") || $0.id.hasPrefix("at-") }.map(\.id)
        return edges.isEmpty ? Array(ids.prefix(1)) : edges
    }

    /// A click on a map: in the mix or out. The choice becomes the person's (an empty choice is a valid one).
    static func toggle(_ id: String, in mix: inout ColorMix, maps: [EELSMapTile]) {
        var chosen = Set(selection(mix, maps: maps))
        if !chosen.insert(id).inserted { chosen.remove(id) }
        mix.members = maps.map(\.id).filter(chosen.contains)
        mix.isCustom = true
    }

    /// One layer per map in the mix, each on its own 0...1 scale (`EELSMapScale`) in the map's colour (an edge's element colour, a colormap's top colour).
    static func layers(_ members: [EELSMapTile], appearance: MapAppearance) -> [MapRaster.MixLayer] {
        members.map { tile in
            let values = EELSMapScale.isFlat(tile.values) ? EELSMapScale.flatValues(tile.values) : EELSMapScale.scaled(tile.values, mode: EELSMapScale.mode(forTileID: tile.id)).values
            let color = appearance.coloring(for: tile.id, default: EELSTileStyle.defaultColoring(tile.id)).endColor
            return MapRaster.MixLayer(values: values, color: color, upper: 1, adjustment: appearance.adjustment(for: tile.id))
        }
    }
}

/// The maps block: the colour mix as the anchor where regions are drawn and edited, the maps beside it (a click puts one in the mix), all on one zoom.
struct EELSMapsBlock: View {
    let session: EELSSession
    @Bindable var state: EELSRoomState

    /// The maps on the right as the Maps control picks them (what the mix chooses from, and what "Maps…" exports).
    static func shownMaps(_ session: EELSSession, _ state: EELSRoomState) -> [EELSMapTile] {
        let availability = session.mapsAvailability
        let c = EELSMapsComposition.compose(selection: availability.effective(state.maps), onlyCoreLoss: availability.onlyCoreLoss, tiles: session.tiles,
                                            shiftTile: session.alignmentShiftTile, modelTiles: session.modelTiles)
        return EELSMixComposition.maps(anchor: c.anchor, rest: c.rest)
    }

    var body: some View {
        // One read of each observed property, here, handed down as values.
        let availability = session.mapsAvailability
        let composition = EELSMapsComposition.compose(selection: availability.effective(state.maps), onlyCoreLoss: availability.onlyCoreLoss, tiles: session.tiles,
                                                      shiftTile: session.alignmentShiftTile, modelTiles: session.modelTiles)
        let readoutTiles = session.tiles + (session.alignmentShiftTile.map { [$0] } ?? []) + session.modelTiles
        let regions = EELSRegionBridge.set(session, linesFocused: state.linesFocused)
        let image = session.source?.image
        let aspect = EELSMapsComposition.aspect(nx: image?.nx, ny: image?.ny)
        let (align, thickness, fit) = (session.alignState, session.thicknessState, session.fitState)
        let running = session.isComputing
        Group {
            if composition.anchor == nil && composition.rest.isEmpty {
                VStack(spacing: 8) {
                    if let failure = session.failure {
                        Label(failure, systemImage: "xmark.octagon.fill").font(.callout).foregroundStyle(.red).multilineTextAlignment(.center)
                            .accessibilityIdentifier("eels.failure")
                    } else {
                        ProgressView().controlSize(.regular)
                        Text("Mapping the thickness…").foregroundStyle(.secondary)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let maps = EELSMixComposition.maps(anchor: composition.anchor, rest: composition.rest)
                let chosen = Set(EELSMixComposition.selection(state.appearance.mix, maps: maps))
                let mix = EELSGridItem(id: EELSGridItem.mixID, kind: .mix(maps.filter { chosen.contains($0.id) }))
                AnchoredMapsBlock(anchor: mix, items: maps.map { EELSGridItem(id: $0.id, kind: .map($0)) }, aspect: CGFloat(aspect), storageKey: "eels.mapsSplit",
                                  solo: $state.soloTile, soloEnabled: false) { item, size, isAnchor in
                    EELSMapTileHost(item: item, size: size, isAnchor: isAnchor, session: session, readoutTiles: readoutTiles, maps: maps,
                                    regions: isAnchor ? regions : nil, state: state,
                                    isStale: EELSMapsComposition.isStale(item.id, thickness: thickness, fit: fit, align: align), isRunning: running)
                }
            }
        }
        .accessibilityIdentifier("eels.maps")
    }
}

/// One tile with its picture made off the main actor, and the wiring of its regions, cursor and colour popover: a map (a click puts it in the mix) or the mix.
private struct EELSMapTileHost: View {
    let item: EELSGridItem
    let size: CGSize
    let isAnchor: Bool
    let session: EELSSession
    let readoutTiles: [EELSMapTile]
    /// Every map on the right (what the mix chooses from).
    let maps: [EELSMapTile]
    let regions: SpectralRegionSet?
    @Bindable var state: EELSRoomState
    let isStale: Bool
    let isRunning: Bool
    @State private var image: CGImage?

    var body: some View {
        switch item.kind {
        case .map(let tile): mapTile(tile)
        case .mix(let members): mixTile(members)
        }
    }

    private var tileRegions: MapTileRegions? {
        regions.map { set in
            MapTileRegions(set: set, tool: state.tool,
                           onRectangle: { state.linesFocused = false; session.drawRegion(.rectangle(PixelRect(x0: $0, y0: $1, x1: $2, y1: $3))) },
                           onEllipse: { state.linesFocused = false; session.drawRegion(.ellipse(PixelRect(x0: $0, y0: $1, x1: $2, y1: $3))) },
                           onPolygon: { state.linesFocused = false; session.drawRegion(.polygon($0.map { PixelPoint(x: $0.x, y: $0.y) })) },
                           onLine: { if session.drawLine(from: PixelPoint(x: $0.x, y: $0.y), to: PixelPoint(x: $1.x, y: $1.y)) != nil { state.linesFocused = true } },
                           onEdit: { EELSRegionBridge.edit($0, $1, in: session) },
                           onDrag: { session.previewRegion($0.flatMap { EDXRegionBridge.region($0.geometry) }) },
                           onSelect: { EELSRegionBridge.select($0, in: session, state: state) },
                           onDelete: { EELSRegionBridge.deleteSelected(in: session, state: state) })
        }
    }

    private func hover(_ pixel: (x: Int, y: Int)?) {
        state.readout = pixel.map { p in
            let refusal = session.map.flatMap { m in p.x < m.nx && p.y < m.ny ? m[p.x, p.y].unavailable?.description : nil }
            return EELSRoomFormat.readout(x: p.x, y: p.y, tiles: readoutTiles, refusal: refusal)
        }
    }

    /// The colour mix: one layer per chosen map; regions are drawn here.
    @ViewBuilder private func mixTile(_ members: [EELSMapTile]) -> some View {
        let layers = EELSMixComposition.layers(members, appearance: state.appearance)
        let w = session.source?.image.nx ?? members.first?.width ?? 1, h = session.source?.image.ny ?? members.first?.height ?? 1
        let key = members.isEmpty ? "mix-empty" : "mix-" + members.map { t in
            "\(t.id)\(t.version)-\(state.appearance.coloring(for: t.id, default: EELSTileStyle.defaultColoring(t.id)).hashValue)-\(state.appearance.adjustment(for: t.id).hashValue)"
        }.joined(separator: "|")
        MapTileView(title: "Colour mix", detail: members.isEmpty ? nil : members.map(\.title).joined(separator: " + "), image: members.isEmpty ? nil : image, size: size,
                    scanWidth: w, scanHeight: h, pixelSize: session.scanPixel?.size, pixelUnit: session.scanPixel?.unit, regions: tileRegions,
                    placeholder: members.isEmpty ? EELSMixComposition.placeholder : nil, transform: $state.mapView,
                    onHover: { hover($0) },
                    controls: { EmptyView() })
            .opacity(isRunning ? 0.5 : 1)
            .task(id: key) {
                guard !members.isEmpty else { image = nil; return }
                let count = w * h
                image = await Task.detached(priority: .userInitiated) { EDXMapRaster.cgImage(rgba: MapRaster.mix(layers, count: count), width: w, height: h) }.value
            }
    }

    @ViewBuilder private func mapTile(_ tile: EELSMapTile) -> some View {
        let coloring = state.appearance.coloring(for: tile.id, default: EELSTileStyle.defaultColoring(tile.id))
        let adjustment = state.appearance.adjustment(for: tile.id)
        let inMix = EELSMixComposition.selection(state.appearance.mix, maps: maps).contains(tile.id)
        MapTileView(title: tile.title, detail: tile.detailText, image: image, size: size, scanWidth: tile.width, scanHeight: tile.height,
                    pixelSize: session.scanPixel?.size, pixelUnit: session.scanPixel?.unit, regions: tileRegions,
                    inMix: inMix, onToggleMix: { EELSMixComposition.toggle(tile.id, in: &state.appearance.mix, maps: maps) },
                    transform: $state.mapView,
                    onHover: { hover($0) },
                    controls: { EELSMapPopover(tile: tile, state: state) })
            .opacity(isRunning ? 0.5 : (isStale ? 0.7 : 1))
            .task(id: "\(tile.id)-\(tile.version)-\(coloring.hashValue)-\(adjustment.hashValue)") {
                let values = tile.values, coloring = coloring, adjustment = adjustment, w = tile.width, h = tile.height
                let mode = EELSMapScale.mode(forTileID: tile.id)
                image = await Task.detached(priority: .userInitiated) {
                    // NaN (a pixel the kit refused) stays at the bottom of the scale; a stale tile is drawn as it was. A map whose pixels are all one value has no range:
                    // it is drawn at the middle of a neutral grey ramp (never the white of a diverging scale's centre) and the tile's detail names the value.
                    if EELSMapScale.isFlat(values) {
                        return EDXMapRaster.cgImage(rgba: MapRaster.rgba(values: EELSMapScale.flatValues(values), coloring: .colormap(.gray), upper: 1, adjustment: MapAdjustment()), width: w, height: h)
                    }
                    let scaled = EELSMapScale.scaled(values, mode: mode)
                    return EDXMapRaster.cgImage(rgba: MapRaster.rgba(values: scaled.values, coloring: coloring, upper: 1, adjustment: adjustment), width: w, height: h)
                }.value
            }
    }
}

/// The popover of a tile's scale bar: MacEMUI's `MapDisplayPopover` over the tile's values (an edge or at% tile: its element colour; the others: their colormap). The
/// histogram is made once per tile version, off the main actor, over the range the picture is scaled to; the window and the gamma are the tile's `MapAdjustment`.
private struct EELSMapPopover: View {
    let tile: EELSMapTile
    @Bindable var state: EELSRoomState
    @State private var shown: Shown?

    struct Shown {
        var counts: [Int]
        var statistics: HistogramStatistics
    }

    private var effective: MapAdjustment { state.appearance.adjustments[tile.id] ?? MapAdjustment() }
    /// The window is stored unless it is the default one.
    private func commit(_ a: MapAdjustment) { state.appearance.adjustments[tile.id] = a == MapAdjustment() ? nil : a }
    private func binding(_ keyPath: WritableKeyPath<MapAdjustment, Double>) -> Binding<Double> {
        Binding(get: { effective[keyPath: keyPath] }, set: { var a = effective; a[keyPath: keyPath] = $0; commit(a) })
    }

    var body: some View {
        MapDisplayPopover(kind: kind, histogram: shown.map { MapDisplayHistogram(counts: $0.counts, statistics: $0.statistics, title: "Histogram") }, low: binding(\.low), high: binding(\.high), gamma: binding(\.gamma),
                          reset: { state.appearance.adjustments[tile.id] = nil })
            .formStyle(.grouped).scrollContentBackground(.hidden).fixedSize(horizontal: false, vertical: true)
            .task(id: "\(tile.id)-\(tile.version)") {
                let values = tile.values, mode = EELSMapScale.mode(forTileID: tile.id)
                shown = await Task.detached(priority: .userInitiated) { Self.histogram(values: values, mode: mode) }.value
            }
    }

    private var kind: MapDisplayPopover.Kind {
        switch EELSTileStyle.defaultColoring(tile.id) {
        case .color:
            let fallback = EELSTileStyle.defaultColoring(tile.id)
            return .element(color: Binding(get: { state.appearance.coloring(for: tile.id, default: fallback).endColor }, set: { state.appearance.set(.color($0), for: tile.id) }))
        case .colormap(let fallback):
            return .reference(colormap: Binding(get: { if case .colormap(let k) = state.appearance.coloring(for: tile.id, default: .colormap(fallback)) { k } else { fallback } },
                                                set: { state.appearance.set(.colormap($0), for: tile.id) }))
        }
    }

    /// The histogram of the finite values over the range the picture is scaled to (the window is a fraction of that range); none for a flat map.
    private nonisolated static func histogram(values: [Double], mode: EELSMapScale.Mode) -> Shown? {
        let finite = values.filter(\.isFinite)
        guard !finite.isEmpty, !EELSMapScale.isFlat(values) else { return nil }
        let scaled = EELSMapScale.scaled(values, mode: mode)
        guard scaled.high > scaled.low else { return nil }
        let statistics = HistogramStatistics(minimum: Float(scaled.low), maximum: Float(scaled.high), mean: Float(finite.reduce(0, +) / Double(finite.count)))
        return Shown(counts: MapHistogram.bins(values: values, range: scaled.low...scaled.high), statistics: statistics)
    }
}

// MARK: - The spectrum and the results

/// The lower block: the spectrum (the region's low loss and core loss on one axis; a profile along a drawn line as a faint inset over it) and the results beside it.
struct EELSLowerPane: View {
    let session: EELSSession
    @Bindable var state: EELSRoomState

    var body: some View {
        let profile = EELSRegionBridge.series(session) { EELSTileStyle.hue(forID: $0) }
        let refusals = Dictionary(session.refusals.map { (EELSFitCompute.id($0.edge), $0.reason) }, uniquingKeysWith: { first, _ in first })
        let items = session.plot?.core == nil ? [] : session.pickedEdges.map { EELSWindowItem(edge: $0, windows: session.windows(for: $0), refusal: refusals[EELSFitCompute.id($0)]) }
        let layers = Self.layers(session)
        HorizontalPaneSplit(storageKey: "eels.resultsSplit", defaultFraction: 0.6, resizeLabel: "Resize the spectrum and the results", leadingName: "Spectrum",
                            minimumLeading: EDXLayout.spectrumMinimumWidth, minimumTrailing: EDXLayout.resultsWidth.min) {
            EELSSpectrumView(plot: session.plot, items: items, references: session.references, layers: layers,
                             onWindows: { session.setWindows($1, for: $0) },
                             onResetWindows: { edge in if let edge { session.resetWindows(for: edge) } else { session.resetAllWindows() } },
                             hasEditedWindows: session.hasEditedWindows, state: state)
                .overlay(alignment: .bottomLeading) {
                    // The regions' names in their colours, as in the EDS room (one entry per region: its low loss and core loss share the colour).
                    SpectrumLayerLegend(layers: layers.reduce(into: [SpectrumLayer]()) { out, l in if !out.contains(where: { $0.name == l.name }) { out.append(l) } })
                        .padding(.leading, 56).padding(.bottom, 40)
                }
                .overlay(alignment: .topTrailing) {
                    if !profile.isEmpty {
                        ProfileChart(series: profile, unit: "px", valueTitle: "Value")
                            .frame(width: 240, height: 120)   // science: an inset chart
                            .padding(6)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
                            .padding(8)
                    }
                }
        } trailing: {
            EELSResultsPanel(session: session)
        }
    }

    /// Each visible region's low loss and core loss, in its colour, drawn over the selected region's spectrum (the EDS room's `EDXRegionBridge.layers`). The low loss
    /// is on the file's low-loss axis, the core loss on the working core loss's (the plot's own two axes).
    static func layers(_ session: EELSSession) -> [SpectrumLayer] {
        guard let plot = session.plot else { return [] }
        var out: [SpectrumLayer] = []
        // A region is selected: the whole map in grey under it, so the region reads against the whole (the owner's drive, 2026-10-23).
        if session.selectedPinID != nil, let whole = session.wholeMapPlot {
            let grey = RegionColor(red: 0.55, green: 0.55, blue: 0.55)
            out.append(SpectrumLayer(id: "wholeMap-low", name: "Whole map", color: grey, origin: whole.low.origin, step: whole.low.step, counts: whole.low.counts))
            if let core = whole.core {
                out.append(SpectrumLayer(id: "wholeMap-core", name: "Whole map", color: grey, origin: core.origin, step: core.step, counts: core.counts))
            }
        }
        for pin in session.pins where pin.isVisible {
            let color = EDXRegionBridge.color(pin.color, number: pin.number)
            if let low = session.pinSpectra[pin.id] {
                out.append(SpectrumLayer(id: "\(pin.id.uuidString)-low", name: pin.name, color: color, origin: plot.low.origin, step: plot.low.step, counts: low))
            }
            if let core = session.pinCoreSpectra[pin.id], let axis = plot.core {
                out.append(SpectrumLayer(id: "\(pin.id.uuidString)-core", name: pin.name, color: color, origin: axis.origin, step: axis.step, counts: core))
            }
        }
        return out
    }
}

/// What a drag on the EELS spectrum does, by where it starts (pure; the EDS spectrum's `EDXSpectrumDrag` with the EELS view's measured left margin): under the plot
/// the energy axis, left of it the counts axis, inside it a pan (or an edge's window, when the drag starts on one).
nonisolated enum EELSSpectrumDrag {
    typealias Zone = EDXSpectrumDrag.Zone
    static let bottom: CGFloat = 36

    static func zone(start: CGPoint, size: CGSize, left: CGFloat) -> Zone {
        if start.y > size.height - bottom { return .energyAxis }
        if start.x < left { return .countsAxis }
        return .plot
    }
}

/// One edge's windows as the spectrum draws and drags them.
struct EELSWindowItem: Equatable {
    let edge: CoreLossEdge
    let windows: EELSEdgeWindows
    /// The sentence that refuses the edge (its window sits on a stretch with no counts), or nil.
    let refusal: String?
}

/// The region's low loss and core loss on one energy axis (a marked gap when the windows leave energies out), counts on a log axis: the zero-loss mask hatched, each picked edge's
/// background and signal windows shaded and draggable with the background extrapolated under the signal, the kit's model curve in the accent, its power-law background dashed,
/// the references dashed. Hover reads energy and counts into the status line, snapped to an edge onset within 5 eV.
private struct EELSSpectrumView: View {
    let plot: EELSPlotData?
    let items: [EELSWindowItem]
    let references: [EELSReference]
    /// The regions' spectra drawn over the selected one (`EELSLowerPane.layers`).
    let layers: [SpectrumLayer]
    let onWindows: (CoreLossEdge, EELSEdgeWindows) -> Void
    /// Back to the kit's default windows: one edge's, or every edge's (nil).
    let onResetWindows: (CoreLossEdge?) -> Void
    let hasEditedWindows: Bool
    @Bindable var state: EELSRoomState
    @State private var drag: (id: String, handle: EELSEdgeWindows.Handle, start: EELSEdgeWindows, energy: Double)?
    /// A drag that is not a window's: the axis zoom or the pan, from the window and counts zoom it started at (the EDS spectrum's gestures).
    @State private var viewDrag: (zone: EELSSpectrumDrag.Zone, window: ClosedRange<Double>, yZoom: Double)?
    @State private var pinchStart: ClosedRange<Double>?

    private static let bottom: CGFloat = 36, top: CGFloat = 20, right: CGFloat = 8, gapWidth: CGFloat = 30, handleReach: CGFloat = 5

    /// The counts scale over the energies shown: log10 from 1 to the next power of ten above the largest value, or linear from 0; the counts zoom lowers the top.
    private struct Scale {
        var logTop: Double, linearTop: Double
        init(_ plot: EELSPlotData, shown: ClosedRange<Double>, yZoom: Double, layers: [SpectrumLayer] = []) {
            var largest = 1.0
            func scan(_ curve: EELSPlotCurve, _ values: [Double]) {
                for (i, v) in values.enumerated() where v.isFinite && shown.contains(curve.energy(i)) { largest = max(largest, v) }
            }
            scan(plot.low, plot.low.counts)
            for layer in layers { scan(EELSPlotCurve(origin: layer.origin, step: layer.step, counts: layer.counts), layer.counts) }
            if let core = plot.core { scan(core, core.counts); if let model = plot.model { scan(core, model) } }
            let zoom = max(yZoom, 1)
            logTop = max(ceil(log10(largest)) - log10(zoom), 1); linearTop = largest * 1.08 / zoom
        }
        func labels(isLog: Bool) -> [(value: Double, text: String)] {
            isLog ? (0...Int(logTop.rounded(.down))).map { (pow(10, Double($0)), EELSRoomFormat.logTickLabel(decade: $0)) }
                  : [0, 0.25, 0.5, 0.75, 1].map { f in let v = linearTop / 1.08 * f; return (v, EDXRoomFormat.counts(v)) }
        }
    }

    private func domain(_ plot: EELSPlotData) -> ClosedRange<Double> { EELSOneAxis.domain(low: plot.low.range, core: plot.core?.range) }
    private func minimumSpan(_ plot: EELSPlotData) -> Double { 2 * min(plot.low.step, plot.core?.step ?? plot.low.step) }

    /// The energy window shown: the person's zoom, else the whole axis.
    private func window(_ plot: EELSPlotData) -> ClosedRange<Double> {
        state.spectrumWindow.map { EDXSpectrumWindow.clamp($0, domain: domain(plot), minimumSpan: minimumSpan(plot)) } ?? domain(plot)
    }

    private func axis(_ plot: EELSPlotData, window: ClosedRange<Double>, width: CGFloat, left: CGFloat) -> EELSOneAxis {
        let cut = EELSOneAxis.windowed(low: plot.low.range, core: plot.core?.range, window: window) ?? (window, nil)
        return EELSOneAxis(low: cut.low, core: cut.core, width: Double(max(width - left - Self.right, 1)), gapWidth: Double(Self.gapWidth))
    }

    /// Where a point sits in the window, 0...1 (the zoom's anchor); the middle in the gap.
    private func anchor(_ x: CGFloat, axis: EELSOneAxis, left: CGFloat, window w: ClosedRange<Double>) -> Double {
        guard let e = axis.energy(atX: Double(x - left)), w.upperBound > w.lowerBound else { return 0.5 }
        return min(max((e - w.lowerBound) / (w.upperBound - w.lowerBound), 0), 1)
    }

    var body: some View {
        GeometryReader { geo in
            if let plot {
                let isLog = state.spectrumIsLog
                let w = window(plot)
                let scale = Scale(plot, shown: w, yZoom: state.spectrumYZoom, layers: layers)
                let left = CGFloat(EELSRoomFormat.leftMargin(labels: scale.labels(isLog: isLog).map(\.text)))
                let axis = axis(plot, window: w, width: geo.size.width, left: left)
                let plotWidth = max(geo.size.width - left - Self.right, 1)
                // Under each edge: the kit's fitted power law while the windows are the ones the fit used, else the kit's preview of the windows as they are now (the live drag).
                let backgrounds = items.map { item -> [Double]? in
                    if let fitted = plot.backgrounds.first(where: { $0.edgeID == EELSFitCompute.id(item.edge) }), fitted.windows == item.windows { return fitted.curve }
                    return plot.core.flatMap { EELSBackgroundFit.extrapolation(of: $0, windows: item.windows, over: item.windows.background.lowerBound...item.windows.signal.upperBound) }
                }
                Canvas { context, size in
                    Self.draw(&context, size: size, left: left, plot: plot, axis: axis, shown: w, scale: scale, isLog: isLog, items: items, backgrounds: backgrounds,
                              references: references, layers: layers)
                }
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let p):
                        guard p.x >= left, p.x <= geo.size.width - Self.right, let e = axis.energy(atX: Double(p.x - left)) else { state.readout = nil; return }
                        state.readout = Self.readout(at: e, plot: plot)
                    case .ended: state.readout = nil
                    }
                }
                .gesture(MagnifyGesture()
                    .onChanged { v in
                        let start = pinchStart ?? w
                        if pinchStart == nil { pinchStart = start }
                        state.spectrumWindow = EDXSpectrumWindow.zoomed(start, factor: v.magnification, anchor: anchor(v.startLocation.x, axis: axis, left: left, window: start),
                                                                       domain: domain(plot), minimumSpan: minimumSpan(plot))
                    }
                    .onEnded { _ in pinchStart = nil })
                .onScrollWheel { event in
                    state.spectrumWindow = EDXSpectrumWindow.zoomed(w, factor: ScrollZoom.factor(delta: event.delta, isPrecise: event.isPrecise),
                                                                   anchor: anchor(event.location.x, axis: axis, left: left, window: w), domain: domain(plot), minimumSpan: minimumSpan(plot))
                }
                // High priority, as the EDS spectrum's (a plain `.gesture` reached a counts-axis drag only on release). A drag that starts on an edge's window or its end
                // moves or resizes it; one under the plot zooms the energy axis, one left of it the counts axis, any other pans.
                .highPriorityGesture(DragGesture(minimumDistance: 2)
                    .onChanged { value in
                        if drag == nil && viewDrag == nil {
                            if plot.core != nil, let e = axis.energy(atX: Double(value.startLocation.x - left)), let seg = axis.segments.last,
                               EELSSpectrumDrag.zone(start: value.startLocation, size: geo.size, left: left) == .plot {
                                let perPoint = (seg.energy.upperBound - seg.energy.lowerBound) / max(seg.x.upperBound - seg.x.lowerBound, 1)
                                let tolerance = Double(Self.handleReach) * perPoint
                                // The nearest end of any edge's windows wins; a body only when no end is in reach.
                                let hits = items.compactMap { item in item.windows.handle(at: e, tolerance: tolerance).map { (item, $0) } }
                                if let hit = hits.first(where: { ![.backgroundBody, .signalBody].contains($0.1) }) ?? hits.first {
                                    drag = (EELSFitCompute.id(hit.0.edge), hit.1, hit.0.windows, e)
                                }
                            }
                            if drag == nil { viewDrag = (EELSSpectrumDrag.zone(start: value.startLocation, size: geo.size, left: left), w, state.spectrumYZoom) }
                        }
                        if let d = drag {
                            guard let core = plot.core, let item = items.first(where: { EELSFitCompute.id($0.edge) == d.id }),
                                  let e = axis.energy(atX: Double(value.location.x - left)) ?? axis.segments.last.map({ value.location.x - left < 0 ? $0.energy.lowerBound : $0.energy.upperBound }) else { return }
                            onWindows(item.edge, d.start.moved(d.handle, by: e - d.energy, within: core.range))
                        } else if let v = viewDrag {
                            switch v.zone {
                            case .energyAxis:
                                state.spectrumWindow = EDXSpectrumWindow.zoomed(v.window, factor: exp(Double(value.translation.width) / 150),
                                                                               anchor: anchor(value.startLocation.x, axis: axis, left: left, window: v.window),
                                                                               domain: domain(plot), minimumSpan: minimumSpan(plot))
                            case .countsAxis:
                                state.spectrumYZoom = EDXSpectrumDrag.yZoom(start: v.yZoom, dy: Double(value.translation.height))
                            case .plot:
                                state.spectrumWindow = EDXSpectrumWindow.panned(v.window, byFraction: -Double(value.translation.width / plotWidth),
                                                                               domain: domain(plot), minimumSpan: minimumSpan(plot))
                            }
                        }
                    }
                    .onEnded { _ in drag = nil; viewDrag = nil })
                // A double click on an edge's window puts that edge's windows back to the kit's defaults; anywhere else it returns to the whole spectrum.
                .onTapGesture(count: 2) { p in
                    if let e = axis.energy(atX: Double(p.x - left)), let item = items.first(where: { $0.windows.background.contains(e) || $0.windows.signal.contains(e) }) {
                        onResetWindows(item.edge)
                    } else {
                        state.spectrumWindow = nil; state.spectrumYZoom = 1
                    }
                }
                .contextMenu {
                    Picker("Counts axis", selection: $state.spectrumIsLog) {
                        Text("Linear").tag(false)
                        Text("Log").tag(true)
                    }
                    .pickerStyle(.inline)
                    if !items.isEmpty {
                        Divider()
                        ForEach(items.map { (id: EELSFitCompute.id($0.edge), edge: $0.edge) }, id: \.id) { item in
                            Button("Reset \(EELSFitCompute.title(item.edge)) Windows") { onResetWindows(item.edge) }
                        }
                        Button("Reset All Windows") { onResetWindows(nil) }.disabled(!hasEditedWindows)
                    }
                }
                // The region's name on the right: the counts axis's title owns the top left (they overlapped, the owner's drive 2026-10-23).
                .overlay(alignment: .topTrailing) {
                    Text("\(plot.regionName) · \(plot.pixels) px").font(.caption).foregroundStyle(.secondary).padding(.trailing, Self.right + 4).padding(.top, 2)
                }
                .help("Hover for energy and counts; drag a window or its edge to move or resize it, double-click it for its default; scroll or pinch to zoom, drag to pan, drag along an axis to zoom it, double-click elsewhere for the whole spectrum; right-click for a linear or log counts axis and to reset windows")
                .accessibilityElement()
                .accessibilityLabel("Spectrum of \(plot.regionName), \(isLog ? "log" : "linear") counts")
                .accessibilityIdentifier("eels.spectrum")
            } else {
                Text("The spectrum appears once the file is read.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    /// "1305 eV · Mg K onset · 4 567 counts" snapped to an onset, else "283.5 eV · 4 567 counts".
    private static func readout(at energy: Double, plot: EELSPlotData) -> String {
        let snapped = EELSOneAxis.snappedOnset(energy, among: plot.edges.map(\.onsetEV))
        let e = snapped ?? energy
        let counts: Double? = {
            for curve in [plot.core, plot.low].compactMap({ $0 }) where curve.range.contains(e) {
                let i = Int(((e - curve.origin) / curve.step).rounded(.down))
                if curve.counts.indices.contains(i) { return curve.counts[i] }
            }
            return nil
        }()
        let title = snapped.flatMap { s in plot.edges.first { $0.onsetEV == s }?.title }
        return ([EELSRoomFormat.sig(e, 5) + " eV"] + [title.map { "\($0) onset" }].compactMap { $0 } + [counts.map { EDXRoomFormat.counts($0) + " counts" }].compactMap { $0 })
            .joined(separator: " · ")
    }

    private static func draw(_ context: inout GraphicsContext, size: CGSize, left: CGFloat, plot: EELSPlotData, axis: EELSOneAxis, shown: ClosedRange<Double>, scale: Scale,
                             isLog: Bool, items: [EELSWindowItem], backgrounds: [[Double]?], references: [EELSReference], layers: [SpectrumLayer]) {
        let area = CGRect(x: left, y: top, width: max(size.width - left - right, 1), height: max(size.height - top - bottom, 1))
        func x(_ e: Double) -> CGFloat? { axis.x(forEnergy: e).map { area.minX + CGFloat($0) } }
        let (logTop, linearTop) = (scale.logTop, scale.linearTop)
        func y(_ v: Double) -> CGFloat {
            let f = isLog ? log10(max(v, 1)) / logTop : max(v, 0) / linearTop
            return area.maxY - CGFloat(min(max(f, 0), 1)) * area.height
        }
        func hatch(_ rect: CGRect, color: Color, spacing: CGFloat = 6) {
            context.drawLayer { layer in
                layer.clip(to: Path(rect))
                var lines = Path()
                var hx = rect.minX - rect.height
                while hx < rect.maxX { lines.move(to: CGPoint(x: hx, y: rect.maxY)); lines.addLine(to: CGPoint(x: hx + rect.height, y: rect.minY)); hx += spacing }
                layer.stroke(lines, with: .color(color), lineWidth: 0.5)
            }
        }

        // The zero-loss mask, hatched.
        if let m = plot.zlpMaskEV, let x0 = x(m.lowerBound), let x1 = x(m.upperBound), x1 > x0 {
            hatch(CGRect(x: x0, y: area.minY, width: x1 - x0, height: area.height), color: .secondary.opacity(0.35))
        }
        // The gap between the low loss and the core loss: a hatched band with a dashed edge each side and the skipped energies written once, along the band.
        if let gap = axis.gap {
            let g0 = area.minX + CGFloat(gap.lowerBound), g1 = area.minX + CGFloat(gap.upperBound)
            let band = CGRect(x: g0, y: area.minY, width: g1 - g0, height: area.height)
            context.fill(Path(band), with: .color(.secondary.opacity(0.08)))
            hatch(band, color: .secondary.opacity(0.45), spacing: 5)
            for gx in [g0, g1] {
                var edge = Path(); edge.move(to: CGPoint(x: gx, y: area.minY)); edge.addLine(to: CGPoint(x: gx, y: area.maxY))
                context.stroke(edge, with: .color(.secondary), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
            if let label = axis.gapLabel, area.height > 90 {
                context.drawLayer { layer in
                    layer.translateBy(x: (g0 + g1) / 2, y: area.midY)
                    layer.rotate(by: .degrees(-90))
                    layer.draw(Text(label).font(.caption2).foregroundStyle(.secondary), at: .zero)
                }
            }
        }
        // Each picked edge's windows: background (orange), signal (accent), refused ones in red.
        for item in items {
            let refused = item.refusal != nil
            for (w, color) in [(item.windows.background, refused ? Color.red : Color.orange), (item.windows.signal, refused ? Color.red : Color.accentColor)] {
                guard let x0 = x(w.lowerBound), let x1 = x(w.upperBound), x1 > x0 else { continue }
                context.fill(Path(CGRect(x: x0, y: area.minY, width: x1 - x0, height: area.height)), with: .color(color.opacity(0.12)))
                for hx in [x0, x1] {
                    var h = Path(); h.move(to: CGPoint(x: hx, y: area.minY)); h.addLine(to: CGPoint(x: hx, y: area.maxY))
                    context.stroke(h, with: .color(color.opacity(0.7)), lineWidth: 1.5)
                }
            }
        }
        // Grid and labels: counts on the left, energy under each segment.
        for (v, text) in scale.labels(isLog: isLog) {
            var p = Path(); p.move(to: CGPoint(x: area.minX, y: y(v))); p.addLine(to: CGPoint(x: area.maxX, y: y(v)))
            context.stroke(p, with: .color(.secondary.opacity(0.15)), lineWidth: 0.5)
            context.draw(Text(text).font(.caption2).foregroundStyle(.secondary), at: CGPoint(x: area.minX - 4, y: y(v)), anchor: .trailing)
        }
        for segment in axis.segments {
            for t in EELSOneAxis.ticks(in: segment.energy) {
                guard let tx = x(t) else { continue }
                var p = Path(); p.move(to: CGPoint(x: tx, y: area.minY)); p.addLine(to: CGPoint(x: tx, y: area.maxY))
                context.stroke(p, with: .color(.secondary.opacity(0.15)), lineWidth: 0.5)
                context.draw(Text(EELSRoomFormat.sig(t, 5)).font(.caption2).foregroundStyle(.secondary), at: CGPoint(x: tx, y: area.maxY + 10))
            }
        }
        context.draw(Text("energy loss (eV)").font(.caption2).foregroundStyle(.secondary), at: CGPoint(x: area.midX, y: area.maxY + 25))
        context.draw(Text(isLog ? "log counts" : "counts").font(.caption2).foregroundStyle(.secondary), at: CGPoint(x: 4, y: area.minY - 8), anchor: .leading)

        // One point per pixel column (the column's largest value), so a 2048-channel spectrum draws the same line at any width. On the log axis a value with no counts
        // breaks the line instead of dropping to the floor.
        func path(_ curve: EELSPlotCurve, values: [Double], within window: ClosedRange<Double>? = nil) -> Path {
            var p = Path()
            var column = Int.min
            var peak = -Double.infinity
            var started = false
            func flush(_ c: Int, _ v: Double) {
                if !v.isFinite || (isLog && v <= 0) { started = false; return }
                let pt = CGPoint(x: area.minX + CGFloat(c) + 0.5, y: y(v))
                if started { p.addLine(to: pt) } else { p.move(to: pt); started = true }
            }
            for (i, v) in values.enumerated() {
                let e = curve.energy(i)
                if let window, !window.contains(e) { continue }
                if !shown.contains(e) { continue }
                guard v.isFinite, let px = axis.x(forEnergy: e) else { continue }
                let c = Int(px)
                if c != column { if column != Int.min { flush(column, peak) }; column = c; peak = v } else { peak = max(peak, v) }
            }
            if column != Int.min { flush(column, peak) }
            return p
        }
        // The whole map under a selected region, grey, before the region's own trace.
        for layer in layers where layer.id.hasPrefix("wholeMap") {
            let curve = EELSPlotCurve(origin: layer.origin, step: layer.step, counts: layer.counts)
            context.stroke(path(curve, values: layer.counts, within: layer.id.hasSuffix("-low") ? axis.lowShown : axis.coreShown), with: .color(layer.color.color), lineWidth: 1)
        }
        // Where the low loss gives way to the core loss on a shared stretch (a Dual-EELS pair: no gap to mark), a dashed rule and the two names, so the step between
        // the two acquisitions (the core loss is exposed longer) reads as two spectra, not one broken trace (the owner's drive, 2026-10-23).
        if axis.gap == nil, axis.segments.count == 2 {
            let jx = area.minX + CGFloat(axis.segments[1].x.lowerBound)
            var rule = Path(); rule.move(to: CGPoint(x: jx, y: area.minY)); rule.addLine(to: CGPoint(x: jx, y: area.maxY))
            context.stroke(rule, with: .color(.secondary), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            context.draw(Text("low loss").font(.caption2).foregroundStyle(.secondary), at: CGPoint(x: jx - 4, y: area.maxY - 8), anchor: .trailing)
            context.draw(Text("core loss").font(.caption2).foregroundStyle(.secondary), at: CGPoint(x: jx + 4, y: area.maxY - 8), anchor: .leading)
        }
        context.stroke(path(plot.low, values: plot.low.counts, within: axis.lowShown), with: .color(.primary), lineWidth: 1)
        if let core = plot.core { context.stroke(path(core, values: core.counts, within: axis.coreShown), with: .color(.primary), lineWidth: 1) }
        // The background under each edge's signal window from its background window: the kit's per-edge power law (fitted, or previewed while a window is dragged).
        if let core = plot.core {
            for (item, background) in zip(items, backgrounds) {
                guard let background else { continue }
                context.stroke(path(core, values: background), with: .color(item.refusal == nil ? .orange : .red), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
        }
        // The regions' spectra over the selected one, each in its region's colour (the EDS room's layers).
        for layer in layers where !layer.id.hasPrefix("wholeMap") {
            let curve = EELSPlotCurve(origin: layer.origin, step: layer.step, counts: layer.counts)
            let within = layer.id.hasSuffix("-low") ? axis.lowShown : axis.coreShown
            context.stroke(path(curve, values: layer.counts, within: within), with: .color(layer.color.color), lineWidth: 1)
        }
        // The kit's model over the signal windows only (it holds nothing elsewhere).
        if let core = plot.core, let model = plot.model { context.stroke(path(core, values: model), with: .color(.accentColor), lineWidth: 1.25) }
        // The references, dashed.
        for (i, reference) in references.enumerated() {
            let color: Color = [.purple, .teal, .pink, .indigo][i % 4]
            context.stroke(path(reference.curve, values: reference.curve.counts), with: .color(color), style: StrokeStyle(lineWidth: 1, dash: [6, 3]))
        }
        // The fitted edges: a dashed rule at the onset and its name.
        for (i, edge) in plot.edges.enumerated() {
            guard shown.contains(edge.onsetEV), let ex = x(edge.onsetEV) else { continue }
            var rule = Path(); rule.move(to: CGPoint(x: ex, y: area.minY + 10)); rule.addLine(to: CGPoint(x: ex, y: area.maxY))
            context.stroke(rule, with: .color(.primary.opacity(0.5)), style: StrokeStyle(lineWidth: 0.75, dash: [3, 3]))
            context.draw(Text(edge.title).font(.caption2), at: CGPoint(x: ex, y: area.minY + 4 + CGFloat(i % 2) * 10))
        }
        context.stroke(Path(area), with: .color(.secondary.opacity(0.4)), lineWidth: 0.5)
    }
}

/// The results beside the spectrum: the thickness line, one row per edge (I, at%, wt%), the regions' table, the refusal if there is one, and the footer
/// (model · background · convolution · deconvolution). The validation badge is here once; the columns say only their names.
private struct EELSResultsPanel: View {
    let session: EELSSession

    var body: some View {
        let plot = session.plot
        let rows = session.resultRows
        let hasFit = session.model != nil
        let failure = session.failure
        VStack(spacing: 0) {
            HStack(spacing: LayoutPolicy.inspectorRowSpacing) {
                Text(EELSRoomFormat.resultsHeader(region: plot?.regionName ?? "Whole map", lambdaNM: session.map?.meanFreePathNM,
                                                  lambdaSource: EELSRoomFormat.lambdaSource(session.meanFreePath)))
                    .font(.callout.weight(.semibold)).lineLimit(1).truncationMode(.tail)
                    .accessibilityIdentifier("eels.results.header")
                Spacer(minLength: 0)
                Text("validation: none")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
                    .help("t/λ, t and the edge amounts are not compared with a sample of known thickness or a standard: unvalidated")
                    .accessibilityIdentifier("eels.validationBadge")
                if session.isComputing { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, LayoutPolicy.infobarHorizontalPadding)
            .frame(height: LayoutPolicy.paneHeaderHeight)
            Divider()
            Text(EELSRoomFormat.thicknessLine(plot?.thickness, lambdaNM: session.map?.meanFreePathNM, lambdaSource: EELSRoomFormat.lambdaSource(session.meanFreePath)))
                .font(.callout.monospacedDigit()).lineLimit(2)
                .padding(.horizontal, LayoutPolicy.infobarHorizontalPadding).padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help("The median and the interquartile range of the kit's t/λ over the region's pixels; λ and its source; t from the same pixels")
                .accessibilityIdentifier("eels.thicknessLine")
            Divider()
            Group {
                if rows.isEmpty {
                    ContentUnavailableView("No edges fitted yet", systemImage: "list.bullet.rectangle",
                                           description: Text(session.pickedEdges.isEmpty ? "Pick edges in the periodic table, then Run."
                                                             : "Picked: " + session.pickedEdges.map(EELSFitCompute.title).joined(separator: ", ") + ". Run fits them."))
                } else {
                    Table(rows) {
                        TableColumn("Edge") { r in
                            HStack(spacing: 4) {
                                Text(r.title).fontWeight(.semibold)
                                if let why = r.unavailable { Image(systemName: "exclamationmark.circle").foregroundStyle(.secondary).help(why).accessibilityLabel(why) }
                            }
                        }.width(min: 56, ideal: 74)
                        TableColumn("I") { r in
                            Text(EELSRoomFormat.intensityText(r)).monospacedDigit().lineLimit(1)
                                .help("± is 1σ from the counts, carried through the background fit (counts taken as Poisson)"
                                      + (r.exponent.map { "\nPower-law exponent r under this edge: \(EELSRoomFormat.sig($0, 4))" } ?? ""))
                        }.width(min: 110, ideal: 150)
                        TableColumn("at%") { r in
                            Text(EELSRoomFormat.atomicText(r)).monospacedDigit().lineLimit(1)
                                .foregroundStyle(r.belowDetection ? .secondary : .primary)
                                .help(r.belowDetection ? "I is at or under 3σ: this edge is not detected in the region"
                                      : r.atomicPercent == nil ? "at% needs two or more fitted elements" : "")
                        }.width(min: 50, ideal: 100)
                        TableColumn("wt%") { r in Text(r.weightPercent.map { EELSRoomFormat.fixed($0, 1) } ?? "–").monospacedDigit().lineLimit(1) }
                            .width(min: 50, ideal: 64)
                    }
                    .alternatingRowBackgrounds(.disabled)   // the edges' rows, not a page of stripes (as the EDS table)
                    .accessibilityIdentifier("eels.results.table")
                }
            }
            .frame(maxHeight: .infinity)
            if !session.pinRows.isEmpty {
                Divider()
                Text("Regions").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    .padding(.horizontal, LayoutPolicy.infobarHorizontalPadding).padding(.top, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                EELSRegionsTable(session: session)
                    .frame(height: min(CGFloat(session.pinRows.count) * 22 + 60, 190))   // science: a table's rows
            }
            if let failure {
                InspectorWarning(failure, systemImage: "xmark.octagon.fill")
                    .padding(.horizontal, LayoutPolicy.infobarHorizontalPadding).padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let line = EELSRoomFormat.exponentsLine(rows) {
                Text(line).font(.caption.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
                    .padding(.horizontal, LayoutPolicy.infobarHorizontalPadding).padding(.bottom, 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help("The exponent of the power law the kit fitted on each edge's background window")
                    .accessibilityIdentifier("eels.results.exponents")
            }
            Text(EELSRoomFormat.fitFooter(hasFit: hasFit, convolved: session.model?.convolved ?? false))
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                .padding(.horizontal, LayoutPolicy.infobarHorizontalPadding)
                .frame(height: LayoutPolicy.paneHeaderHeight)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .top) { Divider() }
                .help(session.model?.methodName ?? "No fit has run")
                .accessibilityIdentifier("eels.results.footer")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("eels.results")
    }
}
