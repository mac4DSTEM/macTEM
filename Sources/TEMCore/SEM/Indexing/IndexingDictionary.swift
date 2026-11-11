//
//  IndexingDictionary.swift
//  Role: what one dictionary run of the Indexing room is made of (docs/sem/design/indexing-room.md §4, D-SEM-91, D-SEM-98): the
//        method the room indexes with (`IndexingMethod`), kikuchipy's `dictionary_indexing` settings the Dictionary section edits
//        (`DictionaryIndexingSettings`), the master patterns opened for it (`IndexingMasterPattern`, an EMsoft file read as kikuchipy
//        reads it for a projection: Lambert, both hemispheres; each phase on takes one, `preferred(for:among:)` until one is picked),
//        and the plans built from them (`DictionaryIndexingPlan`, one per phase on, `plans`): the orientations sampled in the phase's
//        fundamental zone (orix's `sample_SO3`, cubochoric), the detector with the indexed pattern shape and the file's mean
//        projection centre, the energy, and the scan cut into row blocks the room indexes one after the other, each block read once and
//        matched against every phase's dictionary in turn (kikuchipy's multi-phase recipe: one `dictionary_indexing` per phase, then
//        `merge_crystal_maps`).
//
//  The numbers are `DictionaryIndexing`'s (kikuchipy 0.13.1's port, figure F9), `MasterPatternProjection`'s and `OrientationSampling`'s;
//  this file decides only what goes in. A block's patterns are read through the room's `IndexingSource` (the Patterns room's pipeline,
//  D-SEM-83) and matched against the whole dictionary, projected chunk by chunk inside `DictionaryIndexing`, so a block's result equals
//  the whole scan's at those points: the score of a pattern against a simulation does not depend on the other patterns. The backend
//  (float64 CPU or float32 GPU) is chosen once for the run from the whole scan's work against every phase's dictionary, so a short last
//  block and every phase run the same path.
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

    /// `master` as read from `url` (`load` reads it).
    package init(url: URL, master: EBSDMasterPattern) {
        self.url = url
        self.master = master
    }

    /// The file's path: opening the same file again picks the one already open.
    package var id: String { url.standardizedFileURL.path }
    package var fileName: String { url.lastPathComponent }

    /// The energies, "20 kV" or "10 to 20 kV", in the reader's locale (`energyWords(locale:)`).
    package var energyWords: String { self.energyWords(locale: .autoupdatingCurrent) }

    /// `energyWords` with its numbers in `locale`: the session report passes its own (`en_US_POSIX`), "12.5 kV" on every Mac.
    package func energyWords(locale: Locale) -> String {
        guard let low = master.energies.min(), let high = master.energies.max() else { return "no energy" }
        let format = { (v: Double) in v.formatted(.number.locale(locale).precision(.significantDigits(1...4))) }
        return low == high ? "\(format(low)) kV" : "\(format(low)) to \(format(high)) kV"
    }

    /// The value row: "ni · 20 kV · Lambert · 401 × 401", in the reader's locale (`summary(locale:)`).
    package var summary: String { self.summary(locale: .autoupdatingCurrent) }

    /// `summary` with its energies in `locale` (the session report's Master row).
    package func summary(locale: Locale) -> String {
        "\(master.phase.name) · \(self.energyWords(locale: locale)) · Lambert · \(master.side) × \(master.side)"
    }

    /// The master pattern a phase takes until one is picked for it (D-SEM-98): the latest opened whose phase has the phase's space
    /// group and name (ignoring case, so the preset "Ni" takes kikuchipy's "ni"), else the latest opened of its space group, else the
    /// latest opened (which `DictionaryIndexingPlan.refusal` then names as the wrong one). nil when none is open.
    package static func preferred(for phase: IndexingPhase, among masters: [IndexingMasterPattern]) -> IndexingMasterPattern? {
        let sameGroup = masters.filter { $0.master.phase.spaceGroup == phase.spaceGroup }
        return sameGroup.last { $0.master.phase.name.lowercased() == phase.name.lowercased() } ?? sameGroup.last ?? masters.last
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

/// One phase's dictionary in a run of the room: the patterns, the phase and its master pattern, the dictionary's orientations, the
/// detector and the energy the dictionary is projected for, and the scan's row blocks. A run against several phases holds one per
/// phase (`plans`, D-SEM-98).
package nonisolated struct DictionaryIndexingPlan: Sendable {
    package let source: IndexingSource
    package let phase: IndexingPhase
    package let master: IndexingMasterPattern
    package let settings: DictionaryIndexingSettings
    /// The dictionary's orientations, orix's quaternions in the sample frame (the frame of Hough's solutions).
    package let rotations: [SIMD4<Double>]
    /// The detector the dictionary is projected on: the indexed pattern's shape, the file's tilts, its mean projection centre.
    package let detector: EBSDDetectorGeometry
    /// The master pattern's energy the projection takes (nil: its highest, kikuchipy's default), and the words that say which, in
    /// the reader's locale (`energyWords(locale:)` writes them in another).
    package let energy: Double?
    package let energyWords: String
    /// The scan's beam energy the plan was built for, which the words name.
    private let beamEnergy: Double?
    /// kikuchipy's arguments, with the backend the whole run takes (`DictionaryIndexing`'s automatic choice from the whole scan's work).
    package let options: DictionaryIndexing.Options
    /// Scan rows per block (the last may hold fewer).
    package let rowsPerBlock: Int

    /// The experimental patterns of one block stay within this many bytes as float64 (D-SEM-92); the dictionary's chunks are then
    /// `DictionaryIndexing`'s own memory budget. The demo scan (4125 patterns of 60 × 60) is one block.
    package static let blockBudget = 128 << 20

    /// Why the room cannot index with a dictionary now, without building anything; nil when it can. Every phase on is checked in
    /// turn (D-SEM-98), against its master pattern in `masters` (by `IndexingPhase.id`); one phase keeps D-SEM-91's sentences.
    package static func refusal(phases: [IndexingPhase], masters: [String: IndexingMasterPattern], settings: DictionaryIndexingSettings,
                                detector: EBSDDetectorGeometry, beamEnergy: Double?) -> String? {
        let on = phases.filter(\.isOn)
        if phases.isEmpty { return "Add a phase first: from the file, a preset or a CIF." }
        if on.isEmpty { return "Turn a phase on to index against it." }
        for phase in on {
            guard (1...230).contains(phase.spaceGroup) else { return "\(phase.name): space group \(phase.spaceGroup) is outside 1 to 230." }
            guard phase.pointGroup != nil else { return "\(phase.name): no point group is known for space group \(phase.spaceGroup)." }
            guard let master = masters[phase.id] else { return "Open a master pattern for \(phase.name) in Dictionary." }
            if master.master.phase.spaceGroup != phase.spaceGroup {
                return "The master pattern is for \(master.master.phase.name) (space group \(master.master.phase.spaceGroup)), the phase is "
                    + "\(phase.name) (space group \(phase.spaceGroup))."
            }
        }
        if let why = settings.refusal { return why }
        if IndexingPlan.meanProjectionCenter(detector) == nil { return "The file states no projection centre, which dictionary indexing needs." }
        for phase in on {
            guard let master = masters[phase.id], case .failure(let refusal) = energy(master: master.master, beamEnergy: beamEnergy) else { continue }
            return on.count == 1 ? refusal.sentence : "\(phase.name): " + refusal.sentence
        }
        return nil
    }

    /// `refusal(phases:masters:…)` with every phase on against `master` (one phase's plan; nil: none open).
    package static func refusal(phases: [IndexingPhase], master: IndexingMasterPattern?, settings: DictionaryIndexingSettings,
                                detector: EBSDDetectorGeometry, beamEnergy: Double?) -> String? {
        let masters = master.map { m in Dictionary(phases.map { ($0.id, m) }, uniquingKeysWith: { first, _ in first }) } ?? [:]
        return refusal(phases: phases, masters: masters, settings: settings, detector: detector, beamEnergy: beamEnergy)
    }

    /// The energy the dictionary is projected for: the master pattern's one energy; with several, the scan's beam energy (refused
    /// outside the master pattern's), or the highest when the scan states none (kikuchipy's default). A beam energy of 0 or less is
    /// none: kikuchipy's h5ebsd writer stores 0 when the signal has no beam energy. The words and the refusal have their numbers in
    /// `locale`: the reader's for the room, `en_US_POSIX` for the method JSON (`energyWords(locale:)`).
    package static func energy(master: EBSDMasterPattern, beamEnergy: Double?,
                               locale: Locale = .autoupdatingCurrent) -> Result<(value: Double?, words: String), IndexingRefusal> {
        let format = { (v: Double) in v.formatted(.number.locale(locale).precision(.significantDigits(1...4))) }
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

    /// `energyWords` with its numbers in `locale`: the method JSON writes `en_US_POSIX`, the session report its own locale, so a German
    /// Mac writes "12.5 kV" in a file and "12,5 kV" on screen.
    package func energyWords(locale: Locale) -> String {
        guard case .success(let energy) = Self.energy(master: master.master, beamEnergy: beamEnergy, locale: locale) else { return energyWords }
        return energy.words
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

    /// The plan of `phase`'s dictionary, its orientations already sampled (`sample`), refused as `refusal` refuses the phase against
    /// `master`. `backend`: the run's (`plans`, chosen from every phase's work), or nil to choose from this dictionary's alone.
    package init(source: IndexingSource, phase: IndexingPhase, master: IndexingMasterPattern, settings: DictionaryIndexingSettings,
                 fileDetector: EBSDDetectorGeometry, beamEnergy: Double?, rotations: [SIMD4<Double>],
                 backend: DictionaryIndexing.Backend? = nil) throws {
        if let why = Self.refusal(phases: [phase], master: master, settings: settings, detector: fileDetector, beamEnergy: beamEnergy) {
            throw IndexingRefusal(why)
        }
        guard let detector = Self.detector(fileDetector, rows: source.patternRows, columns: source.patternColumns) else {
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
        self.beamEnergy = beamEnergy
        let mask = try settings.signalMask(rows: source.patternRows, columns: source.patternColumns)
        let kept = mask.map { $0.filter { !$0 }.count } ?? source.patternRows * source.patternColumns
        options = DictionaryIndexing.Options(metric: settings.metric, keepN: settings.keep, signalMask: mask,
                                             backend: backend ?? Self.backend(points: source.scanRows * source.scanColumns,
                                                                              dictionary: rotations.count, keptPixels: kept))
        rowsPerBlock = Self.rowsPerBlock(scanRows: source.scanRows, scanColumns: source.scanColumns,
                                         pixels: source.patternRows * source.patternColumns)
    }

    /// The plans of a run against the phases on (D-SEM-98), one per phase in their order: phase i's dictionary of `rotations[i]`,
    /// projected from `masters[phase.id]`. Refused as `refusal` refuses. One backend for every phase, chosen from the whole run's work
    /// (every dictionary over the whole scan), so the phases are scored on one path as kikuchipy scores every dictionary in one dtype;
    /// one phase gets exactly its plan's own choice. The phases' maps keep as many matches (kikuchipy's merge needs it).
    package static func plans(source: IndexingSource, phases: [IndexingPhase], masters: [String: IndexingMasterPattern],
                              settings: DictionaryIndexingSettings, fileDetector: EBSDDetectorGeometry, beamEnergy: Double?,
                              rotations: [[SIMD4<Double>]]) throws -> [DictionaryIndexingPlan] {
        if let why = refusal(phases: phases, masters: masters, settings: settings, detector: fileDetector, beamEnergy: beamEnergy) {
            throw IndexingRefusal(why)
        }
        let on = phases.filter(\.isOn)
        guard rotations.count == on.count else { throw IndexingRefusal("Each phase on needs its dictionary's orientations.") }
        let mask = try settings.signalMask(rows: source.patternRows, columns: source.patternColumns)
        let kept = mask.map { $0.filter { !$0 }.count } ?? source.patternRows * source.patternColumns
        let shared = Self.backend(points: source.scanRows * source.scanColumns, dictionary: rotations.reduce(0) { $0 + $1.count },
                                  keptPixels: kept)
        var plans: [DictionaryIndexingPlan] = []
        for (phase, sample) in zip(on, rotations) {
            guard let master = masters[phase.id] else { throw IndexingRefusal("Open a master pattern for \(phase.name) in Dictionary.") }
            plans.append(try DictionaryIndexingPlan(source: source, phase: phase, master: master, settings: settings, fileDetector: fileDetector,
                                                    beamEnergy: beamEnergy, rotations: sample, backend: shared))
        }
        if plans.count > 1, let small = plans.first(where: { $0.rotations.count < settings.keep }) {
            throw IndexingRefusal("Keep is above the \(small.phase.name) dictionary's \(small.rotations.count) patterns; the phases' maps "
                + "must keep as many matches to be merged.")
        }
        return plans
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

    /// The experimental patterns of scan rows `rows`, read through the room's source, row after row. Off the caller's actor.
    @concurrent package func readBlock(_ rows: Range<Int>) async throws -> [Double] {
        var experimental: [Double] = []
        experimental.reserveCapacity(rows.count * source.scanColumns * source.patternRows * source.patternColumns)
        for row in rows {
            try Task.checkCancellation()
            for pattern in try source.patterns(row: row) { experimental.append(contentsOf: pattern) }
        }
        return experimental
    }

    /// Indexes the scan rows `rows` against the dictionary (projected chunk by chunk); `experimental` holds their patterns as
    /// `readBlock` reads them (a run against several phases reads a block once for every phase), nil reads them here. `progress`
    /// hears of each chunk merged. A cancelled task stops before the next chunk. Off the caller's actor.
    @concurrent package func indexBlock(_ rows: Range<Int>, experimental: [Double]? = nil,
                                        progress: DictionaryIndexing.Progress? = nil) async throws -> DictionaryIndexing.Result {
        let patterns: [Double]
        if let experimental { patterns = experimental } else { patterns = try await readBlock(rows) }
        return try await DictionaryIndexing.indexAsync(experimental: patterns, navigationShape: [rows.count, source.scanColumns],
                                                       master: master.master, rotations: rotations, detector: detector, energy: energy,
                                                       options: options, progress: progress)
    }

    /// The simulated pattern of one of the dictionary's orientations on the run's detector, -1 to 1 (or as stored for a float32 master
    /// pattern; the Best match pane); at `projectionCenter` (Bruker) in place of the detector's mean one when given (a refinement's
    /// refined PC, D-SEM-109).
    package func simulated(_ rotation: SIMD4<Double>, projectionCenter: SIMD3<Double>? = nil) async throws -> [Float] {
        var onDetector = detector
        if let projectionCenter { onDetector.projectionCenters = [projectionCenter] }
        return try await MasterPatternProjection.patternsFloat32Async(master: master.master, rotations: [rotation], detector: onDetector,
                                                                      energy: energy, backend: .cpu)
    }

    // MARK: - The method record

    /// The locale of the words a method record writes (the energy's): a decimal point on every Mac.
    private static let fileLocale = Locale(identifier: "en_US_POSIX")

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
            energy: energyWords(locale: Self.fileLocale), energyKeV: energy, samplingResolutionDegrees: settings.resolution,
            samplingMethod: "cubochoric", dictionarySize: rotations.count,
            metric: settings.metric.rawValue, keepN: min(settings.keep, rotations.count), signalMask: settings.signalMask.rawValue,
            detectorShape: [detector.rows, detector.columns], projectionCenterBruker: [pc.x, pc.y, pc.z], sampleTilt: detector.sampleTilt,
            cameraElevation: detector.tilt, azimuthal: detector.azimuthal, twist: detector.twist, points: points, indexed: indexed)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(record)
    }

    /// The record of a run against several phases (D-SEM-98): each phase's dictionary, and the two kikuchipy calls that merge the
    /// phases' maps and map their orientation similarity.
    private struct MergedRecord: Encodable {
        struct Phase: Encodable {
            var phase: IndexingPhase
            var masterPattern: Record.Master
            var energy: String
            var energyKeV: Double?
            var dictionarySize: Int
            var indexed: Int
        }

        var software: String
        var method: String
        var reference: String
        var file: String
        var patterns: String
        var processing: PatternPipeline?
        var phases: [Phase]
        var samplingResolutionDegrees: Double
        var samplingMethod: String
        var metric: String
        var keepN: Int
        var signalMask: String
        var merge: String
        var orientationSimilarityMap: String
        var detectorShape: [Int]
        var projectionCenterBruker: [Double]
        var sampleTilt: Double
        var cameraElevation: Double
        var azimuthal: Double
        var twist: Double
        var points: Int
        var indexed: Int
    }

    /// The method record of a run: one plan's as `methodJSON(fileName:points:indexed:)`; several plans (D-SEM-98) list each phase's
    /// dictionary (its master pattern, energy, size and the points it won, `indexedByPhase` in the plans' order) and the merge.
    package static func methodJSON(_ plans: [DictionaryIndexingPlan], fileName: String, points: Int, indexed: Int,
                                   indexedByPhase: [Int]) throws -> Data {
        guard let first = plans.first else { throw IndexingRefusal("The run has no dictionary.") }
        if plans.count == 1 { return try first.methodJSON(fileName: fileName, points: points, indexed: indexed) }
        let pc = first.detector.projectionCenters.first ?? SIMD3(0, 0, 0)
        let phases = plans.enumerated().map { i, plan in
            let m = plan.master.master
            return MergedRecord.Phase(
                phase: plan.phase,
                masterPattern: Record.Master(file: plan.master.fileName, phase: m.phase.name, spaceGroup: m.phase.spaceGroup, energies: m.energies,
                                             side: m.side, projection: m.projection.rawValue, hemisphere: m.hemisphere.rawValue),
                energy: plan.energyWords(locale: Self.fileLocale), energyKeV: plan.energy, dictionarySize: plan.rotations.count,
                indexed: indexedByPhase.indices.contains(i) ? indexedByPhase[i] : 0)
        }
        let keep = plans.map { min(first.settings.keep, $0.rotations.count) }.min() ?? first.settings.keep
        let record = MergedRecord(
            software: "macTEM",
            method: "Dictionary indexing against several phases (one dictionary each, simulated from the phase's master pattern), each point taking the phase whose best match scores highest",
            reference: "kikuchipy 0.13.1 EBSD.dictionary_indexing, EBSDMasterPattern.get_patterns, indexing.merge_crystal_maps and indexing.orientation_similarity_map; orix 0.15.0 sample_SO3 (cubochoric)",
            file: fileName, patterns: first.source.kind.title, processing: first.source.pipeline, phases: phases,
            samplingResolutionDegrees: first.settings.resolution, samplingMethod: "cubochoric", metric: first.settings.metric.rawValue, keepN: keep,
            signalMask: first.settings.signalMask.rawValue,
            merge: "kikuchipy.indexing.merge_crystal_maps(xmaps, mean_n_best=1, simulation_indices_prop=\"simulation_indices\")",
            orientationSimilarityMap: "kikuchipy.indexing.orientation_similarity_map(merged, simulation_indices_prop=\"merged_simulation_indices\")",
            detectorShape: [first.detector.rows, first.detector.columns], projectionCenterBruker: [pc.x, pc.y, pc.z],
            sampleTilt: first.detector.sampleTilt, cameraElevation: first.detector.tilt, azimuthal: first.detector.azimuthal,
            twist: first.detector.twist, points: points, indexed: indexed)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(record)
    }
}
