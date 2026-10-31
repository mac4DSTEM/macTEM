//
//  TIFFImageReaderTests.swift
//  The TIFF reader on TIFFs built in memory with known values: the planted truth is the bytes
//  written here. The parity against RosettaSciIO and tifffile is FormatoKit's; these pin the reader's
//  own rules without Python — sample types and byte order, the grey-render rule, the refusals, and the Velox
//  convention's cross-check.
//

import ImagoCore
import XCTest
import TEMCore
@testable import macTEM

nonisolated final class TIFFImageReaderTests: XCTestCase {

    // MARK: Pixels

    func testUnsigned16ReadsEveryPixelRowMajorWithRowZeroFirst() throws {
        let w = 5, h = 3
        let values = (0..<(w * h)).map { UInt16(40_000 + $0 * 1_001) }   // above Int16.max: width and sign matter
        let tiff = TIFFBuilder(width: w, height: h, bits: 16, format: 1, samples: 1,
                               bytes: values.flatMap { le($0) })
        let image = try TIFFImageReader.read(data: tiff.build(), fileName: "u16.tif")
        XCTAssertEqual(image.width, 5)
        XCTAssertEqual(image.height, 3)
        XCTAssertEqual(image.pixels, values.map(Float.init))
        XCTAssertNil(image.x, "no convention: uncalibrated")
        XCTAssertEqual(image.notes, [])
    }

    func testSignedAndFloatSamplesKeepTheirSign() throws {
        let i16: [Int16] = [-32_768, -1, 0, 1, 32_767, -12_345]
        var image = try TIFFImageReader.read(
            data: TIFFBuilder(width: 3, height: 2, bits: 16, format: 2, samples: 1,
                              bytes: i16.flatMap { le(UInt16(bitPattern: $0)) }).build(), fileName: "i16.tif")
        XCTAssertEqual(image.pixels, i16.map(Float.init))

        let f32: [Float] = [-1.5, 0, 3.25e-7, 1e30, -0.0, 42]
        image = try TIFFImageReader.read(
            data: TIFFBuilder(width: 2, height: 3, bits: 32, format: 3, samples: 1,
                              bytes: f32.flatMap { le($0.bitPattern) }).build(), fileName: "f32.tif")
        XCTAssertEqual(image.pixels.map(\.bitPattern), f32.map(\.bitPattern))
    }

    func testBigEndianReadsTheSameValues() throws {
        let values: [UInt16] = [1, 256, 513, 65_535]
        var tiff = TIFFBuilder(width: 2, height: 2, bits: 16, format: 1, samples: 1,
                               bytes: values.flatMap { be($0) })
        tiff.bigEndian = true
        XCTAssertEqual(try TIFFImageReader.read(data: tiff.build(), fileName: "be.tif").pixels, values.map(Float.init))
    }

    // MARK: Grey renders

    func testAnEqualChannelRGBReadsAsOneGreyChannelLabelledARender() throws {
        let grey: [UInt8] = [0, 17, 255, 128, 3, 200]
        let tiff = TIFFBuilder(width: 3, height: 2, bits: 8, format: 1, samples: 3,
                               bytes: grey.flatMap { [$0, $0, $0] })
        let image = try TIFFImageReader.read(data: tiff.build(), fileName: "render.tif")
        XCTAssertEqual(image.pixels, grey.map(Float.init))
        XCTAssertEqual(image.notes, [TIFFImageReader.Note.render])
        XCTAssertEqual(image.notes, ["8-bit render, not counts"], "the wording, pinned literally")
        XCTAssertTrue(image.source.contains("not counts"), image.source)
    }

    func testOneUnequalPixelRefusesTheColourImageNamingWhere() {
        var bytes = [UInt8](repeating: 9, count: 3 * 2 * 3)
        bytes[(1 * 3 + 2) * 3 + 1] = 10                                  // row 1, column 2, green
        let tiff = TIFFBuilder(width: 3, height: 2, bits: 8, format: 1, samples: 3, bytes: bytes)
        XCTAssertThrowsError(try TIFFImageReader.read(data: tiff.build(), fileName: "colour.tif")) {
            XCTAssertEqual($0 as? TIFFImageReader.Refusal, .unequalChannels(row: 1, column: 2))
        }
    }

    // MARK: Refusals

    func testCompressionTilesPagesAndWhiteIsZeroAreRefusedByName() {
        func refusal(_ edit: (inout TIFFBuilder) -> Void) -> TIFFImageReader.Refusal? {
            var tiff = TIFFBuilder(width: 2, height: 2, bits: 8, format: 1, samples: 1, bytes: [1, 2, 3, 4])
            edit(&tiff)
            do { _ = try TIFFImageReader.read(data: tiff.build(), fileName: "x.tif"); return nil }
            catch { return error as? TIFFImageReader.Refusal }
        }
        XCTAssertEqual(refusal { $0.extra[259] = .short([5]) }, .compressed(scheme: 5))
        XCTAssertEqual(refusal { $0.extra[322] = .short([16]) }, .tiled)
        XCTAssertEqual(refusal { $0.secondPage = true }, .multiPage)
        XCTAssertEqual(refusal { $0.photometric = 0 }, .sampleFormat("1 sample(s) per pixel, photometric 0, planar 1"))
        XCTAssertEqual(refusal { $0.bits = 12 }.map { "\($0)" }?.contains("sampleFormat"), true)
        XCTAssertThrowsError(try TIFFImageReader.read(data: Data("GIF89a..".utf8), fileName: "x.tif")) {
            XCTAssertEqual($0 as? TIFFImageReader.Refusal, .notTIFF)
        }
    }

    // MARK: The Velox convention (tag 34683)

    func testVeloxPixelSizeCalibratesWhenTheResolutionTagsAgree() throws {
        let scale = 1.6448334831730098e-09
        let image = try TIFFImageReader.read(data: velox(scale: scale, perCm: 6_079_643).build(), fileName: "ceta.tif")
        XCTAssertEqual(image.x, AxisCalibration(scale: scale, unit: "m", origin: 0))
        XCTAssertEqual(image.y, AxisCalibration(scale: scale, unit: "m", origin: 0))
        XCTAssertEqual(image.notes, [TIFFImageReader.Note.render, TIFFImageReader.Note.veloxUnvalidated])
        XCTAssertEqual(image.notes, ["8-bit render, not counts", "scale unvalidated (one acquisition)"], "the wording, pinned literally")
    }

    func testTheAgreementBandIsTheTagsOwnRoundingNotMore() throws {
        // 0.01 / 2.1016264901077918e-09 = 4 758 218.3… per cm: the tag stores the rounded count as a float32.
        let scale = 2.1016264901077918e-09
        let count = (0.01 / scale).rounded()
        XCTAssertNotNil(try TIFFImageReader.read(data: velox(scale: scale, perCm: Float(count)).build(),
                                                 fileName: "a.tif").x, "the rounded count agrees")
        let off = try TIFFImageReader.read(data: velox(scale: scale, perCm: Float(count + 2)).build(), fileName: "b.tif")
        XCTAssertNil(off.x, "two counts off is outside half a count plus a float32 step")
        XCTAssertEqual(off.notes, [TIFFImageReader.Note.render, TIFFImageReader.Note.veloxDisagree])
        XCTAssertEqual(off.notes, ["8-bit render, not counts", "uncalibrated: the Velox XML and the resolution tags disagree"], "the wording, pinned literally")
    }

    func testDisagreeingTagsOpenUncalibratedAndSayWhy() throws {
        let image = try TIFFImageReader.read(
            data: velox(scale: 1.6448334831730098e-09, perCm: 6_079_643 * 1.1).build(), fileName: "bad.tif")
        XCTAssertNil(image.x)
        XCTAssertNil(image.y)
        XCTAssertEqual(image.pixels.count, 4, "the pixels are never refused for a calibration disagreement")
        XCTAssertEqual(image.notes.last, TIFFImageReader.Note.veloxDisagree)
    }

    // MARK: Found by a review (2026-10-12)

    func testACorruptSizeIsRefusedBeforeAnyAllocationNotATrap() {
        var tiff = TIFFBuilder(width: 2, height: 2, bits: 16, format: 1, samples: 1, bytes: [UInt8](repeating: 1, count: 8))
        tiff.extra[256] = .long([0xFFFF_FFFF])
        tiff.extra[257] = .long([0xFFFF_FFFF])
        XCTAssertThrowsError(try TIFFImageReader.read(data: tiff.build(), fileName: "huge.tif")) {
            XCTAssertEqual($0 as? TIFFImageReader.Refusal, .truncated)
        }
    }

    func testAnImageJStackInOneDirectoryIsRefusedNotReadAsItsFirstFrame() {
        for planes in ["images=3", "slices=2", "frames=2", "channels=2"] {
            var tiff = TIFFBuilder(width: 2, height: 2, bits: 8, format: 1, samples: 1, bytes: [UInt8](repeating: 1, count: 12))
            tiff.extra[270] = .ascii("ImageJ=1.11a\n\(planes)\nunit=micron\n")
            XCTAssertThrowsError(try TIFFImageReader.read(data: tiff.build(), fileName: "stack.tif"), planes) {
                XCTAssertEqual($0 as? TIFFImageReader.Refusal, .multiPage, planes)
            }
        }
    }

    func testFEIPixelWidthIsTheWidthsScaleByEitherPath() throws {
        func fei(_ ini: String) throws -> CalibratedImage {
            var tiff = TIFFBuilder(width: 2, height: 2, bits: 8, format: 1, samples: 1, bytes: [1, 2, 3, 4])
            tiff.extra[34682] = .ascii(ini)
            return try TIFFImageReader.read(data: tiff.build(), fileName: "fei.tif")
        }
        var image = try fei("[Scan]\n PixelWidth = 2e-09 \nPixelHeight=5e-09\n")
        XCTAssertEqual(image.x, AxisCalibration(scale: 2e-9, unit: "m", origin: 0), "PixelWidth on x (DEVIATION from the reference's swap)")
        XCTAssertEqual(image.y, AxisCalibration(scale: 5e-9, unit: "m", origin: 0))
        image = try fei("[IRBeam]\nHFW=0.001\nVFW=0.004\n[Image]\nResolutionX=500\nResolutionY=1000\n")
        XCTAssertEqual(image.x?.scale, 0.001 / 500)
        XCTAssertEqual(image.y?.scale, 0.004 / 1000)
        image = try fei("[Scan]\nPixelWidth=3,4e-6\nPixelHeight=3,4e-6\n[IRBeam]\nHFW=1\nVFW=1\n[Image]\nResolutionX=1\nResolutionY=1\n")
        XCTAssertNil(image.x, "a value that is not a number fails the reading; no fallback to [IRBeam]")
    }

    func testTheVeloxCrossCheckCoversEachAxisAndStopsAtItsBound() throws {
        let scale = 2.1016264901077918e-09
        let implied = 0.01 / scale
        let bound = 0.5 + Double(Float(implied).ulp) / 2
        func image(x: Double?, y: Double?) throws -> CalibratedImage {
            var tiff = velox(scale: scale, perCm: 1)
            tiff.extra[65450] = x.map { .rational(UInt32($0.rounded()), 1) }
            tiff.extra[65451] = y.map { .rational(UInt32($0.rounded()), 1) }
            return try TIFFImageReader.read(data: tiff.build(), fileName: "v.tif")
        }
        XCTAssertNotNil(try image(x: implied, y: implied).x)
        XCTAssertNil(try image(x: implied, y: implied + 5).x, "a disagreeing y alone uncalibrates both axes")
        XCTAssertNotNil(try image(x: implied, y: nil).x, "a missing tag is not a disagreement")
        XCTAssertNil(try image(x: (implied + bound + 1).rounded(.up), y: implied).x, "past the bound by a count")
        // Hundredths of a count, so the band's edge itself is tested: 0.05 inside agrees, 0.25 outside does not.
        func exact(_ perCm: Double) throws -> CalibratedImage {
            var tiff = velox(scale: scale, perCm: 1)
            tiff.extra[65450] = .rational(UInt32((perCm * 100).rounded()), 100)
            tiff.extra[65451] = .rational(UInt32((implied * 100).rounded()), 100)
            return try TIFFImageReader.read(data: tiff.build(), fileName: "edge.tif")
        }
        XCTAssertNotNil(try exact(implied + bound - 0.05).x, "just inside the band")
        XCTAssertNil(try exact(implied + bound + 0.25).x, "just outside the band")
    }

    func testTrimmedImageJLinesCalibrateAndAMissingResolutionDoesNot() throws {
        var tiff = TIFFBuilder(width: 2, height: 2, bits: 8, format: 1, samples: 1, bytes: [1, 2, 3, 4])
        tiff.extra[270] = .ascii("ImageJ=1.11a\nunit = micron\n")
        tiff.extra[282] = .rational(4, 1)
        tiff.extra[283] = .rational(5, 1)
        var image = try TIFFImageReader.read(data: tiff.build(), fileName: "ij.tif")
        XCTAssertEqual(image.x, AxisCalibration(scale: 0.25, unit: "µm", origin: 0))
        XCTAssertEqual(image.y, AxisCalibration(scale: 0.2, unit: "µm", origin: 0))
        tiff.extra[282] = nil
        image = try TIFFImageReader.read(data: tiff.build(), fileName: "ij.tif")
        XCTAssertNil(image.x, "a unit without a resolution is not a calibration")
        XCTAssertNil(image.y)
    }

    func testADigitalMicrographScaleOfZeroIsNotACalibration() throws {
        var tiff = TIFFBuilder(width: 2, height: 2, bits: 8, format: 1, samples: 1, bytes: [1, 2, 3, 4])
        tiff.extra[65003] = .ascii("nm")
        tiff.extra[65004] = .ascii("nm")
        tiff.extra[65009] = .double(0)
        tiff.extra[65010] = .double(0.5)
        tiff.extra[65007] = .double(1.0)
        let image = try TIFFImageReader.read(data: tiff.build(), fileName: "dm.tif")
        XCTAssertNil(image.x)
        XCTAssertEqual(image.y, AxisCalibration(scale: 0.5, unit: "nm", origin: -2), "origin = −offset/scale")
    }

    func testVeloxWithoutAPixelSizeFallsThroughToImageJ() throws {
        var tiff = TIFFBuilder(width: 2, height: 2, bits: 8, format: 1, samples: 1, bytes: [1, 2, 3, 4])
        tiff.extra[34683] = .ascii("<?xml version=\"1.0\"?><Metadata><BinaryResult></BinaryResult></Metadata>")
        tiff.extra[270] = .ascii("ImageJ=1.11a\nunit=micron\n")
        tiff.extra[282] = .rational(2, 1)
        tiff.extra[283] = .rational(2, 1)
        let image = try TIFFImageReader.read(data: tiff.build(), fileName: "v.tif")
        XCTAssertEqual(image.x, AxisCalibration(scale: 0.5, unit: "µm", origin: 0))
        XCTAssertEqual(image.notes, [])
    }

    // MARK: Helpers

    private func velox(scale: Double, perCm: Float) -> TIFFBuilder {
        var tiff = TIFFBuilder(width: 2, height: 2, bits: 8, format: 1, samples: 3,
                               bytes: [UInt8](repeating: 7, count: 12))
        let xml = """
        <?xml version="1.0" encoding="utf-8"?><Metadata><BinaryResult><ImageSize><X>4096</X><Y>4096</Y></ImageSize>\
        <PixelSize><X unit="m">\(scale)</X><Y unit="m">\(scale)</Y></PixelSize>\
        <Offset><X>-1.6e-06</X><Y>-1.6e-06</Y></Offset></BinaryResult></Metadata>
        """
        tiff.extra[34683] = .ascii(xml)
        tiff.extra[65450] = .float(perCm)
        tiff.extra[65451] = .float(perCm)
        tiff.extra[65452] = .short([3])
        return tiff
    }
}

