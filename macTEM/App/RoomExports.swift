//
//  RoomExports.swift
//  Role: the File menu's exports of the rooms that hold a document of their own: when a room's items are listed, which of them
//        are enabled, and the call each makes. A room's items are in the menu only while that room shows its document (the rule is
//        nil anywhere else), as mac4DSTEM lists its Spectroscopy exports, and each is enabled by the rule of its button in the room's
//        inspector. An item goes through the room state's own export, the call that button makes, so the menu and the inspector
//        write the same file through the room's own save panel, or into a UI journey's export folder. The rules are pure functions,
//        pinned without a window; `ExportCommands` draws the items.
//
//        The rooms: EDS (the shared room's `EDXRoomState.export`), EELS (`EELSRoomState.export`) and Patterns
//        (`PatternsRoomState.export`).
//

import ShellEDXModel
import ShellSpectroscopy
import TEMSession

// MARK: - EDS

/// Which of the EDS room's File-menu exports are enabled, by the rules of the room's own Export buttons (the shared room's inspector).
nonisolated struct EDSExportAvailability: Sendable, Equatable {
    /// Export Spectrum CSV…: the shown spectrum has channels.
    let spectrum: Bool
    /// Export Maps…: maps are shown (a single spectrum has none).
    let maps: Bool
    /// Export Results CSV… and Export Method JSON…: a fit is in, and neither a fit nor its check is running.
    let results: Bool
    /// Export Regions CSV…: a region is kept.
    let regions: Bool
}

extension ExportSnapshot {
    /// The EDS room's exports are listed only while that room shows a spectrum image: nil in any other room and with none open, and
    /// the menu then lists none. Exhaustive over the rooms on purpose, as `availability` is.
    static func edsAvailability(area: WorkspaceArea, hasSpectrumImage: Bool, spectrumChannels: Int, shownMaps: Int, hasFit: Bool,
                                fitRunning: Bool, keptRegions: Int) -> EDSExportAvailability? {
        let inRoom: Bool
        switch area {
        case .edx: inRoom = true
        case .image, .fft, .diffraction, .results, .eels, .patterns, .indexing, .maps: inRoom = false
        }
        guard inRoom, hasSpectrumImage else { return nil }
        return EDSExportAvailability(spectrum: spectrumChannels > 0, maps: shownMaps > 0, results: hasFit && !fitRunning,
                                     regions: keptRegions > 0)
    }

    static func edsAvailability(of appState: AppState) -> EDSExportAvailability? {
        // The session is read only where it decides something: in the EDS room.
        let area = appState.navigation.workspaceArea
        guard area == .edx else { return nil }
        let session = appState.edx
        return edsAvailability(area: area, hasSpectrumImage: session.hasImage, spectrumChannels: session.spectrumCounts.count,
                               shownMaps: session.shownTiles.count, hasFit: session.fit != nil,
                               fitRunning: session.isFitting || session.isChecking, keptRegions: session.pins.count)
    }
}

// MARK: - EELS

/// Which of the EELS room's File-menu exports are enabled, by the rules of the room's own Export buttons (`EELSExportSection`).
nonisolated struct EELSExportAvailability: Sendable, Equatable {
    /// Spectrum CSV… and Spectrum MSA…: a spectrum is plotted.
    let spectrum: Bool
    /// Maps… and Per-pixel CSV…: the thickness map is there.
    let maps: Bool
    /// Results CSV…: an edge is fitted.
    let results: Bool
    /// Method JSON…: there is a method to record.
    let method: Bool
    /// Regions CSV…: a kept region has its row.
    let regions: Bool

    /// The menu's items in order: the EDS room's five where the EELS room has them, the `.msa` after the CSV, the per-pixel table last.
    static let menuKinds: [EELSExportKind] = [.spectrum, .spectrumMSA, .mapsPNG, .results, .method, .regions, .diagnostics]

    /// Whether the item of `kind` is enabled.
    func isEnabled(_ kind: EELSExportKind) -> Bool {
        switch kind {
        case .spectrum, .spectrumMSA: spectrum
        case .mapsPNG, .diagnostics: maps
        case .results: results
        case .method: method
        case .regions: regions
        }
    }
}

extension ExportSnapshot {
    /// The EELS room's exports are listed only while that room shows a spectrum image: nil in any other room and with none open.
    /// Exhaustive over the rooms on purpose, as `availability` is.
    static func eelsAvailability(area: WorkspaceArea, hasSpectrumImage: Bool, hasSpectrum: Bool, hasThicknessMap: Bool, fittedEdges: Int,
                                 hasMethodRecord: Bool, regionRows: Int) -> EELSExportAvailability? {
        let inRoom: Bool
        switch area {
        case .eels: inRoom = true
        case .image, .fft, .diffraction, .results, .edx, .patterns, .indexing, .maps: inRoom = false
        }
        guard inRoom, hasSpectrumImage else { return nil }
        return EELSExportAvailability(spectrum: hasSpectrum, maps: hasThicknessMap, results: fittedEdges > 0, method: hasMethodRecord,
                                      regions: regionRows > 0)
    }

