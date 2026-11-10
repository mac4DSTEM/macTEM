//
//  LastSession.swift
//  Role: File > Reopen Last Session's record: the files the window had open when it was last used, in order, each with the
//        security-scoped bookmark that opens it again, which one was selected and the room shown, kept from one launch to the next.
//        mac4DSTEM's recovery record (`DatasetRecoveryRecord`, mac4DSTEM/Session/WorkspaceRecovery.swift), for a window of many
//        files: one record, saved as a unit, so it is its own owner, not `AppState`'s.
//
//        Saving is injected, as `RecentFiles`' is. The app passes the record kept in UserDefaults (`stored()`); a bare
//        `LastSession()` keeps it in memory and writes nothing, which is what a test and a UI-testing launch get. The previous
//        launch's record is only read here and offered by the menu, never opened at launch: a mapped multi-GB file must not load
//        before the person asks.
//

import Foundation
import Observation

/// What the window had open: the files (each with the bookmark that opens it again) in the order of the Open Files list and then
/// the rooms' own documents, the selected file's path, and the room shown (`WorkspaceArea`'s raw value).
package nonisolated struct LastSessionRecord: Codable, Equatable, Sendable {
    package var files: [RecentFile]
    /// The selected file's path, one of `files`; nil when the selected file is not among them.
    package var selectedPath: String?
    package var room: String

    package init(files: [RecentFile], selectedPath: String?, room: String) {
        self.files = files
        self.selectedPath = selectedPath
        self.room = room
    }
}

@Observable
package final class LastSession {
    /// The record the previous launch left: what File > Reopen Last Session opens. Read once, at the init; nil when there is none,
    /// and once every file of it is gone (`forgetPrevious`).
    package private(set) var previous: LastSessionRecord?
    /// This launch's record as last saved; nil until a file with a bookmark is open.
    @ObservationIgnored package private(set) var current: LastSessionRecord?

    /// Where `stored()` keeps the record.
    package nonisolated static let defaultsKey = "last.session.v1"

    /// The files taken in this launch, by their standardised path, with the bookmark made in their scope.
    @ObservationIgnored private var taken: [String: RecentFile] = [:]
    private let persist: (LastSessionRecord) -> Void

    /// `previous` as saved, and `persist`, told every new record. The defaults keep it in memory only.
    package init(previous: LastSessionRecord? = nil, persist: @escaping (LastSessionRecord) -> Void = { _ in }) {
        self.previous = previous
        self.persist = persist
    }

    /// The app's record: the previous launch's read from `defaults`, every new one written back. A test passes defaults of its own,
    /// never the standard ones.
    package static func stored(in defaults: UserDefaults = .standard) -> LastSession {
        let saved = defaults.data(forKey: LastSession.defaultsKey).flatMap { try? JSONDecoder().decode(LastSessionRecord.self, from: $0) }
        return LastSession(previous: saved) { record in
            if let data = try? JSONEncoder().encode(record) { defaults.set(data, forKey: LastSession.defaultsKey) }
        }
    }

    /// A file the window took in, with the bookmark made in its scope: only such files are recorded (a demo made in memory has none).
    package func remember(_ file: RecentFile) {
        taken[Self.key(URL(fileURLWithPath: file.path))] = file
    }

    /// The record of what is open now: `urls` in order (a file named twice counts once), the selected one and the room. A file
    /// taken in without a bookmark is left out. An open set with no such file changes nothing, so the last files open stay the record
    /// (mac4DSTEM keeps its last dataset's when it closes); a record is saved only when it differs from the last one.
    package func update(open urls: [URL], selected: URL?, room: String) {
        let selectedKey = selected.map { Self.key($0) }
        var seen = Set<String>()
        var files: [RecentFile] = []
        var selectedPath: String?
        for url in urls {
            let key = Self.key(url)
            guard seen.insert(key).inserted, let file = taken[key] else { continue }
            files.append(file)
            if key == selectedKey { selectedPath = file.path }
        }
        guard !files.isEmpty else { return }
        let record = LastSessionRecord(files: files, selectedPath: selectedPath, room: room)
        guard record != current else { return }
        current = record
        persist(record)
    }

    /// The previous launch's record could open none of its files: the menu stops offering it.
    package func forgetPrevious() {
        previous = nil
    }

    /// The path a file is known by here: the URL's, standardised (no file system call, so a disk that is not connected is never asked).
    private nonisolated static func key(_ url: URL) -> String {
        url.standardizedFileURL.path
    }
}
