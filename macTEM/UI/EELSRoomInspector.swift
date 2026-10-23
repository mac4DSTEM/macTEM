//
//  EELSRoomInspector.swift
//  Role: the EELS room's inspector content, mounted by `WorkspaceInspector`'s Settings and Info switches, in the standard order (docs/design/eels-room.md):
//        Maps (one full-width control: ZLP · t/λ · t · at% · wt%, a segment off with its reason until its stage ran, one caption), Tools (the region tool and the
//        Regions list), Edges (the periodic table answered from the session), Processing (Align, Threshold, λ, Deconvolution; the stage's state on the title),
//        Fitting (model, background, convolution, E0 α β with their source) and Export. Info: the file, its grid and energy axis.
//        Presentation only: the state is `EELSSession` (TEMSession), the numbers SpectroKit's through it, the pure answers `TEMCore/EELS/EELSRoomChassis.swift`.
//

import ShellControls
import ShellInspector
import ShellLayout
import ShellSpectroscopy
import SwiftUI
import UniformTypeIdentifiers
import SpectroEELS
#if canImport(TEMCore)
import TEMCore
import TEMSession
#endif

struct EELSRoomSettings: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let session = appState.eels
        if session.hasImage {
            EELSMapsSection(session: session, state: appState.eelsRoom)
            EELSToolsSection(state: appState.eelsRoom)
            EELSEdgesSection(session: session)
            EELSProcessingSection(session: session)
            EELSFittingSection(session: session)
            EELSExportSection(session: session, state: appState.eelsRoom)
        } else {
            ContentUnavailableView("No EELS spectrum image open", systemImage: "chart.xyaxis.line",
                                   description: Text("Open an EELS spectrum image to map its thickness. Its controls appear here."))
        }
    }
}

/// Maps: the quantity the maps show, one full-width control, and under it the one caption. A segment whose stage has not run is refused with its reason (the caption
/// says it; the control stays where it was).
private struct EELSMapsSection: View {
    let session: EELSSession
    @Bindable var state: EELSRoomState

    var body: some View {
        let availability = session.mapsAvailability
        let selection = availability.effective(state.maps)
        InspectorSection("Maps") {
            // MacEMUI's SegmentedPicker has no disabled segment: a segment that is off carries its reason in its tooltip, a pick of it leaves the control where it was
            // and the one caption says why (delete at: SegmentedPicker takes a disabled segment).
            SegmentedPicker(label: "Maps", items: EELSMapsSegment.allCases.map { s in (s, .title(s.title, help: availability.disabledReason(s).map { "Off: \($0)" })) },
                            selection: Binding(get: { selection }, set: { new in
                                if let why = availability.disabledReason(new) { state.mapsNotice = why } else { state.maps = new; state.mapsNotice = nil }
                            }))
                .accessibilityIdentifier("eels.maps.control")
            InspectorNote(state.mapsNotice ?? availability.caption(selection))
                .accessibilityIdentifier("eels.maps.caption")
        }
    }
}

/// Tools: the region tool, one full-width control of icons, as in the EDS room. The regions live on the anchor tile and in the results' Regions table (Paul,
/// 2026-10-23: no region rows in the inspector).
private struct EELSToolsSection: View {
    @Bindable var state: EELSRoomState

    var body: some View {
        // The tool's hint is its tooltip: no paragraph under the control.
        InspectorSection("Tools") {
            SegmentedPicker(label: "Region tool", items: RegionTool.allCases.map { ($0, .symbol(name: $0.symbolName, label: $0.title, help: $0.hint)) }, selection: $state.tool)
                .controlSize(.large)
                .accessibilityIdentifier("eels.tool")
        }
    }
}

