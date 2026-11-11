// Adapted from mac4DSTEM (mac4DSTEM/App/mac4DSTEMApp.swift).
import ShellLayout
import ShellControls
import SwiftUI
import AppKit
import TEMSession
import ShellEDXModel
import ShellSpectroscopy

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

    /// True while the Objects window (`ParticleTableWindow`) is key: File > Close and Close Window close it (`CloseCommand`).
    var isObjectsWindow: Bool? {
        get { self[FocusedObjectsWindowKey.self] }
        set { self[FocusedObjectsWindowKey.self] = newValue }
    }
}

private struct FocusedObjectsWindowKey: FocusedValueKey {
    typealias Value = Bool
}

/// The focused image window's own close (`DismissWindowAction` called in that window): with several windows, File > Close Window
/// closes the one in front, which a dismiss by the scene's id does not name.
struct CloseWindowAction {
    let close: @MainActor () -> Void
}

private struct FocusedCloseWindowKey: FocusedValueKey {
    typealias Value = CloseWindowAction
}

extension FocusedValues {
    var closeImageWindow: CloseWindowAction? {
        get { self[FocusedCloseWindowKey.self] }
        set { self[FocusedCloseWindowKey.self] = newValue }
    }
}

/// A window, one of several (one file per window, 2026-11-10, as mac4DSTEM's dataset windows): each has its own `AppState`, made on
/// the first read in `body` and never again (`LazyAppState`). The app knows its windows through `AppWindows`: which is in front (a
/// Finder open goes there), what quitting would lose over all of them, and a window closed with marks not saved, whose state is
/// parked there and shown again by the next window, so closing a window loses nothing (the single window's promise, ADR 007).
private struct ImageWindow: View {
    /// A File-menu action asked for while no window was focused (`MenuActionRelay`).
    let menuRelay: MenuActionRelay
    let windows: AppWindows
    @State private var holder: LazyAppState
    private var appState: AppState { holder.state }
    /// This window is the active one: it is then the app's front window (`AppWindows.bringForward`).
    @Environment(\.appearsActive) private var appearsActive
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openWindow) private var openWindow

    init(menuRelay: MenuActionRelay, windows: AppWindows, recents: RecentFiles, lastSession: LastSession) {
        self.menuRelay = menuRelay
        self.windows = windows
        _holder = State(initialValue: LazyAppState {
            windows.stateForNewWindow {
                AppState(launch: windows.launchOptionsForNewWindow(), recents: recents, lastSession: lastSession)
            }
        })
    }

    /// The scheme `--appearance` forces (a journey's light-mode screenshot), else nil: the system's.
    private static func colorScheme(_ name: String?) -> ColorScheme? {
        switch name { case "light": .light; case "dark": .dark; default: nil }
    }

    var body: some View {
        ContentView()
            .environment(appState)
            .preferredColorScheme(Self.colorScheme(appState.launch.appearance))
            .focusedSceneValue(\.appState, appState)
            .focusedSceneValue(\.closeImageWindow, CloseWindowAction { dismissWindow() })
            // The app's windows know this one while it is on screen; a window closed with something to lose is parked (`AppWindows`).
            .onAppear {
                windows.openWindow = { openWindow(id: "image") }
                windows.enroll(appState)
                // The agent door (Settings > Agents) lists this window, and opens when it was left on.
                MacTEMAgentDoor.start(with: appState)
                // The launch's other `--open` files, each in a tab of its own (one file per window).
                if !appState.launchFilesForTabs.isEmpty {
                    windows.openInTabs(appState.launchFilesForTabs)
                    appState.launchFilesForTabs = []
                }
            }
            // New windows join the front window's tabs (`WindowTabbing`, AppKit). The tab's title is the window's (`AppState.windowTitle`).
            .background(WindowTabbing(state: appState, windows: windows))
            .onDisappear {
                windows.withdraw(appState)
                MacTEMAgentDoor.withdraw(appState)
            }
            .onChange(of: appearsActive) { _, active in if active { windows.bringForward(appState) } }
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
            // delivers a Finder open that arrived before the window did, and the delegate's hook for the quit question. Both go
            // through the app's windows: a batch opens in the window in front, the question is asked over all of them.
            .task {
                OpenURLRelay.shared.handler = { [windows] in windows.deliver(urls: $0) }
                AppDelegate.windows = windows
                if let waiting = windows.takeWaitingURLs() { appState.open(urls: waiting) }
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
            // File > Reopen Last Session's record follows what the window holds: a file opened or closed, a room's document read in or
            // closed, the selection and the room (`AppState.recordLastSession`, which saves only a changed record).
            .onChange(of: appState.lastSessionState) { appState.recordLastSession() }
    }
}

