//
//  PatternsProcessingInspector.swift
//  Role: the Patterns room's processing sections (docs/sem/design/pattern-processing.md §3), between Virtual images and Pattern Display:
//        Static background, Dynamic background, Intensity (with Equalise), FFT filter, Size, Average neighbours and NLPAR, in dependency order, each with its stage's state on the title row
//        (the EELS room's glyphs: not run, current, stale). The first row picks what the pattern pane shows, raw or processed; a change
//        to any row re-draws a processed pattern at once and stales the scan's run from that stage on; the toolbar's Process runs it.
//        Presentation only: the settings are `PatternPipeline`'s (TEMCore), the state `EBSDSession`'s (TEMSession).
//

import ShellControls
import ShellInspector
import SwiftUI
import TEMCore
import TEMSession

struct PatternsProcessingSections: View {
    let session: EBSDSession
    let dataset: EBSDDataset

    private var pipeline: PatternPipeline { session.pipeline }
    private static let number = FloatingPointFormatStyle<Double>.number.precision(.significantDigits(1...6))

    private func status(_ stage: PatternPipeline.Stage) -> (word: String, glyph: Image?) {
        let state = session.stageState(stage)
        return (state.word, EELSSectionStatus.glyph(state))
    }

    /// The refusal or the preview's failure when it belongs to `stage`.
    @ViewBuilder private func refusalNote(_ stage: PatternPipeline.Stage) -> some View {
        if let refusal = session.processingRefusal, refusal.stage == stage {
            InspectorNote(refusal.sentence).accessibilityIdentifier("patterns.processing.refusal")
        }
    }

    var body: some View {
        staticSection
        dynamicSection
        intensitySection
        fftSection
        sizeSection
        averagingSection
        nlparSection
    }

