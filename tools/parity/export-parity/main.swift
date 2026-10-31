// tools/parity/export-parity/main.swift — macTEM's Image room export (`ImageExport`, `ProfileCSV`, `ExportFile`; TEMCore, through
// Package.swift's ExportParity target) WRITES what reference.py planted; reference.py `check` reads
// it back with Pillow, numpy and Python's own `float` and holds it to its checks (P1, P3, P4, P5, P6, and P7, the label; and R-P1, the Results room's CSV).
//
//     harness <planted dir of reference.py> <out dir> [<case,case...|all> [<variant,variant...|all>]]
//
// This file does no checking of its own: it renders every planted case with the production code, writes the PNGs and CSVs,
// and dumps what it held in memory so the reader can compare file against memory (the profile's samples and positions as
// little-endian Doubles, the bar plan `render` returned, the window fractions it passed, the real images `ImageOpening`
// returned; for P7, each label alone, drawn upright in a plain CoreGraphics context by `uprightLabel`). It builds the canvas exactly as the app does (`FloatImage.normalized()`, the finite range for `rawRange`) and
// restates `DisplayWindow.fractions` below because TEMSession is not in this harness's closure. The negative controls are
// SOURCE mutants of ProfileCSV.swift, ImageExport.swift and ImageExport+Overlays.swift, built and run by run.sh; this file
// does not know them. The optional case and variant lists run a subset (a mutant need only render the case it is aimed at).
//
// Exit codes: 0 written, 2 any failure to render or write (never 1: reference.py's failure exit is the only 1 a mutant is
// credited with).

@testable import TEMCore
import CoreGraphics
import CoreText
import Foundation
import ImagoCore
import ImagoFFT

struct Manifest: Decodable {
    struct Axis: Decodable {
        let scale: Double
        let units: String
        let origin: Double
    }
    struct Image: Decodable {
        let width: Int
        let height: Int
        let pixels: String
        let open: String?
        let x: Axis?
        let y: Axis?
        let fileName: String
        let object: String
        let notes: [String]
    }
    struct Variant: Decodable {
        let name: String
        let scaleBar: Bool
        let marks: Bool
    }
    struct MarkSpec: Decodable {
        let kind: String
        let points: [ImagePoint]
        let width: Int
        let label: String
    }
    struct Render: Decodable {
        let name: String
        let image: String
        let lut: String
        let colormap: String
        let windowLow: Float?
        let windowHigh: Float?
        let gamma: Double
        let software: String
        let variants: [Variant]
        let marks: [MarkSpec]
    }
    struct Shown: Decodable {
        let unit: String
        let factor: Double
    }
    struct CSV: Decodable {
        let name: String
        let image: String
        let start: ImagePoint
        let end: ImagePoint
        let width: Int
        let shown: Shown?
        let software: String
    }
    /// The Results room's CSV (R-P1): marks and spots built by TEMCore's `ResultRow` builders from planted
    /// points and clicks, and raw rows with planted bit patterns, written through `ResultsCSV`.
    struct ResultsCase: Decodable {
        struct MarkSpec: Decodable {
            let kind: String
            let id: String
            let label: String
            let points: [[Double]]
            let width: Int?
            let uncalibrated: Bool?
            let lineage: String?
        }
        struct CropSpec: Decodable {
            let row: Int
            let col: Int
            let height: Int
            let width: Int
        }
        struct SpotSpec: Decodable {
            let id: String
            let number: Int
            let click: [Int]
            let crop: CropSpec?
        }
        struct EntrySpec: Decodable {
            let name: String
            /// The Double's IEEE bit pattern, 16 hex digits big-endian; nil for a words-only entry.
            let bits: String?
            let unit: String
            let text: String
        }
        struct RawSpec: Decodable {
            let product: String
            let id: String
            let label: String
            let lineage: String?
            let refusal: String?
            let entries: [EntrySpec]
        }
        let name: String
        let image: String
        let software: String
        let session: String
        let marks: [MarkSpec]
        let spots: [SpotSpec]
        let raw: [RawSpec]
    }
    let images: [String: Image]
    let renders: [Render]
    let csvs: [CSV]
    let results: [ResultsCase]
}

