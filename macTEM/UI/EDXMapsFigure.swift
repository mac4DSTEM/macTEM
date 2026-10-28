//
//  EDXMapsFigure.swift
//  Role: the maps as one PNG (the Export section's "Maps as PNG…"): the shown tiles in a grid, each with its title, the selected
//        region drawn over it, a scale bar from the file's pixel size and, for a composition tile, the footer that carries the
//        factor source and the `validation: none` badge. The picture is a SwiftUI view rendered by `ImageRenderer`; the pixels of a
//        tile are `EDXMapRaster`'s, the bar's numbers ImagoKit's (`EDXExports.scaleBar`). Presentation only.
//

import ShellSpectroscopy
import SwiftUI
import SpectroCore
import SpectroEDX
import ImageIO
import UniformTypeIdentifiers
import TEMCore
import TEMSession

/// One picture of the figure made by its room (the EELS room's maps and colour mix): the title, the detail beside it, the RGBA pixels and the footer.
struct EDXFigureCell: Identifiable {
    var id: String
    var title: String
    var detail: String
    var rgba: [UInt8]
    var width: Int
    var height: Int
    var footer: String?
}

/// What the figure draws; a plain value so a test can build one without a session.
struct EDXFigureContent {
    var title: String
    var subtitle: String
    var tiles: [EDXMapTile]
    var region: EDXRegion
    var nx: Int
    var ny: Int
    var bar: (fraction: Double, label: String)?
    /// The maps in the colour mix; drawn as the first tile when there are any.
    var mix: [EDXMapTile] = []
    /// Whether the scale bar and the selected region are drawn (the export's two toggles).
    var showsScaleBar = true
    var showsRegion = true
    /// Pictures another room made (the EELS maps, its colour mix first), drawn after the EDS tiles with the same frame, region and scale bar.
    var cells: [EDXFigureCell] = []
}

struct EDXMapsFigure: View {
    let content: EDXFigureContent
    static let cellWidth: CGFloat = 300
    static let columns = 3

    var body: some View {
        let cols = max(1, min(Self.columns, content.tiles.count + content.cells.count))
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(content.title).font(.headline)
                Text(content.subtitle).font(.caption).foregroundStyle(.white.opacity(0.7))
            }
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(Self.cellWidth), spacing: 10, alignment: .top), count: cols), alignment: .leading, spacing: 12) {
                if !content.mix.isEmpty { mixCell }
                ForEach(content.tiles) { tile in cell(tile) }
                ForEach(content.cells) { c in cell(c) }
            }
        }
        .padding(16)
        .foregroundStyle(.white)
        .background(Color(white: 0.11))
        .environment(\.colorScheme, .dark)
    }

    private var mixCell: some View {
        let first = content.mix[0]
        let layers = content.mix.map { MapRaster.MixLayer(values: $0.values, color: EDXRegionBridge.defaultColoring($0.symbol).endColor) }
        let image = EDXMapRaster.cgImage(rgba: MapRaster.mix(layers, count: first.values.count), width: first.width, height: first.height)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("Colour mix").font(.callout.weight(.semibold))
                Text(content.mix.map(\.symbol).joined(separator: " + ")).font(.callout).foregroundStyle(.white.opacity(0.7))
            }
            Color.black
                .aspectRatio(CGFloat(max(first.width, 1)) / CGFloat(max(first.height, 1)), contentMode: .fit)
                .overlay { if let image { Image(decorative: image, scale: 1).interpolation(.none).resizable() } }
                .overlay { GeometryReader { geo in overlay(size: geo.size) } }
        }
        .frame(width: Self.cellWidth, alignment: .leading)
    }

    private func cell(_ tile: EDXMapTile) -> some View {
        let image = EDXMapRaster.cgImage(rgba: EDXMapRaster.rgba(values: tile.values, hue: EDXRoomFormat.hue(symbol: tile.symbol), width: tile.width),
                                         width: tile.width, height: tile.height)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(tile.symbol).font(.callout.weight(.semibold))
                Text(tile.line).font(.callout).foregroundStyle(.white.opacity(0.7))
            }
            Color.black
                .aspectRatio(CGFloat(max(tile.width, 1)) / CGFloat(max(tile.height, 1)), contentMode: .fit)
                .overlay { if let image { Image(decorative: image, scale: 1).interpolation(.none).resizable() } }
                .overlay { GeometryReader { geo in overlay(size: geo.size) } }
            if let footer = tile.footer {
                Text(footer).font(.caption2).foregroundStyle(.white.opacity(0.7)).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(width: Self.cellWidth, alignment: .leading)
    }

    private func cell(_ c: EDXFigureCell) -> some View {
        let image = EDXMapRaster.cgImage(rgba: c.rgba, width: c.width, height: c.height)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(c.title).font(.callout.weight(.semibold))
                Text(c.detail).font(.callout).foregroundStyle(.white.opacity(0.7))
            }
            Color.black
                .aspectRatio(CGFloat(max(c.width, 1)) / CGFloat(max(c.height, 1)), contentMode: .fit)
                .overlay { if let image { Image(decorative: image, scale: 1).interpolation(.none).resizable() } }
                .overlay { GeometryReader { geo in overlay(size: geo.size) } }
            if let footer = c.footer {
                Text(footer).font(.caption2).foregroundStyle(.white.opacity(0.7)).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(width: Self.cellWidth, alignment: .leading)
    }

    private func overlay(size: CGSize) -> some View {
        ZStack(alignment: .bottomLeading) {
            if content.showsRegion, let outline = EDXMapOutline.outline(of: content.region, in: size, nx: content.nx, ny: content.ny) {
                outline.stroke(.white, lineWidth: 1.5)
            }
            if content.showsScaleBar, let bar = content.bar {
                VStack(alignment: .leading, spacing: 2) {
                    Text(bar.label).font(.caption2.monospaced())
                    Rectangle().frame(width: size.width * bar.fraction, height: EDXLayout.figureBarThickness)
                }
                .padding(6)
                .background(.black.opacity(0.45))
                .padding(6)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .bottomLeading)
    }

    /// The PNG of the figure at 2×, or nil if the renderer made no image.
    @MainActor static func png(_ content: EDXFigureContent) -> Data? {
        let renderer = ImageRenderer(content: EDXMapsFigure(content: content))
        renderer.scale = 2
        guard let image = renderer.cgImage else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }
}

extension EDXSession {
    /// What "Maps as PNG…" draws: the tiles the grid shows, the region, the file's scale bar.
    func figureContent(scaleBar: Bool = true, regions: Bool = true, mix: [EDXMapTile] = []) -> EDXFigureContent? {
        guard let source else { return nil }
        let m = source.metadata
        return EDXFigureContent(title: fileName,
                                subtitle: EDXRoomFormat.region(region, pixels: regionPixels) + " \u{00B7} " + (mapMode == .net ? "net counts" : mapMode.title),
                                tiles: shownTiles, region: region, nx: source.nx, ny: source.ny,
                                bar: EDXExports.scaleBar(pixelSize: m.scanPixelSize, unit: m.scanPixelUnit, nx: source.nx, ny: source.ny),
                                mix: mix, showsScaleBar: scaleBar, showsRegion: regions)
    }
}
