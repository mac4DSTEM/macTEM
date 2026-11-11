//
//  BrukerEDSReader.swift
//  Role: Bruker Esprit files read as RosettaSciIO 0.15.0 reads them with its defaults (`rsciio/bruker/_api.py` and the cython
//        unpacker `unbcf_fast.pyx`, GPL-3.0-or-later):
//        `.bcf` — the SFS container (`BrukerSFS`), the XML header `EDSDatabase/HeaderData` (decimal commas sanitised as
//        `sanitize_msxml_float` does; SEM data HV, Mag, DX/DY; the DSP configuration; the image node's planes as base64 arrays, empty
//        planes skipped, plus the overview images of a version 2 file; the element regions; the line counter), the sum spectrum of
//        each `SpectrumData<i>` (calibration CalibAbs/CalibLin, beam energy and detector angles from the ESMA or XRF header, real and
//        live time) and the hypermap of the first index, unpacked pixel by pixel from its three packings (16-bit pulse lists,
//        12-bit pulse lists, "instructively packed" channel runs with nibble, byte, word and long gains plus extra pulses);
//        `.spx` — one spectrum in the same XML.
//        Metadata as rsciio maps it: the instrument mode guessed from HV (above 30 kV is TEM), beam energy, magnification, detector
//        type and angles, real time from the line counter (`calc_real_time`), elements and X-ray lines from the regions, date and
//        time in ISO form. The x axis of the spectrum image takes DY as rsciio's does; the image axes take DX and DY.
//        Counts are summed as UInt32 (decision D-SEM in docs/decisions.md): rsciio sizes its array by `estimate_map_depth` and
//        names that dtype, which `dtype` reports; no test file reaches the narrower type's limit, so the counts agree exactly.
//

import Foundation

