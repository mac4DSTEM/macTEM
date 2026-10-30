//
//  ImageExportRenderTests.swift
//  The PNG export's own rules (archive: roadmap-registrations-2026-10-15.md V1-10 slice 1, `ImageExport`, `ExportFile`), read back from the bytes it writes:
//  the label drawn in the plate is the label the metadata states (the unit-test half of P3: the metadata's string is
//  rendered alone through the same text routine and found pixel-equal in the label's crop), the bar's exact-white run is
//  the drawn length, the plate-fit edge (a width and a height where the plate just fits and just does not, and nothing is
//  drawn when it does not), the overlay scale table, a side above 16 384 px refused by name, the write over an existing
//  file and to a new one with nothing left beside it, the PNG's format (8-bit RGB, sRGB tag, valid chunk CRCs, pixel
//  (i, j) = canvas column i, row j) and the Description chunk (JSON, sorted keys, "Å" and "µ" intact). The parity against
//  Pillow and numpy over the planted datasets is tools/parity/export-parity (P3, P4); these pin the same rules without Python.
//  The PNG is read with ImageIO and a chunk walker written here (the walker verifies each CRC with its own CRC-32).
//  Mutations each test was broken by (ImageExport.swift, ImageExport+Overlays.swift, ExportFile.swift): the drawn label in
//  `plan.unit` instead of `plan.labelUnit`, and drawn a pixel to the right; the bar's length floored, and one pixel too
//  long; `<=` as `<` in the plate-fit rule (width and height each); `.rounded()` as `.rounded(.down)` in `overlayScale`;
//  `maximumSide` one larger; `moveItem` where `replaceItemAt` belongs, and a copy of the data written beside the target;
//  the reason dropped from `writeFailed`; `export` not writing; rows written bottom to top; an ICC profile that is not
//  sRGB; RGBA written; a CRC left unfinished; the Description written as tEXt (Latin-1) when it holds "Å"; a metadata
//  key given the wrong number; (Gate B R1 F7) every mark given listed in the Description whether or not it was drawn, and
//  the skipped count dropped.
//

import ImagoCore
import XCTest
import TEMCore

