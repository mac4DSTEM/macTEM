//
//  PatternPipeline.swift
//  The Patterns room's processing pipeline (docs/sem/design/pattern-processing.md §3): the stages in kikuchipy's dependency order
//  — static background, dynamic background, intensity (rescale or normalise, then adaptive histogram equalisation), FFT filter,
//  size (bin) — as one Sendable value, applied to one pattern (the live preview) or to every pattern of a scan (the room's verb
//  `Process`, into memory). Two stages work on the whole scan at once, so they run only in `process`, after the per-pattern
//  stages: neighbour averaging (kikuchipy's `average_neighbour_patterns`) and, last, NLPAR (`NLPAR`, pyebsdindex 0.3.10.1), whose
//  output is float32 as pyebsdindex's. Every number is `PatternProcessing`'s, `AdaptiveHistogramEqualization`'s,
//  `PatternFilters`'s and `NeighbourAveraging`'s, ported function by function from kikuchipy 0.13.1 and held by their parity
//  tests; this file only chains the stages and keeps their parameters in kikuchipy's names (`methodJSON`), so a user reproduces
//  the run in Python.
//
//  Pattern types: unsigned 8 and 16 bit (every EBSD reader's); normalisation makes float32, as kikuchipy's
//  `change_dtype("float32")` then `normalize_intensity` does. Binning a float32 pattern rescales it to [-1, 1], float32's
//  `dtype_range`, as `EBSD.downsample` does.
//

import Foundation
import FormatoCore

