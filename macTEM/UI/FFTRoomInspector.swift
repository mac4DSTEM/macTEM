//
//  FFTRoomInspector.swift
//  Role: the FFT room's inspector content (archive: roadmap-registrations-2026-10-15.md V1-6 + 6a + 6b; the design and its cost in
//        archive: fft-room-design-2026-10-13.md, "The inspector, and its cost"). Settings, in the order of
//        `FFTRoomSections.order`: Calibration (the Image room's section, reused), Display,
//        Region, Spots, Radial Profile, Masked Inverse (once a spot is measured), HRTEM Filters (collapsed until opened),
//        then Export (plain buttons, last). Info: the Fourier Transform section. Presentation only: the
//        state is `FFTAnalysis` (TEMSession; `OpenItem.fft`), every number TEMCore's, every string a pure function of
//        `FFTRoomFormat` (pinned by FFTRoomFormatTests). `FFTRoom.swift` forwards `FFTRoomSettings` and
//        `FFTRoomInfoSection` here.
//
//  DESIGNED WITH the swiftui-macos skill (consulted before the code), and where a reference shaped a choice:
//   - observation.md, "State Capture at Body Level" and "Observation Scope Narrowing": each section is its own View, reads
//     each observed property of `analysis` once in its body, and hands VALUES to its rows (a row that read the selection
//     itself would register one identical dependency per spot); a spot row takes values and the owner, no closures, so a row
//     whose spot did not change is not evaluated again ("ForEach Body Extraction").
//   - performance.md, "@State for Animated and Gestured Values": the pointer's |q| on the radial chart changes at the pointer's
//     rate, so it is `@State` in the chart, never on the owner, and the chart's bins are made in the section's body, which a
//     hover does not re-run.
//   - data.md, "Bindings" asks for `$model.property` over `Binding(get:set:)`. The owner here exposes INTENTS (`setRegion`,
//     `setMask`, `setFilterParameters`, `setInMask`: they refuse, clamp or restart work) and `private(set)` properties, so a
//     field cannot bind to the property; each binding is a small private function that reads and calls the intent, never one
//     built inline in a body. `spectrumWindowLow/High` and `selection` are settable and are written directly.
//   - accessibility.md: an icon-only Remove has a text label; the lists and fields carry every value (the canvases are
//     hidden); the spot list is focusable and answers ⌫, ⌘C and ↑↓ as the Image room's marks do; the neighbour glyph has a
//     label of its own, not colour alone.
//   - views.md, "Design Patterns": `Label` over an Image and a Text, hierarchical styles, `.task`-free (no async work here).
//  The kit is `InspectorRows.swift` (sections, rows, notes, the warning, the action row, the entry fields); a collapsed
//  section is the kit's `expanded:` binding over this file's own `@SceneStorage`, default false.
//

import ShellControls
import ShellInspector
import ShellLayout
import SwiftUI
import Charts
import TEMCore
import TEMSession
import ImagoCore
import ImagoFFT
import ImagoFilters

// MARK: - Settings

/// The room's Settings tab: one section after another, as `ImageRoomSettings` is.
struct FFTRoomInspectorSettings: View {
    let image: CalibratedImage
    let analysis: FFTAnalysis

    var body: some View {
        let sections = FFTRoomSections.order(hasMeasuredSpot: analysis.hasMeasuredSpot)
        // One identity per open file: a typed bin, a hovered chart bin or an open disclosure belongs to the file it was made
        // for, and the inspector is not keyed by the item.
        Group {
            ForEach(sections, id: \.self) { section in
                switch section {
                case .calibration: ImageRoomCalibrationSection(image: image)
                case .export: FFTExportSection(analysis: analysis)
                case .region: FFTRegionSection(image: image, analysis: analysis)
                case .spots: FFTSpotsSection(image: image, analysis: analysis)
                case .radialProfile: FFTRadialProfileSection(image: image, analysis: analysis)
                case .maskedInverse: FFTMaskSection(analysis: analysis)
                case .filters: FFTFiltersSection(image: image, analysis: analysis)
                case .display: FFTDisplaySection(analysis: analysis)
                }
            }
        }
        .id(ObjectIdentifier(analysis))
    }
}

// MARK: - Region

/// What is transformed, Left, Top and Size in pixels, Clear Region and Use Centred Square, Δq, and the hint.
private struct FFTRegionSection: View {
    let image: CalibratedImage
    let analysis: FFTAnalysis