/// What `render` returned besides the PNG, for reference.py to hold against the Description chunk.
struct RenderedDump: Encodable {
    struct Plan: Encodable {
        let perPixel: Double
        let unit: String
        let value: Double
        let labelUnit: String
        let label: String
        let lengthPixels: Double
        let drawnPixels: Int
        let overlayScale: Int
    }
    let width: Int
    let height: Int
    let barLeftOut: Bool
    let bar: Plan?
}

struct ProfileDump: Encodable {
    let unit: String
    let isPhysical: Bool
    let width: Int
    let count: Int
}

struct OpenedDump: Encodable {
    struct Axis: Encodable {
        let scale: Double
        let units: String
        let origin: Double
    }
    let width: Int
    let height: Int
    let x: Axis?
    let y: Axis?
    let fileName: String
    let source: String
    let notes: [String]
}

/// `DisplayWindow.fractions` (Sources/TEMSession/ImagePresentation.swift), restated line for line: TEMSession is not in this
/// harness's closure. reference.py recomputes it and compares what this passes (`<case>.window.json`) with its own.
func windowFractions(low: Float?, high: Float?, rawRange: ClosedRange<Float>?) -> (low: Float, high: Float) {
    guard let rawRange, rawRange.upperBound > rawRange.lowerBound else { return (0, 1) }
    let span = rawRange.upperBound - rawRange.lowerBound
    let lo = min(max(((low ?? rawRange.lowerBound) - rawRange.lowerBound) / span, 0), 1)
    let hi = min(max(((high ?? rawRange.upperBound) - rawRange.lowerBound) / span, 0), 1)
    return lo < hi ? (lo, hi) : (0, 1)
}

/// GATE B R1 (P7): `line` drawn UPRIGHT in a plain CoreGraphics context (origin bottom-left, no flip, no translate), white on black, the
/// settings the export draws text under; `baselineFromTop` is measured down from the box's top edge. Memory row 0 of a CGContext is
/// the TOP row, so the bytes read back top to bottom are the picture as a person sees it: an oracle that does not use `draw`.
func uprightLabel(_ line: CTLine, boxWidth: Int, boxHeight: Int, originX: Double, baselineFromTop: Double) -> [UInt8] {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(data: nil, width: boxWidth, height: boxHeight, bitsPerComponent: 8, bytesPerRow: boxWidth * 4,
                            space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: boxWidth, height: boxHeight))
    context.setAllowsAntialiasing(true); context.setShouldAntialias(true)
    context.setAllowsFontSmoothing(false); context.setShouldSmoothFonts(false)
    context.setAllowsFontSubpixelPositioning(true); context.setShouldSubpixelPositionFonts(true)
    context.setAllowsFontSubpixelQuantization(false); context.setShouldSubpixelQuantizeFonts(false)
    context.textMatrix = .identity
    context.textPosition = CGPoint(x: originX, y: Double(boxHeight) - baselineFromTop)
    CTLineDraw(line, context)
    let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
    var rgb = [UInt8](repeating: 0, count: boxWidth * boxHeight * 3)
    for row in 0..<boxHeight {
        for column in 0..<boxWidth {
            let from = row * context.bytesPerRow + 4 * column, to = 3 * (row * boxWidth + column)
            rgb[to] = bytes[from]; rgb[to + 1] = bytes[from + 1]; rgb[to + 2] = bytes[from + 2]
        }
    }
    return rgb
}

struct LabelDump: Encodable {
    let boxWidth: Int
    let boxHeight: Int
    let rgb: String
}
struct LabelsDump: Encodable {
    let marks: [LabelDump]
    let bar: LabelDump
}

func readFloats(_ url: URL) throws -> [Float] {
    try Data(contentsOf: url).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
}

/// A Double as its IEEE bit pattern, 16 hex digits big-endian: the memory the file must re-read to, bit for bit.
func hexBits(_ v: Double) -> String { String(format: "%016llx", v.bitPattern) }

struct ResultsEntryDump: Encodable {
    let name: String
    let bits: String?
    let unit: String
    let text: String
}
struct ResultsRowDump: Encodable {
    let id: String
    let product: String
    let group: String
    let label: String
    let lineage: String?
    let refusal: String?
    let entries: [ResultsEntryDump]
}
/// The truth read from TEMCore's measurements directly (`ImageMeasurement`, ImagoKit's `SpotMeasurement`), not through the row builders, so a
/// builder that puts the wrong number under a name is not its own witness.
struct ResultsTruthDump: Encodable {
    let marks: [String: [String: String]]
    let spots: [String: [String: String]]
}

