//
//  AppState+Open.swift
//  Role: open files into the window. Which files are open, which is selected and what each holds is
//        `OpenItems`'; here are the reader it is given — the file, its metadata, the display copy, the row's thumbnail
//        and a security-scoped bookmark, all off the main actor — and the infobar's events.
//

import ShellMetal
import Foundation
import SwiftUI
import FormatoCore
import ImagoCore
import TEMCore
import TEMSession
import ShellEDXModel
import SpectroCore

extension AppState {
    /// Every open ends here — the panel, a drop, Finder: one item per file not open yet, read one at a time in this
    /// order; a file open already is selected, not read twice; the first is selected at once (`OpenItems.open`). A
    /// failed read is reported by the alert (`onReadFailure`); the infobar says "Opened …" once the batch is in.
    @discardableResult
    func open(urls: [URL]) -> Task<Void, Never>? {
        guard !urls.isEmpty else { return nil }
        statusText = urls.count == 1 ? "Opening \(urls[0].lastPathComponent)…" : "Opening \(urls.count) files…"
        let task = Task {
            // By content (FormatoKit's sniff), off the main actor: an HDF5 file is opened under the HDF5 lock. The sniff runs inside the
            // security scope the panel, a drop or Finder granted. The FILE decides, not the room the person is in: a file is opened into
            // every room that has data in it (`FileInventory`), and the window lands in the room of the richest dataset.
            let inventories = await Self.inventories(urls)
            var images: [URL] = []
            var landing: FileInventory.Landing?
            var edsBatch: [URL] = [], eelsBatch: [URL] = []
            for (url, inventory) in inventories {
                if let why = inventory.refusal { present(OpenRefusal(text: why)); continue }
                if inventory.image { images.append(url) }
                if inventory.image, inventory.opensInEDS || inventory.eelsSpectrumImage { spectrumCompanionImages.insert(url) }
                if inventory.opensInEDS { edsFiles.insert(url); edsBatch.append(url) }
                if inventory.eelsSpectrumImage { eelsFiles.insert(url); eelsBatch.append(url) }
                if let found = inventory.landing, landing == nil || found.richness > landing!.richness { landing = found }
            }
            // One file per spectrum room: the batch's first, the one Open Files selects when it is first in the list (the room followed the
            // selection only on the next click; two files at launch left the last in the room and the first selected, 2026-10-23). The others
            // are reached by selecting their row (`spectrumRoomsFollowSelection`).
            if let first = edsBatch.first { edx.open(url: first) }
            if let first = eelsBatch.first { eels.open(url: first) }
            switch landing {
            case .eds: selectWorkspace(.edx)
            case .eels: selectWorkspace(.eels)
            case .image, nil: break   // the image is selected below, once its item exists
            }
            guard !images.isEmpty else {
                if landing == .eds || landing == .eels { statusText = "" }
                return
            }
            openItems.open(urls: images)
            // From a spectrum room the image is not shown: land on it. From an image room, stay where the person was.
            if landing == .image, navigation.workspaceArea == .edx || navigation.workspaceArea == .eels { selectWorkspace(.image) }
            await openItems.settled()
            if let image = imageSession.image {
                let suffix = openItems.selected.map(Self.sessionSuffix(of:)) ?? ""
                let stack = openItems.selected?.stack.map { " · stack of \($0.frameCount) frames, read one at a time" } ?? ""
                statusText = Self.openedLine(image) + stack + suffix
                if openItems.selected?.sidecarNeedsAccess == true {
                    AccessibilityNotification.Announcement(Self.needsAccessSentence).post()
                }
            }
        }
        lastOpen = task
        return task
    }

    /// What an Open that is refused says (the route's sentence), as an alert.
    struct OpenRefusal: Error, LocalizedError { let text: String; var errorDescription: String? { text } }

    /// What each URL holds, by content, off the main actor and inside the URL's security scope. The generated demo image is an image.
    @concurrent
    nonisolated static func inventories(_ urls: [URL]) async -> [(URL, FileInventory)] {
        urls.map { url in
            if DemoDocuments.isDemo(url) { return (url, FileInventory(image: true)) }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            return (url, FileRouting.inventory(path: url.path))
        }
    }

