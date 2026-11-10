//
//  MapDisplayWindowTests.swift
//  The SEM maps open on their 1st to 99th percentile (control placement §11; drive 2026-11-08, where a few outliers drew the Ni mean,
//  ADP and KAM maps almost all white or black): `DisplayWindow.quantileWindow` reads numpy's linear percentiles from a canvas, and an
//  `ImagePresentation` with `defaultQuantiles` takes each new canvas's window until the person sets one, and returns to it on Reset Range.
//  The image rooms keep the full range.
//

import XCTest
import TEMCore
import TEMSession
@testable import macTEM

nonisolated final class MapDisplayWindowTests: XCTestCase {
    private static func canvas(_ pixels: [Float]) -> CanvasPixels { CanvasPixels.make(width: pixels.count, height: 1, pixels: pixels) }

    /// numpy: `np.percentile(np.arange(101), [1, 99])` is [1, 99]; with one outlier at −1000 under 0…198, [0.99, 196.01]: the outlier
    /// is outside the window.
    /// Mutation: the min–max window (−1000…198), or a nearest-rank percentile.
    func testTheQuantileWindowIsNumpysLinearPercentile() throws {
        let window = try XCTUnwrap(DisplayWindow.quantileWindow(of: Self.canvas((0...100).map(Float.init)), 0.01...0.99))
        XCTAssertEqual(window.lowerBound, 1, accuracy: 1e-3)
        XCTAssertEqual(window.upperBound, 99, accuracy: 1e-3)
        let outlier = try XCTUnwrap(DisplayWindow.quantileWindow(of: Self.canvas([-1000] + (0...198).map(Float.init)), 0.01...0.99))
        XCTAssertEqual(outlier.lowerBound, 0.99, accuracy: 2e-2)
        XCTAssertEqual(outlier.upperBound, 196.01, accuracy: 2e-2)
        XCTAssertNil(DisplayWindow.quantileWindow(of: Self.canvas([5, 5, 5]), 0.01...0.99), "a constant map has no window")
        XCTAssertNil(DisplayWindow.quantileWindow(of: Self.canvas([.nan, 3]), 0.01...0.99), "one finite pixel has no window")
    }

    /// A map presentation opens on its canvas's quantile window, follows a new canvas while untouched, keeps the person's window, and
    /// Reset Range returns to the quantile window; a plain presentation keeps the full range. Mutation: `show` ignores the quantiles, or
    /// overwrites a window the person set.
    @MainActor func testAMapPresentationOpensOnItsPercentilesAndKeepsAPersonsWindow() throws {
        let map = ImagePresentation()
        map.defaultQuantiles = 0.01...0.99
        map.show(Self.canvas((0...100).map(Float.init)))
        XCTAssertEqual(try XCTUnwrap(map.windowLow), 1, accuracy: 1e-3)
        XCTAssertEqual(try XCTUnwrap(map.windowHigh), 99, accuracy: 1e-3)

        map.show(Self.canvas((0...100).map { Float($0) * 2 }))
        XCTAssertEqual(try XCTUnwrap(map.windowHigh), 198, accuracy: 1e-2, "an untouched window follows the new map")

        map.windowLow = 50
        map.show(Self.canvas((0...100).map { Float($0) * 3 }))
        XCTAssertEqual(map.windowLow, 50, "the person's window stays")
        map.resetWindow()
        XCTAssertEqual(try XCTUnwrap(map.windowLow), 3, accuracy: 1e-2)
        XCTAssertEqual(try XCTUnwrap(map.windowHigh), 297, accuracy: 1e-2)

        let image = ImagePresentation()
        image.show(Self.canvas((0...100).map(Float.init)))
        XCTAssertNil(image.windowLow)
        XCTAssertNil(image.windowHigh)
        image.resetWindow()
        XCTAssertNil(image.windowLow)
    }

    /// The three SEM map presentations open on their percentiles; the patterns and the image rooms do not.
    @MainActor func testTheSEMMapsOptIn() {
        let state = AppState(launch: LaunchOptions(arguments: []))
        XCTAssertEqual(state.ebsd.mapPresentation.defaultQuantiles, 0.01...0.99)
        XCTAssertEqual(state.maps.propertyPresentation.defaultQuantiles, 0.01...0.99)
        XCTAssertEqual(state.indexing.mapPresentation.defaultQuantiles, 0.01...0.99)
        XCTAssertNil(state.ebsd.patternPresentation.defaultQuantiles)
        XCTAssertNil(ImagePresentation().defaultQuantiles)
    }
}
