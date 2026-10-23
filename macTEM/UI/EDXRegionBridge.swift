//
//  EDXRegionBridge.swift
//  Role: the EDX room's regions in MacEMUI's words. The session keeps the regions (pins) and lines; the shared Regions list, overlay and spectrum layers
//        speak `SpectralRegionSet`, `SpectrumLayer` and `ProfileSeries`. This file converts both ways and nothing else: no number is made here.
//

import ShellSpectroscopy
import SwiftUI
#if canImport(TEMCore)
import TEMCore
import TEMSession
#endif
import SpectroEDX

enum EDXRegionBridge {
    static func geometry(_ region: EDXRegion) -> RegionGeometry? {
        switch region {
        case .wholeMap: nil
        case .rectangle(let r): .rectangle(x0: Double(r.x0), y0: Double(r.y0), x1: Double(r.x1), y1: Double(r.y1))
        case .ellipse(let r): .ellipse(x0: Double(r.x0), y0: Double(r.y0), x1: Double(r.x1), y1: Double(r.y1))
        case .polygon(let v): .polygon(v.map { RegionPoint(x: $0.x, y: $0.y) })
        }
    }

    /// A region from a geometry the drawing layer edited: boxes are whole pixels already; a line has no region (nil).
    static func region(_ geometry: RegionGeometry) -> EDXRegion? {
        switch geometry {
        case .rectangle(let x0, let y0, let x1, let y1): .rectangle(PixelRect(x0: Int(x0.rounded()), y0: Int(y0.rounded()), x1: Int(x1.rounded()), y1: Int(y1.rounded())))
        case .ellipse(let x0, let y0, let x1, let y1): .ellipse(PixelRect(x0: Int(x0.rounded()), y0: Int(y0.rounded()), x1: Int(x1.rounded()), y1: Int(y1.rounded())))
        case .polygon(let v): .polygon(v.map { PixelPoint(x: $0.x, y: $0.y) })
        case .line: nil
        }
    }

    /// An edit of the drawing layer, as the session's call.
    static func edit(_ id: UUID, _ geometry: RegionGeometry, in session: EDXSession) {
        if let region = region(geometry) { session.setPinRegion(id, region) }
        else if case .line(let a, let b) = geometry { session.setLineEnds(id, from: PixelPoint(x: a.x, y: a.y), to: PixelPoint(x: b.x, y: b.y)) }
    }

    static func color(_ stored: EDXPinColor?, number: Int) -> RegionColor {
        stored.map { RegionColor(red: $0.red, green: $0.green, blue: $0.blue) } ?? RegionPalette.color(at: number - 1)
    }

    /// An element's map colour until the person changes it: its hue at full brightness, black to that colour.
    static func defaultColoring(_ symbol: String) -> MapColoring {
        let rgb = EDXRoomFormat.rgb(hue: EDXRoomFormat.hue(symbol: symbol))
        return .color(RegionColor(red: rgb.0, green: rgb.1, blue: rgb.2))
    }

    static func stored(_ c: RegionColor) -> EDXPinColor { EDXPinColor(red: c.red, green: c.green, blue: c.blue) }

    /// The session's pins and lines as one set. `linesFocused` says which kind the selection belongs to (the last one the person touched).
    static func set(_ session: EDXSession, linesFocused: Bool) -> SpectralRegionSet {
        var regions: [SpectralRegion] = []
        for pin in session.pins {
            guard let g = geometry(pin.region) else { continue }
            regions.append(SpectralRegion(id: pin.id, name: pin.name, color: color(pin.color, number: pin.number), isVisible: pin.isVisible, geometry: g))
        }
        for line in session.lines {
            regions.append(SpectralRegion(id: line.id, name: line.name, color: color(line.color, number: line.number), isVisible: line.isVisible,
                                          geometry: .line(RegionPoint(x: line.from.x, y: line.from.y), RegionPoint(x: line.to.x, y: line.to.y))))
        }
        let selected = linesFocused ? session.selectedLineID : session.selectedPin?.id
        return SpectralRegionSet(regions: regions, selectedID: selected)
    }

