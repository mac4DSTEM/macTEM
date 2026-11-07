//
//  SEMEDSFile.swift
//  Role: what a SEM-EDS map file holds once read (Bruker `.bcf`/`.spx`, EDAX `.spd`/`.lsd`/`.spc`, JEOL `.pts`/`.eds`/`.img`/`.map`/`.asw`):
//        its signals in the order RosettaSciIO 0.15.0 returns them (spectrum images, single spectra, images), each with its axes as
//        rsciio states them (name, size, scale, offset, units), the dtype rsciio gives the data, and the metadata fields the app maps,
//        under rsciio's names. The counts are exact integers; nothing here computes a number. `CSRSpectrumImage` holds a spectrum image
//        as per-pixel compressed rows (an event-counting detector fills a few channels per pixel), which is what the EDS room sums.
//        Parity: macTEMTests/SEMEDSMapReaderTests.swift against tools/parity/sem/references/m7/read-* (emit.py, RosettaSciIO 0.15.0).
//

import Foundation
import FormatoCore
import SpectroCore

/// One axis of a signal, as rsciio states it: the physical value at index i is offset + i · scale, in `units` (nil when the file
/// states no unit, as rsciio leaves it).
package nonisolated struct SEMEDSAxis: Equatable, Sendable {
    package var name: String
    package var size: Int
    package var scale: Double
    package var offset: Double
    package var units: String?

    package init(name: String, size: Int, scale: Double, offset: Double, units: String?) {
        self.name = name; self.size = size; self.scale = scale; self.offset = offset; self.units = units
    }
}

/// The metadata the app maps from a signal, under rsciio's names (`General`, `Signal`, `Acquisition_instrument.<mode>`, its
/// `Detector.EDS` and `Stage`, `Sample`). nil (or an absent list) where rsciio writes nothing.
package nonisolated struct SEMEDSMetadata: Equatable, Sendable {
    package var originalFilename: String?
    package var title: String?
    package var date: String?
    package var time: String?
    package var signalType: String?
    /// "SEM" or "TEM", the key of `Acquisition_instrument` (rsciio guesses it from the beam energy: above 30 kV is TEM).
    package var mode: String?
    /// kV.
    package var beamEnergy: Double?
    package var magnification: Double?
    /// Degrees.
    package var azimuthAngle: Double?
    package var elevationAngle: Double?
    /// eV.
    package var energyResolutionMnKa: Double?
    /// Seconds.
    package var liveTime: Double?
    package var realTime: Double?
    package var detectorType: String?
    package var tiltAlpha: Double?
    package var sampleName: String?
    package var elements: [String]?
    package var xrayLines: [String]?

    package init() {}

    /// The fields under emit.py's flattened keys (`tools/parity/sem/emit.py`, `_eds_metadata`), present only where set.
    package var flattened: [String: Any] {
        var out: [String: Any] = [:]
        func put(_ key: String, _ value: Any?) { if let value { out[key] = value } }
        put("original_filename", originalFilename); put("title", title); put("date", date); put("time", time)
        put("signal_type", signalType); put("mode", mode); put("beam_energy", beamEnergy); put("magnification", magnification)
        put("azimuth_angle", azimuthAngle); put("elevation_angle", elevationAngle); put("energy_resolution_MnKa", energyResolutionMnKa)
        put("live_time", liveTime); put("real_time", realTime); put("detector_type", detectorType); put("tilt_alpha", tiltAlpha)
        put("sample_name", sampleName); put("elements", elements); put("xray_lines", xrayLines)
        return out
    }
}

/// A spectrum image: `shape` and `axes` as rsciio returns them ([y, x, energy] for a map, [x, energy] for an EDAX line scan, which
/// `cube` holds as one row), the counts per pixel and channel.
package nonisolated struct SEMEDSSpectrumImage: Sendable {
    package var shape: [Int]
    package var axes: [SEMEDSAxis]
    /// rsciio's dtype for the data ("uint8", "uint16", "uint32"); the counts here are the same integers held as UInt32.
    package var dtype: String
    package var cube: CSRSpectrumImage
    package var metadata: SEMEDSMetadata

    /// The energy axis (the last).
    package var energyAxis: SEMEDSAxis { axes[axes.count - 1] }
}

