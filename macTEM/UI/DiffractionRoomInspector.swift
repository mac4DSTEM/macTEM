//
//  DiffractionRoomInspector.swift
//  Role: the Diffraction room's Settings (design section 3): Centre, Calibration, Display, Tools, Crystal, Rings, Export (control placement §2:
//        what I am looking at, then the job; Centre stays above Calibration, which it feeds). Presentation only;
//        the state is `DiffractionAnalysis` and every number DiffractoKit's. Every field commits on Return or blur
//        (`OptionalNumericField`), every control has an accessibility identifier for the journey.
//

import ShellControls
import ShellInspector
import SwiftUI
import UniformTypeIdentifiers
import TEMCore
import TEMSession
import DiffractoCore
import DiffractoGeometry

struct DiffractionRoomSettings: View {
    let image: CalibratedImage
    let item: OpenItem

    var body: some View {
        let analysis = item.diffraction
        let view = item.diffractionView
        Group {
            DiffractionCentreSection(analysis: analysis, view: view)
            DiffractionCalibrationSection(image: image, analysis: analysis, view: view)
            DiffractionDisplaySection(view: view)
            DiffractionToolsSection(view: view)
            DiffractionCrystalSection(analysis: analysis)
            DiffractionRingsSection(image: image, analysis: analysis, view: view)
            DiffractionExportSection(image: image, analysis: analysis)
        }
        .onAppear { analysis.bind(image) }
    }
}

private let pixelFormat = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(0...2))
private let qFormat = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(0...6))

private struct DiffractionCentreSection: View {
    let analysis: DiffractionAnalysis
    let view: DiffractionViewState

    private static func sourceNote(_ source: DiffractionCentre.Source) -> String {
        switch source {
        case .fileCentre: "The image centre; a ring fit can refine it."
        case .typed: "Typed."
        case .ring: "Taken from a fitted ring."
        }
    }

    var body: some View {
        InspectorSection("Centre") {
            if let centre = analysis.centre {
                InspectorRow("Row") {
                    OptionalNumericField(title: "Centre row", value: centre.row, format: pixelFormat, unit: "px") { analysis.setCentre(row: $0, column: centre.column) }
                }
                InspectorRow("Column") {
                    OptionalNumericField(title: "Centre column", value: centre.column, format: pixelFormat, unit: "px") { analysis.setCentre(row: centre.row, column: $0) }
                }
                InspectorNote(Self.sourceNote(centre.source))
                InspectorActionRow {
                    Button("Use Ring's Centre") { if let id = view.selection { analysis.useCentre(ofRing: id) } }
                        .disabled(!(analysis.rings.first { $0.id == view.selection }?.fit?.fit != nil))
                        .help("Take the selected ring's fitted centre as the pattern's")
                        .accessibilityIdentifier("diffraction.centre.useRing")
                }
            }
        }
    }
}

private struct DiffractionCalibrationSection: View {
    let image: CalibratedImage
    let analysis: DiffractionAnalysis
    let view: DiffractionViewState

