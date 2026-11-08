//
//  TypedEntryBoundsTests.swift
//  Typed whole numbers and the bounds on what they reach: `TypedWholeNumber` (macTEM/UI) rounds a typed entry and holds it within
//  ±10⁹ where `Int()` trapped on 1e20 (the NLPAR radius, the equalisation kernel, the Richardson-Lucy iterations), and
//  `PatternPipeline.refusal` names a Std × truncate, an NLPAR search radius or a CLAHE kernel too large to run, where it trapped in
//  `Int()` or in `2 r + 1`, or accepted a kernel whose padding exhausts memory. Settings that ran before in memory are not refused.
//  Red before: no `TypedWholeNumber`; the truncate and radius refusals trap while the inspector redraws; the kernel is accepted.
//

import XCTest
import FormatoCore
import TEMCore
@testable import macTEM

nonisolated final class TypedEntryBoundsTests: XCTestCase {

    /// A planted 3 × 3 scan of 60 × 60 uint8 patterns, the h5ebsd fixture's shape: the refusals read only the shape.
    private func dataset() -> EBSDDataset {
        EBSDDataset(format: .generated, manufacturer: "test", version: "", scanGroup: "s", scanGroups: ["s"], scanRows: 3, scanColumns: 3,
                    patternRows: 60, patternColumns: 60, dataType: .uint8, stepY: 1, stepX: 1,
                    detector: EBSDDetectorGeometry(rows: 60, columns: 60, projectionCenters: []),
                    patterns: EBSDPatternSource(url: URL(fileURLWithPath: "/planted"), datasetPath: "", fileShape: [3, 3, 60, 60], dataType: .uint8))
    }

    /// The pipeline without its static stage, so no background is needed, every other stage at its default.
    private func withoutStaticBackground() -> PatternPipeline {
        var p = PatternPipeline()
        p.staticStage.isOn = false
        return p
    }

    func testATypedWholeNumberIsRoundedAndHeldWithinABillion() {
        XCTAssertEqual(TypedWholeNumber.value(1e30), 1_000_000_000)
        XCTAssertEqual(TypedWholeNumber.value(-1e30), -1_000_000_000)
        XCTAssertEqual(TypedWholeNumber.value(.nan), 0)
        XCTAssertEqual(TypedWholeNumber.value(.infinity), 0)
        XCTAssertEqual(TypedWholeNumber.value(-3.4), -3)
        XCTAssertEqual(TypedWholeNumber.value(2.5), 3, "half away from zero, as Double.rounded()")
        XCTAssertEqual(TypedWholeNumber.value(7), 7)
    }

    func testAHugeStdTimesTruncateIsRefusedInsteadOfTrapping() {
        let data = dataset()
        var p = withoutStaticBackground()
        XCTAssertNil(p.refusal(for: data, background: nil), "the default window, 4 × 60 / 8 px")
        p.dynamicStage.truncate = 1e300
        let refusal = p.refusal(for: data, background: nil)
        XCTAssertEqual(refusal?.stage, .dynamicBackground)
        XCTAssertEqual(refusal?.sentence, "Std × truncate is over 1048576 px: the Gaussian window would be far wider than any pattern.")
        p.dynamicStage.truncate = 4
        p.dynamicStage.std = 1e300
        XCTAssertEqual(p.refusal(for: data, background: nil)?.stage, .dynamicBackground, "a huge Std as well")
        p.dynamicStage.std = 0.1
        XCTAssertEqual(p.refusal(for: data, background: nil)?.sentence, "Std × truncate is under one pixel: the Gaussian window would be empty.")
        // The window itself refuses the same width before it is converted or allocated.
        XCTAssertThrowsError(try PatternProcessing.dynamicBackground([1, 2, 3, 4], rows: 2, columns: 2, std: 1e300, truncate: 4)) {
            XCTAssertEqual($0 as? PatternProcessing.Error, .parameter("truncate · std"))
        }
    }

    func testAHugeNLPARSearchRadiusIsRefusedBeforeItsWindowOverflows() {
        let data = dataset()
        var p = withoutStaticBackground()
        p.dynamicStage.isOn = false
        p.nlpar.isOn = true
        p.nlpar.searchRadius = 1
        XCTAssertNil(p.refusal(for: data, background: nil), "a 3 × 3 window fits the 3 × 3 scan")
        p.nlpar.searchRadius = 2
        XCTAssertEqual(p.refusal(for: data, background: nil)?.sentence, "A search radius of 2 needs a scan of at least 5 × 5; this one is 3 × 3.")
        p.nlpar.searchRadius = Int.max / 2 + 1
        let refusal = p.refusal(for: data, background: nil)
        XCTAssertEqual(refusal?.stage, .nlpar)
        XCTAssertEqual(refusal?.sentence, "A search radius of \(Int.max / 2 + 1) is wider than any scan; this one is 3 × 3.")
        p.nlpar.searchRadius = max(1, TypedWholeNumber.value(1e20))
        XCTAssertEqual(p.refusal(for: data, background: nil)?.sentence,
                       "A search radius of 1000000000 needs a scan of at least 2000000001 × 2000000001; this one is 3 × 3.",
                       "a typed 1e20 reaches the refusal")
        p.nlpar.searchRadius = Int.min
        XCTAssertEqual(p.refusal(for: data, background: nil)?.sentence, "The search radius must be at least 1.")
    }

    func testAnEqualisationKernelWhosePaddingWouldExhaustMemoryIsRefused() {
        let data = dataset()
        var p = withoutStaticBackground()
        p.intensity.equalize = true
        XCTAssertNil(p.refusal(for: data, background: nil), "kikuchipy's default kernel, a quarter of the pattern")
        p.intensity.equalizeKernel = 60
        XCTAssertNil(p.refusal(for: data, background: nil), "a kernel as large as the pattern")
        p.intensity.equalizeKernel = 61
        XCTAssertNil(p.refusal(for: data, background: nil), "a kernel past the pattern runs as scikit-image runs it")
        // (60 + 2k)² ≤ 2²⁴ up to k = 2018.
        p.intensity.equalizeKernel = 2018
        XCTAssertNil(p.refusal(for: data, background: nil), "the largest kernel whose padding fits 2²⁴ values")
        p.intensity.equalizeKernel = 2019
        XCTAssertEqual(p.refusal(for: data, background: nil)?.stage, .intensity)
        p.intensity.equalizeKernel = 100_000
        let refusal = p.refusal(for: data, background: nil)
        XCTAssertEqual(refusal?.stage, .intensity)
        XCTAssertEqual(refusal?.sentence, "The equalisation kernel of 100000 px is far larger than the 60 × 60 px pattern.")
    }

    func testTheDefaultSettingsAreNotRefused() throws {
        let data = dataset()
        let background = try FormatoArray(dataType: .uint8, shape: [60, 60], bytes: Data(count: 3600))
        XCTAssertNil(PatternPipeline.roomDefault.refusal(for: data, background: background))
        XCTAssertNil(withoutStaticBackground().refusal(for: data, background: nil))
    }
}