    var body: some View {
        let region = analysis.region
        let spectrum = analysis.spectrum
        let failure = analysis.spectrumFailure
        let centred = FFTRegion.centredSquare(width: image.width, height: image.height)
        InspectorSection("Region") {
            InspectorValueRow("Transformed", FFTRoomFormat.transformed(region, imageWidth: image.width, imageHeight: image.height))
            // No region is possible below 32 px; the whole image has no Left, Top or Size to edit.
            if centred != nil {
                ForEach(FFTRoomFormat.RegionField.allCases, id: \.self) { field in
                    FFTRegionFieldRow(field: field, value: region.map(field.value(of:))) { typed in
                        commit(typed, into: field)
                    }
                }
            }
            InspectorActionRow {
                Button("Clear Region") { PendingEdits.run { analysis.setRegion(nil, committed: true) } }
                    .disabled(region == nil)
                    .accessibilityIdentifier("fft.region.clear")
                Button("Use Centred Square") { PendingEdits.run { analysis.setRegion(centred, committed: true) } }
                    .disabled(centred == nil || centred == region)
                    .accessibilityIdentifier("fft.region.centredSquare")
            }
            if let spectrum {
                frequencyRows(of: spectrum)
            }
            FFTPreprocessRows(analysis: analysis)
            if let failure {
                InspectorWarning(failure)
            }
            InspectorNote(centred == nil ? FFTRoomFormat.noRegionPossible : FFTRoomFormat.regionHint)
        }
    }

    /// Δq of the transform shown: one row when both axes agree, else one per axis.
    @ViewBuilder
    private func frequencyRows(of spectrum: FFTSpectrumProduct) -> some View {
        let steps = FFTRoomFormat.frequencySteps(spacingX: spectrum.spacingX, unitsX: spectrum.unitsX,
                                                 spacingY: spectrum.spacingY, unitsY: spectrum.unitsY)
        if steps.x == steps.y {
            FFTValueRow("Δq", steps.x)
                .help("The frequency step between neighbouring bins of the transform shown")
        } else {
            FFTValueRow("Δq (x)", steps.x)
            FFTValueRow("Δq (y)", steps.y)
        }
    }

    /// A typed number replaces one of the region's three, through the registered clamps; the owner is written once, committed.
    private func commit(_ typed: Int, into field: FFTRoomFormat.RegionField) {
        guard let current = analysis.region,
              let crop = FFTRoomFormat.region(typing: typed, into: field, current: current,
                                              width: image.width, height: image.height),
              crop != current else { return }
        analysis.setRegion(crop, committed: true)
    }
}

/// What is done to the transformed pixels before the transform: a window (it tapers the edges, which removes the streaks a hard edge
/// puts on the spectrum), Gaussian smoothing and a band-pass, ImagoKit's. Unvalidated until compared with Digital Micrograph.
private struct FFTPreprocessRows: View {
    let analysis: FFTAnalysis

    private enum SmoothingKind: Hashable { case none, gaussian }
    private enum BandKind: Hashable { case none, differenceOfGaussians, highPass, lowPass }

