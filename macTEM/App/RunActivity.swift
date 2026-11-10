//
//  RunActivity.swift
//  Role: keeps the Mac working at full speed while a room works. A minutes-long Process, Index, Segment, texture or fit in an
//        app that is hidden, occluded or left alone was eligible for App Nap and idle sleep, which slow or pause it. While any
//        room has a run in flight (`AppState.busyRooms`, the rooms quitting would end) the app holds one `ProcessInfo` activity
//        (`.userInitiated`, which keeps idle system sleep off), begun when the first run starts and ended when the last one lands,
//        stops or fails. The watch is the window's `AppState`, not a view: the state outlives a closed window (ADR 007), and so do
//        its runs. mac4DSTEM holds the same activity for its long replay (`ReplayRun`).
//

import Foundation
import Observation

/// One activity held while asked, begun and ended through injected closures (`ProcessInfo`'s by default), so a test counts them.
final class RunActivity {
    private let begin: () -> any NSObjectProtocol
    private let end: (any NSObjectProtocol) -> Void
    private var token: (any NSObjectProtocol)?

    init(begin: @escaping () -> any NSObjectProtocol = {
             ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason: "macTEM is running an analysis")
         },
         end: @escaping (any NSObjectProtocol) -> Void = { ProcessInfo.processInfo.endActivity($0) }) {
        self.begin = begin
        self.end = end
    }

    /// Whether the activity is held now.
    var isHeld: Bool { token != nil }

    /// Holds the activity while `working` and lets it go otherwise; asked again for the same, it changes nothing, so one stretch of
    /// work holds exactly one activity.
    func hold(_ working: Bool) {
        if working {
            if token == nil { token = begin() }
        } else if let held = token {
            token = nil
            end(held)
        }
    }
}

extension AppState {
    /// Holds `runActivity` while any room works, and watches for the next change: observation tracking fires once, before the
    /// change, so the new state is read on the main actor after it and the watch is armed again there.
    func holdActivityWhileRoomsWork() {
        let working = withObservationTracking({ !busyRooms.isEmpty }, onChange: { [weak self] in
            Task { @MainActor in self?.holdActivityWhileRoomsWork() }
        })
        runActivity.hold(working)
    }
}
