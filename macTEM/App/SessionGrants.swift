//
//  SessionGrants.swift
//  Role: the sandbox grant for a session file (V1-2 slice B's UI, archive: v12-session-ui-design-2026-10-14.md,
//        "The sandbox grant for a sidecar"). Opening an image grants that file only, so the sidecar beside it is
//        reachable through a security-scoped bookmark made when the user chose it in the save panel (or Choose Session
//        File…), kept in UserDefaults by the image's path — mac4DSTEM's way. `@AppStorage` does nothing in an
//        `@Observable`, so the defaults are read directly. A grant is a fact about the process and the file system, not
//        about any open file, so it lives here and not on `AppState`.
//
//        The scope is never held for a file's life: `outcome` holds it for one read.
//

import Foundation
import TEMCore
import TEMSession

nonisolated enum SessionGrants {
    private static let keyPrefix = "session.grant."

    /// The key for the grant of `source`'s sidecar: the image's path as the open resolved it.
    static func key(forSource source: URL) -> String {
        keyPrefix + source.standardizedFileURL.path
    }

    static func bookmark(forSource source: URL, defaults: UserDefaults = .standard) -> Data? {
        defaults.data(forKey: key(forSource: source))
    }

    /// Stores `bookmark`, or drops the grant when nil.
    static func store(_ bookmark: Data?, forSource source: URL, defaults: UserDefaults = .standard) {
        if let bookmark { defaults.set(bookmark, forKey: key(forSource: source)) }
        else { drop(forSource: source, defaults: defaults) }
    }

    static func drop(forSource source: URL, defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key(forSource: source))
    }

    /// What the sidecar beside `source` made of its first read, off the main actor: through the stored grant when there is
    /// one (its scope held for the read), else the derived name beside the image. A grant that no longer resolves is
    /// no grant, and the derived name is tried (the sandbox then says `needsAccess`).
    static func outcome(source: URL, opened: SessionSourceIdentity, image: CalibratedImage,
                        defaults: UserDefaults = .standard) -> SidecarOutcome {
        var granted: URL?
        if let data = bookmark(forSource: source, defaults: defaults) {
            granted = SessionSaving.grantedURL(data, source: source)
            if granted == nil { drop(forSource: source, defaults: defaults) }   // moved, renamed, trashed or gone: no grant
        }
        let scoped = granted?.startAccessingSecurityScopedResource() ?? false
        defer { if scoped { granted?.stopAccessingSecurityScopedResource() } }
        return SessionOpening.outcome(source: source, sidecar: granted, opened: opened, image: image)
    }
}