/// One spectrum.
package nonisolated struct SEMEDSSpectrum: Sendable, Equatable {
    package var axis: SEMEDSAxis
    package var dtype: String
    package var counts: [Int64]
    package var metadata: SEMEDSMetadata
}

/// One image (an SE, BSE or HAADF image recorded with the map, a JEOL image or element map), row-major, row 0 first.
package nonisolated struct SEMEDSImage: Sendable, Equatable {
    package var axes: [SEMEDSAxis]
    package var dtype: String
    package var width: Int
    package var height: Int
    package var pixels: [UInt32]
    package var metadata: SEMEDSMetadata
}

package nonisolated enum SEMEDSSignal: Sendable {
    case spectrumImage(SEMEDSSpectrumImage)
    case spectrum(SEMEDSSpectrum)
    case image(SEMEDSImage)
}

/// A read file: its signals in rsciio's order.
package nonisolated struct SEMEDSFile: Sendable {
    package var url: URL
    package var signals: [SEMEDSSignal]

    package var spectrumImages: [SEMEDSSpectrumImage] {
        signals.compactMap { if case .spectrumImage(let s) = $0 { s } else { nil } }
    }
    package var spectra: [SEMEDSSpectrum] { signals.compactMap { if case .spectrum(let s) = $0 { s } else { nil } } }
    package var images: [SEMEDSImage] { signals.compactMap { if case .image(let s) = $0 { s } else { nil } } }
}

/// A file a SEM-EDS reader does not read, in a sentence.
package nonisolated struct SEMEDSReadError: Error, LocalizedError, Equatable {
    package var text: String
    package init(_ text: String) { self.text = text }
    package var errorDescription: String? { text }
}

// MARK: - The spectrum image store

/// A spectrum image as per-pixel compressed rows: `rowOffsets` (ny · nx + 1 entries) into `channelIndex` and `counts`; inside a pixel
/// the channels ascend and each appears once with a nonzero count. Every sum is an exact UInt64 sum.
package nonisolated struct CSRSpectrumImage: SpectrumImage, Equatable {
    package let ny: Int
    package let nx: Int
    package let channels: Int
    package let rowOffsets: [Int]
    package let channelIndex: [UInt16]
    package let counts: [UInt32]

    package init(ny: Int, nx: Int, channels: Int, rowOffsets: [Int], channelIndex: [UInt16], counts: [UInt32]) {
        precondition(rowOffsets.count == ny * nx + 1 && channelIndex.count == counts.count && rowOffsets.last == counts.count,
                     "CSRSpectrumImage: the rows must describe the counts")
        self.ny = ny; self.nx = nx; self.channels = channels
        self.rowOffsets = rowOffsets; self.channelIndex = channelIndex; self.counts = counts
    }

    private static let blockPixels = 4096

    /// One pixel's spectrum (`channels` counts).
    package func spectrum(pixel p: Int) -> [UInt32] {
        var out = [UInt32](repeating: 0, count: channels)
        for k in rowOffsets[p]..<rowOffsets[p + 1] { out[Int(channelIndex[k])] = counts[k] }
        return out
    }

    /// The total count of every pixel, row-major.
    package func pixelTotals() -> [Int64] {
        (0..<(ny * nx)).map { p in
            var s: Int64 = 0
            for k in rowOffsets[p]..<rowOffsets[p + 1] { s += Int64(counts[k]) }
            return s
        }
    }

    package func sum(mask: PixelMask?) -> [UInt64] {
        // The closure never answers true, so the throwing core cannot throw.
        try! sum(mask: mask, cancelled: { false }, progress: nil)
    }

    package func sum(mask: PixelMask?, cancelled: @Sendable () -> Bool, progress: (@Sendable (Double) -> Void)?) throws -> [UInt64] {
        precondition(mask == nil || mask!.count == ny * nx, "mask length must be ny*nx")
        var out = [UInt64](repeating: 0, count: channels)
        let n = ny * nx
        for start in stride(from: 0, to: n, by: Self.blockPixels) {
            try FormatoCancellation.check(cancelled)
            let end = min(start + Self.blockPixels, n)
            for p in start..<end where mask?[p] ?? true {
                for k in rowOffsets[p]..<rowOffsets[p + 1] { out[Int(channelIndex[k])] &+= UInt64(counts[k]) }
            }
            progress?(Double(end) / Double(n))
        }
        if n == 0 { progress?(1) }
        return out
    }

    package func windowSums(_ ranges: [Range<Int>]) -> [[UInt64]] {
        try! windowSums(ranges, cancelled: { false }, progress: nil)
    }

    package func windowSums(_ ranges: [Range<Int>], cancelled: @Sendable () -> Bool,
                            progress: (@Sendable (Double) -> Void)?) throws -> [[UInt64]] {
        let n = ny * nx
        var out = [[UInt64]](repeating: [UInt64](repeating: 0, count: n), count: ranges.count)
        let los = ranges.map(\.lowerBound), his = ranges.map(\.upperBound)
        let maxHi = his.max() ?? 0
        for start in stride(from: 0, to: n, by: Self.blockPixels) {
            try FormatoCancellation.check(cancelled)
            let end = min(start + Self.blockPixels, n)
            for p in start..<end {
                for k in rowOffsets[p]..<rowOffsets[p + 1] {
                    let c = Int(channelIndex[k])
                    if c >= maxHi { break }
                    let v = UInt64(counts[k])
                    for r in 0..<ranges.count where c >= los[r] && c < his[r] { out[r][p] &+= v }
                }
            }
            progress?(Double(end) / Double(n))
        }
        if n == 0 { progress?(1) }
        return out
    }
}

