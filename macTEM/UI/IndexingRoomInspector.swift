//
//  IndexingRoomInspector.swift
//  Role: the Indexing room's inspector content, mounted by `WorkspaceInspector`'s Settings and Info switches, in the Image room's order
//        (control placement §2; design §4): Calibration (where the patterns come from and the geometry the indexer takes, as value rows),
//        Display (the map's layer, the detected bands), Pattern Display (the pattern pane's own contrast), Phases (the list indexed
//        against, each with its colour and its switch; a preset or a CIF added), Method (Hough or Dictionary, D-SEM-91), then the
//        method's own section: Hough (pyEBSDindex's `EBSDIndexer` parameters) or Dictionary (the master pattern, kikuchipy's
//        `dictionary_indexing` settings and orix's sampling), and Export (the map, the results, the method). Info: the dataset's rows
//        (Patterns › Info) and the run's. Presentation only: the state is `IndexingSession`'s (TEMSession), the phases
//        `IndexingPhase`'s and the dictionary's `DictionaryIndexingPlan`'s (TEMCore).
//

import DiffractoCore
import ShellControls
import ShellInspector
import ShellLayout
import SwiftUI
import UniformTypeIdentifiers
import TEMCore
import TEMSession

struct IndexingRoomSettings: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let session = appState.indexing
        if let dataset = session.patterns.dataset {
            IndexingCalibrationSection(session: session, dataset: dataset)
            IndexingDisplaySection(session: session)
            ImageRoomDisplaySection(presentation: session.patternPresentation, title: "Pattern Display", colormapID: "indexing.pattern.colormap")
            IndexingPhasesSection(session: session)
            IndexingMethodSection(session: session)
            switch session.method {
            case .hough: IndexingHoughSection(session: session)
            case .dictionary: IndexingDictionarySection(session: session)
            }
            IndexingExportSection(session: session, state: appState.indexingRoom)
        } else {
            ContentUnavailableView("No EBSD dataset open", systemImage: "scope",
                                   description: Text("Open an h5ebsd pattern file to index its scan. Its controls appear here."))
        }
    }
}

// MARK: - Calibration

/// What the indexer takes from the Patterns room (design §4): the patterns as the pipeline makes them, the mean projection centre, the
/// tilts and the pattern's size; the settings live in Patterns, so the one action goes there.
private struct IndexingCalibrationSection: View {
    @Environment(AppState.self) private var appState
    let session: IndexingSession
    let dataset: EBSDDataset

    private var patternsRow: String {
        switch session.source() {
        case .success(let source):
            guard source.kind != .asStored else { return source.kind.title }
            let stages = PatternPipeline.Stage.allCases.filter { session.patterns.pipeline.isActive($0) }.count
            return "\(source.kind.title) · \(stages) stage\(stages == 1 ? "" : "s")"
        case .failure:
            return "Not readable as set"
        }
    }

    var body: some View {
        let detector = dataset.detector
        InspectorSection("Calibration") {
            InspectorValueRow("Patterns", patternsRow)
                .accessibilityIdentifier("indexing.calibration.patterns")
            if let pc = IndexingPlan.meanProjectionCenter(detector) {
                InspectorValueRow("PC", "(\(UnitDisplay.number(pc.x, digits: 4)), \(UnitDisplay.number(pc.y, digits: 4)), \(UnitDisplay.number(pc.z, digits: 4)))")
                    .help(detector.projectionCenters.count > 1 ? "The mean of the file's \(detector.projectionCenters.count) projection centres, Bruker convention (kikuchipy's pc_average)"
                          : "The file's projection centre, Bruker convention")
                    .accessibilityIdentifier("indexing.calibration.pc")
            } else {
                InspectorValueRow("PC", "None in the file")
                    .accessibilityIdentifier("indexing.calibration.pc")
            }
            InspectorValueRow("Sample tilt", "\(UnitDisplay.number(detector.sampleTilt))°")
            InspectorValueRow("Camera tilt", "\(UnitDisplay.number(detector.tilt))°")
            InspectorValueRow("Pattern", "\(session.patternShape.columns > 0 ? session.patternShape.columns : dataset.patternColumns) × \(session.patternShape.rows > 0 ? session.patternShape.rows : dataset.patternRows) px")
            InspectorActionRow {
                Button("Edit in Patterns") { appState.selectWorkspace(.patterns) }
                    .help("The processing, the background and the geometry are the Patterns room's; a change there stales this room's result")
                    .accessibilityIdentifier("indexing.editInPatterns")
            }
        }
    }
}

