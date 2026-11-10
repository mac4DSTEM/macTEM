//
//  ImageRoomParticles.swift
//  Role: the Particles view, a section of the Image room's inspector: precipitates on
//        a 2D image, found by a threshold on the raw range (bright or dark objects), optional Gaussian smoothing, connected-component
//        labelling and the objects' moments, then counted (not on the edge, not below the minimum area). The image keeps its marks;
//        the objects are outlined over it (`ParticleOverlay`), the mask can be tinted while the settings are edited, and an object
//        table (its own window, `ParticleTableWindow`, so it stays beside the image) selects a row to outline it heavier (⌘C copies
//        the selected row, `ParticleTableFormat`); the pointer
//        readout names the object under the pointer (`ImageReadout`). Presentation only: the numbers are ImagoKit's through
//        `ParticleCompute`, held per file by `ParticleAnalysis` (TEMSession).
//

import ShellControls
import ShellInspector
import SwiftUI
import ImagoCore
import UniformTypeIdentifiers
import TEMCore
import TEMSession
import ShellEDXModel
import ShellSpectroscopy

struct ImageRoomParticlesSection: View {
    let image: CalibratedImage
    let item: OpenItem
    let rawRange: ClosedRange<Float>?
    @State private var exporting = false
    @Environment(\.openWindow) private var openWindow
    @Environment(AppState.self) private var appState

    private struct PreviewKey: Equatable { var settings: ParticleSettings; var on: Bool }

