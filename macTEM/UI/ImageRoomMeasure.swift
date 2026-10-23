//
//  ImageRoomMeasure.swift
//  Role: the Image room's Measure section (Settings tab, under Display; archive: roadmap-registrations-2026-10-15.md V1-5, the design in
//        archive: image-room-design-2026-10-13.md): the tool, the list of marks on the open file, and, for a
//        selected profile, its chart and width. Presentation only: the marks and their profiles are the file's
//        `ImageMeasurements` (TEMSession), the numbers TEMCore's (`ImageMeasurement`, `LineProfile`), the tool the
//        window's `ImageRoomTools`. What a mark's value READS as is `MarkFormat`, pure so a test pins it.
//
//        The units are the FILE's (Velox writes metres): `MarkFormat` brings a metre axis to nm, µm or mm
//        (`DisplaySampling`) before it measures, so every length comes out in the unit it is shown in.
//

import ShellControls
import ShellInspector
import ShellLayout
import ImagoCore
import SwiftUI
import Charts
#if canImport(TEMCore)
import TEMCore
import TEMSession
#endif

// MARK: - The section

/// Tool, marks, and the selected profile — for the selected file. The owners come in as parameters, as the Display
/// section's does, so `ImageRoomSettings` is the one place that follows the selected file.
struct ImageRoomMeasureSection: View {
    let image: CalibratedImage
    let measurements: ImageMeasurements
    let tools: ImageRoomTools
    /// The selected item, whose session state the tail shows (V1-2); nil with no file open.
    let item: OpenItem?

    var body: some View {
        InspectorSection("Measure") {
            MeasureToolPicker(tools: tools)
            MeasureMarksList(image: image, measurements: measurements)
            MeasureProfileDetail(image: image, measurements: measurements)
            if let item { ImageRoomSessionTail(item: item) }
        }
    }
}

/// The four tools as one segmented control, and a line saying what the chosen one does with the pointer.
///
/// Words, not symbols: a segmented `Picker` on macOS draws only a `Label`'s title and gives VoiceOver the title, but
/// an icon-only segment is spoken as its SF Symbol's description ("block" for the hand), so a symbol picker would
/// need its own accessibility work. Measured (scratch app, 2026-10-13): at the regular control size the four titles need
/// 246 pt at least and 308 ideally — 2 pt under the inspector's 248-pt content at its minimum and over its 233 pt
/// beside an always-visible scroll bar, where it would raise the inspector's minimum width; at the small size 209.5 pt
/// at least and 264 ideally, which fits both and the ideal column (288) with room.
private struct MeasureToolPicker: View {
    @Bindable var tools: ImageRoomTools

    var body: some View {
        // Full inspector width, no label (control placement standard); `SegmentedPicker` is MacEMUI's.
        SegmentedPicker(label: "Tool", items: ImageRoomTools.Tool.allCases.map { ($0, .title($0.title)) }, selection: $tools.tool)
            .accessibilityIdentifier("image.tool")
        // One line at the ideal column, two for Angle's at the minimum (measured, scratch app 2026-10-13: 13 pt and
        // 26 pt); no space is reserved for the second, which would leave 12 pt of blank beneath every hint at the
        // widths where none wraps.
        InspectorNote(tools.tool.hint)
    }
}

private extension ImageRoomTools.Tool {
    /// What the pointer does in this tool (the gestures of the design note's Measure section).
    var hint: String {
        switch self {
        case .pan: "Drag to pan; drag a mark's end to move it."
        case .distance, .profile: "Drag on the image."
        case .angle: "Drag the first arm to the vertex, then click the third point."
        }
    }
}

// MARK: - The marks

/// One row per mark of the file and Remove All (where the marks are kept is the session tail's, `ImageRoomSession.swift`). The list takes the keyboard when
/// clicked: ⌫ removes the selected mark, ⌘C copies its value, ↑ and ↓ move the selection.
///
/// A row is a plain `Button` over a `.quaternary` fill when selected, not a `List(selection:)` (not allowed inside the
/// inspector's `ScrollView`), with the kind's symbol in the accent colour as the selected mark is drawn on the image.
/// Not `.selection`: its use outside a list is not documented; rendered off screen (2026-10-13, no key window) it came
/// out the neutral grey of an inactive selection, and in a key window it would presumably be the accent colour under
/// unchanged text, which a list swaps to white and a plain row does not (not checked on screen). `.quaternary` is the
/// system's own fill, adapts to light, dark and Increase Contrast, and is no custom wash (UI contract rule 3).
private struct MeasureMarksList: View {
    let image: CalibratedImage
    let measurements: ImageMeasurements
    @FocusState private var hasFocus: Bool