/// Builds a `CSRSpectrumImage` pixel by pixel in row-major order.
package nonisolated struct CSRSpectrumImageBuilder {
    package let ny: Int
    package let nx: Int
    package let channels: Int
    private var rowOffsets: [Int]
    private var channelIndex: [UInt16] = []
    private var counts: [UInt32] = []

    package init(ny: Int, nx: Int, channels: Int) throws {
        guard ny >= 0, nx >= 0, channels > 0, channels <= Int(UInt16.max) + 1 else {
            throw SEMEDSReadError("A spectrum image of \(ny) x \(nx) pixels and \(channels) channels is not one macTEM holds.")
        }
        self.ny = ny; self.nx = nx; self.channels = channels
        rowOffsets = [0]
        rowOffsets.reserveCapacity(ny * nx + 1)
    }

    package var pixelsAppended: Int { rowOffsets.count - 1 }

    /// The next pixel's spectrum (`channels` counts).
    package mutating func append(spectrum: UnsafeBufferPointer<UInt32>) {
        for c in 0..<channels where spectrum[c] != 0 {
            channelIndex.append(UInt16(c)); counts.append(spectrum[c])
        }
        rowOffsets.append(counts.count)
    }

    /// The next pixel's nonzero entries, channels ascending.
    package mutating func append(channels cs: some Sequence<UInt16>, counts vs: some Sequence<UInt32>) {
        channelIndex.append(contentsOf: cs); counts.append(contentsOf: vs)
        rowOffsets.append(counts.count)
    }

    /// Empty pixels up to the end of the image, then the image.
    package mutating func finish() -> CSRSpectrumImage {
        while rowOffsets.count < ny * nx + 1 { rowOffsets.append(counts.count) }
        return CSRSpectrumImage(ny: ny, nx: nx, channels: channels, rowOffsets: rowOffsets, channelIndex: channelIndex, counts: counts)
    }
}

// MARK: - Little-endian reads

/// Little-endian reads from a byte array, bounds-checked (a short file is a refusal, never a crash).
package nonisolated struct SEMEDSBytes {
    package let bytes: [UInt8]
    package let name: String

    package init(_ bytes: [UInt8], name: String) { self.bytes = bytes; self.name = name }

    package func need(_ offset: Int, _ count: Int) throws {
        guard offset >= 0, count >= 0, offset + count <= bytes.count else {
            throw SEMEDSReadError("\(name) ends before its header says it does (byte \(offset + count) of \(bytes.count)).")
        }
    }

    package func u8(_ o: Int) throws -> UInt8 { try need(o, 1); return bytes[o] }
    package func i8(_ o: Int) throws -> Int8 { Int8(bitPattern: try u8(o)) }
    package func u16(_ o: Int) throws -> UInt16 { try need(o, 2); return UInt16(bytes[o]) | UInt16(bytes[o + 1]) << 8 }
    package func i16(_ o: Int) throws -> Int16 { Int16(bitPattern: try u16(o)) }
    package func u32(_ o: Int) throws -> UInt32 {
        try need(o, 4)
        return UInt32(bytes[o]) | UInt32(bytes[o + 1]) << 8 | UInt32(bytes[o + 2]) << 16 | UInt32(bytes[o + 3]) << 24
    }
    package func i32(_ o: Int) throws -> Int32 { Int32(bitPattern: try u32(o)) }
    package func u64(_ o: Int) throws -> UInt64 { UInt64(try u32(o)) | UInt64(try u32(o + 4)) << 32 }
    package func f32(_ o: Int) throws -> Float { Float(bitPattern: try u32(o)) }
    package func f64(_ o: Int) throws -> Double { Double(bitPattern: try u64(o)) }
    package func slice(_ o: Int, _ n: Int) throws -> ArraySlice<UInt8> { try need(o, n); return bytes[o..<(o + n)] }
}