    var body: some View {
        let analysis = item.particles
        let settings = analysis.settings
        InspectorSection("Particles") {
            // First, under the header, so the table and the export are in view without scrolling past the settings.
            if analysis.report != nil {
                InspectorActionRow {
                    Button("Object Table…") { openWindow(id: ParticleTableWindow.id) }.accessibilityIdentifier("particles.table")
                    Button("Export CSV…") { export(analysis) }.accessibilityIdentifier("particles.export")
                }
            }
            SegmentedPicker(label: "Objects", items: ParticleSettings.Polarity.allCases.map { ($0, .title($0.title)) },
                            selection: Binding(get: { settings.polarity }, set: { new in analysis.setSettings { $0.polarity = new } }))
                .accessibilityIdentifier("particles.polarity")
            SegmentedPicker(label: "Threshold", items: ParticleSettings.Method.allCases.map { ($0, .title($0.title)) },
                            selection: Binding(get: { settings.method }, set: { new in analysis.setSettings { $0.method = new } }))
                .accessibilityIdentifier("particles.method")
            if settings.method == .otsu {
                InspectorNote(analysis.report.map { $0.settings.method == .otsu && analysis.isCurrent
                    ? "Otsu's level: \(ParticleFormat.number(Double($0.thresholdValue)))" : "Otsu's level is found with the objects." }
                    ?? "Otsu's level is found with the objects.")
            } else if let range = rawRange, range.upperBound > range.lowerBound {
                AdjustmentSlider("Level",
                                 value: Binding(get: { Double(range.lowerBound) + settings.thresholdFraction * Double(range.upperBound - range.lowerBound) },
                                                set: { v in analysis.setSettings { $0.thresholdFraction = (v - Double(range.lowerBound)) / Double(range.upperBound - range.lowerBound) } }),
                                 in: Double(range.lowerBound)...Double(range.upperBound),
                                 format: .number.precision(.significantDigits(1...5)), unit: "intensity")
                    .accessibilityIdentifier("particles.threshold")
            } else {
                InspectorWarning("The image has no range to threshold (constant or no finite value).")
            }
            InspectorRow("Smoothing σ") {
                OptionalNumericField(title: "Smoothing sigma", value: settings.sigma, format: FloatingPointFormatStyle<Double>.number.precision(.significantDigits(1...4)),
                                     unit: "px", prompt: "0") { v in analysis.setSettings { $0.sigma = v } }
                    .accessibilityIdentifier("particles.sigma")
            }
            SegmentedPicker(label: "Connectivity",
                            items: [(Segmentation.Connectivity.four, .title("4-connected")), (.eight, .title("8-connected"))],
                            selection: Binding(get: { settings.connectivity }, set: { new in analysis.setSettings { $0.connectivity = new } }))
                .accessibilityIdentifier("particles.connectivity")
            InspectorRow("Minimum area") {
                Stepper(value: Binding(get: { settings.minimumArea }, set: { new in analysis.setSettings { $0.minimumArea = new } }), in: 1...100_000) {
                    Text("\(settings.minimumArea) px²").monospacedDigit()
                }
                .accessibilityIdentifier("particles.minimumArea")
            }
            InspectorRow("Tint mask") {
                Toggle("Tint mask", isOn: Binding(get: { analysis.previewsMask }, set: { analysis.setPreviewsMask($0) }))
                    .labelsHidden().toggleStyle(.switch)
                    .help("Tint the pixels on the object side of the threshold while you edit the settings")
            }
            InspectorActionRow {
                Button(analysis.isComputing ? "Finding…" : "Show Objects") { analysis.analyse(image: image) }
                    .disabled(analysis.isComputing || rawRange == nil)
                    .accessibilityIdentifier("particles.show")
                if analysis.showsObjects { Button("Hide") { analysis.hideObjects() } }
            }
            if let failure = analysis.failure { InspectorWarning(failure, systemImage: "xmark.octagon.fill") }
            if let report = analysis.report {
                let scale = ParticleCompute.scale(of: image)
                if !analysis.isCurrent { InspectorWarning("The settings changed since these objects were found: Show Objects again.", systemImage: "arrow.triangle.2.circlepath") }
                InspectorNote(ParticleFormat.counts(report.summary))
                    .accessibilityIdentifier("particles.counts")
                    .accessibilityValue("\(report.summary.counted)")
                InspectorNote(ParticleFormat.sizes(report.summary, scale: scale))
                InspectorNote(ParticleFormat.density(report.summary, scale: scale))
                    .accessibilityIdentifier("particles.density")
                if !scale.isCalibrated { InspectorNote("The image is not calibrated (or its pixels are not square): sizes are in pixels.") }
            } else if !analysis.isComputing {
                InspectorNote("Choose bright or dark objects and a threshold, then Show Objects.")
            }
        }
        .task(id: PreviewKey(settings: settings, on: analysis.previewsMask)) {
            guard analysis.previewsMask else { return }
            try? await Task.sleep(for: .milliseconds(150))
            if !Task.isCancelled { analysis.updatePreview(image: image) }
        }
        .fileExporter(isPresented: $exporting,
                      document: EDXExportFile(data: Data(csv(analysis).utf8)),
                      contentType: .commaSeparatedText,
                      defaultFilename: ParticleExport.baseName(of: image.fileName)) { result in
            switch result {
            case .success(let url): appState.statusText = "Exported \(url.lastPathComponent)"
            case .failure(let error): appState.present(error)
            }
        }
    }

    /// `--export-dir` (a UI journey) writes without a panel, as the Diffraction readout does; otherwise the save panel.
    private func export(_ analysis: ParticleAnalysis) {
        guard let directory = appState.exportDirectory else { exporting = true; return }
        do {
            let url = try ParticleExport.write(csv(analysis), imageFileName: image.fileName, into: directory)
            appState.statusText = "Exported \(url.lastPathComponent)"
        } catch { appState.present(error) }
    }

    private func csv(_ analysis: ParticleAnalysis) -> String {
        analysis.report.map { ParticleFormat.csv($0, scale: ParticleCompute.scale(of: image), fileName: image.fileName) } ?? ""
    }
}

/// Where Export CSV writes when the launch gave `--export-dir`: "<image name> particles.csv" in that folder.
nonisolated enum ParticleExport {
    static func baseName(of imageFileName: String) -> String { (imageFileName as NSString).deletingPathExtension + " particles" }

    static func write(_ text: String, imageFileName: String, into directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(baseName(of: imageFileName) + ".csv")
        try Data(text.utf8).write(to: url)
        return url
    }
}

