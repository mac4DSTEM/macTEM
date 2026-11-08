// Adapted from mac4DSTEM (mac4DSTEM/App/mac4DSTEMApp.swift).
import ShellLayout
import ShellControls
import SwiftUI
import AppKit
import TEMSession

/// Finder integration stays in App/; the window and its controls stay SwiftUI.
@MainActor enum DatasetLocationActions {
    static func reveal(url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

private struct FocusedAppStateKey: FocusedValueKey {
    typealias Value = AppState
}

extension FocusedValues {
    var appState: AppState? {
        get { self[FocusedAppStateKey.self] }
        set { self[FocusedAppStateKey.self] = newValue }
    }
}

/// The one window. The `AppState` is owned by `macTEMApp`, not here: a `Window` scene keeps its view state through
/// a close (spike E1c), but the files must not depend on SwiftUI retaining a closed window's view.
private struct ImageWindow: View {
    /// A File-menu action asked for while no window was focused (`MenuActionRelay`).
    let menuRelay: MenuActionRelay
    let appState: AppState

    /// The scheme `--appearance` forces (a journey's light-mode screenshot), else nil: the system's.
    private static func colorScheme(_ name: String?) -> ColorScheme? {
        switch name { case "light": .light; case "dark": .dark; default: nil }
    }

    var body: some View {
        ContentView()
            .environment(appState)
            .preferredColorScheme(Self.colorScheme(appState.launch.appearance))
            .focusedSceneValue(\.appState, appState)
            // Info.plist declares CFBundleDocumentTypes, which puts macTEM in Finder's "Open With" — this is
            // the handler that requires. It gets only the FIRST file of a multi-file open; `AppDelegate` gets
            // the rest, and the relay rebuilds the batch.
            .onOpenURL { OpenURLRelay.shared.add([$0]) }
            .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
            // The minimum sits ABOVE ContentView: `WindowFillingLayout` answers a finite proposal with itself.
            .frame(minWidth: LayoutPolicy.datasetWindowMinimumSize.width,
                   minHeight: LayoutPolicy.datasetWindowMinimumSize.height)
            // "Open Image…" chosen with no window focused opened this one; a `.task`, so the content's own
            // request observer exists before the action fires. The relay's handler is set here too, which
            // delivers a Finder open that arrived before the window did, and the delegate's hook for the quit question.
            .task {
                OpenURLRelay.shared.handler = { appState.open(urls: $0) }
                AppDelegate.appState = appState
                if let action = menuRelay.take() { MenuActionRelay.run(action, in: appState) }
            }
            // A window that was minimised, not closed, does not run its `.task` again; `take` runs an action once.
            .onChange(of: menuRelay.requestCount) {
                if let action = menuRelay.take() { MenuActionRelay.run(action, in: appState) }
            }
            // A close of files with unsaved marks waits for the answer (`AppState.requestClose`), asked as a sheet here.
            .onChange(of: appState.closeRequest) { _, request in
                if let request { SessionPanels.askToClose(request, appState: appState) }
            }
    }
}

private struct ImageCommands: Commands {
    @FocusedValue(\.appState) private var appState
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    let menuRelay: MenuActionRelay
    /// File > Open Recent's list, the app's, not the focused window's: the menu lists it with no window focused too.
    let recents: RecentFiles

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            // With no window focused it opens one and runs there (`MenuActionRelay`), so it is enabled then too.
            Button("Open Image…") { perform(.openImage) }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(!MenuActionRelay.isEnabled(
                    hasFocusedWindow: appState != nil,
                    blocked: appState?.imageSession.isLoading == true))
            // The last eight files opened (`RecentFiles`), two of one name told apart by their folders. As Open Image…, with no window
            // focused it opens the window and the file there (`MenuActionRelay`).
            Menu("Open Recent") {
                ForEach(recents.entries) { entry in
                    Button(recents.title(of: entry)) { perform(.openRecent(entry)) }
                }
                Divider()
                Button("Clear Menu") { recents.clear() }
            }
            .disabled(recents.entries.isEmpty || !MenuActionRelay.isEnabled(
                hasFocusedWindow: appState != nil,
                blocked: appState?.imageSession.isLoading == true))
            // The macOS term (ADR 011); no key of its own. It acts on the document the room shows (`DocumentTarget`): the selected
            // file in the image rooms, as the row's menu does, the dataset, the map or the spectrum image in theirs.
            Button("Show in Finder") {
                if let url = appState?.documentURL { DatasetLocationActions.reveal(url: url) }
            }
            .disabled(appState?.documentURL == nil)
        }
        // Replaces the system's Close (⌘W), which would close the window: ⌘W closes the document the room shows (`DocumentTarget`:
        // Close Image, Close Dataset, Close Map, Close Spectrum Image) and ⇧⌘W the window (the owner, ADR 007); with nothing shown
        // ⌘W closes the window, as the system's would. Close is the part of the Save group that SwiftUI exposes. An image with
        // unsaved marks asks first (`requestClose`).
        CommandGroup(replacing: .saveItem) {
            if let target = appState?.documentTarget {
                Button(target.closeTitle) { appState?.closeDocument(target) }
                    .keyboardShortcut("w", modifiers: .command)
            } else {
                Button("Close") { dismissWindow(id: "image") }
                    .keyboardShortcut("w", modifiers: .command)
                    .disabled(appState == nil)
            }
            Button("Close Window") { dismissWindow(id: "image") }
                .keyboardShortcut("w", modifiers: [.command, .shift])
                .disabled(appState == nil)
        }
        CommandGroup(replacing: .sidebar) {
            Button(appState?.navigation.panels.sidebarIsVisible == true ? "Hide Sidebar" : "Show Sidebar") {
                appState?.navigation.panels.toggleSidebar()
            }
            .keyboardShortcut("s", modifiers: [.command, .control])
            Button(appState?.navigation.panels.inspectorIsVisible == true ? "Hide Inspector" : "Show Inspector") {
                appState?.navigation.panels.showInspectorPane.toggle()
            }
            // The one key, also the toolbar button's (`InspectorToggleButton`): Opt-Cmd-I, as Mac apps with an inspector
            // have it (HIG, Keyboards). It was Ctrl-Cmd-I here and a hidden Opt-Cmd-0 on the button.
            .keyboardShortcut("i", modifiers: [.command, .option])
            Button(appState?.navigation.panels.showProcessArea == true ? "Hide Output" : "Show Output") {
                appState?.navigation.panels.showProcessArea.toggle()
            }
            .keyboardShortcut("l", modifiers: [.command, .control])
            .disabled(appState?.hasImage != true)
        }
        CommandMenu("Image") {
            Button("Previous Image") { appState?.openItems.selectPrevious() }
                .keyboardShortcut("[", modifiers: [.command, .shift])
                .disabled((appState?.openItems.items.count ?? 0) < 2)
            Button("Next Image") { appState?.openItems.selectNext() }
                .keyboardShortcut("]", modifiers: [.command, .shift])
                .disabled((appState?.openItems.items.count ?? 0) < 2)
            // The Image room's measuring tools (V1-5), ⌃⌘1…4: a Toggle each, so the chosen tool carries the menu's
            // checkmark and a chosen one cannot be switched off (the Measure section's picker is the same state).
            // Listed always, as the Workspace menu lists its rooms: with no image open, or in another room, disabled.
            Divider()
            ForEach(ImageRoomTools.Tool.allCases) { tool in
                Toggle(tool.title, isOn: Binding(get: { appState?.imageRoomTools.tool == tool },
                                                 set: { if $0 { appState?.imageRoomTools.tool = tool } }))
                    .keyboardShortcut(KeyEquivalent(tool.shortcutDigit), modifiers: [.command, .control])
                    .disabled(appState?.hasImage != true || appState?.navigation.workspaceArea != .image)
            }
            if let items = appState?.openItems, !items.items.isEmpty {
                Divider()
                Picker("Open Images", selection: Binding(get: { items.selection },
                                                         set: { items.selection = $0 })) {
                    // The sidebar's titles: two files of one name are told apart by their folder.
                    let titles = items.displayTitles
                    ForEach(items.items) { item in
                        Text(titles[item.id] ?? item.url.lastPathComponent).tag(Optional(item.id))
                    }
                }
                .pickerStyle(.inline)
            }
        }
        CommandMenu("Workspace") {
            // ⌘1…⌘5 go to the workspaces (`WorkspaceGroup`), as the sidebar lists them; a workspace's parts are its submenu, as they are
            // the section under it in the sidebar. The file decides: a workspace or a part with no data for what is open is disabled.
            ForEach(WorkspaceGroup.allCases) { group in
                Button("Go to \(group.title)") { appState?.selectWorkspaceGroup(group) }
                    .keyboardShortcut(KeyEquivalent(group.shortcutDigit), modifiers: .command)
                    .disabled(appState.map { $0.workspaceUnavailableReason(group) != nil } ?? true)
            }
            Divider()
            ForEach(WorkspaceGroup.allCases.filter(\.hasParts)) { group in
                Menu(group.title) {
                    ForEach(group.parts) { area in
                        Button(area.title) { appState?.selectWorkspace(area) }
                            .disabled(appState.map { $0.roomUnavailableReason(area) != nil } ?? true)
                    }
                }
            }
            Divider()
            // The room's verb (⌘R), titled with it, as mac4DSTEM's Run Current Task: on only when the toolbar's button can run it, so ⌘R
            // is never a dead key. The button keeps its own ⌘↩.
            Button(RoomPrimaryAction.runTitle(appState)) { if let appState { RoomPrimaryAction.runActive(appState) } }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(!RoomPrimaryAction.canRun(appState.flatMap { RoomPrimaryAction.current($0) }))
            // The room's Stop (the toolbar's verb turns into Cancel while a run is in flight; this is its key). While the shown room is
            // idle it stops the run of another room the toolbar shows, and says which ("Stop Indexing").
            Button(appState.map { RoomPrimaryAction.stopTitle($0) } ?? "Stop") { if let appState { RoomPrimaryAction.stopActive(appState) } }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(appState.map { !RoomPrimaryAction.canStop($0) } ?? true)
        }
        // Generated documents for someone with no microscope file at hand, App Review first (macTEM#105, DemoData.swift).
        CommandGroup(after: .help) {
            Menu("Open Demo Data") {
                ForEach(DemoDocument.allCases) { demo in
                    Button(demo.title) { appState?.openDemo(demo) }
                }
            }
            .disabled(appState == nil || appState?.imageSession.isLoading == true)
        }
    }

