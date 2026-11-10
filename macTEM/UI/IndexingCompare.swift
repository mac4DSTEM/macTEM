//
//  IndexingCompare.swift
//  Role: the Indexing room's Compare (docs/sem/design/indexing-room.md §3, §6; #230, D-SEM-97), in the bottom pane while
//        `Display › Compare` is on: A and B side by side on the compare layer (IPF-Z, IPF-X or IPF-Y), one zoom and pan for both, the
//        pinned point's crosshair on each, each captioned with its source (and `stale` when its run's inputs changed), the scale bar
//        under A and the IPF key under B; beside them the histogram of the disorientation between A and B at every point compared,
//        on 1° bars with the median and the 2° line, its footer giving the points compared, the median, the share over 2° and what was
//        left out. Hovering either map moves the pattern pane and writes both solutions and their disorientation in the status line;
//        a click pins the point; pointing at a bar reads it. The tiles publish no View › Zoom target: the indexed map keeps it (one
//        target per scene). Presentation only: the numbers are `IndexingComparison`'s (TEMCore) through `IndexingSession`
//        (TEMSession), the words `IndexingCompareFormat`'s.
//

import Charts
import CoreGraphics
import ShellControls
import ShellLayout
import ShellMetal
import SwiftUI
import TEMCore
import TEMSession

/// The two maps beside the histogram.
struct IndexingComparePane: View {
    let session: IndexingSession
    let state: IndexingRoomState
    let dataset: EBSDDataset

    var body: some View {
        PaneSplit(storageKey: "indexing.compareSplit", resizeLabel: "Resize the compared maps and the histogram", leadingName: "Compared maps") {
            IndexingCompareMaps(session: session, state: state, dataset: dataset)
        } trailing: {
            IndexingCompareHistogram(session: session, state: state)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("indexing.compare")
    }
}

// MARK: - The two maps

/// A and B on one zoom: one `PaneZoomModel` drives both tiles (its gesture state lives in the model), each tile the same box.
private struct IndexingCompareMaps: View {
    let session: IndexingSession
    let state: IndexingRoomState
    let dataset: EBSDDataset
    @State private var zoomModel = PaneZoomModel()

