//
//  EELSRegionBridge.swift
//  Role: the EELS room's regions in MacEMUI's words, as `EDXRegionBridge` does for the EDS room: the session's regions and lines as a `SpectralRegionSet`,
//        the edits of the shared Regions list and of the anchor tile as the session's calls, and the series of the profile chart.
//

import ShellSpectroscopy
import SwiftUI
import TEMCore
import TEMSession
import SpectroEDX
import SpectroEELS
import ShellEDXModel

enum EELSRegionBridge {
    static func set(_ session: EELSSession, linesFocused: Bool) -> SpectralRegionSet {
        var regions: [SpectralRegion] = []
        for pin in session.pins {
            guard let g = EDXRegionBridge.geometry(pin.region) else { continue }
            regions.append(SpectralRegion(id: pin.id, name: pin.name, color: EDXRegionBridge.color(pin.color, number: pin.number), isVisible: pin.isVisible, geometry: g))
        }
        for line in session.lines {
            regions.append(SpectralRegion(id: line.id, name: line.name, color: EDXRegionBridge.color(line.color, number: line.number), isVisible: line.isVisible,
                                          geometry: .line(RegionPoint(x: line.from.x, y: line.from.y), RegionPoint(x: line.to.x, y: line.to.y))))
        }
        return SpectralRegionSet(regions: regions, selectedID: linesFocused ? session.selectedLineID : session.selectedPinID)
    }

    static func edit(_ id: UUID, _ geometry: RegionGeometry, in session: EELSSession) {
        if let region = EDXRegionBridge.region(geometry) { session.setPinRegion(id, region) }
        else if case .line(let a, let b) = geometry { session.setLineEnds(id, from: PixelPoint(x: a.x, y: a.y), to: PixelPoint(x: b.x, y: b.y)) }
    }

    static func apply(_ new: SpectralRegionSet, to session: EELSSession, from old: SpectralRegionSet, state: EELSRoomState) {
        let kept = Set(new.regions.map(\.id))
        for region in old.regions where !kept.contains(region.id) {
            if session.pins.contains(where: { $0.id == region.id }) { session.removePin(region.id) } else { session.removeLine(region.id) }
        }
        for region in new.regions {
            guard let before = old.regions.first(where: { $0.id == region.id }) else { continue }
            let isPin = session.pins.contains { $0.id == region.id }
            if region.name != before.name { isPin ? session.renamePin(region.id, to: region.name) : session.renameLine(region.id, to: region.name) }
            if region.color != before.color {
                let c = EDXRegionBridge.stored(region.color)
                isPin ? session.setPinColor(region.id, c) : session.setLineColor(region.id, c)
            }
            if region.isVisible != before.isVisible { isPin ? session.setPinVisible(region.id, region.isVisible) : session.setLineVisible(region.id, region.isVisible) }
        }
        if new.selectedID != old.selectedID, let id = new.selectedID {
            if session.pins.contains(where: { $0.id == id }) { state.linesFocused = false; session.selectPin(id) } else { state.linesFocused = true; session.selectLine(id) }
        }
    }

    /// A click on a region of the anchor selects it; a click on none returns to the whole map.
    static func select(_ id: UUID?, in session: EELSSession, state: EELSRoomState) {
        guard let id else { state.linesFocused = false; session.selectWholeMap(); return }
        if session.pins.contains(where: { $0.id == id }) { state.linesFocused = false; session.selectPin(id) }
        else { state.linesFocused = true; session.selectLine(id) }
    }

    /// The delete key: the selected region (or line) goes; the selection falls back to the whole map.
    static func deleteSelected(in session: EELSSession, state: EELSRoomState) {
        if state.linesFocused, let id = session.selectedLineID { session.removeLine(id); return }
        guard let pin = session.selectedPin else { return }
        session.removePin(pin.id)
        session.selectWholeMap()
    }

    /// The maps the profile reads: the maps the block shows for the Maps control's segment (`EELSMapsBlock.shownMaps`), in their order, kept to one quantity.
    static func profileMaps(_ session: EELSSession, state: EELSRoomState) -> [EELSMapTile] {
        profileMaps(shown: EELSMapsBlock.shownMaps(session, state), segment: session.mapsAvailability.effective(state.maps))
    }

    /// One quantity, as the EDS room's profile is its map mode's tiles: the segment's own (the at% or wt% maps on those segments, else the first map shown:
    /// t/λ, t, the ZLP shift, I total in a file with only a core loss), and every shown map in its unit, in the order shown. The edge maps beside t/λ are
    /// another unit and are left out, so no map lies flat along 0 on another's axis.
    nonisolated static func profileMaps(shown: [EELSMapTile], segment: EELSMapsSegment) -> [EELSMapTile] {
        let own = segment == .atomicPercent || segment == .weightPercent ? shown.first { $0.unit == segment.title } : nil
        guard let lead = own ?? shown.first else { return [] }
        return shown.filter { $0.unit == lead.unit }
    }

    /// The selected line's profile on the maps the Maps control shows (`profileMaps`), one series per map in the map's own hue.
    static func series(_ session: EELSSession, state: EELSRoomState, hue: (String) -> Double) -> [ProfileSeries] {
        series(session, maps: profileMaps(session, state: state), hue: hue)
    }

    /// The profile's value axis for the maps the Maps control shows (`profileValueTitle(maps:)`).
    static func profileValueTitle(_ session: EELSSession, state: EELSRoomState) -> String {
        profileValueTitle(maps: profileMaps(session, state: state).map { (title: $0.title, unit: $0.unit) })
    }