// MARK: - Display

/// The map's layer (eight for Hough, five for a dictionary: a pop-up, control placement §3) and the detected bands over the pattern.
private struct IndexingDisplaySection: View {
    let session: IndexingSession

    var body: some View {
        InspectorSection("Display") {
            InspectorRow("Map") {
                Picker("Map", selection: Binding(get: { session.layer }, set: { session.setLayer($0) })) {
                    ForEach(session.availableLayers) { layer in Text(layer.title).tag(layer) }
                }
                .labelsHidden()
                .help(session.layer.help)
                .accessibilityIdentifier("indexing.layer")
            }
            InspectorRow("Detected bands") {
                Toggle("Show the detected bands", isOn: Binding(get: { session.showsDetectedBands }, set: { session.showsDetectedBands = $0 }))
                    .toggleStyle(.switch).labelsHidden()
                    .help("The bands the Hough transform found on the pattern: matched solid green with their family, unmatched dashed orange")
                    .accessibilityIdentifier("indexing.showBands")
            }
        }
    }
}

// MARK: - Phases

/// The phases indexed against (design §4): the file's crystal map's, then those added; each with its colour on the Phase map, its
/// space group and reflector list, and a switch. A phase is edited by picking it: its reflector list and Remove.
private struct IndexingPhasesSection: View {
    @Environment(AppState.self) private var appState
    let session: IndexingSession
    @State private var preset = IndexingPhase.presets.first?.name ?? "Ni"
    @State private var edited: String?
    @State private var importing = false

    private var editedPhase: IndexingPhase? {
        session.phases.first { $0.name == edited } ?? session.phases.first
    }

    var body: some View {
        let count = session.phases.count
        let on = session.phasesOn.count
        InspectorSection("Phases", status: count == 0 ? "none" : "\(on) of \(count) on") {
            ForEach(session.phases) { phase in
                IndexingPhaseRow(phase: phase, isOn: Binding(get: { phase.isOn }, set: { session.setPhase(named: phase.name, isOn: $0) }))
            }
            if let phase = editedPhase {
                InspectorRow("Edit") {
                    Picker("Phase to edit", selection: Binding(get: { phase.name }, set: { edited = $0 })) {
                        ForEach(session.phases) { Text($0.name).tag($0.name) }
                    }
                    .labelsHidden()
                    .help("The phase whose reflector list and removal the controls below apply to")
                    .accessibilityIdentifier("indexing.phase.edited")
                }
                SegmentedPicker(label: "Reflectors", items: IndexingPhase.Reflectors.allCases.map { r in
                    (r, .title(r.title, help: "pyEBSDindex's \(r.title) reflector list",
                               disabledReason: r.fits(spaceGroup: phase.spaceGroup) ? nil : "The HCP list takes a hexagonal space group (168 to 194)"))
                }, selection: Binding(get: { phase.reflectors }, set: { session.setReflectors($0, named: phase.name) }))
                    .accessibilityIdentifier("indexing.phase.reflectors")
                InspectorActionRow {
                    Button("Remove \(phase.name)") {
                        session.removePhase(named: phase.name)
                        edited = nil
                    }
                    .help("Take the phase out of the list; the file is unchanged")
                    .accessibilityIdentifier("indexing.phase.remove")
                }
            }
            InspectorRow("Preset") {
                Picker("Preset", selection: $preset) {
                    ForEach(IndexingPhase.presets) { Text($0.name).tag($0.name) }
                }
                .labelsHidden()
                .help("The built-in phases, with DiffractoKit's lattice constants")
                .accessibilityIdentifier("indexing.preset")
            }
            InspectorActionRow {
                Button("Add Preset") {
                    guard let phase = IndexingPhase.presets.first(where: { $0.name == preset }) else { return }
                    session.addPhase(phase)
                    edited = session.phases.last?.name
                }
                .help("Add the preset picked above to the phases")
                .accessibilityIdentifier("indexing.addPreset")
                Button("Add from CIF…") { importing = true }
                    .help("Add the structure of a CIF; it needs the space group number")
                    .accessibilityIdentifier("indexing.addCIF")
            }
            if !session.skippedPhases.isEmpty {
                InspectorNote("The file's \(session.skippedPhases.joined(separator: ", ")) states no space group or lattice, so it is left out.")
            } else if count == 0 {
                InspectorNote("Add a phase to index against: a preset or a CIF.")
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [UTType(filenameExtension: "cif") ?? .plainText, .plainText]) { result in
            switch result {
            case .success(let url):
                Task {
                    do {
                        let loaded = try await DiffractionCIF.load(url)
                        let name = loaded.displayName.isEmpty ? url.deletingPathExtension().lastPathComponent : loaded.displayName
                        session.addPhase(try IndexingPhase.fromCIF(loaded.structure, name: name))
                        edited = session.phases.last?.name
                    } catch {
                        appState.present(error)
                    }
                }
            case .failure(let error):
                appState.present(error)
            }
        }
    }
}

/// One phase in the list: its colour, its name, its space group and reflector list, where it came from, and the switch that indexes it.
private struct IndexingPhaseRow: View {
    let phase: IndexingPhase
    @Binding var isOn: Bool

