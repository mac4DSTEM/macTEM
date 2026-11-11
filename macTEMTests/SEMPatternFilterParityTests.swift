//
//  SEMPatternFilterParityTests.swift
//  TEMCore's EBSD pattern filters against kikuchipy 0.13.1 (scikit-image 0.26.0 for CLAHE), from the `m2/fft-filter-*`,
//  `m2/clahe-*` and `m2/average-neighbours-*` bundles of tools/parity/sem (each carries its input patterns):
//  - `PatternWindow`: lowpass, highpass, their product, Gaussian, modified Hann and circular windows at rtol 1e-12;
//  - `PatternFilters.fftFilter` in the frequency domain (shift on and off) and the spatial domain (5 x 5 Gaussian, 3 x 4
//    asymmetric kernel): values before the cast within 1e-5 relative or 1e-3 grey levels, cast patterns within one grey level
//    on at most 1 % of the pixels (D-SEM-18's rule; measured at most 0.22 %, the asymmetric kernel on nickel pattern (0, 0);
//    kikuchipy's FFTs are float32);
//  - `AdaptiveHistogramEqualization.equalize`: exact (three kernel / clip limit / bin settings);
//  - `NeighbourAveraging.average`: window sums exact, values within 1e-5 relative or 1e-4 grey levels, cast patterns within one
//    grey level on at most 0.2 % (3 x 3 Gaussian) or 2 % (the integer-weight windows, whose exact integers kikuchipy's float32
//    fastmath lands just below) of the pixels.
//  North-star figure F4: pattern (0, 0) of nickel_ebsd_large after the guide's lowpass x highpass transfer function.
//  Red before the port: no `PatternWindow`, `PatternFilters`, `AdaptiveHistogramEqualization`, `NeighbourAveraging`. Red after a
//  change to the shift layout, a kernel flip or tap offset, the CLAHE quantisation, padding, clip redistribution or float32
//  accumulation, or the averaging's edge rule: whole grey levels move across the patterns.
//

import Foundation
import TEMCore
import XCTest