    /// The selected line's profile on `maps` (every map the room holds when nil), one series per map in the map's own hue. Positions are in scan pixels;
    /// with the file's pixel size they are in its unit (`profileUnit`), as the EDS room's `EDXRegionBridge.series`.
    static func series(_ session: EELSSession, maps: [EELSMapTile]? = nil, hue: (String) -> Double) -> [ProfileSeries] {
        let size = session.scanPixel?.size ?? 1
        return session.profiles(of: maps).compactMap { p in
            guard !p.samples.isEmpty else { return nil }
            let spacing = (p.positions.count > 1 ? p.positions[1] - p.positions[0] : 1) * size
            let rgb = EDXRoomFormat.rgb(hue: hue(p.id))
            return ProfileSeries(id: p.id, name: p.title, color: RegionColor(red: rgb.0, green: rgb.1, blue: rgb.2), values: p.samples, spacing: spacing)
        }
    }

    /// The profile's distance unit: the scan's pixel unit when the file states a pixel size, else pixels.
    static func profileUnit(_ session: EELSSession) -> String { session.scanPixel?.unit ?? "px" }

    /// One short quantity name, so it fits the inset, as the EDS room's (its map mode's title, "at%"); the series are told apart by their maps' colours.
    /// The first map's quantity: one map is its title with its unit ("t/λ", "t (nm)"); several are their unit when it names the quantity ("at%", "wt%"),
    /// else "n maps (unit)".
    nonisolated static func profileValueTitle(maps: [(title: String, unit: String)]) -> String {
        guard let first = maps.first else { return "Value" }
        let same = maps.filter { $0.unit == first.unit }
        if same.count == 1 { return first.unit.isEmpty ? first.title : "\(first.title) (\(first.unit))" }
        if first.unit == "at%" || first.unit == "wt%" { return first.unit }
        return first.unit.isEmpty ? "\(same.count) maps" : "\(same.count) maps (\(first.unit))"
    }

    // MARK: The keyboard route (the anchor tile with the focus: after a click on it, or by Tab), as the EDS room's

    /// The shape Return draws with `tool` on a scan `nx` x `ny`: the middle half of the scan, a pixel at least (a polygon is that box's four corners, a line
    /// along the centres of its middle row). nil for the arrow tool or an empty scan. The EDS room's `EDXRegionBridge.keyboardShape` (internal to MacEMUI).
    nonisolated static func keyboardShape(_ tool: RegionTool, nx: Int, ny: Int) -> RegionGeometry? {
        guard nx > 0, ny > 0 else { return nil }
        let w = max(nx / 2, 1), h = max(ny / 2, 1)
        let x0 = Double((nx - w) / 2), y0 = Double((ny - h) / 2), x1 = x0 + Double(w), y1 = y0 + Double(h)
        switch tool {
        case .pointer: return nil
        case .rectangle: return .rectangle(x0: x0, y0: y0, x1: x1, y1: y1)
        case .ellipse: return .ellipse(x0: x0, y0: y0, x1: x1, y1: y1)
        case .polygon: return .polygon([RegionPoint(x: x0, y: y0), RegionPoint(x: x1, y: y0), RegionPoint(x: x1, y: y1), RegionPoint(x: x0, y: y1)])
        case .line: return .line(RegionPoint(x: x0, y: Double(ny / 2) + 0.5), RegionPoint(x: x1, y: Double(ny / 2) + 0.5))
        }
    }

    /// Return: the chosen tool's shape is drawn as the mouse draws it (kept as the next numbered region, or line, and selected). False with the arrow tool
    /// or when nothing was drawn, so the key is left to whatever else wants it.
    @discardableResult
    static func drawByKeyboard(in session: EELSSession, state: EELSRoomState) -> Bool {
        guard let image = session.source?.image, let shape = keyboardShape(state.tool, nx: image.nx, ny: image.ny) else { return false }
        if case .line(let a, let b) = shape {
            guard session.drawLine(from: PixelPoint(x: a.x, y: a.y), to: PixelPoint(x: b.x, y: b.y)) != nil else { return false }
            state.linesFocused = true
            return true
        }
        guard let region = EDXRegionBridge.region(shape), session.drawRegion(region) != nil else { return false }
        state.linesFocused = false
        return true
    }

    /// The step an arrow key moves the selected region, in scan pixels: one, ten with shift; nil for any other key.
    nonisolated static func arrowStep(_ key: KeyEquivalent, shift: Bool) -> (dx: Int, dy: Int)? {
        let n = shift ? 10 : 1
        switch key {
        case .leftArrow: return (-n, 0)
        case .rightArrow: return (n, 0)
        case .upArrow: return (0, -n)
        case .downArrow: return (0, n)
        default: return nil
        }
    }

    /// An arrow key: the selected region (or line) moves by `dx`, `dy` scan pixels, kept on the scan, as a drag on its body moves it. False when nothing is
    /// selected, the selection is hidden, or it cannot move further.
    @discardableResult
    static func nudgeSelected(dx: Int, dy: Int, in session: EELSSession, state: EELSRoomState) -> Bool {
        guard let image = session.source?.image, let selected = set(session, linesFocused: state.linesFocused).selected, selected.isVisible else { return false }
        let moved = RegionEditing.moved(selected.geometry, dx: Double(dx), dy: Double(dy), scanWidth: image.nx, scanHeight: image.ny)
        guard moved != selected.geometry else { return false }
        edit(selected.id, moved, in: session)
        return true
    }
}
