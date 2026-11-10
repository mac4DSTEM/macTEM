//
//  IndexingRefinement.swift
//  Role: the Indexing room's Refine stage (docs/sem/design/indexing-room.md §3, §4; D-SEM-109): its settings, and one block of a
//        dictionary run's rows refined against the run's master pattern with EBSDRefinement's pattern-level calls (kikuchipy 0.13.1
//        refine_orientation, refine_projection_center, refine_orientation_projection_center; SciPy Nelder-Mead). Nothing here
//        makes a new number: every value is EBSDRefinement's.
//

import Foundation
import FormatoCore

/// What Refine moves and its trust region (kikuchipy's `trust_region`), with the one solver ported (D-SEM-86) at SciPy's defaults.
package nonisolated struct IndexingRefineSettings: Sendable, Equatable {
    package enum Target: String, Sendable, CaseIterable, Identifiable {
        case orientation, projectionCenter, both

        package var id: String { rawValue }

        /// The segmented control's word.
        package var title: String {
            switch self {
            case .orientation: "Orientation"
            case .projectionCenter: "PC"
            case .both: "Both"
            }
        }

        /// What is refined, in a sentence: "Refine the orientations of …".
        package var noun: String {
            switch self {
            case .orientation: "orientations"
            case .projectionCenter: "projection centres"
            case .both: "orientations and projection centres"
            }
        }

        /// kikuchipy's call.
        package var call: String {
            switch self {
            case .orientation: "EBSD.refine_orientation"
            case .projectionCenter: "EBSD.refine_projection_center"
            case .both: "EBSD.refine_orientation_projection_center"
            }
        }

        package var help: String {
            switch self {
            case .orientation: "kikuchipy's refine_orientation: each point's Euler angles move, the PC is held"
            case .projectionCenter: "kikuchipy's refine_projection_center: each point's PC moves, its orientation is held"
            case .both: "kikuchipy's refine_orientation_projection_center: the Euler angles and the PC move together"
            }
        }
    }

    package var target: Target
    /// ± around each indexed Euler angle, degrees.
    package var trustAngle: Double
    /// ± around each of PCx, PCy, PCz (Bruker fractions).
    package var trustPC: Double

    package init(target: Target = .orientation, trustAngle: Double = 2, trustPC: Double = 0.05) {
        self.target = target; self.trustAngle = trustAngle; self.trustPC = trustPC
    }

    /// kikuchipy's pattern-matching tutorial's trust region (refine_orientation_projection_center: [2, 2, 2, 0.05, 0.05, 0.05]).
    package static let roomDefault = IndexingRefineSettings()

    /// kikuchipy's trust_region for the target: three angles, three PC values, or six.
    package var trustRegion: [Double] {
        switch target {
        case .orientation: [trustAngle, trustAngle, trustAngle]
        case .projectionCenter: [trustPC, trustPC, trustPC]
        case .both: [trustAngle, trustAngle, trustAngle, trustPC, trustPC, trustPC]
        }
    }

    /// Two settings make the same refinement (an unused field's edit does not stale one).
    package func refinesAlike(_ other: Self) -> Bool { target == other.target && trustRegion == other.trustRegion }

    /// The solver's settings: the trust region, the dictionary's signal mask (true excluded), SciPy's Nelder-Mead defaults.
    package func solver(signalMask: [Bool]?) -> EBSDRefinement.Settings {
        EBSDRefinement.Settings(trustRegion: trustRegion, signalMask: signalMask)
    }

    /// Why these settings cannot refine, in the room's words; nil when they can. A field the target does not use is not checked.
    package var refusal: String? {
        if target != .projectionCenter, !(trustAngle.isFinite && trustAngle > 0 && trustAngle <= 180) {
            return "The orientation trust region is an angle above 0° and up to 180°."
        }
        if target != .orientation, !(trustPC.isFinite && trustPC > 0 && trustPC <= 1) {
            return "The PC trust region is a fraction above 0 and up to 1."
        }
        return nil
    }

    /// "Orientation · ±2° · Nelder–Mead": Output, Info and the ledger.
    package var words: String {
        let f = { (v: Double) in v.formatted(.number.precision(.significantDigits(1...3))) }
        let bounds = switch target {
        case .orientation: "±\(f(trustAngle))°"
        case .projectionCenter: "PC ±\(f(trustPC))"
        case .both: "±\(f(trustAngle))° · PC ±\(f(trustPC))"
        }
        return "\(target.title) · \(bounds) · Nelder–Mead"
    }
}

