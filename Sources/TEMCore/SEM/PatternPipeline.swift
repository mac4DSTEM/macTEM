//
//  PatternPipeline.swift
//  The Patterns room's processing pipeline (docs/sem/design/pattern-processing.md §3): the stages in kikuchipy's dependency order
//  — static background, dynamic background, intensity (rescale or normalise), size (bin) — as one Sendable value, applied to one
//  pattern (the live preview) or to every pattern of a scan (the room's verb `Process`, into memory). NLPAR (`NLPAR`, pyebsdindex
//  0.3.10.1) is the last stage and the only one over the whole scan at once: each pattern is averaged with its neighbours, so it
//  runs only in `process`, after the per-pattern stages, and its output is float32 as pyebsdindex's. Every number is
//  `PatternProcessing`'s, ported function by function from kikuchipy 0.13.1 and held by its parity tests; this file only chains
//  the stages and keeps their parameters in kikuchipy's names (`methodJSON`), so a user reproduces the run in Python.
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
        package init() {}
    }

    package var staticStage = StaticStage()
    package var dynamicStage = DynamicStage()
    package var intensity = IntensityStage()
    /// The binning factor (`EBSD.downsample`): 1, 2, 4 or 8.
    package var binning = 1

    /// NLPAR over the whole scan (Brewick, Wright and Rowenhorst 2019): λ from `opt_lambda` (the median of the three target weights).
    package struct NLPARStage: Sendable, Equatable, Codable {
        package var isOn = false
        package var searchRadius = NLPAR.defaultSearchRadius
        package init() {}
    }

    package var nlpar = NLPARStage()

    package static let binnings = [1, 2, 4, 8]

    package init() {}

    /// The room's default (design §6): the file's static background subtracted, then the Gaussian dynamic background at kikuchipy's
    /// defaults (std = width / 8, truncate 4); `Process` on the demo scan reproduces the north-star figure F2.
    package static let roomDefault = PatternPipeline()

    /// The pipeline's stages in dependency order, for the stage glyphs.
    package enum Stage: Int, Sendable, CaseIterable, Identifiable, Comparable {
        case staticBackground, dynamicBackground, intensity, size, nlpar
        package var id: Int { rawValue }
        package var title: String {
            switch self {
            case .staticBackground: "Static background"
            case .dynamicBackground: "Dynamic background"
            case .intensity: "Intensity"
            case .size: "Size"
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
        case .intensity: intensity.mode != .none
        case .size: binning > 1
        case .nlpar: nlpar.isOn
        }
    }

    /// The first stage whose settings differ between `self` and `other` (a change there stales it and every later stage), nil when equal.
    package func firstDifference(from other: PatternPipeline) -> Stage? {
        if staticStage != other.staticStage { return .staticBackground }
        if dynamicStage != other.dynamicStage { return .dynamicBackground }
        if intensity != other.intensity { return .intensity }
        if binning != other.binning { return .size }
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
            if dynamicStage.domain == .frequency, Int(dynamicStage.truncate * std) < 1 {
                return Refusal(.dynamicBackground, "Std × truncate is under one pixel: the Gaussian window would be empty.")
            }
        }
        if intensity.mode == .rescale, intensity.usesPercentiles {
            let low = intensity.lowPercentile, high = intensity.highPercentile
            guard low >= 0, high <= 100, low < high else { return Refusal(.intensity, "Percentiles run from 0 to 100, low below high.") }
        }
        if intensity.mode == .normalize, !(intensity.numStd.isFinite && intensity.numStd > 0) {
            return Refusal(.intensity, "Std must be positive.")
        }
        if binning > 1, dataset.patternRows % binning != 0 || dataset.patternColumns % binning != 0 {
            return Refusal(.size, "Bin \(binning) does not divide the \(dataset.patternRows) × \(dataset.patternColumns) px pattern.")
        }
        if nlpar.isOn {
            let window = 2 * nlpar.searchRadius + 1
            guard nlpar.searchRadius >= 1 else { return Refusal(.nlpar, "The search radius must be at least 1.") }
            guard window <= dataset.scanRows, window <= dataset.scanColumns else {
                return Refusal(.nlpar, "A search radius of \(nlpar.searchRadius) needs a scan of at least \(window) × \(window); this one is \(dataset.scanRows) × \(dataset.scanColumns).")
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
            var f = try PatternProcessing.normalizeIntensity(x.map { Double($0) }, numStd: intensity.numStd, divideBySquareRoot: intensity.divideBySquareRoot)
            if binning > 1 { f = try PatternProcessing.downsampleFloat(f, rows: rows, columns: columns, factor: binning) }
            return try Self.array(f, rows: outRows, columns: outColumns)
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

    /// Every pattern of the scan through the pipeline, row by row, into memory, then NLPAR over the result when it is on (`lambda` is
    /// told the λ it chose). `progress` gets the fraction done after each scan row (the rows are the first half when NLPAR follows);
    /// returns nil when `isCancelled` says so between rows.
    package func process(_ access: any EBSDPatternAccess, background: FormatoArray?,
                         progress: (Double) -> Void = { _ in }, isCancelled: () -> Bool = { false },
                         lambda: (Double) -> Void = { _ in }) throws -> EBSDMemoryPatterns? {
        let dataset = access.dataset
        if let problem = refusal(for: dataset, background: background) { throw problem }
        let out = processedDataset(dataset)
        let inSize = dataset.patternPixels * dataset.dataType.byteSize
        var bytes = Data()
        bytes.reserveCapacity(out.patternCount * out.patternPixels * out.dataType.byteSize)
        for row in 0..<dataset.scanRows {
            if isCancelled() { return nil }
            let slab = try access.row(row)
            for column in 0..<dataset.scanColumns {
                let one = try FormatoArray(dataType: dataset.dataType, shape: [dataset.patternRows, dataset.patternColumns],
                                           bytes: slab.bytes.subdata(in: (column * inSize)..<((column + 1) * inSize)))
                bytes.append(try apply(one, rows: dataset.patternRows, columns: dataset.patternColumns, background: background).bytes)
            }
            progress(Double(row + 1) / Double(dataset.scanRows) * (nlpar.isOn ? 0.5 : 1))
        }
        guard nlpar.isOn else { return try EBSDMemoryPatterns(dataset: out, bytes: bytes) }
        if isCancelled() { return nil }
        let perPattern: FormatoDataType = intensity.mode == .normalize ? .float32 : dataset.dataType
        let values = try FormatoArray(dataType: perPattern, shape: [bytes.count / perPattern.byteSize], bytes: bytes).doubles().map { Float($0) }
        let scan = try NLPAR.Scan(rows: out.scanRows, columns: out.scanColumns, patternRows: out.patternRows, patternColumns: out.patternColumns,
                                  values: values)
        let result = try NLPAR.run(scan, searchRadius: nlpar.searchRadius)
        lambda(result.lambda)
        progress(1)
        let denoised = try Self.array(result.denoised.values, rows: result.denoised.values.count, columns: 1)
        return try EBSDMemoryPatterns(dataset: out, bytes: denoised.bytes)
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
        if binning > 1 { steps.append(["method": "EBSD.downsample", "factor": binning]) }
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
