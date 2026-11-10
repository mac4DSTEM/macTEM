//
//  IndexingSession+Refine.swift
//  Role: the Indexing room's Refine stage (docs/sem/design/indexing-room.md §3, §4; D-SEM-109): Refine › After indexing, what it
//        moves and its trust region; the refinement of the Dictionary run, block of rows by block off the main actor with
//        `IndexingRefinement.refine` (kikuchipy's refine_*), each block landing in order on a copy of the run kept beside it
//        (`refinedRun`) if no newer run started (`runGeneration`), so the map fills row by row and Stop keeps the refined rows.
//

import Foundation
import TEMCore

extension IndexingSession {
    /// `Refine › After indexing`: on, Index refines the Dictionary run after it and the room shows the refinement in its place.
    package func setRefinesAfterIndexing(_ on: Bool) {
        guard on != refinesAfterIndexing else { return }
        let before = shownRun?.id
        refinesAfterIndexing = on
        if shownRun?.id != before { shownResultChanged() }
    }

    /// Edits the Refine settings in place (one field). The Dictionary run stays current; its refinement goes stale.
    package func editRefineSettings(_ change: (inout IndexingRefineSettings) -> Void) {
        var edited = refineSettings
        change(&edited)
        guard edited != refineSettings else { return }
        refineSettings = edited
    }

    package func resetRefineSettings() {
        guard refineSettings != .roomDefault else { return }
        refineSettings = .roomDefault
    }

    /// The refinement of the room's Dictionary run, when it holds one.
    package var heldRefinement: IndexingRun? {
        guard let refinedRun, let base = runs[.dictionary], refinedRun.refinement?.base == base.id else { return nil }
        return refinedRun
    }

    /// The refinement shown in the Dictionary run's place: Refine is on and it reached a point (a refinement lands whole rows, so
    /// a row landed is a point reached; `shownRun` reads this on every hover, and `reachedCount` walks the scan).
    package var shownRefinedRun: IndexingRun? {
        guard refinesAfterIndexing, let held = heldRefinement, held.result.rowsDone > 0 else { return nil }
        return held
    }

    /// The refinement held is stale: its Dictionary run was replaced or is stale, or Refine moves something else now.
    package var isRefinementStale: Bool {
        guard let record = refinedRun?.refinement else { return false }
        guard let base = runs[.dictionary], base.id == record.base else { return true }
        return isStale(of: .dictionary) || !record.settings.refinesAlike(refineSettings)
    }

    /// Why Refine cannot run (the Refine section's warning; the verb's while Refine is on); nil when it can.
    package var refineRefusal: String? {
        if let why = refineSettings.refusal { return why }
        guard refinesAfterIndexing else { return nil }
        if phasesOn.count > 1 {
            return "Refine one phase at a time: kikuchipy refines each phase against its own master pattern. Turn one phase on, or Refine off."
        }
        return nil
    }

    /// Index refines alone (design §3): the Dictionary run is current and complete, and its refinement is missing, stale, stopped
    /// or incomplete.
    var refinesAlone: Bool {
        guard let base = runs[.dictionary], !isStale(of: .dictionary), base.result.isComplete, !base.wasStopped else { return false }
        guard let held = heldRefinement else { return true }
        return isRefinementStale || held.wasStopped || !held.result.isComplete
    }

    /// The inspector's numbers: the mean score over the refined points as indexed (in the run's metric) and as refined (NCC), kept
    /// as the blocks land (the inspector's body reads them on every render).
    package var refinementScores: (before: Double, after: Double, metric: String)? {
        guard let held = heldRefinement, let base = runs[.dictionary], let s = held.refinement?.scores.means else { return nil }
        return (s.before, s.after, base.result.scoreTitle)
    }

    /// The refined PCs' mean and standard deviation (Bruker), kept as the blocks land; nil while the PC is held or none landed.
    package var refinedProjectionCentre: (mean: SIMD3<Double>, deviation: SIMD3<Double>)? {
        heldRefinement?.refinement?.projectionCentre
    }

