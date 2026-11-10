//
//  ExportCommands.swift
//  Role: the File menu's export items, in their own `Commands`, so `ImageCommands` and `AppState` stay as they are; the scene adds
//        `ExportCommands()` to its `.commands`. They act on the focused window's `AppState`. Listed always, each enabled only where
//        it can act: Export Image… (⇧⌘E) and Export Profile… in the Image room and Export Results… (⇧⌥⌘E) in the Results room
//        (`ExportSnapshot.availability`), Export Transform… (⌥⌘E), Export Radial Profile… and Export Spots… in the FFT room
//        (`ExportSnapshot.fftAvailability`), and Export Session Report… wherever the SEM rooms hold a result. Listed only while
//        their room shows its document, as mac4DSTEM lists its Spectroscopy exports: the EDS room's five
//        (`ExportSnapshot.edsAvailability`), each through the room's own export (`RoomExports`), the call its inspector button makes.
//
//        PLACEMENT: after the Save group, which this app's File menu fills with Close Image and Close Window (`ImageCommands`
//        replaces it) — the anchor already known to render here. `.importExport`, the HIG's home of Export, would put the items
//        in a group of their own, but it is not checked on screen in this window, and an item that silently does not appear
//        costs more than one without its own section; a Divider keeps them apart from Close. The drive confirms the menu,
//        and moving them is this one placement. ⇧⌘E collides with nothing in macTEM (⌘E is the system's Use Selection
//        for Find).
//

import ShellSpectroscopy
import SwiftUI

struct ExportCommands: Commands {
    @FocusedValue(\.appState) private var appState

    var body: some Commands {
        // Read once: both items follow the same state, and a second read of the focused value is a second dependency.
        let availability = appState.map(ExportSnapshot.availability(of:))
        let fft = appState.map(ExportSnapshot.fftAvailability(of:))
        let session = appState.map(SEMSessionLedger.hasRows(_:))
        let eds = appState.flatMap(ExportSnapshot.edsAvailability(of:))
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
            // The SEM session as one report (D-SEM-103): enabled wherever the SEM rooms hold a result; no key.
            Button("Export Session Report…") {
                if let appState { ExportPanels.exportSessionReport(appState: appState) }
            }
            .disabled(session != true)
            // The EDS room's five, in the menu only while that room shows a spectrum image.
            if let appState, let eds { edsItems(eds, appState: appState) }
        }
    }

    /// The EDS room's exports, named and ordered as mac4DSTEM's Spectroscopy exports are: each enabled by the rule of its button in
    /// the room's inspector (`ExportSnapshot.edsAvailability`) and written by the room's own export (`RoomExports.eds`). No keys.
    @ViewBuilder
    private func edsItems(_ eds: EDSExportAvailability, appState: AppState) -> some View {
        Divider()
        Button("Export Spectrum CSV…") { RoomExports.eds(.spectrum, appState: appState) }
            .disabled(!eds.spectrum)
        Button("Export Maps…") { RoomExports.eds(.mapsPNG, appState: appState) }
            .disabled(!eds.maps)
        Button("Export Results CSV…") { RoomExports.eds(.results, appState: appState) }
            .disabled(!eds.results)
        Button("Export Method JSON…") { RoomExports.eds(.method, appState: appState) }
            .disabled(!eds.results)
        Button("Export Regions CSV…") { RoomExports.eds(.pins, appState: appState) }
            .disabled(!eds.regions)
    }
}