    static func eelsAvailability(of appState: AppState) -> EELSExportAvailability? {
        // The session is read only where it decides something: in the EELS room.
        let area = appState.navigation.workspaceArea
        guard area == .eels else { return nil }
        let session = appState.eels
        return eelsAvailability(area: area, hasSpectrumImage: session.hasImage, hasSpectrum: session.plot != nil,
                                hasThicknessMap: session.map != nil, fittedEdges: session.resultRows.count,
                                hasMethodRecord: session.hasMethodRecord, regionRows: session.pinRows.count)
    }
}

// MARK: - Patterns

/// Which of the Patterns room's File-menu exports are enabled. The menu follows the facts that change when the person does something
/// to the room, never the pattern under the pointer (the menu would be made again at every scan point the pointer passes): where
/// the room's own button also asks for a pattern or an overlay at that point, the item stays enabled and the room's export says in
/// the status line what is missing, as it does for its button.
nonisolated struct PatternsExportAvailability: Sendable, Equatable {
    /// Map PNG…: the map has landed.
    let map: Bool
    /// Pattern with Overlay… and Overlay CSV…: the Kikuchi overlay is on and the dataset has the orientations it is drawn from.
    let overlay: Bool

    /// Whether the item of `kind` is enabled; the pattern and the two JSON files are there whenever a dataset is.
    func isEnabled(_ kind: PatternsExportKind) -> Bool {
        switch kind {
        case .mapPNG: map
        case .overlayPNG, .overlayCSV: overlay
        case .patternPNG, .metadataJSON, .methodJSON: true
        }
    }
}

extension ExportSnapshot {
    /// The Patterns room's exports are listed only while that room shows a dataset: nil in any other room and with none open.
    /// Exhaustive over the rooms on purpose, as `availability` is.
    static func patternsAvailability(area: WorkspaceArea, hasDataset: Bool, mapLanded: Bool, overlayOn: Bool,
                                     canOverlay: Bool) -> PatternsExportAvailability? {
        let inRoom: Bool
        switch area {
        case .patterns: inRoom = true
        case .image, .fft, .diffraction, .results, .edx, .eels, .indexing, .maps: inRoom = false
        }
        guard inRoom, hasDataset else { return nil }
        return PatternsExportAvailability(map: mapLanded, overlay: overlayOn && canOverlay)
    }

    static func patternsAvailability(of appState: AppState) -> PatternsExportAvailability? {
        // The session is read only where it decides something: in the Patterns room.
        let area = appState.navigation.workspaceArea
        guard area == .patterns else { return nil }
        let session = appState.ebsd
        return patternsAvailability(area: area, hasDataset: session.hasDataset, mapLanded: session.mapPresentation.canvas != nil,
                                    overlayOn: session.overlayOn, canOverlay: session.canOverlay)
    }
}

// MARK: - The calls

/// What a room's File-menu export does: the room state's own export, as the room's inspector button calls it.
enum RoomExports {
    /// The EDS room's: the bytes of `kind` to the room's save panel, or into a UI journey's export folder, with the room's line in
    /// the status line. The returned task ends when the bytes are made and handed over (a test awaits it).
    @discardableResult
    static func eds(_ kind: EDXExportKind, appState: AppState) -> Task<Void, Never> {
        Task { await appState.edxRoom.export(kind, from: appState.edx, directory: appState.exportDirectory) { appState.statusText = $0 } }
    }

    /// The EELS room's: the bytes of `kind`, the maps as the Maps control shows them, to the room's save panel or into a UI journey's
    /// export folder, with the room's line in the status line.
    static func eels(_ kind: EELSExportKind, appState: AppState) {
        appState.eelsRoom.export(kind, from: appState.eels, maps: EELSMapsBlock.shownMaps(appState.eels, appState.eelsRoom),
                                 directory: appState.exportDirectory) { appState.statusText = $0 }
    }

    /// The Patterns room's: the bytes of `kind` at the pattern on screen, to the room's save panel or into a UI journey's export
    /// folder, with the room's line in the status line (what is missing, when there is nothing to write).
    static func patterns(_ kind: PatternsExportKind, appState: AppState) {
        appState.patternsRoom.export(kind, from: appState.ebsd, directory: appState.exportDirectory) { appState.statusText = $0 }
    }
}