package nonisolated enum BrukerEDSReader {
    package static let readableExtensions = ["bcf", "spx"]

    package static func read(url: URL) throws -> SEMEDSFile {
        switch url.pathExtension.lowercased() {
        case "bcf": return try readBCF(url: url)
        case "spx": return try readSPX(url: url)
        default: throw SEMEDSReadError("\(url.lastPathComponent) is not a Bruker .bcf or .spx file.")
        }
    }

    // MARK: - XML helpers

    /// The direct children of `el` named `name`, optionally with `@Type` (and `@Name`) equal to the given values.
    static func children(_ el: XMLElement, _ name: String, type: String? = nil, named: String? = nil) -> [XMLElement] {
        (el.children ?? []).compactMap { $0 as? XMLElement }.filter {
            $0.name == name && (type == nil || $0.attribute(forName: "Type")?.stringValue == type)
                && (named == nil || $0.attribute(forName: "Name")?.stringValue == named)
        }
    }

    static func child(_ el: XMLElement?, _ name: String, type: String? = nil) -> XMLElement? {
        guard let el else { return nil }
        return children(el, name, type: type).first
    }

    /// ElementTree's `find` along a path of steps: the first element, in document order, that ends the path.
    static func find(_ el: XMLElement, _ steps: [(name: String, type: String?, named: String?)]) -> XMLElement? {
        guard let first = steps.first else { return el }
        for c in children(el, first.name, type: first.type, named: first.named) {
            if let hit = find(c, Array(steps.dropFirst())) { return hit }
        }
        return nil
    }

    static func findAll(_ el: XMLElement, _ steps: [(name: String, type: String?, named: String?)]) -> [XMLElement] {
        guard let first = steps.first else { return [el] }
        return children(el, first.name, type: first.type, named: first.named).flatMap { findAll($0, Array(steps.dropFirst())) }
    }

    static func text(_ el: XMLElement?) -> String? { el?.stringValue }

    /// The leaf fields of a node as rsciio's `XmlToDict(tags_to_flatten="ClassInstance")` places them: a leaf child's text under its
    /// tag, the children of a `ClassInstance` child one level up. The first value of a repeated tag is kept.
    static func fields(_ el: XMLElement?) -> [String: String] {
        guard let el else { return [:] }
        var out: [String: String] = [:]
        for case let c as XMLElement in el.children ?? [] {
            guard let name = c.name else { continue }
            if name == "ClassInstance" {
                for (k, v) in fields(c) where out[k] == nil { out[k] = v }
            } else if (c.children ?? []).allSatisfy({ !($0 is XMLElement) }), out[name] == nil {
                out[name] = (c.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return out
    }

    /// A number as `literal_eval` gives it (an int or a float literal), nil for anything else.
    static func number(_ s: String?) -> Double? {
        guard let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        if let i = Int(s) { return Double(i) }
        if s.contains(where: { $0.isLetter && $0 != "e" && $0 != "E" }) { return nil }
        return Double(s)
    }

    /// A header number as a whole count, truncated as Int(_:) truncates it; nil when it is no number, or infinite or past Int
    /// (a damaged header's "1e400"), so a size is refused rather than trapped on.
    package static func whole(_ s: String?) -> Int? {
        guard let v = number(s) else { return nil }
        return Int(exactly: v.rounded(.towardZero))
    }

    /// rsciio's `sanitize_msxml_float`: `>-?\d+,(\d*([Ee]-?\d*)?<` gets a decimal point for its comma.
    static func sanitized(_ xml: [UInt8]) -> Data {
        guard let s = String(bytes: xml, encoding: .isoLatin1),
              let re = try? NSRegularExpression(pattern: ">(-?\\d+),(\\d*([Ee]-?\\d*)?<)") else { return Data(xml) }
        let fixed = re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: ">$1.$2")
        return fixed.data(using: .isoLatin1) ?? Data(xml)
    }

    static func document(_ xml: [UInt8], name: String) throws -> XMLElement {
        do {
            let doc = try XMLDocument(data: sanitized(xml), options: [])
            guard let root = doc.rootElement() else { throw SEMEDSReadError("\(name) holds no XML header.") }
            return root
        } catch let e as SEMEDSReadError { throw e } catch {
            throw SEMEDSReadError("\(name)'s XML header could not be parsed (\(error.localizedDescription)).")
        }
    }

    // MARK: - The EDS spectrum (rsciio `EDXSpectrum`)

    struct Spectrum {
        var hardware: [String: String]
        var detector: [String: String]
        var esma: [String: String]
        var spectrumHeader: [String: String]
        var hv: Double?
        var elevation: Double?
        var date: (date: String, time: String)?
        var offset: Double
        var scale: Double
        var channels: [UInt64]

        init(_ node: XMLElement, name: String) throws {
            let trt = BrukerEDSReader.child(node, "TRTHeaderedClass")
            hardware = BrukerEDSReader.fields(BrukerEDSReader.child(trt, "ClassInstance", type: "TRTSpectrumHardwareHeader"))
            detector = BrukerEDSReader.fields(BrukerEDSReader.child(trt, "ClassInstance", type: "TRTDetectorHeader"))
            guard hardware["Amplification"] != nil, detector["Type"] != nil else {
                throw SEMEDSReadError("\(name) holds an EDS spectrum without its hardware or detector header.")
            }
            var esma = BrukerEDSReader.fields(BrukerEDSReader.child(trt, "ClassInstance", type: "TRTESMAHeader"))
            if let xrf = BrukerEDSReader.child(trt, "ClassInstance", type: "TRTXrfHeader") {
                let x = BrukerEDSReader.fields(xrf)
                esma = [:]
                if let v = x["Voltage"] { esma["PrimaryEnergy"] = v }
                if let a = x["ExcitationAngle"] { esma["ElevationAngle"] = a }
            }
            self.esma = esma
            hv = BrukerEDSReader.number(esma["PrimaryEnergy"])
            guard let elevation = BrukerEDSReader.number(esma["ElevationAngle"]) else {
                throw SEMEDSReadError("\(name) holds an EDS spectrum without the detector's elevation angle.")
            }
            self.elevation = elevation
            let header = BrukerEDSReader.child(node, "ClassInstance", type: "TRTSpectrumHeader")
            if let header, let d = BrukerEDSReader.text(BrukerEDSReader.child(header, "Date")), let t = BrukerEDSReader.text(BrukerEDSReader.child(header, "Time")) {
                date = SEMEDSText.brukerDateTime(date: d, time: t)
            }
            spectrumHeader = BrukerEDSReader.fields(header)
            guard let offset = BrukerEDSReader.number(spectrumHeader["CalibAbs"]), let scale = BrukerEDSReader.number(spectrumHeader["CalibLin"]) else {
                throw SEMEDSReadError("\(name) holds an EDS spectrum without its energy calibration.")
            }
            self.offset = offset; self.scale = scale
            let list = BrukerEDSReader.text(BrukerEDSReader.child(node, "Channels")) ?? ""
            channels = list.split(separator: ",").compactMap { UInt64($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }

        /// rsciio `gen_detector_node`.
        func detectorFields(into md: inout SEMEDSMetadata) {
            md.elevationAngle = elevation
            md.detectorType = detector["Type"]
            if let az = BrukerEDSReader.number(esma["AzimutAngle"]) { md.azimuthAngle = az }
            if let rt = BrukerEDSReader.number(hardware["RealTime"]) {
                md.realTime = rt / 1000
                md.liveTime = BrukerEDSReader.number(hardware["LifeTime"]).map { $0 / 1000 }
            }
        }
    }

    static func guessMode(_ hv: Double?) -> String { (hv ?? 0) > 30 ? "TEM" : "SEM" }

    // MARK: - .bcf

    struct Header {
        var name: String
        var date: (date: String, time: String)?
        var version: Int
        var sem: [String: String]
        var dsp: [String: String]
        var hv: Double?
        var units: String
        var xRes: Double
        var yRes: Double
        var mode: String
        var imageNode: XMLElement
        var imageWidth: Int
        var imageHeight: Int
        var overviewNode: XMLElement?
        var elements: [(name: String, line: String)]
        var lineCounter: [Double]
        var spectra: [Int: Spectrum]
    }

    static func header(_ root: XMLElement, indexes: [Int], name: String) throws -> Header {
        guard let db = child(root, "ClassInstance", type: "TRTSpectrumDatabase") else {
            throw SEMEDSReadError("\(name) holds no spectrum database in its header.")
        }
        let dbName = db.attribute(forName: "Name")?.stringValue ?? "Undefined"
        let hd = child(db, "Header")
        var date: (String, String)?
        if let d = text(child(hd, "Date")), let t = text(child(hd, "Time")) { date = SEMEDSText.brukerDateTime(date: d, time: t) }
        let version = whole(text(child(hd, "FileVersion"))) ?? 1
        let sem = fields(child(db, "ClassInstance", type: "TRTSEMData"))
        let hv = number(sem["HV"])
        let units = sem["DX"] != nil ? "µm" : "pix"
        let xRes = number(sem["DX"]) ?? 1.0, yRes = number(sem["DY"]) ?? 1.0
        let dsp = fields(child(db, "ClassInstance", type: "TRTDSPConfiguration"))
        // The image node is the last TRTImageData without a Name.
        guard let imageNode = children(db, "ClassInstance", type: "TRTImageData").last(where: {
            ($0.attribute(forName: "Name")?.stringValue ?? "").isEmpty
        }) else { throw SEMEDSReadError("\(name) holds no image node in its header.") }
        guard let width = whole(text(child(imageNode, "Width"))), let height = whole(text(child(imageNode, "Height"))),
              width > 0, height > 0 else {
            throw SEMEDSReadError("\(name) states no map size.")
        }
        var overview: XMLElement?
        if version == 2 {
            overview = findAll(db, [("ClassInstance", "TRTContainerClass", nil), ("ChildClassInstances", nil, nil),
                                    ("ClassInstance", nil, "OverviewImages"), ("ChildClassInstances", nil, nil),
                                    ("ClassInstance", "TRTImageData", nil)]).first
        }
        var elements: [(String, String)] = []
        if let regions = find(db, [("ClassInstance", "TRTContainerClass", nil), ("ChildClassInstances", nil, nil),
                                   ("ClassInstance", "TRTElementInformationList", nil), ("ClassInstance", "TRTSpectrumRegionList", nil),
                                   ("ChildClassInstances", nil, nil)]) {
            for region in children(regions, "ClassInstance", type: "TRTSpectrumRegion") {
                guard let n = region.attribute(forName: "Name")?.stringValue else { continue }
                let line = fields(region)["Line"] ?? "Ka"
                if let i = elements.firstIndex(where: { $0.0 == n }) { elements[i].1 = line } else { elements.append((n, line)) }
            }
        }
        let lineCounter = (text(child(db, "LineCounter")) ?? "").split(separator: ",").compactMap {
            Double($0.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        var spectra: [Int: Spectrum] = [:]
        for i in indexes {
            guard let node = child(child(db, "SpectrumData\(i)"), "ClassInstance") else {
                throw SEMEDSReadError("\(name) names SpectrumData\(i) but its header has no spectrum for it.")
            }
            spectra[i] = try Spectrum(node, name: name)
        }
        return Header(name: dbName, date: date, version: version, sem: sem, dsp: dsp, hv: hv, units: units, xRes: xRes, yRes: yRes,
                      mode: guessMode(hv), imageNode: imageNode, imageWidth: width, imageHeight: height, overviewNode: overview,
                      elements: elements, lineCounter: lineCounter, spectra: spectra)
    }

    /// rsciio `parse_line`: one letter gets "a", more than two are cut to two, then capitalised.
    static func parseLine(_ line: String) -> String {
        var l = line
        if l.count == 1 { l += "a" } else if l.count > 2 { l = String(l.prefix(2)) }
        return l.prefix(1).uppercased() + l.dropFirst().lowercased()
    }

    /// The images of one image node, empty planes skipped (rsciio `_parse_image`).
    static func images(_ node: XMLElement, header h: Header, fileName: String) throws -> [SEMEDSImage] {
        guard let width = whole(text(child(node, "Width"))), let height = whole(text(child(node, "Height"))),
              let itemSize = whole(text(child(node, "ItemSize"))), let planes = whole(text(child(node, "PlaneCount"))) else {
            throw SEMEDSReadError("\(fileName) has an image node without its size.")
        }
        guard [1, 2, 4].contains(itemSize) else { throw SEMEDSReadError("\(fileName) stores images of \(itemSize)-byte pixels.") }
        var out: [SEMEDSImage] = []
        for i in 0..<max(planes, 0) {
            guard let plane = child(node, "Plane\(i)"), let b64 = text(child(plane, "Data")),
                  let raw = Data(base64Encoded: b64, options: .ignoreUnknownCharacters) else { continue }
            let bytes = [UInt8](raw)
            let count = bytes.count / itemSize
            var pixels = [UInt32](repeating: 0, count: count)
            for k in 0..<count {
                var v: UInt32 = 0
                for b in 0..<itemSize { v |= UInt32(bytes[k * itemSize + b]) << (8 * b) }
                pixels[k] = v
            }
            guard pixels.contains(where: { $0 != 0 }) else { continue }
            let area = width.multipliedReportingOverflow(by: height)
            guard !area.overflow, count == area.partialValue else {
                throw SEMEDSReadError("An image of \(fileName) holds \(count) pixels for \(width) x \(height).")
            }
            var md = SEMEDSMetadata()
            md.mode = h.mode
            md.beamEnergy = h.hv
            md.magnification = number(h.sem["Mag"])
            md.sampleName = h.name
            md.originalFilename = fileName
            if let desc = child(plane, "Description") { md.title = desc.stringValue ?? "None" }
            out.append(SEMEDSImage(axes: [SEMEDSAxis(name: "height", size: height, scale: h.yRes, offset: 0, units: h.units),
                                          SEMEDSAxis(name: "width", size: width, scale: h.xRes, offset: 0, units: h.units)],
                                   dtype: "uint\(itemSize * 8)", width: width, height: height, pixels: pixels, metadata: md))
        }
        return out
    }

    /// rsciio `estimate_map_depth` (for the cython unpacker): the dtype that holds twice the mean count of the busiest channel.
    static func mapDepth(sum: [UInt64], width: Int, height: Int) -> String {
        let roof = (sum.max() ?? 0) / UInt64(width) / UInt64(height) * 2
        if roof > 0xFFFF { return "uint32" }
        if roof > 0xFF { return "uint16" }
        return "uint8"
    }

    static func readBCF(url: URL) throws -> SEMEDSFile {
        let name = url.lastPathComponent
        let sfs = try BrukerSFS(url: url)
        guard let headerItem = sfs.item(path: "EDSDatabase/HeaderData") else {
            throw SEMEDSReadError("\(name) holds no EDSDatabase/HeaderData: it is not a Bruker hypermap.")
        }
        let indexes = sfs.items.filter { $0.path.hasPrefix("EDSDatabase/") && $0.name.contains("SpectrumData") }
            .compactMap { $0.name.last.flatMap { Int(String($0)) } }
        guard let index = indexes.min() else { throw SEMEDSReadError("\(name) holds no spectral data.") }
        let root = try document(try sfs.contents(headerItem), name: name)
        let h = try header(root, indexes: indexes, name: name)

        var signals: [SEMEDSSignal] = []
        for image in try images(h.imageNode, header: h, fileName: name) { signals.append(.image(image)) }
        if let overview = h.overviewNode {
            for image in try images(overview, header: h, fileName: name) { signals.append(.image(image)) }
        }

        guard let eds = h.spectra[index] else { throw SEMEDSReadError("\(name) has no spectrum for map \(index).") }
        let channels = eds.channels.count
        guard channels > 0 else { throw SEMEDSReadError("\(name) states an empty sum spectrum.") }
        guard let item = sfs.item(path: "EDSDatabase/SpectrumData\(index)") else {
            throw SEMEDSReadError("\(name) holds no EDSDatabase/SpectrumData\(index).")
        }
        let cube = try hypermap(sfs: sfs, item: item, height: h.imageHeight, width: h.imageWidth, channels: channels, name: name)

        var md = SEMEDSMetadata()
        md.mode = h.mode
        md.beamEnergy = h.hv
        md.magnification = number(h.sem["Mag"])
        eds.detectorFields(into: &md)
        md.realTime = realTime(h)
        if let hv = eds.hv { md.beamEnergy = hv }
        md.originalFilename = name
        md.title = "EDX"
        md.date = h.date?.date
        md.time = h.date?.time
        md.sampleName = h.name
        md.elements = h.elements.map(\.name).sorted()
        md.xrayLines = h.elements.map { $0.name + "_" + parseLine($0.line) }.sorted()
        md.signalType = "EDS_" + h.mode
        let axes = [SEMEDSAxis(name: "height", size: h.imageHeight, scale: h.yRes, offset: 0, units: h.units),
                    SEMEDSAxis(name: "width", size: h.imageWidth, scale: h.yRes, offset: 0, units: h.units),
                    SEMEDSAxis(name: "Energy", size: channels, scale: eds.scale, offset: eds.offset, units: "keV")]
        signals.append(.spectrumImage(SEMEDSSpectrumImage(shape: [h.imageHeight, h.imageWidth, channels], axes: axes,
                                                          dtype: mapDepth(sum: eds.channels, width: h.imageWidth, height: h.imageHeight),
                                                          cube: cube, metadata: md)))
        return SEMEDSFile(url: url, signals: signals)
    }

    /// rsciio `calc_real_time`: line count sum · line average · pixel average · pixel time · width · 1e-6 seconds.
    static func realTime(_ h: Header) -> Double? {
        guard let la = number(h.dsp["LineAverage"]), let pa = number(h.dsp["PixelAverage"]), let pt = number(h.dsp["PixelTime"]) else {
            return nil
        }
        let lines = h.lineCounter.reduce(0, +)
        return lines * la * pa * pt * Double(h.imageWidth) * 1e-6
    }

    /// The hypermap of one `SpectrumData` file (`unbcf_fast.bin_to_numpy`, downsample 1, no energy cut-off).
    static func hypermap(sfs: BrukerSFS, item: BrukerSFS.Item, height: Int, width: Int, channels: Int, name: String) throws -> CSRSpectrumImage {
        var stream = SEMEDSByteStream(name: name, next: sfs.blocks(item))
        let lines = Int(try stream.u32())
        _ = try stream.u32()   // the stream's own width; rsciio sizes the map from the header's image
        try stream.seek(0x1A0)
        guard lines <= height else {
            throw SEMEDSReadError("\(name)'s spectral data holds \(lines) lines for a map of \(height): it is not this map's.")
        }
        // The map's size comes from the XML alone: the stream may hold fewer lines than the map and names each pixel it stores by
        // x, so the file does not bound it. It is held to a stated cap instead: the builder's rows, and the one dense line
        // unpacked at a time.
        var builder = try CSRSpectrumImageBuilder(ny: height, nx: width, channels: channels)
        let lineCount = width.multipliedReportingOverflow(by: channels)
        guard !lineCount.overflow, lineCount.partialValue <= SEMEDSFile.largestArray else {
            throw SEMEDSReadError("\(name) states a map \(width) pixels wide of \(channels) channels, more than macEM unpacks in one line.")
        }
        var line = [UInt32](repeating: 0, count: lineCount.partialValue)
        for _ in 0..<lines {
            for i in line.indices { line[i] = 0 }
            let pixels = Int(try stream.u32())
            for _ in 0..<pixels {
                let x = Int(try stream.u32())
                _ = try stream.u16()               // chan1
                _ = try stream.u16()               // chan2
                try stream.skip(4)
                let flag = try stream.u16()
                _ = try stream.u16()               // data_size1
                let pulses = Int(try stream.u16())
                let size2 = Int(try stream.u32())
                guard x < width else { throw SEMEDSReadError("\(name) places a pixel at x = \(x) in a map \(width) wide.") }
                let base = x * channels
                switch flag {
                case 0:
                    let src = try stream.take(size2)
                    try unpack16(src, pulses: pulses, into: &line, base: base, cutoff: channels, name: name)
                case 1:
                    let src = try stream.take(size2)
                    try unpack12(src, pulses: pulses, into: &line, base: base, cutoff: channels, name: name)
                default:
                    guard size2 >= 4 else { throw SEMEDSReadError("\(name) holds a packed pixel of \(size2) bytes.") }
                    let src = try stream.take(size2 - 4)
                    // The cython unpacker takes the length as uint16_t.
                    try unpackInstructed(src, limit: Int(UInt16(truncatingIfNeeded: size2 - 4)), into: &line, base: base,
                                         cutoff: channels, name: name)
                    if pulses > 0 {
                        _ = try stream.u32()
                        for _ in 0..<pulses {
                            let v = Int(try stream.u16())
                            if v < channels { line[base + v] &+= 1 }
                        }
                    } else {
                        try stream.skip(4)
                    }
                }
            }
            line.withUnsafeBufferPointer { all in
                for x in 0..<width {
                    builder.append(spectrum: UnsafeBufferPointer(rebasing: all[(x * channels)..<((x + 1) * channels)]))
                }
            }
        }
        return builder.finish()
    }

    static func unpack16(_ src: ArraySlice<UInt8>, pulses: Int, into line: inout [UInt32], base: Int, cutoff: Int, name: String) throws {
        let s = src.startIndex
        guard pulses * 2 <= src.count else { throw SEMEDSReadError("\(name) holds a 16-bit pixel shorter than its pulse count.") }
        for i in 0..<pulses {
            let c = Int(src[s + 2 * i]) | Int(src[s + 2 * i + 1]) << 8
            if c < cutoff { line[base + c] &+= 1 }
        }
    }

    static func unpack12(_ src: ArraySlice<UInt8>, pulses: Int, into line: inout [UInt32], base: Int, cutoff: Int, name: String) throws {
        let s = src.startIndex
        func at(_ k: Int) throws -> Int {
            guard k < src.count else { throw SEMEDSReadError("\(name) holds a 12-bit pixel shorter than its pulse count.") }
            return Int(src[s + k])
        }
        for i in 0..<pulses {
            let g = 6 * (i / 4)
            let c: Int
            switch i % 4 {
            case 0: c = try (at(g) >> 4) + (at(g + 1) << 4)
            case 1: c = try ((at(g) << 8) + at(g + 3)) & 0xFFF
            case 2: c = try (at(g + 2) << 4) + (at(g + 5) >> 4)
            default: c = try ((at(g + 5) << 8) + at(g + 4)) & 0xFFF
            }
            if c < cutoff { line[base + c] &+= 1 }
        }
    }

    /// The "instructively packed" pixel: runs of (size, channels) heads, size 0 for empty channels, else a gain of `size` bytes
    /// (1, 2, 4, or 5 read for 8) and the run's values, nibbles for size 1, bytes for 2, words for 4, longs at word stride for 8.
    static func unpackInstructed(_ src: ArraySlice<UInt8>, limit: Int, into line: inout [UInt32], base: Int, cutoff: Int,
                                 name: String) throws {
        let s = src.startIndex
        func b(_ k: Int) throws -> Int {
            guard k >= 0, k < src.count else { throw SEMEDSReadError("\(name) holds a packed pixel that runs past its end.") }
            return Int(src[s + k])
        }
        func r16(_ k: Int) throws -> Int { try b(k) | (b(k + 1) << 8) }
        func r32(_ k: Int) throws -> Int { try r16(k) | (r16(k + 2) << 16) }
        var offset = 0, channel = 0
        while offset < limit {
            let size = try b(offset), runs = try b(offset + 1)
            offset += 2
            if size == 0 { channel += runs; continue }
            // C `int` gains: a 32-bit read is signed, the 5-byte read keeps its low 32 bits.
            let gain: Int
            switch size {
            case 1: gain = try b(offset)
            case 2: gain = try r16(offset)
            default: gain = try Int(Int32(truncatingIfNeeded: r32(offset)))
            }
            offset += size
            let length: Int
            switch size {
            case 1:
                for i in 0..<runs where i + channel < cutoff {
                    let byte = try b(offset + i / 2)
                    let v = i % 2 == 0 ? (byte & 15) : (byte >> 4)
                    line[base + i + channel] &+= UInt32(truncatingIfNeeded: v + gain)
                }
                length = runs % 2 == 0 ? runs / 2 : runs / 2 + 1
            case 2:
                for i in 0..<runs where i + channel < cutoff {
                    let v = try b(offset + i)
                    line[base + i + channel] &+= UInt32(truncatingIfNeeded: v + gain)
                }
                length = runs
            case 4:
                for i in 0..<runs where i + channel < cutoff {
                    let v = try r16(offset + i * 2)
                    line[base + i + channel] &+= UInt32(truncatingIfNeeded: v + gain)
                }
                length = runs * 2
            default:
                for i in 0..<runs where i + channel < cutoff {
                    let v = try r32(offset + i * 2)
                    line[base + i + channel] &+= UInt32(truncatingIfNeeded: v + gain)
                }
                length = runs * size / 2
            }
            offset += length
            channel += runs
        }
    }

    // MARK: - .spx

    static func readSPX(url: URL) throws -> SEMEDSFile {
        let name = url.lastPathComponent
        let raw: [UInt8]
        do { raw = [UInt8](try Data(contentsOf: url)) } catch { throw SEMEDSReadError("\(name) could not be read: \(ErrorDetail.text(error))") }
        let root = try document(raw, name: name)
        guard let node = child(root, "ClassInstance", type: "TRTSpectrum") else {
            throw SEMEDSReadError("\(name) holds no Bruker spectrum (TRTSpectrum).")
        }
        let spectrum = try Spectrum(node, name: name)
        let mode = guessMode(spectrum.hv)
        var md = SEMEDSMetadata()
        md.mode = mode
        spectrum.detectorFields(into: &md)
        md.beamEnergy = spectrum.hv
        md.originalFilename = name
        md.title = "EDX"
        md.date = spectrum.date?.date
        md.time = spectrum.date?.time
        md.sampleName = node.attribute(forName: "Name")?.stringValue ?? "Undefinded"
        md.signalType = "EDS_" + mode
        if let list = child(node, "ClassInstance", type: "TRTPSEElementList"),
           let kids = child(list, "ChildClassInstances") {
            md.elements = children(kids, "ClassInstance").compactMap { $0.attribute(forName: "Name")?.stringValue }
        }
        let axis = SEMEDSAxis(name: "Energy", size: spectrum.channels.count, scale: spectrum.scale, offset: spectrum.offset, units: "keV")
        return SEMEDSFile(url: url, signals: [.spectrum(SEMEDSSpectrum(axis: axis, dtype: "uint64",
                                                                       counts: spectrum.channels.map { Int64(bitPattern: $0) },
                                                                       metadata: md))])
    }
}
