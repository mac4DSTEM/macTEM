//
//  ExportPanels.swift
//  Role: the two save panels of the Image room's export (V1-10 slice 1, archive: export-design-2026-10-13.md): Export
//        Image… (a PNG, with the Scale bar and Marks options) and Export Profile… (a CSV, no options). They present
//        a sheet on the window, ask `ExportSnapshot` for what the selected file gives, and hand TEMCore's `@concurrent`
//        writers the values; the infobar and the alert report. Nothing is rendered or written here.
//
//  WHY APPKIT (CLAUDE.md: AppKit only where SwiftUI cannot do the job, named where used): the macOS 27 SDK's
//  `fileExporter` overloads and `fileDialog*` modifiers offer no accessory, and the options belong in the save panel
//  (Preview's export is the model). A SwiftUI options sheet followed by `fileExporter` would be two dialogs for one act and
//  would have to render the PNG before the place is chosen. `NSSavePanel` and the `NSHostingView` accessory live here
//  (`UI/` imports no AppKit); the accessory's content is SwiftUI (`UI/ExportImageOptions.swift`). The third named AppKit
//  use, after the Metal image view and `NSWorkspace`'s Show in Finder.
//
//  THE SHEET: the host is `NSApp.mainWindow` (a sheet is key, not main), and nothing is presented when the window has a
//  sheet already (the open panel or the alert can be up, and a menu item stays enabled under a window sheet): the entry
//  point beeps, as AppKit does for a refused action, and so it does while an export is still writing. The panel is begun
//  synchronously (`Task.immediate`), so a second ⇧⌘E before the first sheet is up finds it. Anything but OK is a silent
//  cancel, a window closed under the sheet included: AppKit takes the sheet away with its window and never calls the
//  completion handler, so `present` cancels the panel when its window is about to close (Gate B U1, measured for
//  `close()`). `orderOut` takes the sheet away the same way and posts no willClose (measured: only the sheet-ended and
//  occlusion notifications), so it is not covered; nothing in macTEM orders the image window out. Nothing keeps the panel
//  or the options alive by hand: both are read after the await, which keeps them.
//
//  THE NAME FIELD starts as the bare stem and never carries an extension: `allowedContentTypes` supplies it (no
//  "scan.png.png"). The extension is shown. The panel opens in the image's folder (the system would otherwise reuse its
//  last folder silently).
//
//  THE WRITE: the snapshot is taken when the panel opens; after OK the render and the write run in TEMCore's
//  `@concurrent` entry points, reached only through the snapshot's own `write(to:)` (the one hand-over, which a test calls;
//  a 4096² PNG maps 16 M pixels and encodes about 50 MB), so the main actor only presents and reports: "Exporting scan.png…", then "Exported scan.png — 1024 × 1024 px" (also announced to VoiceOver: nothing else
//  in macTEM announces the infobar), or the app's alert. The panel grants the chosen file, not its folder: TEMCore writes
//  through the destination's item-replacement directory (`ExportFile.write`), never an atomic write beside it.
//

import ImagoCore
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import TEMCore
import TEMSession

@MainActor
enum ExportPanels {

    /// The exports rendering and writing right now (never more than one: a second is refused). Transient, a fact about
    /// the process and not about any file, so it lives here and not on `AppState`. Counted from the panel's OK to the
    /// infobar's last line, so two exports never interleave their status lines or write one destination twice.
    private static var writing = 0

    // MARK: Entry points

    /// File > Export Image… (⇧⌘E): the selected file's image as a PNG.
    static func exportImage(appState: AppState) {
        guard ExportSnapshot.availability(of: appState).image,
              let snapshot = ExportSnapshot.imageSnapshot(in: appState.openItems) else { return }
        guard let window = hostWindowOrBeep() else { return }
        // A side TEMCore would refuse is refused by name now, not after the user has chosen a place.
        if let refusal = ExportSnapshot.refusal(width: snapshot.display.width, height: snapshot.display.height) {
            appState.present(refusal)
            return
        }
        Task.immediate { await presentImagePanel(snapshot, on: window, appState: appState) }
    }

