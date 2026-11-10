//
//  SessionEventSpeech.swift
//  Role: what VoiceOver hears of the rooms' runs. The sessions' event lines (a file opened, a run that landed, stopped, was refused
//        or failed) went only to the infobar, which VoiceOver does not read out, so a long indexing run or an EELS fit ended in
//        silence. `AppState` sends every session's line through `report(event:in:)`: the infobar and the Output pane as before, the
//        SEM rooms' lines to the session record, and the line that ends something to VoiceOver, as an export's line is
//        (`ExportPanels.announcement`). Which lines are spoken is pure (`SessionEventSpeech`), so a test pins it.
//

import SwiftUI

/// The rule, pure so a test pins it.
nonisolated enum SessionEventSpeech {
    /// Whether VoiceOver hears `line`: every event but an empty line and a run's start line ("Opening scan.h5…", "Indexing 4125
    /// patterns with Hough (Ni)…"), whose outcome the line that ends the run says ("Opened …", "Indexed …", "Stopped …",
    /// "Refused: …", "Error: …"). The same rule as the lines the session record keeps (`SEMSessionRecord.note`).
    static func announces(_ line: String) -> Bool {
        !line.isEmpty && !line.hasSuffix("\u{2026}")
    }
}

extension AppState {
    /// A session's event `line`: the infobar's line and so an Output line (`statusText`), the SEM room's line for the session report
    /// (`semRecord`; `room` is nil for the spectrum rooms), and the same words to VoiceOver when the line ends something
    /// (`SessionEventSpeech`): a status that appears in the infobar is not spoken.
    func report(event line: String, in room: SEMSessionRecord.Room?) {
        statusText = line
        if let room { semRecord.note(line, in: room) }
        if SessionEventSpeech.announces(line) {
            AccessibilityNotification.Announcement(ExportPanels.announcement(line)).post()
        }
    }
}