    /// Why the Refine stage cannot refine the Dictionary run now (the Output line when Index → Refine skips it); nil when it can.
    var refineStageRefusal: String? {
        if let why = refineRefusal { return why }
        guard let base = runs[.dictionary], base.result.isComplete else {
            return "Refine refines a complete Dictionary run: Index with Dictionary first."
        }
        guard base.dictionaryPlans.count == 1 else {
            return "Refine one phase at a time: the Dictionary run indexed against \(base.result.phases.count) phases."
        }
        return nil
    }

    /// The Refine stage: the Dictionary run's indexed rows refined block by block against its master pattern on its detector, with
    /// its signal mask. nil when the Dictionary run cannot be refined (`refineStageRefusal`). The returned task ends when the
    /// refinement has landed (or was stopped or failed).
    @discardableResult
    func refineDictionaryRun() -> Task<Void, Never>? {
        guard refineStageRefusal == nil, let base = runs[.dictionary], let plan = base.dictionaryPlans.first else { return nil }
        let settings = refineSettings
        runTask?.cancel()
        runGeneration += 1
        let run = runGeneration
        var refined = IndexingRun(id: run, result: IndexingResult(refining: base.result), inputs: base.inputs, source: base.source,
                                  projectionCenter: base.projectionCenter)
        refined.dictionaryPlans = base.dictionaryPlans
        refined.refinement = IndexingRefinementRecord(base: base.id, settings: settings)
        refinedRun = refined
        isIndexing = true; isRefining = true; runningMethod = .dictionary
        progress = 0; chunksDone = 0; chunksTotal = 0; chunkPhase = nil
        shownResultChanged()   // the refinement comes on screen, empty, and fills row by row
        onEvent?("Refining \(base.result.indexedCount) patterns against the \(plan.phase.name) master pattern (\(settings.words))…")
        let indexed = base.result
        let blocks = IndexingRefinement.blocks(rows: indexed.rowsDone, columns: indexed.scanColumns, limit: plan.rowsPerBlock)
        let isFloat32 = IndexingRefinement.isFloat32(plan.source)
        let started = Date()
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            // Stop cancels this task; the handler raises the flag the solver asks on its worker threads (no task runs there, so
            // `Task.isCancelled` stays false: CancellationFlag.swift).
            let stopped = CancellationFlag()
            do {
                let master = try EBSDRefinement.Master(plan.master.master, energy: plan.energy)
                for rows in blocks {
                    try Task.checkCancellation()
                    let experimental = try await plan.readBlock(rows)
                    let block = try await withTaskCancellationHandler {
                        try IndexingRefinement.refine(indexed, rows: rows, experimental: experimental, isFloat32: isFloat32,
                                                      detector: plan.detector, master: master, signalMask: plan.options.signalMask,
                                                      settings: settings, isCancelled: { stopped.isRaised })
                    } onCancel: {
                        stopped.raise()
                    }
                    await self?.landRefined(block, run: run)
                }
                await self?.finish(seconds: Date().timeIntervalSince(started), failure: nil, run: run)
            } catch is CancellationError {
                return
            } catch {
                let words = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                await self?.finish(seconds: 0, failure: words, run: run)
            }
        }
        runTask = task
        return Task { await task.value }
    }

    /// A refined block lands, in order, if it is the run in flight's (never after Stop): the map repaints its rows, the inspector's
    /// mean scores and PC follow, the best match too. Package-visible so a test can deliver a block late.
    package func landRefined(_ block: IndexingRefinedBlock, run: Int) {
        guard run == runGeneration, isIndexing, isRefining, let before = refinedRun?.result.rowsDone,
              let base = runs[.dictionary], base.id == refinedRun?.refinement?.base else { return }
        // In place: a copy of the run would copy the whole scan's solutions for every block.
        refinedRun?.result.landRefined(block)
        guard let landed = refinedRun?.result, landed.rowsDone > before else { return }
        refinedRun?.refinement?.scores.add(base: base.result, refined: landed, rows: block.rows)
        if !block.projectionCenters.isEmpty {
            refinedRun?.refinement?.projectionCentre = IndexingRefinement.meanAndDeviation(landed.refinedProjectionCenters)
        }
        progress = Double(block.rows.upperBound) / Double(max(refinedRun?.result.scanRows ?? 1, 1))
        repaint(rows: block.rows)
        if let row = patternPosition?.row, block.rows.contains(row) { showBestMatch() }
    }
}