nonisolated final class ImageExportRenderTests: XCTestCase {

    // MARK: Fixtures

    private static let micro = "\u{00B5}m"
    private static let angstrom = "\u{00C5}"

    /// Entry i is (i, i, i, 255): black at 0.
    private static let grayLUT: [UInt8] = (0..<1024).map { (i: Int) -> UInt8 in i % 4 == 3 ? 255 : UInt8(i / 4) }

    private func source(_ w: Int, _ h: Int, x: AxisCalibration? = nil, y: AxisCalibration? = nil, fileName: String = "planted.dm4",
                        object: String = "ImageList.1", notes: [String] = []) -> ExportSource {
        let image = CalibratedImage(width: w, height: h, pixels: [Float](repeating: 0, count: w * h), x: x, y: y,
                                    fileName: fileName, source: object, voltage: nil, notes: notes)
        return ExportSource(image: image, software: "macTEM 0.1.0 (1)")
    }

    /// A canvas of `normalized` (zeros: black through the gray LUT) at the window and gamma given.
    private func display(_ w: Int, _ h: Int, normalized: [Float]? = nil, lut: [UInt8] = ImageExportRenderTests.grayLUT,
                         low: Float = 0, high: Float = 1, gamma: Double = 1, colormap: String = "gray",
                         windowLow: Float? = nil, windowHigh: Float? = nil, rawRange: ClosedRange<Float>? = nil) -> ImageExport.Display {
        ImageExport.Display(normalized: normalized ?? [Float](repeating: 0, count: w * h), width: w, height: h, low: low,
                            high: high, gamma: gamma, lut: lut, colormap: colormap, windowLow: windowLow,
                            windowHigh: windowHigh, rawRange: rawRange)
    }

    private func render(_ w: Int, _ h: Int, x: AxisCalibration? = nil, y: AxisCalibration? = nil, scaleBar: Bool = true,
                        marks: [ImageExport.Mark] = [], marksOn: Bool = false,
                        fileName: String = "planted.dm4") throws -> ImageExport.Rendered {
        try ImageExport.render(source: source(w, h, x: x, y: y, fileName: fileName), display: display(w, h), marks: marks,
                               options: ImageExport.Options(scaleBar: scaleBar, marks: marksOn))
    }

    private func scratchDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImageExportRenderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func listing(_ directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    }

    // MARK: Reading a PNG back

    private struct PNGChunk {
        let type: String
        let body: [UInt8]
    }

    /// Every chunk of `png` in order, or nil when the signature is wrong, a chunk runs past the end, a CRC does not match
    /// the CRC-32 of its type and body (computed here, bit by bit), or IEND is missing.
    private static func chunks(_ png: Data) -> [PNGChunk]? {
        let bytes = [UInt8](png)
        guard bytes.count > 20, Array(bytes.prefix(8)) == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] else { return nil }
        var out: [PNGChunk] = []
        var offset = 8
        while offset + 12 <= bytes.count {
            let length = (Int(bytes[offset]) << 24) | (Int(bytes[offset + 1]) << 16) | (Int(bytes[offset + 2]) << 8)
                | Int(bytes[offset + 3])
            guard offset + 12 + length <= bytes.count else { return nil }
            let typeAndBody = Array(bytes[(offset + 4)..<(offset + 8 + length)])
            let crc = (UInt32(bytes[offset + 8 + length]) << 24) | (UInt32(bytes[offset + 9 + length]) << 16)
                | (UInt32(bytes[offset + 10 + length]) << 8) | UInt32(bytes[offset + 11 + length])
            guard crc == crc32(typeAndBody) else { return nil }
            out.append(PNGChunk(type: String(decoding: typeAndBody.prefix(4), as: UTF8.self), body: Array(typeAndBody.dropFirst(4))))
            offset += 12 + length
        }
        return out.last?.type == "IEND" && offset == bytes.count ? out : nil
    }

    private static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = crc & 1 != 0 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1 }
        }
        return ~crc
    }

    /// The text chunks by keyword: tEXt as Latin-1, iTXt (uncompressed) as UTF-8, as every PNG reader reads them.
    private static func texts(_ chunks: [PNGChunk]) -> [String: String] {
        var out: [String: String] = [:]
        for chunk in chunks {
            guard let nul = chunk.body.firstIndex(of: 0) else { continue }
            let keyword = String(decoding: chunk.body[..<nul], as: UTF8.self)
            if chunk.type == "tEXt" {
                out[keyword] = String(bytes: chunk.body[(nul + 1)...], encoding: .isoLatin1)
            } else if chunk.type == "iTXt", chunk.body.count > nul + 3, chunk.body[nul + 1] == 0 {
                var i = nul + 3                                            // after the flag and the method
                while i < chunk.body.count, chunk.body[i] != 0 { i += 1 }  // the language tag
                i += 1
                while i < chunk.body.count, chunk.body[i] != 0 { i += 1 }  // the translated keyword
                i += 1
                if i <= chunk.body.count { out[keyword] = String(decoding: chunk.body[i...], as: UTF8.self) }
            }
        }
        return out
    }

    /// The Description chunk's JSON object.
    private static func metadata(_ png: Data) throws -> [String: Any] {
        let all = try XCTUnwrap(chunks(png), "the PNG's chunks (signature, lengths, CRCs, IEND)")
        let description = try XCTUnwrap(texts(all)["Description"], "a Description text chunk")
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(description.utf8)) as? [String: Any])
    }

    /// The PNG's pixels as 8-bit sRGB RGB, row 0 first, through ImageIO and a 1:1, non-interpolated draw.
    private static func decode(_ png: Data) -> (width: Int, height: Int, rgb: [UInt8])? {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                      bytesPerRow: image.width * 4, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let data = context.data else { return nil }
        let rgba = data.assumingMemoryBound(to: UInt8.self)
        var rgb = [UInt8](repeating: 0, count: image.width * image.height * 3)
        for row in 0..<image.height {
            for column in 0..<image.width {
                let from = row * context.bytesPerRow + 4 * column, to = 3 * (row * image.width + column)
                rgb[to] = rgba[from]; rgb[to + 1] = rgba[from + 1]; rgb[to + 2] = rgba[from + 2]
            }
        }
        return (image.width, image.height, rgb)
    }

    // MARK: The bar's label and run

    /// The scale bars the tests read back: the registration's laddered and anisotropic plants at a size that renders in
    /// milliseconds, and the label, scale and drawn length worked out by hand.
    private struct BarCase {
        let name: String
        let width: Int, height: Int
        let x: AxisCalibration?, y: AxisCalibration?
        let label: String
        let overlayScale: Int
        let drawn: Int
    }

    private static let barCases: [BarCase] = [
        // 0.5 nm per pixel along x: 70 px = 35 nm → 50 nm → 100 px. (y is 0.8 nm: the bar measures x.)
        BarCase(name: "anisotropic", width: 512, height: 384, x: AxisCalibration(scale: 0.5, unit: "nm", origin: 0),
                y: AxisCalibration(scale: 0.8, unit: "nm", origin: 0), label: "50 nm", overlayScale: 1, drawn: 100),
        // 0.0004 µm per pixel: 70 px = 0.028 µm → 0.02 µm, read as 20 nm (the ladder down), 50 px.
        BarCase(name: "laddered down", width: 512, height: 512, x: AxisCalibration(scale: 0.0004, unit: micro, origin: 0),
                y: AxisCalibration(scale: 0.0004, unit: micro, origin: 0), label: "20 nm", overlayScale: 1, drawn: 50),
        // 20 nm per pixel: 70 px = 1400 nm → 1000 nm, read as 1 µm (the ladder up), 50 px.
        BarCase(name: "laddered up", width: 512, height: 384, x: AxisCalibration(scale: 20, unit: "nm", origin: 0),
                y: AxisCalibration(scale: 20, unit: "nm", origin: 0), label: "1 \(micro)", overlayScale: 1, drawn: 50),
        // 0.1 Å per pixel: 70 px = 7 Å → 5 Å (the ladder leaves the Å alone), 50 px.
        BarCase(name: "ångström", width: 600, height: 500, x: AxisCalibration(scale: 0.1, unit: angstrom, origin: 0),
                y: AxisCalibration(scale: 0.1, unit: angstrom, origin: 0), label: "5 \(angstrom)", overlayScale: 1, drawn: 50),
        // 0.3 nm per pixel: 70 px = 21 nm → 20 nm → 66.67 px, drawn as 67 (a length that is not whole: rounded, not floored).
        BarCase(name: "fractional length", width: 512, height: 384, x: AxisCalibration(scale: 0.3, unit: "nm", origin: 0),
                y: AxisCalibration(scale: 0.3, unit: "nm", origin: 0), label: "20 nm", overlayScale: 1, drawn: 67),
        // Uncalibrated: pixels. 70 px → 50 px.
        BarCase(name: "uncalibrated", width: 640, height: 480, x: nil, y: nil, label: "50 px", overlayScale: 1, drawn: 50),
        // 1024 × 768 is u = 2 (768/512 = 1.5 rounds to 2): 140 px = 70 nm → 50 nm → 100 px.
        BarCase(name: "u = 2", width: 1024, height: 768, x: AxisCalibration(scale: 0.5, unit: "nm", origin: 0),
                y: AxisCalibration(scale: 0.5, unit: "nm", origin: 0), label: "50 nm", overlayScale: 2, drawn: 100),
    ]

    /// The bar's plan and the metadata's `scale_bar` say what the case was worked out to be.
    private func renderBar(_ c: BarCase) throws -> (rendered: ImageExport.Rendered, bar: [String: Any], x0: Int, top: Int) {
        let rendered = try render(c.width, c.height, x: c.x, y: c.y)
        let plan = try XCTUnwrap(rendered.bar, c.name)
        XCTAssertFalse(rendered.barLeftOut, c.name)
        XCTAssertEqual(plan.label, c.label, c.name)
        XCTAssertEqual(plan.overlayScale, c.overlayScale, c.name)
        XCTAssertEqual(plan.drawnPixels, c.drawn, c.name)
        let bar = try XCTUnwrap(try Self.metadata(rendered.png)["scale_bar"] as? [String: Any], c.name)
        return (rendered, bar, try XCTUnwrap(bar["x0"] as? Int), try XCTUnwrap(bar["top"] as? Int))
    }

    /// The label the plate shows is the label the metadata states, pixel for pixel: the metadata's string is drawn alone
    /// through the same text routine (`scaleBarLabelBitmap`) and the crop of the export at the label's place equals it.
    /// The image under the plate is black, so what is left is the white label. Red under: the label drawn in `plan.unit`
    /// (the laddered cases read "1 nm" and "20 µm" in the picture), drawn a pixel to the right, or in another size.
    func testTheDrawnLabelIsTheMetadatasLabelPixelForPixel() throws {
        for c in Self.barCases {
            let r = try renderBar(c)
            XCTAssertEqual(r.bar["label"] as? String, c.label, c.name)
            let bitmap = try XCTUnwrap(ImageExport.scaleBarLabelBitmap(c.label, overlayScale: c.overlayScale), c.name)
            let decoded = try XCTUnwrap(Self.decode(r.rendered.png), c.name)
            XCTAssertEqual(decoded.width, c.width)
            XCTAssertEqual(decoded.height, c.height)
            let originY = r.top - 3 * c.overlayScale - bitmap.height          // the label's box sits 3u above the bar
            var differing = 0, white = 0
            for j in 0..<bitmap.height {
                for i in 0..<bitmap.width {
                    for channel in 0..<3 {
                        let exported = decoded.rgb[3 * ((originY + j) * decoded.width + r.x0 + i) + channel]
                        let alone = bitmap.rgb[3 * (j * bitmap.width + i) + channel]
                        if exported != alone { differing += 1 }
                        if alone > 128 { white += 1 }
                    }
                }
            }
            let total = 3 * bitmap.width * bitmap.height
            XCTAssertEqual(differing, 0, "\(c.name): \(differing) of \(total) channels of the label's crop differ")
            XCTAssertGreaterThan(white, bitmap.width, "\(c.name): the label alone must have white pixels in it")
        }
    }

    /// The bar is a rectangle of exact white `drawn_px` wide and 2u tall at (x0, top): in every one of its rows the run of
    /// exact white starting at x0 is the drawn length, and the pixel before it and the pixel after it are not white. Its
    /// length times the sampling is the label's value within one pixel (the half-pixel the integer snap allows).
    /// Red under: the length floored (the 0.3 nm case: 66.67 px drawn as 66), the bar a pixel too long or too short.
    func testTheBarsExactWhiteRunIsItsDrawnLength() throws {
        for c in Self.barCases {
            let r = try renderBar(c)
            let u = c.overlayScale
            XCTAssertEqual(r.bar["drawn_px"] as? Int, c.drawn, c.name)
            XCTAssertEqual(r.bar["height_px"] as? Int, 2 * u, c.name)
            XCTAssertEqual(r.x0, 16 * u, "\(c.name): x0 = margin 8u + padding 8u")
            XCTAssertEqual(r.top, c.height - 15 * u, "\(c.name): top = H − margin 8u − padding 5u − bar 2u")
            let decoded = try XCTUnwrap(Self.decode(r.rendered.png), c.name)
            func isWhite(_ x: Int, _ y: Int) -> Bool {
                (0..<3).allSatisfy { decoded.rgb[3 * (y * decoded.width + x) + $0] == 255 }
            }
            for y in r.top..<(r.top + 2 * u) {
                var run = 0
                while r.x0 + run < decoded.width, isWhite(r.x0 + run, y) { run += 1 }
                XCTAssertEqual(run, c.drawn, "\(c.name): row \(y)")
                XCTAssertFalse(isWhite(r.x0 - 1, y), "\(c.name): the pixel before the bar, row \(y)")
            }
            XCTAssertFalse(isWhite(r.x0, r.top - 1), "\(c.name): above the bar")
            XCTAssertFalse(isWhite(r.x0, r.top + 2 * u), "\(c.name): below the bar")
            // The run, times the sampling the plan measured, is the label's value within one pixel's length.
            let plan = try XCTUnwrap(r.rendered.bar)
            XCTAssertEqual(Double(c.drawn) * plan.perPixel, plan.value * Self.labelUnitsPerBarUnit(bar: plan.unit, label: plan.labelUnit),
                           accuracy: plan.perPixel, c.name)
        }
    }

    /// How many of the bar's own unit one label unit is, for the nm / µm / mm rungs the ladder moves between (×1000 a step);
    /// 1 for any other pair (the ladder leaves those alone).
    private static func labelUnitsPerBarUnit(bar: String, label: String) -> Double {
        let order = ["nm": 0, micro: 1, "mm": 2]
        guard let a = order[bar], let b = order[label] else { return 1 }
        return pow(1000, Double(b - a))
    }

    // MARK: The plate's fit

    /// The plate the plan implies, worked out in the test from the twins `ImageExport` exposes (pinned by
    /// ImageExportTwinTests) and the label alone (`scaleBarLabelBitmap`): width max(label, bar) + 16u, height label + 15u.
    private static func plate(_ w: Int, _ h: Int, x: AxisCalibration?, y: AxisCalibration?) -> (width: Int, height: Int)? {
        let s = ScaleBarMath.sampling(x: x, y: y, width: w, height: h, unitLabel: UnitDisplay.label)
        let u = ScaleBarMath.overlayScale(width: w, height: h)
        let nice = ScaleBarMath.nice125(s.perPixel * min(70 * Double(u), Double(w) / 4))
        let reading = ScaleBarMath.ladder(nice, unit: s.unit)
        let label = "\(ScaleBarMath.format(reading.value)) \(reading.unit)"
        guard let bitmap = ImageExport.scaleBarLabelBitmap(label, overlayScale: u) else { return nil }
        let drawn = Int((nice / s.perPixel).rounded())
        return (max(bitmap.width, drawn) + 16 * u, bitmap.height + 15 * u)
    }

    private static let fitImages: [(name: String, x: AxisCalibration?, y: AxisCalibration?)] = [
        ("uncalibrated", nil, nil),
        ("0.5 nm", AxisCalibration(scale: 0.5, unit: "nm", origin: 0), AxisCalibration(scale: 0.8, unit: "nm", origin: 0)),
        ("5 nm, x only", AxisCalibration(scale: 5, unit: "nm", origin: 0), nil),
    ]

    /// The plate fits when it is no wider than W/2 (and no taller than H/3), the boundary included. Scanning every width
    /// from 20 to 300 against the rule worked out in the test finds, for each image, a width where the plate is EXACTLY W/2
    /// (it fits) and one where it overshoots by half a pixel (it does not, and then neither plate nor bar is drawn and
    /// the export says so). Red under: `<=` as `<`, W/2 as W/3.
    func testThePlateFitsExactlyAtItsEdgeInWidth() throws {
        let height = 900
        for image in Self.fitImages {
            var exact: [Int] = [], justOut: [Int] = []
            for w in 20...300 {
                let plate = try XCTUnwrap(Self.plate(w, height, x: image.x, y: image.y))
                let fits = Double(plate.width) <= Double(w) / 2 && Double(plate.height) <= Double(height) / 3
                let plan = ImageExport.scaleBarPlan(x: image.x, y: image.y, width: w, height: height)
                XCTAssertEqual(plan != nil, fits, "\(image.name): width \(w), plate \(plate.width) × \(plate.height)")
                if Double(plate.width) == Double(w) / 2 { exact.append(w) }
                if !fits, Double(plate.width) - Double(w) / 2 <= 1 { justOut.append(w) }
            }
            XCTAssertFalse(exact.isEmpty, "\(image.name): the scan must contain a width where the plate is exactly W/2")
            XCTAssertFalse(justOut.isEmpty, "\(image.name): ... and one where it is just too wide")
            for w in exact.prefix(2) {
                let r = try render(w, height, x: image.x, y: image.y)
                XCTAssertNotNil(r.bar, "\(image.name): width \(w) is exactly the edge: the plate fits")
                XCTAssertFalse(r.barLeftOut)
            }
            for w in justOut.prefix(3) {
                let r = try render(w, height, x: image.x, y: image.y)
                XCTAssertNil(r.bar, "\(image.name): width \(w) is just too narrow")
                XCTAssertTrue(r.barLeftOut)
                XCTAssertEqual(try Self.metadata(r.png)["scale_bar"] as? [String: String], ["left_out": "the image is too small"])
                // Nothing is drawn: the pixels are those of the export that never asked for a bar.
                let without = try render(w, height, x: image.x, y: image.y, scaleBar: false)
                XCTAssertNil(without.bar)
                XCTAssertFalse(without.barLeftOut)
                XCTAssertTrue(try XCTUnwrap(Self.decode(r.png)).rgb == XCTUnwrap(Self.decode(without.png)).rgb,
                              "\(image.name): width \(w), a left-out bar must leave the picture as it was")
                XCTAssertTrue(try Self.metadata(without.png)["scale_bar"] is NSNull)
            }
        }
    }

    /// The same for the height: the plate is H/3 tall at H = 3 × (label + 15u); one pixel less and it is left out.
    func testThePlateFitsExactlyAtItsEdgeInHeight() throws {
        let width = 600
        for image in Self.fitImages {
            let plate = try XCTUnwrap(Self.plate(width, 90, x: image.x, y: image.y))
            let edge = 3 * plate.height
            XCTAssertLessThan(Double(plate.width), Double(width) / 2, "\(image.name): the width is not what limits")
            for h in (edge - 6)...(edge + 6) {
                let p = try XCTUnwrap(Self.plate(width, h, x: image.x, y: image.y))
                XCTAssertEqual(p.height, plate.height, "\(image.name): the plate's height does not depend on H here")
                let plan = ImageExport.scaleBarPlan(x: image.x, y: image.y, width: width, height: h)
                XCTAssertEqual(plan != nil, h >= edge, "\(image.name): height \(h), plate \(p.height), edge \(edge)")
            }
            let fits = try render(width, edge, x: image.x, y: image.y)
            XCTAssertNotNil(fits.bar, "\(image.name): height \(edge) is exactly 3 × the plate")
            XCTAssertFalse(fits.barLeftOut)
            let out = try render(width, edge - 1, x: image.x, y: image.y)
            XCTAssertNil(out.bar)
            XCTAssertTrue(out.barLeftOut)
        }
    }

    // MARK: Overlay scale, size limit

    func testTheOverlayScaleTable() {
        let table: [(w: Int, h: Int, u: Int)] = [
            (512, 512, 1), (4096, 4096, 8), (1, 1, 1), (255, 300, 1), (256, 256, 1), (767, 767, 1), (768, 768, 2),
            (640, 480, 1), (1000, 700, 1), (1024, 1024, 2), (1536, 1536, 3), (2047, 4000, 4), (16384, 16384, 32),
            (100_000, 100, 1), (8192, 512, 1), (512, 8192, 1), (1024, 768, 2), (4096, 1024, 2), (1280, 1280, 3), (1279, 1279, 2),
            (1792, 1792, 4), (1791, 1791, 3),
        ]
        for row in table {
            XCTAssertEqual(ScaleBarMath.overlayScale(width: row.w, height: row.h), row.u, "\(row.w) × \(row.h)")
        }
        // The rule is max(1, round(min(W, H) / 512)), halves away from zero: 768 / 512 = 1.5 → 2, 1280 / 512 = 2.5 → 3.
    }

    func testASideAboveTheMaximumIsRefusedByNameAndTheMaximumIsTaken() throws {
        XCTAssertEqual(ImageExport.maximumSide, 16_384)
        for (w, h) in [(16_385, 2), (3, 16_385), (20_000, 3)] {
            XCTAssertThrowsError(try render(w, h, scaleBar: false), "\(w) × \(h)") { error in
                XCTAssertEqual(error as? ExportFile.Failure, .tooLarge(width: w, height: h))
                XCTAssertEqual((error as? LocalizedError)?.errorDescription,
                               "The image is \(w) × \(h) px; export takes at most 16384 px a side.")
            }
        }
        for (w, h) in [(16_384, 1), (1, 16_384)] {
            let r = try render(w, h, scaleBar: false)
            XCTAssertEqual(r.width, w)
            XCTAssertEqual(r.height, h)
            let decoded = try XCTUnwrap(Self.decode(r.png))
            XCTAssertEqual(decoded.width, w)
            XCTAssertEqual(decoded.height, h)
        }
    }

    // MARK: The write

    func testWriteCreatesANewFileAndReplacesAnExistingOneLeavingNothingBeside() throws {
        let directory = try scratchDirectory()
        let url = directory.appendingPathComponent("sample \(Self.angstrom).png")
        let first = Data((0..<4000).map { UInt8($0 % 251) })
        try ExportFile.write(first, to: url)
        XCTAssertEqual(try Data(contentsOf: url), first, "a new name")
        XCTAssertEqual(try listing(directory), ["sample \(Self.angstrom).png"], "no scratch file beside the target")
        let second = Data("a replacement, shorter than the first".utf8)
        try ExportFile.write(second, to: url)
        XCTAssertEqual(try Data(contentsOf: url), second, "over an existing file")
        XCTAssertEqual(try listing(directory), ["sample \(Self.angstrom).png"], "nor after a replacement")
        try ExportFile.write(Data(), to: url)
        XCTAssertEqual(try Data(contentsOf: url), Data(), "an empty file is a file")
        XCTAssertEqual(try listing(directory), ["sample \(Self.angstrom).png"])
    }

    func testWriteIntoAMissingFolderThrowsTheSystemsReason() throws {
        let directory = try scratchDirectory()
        let url = directory.appendingPathComponent("no such folder", isDirectory: true).appendingPathComponent("out.png")
        XCTAssertThrowsError(try ExportFile.write(Data([1, 2, 3]), to: url)) { error in
            guard case .writeFailed(let reason)? = error as? ExportFile.Failure else { return XCTFail("\(error)") }
            XCTAssertFalse(reason.isEmpty)
            XCTAssertTrue((error as? LocalizedError)?.errorDescription?.hasPrefix("The file could not be written.") == true)
        }
        XCTAssertEqual(try listing(directory), [], "the missing folder is not made")
    }

    /// `export` is `render` then `write`: the file holds the bytes `render` returned, to a new name and over an existing
    /// one, and nothing else is in the folder.
    func testExportWritesTheRenderedPNGToANewAndAnExistingFile() async throws {
        let directory = try scratchDirectory()
        let url = directory.appendingPathComponent("out.png")
        let src = source(200, 150, x: AxisCalibration(scale: 0.5, unit: "nm", origin: 0), y: AxisCalibration(scale: 0.5, unit: "nm", origin: 0))
        let rendered = try await ImageExport.export(source: src, display: display(200, 150), marks: [],
                                                    options: ImageExport.Options(scaleBar: true, marks: false), to: url)
        XCTAssertEqual(try Data(contentsOf: url), rendered.png)
        XCTAssertEqual(try Self.decode(Data(contentsOf: url))?.width, 200)
        XCTAssertEqual(try listing(directory), ["out.png"])
        try Data("old".utf8).write(to: url)
        let again = try await ImageExport.export(source: src, display: display(200, 150), marks: [],
                                                 options: ImageExport.Options(scaleBar: false, marks: false), to: url)
        XCTAssertEqual(try Data(contentsOf: url), again.png, "over a file that was there")
        XCTAssertNotEqual(again.png, rendered.png)
        XCTAssertEqual(try listing(directory), ["out.png"])
    }

    // MARK: Format and metadata

    /// The PNG is 8-bit truecolour with no alpha ("RGB" in Pillow), tagged sRGB, with valid chunks and its text before
    /// the pixels, and export pixel (i, j) is canvas column i, row j: a 5 × 3 canvas whose values sit on LUT texel centres,
    /// through a LUT of distinct colours, one canvas value masked. Red under: rows or columns flipped or transposed,
    /// RGBA written, the sRGB tag dropped, a CRC off by one.
    func testThePNGIsEightBitRGBTaggedSRGBAndPixelIJIsColumnIRowJ() throws {
        let w = 5, h = 3
        var lut = [UInt8](repeating: 255, count: 1024)                     // entry k: (k, 255 − k, 7k mod 256)
        for k in 0..<256 { lut[4 * k] = UInt8(k); lut[4 * k + 1] = UInt8(255 - k); lut[4 * k + 2] = UInt8((k * 7) % 256) }
        let ks = (0..<(w * h)).map { 10 * ($0 / w) + ($0 % w) + 3 }
        var canvas = ks.map { (Float($0) + 0.5) / 256 }                    // v = (k + ½)/256 → LUT position exactly k
        canvas[2 * w + 4] = -1                                             // masked at column 4, row 2
        let rendered = try ImageExport.render(source: source(w, h), display: display(w, h, normalized: canvas, lut: lut),
                                              marks: [], options: ImageExport.Options(scaleBar: false, marks: false))
        XCTAssertEqual(rendered.width, w)
        XCTAssertEqual(rendered.height, h)
        let chunks = try XCTUnwrap(Self.chunks(rendered.png), "valid signature, lengths, CRCs and IEND")
        let types = chunks.map(\.type)
        XCTAssertEqual(types.first, "IHDR")
        XCTAssertEqual(types.last, "IEND")
        let ihdr = chunks[0].body
        XCTAssertEqual(ihdr.count, 13)
        XCTAssertEqual(Array(ihdr[0..<4]), [0, 0, 0, UInt8(w)])
        XCTAssertEqual(Array(ihdr[4..<8]), [0, 0, 0, UInt8(h)])
        XCTAssertEqual(ihdr[8], 8, "bit depth")
        XCTAssertEqual(ihdr[9], 2, "colour type 2: truecolour, no alpha")
        XCTAssertEqual(Array(ihdr[10...]), [0, 0, 0], "deflate, adaptive filtering, not interlaced")
        // The tag is the sRGB chunk, or an ICC profile that is sRGB by name (an untagged or generic-RGB file is not sRGB).
        let iccNames = chunks.filter { $0.type == "iCCP" }.map { String(decoding: $0.body.prefix { $0 != 0 }, as: UTF8.self) }
        XCTAssertTrue(types.contains("sRGB") || iccNames.contains { $0.contains("sRGB") }, "tagged sRGB: \(types), ICC \(iccNames)")
        XCTAssertFalse(types.contains("tRNS"))
        let firstData = try XCTUnwrap(types.firstIndex(of: "IDAT"))
        for keyword in ["Title", "Software", "Description"] {
            let i = chunks.firstIndex { $0.type == "tEXt" || $0.type == "iTXt" ? $0.body.starts(with: Array(keyword.utf8) + [0]) : false }
            XCTAssertNotNil(i, keyword)
            XCTAssertLessThan(i ?? Int.max, firstData, "\(keyword) comes before the pixels")
        }
        let decoded = try XCTUnwrap(Self.decode(rendered.png))
        XCTAssertEqual(decoded.width, w)
        XCTAssertEqual(decoded.height, h)
        for j in 0..<h {
            for i in 0..<w {
                let got = Array(decoded.rgb[(3 * (j * w + i))..<(3 * (j * w + i) + 3)])
                let k = ks[j * w + i]
                let want: [UInt8] = (i == 4 && j == 2) ? [82, 82, 87] : [lut[4 * k], lut[4 * k + 1], lut[4 * k + 2]]
                XCTAssertEqual(got, want, "pixel (column \(i), row \(j))")
            }
        }
    }

    /// The Description is one JSON object with sorted keys, the full key set of the contract, the file's own numbers, and
    /// "Å" and "µ" read back intact (iTXt, UTF-8: tEXt would be Latin-1); Title and Software are chunks of their own.
    /// Red under: the Description written as tEXt, a key renamed or dropped, a wrong number.
    func testTheDescriptionChunkIsJSONWithSortedKeysAndKeepsNonASCII() throws {
        let w = 6, h = 4
        var canvas = [Float](repeating: 0.5, count: w * h)
        canvas[0] = -1; canvas[7] = -1; canvas[23] = -1
        let axis = AxisCalibration(scale: 0.25, unit: Self.angstrom, origin: 2)
        let src = ExportSource(image: CalibratedImage(width: w, height: h, pixels: [Float](repeating: 1, count: w * h), x: axis, y: axis,
                                                      fileName: "sample \(Self.angstrom) \(Self.micro).dm4",
                                                      source: "ImageList.1 \u{00B7} HAADF", voltage: nil,
                                                      notes: ["\(Self.micro) note", "scale unvalidated"]),
                               software: "macTEM 0.1.0 (1)")
        let rendered = try ImageExport.render(
            source: src, display: display(w, h, normalized: canvas, low: 0.1, high: 0.9, gamma: 1.5, colormap: "viridis",
                                          windowLow: 3.5, windowHigh: 9, rawRange: 1...20),
            marks: [], options: ImageExport.Options(scaleBar: false, marks: false))
        let chunks = try XCTUnwrap(Self.chunks(rendered.png))
        let texts = Self.texts(chunks)
        XCTAssertEqual(texts["Title"], "sample \(Self.angstrom) \(Self.micro).dm4")
        XCTAssertEqual(texts["Software"], "macTEM 0.1.0 (1)")
        let description = try XCTUnwrap(texts["Description"])
        XCTAssertTrue(description.hasPrefix("{\"anisotropic\":false,"), "sorted keys: \(description.prefix(40))")
        let lastKey = "\"y_scale\":{\"origin\":2.0,\"scale\":0.25,\"units\":\"\(Self.angstrom)\"}}"
        XCTAssertTrue(description.hasSuffix(lastKey), "\(description.suffix(80))")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(description.utf8)) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["software", "file", "object", "width", "height", "x_scale", "y_scale", "raw_range", "colormap",
                                        "window", "gamma", "masked_pixels", "notes", "overlay_scale", "scale_bar", "marks",
                                        "anisotropic", "validation", "lineage"])
        XCTAssertEqual(json["software"] as? String, "macTEM 0.1.0 (1)")
        XCTAssertEqual(json["file"] as? String, "sample \(Self.angstrom) \(Self.micro).dm4")
        XCTAssertEqual(json["object"] as? String, "ImageList.1 \u{00B7} HAADF")
        XCTAssertEqual(json["width"] as? Int, w)
        XCTAssertEqual(json["height"] as? Int, h)
        for name in ["x_scale", "y_scale"] {
            let scale = try XCTUnwrap(json[name] as? [String: Any], name)
            XCTAssertEqual(scale["scale"] as? Double, 0.25)
            XCTAssertEqual(scale["origin"] as? Double, 2)
            XCTAssertEqual(scale["units"] as? String, Self.angstrom, "\(name): the Å survives")
        }
        XCTAssertEqual(json["raw_range"] as? [Double], [1, 20])
        XCTAssertEqual(json["colormap"] as? String, "viridis")
        let window = try XCTUnwrap(json["window"] as? [String: Any])
        XCTAssertEqual(window["low"] as? Double, 3.5)
        XCTAssertEqual(window["high"] as? Double, 9)
        XCTAssertEqual(window["fractions"] as? [Double], [Double(Float(0.1)), Double(Float(0.9))], "the Float the shader got, exactly")
        XCTAssertEqual(json["gamma"] as? Double, 1.5)
        XCTAssertEqual(json["masked_pixels"] as? Int, 3)
        XCTAssertEqual(json["notes"] as? [String], ["\(Self.micro) note", "scale unvalidated"])
        XCTAssertEqual(json["overlay_scale"] as? Int, 1)
        XCTAssertTrue(json["scale_bar"] is NSNull, "not asked for")
        XCTAssertTrue(json["marks"] is NSNull, "not asked for")
        XCTAssertEqual(json["anisotropic"] as? Bool, false)
        XCTAssertTrue((json["validation"] as? String)?.hasPrefix("display rendering: window, gamma, 8-bit colour, not intensities") == true)
        XCTAssertTrue((json["lineage"] as? String)?.hasPrefix("none \u{2014} marks carry no lineage id;") == true)
        // The same image with a missing range and an open window: null, not 0.
        let open = try ImageExport.render(source: src, display: display(w, h, normalized: canvas), marks: [],
                                          options: ImageExport.Options(scaleBar: false, marks: false))
        let openWindow = try XCTUnwrap(try Self.metadata(open.png)["window"] as? [String: Any])
        XCTAssertTrue(openWindow["low"] is NSNull)
        XCTAssertTrue(openWindow["high"] is NSNull)
        XCTAssertTrue(try Self.metadata(open.png)["raw_range"] is NSNull)
    }

    /// With the bar and the marks asked for, their parameters are in the metadata as drawn: the bar's keys and its
    /// "measures x" on anisotropic pixels, each mark's kind, points (Swift's shortest text), width and label.
    func testTheDescriptionNamesTheBarAndTheMarksAsDrawn() throws {
        let w = 512, h = 384
        let marks = [
            ImageExport.Mark(kind: .profile, points: [ImagePoint(x: 100.5, y: 50), ImagePoint(x: 300, y: 200.25)], width: 5,
                             label: "12.5 nm"),
            ImageExport.Mark(kind: .angle, points: [ImagePoint(x: 10, y: 10), ImagePoint(x: 50, y: 60), ImagePoint(x: 90, y: 20)],
                             width: 1, label: "62.1\u{00B0}"),
        ]
        let rendered = try render(w, h, x: AxisCalibration(scale: 0.5, unit: "nm", origin: 0), y: AxisCalibration(scale: 0.8, unit: "nm", origin: 0),
                                  marks: marks, marksOn: true)
        let json = try Self.metadata(rendered.png)
        let bar = try XCTUnwrap(json["scale_bar"] as? [String: Any])
        XCTAssertEqual(Set(bar.keys), ["label", "value", "unit", "per_pixel", "per_pixel_unit", "length_px", "drawn_px", "x0", "top",
                                       "height_px", "measures"])
        XCTAssertEqual(bar["measures"] as? String, "x")
        XCTAssertEqual(bar["label"] as? String, "50 nm")
        XCTAssertEqual(bar["value"] as? Double, 50)
        XCTAssertEqual(bar["unit"] as? String, "nm")
        XCTAssertEqual(bar["per_pixel"] as? Double, 0.5, "x's sampling, not y's 0.8")
        XCTAssertEqual(bar["per_pixel_unit"] as? String, "nm")
        XCTAssertEqual(bar["length_px"] as? Double, 100)
        XCTAssertEqual(json["anisotropic"] as? Bool, true)
        let listed = try XCTUnwrap(json["marks"] as? [[String: Any]])
        XCTAssertEqual(listed.count, 2)
        XCTAssertEqual(listed[0]["kind"] as? String, "profile")
        XCTAssertEqual(listed[0]["width"] as? Int, 5)
        XCTAssertEqual(listed[0]["label"] as? String, "12.5 nm")
        XCTAssertEqual(listed[0]["points"] as? [[String: String]], [["x": "100.5", "y": "50.0"], ["x": "300.0", "y": "200.25"]])
        XCTAssertEqual(listed[1]["kind"] as? String, "angle")
        XCTAssertEqual(listed[1]["label"] as? String, "62.1\u{00B0}")
        XCTAssertEqual((listed[1]["points"] as? [[String: String]])?.count, 3)
        // Marks off: null, even with marks given.
        let off = try render(w, h, x: AxisCalibration(scale: 0.5, unit: "nm", origin: 0), marks: marks, marksOn: false)
        XCTAssertTrue(try Self.metadata(off.png)["marks"] is NSNull)
    }

    /// The `marks` list states what the PNG shows: a mark `drawMarks` skips (a coordinate that is not finite, fewer than two
    /// points) is not listed, and `marks_skipped` counts them, only when there are some. The picture is the same as without
    /// the skipped marks, and with no skipped mark the key is absent. Red under: every mark given listed whether drawn or not,
    /// the count dropped or written as 0.
    func testTheDescriptionListsOnlyTheMarksDrawnAndCountsTheOthers() throws {
        let w = 128, h = 96
        let drawn = ImageExport.Mark(kind: .distance, points: [ImagePoint(x: 10, y: 10), ImagePoint(x: 100, y: 60)], width: 1,
                                     label: "10 nm")
        let notFinite = ImageExport.Mark(kind: .distance, points: [ImagePoint(x: .nan, y: 5), ImagePoint(x: 40, y: 40)], width: 1,
                                         label: "nan nm")
        let onePoint = ImageExport.Mark(kind: .distance, points: [ImagePoint(x: 60, y: 30)], width: 1, label: "lonely")
        let all = try render(w, h, scaleBar: false, marks: [notFinite, drawn, onePoint], marksOn: true)
        let json = try Self.metadata(all.png)
        let listed = try XCTUnwrap(json["marks"] as? [[String: Any]])
        XCTAssertEqual(listed.compactMap { $0["label"] as? String }, ["10 nm"], "only the mark that was drawn")
        XCTAssertEqual(json["marks_skipped"] as? Int, 2)
        // What the PNG shows is what the list says: the same pixels as the export of the drawn mark alone.
        let alone = try render(w, h, scaleBar: false, marks: [drawn], marksOn: true)
        let pixels = try XCTUnwrap(Self.decode(all.png)), expected = try XCTUnwrap(Self.decode(alone.png))
        XCTAssertEqual(pixels.rgb, expected.rgb)
        XCTAssertNotEqual(pixels.rgb, try XCTUnwrap(Self.decode(try render(w, h, scaleBar: false).png)).rgb, "the drawn mark is on it")
        // No skipped mark: no key. Marks off: the list is null and nothing is counted.
        let aloneJSON = try Self.metadata(alone.png)
        XCTAssertNil(aloneJSON["marks_skipped"])
        XCTAssertEqual((aloneJSON["marks"] as? [[String: Any]])?.count, 1)
        let off = try render(w, h, scaleBar: false, marks: [notFinite, drawn, onePoint], marksOn: false)
        let offJSON = try Self.metadata(off.png)
        XCTAssertTrue(offJSON["marks"] is NSNull)
        XCTAssertNil(offJSON["marks_skipped"])
    }
}
