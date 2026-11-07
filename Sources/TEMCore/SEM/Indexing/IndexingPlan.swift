//
//  IndexingPlan.swift
//  Role: what one Hough run of the Indexing room is made of (docs/sem/design/indexing-room.md §4, §6): the patterns it reads
//        (`IndexingSource`), the band detector's and the vote's settings (`HoughIndexingSettings`, pyEBSDindex's `EBSDIndexer`
//        parameters), the phases that are on, the projection centre and the two tilts, and the `HoughIndexer` built from them. The
//        room builds a plan off the main actor (the Radon line plan and the triplet tables take tens of milliseconds) and indexes
//        the scan with it row by row, so the map grows in place.
//
//  The defaults are kikuchipy 0.13.1's Hough indexing tutorial (D-SEM-83), the settings of north-star figure F8 and its parity
//  bundle `m4/hough-indexing-nickel-large`: 10 bands, both kernel sigmas 2, 90 rho and 180 theta bins, a 15 % rho mask, a 2°
//  tolerance, early exit at 10 matched bands; the projection centre is the mean of the file's per-point centres (Bruker), as
//  the tutorial's `det.pc_average`; the sample tilt and the camera elevation are the file's.
//

import Foundation
import FormatoCore

/// pyEBSDindex's `EBSDIndexer` parameters the Hough section edits.
package nonisolated struct HoughIndexingSettings: Sendable, Equatable, Codable {
    /// Bands detected per pattern (`nBands`).
    package var bands = 10
    /// The Laplacian-of-Gaussian kernel's widths along theta and rho, in Radon cells (`tSigma`, `rSigma`).
    package var thetaSigma = 2.0
    package var rhoSigma = 2.0
    /// The Radon transform's bins (`nRho`, `nTheta`).
    package var rhoBins = 90
    package var thetaBins = 180
    /// The fraction of rho bins at each end where no peak is taken (`rhoMaskFrac`).
    package var rhoMaskFraction = 0.15
    /// The interplanar-angle tolerance of the triplet vote, degrees (`angTol`).
    package var angleTolerance = 2.0
    /// Matched bands after which no further phase is tried (`nband_earlyexit`).
    package var earlyExitBands = 10

    package init() {}

    /// kikuchipy's Hough indexing tutorial (figure F8).
    package static let roomDefault = HoughIndexingSettings()

    /// The band detector's settings.
    package var detectorSettings: HoughBandDetector.Settings {
        HoughBandDetector.Settings(rhoBins: rhoBins, thetaBins: thetaBins, thetaSigma: thetaSigma, rhoSigma: rhoSigma,
                                   rhoMaskFraction: rhoMaskFraction, bands: bands)
    }

    /// Why these settings cannot run, in the room's words; nil when they can.
    package var refusal: String? {
        guard (3...30).contains(bands) else { return "Bands runs from 3 to 30." }
        guard (10...720).contains(rhoBins) else { return "ρ bins runs from 10 to 720." }
        guard (18...720).contains(thetaBins) else { return "θ bins runs from 18 to 720." }
        guard thetaSigma.isFinite, rhoSigma.isFinite, thetaSigma > 0, rhoSigma > 0, thetaSigma <= 20, rhoSigma <= 20 else {
            return "The kernel's σ θ and σ ρ are positive, at most 20 cells."
        }
        guard rhoMaskFraction.isFinite, rhoMaskFraction >= 0, rhoMaskFraction < 0.5 else { return "The ρ mask is a fraction from 0 to under 0.5." }
        guard angleTolerance.isFinite, angleTolerance > 0, angleTolerance <= 10 else { return "The tolerance is above 0° and at most 10°." }
        guard (1...30).contains(earlyExitBands) else { return "Early exit runs from 1 to 30 bands." }
        return nil
    }
}