    var body: some View {
        let p = analysis.preprocess
        InspectorRow("Window") {
            Picker("Window", selection: Binding(get: { p.window }, set: { new in var n = p; n.window = new; analysis.setPreprocess(n) })) {
                ForEach(FFTPreprocess.Window.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden().fixedSize()
            .help("Taper the region's edges before the transform: a hard edge streaks the spectrum along both axes")
            .accessibilityIdentifier("fft.window")
        }
        InspectorRow("Smoothing") {
            Picker("Smoothing", selection: Binding(get: { smoothingKind(p) }, set: { kind in
                var n = p; n.smoothing = kind == .gaussian ? .gaussian(sigma: sigma(p)) : .none; analysis.setPreprocess(n)
            })) {
                Text("None").tag(SmoothingKind.none)
                Text("Gaussian").tag(SmoothingKind.gaussian)
            }
            .labelsHidden().fixedSize()
            .accessibilityIdentifier("fft.smoothing")
        }
        if case .gaussian(let sigma) = p.smoothing {
            InspectorRow("σ") {
                OptionalNumericField(title: "Smoothing sigma", value: sigma, format: FloatingPointFormatStyle<Double>.number.precision(.significantDigits(1...3)),
                                     unit: "px", prompt: "1") { v in
                    var n = p; n.smoothing = .gaussian(sigma: min(max(v, 0.1), 50)); analysis.setPreprocess(n)
                }
            }
        }
        InspectorRow("Band-pass") {
            Picker("Band-pass", selection: Binding(get: { bandKind(p) }, set: { kind in
                var n = p
                switch kind {
                case .none: n.bandpass = .none
                case .differenceOfGaussians: n.bandpass = .differenceOfGaussians(lowSigma: lowSigma(p))
                case .highPass: n.bandpass = .butterworth(cutoff: cutoff(p), highPass: true)
                case .lowPass: n.bandpass = .butterworth(cutoff: cutoff(p), highPass: false)
                }
                analysis.setPreprocess(n)
            })) {
                Text("None").tag(BandKind.none)
                Text("Difference of Gaussians").tag(BandKind.differenceOfGaussians)
                Text("Butterworth high-pass").tag(BandKind.highPass)
                Text("Butterworth low-pass").tag(BandKind.lowPass)
            }
            .labelsHidden().fixedSize()
            .accessibilityIdentifier("fft.bandpass")
        }
        switch p.bandpass {
        case .none: EmptyView()
        case .differenceOfGaussians(let low):
            InspectorRow("Low σ") {
                OptionalNumericField(title: "Low sigma", value: low, format: FloatingPointFormatStyle<Double>.number.precision(.significantDigits(1...3)),
                                     unit: "px", prompt: "2") { v in
                    var n = p; n.bandpass = .differenceOfGaussians(lowSigma: min(max(v, 0.1), 50)); analysis.setPreprocess(n)
                }
            }
        case .butterworth(let c, let high):
            InspectorRow("Cutoff") {
                OptionalNumericField(title: "Cutoff frequency ratio", value: c, format: FloatingPointFormatStyle<Double>.number.precision(.significantDigits(1...3)),
                                     unit: "× Nyquist", prompt: "0.1") { v in
                    var n = p; n.bandpass = .butterworth(cutoff: min(max(v, 0.001), 0.5), highPass: high); analysis.setPreprocess(n)
                }
            }
        }
        if !p.isNone {
            InspectorNote("Before the transform: \(p.summary). Unvalidated: not compared with Digital Micrograph.")
        }
    }

    private func smoothingKind(_ p: FFTPreprocess) -> SmoothingKind { if case .gaussian = p.smoothing { .gaussian } else { .none } }
    private func sigma(_ p: FFTPreprocess) -> Double { if case .gaussian(let s) = p.smoothing { s } else { 1 } }
    private func bandKind(_ p: FFTPreprocess) -> BandKind {
        switch p.bandpass {
        case .none: .none
        case .differenceOfGaussians: .differenceOfGaussians
        case .butterworth(_, let high): high ? .highPass : .lowPass
        }
    }
    private func lowSigma(_ p: FFTPreprocess) -> Double { if case .differenceOfGaussians(let s) = p.bandpass { s } else { 2 } }
    private func cutoff(_ p: FFTPreprocess) -> Double { if case .butterworth(let c, _) = p.bandpass { c } else { 0.1 } }
}

/// One of Left, Top, Size: a number field with its unit; empty and disabled while the whole image is transformed.
private struct FFTRegionFieldRow: View {
    let field: FFTRoomFormat.RegionField
    let value: Int?
    let commit: (Int) -> Void

    var body: some View {
        InspectorRow(field.title) {
            // The row shows "Left"; the field speaks "Left in pixels" (the unit spelled out is named once, not "px" by letter).
            OptionalNumericField(title: field.spokenTitle, value: value, format: IntegerFormatStyle<Int>.number.grouping(.never),
                                 unit: "px", prompt: "–", onCommit: commit)
                .accessibilityIdentifier(field.identifier)
                .disabled(value == nil)
        }
        .help(value == nil ? "No region: the whole image is transformed. Draw one, or use a centred square." : field.title)
    }
}

/// A value row whose spoken value says "per pixel" for "px⁻¹" (and "pixels" for "px"), which VoiceOver would read letter by
/// letter; a row with neither is the kit's row as it is.
private struct FFTValueRow: View {
    private let label: String
    private let value: String

    init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }

    var body: some View {
        let spoken = FFTRoomFormat.spoken(value)
        if spoken == value {
            InspectorValueRow(label, value)
        } else {
            InspectorValueRow(label, value)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(label)
                .accessibilityValue(spoken)
        }
    }
}

// MARK: - Spots

/// The spots measured on the transform: a list (number, d, |q|, a neighbour flag, In Mask, Remove), what they were measured on,
/// and Measure at… for the click's twin.
private struct FFTSpotsSection: View {
    let image: CalibratedImage
    let analysis: FFTAnalysis

    var body: some View {
        let spots = analysis.spots
        let selection = analysis.selection
        let spectrum = analysis.spectrum
        InspectorSection("Spots") {
            if spots.isEmpty {
                InspectorNote(FFTRoomFormat.noSpots)
            } else {
                FFTSpotsList(spots: spots, selection: selection, analysis: analysis)
                // What the rings on the transform mean, once (the colour is never alone: a dashed ring is not measured).
                InspectorNote("Yellow ring: a measured spot; blue: the selected one; dashed: not measured. ⚠ marks a spot with another peak close by.")
                notes(for: spots)
                InspectorActionRow {
                    Button("Remove All") { analysis.removeAllSpots() }
                }
            }
            if let spectrum {
                FFTSpotFinderRows(analysis: analysis)
                InspectorActionRow {
                    Button("Find Spots") { analysis.findSpots() }
                        .help("Put the strongest reflections of the transform on it, each measured as a click would be")
                        .accessibilityIdentifier("fft.spots.find")
                }
                if let why = analysis.findSpotsFailure { InspectorNote(why) }
                FFTMeasureAt(analysis: analysis, width: spectrum.width, height: spectrum.height)
            }
        }
    }

