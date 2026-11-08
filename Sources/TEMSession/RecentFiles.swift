//
//  RecentFiles.swift
//  Role: File > Open Recent's list — the last eight files the window opened, most recent first, each with the security-scoped
//        bookmark that opens it again after a relaunch, and the menu titles that tell two files of one name apart by their folders.
//        mac4DSTEM's `RecentDatasets` (mac4DSTEM/Session/RecentDatasets.swift), for files: the list is state with its own changes
//        (remember, remove, clear, the cap at eight) and is saved as a unit, so it is its own owner, not `AppState`'s.
//
//        Saving is injected. The app passes the list kept in UserDefaults (`stored()`); a bare `RecentFiles()` keeps the list in
//        memory and writes nothing, which is what a test and a UI-testing launch get, so neither reads or writes a person's recents.
//        The titles are stored and made again on every change, never on a read (the menu reads them each time it is drawn).
//

import Foundation
import Observation

/// One file the window opened: its path (the identity), the name the menu shows and the bookmark that opens it again.
package nonisolated struct RecentFile: Codable, Identifiable, Hashable, Sendable {
    package let path: String
    package var displayName: String
    package var bookmark: Data

    package var id: String { path }

    package init(path: String, displayName: String, bookmark: Data) {
        self.path = path
        self.displayName = displayName
        self.bookmark = bookmark
    }
}

@Observable
package final class RecentFiles {
    /// Most recently opened first; never more than `capacity`, never one path twice.
    package private(set) var entries: [RecentFile]
    /// Each entry's menu title by its path (`menuTitles(for:)`), made again on every change.
    package private(set) var titles: [String: String] = [:]

    /// Eight, as mac4DSTEM's list and the system's own Open Recent menus.
    package static let capacity = 8
    /// Where `stored()` keeps the list.
    package nonisolated static let defaultsKey = "recent.files.v1"

    private let persist: ([RecentFile]) -> Void

    /// `entries` as saved (a path saved twice, by a hand-edited or damaged store, is kept once: the first), and `persist`, told the
    /// whole list after every change. The defaults keep it in memory only.
    package init(entries: [RecentFile] = [], persist: @escaping ([RecentFile]) -> Void = { _ in }) {
        var seen = Set<String>()
        self.entries = Array(entries.filter { seen.insert($0.path).inserted }.prefix(RecentFiles.capacity))
        self.persist = persist
        retitle()
    }

    /// The app's list: read from `defaults`, every change written back. A test passes defaults of its own, never the standard ones.
    package static func stored(in defaults: UserDefaults = .standard) -> RecentFiles {
        let saved = defaults.data(forKey: RecentFiles.defaultsKey).flatMap { try? JSONDecoder().decode([RecentFile].self, from: $0) } ?? []
        return RecentFiles(entries: saved) { entries in
            if let data = try? JSONEncoder().encode(entries) { defaults.set(data, forKey: RecentFiles.defaultsKey) }
        }
    }

    /// `entry` at the front (moved there when its path is in the list already), the oldest past eight dropped, and the list saved.
    package func remember(_ entry: RecentFile) {
        entries.removeAll { $0.path == entry.path }
        entries.insert(entry, at: 0)
        if entries.count > Self.capacity { entries.removeLast(entries.count - Self.capacity) }
        save()
    }

    /// Drops the entry of `path`. A path not in the list changes nothing and saves nothing.
    package func remove(path: String) {
        let before = entries.count
        entries.removeAll { $0.path == path }
        guard entries.count != before else { return }
        save()
    }

    /// Clear Menu: the list emptied and saved. An empty list saves nothing.
    package func clear() {
        guard !entries.isEmpty else { return }
        entries.removeAll()
        save()
    }

    /// The menu's title for `entry`: its name, with its folders in front when another entry has the same name.
    package func title(of entry: RecentFile) -> String {
        titles[entry.path] ?? entry.displayName
    }

    private func save() {
        persist(entries)
        retitle()
    }

    private func retitle() {
        let paths = entries.map(\.path)
        titles = Dictionary(zip(paths, Self.menuTitles(for: paths)), uniquingKeysWith: { first, _ in first })
    }

    /// A title per path, in order: the file name alone when no other path has that name; else the name with the fewest of its folders
    /// in front ("2026-11/scan.dm4") that no other path of that name shares; the whole path when every folder up to the root is
    /// shared. String work on the saved paths only, so a disk that is not connected is never asked about.
    package nonisolated static func menuTitles(for paths: [String]) -> [String] {
        let components = paths.map { $0.split(separator: "/").map(String.init) }
        return components.indices.map { index in
            let parts = components[index]
            guard let name = parts.last else { return paths[index] }
            let others = components.indices
                .filter { $0 != index && components[$0].last == name && paths[$0] != paths[index] }
                .map { components[$0] }
            guard !others.isEmpty else { return name }
            for depth in 1..<parts.count {
                let suffix = Array(parts.suffix(depth + 1))
                if !others.contains(where: { Array($0.suffix(depth + 1)) == suffix }) { return suffix.joined(separator: "/") }
            }
            return paths[index]
        }
    }

    /// The volume `path` is on when it is a disk or share under `/Volumes` that is not connected now, else nil. Such an entry is kept
    /// (mac4DSTEM's rule): the file is likely still there, and removing it would forget the only place its path is shown.
    package nonisolated static func absentVolume(of path: String,
                                                 exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> String? {
        let parts = path.split(separator: "/")
        guard parts.count >= 3, parts[0] == "Volumes" else { return nil }
        let volume = String(parts[1])
        return exists("/Volumes/\(volume)") ? nil : volume
    }
}