    var body: some View {
        // One read of each, here, then values down to the rows (a row that read `selection` itself would register N
        // identical dependencies).
        let marks = measurements.marks
        let selection = measurements.selection
        if !marks.isEmpty {
            VStack(alignment: .leading, spacing: Self.rowSpacing) {
                ForEach(marks) { mark in
                    MeasureMarkRow(mark: mark, x: image.x, y: image.y,
                                   isSelected: mark.id == selection, measurements: measurements)
                }
            }
            .focusable()
            .focused($hasFocus)
            .simultaneousGesture(TapGesture().onEnded { hasFocus = true })
            .onDeleteCommand { if let selection { measurements.remove(selection) } }
            .onCopyCommand { copyProviders(marks: marks, selection: selection) }
            .onMoveCommand { move($0, marks: marks, selection: selection) }
            InspectorActionRow {
                Button("Remove All") { measurements.removeAll() }
            }
        }
    }

    private static let rowSpacing: CGFloat = 2

    /// The selected mark's value, as the row shows it.
    private func copyProviders(marks: [ImageMark], selection: ImageMark.ID?) -> [NSItemProvider] {
        guard let mark = marks.first(where: { $0.id == selection }) else { return [] }
        return [NSItemProvider(object: MarkFormat.value(mark, x: image.x, y: image.y) as NSString)]
    }

    /// ↑ and ↓ select the previous and the next mark; with none selected, the last and the first.
    private func move(_ direction: MoveCommandDirection, marks: [ImageMark], selection: ImageMark.ID?) {
        guard !marks.isEmpty else { return }
        let current = marks.firstIndex { $0.id == selection }
        switch direction {
        case .up: measurements.selection = marks[current.map { max($0 - 1, 0) } ?? marks.count - 1].id
        case .down: measurements.selection = marks[current.map { min($0 + 1, marks.count - 1) } ?? 0].id
        default: break
        }
    }
}

/// One mark: its kind's symbol, its value, and Remove. Takes values and the owner (a reference, compared by identity),
/// no closures, so a row whose mark, axes and selection did not change is not evaluated again.
private struct MeasureMarkRow: View {
    let mark: ImageMark
    let x: AxisCalibration?
    let y: AxisCalibration?
    let isSelected: Bool
    let measurements: ImageMeasurements

    /// The symbols differ in width; a fixed one keeps the values in a column.
    private static let symbolWidth: CGFloat = 18