    static let needsAccessSentence =
        "A session file for this image is beside it, but macOS has not given macTEM access to read it."

    /// What the infobar's "Opened …" line adds about the file's session (the design's table): the persistent words are
    /// in the Measure section, this is the event.
    static func sessionSuffix(of item: OpenItem) -> String {
        sessionSuffix(sidecar: item.measurements.sidecar, marks: item.measurements.marks.count,
                      notes: item.measurements.notes, needsAccess: item.sidecarNeedsAccess,
                      readOnly: item.measurements.lineage.isReadOnly)
    }

    nonisolated static func sessionSuffix(sidecar: ImageMeasurements.Sidecar, marks: Int,
                                          notes: [ImageMeasurements.Note], needsAccess: Bool, readOnly: Bool) -> String {
        if needsAccess { return " · session file needs access" }
        if readOnly { return " · session file is newer" }
        switch sidecar {
        case .refused: return " · session file not used"
        case .restored:
            let differs = notes.contains(.pixelsDiffer) ? " (image differs)" : ""
            return " · restored \(marks) \(marks == 1 ? "mark" : "marks")\(differs)"
        case .none, .saved: return ""
        }
    }

    /// The infobar is events only (an open, an error): when the selection changes or a file closes, the line of the
    /// event before is no longer about what is shown, and is cleared (an empty line is not logged: `ActivityLog.record`).
    /// A selected file whose first read is still running keeps its "Opening…" line: the open that selected it is the event.
    func selectionDidChange() {
        if let selected = openItems.selected, selected.summary == nil, selected.readFailure == nil { return }
        if !statusText.isEmpty { statusText = "" }
    }

