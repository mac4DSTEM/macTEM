//
//  ScanRowWork.swift
//  Role: the patterns of one scan row worked on every core (`DispatchQueue.concurrentPerform`). A pass over an EBSD scan reads its rows
//        one after another (a file's slabs are read in turn, never side by side), but the patterns of a row do not depend on each other:
//        Process's per-pattern stages, the indexer's streamed patterns, the image quality and the virtual BSE sums each run the same
//        function on each pattern. Each result lands in its column's slot and the row comes back in column order, so the output is the
//        serial loop's, byte for byte. No numerics here.
//

import Foundation

package nonisolated enum ScanRowWork {
    /// `work(column)` for every column 0..<columns of one scan row, on all cores; the results in column order. When columns throw, the
    /// error of the lowest one is thrown after the pass (the one a serial loop over the row stops at), and a column after a column that
    /// has already failed is not started.
    package static func map<T: Sendable>(columns: Int, _ work: @Sendable (_ column: Int) throws -> T) throws -> [T] {
        let slots = ColumnSlots<T>(count: columns)
        DispatchQueue.concurrentPerform(iterations: columns) { column in
            if slots.hasFailed(before: column) { return }
            do {
                slots.set(column, try work(column))
            } catch {
                slots.fail(column, error)
            }
        }
        return try slots.results()
    }
}

/// One row's results written from many threads, each to its own column's slot, and the lowest column's error; behind the lock, hence
/// unchecked.
private nonisolated final class ColumnSlots<T: Sendable>: @unchecked Sendable {
    private var slots: [T?]
    private var firstFailure: (column: Int, error: any Error)?
    private let lock = NSLock()

    init(count: Int) {
        slots = [T?](repeating: nil, count: count)
    }

    func set(_ column: Int, _ value: T) {
        lock.withLock { slots[column] = value }
    }

    func fail(_ column: Int, _ error: any Error) {
        lock.withLock { () -> Void in
            if let first = firstFailure, first.column < column { return }
            firstFailure = (column: column, error: error)
        }
    }

    func hasFailed(before column: Int) -> Bool {
        lock.withLock { () -> Bool in
            guard let first = firstFailure else { return false }
            return first.column < column
        }
    }

    func results() throws -> [T] {
        try lock.withLock { () throws -> [T] in
            if let first = firstFailure { throw first.error }
            // Every slot was filled: no failure was recorded, so each row ran to its end.
            return slots.compactMap { $0 }
        }
    }
}