    /// What the numbers were measured on, the neighbour flag's consequence, and the accuracy by size — each only when it applies.
    @ViewBuilder
    private func notes(for spots: [FFTSpot]) -> some View {
        if spots.contains(where: { $0.measured != nil }), let key = spots.last?.spectrumKey {
            InspectorNote(FFTRoomFormat.measuredOn(key.crop, imageWidth: image.width, imageHeight: image.height))
            if spots.contains(where: { $0.measured?.neighbour == true }) {
                InspectorWarning(FFTRoomFormat.neighbourNote)
            }
            if let accuracy = FFTRoomFormat.accuracyNote(width: key.crop?.width ?? image.width,
                                                         height: key.crop?.height ?? image.height) {
                InspectorNote(accuracy)
            }
        }
    }
}

/// The spots, one row each. The list takes the keyboard when clicked: ⌫ removes the selected spot, ⌘C copies its line, ↑ and ↓
/// move the selection (the Image room's marks list does the same; a plain stack, not `List(selection:)`, which the inspector's
/// `ScrollView` does not allow).
private struct FFTSpotsList: View {
    let spots: [FFTSpot]
    let selection: FFTSpot.ID?
    let analysis: FFTAnalysis
    @FocusState private var hasFocus: Bool

    private static let rowSpacing: CGFloat = 2

    var body: some View {
        VStack(alignment: .leading, spacing: Self.rowSpacing) {
            let angles = FFTSpotAngles.angles(spots)
            ForEach(spots) { spot in
                FFTSpotRow(spot: spot, isSelected: spot.id == selection, angle: angles[spot.id], analysis: analysis)
            }
        }
        .focusable()
        .focused($hasFocus)
        .simultaneousGesture(TapGesture().onEnded { hasFocus = true })
        .onDeleteCommand { if let selection { analysis.removeSpot(selection) } }
        .onCopyCommand { copyProviders() }
        .onMoveCommand { move($0) }
    }

    /// The selected spot's line, as the row shows it.
    private func copyProviders() -> [NSItemProvider] {
        guard let spot = spots.first(where: { $0.id == selection }) else { return [] }
        let angle = FFTSpotAngles.angles(spots)[spot.id].map { " · " + FFTRoomFormat.angleText($0) } ?? ""
        return [NSItemProvider(object: (FFTRoomFormat.spotValue(spot) + angle) as NSString)]
    }

    /// ↑ and ↓ select the previous and the next spot; with none selected, the last and the first.
    private func move(_ direction: MoveCommandDirection) {
        guard !spots.isEmpty else { return }
        let current = spots.firstIndex { $0.id == selection }
        switch direction {
        case .up: analysis.selection = spots[current.map { max($0 - 1, 0) } ?? spots.count - 1].id
        case .down: analysis.selection = spots[current.map { min($0 + 1, spots.count - 1) } ?? 0].id
        default: break
        }
    }
}

/// One spot: its number, what it measured (or that it is measuring, or why it was refused), a flag for a close neighbour, In Mask
/// and Remove. Takes values and the owner (a reference, compared by identity), no closures.
private struct FFTSpotRow: View {
    let spot: FFTSpot
    let isSelected: Bool
    /// The angle to the reference spot (the first measured one); nil for the reference itself and for a spot with none.
    let angle: FFTSpotAngles.Angle?
    let analysis: FFTAnalysis

    /// The numbers and the glyph differ in width; fixed slots keep the columns of In Mask and Remove in line across rows.
    private static let numberWidth: CGFloat = 20
    private static let glyphWidth: CGFloat = 16