/// The periodic table answered from the session: only the elements with a bundled edge are live, and only those the core loss reaches. A click picks the default
/// edge (K where bundled, else L₂,₃) to quantify, a second click takes it off; a right-click gives the edge, Quantify and Off.
/// "Fit only" has no effect of its own yet (the composition is over every fitted edge), so it picks the edge like Quantify (delete at the next slice).
enum EELSPeriodicActions {
    static func make(_ session: EELSSession) -> PeriodicTableActions {
        func symbol(_ z: Int) -> String { PeriodicTableGrid.symbol(z) }
        let offered = session.offeredEdges, hasCore = session.workingCoreLoss != nil
        let window = session.workingCoreLoss.map(EELSEdgeChoices.window(of:))
        func picks(_ z: Int) -> [CoreLossEdge] { session.pickedEdges.filter { $0.element == symbol(z) } }
        func clear(_ z: Int) { for edge in picks(z) { session.toggleEdge(edge) } }
        func pickDefault(_ z: Int) {
            if picks(z).isEmpty, let edge = EELSEdgeChoices.defaultEdge(symbol: symbol(z), offered: offered) { session.toggleEdge(edge) }
        }
        return PeriodicTableActions(
            state: { z in
                if let why = EELSEdgeChoices.unavailableReason(symbol: symbol(z), offered: offered, hasCoreLoss: hasCore, windowEV: window) { return .unavailable(why) }
                return picks(z).isEmpty ? .off : .quantify
            },
            role: { z in picks(z).isEmpty ? .off : .quantify },
            click: { z in if picks(z).isEmpty { pickDefault(z) } else { clear(z) } },
            setRole: { z, role in if role == .off { clear(z) } else { pickDefault(z) } },
            families: { z in
                EELSEdgeChoices.families(symbol: symbol(z), offered: offered).map { f in
                    let on = session.pickedEdges.contains(f.edge)
                    return ElementLineFamily(family: f.name, isSelected: on,
                                             lines: [ElementLineChoice(id: EELSFitCompute.id(f.edge), title: "\(f.name) \(EELSRoomFormat.sig(f.edge.onsetEV, 5)) eV", isChecked: on)])
                }
            },
            setFamily: { z, family in
                if let f = EELSEdgeChoices.families(symbol: symbol(z), offered: offered).first(where: { $0.name == family }) { session.toggleEdge(f.edge) }
            },
            toggleLine: { z, id in
                if let edge = offered.first(where: { $0.element == symbol(z) && EELSFitCompute.id($0) == id }) { session.toggleEdge(edge) }
            },
            resetLines: { z in clear(z); pickDefault(z) },
            hasChosenLines: { z in
                let own = picks(z)
                return !own.isEmpty && own != EELSEdgeChoices.defaultEdge(symbol: symbol(z), offered: offered).map { [$0] }
            },
            mapped: { Array(Set(session.pickedEdges.compactMap { e in PeriodicTableGrid.symbols.firstIndex(of: e.element).map { $0 + 1 } })).sorted() })
    }
}

/// Edges: the periodic table and one line saying what is picked or why nothing can be.
private struct EELSEdgesSection: View {
    let session: EELSSession

    var body: some View {
        InspectorSection("Edges") {
            PeriodicTable(actions: EELSPeriodicActions.make(session))
                .accessibilityIdentifier("eels.periodicTable")
            EELSReferencesBlock(session: session)
            if session.workingCoreLoss == nil {
                InspectorNote("This file holds no core-loss spectrum image: the edge model fits one.")
            } else if session.pickedEdges.isEmpty {
                InspectorNote("Click an element to quantify its edge; right-click for the edge, Quantify or Off.")
            } else {
                InspectorNote("Quantify: " + session.pickedEdges.map { "\(EELSFitCompute.title($0)) \(EELSRoomFormat.sig($0.onsetEV, 5)) eV" }.joined(separator: ", "))
                    .accessibilityIdentifier("eels.edges.picked")
                // Back to the kit's default windows after a drag (Paul's drive, 2026-10-23: "how do I go back to the default?"); one edge: double-click its window.
                InspectorActionRow {
                    Button("Reset Windows") { session.resetAllWindows() }
                        .disabled(!session.hasEditedWindows)
                        .help("Every edge's background and signal windows back to the defaults; double-click one window on the spectrum for that edge alone")
                        .accessibilityIdentifier("eels.windows.reset")
                }
            }
        }
    }
}

/// Processing: one section for the stages before the edges: Align (fixed options in this version), Threshold, λ and Deconvolution (next slice). The stage's state is
/// on the title; the kit's readout is one line under the rows, and a refusal's sentence under that.
private struct EELSProcessingSection: View {
    let session: EELSSession

    private var isFixed: Bool { if case .fixed = session.threshold { true } else { false } }
    private var fixedValue: Double { if case .fixed(let eV) = session.threshold { eV } else { 3 } }

    private enum Kind: Hashable { case none, given, estimate }
    private var kind: Kind {
        switch session.meanFreePath {
        case .none: .none
        case .given: .given
        case .iakoubovskii: .estimate
        }
    }
    @State private var lambdaNotice: String?

