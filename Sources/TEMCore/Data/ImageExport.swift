//
//  ImageExport.swift
//  Role: the Image room's export to PNG (V1-10 slice 1; archive: roadmap-registrations-2026-10-15.md "Completed at pickup — slice 1";
//        archive: export-design-2026-10-13.md): the file's canvas at its own pixels through the display mapping, an
//        optional scale bar and optional marks drawn over it (`ImageExport+Overlays.swift`), and one JSON text chunk that says
//        exactly what was drawn. Pure compute on values the app snapshots when the panel opens; `export` renders and writes
//        off the main actor.
//
//  WHAT THE PNG IS: W × H pixels exactly (sides above `maximumSide` are refused by name), export pixel (i, j) = image pixel
//  (column i, row j), 8-bit RGB tagged sRGB, no alpha. The colours are the DISPLAY's — the window, the gamma, the colormap,
//  8-bit code values; not intensities (the metadata says so) — computed by `DisplayMapping`, the shader's arithmetic.
//
//  THE KIT does the arithmetic (ImagoKit 0.5.0): `ScaleBarMath` (the sampling, the 1-2-5 length, the unit ladder, the number's text,
//  the plan) and `DisplayMapping` (the shader's arithmetic in Double, pinned to the real display pipeline on this Mac's GPU in
//  ImageExportGPUTests, whose measured difference is registered). Text a person reads is `en_US_POSIX` here and in the labels
//  the app passes: a de_DE user still gets "12.43 nm" in the file.
//
//  THE BAR measures along the SCREEN HORIZONTAL, so it takes x's sampling: on anisotropic pixels it measures x, and the
//  metadata says `anisotropic`. The overlays are drawn as on a pane where one screen point is `u` export pixels, u =
//  max(1, round(min(W, H) / 512)).
//
//  THE METADATA is written as PNG chunks by this file, not through ImageIO's property dictionary: on this system ImageIO
//  turns kCGImagePropertyPNGDescription, ...Software and ...Title into an XMP packet (an iTXt "XML:com.adobe.xmp") and never
//  writes the PNG tEXt/iTXt chunks of those names (measured 2026-10-13, macOS 27.0.1; Pillow then has no `Description`).
//  The chunks are inserted before the first IDAT with their CRCs computed here; Title, Software and Description are tEXt
//  when ASCII and iTXt (UTF-8) otherwise, so "Å" and "µ" read back intact.
//

import ImagoCore
import CoreGraphics
import FormatoCore
import Foundation
import ImageIO
import UniformTypeIdentifiers