    var body: some View {
        HStack(spacing: 6) {
            Button { analysis.selection = spot.id } label: { label }
                .buttonStyle(.plain)
                .accessibilityLabel(FFTRoomFormat.spotSpoken(spot))
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            neighbourFlag
            Toggle("In Mask, spot \(spot.number)", isOn: inMask)
                .labelsHidden()
                .toggleStyle(.checkbox)
                .disabled(spot.measured == nil)
                .help(spot.measured == nil ? "Only a measured spot can be in the mask" : "Pass this spot in the masked inverse")
            Button("Remove", systemImage: "xmark") { analysis.removeSpot(spot.id) }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Remove")
                .accessibilityLabel("Remove spot \(spot.number)")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background { RoundedRectangle(cornerRadius: 6).fill(.quaternary).opacity(isSelected ? 1 : 0) }
    }

    private var label: some View {
        HStack(spacing: 8) {
            Text("\(spot.number)")
                .monospacedDigit()
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                .frame(width: Self.numberWidth, alignment: .trailing)
            outcome
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var outcome: some View {
        switch spot.outcome {
        case .measuring:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(FFTRoomFormat.spotValue(spot)).foregroundStyle(.secondary)
            }
        case .measured:
            if let parts = FFTRoomFormat.measuredParts(spot) {
                // One line when it fits, else d over |q|.
                ViewThatFits(in: .horizontal) {
                    Text(FFTRoomFormat.spotValue(spot) + (angle.map { " · " + FFTRoomFormat.angleText($0) } ?? "")).monospacedDigit().lineLimit(1)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(parts.d)
                        Text(parts.q)
                        if let angle { Text(FFTRoomFormat.angleText(angle)).foregroundStyle(.secondary) }
                    }
                    .monospacedDigit()
                }
                // The value a UI test reads: d as a number and its unit, "0.2351 nm" (never parsed from the label). One leaf element: a `ViewThatFits`
                // with an identifier alone is not resolved by XCUITest on macOS 27.
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Spot spacing")
                .accessibilityIdentifier("fft.spotSpacing")
                .accessibilityValue(spot.measured.map { String(format: "%.5g %@", $0.d, $0.units) } ?? "")
                .overlay { if let angle { Color.clear.accessibilityIdentifier("fft.spotAngle").accessibilityValue(String(format: "%.1f", angle.degrees)).accessibilityLabel("Angle to spot \(angle.reference)") } }
            }
        case .refused(let failure):
            InspectorNote(FFTRoomFormat.refusal(failure))
        }
    }

    /// A spot with another peak close by: the glyph, its help and its spoken label are the sentence.
    private var neighbourFlag: some View {
        ZStack {
            if spot.measured?.neighbour == true {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help(FFTRoomFormat.neighbourNote)
                    .accessibilityLabel(FFTRoomFormat.neighbourNote)
            }
        }
        .frame(width: Self.glyphWidth)
    }

    /// A refused or measuring spot has no centroid, so it is never in the mask.
    private var inMask: Binding<Bool> {
        Binding(get: { spot.inMask && spot.measured != nil }, set: { analysis.setInMask(spot.id, $0) })
    }
}

/// Measure at…: the click's twin, for VoiceOver and a drive — whole bins from the centre, then Measure.
private struct FFTMeasureAt: View {
    let analysis: FFTAnalysis
    let width: Int
    let height: Int
    @State private var isOpen = false
    @State private var kx = 0
    @State private var ky = 0

    var body: some View {
        let bin = SpectrumBin.at(kx: kx, ky: ky, width: width, height: height)
        DisclosureGroup("Measure at…", isExpanded: $isOpen) {
            VStack(alignment: .leading, spacing: LayoutPolicy.inspectorRowSpacing) {
                binRow("kx", value: kx, identifier: "fft.spots.measureAt.kx") { kx = $0 }
                binRow("ky", value: ky, identifier: "fft.spots.measureAt.ky") { ky = $0 }
                InspectorNote(FFTRoomFormat.binRange(width: width, height: height))
                InspectorActionRow {
                    Button("Measure") { PendingEdits.run { measure() } }
                        .disabled(bin == nil)
                        .accessibilityIdentifier("fft.spots.measureAt.measure")
                }
            }
            .padding(.top, LayoutPolicy.inspectorRowSpacing)
        }
        .accessibilityIdentifier("fft.spots.measureAt")
    }

    private func binRow(_ title: String, value: Int, identifier: String, set: @escaping (Int) -> Void) -> some View {
        InspectorRow(title) {
            OptionalNumericField(title: title, value: value, format: IntegerFormatStyle<Int>.number.grouping(.never),
                                 unit: "bins", onCommit: set)
                .accessibilityIdentifier(identifier)
        }
    }

    private func measure() {
        guard let bin = SpectrumBin.at(kx: kx, ky: ky, width: width, height: height) else { return }
        analysis.measureSpot(row: bin.row, col: bin.col)
    }
}

// MARK: - Radial Profile

/// The mean |F|² per |q| bin on a log axis, with the bin under the pointer read out below it.
private struct FFTRadialProfileSection: View {
    let image: CalibratedImage
    let analysis: FFTAnalysis

    var body: some View {
        if let spectrum = analysis.spectrum {
            InspectorSection("Radial Profile") {
                if let profile = spectrum.profile {
                    let unit = FFTUnits.spectrumUnit(spectrum.unitsX)
                    let samples = FFTRoomFormat.chartSamples(profile, factor: unit.factor)
                    let binWidth = profile.width * unit.factor
                    if samples.isEmpty {
                        InspectorNote(FFTRoomFormat.profileEmpty)
                    } else {
                        FFTRadialChart(samples: samples, label: unit.label, binWidth: binWidth)
                    }
                    let caption = FFTRoomFormat.caption(binWidth: binWidth, label: unit.label,
                                                        what: FFTRoomFormat.transformed(spectrum.key.crop, imageWidth: image.width,
                                                                                        imageHeight: image.height, withPosition: false))
                    InspectorNote(caption).accessibilityLabel(FFTRoomFormat.spoken(caption))
                } else {
                    InspectorNote(FFTRoomFormat.profileUnavailable)
                }
            }
        }
    }
}

/// The chart and its readout. The pointer's |q| is `@State` (it changes at the pointer's rate); the readout is an interval of
/// |q| with its mean power and pixel count, never a d.
struct FFTRadialChart: View {
    let samples: [FFTRoomFormat.ChartSample]
    let label: String
    let binWidth: Double
    @State private var pointerX: Double?
    /// The x title as a String, so `.value` takes its StringProtocol overload. The interpolated LocalizedStringKey form,
    /// `.value("|q| (\(label))", …)`, trapped Charts' layout now and then ("Duplicate keys of type 'HashableText'"):
    /// 18 of 2400 fresh renders, 0 of 2400 with this, 8 of 900 hosted in an NSHostingView (Gate D, 2026-10-14,
    /// archive: fft-chart-trap-gate-d-2026-10-14.md). Why Charts' dictionary breaks is not known.
    private var xTitle: String { "|q| (\(label))" }