    var body: some View {
        InspectorSection("Processing") {
            // The first row also carries the pipeline's four stages in words, for the UI journey (`eels.pipeline`: "Align current · Thickness
            // current · Edges not run · Fit not run").
            InspectorValueRow("Align method", "Maximum, then cross-correlation")
                .accessibilityIdentifier("eels.pipeline")
                .accessibilityValue(session.stages.map { "\($0.stage.title) \($0.state.word)" }.joined(separator: " · "))
            InspectorValueRow("Signal range", "±5 eV about 0")
            InspectorValueRow("Crop", "On")
            InspectorActionRow {
                Button("Align") { session.align() }
                    .disabled(session.isBusy || session.onlyCoreLoss)
                    .help(session.onlyCoreLoss ? "This file holds no zero-loss peak to align."
                          : "Shift every pixel's zero-loss peak to a common energy and recalibrate the axis (exSpy align_zero_loss_peak)")
                    .accessibilityIdentifier("eels.align")
            }
            InspectorRow("Threshold") {
                Picker("Threshold", selection: Binding(get: { isFixed }, set: { session.setThreshold($0 ? .fixed(fixedValue) : .estimated) })) {
                    Text("Estimated").tag(false)
                    Text("Fixed").tag(true)
                }
                .labelsHidden().fixedSize()
                .help("Estimated: the kit's inflexion rule, one tolerance for the whole map. Noisy data want a fixed threshold.")
                .accessibilityIdentifier("eels.threshold")
            }
            if case .fixed(let eV) = session.threshold {
                InspectorRow("Energy") {
                    OptionalNumericField(title: "Threshold", value: eV, format: FloatingPointFormatStyle<Double>.number.precision(.significantDigits(1...6)),
                                         unit: "eV", prompt: "3") { v in session.setThreshold(.fixed(v)) }
                        .accessibilityIdentifier("eels.thresholdEnergy")
                }
            }
            lambdaRows
            InspectorRow("Deconvolution") {
                // delete at: the deconvolution slice (the kit has Fourier-log, Fourier-ratio and Richardson-Lucy; the session does not call them yet)
                Picker("Deconvolution", selection: .constant("Off")) {
                    ForEach(["Off", "Fourier-log", "Fourier-ratio", "Richardson-Lucy"], id: \.self) { Text($0) }
                }
                .labelsHidden().fixedSize().disabled(true)
                .help("Deconvolution arrives with the next slice.")
                .accessibilityIdentifier("eels.deconvolution")
            }
            // One line for the section; the pixels the kit refused are its tooltip.
            InspectorNote(EELSRoomFormat.processingNote(align: session.alignState, thickness: session.thicknessState, alignmentReadout: session.alignmentReadout,
                                                        coreAligned: session.source?.coreLoss != nil && session.alignment != nil))
                .help(session.unavailableReasons.map { "\($0.count) px: \($0.reason)" }.joined(separator: "\n"))
                .accessibilityIdentifier("eels.alignReadout")
            if let failure = session.failure { InspectorWarning(failure, systemImage: "xmark.octagon.fill").accessibilityIdentifier("eels.processing.failure") }
        }
    }

