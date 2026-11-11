import ShellLayout
import SwiftUI
import UniformTypeIdentifiers
import SpectroCore
import TEMCore
import TEMSession
import ShellEDXModel
import ShellSpectroscopy

/// The app's window: a SwiftUI-only shell. The skeleton (the split view, the inspector, where the toolbar is declared, the
/// width at which the sidebar steps aside, the scene-stored panel intent, the launch flags and the drop outline) is ShellLayout's
/// `ShellWindow` (suite task 8, MacEMUI); this file adds what is the app's: the importer, the alert, the open and drop
/// handlers, the toolbar's content and the selection-rests re-read.
///
/// **The shape** is Xcode's: left, navigation (the rooms and the open files); centre, the science, the infobar and the
/// process area; right, the inspector in two tabs, Settings and Info.
struct ContentView: View {
    @Environment(AppState.self) private var appState
    @State private var showImporter = false

    private var imageTypes: [UTType] {
        FileRouting.openableExtensions.compactMap { UTType(filenameExtension: $0) }
    }

    var body: some View {
        ShellWindow(
            navigation: appState.navigation.panels,
            title: appState.windowTitle,
            onDropURLs: { openDropped($0) },
            sidebar: { WorkspaceSidebar() },
            canvas: { WorkspaceView() },
            inspector: { WorkspaceInspector() },
            toolbar: { windowToolbarContent })
        .background { SelectionRestorer() }
        .onChange(of: appState.roomHoldings) { appState.reconcileRoom() }
        .onChange(of: appState.openImageRequest) { showImporter = true }
        // The busy clock's start: each spectrum room's busy edge, whichever room is shown.
        .onChange(of: appState.edx.isBusy, initial: true) { appState.markBusy(.edx, appState.edx.isBusy) }
        .onChange(of: appState.eels.isBusy, initial: true) { appState.markBusy(.eels, appState.eels.isBusy) }
        .onChange(of: appState.ebsd.isBusy, initial: true) { appState.markBusy(.patterns, appState.ebsd.isBusy) }
        .onChange(of: appState.indexing.isBusy, initial: true) { appState.markBusy(.indexing, appState.indexing.isBusy) }
        .onChange(of: appState.maps.isBusy, initial: true) { appState.markBusy(.maps, appState.maps.isBusy) }
        // INTERIM, delete at MacEMUI <next>: the shared EDS room's own Open button reads its file past the app's Open, so the file
        // the room comes to hold is noted as one of the app's EDS files here (EDSRoomDoor.swift, #318).
        .onChange(of: appState.edx.source?.metadata.filePath) { _, path in appState.noteEDSRoomFile(path: path) }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: imageTypes,
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                if !urls.isEmpty { appState.open(urls: urls) }
            case .failure(let error):
                appState.present(error)
            }
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(
                get: { appState.errorMessage != nil },
                set: { if !$0 { appState.errorMessage = nil } }
            )
        ) {
            // Through the app's one pasteboard writer (PaneKeys.swift), as a pane's ⌘C.
            Button("Copy Details") { SystemPaneTextWriter().write(appState.errorMessage ?? "") }
            Button("OK", role: .cancel) { appState.errorMessage = nil }
        } message: {
            Text(appState.errorMessage ?? "")
        }
    }

    /// The arrangement (alignment design M2): the file, the room and the size as a DISPLAY in the centre, never a button; at the
    /// trailing edge the room's verb (EDS: Quantify) and the Image menu; the inspector's toggle is the shell's.
    @ToolbarContentBuilder
    private var windowToolbarContent: some ToolbarContent {
        ShellToolbar(
            display: { ToolbarRunDisplay(ToolbarDisplay.state(appState)) },
            verb: { PrimaryActionButton(RoomPrimaryAction.current(appState)) },
            documentMenu: { ImageMenu() })
    }

    /// Opens the dropped files macTEM reads; every dropped file it does not read is refused by name in one alert, a line each, and
    /// what macTEM opens is said once after them (`FileRouting.dropped`). With files to open the lines go to the Open, which shows
    /// them once with the files its routing refuses, after any folder it asks for (`AppState.open(urls:refused:)`): an alert raised
    /// here first lost its lines to the Open's, and kept the folder panel of a NORDIF scan from showing. With none to open the
    /// alert is raised here.
    private func openDropped(_ urls: [URL]) -> Bool {
        let drop = FileRouting.dropped(urls)
        guard !drop.accepted.isEmpty else {
            appState.presentRefusals(drop.refusals)
            return false
        }
        appState.open(urls: drop.accepted, refused: drop.refusals)
        return true
    }
}

/// A cold item is read again only after the selection has rested (150 ms), so stepping through a list with the arrow keys
/// does not read every file passed over (`OpenItems.restoreSelected`). It reads the selection itself, outside
/// `ContentView.body`, so a selection change does not re-evaluate the window.
private struct SelectionRestorer: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Color.clear
            .task(id: appState.openItems.selectedID) {
                // The infobar is events only: a new selection (or a closed file) ends the line of the event before.
                appState.selectionDidChange()
                do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
                appState.openItems.restoreSelected()
            }
            .accessibilityHidden(true)
    }
}

struct ImageMenu: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var openItems = appState.openItems
        Menu {
            Button("Open Image…") { appState.requestOpenImage() }
                .disabled(appState.imageSession.isLoading)
            if !openItems.items.isEmpty {
                // The open files are the window's tabs (one file per window): no list of them here.
                Divider()
                Button("Close Image") { appState.requestCloseSelected() }
            }
        } label: {
            Label("Image", systemImage: "photo.on.rectangle")
        }
        // With nothing open the menu would offer only what the welcome door and ⌘O already do.
        .disabled(openItems.items.isEmpty)
        .help("Open an image")
        .accessibilityIdentifier("toolbar.datasetMenu")
    }
}
