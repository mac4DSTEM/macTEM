//
//  IndexingDictionary.swift
//  Role: what one dictionary run of the Indexing room is made of (docs/sem/design/indexing-room.md §4, D-SEM-91): the method the room
//        indexes with (`IndexingMethod`), kikuchipy's `dictionary_indexing` settings the Dictionary section edits
//        (`DictionaryIndexingSettings`), the master pattern opened for it (`IndexingMasterPattern`, an EMsoft file read as kikuchipy
//        reads it for a projection: Lambert, both hemispheres), and the plan built from them (`DictionaryIndexingPlan`): the
//        orientations sampled in the phase's fundamental zone (orix's `sample_SO3`, cubochoric), the detector with the indexed pattern
//        shape and the file's mean projection centre, the energy, and the scan cut into row blocks the room indexes one after the other.
//
//  The numbers are `DictionaryIndexing`'s (kikuchipy 0.13.1's port, figure F9), `MasterPatternProjection`'s and `OrientationSampling`'s;
//  this file decides only what goes in. A block's patterns are read through the room's `IndexingSource` (the Patterns room's pipeline,
//  D-SEM-83) and matched against the whole dictionary, projected chunk by chunk inside `DictionaryIndexing`, so a block's result equals
//  the whole scan's at those points: the score of a pattern against a simulation does not depend on the other patterns. The backend
//  (float64 CPU or float32 GPU) is chosen once for the run from the whole scan's work, so a short last block runs the same path.
//

import Foundation

/// How the Indexing room indexes (D-SEM-91): pyEBSDindex's Hough indexing or kikuchipy's dictionary indexing.
package nonisolated enum IndexingMethod: String, Sendable, Codable, CaseIterable, Identifiable {
    case hough, dictionary

    package var id: String { rawValue }

    package var title: String {
        switch self {
        case .hough: "Hough"
        case .dictionary: "Dictionary"
        }
    }
}

nonisolated extension DictionaryIndexing.Metric: Codable {
    /// The Metric segment's word and the score's name: "NCC", "NDP".
    package var title: String { rawValue.uppercased() }

    /// What the score is, in kikuchipy's words.
    package var help: String {
        switch self {
        case .ncc: "The normalised cross-correlation: each pattern centred and divided by its norm, then the dot product (kikuchipy's ncc)"
        case .ndp: "The normalised dot product: each pattern divided by its norm, not centred (kikuchipy's ndp)"
        }
    }
}

/// kikuchipy's `EBSD.dictionary_indexing` settings the Dictionary section edits, with the sampling of the dictionary's orientations.
package nonisolated struct DictionaryIndexingSettings: Sendable, Equatable, Codable {
    /// Which detector pixels the comparison takes (kikuchipy's `signal_mask`).
    package enum SignalMask: String, Sendable, Codable, CaseIterable, Identifiable {
        /// Every pixel.
        case none
        /// The pixels inside kikuchipy's circular window (`~kp.filters.Window("circular", shape)`): the corners left out.
        case circular

        package var id: String { rawValue }
        package var title: String {
            switch self {
            case .none: "None"
            case .circular: "Circular"
            }
        }
    }

    /// The angular resolution of orix's cubochoric sampling of the phase's fundamental zone, degrees (`sample_SO3(resolution=…)`).
    package var resolution = 4.0
    package var metric = DictionaryIndexing.Metric.ncc
    /// The best matches kept per pattern (`keep_n`).
    package var keep = 5
    package var signalMask = SignalMask.none

    package init() {}

    /// Figure F9's settings (D-SEM-91): 4° (11 935 orientations of m-3m), NCC, keep 5, no signal mask.
    package static let roomDefault = DictionaryIndexingSettings()

    package static let resolutionRange = 1.0...15.0
    package static let keepRange = 1...50

    /// Why these settings cannot run, in the room's words; nil when they can.
    package var refusal: String? {
        guard resolution.isFinite, Self.resolutionRange.contains(resolution) else { return "The angular resolution runs from 1° to 15°." }
        guard Self.keepRange.contains(keep) else { return "Keep runs from 1 to 50 matches." }
        return nil
    }

    /// The signal mask for a pattern of `rows` × `columns` px, `true` where a pixel is left out (kikuchipy's polarity); nil for none.
    package func signalMask(rows: Int, columns: Int) throws -> [Bool]? {
        switch signalMask {
        case .none: return nil
        case .circular: return try PatternWindow.circular(rows: rows, columns: columns).values.map { $0 == 0 }
        }
    }
}

