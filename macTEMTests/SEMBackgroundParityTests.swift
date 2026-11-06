//
//  SEMBackgroundParityTests.swift
//  TEMCore's `PatternProcessing` (static and dynamic background removal of EBSD patterns) against kikuchipy 0.13.1's numbers:
//  the fixtures under Fixtures/sem/background/ are `tools/parity/sem/background_reference.py`'s output for pattern (0, 0) (the
//  north-star figure F2) and pattern (27, 37) of nickel_ebsd_large, plus the file's static background and the set's mean pattern.
//  Tolerances (docs/parity.md): rescaled values within 1e-5 relative of kikuchipy's float32 values; a pattern cast back to uint8
//  within one grey level on at most 1 % of its pixels (kikuchipy truncates its float32 values; measured here: at most 22 of 3600);
//  the mean background exact. The whole-set test is opt-in: it reads `--whole-set`'s files from `$MACEM_DATA/sem/nickel_ebsd_large`
//  (all 4125 patterns, same bound at 0.2 % of the pixels, measured 0.007 %) and skips when they are not there.
//  Red before the port: no `PatternProcessing` type. Red after a change to a tap offset, the window's extent, the rescale rule or
//  the cast: the uint8 fixtures differ by whole grey levels across the pattern.
//

import XCTest
import TEMCore

