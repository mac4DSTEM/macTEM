//
//  BusyOperation.swift
//  Role: the name of the work a room is running, for the toolbar's busy line and the Stop button's help. The status line holds
//        the last event ("Opened … · 4096 channels"), which is not what runs: Quantify, the line check, Auto ID and the maps set no
//        sentence when they start, so the busy line named the open while the fit ran. The name is read from the room's own busy flags;
//        an open keeps its own sentence ("Opening <file>…"), which it sets as it starts. The Patterns toolbar read "Reading the scan for
//        the map…" during Process and the quality pass, and the Maps toolbar showed the file while Segment and the texture ran: both
//        rooms now take their busy line from here too (`toolbarOperation`).
//

import Foundation
import ShellEDXModel
import TEMCore
import TEMSession

enum BusyOperation {
    /// The EDS room's running work, the first of its busy flags in the order a Quantify sets them (the fit runs inside a refresh).
    nonisolated static func edx(opening: Bool, openSentence: String, fitting: Bool, checking: Bool, identifying: Bool, mapping: Bool,
                                refreshing: Bool) -> String? {
        if opening { return openSentence.hasPrefix("Opening") ? openSentence : "Opening the spectrum image…" }
        if fitting { return "Quantifying…" }
        if checking { return "Checking for unlisted lines…" }
        if identifying { return "Identifying elements…" }
        if mapping { return "Computing the composition maps…" }
        if refreshing { return "Updating the spectrum and maps…" }
        return nil
    }

    /// The EELS room's running work: the open, else the stage a pass is computing (the first run stage that is not current, as Run goes
    /// through them in order).
    nonisolated static func eels(opening: Bool, openSentence: String, computing: Bool, stage: EELSStage?) -> String? {
        if opening { return openSentence.hasPrefix("Opening") ? openSentence : "Opening the spectrum image…" }
        guard computing else { return nil }
        switch stage {
        case .align: return "Aligning the zero-loss peak…"
        case .thickness: return "Mapping the thickness…"
        case .deconvolve: return "Deconvolving…"
        case .fit: return "Fitting the edges…"
        case .edges, nil: return "Computing…"
        }
    }

    /// The Patterns room's running work: the open, the processing run (named by its first stage that is not current), else the map's
    /// pass, the quality pass and the scan's mean on its own pass, in the order the map pane's header shows them.
    nonisolated static func patterns(opening: Bool, processing: Bool, mapping: Bool, qualityMapping: Bool, computingMean: Bool = false,
                                     stage: PatternPipeline.Stage?) -> String? {
        if opening { return "Opening the dataset…" }
        if processing { return stage.map { "Processing: \($0.title)…" } ?? "Processing the patterns…" }
        if mapping { return "Reading the scan…" }
        if qualityMapping { return "Computing the quality maps…" }
        if computingMean { return "Computing the scan's mean pattern…" }
        return nil
    }

    /// The Maps room's running work: the open, Segment, the texture the bottom pane asked for, else a layer's picture.
    nonisolated static func maps(opening: Bool, segmenting: Bool, texturing: Bool, drawing: Bool) -> String? {
        if opening { return "Opening the orientation map…" }
        if segmenting { return "Segmenting grains…" }
        if texturing { return "Computing the texture…" }
        if drawing { return "Drawing the map…" }
        return nil
    }

    /// What `room` is running now, or nil when it is idle.
    @MainActor
    static func name(room: WorkspaceArea, appState: AppState) -> String? {
        switch room {
        case .edx:
            let s = appState.edx
            return edx(opening: s.isOpening, openSentence: appState.statusText, fitting: s.isFitting, checking: s.isChecking,
                       identifying: s.autoID == .running, mapping: s.mapsState == .running, refreshing: s.isRefreshing)
        case .eels:
            let s = appState.eels
            let next = s.stages.first { $0.stage.isRun && $0.state != .current }?.stage
            return eels(opening: s.isOpening, openSentence: appState.statusText, computing: s.isComputing, stage: next)
        case .patterns:
            let s = appState.ebsd
            return patterns(opening: s.isOpening, processing: s.isProcessing, mapping: s.isMapping, qualityMapping: s.isQualityMapping,
                            computingMean: s.isComputingMean, stage: s.firstStaleStage)
        case .indexing:
            let session = appState.indexing
            guard session.isIndexing else { return nil }
            return session.result?.method == .dictionary ? "Indexing with the dictionary…" : "Indexing with Hough…"
        case .maps:
            let s = appState.maps
            return maps(opening: s.isOpening, segmenting: s.isSegmenting, texturing: s.isTexturing, drawing: s.isDrawing)
        default:
            return nil
        }
    }

    /// The toolbar's busy line for `room`: what it runs (`name`) while its session is busy, the room's title for busy work without a
    /// name; nil while it is idle, when the toolbar shows the file. The Patterns and Maps rooms show it as it is.
    @MainActor
    static func toolbarOperation(room: WorkspaceArea, appState: AppState) -> String? {
        let busy: Bool = switch room {
        case .edx: appState.edx.isBusy
        case .eels: appState.eels.isBusy
        case .patterns: appState.ebsd.isBusy
        case .indexing: appState.indexing.isBusy
        case .maps: appState.maps.isBusy
        case .image, .fft, .diffraction, .results: false
        }
        guard busy else { return nil }
        return name(room: room, appState: appState) ?? room.title
    }
}
