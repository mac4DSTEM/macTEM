//
//  AppState.swift
//  Role: the window's composition root — the app's one window (ADR 007). It composes the owners and holds only
//        the shell's own feedback channels. A feature's state lives in its owner, never here: a new stored
//        property names its owner first.
//
//  Owners: `navigation` (rooms and panes, App/), `openItems` (the files open in the window, each with its own
//  session, presentation, marks and viewport, TEMSession), `activityLog` (the Output pane, App/), `imageRoomTools`
//  (the Image room's measuring tool, App/), `resultsRoom` (the Results room's selection and shown groups, App/), `edx` (the EDX room's spectrum image, picks and fit, TEMSession) and `edxRoom` (its spectrum window and export in flight, App/), `ebsd` (the Patterns room's dataset) and `indexing` (the Indexing room's run on it, TEMSession), `semRecord` (the SEM rooms' exports and Output lines for the session report, App/), `recents` (File > Open Recent's last eight files, TEMSession), `lastSession` (File > Reopen Last Session's record, TEMSession). `imageSession`, `presentation` and `measurements` are the selected
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
    /// The EDS room's SEM rows for an SEM `.hspy` spectrum (line intensities with background windows, window quantification).
    let semEDS = SEMEDSState()
    let eels = EELSSession()
    /// The Patterns room's dataset, position and pictures (TEMSession) and its view state (App/).
    let ebsd: EBSDSession
    let patternsRoom = PatternsRoomState()
    /// The Indexing room's phases, settings and run on the Patterns room's dataset (TEMSession) and its view state (App/).
    let indexing: IndexingSession
    let indexingRoom = IndexingRoomState()
    /// The Maps room's orientation map, layer and pictures (TEMSession) and its view state (App/).
    let maps = OrientationMapSession()
    let mapsRoom = MapsRoomState()
    /// What the SEM rooms did that none of them keeps: every file they wrote and their Output lines with times (App/), for the Results
    /// room's session rows and the session report.
    let semRecord = SEMSessionRecord()
    /// File > Open Recent's list (TEMSession): every file `open(urls:)` takes in, with the bookmark that opens it again. The app passes
    /// the list kept in UserDefaults (`RecentFiles.stored()`); a bare `AppState()`, a test's, keeps one in memory and writes nothing.
    let recents: RecentFiles
    /// File > Reopen Last Session's record (TEMSession): the files open, the selected one and the room, written as they change
    /// (`recordLastSession`), and the previous launch's, which the menu offers. The app passes the record kept in UserDefaults
    /// (`LastSession.stored()`); a bare `AppState()`, a test's, keeps one in memory and writes nothing.
    let lastSession: LastSession

    /// The window's title: the file of the room that is shown (the spectrum image in the EDX and EELS rooms, the image elsewhere).
    var windowTitle: String {
        let name: String? = switch navigation.workspaceArea {
        case .edx: edx.fileName
        case .eels: eels.fileName
        case .patterns, .indexing: ebsd.fileName
        case .maps: maps.fileName
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

    /// The question up before files with unsaved marks close (`requestClose`, CloseGuard.swift); nil when none is asked.
    var closeRequest: CloseRequest?

    /// Bumped by every "Open Image…" gesture; `ContentView` presents the open panel when it changes.
    private(set) var openImageRequest = 0

    var hasImage: Bool { imageSession.image != nil }

    /// The newest Open in flight (routing, then the reads): a test awaits it.
    @ObservationIgnored var lastOpen: Task<Void, Never>?
    /// Files opened into the Image room that are also spectrum images (the HAADF of a Velox SI): their image is a scan image, which the Diffraction room does not take.
    var spectrumCompanionImages: Set<URL> = []
    /// The scan of each opened DM4 spectrum image, from its header: its Open Files row shows the scan, not the survey image's size.
    var spectrumScans: [URL: FileInventory.Scan] = [:]
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

    init(launch: LaunchOptions = LaunchOptions(), recents: RecentFiles? = nil, lastSession: LastSession? = nil) {
        self.launch = launch
        self.recents = recents ?? RecentFiles()
        self.lastSession = lastSession ?? LastSession()
        let ebsd = EBSDSession()
        self.ebsd = ebsd
        indexing = IndexingSession(patterns: ebsd)
        // The spectrum rooms follow the selected file through the list's own callback (a view's observation did not fire on screen, drive 6),
        // and the last-session record takes the new selection.
        openItems.onSelect = { [weak self] _ in
            self?.spectrumRoomsFollowSelection()
            self?.recordLastSession()
        }
        openItems.onReadFailure = { [weak self] _, error in self?.present(error) }
        // A stack frame that could not be read: the status line, Output and VoiceOver say which and why (the slider is back on the frame shown).
        openItems.onFrameFailure = { [weak self] in self?.report(event: $0, in: nil) }
        // Every session's event line: the infobar, the SEM rooms' session record, and VoiceOver for a line that ends something.
        edx.onEvent = { [weak self] in self?.report(event: $0, in: nil) }
        edx.onFailure = { [weak self] in self?.present($0) }
        eels.onEvent = { [weak self] in self?.report(event: $0, in: nil) }
        eels.onFailure = { [weak self] in self?.present($0) }
        ebsd.onEvent = { [weak self] in self?.report(event: $0, in: .patterns) }
        ebsd.onFailure = { [weak self] in self?.present($0) }
        maps.onEvent = { [weak self] in self?.report(event: $0, in: .maps) }
        maps.onFailure = { [weak self] in self?.present($0) }
        // Every dataset the Patterns room binds: the Indexing room starts over on it, and the Maps room drops the old dataset's maps
        // (its own and an Indexing run on it) and shows the new one's crystal map with the patterns beside (a map opened on its own
        // gives way to it); both go back when the dataset closes, a map opened on its own stays.
        ebsd.onBind = { [weak self] document in
            guard let self else { return }
            self.indexing.bind(document)
            self.maps.patternsChanged(to: OrientationMapSession.patternsDocument(fileName: document.fileName, url: document.url,
                                                                                 dataset: document.dataset))
        }
        ebsd.onClose = { [weak self] in
            self?.indexing.close()
            self?.maps.patternsClosed()
        }
        indexing.onEvent = { [weak self] in self?.report(event: $0, in: .indexing) }
        // Every file the SEM rooms write is kept for the Results room and the session report (D-SEM-104).
        patternsRoom.onWritten = { [weak self] in self?.semRecord.wrote($0) }
        indexingRoom.onWritten = { [weak self] in self?.semRecord.wrote($0) }
        mapsRoom.onWritten = { [weak self] in self?.semRecord.wrote($0) }
        indexing.onFailure = { [weak self] in self?.present($0) }
        applyLaunchOptions(launch)
    }

    /// Whether the databar a Thermo or Tescan SEM TIFF's vendor drew under the scan is hidden (`SEMImageSettings`, on by default).
    /// The picture is always the scan alone; shown, the bar is a strip under it (`ImagePane`), so the setting re-reads nothing.
    var cropsDatabar = SEMImageSettings.cropDatabar() {
        didSet {
            guard cropsDatabar != oldValue else { return }
            SEMImageSettings.setCropDatabar(cropsDatabar)
        }
    }

    /// The UI tests' and the demo's starting state (`LaunchOptions`): saved geometry cleared, the generated documents opened.
    private func applyLaunchOptions(_ launch: LaunchOptions) {
        if launch.isUITesting { LaunchOptions.resetSavedState(); UITestingPlacement.installIfTesting() }
        if launch.demoImage { open(urls: [DemoDocuments.latticeURL]) }
        if launch.demoPattern { openDemo(.diffraction) }
        if launch.demoStack, let url = try? DemoDocuments.stackFile() { open(urls: [url]) }
        if launch.demoSEMImage, let url = try? DemoDocuments.semImageFile() { open(urls: [url]) }
        if launch.demoSpectrumFile, let url = try? DemoDocuments.spectrumFile() { open(urls: [url]) }
        if launch.demoSEMSpectrum { openDemo(.semSpectrum) }
        if launch.demoOrientationMap { openDemo(.orientationMap) }
        if launch.demoSpectrum {
            edx.bind(DemoDocuments.edx())
            if launch.demoRegions { DemoDocuments.drawRegions(on: edx) }
        }
        if launch.demoEELS, let loaded = try? DemoDocuments.eels() {
            eels.bind(loaded)
            if launch.demoRegions { DemoDocuments.drawRegions(on: eels) }
        }
        if launch.demoEBSD, let document = try? DemoDocuments.ebsd() {   // the generated set: planted numbers for the journey
            ebsd.bind(document); navigation.workspaceArea = .patterns
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
        recordLastSession()
    }

    /// Go to a workspace: the room it was last in when that can still be entered, else its first room that can. A workspace none of
    /// whose rooms can be entered is not entered (`workspaceUnavailableReason`).
    func selectWorkspaceGroup(_ group: WorkspaceGroup) {
        guard group != navigation.workspaceArea.group else { return }
        let candidates = [navigation.lastRoom[group]].compactMap { $0 } + group.parts
        if let room = candidates.first(where: { roomUnavailableReason($0) == nil }) { navigation.workspaceArea = room }
    }

    /// Indexing's `Open in Maps` (D-SEM-99): the last run's crystal map to the Maps room without a file, at the pattern pinned in
    /// Patterns and Indexing, and the Maps room in front. The returned task ends when the map is drawn; nil when nothing went across
    /// (`IndexingSession.openInMapsRefusal`, said in the status line, or the map could not be built, said in the error sheet).
    @discardableResult
    func openIndexingInMaps() -> Task<Void, Never>? {
        if let refusal = indexing.openInMapsRefusal { statusText = refusal; return nil }
        do {
            guard let run = try indexing.mapsDocument() else { statusText = "Index first"; return nil }
            let drawn = maps.bind(run, pinned: ebsd.pinned)
            followMapsPin()
            selectWorkspace(.maps)
            return drawn
        } catch {
            present(error)
            return nil
        }
    }

    /// The Maps room's `Source` pop-up: the map held as `id`, at the same point where it has it (`OrientationMapSession.showSource`),
    /// the pattern pane beside it on the same point.
    @discardableResult
    func showMapsSource(_ id: OrientationMapSession.Document.ID) -> Task<Void, Never>? {
        let drawn = maps.showSource(id)
        followMapsPin()
        return drawn
    }

    /// A map on the Patterns room's scan takes the pattern pinned there, or the origin when it does not reach it (a stopped run's
    /// rows): the Patterns room follows, so the crosshair and the live pattern pane beside it show the same point.
    private func followMapsPin() {
        guard let dataset = ebsd.dataset, maps.isOnScan(of: dataset), ebsd.pinned != maps.pinned else { return }
        ebsd.pin(maps.pinned)
    }

    /// What the Maps room says of the map it shows when that is an Indexing run (`IndexingSession.staleness(ofRun:method:)`), nil
    /// otherwise.
    var mapsStaleness: String? {
        guard case .indexing(let run, let method) = maps.document?.source else { return nil }
        return indexing.staleness(ofRun: run, method: method)
    }

    /// What the shared EDS room's views ask of this window: the status line, the error sheet, a UI journey's export folder.
    var edxActions: EDXRoomActions {
        EDXRoomActions(report: { [weak self] in self?.statusText = $0 }, present: { [weak self] in self?.present($0) },
                       exportDirectory: { [weak self] in self?.exportDirectory })
    }

    /// The alert and the status line for `error`: its sentence, and for a system error its domain, code and underlying error
    /// (`ErrorDetail`), so a sandbox denial and a missing file read apart.
    func present(_ error: any Error) {
        let detail = ErrorDetail.text(error)
        errorMessage = detail
        statusText = "Error: \(detail)"
    }
}
