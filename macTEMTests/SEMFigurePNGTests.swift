//
//  SEMFigurePNGTests.swift
//  The SEM rooms' figure PNGs through the app's one encoder (`ImageExport.encodePNG`, #331): the Maps room's map figure and the
//  Patterns room's colour mix (the Indexing room's colour map is the same function) carry the file's name as Title and macTEM as
//  Software, as the Patterns room's map PNG does; the pixels are ImageIO's, as before; the encoder writes its text in order, leaves
//  out what it is not given and makes a control character a space; the IPF colour key's image comes from the one RGBA builder
//  (`MapsFigure.cgImage`), smoothed or not. The texture figure's Title is pinned in MapsAnalysisTests, the overlay figure's Description
//  in KikuchiOverlayExportTests.
//  Red before: the map figure dropped its file name (`_ = fileName`) and neither PNG carried a text chunk.
//

import CoreGraphics
import FormatoCore
import Foundation
import ImageIO
import TEMCore
import TEMSession
import XCTest
@testable import macTEM

nonisolated final class SEMFigurePNGTests: XCTestCase {

    private static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")

    /// 3 × 2 opaque pixels, each its own colour, row 0 first.
    private static let planted: [UInt8] = [
        255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255,
        10, 20, 30, 255, 200, 150, 100, 255, 1, 2, 3, 255,
    ]

    /// The PNG's Title, Software and Description text chunks, in file order.
    private static func text(_ png: Data) throws -> [PNGTextEntry] {
        try FormatoPNG.textEntries(in: png).filter { ["Title", "Software", "Description"].contains($0.keyword) }
    }

    /// The PNG's pixels as 8-bit sRGB RGBA, row 0 first, through ImageIO and a 1:1, non-interpolated draw.
    private static func rgba(_ png: Data) throws -> [UInt8] {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                              bytesPerRow: image.width * 4, space: space,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        var out: [UInt8] = []
        for row in 0..<image.height {
            out.append(contentsOf: UnsafeMutableBufferPointer(start: bytes + row * context.bytesPerRow, count: image.width * 4))
        }
        return out
    }

    /// Map PNG… of the Maps room carries the file's name as Title and macTEM as Software. Red before: the figure dropped its
    /// file name and wrote no text chunk.
    @MainActor func testTheMapFigureCarriesItsFileName() throws {
        let map = try ANGReader.read(url: Self.fixtures.appendingPathComponent("ebsd-tsl.ang")).map
        let png = try MapsFigure.png(raster: OrientationMaps.raster(.phase, of: map), layer: .phase, map: map, keys: [],
                                     presentation: ImagePresentation(), fileName: "sdss.ang")
        XCTAssertEqual(try Self.text(png), [PNGTextEntry(keyword: "Title", value: "sdss.ang"),
                                            PNGTextEntry(keyword: "Software", value: "macTEM")])
    }

    /// The Patterns room's colour mix: the planted pixels come back as they went in, as ImageIO wrote them before, and the file's
    /// name is the Title. Red before: no text chunk (and no file name to give).
    func testTheColourMixKeepsItsPixelsAndCarriesItsFileName() throws {
        let png = try XCTUnwrap(PatternsRoomState.mixPNG(rgba: Self.planted, width: 3, height: 2, fileName: "patterns_v2.h5"))
        XCTAssertEqual(try Self.text(png), [PNGTextEntry(keyword: "Title", value: "patterns_v2.h5"),
                                            PNGTextEntry(keyword: "Software", value: "macTEM")])
        XCTAssertEqual(try Self.rgba(png), Self.planted)
    }

    /// The IPF colour key goes through the one RGBA builder (#331), for the Maps room's key and figure (each pixel a block) and for the
    /// Indexing room's legend (`IndexingIPFKey.picture`, smoothed with `interpolate`; its own builder is gone). Every property that
    /// decides how the key draws is pinned: its premultiplied bytes as they are, 8-bit RGBA with the alpha last and premultiplied in
    /// sRGB, no decode array, the default intent. The Indexing builder made exactly this image (compared property by property and drawn
    /// smoothed at 7×, byte for byte, on six point groups before it was deleted), so its legend draws as it did.
    /// Red under: a second builder's bytes or colour space, the Maps key smoothed (its pixels would change), the flag ignored, the
    /// legend's picture not smoothed or not this builder's.
    func testTheColourKeyImageIsItsBytesWithOrWithoutSmoothing() throws {
        for group in ["432", "6/mmm"] {
            let key = OrientationMaps.keyImage(for: try XCTUnwrap(PointGroup.named(group))).0
            let block = try XCTUnwrap(MapsFigure.cgImage(key))
            let smooth = try XCTUnwrap(MapsFigure.cgImage(key, interpolate: true))
            let legend = try XCTUnwrap(IndexingIPFKey.picture(key))
            XCTAssertFalse(block.shouldInterpolate, group)
            XCTAssertTrue(smooth.shouldInterpolate, group)
            XCTAssertTrue(legend.shouldInterpolate, group)
            for image in [block, smooth, legend] {
                XCTAssertEqual([image.width, image.height, image.bitsPerComponent, image.bitsPerPixel, image.bytesPerRow],
                               [key.width, key.height, 8, 32, key.width * 4], group)
                XCTAssertEqual(image.bitmapInfo, CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), group)
                XCTAssertEqual(image.alphaInfo, .premultipliedLast, group)
                XCTAssertEqual(image.colorSpace?.name, CGColorSpace.sRGB, group)
                XCTAssertNil(image.decode, group)
                XCTAssertEqual(image.renderingIntent, .defaultIntent, group)
                let bytes = try XCTUnwrap(image.dataProvider?.data) as Data
                XCTAssertEqual([UInt8](bytes), key.premultipliedRGBA8, group)
            }
        }
    }

    /// The encoder writes Title, Software and Description in that order, leaves out what it is not given and makes a control
    /// character a space, so a NUL in a file's name cannot make its chunk unwritable; the pixels are the picture's.
    func testTheEncoderWritesItsTextInOrderOnOneLine() throws {
        let image = try XCTUnwrap(MapsFigure.cgImage(premultipliedRGBA: Self.planted, width: 3, height: 2))
        let png = try ImageExport.encodePNG(image, title: "a\u{0}b.ang", description: "two\nlines")
        XCTAssertEqual(try Self.text(png), [PNGTextEntry(keyword: "Title", value: "a b.ang"),
                                            PNGTextEntry(keyword: "Description", value: "two lines")])
        XCTAssertEqual(try Self.rgba(png), Self.planted)
    }
}
