//
//  EDXFactorsSheet.swift
//  Role: the sheet that types the zeta factors or the ionisation cross sections of the maps' dose methods: one row per quantified
//        element, the beam current, the live time (and the probe area for cross sections), and the source line. It edits
//        `EDXFactorsDraft` (TEMCore) and hands a complete draft to the session. Until FormatoKit reads the dose from the file the
//        beam current and live time are typed here, one live time for every pixel. Presentation only.
//

import SwiftUI
import TEMCore
import TEMSession

struct EDXFactorsSheet: View {
    let session: EDXSession
    let method: EDXMapMethod
    @Environment(\.dismiss) private var dismiss
    @State private var draft: EDXFactorsDraft

    init(session: EDXSession, method: EDXMapMethod) {
        self.session = session
        self.method = method
        _draft = State(initialValue: EDXFactorsDraft(method: method, elements: session.quantifiedSymbols, current: session.dose))
    }

    private var unit: String { method == .zeta ? "kg/m² per count" : "barn" }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(method.title + " factors").font(.headline)
            Text(method == .zeta
                 ? "Zeta factors in kg/m² per electron-count unit, as eXSpy takes them. The dose is live time × beam current / e."
                 : "Ionisation cross sections in barn. The dose is live time × beam current / (e × probe area).")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if draft.rows.isEmpty {
                Text("Pick the elements to quantify first.").foregroundStyle(.secondary)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                    ForEach($draft.rows) { $row in
                        GridRow {
                            Text(row.element).font(.body.weight(.semibold))
                            TextField(method.factorName, value: $row.value, format: .number.precision(.significantDigits(1...6)), prompt: Text("required"))
                                .labelsHidden().multilineTextAlignment(.trailing).frame(width: EDXLayout.factorFieldWidth)
                                .accessibilityLabel("\(method.factorName) of \(row.element)")
                            Text(unit).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    GridRow {
                        Text("Beam current")
                        TextField("Beam current", value: $draft.beamCurrentNA, format: .number.precision(.significantDigits(1...6)), prompt: Text("required"))
                            .labelsHidden().multilineTextAlignment(.trailing).frame(width: EDXLayout.factorFieldWidth)
                        Text("nA").font(.caption).foregroundStyle(.secondary)
                    }
                    GridRow {
                        Text("Live time")
                        TextField("Live time", value: $draft.liveTimeSeconds, format: .number.precision(.significantDigits(1...6)), prompt: Text("required"))
                            .labelsHidden().multilineTextAlignment(.trailing).frame(width: EDXLayout.factorFieldWidth)
                        Text("s per pixel").font(.caption).foregroundStyle(.secondary)
                    }
                    if method == .crossSection {
                        GridRow {
                            Text("Probe area")
                            TextField("Probe area", value: $draft.probeAreaNm2, format: .number.precision(.significantDigits(1...6)), prompt: Text("required"))
                                .labelsHidden().multilineTextAlignment(.trailing).frame(width: EDXLayout.factorFieldWidth)
                            Text("nm²").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            TextField("Source", text: $draft.source, prompt: Text("Where the factors come from (required)"), axis: .vertical)
                .lineLimit(1...3)
                .accessibilityIdentifier("edx.factors.source")
            if let why = draft.incompleteReason {
                Label(why, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Done") {
                    session.commitFactors(draft, date: EDXTypedKSheet.today())
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!draft.isComplete)
                .accessibilityIdentifier("edx.factors.done")
            }
        }
        .padding(20)
        .frame(width: EDXLayout.factorsSheetWidth)
        .accessibilityIdentifier("edx.factors")
    }
}
