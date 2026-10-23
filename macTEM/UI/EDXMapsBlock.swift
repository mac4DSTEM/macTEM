//
//  EDXMapsBlock.swift
//  Role: the EDS room's maps (the corrected design, 2026-10-22): the colour mix as the ANCHOR tile on the left, where regions are drawn and edited (and shown nowhere else), the scan image and one
//        net-count (or composition) map per quantified element fitted into the rest; everything scales with the panes. The frame of a map (name, scale bar and its popover, one cursor; no chip, no
//        hover colour scale) is MacEMUI's `MapTileView`, the popover is its `MapDisplayPopover`; here are the pictures and the wiring to the session. The wt%, at% and Thickness tiles are drawn through
//        the display filter (`EDXMapFilter`), composition tiles only; the readout and every export use the raw values.
//

import ShellControls
import ShellLayout
import ShellMetal
import ShellSpectroscopy
import SwiftUI
import CoreGraphics
import SpectroCore
import SpectroEDX
#if canImport(TEMCore)
import TEMCore
import TEMSession
#endif

/// One tile of the block: the scan image, an element's map or the colour mix.
struct EDXGridItem: Identifiable {
    enum Kind { case scan([Float]), map(EDXMapTile), mix([EDXMixMember]) }
    let id: String
    let kind: Kind

    static let mixID = "colourMix"
}

/// One layer of the colour mix: the scan image (a grey layer) or an element's map.
struct EDXMixMember: Identifiable {
    let id: String
    let tile: EDXMapTile?
    let scan: [Float]?
    var version: String { tile.map { "\($0.symbol)\($0.version)" } ?? "haadf" }
}

/// The tiles of the block: the colour mix is the anchor on the left (whatever is selected on the right, scan image included, nothing selected: an empty tile with its placeholder), the scan
/// image and the maps are the tiles on the right.
enum EDXMapsComposition {
    static let placeholder = "Select maps on the right to build the colour mix"

    /// The ids a click can select: the scan image first, then the element maps.
    static func selectable(scan: [Float]?, tiles: [EDXMapTile]) -> [String] { (scan == nil ? [] : ["haadf"]) + tiles.map(\.symbol) }

    static func items(scan: [Float]?, tiles: [EDXMapTile], appearance: MapAppearance) -> (anchor: EDXGridItem?, rest: [EDXGridItem]) {
        let all = (scan.map { [EDXGridItem(id: "haadf", kind: .scan($0))] } ?? []) + tiles.map { EDXGridItem(id: $0.symbol, kind: .map($0)) }
        return (EDXGridItem(id: EDXGridItem.mixID, kind: .mix(mixMembers(scan: scan, tiles: tiles, appearance: appearance))), all)
    }

    /// The ids in the mix: the person's choice, else the elements (the scan image joins the mix only when clicked, as in Velox).
    static func selection(_ mix: ColorMix, scan: [Float]?, tiles: [EDXMapTile]) -> [String] {
        let ids = selectable(scan: scan, tiles: tiles)
        return mix.isCustom ? ids.filter(mix.members.contains) : tiles.map(\.symbol)
    }

    /// A click on a tile: in the mix or out. The choice becomes the person's (an empty choice is a valid one).
    static func toggle(_ id: String, in mix: inout ColorMix, scan: [Float]?, tiles: [EDXMapTile]) {
        var chosen = Set(selection(mix, scan: scan, tiles: tiles))
        if !chosen.insert(id).inserted { chosen.remove(id) }
        mix.members = selectable(scan: scan, tiles: tiles).filter(chosen.contains)
        mix.isCustom = true
    }

    /// The layers of the mix in the order of the tiles: the person's selection, else every tile.
    static func mixMembers(scan: [Float]?, tiles: [EDXMapTile], appearance: MapAppearance) -> [EDXMixMember] {
        let chosen = Set(selection(appearance.mix, scan: scan, tiles: tiles))
        var out: [EDXMixMember] = []
        if let scan, chosen.contains("haadf") { out.append(EDXMixMember(id: "haadf", tile: nil, scan: scan)) }
        out += tiles.filter { chosen.contains($0.symbol) }.map { EDXMixMember(id: $0.symbol, tile: $0, scan: nil) }
        return out
    }
}

struct EDXMapsBlock: View {
    let session: EDXSession
    @Bindable var state: EDXRoomState