    /// File > Export Profile… and the selected profile's button: the CSV of its samples.
    static func exportProfile(appState: AppState) {
        guard ExportSnapshot.availability(of: appState).profile,
              let snapshot = ExportSnapshot.profileSnapshot(in: appState.openItems) else { return }
        guard let window = hostWindowOrBeep() else { return }
        Task.immediate { await presentProfilePanel(snapshot, on: window, appState: appState) }
    }

    /// File > Export Transform… (⌥⌘E) and the inspector's Export menu, Transform as PNG…: the spectrum on screen as a PNG.
    static func exportTransform(appState: AppState) {
        guard ExportSnapshot.fftAvailability(of: appState).transform,
              let snapshot = ExportSnapshot.transformSnapshot(in: appState.openItems) else { return }
        guard let window = hostWindowOrBeep() else { return }
        if let refusal = ExportSnapshot.refusal(width: snapshot.display.width, height: snapshot.display.height) {
            appState.present(refusal)
            return
        }
        Task.immediate { await presentTransformPanel(snapshot, on: window, appState: appState) }
    }

    /// File > Export Radial Profile… and the inspector's Export menu, Radial Profile as CSV…: the profile's bins as a CSV.
    static func exportRadialProfile(appState: AppState) {
        guard ExportSnapshot.fftAvailability(of: appState).profile,
              let snapshot = ExportSnapshot.radialProfileSnapshot(in: appState.openItems) else { return }
        guard let window = hostWindowOrBeep() else { return }
        Task.immediate { await presentRadialProfilePanel(snapshot, on: window, appState: appState) }
    }

    /// File > Export Spots… and the inspector's Export menu, Spots as CSV…: the measured spots as a CSV.
    static func exportSpots(appState: AppState) {
        guard ExportSnapshot.fftAvailability(of: appState).spots,
              let snapshot = ExportSnapshot.spotsSnapshot(in: appState.openItems) else { return }
        guard let window = hostWindowOrBeep() else { return }
        Task.immediate { await presentSpotsPanel(snapshot, on: window, appState: appState) }
    }

    /// File > Export Results… (⇧⌥⌘E) and the Results inspector's Export menu: every finished measurement of the file as one CSV.
    static func exportResults(appState: AppState) {
        guard ExportSnapshot.availability(of: appState).results,
              let snapshot = ExportSnapshot.resultsSnapshot(in: appState.openItems) else { return }
        // `--export-dir` (a UI journey): written without a panel, so no window is needed.
        if appState.exportDirectory != nil {
            Task.immediate { await presentResultsPanel(snapshot, on: nil, appState: appState) }
            return
        }
        guard let window = hostWindowOrBeep() else { return }
        Task.immediate { await presentResultsPanel(snapshot, on: window, appState: appState) }
    }

    /// The window the sheet is presented on: the main window, unless it has a sheet already.
    static func hostWindow() -> NSWindow? {
        guard let window = NSApp.mainWindow, window.attachedSheet == nil else { return nil }
        return window
    }

    /// The host window, or a beep and nil when an export is writing or a sheet is up: an enabled command that did nothing
    /// and said nothing would read as broken (Gate B U2, U3).
    private static func hostWindowOrBeep() -> NSWindow? {
        if writing == 0, let window = hostWindow() { return window }
        NSSound.beep()
        return nil
    }

    // MARK: The panels

    /// A save panel for one content type, named and placed as the design says. `panel.url` gets the extension of
    /// `type`, whatever the user typed.
    static func savePanel(type: UTType, name: String, directory: URL?, message: String) -> NSSavePanel {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [type]
        panel.nameFieldStringValue = name
        panel.nameFieldLabel = "Export As:"
        panel.prompt = "Export"
        panel.message = message
        panel.directoryURL = directory
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        return panel
    }

    static func imagePanel(for snapshot: ExportImageSnapshot, choices: ExportImageChoices) -> NSSavePanel {
        pngPanel(name: snapshot.defaultName, directory: snapshot.directory, message: snapshot.message, choices: choices)
    }

