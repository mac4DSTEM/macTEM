//
//  EBSDRefinement.swift
//  Refinement of indexed EBSD patterns against a master pattern: each pattern's orientation (Bunge Euler angles), its
//  projection centre (Bruker PCx, PCy, PCz) or both, moved by the Nelder-Mead simplex (`NelderMead`) to maximise the
//  normalised cross-correlation (NCC) between the experimental pattern and the pattern projected from the master pattern
//  (Winkelmann et al. 2020, J. Microsc. 277, 79; the kikuchipy paper, Ånes et al. 2020, IOP Conf. Ser.: Mater. Sci. Eng. 891, 012002).
//  A trust region bounds every variable around its start (angles in degrees, PCs as fractions), inside absolute limits
//  (Euler angles −5° to 365° / 185° / 365°, PCs −2 to 2); pseudo-symmetry operators start one extra search from each
//  operator times the start rotation and keep the best.
//  Ported from kikuchipy 0.13.1 (GPL-3.0-or-later, NOTICE): `indexing/_refinement/_refinement.py`
//  (`_refine_orientation`, `_refine_pc`, `_refine_orientation_pc`, `_RefinementSetup.get_bound_constraints`,
//  `compute_refine_*_results`, `_get_master_pattern_data`), `_solvers.py` (`_prepare_pattern`, the three
//  `_refine_*_solver_scipy`), `_objective_functions.py`, `similarity_metrics/_normalized_cross_correlation.py`
//  (`_ncc_single_patterns_1d_float32_exp_centered`), with the default solver, SciPy's `minimize(method="Nelder-Mead")`.
//  NLopt and SciPy's global optimisers are not ported (D-SEM-86). The projection is `MasterPatternProjection`'s; the NCC
//  takes kikuchipy's float32 patterns and sums in float64 (kikuchipy: float32 under numba fastmath), so the simplex walks a
//  path within the tolerances of docs/parity.md "Refinement" (D-SEM-87).
//  Parity: `m4/refine-nickel-block` (north-star figure F10), `m4/nelder-mead`.
//

import Foundation
import Synchronization
import FormatoCore

