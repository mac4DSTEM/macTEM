//
//  IntensityHistogramTests.swift
//  The raw-pixel histogram on small planted arrays whose bins are worked out by hand, a few bins at a time
//  (`bins:`) and then the 96 of the Display section. The parity against numpy 2.5.4's np.histogram — every float32 edge
//  and one ulp either side, constants, non-finite pixels, narrow ranges, 2048² images, real files — is ImagoKit's.
//

import XCTest
import ImagoCore
import TEMCore

nonisolated final class IntensityHistogramTests: XCTestCase {

    // Four bins over [0, 4] have the edges 0, 1, 2, 3, 4 exactly: [0, 1) [1, 2) [2, 3) [3, 4], the last closed.

    func testAValueOnAnEdgeOpensTheBinThatStartsThere() throws {
        let h = try XCTUnwrap(IntensityHistogram.compute([0, 1, 2, 3, 4], bins: 4))
        XCTAssertEqual(h.edges, [0, 1, 2, 3, 4])
        XCTAssertEqual(h.counts, [1, 1, 1, 2], "1 opens [1, 2) and 2 opens [2, 3); the 4 on the last edge joins the 3's bin")
        XCTAssertEqual(h.finiteCount, 5)
        XCTAssertEqual(h.mean, 2)
    }

    func testTheMaximumIsInTheLastBinAndNothingIsLost() throws {
        let h = try XCTUnwrap(IntensityHistogram.compute([0, 4], bins: 4))
        XCTAssertEqual(h.counts, [1, 0, 0, 1], "the last bin is closed: a value on its upper edge is counted there")
        let spread = try XCTUnwrap(IntensityHistogram.compute([0, 0.5, 1.5, 2.5, 3.5, 4, 4, 4], bins: 4))
        XCTAssertEqual(spread.counts, [2, 1, 1, 4])
        XCTAssertEqual(spread.counts.reduce(0, +), spread.finiteCount)
    }

    func testNaNAndInfinitiesAreNeitherCountedNorInTheRange() throws {
        let h = try XCTUnwrap(IntensityHistogram.compute([.nan, .infinity, -.infinity, 0, 4, 2], bins: 4))
        XCTAssertEqual(h.finiteCount, 3)
        XCTAssertEqual(h.minimum, 0)
        XCTAssertEqual(h.maximum, 4)
        XCTAssertEqual(h.mean, 2)
        XCTAssertEqual(h.counts, [1, 0, 1, 1], "0 in [0, 1), 2 in [2, 3), 4 on the last edge")
        XCTAssertEqual(h.firstEdge, 0)
        XCTAssertEqual(h.lastEdge, 4)
    }

    func testAConstantImageIsWidenedByHalfEitherWay() throws {
        let h = try XCTUnwrap(IntensityHistogram.compute([5, 5, 5], bins: 4))
        XCTAssertEqual(h.edges, [4.5, 4.75, 5, 5.25, 5.5], "numpy widens a point range to ±0.5 before it makes the edges")
        XCTAssertEqual(h.counts, [0, 0, 3, 0], "5 is the edge that opens bin 2")
        XCTAssertEqual(h.minimum, 5)
        XCTAssertEqual(h.maximum, 5)
    }

    func testThereIsNoHistogramWhereNothingCanBeBinned() throws {
        XCTAssertNil(IntensityHistogram.compute([.nan, .infinity, -.infinity]), "numpy's f.min() raises on no finite pixel")
        XCTAssertNil(IntensityHistogram.compute([]))
        // One ulp apart: 97 strictly increasing float32 edges do not fit, numpy raises "Too many bins for data range";
        // the statistics of the image are still given, with no bars.
        let next = Float(1).nextUp
        let h = try XCTUnwrap(IntensityHistogram.compute([1, next, 1]))
        XCTAssertTrue(h.counts.isEmpty)
        XCTAssertTrue(h.edges.isEmpty)
        XCTAssertEqual(h.minimum, 1)
        XCTAssertEqual(h.maximum, next)
        XCTAssertEqual(h.finiteCount, 3)
        XCTAssertEqual(h.firstEdge, 1)
        XCTAssertEqual(h.lastEdge, next)
    }

    func testTheDisplaySectionHasNinetySixBins() throws {
        XCTAssertEqual(IntensityHistogram.binCount, 96)
        // The integers 0...96 span 96 and so make one-wide bins; the last bin also holds the 96.
        let h = try XCTUnwrap(IntensityHistogram.compute((0...96).map { Float($0) }))
        XCTAssertEqual(h.counts.count, 96)
        XCTAssertEqual(h.edges.count, 97)
        XCTAssertEqual(h.counts, [Int](repeating: 1, count: 95) + [2])
    }

    func testTheMeanIsSummedInDouble() throws {
        // 2^24 + 1 is not a Float32: a Float32 running sum stays at 2^24 however many 1s follow it.
        let h = try XCTUnwrap(IntensityHistogram.compute([16_777_216, 1, 1, 1, 1], bins: 4))
        XCTAssertEqual(h.mean, 16_777_220.0 / 5.0, "Double: 3 355 444 exactly")
    }

    func testTheIndexIsCorrectedAgainstTheEdges() throws {
        // numpy 2.5.4, 96 float32 bins over [0.1, 0.7]: edge k is 0.1 + k·0.00625 rounded in float32. The index
        // ((p − low)/(high − low))·96, truncated, is wrong within an ulp of an edge, and numpy corrects it against the
        // edges: a value on edge 2 has index 1 (one too low), the float just below edge 18 has index 18 (one too high).
        let low = Float(bitPattern: 0x3dcccccd), high = Float(bitPattern: 0x3f333333)        // 0.1f and 0.7f
        let onEdge2 = Float(bitPattern: 0x3de66666)
        let belowEdge18 = Float(bitPattern: 0x3e599999)
        func uncorrected(_ p: Float) -> Int { Int(((p - low) / (high - low)) * 96) }
        XCTAssertEqual(uncorrected(onEdge2), 1, "the premise: the uncorrected index is one too low here")
        XCTAssertEqual(uncorrected(belowEdge18), 18, "the premise: the uncorrected index is one too high here")

        let h = try XCTUnwrap(IntensityHistogram.compute([low, high, onEdge2, belowEdge18]))
        XCTAssertEqual(h.edges[2], onEdge2)
        XCTAssertEqual(belowEdge18.nextUp, h.edges[18])
        var want = [Int](repeating: 0, count: 96)
        want[0] = 1                  // low, the first edge
        want[2] = 1                  // onEdge2 opens bin 2
        want[17] = 1                 // belowEdge18 is still in bin 17
        want[95] = 1                 // high, the last edge
        XCTAssertEqual(h.counts, want)
    }
}
