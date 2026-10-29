//
//  EDXRoomInspector.swift
//  Role: the EDX room's inspector content, mounted by `WorkspaceInspector`'s Settings and Info switches.
//        The Maps and Tools controls are MacEMUI's `SegmentedPicker` (AppKit, so they fill the inspector's width).
//        Settings, in the order a spectrum image is worked: Maps (the quantity the maps show, and what they need), Tools (the
//        region tool), Elements (the periodic table, Auto ID), Quantification (continuum, k-factors, absorption and thickness,
//        beam energy), Fitting (estimator, energy axis, fit range) and Export. Info: the file, its grid, energy axis and detector.
//        Presentation only: the state is `EDXSession` (TEMSession), the rest is SpectroKit's through it.
//
//        k-factors are computed (Bote-Salvat cross sections, Krause yield, EPQ detector efficiency; unvalidated) or typed
//        (`EDXTypedKSheet`: k, σ and the source per quantified element). The wt% / at% maps take typed k, or the fit's computed k, and the absorption correction when the file gives the geometry and a thickness is typed (EDXQuantMaps).
//

import ShellControls
import ShellInspector
import ShellMetal
import ShellSpectroscopy
import ShellLayout
import SwiftUI
import SpectroCore
import SpectroEDX
import TEMCore
import TEMSession

// MARK: - Settings

struct EDXRoomSettings: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let session = appState.edx
        if session.hasImage {
            EDXMapsSection(session: session, state: appState.edxRoom)
            EDXToolsSection(session: session, state: appState.edxRoom)
            EDXElementsSection(session: session)
            EDXQuantificationSection(session: session)
            EDXExportSection(session: session, state: appState.edxRoom)
        } else {
            ContentUnavailableView(EDXRoomFormat.emptyTitle, systemImage: "waveform.path.ecg",
                                   description: Text("\(EDXRoomFormat.openPrompt) Its controls appear here."))
        }
    }
}

/// Maps: the quantity the maps show, one full-width control, the display filter of the composition maps, and the one line saying what the maps need or are doing.
private struct EDXMapsSection: View {
    let session: EDXSession
    @Bindable var state: EDXRoomState

    var body: some View {
        if !session.isSingleSpectrum {
            InspectorSection("Maps") {
                SegmentedPicker(label: "Maps", items: EDXMapMode.allCases.map { ($0, .title($0.title, help: Self.help($0))) },
                                selection: Binding(get: { session.mapMode }, set: { session.setMapMode($0) }))
                    .accessibilityIdentifier("edx.mapMode")
                InspectorRow("Filter") {
                    Picker("Filter", selection: $state.mapFilter) {
                        ForEach(EDXMapFilter.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.menu).labelsHidden().fixedSize()
                    .disabled(session.mapMode == .net)
                    .help("A display kernel on the wt%, at% and Thickness maps, on by default. The readout, the exports and the results use the raw values; a filtered tile says so. Net maps are never filtered.")
                    .accessibilityIdentifier("edx.mapFilter")
                }
                status
            }
        }
    }

    private static func help(_ mode: EDXMapMode) -> String {
        switch mode {
        case .net: "Net counts of each line window"
        case .weight, .atomic: "The composition (\(mode.title)) from the typed or computed k-factors"
        case .massThickness: "The mass thickness (kg/m²)"
        }
    }

    @ViewBuilder private var status: some View {
        switch session.mapsState {
        case .idle, .done: EmptyView()
        case .blocked(let why): InspectorNote(why).accessibilityIdentifier("edx.mapsStatus")
        case .running:
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Computing \(session.mapMode.title) maps…") }
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("edx.mapsStatus")
        case .failed(let why): InspectorWarning(why, systemImage: "xmark.octagon.fill").accessibilityIdentifier("edx.mapsStatus")
        }
    }
}

/// Elements: the periodic table and Auto ID; what Auto ID found is one line under the results (the fit footer's popover), not here.
private struct EDXElementsSection: View {
    let session: EDXSession

    var body: some View {
        let autoID = session.autoID
        InspectorSection("Elements") {
            EDXPeriodicTable(session: session)
            InspectorActionRow {
                Button("Auto ID") { session.runAutoID(explicit: true) }
                    .disabled(autoID == .running)
                    .help("Propose elements from the region's spectrum (the element proposer, unvalidated rules)")
                    .accessibilityIdentifier("edx.autoID")
                if autoID == .running { ProgressView().controlSize(.small) }
            }
            if case .failed(let message) = autoID { InspectorWarning(message, systemImage: "xmark.octagon.fill") }
        }
    }
}

/// Tools: the region tool, one full-width control of icons. The regions live on the colour mix and in the results; the whole map is no region.
private struct EDXToolsSection: View {
    let session: EDXSession
    @Bindable var state: EDXRoomState