    /// The read `OpenItems` asks for, off the main actor: a re-read resolves the item's bookmark (a stale one is made
    /// again) and holds its scope for the read; a first read uses the URL the sandbox just granted. The read itself is
    /// `read(_ url:)`; then the row's thumbnail from the display copy, and the bookmark, made inside the live scope.
    /// It ends early, at each boundary, when the item was closed or the selection left it.
    @concurrent
    nonisolated static func read(_ request: ReadRequest) async throws -> OpenedImage {
        // The generated demo image is answered from memory (`--demo-fixture`), through the same item, row and canvas as a file.
        if DemoDocuments.isDemo(request.url) {
            let image = request.url == DemoDocuments.patternURL ? DemoDocuments.diffractionPattern() : DemoDocuments.lattice()
            let canvas = canvas(for: image)
            return OpenedImage(image: image, canvas: canvas, metadata: AcquisitionMetadata(), url: request.url,
                               thumbnail: Thumbnail.make(normalized: canvas.normalized, width: canvas.width, height: canvas.height, maxSide: Thumbnail.defaultMaxSide),
                               bookmark: nil)
        }
        var url = request.url
        if let bookmark = request.bookmark {
            var stale = false
            url = try URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, bookmarkDataIsStale: &stale)
        }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        try Task.checkCancellation()
        // A multi-page TIFF opens as a stack read on demand: its first frame now, the others one at a time later, with the sandbox scope held
        // for the source's life (it is read long after this open).
        if request.bookmark == nil, ["tif", "tiff"].contains(url.pathExtension.lowercased()),
           let stack = try ImageStackSource.open(path: url.path, hold: ScopeHold(url: url)) {
            let first = try stack.frame(0)
            let canvas = canvas(for: first)
            return OpenedImage(image: first, canvas: canvas, metadata: AcquisitionMetadata.read(path: url.path), url: url,
                               thumbnail: Thumbnail.make(normalized: canvas.normalized, width: canvas.width, height: canvas.height, maxSide: Thumbnail.defaultMaxSide),
                               bookmark: nil, stack: stack)
        }
        let (image, canvas, metadata) = try await read(url)
        try Task.checkCancellation()
        // The identity of the pixels just read (what saved marks describe), and — for a file's first read only; a cold
        // item's re-read never restores — what the sidecar beside it makes of it. Inside the live scope.
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        let identity = SessionSourceIdentity.of(image, fileByteSize: size)
        let sidecar = request.bookmark == nil
            ? SessionGrants.outcome(source: url, opened: identity, image: image) : SidecarOutcome.none
        try Task.checkCancellation()
        let thumbnail = Thumbnail.make(normalized: canvas.normalized, width: canvas.width, height: canvas.height,
                                      maxSide: Thumbnail.defaultMaxSide)
        try Task.checkCancellation()
        // Nil when none can be made: the item then keeps its pixels for its life (`OpenItems`' memory rule).
        let bookmark = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil,
                                             relativeTo: nil)
        return OpenedImage(image: image, canvas: canvas, metadata: metadata, url: url,
                           thumbnail: thumbnail, bookmark: bookmark, identity: identity, sidecar: sidecar,
                           hasGrant: SessionGrants.bookmark(forSource: url) != nil)
    }

    /// One frame of an open stack: the page's pixels and the canvas, off the main actor. The stack holds its own scope.
    @concurrent
    nonisolated static func readFrame(_ stack: ImageStackSource, _ frame: Int) async throws -> OpenedImage {
        let interval = Signposts.begin("stack.frame"); defer { Signposts.end(interval) }
        try Task.checkCancellation()
        let image = try stack.frame(frame)
        try Task.checkCancellation()
        let canvas = canvas(for: image)
        // The sidebar's thumbnail follows the frame shown (it was the first frame's before).
        let thumbnail = Thumbnail.make(normalized: canvas.normalized, width: canvas.width, height: canvas.height, maxSide: Thumbnail.defaultMaxSide)
        return OpenedImage(image: image, canvas: canvas, metadata: AcquisitionMetadata(), url: stack.url, thumbnail: thumbnail, bookmark: nil)
    }

    /// The whole read: the file (the sandbox scope is held only while it is read; a 2D image is read whole), what the
    /// same file records about the acquisition (inside the same scope; it never throws, an unreadable record is
    /// empty), then the pixels the canvas uploads.
    @concurrent
    nonisolated static func read(_ url: URL) async throws -> (CalibratedImage, CanvasPixels, AcquisitionMetadata) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let interval = Signposts.begin("open.image"); defer { Signposts.end(interval) }
        let opened = try ImageOpening.openNow(path: url.path)
        let metadata = AcquisitionMetadata.read(path: url.path)
        return (opened, canvas(for: opened), metadata)
    }

    /// The pixels the canvas uploads, normalised over the image's finite range, and the histogram of the raw pixels.
    nonisolated static func canvas(for image: CalibratedImage) -> CanvasPixels {
        let floatImage = FloatImage(width: image.width, height: image.height, pixels: image.pixels)
        let normalized = floatImage.normalized()
        // `minMax` answers 0…1 for an image with no finite value; that is not a range the file holds.
        let range: ClosedRange<Float>? = image.pixels.contains(where: \.isFinite)
            ? floatImage.minMax.0...floatImage.minMax.1 : nil
        return CanvasPixels(
            width: image.width, height: image.height, normalized: normalized,
            contentVersion: MetalImageView.contentVersion(of: normalized, width: image.width, height: image.height),
            rawRange: range, histogram: IntensityHistogram.compute(image.pixels))
    }

    /// "Opened Au_rings.dm4 — 2048 × 2048 px, 0.0123 nm/px" (a metre axis in nm, µm or mm: `DisplaySampling`).
    nonisolated static func openedLine(_ image: CalibratedImage) -> String {
        let size = "\(image.width) × \(image.height) px"
        if let q = UnitDisplay.reciprocalAngstromsPerPixel(image.x) {
            return "Opened \(image.fileName) — \(size), \(UnitDisplay.number(q)) Å⁻¹/px"
        }
        guard let x = DisplaySampling.perPixel(image.x), x.isCalibrated else {
            return "Opened \(image.fileName) — \(size), not calibrated"
        }
        let unit = UnitDisplay.label(x.unit)
        return "Opened \(image.fileName) — \(size), \(UnitDisplay.number(x.scale)) \(unit)/px"
    }
}