/// Where the room reads the patterns it indexes (D-SEM-83): the Patterns room's processed scan in memory when it is current (the only
/// way NLPAR reaches the indexer), else the patterns as stored, each through the pipeline's per-pattern stages on the fly
/// (`PatternPipeline.apply`, the numbers `process` writes), or as stored when no stage is on.
package nonisolated struct IndexingSource: Sendable {
    package enum Kind: String, Sendable, Codable, Equatable {
        case processedScan, perPattern, asStored

        package var title: String {
            switch self {
            case .processedScan: "Processed scan (in memory)"
            case .perPattern: "Processed per pattern"
            case .asStored: "As stored"
            }
        }
    }

    package let access: any EBSDPatternAccess
    /// The stages applied to each pattern as it is read; nil when the access already holds what is indexed.
    package let pipeline: PatternPipeline?
    package let background: FormatoArray?
    package let kind: Kind
    /// The shape of an indexed pattern (binned when the pipeline bins).
    package let patternRows: Int
    package let patternColumns: Int

    /// The Patterns room's processed scan.
    package init(processed: EBSDMemoryPatterns) {
        access = processed
        pipeline = nil
        background = nil
        kind = .processedScan
        patternRows = processed.dataset.patternRows
        patternColumns = processed.dataset.patternColumns
    }

    /// The patterns as stored, through `pipeline`'s per-pattern stages (none: as stored).
    package init(stored: any EBSDPatternAccess, pipeline: PatternPipeline, background: FormatoArray?) {
        access = stored
        let active = PatternPipeline.Stage.allCases.contains { pipeline.isActive($0) }
        self.pipeline = active ? pipeline : nil
        self.background = active ? background : nil
        kind = active ? .perPattern : .asStored
        let binning = active ? max(pipeline.binning, 1) : 1
        patternRows = stored.dataset.patternRows / binning
        patternColumns = stored.dataset.patternColumns / binning
    }

    package var scanRows: Int { access.dataset.scanRows }
    package var scanColumns: Int { access.dataset.scanColumns }

    /// One scan row of indexed patterns, in map order, each row-major (row 0 at the top) as the band detector takes it.
    package func patterns(row: Int) throws -> [[Double]] {
        let dataset = access.dataset
        let slab = try access.row(row)
        let size = dataset.patternPixels * slab.dataType.byteSize
        let bytes = slab.bytes, base = bytes.startIndex   // a slab may be a slice of a larger buffer: index from its start
        var out: [[Double]] = []
        out.reserveCapacity(dataset.scanColumns)
        for column in 0..<dataset.scanColumns {
            let one = try FormatoArray(dataType: slab.dataType, shape: [dataset.patternRows, dataset.patternColumns],
                                       bytes: bytes.subdata(in: (base + column * size)..<(base + (column + 1) * size)))
            out.append(try indexed(one))
        }
        return out
    }

    /// The indexed pattern at one scan position.
    package func pattern(row: Int, column: Int) throws -> [Double] {
        try indexed(access.pattern(row: row, column: column))
    }

    private func indexed(_ stored: FormatoArray) throws -> [Double] {
        guard let pipeline else { return stored.doubles() }
        let dataset = access.dataset
        return try pipeline.apply(stored, rows: dataset.patternRows, columns: dataset.patternColumns, background: background).doubles()
    }
}

/// The inputs a run is made of, compared to stale a result (design §6: a Processing or a Phases change stales Indexing; Display never).
/// The method's own settings count, the other method's do not (a Hough edit, the phases' reflector lists included, leaves a dictionary
/// result current, D-SEM-91).
package nonisolated struct IndexingInputs: Sendable, Equatable {
    package var pipeline: PatternPipeline
    /// The phases that are on, in the indexer's order.
    package var phases: [IndexingPhase]
    package var method: IndexingMethod
    /// The Hough settings (the room's defaults for a dictionary run).
    package var settings: HoughIndexingSettings
    /// The dictionary settings and the master pattern's file (the defaults and nil for a Hough run).
    package var dictionary: DictionaryIndexingSettings
    package var masterID: String?

    package init(pipeline: PatternPipeline, phases: [IndexingPhase], settings: HoughIndexingSettings, method: IndexingMethod = .hough,
                 dictionary: DictionaryIndexingSettings = .roomDefault, masterID: String? = nil) {
        self.pipeline = pipeline
        self.phases = phases.filter(\.isOn)
        self.method = method
        switch method {
        case .hough:
            self.settings = settings
            self.dictionary = .roomDefault
            self.masterID = nil
        case .dictionary:
            // A phase's reflector list is the Hough library's; a dictionary run never reads it, so an edit to it leaves the run current.
            self.phases = self.phases.map { phase in
                var p = phase
                p.reflectors = IndexingPhase.defaultReflectors(spaceGroup: p.spaceGroup)
                return p
            }
            self.settings = .roomDefault
            self.dictionary = dictionary
            self.masterID = masterID
        }
    }
}

/// The patterns and the band detector, without any phase: what the pattern pane needs to show a pattern as it is indexed and its
/// detected bands. Building the detector's Radon line plan takes tens of milliseconds: build it off the main actor, once per settings.
package nonisolated struct IndexingProbe: Sendable {
    package let source: IndexingSource
    package let detector: HoughBandDetector

    package init(source: IndexingSource, settings: HoughIndexingSettings) throws {
        if let why = settings.refusal { throw IndexingRefusal(why) }
        do {
            detector = try HoughBandDetector(rows: source.patternRows, columns: source.patternColumns, settings: settings.detectorSettings)
        } catch {
            throw IndexingRefusal("The Hough settings do not fit a \(source.patternColumns) × \(source.patternRows) px pattern.")
        }
        self.source = source
    }

    /// The pattern at one scan position as it is indexed, and its detected bands.
    package func inspect(row: Int, column: Int) throws -> (pattern: [Double], bands: [HoughBandDetector.Band]) {
        let pattern = try source.pattern(row: row, column: column)
        return (pattern, try detector.detect(pattern))
    }
}