/// A master pattern opened in the Dictionary section: an EMsoft EBSD or TKD master pattern file read as kikuchipy reads it for a
/// projection (`kp.load(…, projection="lambert", hemisphere="both")`), every energy.
package nonisolated struct IndexingMasterPattern: Sendable, Identifiable {
    package let url: URL
    package let master: EBSDMasterPattern

    /// The file's path: opening the same file again picks the one already open.
    package var id: String { url.standardizedFileURL.path }
    package var fileName: String { url.lastPathComponent }

    /// The energies, "20 kV" or "10 to 20 kV".
    package var energyWords: String {
        guard let low = master.energies.min(), let high = master.energies.max() else { return "no energy" }
        let format = { (v: Double) in v.formatted(.number.precision(.significantDigits(1...4))) }
        return low == high ? "\(format(low)) kV" : "\(format(low)) to \(format(high)) kV"
    }

    /// The value row: "ni · 20 kV · Lambert · 401 × 401".
    package var summary: String {
        "\(master.phase.name) · \(energyWords) · Lambert · \(master.side) × \(master.side)"
    }

    /// Reads `url` (call it off the main actor: an HDF5 read of a few to some hundred megabytes). Refuses a file that is not an EMsoft
    /// master pattern, an ECP master pattern, and one a projection cannot take.
    package static func load(_ url: URL) throws -> IndexingMasterPattern {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let type = EMsoftMasterPatternReader.sniff(url: url) else {
            throw IndexingRefusal("\(url.lastPathComponent) is not an EMsoft master pattern file.")
        }
        guard type != .ecp else {
            throw IndexingRefusal("\(url.lastPathComponent) is an ECP master pattern; EBSD indexing takes an EBSD or TKD one.")
        }
        let master = try EMsoftMasterPatternReader.read(url: url, type: type, projection: .lambert, hemisphere: .both)
        try MasterPatternProjection.checkSuitable(master)
        return IndexingMasterPattern(url: url, master: master)
    }
}

