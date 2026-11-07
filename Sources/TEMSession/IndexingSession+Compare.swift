//
//  IndexingSession+Compare.swift
//  Role: the Indexing room's Compare (docs/sem/design/indexing-room.md §3, §6; #230, D-SEM-97): two results of the scan, A and B, each
//        the room's last Hough run, its last Dictionary run or the file's own indexing (the dataset's crystal map when it lies on the
//        scan's grid), drawn side by side on the Map layer when it is an IPF layer (else IPF-Z), with the disorientation between them
//        at every point and its histogram. The numbers are `IndexingComparison`'s (orix's `angle_with`, numpy's histogram, median and
//        mean); the pictures `IndexingRaster`'s for a run (as the indexed map draws it) and `OrientationMaps.raster`'s for the file (as
//        the Maps room draws it). This owner decides WHEN: the comparison is made off the main actor when Compare is switched on, a
//        pick or the layer changes and a run of A's or B's method ends, and lands only if nothing newer was asked for meanwhile
//        (`compareKey`); it waits while A's or B's method runs, so a run's rows never land on a result Compare is reading.
//

import Foundation
import TEMCore

/// A result Compare can show: the room's last run of a method, or the file's own indexing.
package nonisolated enum IndexingCompareSource: String, CaseIterable, Identifiable, Hashable, Sendable {
    case hough, dictionary, file

    package var id: String { rawValue }

    package init(_ method: IndexingMethod) {
        switch method {
        case .hough: self = .hough
        case .dictionary: self = .dictionary
        }
    }

    /// The method whose last run this is; nil for the file's indexing.
    package var method: IndexingMethod? {
        switch self {
        case .hough: .hough
        case .dictionary: .dictionary
        case .file: nil
        }
    }

    /// The pop-ups' and captions' word: "Hough", "Dictionary", "File".
    package var title: String {
        switch self {
        case .hough: IndexingMethod.hough.title
        case .dictionary: IndexingMethod.dictionary.title
        case .file: "File"
        }
    }
}

/// A's and B's pictures on the compare layer, 4 bytes per scan point (the Metal view's RGBA).
package nonisolated struct IndexingComparePictures: Sendable {
    package var a: [UInt8]
    package var b: [UInt8]
    package var layer: IndexingLayer
}

/// What the comparison on screen was made of: the sources, the runs and how far they reached, the layer, and whether the navigator
/// was there to draw under the points a run did not reach.
nonisolated struct IndexingCompareKey: Equatable, Sendable {
    var a: IndexingCompareSource
    var b: IndexingCompareSource
    var runA: Int?
    var runB: Int?
    var reachedA: Int?
    var reachedB: Int?
    var layer: IndexingLayer
    var backdrop: Bool
}

/// One side's data handed off the main actor.
nonisolated enum IndexingCompareInput: Sendable {
    case run(IndexingResult)
    case file(CrystalMap)
}

extension IndexingSession {
    /// What A and B can be: Hough, Dictionary, and File when the dataset's crystal map lies on the scan's grid.
    package var compareSources: [IndexingCompareSource] {
        fileIndexing == nil ? [.hough, .dictionary] : [.hough, .dictionary, .file]
    }

    /// The layer A and B are drawn on: the map's when it is IPF-Z, IPF-X or IPF-Y, else IPF-Z.
    package var compareLayer: IndexingLayer { layer.direction == nil ? .ipfZ : layer }

    /// Whether `source` is a run made of other inputs than its method's current ones (the file's indexing never is).
    package func isStale(source: IndexingCompareSource) -> Bool {
        source.method.map { isStale(of: $0) } ?? false
    }

    /// Why `source` cannot be compared now, in the tile's words; nil when it can.
    package func compareAbsence(_ source: IndexingCompareSource) -> String? {
        guard let method = source.method else {
            return fileIndexing == nil ? "The file holds no indexing on the scan's grid" : nil
        }
        if isIndexing, runningMethod == method { return "\(method.title) is indexing: Compare follows when the run ends" }
        guard let run = runs[method], run.result.reachedCount > 0 else {
            if let run = runs[method], run.wasStopped { return "The \(method.title) run was stopped before a row landed" }
            return "Index with \(method.title) to compare it"
        }
        return nil
    }

    /// `Display › Compare`: on puts Compare in the bottom pane (with A on the run on screen when A has nothing to show), off takes it
    /// away and drops the comparison.
    package func setShowsCompare(_ on: Bool) {
        guard on != showsCompare else { return }
        showsCompare = on
        guard on else {
            clearComparison()
            return
        }
        if compareAbsence(compareA) != nil, let shown = shownRun, shown.result.reachedCount > 0 {
            let source = IndexingCompareSource(shown.method)
            if source == compareB {
                compareB = compareSources.first { $0 != source && compareAbsence($0) == nil } ?? compareA
            }
            compareA = source
        }
        refreshComparison()
    }

