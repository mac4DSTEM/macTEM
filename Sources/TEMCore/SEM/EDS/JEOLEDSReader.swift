//
//  JEOLEDSReader.swift
//  Role: JEOL Analysis Station files read as RosettaSciIO 0.15.0 reads them (`rsciio/jeol/_api.py`, GPL-3.0-or-later):
//        the tagged header tree every JEOL file carries (`_parsejeol`: marks, keywords, typed values, the PARAMPAGE renaming, the
//        CountRate/DeadTime/index wrappers, the "Limits" skip, the Shift-JIS fallback); `.pts` — the spectrum image as an event stream
//        of 16-bit words (0x8000 x, 0x9000 y, 0xA000 S(T)EM image value, 0xB000 X-ray channel), frame by frame (a frame ends where y
//        steps back), every complete frame summed and an incomplete last frame dropped (`_readcube` with `sum_frames=True`,
//        `only_valid_data=True`), plus the S(T)EM image of the stream when it holds one; `.eds` — one spectrum with its footer
//        (excluded and selected elements, quantification, detector parameters); `.img`/`.map` — an image or element map;
//        `.asw` — the project file, which names the views' files and reads each in turn.
//        The app reads a `.pts` with `SI_dtype=np.uint32` and `read_em_image=True` (decision D-SEM in docs/decisions.md): every count
//        kept, where rsciio's uint8 default refuses a channel's 255th X-ray. The counts accumulate as sorted (pixel, channel) keys
//        merged frame by frame, so memory follows the X-rays recorded, not the 512 x 512 x 4096 cube.
//

import Foundation

