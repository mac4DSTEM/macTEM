//
//  AppState.swift
//  Role: the window's composition root — the app's one window (ADR 007). It composes the owners and holds only
//        the shell's own feedback channels. A feature's state lives in its owner, never here: a new stored
//        property names its owner first.
//
//  Owners: `navigation` (rooms and panes, App/), `openItems` (the files open in the window, each with its own
//  session, presentation, marks and viewport, TEMSession), `activityLog` (the Output pane, App/), `imageRoomTools`
//  (the Image room's measuring tool, App/), `resultsRoom` (the Results room's selection and shown groups, App/), `edx` (the EDX room's spectrum image, picks and fit, TEMSession) and `edxRoom` (its spectrum window and export in flight, App/). `imageSession`, `presentation` and `measurements` are the selected
//  item's, forwarded, so the views that read them did not change with V1-13.
//

import ShellLayout
import Foundation
import TEMCore
import TEMSession
import ShellEDXModel
import ShellSpectroscopy

@Observable
final class AppState {
    let navigation = WorkspaceNavigation()
    let openItems = OpenItems(frameReader: AppState.readFrame(_:_:), reader: AppState.read(_:))
    let activityLog = ActivityLog()
    let imageRoomTools = ImageRoomTools()
    let resultsRoom = ResultsRoomState()
    let edx = EDXSession(host: .macTEM)
    let edxRoom = EDXRoomState()
    let eels = EELSSession()

    /// The window's title: the file of the room that is shown (the spectrum image in the EDX and EELS rooms, the image elsewhere).
    var windowTitle: String {
        let name: String? = switch navigation.workspaceArea {
        case .edx: edx.fileName
        case .eels: eels.fileName
        default: imageSession.image?.fileName
        }
        if let name, !name.isEmpty { return name }
        return imageSession.image?.fileName ?? "macTEM"
    }
    let eelsRoom = EELSRoomState()
    /// The status line's readout over the diffraction pattern (`DiffractionReadoutText`); nil when the pointer is elsewhere.
    var diffractionReadout: String?

    /// What the views read with no file open: an empty session and presentation, never written.
    @ObservationIgnored private let idleSession = ImageSession()
    @ObservationIgnored private let idlePresentation = ImagePresentation()
    @ObservationIgnored private let idleMeasurements = ImageMeasurements()

    /// The selected item's session (the open image, its file, whether it is being read), else an empty one.
    var imageSession: ImageSession { openItems.selected?.session ?? idleSession }
    /// The selected item's presentation (the canvas and the colormap), else an empty one.
    var presentation: ImagePresentation { openItems.selected?.presentation ?? idlePresentation }
    /// The selected item's marks (V1-5), else an empty owner.
    var measurements: ImageMeasurements { openItems.selected?.measurements ?? idleMeasurements }

    /// The infobar's one line, events only (an open, an error), empty otherwise; every non-empty change is also an
    /// Output line.
    var statusText = "" {
        didSet { activityLog.record(statusText) }
    }

    /// The alert's text; nil when no alert is up.
    var errorMessage: String?

    /// Bumped by every "Open Image…" gesture; `ContentView` presents the open panel when it changes.
    private(set) var openImageRequest = 0

    var hasImage: Bool { imageSession.image != nil }

    /// The newest Open in flight (routing, then the reads): a test awaits it.
    @ObservationIgnored var lastOpen: Task<Void, Never>?
    /// Files opened into the Image room that are also spectrum images (the HAADF of a Velox SI): their image is a scan image, which the Diffraction room does not take.
    var spectrumCompanionImages: Set<URL> = []
    /// The files that opened into the EDS room and into the EELS room: a room follows the selected file (`spectrumRoomsFollowSelection`).
    var edsFiles: Set<URL> = []
    var eelsFiles: Set<URL> = []
    /// When each spectrum room last became busy (`markBusy`): the start of the toolbar's busy clock (`RunClock`). Not observed: the
    /// clock ticks on its own.
    @ObservationIgnored var busySince: [WorkspaceArea: Date] = [:]

    /// The launch arguments this window started with (`--export-dir` is read where an export chooses its URL).
    let launch: LaunchOptions

    /// Where an export journey writes without a panel (`--export-dir`): an absolute path as given, a relative one inside the app's
    /// temporary folder (the sandbox lets the app write there, a test runner outside it cannot name it). nil for a person.
    var exportDirectory: URL? {
        guard let dir = launch.exportDirectory else { return nil }
        return dir.path.hasPrefix("/") && !launch.exportDirectoryIsRelative ? dir : FileManager.default.temporaryDirectory.appendingPathComponent(launch.exportDirectoryName ?? "export", isDirectory: true)
    }

    init(launch: LaunchOptions = LaunchOptions()) {
        self.launch = launch
        // The spectrum rooms follow the selected file through the list's own callback (a view's observation did not fire on screen, drive 6).
        openItems.onSelect = { [weak self] _ in self?.spectrumRoomsFollowSelection() }
        openItems.onReadFailure = { [weak self] _, error in self?.present(error) }
        edx.onEvent = { [weak self] in self?.statusText = $0 }
        edx.onFailure = { [weak self] in self?.present($0) }
        eels.onEvent = { [weak self] in self?.statusText = $0 }
        eels.onFailure = { [weak self] in self?.present($0) }
        applyLaunchOptions(launch)
    }

    /// The UI tests' and the demo's starting state (`LaunchOptions`): saved geometry cleared, the generated documents opened.
    private func applyLaunchOptions(_ launch: LaunchOptions) {
        if launch.isUITesting { LaunchOptions.clearSavedGeometry(); UITestingPlacement.installIfTesting() }
        if launch.demoImage { open(urls: [DemoDocuments.latticeURL]) }
        if launch.demoPattern { open(urls: [DemoDocuments.patternURL]); navigation.workspaceArea = .diffraction }
        if launch.demoStack, let url = try? DemoDocuments.stackFile() { open(urls: [url]) }
        if launch.demoSpectrumFile, let url = try? DemoDocuments.spectrumFile() { open(urls: [url]) }
        if launch.demoSpectrum {
            edx.bind(DemoDocuments.edx())
            if launch.demoRegions { DemoDocuments.drawRegions(on: edx) }
        }
        if launch.demoEELS, let loaded = try? DemoDocuments.eels() {
            eels.bind(loaded)
            if launch.demoRegions { DemoDocuments.drawRegions(on: eels) }
        }
        if !launch.openFiles.isEmpty { open(urls: launch.openFiles) }   // `--open`: the path a drop takes
        reconcileRoom()
    }

    func requestOpenImage() {
        openImageRequest &+= 1
    }

    /// A room can be entered when the window holds data for it (`RoomAvailability`); one that is not built never can.
    func selectWorkspace(_ area: WorkspaceArea) {
        guard roomUnavailableReason(area) == nil else { return }
        navigation.workspaceArea = area
    }

    /// What the shared EDS room's views ask of this window: the status line, the error sheet, a UI journey's export folder.
    var edxActions: EDXRoomActions {
        EDXRoomActions(report: { [weak self] in self?.statusText = $0 }, present: { [weak self] in self?.present($0) },
                       exportDirectory: { [weak self] in self?.exportDirectory })
    }

    func present(_ error: any Error) {
        let detail = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        errorMessage = detail
        statusText = "Error: \(detail)"
    }
}