    private var detail: String {
        let group = phase.pointGroupName.map { "\($0) · " } ?? ""
        return "\(group)space group \(phase.spaceGroup) · \(phase.reflectors.title) · \(phase.source.title)"
    }

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color(red: phase.colorRGB.x, green: phase.colorRGB.y, blue: phase.colorRGB.z))
                .frame(width: LayoutPolicy.regionSwatchSize, height: LayoutPolicy.regionSwatchSize)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(phase.name).lineLimit(1)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).help(detail)
            }
            Spacer(minLength: 4)
            Toggle("Index against \(phase.name)", isOn: $isOn)
                .toggleStyle(.switch).labelsHidden()
                .help(phase.refusal ?? "Index against \(phase.name)")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("indexing.phase.\(phase.name)")
    }
}

// MARK: - Method

/// How Index indexes (design §4, D-SEM-91): Hough or Dictionary, full width; the caption under it says what Dictionary needs while no
/// master pattern is open. Picking a method shows its section below; the result on screen stays its own method's.
private struct IndexingMethodSection: View {
    let session: IndexingSession

    var body: some View {
        InspectorSection("Method", status: session.isStale ? "stale" : nil) {
            SegmentedPicker(label: "Method", items: IndexingMethod.allCases.map { method in
                (method, .title(method.title, help: method == .hough
                    ? "pyEBSDindex's Hough indexing: Radon band detection, triplet voting, QUEST"
                    : "kikuchipy's dictionary indexing: every pattern against simulated patterns of a master pattern"))
            }, selection: Binding(get: { session.method }, set: { session.setMethod($0) }))
                .accessibilityIdentifier("indexing.method")
            if session.currentMaster == nil {
                InspectorNote(session.isLoadingMaster ? "Reading the master pattern" : "Dictionary needs a master pattern")
                    .accessibilityIdentifier("indexing.method.caption")
            }
        }
    }
}

// MARK: - Dictionary

/// kikuchipy's dictionary indexing (design §4, D-SEM-91): the master pattern the dictionary is projected from (the shipped Ni 20 kV one
/// open from the start; others opened here), orix's sampling resolution with the dictionary's size, the metric, the matches kept, the
/// signal mask, and how the run cuts the work (memory, not a setting).
private struct IndexingDictionarySection: View {
    @Environment(AppState.self) private var appState
    let session: IndexingSession
    @State private var importing = false

