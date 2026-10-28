//
//  EDXResultsPanel.swift
//  Role: the EDX room's results, beside the spectrum: before Quantify the window net counts of the picked elements, after it
//        the pooled fit's rows (net, at%, wt%), with everything the fit says about itself under the table: the validation
//        badge, the warnings, the unlisted-line check, the fit quality and the fit's own footer lines. Presentation only:
//        every number and sentence is the kit's (`PooledQuantification`), formatted by `EDXRoomFormat`.
//
//        at% rests on a computed or typed k whose validation is "none": it is badged unvalidated wherever it is shown and is
//        never called validated (CLAUDE.md, "Unvalidated stays labelled").
//

import ShellInspector
import ShellLayout
import SwiftUI
import SpectroEDX
import TEMCore
import TEMSession

struct EDXResultsPanel: View {
    let session: EDXSession

    var body: some View {
        // One read of each observed property, here.
        let fit = session.fit
        let rows = session.windowRows
        let failure = session.fitFailure
        let isFitting = session.isFitting
        let isChecking = session.isChecking
        let autoID = session.autoID
        VStack(spacing: 0) {
            HStack(spacing: LayoutPolicy.inspectorRowSpacing) {
                Text("Results · \(session.regionName)").font(.callout.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 0)
                // The badge, once, here: the at% and wt% columns say only their names.
                if fit?.hasAbundance == true {
                    Text("at%, wt%: validation none")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                        .help("at% and wt% rest on a k with validation \u{201C}none\u{201D}: unvalidated")
                        .accessibilityIdentifier("edx.validationBadge")
                }
                if isFitting { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, LayoutPolicy.infobarHorizontalPadding)
            .frame(height: LayoutPolicy.paneHeaderHeight)
            Divider()
            // The table keeps the room: whatever the fit says about itself is one line below it, opening a popover.
            Group {
                if let fit {
                    FitTable(fit: fit)
                } else if rows.isEmpty {
                    ContentUnavailableView("No results yet", systemImage: "list.bullet.rectangle",
                                           description: Text(EDXRoomFormat.noElementsDetail))
                } else {
                    WindowTable(rows: rows)
                }
            }
            .frame(maxHeight: .infinity)
            if !session.pinRows.isEmpty {
                // The regions, one row each: a result of the same standing as the composition (it was a tab of its own).
                Divider()
                Text("Regions").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    .padding(.horizontal, LayoutPolicy.infobarHorizontalPadding).padding(.top, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                EDXRegionTable(rows: session.pinRows)
                    .frame(height: min(CGFloat(session.pinRows.count) * 22 + 34, 170))   // science: a table's rows
            }
            if let failure {
                InspectorWarning(failure, systemImage: "xmark.octagon.fill")
                    .padding(.horizontal, LayoutPolicy.infobarHorizontalPadding).padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if fit != nil || autoID.outcome != nil { FitFooter(fit: fit, autoID: autoID.outcome, isChecking: isChecking) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("edx.results")
    }
}

private struct WindowTable: View {
    let rows: [EDXWindowRow]

    var body: some View {
        Table(rows) {
            TableColumn("Element") { r in Text(r.symbol).fontWeight(.semibold) }.width(min: 50, ideal: 60)
            TableColumn("Line") { r in Text(r.line).lineLimit(1) }.width(min: 50, ideal: 60)
            TableColumn("Net counts") { r in
                if let f = r.failure {
                    Label("not a measurement", systemImage: "exclamationmark.triangle.fill").labelStyle(.titleAndIcon).help(f)
                } else {
                    Text(EDXRoomFormat.plusMinus(r.net, r.sigma)).monospacedDigit().help(r.note ?? "σ² = G + s²B, counting only")
                }
            }.width(min: 110, ideal: 140)
        }
        .alternatingRowBackgrounds(.disabled)   // three rows, not a page of stripes
        .accessibilityIdentifier("edx.results.table")
    }
}

private struct FitTable: View {
    let fit: PooledQuantification

    var body: some View {
        let rows = EDXRoomFormat.fitRows(fit)
        Table(rows) {
            TableColumn("Element") { r in
                HStack(spacing: 4) {
                    Text(r.element).fontWeight(.semibold).accessibilityIdentifier("edx.composition.\(r.element)")
                    // The reference element of the computed k says so in a word; anything else the fit says about a row is a mark with the sentence as its help.
                    if r.isReference { Text("ref.").font(.caption).foregroundStyle(.secondary).help("The reference element: its computed k is 1 by definition, the others are relative to it") }
                    if let n = r.note { Image(systemName: "exclamationmark.circle").foregroundStyle(.secondary).help(n).accessibilityLabel(n) }
                }
            }.width(min: 56, ideal: 70)
            TableColumn("Net") { r in Text(r.net).monospacedDigit().lineLimit(1).help(r.line) }.width(min: 96, ideal: 112)
            TableColumn("at%") { r in Text(r.atPercent).monospacedDigit().lineLimit(1) }.width(min: 70, ideal: 90)
            TableColumn("wt%") { r in
                Text(r.wtPercent).monospacedDigit().lineLimit(1)
                    .accessibilityIdentifier("edx.composition.\(r.element).wt")
                    .accessibilityValue(r.wtValue.map { String(format: "%.4f", $0) } ?? "")
            }.width(min: 70, ideal: 90)
        }
        .alternatingRowBackgrounds(.disabled)
        .accessibilityIdentifier("edx.compositionTable")
    }
}

/// One line under the table: how many notes the fit has on its numbers and how well it fits; a click opens everything the fit says about itself (the notes, the unlisted-line check, the
/// fit's own footer lines) in a popover, so the table is never squeezed.
private struct FitFooter: View {
    let fit: PooledQuantification?
    let autoID: EDXCompute.AutoIDOutcome?
    let isChecking: Bool
    @State private var open = false

    /// What the fit says about its abundances and its lines, each the kit's own sentence (the validation badge is in the panel header), then what the last Auto ID run found and doubted.
    private static func notes(of fit: PooledQuantification?, autoID: EDXCompute.AutoIDOutcome?) -> [String] {
        var out: [String] = []
        if let fit {
            if let why = fit.abundanceRefusal, !fit.hasAbundance { out.append("at% not computed: \(why)") }
            if let caveat = fit.abundanceCaveat { out.append("at% caveat: \(caveat)") }
            out += fit.warnings
        }
        if let autoID { out += autoID.suspects + autoID.excesses + autoID.uncorroborated }
        return out
    }

    private var summary: String {
        if let fit { return EDXRoomFormat.fitQuality(fit) }
        guard let autoID else { return "" }
        return autoID.suggestions.isEmpty ? "Auto ID found nothing more" : "Auto ID picked " + autoID.suggestions.map(\.symbol).joined(separator: ", ")
    }

    var body: some View {
        let notes = Self.notes(of: fit, autoID: autoID)
        Button { open.toggle() } label: {
            HStack(spacing: 6) {
                if !notes.isEmpty { Text("\(notes.count) \(notes.count == 1 ? "note" : "notes")") ; Text("·") }
                Text(summary)
                if isChecking { ProgressView().controlSize(.mini) }
                Spacer(minLength: 0)
                Image(systemName: "chevron.up").font(.caption2)
            }
            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            .padding(.horizontal, LayoutPolicy.infobarHorizontalPadding)
            .frame(height: LayoutPolicy.paneHeaderHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .top) { Divider() }
        .popover(isPresented: $open, arrowEdge: .top) {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(notes, id: \.self) { InspectorWarning($0) }
                    if let autoID {
                        Text("Auto ID · \(autoID.region)").font(.caption.weight(.semibold))
                        ForEach(autoID.suggestions, id: \.symbol) { InspectorNote("\($0.symbol): \($0.reason)") }
                    }
                    if let fit {
                        if let check = fit.unlistedCheck { InspectorNote(check.line).help(check.summary) }
                        Text("Fit · \(EDXRoomFormat.fitQuality(fit))").font(.caption.weight(.semibold))
                        ForEach(fit.footerLines, id: \.self) { InspectorNote($0) }
                    }
                }
                .padding(12)
            }
            .frame(width: 360, height: 280)   // science: a popover's text
        }
        .help("What the fit and Auto ID say about their own numbers")
        .accessibilityLabel("Fit notes")
        .accessibilityIdentifier("edx.notes")
    }
}