    var body: some View {
        VStack(spacing: 6) {
            Text(IndexingCompareFormat.mapsTitle(a: session.compareA, b: session.compareB, layer: session.compareLayer))
                .font(.headline).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: LayoutPolicy.paneHeaderHeight)
                .accessibilityIdentifier("indexing.compare.title")
            GeometryReader { geometry in
                let gap: CGFloat = 6
                let tile = CGSize(width: max((geometry.size.width - gap) / 2, 0), height: geometry.size.height)
                let box = LayoutPolicy.fitted(in: tile, aspect: CGFloat(dataset.scanColumns) / CGFloat(dataset.scanRows))
                let pictures = session.comparePictures
                HStack(spacing: gap) {
                    IndexingCompareTile(session: session, state: state, dataset: dataset, letter: "A", source: session.compareA,
                                        pixels: pictures?.a, box: box, zoomModel: zoomModel, isLeading: true)
                    IndexingCompareTile(session: session, state: state, dataset: dataset, letter: "B", source: session.compareB,
                                        pixels: pictures?.b, box: box, zoomModel: zoomModel, isLeading: false)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(8)
        .clipped()
    }
}

/// One compared map: its picture, the pinned point, its caption, and under it the scale bar (A) or the IPF key (B).
private struct IndexingCompareTile: View {
    let session: IndexingSession
    let state: IndexingRoomState
    let dataset: EBSDDataset
    let letter: String
    let source: IndexingCompareSource
    let pixels: [UInt8]?
    let box: CGSize
    let zoomModel: PaneZoomModel
    let isLeading: Bool
    private var zp: ZoomPan { zoomModel.state }

    /// The tile's accessibility identifiers, written out so the journeys' inventory finds them.
    private var ids: (map: String, title: String, empty: String) {
        isLeading ? ("indexing.compare.mapA", "indexing.compare.mapA.title", "indexing.compare.mapA.empty")
            : ("indexing.compare.mapB", "indexing.compare.mapB.title", "indexing.compare.mapB.empty")
    }

    /// The point groups of both sides' phases, by orix name, in order: the IPF key under B.
    private var keyGroups: [String] {
        guard let comparison = session.comparison else { return [] }
        let names = (comparison.a.phases + comparison.b.phases).compactMap(\.pointGroupName)
        return names.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
    }

    var body: some View {
        let transform = MetalDisplayTransform(paneSize: box, imageBox: box, zoom: zp.drawZoom, offset: zp.effectiveOffset)
        let geometry = MarkGeometry(transform: transform, imageWidth: dataset.scanColumns, imageHeight: dataset.scanRows)
        let points = dataset.scanRows * dataset.scanColumns
        let title = IndexingCompareFormat.tileTitle(letter, source, layer: session.compareLayer, stale: session.isStale(source: source))
        let shown = pixels.flatMap { $0.count == points * 4 ? $0 : nil }
        return ZStack {
            ZStack {
                if let shown {
                    MetalImageView(pixels: [Float](repeating: 0, count: points), width: dataset.scanColumns, height: dataset.scanRows,
                                   contentVersion: session.compareVersion, rgba: shown)
                        .displayTransform(transform)
                        .frame(width: box.width, height: box.height)
                        .allowsHitTesting(false)
                } else {
                    Rectangle().fill(.quaternary).frame(width: box.width, height: box.height)
                }
                ScanMarker(center: geometry.panePoint(of: ImagePoint(x: Double(session.patterns.pinned.column), y: Double(session.patterns.pinned.row))),
                           pointsPerPixel: geometry.pointsPerPixel)
                    .allowsHitTesting(false)
            }
            .frame(width: box.width, height: box.height)
            .clipped()
            .contentShape(Rectangle())
            .onTapGesture { location in
                let q = geometry.imagePoint(atPanePoint: location)
                let position = EBSDPosition(row: Int(q.y.rounded()), column: Int(q.x.rounded()))
                if position.isInside(rows: dataset.scanRows, columns: dataset.scanColumns) { session.pin(position) }
            }
            .border(Color.white.opacity(0.08))
            .zoomPan(zoomModel, box: box, onHover: { phase in hovered(phase, geometry: geometry) })
            .zoomPanWheel(zoomModel, box: box)

            if shown == nil {
                // Why the side is empty: its method not run yet, running, stopped before a row, the other side so, or the comparison
                // on its way.
                let other = isLeading ? session.compareB : session.compareA
                Text(session.compareAbsence(source)
                     ?? session.compareAbsence(other).map { "Waiting for \(isLeading ? "B" : "A") · \($0)" }
                     ?? "Comparing…")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .padding(8)
                    .allowsHitTesting(false)
                    .accessibilityIdentifier(ids.empty)
            }

            VStack {
                HStack {
                    Text(title)
                        .font(.caption).lineLimit(1)
                        .padding(4)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
                        .accessibilityIdentifier(ids.title)
                    Spacer(minLength: 0)
                }
                Spacer(minLength: 0)
            }
            .padding(6)
            .allowsHitTesting(false)

            PaneFooter {
                if isLeading {
                    ScaleBar(unitsPerPoint: ImageScaleBar.unitsPerPoint(perPixel: dataset.stepX, imageWidth: dataset.scanColumns, boxWidth: box.width, zoom: zp.drawZoom),
                             unitLabel: EBSDBrowsing.unitLabel(dataset.scanUnit))
                }
            } trailing: {
                HStack(alignment: .bottom, spacing: 8) {
                    if !isLeading, shown != nil, !keyGroups.isEmpty {
                        IndexingIPFKey(session: session, layer: session.compareLayer, groups: keyGroups)
                            .padding(4)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
                    }
                    if let text = ZoomPan.badgeText(zoom: zp.drawZoom), let spoken = ZoomPan.badgeSpoken(zoom: zp.drawZoom) {
                        Text(text).font(.caption.weight(.semibold).monospacedDigit()).foregroundStyle(Color.accentColor).fixedSize()
                            .accessibilityLabel(spoken)
                    }
                }
            }
        }
        .frame(width: box.width, height: box.height)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(ids.map)
        .accessibilityLabel("Compared map \(letter)")
        .accessibilityValue(title)
        .accessibilityHint(ZoomPan.accessibilityHint)
        .zoomPanAccessibilityActions(zoomModel, box: box)
    }

    /// The pattern pane follows the pointer; the status line gives both solutions and their disorientation there (the run's own line
    /// while the comparison is on its way).
    private func hovered(_ phase: HoverPhase, geometry: MarkGeometry) {
        switch phase {
        case .active(let p):
            let q = geometry.imagePoint(atPanePoint: p)
            let position = EBSDPosition(row: Int(q.y.rounded()), column: Int(q.x.rounded()))
            guard position.isInside(rows: dataset.scanRows, columns: dataset.scanColumns) else {
                session.hover(nil); state.readout = nil; return
            }
            session.hover(position)
            state.readout = session.comparison.flatMap {
                IndexingCompareFormat.readout($0, a: session.compareA, b: session.compareB, at: position, columns: dataset.scanColumns)
            } ?? session.readout(at: position)
        case .ended:
            session.hover(nil)
            state.readout = nil
        }
    }
}

// MARK: - The histogram

/// The disorientation histogram: one bar per degree, the median and the 2° line, the bar under the pointer read in the status line,
/// the hovered point's angle marked.
private struct IndexingCompareHistogram: View {
    let session: IndexingSession
    let state: IndexingRoomState
    @State private var pointerX: Double?

    /// The axis titles as Strings, so `.value` takes its StringProtocol overload (the trap `FFTRadialChart` notes).
    private let xTitle = "Disorientation (°)"
    private let yTitle = "Points"

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(IndexingCompareFormat.histogramTitle(a: session.compareA, b: session.compareB))
                .font(.headline).lineLimit(1)
                .frame(height: LayoutPolicy.paneHeaderHeight)
                .accessibilityIdentifier("indexing.compare.histogram.title")
            if let comparison = session.comparison, let histogram = comparison.histogram {
                chart(comparison, histogram)
                Text(IndexingCompareFormat.footer(comparison, a: session.compareA, b: session.compareB))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .lineLimit(2, reservesSpace: true)
                    .accessibilityIdentifier("indexing.compare.footer")
            } else {
                Text(emptyWords)
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("indexing.compare.empty")
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onChange(of: pointerX) {
            // The pointer off the chart clears the bar's line, as leaving a map clears the point's.
            state.readout = pointerX.flatMap { x in session.comparison.flatMap { IndexingCompareFormat.binReadout($0, atDegrees: x) } }
        }
    }

    /// What the pane says without a histogram: why a side is empty, that nothing pairs, or that the comparison is on its way.
    private var emptyWords: String {
        if let why = session.compareAbsence(session.compareA) ?? session.compareAbsence(session.compareB) { return why }
        if let comparison = session.comparison {
            return IndexingCompareFormat.nothingCompared(comparison, a: session.compareA, b: session.compareB)
        }
        return "Comparing…"
    }

    private func chart(_ comparison: IndexingComparison, _ histogram: AngleHistogram) -> some View {
        let bins = IndexingCompareFormat.drawnBins(histogram)
        let top = histogram.edges.last ?? 1
        let hoveredAngle = session.hovered.flatMap { p -> Double? in
            guard let columns = session.patterns.dataset?.scanColumns else { return nil }
            return comparison.degrees(at: p.row * columns + p.column)
        }
        return Chart {
            ForEach(bins) { bin in
                BarMark(xStart: .value(xTitle, bin.low), xEnd: .value(xTitle, bin.high), y: .value(yTitle, bin.count))
                    .foregroundStyle(Color.accentColor)
            }
            if let median = comparison.medianDegrees {
                RuleMark(x: .value("Median", median))
                    .foregroundStyle(.primary)
            }
            RuleMark(x: .value("Threshold", IndexingComparison.thresholdDegrees))
                .foregroundStyle(.secondary)
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
            if let hoveredAngle {
                RuleMark(x: .value("Hovered point", hoveredAngle))
                    .foregroundStyle(.orange)
            }
        }
        .chartXScale(domain: 0...top)
        .chartXSelection(value: $pointerX)
        .chartXAxisLabel(alignment: .center) { Text(xTitle) }
        .chartYAxisLabel { Text(yTitle) }
        .accessibilityIdentifier("indexing.compare.histogram")
        .accessibilityLabel("Disorientation histogram")
        .accessibilityValue(IndexingCompareFormat.footer(comparison, a: session.compareA, b: session.compareB))
    }
}