    private static let whole = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(0))
    private static let decimal = FloatingPointFormatStyle<Double>.number.precision(.significantDigits(1...3))

    private var settings: DictionaryIndexingSettings { session.dictionarySettings }
    private var defaults: DictionaryIndexingSettings { .roomDefault }

    private var sizeRow: String {
        let resolution = settings.resolution.formatted(Self.decimal)
        guard let size = session.dictionarySize else {
            return session.phasesOn.count == 1 && settings.refusal == nil ? "Counting at \(resolution)°" : "–"
        }
        return "\(size.formatted()) patterns at \(resolution)°"
    }

    private var chunkRow: String {
        guard let cut = session.dictionaryChunking, cut.size > 0 else { return "–" }
        let chunks = "\(cut.size.formatted()) patterns · \(cut.chunks) chunk\(cut.chunks == 1 ? "" : "s")"
        return cut.blocks > 1 ? chunks + " per block · \(cut.blocks) blocks" : chunks
    }

    var body: some View {
        InspectorSection("Dictionary", status: settings == defaults ? nil : "edited") {
            if session.masterPatterns.isEmpty {
                InspectorValueRow("Master", session.isLoadingMaster ? "Reading…" : "None open")
                    .accessibilityIdentifier("indexing.dictionary.master")
            } else {
                InspectorRow("Master") {
                    Picker("Master pattern", selection: Binding(get: { session.masterID ?? "" }, set: { session.selectMasterPattern($0) })) {
                        ForEach(session.masterPatterns) { Text($0.fileName).tag($0.id) }
                    }
                    .labelsHidden()
                    .help("The master pattern the dictionary is simulated from; its phase must be the phase on")
                    .accessibilityIdentifier("indexing.dictionary.master")
                }
            }
            if let master = session.currentMaster {
                InspectorValueRow("Pattern", master.summary)
                    .help("The master pattern's phase, energies, projection and side, as EMsoft wrote it")
                    .accessibilityIdentifier("indexing.dictionary.summary")
                    .accessibilityValue(master.summary)
            }
            InspectorActionRow {
                Button("Open Master Pattern…") { importing = true }
                    .help("Open an EMsoft EBSD or TKD master pattern (.h5), as kikuchipy loads it: Lambert, both hemispheres")
                    .accessibilityIdentifier("indexing.dictionary.open")
            }
            InspectorRow("Resolution") {
                OptionalNumericField(title: "Angular resolution", value: settings.resolution, format: Self.decimal, unit: "°",
                                     prompt: "\(Int(defaults.resolution))") { v in
                    session.editDictionarySettings { $0.resolution = v }
                }
                .help("orix's cubochoric sampling of the phase's fundamental zone: the mean angle between neighbouring orientations, 1° to 15°")
                .accessibilityIdentifier("indexing.dictionary.resolution")
            }
            InspectorValueRow("Dictionary", sizeRow)
                .help("The orientations sampled, one simulated pattern each")
                .accessibilityIdentifier("indexing.dictionary.size")
                .accessibilityValue(sizeRow)
            SegmentedPicker(label: "Metric", items: DictionaryIndexing.Metric.allCases.map { metric in
                (metric, .title(metric.title, help: metric.help))
            }, selection: Binding(get: { settings.metric }, set: { metric in session.editDictionarySettings { $0.metric = metric } }))
                .accessibilityIdentifier("indexing.dictionary.metric")
            InspectorRow("Keep") {
                OptionalNumericField(title: "Matches kept", value: Double(settings.keep), format: Self.whole, prompt: "\(defaults.keep)") { v in
                    session.editDictionarySettings { $0.keep = WholeNumberEntry.value(v) }
                }
                .help("The best matches kept per pattern, best first (keep_n); the map shows the best")
                .accessibilityIdentifier("indexing.dictionary.keep")
            }
            SegmentedPicker(label: "Signal mask", items: DictionaryIndexingSettings.SignalMask.allCases.map { mask in
                (mask, .title(mask.title, help: mask == .none ? "Every pixel of the pattern is compared"
                    : "Only the pixels inside the pattern's inscribed circle are compared (kikuchipy's circular window)"))
            }, selection: Binding(get: { settings.signalMask }, set: { mask in session.editDictionarySettings { $0.signalMask = mask } }))
                .accessibilityIdentifier("indexing.dictionary.mask")
            InspectorValueRow("Chunk", chunkRow)
                .help("The dictionary patterns simulated and compared at once, as the memory budget holds them; the scan is read in blocks of rows")
                .accessibilityIdentifier("indexing.dictionary.chunk")
            InspectorActionRow {
                Button("Reset Dictionary") { session.resetDictionarySettings() }
                    .disabled(settings == defaults)
                    .help(settings == defaults ? "The settings are figure F9's: 4°, NCC, keep 5, no mask" : "Back to figure F9's settings: 4°, NCC, keep 5, no mask")
                    .accessibilityIdentifier("indexing.dictionary.reset")
            }
            if let why = session.dictionaryRefusal {
                InspectorWarning(why)
                    .accessibilityIdentifier("indexing.dictionary.refusal")
            } else {
                InspectorNote("kikuchipy's dictionary indexing: the patterns compared in double precision on the CPU, or in single precision on the GPU when the work pays.")
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [UTType(filenameExtension: "h5") ?? .data, UTType(filenameExtension: "hdf5") ?? .data]) { result in
            switch result {
            case .success(let url): session.openMasterPattern(url: url)
            case .failure(let error): appState.present(error)
            }
        }
    }
}

