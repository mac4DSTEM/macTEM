//
//  EELSRegionsTable.swift
//  Role: the Table tab of the EELS room: one row per region with its pixels, its summed low loss (total counts, t/λ) and, once the edge model has run, the
//        intensity and the composition of each fitted edge in that region's summed core loss. The rows are the session's (`EELSRegionRow`, SpectroKit's
//        thickness and edge model on the region's sum); this file lays them out. Every cell is named for VoiceOver by its region and its column
//        (`EELSRegionSpeech`), and a hidden region says so in words.
//

import ShellLayout
import ShellSpectroscopy
import SwiftUI
import TEMCore
import TEMSession
import ShellEDXModel

/// What VoiceOver says for the Regions table's cells (pure, so a test reads the words): an edge cell is "<region> <edge> intensity" or "<region> <edge> at%",
/// as the EDS room's region table names its per-element cells, with the number the cell shows as its value; a region whose layer is off is "hidden".
nonisolated enum EELSRegionSpeech {
    enum Kind { case intensity, atomic }

    static func cellLabel(region: String, edge: String, kind: Kind) -> String {
        switch kind {
        case .intensity: "\(region) \(edge) intensity"
        case .atomic: "\(region) \(edge) at%"
        }
    }

    /// The cell's number as the table writes it; "none" for a cell that shows a dash.
    static func cellValue(_ value: Double?, kind: Kind, locale: Locale = .autoupdatingCurrent) -> String {
        guard let value else { return "none" }
        switch kind {
        case .intensity: return Num.sig(value, 4, locale: locale)
        case .atomic: return Num.fixed(value, 1, locale: locale)
        }
    }

    /// The name cell's value: a region whose layer is off is dimmed on screen and "hidden" in words; a visible one adds nothing.
    static func visibility(isVisible: Bool) -> String { isVisible ? "" : "hidden" }
}

struct EELSRegionsTable: View {
    let session: EELSSession

    var body: some View {
        let rows = session.pinRows
        if rows.isEmpty {
            ContentUnavailableView("No regions", systemImage: "square.dashed",
                                   description: Text("Draw a rectangle, ellipse or polygon on a map to list its summed spectrum here."))
                .accessibilityIdentifier("eels.regionTable.empty")
        } else {
            let edges = rows.first(where: { !$0.edges.isEmpty })?.edges ?? []
            let hasComposition = edges.contains { $0.atomicPercent != nil }
            let pins = Dictionary(uniqueKeysWithValues: session.pins.map { ($0.id, $0) })
            VStack(alignment: .leading, spacing: 4) {
                ScrollView([.horizontal, .vertical]) {
                    Grid(alignment: .trailing, horizontalSpacing: 14, verticalSpacing: 4) {
                        GridRow {
                            Text("Region").gridColumnAlignment(.leading)
                            Text("Pixels"); Text("I total"); Text("t/λ")
                            ForEach(edges) { Text("\($0.title)") }
                            if hasComposition { ForEach(edges.filter { $0.atomicPercent != nil }) { Text("\($0.title) at%") } }
                        }
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Divider().gridCellUnsizedAxes(.horizontal)
                        ForEach(rows) { row in
                            let pin = pins[row.id] ?? row.pin
                            GridRow {
                                HStack(spacing: 6) {
                                    Circle().fill(EDXRegionBridge.color(pin.color, number: pin.number).color)
                                        .frame(width: LayoutPolicy.regionSwatchSize, height: LayoutPolicy.regionSwatchSize)
                                    Text(pin.name).lineLimit(1)
                                }
                                .gridColumnAlignment(.leading)
                                .opacity(pin.isVisible ? 1 : 0.5)
                                // One element, the region's name: the swatch is not a stop of its own, and the dimming of a hidden region is said in words.
                                .accessibilityElement(children: .combine)
                                .accessibilityValue(EELSRegionSpeech.visibility(isVisible: pin.isVisible))
                                Text("\(row.pixels)").monospacedDigit()
                                    .accessibilityLabel("\(pin.name) pixels").accessibilityValue("\(row.pixels)")
                                    .accessibilityIdentifier("eels.regionTable.\(pin.name).pixels")
                                Text(EDXRoomFormat.counts(row.totalCounts)).monospacedDigit()
                                    .accessibilityLabel("\(pin.name) total counts").accessibilityValue(String(format: "%.0f", row.totalCounts))
                                    .accessibilityIdentifier("eels.regionTable.\(pin.name).total")
                                Text(row.tOverLambda.map { Num.fixed($0, 4) } ?? "–").monospacedDigit()
                                    .accessibilityLabel("\(pin.name) t over lambda").accessibilityValue(row.tOverLambda.map { String(format: "%.4f", $0) } ?? "")
                                    .accessibilityIdentifier("eels.regionTable.\(pin.name).tOverLambda")
                                ForEach(edges) { edge in
                                    let value = row.edges.first { $0.id == edge.id }?.intensity
                                    Text(value.map { Num.sig($0, 4) } ?? "–").monospacedDigit()
                                        .accessibilityLabel(EELSRegionSpeech.cellLabel(region: pin.name, edge: edge.title, kind: .intensity))
                                        .accessibilityValue(EELSRegionSpeech.cellValue(value, kind: .intensity))
                                        .accessibilityIdentifier("eels.regionTable.\(pin.name).\(edge.id)")
                                }
                                if hasComposition {
                                    ForEach(edges.filter { $0.atomicPercent != nil }) { edge in
                                        let value = row.edges.first { $0.id == edge.id }?.atomicPercent
                                        Text(value.map { Num.fixed($0, 1) } ?? "–").monospacedDigit()
                                            .accessibilityLabel(EELSRegionSpeech.cellLabel(region: pin.name, edge: edge.title, kind: .atomic))
                                            .accessibilityValue(EELSRegionSpeech.cellValue(value, kind: .atomic))
                                            .accessibilityIdentifier("eels.regionTable.\(pin.name).\(edge.id).at")
                                    }
                                }
                            }
                            .font(.callout)
                        }
                    }
                    .padding(10)
                }
            }
            .accessibilityIdentifier("eels.regionTable")
        }
    }
}