    /// Picks A; picking B's source swaps the two.
    package func setCompareA(_ source: IndexingCompareSource) {
        guard source != compareA, compareSources.contains(source) else { return }
        if source == compareB { compareB = compareA }
        compareA = source
        refreshComparison()
    }

    /// Picks B; picking A's source swaps the two.
    package func setCompareB(_ source: IndexingCompareSource) {
        guard source != compareB, compareSources.contains(source) else { return }
        if source == compareA { compareA = compareB }
        compareB = source
        refreshComparison()
    }

    /// Makes the comparison of A and B and their pictures off the main actor, unless the one on screen (or on its way) is of the same
    /// inputs; clears it while Compare is off or A or B has nothing to show. The returned task ends when it has landed.
    @discardableResult
    package func refreshComparison() -> Task<Void, Never> {
        guard showsCompare, let dataset = patterns.dataset, let a = compareInput(compareA), let b = compareInput(compareB) else {
            clearComparison()
            return Task {}
        }
        let layer = compareLayer
        let backdrop = patterns.meanIntensities
        let key = IndexingCompareKey(a: compareA, b: compareB, runA: compareA.method.flatMap { runs[$0]?.id },
                                     runB: compareB.method.flatMap { runs[$0]?.id },
                                     reachedA: compareA.method.flatMap { runs[$0]?.result.reachedCount },
                                     reachedB: compareB.method.flatMap { runs[$0]?.result.reachedCount }, layer: layer,
                                     backdrop: backdrop != nil)
        if key == compareKey, let compareTask { return compareTask }
        compareTask?.cancel()
        compareKey = key
        comparison = nil
        comparePictures = nil
        let rows = dataset.scanRows, columns = dataset.scanColumns
        let task = Task { [weak self] in
            do {
                let made = try await Self.compared(a, b, rows: rows, columns: columns, layer: layer, backdrop: backdrop)
                guard let self, !Task.isCancelled, self.compareKey == key else { return }
                self.comparison = made.comparison
                self.comparePictures = IndexingComparePictures(a: made.a, b: made.b, layer: layer)
                self.compareVersion &+= 1
            } catch {
                guard let self, !Task.isCancelled, self.compareKey == key, !(error is CancellationError) else { return }
                self.onEvent?("Compare: " + ((error as? LocalizedError)?.errorDescription ?? error.localizedDescription))
            }
        }
        compareTask = task
        return task
    }

    /// The data `source` is compared from; nil while it has nothing to show (`compareAbsence`).
    private func compareInput(_ source: IndexingCompareSource) -> IndexingCompareInput? {
        guard compareAbsence(source) == nil else { return nil }
        if let method = source.method {
            return runs[method].map { IndexingCompareInput.run($0.result) }
        }
        return fileIndexing.map(IndexingCompareInput.file)
    }

    private func clearComparison() {
        compareTask?.cancel()
        compareTask = nil
        compareKey = nil
        comparison = nil
        comparePictures = nil
    }

    /// A and B on the scan's grid, compared (`IndexingComparison`), and drawn on `layer`: a run as the indexed map draws it (over the
    /// navigator where it did not reach), the file as the Maps room draws it.
    @concurrent
    nonisolated static func compared(_ a: IndexingCompareInput, _ b: IndexingCompareInput, rows: Int, columns: Int, layer: IndexingLayer,
                                     backdrop: [Float]?) async throws -> (comparison: IndexingComparison, a: [UInt8], b: [UInt8]) {
        let sideA = try side(a, rows: rows, columns: columns)
        let sideB = try side(b, rows: rows, columns: columns)
        try Task.checkCancellation()
        let comparison = try IndexingComparison(sideA, sideB)
        try Task.checkCancellation()
        return (comparison, picture(a, layer: layer, backdrop: backdrop), picture(b, layer: layer, backdrop: backdrop))
    }

    nonisolated private static func side(_ input: IndexingCompareInput, rows: Int, columns: Int) throws -> IndexingComparison.Side {
        switch input {
        case .run(let result):
            guard result.scanRows == rows, result.scanColumns == columns else { throw IndexingComparison.Refusal.differentScans }
            return IndexingComparison.Side(result)
        case .file(let map):
            guard let side = IndexingComparison.Side(map, scanRows: rows, scanColumns: columns) else {
                throw IndexingComparison.Refusal.differentScans
            }
            return side
        }
    }

    nonisolated private static func picture(_ input: IndexingCompareInput, layer: IndexingLayer, backdrop: [Float]?) -> [UInt8] {
        switch input {
        case .run(let result):
            return IndexingRaster.rgba(result, palette: IndexingPalette(layer: layer, phases: result.phases), backdrop: backdrop)
        case .file(let map):
            let direction: SampleDirection = layer == .ipfX ? .x : layer == .ipfY ? .y : .z
            return OrientationMaps.raster(.ipf(direction), of: map).rgba8 ?? []
        }
    }
}