// MARK: - The table

nonisolated struct ParticleRow: Identifiable, Hashable, Sendable {
    let id: Int32
    let counted: Bool
    let note: String
    let area: Double
    let length: Double
    let width: Double
    let angle: Double

    init(_ o: ParticleObject, scale: ParticleScale) {
        id = o.id; counted = o.isCounted
        note = o.touchesEdge ? "edge" : ""
        area = Double(o.moments.area) * scale.perPixel * scale.perPixel
        length = o.moments.lengthPx * scale.perPixel
        width = o.moments.widthPx * scale.perPixel
        angle = o.moments.orientationDegrees
    }

    /// A row from its values as shown (lengths already in the scale's unit): what a test of the table's words builds without a report.
    init(id: Int32, counted: Bool, note: String, area: Double, length: Double, width: Double, angle: Double) {
        self.id = id
        self.counted = counted
        self.note = note
        self.area = area
        self.length = length
        self.width = width
        self.angle = angle
    }
}

private struct ParticleTableSheet: View {
    let analysis: ParticleAnalysis
    let report: ParticleReport
    let scale: ParticleScale
    @State private var countedOnly = false
    @State private var sortOrder = [KeyPathComparator(\ParticleRow.id)]

    var body: some View {
        let rows = report.objects.map { ParticleRow($0, scale: scale) }.filter { !countedOnly || $0.counted }.sorted(using: sortOrder)
        // Read here, so Edit > Copy is offered and dimmed as the selection comes and goes.
        let selected = analysis.selectedLabel
        VStack(alignment: .leading, spacing: 10) {
            // A window: its title bar names it and closes it (⌘W), so no headline and no Done.
            HStack {
                Spacer()
                Toggle("Counted only", isOn: $countedOnly)
            }
            Table(rows, selection: Binding(get: { analysis.selectedLabel }, set: { analysis.selectedLabel = $0 }), sortOrder: $sortOrder) {
                TableColumn("#", value: \.id) { Text(verbatim: "\($0.id)").monospacedDigit() }.width(40)
                TableColumn("Length (\(scale.unit))", value: \.length) { Text(ParticleFormat.number($0.length)).monospacedDigit() }
                TableColumn("Width (\(scale.unit))", value: \.width) { Text(ParticleFormat.number($0.width)).monospacedDigit() }
                TableColumn("Angle (°)", value: \.angle) { Text(ParticleTableFormat.angle($0)).monospacedDigit() }
                TableColumn("Area (\(scale.unit)²)", value: \.area) { Text(ParticleFormat.number($0.area)).monospacedDigit() }
                TableColumn("Note") { Text(ParticleTableFormat.note($0)).foregroundStyle($0.counted ? Color.primary : Color.secondary) }
            }
            // ⌘C and Edit > Copy: the selected object's row under the column titles, tab-separated; dimmed with no row selected.
            .onCopyCommand(perform: rows.contains(where: { $0.id == selected }) ? { copied(rows, selected: selected) } : nil)
            .accessibilityIdentifier("particles.tableView")
            Text(ParticleFormat.counts(report.summary) + " · select a row to outline it on the image").font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(minWidth: EDXLayout.tableSheetMinimum.width, minHeight: EDXLayout.tableSheetMinimum.height)
    }

    /// What ⌘C hands the system: the selected row as the table shows it (`ParticleTableFormat.copyText`), nothing when none is.
    private func copied(_ rows: [ParticleRow], selected: Int32?) -> [NSItemProvider] {
        let picked = rows.filter { $0.id == selected }
        guard !picked.isEmpty else { return [] }
        return [NSItemProvider(object: ParticleTableFormat.copyText(picked, unit: scale.unit) as NSString)]
    }
}

// MARK: - The overlay

/// The tinted mask and the objects' ellipses over the image, mapped through the pane's own transform (`MarkGeometry`), so they keep
/// their stroke at any zoom. The ellipse of an object is its centroid, its major and minor axis lengths and its orientation (ImagoKit's
/// moments): counted objects solid, edge and small ones dashed and dim, the selected one heavier.
struct ParticleOverlay: View {
    let analysis: ParticleAnalysis
    let geometry: MarkGeometry
    @State private var tint: CGImage?

