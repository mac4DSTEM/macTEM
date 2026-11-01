//
//  RunClock.swift
//  Role: the clock of the toolbar's busy line for the spectrum rooms' long work (opening a spectrum image, Quantify, the EELS stages):
//        the time since the room became busy (`AppState.busySince`, set at the busy edge) and, once the work reports a fraction done,
//        an ETA extrapolated linearly from it. `ToolbarRunDisplay` asks once a second. An ETA it cannot yet estimate is absent, never
//        invented (MacEMUI's `OperationMetricsFormat.line`).
//

import Foundation

nonisolated enum RunClock {
    /// Below this fraction done, or this many seconds, the extrapolation is noise: no ETA.
    static let minimumFraction = 0.02
    static let minimumElapsed: TimeInterval = 2

    /// Elapsed since `start` and, with a fraction done in (0, 1), the time left at the rate so far; nil without a start.
    static func reading(since start: Date?, progress: Double?, now: Date) -> (elapsed: TimeInterval, eta: TimeInterval?)? {
        guard let start else { return nil }
        let elapsed = max(0, now.timeIntervalSince(start))
        guard let p = progress, p >= minimumFraction, p < 1, elapsed >= minimumElapsed else { return (elapsed, nil) }
        return (elapsed, elapsed * (1 - p) / p)
    }
}

extension AppState {
    /// A spectrum room's busy edge: the start is set when it becomes busy and kept while it stays busy; idle clears it.
    func markBusy(_ room: WorkspaceArea, _ busy: Bool, now: Date = .now) {
        if !busy {
            busySince[room] = nil
        } else if busySince[room] == nil {
            busySince[room] = now
        }
    }
}
