//
//  IndexingResult.swift
//  Role: a run of the Indexing room as it lands (docs/sem/design/indexing-room.md §3, §6): one solution per scan point, filled row by
//        row (Hough) or block of rows by block (dictionary, D-SEM-92), so the map grows in place and a stopped run keeps its indexed
//        prefix; the map's layers (IPF-Z, IPF-X, IPF-Y, Euler, Phase, then CI, Fit, Bands, PQ for Hough, D-SEM-84, or Score and OSM
//        for a dictionary): the orientation's and the phase's as RGBA, the scalars as their values (D-SEM-96), one pixel per scan
//        point; the status line's readout; the Bands table of the pattern on screen, and each detected band's centre line on that
//        pattern for the overlay.
//
//  A dictionary run's point carries its best match as a `HoughIndexer.Solution` (the rotation, the phase whose dictionary scored it
//  best, the score as its confidence, no fit and no bands), so the map, the readout and the tables read both methods alike; the full
//  ranking (keep_n matches per point) stays in `dictionary`, kikuchipy's result (with several phases the merged map's: each point's
//  matches in the phase it takes), which its crystal map is built from. Its orientation similarity map (kikuchipy's
//  `orientation_similarity_map` with its defaults: every kept match, not normalised, the four nearest neighbours; Marquardt et al.
//  2017) is `OrientationSimilarityMap` (#221) on the rows landed, updated as each block lands (D-SEM-92). A run against several phases
//  (D-SEM-98) lands each block as kikuchipy's `merge_crystal_maps` merges the phases' maps (`DictionaryMapMerge.chosenMaps` and
//  `picked`), and its OSM is kikuchipy's on the merged map's `merged_simulation_indices` (keep_n × phases per point), computed on
//  each phase's own indices (`phaseSimulationIndices`) made distinct across the phases.
//
//  Colours: the IPF layers are orix's `IPFColorKeyTSL` of the phase's point group, Euler is orix's `EulerColorKey` of it (both
//  parity-tested, `SEMColorKeyParityTests`); Phase is the phase's colour. On those layers a point the run has not indexed is black,
//  as orix draws `not_indexed`, and a point the run has not reached shows the scan's mean intensity, dimmed, so the map reads as the
//  Patterns room's navigator until Index has passed. A scalar layer is its values (`scalarPixels`), drawn as the image rooms draw a
//  picture (colormap, window, gamma, D-SEM-96): a point without a value (not indexed, not reached) is NaN, the masked grey.
//

import Foundation
import ImagoCore

/// The Indexing room's map layers (D-SEM-84, D-SEM-96).
package nonisolated enum IndexingLayer: String, Sendable, CaseIterable, Identifiable, Codable {
    case ipfZ, ipfX, ipfY, euler, phase, confidence, fit, bands, patternQuality, score, osm

    package var id: String { rawValue }

    /// The layers a run of `method` has (D-SEM-84, D-SEM-92, D-SEM-96): the orientation's in its two colour keys and the phase's, then
    /// the method's own scalars.
    package static func layers(for method: IndexingMethod) -> [IndexingLayer] {
        switch method {
        case .hough: [.ipfZ, .ipfX, .ipfY, .euler, .phase, .confidence, .fit, .bands, .patternQuality]
        case .dictionary: [.ipfZ, .ipfX, .ipfY, .euler, .phase, .score, .osm]
        }
    }

    /// The picker's word.
    package var title: String {
        switch self {
        case .ipfZ: "IPF-Z"
        case .ipfX: "IPF-X"
        case .ipfY: "IPF-Y"
        case .euler: "Euler"
        case .phase: "Phase"
        case .confidence: "Confidence index"
        case .fit: "Fit"
        case .bands: "Matched bands"
        case .patternQuality: "Pattern quality"
        case .score: "Score"
        case .osm: "OSM"
        }
    }

    /// The sample direction an IPF layer colours, nil for the others.
    package var direction: SIMD3<Double>? {
        switch self {
        case .ipfZ: Vector3.z
        case .ipfX: Vector3.x
        case .ipfY: Vector3.y
        default: nil
        }
    }

    /// Whether each point's colour is its own (IPF, Euler, Phase); a scalar layer is drawn through a colormap over the range of every
    /// point reached.
    package var isPointwise: Bool { direction != nil || self == .euler || self == .phase }

    /// The pop-up's help: what the layer shows, in its source's words (pyEBSDindex's cm, fit and pq; orix's colour keys).
    package var help: String {
        switch self {
        case .ipfZ, .ipfX, .ipfY: "The crystal direction along the sample's \(title.suffix(1).lowercased()) axis, in the phase's IPF colour key (orix's TSL key)"
        case .euler: "The Bunge angles (φ₁, Φ, φ₂) in the Euler fundamental region of the phase's proper point group, each over its largest value, as red, green and blue (orix's Euler colour key)"
        case .phase: "Each point in its phase's colour"
        case .confidence: "pyEBSDindex's confidence metric (cm): the votes of the matched families over all votes, 0 to 1"
        case .fit: "The mean angle between the detected and the matched band normals, degrees"
        case .bands: "The number of detected bands matched to the phase's reflectors"
        case .patternQuality: "The mean Radon peak of the detected bands (pyEBSDindex's pq)"
        case .score: "The best match's score against the dictionary, kikuchipy's scores: its normalised cross-correlation (NCC) or dot product (NDP)"
        case .osm: "The orientation similarity map (kikuchipy's, Marquardt et al. 2017): how many of a point's kept matches (in every phase's dictionary) each of its four nearest neighbours shares, on average. High inside a grain, low at its boundaries and on poor patterns"
        }
    }

    /// The scalar of a solution on this layer; nil where it has none (the orientation's layers on a point not indexed, and OSM, which
    /// is the neighbourhood's and not the solution's: `IndexingResult.value(_:at:)` reads it).
    package func value(_ s: HoughIndexer.Solution) -> Double? {
        switch self {
        case .confidence, .score: return s.phase >= 0 ? s.confidence : nil
        case .fit: return s.phase >= 0 ? s.fit : nil
        case .bands: return Double(s.matchedBands)
        case .patternQuality: return s.patternQuality.isFinite ? s.patternQuality : nil
        case .ipfZ, .ipfX, .ipfY, .euler, .phase, .osm: return nil
        }
    }
}