    var body: some View {
        let calibration = analysis.calibration(for: image)
        let families = analysis.standardFamilies()
        InspectorSection("Calibration") {
            InspectorValueRow("Scale", calibration.map { "\($0.sourceText) · \(Num.fixed($0.deltaQ, 5)) Å⁻¹/px" } ?? "none")
            if let fit = analysis.fitVersusFilePercent(for: image) {
                InspectorNote("The fit's Δq is \(Num.signed(fit, 2)) % from the file's axis.")
            }
            InspectorRow("Standard") {
                Picker("Standard", selection: Binding(get: { analysis.standard.name }, set: { name in if let s = StandardCrystals.named(name) { analysis.setStandard(s) } })) {
                    ForEach(StandardCrystals.all, id: \.name) { Text($0.name).tag($0.name) }
                }
                .labelsHidden().fixedSize().accessibilityIdentifier("diffraction.standard")
            }
            InspectorRow("Ring") {
                Picker("Family", selection: Binding(get: { analysis.familyIndex }, set: { analysis.familyIndex = $0 })) {
                    ForEach(families.indices, id: \.self) { Text("\(families[$0].name) · \(Num.fixed(families[$0].d, 3)) Å").tag($0) }
                }
                .labelsHidden().fixedSize().accessibilityIdentifier("diffraction.family")
            }
            InspectorActionRow {
                Button("Calibrate on Ring") {
                    PendingEdits.run { if families.indices.contains(analysis.familyIndex) { analysis.fitRing(image: image, inner: view.annulusInner, outer: view.annulusOuter, calibrateOn: families[analysis.familyIndex].family) } }
                }
                .disabled(analysis.isFitting || families.isEmpty)
                .help("Fit the ring in the annulus and take Δq from its radius and the family's listed spacing")
                .accessibilityIdentifier("diffraction.calibrate")
                if analysis.ringCalibrationExists { Button("Clear") { analysis.clearCalibration() }.accessibilityIdentifier("diffraction.calibration.clear") }
            }
            if let ring = calibration?.ring {
                if let l = ring.lengthPixels { InspectorValueRow("L", "\(Num.fixed(l, 0)) px") }
                if let mm = ring.lengthMillimetres { InspectorValueRow("L", "\(Num.fixed(mm, 1)) mm") }
                else if ring.lengthPixels != nil { InspectorNote("L in mm needs the camera's pixel pitch.") }
            }
            if analysis.fileDeltaQ(image) == nil {
                InspectorRow("Δq typed") {
                    OptionalNumericField(title: "Typed delta q", value: analysis.typedDeltaQ, format: qFormat, unit: "Å⁻¹/px") { analysis.typedDeltaQ = $0 }
                }
            }
            InspectorRow("Beam") {
                if let v = image.voltage { Text("\(Num.sig(v / 1000, 4)) kV (file)").foregroundStyle(.secondary) }
                else { OptionalNumericField(title: "Beam energy", value: analysis.typedBeamKV, format: pixelFormat, unit: "kV") { analysis.typedBeamKV = $0 } }
            }
            InspectorRow("Camera") {
                Picker("Camera", selection: Binding(get: { analysis.pitchMM.flatMap { p in CameraPitches.all.first { $0.pitchMM == p }?.name } ?? "" },
                                                    set: { name in analysis.pitchMM = CameraPitches.all.first { $0.name == name }?.pitchMM })) {
                    Text("Pitch not stated").tag("")
                    ForEach(CameraPitches.all, id: \.name) { Text($0.name).tag($0.name) }
                }
                .labelsHidden().fixedSize().accessibilityIdentifier("diffraction.camera")
            }
            InspectorRow("Pixel pitch") {
                OptionalNumericField(title: "Pixel pitch", value: analysis.pitchMM, format: FloatingPointFormatStyle<Double>.number.precision(.fractionLength(0...4)), unit: "mm") { analysis.pitchMM = $0 }
            }
            if let why = analysis.failure { InspectorWarning(why) }
        }
    }
}

private struct DiffractionCrystalSection: View {
    let analysis: DiffractionAnalysis
    @State private var importing = false
    @Environment(AppState.self) private var appState

    var body: some View {
        InspectorSection("Crystal") {
            InspectorRow("Crystal") {
                Picker("Crystal", selection: Binding(get: { analysis.crystal.sha256 == nil ? analysis.crystal.name : "cif" },
                                                     set: { name in if let s = StandardCrystals.named(name) { analysis.setCrystal(.preset(s)) } })) {
                    ForEach(StandardCrystals.all, id: \.name) { Text($0.name).tag($0.name) }
                    if analysis.crystal.sha256 != nil { Text(analysis.crystal.name).tag("cif") }
                }
                .labelsHidden().fixedSize().accessibilityIdentifier("diffraction.crystal")
            }
            InspectorActionRow {
                Button("Open CIF…") { importing = true }.accessibilityIdentifier("diffraction.cif")
            }
            if let why = analysis.crystalFailure { InspectorWarning(why) }
            InspectorRow("k_max") {
                OptionalNumericField(title: "k max", value: analysis.kMax, format: pixelFormat, unit: "Å⁻¹") { analysis.setKMax($0) }
            }
            InspectorRow("Tolerance") {
                OptionalNumericField(title: "Indexing tolerance", value: analysis.tolerancePercent, format: pixelFormat, unit: "% of q") { analysis.setTolerance(percent: $0) }
            }
            InspectorNote("validation: none · the indexing rule is the kit's own; chance acceptance is unmeasured.")
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [UTType(filenameExtension: "cif") ?? .plainText, .plainText]) { result in
            switch result {
            case .success(let url):
                Task {
                    do { analysis.setCrystal(.cif(try await DiffractionCIF.load(url))) }
                    catch { analysis.crystalRefused(error.localizedDescription) }
                }
            case .failure(let error): analysis.crystalRefused(error.localizedDescription)
            }
        }
    }
}

