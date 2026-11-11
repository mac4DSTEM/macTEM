//
//  AppState+Open.swift
//  Role: open files into the window. Which files are open, which is selected and what each holds is
//        `OpenItems`'; here are the reader it is given — the file, its metadata, the display copy, the row's thumbnail
//        and a security-scoped bookmark, all off the main actor — the infobar's events, File > Open Recent's side
//        (every file that opened is remembered with a bookmark; an entry is opened again through it) and File > Reopen Last
//        Session's (the files open, the selected one and the room recorded as they change; the last launch's opened again).
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
    /// Every open ends here — the panel, a drop, Finder, Open Recent: one item per file not open yet, read one at a time in
    /// this order; a file open already is selected, not read twice; the first is selected at once (`OpenItems.open`). A
    /// failed read is reported by the alert (`onReadFailure`); the infobar says "Opened …" once the batch is in. Every
    /// file that opened goes to the front of Open Recent (`recents`) once the batch is in and the rooms' own opens have ended, with
    /// the bookmark made in its scope (`rememberOpened`), and into the last-session record (`recordLastSession`). The returned
    /// task ends then: with a room's file, once that room has the file or has failed. The batch's refused files are one alert, a line
    /// each, after the lines of the files a drop did not hand over (`refused`: an extension macTEM does not open), and only once
    /// every folder the Open asks for is answered: an alert up before would take the window's sheet, and the folder panel then
    /// cannot show. The files a one-document room left out are named, and said to VoiceOver, once the rooms' own opens have
    /// landed (`reportLeftOut`).
    ///
    /// One file per window (2026-11-10, Paul: "tabs like Finder or safari"): of a batch, this window takes the files it holds already
    /// and, while it holds nothing, the first; every other file opens in a tab of its own (`AppWindows.openInTabs`), or comes
    /// forward in the window that holds it. A state no window shows takes the whole batch (`windows`).
    @discardableResult
    func open(urls batch: [URL], refused: [String] = []) -> Task<Void, Never>? {
        let urls: [URL]
        let tabs: Task<[String], Never>?   // the files that get a tab of their own, looked at first (`tabsChecked`): the refused ones' sentences
        if let windows, windows.canOpenTabs {
            let split = OpenBatch.perWindow(batch, held: heldFiles, windowIsTaken: isTaken)
            // A file another window holds comes forward there at once; a new one is looked at before its tab is made.
            windows.openInTabs(split.elsewhere.filter { windows.holder(of: $0) != nil })
            let fresh = split.elsewhere.filter { windows.holder(of: $0) == nil }
            tabs = fresh.isEmpty ? nil : Task { await self.tabsChecked(fresh, windows: windows) }
            urls = split.here
            if urls.isEmpty {
                guard let tabs else { presentRefusals(refused); return nil }
                let task = Task { presentRefusals(refused + (await tabs.value)) }
                lastOpen = task
                return task
            }
        } else {
            urls = batch
            tabs = nil
        }
        guard !urls.isEmpty else { return nil }
        opensInFlight += 1
        statusText = urls.count == 1 ? "Opening \(urls[0].lastPathComponent)…" : "Opening \(urls.count) files…"
        let task = Task {
            defer { opensInFlight -= 1; recordLastSession() }
            // By content (FormatoKit's sniff), off the main actor: an HDF5 file is opened under the HDF5 lock. The sniff runs inside the
            // security scope the panel, a drop or Finder granted. The FILE decides, not the room the person is in: a file is opened into
            // every room that has data in it (`FileInventory`), and the window lands in the room of the richest dataset.
            var inventories = await Self.inventories(urls)
            // A NORDIF scan whose settings file the sandbox refused asks for its folder, once per folder in an Open (`FolderPanels`): the
            // grant is kept (`FolderGrants`) and the scan is routed again inside it. Declined, the scan keeps its refusal. A folder
            // granted for an earlier scan of this Open that is around this one too (their common parent) reaches it: nothing is asked.
            var answered: [String: Bool] = [:]   // each folder asked for in this Open: granted or not
            var granted: [String] = []           // the folders granted in this Open, by `FolderGrants.path`
            for index in inventories.indices where inventories[index].asksForFolder {
                let url = inventories[index].url
                let folder = FolderGrants.path(of: url.deletingLastPathComponent())
                if answered[folder] == nil, FolderGrants.reaches(granted, file: url) { answered[folder] = true }
                if answered[folder] == nil {
                    let chosen = await FolderPanels.askForFolder(of: url)
                    if let chosen {
                        let bookmark = try? SecurityScopedBookmark.make(for: chosen)
                        FolderGrants.store(bookmark, forFolder: chosen)
                        if bookmark != nil { granted.append(FolderGrants.path(of: chosen)) }
                    }
                    answered[folder] = chosen != nil
                }
                if answered[folder] == true, let again = await Self.inventories([url]).first { inventories[index] = again }
            }
            var images: [URL] = []
            var landing: FileInventory.Landing?
            var edsBatch: [URL] = [], eelsBatch: [URL] = [], ebsdBatch: [URL] = [], mapBatch: [URL] = []
            var refusals: [String] = []
            var taken: [RecentFile] = []   // the files with a bookmark: Open Recent takes those that opened, once the opens have ended
            for (url, inventory, bookmark, _) in inventories {
                if let why = inventory.refusal { refusals.append(why); continue }
                if let bookmark {
                    let file = RecentFile(path: url.standardizedFileURL.path, displayName: url.lastPathComponent, bookmark: bookmark)
                    taken.append(file)
                    lastSession.remember(file)
                }
                if inventory.ebsdPatterns { ebsdBatch.append(url) }
                if inventory.orientationMap { mapBatch.append(url) }
                if inventory.image { images.append(url) }
                if inventory.image, inventory.opensInEDS || inventory.eelsSpectrumImage { spectrumCompanionImages.insert(url) }
                if let scan = inventory.scan { spectrumScans[url] = scan }
                if inventory.opensInEDS { edsFiles.insert(url); edsBatch.append(url) }
                if inventory.eelsSpectrumImage { eelsFiles.insert(url); eelsBatch.append(url) }
                if let found = inventory.landing, landing == nil || found.richness > landing!.richness { landing = found }
            }
            presentRefusals(refused + refusals + (await tabs?.value ?? []))
            // One file per spectrum room: the batch's first, the one Open Files selects when it is first in the list (the room followed the
            // selection only on the next click; two files at launch left the last in the room and the first selected, 2026-10-23). The others
            // are reached by selecting their row (`spectrumRoomsFollowSelection`).
            var roomOpens: [Task<Void, Never>] = []   // the rooms' own opens, each ending when its room has the file (or has failed)
            if let first = edsBatch.first { roomOpens.append(edx.open(url: first)) }
            if let first = eelsBatch.first { roomOpens.append(eels.open(url: first)) }
            // The Patterns room holds one dataset, as the spectrum rooms do; the batch's first is it. A NORDIF scan's settings and
            // background are read with the dataset: its folder's grant is held from before the read until the open ends (`FolderGrants`).
            if let first = ebsdBatch.first {
                let folder = FolderGrants.hold(forFolderOf: first)
                let opening = ebsd.open(url: first)
                roomOpens.append(opening)
                if let folder { Task { await opening.value; folder.release() } }
            }
            // The Maps room holds one map: an `.ang`, `.ctf` or map-only `.h5oina` opened on its own (a dataset's map comes through the Patterns room).
            if let first = mapBatch.first { roomOpens.append(maps.open(url: first)) }
            // The others of each room that no Open Files row reaches are named once the rooms' opens have landed (`reportLeftOut`),
            // not dropped without a word.
            let leftOut = OpenBatch.leftOut(eds: edsBatch, eels: eelsBatch, ebsd: ebsdBatch, maps: mapBatch, imageRows: images)
            switch landing {
            case .patterns: if navigation.workspaceArea != .indexing { selectWorkspace(.patterns) }   // Indexing shows the scan too
            case .maps: selectWorkspace(.maps)
            case .eds: selectWorkspace(.edx)
            case .eels: selectWorkspace(.eels)
            case .image, nil: break   // the image is selected below, once its item exists
            }
            let roomFiles = [edsBatch.first, eelsBatch.first, ebsdBatch.first, mapBatch.first].compactMap { $0 }
            guard !images.isEmpty else {
                if landing == .eds || landing == .eels || landing == .patterns || landing == .maps { statusText = "" }
                await rememberOpened(taken, rooms: roomFiles, images: [], closed: [], after: roomOpens)
                if let leftOut { await reportLeftOut(leftOut, after: roomOpens) }
                return
            }
            // The rows this Open makes: one that is gone once the reads are in did not open (its first read failed, or it was closed).
            let made = openItems.open(urls: images).opened.compactMap { openItems.item($0) }.map { (id: $0.id, url: $0.url) }
            // From a spectrum or SEM room the image is not shown: land on it. From an image room, stay where the person was.
            if landing == .image, [.edx, .eels, .patterns, .indexing, .maps].contains(navigation.workspaceArea) { selectWorkspace(.image) }
            await openItems.settled()
            let closed = made.filter { openItems.item($0.id) == nil }.map { $0.url }
            var opened: String?
            if let image = imageSession.image {
                let suffix = openItems.selected.map(Self.sessionSuffix(of:)) ?? ""
                let stack = openItems.selected?.stack.map { " · stack of \($0.frameCount) frames, read one at a time" } ?? ""
                let line = Self.openedLine(image) + stack + suffix
                statusText = line
                opened = line
                if openItems.selected?.sidecarNeedsAccess == true {
                    AccessibilityNotification.Announcement(Self.needsAccessSentence).post()
                }
            }
            await rememberOpened(taken, rooms: roomFiles, images: images, closed: closed, after: roomOpens)
            // With the image's "Opened …" line, not in its place.
            if let leftOut { await reportLeftOut([opened, leftOut].compactMap { $0 }.joined(separator: " · "), after: roomOpens) }
        }
        lastOpen = task
        return task
    }

    /// The files of a batch that each get a tab of their own, looked at before the tab is made (`inventories`, off the main actor): a
    /// file the routing refuses gets no tab and is named in this window's alert, as Preview opens no window for a file it cannot open,
    /// so no empty tab is left behind. A NORDIF scan that asks for its folder is not refused here: its own tab asks. Returns the
    /// refused files' sentences.
    private func tabsChecked(_ urls: [URL], windows: AppWindows) async -> [String] {
        let looked = await Self.inventories(urls)
        windows.openInTabs(looked.filter { $0.inventory.refusal == nil || $0.asksForFolder }.map(\.url))
        return looked.compactMap { $0.asksForFolder ? nil : $0.inventory.refusal }
    }

    /// The refused files of one Open (a drop's own lines, then the route's sentences) as one alert, a line each: a `present` per file
    /// left only the last one up, and so did a second call while the first alert was up, which is why a drop hands its lines to its
    /// Open (`open(urls:refused:)`). The status line and Output take the same sentences on one line. Nothing for none.
    func presentRefusals(_ sentences: [String]) {
        guard !sentences.isEmpty else { return }
        errorMessage = sentences.joined(separator: "\n")
        statusText = "Error: " + sentences.joined(separator: " ")
    }

    /// Says `line`, the files a one-document room left out of a batch (`OpenBatch.leftOut`), once the rooms' own opens have landed,
    /// through `report(event:in:)`. Set while the opens had only started, the line flashed in the infobar until each room's
    /// "Opened …" replaced it, and VoiceOver, which does not read the infobar, never said it. An open that failed or was replaced
    /// by a newer one has ended too, so the wait returns.
    private func reportLeftOut(_ line: String, after roomOpens: [Task<Void, Never>]) async {
        for opening in roomOpens { await opening.value }
        report(event: line, in: nil)
    }

    /// Open Recent takes the files of a batch that opened (`OpenBatch.opened`), in the batch's order, so the last is first in the
    /// menu, with the bookmark made in each file's scope. Called once the batch is in, and run once the rooms' own opens have ended,
    /// as mac4DSTEM remembers a dataset only once its load has finished (`rememberOpenedDataset`): a file that did not open at the
    /// top of the list is backwards, and picking it there fails again. `taken` are the batch's files with a bookmark, `rooms` the
    /// file each one-document room was given, of which only one the room then holds counts (its reader refused it, or a newer open
    /// replaced it: `roomDocuments`), `closed` the images whose row this Open made and that is gone.
    private func rememberOpened(_ taken: [RecentFile], rooms: [URL], images: [URL], closed: [URL],
                                after roomOpens: [Task<Void, Never>]) async {
        for opening in roomOpens { await opening.value }
        let held = Set(roomDocuments.map(\.standardizedFileURL.path))
        let opened = rooms.filter { held.contains($0.standardizedFileURL.path) }
        for file in OpenBatch.opened(taken, rooms: opened, imageRows: images, closed: closed) { recents.remember(file) }
    }

    /// What each URL holds, by content, off the main actor and inside the URL's security scope, and for a file that is not refused
    /// the security-scoped bookmark Open Recent keeps (made in the same scope; nil when none can be made, and then the file is not
    /// remembered). The generated demo image is an image, in memory, with no bookmark. The file a vendor file is read with (an EBSD
    /// scan's `.ang` or `.ctf` beside its patterns, and back) is granted first, inside that scope: the sandbox grants the picked file
    /// only, and the routing already reads the other (`RelatedFileAccess`). A NORDIF scan's folder granted at an earlier Open is held
    /// for its routing (`FolderGrants`); `asksForFolder` is set for one whose settings file the sandbox refused without a grant.
    @concurrent
    nonisolated static func inventories(_ urls: [URL]) async -> [(url: URL, inventory: FileInventory, bookmark: Data?, asksForFolder: Bool)] {
        urls.map { url in
            if DemoDocuments.isDemo(url) { return (url: url, inventory: FileInventory(image: true), bookmark: nil, asksForFolder: false) }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            RelatedFileAccess.grant(for: url)
            let folder = FolderGrants.hold(forFolderOf: url)
            defer { folder?.release() }
            let inventory = FileRouting.inventory(path: url.path)
            let bookmark = inventory.refusal == nil ? (try? SecurityScopedBookmark.make(for: url)) : nil
            let asks = FolderGrants.asksForFolder(refused: inventory.refusal != nil, settingsError: NORDIFOpening.settingsOpenError(url))
            return (url: url, inventory: inventory, bookmark: bookmark, asksForFolder: asks)
        }
    }

    /// File > Open Recent: the entry's bookmark resolved (without mounting a volume or asking anything) and the file opened as
    /// any other, through `open(urls:)`, which remembers it again with a bookmark made now, so a stale one is renewed and a file
    /// that moved is listed where it is. An entry on a disk that is not connected stays and the window's alert says so; one whose
    /// file is gone (moved away, renamed or deleted) leaves the list, and the alert says that (`presentRefusals`, as mac4DSTEM
    /// answers both with an alert: a menu item that only changed the status line read as nothing happening).
    @discardableResult
    func openRecent(_ entry: RecentFile) -> Task<Void, Never>? {
        var stale = false
        if let url = try? URL(resolvingBookmarkData: entry.bookmark, options: [.withSecurityScope, .withoutUI, .withoutMounting],
                              relativeTo: nil, bookmarkDataIsStale: &stale) {
            if url.standardizedFileURL.path != entry.path { recents.remove(path: entry.path) }
            return open(urls: [url])
        }
        if let volume = RecentFiles.absentVolume(of: entry.path) {
            presentRefusals(["\(entry.displayName) is on \(volume), which is not connected: connect it, then open the file again."])
        } else {
            recents.remove(path: entry.path)
            presentRefusals(["\(entry.displayName) is no longer where it was (moved, renamed or deleted), so it was removed from Open Recent."])
        }
        return nil
    }

    /// What the last-session record is made of now: the window writes the record again whenever this changes (`ImageWindow`).
    var lastSessionState: LastSessionState {
        LastSessionState(urls: openItems.items.map(\.url) + roomDocuments, selected: openItems.selected?.url, room: navigation.workspaceArea)
    }

    /// The files the one-document rooms hold now, each by the path its reader states (every reader states the one it was given): the
    /// Patterns room's dataset, the Maps room's maps, then the EDS and EELS rooms' spectrum images.
    private var roomDocuments: [URL] {
        var urls: [URL] = []
        if let url = ebsd.document?.url { urls.append(url) }
        urls.append(contentsOf: maps.sources.compactMap(\.url))
        for path in [edx.source?.metadata.filePath ?? "", eels.filePath] where !path.isEmpty {
            urls.append(URL(fileURLWithPath: path))
        }
        return urls
    }

    /// The window's open set into the last-session record (`LastSession.update`, which saves it only when it changed): the Open Files
    /// list in order, then each room's own document (the Patterns room's dataset, the maps, the spectrum images), the selected file
    /// and the room shown. Called at the end of every Open and when the selection or the room changes, and by the window whenever
    /// any of it changes (a file closed, a room's document read in).
    ///
    /// The record is the app's, over every window on screen in their order (one file per window: a window's own files alone would
    /// leave the record with one file); the selected file and the room are this window's, the one that changed last.
    func recordLastSession() {
        let state = lastSessionState
        var states = windows?.onScreen ?? []
        if !states.contains(where: { $0 === self }) { states.append(self) }
        var urls: [URL] = []
        for url in states.flatMap({ $0 === self ? state.urls : $0.lastSessionState.urls }) where !urls.contains(url) { urls.append(url) }
        lastSession.update(open: urls, selected: state.selected, room: state.room.rawValue)
    }

    /// The files this window holds, each by its standardised path: the Open Files rows and every room's own document.
    var heldFiles: Set<String> { Set(lastSessionState.urls.map { $0.standardizedFileURL.path }) }

    /// The window holds a document, or an Open is on its way into it: the next file opened gets a tab of its own.
    var isTaken: Bool { roomHoldings.hasDocument || opensInFlight > 0 }

    /// File > Reopen Last Session: the files the previous launch had open (`LastSession.previous`), each through its bookmark
    /// (resolved without mounting a volume or asking anything), opened as any other through `open(urls:)`; once they are in (a
    /// room's file once the room has it), the file that was selected and the room that was shown. A file that is gone, or on a disk
    /// that is not connected, is named in the status line and the others open; when none can be opened and no disk is waited for,
    /// the record is forgotten and the menu stops offering it. Never run at launch: a mapped multi-GB file must not load before the
    /// person asks. Nil only without a record: which files are still there is found inside the returned task, off the main actor.
    @discardableResult
    func reopenLastSession() -> Task<Void, Never>? {
        guard let record = lastSession.previous else { return nil }
        let task = Task {
            // Which files are still there is asked off the main actor (`lastSessionFiles`): a share that is mounted but asleep answers
            // slowly, once per file, and the menu must not wait for it.
            let (found, gone, offline) = await Self.lastSessionFiles(record.files)
            let missing = Self.notReopened(gone: gone, offline: offline)
            guard !found.isEmpty else {
                if offline.isEmpty { lastSession.forgetPrevious() }
                report(event: missing ?? "", in: nil)   // the status line, and VoiceOver: with every file gone this line is the whole answer
                return
            }
            let selectedPath = found.first { $0.path == record.selectedPath }?.url.standardizedFileURL.path
            await open(urls: found.map { $0.url })?.value
            if let selectedPath, let item = openItems.items.first(where: { $0.url.standardizedFileURL.path == selectedPath }) {
                openItems.select(item.id)
            }
            if let room = WorkspaceArea(rawValue: record.room) { selectWorkspace(room) }
            if let missing { report(event: missing, in: nil) }
        }
        lastOpen = task
        return task
    }

    /// The last session's files by what became of each, off the main actor: `found` (the bookmark resolves and the file is there),
    /// `offline` (on a disk that is not connected: the file's name and the volume's) and `gone` (the names of the others). Each file
    /// costs a bookmark resolved and a look at the file system; on a share that is mounted but asleep every such call waits, and
    /// on the main actor the menu hung once per file.
    @concurrent
    nonisolated static func lastSessionFiles(_ files: [RecentFile]) async
        -> (found: [(path: String, url: URL)], gone: [String], offline: [(name: String, volume: String)]) {
        var found: [(path: String, url: URL)] = []
        var gone: [String] = []
        var offline: [(name: String, volume: String)] = []
        for file in files {
            if let url = reachable(file) {
                found.append((path: file.path, url: url))
            } else if let volume = RecentFiles.absentVolume(of: file.path) {
                offline.append((name: file.displayName, volume: volume))
            } else {
                gone.append(file.displayName)
            }
        }
        return (found: found, gone: gone, offline: offline)
    }

    /// The file a last-session entry's bookmark resolves to while it is still there; nil when the bookmark does not resolve or the
    /// file it names is gone (looked at inside its security scope). Not the main actor's: `lastSessionFiles` calls it.
    private nonisolated static func reachable(_ file: RecentFile) -> URL? {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: file.bookmark, options: [.withSecurityScope, .withoutUI, .withoutMounting],
                                 relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// What Reopen Last Session says of the files it could not open; nil for none. "b.dm4 is no longer where it was (moved, renamed
    /// or deleted), so it was not reopened." (two or more: "b.dm4 and c.h5 are no longer where they were …, so they were not
    /// reopened."), and "d.dm4 is on NAS, which is not connected, so it was not reopened." Pure, so a test pins it.
    nonisolated static func notReopened(gone: [String], offline: [(name: String, volume: String)]) -> String? {
        var sentences: [String] = []
        if gone.count == 1 {
            sentences.append("\(gone[0]) is no longer where it was (moved, renamed or deleted), so it was not reopened.")
        } else if gone.count > 1 {
            sentences.append("\(OpenBatch.list(gone)) are no longer where they were (moved, renamed or deleted), so they were not reopened.")
        }
        for file in offline {
            sentences.append("\(file.name) is on \(file.volume), which is not connected, so it was not reopened.")
        }
        return sentences.isEmpty ? nil : sentences.joined(separator: " ")
    }

    static let needsAccessSentence =
        "A session file for this image is beside it, but macOS has not given macEM access to read it."

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
            // An SEM vendor record calibrates a stack's frames (a Zeiss series); the databar is not cut from a stack.
            let sem = SEMImageMetadata.read(path: url.path)
            let frame0 = try stack.frame(0)
            let first = sem?.calibrated(frame0) ?? frame0
            let canvas = canvas(for: first)
            // The stack's identity (its first frame's pixels, the stack as the object, so a mark drawn on any frame is the stack's
            // and restores with it) and what the sidecar beside it makes of it, as for a single image. Inside the live scope.
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            let identity = SessionSourceIdentity.ofStack(firstFrame: first, frameCount: stack.frameCount, fileByteSize: size)
            let sidecar = SessionGrants.outcome(source: url, opened: identity, image: first)
            return OpenedImage(image: first, canvas: canvas, metadata: AcquisitionMetadata.read(path: url.path), url: url,
                               thumbnail: Thumbnail.make(normalized: canvas.normalized, width: canvas.width, height: canvas.height, maxSide: Thumbnail.defaultMaxSide),
                               bookmark: nil, identity: identity, sidecar: sidecar, stack: stack,
                               hasGrant: SessionGrants.bookmark(forSource: url) != nil, sem: sem)
        }
        let (image, canvas, metadata, sem, databar) = try await read(url)
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
        let bookmark = try? SecurityScopedBookmark.make(for: url)
        return OpenedImage(image: image, canvas: canvas, metadata: metadata, url: url,
                           thumbnail: thumbnail, bookmark: bookmark, identity: identity, sidecar: sidecar,
                           hasGrant: SessionGrants.bookmark(forSource: url) != nil, sem: sem, databar: databar)
    }

    /// One frame of an open stack: the page's pixels and the canvas, off the main actor. The stack holds its own scope.
    @concurrent
    nonisolated static func readFrame(_ stack: ImageStackSource, _ frame: Int) async throws -> OpenedImage {
        let interval = Signposts.begin("stack.frame"); defer { Signposts.end(interval) }
        try Task.checkCancellation()
        let sem = SEMImageMetadata.read(path: stack.url.path)
        let page = try stack.frame(frame)
        let image = sem?.calibrated(page) ?? page
        try Task.checkCancellation()
        let canvas = canvas(for: image)
        // The sidebar's thumbnail follows the frame shown (it was the first frame's before).
        let thumbnail = Thumbnail.make(normalized: canvas.normalized, width: canvas.width, height: canvas.height, maxSide: Thumbnail.defaultMaxSide)
        return OpenedImage(image: image, canvas: canvas, metadata: AcquisitionMetadata(), url: stack.url, thumbnail: thumbnail, bookmark: nil, sem: sem)
    }

    /// The whole read: the file (the sandbox scope is held only while it is read; a 2D image is read whole), what the
    /// same file records about the acquisition (inside the same scope; it never throws, an unreadable record is
    /// empty), the SEM vendor record applied to the image (a Zeiss or Tescan pixel size the TIFF reader left out; the
    /// databar always cut off, so every number of the room is of the scan), then the pixels the canvas uploads, and the
    /// cut rows' own canvas, which the pane draws under the picture when the databar is shown (design §3).
    @concurrent
    nonisolated static func read(_ url: URL) async throws
        -> (CalibratedImage, CanvasPixels, AcquisitionMetadata, SEMImageMetadata?, CanvasPixels?) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let interval = Signposts.begin("open.image"); defer { Signposts.end(interval) }
        var opened = try ImageOpening.openNow(path: url.path)
        let metadata = AcquisitionMetadata.read(path: url.path)
        let sem = SEMImageMetadata.read(path: url.path)
        var databar: CanvasPixels?
        if let sem {
            let calibrated = sem.calibrated(opened)
            databar = sem.databar(of: calibrated).map(canvas(for:))
            opened = sem.cropped(calibrated)
        }
        return (opened, canvas(for: opened), metadata, sem, databar)
    }

    /// The pixels the canvas uploads, normalised over the image's finite range, and the histogram of the raw pixels.
    nonisolated static func canvas(for image: CalibratedImage) -> CanvasPixels {
        CanvasPixels.make(width: image.width, height: image.height, pixels: image.pixels)
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
    /// in the EDS room). The room holds the file whose path its reader states, so two files of one name in two folders are told apart (as
    /// `edsFitBelongs`); by name only when the reader states no path. Pure, so a test holds it; a room that is opening is left alone.
    static func roomsToFollow(selected: URL?, edsFiles: Set<URL>, eelsFiles: Set<URL>, edsFile: String, eelsFile: String,
                              edsPath: String = "", eelsPath: String = "", edsOpening: Bool, eelsOpening: Bool) -> (eds: Bool, eels: Bool) {
        guard let url = selected else { return (false, false) }
        // The open-files list keeps a resolved, standardised URL (symlinks and /private resolved); compare both sides the same way.
        func key(_ u: URL) -> String { u.resolvingSymlinksInPath().standardizedFileURL.path }
        let k = key(url), name = url.lastPathComponent
        func holds(file: String, path: String) -> Bool { path.isEmpty ? file == name : key(URL(fileURLWithPath: path)) == k }
        let eds = edsFiles.contains { key($0) == k }, eels = eelsFiles.contains { key($0) == k }
        return (eds && !holds(file: edsFile, path: edsPath) && !edsOpening, eels && !holds(file: eelsFile, path: eelsPath) && !eelsOpening)
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
                                        edsPath: edx.source?.metadata.filePath ?? "", eelsPath: eels.filePath,
                                        edsOpening: edx.isOpening, eelsOpening: eels.isOpening)
        if follow.eds, let url { edx.open(url: url) }
        if follow.eels, let url { eels.open(url: url) }
    }
}

