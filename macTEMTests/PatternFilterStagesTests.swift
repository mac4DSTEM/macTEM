//
//  PatternFilterStagesTests.swift
//  The pattern filters in the Patterns room's pipeline (`PatternPipeline`, TEMCore; decision D-SEM-82): Equalise in the Intensity
//  stage, the FFT filter stage after it, and neighbour averaging over the scan after Size. On the nine-pattern h5ebsd fixture each
//  stage is its ported function (`AdaptiveHistogramEqualization.equalize`, `PatternFilters.fftFilter`, `NeighbourAveraging.average`,
//  each held to kikuchipy by `SEMPatternFilterParityTests`) applied to the previous stage's output, bit for bit; the stages stale in
//  the design's order, refuse Normalise's float32, and the method JSON names them as kikuchipy does.
//  Red before the change: no `fftFilter`, `averaging` or `intensity.equalize` on the pipeline. Red after a stage is skipped or
//  reordered: the patterns move.
//

import XCTest
import FormatoCore
import TEMCore

nonisolated final class PatternFilterStagesTests: XCTestCase {
    private func opened() throws -> (EBSDDataset, EBSDPatternReader) {
        let ref = try SEMParityReference.load("m2/intensity-kikuchipy-h5ebsd")
        let url = try XCTUnwrap(ref.inputURL(0))
        let (dataset, reader) = try EBSDOpening.open(url: url)
        return (dataset, reader)
    }

    private func firstPattern(_ dataset: EBSDDataset, _ reader: EBSDPatternReader) throws -> FormatoArray {
        let n = dataset.patternPixels * dataset.dataType.byteSize
        return try FormatoArray(dataType: dataset.dataType, shape: [dataset.patternRows, dataset.patternColumns],
                                bytes: try reader.row(0).bytes.subdata(in: 0..<n))
    }

    func testEqualiseThenTheFFTFilterRunOnTheBackgroundCorrectedPattern() throws {
        let (dataset, reader) = try opened()
        let rows = dataset.patternRows, columns = dataset.patternColumns
        let raw = try firstPattern(dataset, reader)
        let background = dataset.staticBackground
        let corrected = PatternPipeline.unsigned(try PatternPipeline.roomDefault.apply(raw, rows: rows, columns: columns, background: background),
                                                 as: UInt8.self)

        var equalise = PatternPipeline.roomDefault
        equalise.intensity.equalize = true
        equalise.intensity.equalizeKernel = 10
        equalise.intensity.clipLimit = 0.01
        let equalised = try AdaptiveHistogramEqualization.equalize(corrected, rows: rows, columns: columns, kernel: (10, 10), clipLimit: 0.01, bins: 128)
        XCTAssertEqual(PatternPipeline.unsigned(try equalise.apply(raw, rows: rows, columns: columns, background: background), as: UInt8.self), equalised)

        var both = equalise
        both.fftFilter.isOn = true
        let h = try PatternWindow.lowpass(rows: rows, columns: columns, cutoff: 22, cutoffWidth: 10)
            * PatternWindow.highpass(rows: rows, columns: columns, cutoff: 3, cutoffWidth: 2)
        XCTAssertEqual(try both.fftFilter.transferFunction(rows: rows, columns: columns).values, h.values)
        let filtered = try PatternFilters.fftFilter(equalised, rows: rows, columns: columns, domain: .frequency, filter: h, shift: true)
        let out = try both.apply(raw, rows: rows, columns: columns, background: background)
        XCTAssertEqual(out.dataType, .uint8)
        XCTAssertEqual(PatternPipeline.unsigned(out, as: UInt8.self), filtered)

        // The filter runs at full resolution, before Size bins the pattern.
        var binned = both
        binned.binning = 2
        let small = try binned.apply(raw, rows: rows, columns: columns, background: background)
        XCTAssertEqual(small.shape, [rows / 2, columns / 2])
        XCTAssertEqual(PatternPipeline.unsigned(small, as: UInt8.self), try PatternProcessing.downsample(filtered, rows: rows, columns: columns, factor: 2))

        // Low and High alone are the guide's lowpass and highpass.
        var low = PatternPipeline()
        low.staticStage.isOn = false; low.dynamicStage.isOn = false
        low.fftFilter.isOn = true; low.fftFilter.pass = .low
        let rawValues = PatternPipeline.unsigned(raw, as: UInt8.self)
        XCTAssertEqual(PatternPipeline.unsigned(try low.apply(raw, rows: rows, columns: columns, background: nil), as: UInt8.self),
                       try PatternFilters.fftFilter(rawValues, rows: rows, columns: columns, domain: .frequency,
                                                    filter: PatternWindow.lowpass(rows: rows, columns: columns, cutoff: 22, cutoffWidth: 10), shift: true))
        var high = low
        high.fftFilter.pass = .high
        XCTAssertEqual(PatternPipeline.unsigned(try high.apply(raw, rows: rows, columns: columns, background: nil), as: UInt8.self),
                       try PatternFilters.fftFilter(rawValues, rows: rows, columns: columns, domain: .frequency,
                                                    filter: PatternWindow.highpass(rows: rows, columns: columns, cutoff: 3, cutoffWidth: 2), shift: true))
    }

    func testAverageNeighboursRunsOverTheScanAfterThePerPatternStages() throws {
        let (dataset, reader) = try opened()
        let background = dataset.staticBackground
        let corrected = try XCTUnwrap(PatternPipeline.roomDefault.process(reader, background: background))
        let correctedValues = PatternPipeline.unsigned(try FormatoArray(dataType: .uint8, shape: [corrected.bytes.count], bytes: corrected.bytes), as: UInt8.self)
        for window in PatternPipeline.AveragingWindow.allCases {
            var p = PatternPipeline.roomDefault
            p.averaging.isOn = true
            p.averaging.window = window
            var fractions: [Double] = []
            let processed = try XCTUnwrap(p.process(reader, background: background, progress: { fractions.append($0) }))
            XCTAssertEqual(processed.dataset.dataType, .uint8)
            XCTAssertEqual(fractions.last, 1)
            XCTAssertEqual(fractions, fractions.sorted())
            let expected = try NeighbourAveraging.average(correctedValues, scanRows: dataset.scanRows, scanColumns: dataset.scanColumns,
                                                          pixels: dataset.patternPixels, window: window.window())
            XCTAssertEqual(PatternPipeline.unsigned(try FormatoArray(dataType: .uint8, shape: [processed.bytes.count], bytes: processed.bytes), as: UInt8.self),
                           expected, window.title)
        }
        XCTAssertEqual(try PatternPipeline.AveragingWindow.circular3.window().values, try PatternWindow.circular(rows: 3, columns: 3).values)
        XCTAssertEqual(try PatternPipeline.AveragingWindow.gaussian3.window().values, try PatternWindow.gaussian(rows: 3, columns: 3, std: 1).values)

        // Before NLPAR: NLPAR runs on the averaged scan, and averaging takes the third quarter of the progress.
        var both = PatternPipeline.roomDefault
        both.averaging.isOn = true
        both.nlpar.isOn = true; both.nlpar.searchRadius = 1
        var fractions: [Double] = []
        let processed = try XCTUnwrap(both.process(reader, background: background, progress: { fractions.append($0) }))
        XCTAssertTrue(fractions.contains(0.75), "\(fractions)")
        let averaged = try NeighbourAveraging.average(correctedValues, scanRows: 3, scanColumns: 3, pixels: dataset.patternPixels,
                                                      window: PatternWindow.circular(rows: 3, columns: 3))
        let scan = try NLPAR.Scan(rows: 3, columns: 3, patternRows: dataset.patternRows, patternColumns: dataset.patternColumns,
                                  values: averaged.map { Float($0) })
        XCTAssertEqual(try FormatoArray(dataType: .float32, shape: [processed.bytes.count / 4], bytes: processed.bytes).doubles().map { Float($0) },
                       try NLPAR.run(scan, searchRadius: 1).denoised.values)
    }

    func testTheFilterStagesStaleInTheDesignsOrderAndRefuseFloatPatterns() throws {
        let (dataset, _) = try opened()
        let background = dataset.staticBackground
        XCTAssertEqual(PatternPipeline.Stage.allCases,
                       [.staticBackground, .dynamicBackground, .intensity, .fftFilter, .size, .averaging, .nlpar])

        var p = PatternPipeline.roomDefault
        p.averaging.isOn = true
        XCTAssertEqual(p.firstDifference(from: .roomDefault), .averaging)
        XCTAssertTrue(p.isActive(.averaging))
        p.fftFilter.isOn = true
        XCTAssertEqual(p.firstDifference(from: .roomDefault), .fftFilter)
        p.intensity.equalize = true
        XCTAssertEqual(p.firstDifference(from: .roomDefault), .intensity)
        XCTAssertTrue(p.isActive(.intensity))
        XCTAssertEqual(p.outputType(.uint8), .uint8)
        XCTAssertNil(p.refusal(for: dataset, background: background))

        var normalised = p
        normalised.intensity.mode = .normalize
        XCTAssertEqual(normalised.refusal(for: dataset, background: background)?.stage, .intensity)
        normalised.intensity.equalize = false
        XCTAssertEqual(normalised.refusal(for: dataset, background: background)?.stage, .fftFilter)
        normalised.fftFilter.isOn = false
        XCTAssertEqual(normalised.refusal(for: dataset, background: background)?.sentence,
                       "Average neighbours reads 8 and 16 bit patterns; Normalise makes them float32. Rescale or leave the intensities instead.")

        var band = PatternPipeline.roomDefault
        band.fftFilter.isOn = true
        band.fftFilter.highCutoff = 30
        XCTAssertEqual(band.refusal(for: dataset, background: background)?.sentence,
                       "Band keeps the frequencies between the highpass and lowpass cutoffs: the highpass cutoff must be the lower.")
        band.fftFilter.pass = .high
        XCTAssertNil(band.refusal(for: dataset, background: background), "High alone has no lowpass to sit below")
        band.fftFilter.highWidth = 0
        XCTAssertEqual(band.refusal(for: dataset, background: background)?.sentence, "The highpass cutoff and width must be positive.")

        var kernel = PatternPipeline.roomDefault
        kernel.intensity.equalize = true
        kernel.intensity.clipLimit = -1
        XCTAssertEqual(kernel.refusal(for: dataset, background: background)?.sentence, "The clip limit must be 0 or more.")
    }

    func testTheMethodJSONNamesTheFiltersAsKikuchipyDoes() throws {
        let (dataset, _) = try opened()
        var p = PatternPipeline.roomDefault
        p.intensity.equalize = true
        p.fftFilter.isOn = true
        p.binning = 2
        p.averaging.isOn = true
        p.averaging.window = .gaussian3
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: p.methodJSON(fileName: "x.h5", dataset: dataset)) as? [String: Any])
        let steps = try XCTUnwrap(json["steps"] as? [[String: Any]])
        XCTAssertEqual(steps.compactMap { $0["method"] as? String },
                       ["EBSD.remove_static_background", "EBSD.remove_dynamic_background", "EBSD.adaptive_histogram_equalization",
                        "EBSD.fft_filter", "EBSD.downsample", "EBSD.average_neighbour_patterns"])
        XCTAssertTrue(steps[2]["kernel_size"] is NSNull)
        XCTAssertEqual(steps[2]["nbins"] as? Int, 128)
        XCTAssertEqual(steps[3]["transfer_function"] as? String,
                       "Window('lowpass', cutoff=22.0, cutoff_width=10.0, shape=(60, 60)) * Window('highpass', cutoff=3.0, cutoff_width=2.0, shape=(60, 60))")
        XCTAssertEqual(steps[3]["shift"] as? Bool, true)
        XCTAssertEqual(steps[5]["window"] as? String, "gaussian")
        XCTAssertEqual(steps[5]["window_shape"] as? [Int], [3, 3])
        XCTAssertEqual(steps[5]["std"] as? Double, 1)
    }
}
