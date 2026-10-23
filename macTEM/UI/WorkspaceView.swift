import ShellLayout
import SwiftUI
#if canImport(TEMCore)
import TEMCore
import TEMSession
#endif

/// The detail column: the science, and the infobar + process area along its bottom edge. The column's chassis (the divider,
/// its drag, the infobar, the process area and their scene-stored fractions) is ShellLayout's `WorkspaceColumn` (suite task 8,
/// MacEMUI); what stays here is what the canvas shows (the room switch, welcome, loading, unreadable). The room actions and
/// the file name live in the toolbar, not here. **There is no workspace header**; readiness has one owner, the inspector's
/// Settings tab.
struct WorkspaceView: View {
    @Environment(AppState.self) private var appState

    /// Whether the process area has a document to sit under: an open image, or a spectrum-image room (its document is the
    /// spectrum image, which needs no open image; alignment design: Output is available there too). An image that is absent
    /// or still loading forces the area shut regardless of the dragged fraction, which is NOT reset for it.
    private var hasDocument: Bool {
        switch appState.navigation.workspaceArea {
        case .edx: appState.edx.hasImage
        case .eels: appState.eels.hasImage
        default: appState.hasImage && !appState.imageSession.isLoading
        }
    }

    var body: some View {
        WorkspaceColumn(
            navigation: appState.navigation.panels,
            tabs: [ProcessTab.output { OutputPane(log: appState.activityLog) }],
            hasDocument: hasDocument,
            statusText: cursorReadout ?? appState.statusText,
            isRunning: showsRun,
            canvas: { content },
            run: { runSlot },
            glance: { glanceSlot })
    }

    /// The room's cursor readout, which stands in the status line while the pointer is over a picture (control placement §7).
    private var cursorReadout: String? {
        switch appState.navigation.workspaceArea {
        case .edx: appState.edxRoom.readout
        case .eels: appState.eelsRoom.readout
        case .image: appState.imageRoomTools.readout
        case .diffraction: appState.diffractionReadout
        default: nil
        }
    }

    private var showsRun: Bool { InfobarRunPolicy.shows(area: appState.navigation.workspaceArea, eelsComputing: appState.eels.isComputing) || showsFit }

    /// The Diffraction room's ring fit, while it runs and the room is shown.
    private var showsFit: Bool {
        InfobarRunPolicy.showsFit(area: appState.navigation.workspaceArea, fitting: appState.openItems.selected?.diffraction.isFitting ?? false)
    }

    /// A room's pass in flight, in the infobar where every run of the suite sits (Paul, 2026-10-23: not a bar over the maps): the bar, the percent and Stop.
    @ViewBuilder
    private var runSlot: some View {
        if showsFit, let analysis = appState.openItems.selected?.diffraction {
            // A fit has no fraction to show: the bar is indeterminate.
            InfobarRunReadout(operation: "Ring fit", progress: nil, line: { _ in "Fitting" }, onCancel: { analysis.stop() })
        } else if showsRun {
            let eels = appState.eels
            InfobarRunReadout(operation: "EELS", progress: eels.progress, line: { _ in InfobarRunPolicy.percent(eels.progress) }, onCancel: { eels.stop() })
        }
    }

    /// The standing fact: this app's memory, in Finder's decimal style (the engine's name tells nothing, ADR 011).
    private var glanceSlot: some View {
        InfobarGlance(help: "This app's memory footprint") {
            OperationMetricsFormat.glance(residentMB: SystemMonitor.residentMemoryMB() * 1.048576)
        }
    }

