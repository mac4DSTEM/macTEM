//
//  OpenItems.swift
//  Role: the one owner of the files open in the window (V1-13, ADR 007) — the ordered list, which one is selected,
//        and for each item its own ImageSession, ImagePresentation and viewport, so switching restores what the
//        reader left. Opening a batch, closing, selecting, stepping with wrap, and the memory rule (a byte budget
//        that sends the least recently selected items cold) are decided here as plain operations on values.
//
//        No file is touched here and no pixel is read: the read arrives as an injected `ImageReader` (the app
//        passes `AppState.read`; a test passes a fake) and the file identity as an injected closure
//        (`FileIdentity.of`, which asks the file system for the file's name only, never its bytes). Reads run one at
//        a time, in the order asked, so the transient peak of a batch is one read, not twenty; a read the selection
//        has left (a re-read of an evicted item) or the user has closed is cancelled — the reader ends at its next
//        cancellation check, which is what frees the queue — and whatever it answers anyway is dropped, never
//        published; and no read ever moves the selection. The file read may be where its bookmark resolved to, not
//        where it was opened: the answer names it, and the item (its URL, its identity) follows.
//
//        A cold item keeps its row: the summary (size, calibration) and the thumbnail the reader made, a few tens of
//        kilobytes; the pixels are the part that goes. The selected item is stored, not looked up in the list, so
//        a view that reads it is told when the selection changes and not when an unrelated file is opened or closed.
//
//        Neither a thumbnail nor a pixel is made here. The `Thumbnail` value and its pure maker (`Thumbnail.make`: a
//        box average of the finite pixels, 96 px at most) are ImagoKit's (ImagoCore, 0.4.0); the reader the app injects
//        builds it off the main actor, from the display-normalised pixels it has just made.
//
//        Isolation: this module is MainActor by default, so the owners and the items are MainActor; the values that
//        cross to the reader (and the pure rules) are `nonisolated`, Sendable and carry no state of their own.
//

import CoreGraphics
import Foundation
import Observation
#if canImport(TEMCore)
import FormatoCore
import ImagoCore
import TEMCore
#endif

// MARK: - Values

/// What an open item is. The rooms offered follow the selected item's kind; only images exist so far (spectrum images
/// and EDX files join as kinds, ADR 007).
package nonisolated enum OpenItemKind: Sendable, Equatable {
    case image
}

/// The committed zoom and pan of an item's pane, in the types `ZoomPan` uses so a round trip changes no bit. The live
/// gesture values stay in the pane's `@State`; the pane writes here when a gesture ends and starts from here.
package nonisolated struct ImageViewport: Sendable, Equatable {
    package var zoom: CGFloat
    package var offset: CGSize

    package static let initial = ImageViewport(zoom: 1, offset: .zero)

    package init(zoom: CGFloat, offset: CGSize) {
        self.zoom = zoom
        self.offset = offset
    }
}

/// The file system's opaque identifier of a file (`fileResourceIdentifier`), compared with `isEqual` as its documentation
/// says. The object is an immutable value (NSCopying, NSSecureCoding), which is why it may cross actors.
package nonisolated struct ResourceIdentifier: @unchecked Sendable, Equatable {
    private let object: NSObject

    package init(_ object: NSObject) { self.object = object }

    package static func == (lhs: ResourceIdentifier, rhs: ResourceIdentifier) -> Bool { lhs.object.isEqual(rhs.object) }
}

/// Which file an item is, independent of how its URL was spelled. The file system's own answer (`fileResourceIdentifier`:
/// equal for one path, a symlink's target and a hard link, not stable across restarts — which an in-memory list does not
/// need) decides when both sides have one; otherwise the resolved path does.
package nonisolated struct FileIdentity: Sendable {
    /// The path with symlinks and `..` resolved.
    package let path: String
    /// The identifier of the resolved file; nil when the file system did not answer.
    package let resourceID: ResourceIdentifier?

    package init(path: String, resourceID: ResourceIdentifier? = nil) {
        self.path = path
        self.resourceID = resourceID
    }

    /// Whether the two name one file. Two files of the same name in two folders are two; two spellings of one path
    /// (`dir/sub/../a.dm4`, a symlink to it) and a hard link to it are one.
    package func isSameFile(as other: FileIdentity) -> Bool {
        if let mine = resourceID, let theirs = other.resourceID { return mine == theirs }
        return path == other.path
    }

    /// The identity of `url`. Asks the file system for the resolved path and the file's identifier; reads no bytes.
    /// The identifier is read from the resolved file (a symlink's own identifier is the link's, not its target's).
    package static func of(_ url: URL) -> FileIdentity {
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        let identifier = (try? resolved.resourceValues(forKeys: [.fileResourceIdentifierKey]))?.fileResourceIdentifier
        return FileIdentity(path: resolved.path, resourceID: (identifier as? NSObject).map(ResourceIdentifier.init))
    }
}

