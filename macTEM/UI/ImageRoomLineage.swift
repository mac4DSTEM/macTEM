//
//  ImageRoomLineage.swift
//  Role: the Image room's Lineage section,
//        third child of the Settings column after Measure. Not a second marks list: for a distance, an angle or a profile it
//        repeats what Measure lists; what it alone shows is the RECORD a collaborator's h5py reads — each node's id and
//        time, nodes this build cannot draw (opaque kinds, the reserved `fft`, `calibration`…), nodes removed but kept for a
//        citer. Collapsed by default (`@SceneStorage`), drawn only when there is something to show.
//
//        Presentation only: the lineage is `ImageMeasurements`' (TEMSession); the rows are `LineageFormat`, pure so a test
//        pins them. A row's value is recomputed from the mark's points and the file's axes (`MarkFormat`), never the stored
//        `results`. One selection source: `measurements.selection`. A row has no ⌫ and no ⌘C: removal and copying stay in
//        Measure, so there is one delete surface.
//

import ShellInspector
import ImagoCore
import SwiftUI
import TEMCore
import TEMSession

// MARK: - The rows

/// One node of the lineage as a row.
nonisolated struct LineageRowModel: Identifiable, Equatable {
    /// The node's id (`s3`): stable, never reused.
    let id: String
    /// The mark this node became, when the build draws it and it is live.
    let markID: ImageMark.ID?
    /// Line 1: the value shown (measured again on the pixels), or the stored kind verbatim for a record not drawn.
    let value: String
    /// "s3 · 14 Oct 2026, 09:12".
    let caption: String
    let spoken: String
    let isRemoved: Bool
    let isOpaque: Bool
    let kind: ImageMark.Kind?
}

nonisolated enum LineageFormat {
    /// The rows of `lineage`, in node order. `marks` pairs each live mark with its node id.
    static func rows(lineage: SessionLineage, marks: [(nodeID: String, mark: ImageMark)], x: AxisCalibration?, y: AxisCalibration?,
                     now: Date = Date(), calendar: Calendar = .current, locale: Locale = .autoupdatingCurrent) -> [LineageRowModel] {
        let byNode = Dictionary(marks.map { ($0.nodeID, $0.mark) }, uniquingKeysWith: { first, _ in first })
        return lineage.nodes.map { node in
            let recorded = SessionLineage.date(milliseconds: node.recorded)
            let when = time(recorded, now: now, calendar: calendar, locale: locale)
            if let removed = node.removed {
                let citers = lineage.nodes.filter { $0.removed == nil && $0.inputs.contains { $0.step == node.id } }.map(\.id)
                let because = citers.isEmpty ? "kept because another record uses it"
                    : "kept because \(citers.joined(separator: ", ")) \(citers.count == 1 ? "uses" : "use") it"
                let removedAt = time(SessionLineage.date(milliseconds: removed), now: now, calendar: calendar, locale: locale)
                return LineageRowModel(id: node.id, markID: nil, value: node.kind,
                                       caption: "\(node.id) · removed \(removedAt) · \(because)",
                                       spoken: "\(node.kind), removed", isRemoved: true, isOpaque: false, kind: nil)
            }
            if let mark = byNode[node.id] {
                let long = recorded.formatted(.dateTime.day().month(.wide).year().hour().minute().locale(locale))
                return LineageRowModel(id: node.id, markID: mark.id, value: MarkFormat.value(mark, x: x, y: y, locale: locale),
                                       caption: "\(node.id) · \(when)",
                                       spoken: MarkFormat.spoken(mark, x: x, y: y, locale: locale) + ", recorded \(long)",
                                       isRemoved: false, isOpaque: false, kind: mark.kind)
            }
            return LineageRowModel(id: node.id, markID: nil, value: node.kind,
                                   caption: "\(node.id) · \(when) · kept unchanged, not drawn",
                                   spoken: "\(node.kind), kept unchanged, not drawn", isRemoved: false, isOpaque: true, kind: nil)
        }
    }

    /// The time alone for today, else the date and the time.
    static func time(_ date: Date, now: Date, calendar: Calendar, locale: Locale) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return date.formatted(.dateTime.hour().minute().locale(locale)) }
        return date.formatted(.dateTime.day().month(.abbreviated).year().hour().minute().locale(locale))
    }

    /// The footer's and the empty states' words.
    static let footer = "Values are measured again on the image each time the session is opened."
    static let empty = "No marks recorded."
    static let newer = "No records shown: the file is a newer version."
    static let opaqueHelp = "This macTEM does not draw this kind of record. It is saved back exactly as it was."
}

// MARK: - The section

/// Drawn only when there is a node or a session state to show; collapsed by default.
struct ImageRoomLineageSection: View {
    let image: CalibratedImage
    let item: OpenItem
    @SceneStorage("inspector.section.image.Lineage") private var expanded = false

    var body: some View {
        // One read of each, here; values down to the rows.
        let measurements = item.measurements
        let lineage = measurements.lineage
        let sidecar = measurements.sidecar
        let hasState = sidecar != .none || lineage.isReadOnly
        if !lineage.nodes.isEmpty || hasState {
            let pairs = measurements.marks.compactMap { mark in
                measurements.nodeID(of: mark.id).map { (nodeID: $0, mark: mark) }
            }
            let rows = LineageFormat.rows(lineage: lineage, marks: pairs, x: image.x, y: image.y)
            InspectorSection("Lineage", expanded: $expanded) {
                if rows.isEmpty {
                    InspectorNote(lineage.isReadOnly ? LineageFormat.newer : LineageFormat.empty)
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(rows) { row in
                            LineageRow(row: row, isSelected: row.markID != nil && row.markID == measurements.selection,
                                       measurements: measurements)
                        }
                    }
                    InspectorNote(LineageFormat.footer)
                }
            }
        }
    }
}

/// One record: a button when it is a mark this build draws (it selects the mark, as Measure's row does), else plain text.
private struct LineageRow: View {
    let row: LineageRowModel
    let isSelected: Bool
    let measurements: ImageMeasurements

    private static let symbolWidth: CGFloat = 18

    var body: some View {
        if let markID = row.markID {
            Button { measurements.selection = markID } label: { content }
                .buttonStyle(.plain)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background { RoundedRectangle(cornerRadius: 6).fill(.quaternary).opacity(isSelected ? 1 : 0) }
                .accessibilityLabel(row.spoken)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
        } else {
            content
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .opacity(row.isRemoved ? 0.6 : 1)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(row.spoken)
                .help(row.isOpaque ? LineageFormat.opaqueHelp : "")
        }
    }

    private var content: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                .frame(width: Self.symbolWidth)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(row.value).monospacedDigit().lineLimit(1)
                Text(row.caption).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }

    private var symbol: String {
        guard let kind = row.kind else { return "questionmark.square.dashed" }
        return ImageRoomTools.Tool.allCases.first { $0.markKind == kind }?.systemImage ?? "questionmark.square.dashed"
    }
}