    /// The room's pane, the welcome door before any image, and the open in flight over either. The Image and
    /// FFT rooms are built, and a room that is not built cannot be selected (`AppState.selectWorkspace`). An open in
    /// flight is drawn OVER the image already shown: if it fails, that image is still there, at its zoom.
    @ViewBuilder
    private var content: some View {
        if appState.navigation.workspaceArea == .edx {
            EDXRoom()
        } else if appState.navigation.workspaceArea == .eels {
            EELSRoom()
        } else if let item = appState.openItems.selected {
            if let image = item.session.image, let canvas = item.presentation.canvas {
                // Keyed by the item: switching items is a new pane, which starts from the item's own committed zoom
                // and pan (`ImagePane`), not the last pane's. (Not `canvas.contentVersion`: two files with equal
                // pixels are two items.)
                Group {
                    // The room switch: the FFT room shows the image beside its transform (V1-6), the Results room the file's
                    // measurements (V1-10 slice 3); the Image room its pane.
                    if appState.navigation.workspaceArea == .fft {
                        FFTRoom(image: image, canvas: canvas, item: item)
                    } else if appState.navigation.workspaceArea == .results {
                        ResultsRoom(image: image, item: item)
                    } else if appState.navigation.workspaceArea == .diffraction {
                        DiffractionRoom(image: image, item: item)
                    } else {
                        ImagePane(image: image, canvas: canvas, item: item)
                    }
                }
                    .id(item.id)
                    .stackArrowKeys(item: item, items: appState.openItems)
                    .overlay {
                        if item.session.isLoading { loadingState.background(.regularMaterial) }
                    }
            } else if let failure = item.readFailure {
                unreadableState(item, failure)
            } else {
                // First read, or a cold item about to be read again once the selection rests.
                loadingState
            }
        } else {
            WelcomeWorkspace()
        }
    }

    private func unreadableState(_ item: OpenItem, _ failure: String) -> some View {
        ContentUnavailableView {
            Label("Can't read \(item.url.lastPathComponent)", systemImage: "exclamationmark.triangle")
        } description: {
            Text(failure)
        } actions: {
            Button("Try Again") { appState.openItems.restoreSelected() }
        }
        .accessibilityIdentifier("welcome.unreadableStatus")
    }

    private var loadingState: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
            Text("Opening image")
                .font(.headline)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("welcome.loadingStatus")
    }
}

/// The canvas before any image: the app's name and its one door.
struct WelcomeWorkspace: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                VStack(spacing: 12) {
                    Image(systemName: "circle.dotted")
                        .font(.system(size: 54, weight: .light))
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                    Text("macTEM")
                        .font(.largeTitle.weight(.semibold))
                    Text("Calibrated TEM images and electron diffraction, native on the Mac.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: LayoutPolicy.readableWidth)
                }
                Button("Open Image…") { appState.requestOpenImage() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .help(OpenItemRowFormat.openPrompt)
                    .accessibilityIdentifier("welcome.openImage")
            }
            .padding(.horizontal, 36)
            .padding(.vertical, 44)
            .frame(maxWidth: .infinity)
        }
    }
}

/// ← and → step through the frames of an image stack (Home and End go to the ends) while the picture has the keyboard; a click on it
/// gives it the keyboard, and it is the default focus of the window while nothing else is being typed in. Nothing for an item that is not a stack.
private struct StackArrowKeys: ViewModifier {
    let item: OpenItem
    let items: OpenItems
    @FocusState private var hasFocus: Bool

    func body(content: Content) -> some View {
        if let stack = item.stack {
            content
                .focusable()
                .focusEffectDisabled()
                .focused($hasFocus)
                .simultaneousGesture(TapGesture().onEnded { hasFocus = true })
                // The picture is the DEFAULT focus: it has the keyboard when nothing else claims it, and never takes it from a field the person is in
                // (an inspector entry) when the pane is rebuilt. A click on it takes the keyboard (above).
                .defaultFocus($hasFocus, true)
                .onKeyPress(.leftArrow) { items.stepFrame(item, by: -1); return .handled }
                .onKeyPress(.rightArrow) { items.stepFrame(item, by: 1); return .handled }
                .onKeyPress(.home) { items.showFrame(item, to: 0); return .handled }
                .onKeyPress(.end) { items.showFrame(item, to: stack.frameCount - 1); return .handled }
        } else {
            content
        }
    }
}

private extension View {
    func stackArrowKeys(item: OpenItem, items: OpenItems) -> some View { modifier(StackArrowKeys(item: item, items: items)) }
}

/// When the infobar shows a room's run, and its words (pure).
nonisolated enum InfobarRunPolicy {
    /// The EELS room's map or fit pass, while it runs and the room is shown.
    static func shows(area: WorkspaceArea, eelsComputing: Bool) -> Bool { area == .eels && eelsComputing }

    /// The Diffraction room's ring fit, while it runs and the room is shown (control placement: progress in the infobar, not the pane header).
    static func showsFit(area: WorkspaceArea, fitting: Bool) -> Bool { area == .diffraction && fitting }

    static func percent(_ f: Double) -> String { "\(Int((min(max(f, 0), 1) * 100).rounded())) %" }
}
