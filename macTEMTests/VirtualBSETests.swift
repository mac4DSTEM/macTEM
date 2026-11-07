//
//  VirtualBSETests.swift
//  Virtual BSE imaging (SEM program P1-07, north star F1) against kikuchipy 0.13.1's VirtualBSEImager through the committed reference
//  bundles (tools/parity/sem/references/m1/vbse-*): the detector grid's tile edges as HyperSpy slices them, every tile's sum image
//  (exact), the colour mix of three tiles (within one count), one explicit detector rectangle (exact) and the mean map (rtol 1e-7).
//  The 3 x 3 fixture runs always; the 55 x 75 north-star scan when tools/parity/sem/fetch-data.sh has placed it.
//

import XCTest
import FormatoCore
import TEMCore
import TEMSession

nonisolated final class VirtualBSETests: XCTestCase {

    /// The grid's edges are numpy's `linspace` rounded to pixels, half to even, as HyperSpy's `value2index`: a 60 px side in 7 is
    /// 9, 8, 9, 8, 9, 8, 9 px (measured on kikuchipy 0.13.1 / HyperSpy 2.5.0). Red under: truncation, or rounding half away from zero.
    func testGridEdgesRoundAsHyperSpySlicesTheROI() {
        XCTAssertEqual(VirtualBSEGrid.edges(7, side: 60), [0, 9, 17, 26, 34, 43, 51, 60])
        XCTAssertEqual(VirtualBSEGrid.edges(7, side: 50), [0, 7, 14, 21, 29, 36, 43, 50])
        XCTAssertEqual(VirtualBSEGrid.edges(5, side: 64), [0, 13, 26, 38, 51, 64])
        XCTAssertEqual(VirtualBSEGrid.edges(5, side: 60), [0, 12, 24, 36, 48, 60])
        XCTAssertEqual(VirtualBSEGrid.edges(3, side: 60), [0, 20, 40, 60])
        XCTAssertEqual(VirtualBSEGrid.edges(1, side: 60), [0, 60])
        let grid = VirtualBSEGrid(5)
        XCTAssertEqual(grid.rect(of: VirtualBSETile(row: 2, column: 1), patternRows: 60, patternColumns: 60), DetectorRect(top: 24, bottom: 36, left: 12, right: 24))
        XCTAssertEqual(grid.tiles.count, 25)
        XCTAssertEqual(grid.index(of: VirtualBSETile(row: 2, column: 1)), 11)
        XCTAssertEqual(grid.tiles[11].label, "r2 c1")
        XCTAssertEqual(DetectorRect(top: -3, bottom: 99, left: 5, right: 7).clamped(rows: 60, columns: 6), DetectorRect(top: 0, bottom: 60, left: 5, right: 6))
        XCTAssertEqual(DetectorRect(top: 24, bottom: 36, left: 12, right: 24).pixelCount, 144)
    }

    /// Each image is the sum of its rectangle's pixels per pattern, in map order, read row by row. Red under: a transposed rectangle, a
    /// sum over the wrong pattern, an inclusive right edge.
    func testTheSumImagesOnAPlantedScan() throws {
        var bytes = Data()
        for k in 0..<6 { for p in 0..<4 { var v = UInt16(k * 10 + p).littleEndian; withUnsafeBytes(of: &v) { bytes.append(contentsOf: $0) } } }
        let dataset = EBSDDataset(format: .generated, manufacturer: "test", version: "", scanGroup: "s", scanGroups: ["s"], scanRows: 2, scanColumns: 3,
                                  patternRows: 2, patternColumns: 2, dataType: .uint16, stepY: 1, stepX: 1,
                                  detector: EBSDDetectorGeometry(rows: 2, columns: 2, projectionCenters: []),
                                  patterns: EBSDPatternSource(url: URL(fileURLWithPath: "/planted"), datasetPath: "", fileShape: [2, 3, 2, 2], dataType: .uint16))
        let access = try EBSDMemoryPatterns(dataset: dataset, bytes: bytes)
        let whole = DetectorRect(top: 0, bottom: 2, left: 0, right: 2)
        let topRight = DetectorRect(top: 0, bottom: 1, left: 1, right: 2)
        var reported: [Double] = []
        let images = try XCTUnwrap(VirtualBSEImaging.images(access, rects: [whole, topRight], progress: { reported.append($0) }))
        XCTAssertEqual(images[0], (0..<6).map { Double($0 * 10 * 4 + 6) })
        XCTAssertEqual(images[1], (0..<6).map { Double($0 * 10 + 1) })
        XCTAssertEqual(reported, [0.5, 1])
        XCTAssertNil(try VirtualBSEImaging.images(access, rects: [whole], isCancelled: { true }))
    }

    /// kikuchipy's channel normalisation and the mix's common rescale, on numbers worked by hand: a constant channel sits at 127; the
    /// mix is truncated to uint8 as numpy's `astype`.
    func testTheMixNormalisesEachChannelThenRescalesTheThreeTogether() {
        XCTAssertEqual(VirtualBSEImaging.normalizedChannel([5, 5, 5]), [127, 127, 127])
        XCTAssertEqual(VirtualBSEImaging.median([3, 1, 2]), 2)
        XCTAssertEqual(VirtualBSEImaging.median([4, 1, 2, 3]), 2.5)
        XCTAssertEqual(VirtualBSEImaging.standardDeviation([1, 3]), 1)
        // Channel [0, 2]: median 1, std 1: 127 ± 79.6875 -> 47.3125, 206.6875. The mix of three such channels spans 47.3125...206.6875 -> 0 and 255.
        let mix = VirtualBSEImaging.rgb(red: [0, 2], green: [0, 2], blue: [0, 2])
        XCTAssertEqual(mix, [0, 0, 0, 255, 255, 255])
        XCTAssertEqual(VirtualBSEImaging.rgb(red: [1, 1], green: [1, 1], blue: [1, 1]), [0, 0, 0, 0, 0, 0], "a flat mix has no span: zeros, not NaN")
        XCTAssertEqual(VirtualBSEImaging.rgb(red: [1], green: [1, 2], blue: [1]), [], "channels of different lengths")
    }

    func testTheGridImagesMixAndROIMatchKikuchipyOnTheFixture() throws {
        try compare("m1/vbse-kikuchipy-h5ebsd")
    }

    /// The north-star scan is the shipped demo file (`DemoDocuments.Shipped.nickelEBSD`, the same bytes the bundle's input names).
    func testTheNorthStarScanMatchesItsBundle() throws {
        try compare("m1/vbse-nickel-ebsd-large", input: try XCTUnwrap(DemoDocuments.Shipped.nickelEBSD.url, "DemoData/ is not in the bundle"))
    }

    /// The bundle's grid, mix tiles and rectangle on its input file (`input`, or the bundle's own) through the Swift port, each array at
    /// the bundle's tolerance.
    private func compare(_ caseName: String, input: URL? = nil) throws {
        let ref = try SEMParityReference.load(caseName)
        guard let url = input ?? ref.inputURL(0), FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("\(caseName): its dataset is not on this machine (tools/parity/sem/fetch-data.sh)")
        }
        let dataset = try EBSDH5Reader.read(url: url)
        let reader = try EBSDPatternReader(dataset)
        let shape = try XCTUnwrap(ref.values["grid_shape"] as? [Int])
        let grid = VirtualBSEGrid(rows: shape[0], columns: shape[1])
        let bounds = try XCTUnwrap(ref.values["tile_bounds"] as? [String: [String: Double]])
        for tile in grid.tiles {
            let rect = grid.rect(of: tile, patternRows: dataset.patternRows, patternColumns: dataset.patternColumns)
            let expected = try XCTUnwrap(bounds[tile.id], "no bounds for \(tile.id)")
            XCTAssertEqual(Double(rect.left), expected["left"], tile.id); XCTAssertEqual(Double(rect.right), expected["right"], tile.id)
            XCTAssertEqual(Double(rect.top), expected["top"], tile.id); XCTAssertEqual(Double(rect.bottom), expected["bottom"], tile.id)
        }
        let roiPx = try XCTUnwrap(ref.values["roi_px"] as? [String: Int])
        let roi = DetectorRect(top: try XCTUnwrap(roiPx["top"]), bottom: try XCTUnwrap(roiPx["bottom"]), left: try XCTUnwrap(roiPx["left"]), right: try XCTUnwrap(roiPx["right"]))
        let whole = DetectorRect(top: 0, bottom: dataset.patternRows, left: 0, right: dataset.patternColumns)
        let rects = [whole] + grid.rects(patternRows: dataset.patternRows, patternColumns: dataset.patternColumns) + [roi]
        let images = try XCTUnwrap(VirtualBSEImaging.images(reader, rects: rects))
        let tileImages = Array(images[1...grid.tileCount])
        SEMAssertParity(tileImages.flatMap { $0 }, try ref.array("grid_images"), shape: [grid.rows, grid.columns, dataset.scanRows, dataset.scanColumns])
        SEMAssertParity(try XCTUnwrap(images.last), try ref.array("roi_image"), shape: [dataset.scanRows, dataset.scanColumns])
        let pixels = Double(dataset.patternPixels)
        SEMAssertParity(images[0].map { $0 / pixels }, try ref.array("mean_intensity_map"), shape: [dataset.scanRows, dataset.scanColumns])
        let mixTiles = try XCTUnwrap(ref.values["rgb_tiles"] as? [String: [Int]])
        func channel(_ name: String) throws -> [Float] {
            let rc = try XCTUnwrap(mixTiles[name])
            return tileImages[grid.index(of: VirtualBSETile(row: rc[0], column: rc[1]))].map(Float.init)
        }
        let rgb = VirtualBSEImaging.rgb(red: try channel("r"), green: try channel("g"), blue: try channel("b"))
        SEMAssertParity(rgb.map(Double.init), try ref.array("rgb_image"), shape: [dataset.scanRows, dataset.scanColumns, 3])
        // The mean map the Patterns room draws is the same number.
        let mean = try XCTUnwrap(EBSDBrowsing.meanIntensityMap(reader))
        SEMAssertParity(mean.map(Double.init), try ref.array("mean_intensity_map"))
    }
}
