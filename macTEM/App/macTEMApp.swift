// Adapted from mac4DSTEM (mac4DSTEM/App/mac4DSTEMApp.swift).
import ShellLayout
import ShellControls
import SwiftUI
import AppKit
#if canImport(TEMCore)
import TEMCore
import TEMSession
#endif

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
            // delivers a Finder open that arrived before the window did.
            .task {
                OpenURLRelay.shared.handler = { appState.open(urls: $0) }
                if let action = menuRelay.take() { MenuActionRelay.run(action, in: appState) }
            }
            // A window that was minimised, not closed, does not run its `.task` again; `take` runs an action once.
            .onChange(of: menuRelay.requestCount) {
                if let action = menuRelay.take() { MenuActionRelay.run(action, in: appState) }
            }
    }
}

private struct ImageCommands: Commands {
    @FocusedValue(\.appState) private var appState
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    let menuRelay: MenuActionRelay

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            // With no window focused it opens one and runs there (`MenuActionRelay`), so it is enabled then too.
            Button("Open Image…") { perform(.openImage) }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(!MenuActionRelay.isEnabled(
                    hasFocusedWindow: appState != nil,
                    blocked: appState?.imageSession.isLoading == true))
            // The macOS term (ADR 011); no key of its own. It acts on the selected file, as the row's menu does.
            Button("Show in Finder") {
                if let url = appState?.openItems.selected?.url { DatasetLocationActions.reveal(url: url) }
            }
            .disabled(appState?.openItems.selected == nil)
        }
        // Replaces the system's Close (⌘W), which would close the window: ⌘W closes the selected image and
        // ⇧⌘W the window (the owner, ADR 007); with no image open ⌘W closes the window, as the system's would.
        // Close is the part of the Save group that SwiftUI exposes.
        CommandGroup(replacing: .saveItem) {
            if appState?.openItems.selected != nil {
                Button("Close Image") { appState?.openItems.closeSelected() }
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
            ForEach(WorkspaceArea.allCases) { area in
                Button("Go to \(area.title)") { appState?.selectWorkspace(area) }
                    .keyboardShortcut(KeyEquivalent(area.shortcutDigit), modifiers: .command)
                    // The file decides: a room with no data for what is open is disabled, a room not built never opens (`RoomAvailability`).
                    .disabled(appState.map { $0.roomUnavailableReason(area) != nil } ?? true)
            }
            Divider()
            // The room's Stop (the toolbar's verb turns into Cancel while a run is in flight; this is its key).
            Button("Stop") { if let appState { RoomPrimaryAction.stopActive(appState) } }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(appState.map { !RoomPrimaryAction.canStop($0) } ?? true)
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
    /// The one state graph, owned here so that closing the window never releases the files (ADR 007).
    @State private var appState = AppState()
    // File-menu actions asked for while no window is focused (`MenuActionRelay`): read by the commands, taken
    // by the window they open.
    @State private var menuRelay = MenuActionRelay()

    var body: some Scene {
        Window("macTEM", id: "image") {
            ImageWindow(menuRelay: menuRelay, appState: appState)
        }
            .handlesExternalEvents(matching: ["*"])
            .defaultLaunchBehavior(.presented)
            .defaultSize(width: LayoutPolicy.datasetWindowIdealSize.width,
                         height: LayoutPolicy.datasetWindowIdealSize.height)
            .windowStyle(.titleBar)
            .windowToolbarStyle(.unified)
            .commands {
                ImageCommands(menuRelay: menuRelay)
                // File > Save to Session (V1-2), listed before the export group so it sits above its Divider.
                SessionCommands()
                // File > Export Image… and Export Profile… (V1-10), their own `Commands` (`ExportCommands.swift`).
                ExportCommands()
                // View > Zoom In, Zoom Out, Zoom to Fit (⌘+ ⌘− ⌘0) on the pane that publishes its zoom (control placement §6).
                ZoomCommands()
            }
    }
}
