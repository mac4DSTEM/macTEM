//
//  SessionOpening.swift
//  Role: the session sidecar's two crossings between a file and the app: what the sidecar beside a file made of its first read
//        (`SessionOpening.outcome`, run off the main actor by the reader, before anything is adopted), and a save
//        (`SessionSaving.save`, the request taken on the main actor, the write off it).
//
//        Nothing here presents a panel or reads a bookmark store: the app passes the sidecar's URL (a stored grant's, or
//        nil for the derived name beside the image) and, for a save, the place to write — the panel's URL, or the
//        bookmark of an earlier save. The sandbox facts are the design's: opening an image grants that file only, so a
//        sidecar beside it can exist yet be unreadable (`SessionSidecarFile.Refusal.notPermitted`, named apart).
//

import Foundation
import TEMCore

/// What the sidecar beside a file made of the file's first read.
package nonisolated enum SidecarOutcome: Sendable, Equatable {
    /// No sidecar (or the image is itself one, or its name cannot be derived).
    case none
    /// Read, decided and decoded: ready to adopt.
    case restored(SessionRestore.Restored)
    /// There, and not used; the reason as a sentence (a verdict's, or the file layer's).
    case refused(String)
    /// There, and macOS does not let the app read it.
    case needsAccess
}

package nonisolated enum SessionOpening {
    /// The outcome for the image `image` opened from `source`, whose identity is `opened`. `sidecar` is the URL of a
    /// stored grant or a file the user chose (the caller holds its security scope for the call); nil derives the name
    /// beside the image. Blocks on the HDF5 lock and the disk: call it off the main actor.
    package static func outcome(source: URL, sidecar: URL?, opened: SessionSourceIdentity,
                                image: CalibratedImage) -> SidecarOutcome {
        let url: URL
        if let sidecar {
            url = sidecar
        } else {
            do {
                url = try SessionSidecarFile.sidecarURL(forSource: source)
            } catch SessionSidecarFile.Refusal.sourceIsASidecar {
                return .none
            } catch let refusal as SessionSidecarFile.Refusal {
                return .refused(refusal.reason)
            } catch {
                return .none
            }
        }
        guard FileManager.default.fileExists(atPath: url.path) else { return .none }
        let contents: SessionSidecarFile.Contents
        do {
            contents = try SessionSidecarFile.read(url: url)
        } catch let refusal as SessionSidecarFile.Refusal {
            if case .notPermitted = refusal { return .needsAccess }
            return .refused(refusal.reason)
        } catch {
            return .refused("\(error)")
        }
        do throws(SessionRestore.Refusal) {
            return .restored(try SessionRestore.restore(contents, opened: opened, x: image.x, y: image.y))
        } catch {
            return .refused(error.reason)
        }
    }
}

