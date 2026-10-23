//
//  SessionPanels.swift
//  Role: File > Save to Session and the actions of the Measure tail (V1-2 slice B's UI,
//        archive: v12-session-ui-design-2026-10-14.md, sections 1 and 2): the first save's panel, the later saves
//        through the stored grant, the refusal alert, the infobar event, Show in Finder, and restoring from a session
//        file the user chose. What is saved and restored is TEMSession's (`SessionSaving`, `SessionOpening`,
//        `OpenItem.adopt`); the bookmarks are `SessionGrants`'; nothing is written here.
//
//  WHY APPKIT (CLAUDE.md: only where SwiftUI cannot do the job, named where used): `NSSavePanel` and its delegate's
//  `panel(_:validate:)`. SwiftUI's `fileExporter` writes the bytes itself, which would leave an empty file where
//  `SessionSidecarFile.write` refuses to replace a non-sidecar, and has no hook to hold the name and the folder to the
//  derived ones (restore finds the file by them). The fourth named AppKit use, after the Metal view, Show in Finder and
//  export's panels (`ExportPanels`, whose `present` and `hostWindow` this reuses as a caller).
//
//  THE PANEL IS A GRANT, NOT A CHOICE: seeded with the whole name `scan.dm4.mactem.h5` (never a bare stem: the name has a
//  compound extension), no allowed content types (so nothing is appended), in the image's folder; any other name or
//  folder is refused by the delegate with the design's sentence.
//

import SwiftUI
import AppKit
#if canImport(TEMCore)
import TEMCore
import TEMSession
#endif

@MainActor
enum SessionPanels {

    // MARK: Save

    /// File > Save to Session (⌘S) and the Measure tail's button. Later saves go through the stored grant with no panel;
    /// the first, or one whose grant no longer resolves, asks for the file.
    static func save(appState: AppState) {
        guard appState.navigation.workspaceArea == .image, let item = appState.openItems.selected, item.canSave else {
            NSSound.beep()
            return
        }
        Task.immediate { await run(item, appState: appState) }
    }

    /// The files whose save panel is up or whose first save is writing.
    private static var panelItems = Set<OpenItem.ID>()

    private static func run(_ item: OpenItem, appState: AppState) async {
        if let grant = SessionGrants.bookmark(forSource: item.url) {
            do {
                let saved = try await SessionSaving.save(item, to: .bookmark(grant))
                finish(saved, item: item, appState: appState)
                return
            } catch SessionSaving.Failure.grantLost {
                SessionGrants.drop(forSource: item.url)   // no grant: the next step is a first save
            } catch {
                await failed(error, item: item, target: { .bookmark(grant) }, appState: appState)
                return
            }
        }
        // One panel per file: a second ⌘S while the first panel is up asks for nothing more (saves themselves are
        // serialised by `SessionSaving.save`).
        guard panelItems.insert(item.id).inserted else { return }
        defer { panelItems.remove(item.id) }
        guard let window = ExportPanels.hostWindow() else {
            NSSound.beep()
            return
        }
        guard let expected = try? SessionSidecarFile.sidecarURL(forSource: item.url) else { return }
        let delegate = PanelRule(expected: expected)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = expected.lastPathComponent
        panel.nameFieldLabel = "Save As:"
        panel.prompt = "Save"
        panel.message = "macTEM keeps the marks for \(item.url.lastPathComponent) in this file, beside the image. "
            + "Keep the name and the folder: macTEM looks for it there when you open the image."
        panel.directoryURL = item.url.deletingLastPathComponent()
        panel.canCreateDirectories = false
        panel.isExtensionHidden = false
        panel.delegate = delegate
        guard await ExportPanels.present(panel, on: window) == .OK, let url = panel.url else { return }
        withExtendedLifetime(delegate) {}
        do {
            let saved = try await SessionSaving.save(item, to: .url(url))
            finish(saved, item: item, appState: appState)
        } catch {
            await failed(error, item: item, target: { .url(url) }, appState: appState)
        }
    }

    /// A save that failed: the alert; for a file another app changed, the alert offers Replace (a destructive choice that
    /// names what is lost) and Cancel, and Replace saves over it once.
    private static func failed(_ error: any Error, item: OpenItem, target: () -> SessionSaving.Target,
                               appState: AppState) async {
        let failure = error as? SessionSaving.Failure
        if failure?.dropsGrant == true { SessionGrants.drop(forSource: item.url) }
        guard failure?.offersReplace == true, let window = ExportPanels.hostWindow() else {
            appState.present(error)
            return
        }
        let name = item.sessionFileName ?? "the session file"
        guard await confirmReplace(name: name, on: window) else {
            appState.statusText = "Not saved: \(name) was left as it is"
            return
        }
        do {
            finish(try await SessionSaving.replaceAndSave(item, to: target()), item: item, appState: appState)
        } catch {
            if (error as? SessionSaving.Failure)?.dropsGrant == true { SessionGrants.drop(forSource: item.url) }
            appState.present(error)
        }
    }