/// What a cold item keeps of its image: the size and calibration its row shows, and the thumbnail the reader made
/// (the pixels are gone).
package nonisolated struct ImageSummary: Sendable, Equatable {
    package let width: Int
    package let height: Int
    package let fileName: String
    package let x: AxisCalibration?
    package let y: AxisCalibration?
    /// Nil when the reader made none.
    package let thumbnail: Thumbnail?

    package init(_ image: CalibratedImage, thumbnail: Thumbnail?) {
        width = image.width
        height = image.height
        fileName = image.fileName
        x = image.x
        y = image.y
        self.thumbnail = thumbnail
    }
}

/// One read the reader is asked for.
package nonisolated struct ReadRequest: Sendable {
    package let url: URL
    /// The item's security-scoped bookmark, for the re-read of an evicted item (the reader resolves it, re-making a
    /// stale one, and scopes the read); nil for a file's first read, whose URL the sandbox granted just now.
    package let bookmark: Data?

    package init(url: URL, bookmark: Data?) {
        self.url = url
        self.bookmark = bookmark
    }
}

/// What a read answers. No default on `url` or `thumbnail`: a reader that forgets either would leave the item with the
/// previous read's.
package nonisolated struct OpenedImage: Sendable {
    package let image: CalibratedImage
    /// The display-normalised pixels the canvas uploads.
    package let canvas: CanvasPixels
    package let metadata: AcquisitionMetadata
    /// The file that was read: the request's URL, or where its bookmark resolved to when the file has moved since
    /// (the item then follows it, so opening the file at its new path selects the item instead of making another).
    package let url: URL
    /// The row's picture, made by the reader off the main actor from `canvas`; nil when it made none.
    package let thumbnail: Thumbnail?
    /// The bookmark made (or re-made) inside the live scope; nil when none could be made, and then the item is never
    /// evicted — its pixels are the only copy.
    package let bookmark: Data?
    /// The identity of the pixels just read (V1-2: what the marks are drawn on), made off the main actor by the reader;
    /// nil for a reader that makes none (a test's).
    package let identity: SessionSourceIdentity?
    /// What the sidecar beside the file made of this read, decided off the main actor. Only a file's first read acts on it.
    package let sidecar: SidecarOutcome
    /// Set when the file is an image stack read on demand: `image` is its first frame and the item keeps the source, which reads the
    /// others one at a time (`OpenItems.showFrame`). Such an item has no bookmark, so it is never evicted: only one frame is resident.
    package let stack: ImageStackSource?

    package init(image: CalibratedImage, canvas: CanvasPixels, metadata: AcquisitionMetadata,
                 url: URL, thumbnail: Thumbnail?, bookmark: Data?,
                 identity: SessionSourceIdentity? = nil, sidecar: SidecarOutcome = .none, stack: ImageStackSource? = nil) {
        self.stack = stack
        self.identity = identity
        self.sidecar = sidecar
        self.image = image
        self.canvas = canvas
        self.metadata = metadata
        self.url = url
        self.thumbnail = thumbnail
        self.bookmark = bookmark
    }
}

/// The read, off the main actor. It ends early when its task is cancelled — an item closed, or a re-read the selection
/// left — by checking `Task.checkCancellation()` at its boundaries: after the file is read, before the display copy
/// and the thumbnail are made, before the bookmark. The queue waits for a read to end (reads run one at a time, so a
/// batch's peak is one), and a read that never checks holds the queue until it is done; its answer is dropped all the
/// same.
package typealias ImageReader = @concurrent @Sendable (ReadRequest) async throws -> OpenedImage