    var body: some View {
        // One read of each observed property, here, handed down as values.
        let tiles = session.shownTiles
        let mapsState = session.mapsState
        let nx = session.source?.nx ?? 0, ny = session.source?.ny ?? 0
        let scan = session.source?.scanImage
        let composition = EDXMapsComposition.items(scan: scan, tiles: tiles, appearance: state.appearance)
        let regions = EDXRegionBridge.set(session, linesFocused: state.linesFocused)
        VStack(spacing: 0) {
            if nx * ny == 1 {
                // One pixel: a map would be one flat square. The spectrum and the composition below are the result.
                ContentUnavailableView("A single spectrum has no maps", systemImage: "waveform.path",
                                       description: Text("The spectrum and its composition are below; the elements are in the inspector."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("edx.noMaps")
            } else {
                AnchoredMapsBlock(anchor: composition.anchor, items: composition.rest, aspect: CGFloat(max(nx, 1)) / CGFloat(max(ny, 1)), storageKey: "edx.mapsSplit",
                                  solo: $state.soloTile, soloEnabled: false) { item, size, isAnchor in
                    EDXMapTileHost(item: item, size: size, isAnchor: isAnchor, nx: nx, ny: ny, mapsState: mapsState,
                                   regions: isAnchor ? regions : nil, session: session, state: state)
                }
            }
        }
        .accessibilityIdentifier("edx.maps")
    }
}

/// One tile with its picture made off the main actor, and the wiring of its regions, hover and popover.
private struct EDXMapTileHost: View {
    let item: EDXGridItem
    let size: CGSize
    let isAnchor: Bool
    let nx: Int
    let ny: Int
    let mapsState: EDXMapsState
    let regions: SpectralRegionSet?
    let session: EDXSession
    @Bindable var state: EDXRoomState
    @State private var image: CGImage?

    private var appearance: MapAppearance { state.appearance }

    /// Every tile but the colour mix is selected by a click: what is selected is what the mix on the left shows.
    private func inMixNow(_ id: String) -> Bool {
        EDXMapsComposition.selection(appearance.mix, scan: session.source?.scanImage, tiles: session.shownTiles).contains(id)
    }
    private var isMix: Bool { if case .mix = item.kind { true } else { false } }
    private var tileID: String? { switch item.kind { case .scan: "haadf"; case .map(let tile): tile.symbol; case .mix: nil } }
    private var selectable: [String] { EDXMapsComposition.selectable(scan: session.source?.scanImage, tiles: session.shownTiles) }
    private var inMix: Bool? {
        guard let id = tileID else { return nil }
        return EDXMapsComposition.selection(appearance.mix, scan: session.source?.scanImage, tiles: session.shownTiles).contains(id)
    }
    private var toggleMix: (() -> Void)? {
        guard let id = tileID else { return nil }
        return { EDXMapsComposition.toggle(id, in: &state.appearance.mix, scan: session.source?.scanImage, tiles: session.shownTiles) }
    }

    var body: some View {
        let spec = Self.spec(for: item, appearance: appearance, filter: state.mapFilter, width: nx)
        MapTileView(title: spec.title, detail: spec.detail, image: image, size: size, scanWidth: nx, scanHeight: ny,
                    pixelSize: session.scanPixel?.size, pixelUnit: session.scanPixel?.unit,
                    regions: regions.map { set in
                        MapTileRegions(set: set, tool: state.tool,
                                       onRectangle: { state.linesFocused = false; session.drawRectangle(PixelRect(x0: $0, y0: $1, x1: $2, y1: $3)) },
                                       onEllipse: { state.linesFocused = false; session.drawEllipse(PixelRect(x0: $0, y0: $1, x1: $2, y1: $3)) },
                                       onPolygon: { state.linesFocused = false; session.drawPolygon($0.map { PixelPoint(x: $0.x, y: $0.y) }) },
                                       onLine: { if session.drawLine(from: PixelPoint(x: $0.x, y: $0.y), to: PixelPoint(x: $1.x, y: $1.y)) != nil { state.linesFocused = true } },
                                       onEdit: { EDXRegionBridge.edit($0, $1, in: session) },
                                       onDrag: { session.previewRegion($0.flatMap { EDXRegionBridge.region($0.geometry) }) },
                                       onSelect: { EDXRegionBridge.select($0, in: session, state: state) },
                                       onDelete: { EDXRegionBridge.deleteSelected(in: session, state: state) })
                    },
                    filteredTag: spec.filtered,
                    inMix: inMix, onToggleMix: toggleMix, placeholder: isMix ? EDXMapsComposition.placeholder : nil, transform: $state.mapView,
                    onHover: { pixel in
                        state.hoverPixel = pixel.map { EDXHoverPixel(x: $0.x, y: $0.y) }
                        state.readout = pixel.map { p in ["x \(p.x), y \(p.y)", spec.valueText(p.x, p.y)].compactMap { $0 }.joined(separator: " · ") }
                    },
                    controls: { controls })
            .opacity(mapsState == .running ? 0.5 : 1)
            .task(id: spec.pictureKey) {
                if spec.isEmpty { image = nil; return }
                let make = spec.raster, (w, h) = (nx, ny)
                image = await Task.detached(priority: .userInitiated) { EDXMapRaster.cgImage(rgba: make(), width: w, height: h) }.value
            }
    }

    /// The popover the scale bar opens: mac4DSTEM's display popover.
    private var controls: some View { EDXMapPopover(item: item, session: session, state: state) }

    /// Everything the tile shows that depends on its kind, as values.
    struct Spec {
        var title: String
        var detail: String?
        var valueText: (Int, Int) -> String?
        var raster: @Sendable () -> [UInt8]
        /// What the picture is made from; a new key is a new picture.
        var pictureKey: String
        /// The colour mix with nothing selected: no picture, the placeholder shows.
        var isEmpty = false
        /// The picture is drawn through the display filter (the tile's "filtered" tag).
        var filtered = false
    }

    /// The filter a tile is drawn through: composition tiles only, never the net maps or the HAADF.
    static func filter(of tile: EDXMapTile, _ chosen: EDXMapFilter) -> EDXMapFilter { tile.mode == .net ? .off : chosen }

    static func spec(for item: EDXGridItem, appearance: MapAppearance, filter chosen: EDXMapFilter, width: Int) -> Spec {
        switch item.kind {
        case .scan(let scan):
            let coloring = appearance.coloring(for: "haadf", default: .colormap(.gray)), adjustment = appearance.adjustment(for: "haadf")
            return Spec(title: "HAADF", detail: nil,
                        valueText: { [width] x, y in
                            let i = y * width + x
                            return i < scan.count && scan[i].isFinite ? "\(Num.sig(Double(scan[i]), 4)) intensity" : nil
                        },
                        raster: { @Sendable in
                            let (values, upper) = EDXTileDisplay.shifted(scan)
                            return MapRaster.rgba(values: values, coloring: coloring, upper: upper, adjustment: adjustment)
                        },
                        pictureKey: "haadf-\(coloring.hashValue)-\(adjustment.hashValue)")
        case .map(let tile):
            let coloring = appearance.coloring(for: tile.symbol, default: EDXRegionBridge.defaultColoring(tile.symbol)), stored = appearance.adjustments[tile.symbol]
            let values = tile.values, width = tile.width, height = tile.height, top = tile.maxValue, filter = Self.filter(of: tile, chosen)
            return Spec(title: tile.symbol, detail: tile.line.replacingOccurrences(of: tile.symbol + " ", with: ""),
                        valueText: { [symbol = tile.symbol, unit = tile.mode.unit] x, y in
                            let i = y * width + x
                            return i < values.count && values[i].isFinite ? "\(symbol) \(Num.sig(values[i], 4)) \(unit)" : nil
                        },
                        raster: { @Sendable in
                            let d = EDXTileDisplay.make(values: values, width: width, height: height, top: top, filter: filter, stored: stored)
                            // A missing pixel is the scale's bottom: no width, no hatching.
                            return MapRaster.rgba(values: d.values, coloring: coloring, upper: top > 0 ? top : nil, adjustment: d.adjustment)
                        },
                        pictureKey: "\(tile.symbol)-\(tile.version)-\(coloring.hashValue)-\(stored.hashValue)-\(filter.rawValue)", filtered: filter.isOn)
        case .mix(let members):
            let parts = members.map { member -> (layer: @Sendable () -> MapRaster.MixLayer, key: String) in
                if let tile = member.tile {
                    let color = appearance.coloring(for: tile.symbol, default: EDXRegionBridge.defaultColoring(tile.symbol)).endColor, stored = appearance.adjustments[tile.symbol]
                    let values = tile.values, width = tile.width, height = tile.height, top = tile.maxValue, filter = Self.filter(of: tile, chosen)
                    return ({ @Sendable in
                        let d = EDXTileDisplay.make(values: values, width: width, height: height, top: top, filter: filter, stored: stored)
                        return MapRaster.MixLayer(values: d.values, color: color, upper: top > 0 ? top : nil, adjustment: d.adjustment)
                    }, "\(member.id)-\(color.hashValue)-\(stored.hashValue)-\(filter.rawValue)")
                }
                // The scan image is a grey layer under the colours: its finite range shifted to start at 0.
                let scan = member.scan ?? [], adjustment = appearance.adjustment(for: "haadf")
                return ({ @Sendable in
                    MapRaster.MixLayer(values: EDXTileDisplay.shifted(scan).values, color: RegionColor(red: 0.5, green: 0.5, blue: 0.5), adjustment: adjustment)
                }, "haadf-\(adjustment.hashValue)")
            }
            let count = members.first.map { $0.tile?.values.count ?? $0.scan?.count ?? 0 } ?? 0
            let layers = parts.map(\.layer)
            return Spec(title: "Colour mix", detail: members.isEmpty ? nil : members.map { $0.id == "haadf" ? "HAADF" : $0.id }.joined(separator: " + "),
                        valueText: { _, _ in nil },
                        raster: { @Sendable in MapRaster.mix(layers.map { $0() }, count: count) },
                        pictureKey: members.isEmpty ? "mix-empty" : "mix-" + members.map { "\($0.version)" }.joined() + "-" + parts.map(\.key).joined(separator: "|"),
                        isEmpty: members.isEmpty, filtered: members.contains { $0.tile.map { Self.filter(of: $0, chosen).isOn } ?? false })
        }
    }
}

/// What a numeric tile draws, from its raw values (pure, made off the main actor): the values through the display filter, the scale's top (the raw map's
/// maximum, so the filter never rescales a map), and the contrast window: the stored one, else the filtered map's default, the 1st to 99th percentile of the raw map.
nonisolated struct EDXTileDisplay {
    var values: [Double]
    var upper: Double
    var adjustment: MapAdjustment
    /// The window "Reset Range" returns to: the full range, or the percentile window of a filtered map.
    var fallback: MapAdjustment

    static func make(values: [Double], width: Int, height: Int, top: Double, filter: EDXMapFilter, stored: MapAdjustment?) -> EDXTileDisplay {
        var fallback = MapAdjustment()
        if filter.isOn, top > 0, let range = EDXMapFilter.displayRange(of: values) { fallback = MapAdjustment(low: range.lowerBound / top, high: range.upperBound / top) }
        return EDXTileDisplay(values: filter.apply(values, width: width, height: height), upper: top, adjustment: stored ?? fallback, fallback: fallback)
    }

    /// The scan image's finite range shifted to start at 0, and the span (the full scale).
    static func shifted(_ scan: [Float]) -> (values: [Double], upper: Double) {
        let finite = scan.filter(\.isFinite)
        let lo = Double(finite.min() ?? 0), hi = Double(finite.max() ?? 1)
        return (scan.map { $0.isFinite ? Double($0) - lo : .nan }, hi > lo ? hi - lo : 1)
    }
}

/// The popover of a tile's scale bar: `MapDisplayPopover` over the session's values. The histogram is made once per tile and filter, off the main actor.
private struct EDXMapPopover: View {
    let item: EDXGridItem
    let session: EDXSession
    @Bindable var state: EDXRoomState
    @State private var shown: Shown?

    struct Shown {
        var counts: [Int]
        var statistics: HistogramStatistics
        var title: String
        var fallback: MapAdjustment
    }

    private var id: String? { switch item.kind { case .scan: "haadf"; case .map(let tile): tile.symbol; case .mix: nil } }
    private var fallback: MapAdjustment { shown?.fallback ?? MapAdjustment() }
    private var effective: MapAdjustment { id.flatMap { state.appearance.adjustments[$0] } ?? fallback }
    /// The window is stored unless it is the default one.
    private func commit(_ a: MapAdjustment) { if let id { state.appearance.adjustments[id] = a == fallback ? nil : a } }
    private func binding(_ keyPath: WritableKeyPath<MapAdjustment, Double>) -> Binding<Double> {
        Binding(get: { effective[keyPath: keyPath] }, set: { var a = effective; a[keyPath: keyPath] = $0; commit(a) })
    }

    var body: some View {
        let scan = session.source?.scanImage, tiles = session.shownTiles
        MapDisplayPopover(kind: kind(scan: scan, tiles: tiles), histogram: shown.map { MapDisplayHistogram(counts: $0.counts, statistics: $0.statistics, title: $0.title) },
                          low: binding(\.low), high: binding(\.high), gamma: binding(\.gamma),
                          reset: { if let id { state.appearance.adjustments[id] = nil } })
            .formStyle(.grouped).scrollContentBackground(.hidden).fixedSize(horizontal: false, vertical: true)
            .task(id: key) { shown = await Self.histogram(of: item.kind, filter: state.mapFilter) }
    }

    private var key: String {
        switch item.kind { case .scan: "haadf"; case .map(let tile): "\(tile.symbol)-\(tile.version)-\(EDXMapTileHost.filter(of: tile, state.mapFilter).rawValue)"; case .mix: "mix" }
    }

    private func kind(scan: [Float]?, tiles: [EDXMapTile]) -> MapDisplayPopover.Kind {
        switch item.kind {
        case .scan:
            return .reference(colormap: Binding(
                get: { if case .colormap(let k) = state.appearance.coloring(for: "haadf", default: .colormap(.gray)) { k } else { .gray } },
                set: { state.appearance.set(.colormap($0), for: "haadf") }))
        case .map(let tile):
            let fallback = EDXRegionBridge.defaultColoring(tile.symbol)
            return .element(color: Binding(get: { state.appearance.coloring(for: tile.symbol, default: fallback).endColor },
                                           set: { state.appearance.set(.color($0), for: tile.symbol) }))
        case .mix:
            let items = EDXMapsComposition.selectable(scan: scan, tiles: tiles).map {
                MapColorItem(id: $0, title: $0 == "haadf" ? "HAADF" : $0, defaultColoring: $0 == "haadf" ? .colormap(.gray) : EDXRegionBridge.defaultColoring($0))
            }
            return .mix(items: items,
                        isIn: { EDXMapsComposition.selection(state.appearance.mix, scan: scan, tiles: tiles).contains($0) },
                        toggle: { EDXMapsComposition.toggle($0, in: &state.appearance.mix, scan: scan, tiles: tiles) })
        }
    }

    /// The histogram of what the tile draws, over 0 to the scale's top (the window is a fraction of that range, as the picture applies it).
    private static func histogram(of kind: EDXGridItem.Kind, filter chosen: EDXMapFilter) async -> Shown? {
        switch kind {
        case .mix: return nil
        case .scan(let scan):
            return await Task.detached(priority: .userInitiated) {
                let (values, upper) = EDXTileDisplay.shifted(scan)
                return make(values: values, top: upper, fallback: MapAdjustment(), title: "Histogram")
            }.value
        case .map(let tile):
            let values = tile.values, (w, h, top) = (tile.width, tile.height, tile.maxValue), filter = EDXMapTileHost.filter(of: tile, chosen)
            return await Task.detached(priority: .userInitiated) {
                let d = EDXTileDisplay.make(values: values, width: w, height: h, top: top, filter: filter, stored: nil)
                return make(values: d.values, top: top, fallback: d.fallback, title: filter.isOn ? "Histogram · filtered, \(filter.title)" : "Histogram")
            }.value
        }
    }

    private nonisolated static func make(values: [Double], top: Double, fallback: MapAdjustment, title: String) -> Shown? {
        let finite = values.filter(\.isFinite)
        guard top > 0, !finite.isEmpty else { return nil }
        let statistics = HistogramStatistics(minimum: 0, maximum: Float(top), mean: Float(finite.reduce(0, +) / Double(finite.count)))
        return Shown(counts: MapHistogram.bins(values: values, range: 0...top), statistics: statistics, title: title, fallback: fallback)
    }
}

/// The outline of a region in the points of a picture (the maps figure draws it); nil for the whole map.
nonisolated enum EDXMapOutline {
    /// The selected region's outline in the picture's points; nil for the whole map (no outline).
    static func outline(of region: EDXRegion, in size: CGSize, nx: Int, ny: Int) -> Path? {
        guard nx > 0, ny > 0 else { return nil }
        let sx = size.width / CGFloat(nx), sy = size.height / CGFloat(ny)
        func box(_ r: PixelRect) -> CGRect { CGRect(x: CGFloat(r.x0) * sx, y: CGFloat(r.y0) * sy, width: CGFloat(r.width) * sx, height: CGFloat(r.height) * sy) }
        switch region {
        case .wholeMap: return nil
        case .rectangle(let r): return Path(box(r))
        case .ellipse(let r): return Path(ellipseIn: box(r))
        case .polygon(let v):
            guard let first = v.first else { return nil }
            return Path { p in
                p.move(to: CGPoint(x: first.x * sx, y: first.y * sy))
                for q in v.dropFirst() { p.addLine(to: CGPoint(x: q.x * sx, y: q.y * sy)) }
                p.closeSubpath()
            }
        }
    }}