extension AppState {
    /// Which spectrum rooms must reopen the selected file: the EDS and EELS sessions hold one document each, so a file that opened into a room is
    /// read into it again when its row is selected while another file holds the room (drive 6, 2026-10-22: clicking another open file did nothing
    /// in the EDS room). Pure, so a test holds it; a room that is opening is left alone.
    static func roomsToFollow(selected: URL?, edsFiles: Set<URL>, eelsFiles: Set<URL>, edsFile: String, eelsFile: String,
                              edsOpening: Bool, eelsOpening: Bool) -> (eds: Bool, eels: Bool) {
        guard let url = selected else { return (false, false) }
        // The open-files list keeps a resolved, standardised URL (symlinks and /private resolved); compare both sides the same way.
        func key(_ u: URL) -> String { u.resolvingSymlinksInPath().standardizedFileURL.path }
        let k = key(url), name = url.lastPathComponent
        let eds = edsFiles.contains { key($0) == k }, eels = eelsFiles.contains { key($0) == k }
        return (eds && edsFile != name && !edsOpening, eels && eelsFile != name && !eelsOpening)
    }

    /// Whether the EDS room's fit is `url`'s: the file opened into the EDS room, the room holds it (by its path when the reader states one,
    /// so two files of one name in two folders are told apart; else by name, as `roomsToFollow` compares) and is not opening another.
    /// Pure, so a test holds it.
    nonisolated static func edsFitBelongs(to url: URL, edsFiles: Set<URL>, edsFile: String, edsPath: String = "", edsOpening: Bool) -> Bool {
        func key(_ u: URL) -> String { u.resolvingSymlinksInPath().standardizedFileURL.path }
        let k = key(url)
        guard !edsOpening, edsFile == url.lastPathComponent, edsFiles.contains(where: { key($0) == k }) else { return false }
        return edsPath.isEmpty || key(URL(fileURLWithPath: edsPath)) == k
    }

    /// The EDS room's finished fit, when it is `item`'s file's (`edsFitBelongs`) and settled: while a region, pick or setting change is
    /// being fitted again the old fit would be shown under the new region's name, so nothing is listed until it lands.
    func edsResults(for item: OpenItem) -> ResultsLedger.EDSResults? {
        guard let fit = edx.fit, !edx.isRefreshing, !edx.isFitting,
              Self.edsFitBelongs(to: item.url, edsFiles: edsFiles, edsFile: edx.fileName, edsPath: edx.source?.metadata.filePath ?? "",
                                 edsOpening: edx.isOpening)
        else { return nil }
        return ResultsLedger.EDSResults(regionName: edx.regionName, fit: fit)
    }

    /// Whether the EELS room's results are `url`'s: the same rule as the EDS room's (`edsFitBelongs`), as the window holds one EELS document too.
    nonisolated static func eelsResultsBelong(to url: URL, eelsFiles: Set<URL>, eelsFile: String, eelsPath: String = "", eelsOpening: Bool) -> Bool {
        edsFitBelongs(to: url, edsFiles: eelsFiles, edsFile: eelsFile, edsPath: eelsPath, edsOpening: eelsOpening)
    }

    /// The EELS room's settled results (`ResultsLedger.EELSResults.settled`), when they are `item`'s file's (`eelsResultsBelong`).
    func eelsResults(for item: OpenItem) -> ResultsLedger.EELSResults? {
        guard Self.eelsResultsBelong(to: item.url, eelsFiles: eelsFiles, eelsFile: eels.fileName, eelsPath: eels.filePath, eelsOpening: eels.isOpening)
        else { return nil }
        return .settled(eels)
    }

    /// Every finished result of `item`: its own owners' and, when the EDS or EELS room holds its file, the room's numbers.
    func resultRows(of item: OpenItem) -> [ResultRow] {
        ResultsLedger.rows(of: item, eds: edsResults(for: item), eels: eelsResults(for: item))
    }

    /// The spectrum rooms follow the selected file (see `roomsToFollow`); called when the Open Files selection changes.
    func spectrumRoomsFollowSelection() {
        let url = openItems.selected?.url
        let follow = Self.roomsToFollow(selected: url, edsFiles: edsFiles, eelsFiles: eelsFiles, edsFile: edx.fileName, eelsFile: eels.fileName,
                                        edsOpening: edx.isOpening, eelsOpening: eels.isOpening)
        if follow.eds, let url { edx.open(url: url) }
        if follow.eels, let url { eels.open(url: url) }
    }
}