private struct DiffractionRingsSection: View {
    let image: CalibratedImage
    let analysis: DiffractionAnalysis
    let view: DiffractionViewState

    var body: some View {
        InspectorSection("Rings and Spots") {
            InspectorNote("Ring tool: drag from the inner to the outer edge of a ring. Spot tool: click a spot.")
            InspectorRow("Inner") {
                OptionalNumericField(title: "Inner radius", value: view.annulusInner, format: pixelFormat, unit: "px") { view.setAnnulus(inner: $0, outer: view.annulusOuter) }
            }
            InspectorRow("Outer") {
                OptionalNumericField(title: "Outer radius", value: view.annulusOuter, format: pixelFormat, unit: "px") { view.setAnnulus(inner: view.annulusInner, outer: $0) }
            }
            InspectorActionRow {
                Button("Fit Ring") { PendingEdits.run { analysis.fitRing(image: image, inner: view.annulusInner, outer: view.annulusOuter) } }
                    .disabled(analysis.isFitting).accessibilityIdentifier("diffraction.fitRing")
                Button("Remove") { if let id = view.selection { analysis.remove(id); view.selection = nil } }.disabled(view.selection == nil).accessibilityIdentifier("diffraction.remove")
            }
            InspectorActionRow {
                Button("Remove All") { analysis.removeAll() }.disabled(analysis.rings.isEmpty && analysis.spots.isEmpty)
            }
        }
    }
}

/// Ring or Spot: what a click on the pattern does. A full-width segmented control in its own section, no leading label.
private struct DiffractionToolsSection: View {
    let view: DiffractionViewState

    var body: some View {
        InspectorSection("Tools") {
            SegmentedPicker(label: "Tool",
                            items: [(DiffractionViewState.Tool.ring, .title("Ring")), (.spot, .title("Spot"))],
                            selection: Binding(get: { view.tool }, set: { view.tool = $0 }))
                .accessibilityIdentifier("diffraction.tool")
        }
    }
}

/// The image rooms' one Display section (control placement §5) for the pattern: colormap, the histogram of the drawn values with its
/// window, gamma, and the log switch. The zoom is the pane's own (the wheel, a pinch, a double-click), not buttons here (§6).
private struct DiffractionDisplaySection: View {
    let view: DiffractionViewState

    var body: some View {
        ImageRoomDisplaySection(presentation: view.presentation, colormapID: "diffraction.colormap", logID: "diffraction.log",
                                log: Binding(get: { view.useLog }, set: { view.useLog = $0 }))
    }
}

private struct DiffractionExportSection: View {
    let image: CalibratedImage
    let analysis: DiffractionAnalysis
    @Environment(AppState.self) private var appState
    @State private var exporting = false
    @State private var document = CSVTextDocument(text: "")

    var body: some View {
        InspectorSection("Export") {
            InspectorActionRow {
                Button("Export Readout CSV…") { export() }
                    .disabled(analysis.rings.isEmpty && analysis.spots.isEmpty)
                    .accessibilityIdentifier("diffraction.export")
            }
        }
        .fileExporter(isPresented: $exporting, document: document, contentType: .commaSeparatedText,
                      defaultFilename: ((image.fileName as NSString).deletingPathExtension) + " diffraction") { result in
            if case .failure(let error) = result { appState.present(error) }
        }
    }

    private func export() {
        let text = analysis.exportText(image: image)
        if let directory = appState.exportDirectory {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent(((image.fileName as NSString).deletingPathExtension) + " diffraction.csv")
            do { try Data(text.utf8).write(to: url); appState.statusText = "Exported \(url.lastPathComponent)" } catch { appState.present(error) }
        } else {
            document = CSVTextDocument(text: text)
            exporting = true
        }
    }
}

/// A CSV as a document for `fileExporter`.
struct CSVTextDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.commaSeparatedText]
    var text: String
    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws { text = String(decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self) }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: Data(text.utf8)) }
}

/// Opens a CIF off the main actor inside the file's security scope (the kit's refusals in its words, its 5 MB cap).
enum DiffractionCIF {
    @concurrent
    nonisolated static func load(_ url: URL) async throws -> LoadedCrystal {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        return try CrystalLoading.load(bytes: data, fileName: url.lastPathComponent)
    }
}