    var body: some View {
        let selected = pointerX.flatMap { FFTRoomFormat.nearest(samples, toX: $0) }
        Chart {
            ForEach(samples, id: \.bin) { sample in
                LineMark(x: .value(xTitle, sample.q), y: .value("Mean |F|²", sample.mean))
            }
            if let selected {
                RuleMark(x: .value("Selected |q|", selected.q))
                    .foregroundStyle(.secondary)
            }
        }
        .chartYScale(type: .log)
        .chartXSelection(value: $pointerX)
        // The ticks read as every other number in the app (`displayNumber`: no grouping); a power in decades.
        .chartXAxis { numberedAxis }
        .chartYAxis { powerAxis }
        .chartXAxisLabel("|q| (\(label))", alignment: .center)
        .chartYAxisLabel("Mean |F|²")
        .frame(height: FFTRoomFormat.chartHeight)
        .accessibilityLabel("Radial profile")
        .accessibilityValue(FFTRoomFormat.spoken(FFTRoomFormat.profileSummary(samples, label: label)))
        // Two lines reserved: the readout appearing must not move what is below it.
        let readout = selected.map { FFTRoomFormat.readout($0, binWidth: binWidth, label: label) } ?? "Point at the chart to read a bin."
        InspectorNote(readout)
            .lineLimit(2, reservesSpace: true)
            .accessibilityLabel(FFTRoomFormat.spoken(readout))
    }

    private var numberedAxis: some AxisContent {
        AxisMarks { value in
            AxisGridLine()
            AxisTick()
            AxisValueLabel {
                if let number = value.as(Double.self) { Text(UnitDisplay.number(number)) }
            }
        }
    }

    /// A label on the decades `FFTRoomFormat.powerAxisMarks` chooses — every n-th, so that none is closer than 16 pt to the next
    /// on the plot the 120-pt chart leaves (a label per decade over six to ten decades overprinted).
    private var powerAxis: some AxisContent {
        AxisMarks(values: FFTRoomFormat.powerAxisMarks(samples)) { value in
            AxisGridLine()
            AxisTick()
            AxisValueLabel {
                if let number = value.as(Double.self) { Text(FFTRoomFormat.power(number)) }
            }
        }
    }
}

// MARK: - Masked Inverse

/// The mask's Radius and Edge in bins, and how many spots it takes. Shown once a spot is measured (a refused spot has no centroid).
private struct FFTMaskSection: View {
    let analysis: FFTAnalysis

    var body: some View {
        let spots = analysis.spots
        if analysis.hasMeasuredSpot {
            InspectorSection("Masked Inverse") {
                AdjustmentSlider("Radius", value: radius, in: FFTMask.radiusRange, step: Self.step,
                                 format: .number.precision(.fractionLength(0...1)), unit: "bins", defaultValue: FFTMask.defaultRadius)
                    .help("The mask passes everything within this many bins of a spot's centre")
                    .accessibilityIdentifier("fft.mask.radius")
                AdjustmentSlider("Edge", value: edge, in: FFTMask.edgeRange, step: Self.step,
                                 format: .number.precision(.fractionLength(0...1)), unit: "bins", defaultValue: FFTMask.defaultEdge)
                    .help("The mask falls to nothing over this many bins beyond the radius")
                    .accessibilityIdentifier("fft.mask.edge")
                InspectorNote(FFTRoomFormat.maskSummary(spots))
            }
        }
    }

    /// Half a bin: the mask's centres are fractional, and a coarser step would make the live inverse follow a slider that cannot
    /// tell two values apart.
    private static let step = 0.5

    private var radius: Binding<Double> {
        Binding(get: { analysis.maskRadius }, set: { analysis.setMask(radius: $0, edge: analysis.maskEdge) })
    }