    /// λ: none (t/λ only), a typed value, or the estimate (Iakoubovskii, from E₀, α, β and a density). The result says which it is.
    @ViewBuilder private var lambdaRows: some View {
        SegmentedPicker(label: "Mean free path λ", items: [(Kind.none, .title("No λ", help: "t/λ only")), (.given, .title("Typed λ", help: "Type λ in nm: t = λ · t/λ")),
                                                          (.estimate, .title("Estimate λ", help: session.lambdaEstimateBlocker ?? "Iakoubovskii's λ from E₀, α, β and a density"))],
                        selection: Binding(get: { kind }, set: select))
            .accessibilityIdentifier("eels.mfp")
        switch session.meanFreePath {
        case .none:
            EmptyView()
        case .given(let nm):
            InspectorRow("λ (nm)") {
                OptionalNumericField(title: "Mean free path", value: nm, format: FloatingPointFormatStyle<Double>.number.precision(.significantDigits(1...6)),
                                     unit: "nm", prompt: "100") { v in session.setMeanFreePath(.given(nanometres: v)) }
                    .accessibilityIdentifier("eels.lambda")
            }
        case .iakoubovskii(let rho, let alpha, let beta):
            InspectorValueRow("λ", session.map?.meanFreePathNM.map { "\(EELSRoomFormat.sig($0, 3)) nm · estimated" } ?? "estimated once the map has run")
                .accessibilityIdentifier("eels.lambda")
            InspectorRow("Density") {
                OptionalNumericField(title: "Density", value: rho, format: FloatingPointFormatStyle<Double>.number.precision(.significantDigits(1...6)),
                                     unit: "g/cm³", prompt: "2.7") { v in session.setMeanFreePath(.iakoubovskii(density: v, convergenceMrad: alpha, collectionMrad: beta)) }
            }
            InspectorRow("Convergence") {
                OptionalNumericField(title: "Convergence semi-angle", value: alpha, format: FloatingPointFormatStyle<Double>.number.precision(.significantDigits(1...6)),
                                     unit: "mrad", prompt: "0") { v in session.setMeanFreePath(.iakoubovskii(density: rho, convergenceMrad: v, collectionMrad: beta)) }
            }
            InspectorRow("Collection") {
                OptionalNumericField(title: "Collection semi-angle", value: beta, format: FloatingPointFormatStyle<Double>.number.precision(.significantDigits(1...6)),
                                     unit: "mrad", prompt: "0") { v in session.setMeanFreePath(.iakoubovskii(density: rho, convergenceMrad: alpha, collectionMrad: v)) }
            }
        }
        if let lambdaNotice { InspectorNote(lambdaNotice).accessibilityIdentifier("eels.lambda.notice") }
    }

    private func select(_ new: Kind) {
        let file = session.source
        lambdaNotice = nil
        switch new {
        case .none: session.setMeanFreePath(.none)
        case .given: session.setMeanFreePath(.given(nanometres: 100))
        case .estimate:
            if let why = session.lambdaEstimateBlocker { lambdaNotice = why; return }
            session.setMeanFreePath(.iakoubovskii(density: 2.7, convergenceMrad: session.typedConvergenceMrad ?? file?.convergenceMrad ?? 0,
                                                  collectionMrad: session.typedCollectionMrad ?? file?.collectionMrad ?? 0))
        }
    }
}

/// Fitting: the model (exact NNLS; MLLS next), the background, the convolution with the low loss and the microscope (E0, α, β, each with where it comes from).
private struct EELSFittingSection: View {
    let session: EELSSession