    /// A PNG panel with the Scale bar and (Marks | Spots) accessory: the Image room's and the FFT transform's.
    static func pngPanel(name: String, directory: URL?, message: String, choices: ExportImageChoices) -> NSSavePanel {
        let panel = savePanel(type: .png, name: name, directory: directory, message: message)
        panel.accessoryView = accessory(for: choices)
        return panel
    }

    static func transformPanel(for snapshot: ExportTransformSnapshot, choices: ExportImageChoices) -> NSSavePanel {
        pngPanel(name: snapshot.defaultName, directory: snapshot.directory, message: snapshot.message, choices: choices)
    }

    static func radialProfilePanel(for snapshot: ExportRadialProfileSnapshot) -> NSSavePanel {
        savePanel(type: .commaSeparatedText, name: snapshot.defaultName, directory: snapshot.directory, message: snapshot.message)
    }

    static func spotsPanel(for snapshot: ExportSpotsSnapshot) -> NSSavePanel {
        savePanel(type: .commaSeparatedText, name: snapshot.defaultName, directory: snapshot.directory, message: snapshot.message)
    }

    static func resultsPanel(for snapshot: ExportResultsSnapshot) -> NSSavePanel {
        savePanel(type: .commaSeparatedText, name: snapshot.defaultName, directory: snapshot.directory, message: snapshot.message)
    }

    static func profilePanel(for snapshot: ExportProfileSnapshot) -> NSSavePanel {
        savePanel(type: .commaSeparatedText, name: snapshot.defaultName, directory: snapshot.directory,
                  message: snapshot.message)
    }