/// The read of one frame of an open image stack, off the main actor; its `OpenedImage` carries the frame's image, canvas and
/// metadata (no bookmark, identity or sidecar).
package typealias FrameReader = @concurrent @Sendable (ImageStackSource, Int) async throws -> OpenedImage

// MARK: - Memory rule

/// What an item holds in memory, from its size alone.
package nonisolated enum ResidentBytes {
    /// The pixels (4 bytes each) and the display copy (4 bytes each).
    package static let warmBytesPerPixel = 8
    /// Warm plus the `r32Float` texture of the pane (4 bytes each).
    package static let selectedBytesPerPixel = 12

    /// 8·W·H for a warm item, 12·W·H for the selected one: 128 and 192 MiB for a 4096² image.
    package static func estimate(width: Int, height: Int, isSelected: Bool) -> Int {
        (isSelected ? selectedBytesPerPixel : warmBytesPerPixel) * width * height
    }
}

/// What the eviction decision knows of one item.
package nonisolated struct EvictionCandidate: Sendable, Equatable {
    package let id: UUID
    /// What it holds in memory now; 0 for a cold item or one still being read.
    package let bytes: Int
    /// When it was last selected (a rising count); the smallest is the least recently used.
    package let lastSelected: Int
    package let isSelected: Bool
    /// An item without a bookmark cannot be read again, so its pixels are the only copy.
    package let hasBookmark: Bool

    package init(id: UUID, bytes: Int, lastSelected: Int, isSelected: Bool, hasBookmark: Bool) {
        self.id = id
        self.bytes = bytes
        self.lastSelected = lastSelected
        self.isSelected = isSelected
        self.hasBookmark = hasBookmark
    }
}

package nonisolated enum EvictionPolicy {
    /// The items to send cold, in the order to do it: the least recently selected first, until what the candidates hold
    /// is within `budget`. Never the selected item, never one without a bookmark, never one that holds nothing; when
    /// those alone keep the total over the budget, the total stays over it.
    package static func evictions(_ candidates: [EvictionCandidate], budget: Int) -> [UUID] {
        var total = candidates.reduce(0) { $0 + $1.bytes }
        guard total > budget else { return [] }
        let order = candidates.indices
            .filter { !candidates[$0].isSelected && candidates[$0].hasBookmark && candidates[$0].bytes > 0 }
            .sorted { (candidates[$0].lastSelected, $0) < (candidates[$1].lastSelected, $1) }
        var evicted: [UUID] = []
        for index in order where total > budget {
            total -= candidates[index].bytes
            evicted.append(candidates[index].id)
        }
        return evicted
    }
}

// MARK: - One item

