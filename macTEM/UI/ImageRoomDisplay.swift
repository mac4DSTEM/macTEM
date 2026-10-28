//
//  ImageRoomDisplay.swift
//  Role: the Image room's Display section (Settings tab, under Calibration): the colormap, the histogram with the contrast window, the gamma,
//        Show Scale Bar — each the open file's own (`ImagePresentation`). Display only: nothing here reaches a number.
//

import ShellControls
import ShellInspector
import ShellLayout
import ShellMetal
import SwiftUI
#if canImport(TEMCore)
import ImagoCore
import TEMCore
import TEMSession
#endif

/// Colormap, histogram and window, gamma, scale bar — for the selected file. The one Display section of the image rooms (control
/// placement §5): the Diffraction room draws it for its pattern with the log switch in place of the scale bar (its pane has none).
struct ImageRoomDisplaySection: View {
    @Bindable var presentation: ImagePresentation
    /// The colormap pop-up's and the log switch's identifiers, the room's own (spelled whole: the inventory finds them by name).
    var colormapID = "image.colormap"
    var logID = "diffraction.log"
    /// The pattern's log display, a switch row where the scale bar's would be; nil in a room that draws a scale bar.
    var log: Binding<Bool>?

    /// Gray first: the TEM convention.
    private static let colormaps: [ColormapKind] = [.gray, .inferno, .viridis, .rdbu]

    var body: some View {
        InspectorSection("Display") {
            InspectorRow("Colormap") {
                Picker("Colormap", selection: $presentation.colormap) {
                    ForEach(Self.colormaps) { Text($0.displayName).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .accessibilityIdentifier(colormapID)
            }
            if let histogram = presentation.canvas?.histogram {
                IntensityHistogramView(histogram: histogram,
                                       low: edge(\.windowLow, default: histogram.minimum),
                                       high: edge(\.windowHigh, default: histogram.maximum),
                                       reset: presentation.resetWindow)
            } else {
                InspectorNote("No finite value: there is no histogram.")
            }
            AdjustmentSlider("Gamma", value: $presentation.gamma, in: 0.2...5,
                             format: .number.precision(.fractionLength(2)), defaultValue: 1)
            if let log {
                InspectorRow("Log") {
                    Toggle("Log", isOn: log)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .accessibilityIdentifier(logID)
                }
                .help("Draw log₁₀(1 + I): a pattern spans decades. Display only.")
            } else {
                InspectorRow("Show Scale Bar") {
                    Toggle("Show Scale Bar", isOn: $presentation.showsScaleBar)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
            }
        }
    }

    /// A window edge as a value the histogram can drag: the stored edge, else the data's own extreme.
    private func edge(_ keyPath: ReferenceWritableKeyPath<ImagePresentation, Float?>, default extreme: Float) -> Binding<Float> {
        Binding(get: { presentation[keyPath: keyPath] ?? extreme },
                set: { presentation[keyPath: keyPath] = $0 })
    }
}

/// The histogram of the file's finite raw pixels: the bins and the extremes are TEMCore's `IntensityHistogram` (computed once at
/// open, off the main actor); the drawing, the contrast window's two handles and the min · mean · max footer are ShellControls'
/// `HistogramChart` (suite task 8, MacEMUI). This adapter holds the window in the image's raw values, as `ImagePresentation`
/// does, and hands the chart fractions of the data's range.
struct IntensityHistogramView: View {
    let histogram: IntensityHistogram
    @Binding var low: Float
    @Binding var high: Float
    let reset: () -> Void

    private var span: Float { histogram.maximum - histogram.minimum }

    /// A raw window edge as a fraction of the data's range, and back.
    private func fraction(of raw: Binding<Float>) -> Binding<Float> {
        Binding(
            get: { span > 0 ? min(max((raw.wrappedValue - histogram.minimum) / span, 0), 1) : 0 },
            set: { raw.wrappedValue = histogram.minimum + $0 * span })
    }

    var body: some View {
        HistogramChart(
            counts: histogram.counts,
            statistics: HistogramStatistics(minimum: histogram.minimum, maximum: histogram.maximum, mean: Float(histogram.mean)),
            rangeLo: fraction(of: $low), rangeHi: fraction(of: $high),
            reset: reset)
            .padding(.vertical, 2)
    }
}