/// One dictionary run of the room: the patterns, the phase and its master pattern, the dictionary's orientations, the detector and the
/// energy the dictionary is projected for, and the scan's row blocks.
package nonisolated struct DictionaryIndexingPlan: Sendable {
    package let source: IndexingSource
    package let phase: IndexingPhase
    package let master: IndexingMasterPattern
    package let settings: DictionaryIndexingSettings
    /// The dictionary's orientations, orix's quaternions in the sample frame (the frame of Hough's solutions).
    package let rotations: [SIMD4<Double>]
    /// The detector the dictionary is projected on: the indexed pattern's shape, the file's tilts, its mean projection centre.
    package let detector: EBSDDetectorGeometry
    /// The master pattern's energy the projection takes (nil: its highest, kikuchipy's default), and the words that say which.
    package let energy: Double?
    package let energyWords: String
    /// kikuchipy's arguments, with the backend the whole run takes (`DictionaryIndexing`'s automatic choice from the whole scan's work).
    package let options: DictionaryIndexing.Options
    /// Scan rows per block (the last may hold fewer).
    package let rowsPerBlock: Int

    /// The experimental patterns of one block stay within this many bytes as float64 (D-SEM-92); the dictionary's chunks are then
    /// `DictionaryIndexing`'s own memory budget. The demo scan (4125 patterns of 60 × 60) is one block.
    package static let blockBudget = 128 << 20

    /// Why the room cannot index with a dictionary now, without building anything; nil when it can.
    package static func refusal(phases: [IndexingPhase], master: IndexingMasterPattern?, settings: DictionaryIndexingSettings,
                                detector: EBSDDetectorGeometry, beamEnergy: Double?) -> String? {
        let on = phases.filter(\.isOn)
        if phases.isEmpty { return "Add a phase first: from the file, a preset or a CIF." }
        if on.isEmpty { return "Turn a phase on to index against it." }
        guard on.count == 1, let phase = on.first else {
            return "Dictionary indexing takes one phase and its master pattern: turn the others off."
        }
        guard (1...230).contains(phase.spaceGroup) else { return "\(phase.name): space group \(phase.spaceGroup) is outside 1 to 230." }
        guard phase.pointGroup != nil else { return "\(phase.name): no point group is known for space group \(phase.spaceGroup)." }
        guard let master else { return "Open a master pattern for \(phase.name) in Dictionary." }
        if master.master.phase.spaceGroup != phase.spaceGroup {
            return "The master pattern is for \(master.master.phase.name) (space group \(master.master.phase.spaceGroup)), the phase is "
                + "\(phase.name) (space group \(phase.spaceGroup))."
        }
        if let why = settings.refusal { return why }
        if IndexingPlan.meanProjectionCenter(detector) == nil { return "The file states no projection centre, which dictionary indexing needs." }
        if case .failure(let refusal) = energy(master: master.master, beamEnergy: beamEnergy) { return refusal.sentence }
        return nil
    }

    /// The energy the dictionary is projected for: the master pattern's one energy; with several, the scan's beam energy (refused
    /// outside the master pattern's), or the highest when the scan states none (kikuchipy's default). A beam energy of 0 or less is
    /// none: kikuchipy's h5ebsd writer stores 0 when the signal has no beam energy.
    package static func energy(master: EBSDMasterPattern, beamEnergy: Double?) -> Result<(value: Double?, words: String), IndexingRefusal> {
        let format = { (v: Double) in v.formatted(.number.precision(.significantDigits(1...4))) }
        guard let low = master.energies.min(), let high = master.energies.max() else {
            return .failure(IndexingRefusal("The master pattern holds no energy."))
        }
        if master.energies.count == 1 { return .success((nil, "\(format(high)) kV, the master pattern's one energy")) }
        guard let beam = beamEnergy, beam.isFinite, beam > 0 else {
            return .success((nil, "\(format(high)) kV, the highest; the scan states no beam energy"))
        }
        let step = master.energies.count > 1 ? (high - low) / Double(master.energies.count - 1) : 0
        guard beam >= low - step / 2, beam <= high + step / 2 else {
            return .failure(IndexingRefusal("The scan's beam energy, \(format(beam)) kV, is outside the master pattern's \(format(low)) to \(format(high)) kV."))
        }
        let nearest = master.energies.min { abs($0 - beam) < abs($1 - beam) } ?? high
        return .success((min(max(beam, low), high), "\(format(nearest)) kV, the scan's beam energy"))
    }

    /// The detector a dictionary of patterns of `rows` × `columns` px is projected on: the file's (its shape is the stored pattern's) with
    /// the tilts, the binning folded in, and the mean of its projection centres (kikuchipy's `pc_average`; the projection takes one
    /// centre for every rotation). nil without a centre.
    package static func detector(_ file: EBSDDetectorGeometry, rows: Int, columns: Int) -> EBSDDetectorGeometry? {
        guard let pc = IndexingPlan.meanProjectionCenter(file), rows > 0, columns > 0 else { return nil }
        var detector = file
        detector.binning = file.binning * max(file.rows / rows, 1)
        detector.rows = rows
        detector.columns = columns
        detector.projectionCenters = [pc]
        return detector
    }

    /// The point group the dictionary samples (the phase's; an improper group samples its proper subgroup's zone, as orix does).
    package static func pointGroup(of phase: IndexingPhase) -> PointGroup? { phase.pointGroup }

    /// orix's `sample_SO3(phase.point_group, resolution, method="cubochoric")` as quaternions (call it off the main actor: 1° is about
    /// 800 000 orientations).
    @concurrent package static func sample(resolution: Double, pointGroup: PointGroup) async throws -> [SIMD4<Double>] {
        do {
            return try await OrientationSampling.fundamentalSample(resolution: resolution, pointGroup: pointGroup).map(\.q)
        } catch is OrientationSampling.Error {
            throw IndexingRefusal("The orientations cannot be sampled at \(resolution)°.")
        }
    }

    /// Scan rows per block for patterns of `pixels` values in a scan `scanColumns` wide.
    package static func rowsPerBlock(scanRows: Int, scanColumns: Int, pixels: Int) -> Int {
        let perRow = max(scanColumns * pixels * MemoryLayout<Double>.stride, 1)
        return min(max(blockBudget / perRow, 1), max(scanRows, 1))
    }

    /// The dictionary's chunking for a block of `points` patterns: patterns per chunk and chunks (`DictionaryIndexing.chunkSize`).
    package static func chunking(points: Int, keptPixels: Int, dictionary: Int, options: DictionaryIndexing.Options) -> (size: Int, chunks: Int) {
        guard dictionary > 0, let size = try? DictionaryIndexing.chunkSize(options, experimental: points, length: keptPixels, dictionary: dictionary) else {
            return (0, 0)
        }
        return (size, (dictionary + size - 1) / size)
    }

    /// The plan, with the dictionary's orientations already sampled (`sample`) for the phase on.
    package init(source: IndexingSource, phases: [IndexingPhase], master: IndexingMasterPattern, settings: DictionaryIndexingSettings,
                 fileDetector: EBSDDetectorGeometry, beamEnergy: Double?, rotations: [SIMD4<Double>]) throws {
        if let why = Self.refusal(phases: phases, master: master, settings: settings, detector: fileDetector, beamEnergy: beamEnergy) {
            throw IndexingRefusal(why)
        }
        guard let phase = phases.first(where: \.isOn),
              let detector = Self.detector(fileDetector, rows: source.patternRows, columns: source.patternColumns) else {
            throw IndexingRefusal("The file states no projection centre, which dictionary indexing needs.")
        }
        guard !rotations.isEmpty else { throw IndexingRefusal("The dictionary holds no orientation.") }
        guard case .success(let energy) = Self.energy(master: master.master, beamEnergy: beamEnergy) else {
            throw IndexingRefusal("The master pattern holds no energy for the scan.")
        }
        self.source = source
        self.phase = phase
        self.master = master
        self.settings = settings
        self.rotations = rotations
        self.detector = detector
        self.energy = energy.value
        energyWords = energy.words
        let mask = try settings.signalMask(rows: source.patternRows, columns: source.patternColumns)
        let kept = mask.map { $0.filter { !$0 }.count } ?? source.patternRows * source.patternColumns
        options = DictionaryIndexing.Options(metric: settings.metric, keepN: settings.keep, signalMask: mask,
                                             backend: Self.backend(points: source.scanRows * source.scanColumns, dictionary: rotations.count,
                                                                   keptPixels: kept))
        rowsPerBlock = Self.rowsPerBlock(scanRows: source.scanRows, scanColumns: source.scanColumns,
                                         pixels: source.patternRows * source.patternColumns)
    }

    /// One backend for the whole run (D-SEM-92): `DictionaryIndexing`'s automatic choice from the whole scan's work (points × dictionary
    /// × kept pixels), so every block, a short last one included, projects and matches on the same path and gives what the whole scan
    /// gives. Left automatic per block, a last block under the threshold would run the float64 CPU path beside float32 GPU blocks.
    package static func backend(points: Int, dictionary: Int, keptPixels: Int) -> DictionaryIndexing.Backend {
        let (perPoint, a) = dictionary.multipliedReportingOverflow(by: keptPixels)
        let (work, b) = points.multipliedReportingOverflow(by: perPoint)
        return DictionaryIndexing.usesMetal(.automatic, work: a || b ? .max : work) ? .metal : .cpu
    }

    /// The scan's row blocks, in order.
    package var blocks: [Range<Int>] {
        stride(from: 0, to: source.scanRows, by: rowsPerBlock).map { $0 ..< min($0 + rowsPerBlock, source.scanRows) }
    }

    /// The pixels the comparison takes.
    package var keptPixels: Int {
        let pixels = source.patternRows * source.patternColumns
        return options.signalMask.map { mask in mask.filter { !$0 }.count } ?? pixels
    }

    /// The chunks of the dictionary each block runs through, in block order (the toolbar's "k of n chunks").
    package var chunksPerBlock: [Int] {
        blocks.map { Self.chunking(points: $0.count * source.scanColumns, keptPixels: keptPixels, dictionary: rotations.count, options: options).chunks }
    }

    /// Indexes the scan rows `rows` against the dictionary (their patterns read here, the dictionary projected chunk by chunk);
    /// `progress` hears of each chunk merged. A cancelled task stops before the next chunk. Off the caller's actor.
    @concurrent package func indexBlock(_ rows: Range<Int>, progress: DictionaryIndexing.Progress? = nil) async throws -> DictionaryIndexing.Result {
        var experimental: [Double] = []
        experimental.reserveCapacity(rows.count * source.scanColumns * source.patternRows * source.patternColumns)
        for row in rows {
            try Task.checkCancellation()
            for pattern in try source.patterns(row: row) { experimental.append(contentsOf: pattern) }
        }
        return try await DictionaryIndexing.indexAsync(experimental: experimental, navigationShape: [rows.count, source.scanColumns],
                                                       master: master.master, rotations: rotations, detector: detector, energy: energy,
                                                       options: options, progress: progress)
    }

    /// The simulated pattern of one of the dictionary's orientations on the run's detector, -1 to 1 (or as stored for a float32 master
    /// pattern; the Best match pane).
    package func simulated(_ rotation: SIMD4<Double>) async throws -> [Float] {
        try await MasterPatternProjection.patternsFloat32Async(master: master.master, rotations: [rotation], detector: detector,
                                                               energy: energy, backend: .cpu)
    }

    // MARK: - The method record

    private struct Record: Encodable {
        struct Master: Encodable {
            var file: String
            var phase: String
            var spaceGroup: Int
            var energies: [Double]
            var side: Int
            var projection: String
            var hemisphere: String
        }

        var software: String
        var method: String
        var reference: String
        var file: String
        var patterns: String
        var processing: PatternPipeline?
        var phase: IndexingPhase
        var masterPattern: Master
        var energy: String
        /// The energy handed to `get_patterns` (nil: its default, the highest).
        var energyKeV: Double?
        var samplingResolutionDegrees: Double
        var samplingMethod: String
        var dictionarySize: Int
        var metric: String
        var keepN: Int
        var signalMask: String
        var detectorShape: [Int]
        var projectionCenterBruker: [Double]
        var sampleTilt: Double
        var cameraElevation: Double
        var azimuthal: Double
        var twist: Double
        var points: Int
        var indexed: Int
    }

    /// Every input of the run in kikuchipy's and orix's terms, to redo it in Python (`sample_SO3`, `mp.get_patterns(rotations, det,
    /// energy)`, `s.dictionary_indexing(dictionary, metric=…, keep_n=…, signal_mask=…)`).
    package func methodJSON(fileName: String, points: Int, indexed: Int) throws -> Data {
        let pc = detector.projectionCenters.first ?? SIMD3(0, 0, 0)
        let m = master.master
        let record = Record(
            software: "macTEM", method: "Dictionary indexing (simulated patterns of a master pattern, normalised cross-correlation or dot product)",
            reference: "kikuchipy 0.13.1 EBSD.dictionary_indexing and EBSDMasterPattern.get_patterns; orix 0.15.0 sample_SO3 (cubochoric)",
            file: fileName, patterns: source.kind.title, processing: source.pipeline, phase: phase,
            masterPattern: Record.Master(file: master.fileName, phase: m.phase.name, spaceGroup: m.phase.spaceGroup, energies: m.energies,
                                         side: m.side, projection: m.projection.rawValue, hemisphere: m.hemisphere.rawValue),
            energy: energyWords, energyKeV: energy, samplingResolutionDegrees: settings.resolution, samplingMethod: "cubochoric", dictionarySize: rotations.count,
            metric: settings.metric.rawValue, keepN: min(settings.keep, rotations.count), signalMask: settings.signalMask.rawValue,
            detectorShape: [detector.rows, detector.columns], projectionCenterBruker: [pc.x, pc.y, pc.z], sampleTilt: detector.sampleTilt,
            cameraElevation: detector.tilt, azimuthal: detector.azimuthal, twist: detector.twist, points: points, indexed: indexed)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(record)
    }
}
