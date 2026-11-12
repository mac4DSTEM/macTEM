//
//  CubeHandoff.swift
//  Role: hands a spectrum image (or any large value) to a background task without the task's closure keeping it. A closure that
//        captures a cube by value holds it for as long as the closure's context lives, and a finished pass's context outlived the
//        pass: after Align the room held the file's low-loss and core-loss cubes beside the aligned ones (12 Nov memgraph on the
//        145_STEM spectrum image, 2.9 GB where 1.45 GB was due, macTEM#571). The closure captures this box instead; the task takes the
//        value out as it starts, so whatever keeps the context afterwards keeps an empty box.
//

import Foundation
import Synchronization

/// One value, taken once.
package final class CubeHandoff<Value: Sendable>: Sendable {
    private let slot: Mutex<Value?>

    package init(_ value: Value) { slot = Mutex(value) }

    /// The value, the first time; nil after.
    package func take() -> Value? { slot.withLock { $0.take() } }

    /// Whether the value is still in the box (a test's question).
    package var isEmpty: Bool { slot.withLock { $0 == nil } }
}
