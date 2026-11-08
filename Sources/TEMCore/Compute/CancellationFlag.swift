//
//  CancellationFlag.swift
//  Role: Stop's reach into work that runs on `DispatchQueue.concurrentPerform`'s worker threads (NLPAR's tile averages). Those threads
//        run no task, so `Task.isCancelled` is false there even after the task that started the work was cancelled; the task's
//        `withTaskCancellationHandler` raises this flag instead, and the work asks the flag between rows.
//

import Synchronization

/// A one-way flag: lowered at first, raised once, read from any thread.
package nonisolated final class CancellationFlag: Sendable {
    private let state: Mutex<Bool>

    package init() {
        state = Mutex(false)
    }

    /// Whether the flag was raised.
    package var isRaised: Bool { state.withLock { $0 } }

    /// Raises the flag; it stays raised.
    package func raise() {
        state.withLock { $0 = true }
    }
}