// MARK: - Hough

/// pyEBSDindex's `EBSDIndexer` parameters (design §4), kikuchipy's tutorial values by default (D-SEM-83).
private struct IndexingHoughSection: View {
    let session: IndexingSession

    private static let whole = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(0))
    private static let decimal = FloatingPointFormatStyle<Double>.number.precision(.significantDigits(1...4))

    private var settings: HoughIndexingSettings { session.settings }
    private var defaults: HoughIndexingSettings { .roomDefault }

    var body: some View {
        InspectorSection("Hough", status: settings == defaults ? nil : "edited") {
            InspectorRow("Bands") {
                OptionalNumericField(title: "Bands", value: Double(settings.bands), format: Self.whole, prompt: "\(defaults.bands)") { v in
                    session.editSettings { $0.bands = WholeNumberEntry.value(v) }
                }
                .help("The number of bands detected in each pattern (nBands)")
                .accessibilityIdentifier("indexing.hough.bands")
            }
            InspectorRow("ρ mask") {
                OptionalNumericField(title: "Rho mask", value: settings.rhoMaskFraction * 100, format: Self.decimal, unit: "%",
                                     prompt: "\(Int(defaults.rhoMaskFraction * 100))") { v in
                    session.editSettings { $0.rhoMaskFraction = v / 100 }
                }
                .help("The fraction of the Radon transform's ρ range at each edge where no band is taken (rhoMaskFrac)")
                .accessibilityIdentifier("indexing.hough.rhoMask")
            }
            InspectorRow("ρ bins") {
                OptionalNumericField(title: "Rho bins", value: Double(settings.rhoBins), format: Self.whole, prompt: "\(defaults.rhoBins)") { v in
                    session.editSettings { $0.rhoBins = WholeNumberEntry.value(v) }
                }
                .help("The Radon transform's bins across the pattern's distance from its centre (nRho)")
                .accessibilityIdentifier("indexing.hough.rhoBins")
            }
            InspectorRow("θ bins") {
                OptionalNumericField(title: "Theta bins", value: Double(settings.thetaBins), format: Self.whole, prompt: "\(defaults.thetaBins)") { v in
                    session.editSettings { $0.thetaBins = WholeNumberEntry.value(v) }
                }
                .help("The Radon transform's bins over 180° of band angle (nTheta)")
                .accessibilityIdentifier("indexing.hough.thetaBins")
            }
            InspectorRow("ρ width") {
                OptionalNumericField(title: "Rho sigma", value: settings.rhoSigma, format: Self.decimal, unit: "bins", prompt: "\(Int(defaults.rhoSigma))") { v in
                    session.editSettings { $0.rhoSigma = v }
                }
                .help("The band-shaped kernel's width across ρ, in Radon bins (rSigma)")
                .accessibilityIdentifier("indexing.hough.rhoSigma")
            }
            InspectorRow("θ width") {
                OptionalNumericField(title: "Theta sigma", value: settings.thetaSigma, format: Self.decimal, unit: "bins", prompt: "\(Int(defaults.thetaSigma))") { v in
                    session.editSettings { $0.thetaSigma = v }
                }
                .help("The band-shaped kernel's width along θ, in Radon bins (tSigma)")
                .accessibilityIdentifier("indexing.hough.thetaSigma")
            }
            InspectorRow("Tolerance") {
                OptionalNumericField(title: "Vote tolerance", value: settings.angleTolerance, format: Self.decimal, unit: "°", prompt: "\(Int(defaults.angleTolerance))") { v in
                    session.editSettings { $0.angleTolerance = v }
                }
                .help("How far an interband angle may be from a reflector pair's to vote for it (angTol)")
                .accessibilityIdentifier("indexing.hough.tolerance")
            }
            InspectorRow("Early exit") {
                OptionalNumericField(title: "Early exit", value: Double(settings.earlyExitBands), format: Self.whole, unit: "bands",
                                     prompt: "\(defaults.earlyExitBands)") { v in
                    session.editSettings { $0.earlyExitBands = WholeNumberEntry.value(v) }
                }
                .help("A pattern stops voting once this many bands agree on one orientation (nband_earlyexit)")
                .accessibilityIdentifier("indexing.hough.earlyExit")
            }
            InspectorActionRow {
                Button("Reset Hough") { session.resetSettings() }
                    .disabled(settings == defaults)
                    .help(settings == defaults ? "The settings are kikuchipy's tutorial values" : "Back to kikuchipy's tutorial values")
                    .accessibilityIdentifier("indexing.hough.reset")
            }
            if let why = settings.refusal {
                InspectorWarning(why)
                    .accessibilityIdentifier("indexing.hough.refusal")
            } else {
                InspectorNote("pyEBSDindex's Hough indexing on the CPU in double precision: Radon band detection, triplet voting, QUEST.")
            }
        }
    }
}

