//
//  EDXRegionTable.swift
//  Role: the Table tab (design 2026-10-22 §2.2): one row per region (and the whole map when no region is kept), with its pixels, its counts and, per picked
//        element, the net counts of its line window in that region's spectrum and, when the factors are complete, wt% and at%. The rows are the session's
//        (`EDXPins.rows`, SpectroKit's windows and quantification); this file lays them out.
//

import ShellLayout
import ShellSpectroscopy
import SwiftUI
import TEMCore
import TEMSession

struct EDXRegionTable: View {
    let rows: [EDXPins.Row]

    var body: some View {
        if rows.isEmpty {
            ContentUnavailableView("No regions", systemImage: "square.dashed",
                                   description: Text("Draw a rectangle, ellipse or polygon on a map to list its spectrum here."))
                .accessibilityIdentifier("edx.regionTable.empty")
        } else {
            let elements = rows.first?.elements ?? []
            let hasComposition = rows.contains { $0.atomicPercent != nil }
            ScrollView([.horizontal, .vertical]) {
                Grid(alignment: .trailing, horizontalSpacing: 14, verticalSpacing: 4) {
                    GridRow {
                        Text("Region").gridColumnAlignment(.leading)
                        Text("Pixels"); Text("Counts")
                        ForEach(elements, id: \.self) { Text("\($0) net") }
                        if hasComposition { ForEach(elements, id: \.self) { Text("\($0) at%") } }
                    }
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Divider().gridCellUnsizedAxes(.horizontal)
                    ForEach(rows, id: \.pin.id) { row in
                        GridRow {
                            HStack(spacing: 6) {
                                Circle().fill(EDXRegionBridge.color(row.pin.color, number: row.pin.number).color).frame(width: LayoutPolicy.regionSwatchSize, height: LayoutPolicy.regionSwatchSize)
                                Text(row.pin.name).lineLimit(1)
                            }
                            .gridColumnAlignment(.leading)
                            .opacity(row.pin.isVisible ? 1 : 0.5)
                            Text("\(row.pixels)").monospacedDigit()
                                .accessibilityLabel("\(row.pin.name) pixels").accessibilityValue("\(row.pixels)")
                                .accessibilityIdentifier("edx.regionTable.\(row.pin.name).pixels")
                            Text(EDXRoomFormat.counts(Double(row.counts))).monospacedDigit()
                                .accessibilityLabel("\(row.pin.name) counts").accessibilityValue("\(row.counts)")
                                .accessibilityIdentifier("edx.regionTable.\(row.pin.name).counts")
                            ForEach(Array(elements.enumerated()), id: \.offset) { i, symbol in
                                let net = row.net[i]
                                Text(net.map { EDXRoomFormat.counts($0) } ?? "–").monospacedDigit()
                                    .accessibilityLabel("\(row.pin.name) \(symbol) net counts")
                                    .accessibilityValue(net.map { String(format: "%.0f", $0) } ?? "")
                                    .accessibilityIdentifier("edx.regionTable.\(row.pin.name).\(symbol).net")
                            }
                            if hasComposition {
                                ForEach(Array(elements.enumerated()), id: \.offset) { i, symbol in
                                    let at = row.atomicPercent?[i]
                                    Text(at.map { Num.sig($0, 3) } ?? "–").monospacedDigit()
                                        .accessibilityLabel("\(row.pin.name) \(symbol) at%")
                                        .accessibilityValue(at.map { String(format: "%.1f", $0) } ?? "")
                                        .accessibilityIdentifier("edx.regionTable.\(row.pin.name).\(symbol).at")
                                }
                            }
                        }
                        .font(.callout)
                    }
                }
                .padding(10)
            }
            .accessibilityIdentifier("edx.regionTable")
        }
    }
}