package nonisolated struct PatternPipeline: Sendable, Equatable, Codable {

    /// Where the static background comes from: the one the file carries, or the mean of every pattern in the scan.
    package enum BackgroundSource: String, Sendable, Codable, CaseIterable, Identifiable {
        case file, mean
        package var id: String { rawValue }
        package var title: String {
            switch self {
            case .file: "The file's"
            case .mean: "The scan's mean"
            }
        }
    }

    package struct StaticStage: Sendable, Equatable, Codable {
        package var isOn = true
        package var source = BackgroundSource.file
        package var operation = PatternProcessing.Operation.subtract
        package var scaleBackground = false
        package init() {}
    }

    package struct DynamicStage: Sendable, Equatable, Codable {
        package var isOn = true
        package var domain = PatternProcessing.FilterDomain.frequency
        package var operation = PatternProcessing.Operation.subtract
        /// The Gaussian's standard deviation in pixels; nil is kikuchipy's default, the pattern width / 8.
        package var std: Double?
        package var truncate = 4.0
        package init() {}
    }

    package enum IntensityMode: String, Sendable, Codable, CaseIterable, Identifiable {
        case none, rescale, normalize
        package var id: String { rawValue }
        package var title: String {
            switch self {
            case .none: "Off"
            case .rescale: "Rescale"
            case .normalize: "Normalise"
            }
        }
    }

    package struct IntensityStage: Sendable, Equatable, Codable {
        package var mode = IntensityMode.none
        /// Rescale: stretch between these percentiles (clipping beyond them) instead of the minimum and maximum.
        package var usesPercentiles = false
        package var lowPercentile = 2.0
        package var highPercentile = 98.0
        /// Normalise: kikuchipy's `num_std` and `divide_by_square_root`.
        package var numStd = 1.0
        package var divideBySquareRoot = false
        /// Equalise: kikuchipy's `adaptive_histogram_equalization` (CLAHE, scikit-image's `equalize_adapthist`) after the rescale.
        package var equalize = false
        /// The square contextual region in pixels; nil is kikuchipy's default, a quarter of the pattern.
        package var equalizeKernel: Int?
        /// scikit-image's normalised clip limit; 0 clips nothing (kikuchipy's default).
        package var clipLimit = 0.0
        package init() {}
    }

    /// kikuchipy's `adaptive_histogram_equalization` histogram bins (`nbins`).
    package static let equalizeBins = 128

    /// Which frequencies the FFT filter keeps: the guide's Gaussian-edged `lowpass` and `highpass` transfer functions, or their product.
    package enum FFTPass: String, Sendable, Codable, CaseIterable, Identifiable {
        case low, high, band
        package var id: String { rawValue }
        package var title: String {
            switch self {
            case .low: "Low"
            case .high: "High"
            case .band: "Band"
            }
        }
    }

    /// kikuchipy's `EBSD.fft_filter` in the frequency domain with `shift=True`, the transfer function the pattern's shape. The defaults
    /// are kikuchipy's pattern-processing guide (lowpass cutoff 22, width 10; highpass cutoff 3, width 2), north-star figure F4.
    package struct FFTFilterStage: Sendable, Equatable, Codable {
        package var isOn = false
        package var pass = FFTPass.band
        /// Lowpass: frequencies within `lowCutoff` pixels of the centre are kept, rolling off over `lowWidth`.
        package var lowCutoff = 22.0
        package var lowWidth = 10.0
        /// Highpass: frequencies beyond `highCutoff` are kept, rolling off over `highWidth` inside it.
        package var highCutoff = 3.0
        package var highWidth = 2.0
        package init() {}

        package var usesLowpass: Bool { pass != .high }
        package var usesHighpass: Bool { pass != .low }

        /// The transfer function for a rows × columns pattern.
        package func transferFunction(rows: Int, columns: Int) throws -> PatternWindow {
            switch pass {
            case .low: return try PatternWindow.lowpass(rows: rows, columns: columns, cutoff: lowCutoff, cutoffWidth: lowWidth)
            case .high: return try PatternWindow.highpass(rows: rows, columns: columns, cutoff: highCutoff, cutoffWidth: highWidth)
            case .band:
                return try PatternWindow.lowpass(rows: rows, columns: columns, cutoff: lowCutoff, cutoffWidth: lowWidth)
                    * PatternWindow.highpass(rows: rows, columns: columns, cutoff: highCutoff, cutoffWidth: highWidth)
            }
        }

        /// The transfer function as kikuchipy builds it, for the method JSON.
        func python(rows: Int, columns: Int) -> String {
            let low = "Window('lowpass', cutoff=\(lowCutoff), cutoff_width=\(lowWidth), shape=(\(rows), \(columns)))"
            let high = "Window('highpass', cutoff=\(highCutoff), cutoff_width=\(highWidth), shape=(\(rows), \(columns)))"
            switch pass {
            case .low: return low
            case .high: return high
            case .band: return low + " * " + high
            }
        }
    }

    /// The window of neighbour averaging: kikuchipy's default 3 × 3 circular window, the 5 × 5 circular one, or a 3 × 3 Gaussian (std 1).
    package enum AveragingWindow: String, Sendable, Codable, CaseIterable, Identifiable {
        case circular3, circular5, gaussian3
        package var id: String { rawValue }
        package var title: String {
            switch self {
            case .circular3: "3 × 3"
            case .circular5: "5 × 5"
            case .gaussian3: "Gaussian"
            }
        }
        package var size: Int { self == .circular5 ? 5 : 3 }
        package var kikuchipyName: String { self == .gaussian3 ? "gaussian" : "circular" }
        package func window() throws -> PatternWindow {
            switch self {
            case .circular3, .circular5: return try PatternWindow.circular(rows: size, columns: size)
            case .gaussian3: return try PatternWindow.gaussian(rows: 3, columns: 3, std: 1)
            }
        }
    }

    /// Neighbour pattern averaging over the scan (Wright et al. 2015): kikuchipy's `average_neighbour_patterns`.
    package struct AveragingStage: Sendable, Equatable, Codable {
        package var isOn = false
        package var window = AveragingWindow.circular3
        package init() {}
    }

    package var staticStage = StaticStage()
    package var dynamicStage = DynamicStage()
    package var intensity = IntensityStage()
    package var fftFilter = FFTFilterStage()
    /// The binning factor (`EBSD.downsample`): 1, 2, 4 or 8.
    package var binning = 1

    /// NLPAR over the whole scan (Brewick, Wright and Rowenhorst 2019): λ from `opt_lambda` (the median of the three target weights).
    package struct NLPARStage: Sendable, Equatable, Codable {
        package var isOn = false
        package var searchRadius = NLPAR.defaultSearchRadius
        package init() {}
    }

    package var averaging = AveragingStage()
    package var nlpar = NLPARStage()

    package static let binnings = [1, 2, 4, 8]

    package init() {}

    /// The room's default (design §6): the file's static background subtracted, then the Gaussian dynamic background at kikuchipy's
    /// defaults (std = width / 8, truncate 4); `Process` on the demo scan reproduces the north-star figure F2.
    package static let roomDefault = PatternPipeline()

    /// The pipeline's stages in dependency order, for the stage glyphs.
    package enum Stage: Int, Sendable, CaseIterable, Identifiable, Comparable {
        case staticBackground, dynamicBackground, intensity, fftFilter, size, averaging, nlpar
        package var id: Int { rawValue }
        package var title: String {
            switch self {
            case .staticBackground: "Static background"
            case .dynamicBackground: "Dynamic background"
            case .intensity: "Intensity"
            case .fftFilter: "FFT filter"
            case .size: "Size"
            case .averaging: "Average neighbours"
            case .nlpar: "NLPAR"
            }
        }
        package static func < (a: Stage, b: Stage) -> Bool { a.rawValue < b.rawValue }
    }

    /// Whether `stage` changes the pattern at all with these settings.
    package func isActive(_ stage: Stage) -> Bool {
        switch stage {
        case .staticBackground: staticStage.isOn
        case .dynamicBackground: dynamicStage.isOn
        case .intensity: intensity.mode != .none || intensity.equalize
        case .fftFilter: fftFilter.isOn
        case .size: binning > 1
        case .averaging: averaging.isOn
        case .nlpar: nlpar.isOn
        }
    }

    /// The first stage whose settings differ between `self` and `other` (a change there stales it and every later stage), nil when equal.
    package func firstDifference(from other: PatternPipeline) -> Stage? {
        if staticStage != other.staticStage { return .staticBackground }
        if dynamicStage != other.dynamicStage { return .dynamicBackground }
        if intensity != other.intensity { return .intensity }
        if fftFilter != other.fftFilter { return .fftFilter }
        if binning != other.binning { return .size }
        if averaging != other.averaging { return .averaging }
        if nlpar != other.nlpar { return .nlpar }
        return nil
    }

    // MARK: - Refusals

    /// Why a pipeline cannot run, in the room's words (shown under the stage's rows and in Output).
    package struct Refusal: Error, Equatable, Sendable, LocalizedError {
        package let stage: Stage
        package let sentence: String
        package init(_ stage: Stage, _ sentence: String) {
            self.stage = stage; self.sentence = sentence
        }
        package var errorDescription: String? { sentence }
    }

    /// The first refusal for a scan of `dataset` with `background` as the static background (nil: none known yet), else nil.
    package func refusal(for dataset: EBSDDataset, background: FormatoArray?) -> Refusal? {
        guard dataset.dataType == .uint8 || dataset.dataType == .uint16 else {
            return Refusal(.staticBackground, "Processing reads 8 and 16 bit unsigned patterns; these are \(dataset.dataType.rawValue).")
        }
        if staticStage.isOn {
            guard let background else {
                return Refusal(.staticBackground, staticStage.source == .file
                               ? "The file carries no static background. Choose the scan's mean." : "The scan's mean is not computed yet.")
            }
            let shape = background.shape
            guard shape.count == 2, shape[0] == dataset.patternRows, shape[1] == dataset.patternColumns, background.dataType == dataset.dataType else {
                let size = shape.map(String.init).joined(separator: " × ")
                return Refusal(.staticBackground, "Static background is \(size) \(background.dataType.rawValue), the patterns are \(dataset.patternRows) × \(dataset.patternColumns) \(dataset.dataType.rawValue).")
            }
        }
        if dynamicStage.isOn {
            if let std = dynamicStage.std, !(std.isFinite && std > 0) { return Refusal(.dynamicBackground, "Std must be a positive number of pixels.") }
            guard dynamicStage.truncate.isFinite, dynamicStage.truncate > 0 else { return Refusal(.dynamicBackground, "Truncate must be positive.") }
            let std = dynamicStage.std ?? Double(dataset.patternColumns) / 8
            // The window's width compared in Double, as `PatternProcessing.gaussianWindow` bounds it: `Int()` of a typed 1e300 traps.
            let width = dynamicStage.truncate * std
            if dynamicStage.domain == .frequency, width < 1 {
                return Refusal(.dynamicBackground, "Std × truncate is under one pixel: the Gaussian window would be empty.")
            }
            if dynamicStage.domain == .frequency, width > Double(PatternProcessing.maximumWindow) {
                return Refusal(.dynamicBackground, "Std × truncate is over \(PatternProcessing.maximumWindow) px: the Gaussian window would be far wider than any pattern.")
            }
        }
        if intensity.mode == .rescale, intensity.usesPercentiles {
            let low = intensity.lowPercentile, high = intensity.highPercentile
            guard low >= 0, high <= 100, low < high else { return Refusal(.intensity, "Percentiles run from 0 to 100, low below high.") }
        }
        if intensity.mode == .normalize, !(intensity.numStd.isFinite && intensity.numStd > 0) {
            return Refusal(.intensity, "Std must be positive.")
        }
        if intensity.equalize {
            if intensity.mode == .normalize {
                return Refusal(.intensity, "Equalise reads 8 and 16 bit patterns; Normalise makes them float32. Rescale or leave the intensities instead.")
            }
            if let k = intensity.equalizeKernel, k < 1 { return Refusal(.intensity, "The equalisation kernel must be at least 1 px.") }
            // CLAHE pads the pattern by about the kernel on each side, (rows + 2k) × (columns + 2k) values, so a typed 100000 would ask
            // for (2 × 100000)² of them. scikit-image sets no limit: every kernel up to the pattern's side runs, and so does a larger one
            // whose padding holds at most 2²⁴ values (128 MB of Int); only a kernel past both is refused.
            if let k = intensity.equalizeKernel, k > max(dataset.patternRows, dataset.patternColumns) {
                let padded = (Double(dataset.patternRows) + 2 * Double(k)) * (Double(dataset.patternColumns) + 2 * Double(k))
                if padded > Double(1 << 24) {
                    return Refusal(.intensity, "The equalisation kernel of \(k) px is far larger than the \(dataset.patternRows) × \(dataset.patternColumns) px pattern.")
                }
            }
            guard intensity.clipLimit.isFinite, intensity.clipLimit >= 0 else { return Refusal(.intensity, "The clip limit must be 0 or more.") }
        }
        if fftFilter.isOn {
            if intensity.mode == .normalize {
                return Refusal(.fftFilter, "The FFT filter reads 8 and 16 bit patterns; Normalise makes them float32. Rescale or leave the intensities instead.")
            }
            if fftFilter.usesLowpass {
                guard fftFilter.lowCutoff.isFinite, fftFilter.lowCutoff > 0, fftFilter.lowWidth.isFinite, fftFilter.lowWidth > 0 else {
                    return Refusal(.fftFilter, "The lowpass cutoff and width must be positive.")
                }
            }
            if fftFilter.usesHighpass {
                guard fftFilter.highCutoff.isFinite, fftFilter.highCutoff > 0, fftFilter.highWidth.isFinite, fftFilter.highWidth > 0 else {
                    return Refusal(.fftFilter, "The highpass cutoff and width must be positive.")
                }
            }
            if fftFilter.pass == .band, fftFilter.highCutoff >= fftFilter.lowCutoff {
                return Refusal(.fftFilter, "Band keeps the frequencies between the highpass and lowpass cutoffs: the highpass cutoff must be the lower.")
            }
        }
        if binning > 1, dataset.patternRows % binning != 0 || dataset.patternColumns % binning != 0 {
            return Refusal(.size, "Bin \(binning) does not divide the \(dataset.patternRows) × \(dataset.patternColumns) px pattern.")
        }
        if averaging.isOn, intensity.mode == .normalize {
            return Refusal(.averaging, "Average neighbours reads 8 and 16 bit patterns; Normalise makes them float32. Rescale or leave the intensities instead.")
        }
        if nlpar.isOn {
            let radius = nlpar.searchRadius
            guard radius >= 1 else { return Refusal(.nlpar, "The search radius must be at least 1.") }
            // The radius is held against the scan before the window 2 r + 1 is formed, so no typed radius overflows it.
            guard radius <= (min(dataset.scanRows, dataset.scanColumns) - 1) / 2 else {
                let scan = "this one is \(dataset.scanRows) × \(dataset.scanColumns)."
                guard radius <= Int.max / 2 else { return Refusal(.nlpar, "A search radius of \(radius) is wider than any scan; " + scan) }
                let window = 2 * radius + 1
                return Refusal(.nlpar, "A search radius of \(radius) needs a scan of at least \(window) × \(window); " + scan)
            }
        }
        return nil
    }

    // MARK: - One pattern

    /// The pattern's type after the pipeline.
    package func outputType(_ input: FormatoDataType) -> FormatoDataType { intensity.mode == .normalize || nlpar.isOn ? .float32 : input }

    /// One pattern (shape rows × columns, uint8 or uint16) through every active per-pattern stage; the result's shape is binned.
    /// NLPAR needs the neighbours, so it is not applied here (`process` runs it).
    package func apply(_ pattern: FormatoArray, rows: Int, columns: Int, background: FormatoArray?) throws -> FormatoArray {
        switch pattern.dataType {
        case .uint8:
            return try run(Self.unsigned(pattern, as: UInt8.self), background: background.map { Self.unsigned($0, as: UInt8.self) },
                           rows: rows, columns: columns, type: .uint8)
        case .uint16:
            return try run(Self.unsigned(pattern, as: UInt16.self), background: background.map { Self.unsigned($0, as: UInt16.self) },
                           rows: rows, columns: columns, type: .uint16)
        default:
            throw Refusal(.staticBackground, "Processing reads 8 and 16 bit unsigned patterns; this one is \(pattern.dataType.rawValue).")
        }
    }

    private func run<P: FixedWidthInteger & UnsignedInteger>(_ pattern: [P], background: [P]?, rows: Int, columns: Int,
                                                             type: FormatoDataType) throws -> FormatoArray {
        var x = pattern
        if staticStage.isOn {
            guard let background else { throw Refusal(.staticBackground, "No static background to remove.") }
            x = try PatternProcessing.removeStaticBackground(x, background: background, operation: staticStage.operation,
                                                             scaleBackground: staticStage.scaleBackground)
        }
        if dynamicStage.isOn {
            x = try PatternProcessing.removeDynamicBackground(x, rows: rows, columns: columns, operation: dynamicStage.operation,
                                                              domain: dynamicStage.domain, std: dynamicStage.std, truncate: dynamicStage.truncate)
        }
        let outRows = rows / binning, outColumns = columns / binning
        switch intensity.mode {
        case .none:
            break
        case .rescale:
            x = try PatternProcessing.rescaleIntensity(x, percentiles: intensity.usesPercentiles ? (intensity.lowPercentile, intensity.highPercentile) : nil)
        case .normalize:
            guard !intensity.equalize, !fftFilter.isOn else {
                throw Refusal(intensity.equalize ? .intensity : .fftFilter, "Equalise and the FFT filter read 8 and 16 bit patterns; Normalise makes them float32.")
            }
            var f = try PatternProcessing.normalizeIntensity(x.map { Double($0) }, numStd: intensity.numStd, divideBySquareRoot: intensity.divideBySquareRoot)
            if binning > 1 { f = try PatternProcessing.downsampleFloat(f, rows: rows, columns: columns, factor: binning) }
            return try Self.array(f, rows: outRows, columns: outColumns)
        }
        if intensity.equalize {
            do {
                x = try AdaptiveHistogramEqualization.equalize(x, rows: rows, columns: columns, kernel: intensity.equalizeKernel.map { ($0, $0) },
                                                               clipLimit: intensity.clipLimit, bins: Self.equalizeBins)
            } catch {
                throw Refusal(.intensity, "This pattern is flat after equalisation, so it cannot be rescaled.")
            }
        }
        if fftFilter.isOn {
            let h: PatternWindow
            do {
                h = try fftFilter.transferFunction(rows: rows, columns: columns)
            } catch {
                throw Refusal(.fftFilter, "The cutoffs and widths must be positive.")
            }
            do {
                x = try PatternFilters.fftFilter(x, rows: rows, columns: columns, domain: .frequency, filter: h, shift: true)
            } catch {
                throw Refusal(.fftFilter, "This pattern is flat after the FFT filter, so it cannot be rescaled.")
            }
        }
        if binning > 1 { x = try PatternProcessing.downsample(x, rows: rows, columns: columns, factor: binning) }
        return try Self.array(x, type: type, rows: outRows, columns: outColumns)
    }

    // MARK: - The whole scan

    /// The dataset of the processed patterns: the binned pattern shape and detector (`detector.binning *= factor`), the output type,
    /// the static background binned as kikuchipy's `downsample` bins it.
    package func processedDataset(_ dataset: EBSDDataset) -> EBSDDataset {
        var out = dataset
        out.patternRows = dataset.patternRows / binning
        out.patternColumns = dataset.patternColumns / binning
        out.dataType = outputType(dataset.dataType)
        if binning > 1 {
            out.detector.rows = dataset.detector.rows / binning
            out.detector.columns = dataset.detector.columns / binning
            out.detector.binning = dataset.detector.binning * binning
            if let bg = dataset.staticBackground {
                out.staticBackground = try? Self.binned(bg, rows: dataset.patternRows, columns: dataset.patternColumns, factor: binning)
            }
        }
        return out
    }

    /// Every pattern of the scan through the pipeline, row by row, into memory, then neighbour averaging and NLPAR over the result when
    /// they are on (`lambda` is told the λ NLPAR chose). `progress` gets the fraction done after each scan row (the rows are the first
    /// half when a whole-scan stage follows, averaging the third quarter when NLPAR follows it); returns nil when `isCancelled` says so
    /// between rows. Where it can, the scan is held once: averaging lets its input bytes go before it writes its output, NLPAR takes
    /// the per-pattern output as float32 and the bytes go, and each result is written out in one copy.
    package func process(_ access: any EBSDPatternAccess, background: FormatoArray?,
                         progress: (Double) -> Void = { _ in }, isCancelled: () -> Bool = { false },
                         lambda: (Double) -> Void = { _ in }) throws -> EBSDMemoryPatterns? {
        let dataset = access.dataset
        if let problem = refusal(for: dataset, background: background) { throw problem }
        let out = processedDataset(dataset)
        let inSize = dataset.patternPixels * dataset.dataType.byteSize
        // The per-pattern stages' type: NLPAR's float32 comes after them, so until then the scan is held at this size.
        let perPattern: FormatoDataType = intensity.mode == .normalize ? .float32 : dataset.dataType
        var bytes = Data()
        bytes.reserveCapacity(out.patternCount * out.patternPixels * perPattern.byteSize)
        for row in 0..<dataset.scanRows {
            if isCancelled() { return nil }
            let slab = try access.row(row)
            for column in 0..<dataset.scanColumns {
                let one = try FormatoArray(dataType: dataset.dataType, shape: [dataset.patternRows, dataset.patternColumns],
                                           bytes: slab.bytes.subdata(in: (column * inSize)..<((column + 1) * inSize)))
                bytes.append(try apply(one, rows: dataset.patternRows, columns: dataset.patternColumns, background: background).bytes)
            }
            progress(Double(row + 1) / Double(dataset.scanRows) * (nlpar.isOn || averaging.isOn ? 0.5 : 1))
        }
        if averaging.isOn {
            if isCancelled() { return nil }
            try averageNeighbours(&bytes, dataset: out, type: dataset.dataType)
            progress(nlpar.isOn ? 0.75 : 1)
        }
        guard nlpar.isOn else { return try EBSDMemoryPatterns(dataset: out, bytes: bytes) }
        if isCancelled() { return nil }
        // Straight to float32 (exact for the per-pattern types, so NLPAR's input is unchanged), then the bytes go: NLPAR's scan is
        // the only copy it starts from.
        let scan = try NLPAR.Scan(rows: out.scanRows, columns: out.scanColumns, patternRows: out.patternRows, patternColumns: out.patternColumns,
                                  values: Self.floats(bytes, type: perPattern))
        bytes = Data()
        let result = try NLPAR.run(scan, searchRadius: nlpar.searchRadius)
        lambda(result.lambda)
        progress(1)
        return try EBSDMemoryPatterns(dataset: out, bytes: Self.littleEndianBytes(result.denoised.values))
    }

    /// The per-pattern output of the scan in `bytes` (`type`, uint8 or uint16, in `dataset`'s shapes; not `dataset.dataType`, which is
    /// float32 when NLPAR follows) replaced by itself averaged with its neighbours.
    private func averageNeighbours(_ bytes: inout Data, dataset: EBSDDataset, type: FormatoDataType) throws {
        let window = try averaging.window.window()
        switch type {
        case .uint8: try Self.averagePatterns(&bytes, as: UInt8.self, type: type, dataset: dataset, window: window)
        case .uint16: try Self.averagePatterns(&bytes, as: UInt16.self, type: type, dataset: dataset, window: window)
        default: throw Refusal(.averaging, "Average neighbours reads 8 and 16 bit patterns; these are \(type.rawValue).")
        }
    }

    /// `averageNeighbours` for one pattern type: the values are read out and `bytes` let go before the averaged patterns are written
    /// into their own buffer, so the scan is held twice at most, never beside a float64 copy.
    private static func averagePatterns<P: FixedWidthInteger & UnsignedInteger>(_ bytes: inout Data, as _: P.Type, type: FormatoDataType,
                                                                                dataset: EBSDDataset, window: PatternWindow) throws {
        let values = try unsigned(FormatoArray(dataType: type, shape: [bytes.count / type.byteSize], bytes: bytes), as: P.self)
        bytes = Data()
        var out = [P](repeating: 0, count: values.count)
        do {
            try NeighbourAveraging.average(values, scanRows: dataset.scanRows, scanColumns: dataset.scanColumns, pixels: dataset.patternPixels,
                                           window: window, into: &out)
        } catch {
            throw Refusal(.averaging, "An averaged pattern is flat, so it cannot be rescaled.")
        }
        bytes = littleEndianBytes(out)
    }

    /// The mean of every pattern of the scan cast to the pattern type by truncation (`PatternProcessing.meanBackground`'s numbers, summed
    /// row by row in map order): the static background of a file that carries none. nil when cancelled.
    package static func meanBackground(_ access: any EBSDPatternAccess, progress: (Double) -> Void = { _ in },
                                       isCancelled: () -> Bool = { false }) throws -> FormatoArray? {
        let dataset = access.dataset
        let pixels = dataset.patternPixels
        guard dataset.patternCount >= 1, pixels >= 1 else { throw PatternProcessing.Error.shape }
        guard dataset.dataType == .uint8 || dataset.dataType == .uint16 else {
            throw Refusal(.staticBackground, "Processing reads 8 and 16 bit unsigned patterns; these are \(dataset.dataType.rawValue).")
        }
        var sum = [Double](repeating: 0, count: pixels)
        for row in 0..<dataset.scanRows {
            if isCancelled() { return nil }
            let values = try access.row(row).doubles()
            for column in 0..<dataset.scanColumns {
                let base = column * pixels
                for j in 0..<pixels { sum[j] += values[base + j] }
            }
            progress(Double(row + 1) / Double(dataset.scanRows))
        }
        let n = Double(dataset.patternCount)
        let top = dataset.dataType == .uint8 ? 255.0 : 65535.0
        let mean = sum.map { min(max(($0 / n).rounded(.towardZero), 0), top) }
        if dataset.dataType == .uint8 {
            return try array(mean.map { UInt8($0) }, type: .uint8, rows: dataset.patternRows, columns: dataset.patternColumns)
        }
        return try array(mean.map { UInt16($0) }, type: .uint16, rows: dataset.patternRows, columns: dataset.patternColumns)
    }

    // MARK: - Method JSON

    /// Every active stage with its parameters in kikuchipy's names and call order, as JSON: what a user types to redo the run in Python.
    package func methodJSON(fileName: String, dataset: EBSDDataset) throws -> Data {
        var steps: [[String: Any]] = []
        if staticStage.isOn {
            steps.append(["method": "EBSD.remove_static_background",
                          "static_bg": staticStage.source == .file ? "the file's static_background" : "s.mean(axis=(0, 1)).data.astype(dtype)",
                          "operation": staticStage.operation.rawValue, "scale_bg": staticStage.scaleBackground])
        }
        if dynamicStage.isOn {
            var step: [String: Any] = ["method": "EBSD.remove_dynamic_background", "operation": dynamicStage.operation.rawValue,
                                       "filter_domain": dynamicStage.domain.rawValue, "truncate": dynamicStage.truncate]
            step["std"] = dynamicStage.std ?? NSNull()
            steps.append(step)
        }
        switch intensity.mode {
        case .none: break
        case .rescale:
            var step: [String: Any] = ["method": "EBSD.rescale_intensity"]
            step["percentiles"] = intensity.usesPercentiles ? [intensity.lowPercentile, intensity.highPercentile] : NSNull()
            steps.append(step)
        case .normalize:
            steps.append(["method": "EBSD.change_dtype", "dtype": "float32"])
            steps.append(["method": "EBSD.normalize_intensity", "num_std": intensity.numStd, "divide_by_square_root": intensity.divideBySquareRoot])
        }
        if intensity.equalize {
            var step: [String: Any] = ["method": "EBSD.adaptive_histogram_equalization", "clip_limit": intensity.clipLimit, "nbins": Self.equalizeBins]
            step["kernel_size"] = intensity.equalizeKernel.map { [$0, $0] } ?? NSNull()
            steps.append(step)
        }
        if fftFilter.isOn {
            steps.append(["method": "EBSD.fft_filter", "function_domain": "frequency", "shift": true,
                          "transfer_function": fftFilter.python(rows: dataset.patternRows, columns: dataset.patternColumns)])
        }
        if binning > 1 { steps.append(["method": "EBSD.downsample", "factor": binning]) }
        if averaging.isOn {
            var step: [String: Any] = ["method": "EBSD.average_neighbour_patterns", "window": averaging.window.kikuchipyName,
                                       "window_shape": [averaging.window.size, averaging.window.size]]
            if averaging.window == .gaussian3 { step["std"] = 1.0 }
            steps.append(step)
        }
        if nlpar.isOn {
            steps.append(["method": "pyebsdindex.nlpar.NLPAR", "searchradius": nlpar.searchRadius, "lam": "opt_lambda() median",
                          "reference": "pyebsdindex 0.3.10.1"])
        }
        let root: [String: Any] = [
            "software": "macTEM", "reference": "kikuchipy 0.13.1", "file": fileName,
            "scan": [dataset.scanRows, dataset.scanColumns], "pattern": [dataset.patternRows, dataset.patternColumns],
            "dtype": dataset.dataType.rawValue, "steps": steps,
        ]
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }

    // MARK: - Pieces

    /// The values of a uint8 or uint16 array (little-endian bytes, as `FormatoArray` holds them).
    package static func unsigned<P: FixedWidthInteger & UnsignedInteger>(_ a: FormatoArray, as _: P.Type) -> [P] {
        let size = MemoryLayout<P>.size
        return a.bytes.withUnsafeBytes { raw in
            (0..<(raw.count / size)).map { P(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * size, as: P.self)) }
        }
    }

    static func array<P: FixedWidthInteger & UnsignedInteger>(_ values: [P], type: FormatoDataType, rows: Int, columns: Int) throws -> FormatoArray {
        var data = Data(capacity: values.count * MemoryLayout<P>.size)
        for v in values { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        return try FormatoArray(dataType: type, shape: [rows, columns], bytes: data)
    }

    /// uint8, uint16 or float32 values (little-endian bytes, as `FormatoArray` holds them) as float32: exact for the three types, so the
    /// numbers of `FormatoArray.doubles()` cast to `Float`, without a float64 array of the whole scan between.
    package static func floats(_ bytes: Data, type: FormatoDataType) throws -> [Float] {
        guard type == .uint8 || type == .uint16 || type == .float32 else {
            throw Refusal(.nlpar, "NLPAR reads 8 and 16 bit unsigned or float32 patterns; these are \(type.rawValue).")
        }
        let count = bytes.count / type.byteSize
        var out = [Float](repeating: 0, count: count)
        bytes.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            out.withUnsafeMutableBufferPointer { dst in
                if type == .uint8 {
                    for i in 0..<count { dst[i] = Float(raw.loadUnaligned(fromByteOffset: i, as: UInt8.self)) }
                } else if type == .uint16 {
                    for i in 0..<count { dst[i] = Float(UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: 2 * i, as: UInt16.self))) }
                } else {
                    for i in 0..<count { dst[i] = Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: 4 * i, as: UInt32.self))) }
                }
            }
        }
        return out
    }

    /// Integer or float values as `FormatoArray`'s little-endian bytes, in one copy: every Mac is little-endian, so the array's memory
    /// is those bytes (`array` writes the same bytes value by value).
    static func littleEndianBytes<T: Numeric>(_ values: [T]) -> Data {
        values.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    static func array(_ values: [Float], rows: Int, columns: Int) throws -> FormatoArray {
        var data = Data(capacity: values.count * 4)
        for v in values { withUnsafeBytes(of: v.bitPattern.littleEndian) { data.append(contentsOf: $0) } }
        return try FormatoArray(dataType: .float32, shape: [rows, columns], bytes: data)
    }

    /// A uint8 or uint16 background binned as `EBSD.downsample` bins the signal's `static_background`.
    static func binned(_ bg: FormatoArray, rows: Int, columns: Int, factor: Int) throws -> FormatoArray {
        switch bg.dataType {
        case .uint8:
            return try array(PatternProcessing.downsample(unsigned(bg, as: UInt8.self), rows: rows, columns: columns, factor: factor),
                             type: .uint8, rows: rows / factor, columns: columns / factor)
        case .uint16:
            return try array(PatternProcessing.downsample(unsigned(bg, as: UInt16.self), rows: rows, columns: columns, factor: factor),
                             type: .uint16, rows: rows / factor, columns: columns / factor)
        default:
            throw PatternProcessing.Error.shape
        }
    }
}
