//
//  EDXTypedKSheet.swift
//  Role: the sheet that types the Cliff-Lorimer k-factors: one row per quantified element (k and its relative σ), the source
//        line the kit requires, Done and Cancel. It edits `EDXTypedKDraft` (TEMCore) and hands a complete draft to the session,
//        which writes it into the method with today's date; the fit and the composition maps then follow. Presentation only.
//

import SwiftUI
import SpectroEDX
#if canImport(TEMCore)
import TEMCore
import TEMSession
#endif

struct EDXTypedKSheet: View {
    let session: EDXSession
    @Environment(\.dismiss) private var dismiss
    @State private var draft: EDXTypedKDraft

    init(session: EDXSession) {
        self.session = session
        _draft = State(initialValue: EDXTypedKDraft(elements: session.quantifiedSymbols, current: session.method))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Typed k-factors").font(.headline)
            Text("Cliff-Lorimer k for each quantified element, relative to any common element: only the ratios enter. σ is the relative 1σ in percent; empty takes \(Int((QuantificationMethod.defaultSigmaK * 100).rounded())) %.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if draft.rows.isEmpty {
                Text("Pick the elements to quantify first.").foregroundStyle(.secondary)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                    GridRow {
                        Text("Element").font(.caption).foregroundStyle(.secondary)
                        Text("k").font(.caption).foregroundStyle(.secondary)
                        Text("σ (%)").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach($draft.rows) { $row in
                        GridRow {
                            Text(row.element).font(.body.weight(.semibold))
                            TextField("k", value: $row.k, format: .number.precision(.significantDigits(1...6)), prompt: Text("required"))
                                .labelsHidden().multilineTextAlignment(.trailing).frame(width: EDXLayout.kFieldWidth)
                                .accessibilityLabel("k of \(row.element)")
                            TextField("σ", value: $row.sigmaPercent, format: .number.precision(.significantDigits(1...4)), prompt: Text("default"))
                                .labelsHidden().multilineTextAlignment(.trailing).frame(width: EDXLayout.sigmaFieldWidth)
                                .accessibilityLabel("σ of \(row.element) in percent")
                        }
                    }
                }
            }
            TextField("Source", text: $draft.source, prompt: Text("Where the k-factors come from (required)"), axis: .vertical)
                .lineLimit(1...3)
                .accessibilityIdentifier("edx.typedK.source")
            if let why = draft.incompleteReason {
                Label(why, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Done") {
                    session.commitTypedK(draft, date: Self.today())
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!draft.isComplete)
                .accessibilityIdentifier("edx.typedK.done")
            }
        }
        .padding(20)
        .frame(width: EDXLayout.typedKSheetWidth)
        .accessibilityIdentifier("edx.typedK")
    }

    /// The ISO date the factors were typed.
    static func today() -> String { Date.now.formatted(.iso8601.year().month().day()) }
}
