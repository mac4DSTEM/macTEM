//
//  RoomPrimaryAction.swift
//  Role: the toolbar's one verb for the room that has one (design 2026-10-22, §2.2): EDS has Quantify, EELS has Run (the stages that are not current,
//        in order), Patterns has Process, Indexing has Index, Maps has Segment; the Image, FFT, Diffraction and Results rooms have none yet. The button and its glass styles are ShellLayout's
//        `PrimaryActionButton`; what the verb is, when it is enabled and what it says while blocked is this file's. Workspace > Run (⌘R)
//        runs the same verb from the menu, on exactly when the button can run it (`canRun`). A room without a verb shows Cancel in the
//        verb's place while a run left going in another room is the toolbar's busy line (`BusyOperation.backgroundRoom`).
//

import ShellLayout
import SwiftUI
import TEMCore
import TEMSession
import ShellEDXModel

/// How far the running work is, for the toolbar's busy display: the EDS room's open, the EELS room's pass (align, thickness, fit), the
/// Patterns room's run or pass, the Indexing room's run; nil while idle or when the work reports no fraction (the Maps room's Segment and
/// texture report none).
enum RoomProgress {
    @MainActor
    static func fraction(room: WorkspaceArea, appState: AppState) -> Double? {
        switch room {
        case .edx: appState.edx.isOpening ? appState.edx.openProgress : nil
        case .eels: appState.eels.isComputing ? min(max(appState.eels.progress, 0), 1) : nil
        case .patterns: patternsFraction(appState.ebsd)
        case .indexing: appState.indexing.isIndexing ? min(max(appState.indexing.progress, 0), 1) : nil
        default: nil
        }
    }

    /// The Patterns room's running work in the order `BusyOperation.patterns` names it: Process, the map's pass, the quality pass.
    @MainActor
    private static func patternsFraction(_ session: EBSDSession) -> Double? {
        let fraction: Double
        if session.isProcessing {
            fraction = session.processProgress
        } else if session.isMapping {
            fraction = session.mapProgress
        } else if session.isQualityMapping {
            fraction = session.qualityProgress
        } else {
            return nil
        }
        return min(max(fraction, 0), 1)
    }
}

enum RoomPrimaryAction {
    /// The value for the toolbar, or nil when this room's verb does not apply (no verb, no document, or the document still opening).
    /// A room without a verb answers a Cancel alone (no title, running) while the toolbar shows another room's run.
    @MainActor
    static func current(_ appState: AppState) -> PrimaryAction? {
        switch appState.navigation.workspaceArea {
        case .edx:
            let session = appState.edx
            if session.isOpening {
                // Opening: the verb is the running state, so the toolbar shows Stop (as ⌘.); the read ends at its next check and the room
                // returns to what it showed (the owner's drive, 2026-10-23: an open could not be stopped from the window).
                return PrimaryAction(title: "Quantify", isEnabled: false, help: "Opening the spectrum image", hint: "Opening the spectrum image",
                                     isRunning: true, operationName: BusyOperation.name(room: .edx, appState: appState), stop: { session.stop() }, run: {})
            }
            guard session.hasImage else { return nil }
            return PrimaryAction(
                title: "Quantify",
                isEnabled: session.canQuantify,
                help: session.quantifyBlocker ?? "Fit the region's spectrum and compute the composition; from then on it follows every change",
                hint: "Fits the region's spectrum and computes the composition",
                isRunning: session.isBusy,
                operationName: BusyOperation.name(room: .edx, appState: appState),
                stop: { session.stop() },
                run: { session.quantify() })
        case .eels:
            let session = appState.eels
            guard session.hasImage, !session.isOpening else { return nil }
            let next = session.stages.first { $0.stage.isRun && $0.state != .current && ($0.stage != .fit || session.fitBlocker == nil) }
            return PrimaryAction(
                title: "Run",
                isEnabled: session.canRun,
                help: next.map { "Run the stages that are not current, starting with \($0.stage.title)" } ?? "Every stage is current",
                hint: "Aligns the zero-loss peak, maps the thickness and fits the picked edges",
                isRunning: session.isBusy,
                operationName: BusyOperation.name(room: .eels, appState: appState),
                stop: { session.stop() },
                run: { session.run() })
        case .patterns:
            // Process (pattern-processing design §4): the stages that are not current, over the whole scan, into memory.
            let session = appState.ebsd
            guard session.hasDataset, !session.isOpening else { return nil }
            return PrimaryAction(
                title: "Process",
                isEnabled: session.canProcess,
                help: session.processingRefusal?.sentence
                    ?? session.firstStaleStage.map { "Run the stages that are not current, starting with \($0.title)" } ?? "Every stage is current",
                hint: "Removes the backgrounds, rescales and bins every pattern of the scan",
                isRunning: session.isBusy,
                operationName: BusyOperation.name(room: .patterns, appState: appState),
                stop: { session.stop() },
                run: { session.process() })
        case .indexing:
            // Index (indexing-room design §3): the method picked over the whole scan, row by row (Hough) or block by block (dictionary)
            // onto the map; Stop keeps the indexed rows.
            let session = appState.indexing
            guard session.hasDataset, !session.patterns.isOpening else { return nil }
            return PrimaryAction(
                title: "Index",
                isEnabled: session.canIndex,
                help: session.verbHelp,
                hint: session.method == .hough ? "Detects the bands of every pattern and indexes them against the phases (Hough)"
                    : "Matches every pattern against patterns simulated from the master pattern (Dictionary)",
                isRunning: session.isBusy,
                operationName: BusyOperation.name(room: .indexing, appState: appState),
                stop: { session.stop() },
                run: { session.index() })
        case .maps:
            // Segment (orientation-maps-room design §2): the grain analysis of the whole map with the Grains and Misorientation
            // sections' settings: grains, boundaries, KAM, GOS, GND, the grain table and each grain's slip.
            let session = appState.maps
            guard session.hasMap, !session.isOpening else { return nil }
            return PrimaryAction(
                title: "Segment",
                isEnabled: session.canSegment,
                help: session.segmentBlocker
                    ?? (session.analysisIsStale ? "Segment again with the changed settings" : "Find the grains, their boundaries, KAM, GOS and GND"),
                hint: "Finds the grains of the map and computes KAM, GOS, GND and each grain's Schmid factors",
                isRunning: session.isSegmenting,
                operationName: BusyOperation.name(room: .maps, appState: appState),
                stop: { session.stop() },
                run: { session.segment() })
        default:
            // A room without a verb keeps the Cancel of a run left going in another room, the one the toolbar's centre shows (ShellLayout's
            // `PrimaryAction.title`: nil, "but a run may still be in flight and keep its Cancel"; mac4DSTEM's `isRunning: appState.isBusy`
            // whatever the room). It is ⌘.'s Stop as a button. A room with a verb keeps its verb: rooms run side by side, the shown room's
            // verb may start its own run, and ⌘. still reaches the other one.
            guard let other = BusyOperation.backgroundRoom(appState), canStop(room: other, appState: appState) else { return nil }
            return PrimaryAction(
                title: nil,
                isRunning: true,
                operationName: BusyOperation.name(room: other, appState: appState).map { "\(other.title) · \($0)" } ?? other.title,
                stop: { RoomPrimaryAction.stopActive(appState) },
                run: {})
        }
    }

