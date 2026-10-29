import ShellInspector
import ShellLayout
import SwiftUI
import TEMCore
import TEMSession
import ShellEDXModel
import ShellSpectroscopy

/// The inspector: the window's right column, in two tabs. **Settings** is the room's readiness first, then
/// every control the selected room owns. **Info** is what the open image actually *is*. The frame (the tab
/// capsule in Liquid Glass, the top-pinned column, the one toggle in the inspector's own toolbar, ⌥⌘I, always
/// enabled) is ShellLayout's `WorkspaceInspectorFrame` (suite task 8, MacEMUI); the two tabs' content is the app's.
struct WorkspaceInspector: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        WorkspaceInspectorFrame(
            navigation: appState.navigation.panels,
            infoHelp: "Info — what the image is",
            settings: { InspectorSettingsTab() },
            info: { InspectorInfoTab() })
    }
}

// MARK: - Settings tab

/// Readiness first, then the selected room's own controls.
private struct InspectorSettingsTab: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        if appState.navigation.workspaceArea == .edx {
            InspectorScrollColumn {
                EDXRoomSettings(session: appState.edx, state: appState.edxRoom, actions: appState.edxActions)
                    .environment(\.inspectorScope, "settings.edx")
            }
            .environment(\.inspectorScope, "settings")
        } else if appState.navigation.workspaceArea == .eels {
            InspectorScrollColumn {
                EELSRoomSettings()
                    .environment(\.inspectorScope, "settings.eels")
            }
            .environment(\.inspectorScope, "settings")
        } else if let image = appState.imageSession.image {
            InspectorScrollColumn {
                    switch appState.navigation.workspaceArea {
                    case .image:
                        ImageRoomSettings(image: image)
                            .environment(\.inspectorScope, "settings.image")
                    case .fft:
                        if let item = appState.openItems.selected {
                            FFTRoomSettings(image: image, item: item)
                                .environment(\.inspectorScope, "settings.fft")
                        }
                    case .results:
                        if let item = appState.openItems.selected {
                            ResultsRoomSettings(image: image, item: item)
                                .environment(\.inspectorScope, "settings.results")
                        }
                    case .diffraction:
                        if let item = appState.openItems.selected {
                            DiffractionRoomSettings(image: image, item: item)
                                .environment(\.inspectorScope, "settings.diffraction")
                        }
                    case .edx, .eels:
                        // Unbuilt rooms cannot be selected (`AppState.selectWorkspace`).
                        EmptyView()
                    }
            }
            .environment(\.inspectorScope, "settings")
        } else {
            ContentUnavailableView(
                "No image open",
                systemImage: "photo",
                description: Text("\(OpenItemRowFormat.openPrompt); each room's controls appear here.")
            )
        }
    }
}

// MARK: - Info tab

/// What the open image is.
private struct InspectorInfoTab: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        if appState.navigation.workspaceArea == .edx {
            InspectorScrollColumn {
                EDXRoomInfo(session: appState.edx)
            }
            .environment(\.inspectorScope, "info")
        } else if appState.navigation.workspaceArea == .eels {
            InspectorScrollColumn {
                EELSRoomInfo()
            }
            .environment(\.inspectorScope, "info")
        } else if let image = appState.imageSession.image {
            InspectorScrollColumn {
                    // The room switch: the FFT room says first what it transforms (V1-6).
                    if appState.navigation.workspaceArea == .fft, let item = appState.openItems.selected {
                        FFTRoomInfoSection(image: image, item: item)
                    }
                    // The Results room says what the selected result is, then its source image (V1-10 slice 3).
                    if appState.navigation.workspaceArea == .results, let item = appState.openItems.selected {
                        ResultsRoomInfo(image: image, item: item)
                    } else {
                        ImageInfoSection(image: image, canvas: appState.presentation.canvas)
                    }
            }
            .environment(\.inspectorScope, "info")
        } else {
            ContentUnavailableView(
                "No image open",
                systemImage: "photo",
                description: Text("The file, its size and its calibration appear here.")
            )
        }
    }
}