package nonisolated enum ImageExport {
    /// The longest side an export takes: a 16 384² canvas is 1 GiB of RGB.
    package static let maximumSide = 16_384

    // MARK: - Inputs

    /// The canvas as the display shows it: the values the shader samples and the window, gamma and colormap it maps them with,
    /// plus the raw numbers the presentation holds for the metadata.
    package struct Display: Sendable, Equatable {
        /// `CanvasPixels.normalized`: [0, 1], or `FloatImage.invalidDisplayValue` (−1) for a masked pixel.
        package var normalized: [Float]
        package var width: Int
        package var height: Int
        /// The window as fractions, as the shader gets them (`DisplayWindow.fractions`).
        package var low: Float
        package var high: Float
        /// The presentation's gamma; the mapping uses max(gamma, 0.05) as the shader does.
        package var gamma: Double
        /// 1024 bytes: 256 RGBA texels (`Colormaps.lutRGBA`).
        package var lut: [UInt8]
        /// The colormap's name, for the metadata.
        package var colormap: String
        /// The window in raw values as the presentation holds them (nil = the range's edge).
        package var windowLow: Float?
        package var windowHigh: Float?
        /// `CanvasPixels.rawRange`.
        package var rawRange: ClosedRange<Float>?

        package init(normalized: [Float], width: Int, height: Int, low: Float, high: Float, gamma: Double, lut: [UInt8],
                     colormap: String, windowLow: Float? = nil, windowHigh: Float? = nil,
                     rawRange: ClosedRange<Float>? = nil) {
            self.normalized = normalized
            self.width = width
            self.height = height
            self.low = low
            self.high = high
            self.gamma = gamma
            self.lut = lut
            self.colormap = colormap
            self.windowLow = windowLow
            self.windowHigh = windowHigh
            self.rawRange = rawRange
        }
    }

    package enum MarkKind: String, Sendable {
        case distance, angle, profile
        /// One point: a ring at a measured FFT spot, its number as the label (V1-10 slice 2).
        case spot
    }

    /// One mark of the file, as the Image room draws it.
    package struct Mark: Sendable, Equatable {
        package var kind: MarkKind
        /// Image pixels (x column, y row, a pixel's centre at integers): 2 points, or 3 for an angle (the middle one is the vertex).
        package var points: [ImagePoint]
        /// A profile's width in pixels, else 1.
        package var width: Int
        /// Drawn beside it; the app passes `MarkFormat.value(…, locale: en_US_POSIX)`.
        package var label: String

        package init(kind: MarkKind, points: [ImagePoint], width: Int, label: String) {
            self.kind = kind
            self.points = points
            self.width = width
            self.label = label
        }
    }

    package struct Options: Sendable, Equatable {
        package var scaleBar: Bool
        package var marks: Bool

        package init(scaleBar: Bool, marks: Bool) {
            self.scaleBar = scaleBar
            self.marks = marks
        }
    }

    /// What an export that is not of an image's own pixels adds to its Description (V1-10 slice 2, the FFT transform): `fields`
    /// go under the key "fft" (strings, sorted keys), and `validation` and `lineage` replace the image export's two sentences.
    /// nil (the default) leaves the Description exactly as slice 1 wrote it.
    package struct Provenance: Sendable, Equatable {
        package var fields: [String: String]
        package var validation: String
        package var lineage: String

        package init(fields: [String: String], validation: String, lineage: String) {
            self.fields = fields
            self.validation = validation
            self.lineage = lineage
        }
    }

    // MARK: - Outputs

    package struct Rendered: Sendable {
        package var png: Data
        package var width: Int
        package var height: Int
        /// nil: not asked for, or left out.
        package var bar: ScaleBarPlan?
        /// Asked for, and the plate did not fit.
        package var barLeftOut: Bool

        package init(png: Data, width: Int, height: Int, bar: ScaleBarPlan? = nil, barLeftOut: Bool = false) {
            self.png = png
            self.width = width
            self.height = height
            self.bar = bar
            self.barLeftOut = barLeftOut
        }
    }

    // MARK: - The bar (ImagoKit's `ScaleBarMath`)

    /// The bar, ImagoKit's `ScaleBarMath.plan` with the app's unit spelling, or nil when the plate does not fit (wider than W/2
    /// or taller than H/3: `barLayout`).
    package static func scaleBarPlan(x: AxisCalibration?, y: AxisCalibration?, width: Int, height: Int) -> ScaleBarPlan? {
        guard let plan = ScaleBarMath.plan(x: x, y: y, width: width, height: height, unitLabel: UnitDisplay.label) else { return nil }
        return barLayout(for: plan, width: width, height: height) == nil ? nil : plan
    }

    /// The display mapping of one canvas value (ImagoKit's `DisplayMapping`; the shader's arithmetic in Double). Nil unless
    /// `lut` is 1024 bytes.
    package static func rgb(_ n: Float, low: Float, high: Float, gamma: Double, lut: [UInt8]) -> (UInt8, UInt8, UInt8) {
        DisplayMapping(low: low, high: high, gamma: gamma, lut: lut)?.rgb(n) ?? DisplayMapping.maskedGrey
    }

    // MARK: - Render

    /// The PNG. Throws `ExportFile.Failure.tooLarge` above `maximumSide` (named, never clipped) and `.encodeFailed` if
    /// CoreGraphics or ImageIO refuses. `display` must be `source.width` × `source.height` with `normalized.count` pixels
    /// and a 1024-byte `lut` (a caller bug otherwise: a precondition).
    package static func render(source: ExportSource, display: Display, marks: [Mark], options: Options,
                               provenance: Provenance? = nil) throws -> Rendered {
        let width = display.width, height = display.height
        guard width <= maximumSide, height <= maximumSide else { throw ExportFile.Failure.tooLarge(width: width, height: height) }
        precondition(width >= 1 && height >= 1 && display.normalized.count == width * height,
                     "ImageExport.render: \(display.normalized.count) values for \(width) × \(height)")
        precondition(source.width == width && source.height == height,
                     "ImageExport.render: the source is \(source.width) × \(source.height), the canvas \(width) × \(height)")
        precondition(display.lut.count == 1024, "ImageExport.render: a LUT of \(display.lut.count) bytes, not 256 RGBA texels")

        guard let context = makeContext(width: width, height: height), let data = context.data else {
            throw ExportFile.Failure.encodeFailed
        }
        fillPixels(display, into: data.assumingMemoryBound(to: UInt8.self), bytesPerRow: context.bytesPerRow)

        let u = ScaleBarMath.overlayScale(width: width, height: height)
        if options.marks { drawMarks(marks, in: context, width: width, height: height, overlayScale: u) }
        var plan: ScaleBarPlan?
        var layout: BarLayout?
        if options.scaleBar {
            plan = scaleBarPlan(x: source.x, y: source.y, width: width, height: height)
            if let plan { layout = barLayout(for: plan, width: width, height: height) }
            if let layout { drawScaleBar(layout, in: context) }
        }
        let barLeftOut = options.scaleBar && layout == nil

        guard let image = context.makeImage() else { throw ExportFile.Failure.encodeFailed }
        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(encoded as CFMutableData, UTType.png.identifier as CFString, 1, nil)
        else { throw ExportFile.Failure.encodeFailed }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw ExportFile.Failure.encodeFailed }

        let description = metadata(source: source, display: display, marks: marks, options: options, plan: plan,
                                   layout: layout, overlayScale: u, provenance: provenance)
        let text = [("Title", CSVText.headerValue(source.fileName)),
                    ("Software", CSVText.headerValue(source.software)),
                    ("Description", description)]
        guard let png = try? FormatoPNG.inserting(text.map { PNGTextEntry(keyword: $0.0, value: $0.1) }, into: encoded as Data)
        else { throw ExportFile.Failure.encodeFailed }
        return Rendered(png: png, width: width, height: height, bar: plan, barLeftOut: barLeftOut)
    }

    /// Render, then `ExportFile.write`, off the main actor (a 4096² export maps 16 M pixels and encodes tens of MB).
    @concurrent package static func export(source: ExportSource, display: Display, marks: [Mark], options: Options,
                                           provenance: Provenance? = nil, to url: URL) async throws -> Rendered {
        let rendered = try render(source: source, display: display, marks: marks, options: options, provenance: provenance)
        try ExportFile.write(rendered.png, to: url)
        return rendered
    }

    /// Every canvas pixel through `DisplayMapping` into the bitmap, row 0 at the top. The rows are independent, so they are split
    /// across the cores (the result does not depend on the split).
    private static func fillPixels(_ display: Display, into bytes: UnsafeMutablePointer<UInt8>, bytesPerRow: Int) {
        let width = display.width, height = display.height
        // `render` has checked the 1024-byte LUT.
        let mapping = DisplayMapping(low: display.low, high: display.high, gamma: display.gamma, lut: display.lut)!
        display.normalized.withUnsafeBufferPointer { canvas in
            let shared = SharedBuffers(source: canvas.baseAddress!, target: bytes)
            let bands = max(1, min(height, ProcessInfo.processInfo.activeProcessorCount * 4))
            DispatchQueue.concurrentPerform(iterations: bands) { band in
                let first = band * height / bands, last = (band + 1) * height / bands
                for row in first..<last {
                    let source = shared.source + row * width
                    var target = shared.target + row * bytesPerRow
                    for column in 0..<width {
                        let (r, g, b) = mapping.rgb(source[column])
                        target[0] = r; target[1] = g; target[2] = b; target[3] = 255
                        target += 4
                    }
                }
            }
        }
    }

    /// The two buffers `fillPixels` shares across its bands: disjoint rows are written, the canvas is only read.
    private struct SharedBuffers: @unchecked Sendable {
        let source: UnsafePointer<Float>
        let target: UnsafeMutablePointer<UInt8>
    }

    // MARK: - Metadata

    /// The Description chunk's JSON (sorted keys, compact): what was drawn and from what. See the registration for each key.
    /// `marks` lists the marks that were drawn (`isDrawn`); `marks_skipped` counts the others and is present only when there are some.
    private static func metadata(source: ExportSource, display: Display, marks: [Mark], options: Options, plan: ScaleBarPlan?,
                                 layout: BarLayout?, overlayScale u: Int, provenance: Provenance?) -> String {
        func axis(_ a: AxisCalibration?) -> JSON {
            guard let a, a.isCalibrated else { return .null }
            return .object(["scale": .number(a.scale), "units": .string(a.unit), "origin": .number(a.origin)])
        }
        func raw(_ v: Float?) -> JSON { v.map { .number(Double($0)) } ?? .null }
        var anisotropic = false
        if let x = source.x, let y = source.y, x.isCalibrated, y.isCalibrated { anisotropic = x.scale != y.scale || x.unit != y.unit }

        let scaleBar: JSON
        if !options.scaleBar {
            scaleBar = .null
        } else if let plan, let layout {
            scaleBar = .object(["label": .string(plan.label), "value": .number(plan.value), "unit": .string(plan.labelUnit),
                                "per_pixel": .number(plan.perPixel), "per_pixel_unit": .string(plan.unit),
                                "length_px": .number(plan.lengthPixels), "drawn_px": .int(plan.drawnPixels),
                                "x0": .int(layout.barX), "top": .int(layout.barTop), "height_px": .int(layout.barHeight),
                                "measures": .string("x")])
        } else {
            scaleBar = .object(["left_out": .string("the image is too small")])
        }
        // Only the marks `drawMarks` draws are listed; the others are counted, so the Description states what the PNG shows.
        let drawn = marks.filter(isDrawn)
        let markList: JSON = options.marks
            ? .array(drawn.map { mark in
                .object(["kind": .string(mark.kind.rawValue),
                         "points": .array(mark.points.map { .object(["x": .string("\($0.x)"), "y": .string("\($0.y)")]) }),
                         "width": .int(mark.width), "label": .string(mark.label)])
            })
            : .null
        var object: [String: JSON] = [
            "software": .string(source.software), "file": .string(source.fileName), "object": .string(source.object),
            "width": .int(display.width), "height": .int(display.height),
            "x_scale": axis(source.x), "y_scale": axis(source.y),
            "raw_range": display.rawRange.map { .array([.number(Double($0.lowerBound)), .number(Double($0.upperBound))]) } ?? .null,
            "colormap": .string(display.colormap),
            "window": .object(["low": raw(display.windowLow), "high": raw(display.windowHigh),
                               "fractions": .array([.number(Double(display.low)), .number(Double(display.high))])]),
            "gamma": .number(display.gamma),
            "masked_pixels": .int(display.normalized.reduce(0) { $0 + ($1 < 0 ? 1 : 0) }),
            "notes": .array(source.notes.map { .string($0) }),
            "overlay_scale": .int(u),
            "scale_bar": scaleBar, "marks": markList, "anisotropic": .bool(anisotropic),
            "validation": .string("display rendering: window, gamma, 8-bit colour, not intensities; "
                                  + "the scale bar's length checked against its label (export-parity P3)"),
            "lineage": .string("none — marks carry no lineage id until V1-2; the marks' parameters stand in"),
        ]
        if options.marks, drawn.count < marks.count { object["marks_skipped"] = .int(marks.count - drawn.count) }
        if let provenance {
            object["fft"] = .object(provenance.fields.mapValues { .string($0) })
            object["validation"] = .string(provenance.validation)
            object["lineage"] = .string(provenance.lineage)
        }
        return JSON.object(object).text
    }

    /// A JSON value written by hand: sorted keys, compact, UTF-8 with the characters JSON requires escaped (and the two
    /// Unicode line separators, and the C1 controls, so the text is safe wherever it is pasted); numbers are Swift's
    /// `description` (the shortest text that reads back to the same bits), non-finite ones `null`.
    private enum JSON {
        case null
        case bool(Bool)
        case int(Int)
        case number(Double)
        case string(String)
        case array([JSON])
        case object([String: JSON])

        var text: String {
            switch self {
            case .null: return "null"
            case .bool(let b): return b ? "true" : "false"
            case .int(let i): return String(i)
            case .number(let d): return d.isFinite ? d.description : "null"
            case .string(let s): return Self.quoted(s)
            case .array(let items): return "[" + items.map(\.text).joined(separator: ",") + "]"
            case .object(let members):
                return "{" + members.sorted { $0.key < $1.key }.map { Self.quoted($0.key) + ":" + $0.value.text }.joined(separator: ",") + "}"
            }
        }

        private static func quoted(_ s: String) -> String {
            var out = "\""
            for scalar in s.unicodeScalars {
                switch scalar {
                case "\"": out += "\\\""
                case "\\": out += "\\\\"
                case "\n": out += "\\n"
                case "\r": out += "\\r"
                case "\t": out += "\\t"
                default:
                    let v = scalar.value
                    if v < 0x20 || (v >= 0x7F && v <= 0x9F) || v == 0x2028 || v == 0x2029 {
                        out += String(format: "\\u%04x", v)
                    } else {
                        out.unicodeScalars.append(scalar)
                    }
                }
            }
            return out + "\""
        }
    }
}