@Observable
package final class OpenItem: Identifiable {

    /// Whether the item holds its pixels.
    package nonisolated enum Residency: Sendable, Equatable {
        /// A read is waiting or running and nothing is held yet (a file's first read, or the re-read of an evicted item).
        case reading
        /// The image and its display copy are held (the selected item's texture is the pane's).
        case resident
        /// The pixels are gone; the summary, the viewport, the presentation settings and the bookmark are kept.
        case cold
    }

    package nonisolated let id = UUID()
    package nonisolated let kind = OpenItemKind.image
    /// The file as the sandbox granted it (a name for the row before the read has answered, and what is read again);
    /// after a read that found the file moved, where its bookmark resolved to.
    package fileprivate(set) var url: URL
    /// Which file this is; follows `url` when a read finds the file moved.
    @ObservationIgnored package fileprivate(set) var fileIdentity: FileIdentity

    /// This item's own session and presentation, touched only through the item and the list. Swapped for fresh ones when
    /// the item goes cold (neither owner can release its pixels), carrying the display settings over; whoever shows an item
    /// reads them through the item each time.
    package fileprivate(set) var session = ImageSession()
    package fileprivate(set) var presentation = ImagePresentation()
    /// The marks on this file (V1-5). Never swapped: they hold no pixels, so they stay while the item is cold; its
    /// profiles are computed again when the file is read again (`publish`).
    package let measurements = ImageMeasurements()
    /// The FFT room's state for this file (V1-6): its region, spots and settings. Never swapped, as the marks; its
    /// products are held only while the room shows this file.
    package let fft = FFTAnalysis()
    /// The Particles view's settings, mask preview and report for this file. Never swapped: it holds labels and numbers, no pixels.
    package let particles = ParticleAnalysis()
    /// The Diffraction room's centre, scale, crystal, rings and spots for this file. Never swapped: numbers and labels, no pixels.
    package let diffraction = DiffractionAnalysis()
    /// The Diffraction room's tool, annulus, selection and zoom for this file: view state, apart from the results above.
    package let diffractionView = DiffractionViewState()
    /// The committed zoom and pan; kept per item, through eviction and re-read. Not observed: the pane reads it once,
    /// when it is made, and writes it at the end of every gesture — observing it would re-evaluate the pane's parent
    /// on each write for nothing.
    @ObservationIgnored package var viewport = ImageViewport.initial

    package fileprivate(set) var residency = Residency.reading
    /// Nil until the first read has answered.
    package fileprivate(set) var summary: ImageSummary?
    /// The image stack this item reads on demand (a multi-page TIFF), and the frame shown now (from 0); nil for a single image.
    package fileprivate(set) var stack: ImageStackSource?
    package fileprivate(set) var frame = 0
    /// The newest frame asked for, which may still be reading: the slider shows this one.
    package fileprivate(set) var requestedFrame = 0
    @ObservationIgnored fileprivate var frameGeneration = 0
    @ObservationIgnored fileprivate var frameTask: Task<Void, Never>?
    /// Opaque to every view, and re-made by every read: a renewed one is no news, so it is not observed.
    @ObservationIgnored package fileprivate(set) var bookmark: Data?
    /// Why the last read failed, for a row that cannot show its image; nil after a read that succeeded.
    package fileprivate(set) var readFailure: String?

    // MARK: The session record's per-file state (V1-2 slice B's UI; the marks and the lineage are `measurements`')

    /// The identity of the pixels of the latest read: what a save describes. Kept while cold.
    @ObservationIgnored package fileprivate(set) var openedIdentity: SessionSourceIdentity?
    /// A session file is beside the image and macOS has not given the app access to read it: saving is off until the
    /// user chooses it.
    package var sidecarNeedsAccess = false
    /// A save is writing (the HDF5 lock can make it wait).
    package private(set) var isSaving = false
    /// Saves that asked while one was writing, in the order they asked (slice B core's Gate B finding 5: saves are serialised).
    @ObservationIgnored private var saveWaiters: [CheckedContinuation<Void, Never>] = []
    /// What the last save of this window wrote, for a save that waited and found its marks already written.
    @ObservationIgnored package var lastSaved: SessionSaving.Saved?
    /// Saves holding the place now, and the most that ever did: one, by `beginSaving`'s own rule. Kept so a test can see
    /// that two saves never overlapped.
    @ObservationIgnored package private(set) var savesHolding = 0
    @ObservationIgnored package private(set) var mostSavesHolding = 0
    /// When this window last wrote the sidecar.
    package var lastSavedAt: Date?

    /// When the item was last selected (a rising count): the least recently selected goes cold first.
    @ObservationIgnored fileprivate var lastSelected: Int
    /// Which item was selected before the open that made this one selected; where the selection returns if its first
    /// read fails.
    @ObservationIgnored fileprivate var selectionBeforeOpen: OpenItem.ID?
    /// Raised by every read start and every read dropped: only the answer of the current one is published.
    @ObservationIgnored fileprivate var readGeneration = 0
    @ObservationIgnored fileprivate var sessionToken = 0
    @ObservationIgnored fileprivate var readTask: Task<OpenedImage, any Error>?

    fileprivate init(url: URL, fileIdentity: FileIdentity, lastSelected: Int) {
        self.url = url
        self.fileIdentity = fileIdentity
        self.lastSelected = lastSelected
    }

    /// The sidecar's file name for this image, or nil when none can be named (a name over the limit, a sidecar itself).
    package var sessionFileName: String? {
        (try? SessionSidecarFile.sidecarURL(forSource: url))?.lastPathComponent
    }

    /// Whether a save could be taken: the pixels are held and no read runs, the sidecar is not hidden, refused or newer.
    /// Whether one is writing or something changed is `canSave`'s and `SessionSaving.save`'s own question.
    package var canTakeASave: Bool {
        residency == .resident && session.image != nil && !session.isLoading && openedIdentity != nil
            && !sidecarNeedsAccess && measurements.savingRefusal == nil
    }

    /// Whether File > Save to Session would save now: a save could be taken, none is writing, and something changed since
    /// the last save or restore.
    package var canSave: Bool { canTakeASave && !isSaving && measurements.isDirty }

    /// Takes the one place to write: returns at once when no save is writing, else when every save that asked before this
    /// one has finished (first come, first served). Two saves never overlap, so neither's request is taken against the
    /// state the other has not yet recorded (`ImageMeasurements.didSave`). Pair with `endSaving`.
    package func beginSaving() async {
        if isSaving {
            await withCheckedContinuation { saveWaiters.append($0) }   // the one that finishes hands over `isSaving`
        } else {
            isSaving = true
        }
        savesHolding += 1
        mostSavesHolding = max(mostSavesHolding, savesHolding)
    }

    /// Gives the place to the next save that asked, or frees it.
    package func endSaving() {
        savesHolding -= 1
        if saveWaiters.isEmpty { isSaving = false } else { saveWaiters.removeFirst().resume() }
    }

    /// Acts on what the sidecar made of a read: restores the marks it holds, or records why it was not used. Only into an
    /// owner that holds nothing (`ImageMeasurements.restore`); a late answer into marks drawn meanwhile is dropped.
    /// Returns whether the marks were adopted.
    @discardableResult
    package func adopt(_ outcome: SidecarOutcome, identity: SessionSourceIdentity, on image: CalibratedImage) -> Bool {
        switch outcome {
        case .none:
            sidecarNeedsAccess = false   // the file just read (or chosen) is not there: nothing is hidden any more
            return false
        case .needsAccess:
            sidecarNeedsAccess = true
            return false
        case .refused(let reason):
            sidecarNeedsAccess = false
            measurements.sidecarRefused(reason)
            return false
        case .restored(let restored):
            sidecarNeedsAccess = false   // it was read, so it is no longer hidden, whether or not it is adopted now
            do throws(ImageMeasurements.RestoreRefusal) {
                try measurements.restore(restored, opened: identity, on: image)
            } catch {
                return false
            }
            return true
        }
    }

    /// Whether a read has ever answered; false for a file's first read (which, failing, removes the item).
    fileprivate var hasBeenRead: Bool { summary != nil }

    /// What the item holds in memory now, by `ResidentBytes`; 0 when it holds nothing.
    package func residentBytes(isSelected: Bool) -> Int {
        guard residency == .resident, let summary else { return 0 }
        return ResidentBytes.estimate(width: summary.width, height: summary.height, isSelected: isSelected)
    }

    fileprivate func beginReading() {
        readGeneration &+= 1
        readFailure = nil
        residency = .reading
        sessionToken = session.beginOpen()
    }

    /// Publishes a read's answer. `movedTo` is the identity of `opened.url` when the read found the file somewhere other
    /// than `url`; the item then follows it.
    fileprivate func publish(_ opened: OpenedImage, movedTo: FileIdentity?) {
        guard session.finishOpen(sessionToken, image: opened.image, url: opened.url, metadata: opened.metadata) else { return }
        if let movedTo {
            url = opened.url
            fileIdentity = movedTo
        }
        presentation.show(opened.canvas)
        measurements.refresh(on: opened.image)
        // The session record (V1-2): only a file's first read restores — a re-read of a cold item never swaps the marks —
        // and only the read that is still the current one reaches here (`finishOpen`'s token above).
        if let identity = opened.identity {
            let first = !hasBeenRead
            measurements.noteOpened(identity)
            openedIdentity = identity
            if first { adopt(opened.sidecar, identity: identity, on: opened.image) }
        }
        if let source = opened.stack {
            stack?.release()
            stack = source
            frame = 0
            requestedFrame = 0
        }
        // Wholesale, the thumbnail too: a file changed on disk since the last read must not keep the old picture.
        summary = ImageSummary(opened.image, thumbnail: opened.thumbnail)
        if let renewed = opened.bookmark { bookmark = renewed }
        readFailure = nil
        residency = .resident
    }

    /// A re-read ended without pixels (failed, or dropped by the selection leaving): back to cold, saying why if it failed.
    fileprivate func endRead(failure: String?) {
        session.failOpen(sessionToken)
        readFailure = failure
        residency = .cold
    }

    /// Shows frame `n` of the stack: the image and its canvas are replaced, the marks stay and are refreshed on the new pixels. The
    /// answer of an older request is dropped.
    fileprivate func publishFrame(_ opened: OpenedImage, frame n: Int, generation: Int) {
        guard generation == frameGeneration else { return }
        sessionToken = session.beginOpen()
        guard session.finishOpen(sessionToken, image: opened.image, url: opened.url, metadata: opened.metadata) else { return }
        presentation.show(opened.canvas)
        measurements.refresh(on: opened.image)
        summary = ImageSummary(opened.image, thumbnail: opened.thumbnail ?? summary?.thumbnail)
        frame = n
        frameTask = nil
    }

    fileprivate func requestFrame(_ n: Int, reader: @escaping FrameReader) {
        guard let source = stack, n >= 0, n < source.frameCount, n != requestedFrame else { return }
        requestedFrame = n
        frameGeneration &+= 1
        let generation = frameGeneration
        frameTask?.cancel()
        frameTask = Task { [weak self] in
            guard let opened = try? await reader(source, n), !Task.isCancelled else { return }
            self?.publishFrame(opened, frame: n, generation: generation)
        }
    }

    fileprivate func closeStack() {
        frameTask?.cancel()
        frameTask = nil
        stack?.release()
    }

    fileprivate func cancelRead() {
        readGeneration &+= 1
        readTask?.cancel()
        readTask = nil
    }

    fileprivate func goCold() {
        let kept = presentation
        session = ImageSession()
        presentation = ImagePresentation()
        presentation.keepSettings(of: kept)
        residency = .cold
    }
}