func littleEndian(_ values: [Double]) -> Data {
    var data = Data(capacity: values.count * 8)
    for v in values {
        var bits = v.bitPattern.littleEndian
        withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
    }
    return data
}

func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    try encoder.encode(value).write(to: url)
}

func axis(_ a: Manifest.Axis?) -> AxisCalibration? { a.map { AxisCalibration(scale: $0.scale, unit: $0.units, origin: $0.origin) } }

@main
struct ExportParity {
    static func main() {
        do {
            try run()
        } catch {
            print("export-parity harness: \(error)")
            exit(2)
        }
    }

    static func run() throws {
        let args = CommandLine.arguments
        guard args.count >= 3 else {
            print("usage: harness <planted dir> <out dir> [<case,case...|all> [<variant,variant...|all>]]")
            exit(64)
        }
        let planted = URL(fileURLWithPath: args[1], isDirectory: true)
        let out = URL(fileURLWithPath: args[2], isDirectory: true)
        let only: Set<String>? = args.count > 3 && args[3] != "all" ? Set(args[3].split(separator: ",").map(String.init)) : nil
        let variantsWanted: Set<String>? = args.count > 4 && args[4] != "all" ? Set(args[4].split(separator: ",").map(String.init)) : nil
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let opened = out.appendingPathComponent("opened", isDirectory: true)
        try FileManager.default.createDirectory(at: opened, withIntermediateDirectories: true)
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: planted.appendingPathComponent("manifest.json")))
        func wanted(_ name: String) -> Bool { only?.contains(name) ?? true }

        // Images, loaded when first used. A real file is opened with ImageOpening and what it returned is dumped for
        // reference.py (P0-open: pixels and calibration equal what ncempy reads); a planted one is the planted pixels.
        var images: [String: CalibratedImage] = [:]
        func image(_ name: String) throws -> CalibratedImage {
            if let cached = images[name] { return cached }
            guard let m = manifest.images[name] else { throw NSError(domain: "export-parity", code: 1, userInfo: [NSLocalizedDescriptionKey: "no image '\(name)' in the manifest"]) }
            let made: CalibratedImage
            if let path = m.open {
                made = try ImageOpening.openNow(path: path)
                try Data(bytes: made.pixels, count: made.pixels.count * MemoryLayout<Float>.size)
                    .write(to: opened.appendingPathComponent("\(name).f32"))
                let dump = OpenedDump(width: made.width, height: made.height,
                                      x: made.x.map { .init(scale: $0.scale, units: $0.unit, origin: $0.origin) },
                                      y: made.y.map { .init(scale: $0.scale, units: $0.unit, origin: $0.origin) },
                                      fileName: made.fileName, source: made.source, notes: made.notes)
                try writeJSON(dump, to: opened.appendingPathComponent("\(name).json"))
            } else {
                let pixels = try readFloats(planted.appendingPathComponent(m.pixels))
                made = CalibratedImage(width: m.width, height: m.height, pixels: pixels, x: axis(m.x), y: axis(m.y),
                                       fileName: m.fileName, source: m.object, voltage: nil, notes: m.notes)
            }
            images[name] = made
            return made
        }

        // PNGs.
        for r in manifest.renders where wanted(r.name) {
            let source = try image(r.image)
            let canvasImage = FloatImage(width: source.width, height: source.height, pixels: source.pixels)
            let canvas = canvasImage.normalized()
            let (low, high) = canvasImage.minMax
            let rawRange: ClosedRange<Float>? = source.pixels.contains(where: { $0.isFinite }) ? low...high : nil
            let fractions = windowFractions(low: r.windowLow, high: r.windowHigh, rawRange: rawRange)
            let lut = [UInt8](try Data(contentsOf: planted.appendingPathComponent(r.lut)))
            let display = ImageExport.Display(normalized: canvas, width: source.width, height: source.height,
                                              low: fractions.low, high: fractions.high, gamma: r.gamma, lut: lut,
                                              colormap: r.colormap, windowLow: r.windowLow, windowHigh: r.windowHigh,
                                              rawRange: rawRange)
            let exportSource = ExportSource(image: source, software: r.software)
            let marks = try r.marks.map { spec -> ImageExport.Mark in
                guard let kind = ImageExport.MarkKind(rawValue: spec.kind) else {
                    throw NSError(domain: "export-parity", code: 2, userInfo: [NSLocalizedDescriptionKey: "unknown mark kind '\(spec.kind)'"])
                }
                return ImageExport.Mark(kind: kind, points: spec.points, width: spec.width, label: spec.label)
            }
            try writeJSON(["low": Double(fractions.low), "high": Double(fractions.high)], to: out.appendingPathComponent("\(r.name).window.json"))
            var barLabel: String?
            for v in r.variants where variantsWanted?.contains(v.name) ?? true {
                let rendered = try ImageExport.render(source: exportSource, display: display, marks: marks,
                                                      options: ImageExport.Options(scaleBar: v.scaleBar, marks: v.marks))
                try rendered.png.write(to: out.appendingPathComponent("\(r.name).\(v.name).png"))
                if v.name == "bar" { barLabel = rendered.bar?.label }
                let plan = rendered.bar.map {
                    RenderedDump.Plan(perPixel: $0.perPixel, unit: $0.unit, value: $0.value, labelUnit: $0.labelUnit, label: $0.label,
                                      lengthPixels: $0.lengthPixels, drawnPixels: $0.drawnPixels, overlayScale: $0.overlayScale)
                }
                try writeJSON(RenderedDump(width: rendered.width, height: rendered.height, barLeftOut: rendered.barLeftOut, bar: plan),
                              to: out.appendingPathComponent("\(r.name).\(v.name).rendered.json"))
            }
            if r.name.hasPrefix("p7"), let barLabel {
                // GATE B R1 (P7): each label alone, drawn upright by `uprightLabel`, for reference.py to hold the crops against.
                let u = ScaleBarMath.overlayScale(width: source.width, height: source.height)
                var dumps: [LabelDump] = []
                for (k, spec) in r.marks.enumerated() where !spec.label.isEmpty {
                    let text = ImageExport.textLine(spec.label, font: ImageExport.markFont(overlayScale: u))!
                    let w = text.boxWidth + 8 * u, h = text.boxHeight + 2 * u
                    let name = "\(r.name).m\(k).rgb"
                    try Data(uprightLabel(text.line, boxWidth: w, boxHeight: h, originX: Double(4 * u), baselineFromTop: Double(u) + text.ascent))
                        .write(to: out.appendingPathComponent(name))
                    dumps.append(LabelDump(boxWidth: w, boxHeight: h, rgb: name))
                }
                let text = ImageExport.textLine(barLabel, font: ImageExport.scaleBarFont(overlayScale: u))!
                let barName = "\(r.name).bar.rgb"
                try Data(uprightLabel(text.line, boxWidth: text.boxWidth, boxHeight: text.boxHeight, originX: 0, baselineFromTop: text.ascent))
                    .write(to: out.appendingPathComponent(barName))
                try writeJSON(LabelsDump(marks: dumps, bar: LabelDump(boxWidth: text.boxWidth, boxHeight: text.boxHeight, rgb: barName)),
                              to: out.appendingPathComponent("\(r.name).labels.json"))
            }
        }

        // The Results CSV (R-P1): rows built by the production builders from the planted points and clicks, the planted raw rows, the
        // file written by `ResultsCSV`, and what the rows and the measurements held in memory dumped beside it.
        for c in manifest.results where wanted(c.name) {
            let source = try image(c.image)
            var rows: [ResultRow] = []
            var marksTruth: [String: [String: String]] = [:], spotsTruth: [String: [String: String]] = [:]
            for m in c.marks {
                let x = m.uncalibrated == true ? nil : source.x, y = m.uncalibrated == true ? nil : source.y
                let p = m.points.map { ImagePoint(x: $0[0], y: $0[1]) }
                var t: [String: String] = [:]
                switch m.kind {
                case "distance", "profile":
                    let d = ImageMeasurement.distance(p[0], p[1], x: x, y: y)
                    t["length_px"] = hexBits(d.pixels)
                    if let physical = d.physical { t["length"] = hexBits(physical) }
                    rows.append(m.kind == "distance"
                        ? ResultRow.distance(id: m.id, label: m.label, a: p[0], b: p[1], x: x, y: y, lineage: m.lineage)
                        : ResultRow.profile(id: m.id, label: m.label, a: p[0], b: p[1], width: m.width ?? 1, x: x, y: y, lineage: m.lineage))
                default:
                    if let a = ImageMeasurement.angle(p[0], vertex: p[1], p[2], x: x, y: y) { t["angle"] = hexBits(a.degrees) }
                    rows.append(ResultRow.angle(id: m.id, label: m.label, a: p[0], vertex: p[1], c: p[2], x: x, y: y, lineage: m.lineage))
                }
                marksTruth[m.id] = t
            }
            for s in c.spots {
                let crop = s.crop.map { PixelCrop(row: $0.row, col: $0.col, height: $0.height, width: $0.width) }
                let region = s.crop.map { ResultRow.Region(col: $0.col, row: $0.row, width: $0.width, height: $0.height) }
                    ?? ResultRow.Region(col: 0, row: 0, width: source.width, height: source.height)
                do {
                    let m = try SpotMeasurement.measure(source.micrograph, crop: crop, clickRow: s.click[0], clickColumn: s.click[1])
                    rows.append(ResultRow.spot(id: s.id, number: s.number, measured: m, region: region))
                    spotsTruth[s.id] = ["d": hexBits(m.d), "q": hexBits(m.q), "qx": hexBits(m.qx), "qy": hexBits(m.qy),
                                        "centroid_col": hexBits(m.centroidCol), "centroid_row": hexBits(m.centroidRow)]
                } catch let failure as SpotMeasurementError {
                    rows.append(ResultRow.unmeasuredSpot(id: s.id, number: s.number, clickRow: s.click[0], clickCol: s.click[1],
                                                         region: region, reason: ResultRow.reason(failure)))
                }
            }
            for r in c.raw {
                guard let product = ResultRow.Product(rawValue: r.product) else {
                    throw NSError(domain: "export-parity", code: 3, userInfo: [NSLocalizedDescriptionKey: "unknown product '\(r.product)'"])
                }
                let entries = r.entries.map { e -> ResultRow.Entry in
                    let value = e.bits.flatMap { UInt64($0, radix: 16) }.map { Double(bitPattern: $0) }
                    return ResultRow.Entry(e.name, value, unit: e.unit, text: e.text)
                }
                rows.append(ResultRow(id: r.id, product: product, label: r.label, entries: entries, refusal: r.refusal, lineage: r.lineage))
            }
            let dump = rows.map { row in
                ResultsRowDump(id: row.id, product: row.product.rawValue, group: row.group.rawValue, label: row.label,
                               lineage: row.lineage, refusal: row.refusal,
                               entries: row.entries.map { ResultsEntryDump(name: $0.name, bits: $0.value.map(hexBits), unit: $0.unit, text: $0.text) })
            }
            try writeJSON(dump, to: out.appendingPathComponent("\(c.name).rows.json"))
            try writeJSON(ResultsTruthDump(marks: marksTruth, spots: spotsTruth), to: out.appendingPathComponent("\(c.name).truth.json"))
            var sentences: [String: String] = [:]
            for product in ResultRow.Product.allCases { sentences[product.rawValue] = product.validation }
            try writeJSON(sentences, to: out.appendingPathComponent("\(c.name).validation.json"))
            if let text = ResultsCSV.text(rows, source: ExportSource(image: source, software: c.software), session: c.session) {
                try Data(text.utf8).write(to: out.appendingPathComponent("\(c.name).csv"))
            } else {
                try Data().write(to: out.appendingPathComponent("\(c.name).csv.none"))
            }
        }

        // CSVs: the file, and the profile in memory beside it.
        for c in manifest.csvs where wanted(c.name) {
            let source = try image(c.image)
            let profile = LineProfile.sample(source, from: c.start, to: c.end, width: c.width)
            try littleEndian(profile.positions).write(to: out.appendingPathComponent("\(c.name).positions.f64"))
            try littleEndian(profile.samples).write(to: out.appendingPathComponent("\(c.name).samples.f64"))
            try writeJSON(ProfileDump(unit: profile.unit, isPhysical: profile.isPhysical, width: profile.width, count: profile.samples.count),
                          to: out.appendingPathComponent("\(c.name).profile.json"))
            let text = ProfileCSV.text(profile, start: c.start, end: c.end, source: ExportSource(image: source, software: c.software),
                                       shown: c.shown.map { (unit: $0.unit, factor: $0.factor) })
            if let text {
                try Data(text.utf8).write(to: out.appendingPathComponent("\(c.name).csv"))
            } else {
                try Data().write(to: out.appendingPathComponent("\(c.name).csv.none"))
            }
        }
    }
}
