//
//  ImageRoomInspector.swift
//  Role: the Image room's inspector content. Settings: the calibration a distance in this room is measured
//        in (readiness, the first section), then Display (ImageRoomDisplay.swift), Particles (ImageRoomParticles.swift) and Measure (ImageRoomMeasure.swift).
//        Info: what the open image is, as the file states it, then what it records about the acquisition
//        (ImageRoomAcquisition.swift).
//
//  Every number shown is the file's own (`CalibratedImage`), in the reader's locale at up to 6 significant
//  digits (DM stores calibrations as float32, about 7); the value range uses 9, so an integer image's
//  extremes are exact. A unit is shown with `UnitDisplay.label` (nm, nm⁻¹, Å; anything
//  unrecognised as written), a metre axis in nm, µm or mm (`DisplaySampling`).
//

import ShellInspector
import ImagoCore
import SwiftUI
import TEMCore
import TEMSession

/// The room's Settings: the calibration a distance in this room is measured in (readiness, first), then the
/// display of the selected file and its marks.
struct ImageRoomSettings: View {
    let image: CalibratedImage
    @Environment(AppState.self) private var appState

    var body: some View {
        ImageRoomCalibrationSection(image: image)
        // An image stack read on demand (a multi-page TIFF): the frame shown and the slider that moves it.
        if let item = appState.openItems.selected, item.stack != nil { ImageRoomStackSection(item: item, items: appState.openItems) }
        ImageRoomDisplaySection(presentation: appState.presentation)
        // The Particles view: objects found on the image, outlined over it. Above Measure, so it is in view without scrolling past the tools.
        if let item = appState.openItems.selected {
            ImageRoomParticlesSection(image: image, item: item, rawRange: appState.presentation.canvas?.rawRange)
        }
        ImageRoomMeasureSection(image: image, measurements: appState.measurements, tools: appState.imageRoomTools,
                                item: appState.openItems.selected)
        // The record of those marks: collapsed, drawn only when there is something to show.
        if let item = appState.openItems.selected { ImageRoomLineageSection(image: image, item: item) }
    }
}

/// The calibration this room's distances use: the x axis for horizontal lengths (the scale bar), each axis
/// for its own direction.
struct ImageRoomCalibrationSection: View {
    let image: CalibratedImage

    var body: some View {
        InspectorSection("Calibration") {
            InspectorValueRow("Horizontal (x)", ImageInfoFormat.sampling(image.x))
            InspectorValueRow("Vertical (y)", ImageInfoFormat.sampling(image.y))
            InspectorValueRow("Source", image.x?.isCalibrated == true || image.y?.isCalibrated == true
                              ? "The file" : "None in the file")
            if image.x?.isCalibrated != true {
                InspectorWarning("Not calibrated: the scale bar counts pixels.")
            } else if image.hasSquarePixels == false {
                InspectorWarning("Pixels are not square: the scale bar uses x, and the image is drawn one pixel per pixel.")
            }
        }
    }
}

/// The file, the object it came from, its size, voltage and both axes as stored (a metre axis in nm, µm or mm),
/// and the value range the display spans.
struct ImageInfoSection: View {
    let image: CalibratedImage
    let canvas: CanvasPixels?
    @Environment(AppState.self) private var appState

    var body: some View {
        imageSection
        // What the file records about the acquisition (ImageRoomAcquisition.swift).
        AcquisitionSection(metadata: appState.imageSession.metadata,
                           formatExtension: (image.fileName as NSString).pathExtension)
    }

    private var imageSection: some View {
        InspectorSection("Image") {
            InspectorValueRow("File", image.fileName)
            InspectorValueRow("Object", image.source)
            InspectorValueRow("Size", "\(image.width) × \(image.height) px")
            if let voltage = image.voltage {
                InspectorValueRow("Voltage", "\(UnitDisplay.number(voltage / 1000)) kV")
            }
            InspectorValueRow("x axis", ImageInfoFormat.axis(image.x))
            InspectorValueRow("y axis", ImageInfoFormat.axis(image.y))
            if let canvas {
                InspectorValueRow("Values", canvas.rawRange.map { ImageInfoFormat.range($0.lowerBound, $0.upperBound) }
                                  ?? "No finite values")
            }
            // What the reader must say beyond the numbers ("frame 1 of 212", "8-bit render, not counts"): the
            // pane's header carries them too, so they are never off screen.
            ForEach(image.notes, id: \.self) { InspectorNote($0) }
        }
    }
}