package nonisolated enum JEOLEDSReader {
    package static let readableExtensions = ["pts", "eds", "img", "map", "asw"]
    /// The extensions whose files hold a spectrum or spectrum image (the others hold images).
    package static let spectralExtensions = ["pts", "eds", "asw"]

    package static func read(url: URL) throws -> SEMEDSFile {
        let signals = try signals(url: url)
        return SEMEDSFile(url: url, signals: signals)
    }

    static func signals(url: URL) throws -> [SEMEDSSignal] {
        switch url.pathExtension.lowercased() {
        case "pts": return try readPTS(url: url)
        case "eds": return try [readEDS(url: url)]
        case "img", "map": return try [readIMG(url: url)]
        case "asw": return try readASW(url: url)
        default: return []
        }
    }

    static func load(_ url: URL) throws -> SEMEDSBytes {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw SEMEDSReadError("\(url.lastPathComponent) is missing (\(url.path)): the JEOL project names it but it is not beside the project file.")
        }
        do { return SEMEDSBytes([UInt8](try Data(contentsOf: url)), name: url.lastPathComponent) } catch {
            throw SEMEDSReadError("\(url.lastPathComponent) could not be read.")
        }
    }

    // MARK: - The header tree (`_parsejeol`)

    package final class Node {
        package var keys: [String] = []
        package var children: [String: Node] = [:]
        /// A leaf's value: strings ("c" types) or numbers (exact doubles of the stored type).
        package var strings: [String]?
        package var numbers: [Double]?
        package var typeCode: Character?

        package subscript(_ key: String) -> Node? { children[key] }

        func child(_ key: String) -> Node {
            if let c = children[key] { return c }
            let c = Node(); children[key] = c; keys.append(key); return c
        }

        func set(_ key: String, _ node: Node) {
            if children[key] == nil { keys.append(key) }
            children[key] = node
        }

        package var number: Double? { numbers?.first }
        package var string: String? { strings?.first }
    }

    static let types: [Int: (code: Character, size: Int)] = [
        1: ("B", 1), 2: ("H", 2), 3: ("i", 4), 4: ("f", 4), 5: ("d", 8), 6: ("B", 1), 7: ("H", 2), 8: ("i", 4), 9: ("f", 4),
        10: ("d", 8), 11: ("?", 1), 12: ("c", 1), 13: ("c", 1), 14: ("H", 2), 20: ("c", 1), 65553: ("?", 1), 65552: ("?", 1),
    ]

    static func decode(_ bytes: some Collection<UInt8>) -> String {
        let b = Array(bytes)
        if let s = String(bytes: b, encoding: .utf8) { return s }
        if let s = String(bytes: b, encoding: .shiftJIS) { return s }
        return String(decoding: b, as: UTF8.self)
    }

    /// The tree from byte `start` of `b`; `end` is where the parse stopped.
    static func parseTree(_ b: SEMEDSBytes, at start: Int) throws -> (root: Node, end: Int) {
        let root = Node()
        var path: [String] = []
        var current = root
        var o = start
        var mark: Int8 = 1
        while abs(Int(mark)) == 1 {
            mark = try b.i8(o); o += 1
            if mark == 1 {
                let length = Int(try b.i32(o)); o += 4
                var raw = Array(try b.slice(o, max(length, 0))); o += max(length, 0)
                while let last = raw.last, last == 0 { raw.removeLast() }
                var key: String
                if raw == [0xCE, 0xDF, 0xB0, 0xC4] { key = "Port" }
                else if raw.last == 222 { key = decode(raw.dropLast()) }
                else { key = decode(raw) }
                let valueType = Int(try b.i32(o)), valueLength = Int(try b.i32(o + 4)); o += 8
                path.append(key)
                if valueType == 0 {
                    current.set(key, Node())
                } else {
                    guard let t = types[valueType] else {
                        throw SEMEDSReadError("\(b.name) has a header value of unknown type \(valueType) (\(key)).")
                    }
                    let leaf = Node()
                    leaf.typeCode = t.code
                    if t.code == "c" {
                        var bytes = Array(try b.slice(o, max(valueLength, 0)))
                        while let last = bytes.last, last == 0 { bytes.removeLast() }
                        leaf.strings = decode(bytes).components(separatedBy: "\u{0}")
                        o += max(valueLength, 0)
                    } else {
                        let n = valueLength / t.size
                        var values: [Double] = []
                        values.reserveCapacity(max(n, 0))
                        for k in 0..<max(n, 0) {
                            let p = o + k * t.size
                            switch t.code {
                            case "B": values.append(Double(try b.u8(p)))
                            case "?": values.append(try b.u8(p) != 0 ? 1 : 0)
                            case "H": values.append(Double(try b.u16(p)))
                            case "i": values.append(Double(try b.i32(p)))
                            case "f": values.append(Double(try b.f32(p)))
                            default: values.append(try b.f64(p))
                            }
                        }
                        leaf.numbers = values
                        // numpy's fromfile reads arr_len items; the stream moves by what it read.
                        o += max(n, 0) * t.size
                    }
                    let isPage = key.count >= 5 && String(Array(key)[(key.count - 5)..<(key.count - 1)]) == "PAGE"
                    if isPage, let s = leaf.string {
                        key = key + "_" + s
                        current.set(key, Node())
                        path[path.count - 1] = key
                    } else if key == "CountRate" || key == "DeadTime" {
                        let wrapper = Node(); wrapper.set("value", leaf); current.set(key, wrapper)
                    } else if key == "Limits" {
                        // rsciio keeps no value for Limits.
                    } else if valueType == 14 {
                        let wrapper = Node(); wrapper.set("index", leaf); current.set(key, wrapper)
                    } else {
                        current.set(key, leaf)
                    }
                }
                if key != "Limits", let next = current[key] { current = next }
            } else {
                if !path.isEmpty {
                    path.removeLast()
                    current = root
                    for k in path { if let next = current[k] { current = next } }
                } else {
                    mark = 0
                }
            }
        }
        return (root, o)
    }

    static func node(_ root: Node, _ keys: String..., file: String) throws -> Node {
        var n = root
        for k in keys {
            guard let next = n[k] else { throw SEMEDSReadError("\(file)'s header has no \(keys.joined(separator: " / ")).") }
            n = next
        }
        return n
    }

    static func number(_ root: Node, _ keys: String..., file: String) throws -> Double {
        var n = root
        for k in keys {
            guard let next = n[k] else { throw SEMEDSReadError("\(file)'s header has no \(keys.joined(separator: " / ")).") }
            n = next
        }
        guard let v = n.number else { throw SEMEDSReadError("\(file)'s \(keys.joined(separator: " / ")) is not a number.") }
        return v
    }

    static func string(_ root: Node, _ keys: String..., file: String) throws -> String {
        var n = root
        for k in keys {
            guard let next = n[k] else { throw SEMEDSReadError("\(file)'s header has no \(keys.joined(separator: " / ")).") }
            n = next
        }
        if let s = n.string { return s }
        if let v = n.number { return v == v.rounded() ? String(Int(v)) : String(v) }
        throw SEMEDSReadError("\(file)'s \(keys.joined(separator: " / ")) holds no value.")
    }

    static func mode(_ hv: Double) -> String { hv <= 30 ? "SEM" : "TEM" }

    // MARK: - .img / .map

    static func readIMG(url: URL) throws -> SEMEDSSignal {
        let name = url.lastPathComponent
        let b = try load(url)
        guard b.bytes.count >= 48, try b.u32(0) == 52 else {
            throw SEMEDSReadError("\(name) is not a JEOL image (its first word is not 52), as RosettaSciIO finds too.")
        }
        let dataPos = Int(try b.u32(44))
        let tree = try parseTree(b, at: dataPos + 12).root
        let size = try node(tree, "Image", "Size", file: name).numbers ?? []
        guard size.count == 2, size[0] > 0, size[1] > 0 else { throw SEMEDSReadError("\(name) states no image size.") }
        let width = Int(size[0]), height = Int(size[1])
        let bitsNode = try node(tree, "Image", "Bits", file: name)
        guard let bits = bitsNode.numbers, let code = bitsNode.typeCode, code == "B" || code == "H" else {
            throw SEMEDSReadError("\(name) stores its image in a type macTEM does not read.")
        }
        // numpy's resize: truncated or padded with zeros to height x width.
        var pixels = [UInt32](repeating: 0, count: width * height)
        for i in 0..<min(bits.count, pixels.count) { pixels[i] = UInt32(bits[i]) }
        let scanSize = try number(tree, "Instrument", "ScanSize", file: name)
        let mag = try number(tree, "Instrument", "Mag", file: name)
        let scale = scanSize / mag * 1.0e3
        let created = try number(tree, "Image", "Created", file: name)
        let hv = try number(tree, "Instrument", "AccV", file: name)
        var md = SEMEDSMetadata()
        md.mode = mode(hv)
        md.beamEnergy = hv
        md.magnification = mag
        md.originalFilename = name
        let when = SEMEDSText.oleDate(created)
        md.date = when.date; md.time = when.time
        md.title = try string(tree, "Image", "Title", file: name)
        let axes = [SEMEDSAxis(name: "y", size: height, scale: scale / Double(height), offset: 0, units: "µm"),
                    SEMEDSAxis(name: "x", size: width, scale: scale / Double(width), offset: 0, units: "µm")]
        return .image(SEMEDSImage(axes: axes, dtype: code == "B" ? "uint8" : "uint16", width: width, height: height, pixels: pixels,
                                  metadata: md))
    }

    // MARK: - .eds

    struct Cursor {
        let b: SEMEDSBytes
        var o = 0
        mutating func i8() throws -> Int { defer { o += 1 }; return Int(try b.i8(o)) }
        mutating func i32() throws -> Int { defer { o += 4 }; return Int(try b.i32(o)) }
        mutating func u16() throws -> Int { defer { o += 2 }; return Int(try b.u16(o)) }
        mutating func f64() throws -> Double { defer { o += 8 }; return try b.f64(o) }
        mutating func text(_ n: Int) throws -> String {
            defer { o += max(n, 0) }
            var raw = Array(try b.slice(o, max(n, 0)))
            while let last = raw.last, last == 0 { raw.removeLast() }
            return JEOLEDSReader.decode(raw)
        }
        mutating func skip(_ n: Int) throws { try b.need(o, n); o += n }
    }

    static func readEDS(url: URL) throws -> SEMEDSSignal {
        let name = url.lastPathComponent
        var c = Cursor(b: try load(url))
        _ = try c.i32()
        try c.skip(6)
        let fileDate = try c.f64()
        _ = try c.text(80); _ = try c.text(32)
        _ = try c.i32(); try c.skip(80); _ = try c.i32(); try c.skip(8)
        try c.skip(8 * 4)                       // Esc, Fnano F, E Noise, CH Res
        let liveTime = try c.f64()
        try c.skip(8 * 3)                       // real time, DeadTime, CountRate
        _ = try c.i32(); try c.skip(16 + 8 + 8)  // CountRate n, sum, value, (double)
        _ = try c.i32(); try c.skip(16 + 8 + 8)  // DeadTime n, sum, value, (double)
        let coefA = try c.f64(), coefB = try c.f64()
        _ = try c.text(32); _ = try c.i32(); try c.skip(8)
        _ = try c.text(32)
        let channels = try c.i32()
        guard channels > 0, channels < 1 << 20 else { throw SEMEDSReadError("\(name) states \(channels) channels.") }
        var counts: [Int64] = []
        counts.reserveCapacity(channels)
        for _ in 0..<channels { counts.append(Int64(try c.i32())) }
        // The footer: excluded elements, selected elements with their lines, quantification, then the detector parameters.
        _ = try c.i32()
        let excluded = try c.i32()
        if excluded != 0 { try c.skip(2 * excluded) }
        let selected = try c.i32()
        for _ in 0..<max(selected, 0) {
            _ = try c.i32(); _ = try c.u16(); try c.skip(8); try c.skip(4); try c.skip(14); try c.skip(32)
            _ = try c.text(32); _ = try c.i32()
            let lines = try c.i32()
            for _ in 0..<max(lines, 0) {
                _ = try c.i32(); try c.skip(8); _ = try c.u16()
                let e = try c.i8(); _ = try c.text(e)
                let l = try c.i8(); _ = try c.text(l)
                _ = try c.i32()
            }
        }
        let quanti = try c.i32()
        if quanti != 0 {
            try c.skip(4 * 3 + 8 + 4 * 2)
            for _ in 0..<max(quanti, 0) {
                try c.skip(4 + 2 + 8 + 16 + 8 + 8 + 8 + 16 + 8 * 5 + 4 * 2 + 8)
            }
        }
        guard try c.i32() == 5 else { throw SEMEDSReadError("\(name) has no detector parameters in its footer.") }
        let detector = try c.text(16)
        _ = try c.text(16); _ = try c.text(16)
        let accKV = try c.f64()
        try c.skip(8 + 38)
        let mnKa = try c.f64()
        try c.skip(8 * 5 + 4 + 8 + 2 * 5 + 8)  // WorkD InsD XtiltAng TakeAng IncAng, skip2, ScanSize, DT_64..DT_1K, DetH
        let dirAng = try c.f64()
        try c.skip(8)
        let elevAng = try c.f64()

        var md = SEMEDSMetadata()
        md.mode = mode(accKV)
        md.beamEnergy = accKV
        md.azimuthAngle = dirAng
        md.detectorType = detector
        md.elevationAngle = elevAng
        md.energyResolutionMnKa = mnKa
        md.liveTime = liveTime
        md.originalFilename = name
        let when = SEMEDSText.oleDate(fileDate)
        md.date = when.date; md.time = when.time
        md.title = "EDX"
        md.signalType = "EDS_" + mode(accKV)
        return .spectrum(SEMEDSSpectrum(axis: SEMEDSAxis(name: "Energy", size: channels, scale: coefA, offset: coefB, units: "keV"),
                                        dtype: "int32", counts: counts, metadata: md))
    }

    // MARK: - .pts

    static func readPTS(url: URL) throws -> [SEMEDSSignal] {
        let name = url.lastPathComponent
        let b = try load(url)
        guard b.bytes.count >= 304, try b.u32(0) == 304 else {
            throw SEMEDSReadError("\(name) is not a JEOL spectrum image (its first word is not 304), as RosettaSciIO finds too.")
        }
        let headPos = Int(try b.u32(20)), dataPos = Int(try b.u32(28))
        let fileDate = try b.f64(296)
        let header = try parseTree(b, at: headPos + 12).root
        let meas = try node(header, "PTTD Data", "AnalyzableMap MeasData", file: name)
        let pixelsText = try string(meas, "Meas Cond", "Pixels", file: name)
        let wh = pixelsText.split(separator: "x").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard wh.count == 2, wh[0] > 0, wh[1] > 0 else { throw SEMEDSReadError("\(name) states the map size \"\(pixelsText)\".") }
        let width = wh[0], height = wh[1]
        let widthNorm = Int(4096.0 / Double(width)), heightNorm = Int(4096.0 / Double(height))
        guard widthNorm > 0, heightNorm > 0 else { throw SEMEDSReadError("\(name) states a map wider than the 4096 scan steps.") }
        let channels = 4096
        let mag = try number(meas, "MeasCond", "Mag", file: name)
        let scanSize = try number(header, "PTTD Param", "Params", "PARAMPAGE0_SEM", "ScanSize", file: name)
        let scale = scanSize / mag * 1.0e3
        let template = try string(meas, "Meas Cond", "Tpl", file: name)
        let coefA = try number(meas, "Doc", "CoefA", file: name), coefB = try number(meas, "Doc", "CoefB", file: name)
        let digZ = try number(header, "PTTD Param", "Params", "PARAMPAGE1_EDXRF", "Tpl", template, "DigZ", file: name)
        let energyOffset = coefB - coefA * digZ
        let sweep = Int(try number(meas, "Doc", "Sweep", file: name))

        // The event stream, frame by frame.
        let words = (b.bytes.count - min(dataPos, b.bytes.count)) / 2
        let raw: [UInt16] = (0..<words).map { k in UInt16(b.bytes[dataPos + 2 * k]) | UInt16(b.bytes[dataPos + 2 * k + 1]) << 8 }
        var accumulated: [(key: Int, count: UInt32)] = []
        var em = [UInt32](repeating: 0, count: width * height)
        var hasEM = false
        var start = 0
        for _ in 0...max(sweep, 0) {
            let frame = readFrame(raw, from: start, width: width, height: height, widthNorm: widthNorm, heightNorm: heightNorm,
                                  channels: channels)
            hasEM = hasEM || frame.hasEM
            if frame.length == 0 { break }
            guard frame.valid else { break }
            accumulated = merge(accumulated, frame.keys.sorted())
            for (p, v) in frame.em { em[p] &+= v }
            start += frame.length
        }
        var builder = try CSRSpectrumImageBuilder(ny: height, nx: width, channels: channels)
        var k = 0
        for p in 0..<(width * height) {
            var cs: [UInt16] = [], vs: [UInt32] = []
            while k < accumulated.count, accumulated[k].key / channels == p {
                cs.append(UInt16(accumulated[k].key % channels)); vs.append(accumulated[k].count); k += 1
            }
            builder.append(channels: cs, counts: vs)
        }
        let cube = builder.finish()

        let hv = try number(meas, "MeasCond", "AccKV", file: name)
        let m = mode(hv)
        let when = SEMEDSText.oleDate(fileDate)
        var md = SEMEDSMetadata()
        md.mode = m
        md.beamEnergy = hv
        md.magnification = mag
        md.azimuthAngle = try number(header, "PTTD Param", "Params", "PARAMPAGE0_SEM", "DirAng", file: name)
        md.detectorType = try string(header, "PTTD Param", "Params", "PARAMPAGE0_SEM", "DetT", file: name)
        md.elevationAngle = try number(header, "PTTD Param", "Params", "PARAMPAGE0_SEM", "ElevAng", file: name)
        md.energyResolutionMnKa = try number(header, "PTTD Param", "Params", "PARAMPAGE0_SEM", "MnKaRES", file: name)
        md.realTime = try number(meas, "Doc", "RealTime", file: name)
        md.originalFilename = name
        md.date = when.date; md.time = when.time
        md.title = "EDS extracted from " + name
        md.signalType = "EDS_" + m
        let spatial = [SEMEDSAxis(name: "y", size: height, scale: scale / Double(height), offset: 0, units: "µm"),
                       SEMEDSAxis(name: "x", size: width, scale: scale / Double(width), offset: 0, units: "µm")]
        var signals: [SEMEDSSignal] = [.spectrumImage(SEMEDSSpectrumImage(
            shape: [height, width, channels],
            axes: spatial + [SEMEDSAxis(name: "Energy", size: channels, scale: coefA, offset: energyOffset, units: "keV")],
            dtype: "uint32", cube: cube, metadata: md))]
        if hasEM {
            // uint16 for fewer than 16 sweeps (values wrap as numpy's do), uint32 from 16.
            let wide = sweep >= 16
            var emMD = SEMEDSMetadata()
            emMD.mode = m; emMD.beamEnergy = hv; emMD.magnification = mag; emMD.originalFilename = name
            emMD.date = when.date; emMD.time = when.time
            emMD.title = "S(T)EM Image extracted from " + name
            signals.append(.image(SEMEDSImage(axes: spatial, dtype: wide ? "uint32" : "uint16", width: width, height: height,
                                              pixels: wide ? em : em.map { $0 & 0xFFFF }, metadata: emMD)))
        }
        return signals
    }

    struct Frame {
        var length: Int
        var keys: [Int]
        var em: [(Int, UInt32)]
        var hasEM: Bool
        var valid: Bool
    }

    /// One frame (`_readframe_dense` with no shift and no energy binning): the events up to where y steps back.
    static func readFrame(_ raw: [UInt16], from start: Int, width: Int, height: Int, widthNorm: Int, heightNorm: Int,
                          channels: Int) -> Frame {
        var x = 0, y = 0, previousX = 0, previousY = -1, count = 0
        var hasEM = false
        var keys: [Int] = [], em: [(Int, UInt32)] = []
        var i = start
        while i < raw.count {
            let value = Int(raw[i])
            let type = value & 0xF000, v = value & 0x0FFF
            if type == 0x8000 {
                x = v / widthNorm
                if x >= width { x = -1 }
                previousX = v
            } else if type == 0x9000 {
                y = v / heightNorm
                if v < previousY { break }
                previousY = v
                if y >= height { y = -1 }
            } else if type == 0xA000, x >= 0, y >= 0 {
                em.append((y * width + x, UInt32(v)))
                hasEM = true
            } else if type == 0xB000 {
                let z = v
                if z < channels, x >= 0, y >= 0 { keys.append((y * width + x) * channels + z) }
            }
            count += 1
            i += 1
        }
        let valid = previousY >= 4096 - heightNorm && (previousX >= 4096 - widthNorm || !hasEM)
        return Frame(length: count, keys: keys, em: em, hasEM: hasEM, valid: valid)
    }

    /// Sorted (key, count) runs merged with a sorted list of keys.
    static func merge(_ a: [(key: Int, count: UInt32)], _ sortedKeys: [Int]) -> [(key: Int, count: UInt32)] {
        var runs: [(key: Int, count: UInt32)] = []
        for k in sortedKeys {
            if let last = runs.last, last.key == k { runs[runs.count - 1].count += 1 } else { runs.append((k, 1)) }
        }
        var out: [(key: Int, count: UInt32)] = []
        out.reserveCapacity(a.count + runs.count)
        var i = 0, j = 0
        while i < a.count || j < runs.count {
            if j == runs.count || (i < a.count && a[i].key < runs[j].key) { out.append(a[i]); i += 1 }
            else if i == a.count || runs[j].key < a[i].key { out.append(runs[j]); j += 1 }
            else { out.append((a[i].key, a[i].count &+ runs[j].count)); i += 1; j += 1 }
        }
        return out
    }

    // MARK: - .asw

    static func readASW(url: URL) throws -> [SEMEDSSignal] {
        let name = url.lastPathComponent
        let b = try load(url)
        guard b.bytes.count >= 12, try b.u32(0) == 0 else {
            throw SEMEDSReadError("\(name) is not a JEOL project file (its first word is not 0), as RosettaSciIO finds too.")
        }
        let tree = try parseTree(b, at: 12).root
        guard let samples = tree["SampleInfo"] else { return [] }
        let folder = url.deletingLastPathComponent()
        var out: [SEMEDSSignal] = []
        for i in samples.keys {
            guard let views = samples[i]?["ViewInfo"] else { continue }
            for j in views.keys {
                guard let data = views[j]?["ViewData"] else { continue }
                for k in data.keys {
                    guard let file = data[k]?["Filename"]?.string else { continue }
                    let parts = file.split(separator: "\\").map(String.init).filter { !$0.isEmpty }
                    let sub = parts.reduce(folder) { $0.appendingPathComponent($1) }
                    guard readableExtensions.contains(sub.pathExtension.lowercased()) else { continue }
                    out += try signals(url: sub)
                }
            }
        }
        return out
    }
}
