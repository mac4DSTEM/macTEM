//
//  SessionEventSpeech.swift
//  Role: what VoiceOver hears of the rooms' runs. The sessions' event lines (a file opened, a run that landed, stopped, was refused
//        or failed) went only to the infobar, which VoiceOver does not read out, so a long indexing run or an EELS fit ended in
//        silence. `AppState` sends every session's line through `report(event:in:)`: the infobar and the Output pane as before, the
//        SEM rooms' lines to the session record, and the line that ends something to VoiceOver. Which lines are spoken is pure
//        (`SessionEventSpeech`), so a test pins it. They are posted at default priority, as mac4DSTEM's announcements are (`announcing`):
//        a run ends while the person works, so its line may be cut by what they do next. An export's or a save's line is posted as its
//        sheet goes away and needs high priority to be heard over the focus coming back; that one stays `ExportPanels.announcement`.
//

import SwiftUI

/// The rule, pure so a test pins it.
nonisolated enum SessionEventSpeech {
    /// Whether VoiceOver hears `line`: every event but an empty line and a run's start line ("Opening scan.h5…", "Indexing 4125
    /// patterns with Hough (Ni)…"), whose outcome the line that ends the run says ("Opened …", "Indexed …", "Stopped …",
    /// "Refused: …", "Error: …"). The same rule as the lines the session record keeps (`SEMSessionRecord.note`), but for a line
    /// whose failure the window also shows as an alert (`alertedPrefix`): the record keeps it, and VoiceOver reads the alert.
    static func announces(_ line: String) -> Bool {
        !line.isEmpty && !line.hasSuffix("\u{2026}") && !line.hasPrefix(alertedPrefix)
    }

    /// How the line of a failure starts that the session sends to the alert as well ("Master pattern: x.h5 is not an EMsoft master
    /// pattern file.", `IndexingSession.openMasterPattern`). VoiceOver reads an alert as it opens, so the line spoken too said the
    /// failure twice, and the alert's own speech waited behind it.
    static let alertedPrefix = "Master pattern: "
}

extension AppState {
    /// A session's event `line`: the infobar's line and so an Output line (`statusText`), the SEM room's line for the session report
    /// (`semRecord`; `room` is nil for the spectrum rooms), and the same words to VoiceOver when the line ends something
    /// (`SessionEventSpeech`): a status that appears in the infobar is not spoken. Default priority (the header says why).
    func report(event line: String, in room: SEMSessionRecord.Room?) {
        statusText = line
        if let room { semRecord.note(line, in: room) }
        if SessionEventSpeech.announces(line) {
            AccessibilityNotification.Announcement(line).post()
        }
    }
}