/// The wording of the rows above, pure so a test can pin it.
enum ImageInfoFormat {
    /// "0.0123 nm/px", or "Not calibrated" (no unit, or a scale that is not a positive length per pixel). A metre
    /// axis reads in nm, µm or mm (`DisplaySampling`).
    static func sampling(_ axis: AxisCalibration?) -> String {
        if let q = UnitDisplay.reciprocalAngstromsPerPixel(axis) { return "\(UnitDisplay.number(q)) Å⁻¹/px" }
        guard let axis = DisplaySampling.perPixel(axis), axis.isCalibrated else { return "Not calibrated" }
        return "\(UnitDisplay.number(axis.scale)) \(UnitDisplay.label(axis.unit))/px"
    }

    /// "0.0123 nm/px · origin 12 px": the scale and the DM origin (the pixel index of the physical zero).
    static func axis(_ axis: AxisCalibration?) -> String {
        if let q = UnitDisplay.reciprocalAngstromsPerPixel(axis), let axis {
            return "\(UnitDisplay.number(q)) Å⁻¹/px · origin \(UnitDisplay.number(axis.origin)) px"
        }
        guard let axis = DisplaySampling.perPixel(axis) else { return "No calibration" }
        let unit = axis.unit.isEmpty ? "(no unit)" : UnitDisplay.label(axis.unit)
        return "\(UnitDisplay.number(axis.scale)) \(unit)/px · origin \(UnitDisplay.number(axis.origin)) px"
    }

    /// "−12000 … 11039": 9 significant digits, so every integer a Float32 holds exactly (up to 2^24) prints exactly.
    static func range(_ low: Float, _ high: Float) -> String {
        "\(UnitDisplay.number(Double(low), digits: 9)) … \(UnitDisplay.number(Double(high), digits: 9))"
    }
}

/// The frame of an image stack: "Frame 12 of 100", a slider and the two steps. One frame is read at a time, off the main actor
/// (`OpenItems.showFrame`); the slider moves at once and the image follows when the frame has been read. The sandbox scope of the
/// file is held while the item is open.
struct ImageRoomStackSection: View {
    let item: OpenItem
    let items: OpenItems

    var body: some View {
        if let stack = item.stack {
            let shown = item.frame, wanted = item.requestedFrame
            InspectorSection("Stack") {
                InspectorValueRow("Frame", "\(wanted + 1) of \(stack.frameCount)")
                    .accessibilityIdentifier("image.stack.frame")
                    .accessibilityValue("\(shown + 1)")
                Slider(value: Binding(get: { Double(wanted) }, set: { items.showFrame(item, to: Int($0.rounded())) }),
                       in: 0...Double(max(stack.frameCount - 1, 1)), step: 1)
                    .accessibilityLabel("Frame")
                    .accessibilityValue("\(wanted + 1) of \(stack.frameCount)")
                    .accessibilityIdentifier("image.stack.slider")
                InspectorActionRow {
                    Button("Previous", systemImage: "chevron.left") { items.showFrame(item, to: wanted - 1) }
                        .disabled(wanted <= 0).accessibilityIdentifier("image.stack.previous")
                    Button("Next", systemImage: "chevron.right") { items.showFrame(item, to: wanted + 1) }
                        .disabled(wanted >= stack.frameCount - 1).accessibilityIdentifier("image.stack.next")
                }
                Toggle("Same contrast for every frame", isOn: Binding(
                    get: { item.presentation.windowLow != nil || item.presentation.windowHigh != nil },
                    set: { on in if on { item.presentation.holdCurrentRange() } else { item.presentation.resetWindow() } }))
                    .help("Pin the contrast window at the range of this frame, so a change of brightness between frames shows")
                    .accessibilityIdentifier("image.stack.holdContrast")
                InspectorNote(item.presentation.windowLow == nil && item.presentation.windowHigh == nil
                              ? "Each frame is contrast-scaled on its own range. ← and → step through the frames; frames are read one at a time."
                              : "The contrast window stays at the same values from frame to frame (Reset Range under the histogram releases it).")
            }
        }
    }
}