// MARK: - Export

/// Export (closed until opened, as the image rooms'): the map on screen, the results, the method.
private struct IndexingExportSection: View {
    @Environment(AppState.self) private var appState
    let session: IndexingSession
    let state: IndexingRoomState

    private var reason: String? { (session.result?.reachedCount ?? 0) > 0 ? nil : "Index first" }
    private var isDictionary: Bool { session.result?.method == .dictionary }

    var body: some View {
        InspectorSection("Export", startsExpanded: false) {
            InspectorActionRow {
                Button(IndexingExportKind.mapPNG.title) { export(.mapPNG) }
                    .disabled(reason != nil)
                    .help(reason ?? "The map on screen (its layer) as a PNG, one pixel per scan point")
                    .accessibilityIdentifier("indexing.export.map")
                Button(IndexingExportKind.resultsCSV.title) { export(.resultsCSV) }
                    .disabled(reason != nil)
                    .help(reason ?? (isDictionary ? "One row per point reached: position, phase, Euler angles, the best score and its simulation index"
                                     : "One row per point reached: position, phase, Euler angles, CI, fit, matched bands, pattern quality"))
                    .accessibilityIdentifier("indexing.export.csv")
            }
            InspectorActionRow {
                Button(IndexingExportKind.ang.title) { export(.ang) }
                    .disabled(reason != nil)
                    .help(reason ?? (isDictionary ? "The orientations as an EDAX .ang: Euler angles, CI from the best score (the rows reached)"
                                     : "The orientations as an EDAX .ang: Euler angles, IQ from the pattern quality, CI, fit (the rows reached)"))
                    .accessibilityIdentifier("indexing.export.ang")
                Button(IndexingExportKind.ctf.title) { export(.ctf) }
                    .disabled(reason != nil)
                    .help(reason ?? (isDictionary ? "The orientations as an Oxford .ctf: Euler angles and phase (the rows reached)"
                                     : "The orientations as an Oxford .ctf: Euler angles, matched bands, MAD from the fit (the rows reached)"))
                    .accessibilityIdentifier("indexing.export.ctf")
            }
            InspectorActionRow {
                Button(IndexingExportKind.methodJSON.title) { export(.methodJSON) }
                    .disabled(reason != nil)
                    .help(reason ?? (isDictionary ? "Every input of the run in kikuchipy's and orix's names, to redo it in Python"
                                     : "Every input of the run in pyEBSDindex's and kikuchipy's names, to redo it in Python"))
                    .accessibilityIdentifier("indexing.export.method")
            }
        }
    }

    private func export(_ kind: IndexingExportKind) {
        state.export(kind, from: session, directory: appState.exportDirectory, report: { appState.statusText = $0 })
    }
}

// MARK: - Info