package nonisolated enum SEMEDSText {
    /// A NUL-padded byte field as Python's `bytes.rstrip(b"\x00")` then UTF-8, Shift-JIS when it is not UTF-8 (rsciio's JEOL `_decode`).
    package static func decode(_ field: some Collection<UInt8>, stripLeading: Bool = false) -> String {
        var b = Array(field)
        while let last = b.last, last == 0 { b.removeLast() }
        if stripLeading { while let first = b.first, first == 0 { b.removeFirst() } }
        if let s = String(bytes: b, encoding: .utf8) { return s }
        if let s = String(bytes: b, encoding: .shiftJIS) { return s }
        return String(decoding: b, as: UTF8.self)
    }

    /// An OLE automation date (days since 1899-12-30, as JEOL writes it) as rsciio's `date` and `time` ISO strings; the time keeps its
    /// microseconds when it has any, as Python's `time.isoformat()` does.
    package static func oleDate(_ days: Double) -> (date: String, time: String) {
        // Python: datetime(1899, 12, 30) + timedelta(days=d), timedelta rounds to whole microseconds (round half even).
        let micros = (days * 86_400_000_000).rounded(.toNearestOrEven)
        var totalMicros = Int64(micros)
        var dayNumber = totalMicros / 86_400_000_000
        totalMicros -= dayNumber * 86_400_000_000
        if totalMicros < 0 { totalMicros += 86_400_000_000; dayNumber -= 1 }
        // 1899-12-30 is Julian day number 2415019.
        let (y, m, d) = civil(fromJulianDay: 2_415_019 + Int(dayNumber))
        let second = totalMicros / 1_000_000, us = totalMicros % 1_000_000
        let date = String(format: "%04d-%02d-%02d", y, m, d)
        var time = String(format: "%02d:%02d:%02d", Int(second / 3600), Int(second / 60 % 60), Int(second % 60))
        if us != 0 { time += String(format: ".%06d", Int(us)) }
        return (date, time)
    }

    /// Gregorian (year, month, day) of a Julian day number (Fliegel and Van Flandern, 1968).
    static func civil(fromJulianDay jd: Int) -> (Int, Int, Int) {
        var l = jd + 68569
        let n = 4 * l / 146097
        l -= (146097 * n + 3) / 4
        let i = 4000 * (l + 1) / 1461001
        l = l - 1461 * i / 4 + 31
        let j = 80 * l / 2447
        let d = l - 2447 * j / 80
        l = j / 11
        let m = j + 2 - 12 * l
        let y = 100 * (n - 49) + i + l
        return (y, m, d)
    }

    /// Bruker's "d.m.yyyy" and "h:m:s" as ISO date and time (rsciio: `strptime("%d.%m.%Y %H:%M:%S")`, then `isoformat()`).
    package static func brukerDateTime(date: String, time: String) -> (date: String, time: String)? {
        let d = date.trimmingCharacters(in: .whitespaces).split(separator: ".").compactMap { Int($0) }
        let t = time.trimmingCharacters(in: .whitespaces).split(separator: ":").compactMap { Int($0) }
        guard d.count == 3, t.count == 3 else { return nil }
        return (String(format: "%04d-%02d-%02d", d[2], d[1], d[0]), String(format: "%02d:%02d:%02d", t[0], t[1], t[2]))
    }
}