    var body: some View {
        let report = analysis.showsObjects ? analysis.report : nil
        let preview = analysis.previewsMask ? analysis.maskPreview : nil
        let current = analysis.isCurrent
        let selected = analysis.selectedLabel
        Canvas { ctx, _ in
            if let tint, preview != nil {
                let a = geometry.panePoint(of: ImagePoint(x: -0.5, y: -0.5))
                let b = geometry.panePoint(of: ImagePoint(x: Double(geometry.imageWidth) - 0.5, y: Double(geometry.imageHeight) - 0.5))
                ctx.draw(Image(decorative: tint, scale: 1).interpolation(.none), in: CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y))
            }
            guard let report else { return }
            for o in report.objects {
                let m = o.moments
                let path = Self.ellipse(m, geometry)
                let isSelected = o.id == selected
                let color: Color = isSelected ? .yellow : (o.isCounted ? .cyan : .gray)
                ctx.stroke(path, with: .color(color.opacity(current ? 1 : 0.4)),
                           style: StrokeStyle(lineWidth: isSelected ? 2.5 : 1.25, dash: o.isCounted || isSelected ? [] : [3, 3]))
            }
        }
        .allowsHitTesting(false)
        .task(id: preview?.version) {
            guard let preview else { tint = nil; return }
            let w = preview.width, h = preview.height, mask = preview.mask
            let made: CGImage? = await Task.detached(priority: .userInitiated) {
                var rgba = [UInt8](repeating: 0, count: w * h * 4)
                for (i, on) in mask.enumerated() where on { rgba[4 * i] = 255; rgba[4 * i + 1] = 60; rgba[4 * i + 2] = 60; rgba[4 * i + 3] = 110 }
                guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil as CGImage? }
                return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider, decode: nil,
                               shouldInterpolate: false, intent: .defaultIntent)
            }.value
            // A newer preview cancelled this tint while it ran (the detached work does not see it): it lands nothing over the newer one.
            guard !Task.isCancelled else { return }
            tint = made
        }
    }

    /// The object's ellipse as a path in pane points: 64 points round the centroid, the long axis turned from +x toward +y.
    static func ellipse(_ m: Segmentation.ObjectMoments, _ geometry: MarkGeometry) -> Path {
        let a = m.axisMajorLength / 2, b = m.axisMinorLength / 2
        let t = m.orientationDegrees * .pi / 180
        return Path { p in
            for k in 0...64 {
                let s = Double(k) / 64 * 2 * .pi
                let u = a * cos(s), v = b * sin(s)
                let q = ImagePoint(x: m.centroidCol + u * cos(t) - v * sin(t), y: m.centroidRow + u * sin(t) + v * cos(t))
                let pt = geometry.panePoint(of: q)
                if k == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
            }
            p.closeSubpath()
        }
    }
}

// MARK: - The table's window

/// The object table of the selected file, in a window of its own (Window > Objects, or the section's Object Table… button): it stays
/// open beside the image while rows are selected, and follows the file selected in the main window. With no file or no objects it says so.
struct ParticleTableWindow: View {
    static let id = "particles"
    let appState: AppState

    var body: some View {
        Group {
            if let item = appState.openItems.selected, let image = item.session.image, let report = item.particles.report {
                ParticleTableSheet(analysis: item.particles, report: report, scale: ParticleCompute.scale(of: image))
            } else {
                ContentUnavailableView("No objects", systemImage: "circle.dashed",
                                       description: Text("Show Objects in the Image room's Particles section first."))
                    .frame(minWidth: EDXLayout.tableSheetMinimum.width, minHeight: EDXLayout.tableSheetMinimum.height)
            }
        }
        .environment(appState)
        // While it is key, File > Close (⌘W) and Close Window (⇧⌘W) close it (`CloseCommand`).
        .focusedSceneValue(\.isObjectsWindow, true)
    }
}