    private func perform(_ action: MenuAction) {
        if let appState {
            MenuActionRelay.run(action, in: appState)
        } else {
            menuRelay.request(action)
            openWindow(id: "image")
        }
    }
}

@main
struct macTEMApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    /// The one state graph, owned here so that closing the window never releases the files (ADR 007). Open Recent's list is the one
    /// kept in UserDefaults, except for a UI-testing launch, which keeps one in memory and leaves a person's recents alone.
    @State private var appState = AppState(recents: macTEMApp.isUITesting ? nil : RecentFiles.stored())
    // File-menu actions asked for while no window is focused (`MenuActionRelay`): read by the commands, taken
    // by the window they open.
    @State private var menuRelay = MenuActionRelay()
    private static let isUITesting = LaunchOptions().isUITesting

    var body: some Scene {
        Window("macTEM", id: "image") {
            ImageWindow(menuRelay: menuRelay, appState: appState)
        }
            .handlesExternalEvents(matching: ["*"])
            .defaultLaunchBehavior(.presented)
            // A UI-testing launch restores nothing, so the window is always presented (a saved "window closed" state hid it); a person's launch restores as usual.
            .restorationBehavior(Self.isUITesting ? .disabled : .automatic)
            .defaultSize(width: LayoutPolicy.datasetWindowIdealSize.width,
                         height: LayoutPolicy.datasetWindowIdealSize.height)
            .windowStyle(.titleBar)
            .windowToolbarStyle(.unified)
            .commands {
                ImageCommands(menuRelay: menuRelay, recents: appState.recents)
                // File > Save to Session (V1-2), listed before the export group so it sits above its Divider.
                SessionCommands()
                // File > Export Image… and Export Profile… (V1-10), their own `Commands` (`ExportCommands.swift`).
                ExportCommands()
                // View > Zoom In, Zoom Out, Zoom to Fit (⌘+ ⌘− ⌘0) on the pane that publishes its zoom (control placement §6).
                ZoomCommands()
            }
        // The Particles view's object table, beside the image (ImageRoomParticles.swift); never opened at launch.
        Window("Objects", id: ParticleTableWindow.id) { ParticleTableWindow(appState: appState) }
            .defaultLaunchBehavior(.suppressed)
            .restorationBehavior(.disabled)
            .defaultSize(width: 640, height: 420)
    }
}