    private var edge: Binding<Double> {
        Binding(get: { analysis.maskEdge }, set: { analysis.setMask(radius: analysis.maskRadius, edge: $0) })
    }
}

// MARK: - HRTEM Filters

/// The unvalidated filters: their warning first and always, the seven parameters, Filter, the last run and any refusal. Collapsed
/// until opened.
private struct FFTFiltersSection: View {
    let image: CalibratedImage
    let analysis: FFTAnalysis
    @SceneStorage("fft.inspector.filtersExpanded") private var isExpanded = false
    @State private var parametersOpen = false

    var body: some View {
        let parameters = analysis.filterParameters
        let isFiltering = analysis.isFiltering
        let filtered = analysis.filtered
        let failure = analysis.filterFailure
        let region = analysis.region
        let centred = FFTRegion.centredSquare(width: image.width, height: image.height)
        InspectorSection("HRTEM Filters", expanded: $isExpanded) {
            InspectorWarning(FFTRoomFormat.unvalidatedWarning)
            DisclosureGroup(isExpanded: $parametersOpen) {
                parameterRows(parameters)
            } label: {
                HStack {
                    Text("Parameters")
                    Spacer(minLength: 0)
                    if !parametersOpen {
                        Text(FFTRoomFormat.parametersSummary(parameters)).foregroundStyle(.secondary)
                    }
                }
            }
            .accessibilityIdentifier("fft.filter.parameters")
            InspectorActionRow {
                Button { PendingEdits.run { analysis.runFilter() } } label: {
                    HStack(spacing: 6) {
                        Text("Filter")
                        if isFiltering { ProgressView().controlSize(.small) }
                    }
                }
                .disabled(isFiltering)
                .accessibilityIdentifier("fft.filter.run")
                .accessibilityValue(isFiltering ? "Running" : "")
            }
            InspectorNote(FFTRoomFormat.offBinNote)
            if let filtered {
                InspectorValueRow("Last run", FFTRoomFormat.filterStatus(n: filtered.n, passes: filtered.passes,
                                                                         finalDelta: filtered.finalDelta))
            }
            if let failure {
                InspectorWarning(failure, systemImage: "exclamationmark.circle")
                // The filters take the pixels as they are: a region always, the whole image only when it is square and even.
                if !FFTRegion.filterable(width: region?.width ?? image.width, height: region?.height ?? image.height) {
                    InspectorActionRow {
                        Button("Use Centred Square") { PendingEdits.run { analysis.setRegion(centred, committed: true) } }
                            .disabled(centred == nil)
                            .accessibilityIdentifier("fft.filter.centredSquare")
                    }
                }
            }
        }
    }

    private func parameterRows(_ parameters: HRTEMFilter.Parameters) -> some View {
        VStack(alignment: .leading, spacing: LayoutPolicy.inspectorRowSpacing) {
            decimalRow(.delta, parameters.delta)
            decimalRow(.step, parameters.step)
            wholeRow(.cycles, parameters.cycles)
            InspectorRow("Smoothing") {
                Toggle("Smoothing", isOn: smoothing)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .accessibilityIdentifier("fft.filter.smoothing")
            }
            .help(FFTRoomFormat.smoothingHelp)
            // Order and Ro shape the low-pass: with Smoothing off they act on nothing.
            wholeRow(.order, parameters.order).disabled(!parameters.smoothing)
            decimalRow(.ro, parameters.ro).disabled(!parameters.smoothing)
            decimalRow(.lowFrequency, parameters.lowFrequencyPercent)
        }
        .padding(.top, LayoutPolicy.inspectorRowSpacing)
    }

    private func decimalRow(_ parameter: FFTRoomFormat.FilterParameter, _ value: Double) -> some View {
        FFTParameterRow(parameter: parameter, value: value,
                        format: FloatingPointFormatStyle<Double>.number.precision(.significantDigits(1...4))) {
            commit(parameter, $0)
        }
    }

    private func wholeRow(_ parameter: FFTRoomFormat.FilterParameter, _ value: Int) -> some View {
        FFTParameterRow(parameter: parameter, value: value, format: IntegerFormatStyle<Int>.number.grouping(.never)) {
            commit(parameter, Double($0))
        }
    }

    /// A typed parameter, clamped into the range the filter accepts, on top of the parameters as they are now; the owner drops the
    /// last run's result.
    private func commit(_ parameter: FFTRoomFormat.FilterParameter, _ typed: Double) {
        analysis.setFilterParameters(parameter.applying(typed, to: analysis.filterParameters))
    }

    private var smoothing: Binding<Bool> {
        Binding(get: { analysis.filterParameters.smoothing },
                set: {
                    var parameters = analysis.filterParameters
                    parameters.smoothing = $0
                    analysis.setFilterParameters(parameters)
                })
    }
}

/// One typed parameter: its title, a number field with its unit, the range in its tooltip.
private struct FFTParameterRow<Value: Equatable, Format: ParseableFormatStyle>: View
where Format.FormatInput == Value, Format.FormatOutput == String {
    let parameter: FFTRoomFormat.FilterParameter
    let value: Value
    let format: Format
    let commit: (Value) -> Void

    var body: some View {
        InspectorRow(parameter.title) {
            OptionalNumericField(title: parameter.title, value: value, format: format, unit: parameter.unit, onCommit: commit)
                .accessibilityIdentifier(parameter.identifier)
        }
        .help(parameter.help())
    }
}

// MARK: - Display

/// The spectrum's own histogram (of the values it is drawn in) and its two window handles. Second and open, as every image room's
/// Display (control placement §2); absent while there is no histogram.
private struct FFTDisplaySection: View {
    let analysis: FFTAnalysis