    /// Workspace > Run (⌘R): the shown room's verb as its title ("Process", "Index"), "Run" in a room without one or with no window.
    @MainActor
    static func runTitle(_ appState: AppState?) -> String {
        appState.flatMap { current($0)?.title } ?? "Run"
    }

    /// Whether ⌘R runs `action` now: a verb that applies, is enabled and is not running. The toolbar button's own readiness, so ⌘R is
    /// never a dead key (mac4DSTEM's Run Current Task).
    @MainActor
    static func canRun(_ action: PrimaryAction?) -> Bool {
        guard let action, action.title != nil else { return false }
        return action.isEnabled && !action.isRunning
    }

    /// ⌘R: runs the shown room's verb when it can run now.
    @MainActor
    static func runActive(_ appState: AppState) {
        guard let action = current(appState), canRun(action) else { return }
        action.run()
    }

    /// The room ⌘. acts on: the shown room while it runs something Stop ends; else the room whose run the toolbar shows in its place
    /// (`BusyOperation.backgroundRoom`) when Stop ends it, so a run left going in another room can be stopped from any room; else the
    /// shown room.
    @MainActor
    static func stopTarget(_ appState: AppState) -> WorkspaceArea {
        let shown = appState.navigation.workspaceArea
        guard !canStop(room: shown, appState: appState), let other = BusyOperation.backgroundRoom(appState),
              canStop(room: other, appState: appState) else { return shown }
        return other
    }

    /// ⌘.: ends whatever the shown room is running, or, while it is idle, the run of another room the toolbar shows (`stopTarget`).
    @MainActor
    static func stopActive(_ appState: AppState) {
        switch stopTarget(appState) {
        case .edx: appState.edx.stop()
        case .eels: appState.eels.stop()
        case .patterns: appState.ebsd.stop()
        case .indexing: appState.indexing.stop()
        case .maps: appState.maps.stop()
        case .diffraction: appState.openItems.selected?.diffraction.stop()
        default: break
        }
    }

    @MainActor
    static func canStop(_ appState: AppState) -> Bool {
        canStop(room: stopTarget(appState), appState: appState)
    }

    /// The Stop item's title: "Stop" for the shown room's run, "Stop Indexing" for the run of another room (`stopTarget`).
    @MainActor
    static func stopTitle(_ appState: AppState) -> String {
        let target = stopTarget(appState)
        return target == appState.navigation.workspaceArea ? "Stop" : "Stop \(target.title)"
    }

    /// Whether `room` runs something Stop ends (a layer's picture in the Maps room is not stopped).
    @MainActor
    static func canStop(room: WorkspaceArea, appState: AppState) -> Bool {
        switch room {
        case .edx: appState.edx.isBusy
        case .eels: appState.eels.isBusy
        case .patterns: appState.ebsd.isBusy
        case .indexing: appState.indexing.isBusy
        case .maps: appState.maps.isOpening || appState.maps.isSegmenting || appState.maps.isTexturing
        case .diffraction: appState.openItems.selected?.diffraction.isFitting ?? false
        default: false
        }
    }
}
