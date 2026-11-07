//
//  SEMDatabarStripTests.swift
//  The databar shown as a strip under the picture (design §3): the read always cuts the vendor's rows off the image
//  and hands them on as their own canvas; the pane fits the picture and the strip together at one on-screen width.
//

import CoreGraphics
import XCTest
import ImagoCore
import TEMCore
import TEMSession
@testable import macTEM

nonisolated final class SEMDatabarStripTests: XCTestCase {
    func testTheDatabarIsTheRowsTheCropCuts() throws {
        var sem = SEMImageMetadata(vendor: .thermo, imageWidth: 3, imageHeight: 4, stageUnit: "m")
        sem.databarRows = 1
        let pixels: [Float] = (0..<12).map(Float.init)
        let image = CalibratedImage(width: 3, height: 4, pixels: pixels, x: AxisCalibration(scale: 1e-8, unit: "m"), y: nil,
                                    fileName: "h.tif", source: "page 1", voltage: nil)
        let strip = try XCTUnwrap(sem.databar(of: image))
        XCTAssertEqual(strip.width, 3)
        XCTAssertEqual(strip.height, 1)
        XCTAssertEqual(strip.pixels, [9, 10, 11], "the last row, the one `cropped` cuts")
        XCTAssertEqual(sem.cropped(image).pixels + strip.pixels, pixels, "scan and strip together are the frame")
        let otherSize = CalibratedImage(width: 3, height: 5, pixels: pixels + [0, 0, 0], x: nil, y: nil, fileName: "h.tif", source: "page 1", voltage: nil)
        XCTAssertNil(sem.databar(of: otherSize), "a frame of another height has no strip, as it has no crop")
        sem.databarRows = nil
        XCTAssertNil(sem.databar(of: image))
    }

    func testTheDemoSEMImageReadsAsTheScanWithItsDatabarBeside() async throws {
        let url = try DemoDocuments.semImageFile()
        let (image, canvas, _, sem, databar) = try await AppState.read(url)
        XCTAssertEqual(sem?.databarRows, DemoDocuments.semDatabarRows)
        XCTAssertEqual(image.height, DemoDocuments.semScanRows, "the picture is the scan alone, whatever the Databar control says")
        XCTAssertEqual(canvas.height, DemoDocuments.semScanRows)
        let strip = try XCTUnwrap(databar)
        XCTAssertEqual(strip.width, DemoDocuments.semWidth)
        XCTAssertEqual(strip.height, DemoDocuments.semDatabarRows)
        XCTAssertTrue(strip.normalized.contains { $0 > 0.5 }, "the demo's databar blocks are drawn bright")
    }

    func testThePictureAndTheStripShareOneWidth() {
        // A 512 x 442 scan with a 29-row strip in a wide pane: height-limited, the two fill it top to bottom.
        let wide = DatabarLayout.split(CGSize(width: 1000, height: 471), width: 512, height: 442, stripWidth: 512, stripRows: 29)
        XCTAssertEqual(wide.picture.width, wide.strip.width)
        XCTAssertEqual(wide.picture.height + wide.strip.height, 471, accuracy: 1e-9)
        XCTAssertEqual(wide.picture.width, 512, accuracy: 1e-9)
        XCTAssertEqual(wide.strip.height, 29, accuracy: 1e-9)
        // In a tall pane, width-limited: the picture keeps its pixel aspect and the strip its rows at the same scale.
        let tall = DatabarLayout.split(CGSize(width: 256, height: 1000), width: 512, height: 442, stripWidth: 512, stripRows: 29)
        XCTAssertEqual(tall.picture.width, 256, accuracy: 1e-9)
        XCTAssertEqual(tall.picture.height, 221, accuracy: 1e-9)
        XCTAssertEqual(tall.strip.height, 14.5, accuracy: 1e-9)
        XCTAssertEqual(DatabarLayout.split(CGSize(width: 100, height: 100), width: 10, height: 10, stripWidth: 10, stripRows: 0).strip, .zero)
    }

    func testTheStripPictureIsGreyOfTheNormalisedRows() throws {
        let strip = CanvasPixels(width: 2, height: 1, normalized: [0, 1], contentVersion: 1, rawRange: 0...255)
        let picture = try XCTUnwrap(DatabarStrip.picture(strip))
        XCTAssertEqual(picture.width, 2)
        XCTAssertEqual(picture.height, 1)
        XCTAssertEqual(picture.bitsPerPixel, 8)
        XCTAssertNil(DatabarStrip.picture(CanvasPixels(width: 2, height: 1, normalized: [0], contentVersion: 1, rawRange: nil)))
    }
}