/// What File > Reopen Last Session's record is made of (`AppState.lastSessionState`), compared to tell when it changed: the files the
/// window holds in order, the selected one and the room shown.
nonisolated struct LastSessionState: Equatable {
    var urls: [URL]
    var selected: URL?
    var room: WorkspaceArea
}

/// What one Open leaves out of the rooms that hold one document each (EDS, EELS, Patterns, Maps): pure, so a test holds it.
nonisolated enum OpenBatch {
    /// One file per window: of a batch, the files this window takes (`here`) and those that each get a tab of their own
    /// (`elsewhere`), both in the batch's order. The window takes every file it holds already (`held`, standardised paths: such a
    /// file is selected, not read twice) and, when it is not taken (it holds nothing and no Open is on its way in), the first
    /// of the others.
    static func perWindow(_ urls: [URL], held: Set<String>, windowIsTaken: Bool) -> (here: [URL], elsewhere: [URL]) {
        var here: [URL] = [], elsewhere: [URL] = []
        var free = !windowIsTaken
        for url in urls {
            if held.contains(url.standardizedFileURL.path) {
                here.append(url)
            } else if free {
                here.append(url)
                free = false
            } else {
                elsewhere.append(url)
            }
        }
        return (here, elsewhere)
    }

    /// The files of a batch a one-document room did not open (each room takes the batch's first) and that no Open Files row reaches
    /// (a spectrum image with an image is opened in its room again from its row: `spectrumRoomsFollowSelection`), room by room:
    /// "The Patterns room holds one dataset: b.h5 and c.h5 were not opened." Nil when there are none.
    static func leftOut(eds: [URL], eels: [URL], ebsd: [URL], maps: [URL], imageRows: [URL]) -> String? {
        let rooms: [(holds: String, files: [URL])] = [
            ("The EDS room holds one spectrum image", eds), ("The EELS room holds one spectrum image", eels),
            ("The Patterns room holds one dataset", ebsd), ("The Maps room holds one map", maps),
        ]
        let sentences = rooms.compactMap { room -> String? in
            let names = room.files.dropFirst().filter { !imageRows.contains($0) }.map(\.lastPathComponent)
            guard !names.isEmpty else { return nil }
            return "\(room.holds): \(Self.list(names)) \(names.count == 1 ? "was" : "were") not opened."
        }
        return sentences.isEmpty ? nil : sentences.joined(separator: " ")
    }

    /// The files of a batch that opened, in the batch's order, for Open Recent: the file each one-document room took (`rooms`, its
    /// batch's first) and an image with a row in Open Files (`imageRows`). Not a file a room left out (`leftOut` names those), nor
    /// an image whose row is gone (`closed`: its first read failed, or it was closed while it was read) unless a room took it.
    /// `taken` are the batch's files with a bookmark, each by its standardised path.
    static func opened(_ taken: [RecentFile], rooms: [URL], imageRows: [URL], closed: [URL]) -> [RecentFile] {
        func key(_ url: URL) -> String { url.standardizedFileURL.path }
        let gone = Set(closed.map(key))
        let held = Set(rooms.map(key)).union(imageRows.map(key).filter { !gone.contains($0) })
        return taken.filter { held.contains($0.path) }
    }

    /// "a", "a and b", "a, b and c".
    static func list(_ names: [String]) -> String {
        guard names.count > 1, let last = names.last else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " and " + last
    }
}