nonisolated final class SEMPatternFilterParityTests: XCTestCase {

    private static let small = "kikuchipy-h5ebsd", large = "nickel-ebsd-large"

    // MARK: - Helpers

    /// The bundle's input patterns as uint8, with the pattern shape (the last two axes).
    private func patterns(_ ref: SEMParityReference) throws -> (data: [UInt8], count: Int, rows: Int, columns: Int, shape: [Int]) {
        let a = try ref.array("patterns")
        XCTAssertEqual(a.dtype, "uint8")
        let rows = a.shape[a.shape.count - 2], columns = a.shape[a.shape.count - 1]
        return (a.values.map { UInt8($0) }, a.values.count / (rows * columns), rows, columns, a.shape)
    }

    /// Cast patterns: every pixel within one grey level of the reference, at most `fraction` of them off at all.
    private func assertWithinOneGrey(_ ours: [UInt8], _ reference: SEMParityReference.LoadedArray, fraction: Double,
                                     _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(ours.count, reference.values.count, what, file: file, line: line)
        var off = 0, worst = 0
        for (a, b) in zip(ours, reference.values) {
            let d = abs(Int(a) - Int(b))
            if d > 0 { off += 1 }
            worst = max(worst, d)
        }
        XCTAssertLessThanOrEqual(worst, 1, "\(what): a pixel is \(worst) grey levels off", file: file, line: line)
        XCTAssertLessThanOrEqual(Double(off), fraction * Double(reference.values.count),
                                 "\(what): \(off) of \(reference.values.count) pixels one grey level off", file: file, line: line)
    }

    private func assertWindow(_ w: PatternWindow, _ ref: SEMParityReference, _ name: String,
                              file: StaticString = #filePath, line: UInt = #line) throws {
        let a = try ref.array(name)
        let shape = a.shape.count == 1 ? [a.shape[0], 1] : a.shape
        XCTAssertEqual([w.rows, w.columns], shape, name, file: file, line: line)
        SEMAssertParity(w.values, a, file: file, line: line)
    }

    // MARK: - Windows

    func testWindowsMatchKikuchipy() throws {
        let ref = try SEMParityReference.load("m2/fft-filter-\(Self.small)")
        let low = try PatternWindow.lowpass(rows: 60, columns: 60, cutoff: 22, cutoffWidth: 10)
        let high = try PatternWindow.highpass(rows: 60, columns: 60, cutoff: 3, cutoffWidth: 2)
        try assertWindow(low, ref, "window_lowpass")
        try assertWindow(high, ref, "window_highpass")
        try assertWindow(low * high, ref, "transfer_function")
        try assertWindow(PatternWindow.gaussian(rows: 5, columns: 5, std: 1), ref, "window_gaussian_5x5_std1")
        try assertWindow(PatternWindow.modifiedHann(rows: 60), ref, "window_modified_hann_60")
        try assertWindow(PatternWindow.circular(rows: 5, columns: 7), ref, "window_circular_5x7")
        XCTAssertThrowsError(try PatternWindow.lowpass(rows: 60, columns: 60, cutoff: 0))
        XCTAssertThrowsError(try low * PatternWindow.rectangular(rows: 3, columns: 3))
    }

    // MARK: - FFT filter

    private func filterRuns() throws -> [(name: String, domain: PatternFilters.Domain, filter: PatternWindow, shift: Bool)] {
        let transfer = try PatternWindow.lowpass(rows: 60, columns: 60, cutoff: 22, cutoffWidth: 10)
            * PatternWindow.highpass(rows: 60, columns: 60, cutoff: 3, cutoffWidth: 2)
        let asymmetric = try PatternWindow(rows: 3, columns: 4, values: [0, 1, 2, 3, 4, 5, 6, 7, -1, -2, 0.5, 1.5])
        return [("frequency_shift", .frequency, transfer, true),
                ("frequency_noshift", .frequency, transfer, false),
                ("spatial_gaussian", .spatial, try PatternWindow.gaussian(rows: 5, columns: 5, std: 1), false),
                ("spatial_asymmetric", .spatial, asymmetric, false)]
    }

    private func checkFFTFilter(_ bundle: String) throws {
        let ref = try SEMParityReference.load("m2/fft-filter-\(bundle)")
        let p = try patterns(ref)
        let pixels = p.rows * p.columns
        for run in try filterRuns() {
            var values: [Double] = [], cast: [UInt8] = []
            for i in 0..<p.count {
                let one = Array(p.data[(i * pixels)..<((i + 1) * pixels)])
                values += try PatternFilters.fftFilterValues(one, rows: p.rows, columns: p.columns, domain: run.domain,
                                                             filter: run.filter, shift: run.shift)
                cast += try PatternFilters.fftFilter(one, rows: p.rows, columns: p.columns, domain: run.domain,
                                                     filter: run.filter, shift: run.shift)
            }
            SEMAssertParity(values, try ref.array("\(run.name)_values"), shape: p.shape)
            assertWithinOneGrey(cast, try ref.array(run.name), fraction: 0.01, "\(bundle) \(run.name)")
        }
    }

    func testFFTFilterMatchesKikuchipyOnTheCommittedCut() throws { try checkFFTFilter(Self.small) }

    func testFFTFilterMatchesKikuchipyOnNickelPatternZero() throws { try checkFFTFilter(Self.large) }

    func testFFTFilterRefusesAMismatchedTransferFunction() throws {
        let h = try PatternWindow.rectangular(rows: 4, columns: 4)
        XCTAssertThrowsError(try PatternFilters.fftFilter([UInt8](repeating: 1, count: 25), rows: 5, columns: 5,
                                                          domain: .frequency, filter: h)) { error in
            XCTAssertEqual(error as? PatternFilters.Error, .shape)
        }
    }

    // MARK: - Figure F4

    /// North-star figure F4: pattern (0, 0) of nickel_ebsd_large through the guide's Gaussian lowpass (cutoff 22, width 10)
    /// x highpass (cutoff 3, width 2) transfer function, shift on, equals kikuchipy's pattern. Printed as base64 and written to
    /// $TMPDIR so the figure beside the reference (tools/parity/sem/filter_figure.py) is drawn from this build's numbers.
    func testFigureF4PatternZeroAfterFFTFilter() throws {
        let ref = try SEMParityReference.load("m2/fft-filter-\(Self.large)")
        let p = try patterns(ref)
        let transfer = try PatternWindow.lowpass(rows: p.rows, columns: p.columns, cutoff: 22, cutoffWidth: 10)
            * PatternWindow.highpass(rows: p.rows, columns: p.columns, cutoff: 3, cutoffWidth: 2)
        let ours = try PatternFilters.fftFilter(Array(p.data[0..<(p.rows * p.columns)]), rows: p.rows, columns: p.columns,
                                                domain: .frequency, filter: transfer, shift: true)
        let reference = try ref.array("frequency_shift")
        assertWithinOneGrey(ours, reference, fraction: 0.002, "F4")
        let off = zip(ours, reference.values).filter { Double($0.0) != $0.1 }.count
        let out = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("macTEM-F4-ours.u8")
        try Data(ours).write(to: out)
        print("F4 ours (\(p.rows) x \(p.columns) uint8, \(off) px differ from kikuchipy, base64): \(Data(ours).base64EncodedString())")
    }

    // MARK: - CLAHE

    private func checkCLAHE(_ bundle: String) throws {
        let ref = try SEMParityReference.load("m2/clahe-\(bundle)")
        let p = try patterns(ref)
        let pixels = p.rows * p.columns
        let runs: [(name: String, kernel: (rows: Int, columns: Int)?, clip: Double, bins: Int)] = [
            ("default", nil, 0, 128), ("k10x12_clip0p01_nbins64", (10, 12), 0.01, 64), ("k7_clip0p05_nbins256", (7, 7), 0.05, 256),
        ]
        for run in runs {
            var ours: [Double] = []
            for i in 0..<p.count {
                let one = Array(p.data[(i * pixels)..<((i + 1) * pixels)])
                ours += try AdaptiveHistogramEqualization.equalize(one, rows: p.rows, columns: p.columns, kernel: run.kernel,
                                                                   clipLimit: run.clip, bins: run.bins).map { Double($0) }
            }
            SEMAssertParity(ours, try ref.array(run.name), shape: p.shape)
        }
    }

    func testCLAHEMatchesScikitImageExactlyOnTheCommittedCut() throws { try checkCLAHE(Self.small) }

    func testCLAHEMatchesScikitImageExactlyOnNickelPatternZero() throws { try checkCLAHE(Self.large) }

    func testCLAHEClipHistogramRedistributesEveryExcessCount() {
        var hist = [10, 0, 0, 1, 7]
        AdaptiveHistogramEqualization.clipHistogram(&hist, limit: 4)
        XCTAssertEqual(hist.reduce(0, +), 18)
        XCTAssertTrue(hist.allSatisfy { $0 <= 4 })
    }

    // MARK: - Neighbour averaging

    private func checkAveraging(_ bundle: String, corner: Int?) throws {
        let ref = try SEMParityReference.load("m2/average-neighbours-\(bundle)")
        let p = try patterns(ref)
        let scanRows = p.shape[0], scanColumns = p.shape[1], pixels = p.rows * p.columns
        let runs: [(name: String, window: PatternWindow, fraction: Double)] = [
            ("circular_3x3", try PatternWindow.circular(rows: 3, columns: 3), 0.02),
            ("gaussian_3x3_std1", try PatternWindow.gaussian(rows: 3, columns: 3, std: 1), 0.002),
            ("rectangular_1x3", try PatternWindow.rectangular(rows: 1, columns: 3), 0.02),
        ]
        let n = corner ?? scanRows, m = corner ?? scanColumns
        func crop<T>(_ a: [T]) -> [T] {
            var out: [T] = []
            for r in 0..<n { for c in 0..<m { out += a[((r * scanColumns + c) * pixels)..<((r * scanColumns + c + 1) * pixels)] } }
            return out
        }
        for run in runs {
            try assertWindow(run.window, ref, "window_\(run.name)")
            let sums = NeighbourAveraging.windowSums(scanRows: scanRows, scanColumns: scanColumns, window: run.window)
            var croppedSums: [Double] = []
            for r in 0..<n { for c in 0..<m { croppedSums.append(Double(sums[r * scanColumns + c])) } }
            SEMAssertParity(croppedSums, try ref.array("window_sums_\(run.name)"))
            let values = try NeighbourAveraging.averageValues(p.data, scanRows: scanRows, scanColumns: scanColumns, pixels: pixels,
                                                              window: run.window)
            SEMAssertParity(crop(values), try ref.array("\(run.name)_values"))
            let cast = try NeighbourAveraging.average(p.data, scanRows: scanRows, scanColumns: scanColumns, pixels: pixels,
                                                      window: run.window)
            assertWithinOneGrey(crop(cast), try ref.array(run.name), fraction: run.fraction, "\(bundle) \(run.name)")
        }
    }

    func testNeighbourAveragingMatchesKikuchipyOnTheCommittedCut() throws { try checkAveraging(Self.small, corner: nil) }

    /// The bundle holds the scan's 4 x 4 corner; the averaged 3 x 3 corner reads no pattern beyond it with a 3-wide window.
    func testNeighbourAveragingMatchesKikuchipyOnTheNickelCorner() throws { try checkAveraging(Self.large, corner: 3) }

    func testNeighbourAveragingWithAOneByOneWindowChangesNothing() throws {
        let data: [UInt8] = [1, 2, 3, 4, 5, 6, 7, 8]
        XCTAssertEqual(try NeighbourAveraging.average(data, scanRows: 2, scanColumns: 2, pixels: 2,
                                                      window: PatternWindow.rectangular(rows: 1, columns: 1)), data)
    }
}
