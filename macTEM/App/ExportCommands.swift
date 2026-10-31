//
//  ExportCommands.swift
//  Role: (⇧⌥⌘E; below the FFT room's three.) The File menu's two export items: Export Image… (⇧⌘E)
//        and Export Profile… (no key). Their own `Commands`, so `ImageCommands` and `AppState` stay as they are; the scene
//        adds `ExportCommands()` to its `.commands`. They act on the focused window's `AppState`, and are enabled by
//        `ExportSnapshot.availability`: an image with its pixels in the Image room, no read running, and for the second a
//        profile with samples selected. This is where a later room's export goes: the rule switches on the workspace area,
//        and only the Image room exports.
//
//        PLACEMENT: after the Save group, which this app's File menu fills with Close Image and Close Window (`ImageCommands`
//        replaces it) — the anchor already known to render here. `.importExport`, the HIG's home of Export, would put the items
//        in a group of their own, but it is not checked on screen in this window, and an item that silently does not appear
//        costs more than one without its own section; a Divider keeps them apart from Close. The drive confirms the menu,
//        and moving them is this one placement. ⇧⌘E collides with nothing in macTEM (⌘E is the system's Use Selection
//        for Find).
//

import SwiftUI

struct ExportCommands: Commands {
    @FocusedValue(\.appState) private var appState

    var body: some Commands {
        // Read once: both items follow the same state, and a second read of the focused value is a second dependency.
        let availability = appState.map(ExportSnapshot.availability(of:))
        let fft = appState.map(ExportSnapshot.fftAvailability(of:))
        CommandGroup(after: .saveItem) {
            Divider()
            Button("Export Image…") {
                if let appState { ExportPanels.exportImage(appState: appState) }
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .disabled(availability?.image != true)
            Button("Export Profile…") {
                if let appState { ExportPanels.exportProfile(appState: appState) }
            }
            .disabled(availability?.profile != true)
            // The FFT room's three: enabled only there, with the spectrum on screen current.
            Divider()
            Button("Export Transform…") {
                if let appState { ExportPanels.exportTransform(appState: appState) }
            }
            .keyboardShortcut("e", modifiers: [.command, .option])
            .disabled(fft?.transform != true)
            Button("Export Radial Profile…") {
                if let appState { ExportPanels.exportRadialProfile(appState: appState) }
            }
            .disabled(fft?.profile != true)
            Button("Export Spots…") {
                if let appState { ExportPanels.exportSpots(appState: appState) }
            }
            .disabled(fft?.spots != true)
            // The Results room's one: every finished measurement of the file as one CSV. ⇧⌥⌘E is free (⌘E is the
            // system's Use Selection for Find; ⇧⌘E and ⌥⌘E are the Image and FFT rooms').
            Divider()
            Button("Export Results…") {
                if let appState { ExportPanels.exportResults(appState: appState) }
            }
            .keyboardShortcut("e", modifiers: [.command, .option, .shift])
            .disabled(availability?.results != true)
        }
    }
}
