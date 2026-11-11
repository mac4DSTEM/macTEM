//
//  EELSRoomWords.swift
//  Role: the EELS room's words and rules that its view state shares with its views, in App beside that state (`EELSRoomState`), which exports
//        with both: what the Export section writes (`EELSExportKind`: each export's title, file type and the tail of its file name) and the colour
//        mix (`EELSMixComposition`: which maps are in it, a click that puts one in or takes it out, the maps its popover lists and the layers it is
//        drawn from). The inspector's buttons and the File menu (`ExportCommands`, over `EELSExportAvailability.menuKinds`) list the exports;
//        the maps block draws the mix (`EELSRoom.swift`). No view and no session; the mix's colours until the person changes them are
//        `EELSTileStyle`'s (`UI/EELSRoomLayout.swift`).
//

import Foundation
import UniformTypeIdentifiers
import ShellSpectroscopy
import TEMCore

/// What the EELS room's Export section writes, as the EDS room's (the owner's drive, 2026-10-23): the results, the spectrum, the regions, the maps as one PNG, the
/// per-pixel thickness and the method.
nonisolated enum EELSExportKind: String, CaseIterable, Identifiable {
    case results, spectrum, spectrumMSA, regions, mapsPNG, diagnostics, method
    var id: String { rawValue }
    var title: String {
        switch self {
        case .results: "Results CSV…"
        case .spectrum: "Spectrum CSV…"
        case .spectrumMSA: "Spectrum MSA…"
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
        case .spectrumMSA: UTType(filenameExtension: "msa") ?? .plainText
        default: .commaSeparatedText
        }
    }
    /// The file name's tail after the file's own name: "143_STEM SI results".
    var suffix: String {
        switch self {
        case .results: " results"
        case .spectrum, .spectrumMSA: " spectrum"
        case .regions: " regions"
        case .mapsPNG: " maps"
        case .diagnostics: " thickness"
        case .method: " thickness method"
        }
    }
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
        let edges = maps.filter { $0.id.hasPrefix("edge-") || $0.id.hasPrefix("at-") || $0.id.hasPrefix("wt-") }.map(\.id)
        return edges.isEmpty ? Array(ids.prefix(1)) : edges
    }

    /// A click on a map: in the mix or out. The choice becomes the person's (an empty choice is a valid one).
    static func toggle(_ id: String, in mix: inout ColorMix, maps: [EELSMapTile]) {
        var chosen = Set(selection(mix, maps: maps))
        if !chosen.insert(id).inserted { chosen.remove(id) }
        mix.members = maps.map(\.id).filter(chosen.contains)
        mix.isCustom = true
    }

    /// The maps the mix's popover lists, each with its default colours, as the EDS room's mix popover lists its maps.
    @MainActor static func colorItems(maps: [EELSMapTile]) -> [MapColorItem] {
        maps.map { MapColorItem(id: $0.id, title: $0.title, defaultColoring: EELSTileStyle.defaultColoring($0.id)) }
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
