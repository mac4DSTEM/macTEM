// tools/parity/fft-export-parity/main.swift — macTEM's FFT-room export (`FFTExport`, `RadialProfileCSV`, `SpotsCSV`,
// `ImageExport` with a provenance and spot marks; TEMCore, through Package.swift's FFTExportParity target) WRITES what
// reference.py planted; reference.py `check` reads it back with Pillow, numpy and Python's own `float`.
//
//     harness <planted dir of reference.py> <out dir> [<case,case...|all>]
//
// This file does no checking. For each planted case it does what the app does — the transform of the region, `SpectrumDisplay`,
// the canvas normalised over its finite range, the radial profile at its default width, `SpotMeasurement` at each click — then writes
// the transform's PNG (no overlays, with spots and bar, spots alone on black, bar alone on black), the profile's CSV and the
// spots' CSV with the production writers, and dumps what it held in memory (the canvas, the window, the profile, every spot's
// numbers) for the reader to hold the files against. `windowFractions` restates `DisplayWindow.fractions` (TEMSession is not in
// the closure). Exit codes: 0 written, 2 any failure (never 1: reference.py's failure exit is the only 1 a mutant is credited with).

@testable import TEMCore
import CoreGraphics
import Foundation
import ImagoCore
import ImagoFFT

struct Manifest: Decodable {
    struct Axis: Decodable { let scale: Double; let units: String; let origin: Double }
    struct Crop: Decodable { let row: Int; let col: Int; let height: Int; let width: Int }
    struct Case: Decodable {
        let name: String
        let width: Int
        let height: Int
        let pixels: String
        let x: Axis
        let y: Axis
        let fileName: String
        let crop: Crop?
        let windowLow: Float?
        let windowHigh: Float?
        let clicks: [[Int]]          // [row, col]
        let inMask: [Bool]
        let maskRadius: Double
        let maskEdge: Double
    }
    let lut: String
    let cases: [Case]
}

struct SpotDump: Encodable {
    let number: Int
    let qx: Double, qy: Double, q: Double, d: Double
    let centroidRow: Double, centroidCol: Double
    let clickedRow: Int, clickedCol: Int
    let neighbour: Bool
    let inMask: Bool
    let units: String
    let reciprocalUnits: String
}
struct SpotsDump: Encodable { let spots: [SpotDump]; let omitted: Int }
struct ProfileDump: Encodable { let width: Double; let units: String; let count: [Int] }
struct WindowDump: Encodable {
    let low: Double, high: Double          // the fractions the shader gets
    let rawLow: Double?, rawHigh: Double?  // the window in raw v, as the metadata states it
    let rangeLow: Double?, rangeHigh: Double?
    let spacingX: Double, spacingY: Double, unitsX: String, unitsY: String
    let width: Int, height: Int
}
struct BarDump: Encodable {
    struct Plan: Encodable {
        let perPixel: Double, value: Double, lengthPixels: Double
        let unit: String, labelUnit: String, label: String
        let drawnPixels: Int, overlayScale: Int
    }
    let width: Int, height: Int, barLeftOut: Bool, bar: Plan?
}

/// `DisplayWindow.fractions` (Sources/TEMSession/ImagePresentation.swift), restated line for line.
func windowFractions(low: Float?, high: Float?, rawRange: ClosedRange<Float>?) -> (low: Float, high: Float) {
    guard let rawRange, rawRange.upperBound > rawRange.lowerBound else { return (0, 1) }
    let span = rawRange.upperBound - rawRange.lowerBound
    let lo = min(max(((low ?? rawRange.lowerBound) - rawRange.lowerBound) / span, 0), 1)
    let hi = min(max(((high ?? rawRange.upperBound) - rawRange.lowerBound) / span, 0), 1)
    return lo < hi ? (lo, hi) : (0, 1)
}

