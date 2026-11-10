//
//  FolderPanels.swift
//  Role: the open panel that asks for a NORDIF scan's folder, once: an Open whose `Pattern.dat` has a `Setting.txt` beside it that
//        the sandbox refuses (`FolderGrants.asksForFolder`) asks here, on a sheet, in the scan's folder, with a plain sentence. The
//        folder chosen is the grant (`FolderGrants` keeps it); declined, the scan keeps its refusal, which names the settings file
//        and the folder. Nothing is read here.
//
//  WHY APPKIT (the suite's rule: only where SwiftUI cannot do the job, named where used): `NSOpenPanel` awaited in the middle of
//  an Open (`AppState.open(urls:)`), with a delegate that holds the choice to the scan's folder or one around it. SwiftUI's
//  `fileImporter` is a view's state, raised by a view and answered in its callback, which the Open cannot wait on. It reuses
//  export's `present` and `hostWindow` (`ExportPanels`) as a caller, as the session panel does.
//

import AppKit

@MainActor
enum FolderPanels {
    /// The folder of `file` (or one around it) the person chose to let macTEM read, or nil when the panel was cancelled, or when
    /// the window has a sheet up already (a beep, as for a refused action).
    static func askForFolder(of file: URL) async -> URL? {
        guard let window = ExportPanels.hostWindow() else {
            NSSound.beep()
            return nil
        }
        let rule = FolderRule(file: file)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.directoryURL = file.deletingLastPathComponent()
        panel.prompt = "Allow"
        panel.message = FolderGrants.askSentence(for: file)
        panel.delegate = rule
        guard await ExportPanels.present(panel, on: window) == .OK, let url = panel.url else { return nil }
        withExtendedLifetime(rule) {}
        return url
    }

    /// Holds the panel to the scan's folder or one around it (`FolderGrants.panelRefusal`).
    private final class FolderRule: NSObject, NSOpenSavePanelDelegate {
        let file: URL
        init(file: URL) { self.file = file }

        func panel(_ sender: Any, validate url: URL) throws {
            if let sentence = FolderGrants.panelRefusal(chosen: url, file: file) {
                throw NSError(domain: "macTEM.folder", code: 1, userInfo: [NSLocalizedDescriptionKey: sentence])
            }
        }
    }
}