    /// What the Regions list changed: the edits of `new` against `old` become the session's calls (rename, colour, show/hide, delete, select).
    static func apply(_ new: SpectralRegionSet, to session: EDXSession, from old: SpectralRegionSet, state: EDXRoomState) {
        let kept = Set(new.regions.map(\.id))
        for region in old.regions where !kept.contains(region.id) {
            if session.pins.contains(where: { $0.id == region.id }) { session.removePin(region.id) } else { session.removeLine(region.id) }
        }
        for region in new.regions {
            guard let before = old.regions.first(where: { $0.id == region.id }) else { continue }
            let isPin = session.pins.contains { $0.id == region.id }
            if region.name != before.name { isPin ? session.renamePin(region.id, to: region.name) : session.renameLine(region.id, to: region.name) }
            if region.color != before.color { isPin ? session.setPinColor(region.id, stored(region.color)) : session.setLineColor(region.id, stored(region.color)) }
            if region.isVisible != before.isVisible { isPin ? session.setPinVisible(region.id, region.isVisible) : session.setLineVisible(region.id, region.isVisible) }
        }
        if new.selectedID != old.selectedID, let id = new.selectedID {
            if session.pins.contains(where: { $0.id == id }) { state.linesFocused = false; session.selectPin(id) }
            else { state.linesFocused = true; session.selectLine(id) }
        }
    }

    /// A click on a region of the colour mix selects it; a click on none returns to the whole map.
    static func select(_ id: UUID?, in session: EDXSession, state: EDXRoomState) {
        guard let id else { state.linesFocused = false; session.selectWholeMap(); return }
        if session.pins.contains(where: { $0.id == id }) { state.linesFocused = false; session.selectPin(id) }
        else { state.linesFocused = true; session.selectLine(id) }
    }

    /// The delete key: the selected region (or line) goes; the selection falls back to the whole map.
    static func deleteSelected(in session: EDXSession, state: EDXRoomState) {
        if state.linesFocused, let id = session.selectedLineID { session.removeLine(id); return }
        guard let pin = session.selectedPin else { return }
        session.removePin(pin.id)
        session.selectWholeMap()
    }

    /// One layer per visible region (in its colour, named as the list names it), plus the pointer's pixel when there is one.
    static func layers(_ session: EDXSession, pixel: [Double]?, plot: EDXPlot) -> [SpectrumLayer] {
        var out: [SpectrumLayer] = []
        for pin in session.pins where pin.isVisible {
            guard let counts = session.pinSpectra[pin.id] else { continue }
            out.append(SpectrumLayer(id: pin.id.uuidString, name: pin.name, color: color(pin.color, number: pin.number),
                                     origin: plot.energyStart, step: plot.energyStep, counts: counts))
        }
        if let pixel {
            out.append(SpectrumLayer(id: "pixel", name: "Pixel", color: RegionColor(red: 1, green: 1, blue: 1),
                                     origin: plot.energyStart, step: plot.energyStep, counts: pixel, isTemporary: true))
        }
        return out
    }

    /// The selected line's profile, one series per element in the element's own hue.
    static func series(_ session: EDXSession) -> [ProfileSeries] {
        session.profiles().compactMap { p in
            guard !p.samples.isEmpty else { return nil }
            // Positions are in scan pixels; with the file's pixel size they are in its unit.
            let spacing = (p.positions.count > 1 ? p.positions[1] - p.positions[0] : 1) * (session.scanPixel?.size ?? 1)
            let rgb = EDXRoomFormat.rgb(hue: EDXRoomFormat.hue(symbol: p.symbol))
            return ProfileSeries(id: p.symbol, name: p.symbol, color: RegionColor(red: rgb.0, green: rgb.1, blue: rgb.2), values: p.samples, spacing: spacing)
        }
    }
}