    var body: some View {
        let file = session.source
        InspectorSection("Fitting") {
            // delete at: the MLLS slice (the kit has EELSMLLS; the session fits by exact NNLS only). A pick of MLLS changes nothing.
            SegmentedPicker(label: "Model", items: [("Exact NNLS", .title("Exact NNLS")), ("MLLS", .title("MLLS", help: "Off: the MLLS fit arrives with the next slice."))],
                            selection: .constant("Exact NNLS"))
                .accessibilityIdentifier("eels.model")
            SegmentedPicker(label: "Background", items: EELSBackgroundChoice.allCases.map { c in (c, .title(c.title, help: c.disabledReason.map { "Off: \($0)" })) },
                            selection: Binding(get: { session.backgroundChoice }, set: { session.setBackground($0) }))
                .accessibilityIdentifier("eels.background")
            if let notice = session.backgroundNotice { InspectorNote(notice).accessibilityIdentifier("eels.background.notice") }
            InspectorRow("Convolve low loss") {
                Toggle("Convolve low loss", isOn: Binding(get: { session.convolveLowLoss && session.hasLowLoss }, set: { session.setConvolveLowLoss($0) }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    .disabled(!session.hasLowLoss)
                    .help(session.hasLowLoss ? "Convolve each edge with the low loss, as exSpy's model does: the fitted amounts are areal densities" : "No low loss in this file.")
                    .accessibilityIdentifier("eels.convolve")
            }
            if !session.hasLowLoss { InspectorNote("No low loss in this file: Convolve is off.") }
            InspectorRow("Beam energy") {
                OptionalNumericField(title: "Beam energy", value: session.beamEnergyKeV, format: FloatingPointFormatStyle<Double>.number.precision(.significantDigits(1...6)),
                                     unit: "keV", prompt: "Not set") { v in session.setBeamEnergy(v == file?.beamEnergyKeV ? nil : v) }
                    .accessibilityIdentifier("eels.beamEnergy")
            }
            InspectorRow("Convergence α") {
                OptionalNumericField(title: "Convergence semi-angle", value: session.typedConvergenceMrad ?? file?.convergenceMrad,
                                     format: FloatingPointFormatStyle<Double>.number.precision(.significantDigits(1...6)), unit: "mrad", prompt: "Not set") { v in session.setConvergence(v) }
                    .accessibilityIdentifier("eels.convergence")
            }
            InspectorRow("Collection β") {
                OptionalNumericField(title: "Collection semi-angle", value: session.typedCollectionMrad ?? file?.collectionMrad,
                                     format: FloatingPointFormatStyle<Double>.number.precision(.significantDigits(1...6)), unit: "mrad", prompt: "Not set") { v in session.setCollection(v) }
                    .accessibilityIdentifier("eels.collection")
            }
            InspectorNote("E₀ \(EELSRoomFormat.valueSource(typed: session.typedBeamEnergyKeV, file: file?.beamEnergyKeV)) · "
                          + "α \(EELSRoomFormat.valueSource(typed: session.typedConvergenceMrad, file: file?.convergenceMrad)) · "
                          + "β \(EELSRoomFormat.valueSource(typed: session.typedCollectionMrad, file: file?.collectionMrad))")
                .accessibilityIdentifier("eels.microscopeSources")
            if let why = session.fitBlocker { InspectorNote(why).accessibilityIdentifier("eels.fitBlocker") }
            if let why = session.fitRefusal { InspectorWarning(why, systemImage: "xmark.octagon.fill").accessibilityIdentifier("eels.fitRefusal") }
            if let model = session.model { InspectorNote("\(model.methodName) · validation: \(model.validation)") }
        }
    }
}

/// References: spectra to fit with (MLLS), taken from a region or imported from an MSA file, drawn dashed on the spectrum.
private struct EELSReferencesBlock: View {
    let session: EELSSession
    @State private var selected: EELSReference.ID?
    @State private var importing = false

    var body: some View {
        let picked = session.pickedEdges.filter { session.plot?.core?.range.contains($0.onsetEV) ?? false }
        VStack(alignment: .leading, spacing: 4) {
            Text("References").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if session.references.isEmpty {
                Text("None").font(.caption).foregroundStyle(.tertiary)
            } else {
                ForEach(session.references) { reference in
                    HStack(spacing: 6) {
                        Image(systemName: "waveform.path").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(reference.name).lineLimit(1).truncationMode(.middle)
                            Text(reference.originText).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 2).padding(.horizontal, 4)
                    .background(selected == reference.id ? Color.accentColor.opacity(0.25) : Color.clear, in: RoundedRectangle(cornerRadius: 4))
                    .contentShape(Rectangle())
                    .onTapGesture { selected = reference.id }
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(selected == reference.id ? .isSelected : [])
                }
            }
            InspectorActionRow {
                Menu("From region") {
                    ForEach(Array(picked.enumerated()), id: \.offset) { _, edge in
                        Button(EELSFitCompute.title(edge)) { selected = session.addReferenceFromRegion(edge: edge)?.id }
                    }
                }
                .menuStyle(.button).fixedSize()
                .disabled(picked.isEmpty)
                .help(picked.isEmpty ? "Pick an edge in the periodic table first: the reference is the region's spectrum over that edge's signal window, less the background."
                      : "The selected region's (else the whole map's) core loss over the edge's signal window, less the power-law background")
                .accessibilityIdentifier("eels.references.fromRegion")
                Button("Import…") { importing = true }
                    .help("Read a reference spectrum from an MSA file")
                    .accessibilityIdentifier("eels.references.import")
                Button("Remove") { if let selected { session.removeReference(selected); self.selected = nil } }
                    .disabled(selected == nil || !session.references.contains { $0.id == selected })
                    .help("Remove the selected reference")
                    .accessibilityIdentifier("eels.references.remove")
            }
            InspectorNote(session.referenceNotice ?? EELSReference.note).accessibilityIdentifier("eels.references.note")
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [UTType(filenameExtension: "msa"), .plainText].compactMap { $0 }, allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first { selected = session.importReference(url: url)?.id }
        }
    }
}

/// Export: the buttons the session can serve today, each disabled with its reason before its stage ran.
/// Export: the EDS room's rows (Paul's drive, 2026-10-23): Results and Spectrum, Regions and Maps, the per-pixel thickness and the method; the maps' region switch.
private struct EELSExportSection: View {
    @Environment(AppState.self) private var appState
    let session: EELSSession
    @Bindable var state: EELSRoomState

    var body: some View {
        let hasMap = session.map != nil, hasFit = !session.resultRows.isEmpty
        InspectorSection("Export") {
            InspectorActionRow {
                exportButton(.results, "Results CSV…", "tablecells", enabled: hasFit, help: "The results table: each edge's I and its 1σ, the areal density, at%, wt% and r, with the thickness line and the badge")
                exportButton(.spectrum, "Spectrum CSV…", "waveform", enabled: session.plot != nil, help: "The shown spectrum: the low loss and the core loss, energy and counts, and the model where it is fitted")
            }
            InspectorActionRow {
                exportButton(.regions, "Regions CSV…", "square.dashed", enabled: !session.pinRows.isEmpty, help: "Each kept region's pixels, I total, t/λ and the edges' I and at%")
                exportButton(.mapsPNG, "Maps…", "photo", enabled: hasMap, help: "The colour mix and the maps as one PNG")
            }
            InspectorActionRow {
                exportButton(.diagnostics, "Per-pixel CSV…", "tablecells.badge.ellipsis", enabled: hasMap,
                             help: "Every pixel: t/λ, its counting σ, I₀, I total, the zero-loss centre, the threshold, t and the kit's reason where there is none")
                exportButton(.method, "Method JSON…", "curlybraces", enabled: hasMap, help: "What made the map, with the unvalidated badge")
            }
            InspectorRow("Scale bar") {
                let hasPixelSize = session.scanPixel != nil
                Toggle("Scale bar", isOn: Binding(get: { state.exportScaleBar && hasPixelSize }, set: { state.exportScaleBar = $0 })).labelsHidden().toggleStyle(.switch)
                    .disabled(!hasPixelSize)
                    .help(hasPixelSize ? "Draw the scale bar on the exported maps" : "The file has no pixel size")
                    .accessibilityIdentifier("eels.export.scaleBar")
            }
            InspectorRow("Regions") {
                Toggle("Regions", isOn: $state.exportRegions).labelsHidden().toggleStyle(.switch)
                    .help("Draw the selected region on the exported maps")
                    .accessibilityIdentifier("eels.export.regions")
            }
            if !hasMap { InspectorNote("The exports need the thickness map: Run first.") } else if !hasFit { InspectorNote("Results need the edges fitted: pick edges, then Run.") }
        }
    }

    private func exportButton(_ kind: EELSExportKind, _ title: String, _ symbol: String, enabled: Bool, help: String) -> some View {
        Button(title, systemImage: symbol) {
            state.export(kind, from: session, maps: EELSMapsBlock.shownMaps(session, state), directory: appState.exportDirectory) { appState.statusText = $0 }
        }
        .disabled(!enabled)
        .help(help)
        .accessibilityIdentifier("eels.export.\(kind.rawValue)")
    }
}

struct EELSRoomInfo: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        if let source = appState.eels.source {
            let image = source.image
            InspectorSection("Spectrum Image") {
                InspectorValueRow("File", source.fileName)
                InspectorValueRow("Read as", source.origin)
                InspectorValueRow("Scan", "\(image.nx) × \(image.ny) px")
                InspectorValueRow("Channels", "\(image.channels)")
                InspectorValueRow("Energy axis", "\(EELSRoomFormat.sig(image.energyOffsetEV, 4)) eV + i × \(EELSRoomFormat.sig(image.energyScaleEV, 4)) eV")
                if let core = source.coreLoss {
                    InspectorValueRow("Core loss", "\(core.channels) ch from \(EELSRoomFormat.sig(core.energyOffsetEV, 5)) eV")
                    if let origin = source.coreLossOrigin { InspectorValueRow("Core loss from", origin) }
                }
                if let kv = source.beamEnergyKeV { InspectorValueRow("Beam", "\(EELSRoomFormat.sig(kv, 6)) keV") }
                if let a = source.convergenceMrad { InspectorValueRow("Convergence", "\(EELSRoomFormat.sig(a, 6)) mrad") }
                if let b = source.collectionMrad { InspectorValueRow("Collection", "\(EELSRoomFormat.sig(b, 6)) mrad") }
                if let size = source.scanPixelSize, let unit = source.scanPixelUnit { InspectorValueRow("Scan pixel", "\(EELSRoomFormat.sig(size, 6)) \(unit)") }
                InspectorNote("Counts are as the file stores them (no gain or dark reference).")
            }
        } else {
            ContentUnavailableView("No EELS spectrum image open", systemImage: "chart.xyaxis.line",
                                   description: Text("The file, its grid and its energy axis appear here."))
        }
    }
}