private struct ImageCommands: Commands {
    @FocusedValue(\.appState) private var appState
    @FocusedValue(\.isObjectsWindow) private var objectsWindowIsKey
    @FocusedValue(\.closeImageWindow) private var closeImageWindow
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    let menuRelay: MenuActionRelay
    /// File > Open Recent's list, the app's, not the focused window's: the menu lists it with no window focused too.
    let recents: RecentFiles
    /// File > Reopen Last Session's record, the app's for the same reason.
    let lastSession: LastSession

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            // A window per file: an empty one to open a file in, also as a tab (the system's Window > Merge All Windows and tab bar).
            Button("New Window") { openWindow(id: "image") }
                .keyboardShortcut("n", modifiers: .command)
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
            // The files, the selected one and the room the last launch had open (`LastSession`), listed only when that launch left a
            // record (mac4DSTEM's Reopen ⇧⌘O). Offered, never opened at launch: a mapped multi-GB file must not load before the person
            // asks. As Open Image…, with no window focused it opens the window and runs there (`MenuActionRelay`).
            if lastSession.previous != nil {
                Button("Reopen Last Session") { perform(.reopenLastSession) }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                    .disabled(!MenuActionRelay.isEnabled(
                        hasFocusedWindow: appState != nil,
                        blocked: appState?.imageSession.isLoading == true))
            }
            // The macOS term (ADR 011); no key of its own. It acts on the document the room shows (`DocumentTarget`): the selected
            // file in the image rooms, as the row's menu does, the dataset, the map or the spectrum image in theirs.
            Button("Show in Finder") {
                if let url = appState?.documentURL { DatasetLocationActions.reveal(url: url) }
            }
            .disabled(appState?.documentURL == nil)
        }
        // Replaces the system's Close (⌘W), which would close the window: ⌘W closes the document the room shows (`DocumentTarget`:
        // Close Image, Close Dataset, Close Map, Close Spectrum Image, Close Spectrum for one spectrum) and ⇧⌘W the window (the owner, ADR 007); with nothing shown
        // ⌘W closes the window, as the system's would. Close is the part of the Save group that SwiftUI exposes. An image with
        // unsaved marks asks first (`requestClose`). While the Objects window is key, both close it (`CloseCommand`).
        CommandGroup(replacing: .saveItem) {
            let close = CloseCommand.close(objectsWindowKey: objectsWindowIsKey == true, imageWindowFocused: appState != nil,
                                           shown: appState?.documentTarget)
            Button(close.closeTitle) { runClose(close) }
                .keyboardShortcut("w", modifiers: .command)
                .disabled(close == .unavailable)
            let closeWindow = CloseCommand.closeWindow(objectsWindowKey: objectsWindowIsKey == true, imageWindowFocused: appState != nil)
            Button("Close Window") { runClose(closeWindow) }
                .keyboardShortcut("w", modifiers: [.command, .shift])
                .disabled(closeWindow == .unavailable)
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
            // On wherever the Output pane has a document to sit under, the pane's own rule: an image, or the EDS, EELS, Patterns,
            // Indexing or Maps room's document with no image open (`ProcessAreaDocuments`).
            Button(appState?.navigation.panels.showProcessArea == true ? "Hide Output" : "Show Output") {
                appState?.navigation.panels.showProcessArea.toggle()
            }
            .keyboardShortcut("l", modifiers: [.command, .control])
            .disabled(appState?.processAreaHasDocument != true)
        }
        CommandMenu("Image") {
            // The Image room's measuring tools (V1-5), ⌃⌘1…4: a Toggle each, so the chosen tool carries the menu's
            // checkmark and a chosen one cannot be switched off (the Measure section's picker is the same state).
            // Always listed, so the menu is never empty (HIG, Menus: disable an item that does not apply, never hide it).
            // Outside the Image room they are disabled and carry no key: the EDS room's region tools take ⌃⌘0…4 there
            // (Workspace menu), and two items in the menu bar never share a key. With no image open, disabled.
            let inImageRoom = appState?.navigation.workspaceArea == .image
            ForEach(ImageRoomTools.Tool.allCases) { tool in
                Toggle(tool.title, isOn: Binding(get: { appState?.imageRoomTools.tool == tool },
                                                 set: { if $0 { appState?.imageRoomTools.tool = tool } }))
                    .keyboardShortcut(inImageRoom ? KeyboardShortcut(KeyEquivalent(tool.shortcutDigit), modifiers: [.command, .control]) : nil)
                    .disabled(!inImageRoom || appState?.hasImage != true)
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
            // The EDS room's region tools and Pin Region from the keyboard, as mac4DSTEM's Analysis menu lists them: in the menu
            // only while that room shows a spectrum image (the inspector's Tools control is the pointer's way).
            if let appState, appState.navigation.workspaceArea == .edx, appState.edx.hasImage {
                Divider()
                Button("Select Tool") { appState.edxRoom.tool = .pointer }
                    .keyboardShortcut("0", modifiers: [.command, .control])
                Button("Rectangle Region Tool") { appState.edxRoom.tool = .rectangle }
                    .keyboardShortcut("1", modifiers: [.command, .control])
                Button("Ellipse Region Tool") { appState.edxRoom.tool = .ellipse }
                    .keyboardShortcut("2", modifiers: [.command, .control])
                Button("Polygon Region Tool") { appState.edxRoom.tool = .polygon }
                    .keyboardShortcut("3", modifiers: [.command, .control])
                Button("Line Tool") { appState.edxRoom.tool = .line }
                    .keyboardShortcut("4", modifiers: [.command, .control])
                Button("Pin Region") { appState.edx.pinRegion() }
                    .disabled(appState.edx.selectedPin != nil)
            }
        }
        // Generated documents for someone with no microscope file at hand, App Review first (macTEM#105, DemoData.swift).
        CommandGroup(after: .help) {
            // As Open Image…: with no window focused it opens one and the document there (`MenuActionRelay`).
            Menu("Open Demo Data") {
                ForEach(DemoDocument.allCases) { demo in
                    Button(demo.title) { perform(.openDemo(demo)) }
                }
            }
            .disabled(!MenuActionRelay.isEnabled(
                hasFocusedWindow: appState != nil,
                blocked: appState?.imageSession.isLoading == true))
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

    /// File > Close and Close Window (`CloseCommand`): the shown document, the image window or the Objects window.
    private func runClose(_ command: CloseCommand) {
        switch command {
        case .document(let target): appState?.closeDocument(target)
        case .imageWindow: closeImageWindow?.close()
        case .objectsWindow: dismissWindow(id: ParticleTableWindow.id)
        case .unavailable: break
        }
    }
}

@main
struct macTEMApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    /// The app's windows, as their states (`AppWindows`): each window makes its own `AppState`.
    @State private var windows = AppWindows()
    /// Open Recent's list and the last session's record are the app's, shared by every window: the ones kept in UserDefaults, except
    /// for a UI-testing launch, which keeps them in memory and leaves a person's alone.
    @State private var recents = macTEMApp.isUITesting ? RecentFiles() : RecentFiles.stored()
    @State private var lastSession = macTEMApp.isUITesting ? LastSession() : LastSession.stored()
    // File-menu actions asked for while no window is focused (`MenuActionRelay`): read by the commands, taken
    // by the window they open.
    @State private var menuRelay = MenuActionRelay()
    private static let isUITesting = LaunchOptions().isUITesting

    var body: some Scene {
        WindowGroup("macTEM", id: "image") {
            ImageWindow(menuRelay: menuRelay, windows: windows, recents: recents, lastSession: lastSession)
        }
            .handlesExternalEvents(matching: ["*"])
            .defaultLaunchBehavior(.presented)
            // Not restored: a window comes back without its file (a file is never read before the person asks: File > Reopen Last
            // Session, through bookmarks), so a restored window was an empty tab, and one restored from a Finder open had the open
            // handed to it again by path, which the sandbox does not grant: refused, with an empty tab (driven 2026-11-11). A launch
            // presents one window (`defaultLaunchBehavior`).
            .restorationBehavior(.disabled)
            .defaultSize(width: LayoutPolicy.datasetWindowIdealSize.width,
                         height: LayoutPolicy.datasetWindowIdealSize.height)
            .windowStyle(.titleBar)
            .windowToolbarStyle(.unified)
            .commands {
                ImageCommands(menuRelay: menuRelay, recents: recents, lastSession: lastSession)
                // File > Save to Session (V1-2), listed before the export group so it sits above its Divider.
                SessionCommands()
                // File > Export Image… and Export Profile… (V1-10), their own `Commands` (`ExportCommands.swift`).
                ExportCommands()
                // View > Zoom In, Zoom Out, Zoom to Fit (⌘+ ⌘− ⌘0) on the pane that publishes its zoom (control placement §6).
                ZoomCommands()
            }
        // Settings (⌘,): the agent door's switch (`AgentSettingsView`).
        Settings { AgentSettingsView() }
        // The Particles view's object table, beside the image (ImageRoomParticles.swift); never opened at launch.
        Window("Objects", id: ParticleTableWindow.id) { ObjectsWindow(windows: windows) }
            .defaultLaunchBehavior(.suppressed)
            .restorationBehavior(.disabled)
            .defaultSize(width: 640, height: 420)
    }
}

/// The Objects window's content: the object table of the window in front (`AppWindows.front`), which the Objects window itself never
/// becomes; with no image window open it says so.
private struct ObjectsWindow: View {
    let windows: AppWindows

    var body: some View {
        if let appState = windows.front ?? windows.onScreen.last {
            ParticleTableWindow(appState: appState)
        } else {
            ContentUnavailableView("No objects", systemImage: "circle.dashed",
                                   description: Text("Show Objects in the Image room's Particles section first."))
                .focusedSceneValue(\.isObjectsWindow, true)
        }
    }
}