    var body: some View {
        if !session.isSingleSpectrum {
            InspectorSection("Tools") {
                SegmentedPicker(label: "Region tool", items: RegionTool.allCases.map { ($0, .symbol(name: $0.symbolName, label: $0.title, help: $0.hint)) },
                                selection: $state.tool)
                    .controlSize(.large)
                    .accessibilityIdentifier("edx.tool")
            }
        }
    }
}

private struct EDXQuantificationSection: View {
    let session: EDXSession
    @State private var showTypedK = false
    @State private var showFactors = false

    var body: some View {
        let method = session.method
        let fit = session.fit
        InspectorSection("Quantification") {
            InspectorRow("Continuum") {
                Picker("Continuum", selection: binding(\.background)) {
                    Text("Empirical").tag(QuantificationMethod.Background.empiricalWithAlEdge)
                    Text("Polynomial").tag(QuantificationMethod.Background.wholeRangePolynomial6)
                }
                .labelsHidden().fixedSize()
                .help("Empirical: a fitted whole-spectrum continuum with the Al K-edge step. Polynomial: exSpy's whole-range sixth-order polynomial.")
            }
            InspectorRow("k-factors") {
                Picker("k-factors", selection: Binding(get: { method.kFactorSource },
                                                      set: { session.setKFactorSource($0) })) {
                    Text("Computed").tag(QuantificationMethod.KFactorSource.computed)
                    Text("Typed").tag(QuantificationMethod.KFactorSource.typed)
                }
                .labelsHidden().fixedSize()
                .help("Computed: the kit's own k. Typed: Cliff-Lorimer k-factors you give, with their source. The wt% and at% maps take either; the computed k comes from the fit (press Quantify).")
                .accessibilityIdentifier("edx.kSource")
            }
            if method.kFactorSource == .typed {
                InspectorValueRow("Source", method.kSource.isEmpty ? "Not set" : method.kSource)
                if !method.kDate.isEmpty { InspectorValueRow("Typed on", method.kDate) }
                InspectorActionRow {
                    Button("Edit k-factors…") { showTypedK = true }
                        .accessibilityIdentifier("edx.typedK.edit")
                }
            } else {
                InspectorNote("Bote-Salvat cross sections, Krause yield, EPQ detector efficiency: validation none. The maps take this k from the fit once Quantify has run.")
            }
            InspectorRow("Maps method") {
                Picker("Maps method", selection: Binding(get: { session.mapMethod },
                                                         set: { new in
                                                             session.setMapMethod(new)
                                                             if new != .cliffLorimer { showFactors = true }
                                                         })) {
                    ForEach(EDXMapMethod.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden().fixedSize()
                .help("How the wt% and at% maps are quantified. The results table is always Cliff-Lorimer.")
                .accessibilityIdentifier("edx.mapMethod")
            }
            if session.mapMethod != .cliffLorimer {
                InspectorValueRow("Factors", session.dose.source.isEmpty ? "Not set" : session.dose.source)
                InspectorActionRow {
                    Button("Edit factors…") { showFactors = true }.accessibilityIdentifier("edx.factors.edit")
                }
            }
            InspectorRow("Beam energy") {
                OptionalNumericField(title: "Beam energy", value: session.beamEnergy, format: FloatingPointFormatStyle<Double>.number.precision(.significantDigits(1...6)),
                                     unit: "keV", prompt: "Not set") { v in
                    session.changeMethod { $0.beamEnergyKeV = v == session.fileBeamEnergy ? nil : v }
                }
                .accessibilityIdentifier("edx.beam")
            }
            if session.fileBeamEnergy == nil {
                InspectorNote("The file does not state the beam energy: type it.")
            }
            InspectorRow("Absorption") {
                Toggle("Absorption", isOn: binding(\.absorptionCorrection)).labelsHidden().toggleStyle(.switch)
                    .help("Four-detector weighted transmission. It needs the thickness; without one the fit says it was not applied.")
            }
            InspectorRow("Thickness") {
                OptionalNumericField(title: "Thickness", value: method.thickness?.nanometres ?? 0,
                                     format: FloatingPointFormatStyle<Double>.number.precision(.significantDigits(1...6)), unit: "nm", prompt: "Not set") { v in
                    session.changeMethod { $0.thickness = v > 0 ? .init(nanometres: v, sigmaNanometres: $0.thickness?.sigmaNanometres ?? 0) : nil }
                }
            }
            InspectorRow("Thickness ±") {
                OptionalNumericField(title: "Thickness uncertainty", value: method.thickness?.sigmaNanometres ?? 0,
                                     format: FloatingPointFormatStyle<Double>.number.precision(.significantDigits(1...6)), unit: "nm", prompt: "0") { v in
                    session.changeMethod { if let t = $0.thickness { $0.thickness = .init(nanometres: t.nanometres, sigmaNanometres: max(v, 0)) } }
                }
                .disabled(method.thickness == nil)
            }
            if let fit {
                InspectorValueRow("Fit quality", EDXRoomFormat.fitQuality(fit))
                if case .refused(let why) = fit.absorption { InspectorNote("Absorption not applied: \(why)") }
            }
        }
        // Fitting: the fit's own knobs as plain rows of their own section (mac4DSTEM's Fitting), not a disclosure inside Quantification.
        InspectorSection("Fitting") {
            InspectorRow("Estimator") {
                Picker("Estimator", selection: binding(\.estimator)) {
                    Text("Least squares").tag(QuantificationMethod.Estimator.leastSquares)
                    Text("Poisson ML").tag(QuantificationMethod.Estimator.poissonMaximumLikelihood)
                }
                .labelsHidden().fixedSize()
                .accessibilityIdentifier("edx.estimator")
            }
            InspectorRow("σ_k") {
                OptionalNumericField(title: "σ_k", value: method.sigmaK * 100, format: FloatingPointFormatStyle<Double>.number.precision(.significantDigits(1...4)), unit: "%") { v in
                    session.changeMethod { $0.sigmaK = min(max(v, 0), 100) / 100 }
                }
                .help("The relative uncertainty of a computed k-factor, carried into the composition's uncertainties")
                .accessibilityIdentifier("edx.sigmaK")
            }
            if method.background == .wholeRangePolynomial6 {
                InspectorRow("Poly order") {
                    Stepper("\(method.polynomialOrder ?? 6)", value: Binding(get: { method.polynomialOrder ?? 6 }, set: { v in session.changeMethod { $0.polynomialOrder = v } }), in: 0...8)
                }
            }
            InspectorRow("Lock energy axis") {
                Toggle("Lock energy axis", isOn: Binding(get: { method.lockEnergyAxis == true },
                                                         set: { on in session.changeMethod { $0.lockEnergyAxis = on ? true : nil } }))
                    .labelsHidden().toggleStyle(.checkbox)
                    .help("Do not refine the energy offset, gain and width on the pooled spectrum")
                    .accessibilityIdentifier("edx.lockAxis")
            }
            InspectorRow("Fit to") {
                OptionalNumericField(title: "Fit to", value: method.fitToKeV,
                                     format: FloatingPointFormatStyle<Double>.number.precision(.significantDigits(1...6)), unit: "keV", prompt: "default") { v in
                    session.changeMethod { $0.fitToKeV = v > 0.2 ? v : nil }
                }
                .help("Upper end of the fitted range. Empty: the default, the axis end or the beam energy but at most 20 keV")
                .accessibilityIdentifier("edx.fitTo")
            }
        }
        // Choosing Typed opens the k-factors sheet. The picker's binding only writes the source; the presentation follows the change here, not
        // from inside the binding's setter during the picker's own update.
        .onChange(of: method.kFactorSource) { old, new in if new == .typed, old != .typed { showTypedK = true } }
        .sheet(isPresented: $showTypedK) { EDXTypedKSheet(session: session) }
        .sheet(isPresented: $showFactors) { EDXFactorsSheet(session: session, method: session.mapMethod) }
    }

    /// A control onto the method: it reads the property and writes through the session, which refits once Quantify has run.
    private func binding<V: Equatable>(_ keyPath: WritableKeyPath<QuantificationMethod, V>) -> Binding<V> {
        Binding(get: { session.method[keyPath: keyPath] }, set: { new in session.changeMethod { $0[keyPath: keyPath] = new } })
    }
}

private struct EDXExportSection: View {
    @Environment(AppState.self) private var appState
    let session: EDXSession
    let state: EDXRoomState

    var body: some View {
        let hasFit = session.fit != nil && !session.isFitting && !session.isChecking
        let hasPixelSize = session.scanPixel != nil
        InspectorSection("Export") {
            // Buttons and rows as mac4DSTEM's Export section, not a pop-up menu: what each writes is on its button.
            InspectorActionRow {
                exportButton(.results, "Results CSV…", "tablecells", enabled: hasFit, help: "The results table: element, line, net counts, at% and wt%, with the fit's provenance and the unvalidated badge")
                exportButton(.method, "Method JSON…", "curlybraces", enabled: hasFit, help: "The quantification method in its own sorted-keys encoding, with its SHA-256")
            }
            InspectorActionRow {
                exportButton(.spectrum, "Spectrum CSV…", "waveform", enabled: !session.spectrumCounts.isEmpty, help: "The shown spectrum as energy and counts")
                exportButton(.spectrumMSA, "Spectrum MSA…", "waveform.path", enabled: !session.spectrumCounts.isEmpty, help: "The shown spectrum as an EMSA/MAS file")
            }
            InspectorActionRow {
                exportButton(.pins, "Regions CSV…", "square.dashed", enabled: !session.pins.isEmpty, help: "Each kept region's pixels, counts, net counts and composition")
                exportButton(.mapsPNG, "Maps…", "photo", enabled: !session.shownTiles.isEmpty, help: "The maps as one PNG")
            }
            InspectorRow("Scale bar") {
                Toggle("Scale bar", isOn: Binding(get: { state.exportScaleBar && hasPixelSize }, set: { state.exportScaleBar = $0 })).labelsHidden().toggleStyle(.switch)
                    .disabled(!hasPixelSize)
                    .help(hasPixelSize ? "Draw the scale bar on the exported maps" : "The file has no pixel size")
                    .accessibilityIdentifier("edx.export.scaleBar")
            }
            InspectorRow("Regions") {
                Toggle("Regions", isOn: Bindable(state).exportRegions).labelsHidden().toggleStyle(.switch)
                    .help("Draw the selected region on the exported maps")
                    .accessibilityIdentifier("edx.export.regions")
            }
            if !hasFit { InspectorNote("Results and method need Quantify first.") }
        }
    }

    private func exportButton(_ kind: EDXExportKind, _ title: String, _ symbol: String, enabled: Bool, help: String) -> some View {
        Button(title, systemImage: symbol) { Task { await state.export(kind, from: session, directory: appState.exportDirectory) { appState.statusText = $0 } } }
            .disabled(!enabled)
            .help(help)
            .accessibilityIdentifier("edx.export.\(kind.rawValue)")
    }
}

// MARK: - Info

struct EDXRoomInfo: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        if let source = appState.edx.source {
            let m = source.metadata
            InspectorSection("Spectrum Image") {
                InspectorValueRow("File", m.fileName)
                InspectorValueRow("Format", m.origin == .veloxEMD ? "Velox EMD" : m.origin == .gmsDM4 ? "GMS DM4" : "–")
                InspectorValueRow("Scan", "\(m.scanWidth) × \(m.scanHeight) px")
                if let size = m.scanPixelSize, let unit = m.scanPixelUnit {
                    InspectorValueRow("Pixel size", "\(Num.sig(size, 4)) \(unit)")
                }
                InspectorValueRow("Channels", "\(m.channelCount)")
                InspectorValueRow("Energy axis", "\(Num.sig(m.energyOffsetEV, 4)) eV + i × \(Num.sig(m.energyDispersionEV, 4)) eV")
                if let frames = m.frames { InspectorValueRow("Frames", "\(frames)") }
                if let kv = m.beamEnergyKeV { InspectorValueRow("Beam", "\(Num.sig(kv, 6)) keV · \(m.beamEnergySource.phrase)") }
                if let a = m.alphaTiltDegrees { InspectorValueRow("Alpha tilt", "\(Num.sig(a, 6))°") }
                if let b = m.betaTiltDegrees { InspectorValueRow("Beta tilt", "\(Num.sig(b, 6))°") }
                if let i = m.instrument { InspectorValueRow("Instrument", i) }
            }
            if !m.detectors.isEmpty {
                InspectorSection("Detectors") {
                    ForEach(m.detectors, id: \.name) { d in
                        InspectorValueRow(d.name, [d.azimuthDegrees.map { "az \(Num.fixed($0, 1))°" },
                                                  d.elevationDegrees.map { "el \(Num.fixed($0, 1))°" },
                                                  d.solidAngle.map { "\(Num.sig($0, 3)) sr" }].compactMap { $0 }.joined(separator: " · "))
                    }
                    InspectorNote("As the file records them; live and real times are not interpreted.")
                }
            }
        } else {
            ContentUnavailableView(EDXRoomFormat.emptyTitle, systemImage: "waveform.path.ecg",
                                   description: Text("The file, its grid and its detector appear here."))
        }
    }
}