package nonisolated enum SessionSaving {
    /// Where a save writes.
    package enum Target: Sendable {
        /// A URL the user chose in the save panel (scoped by the panel).
        case url(URL)
        /// The bookmark of an earlier save.
        case bookmark(Data)
    }

    package struct Saved: Sendable {
        package let url: URL
        /// A security-scoped bookmark of the file just published, for the next save; nil when none could be made.
        package let bookmark: Data?
        package let marks: Int
    }

    package enum Failure: Error, LocalizedError, Sendable {
        /// The item cannot be saved now (the menu and the button are off then; a race).
        case nothingToSave
        /// The stored grant does not resolve (file deleted, volume gone): the next save asks for a place.
        case grantLost
        case refused(name: String, SessionSave.Refusal)

        /// The grant to drop: it no longer resolves, or the write was denied.
        /// The file on disk changed since this window read it: the one refusal the user may answer with Replace.
        package var offersReplace: Bool {
            if case .refused(_, .changedOnDisk) = self { return true }
            return false
        }

        /// The image was read again with other pixels: the one refusal the user may answer with Save Anyway.
        package var offersSaveAnyway: Bool {
            if case .refused(_, .pixelsChanged) = self { return true }
            return false
        }

        package var dropsGrant: Bool {
            switch self {
            case .grantLost: true
            case .refused(_, let refusal): refusal.isPermissionDenied
            case .nothingToSave: false
            }
        }

        package var errorDescription: String? {
            switch self {
            case .nothingToSave: return "There is nothing to save."
            case .grantLost:
                return "macTEM no longer has access to the session file. Save again and choose the file in the panel."
            case .refused(let name, let refusal):
                if let bytes = refusal.tooLargeBytes {
                    return "Could not save \(name). The marks and their record would take \(bytes.formatted()) bytes of text; "
                        + "a session file holds \(SessionSidecarFile.maxTotalTextBytes.formatted()). "
                        + "Remove some marks, then save again."
                }
                var text = "Could not save \(name). \(Self.capitalised(refusal.reason))"
                if refusal.isPermissionDenied { text += " Save again and choose the file in the panel." }
                return text
            }
        }

        package static func capitalised(_ text: String) -> String { text.prefix(1).uppercased() + text.dropFirst() }
    }

    /// The stored grant `data` resolved to the session file it was made for, or nil. A bookmark follows its file when it is
    /// moved, renamed or trashed, so what it resolves to must still be `<image>.mactem.h5` beside the image
    /// (`panelRefusal`): else it is no grant (the next save asks in the panel, and open restores nothing from the moved
    /// file). `resolve` is the system's, injected so a test can stand for a file that moved.
    package static func grantedURL(_ data: Data, source: URL,
                                   resolve: (Data) -> URL? = { data in
        var stale = false
        return try? URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI, .withoutMounting],
                        relativeTo: nil, bookmarkDataIsStale: &stale)
    }) -> URL? {
        guard let url = resolve(data), let expected = try? SessionSidecarFile.sidecarURL(forSource: source),
              panelRefusal(chosen: url, expected: expected) == nil else { return nil }
        return url
    }

    /// Takes the request on the main actor, writes it off it and marks the revision it wrote as saved. A refusal that
    /// shows the file at the path is not a session file this build may replace moves the file's state to refused.
    ///
    /// SERIALISED: a save that asks while another writes waits for it, in order, and then
    /// takes its request afresh — so it sees what the first one recorded (`didSave`) and neither a false "changed on disk"
    /// nor a revision moved backwards can happen. A save that waited and finds nothing left to write returns what the one
    /// ahead wrote.
    @MainActor
    package static func save(_ item: OpenItem, to target: Target) async throws -> Saved {
        guard item.canTakeASave, item.measurements.isDirty || item.isSaving, item.openedIdentity != nil else {
            throw Failure.nothingToSave
        }
        await item.beginSaving()
        defer { item.endSaving() }
        if let refusal = item.measurements.savingRefusal {   // the one ahead found the file is not ours to write
            throw Failure.refused(name: item.sessionFileName ?? "the session file", refusal)
        }
        guard item.canTakeASave, let identity = item.openedIdentity else { throw Failure.nothingToSave }
        guard item.measurements.isDirty else {
            guard let saved = item.lastSaved else { throw Failure.nothingToSave }
            return saved
        }
        let name = item.sessionFileName ?? "the session file"
        let request: SessionSave.Request
        do throws(SessionSave.Refusal) {
            request = try item.measurements.saveRequest(opened: identity)
        } catch {
            throw Failure.refused(name: name, error)
        }
        let marks = item.measurements.marks.count
        do {
            let saved = try await write(request, to: target, source: item.url, marks: marks)
            item.measurements.didSave(request, opened: identity)
            item.lastSavedAt = Date()
            item.lastSaved = saved
            return saved
        } catch let failure as Failure {
            throw failure
        } catch let refusal as SessionSave.Refusal {
            if refusal.lockedTheFile { item.measurements.sidecarRefused(refusal.reason) }
            throw Failure.refused(name: name, refusal)
        }
    }

    /// The user confirmed replacing the session file another app changed: the next save writes over it, once. Not a way
    /// round any other refusal (`replaceRefusedSidecar`'s own rule: a file this build must not replace stays refused).
    @MainActor
    package static func replaceAndSave(_ item: OpenItem, to target: Target) async throws -> Saved {
        item.measurements.replaceRefusedSidecar()
        return try await save(item, to: target)
    }

    /// The user chose Save Anyway after a re-read with other pixels: the next save writes the marks against the image as it
    /// is now, once. Not a way round any other refusal.
    @MainActor
    package static func saveAnyway(_ item: OpenItem, to target: Target) async throws -> Saved {
        if let identity = item.openedIdentity { item.measurements.acceptNewPixels(identity) }
        return try await save(item, to: target)
    }

    /// The write, off the main actor: the bookmark resolved (or the panel's URL used), its scope held for the write only,
    /// the file published, and a fresh bookmark made of it (the file is new, so an old one may be stale).
    @concurrent
    private static func write(_ request: SessionSave.Request, to target: Target, source: URL, marks: Int) async throws -> Saved {
        let url: URL
        switch target {
        case .url(let chosen):
            url = chosen
        case .bookmark(let data):
            guard let granted = grantedURL(data, source: source) else { throw Failure.grantLost }
            url = granted
        }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        try SessionSave.write(request, to: url)
        let bookmark = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil,
                                             relativeTo: nil)
        return Saved(url: url, bookmark: bookmark, marks: marks)
    }

    /// The save panel's rule (the design's section 1): the name and the folder are the derived ones, so restore finds the
    /// file. Nil when `chosen` is the expected file, else the sentence for the panel.
    package static func panelRefusal(chosen: URL, expected: URL) -> String? {
        let sameName = chosen.lastPathComponent.precomposedStringWithCanonicalMapping
            == expected.lastPathComponent.precomposedStringWithCanonicalMapping
        let sameFolder = chosen.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath().path
            == expected.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath().path
        guard sameName && sameFolder else {
            return "Keep the name “\(expected.lastPathComponent)” and the image's folder, so macTEM finds the session file when you open the image."
        }
        return nil
    }

    /// The infobar's line after a save: "Saved scan.dm4.mactem.h5 — 3 marks".
    package static func savedLine(name: String, marks: Int) -> String {
        "Saved \(name) — \(marks) \(marks == 1 ? "mark" : "marks")"
    }
}

extension SessionSave.Refusal {
    /// The bytes the record would take, when the refusal is that it is over the budget: from the writer's
    /// `sidecarTooLarge` or the owner's `tooLargeToSave`; nil for any other.
    package nonisolated var tooLargeBytes: Int? {
        switch self {
        case .file(.sidecarTooLarge(let bytes)): bytes
        case .lineage(.tooLargeToSave(let bytes, _)): bytes
        default: nil
        }
    }

    /// The write was denied by the system (not by a rule of the format): the grant is no good.
    package nonisolated var isPermissionDenied: Bool {
        switch self {
        case .file(.notPermitted): return true
        case .file(.cannotWrite(_, let detail)):
            let text = detail.lowercased()
            return text.contains("operation not permitted") || text.contains("permission denied")
                || text.contains("eperm") || text.contains("eacces")
        default: return false
        }
    }

    /// The path holds something this build must not replace: the file's state becomes refused.
    package nonisolated var lockedTheFile: Bool {
        switch self {
        case .file(.foreign), .file(.newerMinReader), .file(.newerSchema), .file(.variableLengthString): return true
        default: return false
        }
    }
}
