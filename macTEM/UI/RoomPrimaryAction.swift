//
//  RoomPrimaryAction.swift
//  Role: the toolbar's one verb for the room that has one (design 2026-10-22, §2.2): EDS has Quantify, EELS has Run (the stages that are not current,
//        in order); the Image, FFT, Diffraction and Results rooms have none yet. The button and its glass styles are ShellLayout's
//        `PrimaryActionButton`; what the verb is, when it is enabled and what it says while blocked is this file's.
//

import ShellLayout
import SwiftUI
import TEMCore
import TEMSession

/// How far the running spectrum-image work is, for the toolbar's busy display: the EDS room's open, or the EELS room's pass (align, thickness, fit); nil while idle
/// or when the work reports no fraction.
enum RoomProgress {
    @MainActor
    static func fraction(room: WorkspaceArea, appState: AppState) -> Double? {
        switch room {
        case .edx: appState.edx.isOpening ? appState.edx.openProgress : nil
        case .eels: appState.eels.isComputing ? min(max(appState.eels.progress, 0), 1) : nil
        default: nil
        }
    }
}

enum RoomPrimaryAction {
    /// The value for the toolbar, or nil when this room's verb does not apply (no verb, no document, or the document still opening).
    @MainActor
    static func current(_ appState: AppState) -> PrimaryAction? {
        switch appState.navigation.workspaceArea {
        case .edx:
            let session = appState.edx
            if session.isOpening {
                // Opening: the verb is the running state, so the toolbar shows Stop (as ⌘.); the read ends at its next check and the room
                // returns to what it showed (Paul's drive, 2026-10-23: an open could not be stopped from the window).
                return PrimaryAction(title: "Quantify", isEnabled: false, help: "Opening the spectrum image", hint: "Opening the spectrum image",
                                     isRunning: true, operationName: appState.statusText, stop: { session.stop() }, run: {})
            }
            guard session.hasImage else { return nil }
            return PrimaryAction(
                title: "Quantify",
                isEnabled: session.canQuantify,
                help: session.quantifyBlocker ?? "Fit the region's spectrum and compute the composition; from then on it follows every change",
                hint: "Fits the region's spectrum and computes the composition",
                isRunning: session.isBusy,
                operationName: appState.statusText,
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
                operationName: appState.statusText,
                stop: { session.stop() },
                run: { session.run() })
        default:
            return nil
        }
    }

    /// ⌘.: ends whatever the shown room is running.
    @MainActor
    static func stopActive(_ appState: AppState) {
        switch appState.navigation.workspaceArea {
        case .edx: appState.edx.stop()
        case .eels: appState.eels.stop()
        case .diffraction: appState.openItems.selected?.diffraction.stop()
        default: break
        }
    }

    @MainActor
    static func canStop(_ appState: AppState) -> Bool {
        switch appState.navigation.workspaceArea {
        case .edx: appState.edx.isBusy
        case .eels: appState.eels.isBusy
        case .diffraction: appState.openItems.selected?.diffraction.isFitting ?? false
        default: false
        }
    }
}