    /// The options as a view the panel can hold: the hosting view's `fittingSize` with the default sizing options, set
    /// as its frame once, so the accessory never changes height after the panel is presented.
    static func accessory(for choices: ExportImageChoices) -> NSHostingView<ExportImageOptions> {
        let hosting = NSHostingView(rootView: ExportImageOptions(choices: choices))
        hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)
        return hosting
    }

    // MARK: Present, then write

    /// `panel` as a sheet on `window`, and how it ended. A window that closes under its sheet takes the sheet with it
    /// and the completion handler is never called, so the await would hang for the life of the process holding the
    /// panel, the options and the snapshot (Gate B U1: after `close()` the continuation stayed suspended; after
    /// `cancel(nil)` it resumed at once). The panel is cancelled when the window is about to close, and the observer
    /// goes when the sheet is over.
    static func present(_ panel: NSSavePanel, on window: NSWindow) async -> NSApplication.ModalResponse {
        let observer = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window,
                                                              queue: .main) { [weak panel] _ in
            MainActor.assumeIsolated { panel?.cancel(nil) }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        return await panel.beginSheetModal(for: window)
    }

    private static func presentImagePanel(_ snapshot: ExportImageSnapshot, on window: NSWindow,
                                          appState: AppState) async {
        let choices = ExportImageChoices(snapshot.defaults)
        let panel = imagePanel(for: snapshot, choices: choices)
        guard await present(panel, on: window) == .OK, let url = panel.url else { return }

        writing += 1
        defer { writing -= 1 }
        let name = url.lastPathComponent
        let options = ExportSnapshot.options(scaleBar: choices.scaleBar, marks: choices.marks,
                                             offersMarks: choices.offersMarks)
        appState.statusText = ExportSnapshot.exportingLine(name: name)
        do {
            let rendered = try await snapshot.write(to: url, options: options)
            report(ExportSnapshot.imageDoneLine(name: name, width: rendered.width, height: rendered.height,
                                                barLeftOut: rendered.barLeftOut), in: appState)
        } catch {
            appState.present(error)
        }
    }

    private static func presentProfilePanel(_ snapshot: ExportProfileSnapshot, on window: NSWindow,
                                            appState: AppState) async {
        let panel = profilePanel(for: snapshot)
        guard await present(panel, on: window) == .OK, let url = panel.url else { return }

        writing += 1
        defer { writing -= 1 }
        let name = url.lastPathComponent
        appState.statusText = ExportSnapshot.exportingLine(name: name)
        do {
            try await snapshot.write(to: url)
            report(ExportSnapshot.profileDoneLine(name: name, samples: snapshot.profile.samples.count), in: appState)
        } catch {
            appState.present(error)
        }
    }

    private static func presentTransformPanel(_ snapshot: ExportTransformSnapshot, on window: NSWindow,
                                              appState: AppState) async {
        let choices = ExportImageChoices(snapshot.defaults, kind: .spots)
        let panel = transformPanel(for: snapshot, choices: choices)
        guard await present(panel, on: window) == .OK, let url = panel.url else { return }

        writing += 1
        defer { writing -= 1 }
        let name = url.lastPathComponent
        let options = ExportSnapshot.options(scaleBar: choices.scaleBar, marks: choices.marks, offersMarks: choices.offersMarks)
        appState.statusText = ExportSnapshot.exportingLine(name: name)
        do {
            let rendered = try await snapshot.write(to: url, options: options)
            report(ExportSnapshot.transformDoneLine(name: name, width: rendered.width, height: rendered.height,
                                                    spots: options.marks ? snapshot.marks.count : 0,
                                                    barLeftOut: rendered.barLeftOut), in: appState)
        } catch {
            appState.present(error)
        }
    }

    private static func presentRadialProfilePanel(_ snapshot: ExportRadialProfileSnapshot, on window: NSWindow,
                                                  appState: AppState) async {
        let panel = radialProfilePanel(for: snapshot)
        guard await present(panel, on: window) == .OK, let url = panel.url else { return }

        writing += 1
        defer { writing -= 1 }
        let name = url.lastPathComponent
        appState.statusText = ExportSnapshot.exportingLine(name: name)
        do {
            try await snapshot.write(to: url)
            report(ExportSnapshot.radialProfileDoneLine(name: name, bins: snapshot.bins), in: appState)
        } catch {
            appState.present(error)
        }
    }

    private static func presentSpotsPanel(_ snapshot: ExportSpotsSnapshot, on window: NSWindow, appState: AppState) async {
        let panel = spotsPanel(for: snapshot)
        guard await present(panel, on: window) == .OK, let url = panel.url else { return }

        writing += 1
        defer { writing -= 1 }
        let name = url.lastPathComponent
        appState.statusText = ExportSnapshot.exportingLine(name: name)
        do {
            try await snapshot.write(to: url)
            report(ExportSnapshot.spotsDoneLine(name: name, spots: snapshot.rows.count), in: appState)
        } catch {
            appState.present(error)
        }
    }

    private static func presentResultsPanel(_ snapshot: ExportResultsSnapshot, on window: NSWindow?, appState: AppState) async {
        let url: URL
        if let directory = appState.exportDirectory {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            url = directory.appendingPathComponent(snapshot.defaultName)
        } else {
            guard let window else { return }
            let panel = resultsPanel(for: snapshot)
            guard await present(panel, on: window) == .OK, let chosen = panel.url else { return }
            url = chosen
        }

        writing += 1
        defer { writing -= 1 }
        let name = url.lastPathComponent
        appState.statusText = ExportSnapshot.exportingLine(name: name)
        do {
            try await snapshot.write(to: url)
            report(ResultsFormat.exportingDoneLine(name: name, rows: snapshot.rows.count), in: appState)
        } catch {
            appState.present(error)
        }
    }

    /// The infobar line, and the same words to VoiceOver: a status that appears in the infobar is not spoken.
    private static func report(_ line: String, in appState: AppState) {
        appState.statusText = line
        AccessibilityNotification.Announcement(announcement(line)).post()
    }

    /// The words VoiceOver is given, at high priority: the line is posted as the sheet goes away, while VoiceOver speaks
    /// the focus returning to the window, and a default-priority announcement can be cut by it (Gate B U4, which could
    /// not hear it, so the drive does).
    static func announcement(_ line: String) -> AttributedString {
        var spoken = AttributedString(line)
        spoken.accessibilitySpeechAnnouncementPriority = .high
        return spoken
    }
}