/// One block of rows refined: the block's solutions (refined points' rotation and NCC, the others as indexed), num_evals per
/// point (0 where not refined), and each point's refined PC (Bruker) in map order, NaN where not refined (empty while the PC is
/// held).
package nonisolated struct IndexingRefinedBlock: Sendable {
    package var rows: Range<Int>
    package var solutions: [HoughIndexer.Solution]
    package var evaluations: [Int]
    package var projectionCenters: [SIMD3<Double>]

    package init(rows: Range<Int>, solutions: [HoughIndexer.Solution], evaluations: [Int], projectionCenters: [SIMD3<Double>] = []) {
        self.rows = rows; self.solutions = solutions; self.evaluations = evaluations; self.projectionCenters = projectionCenters
    }
}

/// The mean score over a refinement's refined points, before (the Dictionary run's, in its metric) and after (NCC), summed row
/// block by row block as the blocks land, in map order (so the means are `IndexingRefinement.meanScores`' to the bit).
package nonisolated struct IndexingRefinementScores: Sendable, Equatable {
    private var before = 0.0, after = 0.0, count = 0

    package init() {}

    /// Adds the points of `rows` that `refined` refined (indexed, a finite score in both runs).
    package mutating func add(base: IndexingResult, refined: IndexingResult, rows: Range<Int>) {
        guard base.pointCount == refined.pointCount else { return }
        let columns = refined.scanColumns
        let end = min(rows.upperBound, base.rowsDone, refined.rowsDone) * columns
        for i in (rows.lowerBound * columns)..<max(end, rows.lowerBound * columns) {
            guard let r = refined.solutions[i], r.phase >= 0, r.confidence.isFinite,
                  let b = base.solutions[i], b.confidence.isFinite else { continue }
            before += b.confidence
            after += r.confidence
            count += 1
        }
    }

    /// The means; nil before a refined point landed.
    package var means: (before: Double, after: Double)? {
        count == 0 ? nil : (before / Double(count), after / Double(count))
    }
}

