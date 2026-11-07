//
//  IndexingMapLayerTests.swift
//  The Indexing room's map layers as they are drawn (D-SEM-96), on small synthetic runs: a scalar layer is its values, with NaN (the
//  masked grey) where a point has none or has not been reached, and the legend names what the grey stands for; the Euler layer is
//  orix's `EulerColorKey` of the phase's point group (its numbers held by `SEMColorKeyParityTests`), not indexed black, not reached the
//  navigator's dark grey; the Euler legend names the fundamental region's ranges.
//  Red before the change: no Euler layer, scalar layers painted as a grey ramp with not-indexed points black.
//

import XCTest
import TEMCore
import TEMSession
@testable import macTEM

nonisolated final class IndexingMapLayerTests: XCTestCase {

    private static let q0 = unit(SIMD4(0.9, 0.3, -0.2, 0.25))
    private static let q2 = unit(SIMD4(0.6, -0.1, 0.5, 0.4))

    private static func unit(_ q: SIMD4<Double>) -> SIMD4<Double> { q / (q * q).sum().squareRoot() }

    private static func solution(_ q: SIMD4<Double>?, confidence: Double, fit: Double, bands: Int, pq: Double) -> HoughIndexer.Solution {
        var s = HoughIndexer.Solution()
        if let q {
            s.quaternion = q
            s.phase = 0
            s.confidence = confidence
            s.fit = fit
        }
        s.matchedBands = bands
        s.patternQuality = pq
        return s
    }

    /// A 2 × 3 Hough run of nickel with its first row landed: indexed, not indexed, indexed.
    private static func firstRowLanded() throws -> IndexingResult {
        let nickel = try XCTUnwrap(IndexingPhase.presets.first { $0.name == "Ni" })
        var result = IndexingResult(scanRows: 2, scanColumns: 3, phases: [nickel])
        result.land([solution(q0, confidence: 0.8, fit: 0.5, bands: 9, pq: 1200),
                     solution(nil, confidence: 0, fit: 180, bands: 2, pq: 800),
                     solution(q2, confidence: 0.2, fit: 1.25, bands: 7, pq: .nan)], at: 0)
        return result
    }

    /// A scalar layer's pixels are its values, NaN where a point has none (CI of a point not indexed, a PQ that is not a number) or has
    /// not been reached; the canvas the room draws spans the finite values and masks the rest; the legend says what the grey is.
    func testAScalarLayerIsItsValuesWithNoValueMasked() throws {
        var result = try Self.firstRowLanded()
        let ci = IndexingRaster.scalarPixels(result, layer: .confidence)
        XCTAssertEqual(ci.count, 6)
        XCTAssertEqual(ci[0], 0.8)
        XCTAssertEqual(ci[2], 0.2)
        XCTAssertEqual([1, 3, 4, 5].map { ci[$0].isNaN }, [true, true, true, true], "not indexed and not reached have no value")
        let bands = IndexingRaster.scalarPixels(result, layer: .bands)
        XCTAssertEqual(Array(bands[0..<3]), [9, 2, 7], "a point not indexed keeps its band count")
        XCTAssertTrue(bands[3...].allSatisfy(\.isNaN))

        let canvas = CanvasPixels.make(width: 3, height: 2, pixels: ci)
        XCTAssertEqual(canvas.rawRange, 0.2...0.8)
        XCTAssertEqual(canvas.normalized[0], 1)
        XCTAssertEqual(canvas.normalized[2], 0)
        XCTAssertEqual(canvas.normalized[1], FloatImage.invalidDisplayValue, "drawn as the masked grey, not as the colormap's low end")

        XCTAssertEqual(IndexingRaster.maskedWords(result, layer: .confidence), "grey: not indexed · not reached")
        XCTAssertEqual(IndexingRaster.maskedWords(result, layer: .bands), "grey: not reached")
        XCTAssertEqual(IndexingRaster.maskedWords(result, layer: .patternQuality), "grey: no value · not reached")
        result.land([Self.solution(Self.q0, confidence: 0.5, fit: 0.7, bands: 8, pq: 900),
                     Self.solution(Self.q2, confidence: 0.6, fit: 0.9, bands: 8, pq: 950),
                     Self.solution(Self.q0, confidence: 0.7, fit: 1.1, bands: 9, pq: 990)], at: 1)
        XCTAssertEqual(IndexingRaster.maskedWords(result, layer: .confidence), "grey: not indexed")
        XCTAssertNil(IndexingRaster.maskedWords(result, layer: .bands))

        XCTAssertEqual(result.scalarTitle(.confidence), "Confidence index")
        XCTAssertEqual(result.scalarTitle(.fit), "Fit (°)")
        XCTAssertEqual(IndexingResult(scanRows: 1, scanColumns: 1, phases: [], metric: .ncc).scalarTitle(.score), "NCC")
    }

    /// The Euler layer is pointwise and in both methods' lists, after the IPF layers; each indexed point is orix's Euler colour of its
    /// orientation in the phase's point group, a point not indexed black, a point not reached the navigator's dark grey.
    func testTheEulerLayerIsOrixsEulerKey() throws {
        XCTAssertEqual(IndexingLayer.layers(for: .hough), [.ipfZ, .ipfX, .ipfY, .euler, .phase, .confidence, .fit, .bands, .patternQuality])
        XCTAssertEqual(IndexingLayer.layers(for: .dictionary), [.ipfZ, .ipfX, .ipfY, .euler, .phase, .score, .osm])
        XCTAssertTrue(IndexingLayer.euler.isPointwise)
        XCTAssertNil(IndexingLayer.euler.direction)
        XCTAssertFalse(IndexingLayer.osm.isPointwise)

        let result = try Self.firstRowLanded()
        let rgba = IndexingRaster.rgba(result, palette: IndexingPalette(layer: .euler, phases: result.phases), backdrop: nil)
        XCTAssertEqual(rgba.count, 6 * 4)
        let key = EulerColorKey(PointGroup.oh)
        for (i, q) in [(0, Self.q0), (2, Self.q2)] {
            let colour = key.color(of: [q])[0]
            for c in 0..<3 { XCTAssertEqual(Double(rgba[i * 4 + c]), (colour[c] * 255).rounded(), "point \(i), channel \(c)") }
        }
        XCTAssertEqual(Array(rgba[4..<8]), [0, 0, 0, 255], "not indexed is black, as orix draws not_indexed")
        XCTAssertEqual(Array(rgba[12..<16]), [38, 38, 38, 255], "not reached, no navigator: dark grey")
        XCTAssertNotEqual(Array(rgba[0..<3]), Array(IndexingRaster.rgba(result, palette: IndexingPalette(layer: .ipfZ, phases: result.phases),
                                                                          backdrop: nil)[0..<3]), "Euler is not IPF-Z")
    }

    /// The Euler legend names each angle's range in its channel: the Euler fundamental region of the proper subgroup (432 for m-3m,
    /// 622 for 6/mmm), the maxima orix's key divides by.
    func testTheEulerLegendNamesTheFundamentalRegion() throws {
        XCTAssertEqual(IndexingColorKey.eulerWords(PointGroup.oh), "R φ₁ 0–360° · G Φ 0–90° · B φ₂ 0–90°")
        XCTAssertEqual(IndexingColorKey.eulerWords(try XCTUnwrap(PointGroup.named("6/mmm"))), "R φ₁ 0–360° · G Φ 0–90° · B φ₂ 0–60°")
    }
}