/// One run of a scan, filled row by row (Hough) or block by block (dictionary).
package nonisolated struct IndexingResult: Sendable {
    package let scanRows: Int
    package let scanColumns: Int
    /// The phases indexed against; a solution's `phase` indexes this list.
    package let phases: [IndexingPhase]
    package let method: IndexingMethod
    /// A dictionary run's metric (the score's name); nil for Hough.
    package let metric: DictionaryIndexing.Metric?
    /// One per scan point in map order; nil until its row has landed.
    package private(set) var solutions: [HoughIndexer.Solution?]
    /// The rows landed (they land in order: a stopped run keeps rows 0..<rowsDone).
    package private(set) var rowsDone = 0
    /// A dictionary run's matches of the rows landed, kikuchipy's result (keep_n per point, best first); with several phases the merged
    /// map's (each point's matches in the phase it takes, the simulation indices into that phase's dictionary), whose own
    /// `orientationSimilarityMap()` is not the run's OSM (`similarity` is). nil for Hough.
    package private(set) var dictionary: DictionaryIndexing.Result?
    /// A run against several phases (D-SEM-98): each phase's simulation indices of the rows landed (point × keep_n, best first, in
    /// `phases` order), the OSM's input. Empty for one phase and for Hough.
    package private(set) var phaseSimulationIndices: [[Int]]
    /// A dictionary run's orientation similarity map of the rows landed, one per scan point in map order (NaN where no row has landed,
    /// and for Hough, which keeps one solution per point).
    package private(set) var similarity: [Float]

    /// A Hough run (`metric` nil) or a dictionary run (`metric` its score).
    package init(scanRows: Int, scanColumns: Int, phases: [IndexingPhase], metric: DictionaryIndexing.Metric? = nil) {
        self.scanRows = scanRows
        self.scanColumns = scanColumns
        self.phases = phases
        self.metric = metric
        method = metric == nil ? .hough : .dictionary
        solutions = [HoughIndexer.Solution?](repeating: nil, count: max(scanRows, 0) * max(scanColumns, 0))
        similarity = [Float](repeating: .nan, count: solutions.count)
        phaseSimulationIndices = metric != nil && phases.count > 1 ? Array(repeating: [], count: phases.count) : []
    }

    /// Lands scan row `row`'s solutions; a row of the wrong length or outside the scan, or on a dictionary run, is dropped.
    package mutating func land(_ row: [HoughIndexer.Solution], at index: Int) {
        guard method == .hough, index >= 0, index < scanRows, row.count == scanColumns else { return }
        for c in 0..<scanColumns { solutions[index * scanColumns + c] = row[c] }
        rowsDone = max(rowsDone, index + 1)
    }

    /// Lands a dictionary block of a run against one phase, kikuchipy's result for scan rows `rows` (the next rows: blocks land in
    /// order). Each point's solution is its best match: the rotation, phase 0 and the score; a point whose score is not a number (a
    /// pattern without contrast, which kikuchipy scores NaN) or that is not in the data is not indexed. A block that does not follow or
    /// does not fit is dropped, and so is any block of a run against several phases (`land(_:rows:)` with one result per phase).
    package mutating func land(_ block: DictionaryIndexing.Result, rows: Range<Int>) {
        guard method == .dictionary, phases.count < 2, rows.lowerBound == rowsDone, rows.upperBound <= scanRows, block.keepN >= 1,
              block.pointCount == rows.count * scanColumns, block.scores.count == block.pointCount * block.keepN,
              block.simulationIndices.count == block.scores.count, block.rotations.count == block.scores.count,
              dictionary.map({ $0.keepN == block.keepN }) ?? true else { return }
        let scores = block.bestScores, rotations = block.bestRotations
        let start = rows.lowerBound * scanColumns
        for k in 0..<block.pointCount {
            var s = HoughIndexer.Solution()
            let indexed = block.isInData[k] && scores[k].isFinite
            s.quaternion = rotations[k]
            s.phase = indexed ? 0 : -1
            s.confidence = indexed ? scores[k] : 0
            s.fit = .nan
            s.patternQuality = .nan
            solutions[start + k] = s
        }
        append(block, rows: rows)
        rowsDone = rows.upperBound
        updateSimilarity(from: rows.lowerBound)
    }

    /// Lands a dictionary block of scan rows `rows` (the next rows): kikuchipy's result of each phase's dictionary, in `phases` order
    /// (D-SEM-98). One phase lands as `land(_:rows:)`. With several, each point takes the phase `DictionaryMapMerge.chosenMaps` picks,
    /// kikuchipy's `merge_crystal_maps` with its defaults (the best score, the first phase on a tie) on the scores as the run made
    /// them, with that phase's best rotation and score; its keep_n matches are the merged map's (`picked`). A point no phase scores (a
    /// pattern without contrast, NaN in every dictionary, where kikuchipy's `nanargmax` raises) is not indexed; a phase that does not
    /// score a point leaves it to the others. A set of blocks that does not follow, does not fit or keeps another keep_n is dropped.
    package mutating func land(_ blocks: [DictionaryIndexing.Result], rows: Range<Int>) {
        guard blocks.count == phases.count, let keep = blocks.first?.keepN else { return }
        if blocks.count == 1 {
            land(blocks[0], rows: rows)
            return
        }
        guard method == .dictionary, rows.lowerBound == rowsDone, rows.upperBound <= scanRows, keep >= 1,
              blocks.allSatisfy({ $0.keepN == keep && $0.pointCount == rows.count * scanColumns && $0.scores.count == $0.pointCount * keep
                                  && $0.simulationIndices.count == $0.scores.count && $0.rotations.count == $0.scores.count }),
              dictionary.map({ $0.keepN == keep }) ?? true else { return }
        let inputs = zip(blocks, phases).map { DictionaryMapMerge.Input(result: $0, phase: $1.crystalPhase) }
        guard let choice = try? DictionaryMapMerge.chosenMaps(inputs, float32: false) else { return }
        let best = DictionaryMapMerge.picked(inputs, choice: choice, float32: false)
        let start = rows.lowerBound * scanColumns
        for k in 0..<best.pointCount {
            var s = HoughIndexer.Solution()
            let indexed = choice[k] != nil && best.isInData[k] && best.scores[k * keep].isFinite
            s.quaternion = best.rotations[k * keep]
            s.phase = indexed ? (choice[k] ?? -1) : -1
            s.confidence = indexed ? best.scores[k * keep] : 0
            s.fit = .nan
            s.patternQuality = .nan
            solutions[start + k] = s
        }
        append(best, rows: rows)
        for (i, block) in blocks.enumerated() { phaseSimulationIndices[i] += block.simulationIndices }
        rowsDone = rows.upperBound
        updateSimilarity(from: rows.lowerBound)
    }

    /// Appends a landed block's matches to `dictionary`, in place: the stored arrays are held once, so the block's matches are added
    /// to them as they stand. A copy of `dictionary` to append to (as before) copied every match landed so far at each block, which
    /// made a run's landing quadratic on the main actor. No capacity is reserved: `append(contentsOf:)` grows geometrically, a
    /// reserve per block would reallocate to the exact size every time, and a reserve of the whole scan would hold a stopped run's
    /// full size.
    private mutating func append(_ block: DictionaryIndexing.Result, rows: Range<Int>) {
        let shape = [rows.upperBound, scanColumns]
        guard dictionary != nil else {
            var landed = block
            landed.navigationShape = shape
            dictionary = landed
            return
        }
        dictionary?.appendMatches(of: block, navigationShape: shape)
    }

    /// Recomputes the orientation similarity map from row `first` down to the last row landed, and the row above it (whose neighbour
    /// below has just landed). A point's value needs only its four nearest neighbours, so the map is computed on those rows and the
    /// one above them, and the rows' values are taken from it: the same numbers kikuchipy gives on the map of the rows landed. With
    /// several phases the points' sets are kikuchipy's `merged_simulation_indices` up to order and shift (D-SEM-98): phase i's index j
    /// is j · phases + i, one-to-one across the phases as kikuchipy's shift past the previous map's largest index is, and with every
    /// merged match counted (its default n_best) a neighbour shares the same number of them either way; unlike kikuchipy's shift, it
    /// does not depend on the rows landed.
    private mutating func updateSimilarity(from first: Int) {
        guard let dictionary, rowsDone > 0 else { return }
        let keep = dictionary.keepN
        let lo = max(first - 1, 0), top = max(lo - 1, 0)
        let window: [Int], width: Int
        if phaseSimulationIndices.isEmpty {
            window = Array(dictionary.simulationIndices[(top * scanColumns * keep)..<(rowsDone * scanColumns * keep)])
            width = keep
        } else {
            let k = phaseSimulationIndices.count
            var merged: [Int] = []
            merged.reserveCapacity((rowsDone - top) * scanColumns * keep * k)
            for p in (top * scanColumns)..<(rowsDone * scanColumns) {
                for (i, indices) in phaseSimulationIndices.enumerated() {
                    for n in 0..<keep { merged.append(indices[p * keep + n] * k + i) }
                }
            }
            window = merged
            width = keep * k
        }
        guard let map = try? OrientationSimilarityMap.compute(simulationIndices: window, keepN: width, rows: rowsDone - top,
                                                              columns: scanColumns).maps.first else { return }
        for i in (lo * scanColumns)..<(rowsDone * scanColumns) { similarity[i] = map[i - top * scanColumns] }
    }

    /// A layer's scalar at point `i` in map order: the solution's (`IndexingLayer.value`), or for OSM the orientation similarity map's
    /// where the point is indexed; nil where the point has none or has not landed.
    package func value(_ layer: IndexingLayer, at i: Int) -> Double? {
        guard solutions.indices.contains(i), let s = solutions[i] else { return nil }
        guard layer == .osm else { return layer.value(s) }
        return s.phase >= 0 && similarity[i].isFinite ? Double(similarity[i]) : nil
    }

    /// A dictionary run's best simulation index at a point (into the dictionary of the point's phase); nil where none has landed.
    package func simulationIndex(at position: EBSDPosition) -> Int? {
        guard let dictionary, position.isInside(rows: scanRows, columns: scanColumns) else { return nil }
        let i = position.index(columns: scanColumns) * dictionary.keepN
        return dictionary.simulationIndices.indices.contains(i) && dictionary.simulationIndices[i] >= 0 ? dictionary.simulationIndices[i] : nil
    }

    /// The score's name: "NCC", "NDP"; "CI" for Hough.
    package var scoreTitle: String { metric?.title ?? "CI" }

    /// A scalar layer's name under its colour bar: the score by its metric ("NCC"), the fit with its unit ("Fit (°)"), else the
    /// layer's title.
    package func scalarTitle(_ layer: IndexingLayer) -> String {
        switch layer {
        case .score: scoreTitle
        case .fit: "Fit (°)"
        default: layer.title
        }
    }

    /// The map layers this run has.
    package var layers: [IndexingLayer] { IndexingLayer.layers(for: method) }

    package var isComplete: Bool { rowsDone >= scanRows }
    package var pointCount: Int { scanRows * scanColumns }
    package var reachedCount: Int { solutions.reduce(0) { $0 + ($1 == nil ? 0 : 1) } }
    package var indexedCount: Int { solutions.reduce(0) { $0 + (($1?.phase ?? -1) >= 0 ? 1 : 0) } }

    /// Points indexed as each phase, in `phases` order.
    package var countsByPhase: [Int] {
        var counts = [Int](repeating: 0, count: phases.count)
        for case let s? in solutions where phases.indices.contains(s.phase) { counts[s.phase] += 1 }
        return counts
    }

    package func solution(at position: EBSDPosition) -> HoughIndexer.Solution? {
        guard position.isInside(rows: scanRows, columns: scanColumns) else { return nil }
        return solutions[position.index(columns: scanColumns)]
    }

    package func phase(of s: HoughIndexer.Solution) -> IndexingPhase? {
        phases.indices.contains(s.phase) ? phases[s.phase] : nil
    }

    /// The rows landed as orix's crystal map, as kikuchipy builds it from pyEBSDindex's result (`HoughIndexer.crystalMap`, D-SEM-81):
    /// the whole scan once the run is complete, rows 0..<rowsDone of a stopped run (the rows it reached, on their own grid), steps
    /// `steps` (dy, dx) in `scanUnit`; the phases keep the room's colours. `indexer` is the run's (its phases are `phases`). nil before a
    /// row has landed.
    package func crystalMap(indexer: HoughIndexer, steps: (dy: Double, dx: Double), scanUnit: String) throws -> CrystalMap? {
        guard method == .hough, rowsDone > 0 else { return nil }
        let landed = solutions.prefix(rowsDone * scanColumns).map { $0 ?? HoughIndexer.Solution() }
        var map = try indexer.crystalMap(HoughIndexer.Map(scanRows: rowsDone, scanColumns: scanColumns, solutions: landed),
                                         steps: steps, scanUnit: scanUnit)
        map.phases = PhaseList(map.phases.entries.map { entry -> (id: Int, phase: CrystalPhase) in
            var phase = entry.phase
            if phases.indices.contains(entry.id) { phase.color = phases[entry.id].color }
            return (id: entry.id, phase: phase)
        })
        return map
    }

    /// A dictionary run's rows landed as orix's crystal map, as kikuchipy builds it (`DictionaryIndexing.Result.crystalMap`, D-SEM-92):
    /// the best match's rotation, the phase as id 0 in the room's colour, the properties `scores` and `simulation_indices`, steps
    /// `steps` (dy, dx) in `scanUnit`. A point the room does not index (no contrast, NaN score) is `not_indexed` with score 0, so the
    /// files hold numbers. With several phases (D-SEM-98) it is kikuchipy's merged map (`DictionaryMapMerge.Merged.crystalMap`): each
    /// point's phase by its index in `phases`, in the room's names and colours, a phase that wins no point left out as kikuchipy leaves
    /// it. nil before a block has landed.
    package func crystalMap(steps: (dy: Double, dx: Double), scanUnit: String) throws -> CrystalMap? {
        guard method == .dictionary, rowsDone > 0, let dictionary, let phase = phases.first else { return nil }
        if phases.count > 1 {
            let (x, y) = CrystalMap.coordinates(shape: (rowsDone, scanColumns), steps: (steps.dy, steps.dx))
            let ids = (0..<(rowsDone * scanColumns)).map { i in solutions[i].map { $0.phase >= 0 ? $0.phase : PhaseList.notIndexedID } ?? PhaseList.notIndexedID }
            // kikuchipy adds a map's phase to the merged list only where it wins a point.
            let won = Set(ids)
            let list = PhaseList(phases.enumerated().filter { won.contains($0.offset) }.map { (id: $0.offset, phase: $0.element.crystalPhase) })
            return try CrystalMap(rotations: dictionary.bestRotations, phaseIDs: ids, x: x, y: y, phaseList: list,
                                  properties: ["scores": dictionary.bestScores.map { $0.isFinite ? $0 : 0 },
                                               "simulation_indices": dictionary.bestSimulationIndices.map(Double.init)],
                                  scanUnit: scanUnit, isInData: dictionary.isInData)
        }
        let map = try dictionary.crystalMap(phase: phase.crystalPhase, stepSizes: [steps.dy, steps.dx], scanUnit: scanUnit)
        let best = dictionary.bestScores
        guard best.contains(where: { !$0.isFinite }) else { return map }
        var properties = map.properties
        properties["scores"] = best.map { $0.isFinite ? $0 : 0 }
        let ids = zip(map.allPhaseIDs, best).map { $1.isFinite ? $0 : PhaseList.notIndexedID }
        return try CrystalMap(rotations: map.rotations, phaseIDs: ids, x: map.allX, y: map.allY, phaseList: map.phases,
                              properties: properties, scanUnit: map.scanUnit, isInData: map.isInData)
    }

    /// The .ang columns of a dictionary crystal map (D-SEM-92): the confidence index from the best score (`scores`, as orix's writer
    /// takes it by name), no image quality, fit or detector signal (written 0).
    package static let dictionaryAngOptions = ANGWriter.Options(confidenceIndex: "scores")

    /// The .ang columns of a Hough crystal map (D-SEM-84): image quality from `pq` (pyEBSDindex's mean Radon peak of the bands, as
    /// EDAX's IQ is the mean Hough peak), confidence index from `cm` (its vote confidence after EDAX's voting CI), fit from `fit`.
    package static let angOptions = ANGWriter.Options(imageQuality: "pq", confidenceIndex: "cm", patternFit: "fit")

    /// A Hough crystal map with the columns an Oxford .ctf reads by name (D-SEM-84): Bands from the matched bands (`nmatch`) and MAD
    /// from the fit (`fit`, pyEBSDindex's mean angular deviation; 0 where not indexed, as AZtec writes it).
    package static func ctfColumns(_ map: CrystalMap) throws -> CrystalMap {
        var properties = map.properties
        if let matched = properties["nmatch"] { properties["bands"] = matched }
        if let fit = properties["fit"] {
            properties["mad"] = zip(fit, map.allPhaseIDs).map { $1 == PhaseList.notIndexedID ? 0 : $0 }
        }
        return try CrystalMap(rotations: map.rotations, phaseIDs: map.allPhaseIDs, x: map.allX, y: map.allY, phaseList: map.phases,
                              properties: properties, scanUnit: map.scanUnit, isInData: map.isInData)
    }

    /// orix's Bunge Euler angles (φ₁, Φ, φ₂) of a solution's orientation, degrees, φ₁ and φ₂ in [0, 360).
    package static func eulerDegrees(_ s: HoughIndexer.Solution) -> SIMD3<Double> {
        Rotation(unit: s.quaternion).euler * (180 / Double.pi)
    }

    // MARK: - The status line

    /// A number of the status line, written as the Results table under it writes the same value (`UnitDisplay.fixed`): printf's digits
    /// in `locale`'s decimal mark, no sign on a value that rounds to zero, `UnitDisplay.noValue` where there is none.
    private static func fixed(_ v: Double, _ digits: Int, _ locale: Locale) -> String {
        UnitDisplay.fixed(v, places: digits, locale: locale)
    }

    /// The status line over the map: "row 12 · col 40 · Ni · φ₁ 12,3° Φ 44,0° φ₂ 271,5° · CI 0,82 · fit 0,6° · bands 9 of 10"; a point
    /// not indexed says so with its band count, a point the run has not reached says "not indexed yet". A dictionary run's point:
    /// "row 12 · col 40 · ni · φ₁ … Φ … φ₂ … · NCC 0,412 · OSM 4,25". nil outside the scan.
    package func readout(at position: EBSDPosition, locale: Locale = .autoupdatingCurrent) -> String? {
        guard position.isInside(rows: scanRows, columns: scanColumns) else { return nil }
        let head = "row \(position.row) · col \(position.column)"
        guard let s = solution(at: position) else { return head + " · not indexed yet" }
        if method == .dictionary {
            guard let indexedPhase = self.phase(of: s) else { return head + " · not indexed: the pattern has no contrast to score" }
            let e = Self.eulerDegrees(s)
            var words = head + " · \(indexedPhase.name) · φ₁ \(Self.fixed(e.x, 1, locale))° Φ \(Self.fixed(e.y, 1, locale))° φ₂ \(Self.fixed(e.z, 1, locale))°"
            words += " · \(scoreTitle) \(Self.fixed(s.confidence, 3, locale))"
            if let osm = value(.osm, at: position.index(columns: scanColumns)) { words += " · OSM \(Self.fixed(osm, 2, locale))" }
            return words
        }
        let bands = "bands \(s.matchedBands) of \(s.bandMatch.count)"
        guard let indexedPhase = self.phase(of: s) else { return head + " · not indexed · " + bands }
        let e = Self.eulerDegrees(s)
        return head + " · \(indexedPhase.name) · φ₁ \(Self.fixed(e.x, 1, locale))° Φ \(Self.fixed(e.y, 1, locale))° φ₂ \(Self.fixed(e.z, 1, locale))°"
            + " · CI \(Self.fixed(s.confidence, 2, locale)) · fit \(Self.fixed(s.fit, 2, locale))° · " + bands
    }

    // MARK: - The results as a table

    /// One row of the Results table and of the CSV.
    package struct Row: Sendable, Identifiable, Equatable {
        /// The point's index in map order.
        package let id: Int
        package let row: Int
        package let column: Int
        package let phase: String
        package let phi1: Double
        package let capitalPhi: Double
        package let phi2: Double
        package let confidence: Double
        package let fit: Double
        package let bands: Int
        package let patternQuality: Double
        /// A dictionary run's best simulation index (-1 for Hough and where none).
        package let simulationIndex: Int
        /// A dictionary run's orientation similarity (NaN for Hough and where the point is not indexed).
        package let similarity: Double

        package var position: EBSDPosition { EBSDPosition(row: row, column: column) }

        /// Sort keys of the columns a point not indexed leaves NaN: NaN last, so a sorted column stays in order.
        package var phi1Key: Double { phi1.isFinite ? phi1 : .infinity }
        package var capitalPhiKey: Double { capitalPhi.isFinite ? capitalPhi : .infinity }
        package var phi2Key: Double { phi2.isFinite ? phi2 : .infinity }
        package var fitKey: Double { fit.isFinite ? fit : .infinity }
        package var patternQualityKey: Double { patternQuality.isFinite ? patternQuality : .infinity }
        package var similarityKey: Double { similarity.isFinite ? similarity : .infinity }
    }

    /// The reached points, in map order. Not indexed: phase "not indexed", the Euler angles and fit NaN, CI (or score) 0. A dictionary
    /// run's row carries the score as its CI, its simulation index and its OSM, and no fit, bands or pattern quality.
    package var rows: [Row] {
        var out: [Row] = []
        out.reserveCapacity(rowsDone * scanColumns)
        let keep = dictionary?.keepN ?? 1
        for (i, solution) in solutions.enumerated() {
            guard let s = solution else { continue }
            let indexed = self.phase(of: s)
            let e = indexed == nil ? SIMD3<Double>(.nan, .nan, .nan) : Self.eulerDegrees(s)
            var simulation = -1
            if let dictionary, dictionary.simulationIndices.indices.contains(i * keep) { simulation = dictionary.simulationIndices[i * keep] }
            out.append(Row(id: i, row: i / scanColumns, column: i % scanColumns, phase: indexed?.name ?? "not indexed",
                           phi1: e.x, capitalPhi: e.y, phi2: e.z, confidence: indexed == nil ? 0 : s.confidence,
                           fit: indexed == nil ? .nan : s.fit, bands: s.matchedBands, patternQuality: s.patternQuality,
                           simulationIndex: simulation, similarity: value(.osm, at: i) ?? .nan))
        }
        return out
    }

    /// The reached points as CSV (locale-free numbers, one header line): row, column, x and y in the scan unit, phase (an RFC 4180 cell,
    /// ImagoKit's `CSVText.quoted`, so a name holding a comma or a quote stays one cell), the Euler angles in degrees, then for Hough CI,
    /// fit, matched bands, pattern quality, for a dictionary the score (named by its metric), the simulation index and the OSM.
    package func csv(stepX: Double, stepY: Double) -> String {
        let tail = method == .dictionary ? "\((metric ?? .ncc).rawValue),simulation_index,osm" : "ci,fit_deg,matched_bands,pattern_quality"
        var lines = ["row,column,x,y,phase,phi1_deg,Phi_deg,phi2_deg," + tail]
        func number(_ v: Double) -> String { v.isFinite ? String(format: "%.6g", v) : "" }
        for r in rows {
            var fields = [String(r.row), String(r.column), number(Double(r.column) * stepX), number(Double(r.row) * stepY), CSVText.quoted(r.phase),
                          number(r.phi1), number(r.capitalPhi), number(r.phi2), number(r.confidence)]
            if method == .dictionary {
                fields += [r.simulationIndex >= 0 ? String(r.simulationIndex) : "", number(r.similarity)]
            } else {
                fields += [number(r.fit), String(r.bands), number(r.patternQuality)]
            }
            lines.append(fields.joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

/// A block's matches after the ones landed before it, in place on the stored result (`IndexingResult.append(_:rows:)`).
private extension DictionaryIndexing.Result {
    mutating func appendMatches(of block: DictionaryIndexing.Result, navigationShape shape: [Int]) {
        isInData.append(contentsOf: block.isInData)
        scores.append(contentsOf: block.scores)
        simulationIndices.append(contentsOf: block.simulationIndices)
        rotations.append(contentsOf: block.rotations)
        navigationShape = shape
    }
}

// MARK: - The map as RGBA

/// The colour keys of one layer for a run's phases, made once (a key's sector and azimuth table take a few milliseconds).
package nonisolated struct IndexingPalette: Sendable {
    package let layer: IndexingLayer
    private let keys: [IPFColorKeyTSL?]
    private let eulerKeys: [EulerColorKey?]
    private let phaseColors: [SIMD3<Double>]

    package init(layer: IndexingLayer, phases: [IndexingPhase]) {
        self.layer = layer
        if let direction = layer.direction {
            keys = phases.map { phase in phase.pointGroup.map { IPFColorKeyTSL($0, direction: direction) } }
        } else {
            keys = phases.map { _ in nil }
        }
        eulerKeys = phases.map { phase in layer == .euler ? phase.pointGroup.map(EulerColorKey.init) : nil }
        phaseColors = phases.map(\.colorRGB)
    }

    /// The colour of each indexed solution in `solutions` (by its position in the list), nil for the points with none on this layer.
    func pointColors(_ solutions: [HoughIndexer.Solution?]) -> [SIMD3<Double>?] {
        var out = [SIMD3<Double>?](repeating: nil, count: solutions.count)
        switch layer {
        case .phase:
            for (i, s) in solutions.enumerated() {
                if let s, phaseColors.indices.contains(s.phase) { out[i] = phaseColors[s.phase] }
            }
        case .ipfZ, .ipfX, .ipfY:
            for (p, key) in keys.enumerated() {
                guard let key else { continue }
                let members = solutions.indices.filter { solutions[$0]?.phase == p }
                guard !members.isEmpty else { continue }
                let colors = key.color(of: members.map { solutions[$0]?.quaternion ?? SIMD4(1, 0, 0, 0) })
                for (k, i) in members.enumerated() { out[i] = colors[k] }
            }
        case .euler:
            for (p, key) in eulerKeys.enumerated() {
                guard let key else { continue }
                let members = solutions.indices.filter { solutions[$0]?.phase == p }
                guard !members.isEmpty else { continue }
                let colors = key.color(of: members.map { solutions[$0]?.quaternion ?? SIMD4(1, 0, 0, 0) })
                for (k, i) in members.enumerated() { out[i] = colors[k] }
            }
        case .confidence, .fit, .bands, .patternQuality, .score, .osm:
            break
        }
        return out
    }
}

package nonisolated enum IndexingRaster {
    /// How much of the mean intensity a point the run has not reached shows.
    static let backdropDimming = 0.45

    /// A pointwise layer (IPF, Euler, Phase) over the whole scan, 4 bytes per point (alpha 255), scan row-major. `backdrop`: the
    /// scan's mean intensity per point (the Patterns room's navigator), drawn dimmed where the run has not reached; nil draws those
    /// points dark grey. A scalar layer is drawn from `scalarPixels`, through the room's display.
    package static func rgba(_ result: IndexingResult, palette: IndexingPalette, backdrop: [Float]?) -> [UInt8] {
        var out = [UInt8](repeating: 255, count: result.pointCount * 4)
        paint(&out, result: result, palette: palette, backdrop: backdrop, rows: 0..<result.scanRows)
        return out
    }

    /// The scan before any run: the mean intensity dimmed, or dark grey without it.
    package static func backdrop(scanRows: Int, scanColumns: Int, means: [Float]?) -> [UInt8] {
        let n = max(scanRows, 0) * max(scanColumns, 0)
        var out = [UInt8](repeating: 255, count: n * 4)
        let range = meanRange(means, count: n)
        for i in 0..<n {
            let g = grey(means, i, range)
            out[4 * i] = g; out[4 * i + 1] = g; out[4 * i + 2] = g
        }
        return out
    }

    /// Repaints scan rows `rows` of `rgba` with a pointwise layer (its points' colours are their own, so only the rows that landed
    /// change); a point reached with no colour on the layer (not indexed) is black.
    package static func paint(_ rgba: inout [UInt8], result: IndexingResult, palette: IndexingPalette, backdrop: [Float]?, rows: Range<Int>) {
        let columns = result.scanColumns
        let lo = max(rows.lowerBound, 0), hi = min(rows.upperBound, result.scanRows)
        guard rgba.count == result.pointCount * 4, lo < hi else { return }
        let start = lo * columns, end = hi * columns
        let slice = Array(result.solutions[start..<end])
        let colors = palette.pointColors(slice)
        let means = meanRange(backdrop, count: result.pointCount)
        for (k, solution) in slice.enumerated() {
            let i = start + k
            if solution != nil {
                let rgb = colors[k] ?? SIMD3(0, 0, 0)
                rgba[4 * i] = byte(rgb.x); rgba[4 * i + 1] = byte(rgb.y); rgba[4 * i + 2] = byte(rgb.z)
            } else {
                let g = grey(backdrop, i, means)
                rgba[4 * i] = g; rgba[4 * i + 1] = g; rgba[4 * i + 2] = g
            }
            rgba[4 * i + 3] = 255
        }
    }

    /// A scalar layer's values over the whole scan, scan row-major, as the room draws them (D-SEM-96): NaN where a point has no value
    /// on it (not indexed for CI, Fit, Score and OSM) or has not been reached, which the display draws as the masked grey.
    package static func scalarPixels(_ result: IndexingResult, layer: IndexingLayer) -> [Float] {
        (0..<result.pointCount).map { i in result.value(layer, at: i).map(Float.init) ?? .nan }
    }

    /// What the masked grey of a scalar layer stands for, for the legend: "grey: not indexed · not reached"; nil when no point is grey.
    /// CI, Fit, Score and OSM have no value where the run did not index; Bands and Pattern quality have one at every point reached
    /// (pyEBSDindex's pq is 0 when no band is valid), so their grey says "no value" only for a pattern quality that is not a number.
    package static func maskedWords(_ result: IndexingResult, layer: IndexingLayer) -> String? {
        var missing = false, unreached = false
        for i in result.solutions.indices {
            if result.solutions[i] == nil {
                unreached = true
            } else if !(result.value(layer, at: i)?.isFinite ?? false) {
                missing = true
            }
            if missing && unreached { break }
        }
        var words: [String] = []
        if missing { words.append(layer == .patternQuality || layer == .bands ? "no value" : "not indexed") }
        if unreached { words.append("not reached") }
        return words.isEmpty ? nil : "grey: " + words.joined(separator: " · ")
    }

    private static func byte(_ v: Double) -> UInt8 { UInt8((min(max(v, 0), 1) * 255).rounded()) }

    private static func meanRange(_ means: [Float]?, count: Int) -> ClosedRange<Float>? {
        guard let means, means.count == count else { return nil }
        var lo = Float.infinity, hi = -Float.infinity
        for v in means where v.isFinite { lo = min(lo, v); hi = max(hi, v) }
        return lo <= hi ? lo...hi : nil
    }

    private static func grey(_ means: [Float]?, _ i: Int, _ range: ClosedRange<Float>?) -> UInt8 {
        guard let means, let range, means.indices.contains(i), means[i].isFinite else { return byte(0.15) }
        let t = range.upperBound > range.lowerBound ? Double((means[i] - range.lowerBound) / (range.upperBound - range.lowerBound)) : 0.5
        return byte(t * backdropDimming)
    }
}

// MARK: - The bands of the pattern on screen

/// One detected band of the pattern on screen, with what the solution made of it (the Bands table and the overlay).
package nonisolated struct IndexedBand: Sendable, Identifiable, Equatable {
    /// The band's rank among the detected (1 is the strongest).
    package let id: Int
    /// pyEBSDindex's band: distance from the pattern centre (px) and angle (degrees), lower-left origin.
    package let rho: Double
    package let thetaDegrees: Double
    /// The convolved Radon peak and the band-width metric.
    package let peak: Double
    package let width: Double
    package let isValid: Bool
    /// The matched reflector family ("{111}"); nil when the assignment did not match the band (outside the angle tolerance) or the
    /// point is not indexed.
    package let family: String?
    /// The angle (degrees) between the band's normal and its pole after the QUEST fit, for the (at most six) matched bands the fit
    /// weighed; nil for the others.
    package let fitDegrees: Double?
    /// The band's centre line on the pattern, (column, row) with pixel centres at integers and row 0 at the top; nil when it misses.
    package let start: SIMD2<Double>?
    package let end: SIMD2<Double>?

    package var isMatched: Bool { family != nil }

    /// The bands of a pattern of `rows` × `columns` px with what `solution` (nil: none) matched them to, `libraries` in the solution's
    /// phase order.
    package static func bands(_ bands: [HoughBandDetector.Band], solution: HoughIndexer.Solution?, libraries: [HoughReflectorLibrary],
                              rows: Int, columns: Int) -> [IndexedBand] {
        let library: HoughReflectorLibrary? = solution.flatMap { libraries.indices.contains($0.phase) ? libraries[$0.phase] : nil }
        return bands.enumerated().map { k, band in
            var family: String?, fit: Double?
            if let solution, let library, solution.bandMatch.indices.contains(k),
               solution.bandMatched.indices.contains(k), solution.bandMatched[k] {
                let variant = solution.bandMatch[k]
                if variant >= 0, library.familyID.indices.contains(variant) {
                    let f = library.familyID[variant]
                    if library.poleFamilies.indices.contains(f) { family = familyLabel(library.poleFamilies[f]) }
                    if solution.bandFit.indices.contains(k), solution.bandFit[k] < 180 { fit = solution.bandFit[k] }
                }
            }
            let line = band.valid ? segment(rho: band.rho, theta: band.theta, rows: rows, columns: columns) : nil
            return IndexedBand(id: k + 1, rho: band.rho, thetaDegrees: band.theta * 180 / Double.pi, peak: band.max, width: band.width,
                               isValid: band.valid, family: family, fitDegrees: fit, start: line?.start, end: line?.end)
        }
    }

    /// "{111}", "{002}", "{10-11}".
    package static func familyLabel(_ hkl: [Int]) -> String {
        let wide = hkl.contains { abs($0) > 9 }
        return "{" + hkl.map(String.init).joined(separator: wide ? " " : "") + "}"
    }

    /// The centre line of the band (rho, theta) on a pattern of `rows` × `columns` px, clipped to the pattern. The band detector's
    /// frame (`HoughBandDetector`): x right and y UP from the pattern centre, the band the points with x cos θ + y sin θ = ρ; the
    /// pattern's pixel centres are at column − (columns − 1)/2 and (rows − 1)/2 − row in it.
    package static func segment(rho: Double, theta: Double, rows: Int, columns: Int) -> (start: SIMD2<Double>, end: SIMD2<Double>)? {
        guard rows > 0, columns > 0, rho.isFinite, theta.isFinite else { return nil }
        let s = sin(theta), c = cos(theta)
        let foot = SIMD2(rho * c + Double(columns - 1) / 2, Double(rows - 1) / 2 - rho * s)
        let direction = SIMD2(s, c)
        let lo = SIMD2(-0.5, -0.5), hi = SIMD2(Double(columns) - 0.5, Double(rows) - 0.5)
        var t0 = -Double.infinity, t1 = Double.infinity
        for axis in 0..<2 {
            if abs(direction[axis]) < 1e-12 {
                if foot[axis] < lo[axis] || foot[axis] > hi[axis] { return nil }
            } else {
                let a = (lo[axis] - foot[axis]) / direction[axis], b = (hi[axis] - foot[axis]) / direction[axis]
                t0 = max(t0, min(a, b))
                t1 = min(t1, max(a, b))
            }
        }
        guard t0 < t1 else { return nil }
        return (foot + t0 * direction, foot + t1 * direction)
    }
}

// MARK: - The colour key

package nonisolated enum IndexingColorKey {
    /// The Euler colour key of a point group in words (orix's `EulerColorKey`: each Bunge angle over the largest it takes in the Euler
    /// fundamental region of the proper subgroup): "R φ₁ 0–360° · G Φ 0–90° · B φ₂ 0–90°" for m-3m.
    package static func eulerWords(_ pointGroup: PointGroup) -> String {
        let region = pointGroup.eulerFundamentalRegion
        return "R φ₁ 0–\(region[0])° · G Φ 0–\(region[1])° · B φ₂ 0–\(region[2])°"
    }

    /// The IPF colour key of a point group as a picture about `side` pixels on its longer edge (orix's TSL key in the stereographic
    /// projection; pixels outside the sector are transparent).
    package static func image(_ pointGroup: PointGroup, side: Int = 160) -> IPFKeyImage {
        let key = DirectionColorKeyTSL(pointGroup)
        let extent = key.sector.stereographicExtent ?? (-1...1, -1...1)
        let span = max(extent.x.upperBound - extent.x.lowerBound, extent.y.upperBound - extent.y.lowerBound)
        return key.keyImage(step: max(span / Double(max(side, 8)), 1e-4), extent: extent)
    }
}