struct IndexingRoomInfo: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let session = appState.indexing
        if let document = session.patterns.document {
            InspectorSection("Dataset") {
                ForEach(EBSDBrowsing.infoRows(document.dataset, fileName: document.fileName)) { row in
                    InspectorValueRow(row.label, row.value)
                }
            }
            InspectorSection("Indexing") {
                let method = session.result?.method ?? session.method
                InspectorValueRow("Method", method == .hough ? "Hough (pyEBSDindex 0.3.10.1)" : "Dictionary (kikuchipy 0.13.1)")
                    .accessibilityIdentifier("indexing.info.method")
                if let result = session.result {
                    InspectorValueRow("Phases", result.phases.map(\.name).joined(separator: ", "))
                    InspectorValueRow("Indexed", "\(result.indexedCount.formatted()) of \(result.pointCount.formatted())")
                        .accessibilityIdentifier("indexing.info.indexed")
                    let counts = result.countsByPhase
                    ForEach(result.phases.indices, id: \.self) { i in
                        InspectorValueRow(result.phases[i].name, "\((counts.indices.contains(i) ? counts[i] : 0).formatted()) points")
                    }
                    if let source = session.resultSource { InspectorValueRow("Patterns", source.title) }
                    if let pc = session.resultProjectionCenter {
                        InspectorValueRow("PC", "(\(UnitDisplay.number(pc.x, digits: 4)), \(UnitDisplay.number(pc.y, digits: 4)), \(UnitDisplay.number(pc.z, digits: 4))) · mean of the file's")
                    }
                    if result.method == .dictionary, let plan = session.dictionaryPlan {
                        InspectorValueRow("Master", "\(plan.master.fileName) · \(plan.master.summary)")
                        InspectorValueRow("Energy", plan.energyWords)
                        InspectorValueRow("Dictionary", "\(plan.rotations.count.formatted()) patterns at \(UnitDisplay.number(plan.settings.resolution))° · \(plan.settings.metric.title) · keep \(min(plan.settings.keep, plan.rotations.count))")
                            .accessibilityIdentifier("indexing.info.dictionary")
                    }
                    InspectorValueRow("State", state(result))
                    if let seconds = session.lastRunSeconds { InspectorValueRow("Time", "\(UnitDisplay.number(seconds, digits: 3)) s") }
                } else {
                    InspectorValueRow("State", "Not indexed")
                }
                if method == .hough {
                    InspectorNote("Krieger Lassen 1994 (Radon), Wright and Adams 1992 (triplet voting), Shuster and Oh 1981 (QUEST), Rowenhorst et al. 2024 (pyEBSDindex 0.3.10.1, as kikuchipy 0.13.1 drives it); orientations and colours as orix 0.15.0.")
                } else {
                    InspectorNote("Chen et al. 2015 and Jackson et al. 2019 (dictionary indexing), Callahan and De Graef 2013 (EMsoft's master patterns), Roşca, Morawiec and De Graef 2014 and Singh and De Graef 2016 (cubochoric sampling), Marquardt et al. 2017 (the orientation similarity map); as kikuchipy 0.13.1 and orix 0.15.0 do it.")
                }
            }
        } else {
            ContentUnavailableView("No EBSD dataset open", systemImage: "scope",
                                   description: Text("The file and the indexing run appear here."))
        }
    }

    private func state(_ result: IndexingResult) -> String {
        let session = appState.indexing
        if session.isIndexing, result.method == .dictionary {
            return "Indexing, chunk \(session.chunksDone) of \(session.chunksTotal) · row \(result.rowsDone) of \(result.scanRows)"
        }
        if appState.indexing.isIndexing { return "Indexing, row \(result.rowsDone) of \(result.scanRows)" }
        if appState.indexing.wasStopped { return "Stopped at row \(result.rowsDone) of \(result.scanRows)" }
        return appState.indexing.isStale ? "Stale: the patterns, phases or settings changed" : "Current"
    }
}

/// The whole-number fields (Keep, Bands, ρ bins, θ bins, Early exit).
nonisolated private enum WholeNumberEntry {
    /// A typed number rounded and held within ±10⁹, so that a huge or non-finite entry reaches the setting's refusal instead of
    /// trapping in the conversion to `Int`.
    static func value(_ v: Double) -> Int {
        v.isFinite ? Int(min(max(v.rounded(), -1e9), 1e9)) : 0
    }
}
