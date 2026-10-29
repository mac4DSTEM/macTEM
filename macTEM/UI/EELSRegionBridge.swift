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

    /// The selected line's profile, one series per map in the map's own hue.
    static func series(_ session: EELSSession, hue: (String) -> Double) -> [ProfileSeries] {
        session.profiles().compactMap { p in
            guard !p.samples.isEmpty else { return nil }
            let spacing = p.positions.count > 1 ? p.positions[1] - p.positions[0] : 1
            let rgb = EDXRoomFormat.rgb(hue: hue(p.id))
            return ProfileSeries(id: p.id, name: p.title, color: RegionColor(red: rgb.0, green: rgb.1, blue: rgb.2), values: p.samples, spacing: spacing)
        }
    }
}
