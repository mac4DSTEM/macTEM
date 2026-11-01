//
//  DisplayNormalizationSeamTests.swift
//  `FloatImage` and `DiffractionPattern` normalise for display through ImagoKit's `DisplayNormalization`: the same
//  values, the same masked sentinel, the same finite range, linear, symmetric and log.
//

import XCTest
import ImagoCore
import TEMCore

nonisolated final class DisplayNormalizationSeamTests: XCTestCase {

    private let pixels: [Float] = [-3, 0, 0.5, 7, .nan, .infinity, 1e6, -.infinity]

    func testFloatImageIsTheKitNormalisation() {
        let image = FloatImage(width: 4, height: 2, pixels: pixels)
        XCTAssertEqual(FloatImage.invalidDisplayValue, DisplayNormalization.invalidValue)
        XCTAssertEqual(image.normalized(), DisplayNormalization.normalized(pixels))
        XCTAssertEqual(image.normalized(symmetric: true), DisplayNormalization.normalized(pixels, symmetric: true))
        XCTAssertEqual(image.minMax.0, -3)
        XCTAssertEqual(image.minMax.1, 1e6)
    }

    func testDiffractionPatternIsTheKitNormalisation() {
        let pattern = DiffractionPattern(qy: 2, qx: 4, pixels: pixels)
        XCTAssertEqual(pattern.normalized(useLog: false), DisplayNormalization.normalized(pixels))
        XCTAssertEqual(pattern.normalized(useLog: true), DisplayNormalization.normalizedLog(pixels))
    }
}
