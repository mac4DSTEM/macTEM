//
//  FolderGrants.swift
//  Role: the sandbox grant for a NORDIF scan's folder. Every signed build is sandboxed: an Open grants the `Pattern.dat` the person
//        picked, and the scan is read with the `Setting.txt` and `Background acquisition pattern.bmp` beside it, which are not of its
//        name and so cannot be asked for as related items (`RelatedFileAccess`). When the settings file is there and the sandbox
//        refuses it (`asksForFolder`), the Open asks for the folder once (`FolderPanels`) and the grant is kept here as a
//        security-scoped bookmark in UserDefaults by the folder's path, as the session sidecars' are (`SessionGrants`). A grant of
//        the scan's folder, or of a folder around it, reaches the scan at every later Open.
//
//        The scope is never held for the scan's life: `hold` holds it for the routing and for the dataset's read, which read the
//        settings and the background; the patterns are read from `Pattern.dat` itself.
//

import Foundation
import TEMCore

nonisolated enum FolderGrants {
    private static let keyPrefix = "folder.grant."

    /// The path a folder is kept by: standardized and with its links resolved, so a folder reached two ways is one grant.
    static func path(of folder: URL) -> String {
        folder.standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// The key for the grant of `folder`: its path.
    static func key(forFolder folder: URL) -> String {
        keyPrefix + path(of: folder)
    }

    static func bookmark(forFolder folder: URL, defaults: UserDefaults = .standard) -> Data? {
        defaults.data(forKey: key(forFolder: folder))
    }

    /// Stores `bookmark`, or drops the grant when nil.
    static func store(_ bookmark: Data?, forFolder folder: URL, defaults: UserDefaults = .standard) {
        if let bookmark { defaults.set(bookmark, forKey: key(forFolder: folder)) }
        else { drop(forFolder: folder, defaults: defaults) }
    }

    static func drop(forFolder folder: URL, defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key(forFolder: folder))
    }

    /// Whether `file` is read with the files of its folder: a NORDIF `Pattern.dat` (any `.dat`; one that is not NORDIF's has no
    /// settings file beside it, and no grant is asked for it).
    static func readsItsFolder(_ file: URL) -> Bool {
        NORDIFOpening.readableExtensions.contains(file.pathExtension.lowercased())
    }

    /// Whether an Open asks for the folder of a file the routing refused: only when the settings file beside it is there and the
    /// sandbox would not open it (EPERM, `NORDIFOpening.settingsOpenError`). A settings file that opens has routed the scan; none
    /// there is a `.dat` that is not NORDIF's; a file mode (EACCES) is not the sandbox's, and no folder grant changes it. Those
    /// keep the routing's answer, and a refused one its sentence.
    static func asksForFolder(refused: Bool, settingsError: Int32?) -> Bool {
        refused && settingsError == EPERM
    }

    /// The folders whose grant reaches `file`: its own, then each one around it up to the root.
    static func folders(around file: URL) -> [String] {
        var paths: [String] = []
        var folder = path(of: file.deletingLastPathComponent())
        while true {
            paths.append(folder)
            let parent = (folder as NSString).deletingLastPathComponent
            if parent == folder || parent.isEmpty { break }
            folder = parent
        }
        return paths
    }

    /// Whether a grant of one of `granted` (folders by `path(of:)`) reaches `file`: its own folder or one around it. An Open keeps
    /// the folders granted while it runs and asks nothing for a scan one of them reaches: two scans in sibling folders, their common
    /// parent chosen for the first, ask once (whether the second asks was decided before that grant existed).
    static func reaches(_ granted: [String], file: URL) -> Bool {
        folders(around: file).contains { granted.contains($0) }
    }

    /// The open panel's rule: nil when `chosen` is the folder of `file` or one around it, else the sentence for the panel.
    static func panelRefusal(chosen: URL, file: URL) -> String? {
        guard !folders(around: file).contains(path(of: chosen)) else { return nil }
        let folder = file.deletingLastPathComponent().lastPathComponent
        return "Choose “\(folder)”, the folder that holds \(file.lastPathComponent), or a folder around it."
    }

    /// The panel's sentence: what is asked for and why.
    static func askSentence(for file: URL) -> String {
        let folder = file.deletingLastPathComponent().lastPathComponent
        return "macEM reads the NORDIF scan \(file.lastPathComponent) with the Setting.txt and the background pattern beside it, "
            + "and macOS lets it open them only with the folder. Choose “\(folder)” and click Allow; macEM remembers the folder."
    }

    /// The folder `data` resolves to while it is still the one at `path`: a bookmark follows a folder that was moved or renamed, and
    /// a folder that is somewhere else is not around the file any more.
    static func grantedFolder(_ data: Data, path folderPath: String, resolve: (Data) -> URL? = { data in
        var stale = false
        return try? URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI, .withoutMounting],
                        relativeTo: nil, bookmarkDataIsStale: &stale)
    }) -> URL? {
        guard let url = resolve(data), path(of: url) == folderPath else { return nil }
        return url
    }

    /// The stored grant that reaches `file` (of its folder or one around it), resolved, with its scope held: nil for a file that is
    /// not read with its folder, when no grant is stored, or when none resolves to where it was granted (such a grant is dropped:
    /// moved, renamed, trashed or gone). Release it once the read is done.
    static func hold(forFolderOf file: URL, defaults: UserDefaults = .standard, resolve: (Data) -> URL? = { data in
        var stale = false
        return try? URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI, .withoutMounting],
                        relativeTo: nil, bookmarkDataIsStale: &stale)
    }) -> ScopeHold? {
        guard readsItsFolder(file) else { return nil }
        for folderPath in folders(around: file) {
            guard let data = defaults.data(forKey: keyPrefix + folderPath) else { continue }
            guard let folder = grantedFolder(data, path: folderPath, resolve: resolve) else {
                defaults.removeObject(forKey: keyPrefix + folderPath)   // no grant
                continue
            }
            return ScopeHold(url: folder)
        }
        return nil
    }
}