package nonisolated enum EBSDRefinement {
    package enum Error: Swift.Error, Equatable, Sendable, LocalizedError {
        case patternCount(patterns: Int, starts: Int)
        case detectorShape
        case centreCount(centres: Int, patterns: Int)
        case trustRegion(expected: Int, got: Int)
        case maskSize(mask: Int, pixels: Int)
        case emptyMask
        case noIndexedPoints
        case moreThanOnePhase([String])
        case phaseMismatch(map: String, master: String)
        case solver(Int, String)
        /// A pattern was given no starting orientation.
        case noStart(Int)

        package var errorDescription: String? {
            switch self {
            case .patternCount(let p, let s): return "There are \(p) patterns for \(s) starting points."
            case .detectorShape: return "The patterns do not have the detector's shape."
            case .centreCount(let c, let p): return "The detector has \(c) projection centres for \(p) patterns; give one or one per pattern."
            case .trustRegion(let e, let g): return "The trust region needs \(e) values, not \(g)."
            case .maskSize(let m, let p): return "The signal mask has \(m) pixels; the detector has \(p)."
            case .emptyMask: return "The signal mask leaves no detector pixel to compare."
            case .noIndexedPoints: return "The crystal map has no indexed point to refine."
            case .moreThanOnePhase(let names): return "Refine one phase at a time; the points to refine are \(names.joined(separator: ", "))."
            case .phaseMismatch(let m, let mp): return "The map's phase is \(m) but the master pattern's is \(mp)."
            case .solver(let i, let text): return "Refining pattern \(i) failed: \(text)"
            case .noStart(let i): return "Pattern \(i) has no starting orientation to refine from."
            }
        }
    }

    // MARK: - Inputs

    /// The master pattern as the objective reads it (`_get_master_pattern_data`): both Lambert hemispheres of one energy in
    /// float32, rescaled each to −1 ... 1 when stored in another type (`rescale_intensity`), their side and the Lambert scale.
    package struct Master: Sendable {
        package let upper: [Float]
        package let lower: [Float]
        package let side: Int
        package let scale: Double
        package let phase: EBSDMasterPattern.Phase

        package init(_ master: EBSDMasterPattern, energy: Double? = nil) throws {
            try MasterPatternProjection.checkSuitable(master)
            let (u, l) = try master.hemispheres(energy: energy)
            if master.dataType == .float32 {
                upper = Array(u); lower = Array(l)
            } else {
                upper = Self.rescaled(Array(u)); lower = Self.rescaled(Array(l))
            }
            side = master.side
            scale = Double(master.side - 1) / 2
            phase = master.phase
        }

        /// `rescale_intensity(hemisphere, dtype_out=float32)`: its minimum and maximum to −1 and 1 (`_rescale_with_min_max`
        /// under fastmath: times the reciprocal of the span).
        static func rescaled(_ values: [Float]) -> [Float] {
            guard let lo = values.min(), let hi = values.max(), hi > lo else { return values }
            let recip = 1 / (Double(hi) - Double(lo))
            return values.map { Float((Double($0) - Double(lo)) * recip * 2 - 1) }
        }
    }

    /// Patterns to refine: `count` patterns of the detector's rows x columns, row-major, as float32 values. `isFloat32` is
    /// whether they are float32 data (kikuchipy then rescales each to −1 ... 1 first); integer patterns pass their values.
    package struct Patterns: Sendable {
        package let count: Int
        package let pixels: Int
        package let values: [Float]
        package let isFloat32: Bool

        package init(count: Int, pixels: Int, values: [Float], isFloat32: Bool) {
            self.count = count; self.pixels = pixels; self.values = values; self.isFloat32 = isFloat32
        }
    }

    /// The solver's settings (`refine_*`'s `trust_region`, `signal_mask` and SciPy's options).
    package struct Settings: Sendable {
        /// ± around the start of each variable: three angles in degrees (orientation), three PC values, or six (both);
        /// nil leaves the search unbounded.
        package var trustRegion: [Double]?
        /// Detector pixels to leave out, true where excluded (kikuchipy's `signal_mask`), row-major.
        package var signalMask: [Bool]?
        package var options: NelderMead.Options

        package init(trustRegion: [Double]? = nil, signalMask: [Bool]? = nil, options: NelderMead.Options = .init()) {
            self.trustRegion = trustRegion; self.signalMask = signalMask; self.options = options
        }
    }

    // MARK: - Results

    package struct OrientationResult: Sendable, Equatable {
        package var score: Double
        package var evaluations: Int
        /// Bunge Euler angles in radians as the simplex left them (not reduced).
        package var euler: SIMD3<Double>
        /// Which start won when pseudo-symmetry operators were given: 0 the original, i the i-th operator.
        package var pseudoSymmetryIndex: Int?
    }

    package struct ProjectionCenterResult: Sendable, Equatable {
        package var score: Double
        package var evaluations: Int
        package var pc: SIMD3<Double>
    }

    package struct OrientationProjectionCenterResult: Sendable, Equatable {
        package var score: Double
        package var evaluations: Int
        package var euler: SIMD3<Double>
        package var pc: SIMD3<Double>
        package var pseudoSymmetryIndex: Int?
    }

    // MARK: - Pattern preparation and the objective

    /// `_prepare_pattern`: float32, rescaled to −1 ... 1 for float32 data, then centred; with its squared norm.
    static func prepare(_ pattern: ArraySlice<Float>, rescale: Bool) -> (values: [Float], squaredNorm: Double)? {
        var p = Array(pattern)
        if rescale {
            guard let lo = p.min(), let hi = p.max(), hi > lo else { return nil }
            let recip = 1 / (Double(hi) - Double(lo))
            p = p.map { Float((Double($0) - Double(lo)) * recip * 2 - 1) }
        }
        let mean = Float(p.reduce(0.0) { $0 + Double($1) } / Double(p.count))
        var norm = 0.0
        for i in p.indices {
            p[i] -= mean
            norm += Double(p[i]) * Double(p[i])
        }
        guard norm > 0 else { return nil }
        return (p, norm)
    }

    /// `1 − NCC` of the centred experimental pattern and the pattern projected for `q` along `dc` (the objective functions).
    package static func objective(_ q: SIMD4<Double>, _ dc: [SIMD3<Double>], experiment: [Float], squaredNorm: Double, master: Master) -> Double {
        let n = dc.count
        var sim = [Float](repeating: 0, count: n)
        master.upper.withUnsafeBufferPointer { up in
            master.lower.withUnsafeBufferPointer { lo in
                for i in 0..<n {
                    sim[i] = Float(MasterPatternProjection.sample(q, dc[i], upper: up, lower: lo, side: master.side, scale: master.scale))
                }
            }
        }
        var sum = 0.0
        for v in sim { sum += Double(v) }
        let mean = Float(sum / Double(n))
        var cross = 0.0, simNorm = 0.0
        for i in 0..<n {
            let s = Double(sim[i] - mean)
            cross += Double(experiment[i]) * s
            simNorm += s * s
        }
        let score = 1 - cross / (squaredNorm * simNorm).squareRoot()
        // A simulation that is not a number (a trial pattern centre at z = 0 sends every direction to NaN) scores as the worst
        // match, 2 (NCC −1), so the search moves away from it instead of comparing NaN.
        return score.isFinite ? score : 2
    }

    /// `rotation_from_euler`: Bunge angles to the unit quaternion with a non-negative scalar part.
    @inline(__always)
    static func rotation(_ x: [Double], at offset: Int = 0) -> SIMD4<Double> {
        RotationConversions.eu2qu(SIMD3(x[offset], x[offset + 1], x[offset + 2]))
    }

    /// The pixels kept by a signal mask (true excluded), all when there is none.
    static func keptPixels(_ mask: [Bool]?, pixels: Int) throws -> [Int] {
        guard let mask else { return Array(0..<pixels) }
        guard mask.count == pixels else { throw Error.maskSize(mask: mask.count, pixels: pixels) }
        let idx = mask.indices.filter { !mask[$0] }
        guard !idx.isEmpty else { throw Error.emptyMask }
        return idx
    }

    /// `_get_direction_cosines_for_fixed_pc` on the kept pixels.
    static func directionCosines(_ detector: EBSDDetectorGeometry, pc: SIMD3<Double>, sampleToDetector m: [Double], kept: [Int]) -> [SIMD3<Double>] {
        let all = MasterPatternProjection.directionCosines(rows: detector.rows, columns: detector.columns, pc: pc, sampleToDetector: m)
        return kept.count == all.count ? all : kept.map { all[$0] }
    }

    static func sampleToDetector(_ d: EBSDDetectorGeometry) -> [Double] {
        MasterPatternProjection.sampleToDetector(sampleTilt: d.sampleTilt, tilt: d.tilt, azimuthal: d.azimuthal, twist: d.twist)
    }

    // MARK: - Bounds

    /// `np.deg2rad`.
    @inline(__always) static func radians(_ degrees: Double) -> Double { degrees * (Double.pi / 180) }

    static let eulerLower: [Double] = Array(repeating: -radians(5), count: 3)
    static let eulerUpper: [Double] = [2 * Double.pi + radians(5), Double.pi + radians(5), 2 * Double.pi + radians(5)]
    static let pcLower: [Double] = [-2, -2, -2]
    static let pcUpper: [Double] = [2, 2, 2]

    /// `get_bound_constraints`: `fmax(x0 − tr, lower)` and `fmin(x0 + tr, upper)` per variable.
    static func bounds(_ x0: [Double], trustRegion tr: [Double]?, lower: [Double], upper: [Double]) -> [NelderMead.Bound]? {
        guard let tr else { return nil }
        return x0.indices.map { NelderMead.Bound(Swift.max(x0[$0] - tr[$0], lower[$0]), Swift.min(x0[$0] + tr[$0], upper[$0])) }
    }

    /// The trust region in the solver's units: the angles to radians.
    static func trustRegion(_ settings: Settings, expected: Int, anglesFirst: Int) throws -> [Double]? {
        guard let tr = settings.trustRegion else { return nil }
        guard tr.count == expected else { throw Error.trustRegion(expected: expected, got: tr.count) }
        return tr.enumerated().map { $0.offset < anglesFirst ? radians($0.element) : $0.element }
    }

    // MARK: - Starting points

    /// The starting Euler angles of each point (`_RefinementSetup`): `to_euler` of its rotation, then of each pseudo-symmetry
    /// operator times it (orix's `outer`), so one start per point plus one per operator.
    package static func startingEuler(rotations: [SIMD4<Double>], pseudoSymmetry ops: [SIMD4<Double>] = []) -> [[SIMD3<Double>]] {
        rotations.map { q in
            [RotationConversions.qu2eu(Rotation(q).q)] + ops.map { RotationConversions.qu2eu((Rotation($0) * Rotation(q)).q) }
        }
    }

    // MARK: - Pattern-level refinement

    /// `refine_orientation` on prepared starts: one list of starting Euler angles per pattern (the first the indexed one,
    /// then one per pseudo-symmetry operator, see `startingEuler`), the detector with one PC or one per pattern.
    package static func refineOrientations(_ patterns: Patterns, starts: [[SIMD3<Double>]], detector: EBSDDetectorGeometry,
                                           master: Master, settings: Settings = Settings(),
                                           isCancelled: @Sendable () -> Bool = { false }) throws -> [OrientationResult] {
        try check(patterns, count: starts.count, detector: detector)
        let tr = try trustRegion(settings, expected: 3, anglesFirst: 3)
        let kept = try keptPixels(settings.signalMask, pixels: patterns.pixels)
        let m = sampleToDetector(detector)
        let pcs = detector.projectionCenters
        let shared = pcs.count == 1 ? directionCosines(detector, pc: pcs[0], sampleToDetector: m, kept: kept) : nil
        let checked = settings.options
        return try perPattern(patterns.count, isCancelled: isCancelled) { (i: Int) throws -> OrientationResult in
            let base = patterns.values[(i * patterns.pixels)..<((i + 1) * patterns.pixels)]
            guard let exp = prepare(ArraySlice(kept.map { base[base.startIndex + $0] }), rescale: patterns.isFloat32) else {
                // A flat pattern: kikuchipy's NCC is NaN there and the run carries on, so this one is NaN, its start kept.
                let start = starts[i].first ?? SIMD3(repeating: .nan)
                return OrientationResult(score: .nan, evaluations: 0, euler: start, pseudoSymmetryIndex: nil)
            }
            let dc = shared ?? directionCosines(detector, pc: pcs[i], sampleToDetector: m, kept: kept)
            var best: (result: NelderMead.Result, index: Int)?
            for (k, start) in starts[i].enumerated() {
                let x0 = [start.x, start.y, start.z]
                let res = try NelderMead.minimize({ x in
                    objective(rotation(x), dc, experiment: exp.values, squaredNorm: exp.squaredNorm, master: master)
                }, x0: x0, bounds: bounds(x0, trustRegion: tr, lower: eulerLower, upper: eulerUpper), options: checked)
                // `np.argmax` of the scores: the first of equal ones.
                if best.map({ 1 - res.fun > 1 - $0.result.fun }) ?? true { best = (res, k) }
            }
            guard let chosen = best else { throw Error.noStart(i) }
            let r = chosen.result
            return OrientationResult(score: 1 - r.fun, evaluations: r.nfev, euler: SIMD3(r.x[0], r.x[1], r.x[2]),
                                     pseudoSymmetryIndex: starts[i].count > 1 ? chosen.index : nil)
        }
    }

    /// `refine_projection_center`: the rotation of each pattern fixed (unit quaternions), its PC (the detector's one or one
    /// per pattern) moved.
    package static func refineProjectionCenters(_ patterns: Patterns, rotations: [SIMD4<Double>], detector: EBSDDetectorGeometry,
                                                master: Master, settings: Settings = Settings(),
                                                isCancelled: @Sendable () -> Bool = { false }) throws -> [ProjectionCenterResult] {
        try check(patterns, count: rotations.count, detector: detector)
        let tr = try trustRegion(settings, expected: 3, anglesFirst: 0)
        let kept = try keptPixels(settings.signalMask, pixels: patterns.pixels)
        let m = sampleToDetector(detector)
        let pcs = detector.projectionCenters
        return try perPattern(patterns.count, isCancelled: isCancelled) { (i: Int) throws -> ProjectionCenterResult in
            let base = patterns.values[(i * patterns.pixels)..<((i + 1) * patterns.pixels)]
            let pc0 = pcs.count == 1 ? pcs[0] : pcs[i]
            guard let exp = prepare(ArraySlice(kept.map { base[base.startIndex + $0] }), rescale: patterns.isFloat32) else {
                return ProjectionCenterResult(score: .nan, evaluations: 0, pc: pc0)   // flat: NaN, as kikuchipy carries on
            }
            let q = rotations[i]
            let x0 = [pc0.x, pc0.y, pc0.z]
            let res = try NelderMead.minimize({ x in
                let dc = directionCosines(detector, pc: SIMD3(x[0], x[1], x[2]), sampleToDetector: m, kept: kept)
                return objective(q, dc, experiment: exp.values, squaredNorm: exp.squaredNorm, master: master)
            }, x0: x0, bounds: bounds(x0, trustRegion: tr, lower: pcLower, upper: pcUpper), options: settings.options)
            return ProjectionCenterResult(score: 1 - res.fun, evaluations: res.nfev, pc: SIMD3(res.x[0], res.x[1], res.x[2]))
        }
    }

    /// `refine_orientation_projection_center`: Euler angles and PC together, six variables per start.
    package static func refineOrientationsAndProjectionCenters(_ patterns: Patterns, starts: [[SIMD3<Double>]],
                                                               detector: EBSDDetectorGeometry, master: Master,
                                                               settings: Settings = Settings(),
                                                               isCancelled: @Sendable () -> Bool = { false }) throws -> [OrientationProjectionCenterResult] {
        try check(patterns, count: starts.count, detector: detector)
        let tr = try trustRegion(settings, expected: 6, anglesFirst: 3)
        let kept = try keptPixels(settings.signalMask, pixels: patterns.pixels)
        let m = sampleToDetector(detector)
        let pcs = detector.projectionCenters
        return try perPattern(patterns.count, isCancelled: isCancelled) { (i: Int) throws -> OrientationProjectionCenterResult in
            let base = patterns.values[(i * patterns.pixels)..<((i + 1) * patterns.pixels)]
            let pc0 = pcs.count == 1 ? pcs[0] : pcs[i]
            guard let exp = prepare(ArraySlice(kept.map { base[base.startIndex + $0] }), rescale: patterns.isFloat32) else {
                let start = starts[i].first ?? SIMD3(repeating: .nan)   // flat: NaN, as kikuchipy carries on
                return OrientationProjectionCenterResult(score: .nan, evaluations: 0, euler: start, pc: pc0, pseudoSymmetryIndex: nil)
            }
            var best: (result: NelderMead.Result, index: Int)?
            for (k, start) in starts[i].enumerated() {
                let x0 = [start.x, start.y, start.z, pc0.x, pc0.y, pc0.z]
                let res = try NelderMead.minimize({ x in
                    let dc = directionCosines(detector, pc: SIMD3(x[3], x[4], x[5]), sampleToDetector: m, kept: kept)
                    return objective(rotation(x), dc, experiment: exp.values, squaredNorm: exp.squaredNorm, master: master)
                }, x0: x0, bounds: bounds(x0, trustRegion: tr, lower: eulerLower + pcLower, upper: eulerUpper + pcUpper),
                   options: settings.options)
                if best.map({ 1 - res.fun > 1 - $0.result.fun }) ?? true { best = (res, k) }
            }
            guard let chosen = best else { throw Error.noStart(i) }
            let x = chosen.result.x
            return OrientationProjectionCenterResult(score: 1 - chosen.result.fun, evaluations: chosen.result.nfev,
                                                     euler: SIMD3(x[0], x[1], x[2]), pc: SIMD3(x[3], x[4], x[5]),
                                                     pseudoSymmetryIndex: starts[i].count > 1 ? chosen.index : nil)
        }
    }

    // MARK: - Crystal-map refinement

    /// The points `refine_*` refines (`_get_indexed_points_in_data_in_xmap`): in the data and indexed, all of one phase,
    /// that phase matching the master pattern's space and point group.
    package static func pointsToRefine(_ map: CrystalMap, master: Master) throws -> (points: [Int], phaseID: Int) {
        let points = map.allPhaseIDs.indices.filter { map.isInData[$0] && map.allPhaseIDs[$0] != PhaseList.notIndexedID }
        guard !points.isEmpty else { throw Error.noIndexedPoints }
        let ids = Set(points.map { map.allPhaseIDs[$0] })
        guard ids.count == 1, let id = ids.first else {
            throw Error.moreThanOnePhase(ids.sorted().compactMap { map.phases[id: $0]?.name })
        }
        if let p = map.phases[id: id] {
            let sameGroup = p.spaceGroup.map { $0 == master.phase.spaceGroup } ?? true
            let samePoint = p.pointGroupName.map { $0 == master.phase.pointGroup } ?? true
            if !sameGroup || !samePoint { throw Error.phaseMismatch(map: p.name, master: master.phase.name) }
        }
        return (points, id)
    }

    /// `EBSD.refine_orientation(xmap, ...)` with `compute_refine_orientation_results`: `patterns` holds one pattern per map
    /// point (all of them, in the map's order). The refined map keeps the coordinates, has the master pattern's phase at the
    /// refined points' id, −1 where not indexed, the identity elsewhere, and the properties `scores`, `num_evals` (and
    /// `pseudo_symmetry_index` when operators were given).
    package static func refineOrientations(map: CrystalMap, patterns: Patterns, detector: EBSDDetectorGeometry, master: Master,
                                           settings: Settings = Settings(), pseudoSymmetry ops: [SIMD4<Double>] = [],
                                           isCancelled: @Sendable () -> Bool = { false }) throws -> CrystalMap {
        let (points, id) = try pointsToRefine(map, master: master)
        let subset = try select(patterns, points: points, of: map.pointCount)
        let starts = startingEuler(rotations: points.map { map.rotations[$0] }, pseudoSymmetry: ops)
        let det = try detectorFor(points, detector, pointCount: map.pointCount)
        let res = try refineOrientations(subset, starts: starts, detector: det, master: master, settings: settings, isCancelled: isCancelled)
        return try refinedMap(map, points: points, phaseID: id, master: master, euler: res.map(\.euler), scores: res.map(\.score),
                              evaluations: res.map(\.evaluations), pseudoSymmetry: ops.isEmpty ? nil : res.map { $0.pseudoSymmetryIndex ?? 0 })
    }

    // MARK: - Helpers

    private static func check(_ patterns: Patterns, count: Int, detector: EBSDDetectorGeometry) throws {
        guard patterns.count == count else { throw Error.patternCount(patterns: patterns.count, starts: count) }
        guard patterns.pixels == detector.rows * detector.columns, patterns.values.count == patterns.count * patterns.pixels else {
            throw Error.detectorShape
        }
        let c = detector.projectionCenters.count
        guard c == 1 || c == count else { throw Error.centreCount(centres: c, patterns: count) }
    }

    /// The refined points' patterns out of one per map point.
    private static func select(_ patterns: Patterns, points: [Int], of pointCount: Int) throws -> Patterns {
        guard patterns.count == pointCount else { throw Error.patternCount(patterns: patterns.count, starts: pointCount) }
        if points.count == pointCount { return patterns }
        var values: [Float] = []
        values.reserveCapacity(points.count * patterns.pixels)
        for p in points { values.append(contentsOf: patterns.values[(p * patterns.pixels)..<((p + 1) * patterns.pixels)]) }
        return Patterns(count: points.count, pixels: patterns.pixels, values: values, isFloat32: patterns.isFloat32)
    }

    /// A detector with one PC per map point restricted to the refined points (kikuchipy's `pc_flattened[points_to_refine]`).
    private static func detectorFor(_ points: [Int], _ detector: EBSDDetectorGeometry, pointCount: Int) throws -> EBSDDetectorGeometry {
        let c = detector.projectionCenters.count
        if c == 1 { return detector }
        guard c == pointCount else { throw Error.centreCount(centres: c, patterns: pointCount) }
        var d = detector
        d.projectionCenters = points.map { detector.projectionCenters[$0] }
        return d
    }

    private static func refinedMap(_ map: CrystalMap, points: [Int], phaseID: Int, master: Master, euler: [SIMD3<Double>],
                                   scores: [Double], evaluations: [Int], pseudoSymmetry: [Int]?) throws -> CrystalMap {
        let n = map.pointCount
        var rotations = [SIMD4<Double>](repeating: SIMD4(1, 0, 0, 0), count: n)
        var ids = [Int](repeating: PhaseList.notIndexedID, count: n)
        var score = [Double](repeating: 0, count: n)
        var evals = [Double](repeating: 0, count: n)
        var psi = [Double](repeating: 0, count: n)
        for (k, p) in points.enumerated() {
            rotations[p] = RotationConversions.eu2qu(euler[k])
            ids[p] = phaseID
            score[p] = scores[k]
            evals[p] = Double(evaluations[k])
            if let pseudoSymmetry { psi[p] = Double(pseudoSymmetry[k]) }
        }
        let mp = master.phase
        var list = PhaseList([(id: phaseID, phase: CrystalPhase(name: mp.name, spaceGroup: mp.spaceGroup, pointGroup: mp.pointGroup,
                                                                lattice: mp.lattice, latticeUnit: .nanometre))])
        if map.phases.contains(id: PhaseList.notIndexedID) { list.addNotIndexed() }
        var properties = ["scores": score, "num_evals": evals]
        if pseudoSymmetry != nil { properties["pseudo_symmetry_index"] = psi }
        return try CrystalMap(rotations: rotations, phaseIDs: ids, x: map.allX, y: map.allY, phaseList: list,
                              properties: properties, scanUnit: map.scanUnit, isInData: map.isInData)
    }

    /// Runs `work` for every pattern on all cores; the first error (or a cancellation) is thrown after the pass.
    private static func perPattern<T: Sendable>(_ count: Int, isCancelled: @Sendable () -> Bool,
                                                _ work: @Sendable (Int) throws -> T) throws -> [T] {
        let box = ResultBox<T>(count: count)
        DispatchQueue.concurrentPerform(iterations: count) { i in
            if isCancelled() { box.fail(i, CancellationError()); return }
            do { box.set(i, try work(i)) } catch { box.fail(i, error) }
        }
        return try box.values()
    }

    /// Per-pattern results written from many threads, each to its own slot.
    private final class ResultBox<T: Sendable>: Sendable {
        private let state: Mutex<(slots: [T?], firstError: (index: Int, error: Swift.Error)?)>

        init(count: Int) {
            let none: (index: Int, error: Swift.Error)? = nil
            state = Mutex((slots: [T?](repeating: nil, count: count), firstError: none))
        }

        func set(_ i: Int, _ value: T) {
            state.withLock { $0.slots[i] = value }
        }

        func fail(_ i: Int, _ error: Swift.Error) {
            state.withLock { s -> Void in
                if let first = s.firstError, first.index <= i { return }
                s.firstError = (index: i, error: error)
            }
        }

        func values() throws -> [T] {
            // One copy of the state, read by its labels: destructuring it as `let (slots, firstError) = state.withLock { $0 }`
            // made Xcode 27.1's compiler infer two different tuple types for withLock's Result.
            let snapshot = state.withLock { $0 }
            if let firstError = snapshot.firstError {
                if firstError.error is CancellationError || firstError.error is EBSDRefinement.Error { throw firstError.error }
                throw EBSDRefinement.Error.solver(firstError.index, firstError.error.localizedDescription)
            }
            return snapshot.slots.map { $0! }
        }
    }
}