// MARK: - The list

@Observable
package final class OpenItems {
    package private(set) var items: [OpenItem] = []
    /// The selected item, stored — not looked up in `items` — so that a view reading it depends on the selection alone:
    /// opening or closing another file changes `items` and does not tell it.
    package private(set) var selected: OpenItem?

    /// The selected item's id, derived from `selected`.
    package var selectedID: OpenItem.ID? { selected?.id }

    /// The binding for `List(selection:)`: reads the selected id, and a write selects that item. A write of nil (the
    /// list asking for no selection) and a write of an id that is not open change nothing — one item stays selected
    /// while any is open.
    package var selection: OpenItem.ID? {
        get { selectedID }
        set { if let newValue { select(newValue) } }
    }

    /// What the items may hold in memory together: a soft cap, not a ceiling. It is enforced when the selection moves,
    /// the selected item closes, a read has published, and the budget itself changes — never while a read runs — so
    /// while one runs, the items held (up to the budget) and the image being read (its raw, Float32 and display copies
    /// counted nowhere) together exceed it by about one image; once the read publishes, the least recently selected
    /// go cold at once. It stays exceeded while the items that may not go cold — the selected one, those without a
    /// bookmark — alone exceed it. Provisional until the measurement of V1-13's slice (c) replaces it.
    package var budgetBytes: Int {
        didSet { if budgetBytes != oldValue { evictToBudget() } }
    }

    /// Told of every read that failed — a file that could not be opened (its item is removed) and an evicted file that
    /// could not be read again (its item stays, cold) — except a read that was dropped. The app shows its alert.
    @ObservationIgnored package var onReadFailure: (@MainActor (URL, any Error) -> Void)?

    @ObservationIgnored private let identify: (URL) -> FileIdentity
    @ObservationIgnored private let reader: ImageReader
    @ObservationIgnored private let frameReader: FrameReader?
    @ObservationIgnored private var clock = 0
    @ObservationIgnored private var queue: [OpenItem] = []
    @ObservationIgnored private var worker: Task<Void, Never>?

    /// A quarter of the physical memory, until the measurement.
    package static var provisionalBudgetBytes: Int { Int(ProcessInfo.processInfo.physicalMemory / 4) }

    package init(budgetBytes: Int = OpenItems.provisionalBudgetBytes,
                 identify: @escaping (URL) -> FileIdentity = FileIdentity.of,
                 frameReader: FrameReader? = nil,
                 reader: @escaping ImageReader) {
        self.budgetBytes = budgetBytes
        self.identify = identify
        self.frameReader = frameReader
        self.reader = reader
    }

    /// Shows frame `frame` (from 0) of `item`'s image stack: one frame is read, off the main actor, and replaces the one shown; a newer
    /// request drops the answer of an older one. Nothing for an item that is not a stack, a frame out of range, or no frame reader.
    package func showFrame(_ item: OpenItem, to frame: Int) {
        guard let frameReader else { return }
        item.requestFrame(frame, reader: frameReader)
    }

    /// The frame `delta` away from the one asked for last, kept inside the stack (the ends do nothing); the arrow keys' step.
    package func stepFrame(_ item: OpenItem, by delta: Int) {
        guard let stack = item.stack else { return }
        showFrame(item, to: min(max(item.requestedFrame + delta, 0), stack.frameCount - 1))
    }

    package func item(_ id: OpenItem.ID) -> OpenItem? { items.first { $0.id == id } }

    /// What the items hold in memory now, the selected one at its 12·W·H.
    package var residentBytes: Int {
        items.reduce(0) { $0 + $1.residentBytes(isSelected: $1 === selected) }
    }

    // MARK: Opening

    package nonisolated struct OpenOutcome: Equatable, Sendable {
        /// The items made, in the order of the URLs.
        package let opened: [OpenItem.ID]
        /// The items an URL named that were open already (a file open twice is selected, not read twice).
        package let alreadyOpen: [OpenItem.ID]
    }

    /// Opens a batch: one new item per file not open yet (a file named twice in the batch counts once), read in the
    /// order given; the first URL's item — new, or open already — is selected at once. A file open already is not
    /// read again, except that when it is the selected one and cold, its re-read is asked for (the gesture is the
    /// user's, there is nothing to wait for). The selected item's read goes ahead of any still waiting, whichever
    /// batch they came from (`restoreSelected`).
    @discardableResult
    package func open(urls: [URL]) -> OpenOutcome {
        let before = selectedID
        var opened: [OpenItem] = []
        var alreadyOpen: [OpenItem.ID] = []
        var first: OpenItem?
        for url in urls {
            let identity = identify(url)
            if let existing = items.first(where: { identity.isSameFile(as: $0.fileIdentity) }) {
                if !alreadyOpen.contains(existing.id), !opened.contains(where: { $0 === existing }) {
                    alreadyOpen.append(existing.id)
                }
                first = first ?? existing
                continue
            }
            let item = OpenItem(url: url, fileIdentity: identity, lastSelected: tick())
            items.append(item)
            opened.append(item)
            first = first ?? item
        }
        guard let first else { return OpenOutcome(opened: [], alreadyOpen: []) }
        if opened.contains(where: { $0 === first }) { first.selectionBeforeOpen = before }
        select(first.id)
        for item in opened { enqueue(item, atFront: false) }
        restoreSelected()
        return OpenOutcome(opened: opened.map(\.id), alreadyOpen: alreadyOpen)
    }

    // MARK: Closing and selecting

    /// Closes an item. When it was the selected one, the next takes its place, else the previous.
    package func close(_ id: OpenItem.ID) {
        guard let item = item(id) else { return }
        remove(item, selectionPreferred: nil)
    }

    /// Closes the selected item (⌘W); nothing when none is open.
    package func closeSelected() {
        guard let selected else { return }
        remove(selected, selectionPreferred: nil)
    }

    /// Keeps `id` and closes every other item ("Close Others"); the selection moves to it first, so no other item is
    /// selected on the way. Nothing when `id` is not open.
    package func closeOthers(keeping id: OpenItem.ID) {
        guard item(id) != nil else { return }
        select(id)
        for other in items where other.id != id { remove(other, selectionPreferred: nil) }
    }

    /// Told after every selection change (the sidebar's click, the next/previous commands): the spectrum rooms follow the selected file through it.
    /// A callback, not an observation: the rooms must follow whether or not a view is watching the selection.
    @ObservationIgnored package var onSelect: ((OpenItem) -> Void)?

    package func select(_ id: OpenItem.ID) {
        guard id != selectedID, let item = item(id) else { return }
        dropRereadOfSelected()
        selected = item
        item.lastSelected = tick()
        evictToBudget()
        onSelect?(item)
    }

    /// The next item in the list, the first after the last.
    package func selectNext() { step(1) }

    /// The previous item in the list, the last before the first.
    package func selectPrevious() { step(-1) }

    private func step(_ delta: Int) {
        guard !items.isEmpty else { return }
        let target: Int
        if let current = items.firstIndex(where: { $0 === selected }) {
            target = (current + delta + items.count) % items.count
        } else {
            target = delta > 0 ? 0 : items.count - 1
        }
        select(items[target].id)
    }

    /// Puts the selected item's read ahead of any still waiting: a cold item is asked to be read again, and an item still
    /// queued for its read (a file of a batch not yet reached) moves to the front of the queue, as it is, without a
    /// second start. An item whose read is already running, or that is resident, is left alone. The caller waits for
    /// the selection to rest first (V1-13: 150 ms); a re-read is dropped if the selection leaves before it ends.
    package func restoreSelected() {
        guard let item = selected else { return }
        switch item.residency {
        case .cold:
            enqueue(item, atFront: true)
        case .reading:
            guard let index = queue.firstIndex(where: { $0 === item }), index > 0 else { return }
            queue.remove(at: index)
            queue.insert(item, at: 0)
        case .resident:
            break
        }
    }

    // MARK: Memory

    private func evictToBudget() {
        let candidates = items.map { item in
            EvictionCandidate(id: item.id, bytes: item.residentBytes(isSelected: item === selected),
                              lastSelected: item.lastSelected, isSelected: item === selected,
                              hasBookmark: item.bookmark != nil)
        }
        for id in EvictionPolicy.evictions(candidates, budget: budgetBytes) { self.item(id)?.goCold() }
    }

    // MARK: Reads

    /// Waits until no read is waiting or running.
    package func settled() async {
        while let running = worker { await running.value }
    }

    private func enqueue(_ item: OpenItem, atFront: Bool) {
        queue.removeAll { $0 === item }
        item.beginReading()
        if atFront { queue.insert(item, at: 0) } else { queue.append(item) }
        if worker == nil { worker = Task { [weak self] in await self?.drain() } }
    }

    private func drain() async {
        while let item = nextQueued() {
            let generation = item.readGeneration
            let request = ReadRequest(url: item.url, bookmark: item.hasBeenRead ? item.bookmark : nil)
            let reader = self.reader
            let read = Task { try await reader(request) }
            item.readTask = read
            let result = await read.result
            if item.readTask == read { item.readTask = nil }
            guard item.readGeneration == generation else { continue }
            finishRead(of: item, result)
        }
        worker = nil
    }

    private func nextQueued() -> OpenItem? {
        while !queue.isEmpty {
            let item = queue.removeFirst()
            if item.residency == .reading { return item }
        }
        return nil
    }

    private func finishRead(of item: OpenItem, _ result: Result<OpenedImage, any Error>) {
        switch result {
        case .success(let opened):
            // The file may be where its bookmark resolved to, not where it was opened: the item follows it.
            // (Outside a live scope the file system may not answer for the identifier; the path then decides.)
            let movedTo = opened.url == item.url ? nil : identify(opened.url)
            item.publish(opened, movedTo: movedTo)
            evictToBudget()
        case .failure(let error):
            if item.hasBeenRead {
                item.endRead(failure: Self.message(error))
            } else {
                remove(item, selectionPreferred: item.selectionBeforeOpen)
            }
            onReadFailure?(item.url, error)
        }
    }

    /// The selection left an item whose re-read is still running: nobody is waiting for it any more.
    private func dropRereadOfSelected() {
        guard let leaving = selected, leaving.residency == .reading, leaving.hasBeenRead else { return }
        leaving.cancelRead()
        queue.removeAll { $0 === leaving }
        leaving.endRead(failure: nil)
    }

    private func remove(_ item: OpenItem, selectionPreferred: OpenItem.ID?) {
        item.cancelRead()
        item.closeStack()
        queue.removeAll { $0 === item }
        guard let index = items.firstIndex(where: { $0 === item }) else { return }
        items.remove(at: index)
        guard selected === item else { return }
        // The one the selection was promised to, else the next (which takes this index), else the previous.
        let successor = selectionPreferred.flatMap(self.item(_:))
            ?? (items.indices.contains(index) ? items[index] : items.last)
        selected = successor
        successor?.lastSelected = tick()
        evictToBudget()
    }

    private func tick() -> Int {
        clock &+= 1
        return clock
    }

    private static func message(_ error: any Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