func readFloats(_ url: URL) throws -> [Float] {
    try Data(contentsOf: url).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
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

@main
struct FFTExportParity {
    static func main() {
        do { try run() } catch {
            print("fft-export-parity harness: \(error)")
            exit(2)
        }
    }

    static func run() throws {
        let args = CommandLine.arguments
        guard args.count >= 3 else { print("usage: harness <planted dir> <out dir> [<case,case...|all>]"); exit(64) }
        let planted = URL(fileURLWithPath: args[1], isDirectory: true)
        let out = URL(fileURLWithPath: args[2], isDirectory: true)
        let only: Set<String>? = args.count > 3 && args[3] != "all" ? Set(args[3].split(separator: ",").map(String.init)) : nil
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: planted.appendingPathComponent("manifest.json")))
        let lut = [UInt8](try Data(contentsOf: planted.appendingPathComponent(manifest.lut)))
        let software = "macTEM 0.1.0 (1)"

        for c in manifest.cases where only?.contains(c.name) ?? true {
            let image = CalibratedImage(
                width: c.width, height: c.height, pixels: try readFloats(planted.appendingPathComponent(c.pixels)),
                x: AxisCalibration(scale: c.x.scale, unit: c.x.units, origin: c.x.origin),
                y: AxisCalibration(scale: c.y.scale, unit: c.y.units, origin: c.y.origin),
                fileName: c.fileName, source: "ImageList.1", voltage: nil, notes: [])
            let crop = c.crop.map { PixelCrop(row: $0.row, col: $0.col, height: $0.height, width: $0.width) }

            // What the room's owner holds: the spectrum product (SpectrumDisplay normalised over its finite range, the profile).
            let spectrum = try PowerSpectrum.compute(image.micrograph, crop: crop)
            let display = SpectrumDisplay.make(spectrum)
            let floatImage = FloatImage(width: display.width, height: display.height, pixels: display.values)
            let canvas = floatImage.normalized()
            let rawRange: ClosedRange<Float>? = display.values.contains(where: \.isFinite) ? floatImage.minMax.0...floatImage.minMax.1 : nil
            let profile = try? RadialProfile.compute(spectrum)
            let windowLow = c.windowLow ?? display.defaultWindow?.low, windowHigh = c.windowHigh ?? display.defaultWindow?.high
            let fractions = windowFractions(low: windowLow, high: windowHigh, rawRange: rawRange)
            try Data(bytes: canvas, count: canvas.count * MemoryLayout<Float>.size).write(to: out.appendingPathComponent("\(c.name).canvas.f32"))
            try writeJSON(WindowDump(low: Double(fractions.low), high: Double(fractions.high), rawLow: windowLow.map(Double.init),
                                     rawHigh: windowHigh.map(Double.init), rangeLow: rawRange.map { Double($0.lowerBound) },
                                     rangeHigh: rawRange.map { Double($0.upperBound) }, spacingX: spectrum.spacingX,
                                     spacingY: spectrum.spacingY, unitsX: spectrum.unitsX, unitsY: spectrum.unitsY,
                                     width: spectrum.width, height: spectrum.height),
                          to: out.appendingPathComponent("\(c.name).window.json"))

            // The spots, each as the room measures a click.
            var rows: [SpotsCSV.Row] = []
            var dumps: [SpotDump] = []
            var omitted = 0
            for (k, click) in c.clicks.enumerated() {
                guard let m = try? SpotMeasurement.measure(image.micrograph, crop: crop, clickRow: click[0], clickColumn: click[1]) else { omitted += 1; continue }
                rows.append(SpotsCSV.Row(number: k + 1, measured: m, inMask: c.inMask[k]))
                dumps.append(SpotDump(number: k + 1, qx: m.qx, qy: m.qy, q: m.q, d: m.d, centroidRow: m.centroidRow,
                                      centroidCol: m.centroidCol, clickedRow: m.clickedRow, clickedCol: m.clickedCol,
                                      neighbour: m.neighbour, inMask: c.inMask[k], units: m.units, reciprocalUnits: m.reciprocalUnits))
            }
            try writeJSON(SpotsDump(spots: dumps, omitted: omitted), to: out.appendingPathComponent("\(c.name).spots.json"))

            let header = FFTExportHeader(
                software: software, fileName: image.fileName, object: image.source, imageWidth: image.width, imageHeight: image.height,
                x: image.x, y: image.y, notes: [], crop: crop, spectrumWidth: spectrum.width, spectrumHeight: spectrum.height,
                spacingX: spectrum.spacingX, spacingY: spectrum.spacingY, unitsX: spectrum.unitsX, unitsY: spectrum.unitsY)

            // The CSVs.
            if let profile {
                try littleEndian(profile.mean).write(to: out.appendingPathComponent("\(c.name).profile.f64"))
                try writeJSON(ProfileDump(width: profile.width, units: profile.units, count: profile.count),
                              to: out.appendingPathComponent("\(c.name).profile.json"))
                if let text = RadialProfileCSV.text(profile, header: header) {
                    try Data(text.utf8).write(to: out.appendingPathComponent("\(c.name).radial.csv"))
                }
            }
            if let text = SpotsCSV.text(rows: rows, omitted: omitted, maskRadius: c.maskRadius, maskEdge: c.maskEdge,
                                        notes: ["a note, verbatim"], header: header) {
                try Data(text.utf8).write(to: out.appendingPathComponent("\(c.name).spots.csv"))
            }

            // The PNGs. The marks are what the snapshot makes: one `.spot` per measured spot, at its centroid, labelled by its number.
            let marks = rows.map { ImageExport.Mark(kind: .spot, points: [ImagePoint(x: $0.measured.centroidCol, y: $0.measured.centroidRow)],
                                                    width: 1, label: "\($0.number)") }
            let source = FFTExport.transformSource(header)
            let shown = ImageExport.Display(normalized: canvas, width: display.width, height: display.height, low: fractions.low,
                                            high: fractions.high, gamma: 1, lut: lut, colormap: "gray", windowLow: windowLow,
                                            windowHigh: windowHigh, rawRange: rawRange)
            let black = ImageExport.Display(normalized: [Float](repeating: 0, count: canvas.count), width: display.width,
                                            height: display.height, low: 0, high: 1, gamma: 1, lut: lut, colormap: "gray")
            func write(_ name: String, _ display: ImageExport.Display, marks: [ImageExport.Mark], bar: Bool, spots: Bool) throws {
                let rendered = try ImageExport.render(source: source, display: display, marks: marks,
                                                      options: ImageExport.Options(scaleBar: bar, marks: spots),
                                                      provenance: FFTExport.transformProvenance(header, spotsDrawn: spots ? marks.count : 0))
                try rendered.png.write(to: out.appendingPathComponent("\(c.name).\(name).png"))
                let plan = rendered.bar.map {
                    BarDump.Plan(perPixel: $0.perPixel, value: $0.value, lengthPixels: $0.lengthPixels, unit: $0.unit,
                                 labelUnit: $0.labelUnit, label: $0.label, drawnPixels: $0.drawnPixels, overlayScale: $0.overlayScale)
                }
                try writeJSON(BarDump(width: rendered.width, height: rendered.height, barLeftOut: rendered.barLeftOut, bar: plan),
                              to: out.appendingPathComponent("\(c.name).\(name).rendered.json"))
            }
            try write("plain", shown, marks: marks, bar: false, spots: false)
            try write("full", shown, marks: marks, bar: true, spots: true)
            try write("rings", black, marks: marks, bar: false, spots: true)
            try write("bar", black, marks: [], bar: true, spots: false)
        }
    }
}
