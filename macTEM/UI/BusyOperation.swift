//
//  BusyOperation.swift
//  Role: the name of the work a spectrum room is running, for the toolbar's busy line and the Stop button's help. The status line holds
//        the last event ("Opened … · 4096 channels"), which is not what runs: Quantify, the line check, Auto ID and the maps set no
//        sentence when they start, so the busy line named the open while the fit ran. The name is read from the room's own busy flags;
//        an open keeps its own sentence ("Opening <file>…"), which it sets as it starts.
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
        case .fit: return "Fitting the edges…"
        case .edges, nil: return "Computing…"
        }
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
        default:
            return nil
        }
    }
}
