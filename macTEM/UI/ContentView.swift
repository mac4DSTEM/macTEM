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
            Button("Copy Details") { copyToPasteboard(appState.errorMessage ?? "") }
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
            display: { ToolbarRunDisplay(toolbarDisplay) },
            verb: { PrimaryActionButton(RoomPrimaryAction.current(appState)) },
            documentMenu: { ImageMenu() })
    }

    /// What the toolbar's centre shows: nothing without a document or while it loads; the running spectrum-image work while busy;
    /// else "file · room · size".
    private var toolbarDisplay: ToolbarDisplayState? {
        let room = appState.navigation.workspaceArea
        switch room {
        case .edx, .eels:
            guard !appState.windowTitle.isEmpty, appState.windowTitle != "macTEM" else { return nil }
            let busy = room == .edx ? appState.edx.isBusy : appState.eels.isBusy
            if busy {
                return .busy(operation: appState.statusText.isEmpty ? room.title : appState.statusText, progress: RoomProgress.fraction(room: room, appState: appState), metrics: { _ in nil })
            }
            let detail = room == .edx ? EDXRoomFormat.capsuleDetail(appState.edx) : "spectrum image"
            return .idle(file: appState.windowTitle, room: room.title, detail: detail, help: nil)
        default:
            guard !appState.imageSession.isLoading, let image = appState.imageSession.image else { return nil }
            return .idle(file: image.fileName, room: room.title, detail: "\(image.width) × \(image.height) px", help: nil)
        }
    }

    /// Opens the dropped files macTEM reads; a dropped file it does not read is refused by name through the alert.
    private func openDropped(_ urls: [URL]) -> Bool {
        let readable = FileRouting.openableExtensions
        // A file of a readable format; a dragged web link ending in .tif is not a file.
        let isReadable = { (url: URL) in url.isFileURL && readable.contains(url.pathExtension.lowercased()) }
        let accepted = urls.filter(isReadable)
        if let refused = urls.first(where: { !isReadable($0) }) {
            appState.present(ImageOpening.Refusal.unreadableFormat(
                file: refused.lastPathComponent, ext: refused.pathExtension.lowercased()))
        }
        guard !accepted.isEmpty else { return false }
        appState.open(urls: accepted)
        return true
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
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
                // The list's twin for a window too narrow to keep the sidebar: the open files, the selected one checked.
                let titles = openItems.displayTitles
                Divider()
                Picker("Open Files", selection: $openItems.selection) {
                    ForEach(openItems.items) { item in
                        Text(verbatim: titles[item.id] ?? item.url.lastPathComponent).tag(Optional(item.id))
                    }
                }
                .pickerStyle(.inline)
                Divider()
                Button("Close Image") { openItems.closeSelected() }
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