nonisolated final class SEMBackgroundParityTests: XCTestCase {

    // MARK: - Fixtures

    private static let folder = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/sem/background")
    private static let rows = 60, columns = 60
    private static let std5 = 5.0, truncate3 = 3.0

    private func u8(_ name: String) throws -> [UInt8] {
        let data = try Data(contentsOf: Self.folder.appendingPathComponent("\(name).u8"))
        XCTAssertEqual(data.count, Self.rows * Self.columns, name)
        return [UInt8](data)
    }

    private func f32(_ name: String) throws -> [Float] {
        let data = try Data(contentsOf: Self.folder.appendingPathComponent("\(name).f32"))
        XCTAssertEqual(data.count, Self.rows * Self.columns * 4, name)
        return data.withUnsafeBytes { raw in
            raw.bindMemory(to: UInt32.self).map { Float(bitPattern: UInt32(littleEndian: $0)) }
        }
    }

    /// Grey levels: every pixel within one of the reference, and at most `fraction` of them off at all.
    private func assertWithinOneGrey(_ ours: [UInt8], _ reference: [UInt8], fraction: Double = 0.01,
                                     _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(ours.count, reference.count, what, file: file, line: line)
        var off = 0, worst = 0
        for (a, b) in zip(ours, reference) {
            let d = abs(Int(a) - Int(b))
            if d > 0 { off += 1 }
            worst = max(worst, d)
        }
        XCTAssertLessThanOrEqual(worst, 1, "\(what): a pixel is \(worst) grey levels off", file: file, line: line)
        XCTAssertLessThanOrEqual(Double(off), fraction * Double(reference.count),
                                 "\(what): \(off) of \(reference.count) pixels differ by one grey level", file: file, line: line)
    }

    /// Values: within `rtol` relative (floored at `atol`) of kikuchipy's float32 values.
    private func assertClose(_ ours: [Double], _ reference: [Float], rtol: Double = 1e-5, atol: Double = 1e-4,
                             _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(ours.count, reference.count, what, file: file, line: line)
        var worst = 0.0
        for (a, b) in zip(ours, reference) {
            let r = Double(b)
            worst = max(worst, abs(a - r) / max(abs(r) * rtol, atol))
        }
        XCTAssertLessThanOrEqual(worst, 1, "\(what): \(worst) × the tolerance", file: file, line: line)
    }

    // MARK: - Static background

    func testStaticBackgroundSubtractMatchesKikuchipy() throws {
        let background = try u8("static_background")
        for p in ["p0_0", "p27_37"] {
            let raw = try u8("\(p)_raw")
            let values = try PatternProcessing.removeStaticBackgroundValues(raw, background: background, operation: .subtract)
            try assertClose(values, f32("\(p)_static_subtract_values"), "\(p) static subtract values")
            let out = try PatternProcessing.removeStaticBackground(raw, background: background)
            try assertWithinOneGrey(out, u8("\(p)_static_subtract"), "\(p) static subtract")
            XCTAssertEqual(out.min(), 0, p); XCTAssertEqual(out.max(), 255, p)
        }
    }

    func testStaticBackgroundDivideAndScaledBackgroundMatchKikuchipy() throws {
        let background = try u8("static_background")
        for p in ["p0_0", "p27_37"] {
            let raw = try u8("\(p)_raw")
            try assertWithinOneGrey(PatternProcessing.removeStaticBackground(raw, background: background, operation: .divide),
                                u8("\(p)_static_divide"), "\(p) static divide")
            try assertWithinOneGrey(PatternProcessing.removeStaticBackground(raw, background: background, operation: .subtract, scaleBackground: true),
                                u8("\(p)_static_subtract_scaled"), "\(p) static subtract, scaled background")
            try assertWithinOneGrey(PatternProcessing.removeStaticBackground(raw, background: background, operation: .divide, scaleBackground: true),
                                u8("\(p)_static_divide_scaled"), "\(p) static divide, scaled background")
        }
    }

    /// The mean pattern as the background when the file carries none: numpy's `mean(axis=0).astype(uint8)`, exact.
    func testMeanBackgroundEqualsNumpyAndRemovesLikeTheFilesOwn() throws {
        // Four two-pixel patterns (count-major): pixel 0 is 1, 3, 0, 0 (mean 1), pixel 1 is 2, 5, 0, 0 (mean 1.75): the cast
        // truncates as numpy's astype does, 1.75 -> 1.
        let four: [UInt8] = [1, 2, 3, 5, 0, 0, 0, 0]
        XCTAssertEqual(try PatternProcessing.meanBackground(of: four, count: 4, pixels: 2), [1, 1])
        // The set's mean in the fixture was taken over all 4125 patterns; the per-pattern removal with it is one more static case.
        let mean = try u8("mean_background")
        for p in ["p0_0", "p27_37"] {
            try assertWithinOneGrey(PatternProcessing.removeStaticBackground(u8("\(p)_raw"), background: mean),
                                u8("\(p)_mean_static_subtract"), "\(p) static subtract with the mean background")
        }
    }

    // MARK: - Dynamic background

    func testDynamicBackgroundFrequencyMatchesTheFFTFilter() throws {
        for p in ["p0_0", "p27_37"] {
            let s = try u8("\(p)_static_subtract").map(Double.init)
            let bg = try PatternProcessing.dynamicBackground(s, rows: Self.rows, columns: Self.columns)
            try assertClose(bg, f32("\(p)_dynamic_background_frequency"), "\(p) dynamic background, frequency, default window")
            let odd = try PatternProcessing.dynamicBackground(s, rows: Self.rows, columns: Self.columns, std: Self.std5, truncate: Self.truncate3)
            try assertClose(odd, f32("\(p)_dynamic_background_frequency_std5_truncate3"), "\(p) dynamic background, frequency, 15 px window")
        }
    }

    func testDynamicBackgroundSpatialMatchesGaussianFilter() throws {
        for p in ["p0_0", "p27_37"] {
            let s = try u8("\(p)_static_subtract").map(Double.init)
            let bg = try PatternProcessing.dynamicBackground(s, rows: Self.rows, columns: Self.columns, domain: .spatial)
            try assertClose(bg, f32("\(p)_dynamic_background_spatial"), "\(p) dynamic background, spatial")
        }
    }

    func testRemoveDynamicBackgroundMatchesKikuchipy() throws {
        let r = Self.rows, c = Self.columns
        for p in ["p0_0", "p27_37"] {
            let s = try u8("\(p)_static_subtract")
            let values = try PatternProcessing.removeDynamicBackgroundValues(s, rows: r, columns: c)
            try assertClose(values, f32("\(p)_dynamic_frequency_subtract_values"), "\(p) dynamic frequency subtract values")
            try assertWithinOneGrey(PatternProcessing.removeDynamicBackground(s, rows: r, columns: c),
                                u8("\(p)_dynamic_frequency_subtract"), "\(p) dynamic frequency subtract")
            try assertWithinOneGrey(PatternProcessing.removeDynamicBackground(s, rows: r, columns: c, operation: .divide),
                                u8("\(p)_dynamic_frequency_divide"), "\(p) dynamic frequency divide")
            try assertWithinOneGrey(PatternProcessing.removeDynamicBackground(s, rows: r, columns: c, domain: .spatial),
                                u8("\(p)_dynamic_spatial_subtract"), "\(p) dynamic spatial subtract")
            try assertWithinOneGrey(PatternProcessing.removeDynamicBackground(s, rows: r, columns: c, operation: .divide, domain: .spatial),
                                u8("\(p)_dynamic_spatial_divide"), "\(p) dynamic spatial divide")
            try assertWithinOneGrey(PatternProcessing.removeDynamicBackground(s, rows: r, columns: c, std: Self.std5, truncate: Self.truncate3),
                                u8("\(p)_dynamic_frequency_subtract_std5_truncate3"), "\(p) dynamic frequency subtract, 15 px window")
            try assertWithinOneGrey(PatternProcessing.removeDynamicBackground(s, rows: r, columns: c, domain: .spatial, std: Self.std5, truncate: Self.truncate3),
                                u8("\(p)_dynamic_spatial_subtract_std5_truncate3"), "\(p) dynamic spatial subtract, std 5, truncate 3")
        }
    }

    // MARK: - Figure F2

    /// The north-star chain on pattern (0, 0): static subtract with the file's background, then the dynamic frequency subtract at
    /// the defaults (std = width / 8, truncate 4), equals kikuchipy's F2 pattern. The result is also printed as base64 and written
    /// to $TMPDIR so the figure beside the reference (tools/parity/sem/background_figure.py) is drawn from this build's numbers.
    func testFigureF2PatternZeroAfterStaticAndDynamicBackground() throws {
        let raw = try u8("p0_0_raw"), background = try u8("static_background")
        let afterStatic = try PatternProcessing.removeStaticBackground(raw, background: background)
        let ours = try PatternProcessing.removeDynamicBackground(afterStatic, rows: Self.rows, columns: Self.columns)
        try assertWithinOneGrey(ours, u8("p0_0_dynamic_frequency_subtract"), "F2")
        let out = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("macTEM-F2-ours.u8")
        try Data(ours).write(to: out)
        print("F2 ours (\(Self.rows) x \(Self.columns) uint8, base64): \(Data(ours).base64EncodedString())")
    }

    /// Opt-in: every pattern of the set through the F2 chain against kikuchipy's, from the whole-set references
    /// (`background_reference.py --whole-set`) under $MACEM_DATA/sem/nickel_ebsd_large; skips without them.
    func testWholeSetF2ChainWithinOneGreyLevel() throws {
        let folder = URL(fileURLWithPath: RealDataFolder.path).appendingPathComponent("sem/nickel_ebsd_large")
        let files = ["patterns.u8", "static_background.u8", "f2_reference.u8"].map { folder.appendingPathComponent($0) }
        try XCTSkipUnless(files.allSatisfy { FileManager.default.fileExists(atPath: $0.path) },
                          "whole-set references not under \(folder.path)")
        let patterns = try [UInt8](Data(contentsOf: files[0])), background = try [UInt8](Data(contentsOf: files[1]))
        let reference = try [UInt8](Data(contentsOf: files[2]))
        let pixels = Self.rows * Self.columns
        XCTAssertEqual(background.count, pixels); XCTAssertEqual(patterns.count, reference.count)
        XCTAssertEqual(patterns.count % pixels, 0)
        let count = patterns.count / pixels
        var off = 0, worst = 0
        for i in 0..<count {
            let slice = Array(patterns[i * pixels..<(i + 1) * pixels])
            let afterStatic = try PatternProcessing.removeStaticBackground(slice, background: background)
            let ours = try PatternProcessing.removeDynamicBackground(afterStatic, rows: Self.rows, columns: Self.columns)
            for (a, b) in zip(ours, reference[i * pixels..<(i + 1) * pixels]) {
                let d = abs(Int(a) - Int(b))
                if d > 0 { off += 1 }
                worst = max(worst, d)
            }
        }
        print("whole set F2: \(count) patterns, \(off) of \(count * pixels) pixels one grey level off, worst \(worst)")
        XCTAssertLessThanOrEqual(worst, 1)
        XCTAssertLessThanOrEqual(Double(off), 0.002 * Double(count * pixels))
    }

    // MARK: - Refusals

    func testShapeAndParameterErrors() throws {
        let p: [UInt8] = [1, 2, 3, 4]
        XCTAssertThrowsError(try PatternProcessing.removeStaticBackground(p, background: [1, 2, 3])) {
            XCTAssertEqual($0 as? PatternProcessing.Error, .shape)
        }
        XCTAssertThrowsError(try PatternProcessing.dynamicBackground(p.map(Double.init), rows: 3, columns: 2)) {
            XCTAssertEqual($0 as? PatternProcessing.Error, .shape)
        }
        XCTAssertThrowsError(try PatternProcessing.dynamicBackground(p.map(Double.init), rows: 2, columns: 2, std: 0)) {
            XCTAssertEqual($0 as? PatternProcessing.Error, .parameter("std"))
        }
        XCTAssertThrowsError(try PatternProcessing.dynamicBackground(p.map(Double.init), rows: 2, columns: 2, std: 0.1, truncate: 1)) {
            XCTAssertEqual($0 as? PatternProcessing.Error, .parameter("truncate · std"))
        }
        // A zero in the background divides to infinity; kikuchipy would cast NaN, this refuses.
        XCTAssertThrowsError(try PatternProcessing.removeStaticBackground(p, background: [0, 1, 2, 3], operation: .divide)) {
            XCTAssertEqual($0 as? PatternProcessing.Error, .nonFinite)
        }
        // A flat pattern cannot be stretched.
        XCTAssertThrowsError(try PatternProcessing.removeStaticBackground([5, 5, 5, 5] as [UInt8], background: [1, 1, 1, 1])) {
            XCTAssertEqual($0 as? PatternProcessing.Error, .nonFinite)
        }
    }

    /// uint16 patterns rescale to 0 ... 65535 (the type's range), the same rule as uint8.
    func testSixteenBitPatternsRescaleToTheirRange() throws {
        let p: [UInt16] = [100, 200, 300, 400], bg: [UInt16] = [50, 50, 50, 50]
        let out = try PatternProcessing.removeStaticBackground(p, background: bg)
        XCTAssertEqual(out, [0, 21845, 43690, 65535])
    }
}