    var body: some View {
        let spoken = MarkFormat.spoken(mark, x: x, y: y)
        HStack(spacing: 6) {
            Button { measurements.selection = mark.id } label: {
                HStack(spacing: 8) {
                    Image(systemName: symbol)
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                        .frame(width: Self.symbolWidth)
                        .accessibilityHidden(true)
                    Text(MarkFormat.value(mark, x: x, y: y))
                        .monospacedDigit()
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(spoken)
            .accessibilityValue(MarkFormat.value(mark, x: x, y: y))
            .accessibilityIdentifier("image.mark")
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            Button("Remove", systemImage: "xmark") { measurements.remove(mark.id) }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Remove")
                .accessibilityLabel("Remove \(spoken)")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background { RoundedRectangle(cornerRadius: 6).fill(.quaternary).opacity(isSelected ? 1 : 0) }
    }

    /// The tool that draws this kind of mark has the symbol for it.
    private var symbol: String {
        ImageRoomTools.Tool.allCases.first { $0.markKind == mark.kind }?.systemImage ?? "questionmark"
    }
}

// MARK: - The selected profile

/// The selected mark's profile, when it is one: the chart, the width it averages over, and Export Profile… (a CSV of its
/// samples; the File menu's item of the same name opens the same panel, for when this row has scrolled out of view).
private struct MeasureProfileDetail: View {
    @Environment(AppState.self) private var appState
    let image: CalibratedImage
    let measurements: ImageMeasurements

    var body: some View {
        if let mark = measurements.mark(measurements.selection), mark.kind == .profile,
           let profile = measurements.profiles[mark.id] {
            MeasureProfileChart(profile: profile, x: image.x, y: image.y)
            InspectorRow("Width") {
                HStack(spacing: 8) {
                    Text("\(mark.width) px")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Stepper("Width", value: width(of: mark), in: 1...ImageMeasurements.maximumWidth)
                        .labelsHidden()
                        .accessibilityValue(RoomAccessibilityText.pixels(Double(mark.width)))
                }
            }
            // Drawn with the chart, so absent for a line with no samples (nothing to export). Dimmed while a read runs: the
            // image shown stays during a re-read and this row with it, but the export waits for the new pixels.
            if !profile.samples.isEmpty {
                InspectorActionRow {
                    Button("Export Profile…") { ExportPanels.exportProfile(appState: appState) }
                        .disabled(appState.imageSession.isLoading)
                        .help("Save this line profile as a CSV file")
                        .accessibilityIdentifier("export.profileButton")
                }
            }
        }
    }

    /// The width, written through the owner, which clamps it and measures the profile again on the file's own pixels.
    private func width(of mark: ImageMark) -> Binding<Int> {
        Binding(get: { mark.width },
                set: {
                    if MarkEdits.setWidth(mark.id, $0, on: image, in: measurements) {
                        SessionPanels.markRefused(nil, .widthChanged, appState: appState)
                    }
                })
    }
}

/// Intensity along the line: position in the shown unit against the raw value (never the display window: no contrast
/// setting reaches a number). Swift Charts speaks its own audio graph; the summary is the spoken overview.
private struct MeasureProfileChart: View {
    let profile: LineProfile
    let x: AxisCalibration?
    let y: AxisCalibration?

    /// The chart's height: a fixed 120 pt (the design note's cost), the width is the column's.
    private static let chartHeight: CGFloat = 120

    private struct Sample: Identifiable {
        let id: Int
        let position: Double
        let value: Double
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

    var body: some View {
        if profile.samples.isEmpty {
            InspectorNote("This line has no samples.")
        } else {
            let shown = MarkFormat.chartPositions(profile, x: x, y: y)
            let samples = zip(shown.positions, profile.samples).enumerated()
                .map { Sample(id: $0.offset, position: $0.element.0, value: $0.element.1) }
            // A String, not an interpolated literal: `.value("Position (\(…))", …)` takes the LocalizedStringKey overload,
            // which traps Charts' layout now and then (archive: fft-chart-trap-gate-d-2026-10-14.md).
            let xTitle = "Position (\(shown.unit))"
            Chart(samples) { sample in
                LineMark(x: .value(xTitle, sample.position),
                         y: .value("Value", sample.value))
            }
            // A data range far from zero (16-bit counts around 30000) would flatten into a line at the top.
            .chartYScale(domain: .automatic(includesZero: false))
            // The ticks read as every other number in the app does (`displayNumber`: no grouping — the chart's own
            // labels write "32.000" for 32000 in a German locale, and "4.096" for 4096 px).
            .chartXAxis { numberedAxis }
            .chartYAxis { numberedAxis }
            .chartXAxisLabel(shown.unit, alignment: .center)
            .chartYAxisLabel("Value")
            .frame(height: Self.chartHeight)
            .accessibilityLabel("Line profile")
            .accessibilityValue(MarkFormat.profileSummary(profile, positions: shown.positions, unit: shown.unit))
        }
    }
}

// MARK: - MarkFormat

/// What a mark's value reads as, pure so a test pins it. A length is `UnitDisplay.number` at 4
/// significant digits (a profile's at 3), an angle one decimal; the unit label is `UnitDisplay.label`. Every function takes
/// the FILE's axes and does the display conversion itself (a metre axis in nm, µm or mm): a caller cannot forget it.
nonisolated enum MarkFormat {
    /// The file's axes as shown: both in one unit, and the way from the file's unit to it.
    nonisolated struct ShownAxes {
        let x: AxisCalibration?
        let y: AxisCalibration?
        /// Multiply a length in the file's unit by this to read it in `unit`.
        let factor: Double
        /// The unit lengths are shown in; nil when they are pixels (not both axes calibrated in one unit).
        let unit: String?
    }

    /// A metre axis pair in the unit one of its pixels reads in (`DisplaySampling.unit(forMetres:)`), the same unit for
    /// both axes: `DisplaySampling.perPixel` picks per axis, so a pair of pixels either side of a unit's boundary (0.9 and
    /// 1.1 µm) would land in two units, which `ImageMeasurement` takes for no common unit and answers in pixels. The
    /// reference is the larger pixel. Any other unit passes through, spelled by `UnitDisplay.label`.
    static func shown(x: AxisCalibration?, y: AxisCalibration?) -> ShownAxes {
        guard let scales = ImageMeasurement.physicalScales(x: x, y: y) else {
            return ShownAxes(x: x, y: y, factor: 1, unit: nil)
        }
        guard DisplaySampling.isMetres(scales.unit) else {
            return ShownAxes(x: x, y: y, factor: 1, unit: UnitDisplay.label(scales.unit))
        }
        let reference = max(scales.sx, scales.sy)
        let unit = DisplaySampling.unit(forMetres: reference)
        return ShownAxes(x: x.map { ScaleBarMath.shown($0, reference: reference) },
                         y: y.map { ScaleBarMath.shown($0, reference: reference) },
                         factor: unit.perMetre, unit: unit.label)
    }

    /// The row's text: "12.43 nm · 50.02 px", or "50.02 px" uncalibrated; "63.2°", with " (pixel grid)" when the angle
    /// was taken on the pixel grid (no common physical unit); "Profile · 25.1 nm" / "Profile · 50 px"; "—" for an angle
    /// with an arm of zero length.
    static func value(_ mark: ImageMark, x: AxisCalibration?, y: AxisCalibration?, locale: Locale = .autoupdatingCurrent) -> String {
        guard mark.points.count == mark.kind.pointCount else { return "—" }
        let axes = shown(x: x, y: y)
        let p = mark.points
        switch mark.kind {
        case .distance:
            let length = ImageMeasurement.distance(p[0], p[1], x: axes.x, y: axes.y)
            let pixels = "\(number(length.pixels, 4, locale)) px"
            guard let physical = length.physical, let unit = length.unit else { return pixels }
            return "\(number(physical, 4, locale)) \(UnitDisplay.label(unit)) · \(pixels)"
        case .angle:
            guard let angle = ImageMeasurement.angle(p[0], vertex: p[1], p[2], x: axes.x, y: axes.y) else { return "—" }
            let degrees = angle.degrees.formatted(.number.locale(locale).grouping(.never).precision(.fractionLength(1)))
            return angle.plane == .pixel ? "\(degrees)° (pixel grid)" : "\(degrees)°"
        case .profile:
            let length = ImageMeasurement.distance(p[0], p[1], x: axes.x, y: axes.y)
            guard let physical = length.physical, let unit = length.unit else {
                return "Profile · \(number(length.pixels, 3, locale)) px"
            }
            return "Profile · \(number(physical, 3, locale)) \(UnitDisplay.label(unit))"
        }
    }

    /// The word for a kind.
    static func kindName(_ kind: ImageMark.Kind) -> String {
        switch kind {
        case .distance: "Distance"
        case .angle: "Angle"
        case .profile: "Profile"
        }
    }

    /// What VoiceOver says for the row: the kind first (a profile's value starts with it), "px" as "pixels" (read as
    /// letters otherwise), the separator a pause.
    static func spoken(_ mark: ImageMark, x: AxisCalibration?, y: AxisCalibration?, locale: Locale = .autoupdatingCurrent) -> String {
        let text = value(mark, x: x, y: y, locale: locale)
            .replacing(" · ", with: ", ")
            .replacing(" px", with: " pixels")
        return mark.kind == .profile ? text : "\(kindName(mark.kind)), \(text)"
    }

    /// A profile's positions as charted — in the shown unit, the file's metres brought to nm, µm or mm like every other
    /// length — and the axis label ("px" when the profile is in pixels).
    static func chartPositions(_ profile: LineProfile, x: AxisCalibration?, y: AxisCalibration?) -> (positions: [Double], unit: String) {
        let axes = shown(x: x, y: y)
        if profile.isPhysical, let unit = axes.unit {
            return (profile.positions.map { $0 * axes.factor }, unit)
        }
        return (profile.positions, profile.isPhysical ? UnitDisplay.label(profile.unit) : "px")
    }

    /// The chart's spoken overview: how many samples, how long the line, the lowest and the highest value.
    static func profileSummary(_ profile: LineProfile, positions: [Double], unit: String,
                               locale: Locale = .autoupdatingCurrent) -> String {
        guard let low = profile.samples.min(), let high = profile.samples.max() else { return "No samples" }
        let length = positions.last ?? 0
        let spokenUnit = unit == "px" ? "pixels" : unit
        return "\(profile.samples.count) samples over \(number(length, 3, locale)) \(spokenUnit); "
            + "lowest \(number(low, 6, locale)), highest \(number(high, 6, locale))"
    }

    private static func number(_ value: Double, _ digits: Int, _ locale: Locale) -> String {
        UnitDisplay.number(value, digits: digits, locale: locale)
    }
}
