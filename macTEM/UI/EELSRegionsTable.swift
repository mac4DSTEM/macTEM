//
//  EELSRegionsTable.swift
//  Role: the Table tab of the EELS room: one row per region with its pixels, its summed low loss (total counts, t/λ) and, once the edge model has run, the
//        intensity and the composition of each fitted edge in that region's summed core loss. The rows are the session's (`EELSRegionRow`, SpectroKit's
//        thickness and edge model on the region's sum); this file lays them out. Unvalidated numbers stay badged.
//

import ShellLayout
import ShellSpectroscopy
import SwiftUI
#if canImport(TEMCore)
import TEMCore
import TEMSession
#endif
import ShellEDXModel

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
                                        .accessibilityIdentifier("eels.regionTable.\(pin.name).\(edge.id)")
                                }
                                if hasComposition {
                                    ForEach(edges.filter { $0.atomicPercent != nil }) { edge in
                                        let value = row.edges.first { $0.id == edge.id }?.atomicPercent
                                        Text(value.map { Num.fixed($0, 1) } ?? "–").monospacedDigit()
                                            .accessibilityIdentifier("eels.regionTable.\(pin.name).\(edge.id).at")
                                    }
                                }
                            }
                            .font(.callout)
                        }
                    }
                    .padding(10)
                }
                Label("validation: none · not compared with a standard", systemImage: "questionmark.circle.fill")
                    .font(.caption).foregroundStyle(.orange)
                    .padding(.horizontal, 10).padding(.bottom, 6)
                    .accessibilityIdentifier("eels.regionTable.badge")
            }
            .accessibilityIdentifier("eels.regionTable")
        }
    }
}