    var body: some View {
        let spectrum = analysis.spectrum
        if let spectrum, let histogram = spectrum.canvas.histogram {
            InspectorSection("Display") {
                IntensityHistogramView(histogram: histogram,
                                       low: edge(\.spectrumWindowLow, default: spectrum.defaultWindow?.low ?? histogram.minimum),
                                       high: edge(\.spectrumWindowHigh, default: spectrum.defaultWindow?.high ?? histogram.maximum),
                                       reset: reset)
                InspectorNote(FFTRoomFormat.displayValueNote)
            }
        }
    }

    /// A window edge as a value the histogram can drag: the stored edge, else the default window's.
    private func edge(_ keyPath: ReferenceWritableKeyPath<FFTAnalysis, Float?>, default fallback: Float) -> Binding<Float> {
        Binding(get: { analysis[keyPath: keyPath] ?? fallback },
                set: { analysis[keyPath: keyPath] = $0 })
    }

    private func reset() {
        analysis.spectrumWindowLow = nil
        analysis.spectrumWindowHigh = nil
    }
}

// MARK: - Info

/// The Info tab's Fourier Transform section, above the Image section: what is transformed, its size, Δq and the Nyquist frequency
/// on each axis, and the three things a reader must know about the picture.
struct FFTRoomInspectorInfo: View {
    let image: CalibratedImage
    let analysis: FFTAnalysis

    var body: some View {
        let spectrum = analysis.spectrum
        // The transform shown names itself; before there is one, the region asked for.
        let crop = spectrum.map(\.key.crop) ?? analysis.region
        InspectorSection("Fourier Transform") {
            InspectorValueRow("Transformed", FFTRoomFormat.transformedKind(crop))
            InspectorValueRow("Size", FFTRoomFormat.pixelSize(crop, imageWidth: image.width, imageHeight: image.height))
            if let spectrum {
                frequencyRows(of: spectrum)
            }
            InspectorNote(FFTRoomFormat.infoUnwindowed)
            InspectorNote(FFTRoomFormat.infoSpotsWindowed)
            InspectorNote(FFTRoomFormat.infoDCNotDrawn)
        }
    }

    /// Δq on each axis, and the Nyquist frequency with the spacing it is (one row when the axes agree).
    @ViewBuilder
    private func frequencyRows(of spectrum: FFTSpectrumProduct) -> some View {
        let steps = FFTRoomFormat.frequencySteps(spacingX: spectrum.spacingX, unitsX: spectrum.unitsX,
                                                 spacingY: spectrum.spacingY, unitsY: spectrum.unitsY)
        let nyquistX = FFTRoomFormat.nyquist(spacing: spectrum.spacingX, count: spectrum.width, units: spectrum.unitsX)
        let nyquistY = FFTRoomFormat.nyquist(spacing: spectrum.spacingY, count: spectrum.height, units: spectrum.unitsY)
        FFTValueRow("Δq (x)", steps.x)
        FFTValueRow("Δq (y)", steps.y)
        if nyquistX == nyquistY {
            FFTValueRow("Nyquist", nyquistX)
        } else {
            FFTValueRow("Nyquist (x)", nyquistX)
            FFTValueRow("Nyquist (y)", nyquistY)
        }
    }
}

/// The finder's three settings: how far above the display's minimum a peak must rise (a fraction of the range), the least distance
/// between two peaks, and how many spots to put on the spectrum. They apply at the next Find Spots.
private struct FFTSpotFinderRows: View {
    let analysis: FFTAnalysis

    var body: some View {
        let finder = analysis.spotFinder
        InspectorRow("Threshold") {
            OptionalNumericField(title: "Finder threshold", value: finder.thresholdFraction, format: .number.precision(.fractionLength(0...2)), unit: "of range") {
                analysis.setSpotFinder(thresholdFraction: $0)
            }
        }
        InspectorRow("Distance") {
            OptionalNumericField(title: "Finder minimum distance", value: finder.minDistance, format: IntegerFormatStyle<Int>.number, unit: "bins") {
                analysis.setSpotFinder(minDistance: $0)
            }
        }
        InspectorRow("Most spots") {
            OptionalNumericField(title: "Finder spot count", value: finder.count, format: IntegerFormatStyle<Int>.number) {
                analysis.setSpotFinder(count: $0)
            }
        }
    }
}