package nonisolated enum IndexingRefinement {
    /// Rows a refinement lands at once: about 512 patterns (several per core, so Stop loses at most one block and the toolbar counts
    /// rows), never more than the dictionary's own block (`DictionaryIndexingPlan.rowsPerBlock`, its memory budget).
    package static func blocks(rows: Int, columns: Int, limit: Int) -> [Range<Int>] {
        let per = max(1, min(max(limit, 1), 512 / max(columns, 1)))
        return stride(from: 0, to: rows, by: per).map { $0 ..< min($0 + per, rows) }
    }

    /// Whether the source's patterns are float32 data (kikuchipy then rescales each to −1 … 1): the pipeline's output type
    /// (float32 under Normalise or NLPAR, `PatternPipeline.outputType`), else the stored or processed scan's own type.
    package static func isFloat32(_ source: IndexingSource) -> Bool {
        let stored = source.access.dataset.dataType
        return (source.pipeline?.outputType(stored) ?? stored) == .float32
    }

    /// Rows `rows` of `result` (a dictionary run against one phase) refined. `experimental` holds those rows' patterns as
    /// `DictionaryIndexingPlan.readBlock` reads them. The detector is the run's plan's (one mean PC). `isCancelled` is asked once per
    /// pattern, on the solver's worker threads.
    package static func refine(_ result: IndexingResult, rows: Range<Int>, experimental: [Double], isFloat32: Bool,
                               detector: EBSDDetectorGeometry, master: EBSDRefinement.Master, signalMask: [Bool]?,
                               settings: IndexingRefineSettings, isCancelled: @Sendable () -> Bool = { false }) throws -> IndexingRefinedBlock {
        let columns = result.scanColumns, pixels = detector.rows * detector.columns
        guard rows.lowerBound >= 0, rows.upperBound <= result.rowsDone,
              experimental.count == rows.count * columns * pixels else { throw EBSDRefinement.Error.detectorShape }
        let start = rows.lowerBound * columns
        var block = (0..<(rows.count * columns)).map { result.solutions[start + $0] ?? HoughIndexer.Solution() }
        var evaluations = [Int](repeating: 0, count: block.count)
        // kikuchipy refines the points in the data that are indexed (`_get_indexed_points_in_data_in_xmap`).
        let points = block.indices.filter { block[$0].phase >= 0 }
        guard !points.isEmpty else {
            return IndexingRefinedBlock(rows: rows, solutions: block, evaluations: evaluations, projectionCenters: [])
        }
        var values = [Float]()
        values.reserveCapacity(points.count * pixels)
        for p in points { values += experimental[(p * pixels)..<((p + 1) * pixels)].map { Float($0) } }
        let patterns = EBSDRefinement.Patterns(count: points.count, pixels: pixels, values: values, isFloat32: isFloat32)
        let solver = settings.solver(signalMask: signalMask)
        let rotations = points.map { block[$0].quaternion }
        var pcs: [SIMD3<Double>] = []
        // The solver counts the patterns it was given; its errors name the scan point instead.
        func scanPoint(_ k: Int) -> String {
            let i = start + (points.indices.contains(k) ? points[k] : 0)
            return "row \(i / max(columns, 1)), column \(i % max(columns, 1))"
        }
        do {
            switch settings.target {
            case .orientation:
                let res = try EBSDRefinement.refineOrientations(patterns, starts: EBSDRefinement.startingEuler(rotations: rotations),
                                                                detector: detector, master: master, settings: solver, isCancelled: isCancelled)
                for (k, p) in points.enumerated() {
                    block[p].quaternion = RotationConversions.eu2qu(res[k].euler)
                    block[p].confidence = res[k].score
                    evaluations[p] = res[k].evaluations
                }
            case .projectionCenter:
                let res = try EBSDRefinement.refineProjectionCenters(patterns, rotations: rotations, detector: detector, master: master,
                                                                     settings: solver, isCancelled: isCancelled)
                pcs = [SIMD3<Double>](repeating: SIMD3(repeating: .nan), count: block.count)
                for (k, p) in points.enumerated() {
                    block[p].confidence = res[k].score
                    evaluations[p] = res[k].evaluations
                    pcs[p] = res[k].pc
                }
            case .both:
                let res = try EBSDRefinement.refineOrientationsAndProjectionCenters(patterns, starts: EBSDRefinement.startingEuler(rotations: rotations),
                                                                                    detector: detector, master: master, settings: solver,
                                                                                    isCancelled: isCancelled)
                pcs = [SIMD3<Double>](repeating: SIMD3(repeating: .nan), count: block.count)
                for (k, p) in points.enumerated() {
                    block[p].quaternion = RotationConversions.eu2qu(res[k].euler)
                    block[p].confidence = res[k].score
                    evaluations[p] = res[k].evaluations
                    pcs[p] = res[k].pc
                }
            }
        } catch EBSDRefinement.Error.flatPattern(let k) {
            throw IndexingRefusal("The pattern at \(scanPoint(k)) is flat, so it cannot be compared.")
        } catch EBSDRefinement.Error.solver(let k, let text) {
            throw IndexingRefusal("Refining the pattern at \(scanPoint(k)) failed: \(text)")
        }
        return IndexingRefinedBlock(rows: rows, solutions: block, evaluations: evaluations, projectionCenters: pcs)
    }

    /// The mean score over the points `refined` refined: before (`base`'s, in its metric) and after (NCC); nil before one lands.
    package static func meanScores(base: IndexingResult, refined: IndexingResult) -> (before: Double, after: Double)? {
        var scores = IndexingRefinementScores()
        scores.add(base: base, refined: refined, rows: 0..<min(base.rowsDone, refined.rowsDone))
        return scores.means
    }

    /// The mean and numpy's standard deviation (ddof 0) of PCs; nil for none.
    package static func meanAndDeviation(_ pcs: [SIMD3<Double>]) -> (mean: SIMD3<Double>, deviation: SIMD3<Double>)? {
        guard !pcs.isEmpty else { return nil }
        let n = Double(pcs.count)
        let mean = pcs.reduce(SIMD3<Double>(repeating: 0), +) / n
        let variance = pcs.reduce(SIMD3<Double>(repeating: 0)) { $0 + ($1 - mean) * ($1 - mean) } / n
        return (mean, variance.squareRoot())
    }

    private struct Record: Encodable {
        var method, reference, call, solver: String
        var xatol, fatol: Double
        var maxEvaluations: String
        var trustRegion: [Double]
        var signalMask: String
        var energyKeV: Double?
        var projectionCenterStartBruker: [Double]
        var pseudoSymmetryOperators: Int
        var points, refined, rowsRefined: Int
        var meanScoreBefore, meanScoreAfter: Double?
        var projectionCenterMeanBruker, projectionCenterStdBruker: [Double]?
        /// Every refined PC: one per point of the rows refined, in map order, null where the point was not refined; absent while
        /// the PC is held (kikuchipy's refined `EBSDDetector.pc`).
        var projectionCentersBruker: [[Double]?]?
    }

    /// The Dictionary run's method record with the refinement under "refinement" (additive: the dictionary's keys stay): its
    /// settings, the mean scores, and the refined PCs (their mean ± std and every one, `refined.projectionCenters`).
    package static func methodJSON(_ dictionary: Data, settings: IndexingRefineSettings, plan: DictionaryIndexingPlan,
                                   base: IndexingResult, refined: IndexingResult) throws -> Data {
        let scores = meanScores(base: base, refined: refined), spread = meanAndDeviation(refined.refinedProjectionCenters)
        let pc = plan.detector.projectionCenters.first ?? .zero, nm = NelderMead.Options()
        let landed = refined.rowsDone * refined.scanColumns
        let every: [[Double]?]? = refined.projectionCenters.isEmpty ? nil : refined.projectionCenters.prefix(landed).map { p in
            p.x.isFinite ? [p.x, p.y, p.z] : nil
        }
        let record = Record(
            method: "Refinement of each indexed pattern against the master pattern: Nelder–Mead on 1 − NCC within a trust region",
            reference: "kikuchipy 0.13.1 \(settings.target.call)(method=\"minimize\"), SciPy 1.18.1 minimize(method=\"Nelder-Mead\")",
            call: settings.target.call, solver: "Nelder-Mead", xatol: nm.xatol, fatol: nm.fatol, maxEvaluations: "200 × variables",
            trustRegion: settings.trustRegion, signalMask: plan.settings.signalMask.rawValue, energyKeV: plan.energy,
            projectionCenterStartBruker: [pc.x, pc.y, pc.z], pseudoSymmetryOperators: 0, points: refined.pointCount,
            refined: refined.indexedCount, rowsRefined: refined.rowsDone, meanScoreBefore: scores?.before, meanScoreAfter: scores?.after,
            projectionCenterMeanBruker: spread.map { [$0.mean.x, $0.mean.y, $0.mean.z] },
            projectionCenterStdBruker: spread.map { [$0.deviation.x, $0.deviation.y, $0.deviation.z] },
            projectionCentersBruker: every)
        guard var top = try JSONSerialization.jsonObject(with: dictionary) as? [String: Any] else {
            throw IndexingRefusal("The method record is not an object.")
        }
        top["refinement"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(record))
        return try JSONSerialization.data(withJSONObject: top, options: [.prettyPrinted, .sortedKeys])
    }
}