package nonisolated struct IndexingPlan: Sendable {
    package let source: IndexingSource
    /// The phases indexed against, in the indexer's order (a solution's `phase` indexes this list).
    package let phases: [IndexingPhase]
    package let settings: HoughIndexingSettings
    package let indexer: HoughIndexer

    /// Why `phases` and `settings` cannot index a dataset with `detector`, without building anything; nil when they can.
    package static func refusal(phases: [IndexingPhase], settings: HoughIndexingSettings, detector: EBSDDetectorGeometry) -> String? {
        let on = phases.filter(\.isOn)
        if phases.isEmpty { return "Add a phase first: from the file, a preset or a CIF." }
        if on.isEmpty { return "Turn a phase on to index against it." }
        if let why = on.lazy.compactMap(\.refusal).first { return why }
        if let why = settings.refusal { return why }
        if meanProjectionCenter(detector) == nil { return "The file states no projection centre, which Hough indexing needs." }
        return nil
    }

    /// The mean of the file's projection centres (Bruker convention), kikuchipy's `EBSDDetector.pc_average`; nil without one.
    package static func meanProjectionCenter(_ detector: EBSDDetectorGeometry) -> SIMD3<Double>? {
        let centres = detector.projectionCenters
        guard !centres.isEmpty, centres.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }) else { return nil }
        return centres.reduce(SIMD3<Double>(0, 0, 0), +) / Double(centres.count)
    }

    /// Builds the phases' reflector libraries on the probe's band detector (call it off the main actor).
    package init(probe: IndexingProbe, phases: [IndexingPhase], settings: HoughIndexingSettings, detector: EBSDDetectorGeometry) throws {
        if let why = Self.refusal(phases: phases, settings: settings, detector: detector) { throw IndexingRefusal(why) }
        let on = phases.filter(\.isOn)
        var libraries: [HoughReflectorLibrary] = []
        for phase in on {
            do {
                libraries.append(try phase.library(angleTolerance: settings.angleTolerance, earlyExitBands: settings.earlyExitBands))
            } catch {
                throw IndexingRefusal("\(phase.name): its reflector library could not be built for space group \(phase.spaceGroup).")
            }
        }
        // The refusal above has checked the centre.
        let pc = Self.meanProjectionCenter(detector) ?? SIMD3(0.5, 0.5, 0.5)
        source = probe.source
        self.phases = on
        self.settings = settings
        indexer = try HoughIndexer(phases: libraries, detector: probe.detector, projectionCenter: pc, sampleTilt: detector.sampleTilt,
                                   cameraElevation: detector.tilt)
    }

    package var projectionCenter: SIMD3<Double> { indexer.projectionCenter }

    /// Indexes scan row `row` (its patterns read here, indexed in parallel by `HoughIndexer.indexMap`).
    package func indexRow(_ row: Int) async throws -> [HoughIndexer.Solution] {
        let patterns = try source.patterns(row: row)
        let map = try await indexer.indexMap(scanRows: 1, scanColumns: patterns.count) { _, column in patterns[column] }
        return map.solutions
    }

    // MARK: - The method record

    private struct Record: Encodable {
        var software: String
        var method: String
        var reference: String
        var file: String
        var patterns: String
        var processing: PatternPipeline?
        var settings: HoughIndexingSettings
        var phases: [IndexingPhase]
        var projectionCenterBruker: [Double]
        var sampleTilt: Double
        var cameraElevation: Double
        var points: Int
        var indexed: Int
    }

    /// Every input of the run in pyEBSDindex's and kikuchipy's terms, to redo it in Python (`kp.EBSD.hough_indexing` with
    /// `det.get_indexer(phase_list, nBands=…, tSigma=…, rSigma=…)`).
    package func methodJSON(fileName: String, points: Int, indexed: Int) throws -> Data {
        let pc = projectionCenter
        let record = Record(software: "macTEM", method: "Hough indexing (Radon band detection, triplet voting, QUEST)",
                            reference: "pyEBSDindex 0.3.10.1 EBSDIndexer, vendor KIKUCHIPY, as kikuchipy 0.13.1 EBSD.hough_indexing drives it",
                            file: fileName, patterns: source.kind.title, processing: source.pipeline, settings: settings, phases: phases,
                            projectionCenterBruker: [pc.x, pc.y, pc.z], sampleTilt: indexer.sampleTilt,
                            cameraElevation: indexer.cameraElevation, points: points, indexed: indexed)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(record)
    }
}