    /// WHY APPKIT: SwiftUI's alert cannot be raised from here, `ContentView`'s alert (the shell, frozen) has no second
    /// choice, and `NSAlert` gives the destructive role and the sheet. True when the user chose Replace.
    private static func confirmReplace(name: String, on window: NSWindow) async -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = SessionFormat.replaceTitle(name: name)
        alert.informativeText = SessionFormat.replaceDetail(name: name)
        let replace = alert.addButton(withTitle: "Replace")
        replace.hasDestructiveAction = true
        let cancel = alert.addButton(withTitle: "Cancel")
        cancel.keyEquivalent = "\u{1b}"
        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { continuation.resume(returning: $0 == .alertFirstButtonReturn) }
        }
    }

    private static func finish(_ saved: SessionSaving.Saved, item: OpenItem, appState: AppState) {
        SessionGrants.store(saved.bookmark, forSource: item.url)
        let line = SessionSaving.savedLine(name: saved.url.lastPathComponent, marks: saved.marks)
        appState.statusText = line
        AccessibilityNotification.Announcement(ExportPanels.announcement(line)).post()
    }

    /// Holds the panel to the derived name and folder (`SessionSaving.panelRefusal`).
    private final class PanelRule: NSObject, NSOpenSavePanelDelegate {
        let expected: URL
        init(expected: URL) { self.expected = expected }

        func panel(_ sender: Any, validate url: URL) throws {
            if let sentence = SessionSaving.panelRefusal(chosen: url, expected: expected) {
                throw NSError(domain: "macTEM.session", code: 1, userInfo: [NSLocalizedDescriptionKey: sentence])
            }
        }
    }

    // MARK: A mark the record would not take

    /// Says why a mark, a move or a width was not recorded (ADR 023 a): the alert, the infobar and an announcement. A
    /// nil refusal on `.added` is a mark that was taken, and says nothing.
    static func markRefused(_ refusal: SessionLineage.Refusal?, _ action: MarkRefusalText.Action, appState: AppState) {
        if action == .added, refusal == nil { return }
        let sentence = MarkRefusalText.refused(refusal, action)
        appState.errorMessage = sentence
        appState.statusText = "Error: " + sentence
    }

    // MARK: The tail's other actions

    /// Show in Finder for the session file (the system selects it; Finder needs no grant).
    static func showInFinder(_ item: OpenItem) {
        guard let url = try? SessionSidecarFile.sidecarURL(forSource: item.url) else { return }
        DatasetLocationActions.reveal(url: url)
    }

    /// The name Choose Session File… accepts, in the image's folder.
    static func expectedSidecar(of item: OpenItem) -> URL? {
        try? SessionSidecarFile.sidecarURL(forSource: item.url)
    }

    /// The user chose `url` in the file importer to restore the marks of `item`: bookmarked, then read and decided as at
    /// open, and adopted when the file holds marks that fit (only into an empty lineage).
    static func restoreChosen(_ url: URL, into item: OpenItem, appState: AppState) async {
        guard let expected = expectedSidecar(of: item),
              SessionSaving.panelRefusal(chosen: url, expected: expected) == nil else {
            appState.errorMessage = "Choose “\(expectedSidecar(of: item)?.lastPathComponent ?? "the session file")”, "
                + "the file beside the image."
            return
        }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let image = item.session.image, let identity = item.openedIdentity else { return }
        let bookmark = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        let outcome = await read(url, source: item.url, identity: identity, image: image)
        if case .needsAccess = outcome { return }
        if case .none = outcome {} else { SessionGrants.store(bookmark, forSource: item.url) }
        let adopted = item.adopt(outcome, identity: identity, on: image)
        appState.statusText = SessionFormat.chosenLine(outcome, adopted: adopted, name: expected.lastPathComponent)
            + (adopted ? AppState.sessionSuffix(of: item) : "")
    }

    @concurrent
    private static func read(_ url: URL, source: URL, identity: SessionSourceIdentity,
                             image: CalibratedImage) async -> SidecarOutcome {
        SessionOpening.outcome(source: source, sidecar: url, opened: identity, image: image)
    }
}
