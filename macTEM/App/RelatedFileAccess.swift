//
//  RelatedFileAccess.swift
//  Role: read access to the file a picked vendor file is read with, under the App Sandbox (mac4DSTEM's RelatedFileAccess,
//        mac4DSTEM#120, ported).
//
//        Every signed build is sandboxed (macTEM.entitlements, for Debug, Release and the DMG alike): the sandbox grants the
//        file the user picked (`files.user-selected.read-write`), not the file beside it. The vendors' EBSD scans are pairs
//        read together by name, whichever of the two is picked: an EDAX `.up1`/`.up2` with its `.ang` (`EDAXOpening`), an
//        Oxford `.ebsp` with its `.ctf` (`OxfordOpening`). Without a grant the sibling still "exists" (file-read-metadata is
//        broad), so the pairing finds it and the read fails with EPERM: a picked `.ebsp` failed outright, a picked `.ang` was
//        refused, a picked `.up1` lost its map.
//
//        The narrow grant macOS offers for this is the related item: Info.plist declares the companion extensions with
//        `NSIsRelatedItemType`, and a file presenter whose `primaryPresentedItemURL` is the picked file and whose
//        `presentedItemURL` is the sibling (same folder, same name, other extension) gets the sibling's access once it is
//        registered and a coordinated read has run. The presenter stays registered for the app's life: the Patterns room reads
//        its patterns long after the open (`EBSDSession`).
//

import Foundation

nonisolated final class RelatedFileAccess: NSObject, NSFilePresenter, @unchecked Sendable {
    let primaryPresentedItemURL: URL?
    let presentedItemURL: URL?
    let presentedItemOperationQueue = OperationQueue()

    private init(primary: URL, related: URL) {
        primaryPresentedItemURL = primary
        presentedItemURL = related
        super.init()
    }

    /// The companion extensions each picked extension reads. Info.plist declares the right-hand sides as related item
    /// types; RelatedFileAccessTests holds the two lists together.
    static let companionExtensions: [String: [String]] = [
        "up1": ["ang"],
        "up2": ["ang"],
        "ang": ["up1", "up2"],
        "ebsp": ["ctf"],
        "ctf": ["ebsp"],
    ]

    /// The siblings a picked file may need: same folder and name, each companion extension, upper case when the picked
    /// extension is upper case (SCAN.EBSP beside SCAN.CTF). The folder cannot be listed under the sandbox, so the case
    /// follows the picked file rather than a directory read; APFS's default case-insensitivity covers a mixed pair.
    static func companions(of url: URL) -> [URL] {
        let picked = url.pathExtension
        guard let extensions = companionExtensions[picked.lowercased()] else { return [] }
        let upper = !picked.isEmpty && picked == picked.uppercased()
        return extensions.map { url.deletingPathExtension().appendingPathExtension(upper ? $0.uppercased() : $0) }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var held: [String: RelatedFileAccess] = [:]

    /// Registers a presenter for each companion of `url` that is not yet held, and runs one coordinated read so the
    /// sandbox extends the grant. Safe to call for any file: other formats have no companions, and outside the sandbox
    /// (the unit tests' host) the grant is a no-op. Call it while the picked file's own security scope is held.
    static func grant(for url: URL) {
        for related in companions(of: url) {
            let key = related.standardizedFileURL.path
            let presenter: RelatedFileAccess? = lock.withLock {
                guard held[key] == nil else { return nil }
                let presenter = RelatedFileAccess(primary: url, related: related)
                held[key] = presenter
                return presenter
            }
            guard let presenter else { continue }
            NSFileCoordinator.addFilePresenter(presenter)
            var error: NSError?
            NSFileCoordinator(filePresenter: presenter)
                .coordinate(readingItemAt: related, options: .withoutChanges, error: &error) { _ in }
        }
    }
}
