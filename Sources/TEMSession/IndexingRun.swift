//
//  IndexingRun.swift
//  Role: one run of the Indexing room as the room keeps it (D-SEM-97): its result, filled row by row (Hough) or block by block
//        (dictionary), what it was made of (its inputs stale it when the room's differ), where it read its patterns, its projection
//        centre, its time or that it was stopped, and its method's plan (Hough's libraries for the Bands table's families and the .ang,
//        each phase's dictionary plan, its master pattern, orientations and detector, for Info, Best match and the method record,
//        D-SEM-98). The room keeps the last run of each method (`IndexingSession.runs`), so a Dictionary run leaves the Hough one, its
//        map, exports and Maps' view of it, as it was; Compare (#230) reads two of them side by side. A refinement of the Dictionary
//        run is a run too, with the record of what it refined, kept beside it (`IndexingSession.refinedRun`, D-SEM-109).
//

import Foundation
import TEMCore

/// What a refinement refined (D-SEM-109): the Dictionary run (its id) and the settings, with the inspector's numbers kept as the
/// blocks land (the refined PCs themselves are the result's, `IndexingResult.projectionCenters`).
package nonisolated struct IndexingRefinementRecord: Sendable {
    package let base: Int
    package let settings: IndexingRefineSettings
    /// The mean score over the refined points before and after, summed block by block.
    package internal(set) var scores = IndexingRefinementScores()
    /// The refined PCs' mean and standard deviation (Bruker), made when a block with PCs lands; nil while the PC is held.
    package internal(set) var projectionCentre: (mean: SIMD3<Double>, deviation: SIMD3<Double>)?

    package init(base: Int, settings: IndexingRefineSettings) {
        self.base = base
        self.settings = settings
    }
}

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
    /// A Hough run's libraries once built (the Bands table's families, the .ang's phases, the method record); without the patterns
    /// once the run has ended (`releasePatterns()`).
    package internal(set) var houghPlan: IndexingPlan?
    /// A dictionary run's plans once built, one per phase it indexed against in `result.phases` order (D-SEM-98): each phase's master
    /// pattern, orientations, detector and energy; without the patterns once the run has ended. Empty before they are built and for
    /// Hough.
    package internal(set) var dictionaryPlans: [DictionaryIndexingPlan] = []
    /// A refinement's record (the Dictionary run it refined, its settings, its PCs; D-SEM-109); nil for a run as indexed.
    package internal(set) var refinement: IndexingRefinementRecord?

    package init(id: Int, result: IndexingResult, inputs: IndexingInputs, source: IndexingSource.Kind, projectionCenter: SIMD3<Double>?) {
        self.id = id
        self.result = result
        self.inputs = inputs
        self.source = source
        self.projectionCenter = projectionCenter
    }

    package var method: IndexingMethod { result.method }

    /// The plans let go of the patterns they read (#427): once the run has ended nothing reads them, and the Patterns room's
    /// processed scan they held would stay in memory beside a newer one.
    package mutating func releasePatterns() {
        houghPlan?.releasePatterns()
        for i in dictionaryPlans.indices { dictionaryPlans[i].releasePatterns() }
    }

    /// "Hough", "Dictionary", "Dictionary · Refined".
    package var title: String { refinement == nil ? method.title : "\(method.title) · Refined" }
}