private nonisolated func le(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8)] }
private nonisolated func be(_ v: UInt16) -> [UInt8] { [UInt8(v >> 8), UInt8(v & 0xFF)] }
private nonisolated func le(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * $0)) & 0xFF) } }

/// A minimal TIFF writer for planted files: one strip, the entries the reader reads, extra tags on demand.
private nonisolated struct TIFFBuilder {
    enum Value { case short([UInt16]), long([UInt32]), ascii(String), float(Float), rational(UInt32, UInt32), double(Double) }
    var width: Int, height: Int, bits: Int, format: Int, samples: Int
    var bytes: [UInt8]
    var bigEndian = false
    var photometric: Int?
    var secondPage = false
    var extra: [UInt16: Value] = [:]

    init(width: Int, height: Int, bits: Int, format: Int, samples: Int, bytes: [UInt8]) {
        (self.width, self.height, self.bits, self.format, self.samples, self.bytes) =
            (width, height, bits, format, samples, bytes)
    }

    func build() -> Data {
        var tags: [UInt16: Value] = [
            256: .long([UInt32(width)]), 257: .long([UInt32(height)]),
            258: .short([UInt16](repeating: UInt16(bits), count: samples)),
            262: .short([UInt16(photometric ?? (samples == 3 ? 2 : 1))]),
            277: .short([UInt16(samples)]), 278: .long([UInt32(height)]),
            279: .long([UInt32(bytes.count)]), 284: .short([1]),
            339: .short([UInt16](repeating: UInt16(format), count: samples)),
        ]
        for (k, v) in extra { tags[k] = v }
        // Layout: header (8) | pixels | IFD | out-of-line values | (second IFD)
        let pixelStart = 8
        let ifdStart = pixelStart + bytes.count + (bytes.count % 2)
        tags[273] = .long([UInt32(pixelStart)])
        let keys = tags.keys.sorted()
        var heap: [UInt8] = []
        let heapStart = ifdStart + 2 + 12 * keys.count + 4
        var ifd: [UInt8] = u16(keys.count)
        for key in keys {
            let (type, count, payload) = encode(tags[key]!)
            ifd += u16(Int(key)) + u16(type) + u32(count)
            if payload.count <= 4 {
                ifd += payload + [UInt8](repeating: 0, count: 4 - payload.count)
            } else {
                ifd += u32(heapStart + heap.count)
                heap += payload
                if heap.count % 2 == 1 { heap.append(0) }
            }
        }
        let secondStart = heapStart + heap.count
        ifd += u32(secondPage ? secondStart : 0)
        var out: [UInt8] = (bigEndian ? [0x4D, 0x4D] : [0x49, 0x49]) + u16(42) + u32(ifdStart)
        out += bytes
        if bytes.count % 2 == 1 { out.append(0) }
        out += ifd + heap
        if secondPage { out += u16(0) + u32(0) }
        return Data(out)
    }

    private func encode(_ value: Value) -> (Int, Int, [UInt8]) {
        switch value {
        case .short(let v): (3, v.count, v.flatMap { u16(Int($0)) })
        case .long(let v): (4, v.count, v.flatMap { u32(Int($0)) })
        case .ascii(let s): (2, s.utf8.count + 1, Array(s.utf8) + [0])
        case .float(let f): (11, 1, u32(Int(f.bitPattern)))
        case .rational(let n, let d): (5, 1, u32(Int(n)) + u32(Int(d)))
        case .double(let v):
            (12, 1, bigEndian ? (0..<8).reversed().map { UInt8((v.bitPattern >> (8 * UInt64($0))) & 0xFF) }
                              : (0..<8).map { UInt8((v.bitPattern >> (8 * UInt64($0))) & 0xFF) })
        }
    }

    private func u16(_ v: Int) -> [UInt8] {
        let b = [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)]
        return bigEndian ? b.reversed() : b
    }

    private func u32(_ v: Int) -> [UInt8] {
        let b = (0..<4).map { UInt8((v >> (8 * $0)) & 0xFF) }
        return bigEndian ? b.reversed() : b
    }
}
