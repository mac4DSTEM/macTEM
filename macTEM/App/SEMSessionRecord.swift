//
//  SEMSessionRecord.swift
//  Role: what the window's SEM session did that no room keeps (D-SEM-104): every file the Patterns, Indexing and Maps rooms wrote,
//        with its bytes when it is a picture, and each room's Output lines with the moment each was logged. The rooms keep only their
//        current state and the last export's bytes; the Results room's session rows and the session report read the rest here
//        (`SEMSessionLedger`). Window-wide and not saved, as the rooms' sessions are; composed by `AppState`, which tells it of every
//        export (the room states' `onWritten`) and every line (the sessions' `onEvent`).
//
//        Nothing is recomputed from it: a line is the room's own words, an export the bytes the room wrote.
//

import Foundation
import Observation
import TEMCore

@Observable
final class SEMSessionRecord {
    /// The rooms whose lines are kept.
    enum Room: String, CaseIterable {
        case patterns, indexing, maps
    }

    /// Every file a SEM room wrote this session, in the order written.
    private(set) var exports: [SEMExportedFile] = []
    /// Each room's Output lines, in the order logged.
    private(set) var lines: [Room: [SEMLogLine]] = [:]

    /// A room wrote a file.
    func wrote(_ file: SEMExportedFile) {
        exports.append(file)
    }

    /// A room logged `text` (an empty line and the "…ing" lines of a run in flight are not kept: the line that ends the run says it).
    func note(_ text: String, in room: Room, at time: Date = Date()) {
        guard !text.isEmpty, !text.hasSuffix("\u{2026}") else { return }
        lines[room, default: []].append(SEMLogLine(time: time, text: text))
    }

    /// The room's lines, in order.
    func lines(of room: Room) -> [SEMLogLine] { lines[room] ?? [] }

    /// The room's lines since the last one that starts with `prefix` (that line included), or all of them when none does: the lines
    /// of the dataset open now, from its "Opened …" line.
    func lines(of room: Room, sinceLastStartingWith prefix: String) -> [SEMLogLine] {
        let all = lines(of: room)
        guard let start = all.lastIndex(where: { $0.text.hasPrefix(prefix) }) else { return all }
        return Array(all[start...])
    }

    /// The last line of the room that starts with `prefix`.
    func lastLine(of room: Room, startingWith prefix: String) -> SEMLogLine? {
        lines(of: room).last { $0.text.hasPrefix(prefix) }
    }
}
