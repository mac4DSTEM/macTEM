//
//  IndexingCompareFormat.swift
//  Role: the words of the Indexing room's Compare (design §3, §6; #230, D-SEM-97): the titles of the two maps and the histogram, the
//        histogram's bars, its footer (the points compared, numpy's median, the share over 2° and what was left out), the sentence
//        when nothing could be compared, the status line over either map (both solutions and their disorientation) and over a bar.
//        Numbers in the reader's decimal mark as the Results table writes them (`IndexingTableFormat`), counts never grouped as the
//        Info words write them (`IndexingInfoFormat.count`), a side without an orientation as `UnitDisplay.noValue`. Pure: no view, no
//        session.
//

import Foundation
import TEMCore
import TEMSession

nonisolated enum IndexingCompareFormat {
    /// One bar of the histogram: degrees `low` to `high`, `count` points.
    struct Bin: Identifiable, Equatable {
        let id: Int
        let low: Double
        let high: Double
        let count: Int
    }

    static func bins(_ histogram: AngleHistogram) -> [Bin] {
        histogram.counts.indices.map { Bin(id: $0, low: histogram.edges[$0], high: histogram.edges[$0 + 1], count: histogram.counts[$0]) }
    }

    /// The bins the chart draws: the occupied ones. Swift Charts draws a bar of count 0 as a dot on the axis, so a scan whose
    /// disorientations sit under 2° drew a row of 60 dots along 0 (drive 2026-11-08). The hover readout still names an empty bin.
    static func drawnBins(_ histogram: AngleHistogram) -> [Bin] {
        bins(histogram).filter { $0.count > 0 }
    }

    /// "Compare · Hough against File · IPF-Z".
    static func mapsTitle(a: IndexingCompareSource, b: IndexingCompareSource, layer: IndexingLayer) -> String {
        "Compare · \(a.title) against \(b.title) · \(layer.title)"
    }

    /// A map's caption: "A · Hough · IPF-Z", with "· stale" once its run's inputs changed.
    static func tileTitle(_ letter: String, _ source: IndexingCompareSource, layer: IndexingLayer, stale: Bool) -> String {
        "\(letter) · \(source.title) · \(layer.title)" + (stale ? " · stale" : "")
    }

    /// "Disorientation · Hough against File".
    static func histogramTitle(a: IndexingCompareSource, b: IndexingCompareSource) -> String {
        "Disorientation · \(a.title) against \(b.title)"
    }

    /// "4124 of 4125 points · median 0.44° · 1.0 % over 2° · 1 without a Hough orientation · 3 of unpaired phases", the counts never grouped.
    static func footer(_ c: IndexingComparison, a: IndexingCompareSource, b: IndexingCompareSource,
                       locale: Locale = .autoupdatingCurrent) -> String {
        var parts = ["\(count(c.comparedCount, locale)) of \(count(c.a.pointCount, locale)) \(UnitDisplay.noun(c.a.pointCount, "point", "points"))"]
        if let median = c.medianDegrees { parts.append("median \(IndexingTableFormat.angle(median, digits: 2, locale: locale))°") }
        if let share = c.fractionOverThreshold {
            parts.append("\(percent(share, locale)) over \(IndexingTableFormat.angle(IndexingComparison.thresholdDegrees, digits: 0, locale: locale))°")
        }
        let noneA = c.count(.noneInA), noneB = c.count(.noneInB), unpaired = c.count(.unpairedPhases)
        if noneA > 0 { parts.append("\(count(noneA, locale)) without a \(a.title) orientation") }
        if noneB > 0 { parts.append("\(count(noneB, locale)) without a \(b.title) orientation") }
        if unpaired > 0 { parts.append("\(count(unpaired, locale)) of unpaired phases") }
        return parts.joined(separator: " · ")
    }

    /// What the histogram says when no point is compared: "No point is indexed in both as phases that pair (Hough: ni; File: Nickel)".
    static func nothingCompared(_ c: IndexingComparison, a: IndexingCompareSource, b: IndexingCompareSource) -> String {
        func names(_ side: IndexingComparison.Side) -> String {
            side.phases.isEmpty ? "no phase" : side.phases.map(\.name).joined(separator: ", ")
        }
        return "No point is indexed in both as phases that pair (\(a.title): \(names(c.a)); \(b.title): \(names(c.b)))"
    }

    /// The status line over either map at `position` of a scan `columns` wide: "row 12 · col 40 · Hough ni φ₁ 12.3° Φ 44.0° φ₂ 271.5° ·
    /// File ni φ₁ … · disorientation 0.41°", or why the point is not compared; nil outside the scan.
    static func readout(_ c: IndexingComparison, a: IndexingCompareSource, b: IndexingCompareSource, at position: EBSDPosition,
                        columns: Int, locale: Locale = .autoupdatingCurrent) -> String? {
        guard position.row >= 0, position.column >= 0, position.column < columns else { return nil }
        let i = position.row * columns + position.column
        guard c.outcomes.indices.contains(i) else { return nil }
        var words = "row \(position.row) · col \(position.column) · " + side(c.a, a, i, locale) + " · " + side(c.b, b, i, locale)
        switch c.outcomes[i] {
        case .compared:
            words += " · disorientation \(IndexingTableFormat.angle(c.degrees(at: i) ?? .nan, digits: 2, locale: locale))°"
        case .noneInA:
            words += " · not compared: " + why(c.a, a, i)
        case .noneInB:
            words += " · not compared: " + why(c.b, b, i)
        case .unpairedPhases:
            words += " · not compared: the phases do not pair"
        }
        return words
    }

    /// The status line over the bar at `x` degrees: "12–13° · 118 points · 2.9 % of those compared"; nil off the bars.
    static func binReadout(_ c: IndexingComparison, atDegrees x: Double, locale: Locale = .autoupdatingCurrent) -> String? {
        guard let histogram = c.histogram, c.comparedCount > 0, x.isFinite, let first = histogram.edges.first,
              let last = histogram.edges.last, x >= first, x <= last else { return nil }
        let k = min(histogram.edges.lastIndex { $0 <= x } ?? 0, histogram.counts.count - 1)
        let n = histogram.counts[k]
        let low = IndexingTableFormat.angle(histogram.edges[k], digits: 0, locale: locale)
        let high = IndexingTableFormat.angle(histogram.edges[k + 1], digits: 0, locale: locale)
        return "\(low)–\(high)° · \(count(n, locale)) \(UnitDisplay.noun(n, "point", "points")) · \(percent(Double(n) / Double(c.comparedCount), locale)) of those compared"
    }

    // MARK: - Pieces

    private static func count(_ n: Int, _ locale: Locale) -> String { IndexingInfoFormat.count(n, locale: locale) }

    /// A share as "1.0 %".
    private static func percent(_ share: Double, _ locale: Locale) -> String {
        IndexingTableFormat.angle(share * 100, digits: 1, locale: locale) + " %"
    }

    /// "Hough ni φ₁ 12.3° Φ 44.0° φ₂ 271.5°", or "Hough —" (`UnitDisplay.noValue`) where the side has no orientation.
    private static func side(_ s: IndexingComparison.Side, _ source: IndexingCompareSource, _ i: Int, _ locale: Locale) -> String {
        guard let name = s.phaseName(at: i), let e = s.eulerDegrees(at: i) else { return "\(source.title) \(UnitDisplay.noValue)" }
        let angle = { (v: Double) in IndexingTableFormat.angle(v, locale: locale) }
        return "\(source.title) \(name) φ₁ \(angle(e.x))° Φ \(angle(e.y))° φ₂ \(angle(e.z))°"
    }

    /// Why a side has nothing to compare at point `i`: no orientation, or a phase without a point group.
    private static func why(_ s: IndexingComparison.Side, _ source: IndexingCompareSource, _ i: Int) -> String {
        if let name = s.phaseName(at: i) { return "\(source.title)'s \(name) has no point group" }
        return "no \(source.title) orientation"
    }
}
