//
//  IndexingRun.swift
//  Role: one run of the Indexing room as the room keeps it (D-SEM-97): its result, filled row by row (Hough) or block by block
//        (dictionary), what it was made of (its inputs stale it when the room's differ), where it read its patterns, its projection
//        centre, its time or that it was stopped, and its method's plan (Hough's libraries for the Bands table's families and the .ang,
//        each phase's dictionary plan, its master pattern, orientations and detector, for Info, Best match and the method record,
//        D-SEM-98). The room keeps the last run of each method (`IndexingSession.runs`), so a Dictionary run leaves the Hough one, its
//        map, exports and Maps' view of it, as it was; Compare (#230) reads two of them side by side.
//

import Foundation
import TEMCore

package nonisolated struct IndexingRun: Sendable {
    /// The room's run number when it started (`IndexingSession.runGeneration`): the Maps room and Compare name a run by it.
    package let id: Int
    package internal(set) var result: IndexingResult
    /// What the run was made of: it is stale once the room's inputs for its method differ.
    package let inputs: IndexingInputs
    package let source: IndexingSource.Kind
    /// The mean projection centre of the dataset's detector the run indexed with (the simulation overlay draws with it).
    package let projectionCenter: SIMD3<Double>?
    /// The run's time once it completed; nil while it runs, after a stop or a failure.
    package internal(set) var seconds: Double?
    /// The run was stopped: its indexed rows stay, the rest of the map shows the navigator.
    package internal(set) var wasStopped = false
    /// A Hough run's libraries once built (the Bands table's families, the .ang's phases, the method record).
    package internal(set) var houghPlan: IndexingPlan?
    /// A dictionary run's plans once built, one per phase it indexed against in `result.phases` order (D-SEM-98): each phase's master
    /// pattern, orientations, detector and energy. Empty before they are built and for Hough.
    package internal(set) var dictionaryPlans: [DictionaryIndexingPlan] = []

    package init(id: Int, result: IndexingResult, inputs: IndexingInputs, source: IndexingSource.Kind, projectionCenter: SIMD3<Double>?) {
        self.id = id
        self.result = result
        self.inputs = inputs
        self.source = source
        self.projectionCenter = projectionCenter
    }

    package var method: IndexingMethod { result.method }
}