    private static let integer = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(0))

    private var fftSection: some View {
        let s = status(.fftFilter)
        let f = pipeline.fftFilter
        return InspectorSection("FFT filter", status: s.word, statusGlyph: s.glyph, startsExpanded: false) {
            InspectorRow("Filter") {
                Toggle("FFT filter", isOn: Binding(get: { f.isOn }, set: { v in session.editPipeline { $0.fftFilter.isOn = v } }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    .help("Multiply each pattern's centred spectrum by a transfer function (kikuchipy fft_filter, frequency domain, shift)")
                    .accessibilityIdentifier("patterns.fft.on")
            }
            SegmentedPicker(label: "Pass", items: PatternPipeline.FFTPass.allCases.map { p in
                (p, .title(p.title, help: p == .low ? "Keep the low frequencies: smooths the noise (lowpass)"
                           : p == .high ? "Keep the high frequencies: removes the slow background (highpass)"
                           : "Lowpass × highpass, the guide's band (kikuchipy's pattern-processing guide)"))
            }, selection: Binding(get: { f.pass }, set: { v in session.editPipeline { $0.fftFilter.pass = v } }))
                .disabled(!f.isOn)
                .accessibilityIdentifier("patterns.fft.pass")
            if f.usesLowpass {
                InspectorRow("Low cutoff") {
                    OptionalNumericField(title: "Lowpass cutoff", value: f.lowCutoff, format: Self.number, unit: "px", prompt: "22") { v in
                        session.editPipeline { $0.fftFilter.lowCutoff = v }
                    }
                        .disabled(!f.isOn)
                        .help("Frequencies within this distance of the spectrum's centre are kept")
                        .accessibilityIdentifier("patterns.fft.lowCutoff")
                }
                InspectorRow("Low width") {
                    OptionalNumericField(title: "Lowpass width", value: f.lowWidth, format: Self.number, unit: "px", prompt: "10") { v in
                        session.editPipeline { $0.fftFilter.lowWidth = v }
                    }
                        .disabled(!f.isOn)
                        .help("The Gaussian roll-off beyond the lowpass cutoff (kikuchipy cutoff_width)")
                        .accessibilityIdentifier("patterns.fft.lowWidth")
                }
            }
            if f.usesHighpass {
                InspectorRow("High cutoff") {
                    OptionalNumericField(title: "Highpass cutoff", value: f.highCutoff, format: Self.number, unit: "px", prompt: "3") { v in
                        session.editPipeline { $0.fftFilter.highCutoff = v }
                    }
                        .disabled(!f.isOn)
                        .help("Frequencies beyond this distance of the spectrum's centre are kept")
                        .accessibilityIdentifier("patterns.fft.highCutoff")
                }
                InspectorRow("High width") {
                    OptionalNumericField(title: "Highpass width", value: f.highWidth, format: Self.number, unit: "px", prompt: "2") { v in
                        session.editPipeline { $0.fftFilter.highWidth = v }
                    }
                        .disabled(!f.isOn)
                        .help("The Gaussian roll-off inside the highpass cutoff (kikuchipy cutoff_width)")
                        .accessibilityIdentifier("patterns.fft.highWidth")
                }
            }
            refusalNote(.fftFilter)
        }
    }

    private var averagingSection: some View {
        let s = status(.averaging)
        let a = pipeline.averaging
        return InspectorSection("Average neighbours", status: s.word, statusGlyph: s.glyph, startsExpanded: false) {
            InspectorRow("Average") {
                Toggle("Average neighbour patterns", isOn: Binding(get: { a.isOn }, set: { v in session.editPipeline { $0.averaging.isOn = v } }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    .help("Average each pattern with its neighbours in the scan, weighted by the window (kikuchipy average_neighbour_patterns)")
                    .accessibilityIdentifier("patterns.average.on")
            }
            SegmentedPicker(label: "Window", items: PatternPipeline.AveragingWindow.allCases.map { w in
                (w, .title(w.title, help: w == .gaussian3 ? "3 × 3 Gaussian weights, std 1" : "\(w.title) circular window, every neighbour weighted 1"))
            }, selection: Binding(get: { a.window }, set: { v in session.editPipeline { $0.averaging.window = v } }))
                .disabled(!a.isOn)
                .accessibilityIdentifier("patterns.average.window")
            refusalNote(.averaging)
            InspectorNote("Averaging needs the neighbours, so it shows on the pattern once Process has run.")
        }
    }

    private var nlparSection: some View {
        let s = status(.nlpar)
        return InspectorSection("NLPAR", status: s.word, statusGlyph: s.glyph, startsExpanded: false) {
            InspectorRow("Average") {
                Toggle("Non-local pattern averaging", isOn: Binding(get: { pipeline.nlpar.isOn }, set: { v in session.editPipeline { $0.nlpar.isOn = v } }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    .help("Average each pattern with its similar neighbours, weighted by their noise-normalised distance (pyebsdindex NLPAR)")
                    .accessibilityIdentifier("patterns.nlpar.on")
            }
            InspectorRow("Radius") {
                OptionalNumericField(title: "Search radius", value: Double(pipeline.nlpar.searchRadius),
                                     format: FloatingPointFormatStyle<Double>.number.precision(.fractionLength(0)), unit: "px",
                                     prompt: "\(NLPAR.defaultSearchRadius)") { v in session.editPipeline { $0.nlpar.searchRadius = max(1, Int(v.rounded())) } }
                    .disabled(!pipeline.nlpar.isOn)
                    .help("The neighbourhood searched around each scan point: (2 r + 1) × (2 r + 1) patterns")
                    .accessibilityIdentifier("patterns.nlpar.radius")
            }
            refusalNote(.nlpar)
            if let lambda = session.nlparLambda, session.stageState(.nlpar) == .current {
                InspectorValueRow("λ", String(format: "%.3f", lambda))
                    .accessibilityIdentifier("patterns.nlpar.lambda")
            }
            InspectorNote("λ is chosen from the scan's noise (opt_lambda, the median of three). NLPAR needs the neighbours, so it shows on the pattern once Process has run.")
        }
    }

    private var staticSection: some View {
        let s = status(.staticBackground)
        return InspectorSection("Static background", status: s.word, statusGlyph: s.glyph) {
            SegmentedPicker(label: "Pattern", items: EBSDSession.PatternDisplay.allCases.map { d in
                (d, .title(d.title, help: d == .raw ? "The pattern as the file stores it" : "The pattern through the stages below, as they are set now"))
            }, selection: Binding(get: { session.patternDisplay }, set: { session.setPatternDisplay($0) }))
                .accessibilityIdentifier("patterns.display")
            InspectorRow("Remove") {
                Toggle("Remove the static background", isOn: Binding(get: { pipeline.staticStage.isOn }, set: { v in session.editPipeline { $0.staticStage.isOn = v } }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    .help("The detector's shading, the same in every pattern (kikuchipy remove_static_background)")
                    .accessibilityIdentifier("patterns.static.on")
            }
            InspectorRow("Source") {
                Picker("Source", selection: Binding(get: { pipeline.staticStage.source }, set: { v in session.editPipeline { $0.staticStage.source = v } })) {
                    ForEach(PatternPipeline.BackgroundSource.allCases) { source in
                        Text(source.title).tag(source).disabled(source == .file && dataset.staticBackground == nil)
                    }
                }
                .labelsHidden().fixedSize()
                .disabled(!pipeline.staticStage.isOn)
                .help(dataset.staticBackground == nil ? "The file carries no static background: the scan's mean pattern stands in"
                      : "The background the file carries, or the mean of every pattern in the scan")
                .accessibilityIdentifier("patterns.static.source")
            }
            SegmentedPicker(label: "Operation", items: PatternProcessing.Operation.allCases.map { ($0, .title($0.title)) },
                            selection: Binding(get: { pipeline.staticStage.operation }, set: { v in session.editPipeline { $0.staticStage.operation = v } }))
                .disabled(!pipeline.staticStage.isOn)
                .accessibilityIdentifier("patterns.static.operation")
            InspectorRow("Scale") {
                Toggle("Scale the background", isOn: Binding(get: { pipeline.staticStage.scaleBackground }, set: { v in session.editPipeline { $0.staticStage.scaleBackground = v } }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    .disabled(!pipeline.staticStage.isOn)
                    .help("Stretch the background to each pattern's own range first (kikuchipy scale_bg)")
                    .accessibilityIdentifier("patterns.static.scale")
            }
            if let failure = session.previewFailure {
                InspectorNote(failure).accessibilityIdentifier("patterns.processing.previewFailure")
            }
            refusalNote(.staticBackground)
            InspectorNote(dataset.staticBackground == nil ? "This file carries no static background; the scan's mean pattern is used."
                          : "The file carries its static background.")
        }
    }

    private var dynamicSection: some View {
        let s = status(.dynamicBackground)
        let defaultStd = Double(dataset.patternColumns) / 8
        return InspectorSection("Dynamic background", status: s.word, statusGlyph: s.glyph, startsExpanded: false) {
            InspectorRow("Remove") {
                Toggle("Remove the dynamic background", isOn: Binding(get: { pipeline.dynamicStage.isOn }, set: { v in session.editPipeline { $0.dynamicStage.isOn = v } }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    .help("Each pattern's own low-frequency intensity, a Gaussian blur of it (kikuchipy remove_dynamic_background)")
                    .accessibilityIdentifier("patterns.dynamic.on")
            }
            SegmentedPicker(label: "Filter", items: PatternProcessing.FilterDomain.allCases.map { d in
                (d, .title(d == .frequency ? "Gaussian" : "Spatial", help: d == .frequency ? "The FFT Gaussian filter (kikuchipy's default)" : "scipy.ndimage.gaussian_filter"))
            }, selection: Binding(get: { pipeline.dynamicStage.domain }, set: { v in session.editPipeline { $0.dynamicStage.domain = v } }))
                .disabled(!pipeline.dynamicStage.isOn)
                .accessibilityIdentifier("patterns.dynamic.filter")
            SegmentedPicker(label: "Operation", items: PatternProcessing.Operation.allCases.map { ($0, .title($0.title)) },
                            selection: Binding(get: { pipeline.dynamicStage.operation }, set: { v in session.editPipeline { $0.dynamicStage.operation = v } }))
                .disabled(!pipeline.dynamicStage.isOn)
                .accessibilityIdentifier("patterns.dynamic.operation")
            InspectorRow("Std") {
                OptionalNumericField(title: "Std", value: pipeline.dynamicStage.std, format: Self.number, unit: "px",
                                     prompt: UnitDisplay.number(defaultStd)) { v in session.editPipeline { $0.dynamicStage.std = v } }
                    .disabled(!pipeline.dynamicStage.isOn)
                    .help("The Gaussian's standard deviation; empty is kikuchipy's default, the pattern width / 8")
                    .accessibilityIdentifier("patterns.dynamic.std")
            }
            InspectorRow("Truncate") {
                OptionalNumericField(title: "Truncate", value: pipeline.dynamicStage.truncate, format: Self.number, unit: "std",
                                     prompt: "4") { v in session.editPipeline { $0.dynamicStage.truncate = v } }
                    .disabled(!pipeline.dynamicStage.isOn)
                    .help("The window's extent in standard deviations")
                    .accessibilityIdentifier("patterns.dynamic.truncate")
            }
            refusalNote(.dynamicBackground)
        }
    }

    private var intensitySection: some View {
        let s = status(.intensity)
        let mode = pipeline.intensity.mode
        return InspectorSection("Intensity", status: s.word, statusGlyph: s.glyph, startsExpanded: false) {
            SegmentedPicker(label: "Intensity", items: PatternPipeline.IntensityMode.allCases.map { m in
                (m, .title(m.title, help: m == .rescale ? "Stretch each pattern to the full grey range (kikuchipy rescale_intensity)"
                           : m == .normalize ? "Zero mean and unit standard deviation, as float32 (kikuchipy normalize_intensity)" : "Leave the intensities"))
            }, selection: Binding(get: { mode }, set: { v in session.editPipeline { $0.intensity.mode = v } }))
                .accessibilityIdentifier("patterns.intensity.mode")
            if mode == .rescale {
                InspectorRow("Percentiles") {
                    Toggle("Clip to percentiles", isOn: Binding(get: { pipeline.intensity.usesPercentiles }, set: { v in session.editPipeline { $0.intensity.usesPercentiles = v } }))
                        .labelsHidden().toggleStyle(.switch).controlSize(.small)
                        .help("Stretch between two percentiles of each pattern instead of its minimum and maximum, clipping beyond them")
                        .accessibilityIdentifier("patterns.intensity.percentiles")
                }
                if pipeline.intensity.usesPercentiles {
                    InspectorRow("Low") {
                        OptionalNumericField(title: "Low percentile", value: pipeline.intensity.lowPercentile, format: Self.number, unit: "%",
                                             prompt: "2") { v in session.editPipeline { $0.intensity.lowPercentile = v } }
                            .accessibilityIdentifier("patterns.intensity.low")
                    }
                    InspectorRow("High") {
                        OptionalNumericField(title: "High percentile", value: pipeline.intensity.highPercentile, format: Self.number, unit: "%",
                                             prompt: "98") { v in session.editPipeline { $0.intensity.highPercentile = v } }
                            .accessibilityIdentifier("patterns.intensity.high")
                    }
                }
            }
            if mode == .normalize {
                InspectorRow("Std") {
                    OptionalNumericField(title: "Standard deviations", value: pipeline.intensity.numStd, format: Self.number, unit: nil,
                                         prompt: "1") { v in session.editPipeline { $0.intensity.numStd = v } }
                        .help("The output's standard deviation in units of the pattern's own (kikuchipy num_std)")
                        .accessibilityIdentifier("patterns.intensity.numStd")
                }
                InspectorRow("÷ √n") {
                    Toggle("Divide by the square root of the pixel count", isOn: Binding(get: { pipeline.intensity.divideBySquareRoot },
                                                                                         set: { v in session.editPipeline { $0.intensity.divideBySquareRoot = v } }))
                        .labelsHidden().toggleStyle(.switch).controlSize(.small)
                        .help("Also divide by the square root of the pattern's pixel count (kikuchipy divide_by_square_root)")
                        .accessibilityIdentifier("patterns.intensity.sqrt")
                }
            }
            InspectorRow("Equalise") {
                Toggle("Equalise", isOn: Binding(get: { pipeline.intensity.equalize }, set: { v in session.editPipeline { $0.intensity.equalize = v } }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    .help("Contrast-limited adaptive histogram equalisation of each pattern (kikuchipy adaptive_histogram_equalization)")
                    .accessibilityIdentifier("patterns.intensity.equalize")
            }
            if pipeline.intensity.equalize {
                InspectorRow("Kernel") {
                    OptionalNumericField(title: "Equalisation kernel", value: pipeline.intensity.equalizeKernel.map(Double.init), format: Self.integer,
                                         unit: "px", prompt: "\(dataset.patternColumns / 4)") { v in
                        session.editPipeline { $0.intensity.equalizeKernel = max(1, Int(v.rounded())) }
                    }
                        .help("The side of each contextual region; empty is kikuchipy's default, a quarter of the pattern")
                        .accessibilityIdentifier("patterns.intensity.kernel")
                }
                InspectorRow("Clip limit") {
                    OptionalNumericField(title: "Clip limit", value: pipeline.intensity.clipLimit, format: Self.number, unit: nil,
                                         prompt: "0") { v in session.editPipeline { $0.intensity.clipLimit = v } }
                        .help("Limits the contrast each region may gain, 0 to 1; 0 limits nothing (scikit-image clip_limit)")
                        .accessibilityIdentifier("patterns.intensity.clipLimit")
                }
            }
            refusalNote(.intensity)
        }
    }

    private var sizeSection: some View {
        let s = status(.size)
        return InspectorSection("Size", status: s.word, statusGlyph: s.glyph, startsExpanded: false) {
            SegmentedPicker(label: "Bin", items: PatternPipeline.binnings.map { k in
                let fits = dataset.patternRows % k == 0 && dataset.patternColumns % k == 0
                return (k, .title("\(k)", help: k == 1 ? "No binning" : "Sum \(k) × \(k) pixels (kikuchipy downsample)",
                                  disabledReason: fits ? nil : "\(k) does not divide the \(dataset.patternRows) × \(dataset.patternColumns) px pattern"))
            }, selection: Binding(get: { pipeline.binning }, set: { v in session.editPipeline { $0.binning = v } }))
                .accessibilityIdentifier("patterns.size.bin")
            refusalNote(.size)
            if pipeline.binning > 1 {
                InspectorNote("Processed patterns are \(dataset.patternRows / pipeline.binning) × \(dataset.patternColumns / pipeline.binning) px; the detector's binning becomes \(dataset.detector.binning * pipeline.binning).")
            }
        }
    }
}
